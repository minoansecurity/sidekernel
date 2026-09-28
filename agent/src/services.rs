//! Background threads: port scanner, credential relay, login adoption.

use std::collections::BTreeSet;
use std::fs;
use std::fs::File;
use std::net::{TcpListener, TcpStream};
use std::os::fd::OwnedFd;
use std::thread;
use std::time::{Duration, SystemTime};

use crate::contract::{
    CtlStatus, Frame, CREDENTIAL_FILE, MAX_ADOPT_BLOB, MAX_CTL_REPLY_FRAME, PLACEHOLDER_BLOB,
    RELAY_PORT, SERVICE_PORT,
};
use crate::serve::{read_frame, write_frame};
use crate::vsock;

pub fn start() {
    thread::spawn(scan_ports);
    thread::spawn(relay_credentials);
    thread::spawn(watch_for_login);
}

fn scan_ports() {
    let mut host = dial_host_forever();
    if write_frame(&mut host, &Frame::HelloPortEvents).is_err() {
        return;
    }
    let mut open = BTreeSet::new();
    loop {
        let now = listening_ports();
        for &port in now.symmetric_difference(&open) {
            let event = Frame::PortEvent { port, open: now.contains(&port) };
            if write_frame(&mut host, &event).is_err() {
                return;
            }
        }
        open = now;
        thread::sleep(Duration::from_secs(1));
    }
}

fn listening_ports() -> BTreeSet<u16> {
    let mut ports = BTreeSet::new();
    for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
        if let Ok(text) = fs::read_to_string(table) {
            collect_listeners(&text, &mut ports);
        }
    }
    ports
}

fn collect_listeners(table: &str, ports: &mut BTreeSet<u16>) {
    for line in table.lines().skip(1) {
        if let Some(port) = listener_port(line) {
            if port != RELAY_PORT {
                ports.insert(port);
            }
        }
    }
}

/// State 0A is TCP_LISTEN.
fn listener_port(line: &str) -> Option<u16> {
    let mut fields = line.split_whitespace();
    let local = fields.nth(1)?;
    let state = fields.nth(1)?;
    if state != "0A" {
        return None;
    }
    u16::from_str_radix(local.rsplit(':').next()?, 16).ok()
}

/// ANTHROPIC_BASE_URL points here.
fn relay_credentials() {
    let Ok(listener) = TcpListener::bind(("127.0.0.1", RELAY_PORT)) else {
        eprintln!("sk-agent: credential relay failed to bind 127.0.0.1:{RELAY_PORT}; API calls cannot reach the host proxy");
        return;
    };
    for connection in listener.incoming() {
        let Ok(request) = connection else { continue };
        thread::spawn(move || relay_one(request));
    }
}

fn relay_one(request: TcpStream) {
    let Ok(fd) = vsock::connect_to_host(SERVICE_PORT) else { return };
    let mut host = File::from(fd);
    if write_frame(&mut host, &Frame::HelloProxy).is_ok() {
        crate::serve::splice(host, File::from(OwnedFd::from(request)));
    }
}

/// Offers each new /login credential to the host for the Keychain.
fn watch_for_login() {
    let mut acked: Option<SystemTime> = None;
    loop {
        thread::sleep(Duration::from_secs(1));
        let Ok(meta) = fs::metadata(CREDENTIAL_FILE) else {
            acked = None;
            continue;
        };
        let stamp = meta.modified().ok();
        if stamp.is_some() && stamp == acked {
            continue;
        }
        let Some(status) = offer_login() else { continue };
        acked = stamp;
        // Overwrite, never delete: the CLI reads this file to know it is logged in.
        if status == CtlStatus::Ok {
            replace_with_placeholder();
        }
    }
}

fn offer_login() -> Option<CtlStatus> {
    let blob = fs::read(CREDENTIAL_FILE).ok()?;
    if blob.is_empty() || blob.len() > MAX_ADOPT_BLOB as usize {
        return None;
    }
    let mut host = File::from(vsock::connect_to_host(SERVICE_PORT).ok()?);
    write_frame(&mut host, &Frame::Adopt { blob }).ok()?;
    match read_frame(&mut host, MAX_CTL_REPLY_FRAME) {
        Ok(Frame::CtlReply { status, .. }) => Some(status),
        _ => None,
    }
}

/// Rename, so no reader sees a partial file.
fn replace_with_placeholder() {
    let staged = format!("{CREDENTIAL_FILE}.sk-tmp");
    if fs::write(&staged, PLACEHOLDER_BLOB).is_err() || fs::rename(&staged, CREDENTIAL_FILE).is_err() {
        let _ = fs::remove_file(&staged);
        eprintln!("sk-agent: could not replace the adopted login with the placeholder");
    }
}

fn dial_host_forever() -> File {
    loop {
        if let Ok(fd) = vsock::connect_to_host(SERVICE_PORT) {
            return File::from(fd);
        }
        thread::sleep(Duration::from_millis(200));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Real rows from a live guest, including the relay's own listener at 0x1092.
    const TCP4: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
        \x20  0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 193 1 00000000ee3adb75 100 0 0 10 0\n\
        \x20  1: 0100007F:0BB8 0100007F:85EE 06 00000000:00000000 03:0000176E 00000000     0        0 0 3 00000000a106c5cc\n\
        \x20  2: 0100007F:1092 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 194 1 00000000ee3adb76 100 0 0 10 0\n";
    const TCP6: &str = "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
        \x20  0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 200 1 00000000aabbccdd 100 0 0 10 0\n";

    #[test]
    fn listeners_are_collected_and_the_relay_port_is_skipped() {
        let mut ports = BTreeSet::new();
        collect_listeners(TCP4, &mut ports);
        collect_listeners(TCP6, &mut ports);
        assert_eq!(ports, BTreeSet::from([3000, 8080]));
    }

    #[test]
    fn non_listen_states_and_malformed_rows_are_ignored() {
        assert_eq!(listener_port("   1: 0100007F:0BB8 0100007F:85EE 06 0:0 00:0 0 0 0 0 3 x"), None);
        assert_eq!(listener_port(""), None);
        assert_eq!(listener_port("  sl  local_address rem_address   st"), None);
        assert_eq!(listener_port("   0: garbage:ZZZZ 00000000:0000 0A"), None);
        assert_eq!(listener_port("   0: 00000000:0050 00000000:0000 0A x"), Some(80));
    }

    #[test]
    #[cfg_attr(not(target_os = "linux"), ignore = "reads the live Linux /proc/net/tcp, which the macOS build host does not have")]
    fn the_diff_loop_reads_this_machines_tables_without_error() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(listening_ports().contains(&port));
    }
}
