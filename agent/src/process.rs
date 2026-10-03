//! Runs interactive commands on a PTY and noninteractive commands on byte streams.

use std::ffi::{c_char, c_int, c_uint, c_void, CStr, CString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::thread;

use crate::contract::{Frame, StdioStream, SERVICE_PORT};
use crate::serve::write_frame;
use crate::sys;
use crate::vsock;

/// Killed and reaped on drop.
pub struct RunningProcess {
    pid: c_int,
    input: Option<OwnedFd>,
    output: OwnedFd,
    error: Option<OwnedFd>,
    tty: bool,
    reaped: bool,
}

const BASE_ENV: [&str; 4] = [
    "HOME=/root",
    "PATH=/root/.local/bin:/run/sidekernel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "TERM=xterm-256color",
    "LANG=C.UTF-8",
];

/// Everything is allocated before the fork.
pub fn spawn(workdir: &str, argv: &[String], env: &[String],
             tty: bool, cols: u16, rows: u16) -> io::Result<RunningProcess> {
    if argv.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "exec has empty argv"));
    }
    let argv_owned = cstrings(argv)?;
    let merged = merge_env(&BASE_ENV, env);
    let envp_owned = cstrings(&merged)?;
    let executable = resolve_executable(&argv[0], &merged)?;
    let workdir = CString::new(workdir).map_err(nul_error)?;
    let argv_pointers = pointer_vec(&argv_owned);
    let envp_pointers = pointer_vec(&envp_owned);
    let (input, output, error, child_input, child_output, child_error) = if tty {
        let (master, slave) = open_pty(cols, rows)?;
        (dup_cloexec(master.as_raw_fd())?, master, None,
         dup_cloexec(slave.as_raw_fd())?, dup_cloexec(slave.as_raw_fd())?, slave)
    } else {
        // Separate sockets preserve arbitrary bytes and deliver EOF when input closes.
        // UnixStream::pair creates close-on-exec descriptors, just like the PTY path.
        let (input, child_input) = UnixStream::pair()?;
        let (output, child_output) = UnixStream::pair()?;
        let (error, child_error) = UnixStream::pair()?;
        (OwnedFd::from(input), OwnedFd::from(output), Some(OwnedFd::from(error)),
         OwnedFd::from(child_input), OwnedFd::from(child_output), OwnedFd::from(child_error))
    };

    let pid = unsafe { sys::fork() };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        exec_child(&executable, &argv_pointers, &envp_pointers, &workdir,
                   child_input.as_raw_fd(), child_output.as_raw_fd(), child_error.as_raw_fd(), tty);
    }
    Ok(RunningProcess { pid, input: Some(input), output, error, tty, reaped: false })
}

/// Async-signal-safe calls only.
fn exec_child(executable: &CStr, argv: &[*const c_char], envp: &[*const c_char],
              workdir: &CStr, input: RawFd, output: RawFd, error: RawFd, tty: bool) -> ! {
    unsafe {
        let mut set = sys::SigSet([0; 16]);
        sys::sigemptyset(&mut set);
        sys::sigaddset(&mut set, sys::SIGCHLD);
        sys::sigprocmask(sys::SIG_UNBLOCK, &set, std::ptr::null_mut());
        sys::setsid();
        if tty { sys::ioctl(input, sys::TIOCSCTTY, std::ptr::null_mut()); }
        sys::dup2(input, 0);
        sys::dup2(output, 1);
        sys::dup2(error, 2);
        // Abort rather than exec in the wrong directory: `save` tars its cwd.
        if sys::chdir(workdir.as_ptr()) != 0 {
            let message = b"sk-agent: cannot enter workdir\n";
            sys::write(2, message.as_ptr() as *const c_void, message.len());
            sys::_exit(127);
        }
        sys::execve(executable.as_ptr(), argv.as_ptr(), envp.as_ptr());
        sys::_exit(127);
    }
}

impl RunningProcess {
    pub fn terminal_fd(&self) -> Option<RawFd> {
        self.tty.then(|| self.output.as_raw_fd())
    }

    pub fn forward_stdio_and_wait(&mut self, nonce: &str) -> io::Result<i32> {
        set_nonblocking(self.output.as_raw_fd())?;
        let stdin_connection = dial_stdio(StdioStream::Stdin, nonce)?;
        let stdout_connection = dial_stdio(StdioStream::Stdout, nonce)?;
        let error_pump = if let Some(error) = &self.error {
            set_nonblocking(error.as_raw_fd())?;
            let error = dup_cloexec(error.as_raw_fd())?;
            let connection = dial_stdio(StdioStream::Stderr, nonce)?;
            Some(thread::spawn(move || pump_stdout(error, connection)))
        } else { None };

        // Move the sole input endpoint into the pump: its drop delivers non-TTY EOF.
        let input = self.input.take().ok_or_else(|| io::Error::other("stdio already forwarded"))?;
        set_nonblocking(input.as_raw_fd())?;
        thread::spawn(move || pump_stdin(stdin_connection, input));
        let output = dup_cloexec(self.output.as_raw_fd())?;
        let stdout_pump = thread::spawn(move || pump_stdout(output, stdout_connection));

        let code = self.wait();
        let _ = stdout_pump.join();
        if let Some(pump) = error_pump { let _ = pump.join(); }
        Ok(code)
    }

    /// Also reaps orphans reparented to PID 1 and syncs the disks.
    fn wait(&mut self) -> i32 {
        let code = loop {
            let mut status: c_int = 0;
            let rc = unsafe { sys::waitpid(self.pid, &mut status, 0) };
            if rc == self.pid { break sys::exit_code(status); }
            if rc < 0 && io::Error::last_os_error().raw_os_error() != Some(sys::EINTR) { break 1; }
        };
        self.reaped = true;
        unsafe {
            while sys::waitpid(-1, std::ptr::null_mut(), sys::WNOHANG) > 0 {}
            sys::sync();
        }
        code
    }
}

impl Drop for RunningProcess {
    fn drop(&mut self) {
        if self.reaped { return; }
        unsafe {
            sys::kill(self.pid, sys::SIGKILL);
            let mut status: c_int = 0;
            while sys::waitpid(self.pid, &mut status, 0) < 0 {
                if io::Error::last_os_error().raw_os_error() != Some(sys::EINTR) { break; }
            }
        }
    }
}

pub fn resize(master: RawFd, cols: u16, rows: u16) {
    let mut size = sys::Winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    unsafe { sys::ioctl(master, sys::TIOCSWINSZ, &mut size as *mut _ as *mut c_void) };
}

pub fn dup_cloexec(fd: RawFd) -> io::Result<OwnedFd> {
    let duplicate = sys::check(unsafe { sys::fcntl(fd, sys::F_DUPFD_CLOEXEC, 0) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(duplicate) })
}

/// Sized before the fork so a TUI never lays out at 0x0.
fn open_pty(cols: u16, rows: u16) -> io::Result<(OwnedFd, OwnedFd)> {
    let master = open_cloexec(c"/dev/ptmx")?;
    let mut unlock: c_int = 0;
    let mut number: c_uint = 0;
    sys::check(unsafe { sys::ioctl(master.as_raw_fd(), sys::TIOCSPTLCK, &mut unlock as *mut _ as *mut c_void) })?;
    sys::check(unsafe { sys::ioctl(master.as_raw_fd(), sys::TIOCGPTN, &mut number as *mut _ as *mut c_void) })?;
    let slave = open_cloexec(&CString::new(format!("/dev/pts/{number}")).map_err(nul_error)?)?;
    if cols > 0 && rows > 0 { resize(master.as_raw_fd(), cols, rows); }
    Ok((master, slave))
}

fn open_cloexec(path: &CStr) -> io::Result<OwnedFd> {
    let fd = sys::check(unsafe { sys::open(path.as_ptr(), sys::O_RDWR | sys::O_NOCTTY | sys::O_CLOEXEC, 0) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// execve does no PATH lookup.
fn resolve_executable(argv0: &str, merged_env: &[String]) -> io::Result<CString> {
    if argv0.contains('/') { return CString::new(argv0).map_err(nul_error); }
    let path = merged_env.iter()
        .find_map(|entry| entry.strip_prefix("PATH="))
        .unwrap_or("/usr/bin:/bin");
    for directory in path.split(':').filter(|d| !d.is_empty()) {
        let candidate = CString::new(format!("{directory}/{argv0}")).map_err(nul_error)?;
        if unsafe { sys::faccessat(sys::AT_FDCWD, candidate.as_ptr(), sys::X_OK, 0) } == 0 {
            return Ok(candidate);
        }
    }
    Err(io::Error::new(io::ErrorKind::NotFound, format!("command not found: {argv0}")))
}

fn merge_env(base: &[&str], overrides: &[String]) -> Vec<String> {
    fn key_of(entry: &str) -> &str { entry.split_once('=').map_or(entry, |(key, _)| key) }
    let mut env: Vec<String> = base.iter().map(|entry| entry.to_string()).collect();
    for entry in overrides {
        match env.iter().position(|existing| key_of(existing) == key_of(entry)) {
            Some(index) => env[index] = entry.clone(),
            None => env.push(entry.clone()),
        }
    }
    env
}

fn cstrings(items: &[String]) -> io::Result<Vec<CString>> {
    items.iter()
        .map(|item| CString::new(item.as_str()))
        .collect::<Result<_, _>>()
        .map_err(nul_error)
}

fn nul_error(_: std::ffi::NulError) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "exec request contains a NUL byte")
}

fn pointer_vec(owned: &[CString]) -> Vec<*const c_char> {
    owned.iter().map(|s| s.as_ptr()).chain(std::iter::once(std::ptr::null())).collect()
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = sys::check(unsafe { sys::fcntl(fd, sys::F_GETFL, 0) })?;
    sys::check(unsafe { sys::fcntl(fd, sys::F_SETFL, flags | sys::O_NONBLOCK) })?;
    Ok(())
}

/// The nonce goes first, tying the stream to this exec.
fn dial_stdio(which: StdioStream, nonce: &str) -> io::Result<File> {
    let mut connection = File::from(vsock::connect_to_host(SERVICE_PORT)?);
    write_frame(&mut connection, &Frame::HelloStdio { which, nonce: nonce.to_string() })?;
    Ok(connection)
}

fn pump_stdin(mut host: File, master: OwnedFd) {
    let fd = master.as_raw_fd();
    let mut buffer = [0u8; 4096];
    loop {
        let count = match host.read(&mut buffer) {
            Ok(0) => return,
            Ok(count) => count,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        let mut written = 0;
        while written < count {
            let wrote = unsafe { sys::write(fd, buffer[written..count].as_ptr() as *const c_void, count - written) };
            if wrote > 0 { written += wrote as usize; continue; }
            match io::Error::last_os_error().raw_os_error() {
                Some(sys::EAGAIN) => { let _ = vsock::poll(fd, sys::POLLOUT, 1000); }
                Some(sys::EINTR) => {}
                _ => return,
            }
        }
    }
}

/// Runs until the child stream ends, so a fast exit keeps its tail.
fn pump_stdout(master: OwnedFd, mut host: File) {
    let fd = master.as_raw_fd();
    let mut buffer = [0u8; 4096];
    loop {
        if vsock::poll(fd, sys::POLLIN, -1).is_err() { return; }
        loop {
            let count = unsafe { sys::read(fd, buffer.as_mut_ptr() as *mut c_void, buffer.len()) };
            if count > 0 {
                if host.write_all(&buffer[..count as usize]).is_err() { return; }
                continue;
            }
            if count == 0 { return; }
            match io::Error::last_os_error().raw_os_error() {
                Some(sys::EAGAIN) => break,
                Some(sys::EINTR) => continue,
                _ => return,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    #[test]
    fn merge_env_replaces_base_key_in_place() {
        let merged = merge_env(&["PATH=/base", "HOME=/root"], &s(&["PATH=/override"]));
        assert_eq!(merged, s(&["PATH=/override", "HOME=/root"]));
    }

    #[test]
    fn merge_env_appends_unknown_key_and_handles_bare_keys() {
        assert_eq!(merge_env(&["HOME=/root"], &s(&["NEW=1"])), s(&["HOME=/root", "NEW=1"]));
        assert_eq!(merge_env(&["FLAG"], &s(&["FLAG"])), s(&["FLAG"]));
        assert_eq!(merge_env(&["FLAGX=1"], &s(&["FLAG"])), s(&["FLAGX=1", "FLAG"]));
    }

    #[test]
    fn resolve_uses_merged_path_and_fails_cleanly() {
        let env = s(&["PATH=/nonexistent:/bin:/usr/bin"]);
        assert_eq!(resolve_executable("sh", &env).unwrap().to_str().unwrap(), "/bin/sh");
        assert_eq!(resolve_executable("/bin/sh", &env).unwrap().to_str().unwrap(), "/bin/sh");
        let err = resolve_executable("no-such-command-xyz", &env).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
    }

    #[test]
    fn spawn_rejects_empty_argv_and_interior_nul() {
        let Err(err) = spawn("/", &[], &[], false, 0, 0) else { panic!("empty argv must not spawn") };
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        let Err(err) = spawn("/", &s(&["/bin/sh", "bad\0arg"]), &[], false, 0, 0) else { panic!("NUL must not spawn") };
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }

    // One test for everything that forks: the orphan sweep would steal a parallel test's child.
    #[test]
    #[cfg_attr(not(target_os = "linux"), ignore = "forks a child on a Linux PTY; the ioctl numbers in sys.rs are the guest kernel's, not the macOS build host's")]
    fn child_lifecycle_exit_codes_chdir_abort_and_drop_reap() {
        let mut child = spawn("/", &s(&["sh", "-c", "exit 7"]), &[], true, 80, 24).unwrap();
        assert_eq!(child.wait(), 7);
        let mut child = spawn("/", &s(&["true"]), &[], false, 0, 0).unwrap();
        assert_eq!(child.wait(), 0);
        let mut child = spawn("/", &s(&["sh", "-c", "kill -9 $$"]), &[], false, 0, 0).unwrap();
        assert_eq!(child.wait(), 137);
        let mut child = spawn("/does-not-exist", &s(&["true"]), &[], false, 0, 0).unwrap();
        assert_eq!(child.wait(), 127);
        let child = spawn("/", &s(&["sleep", "600"]), &[], false, 0, 0).unwrap();
        let pid = child.pid;
        drop(child);
        let rc = unsafe { sys::waitpid(pid, std::ptr::null_mut(), sys::WNOHANG) };
        assert!(rc < 0, "drop must already have reaped the child, got {rc}");

        let mut child = spawn("/", &s(&["cat"]), &[], false, 0, 0).unwrap();
        assert!(child.terminal_fd().is_none());
        let (mut sender, receiver) = UnixStream::pair().unwrap();
        let input = child.input.take().unwrap();
        set_nonblocking(input.as_raw_fd()).unwrap();
        let input_pump = thread::spawn(move || pump_stdin(File::from(OwnedFd::from(receiver)), input));
        let payload: Vec<u8> = (0..65536).map(|n| (n % 256) as u8).collect();
        let expected = payload.clone();
        let writer = thread::spawn(move || {
            sender.write_all(&payload).unwrap();
            sender.shutdown(std::net::Shutdown::Write).unwrap();
        });
        let mut output = File::from(dup_cloexec(child.output.as_raw_fd()).unwrap());
        let mut received = Vec::new();
        output.read_to_end(&mut received).unwrap();
        assert_eq!(received, expected, "piped bytes must not be echoed or transformed by a terminal");
        assert_eq!(child.wait(), 0, "cat must exit when the input stream reaches EOF");
        writer.join().unwrap();
        input_pump.join().unwrap();

        let mut child = spawn("/", &s(&["sh", "-c", "printf OUT; printf ERR >&2"]), &[], false, 0, 0).unwrap();
        drop(child.input.take());
        let mut output = File::from(dup_cloexec(child.output.as_raw_fd()).unwrap());
        let mut error = File::from(dup_cloexec(child.error.as_ref().unwrap().as_raw_fd()).unwrap());
        let mut stdout = String::new();
        let mut stderr = String::new();
        output.read_to_string(&mut stdout).unwrap();
        error.read_to_string(&mut stderr).unwrap();
        assert_eq!(stdout, "OUT");
        assert_eq!(stderr, "ERR");
        assert_eq!(child.wait(), 0);
    }
}
