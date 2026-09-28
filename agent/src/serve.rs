//! Serves the connections the host dials, one exec at a time.

use std::fs::File;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::os::fd::{AsFd, AsRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

use crate::contract::{Frame, CONTROL_PORT, MAX_CONTROL_FRAME};
use crate::net;
use crate::process;
use crate::sys;
use crate::vsock;

pub fn run() -> io::Result<()> {
    let listener = vsock::listen(CONTROL_PORT)?;
    let exec_running = Arc::new(AtomicBool::new(false));
    loop {
        let Some(connection) = vsock::accept_from_host(listener.as_fd()) else { continue };
        dispatch(File::from(connection), &exec_running);
    }
}

/// The hello types a connection for life; a bad one is closed silently.
fn dispatch(mut connection: File, exec_running: &Arc<AtomicBool>) {
    match read_frame(&mut connection, MAX_CONTROL_FRAME) {
        Ok(Frame::HelloExec { network_on }) => {
            net::posture_changed(network_on);
            if exec_running.swap(true, Ordering::AcqRel) {
                let _ = write_frame(&mut connection, &Frame::Error { reason: "busy".into() });
                return;
            }
            let running = exec_running.clone();
            thread::spawn(move || {
                exec_session(connection);
                running.store(false, Ordering::Release);
            });
        }
        Ok(Frame::HelloTunnel { port }) => { thread::spawn(move || tunnel(connection, port)); }
        Ok(Frame::HelloNetChanged { on }) => net::posture_changed(on),
        _ => {}
    }
}

fn exec_session(mut control: File) {
    let Ok(Frame::Exec { nonce, workdir, argv, env, cols, rows }) =
        read_frame(&mut control, MAX_CONTROL_FRAME) else { return };
    let mut child = match process::spawn(&workdir, &argv, &env, cols, rows) {
        Ok(child) => child,
        Err(e) => {
            let _ = write_frame(&mut control, &Frame::Error { reason: e.to_string() });
            return;
        }
    };
    let _ = write_frame(&mut control, &Frame::Started);
    let pump = control.try_clone().ok().and_then(|clone| resize_pump(clone, child.master_fd()));
    let code = child.forward_stdio_and_wait(&nonce).unwrap_or(1);
    let _ = write_frame(&mut control, &Frame::Exited { code });
    if let Some(thread) = pump { let _ = thread.join(); }
}

fn resize_pump(mut control: File, master: RawFd) -> Option<thread::JoinHandle<()>> {
    let master = process::dup_cloexec(master).ok()?;
    Some(thread::spawn(move || {
        while let Ok(Frame::Resize { cols, rows }) = read_frame(&mut control, MAX_CONTROL_FRAME) {
            process::resize(master.as_raw_fd(), cols, rows);
        }
    }))
}

fn tunnel(guest: File, port: u16) {
    let Ok(target) = TcpStream::connect(("127.0.0.1", port)) else { return };
    splice(guest, File::from(OwnedFd::from(target)));
}

/// Shuts both down when either direction ends, so neither copy hangs.
pub fn splice(a: File, b: File) {
    thread::scope(|scope| {
        scope.spawn(|| {
            let _ = io::copy(&mut &a, &mut &b);
            shutdown_both(&a, &b);
        });
        let _ = io::copy(&mut &b, &mut &a);
        shutdown_both(&a, &b);
    });
}

fn shutdown_both(a: &File, b: &File) {
    unsafe {
        sys::shutdown(a.as_raw_fd(), sys::SHUT_RDWR);
        sys::shutdown(b.as_raw_fd(), sys::SHUT_RDWR);
    }
}

/// Checks the length against the cap before allocating.
pub fn read_frame(from: &mut impl Read, cap: u32) -> io::Result<Frame> {
    let mut header = [0u8; 4];
    from.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header);
    if length == 0 || length > cap {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame length out of bounds"));
    }
    let mut body = vec![0u8; length as usize];
    from.read_exact(&mut body)?;
    Frame::decode_payload(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.0))
}

pub fn write_frame(to: &mut impl Write, frame: &Frame) -> io::Result<()> {
    let bytes = frame.try_encode()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "frame field too long for the wire"))?;
    to.write_all(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::net::Shutdown;
    use std::os::unix::net::UnixStream;

    fn as_file(stream: UnixStream) -> File {
        File::from(OwnedFd::from(stream))
    }

    #[test]
    fn frames_round_trip_over_a_stream() {
        let (mut a, mut b) = UnixStream::pair().unwrap();
        for frame in [Frame::Started, Frame::Resize { cols: 203, rows: 51 },
                      Frame::Exited { code: 130 }, Frame::Error { reason: "busy".into() }] {
            write_frame(&mut a, &frame).unwrap();
            assert_eq!(read_frame(&mut b, MAX_CONTROL_FRAME).unwrap(), frame);
        }
    }

    #[test]
    fn hostile_lengths_are_rejected_before_any_body_read() {
        let mut zero = Cursor::new(vec![0, 0, 0, 0]);
        assert!(read_frame(&mut zero, MAX_CONTROL_FRAME).is_err());
        let over_cap = (MAX_CONTROL_FRAME + 1).to_be_bytes().to_vec();
        assert!(read_frame(&mut Cursor::new(over_cap), MAX_CONTROL_FRAME).is_err());
    }

    #[test]
    fn truncated_and_malformed_bodies_are_errors() {
        let mut truncated = Cursor::new(vec![0, 0, 0, 5, 0x07]);
        assert!(read_frame(&mut truncated, MAX_CONTROL_FRAME).is_err());
        let mut unknown_tag = Cursor::new(vec![0, 0, 0, 1, 0xFF]);
        assert!(read_frame(&mut unknown_tag, MAX_CONTROL_FRAME).is_err());
    }

    #[test]
    fn splice_pumps_both_directions_and_propagates_close() {
        let (mut host_a, guest_a) = UnixStream::pair().unwrap();
        let (mut host_b, guest_b) = UnixStream::pair().unwrap();
        let spliced = thread::spawn(move || splice(as_file(guest_a), as_file(guest_b)));

        host_a.write_all(b"ping").unwrap();
        let mut buffer = [0u8; 4];
        host_b.read_exact(&mut buffer).unwrap();
        assert_eq!(&buffer, b"ping");

        host_b.write_all(b"pong").unwrap();
        host_a.read_exact(&mut buffer).unwrap();
        assert_eq!(&buffer, b"pong");

        host_a.shutdown(Shutdown::Both).unwrap();
        let mut rest = Vec::new();
        let _ = host_b.read_to_end(&mut rest);
        assert!(rest.is_empty());
        spliced.join().unwrap();
    }
}
