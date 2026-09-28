//! PID 1 boot: mount the disks, stack the overlay, switch root.

use crate::contract;
use crate::sys;
use std::ffi::{c_ulong, CString};
use std::fs;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const HARDENED: c_ulong = sys::MS_NOSUID | sys::MS_NODEV | sys::MS_NOEXEC;

pub fn boot() -> Result<(), String> {
    mount("proc", "/proc", Some("proc"), HARDENED, None)
        .map_err(|e| format!("mount /proc: {e}"))?;
    if cmdline_has(contract::CMDLINE_OVERLAY) { boot_overlay() } else { boot_fat() }
}

/// Sandbox boot: base + personal + a tmpfs upper.
fn boot_overlay() -> Result<(), String> {
    let _ = mount("none", "/", None, sys::MS_REC | sys::MS_PRIVATE, None);
    mount("sys", "/sys", Some("sysfs"), HARDENED, None).map_err(|e| format!("mount /sys: {e}"))?;
    mount("dev", "/dev", Some("devtmpfs"), sys::MS_NOSUID, None).map_err(|e| format!("mount /dev: {e}"))?;

    let (lower_layers, personal) = mount_lower_layers()?;
    mount("tmpfs", "/over", Some("tmpfs"), 0, None).map_err(|e| format!("mount upper tmpfs: {e}"))?;
    fs::create_dir_all("/over/upper").map_err(|e| format!("create upper: {e}"))?;
    fs::create_dir_all("/over/work").map_err(|e| format!("create work: {e}"))?;
    let options = format!("lowerdir={lower_layers},upperdir=/over/upper,workdir=/over/work,metacopy=off");
    mount("overlay", "/merged", Some("overlay"), sys::MS_NOSUID | sys::MS_NODEV, Some(&options))
        .map_err(|e| format!("overlay mount: {e}"))?;

    let session_view = bind("/over", "/merged/.sk").is_ok();
    let personal_view = matches!(personal, Personal::Stacked)
        && session_view
        && bind("/personal", "/merged/.sk/personal").is_ok();

    let tools = read_tree(Path::new(contract::GUEST_TOOLS_STAGE));
    switch_root("/merged").map_err(|e| format!("switch_root: {e}"))?;

    mount("proc", "/proc", Some("proc"), HARDENED, None).map_err(|e| format!("mount /proc: {e}"))?;
    mount("sys", "/sys", Some("sysfs"), HARDENED, None).map_err(|e| format!("mount /sys: {e}"))?;
    mount("dev", "/dev", Some("devtmpfs"), sys::MS_NOSUID, None).map_err(|e| format!("mount /dev: {e}"))?;
    mount_pseudo_filesystems().map_err(|e| format!("devpts mount: {e}"))?;
    write_tree(Path::new(contract::GUEST_TOOLS), &tools);
    expose_ctl_client();
    mount("workspace", "/workspace", Some("virtiofs"), 0, None)
        .map_err(|e| format!("workspace virtiofs mount: {e}"))?;
    mount_project_shares();
    mount_staging();

    if matches!(personal, Personal::Degraded) || (matches!(personal, Personal::Stacked) && !personal_view) {
        if fs::write(contract::DEGRADED_MARKER, "personal layer unavailable this boot; save is disabled\n").is_err() {
            eprintln!("sk-agent: could not write {}", contract::DEGRADED_MARKER);
        }
    }
    configure_identity();
    Ok(())
}

/// Image-builder boot: the disk is already the root.
fn boot_fat() -> Result<(), String> {
    let _ = mount("sys", "/sys", Some("sysfs"), HARDENED, None);
    let _ = mount("dev", "/dev", Some("devtmpfs"), sys::MS_NOSUID, None);
    mount_pseudo_filesystems().map_err(|e| format!("devpts mount: {e}"))?;
    let _ = mount("workspace", "/workspace", Some("virtiofs"), 0, None);
    configure_identity();
    Ok(())
}

/// Degraded disables save.
enum Personal { Absent, Stacked, Degraded }

/// Returns the overlay lowerdir, top layer first.
fn mount_lower_layers() -> Result<(String, Personal), String> {
    let base = find_device_by_label(contract::LABEL_BASE)
        .ok_or("no disk labeled sk-base (the read-only base ext4)")?;
    mount(&base, "/base", Some("ext4"), sys::MS_RDONLY, None)
        .map_err(|e| format!("mount base ext4: {e}"))?;
    let Some(personal) = find_device_by_label(contract::LABEL_PERSONAL) else {
        return Ok(("/base".to_string(), Personal::Absent));
    };
    match mount(&personal, "/personal", Some("ext4"), sys::MS_RDONLY, Some("noload")) {
        Ok(()) if Path::new("/personal/upper").exists() =>
            Ok(("/personal/upper:/base".to_string(), Personal::Stacked)),
        Ok(()) => {
            eprintln!("sk-agent: personal image has no /upper; booting base-only");
            Ok(("/base".to_string(), Personal::Degraded))
        }
        Err(error) => {
            eprintln!("sk-agent: personal layer failed to mount ({error}); booting base-only");
            Ok(("/base".to_string(), Personal::Degraded))
        }
    }
}

fn mount_staging() {
    let Some(device) = find_device_by_label(contract::LABEL_STAGING) else { return };
    match mount(&device, contract::STAGING_MOUNT, Some("ext4"), HARDENED, None) {
        Ok(()) => { let _ = fs::write("/run/sk-staging-device", format!("{device}\n")); }
        Err(error) => eprintln!("sk-agent: staging disk failed to mount ({error}); save is unavailable"),
    }
}

fn mount_project_shares() {
    let flags = sys::MS_NOSUID | sys::MS_NODEV;
    if let Err(error) = mount(contract::TAG_PROJECT, contract::PROJECT_MOUNT, Some("virtiofs"), flags, None) {
        eprintln!("sk-agent: project share failed to mount ({error}); agent config will not persist");
    }
    if let Err(error) = mount(contract::TAG_SEED, contract::SEED_MOUNT, Some("virtiofs"), flags | sys::MS_RDONLY, None) {
        eprintln!("sk-agent: seed share failed to mount ({error}); host customizations are unavailable");
    }
    // Before the adoption watcher starts, so a stale live token is never offered or left on disk.
    let _ = fs::remove_file(contract::CREDENTIAL_FILE);
}

fn mount_pseudo_filesystems() -> io::Result<()> {
    mount("devpts", "/dev/pts", Some("devpts"), sys::MS_NOSUID | sys::MS_NOEXEC,
          Some("newinstance,ptmxmode=0666"))?;
    let _ = fs::remove_file("/dev/ptmx");
    let _ = std::os::unix::fs::symlink("/dev/pts/ptmx", "/dev/ptmx");
    let scratch = sys::MS_NOSUID | sys::MS_NODEV;
    let _ = mount("shm", "/dev/shm", Some("tmpfs"), scratch, None);
    let _ = mount("tmpfs", "/tmp", Some("tmpfs"), scratch, None);
    let _ = mount("tmpfs", "/run", Some("tmpfs"), scratch, None);
    Ok(())
}

enum Entry { Dir, File(Vec<u8>, u32), Link(PathBuf) }

/// switch_root hides the initramfs, so the guest scripts cross it in memory.
fn read_tree(root: &Path) -> Vec<(PathBuf, Entry)> {
    use std::os::unix::fs::PermissionsExt;
    let mut entries = Vec::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(dir) = pending.pop() {
        let Ok(listing) = fs::read_dir(root.join(&dir)) else { continue };
        for item in listing.flatten() {
            let rel = dir.join(item.file_name());
            let Ok(meta) = fs::symlink_metadata(item.path()) else { continue };
            if meta.file_type().is_symlink() {
                if let Ok(target) = fs::read_link(item.path()) { entries.push((rel, Entry::Link(target))); }
            } else if meta.is_dir() {
                entries.push((rel.clone(), Entry::Dir));
                pending.push(rel);
            } else if let Ok(bytes) = fs::read(item.path()) {
                entries.push((rel, Entry::File(bytes, meta.permissions().mode() & 0o755)));
            }
        }
    }
    entries
}

/// Parents come before their contents, as read_tree lists them.
fn write_tree(root: &Path, entries: &[(PathBuf, Entry)]) {
    use std::os::unix::fs::PermissionsExt;
    if entries.is_empty() {
        eprintln!("sk-agent: no guest scripts in the initramfs; save/sk-drop/sk-net/clipboard are unavailable");
    }
    let _ = fs::create_dir_all(root.join("libexec"));
    for (rel, entry) in entries {
        let path = root.join(rel);
        let written = match entry {
            Entry::Dir => fs::create_dir_all(&path),
            Entry::File(bytes, mode) => fs::write(&path, bytes)
                .and_then(|_| fs::set_permissions(&path, fs::Permissions::from_mode(*mode))),
            Entry::Link(target) => std::os::unix::fs::symlink(target, &path),
        };
        if let Err(error) = written {
            eprintln!("sk-agent: could not place {} ({error})", path.display());
        }
    }
}

/// The guest scripts call this copy as the ctl client.
fn expose_ctl_client() {
    match fs::copy("/proc/self/exe", contract::CTL_CLIENT) {
        Ok(_) => {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(contract::CTL_CLIENT, fs::Permissions::from_mode(0o755));
        }
        Err(error) => eprintln!("sk-agent: could not expose the ctl client ({error}); save/clip/drop/net are unavailable"),
    }
}

fn configure_identity() {
    if !crate::net::configure(cmdline_has(contract::CMDLINE_NETWAIT)) {
        eprintln!("sk-agent: built-in networking unavailable");
    }
    if file_blank("/etc/resolv.conf") {
        let _ = fs::write("/etc/resolv.conf", "nameserver 1.1.1.1\n");
    }
    if file_blank("/etc/hosts") {
        let _ = fs::write("/etc/hosts", "127.0.0.1 localhost\n127.0.1.1 sidekernel\n");
    }
    let name = c"sidekernel";
    unsafe { sys::sethostname(name.as_ptr(), name.to_bytes().len()) };
    let _ = fs::write("/etc/hostname", "sidekernel\n");
}

/// So whoever waits on a child gets its real status.
pub fn block_sigchld() {
    let mut set = sys::SigSet([0; 16]);
    unsafe {
        sys::sigemptyset(&mut set);
        sys::sigaddset(&mut set, sys::SIGCHLD);
        sys::sigprocmask(sys::SIG_BLOCK, &set, std::ptr::null_mut());
    }
}

/// Also creates the mountpoint.
fn mount(source: &str, target: &str, fstype: Option<&str>, flags: c_ulong, data: Option<&str>) -> io::Result<()> {
    let _ = fs::create_dir_all(target);
    let source = CString::new(source).expect("literal source");
    let target = CString::new(target).expect("literal target");
    let fstype = fstype.map(|f| CString::new(f).expect("literal fstype"));
    let data = data.map(|d| CString::new(d).expect("literal data"));
    let code = unsafe {
        sys::mount(
            source.as_ptr(),
            target.as_ptr(),
            fstype.as_ref().map_or(std::ptr::null(), |f| f.as_ptr()),
            flags,
            data.as_ref().map_or(std::ptr::null(), |d| d.as_ptr().cast()),
        )
    };
    sys::check(code).map(|_| ())
}

fn bind(source: &str, target: &str) -> io::Result<()> {
    mount(source, target, None, sys::MS_BIND, None)
}

fn switch_root(new_root: &str) -> io::Result<()> {
    std::env::set_current_dir(new_root)?;
    mount(".", "/", None, sys::MS_MOVE, None)?;
    sys::check(unsafe { sys::chroot(c".".as_ptr()) })?;
    std::env::set_current_dir("/")
}

fn cmdline_has(token: &str) -> bool {
    fs::read_to_string("/proc/cmdline").is_ok_and(|c| cmdline_contains(&c, token))
}

fn cmdline_contains(cmdline: &str, token: &str) -> bool {
    cmdline.split_whitespace().any(|t| t == token)
}

fn file_blank(path: &str) -> bool {
    fs::read_to_string(path).map_or(true, |s| s.trim().is_empty())
}

fn find_device_by_label(label: &str) -> Option<String> {
    for letter in b'a'..=b'h' {
        let device = format!("/dev/vd{}", letter as char);
        if Path::new(&device).exists() && read_ext4_label(&device).as_deref() == Some(label) {
            return Some(device);
        }
    }
    None
}

fn read_ext4_label(device: &str) -> Option<String> {
    ext4_label(&mut File::open(device).ok()?)
}

fn ext4_label<R: Read + Seek>(reader: &mut R) -> Option<String> {
    let mut magic = [0u8; 2];
    reader.seek(SeekFrom::Start(contract::EXT4_MAGIC_OFFSET)).ok()?;
    reader.read_exact(&mut magic).ok()?;
    if magic != [0x53, 0xEF] { return None; }
    let mut label = [0u8; 16];
    reader.seek(SeekFrom::Start(contract::EXT4_LABEL_OFFSET)).ok()?;
    reader.read_exact(&mut label).ok()?;
    let end = label.iter().position(|&b| b == 0).unwrap_or(label.len());
    Some(std::str::from_utf8(&label[..end]).ok()?.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn superblock(label: &[u8]) -> Vec<u8> {
        let mut image = vec![0u8; 0x488];
        image[0x438] = 0x53;
        image[0x439] = 0xEF;
        image[0x478..0x478 + label.len()].copy_from_slice(label);
        image
    }

    #[test]
    fn ext4_label_reads_nul_terminated_label() {
        let mut cursor = Cursor::new(superblock(b"sk-personal\0pad"));
        assert_eq!(ext4_label(&mut cursor).as_deref(), Some("sk-personal"));
    }

    #[test]
    fn ext4_label_rejects_bad_magic() {
        let mut image = superblock(b"sk-base");
        image[0x438] = 0;
        assert_eq!(ext4_label(&mut Cursor::new(image)), None);
    }

    #[test]
    fn ext4_label_handles_full_16_byte_label() {
        let mut cursor = Cursor::new(superblock(b"exactly16bytes!!"));
        assert_eq!(ext4_label(&mut cursor).as_deref(), Some("exactly16bytes!!"));
    }

    #[test]
    fn ext4_label_none_on_short_device() {
        assert_eq!(ext4_label(&mut Cursor::new(vec![0u8; 64])), None);
    }

    #[test]
    fn cmdline_tokens_match_whole_words_only() {
        let cmdline = "console=hvc0 sk_boot=overlay quiet\n";
        assert!(cmdline_contains(cmdline, "sk_boot=overlay"));
        assert!(!cmdline_contains(cmdline, "sk_boot"));
        assert!(!cmdline_contains(cmdline, "sk_netwait"));
        assert!(cmdline_contains("sk_netwait", "sk_netwait"));
    }
}
