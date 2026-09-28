//! AF_VSOCK sockets, which std lacks.

use std::ffi::c_void;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};

use crate::contract::VMADDR_CID_HOST;
use crate::sys;

const ADDRESS_LEN: u32 = std::mem::size_of::<sys::SockaddrVm>() as u32;

pub fn listen(port: u32) -> io::Result<OwnedFd> {
    let fd = socket()?;
    let addr = address(sys::VMADDR_CID_ANY, port);
    sys::check(unsafe { sys::bind(fd.as_raw_fd(), pointer(&addr), ADDRESS_LEN) })?;
    sys::check(unsafe { sys::listen(fd.as_raw_fd(), 8) })?;
    Ok(fd)
}

/// Only the host may connect, never a guest process.
pub fn accept_from_host(listener: BorrowedFd) -> Option<OwnedFd> {
    let mut peer = sys::SockaddrVm::default();
    let mut len = ADDRESS_LEN;
    let rc = unsafe {
        sys::accept4(listener.as_raw_fd(), &mut peer as *mut _ as *mut c_void,
                     &mut len, sys::SOCK_CLOEXEC)
    };
    if rc < 0 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        return None;
    }
    let connection = unsafe { OwnedFd::from_raw_fd(rc) };
    (peer.svm_cid == VMADDR_CID_HOST).then_some(connection)
}

/// A connect interrupted by a signal is finished by polling.
pub fn connect_to_host(port: u32) -> io::Result<OwnedFd> {
    let fd = socket()?;
    let addr = address(VMADDR_CID_HOST, port);
    match sys::check(unsafe { sys::connect(fd.as_raw_fd(), pointer(&addr), ADDRESS_LEN) }) {
        Ok(_) => return Ok(fd),
        Err(e) => match e.raw_os_error() {
            Some(sys::EINTR) => {}
            _ => return Err(e),
        },
    }
    if poll(fd.as_raw_fd(), sys::POLLOUT, 5000)? & sys::POLLOUT == 0 {
        return Err(io::Error::from_raw_os_error(sys::ETIMEDOUT));
    }
    match socket_error(&fd)? {
        0 => Ok(fd),
        err => Err(io::Error::from_raw_os_error(err)),
    }
}

pub fn poll(fd: RawFd, events: i16, timeout_ms: i32) -> io::Result<i16> {
    let mut pfd = sys::PollFd { fd, events, revents: 0 };
    loop {
        match sys::check(unsafe { sys::poll(&mut pfd, 1, timeout_ms) }) {
            Ok(0) => return Ok(0),
            Ok(_) => return Ok(pfd.revents),
            Err(e) if e.raw_os_error() == Some(sys::EINTR) => continue,
            Err(e) => return Err(e),
        }
    }
}

fn socket() -> io::Result<OwnedFd> {
    let fd = sys::check(unsafe { sys::socket(sys::AF_VSOCK, sys::SOCK_STREAM | sys::SOCK_CLOEXEC, 0) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn address(cid: u32, port: u32) -> sys::SockaddrVm {
    sys::SockaddrVm { svm_family: sys::AF_VSOCK as u16, svm_port: port, svm_cid: cid, ..Default::default() }
}

fn pointer(addr: &sys::SockaddrVm) -> *const c_void {
    addr as *const _ as *const c_void
}

fn socket_error(fd: &OwnedFd) -> io::Result<i32> {
    let mut err: i32 = 0;
    let mut len = std::mem::size_of::<i32>() as u32;
    sys::check(unsafe {
        sys::getsockopt(fd.as_raw_fd(), sys::SOL_SOCKET, sys::SO_ERROR,
                        &mut err as *mut _ as *mut c_void, &mut len)
    })?;
    Ok(err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    #[test]
    fn poll_reports_writable_and_times_out_on_quiet_read() {
        let (a, _b) = UnixStream::pair().unwrap();
        let revents = poll(a.as_raw_fd(), sys::POLLOUT, 1000).unwrap();
        assert_ne!(revents & sys::POLLOUT, 0, "fresh socket must be writable");
        let revents = poll(a.as_raw_fd(), sys::POLLIN, 10).unwrap();
        assert_eq!(revents, 0, "nothing to read must time out as 0");
    }

    #[test]
    fn poll_reports_hangup_after_peer_close() {
        let (a, b) = UnixStream::pair().unwrap();
        drop(b);
        let revents = poll(a.as_raw_fd(), sys::POLLIN, 1000).unwrap();
        assert_ne!(revents & (sys::POLLIN | sys::POLLHUP), 0);
    }
}
