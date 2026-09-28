//! libc declarations and kernel ABI structs.

use std::ffi::{c_char, c_int, c_uint, c_ulong, c_void};
use std::io;

pub const AF_INET: c_int = 2;
pub const AF_VSOCK: c_int = 40;
pub const SOCK_STREAM: c_int = 1;
pub const SOCK_DGRAM: c_int = 2;
pub const SOCK_CLOEXEC: c_int = 0x80000;
pub const SOL_SOCKET: c_int = 1;
pub const SO_ERROR: c_int = 4;
pub const SO_BINDTODEVICE: c_int = 25;
pub const SHUT_RDWR: c_int = 2;
pub const VMADDR_CID_ANY: u32 = 0xFFFF_FFFF;

pub const MS_RDONLY: c_ulong = 0x0001;
pub const MS_NOSUID: c_ulong = 0x0002;
pub const MS_NODEV: c_ulong = 0x0004;
pub const MS_NOEXEC: c_ulong = 0x0008;
pub const MS_BIND: c_ulong = 0x1000;
pub const MS_MOVE: c_ulong = 0x2000;
pub const MS_REC: c_ulong = 0x4000;
pub const MS_PRIVATE: c_ulong = 0x40000;

pub const O_RDWR: c_int = 2;
pub const O_NOCTTY: c_int = 0x100;
pub const O_NONBLOCK: c_int = 0x800;
pub const O_CLOEXEC: c_int = 0x80000;
pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const F_DUPFD_CLOEXEC: c_int = 1030;
pub const AT_FDCWD: c_int = -100;
pub const X_OK: c_int = 1;

pub const POLLIN: i16 = 0x001;
pub const POLLOUT: i16 = 0x004;
#[cfg(test)]
pub const POLLHUP: i16 = 0x010;
pub const EINTR: i32 = 4;
pub const EAGAIN: i32 = 11;
pub const EEXIST: i32 = 17;
pub const ETIMEDOUT: i32 = 110;
pub const SIGKILL: c_int = 9;
pub const SIGCHLD: c_int = 17;
pub const SIG_BLOCK: c_int = 0;
pub const SIG_UNBLOCK: c_int = 1;
pub const WNOHANG: c_int = 1;

pub const SIOCADDRT: c_ulong = 0x890B;
pub const SIOCGIFFLAGS: c_ulong = 0x8913;
pub const SIOCSIFFLAGS: c_ulong = 0x8914;
pub const SIOCSIFADDR: c_ulong = 0x8916;
pub const SIOCSIFNETMASK: c_ulong = 0x891C;
pub const TIOCSCTTY: c_ulong = 0x540E;
pub const TIOCSWINSZ: c_ulong = 0x5414;
pub const TIOCGPTN: c_ulong = 0x8004_5430;
pub const TIOCSPTLCK: c_ulong = 0x4004_5431;
pub const IFF_UP: i16 = 0x1;
pub const RTF_UP: u16 = 0x0001;
pub const RTF_GATEWAY: u16 = 0x0002;

/// Kernel `sockaddr_vm`.
#[repr(C)]
#[derive(Default)]
pub struct SockaddrVm {
    pub svm_family: u16,
    pub svm_reserved1: u16,
    pub svm_port: u32,
    pub svm_cid: u32,
    pub svm_flags: u8,
    pub svm_zero: [u8; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Sockaddr {
    pub sa_family: u16,
    pub sa_data: [u8; 14],
}

/// The union is written raw per ioctl.
#[repr(C)]
pub struct Ifreq {
    pub name: [u8; 16],
    pub data: [u8; 24],
}

#[repr(C)]
pub struct Rtentry {
    pub rt_pad1: c_ulong,
    pub rt_dst: Sockaddr,
    pub rt_gateway: Sockaddr,
    pub rt_genmask: Sockaddr,
    pub rt_flags: u16,
    pub rt_pad2: i16,
    pub rt_pad3: c_ulong,
    pub rt_pad4: *mut c_void,
    pub rt_metric: i16,
    pub rt_dev: *mut c_char,
    pub rt_mtu: c_ulong,
    pub rt_window: c_ulong,
    pub rt_irtt: u16,
}

#[repr(C)]
pub struct PollFd {
    pub fd: c_int,
    pub events: i16,
    pub revents: i16,
}

#[repr(C)]
#[derive(Default)]
pub struct Winsize {
    pub ws_row: u16,
    pub ws_col: u16,
    pub ws_xpixel: u16,
    pub ws_ypixel: u16,
}

/// Initialize with `sigemptyset`.
#[repr(C)]
pub struct SigSet(pub [u64; 16]);

unsafe extern "C" {
    pub fn mount(src: *const c_char, target: *const c_char, fstype: *const c_char,
                 flags: c_ulong, data: *const c_void) -> c_int;
    pub fn chroot(path: *const c_char) -> c_int;
    pub fn sethostname(name: *const c_char, len: usize) -> c_int;
    pub fn sync();

    pub fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
    pub fn bind(fd: c_int, addr: *const c_void, len: u32) -> c_int;
    pub fn listen(fd: c_int, backlog: c_int) -> c_int;
    pub fn accept4(fd: c_int, addr: *mut c_void, len: *mut u32, flags: c_int) -> c_int;
    pub fn connect(fd: c_int, addr: *const c_void, len: u32) -> c_int;
    pub fn shutdown(fd: c_int, how: c_int) -> c_int;
    pub fn getsockopt(fd: c_int, level: c_int, name: c_int, value: *mut c_void, len: *mut u32) -> c_int;
    pub fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const c_void, len: u32) -> c_int;
    pub fn poll(fds: *mut PollFd, count: c_ulong, timeout_ms: c_int) -> c_int;
    pub fn ioctl(fd: c_int, request: c_ulong, arg: *mut c_void) -> c_int;

    pub fn fork() -> c_int;
    pub fn execve(path: *const c_char, argv: *const *const c_char, envp: *const *const c_char) -> c_int;
    pub fn faccessat(dirfd: c_int, path: *const c_char, mode: c_int, flags: c_int) -> c_int;
    pub fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
    pub fn kill(pid: c_int, sig: c_int) -> c_int;
    pub fn setsid() -> c_int;
    pub fn chdir(path: *const c_char) -> c_int;
    pub fn dup2(old_fd: c_int, new_fd: c_int) -> c_int;
    pub fn open(path: *const c_char, flags: c_int, mode: c_uint) -> c_int;
    pub fn read(fd: c_int, buf: *mut c_void, count: usize) -> isize;
    pub fn write(fd: c_int, buf: *const c_void, count: usize) -> isize;
    pub fn fcntl(fd: c_int, cmd: c_int, arg: c_int) -> c_int;
    pub fn _exit(code: c_int) -> !;

    pub fn sigemptyset(set: *mut SigSet) -> c_int;
    pub fn sigaddset(set: *mut SigSet, sig: c_int) -> c_int;
    pub fn sigprocmask(how: c_int, set: *const SigSet, old: *mut SigSet) -> c_int;
}

pub fn check(rc: c_int) -> io::Result<c_int> {
    if rc < 0 { Err(io::Error::last_os_error()) } else { Ok(rc) }
}

/// `128 + signal` for a killed child.
pub fn exit_code(status: c_int) -> i32 {
    if status & 0x7F == 0 {
        (status >> 8) & 0xFF
    } else if ((status & 0x7F) + 1) >> 1 > 0 {
        128 + (status & 0x7F)
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    #[test]
    fn struct_layouts_match_the_kernel_abi() {
        assert_eq!(size_of::<SockaddrVm>(), 16);
        assert_eq!(offset_of!(SockaddrVm, svm_family), 0);
        assert_eq!(offset_of!(SockaddrVm, svm_port), 4);
        assert_eq!(offset_of!(SockaddrVm, svm_cid), 8);
        assert_eq!(size_of::<Sockaddr>(), 16);
        assert_eq!(size_of::<Ifreq>(), 40);
        assert_eq!(offset_of!(Ifreq, data), 16);
        assert_eq!(size_of::<Rtentry>(), 120);
        assert_eq!(offset_of!(Rtentry, rt_dst), 8);
        assert_eq!(offset_of!(Rtentry, rt_gateway), 24);
        assert_eq!(offset_of!(Rtentry, rt_genmask), 40);
        assert_eq!(offset_of!(Rtentry, rt_flags), 56);
        assert_eq!(offset_of!(Rtentry, rt_dev), 88);
        assert_eq!(size_of::<PollFd>(), 8);
        assert_eq!(offset_of!(PollFd, events), 4);
        assert_eq!(size_of::<Winsize>(), 8);
        assert_eq!(size_of::<SigSet>(), 128);
    }

    #[test]
    fn cloexec_flags_agree() {
        assert_eq!(SOCK_CLOEXEC, O_CLOEXEC);
    }

    #[test]
    #[cfg_attr(not(target_os = "linux"), ignore = "needs the Linux socket ABI")]
    fn declarations_link_and_answer() {
        let fd = check(unsafe { socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0) }).unwrap();
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        assert!(check(unsafe { fcntl(fd.as_raw_fd(), F_GETFL, 0) }).is_ok());
        assert_eq!(unsafe { poll(std::ptr::null_mut(), 0, 0) }, 0);
        assert_eq!(unsafe { faccessat(AT_FDCWD, c"/bin/sh".as_ptr(), X_OK, 0) }, 0);
        let mut set = SigSet([0; 16]);
        assert_eq!(unsafe { sigemptyset(&mut set) }, 0);
        assert_eq!(unsafe { sigaddset(&mut set, SIGCHLD) }, 0);
    }

    #[test]
    fn exit_code_decodes_wait_statuses() {
        assert_eq!(exit_code(0), 0);
        assert_eq!(exit_code(7 << 8), 7);
        assert_eq!(exit_code(2), 130);
        assert_eq!(exit_code(9), 137);
    }
}
