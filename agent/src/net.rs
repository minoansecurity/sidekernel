//! Interface setup and a minimal DHCP client.

use crate::sys;
use std::ffi::{c_ulong, c_void};
use std::fs;
use std::fs::File;
use std::io::{self, Read};
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

static SAW_OFF: AtomicBool = AtomicBool::new(false);
static REPLUG: AtomicBool = AtomicBool::new(false);

pub fn configure(wait: bool) -> bool {
    let _ = bring_up("lo");
    if bring_up("eth0").is_err() { return false; }
    if wait { return acquire_lease(); }
    std::thread::spawn(|| {
        let mut leased = false;
        loop {
            if REPLUG.swap(false, Ordering::SeqCst) { leased = false; }
            if !leased && !carrier_positively_down() && acquire_lease() { leased = true; }
            std::thread::sleep(Duration::from_secs(2));
        }
    });
    true
}

/// Read by the prompt and `sk-net status`.
const STATE_FILE: &str = "/run/sk-net.state";

pub fn posture_changed(on: bool) {
    note_posture(on, &SAW_OFF, &REPLUG);
    let _ = publish_posture(on);
}

/// Rename, so a reader never sees it empty.
fn publish_posture(on: bool) -> io::Result<()> {
    let tmp = format!("{STATE_FILE}.tmp");
    fs::write(&tmp, if on { "on\n" } else { "off\n" })?;
    fs::rename(&tmp, STATE_FILE)
}

/// Flag a renewal only when an off was actually seen before the on.
fn note_posture(on: bool, saw_off: &AtomicBool, replug: &AtomicBool) {
    if !on {
        saw_off.store(true, Ordering::SeqCst);
    } else if saw_off.swap(false, Ordering::SeqCst) {
        replug.store(true, Ordering::SeqCst);
    }
}

fn acquire_lease() -> bool {
    let deadline = Instant::now() + Duration::from_secs(8);
    for _ in 0..4 {
        if let Some(lease) = dhcp_exchange("eth0") {
            if apply_lease(&lease, "eth0").is_ok() {
                write_resolv(&lease.dns);
                return true;
            }
        }
        if Instant::now() >= deadline { break; }
        std::thread::sleep(Duration::from_millis(300));
    }
    false
}

fn carrier_positively_down() -> bool {
    fs::read_to_string("/sys/class/net/eth0/carrier").is_ok_and(|s| carrier_down(&s))
}

/// Only a literal 0 means down; other values show up on live links.
fn carrier_down(reading: &str) -> bool {
    reading.trim() == "0"
}

#[derive(Default)]
struct Lease {
    ip: [u8; 4],
    mask: [u8; 4],
    router: [u8; 4],
    dns: Vec<[u8; 4]>,
    server: [u8; 4],
}

fn apply_lease(lease: &Lease, interface: &str) -> io::Result<()> {
    let fd = control_socket()?;
    interface_ioctl(&fd, sys::SIOCSIFADDR, &mut ifreq_with_address(interface, lease.ip))?;
    interface_ioctl(&fd, sys::SIOCSIFNETMASK, &mut ifreq_with_address(interface, lease.mask))?;
    bring_up(interface)?;
    if lease.router != [0, 0, 0, 0] { add_default_route(&fd, lease.router)?; }
    Ok(())
}

fn bring_up(interface: &str) -> io::Result<()> {
    let fd = control_socket()?;
    let mut request = ifreq(interface);
    interface_ioctl(&fd, sys::SIOCGIFFLAGS, &mut request)?;
    let flags = i16::from_ne_bytes([request.data[0], request.data[1]]) | sys::IFF_UP;
    request.data[0..2].copy_from_slice(&flags.to_ne_bytes());
    interface_ioctl(&fd, sys::SIOCSIFFLAGS, &mut request)
}

fn add_default_route(fd: &OwnedFd, gateway: [u8; 4]) -> io::Result<()> {
    let mut route = sys::Rtentry {
        rt_dst: route_sockaddr([0; 4]), rt_gateway: route_sockaddr(gateway),
        rt_genmask: route_sockaddr([0; 4]), rt_flags: sys::RTF_UP | sys::RTF_GATEWAY,
        rt_pad1: 0, rt_pad2: 0, rt_pad3: 0, rt_pad4: std::ptr::null_mut(),
        rt_metric: 0, rt_dev: std::ptr::null_mut(), rt_mtu: 0, rt_window: 0, rt_irtt: 0,
    };
    match interface_ioctl(fd, sys::SIOCADDRT, &mut route) {
        Err(error) if error.raw_os_error() != Some(sys::EEXIST) => Err(error),
        _ => Ok(()),
    }
}

fn route_sockaddr(address: [u8; 4]) -> sys::Sockaddr {
    let mut sockaddr = sys::Sockaddr { sa_family: sys::AF_INET as u16, ..Default::default() };
    sockaddr.sa_data[2..6].copy_from_slice(&address);
    sockaddr
}

fn control_socket() -> io::Result<OwnedFd> {
    let fd = sys::check(unsafe { sys::socket(sys::AF_INET, sys::SOCK_DGRAM | sys::SOCK_CLOEXEC, 0) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn interface_ioctl<T>(fd: &OwnedFd, request: c_ulong, argument: &mut T) -> io::Result<()> {
    sys::check(unsafe { sys::ioctl(fd.as_raw_fd(), request, argument as *mut T as *mut c_void) }).map(|_| ())
}

fn ifreq(interface: &str) -> sys::Ifreq {
    let mut name = [0u8; 16];
    let bytes = interface.as_bytes();
    let count = bytes.len().min(15);
    name[..count].copy_from_slice(&bytes[..count]);
    sys::Ifreq { name, data: [0u8; 24] }
}

fn ifreq_with_address(interface: &str, address: [u8; 4]) -> sys::Ifreq {
    let mut request = ifreq(interface);
    request.data[0..2].copy_from_slice(&(sys::AF_INET as u16).to_ne_bytes());
    request.data[4..8].copy_from_slice(&address);
    request
}

fn hardware_address(interface: &str) -> Option<[u8; 6]> {
    let text = fs::read_to_string(format!("/sys/class/net/{interface}/address")).ok()?;
    let mut mac = [0u8; 6];
    let mut octets = text.trim().split(':');
    for slot in &mut mac {
        *slot = u8::from_str_radix(octets.next()?, 16).ok()?;
    }
    Some(mac)
}

const DHCP_MAGIC: [u8; 4] = [99, 130, 83, 99];

fn dhcp_exchange(interface: &str) -> Option<Lease> {
    let mac = hardware_address(interface)?;
    let mut transaction = [0u8; 4];
    if let Ok(mut urandom) = File::open("/dev/urandom") {
        let _ = urandom.read_exact(&mut transaction);
    }
    let socket = UdpSocket::bind("0.0.0.0:68").ok()?;
    socket.set_broadcast(true).ok()?;
    socket.set_read_timeout(Some(Duration::from_millis(1200))).ok()?;
    bind_to_device(socket.as_raw_fd(), interface);
    let destination = SocketAddrV4::new(Ipv4Addr::new(255, 255, 255, 255), 67);

    let discover = build_packet(&mac, transaction, 1, [0; 4], [0; 4]);
    socket.send_to(&discover, destination).ok()?;
    let offer = receive_matching(&socket, transaction, 2)?;

    let request = build_packet(&mac, transaction, 3, offer.ip, offer.server);
    socket.send_to(&request, destination).ok()?;
    receive_matching(&socket, transaction, 5)
}

fn receive_matching(socket: &UdpSocket, transaction: [u8; 4], want_type: u8) -> Option<Lease> {
    let mut buffer = [0u8; 1024];
    for _ in 0..4 {
        let count = socket.recv(&mut buffer).ok()?;
        if let Some(lease) = parse_reply(&buffer[..count], transaction, want_type) {
            return Some(lease);
        }
    }
    None
}

fn build_packet(mac: &[u8; 6], transaction: [u8; 4], message_type: u8,
                requested_ip: [u8; 4], server: [u8; 4]) -> Vec<u8> {
    let mut packet = vec![0u8; 240];
    packet[0] = 1;
    packet[1] = 1;
    packet[2] = 6;
    packet[4..8].copy_from_slice(&transaction);
    packet[10] = 0x80;
    packet[28..34].copy_from_slice(mac);
    packet[236..240].copy_from_slice(&DHCP_MAGIC);
    packet.extend_from_slice(&[53, 1, message_type]);
    if message_type == 3 {
        packet.extend_from_slice(&[50, 4]);
        packet.extend_from_slice(&requested_ip);
        packet.extend_from_slice(&[54, 4]);
        packet.extend_from_slice(&server);
    }
    packet.extend_from_slice(&[55, 4, 1, 3, 6, 51]);
    packet.push(255);
    packet
}

/// Bounds-checks every option: a malformed packet must not panic PID 1.
fn parse_reply(buffer: &[u8], transaction: [u8; 4], want_type: u8) -> Option<Lease> {
    if buffer.len() < 240 || buffer[0] != 2 { return None; }
    if buffer[4..8] != transaction { return None; }
    if buffer[236..240] != DHCP_MAGIC { return None; }
    let mut lease = Lease::default();
    lease.ip.copy_from_slice(&buffer[16..20]);
    let mut index = 240;
    let mut message_type = 0u8;
    while index < buffer.len() {
        let code = buffer[index];
        if code == 255 { break; }
        if code == 0 { index += 1; continue; }
        if index + 1 >= buffer.len() { break; }
        let length = buffer[index + 1] as usize;
        let value_start = index + 2;
        if value_start + length > buffer.len() { break; }
        let value = &buffer[value_start..value_start + length];
        match code {
            53 if length == 1 => message_type = value[0],
            1 if length == 4 => lease.mask.copy_from_slice(value),
            3 if length >= 4 => lease.router.copy_from_slice(&value[..4]),
            54 if length == 4 => lease.server.copy_from_slice(value),
            6 => {
                for chunk in value.chunks_exact(4) {
                    let mut server = [0u8; 4];
                    server.copy_from_slice(chunk);
                    lease.dns.push(server);
                }
            }
            _ => {}
        }
        index = value_start + length;
    }
    if message_type != want_type { return None; }
    Some(lease)
}

fn write_resolv(dns: &[[u8; 4]]) {
    if dns.is_empty() { return; }
    let lines: String = dns.iter()
        .map(|d| format!("nameserver {}.{}.{}.{}\n", d[0], d[1], d[2], d[3]))
        .collect();
    let _ = fs::write("/etc/resolv.conf", lines);
}

fn bind_to_device(fd: RawFd, interface: &str) {
    let name = interface.as_bytes();
    unsafe {
        sys::setsockopt(fd, sys::SOL_SOCKET, sys::SO_BINDTODEVICE,
                        name.as_ptr() as *const c_void, name.len() as u32);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAC: [u8; 6] = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56];
    const TRANSACTION: [u8; 4] = [0xde, 0xad, 0xbe, 0xef];

    fn reply(message_type: u8) -> Vec<u8> {
        let mut packet = vec![0u8; 240];
        packet[0] = 2;
        packet[4..8].copy_from_slice(&TRANSACTION);
        packet[16..20].copy_from_slice(&[192, 168, 64, 5]);
        packet[236..240].copy_from_slice(&DHCP_MAGIC);
        packet.extend_from_slice(&[53, 1, message_type]);
        packet.extend_from_slice(&[1, 4, 255, 255, 255, 0]);
        packet.extend_from_slice(&[3, 4, 192, 168, 64, 1]);
        packet.extend_from_slice(&[54, 4, 192, 168, 64, 1]);
        packet.extend_from_slice(&[6, 8, 1, 1, 1, 1, 8, 8, 8, 8]);
        packet.push(255);
        packet
    }

    #[test]
    fn parse_reply_extracts_lease_fields() {
        let lease = parse_reply(&reply(2), TRANSACTION, 2).expect("valid OFFER must parse");
        assert_eq!(lease.ip, [192, 168, 64, 5]);
        assert_eq!(lease.mask, [255, 255, 255, 0]);
        assert_eq!(lease.router, [192, 168, 64, 1]);
        assert_eq!(lease.server, [192, 168, 64, 1]);
        assert_eq!(lease.dns, vec![[1, 1, 1, 1], [8, 8, 8, 8]]);
    }

    #[test]
    fn parse_reply_rejects_nonmatching_replies() {
        assert!(parse_reply(&reply(2), [0; 4], 2).is_none(), "wrong transaction id");
        let mut bad_magic = reply(2);
        bad_magic[236] = 0;
        assert!(parse_reply(&bad_magic, TRANSACTION, 2).is_none(), "wrong magic");
        assert!(parse_reply(&reply(2), TRANSACTION, 5).is_none(), "OFFER when an ACK is wanted");
        let mut not_a_reply = reply(2);
        not_a_reply[0] = 1;
        assert!(parse_reply(&not_a_reply, TRANSACTION, 2).is_none(), "BOOTREQUEST is not a reply");
        assert!(parse_reply(&[0u8; 239], TRANSACTION, 2).is_none(), "short packet");
    }

    #[test]
    fn parse_reply_survives_truncated_option_length() {
        let mut packet = vec![0u8; 240];
        packet[0] = 2;
        packet[4..8].copy_from_slice(&TRANSACTION);
        packet[236..240].copy_from_slice(&DHCP_MAGIC);
        packet.extend_from_slice(&[53, 200, 2]);
        assert!(parse_reply(&packet, TRANSACTION, 2).is_none());
    }

    #[test]
    fn discover_packet_layout() {
        let packet = build_packet(&MAC, TRANSACTION, 1, [0; 4], [0; 4]);
        assert_eq!(packet[0], 1, "BOOTREQUEST");
        assert_eq!(packet[1], 1, "htype ethernet");
        assert_eq!(packet[2], 6, "hlen");
        assert_eq!(&packet[4..8], &TRANSACTION);
        assert_eq!(packet[10], 0x80, "broadcast flag");
        assert_eq!(&packet[28..34], &MAC);
        assert_eq!(&packet[236..240], &DHCP_MAGIC);
        assert_eq!(&packet[240..243], &[53, 1, 1], "DHCPDISCOVER type option");
        assert_eq!(*packet.last().unwrap(), 255, "end option");
        assert!(!packet.windows(2).any(|w| w == [50, 4]));
        assert!(!packet.windows(2).any(|w| w == [54, 4]));
    }

    #[test]
    fn request_packet_adds_requested_ip_and_server_id() {
        let packet = build_packet(&MAC, TRANSACTION, 3, [10, 0, 0, 9], [10, 0, 0, 1]);
        assert_eq!(&packet[240..243], &[53, 1, 3], "DHCPREQUEST type option");
        assert!(packet.windows(6).any(|w| w == [50, 4, 10, 0, 0, 9]), "option 50 requested-IP");
        assert!(packet.windows(6).any(|w| w == [54, 4, 10, 0, 0, 1]), "option 54 server-id");
    }

    #[test]
    fn only_a_literal_carrier_zero_skips_a_dhcp_round() {
        assert!(carrier_down("0"));
        assert!(carrier_down("0\n"));
        assert!(!carrier_down("1\n"));
        assert!(!carrier_down(""));
        assert!(!carrier_down("unknown"));
    }

    #[test]
    fn replug_requires_off_positively_observed_then_on() {
        let saw_off = AtomicBool::new(false);
        let replug = AtomicBool::new(false);
        note_posture(true, &saw_off, &replug);
        assert!(!replug.load(Ordering::SeqCst));
        note_posture(false, &saw_off, &replug);
        assert!(!replug.load(Ordering::SeqCst));
        note_posture(true, &saw_off, &replug);
        assert!(replug.swap(false, Ordering::SeqCst));
        note_posture(true, &saw_off, &replug);
        assert!(!replug.load(Ordering::SeqCst));
    }

    #[test]
    fn route_sockaddr_places_ipv4_after_the_port_bytes() {
        let sockaddr = route_sockaddr([10, 0, 0, 1]);
        assert_eq!(sockaddr.sa_family, sys::AF_INET as u16);
        assert_eq!(&sockaddr.sa_data[..6], &[0, 0, 10, 0, 0, 1]);
    }
}
