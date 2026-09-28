//! `sk-agent ctl save|clip|copy|drop|net`, the client behind the guest scripts.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::process::{Command, ExitCode, Stdio};

use crate::contract::{CtlStatus, CtlVerb, Frame, DROPS_DIR, MAX_COPY_PAYLOAD, MAX_CTL_PAYLOAD, MAX_CTL_REPLY_FRAME, SERVICE_PORT};
use crate::serve::{read_frame, write_frame};
use crate::vsock;

/// Exits 0 ok, 1 denied, 2 error.
pub fn run() -> ExitCode {
    let Ok(args) = std::env::args_os().skip(1)
        .map(std::ffi::OsString::into_string)
        .collect::<Result<Vec<String>, _>>()
    else { return fail(2, "arguments must be valid UTF-8") };
    let mut request = match parse(&args) {
        Ok(request) => request,
        Err(message) => return fail(2, &message),
    };
    if request.verb == CtlVerb::Copy {
        request.payload = match read_copy_text(std::io::stdin().lock()) {
            Ok(text) => text,
            Err(message) => return fail(2, &message),
        };
    }
    match exchange(&request) {
        Ok((Frame::CtlReply { status: CtlStatus::Ok, message, payload }, mut host)) => {
            deliver(&request, &message, &payload, &mut host)
        }
        Ok((Frame::CtlReply { status: CtlStatus::Deny, message, .. }, _)) => {
            fail(1, if message.is_empty() { "denied on the host" } else { &message })
        }
        Ok((Frame::CtlReply { message, .. }, _)) => fail(2, &message),
        Ok(_) => fail(2, "host sent an unexpected frame"),
        Err(message) => fail(2, &message),
    }
}

/// `landing` is fixed here, so no reply can steer where a drop writes.
struct Request { verb: CtlVerb, payload: Vec<u8>, landing: String }

fn parse(args: &[String]) -> Result<Request, String> {
    const USAGE: &str = "usage: sk-agent ctl save 0|1 | clip | copy | drop /host/path | net on|off";
    if args.first().map(String::as_str) != Some("ctl") || args.len() > 3 {
        return Err(USAGE.into());
    }
    let argument = args.get(2).map(String::as_str);
    let (verb, payload, landing) = match (args.get(1).map(String::as_str).unwrap_or_default(), argument) {
        ("save", Some(flag @ ("0" | "1"))) => (CtlVerb::Save, vec![flag.as_bytes()[0] - b'0'], String::new()),
        ("clip", None) => (CtlVerb::Clip, Vec::new(), String::new()),
        ("copy", None) => (CtlVerb::Copy, Vec::new(), String::new()),
        ("net", Some(posture @ ("on" | "off"))) => (CtlVerb::Net, posture.as_bytes().to_vec(), String::new()),
        ("drop", Some(path)) => {
            if !path.starts_with('/') {
                return Err("drop needs an absolute macOS host path".into());
            }
            if path.len() > MAX_CTL_PAYLOAD as usize {
                return Err("drop path exceeds the 4 KiB payload cap".into());
            }
            (CtlVerb::Drop, path.as_bytes().to_vec(), format!("{DROPS_DIR}/{}", basename(path)?))
        }
        _ => return Err(USAGE.into()),
    };
    Ok(Request { verb, payload, landing })
}

fn basename(path: &str) -> Result<&str, String> {
    match path.trim_end_matches('/').rsplit('/').next().unwrap_or_default() {
        "" | "." | ".." => Err("drop path has no name".into()),
        name => Ok(name),
    }
}

fn exchange(request: &Request) -> Result<(Frame, File), String> {
    let fd = vsock::connect_to_host(SERVICE_PORT).map_err(|e| format!("cannot reach the host: {e}"))?;
    let mut host = File::from(fd);
    let frame = Frame::Ctl { verb: request.verb, payload: request.payload.clone() };
    write_frame(&mut host, &frame).map_err(|e| format!("send failed: {e}"))?;
    let reply = read_frame(&mut host, MAX_CTL_REPLY_FRAME).map_err(|e| format!("no reply: {e}"))?;
    Ok((reply, host))
}

fn deliver(request: &Request, message: &str, payload: &[u8], host: &mut File) -> ExitCode {
    match request.verb {
        CtlVerb::Drop => {
            // A drop replaces any earlier one of its name, and a failed one leaves nothing behind.
            clear(&request.landing);
            let landed = fs::create_dir_all(DROPS_DIR).and_then(|()| match message {
                "dir" => untar(host, &request.landing),
                _ => File::create(&request.landing).and_then(|mut file| receive(host, &mut file)),
            });
            match landed {
                Ok(()) => println!("{}", request.landing),
                Err(e) => {
                    clear(&request.landing);
                    return fail(2, &format!("could not write {}: {e}", request.landing));
                }
            }
        }
        CtlVerb::Clip => {
            if std::io::stdout().write_all(payload).is_err() {
                return fail(2, "could not write the image to stdout");
            }
        }
        CtlVerb::Save | CtlVerb::Net | CtlVerb::Copy => {
            if !message.is_empty() { println!("{message}"); }
        }
    }
    ExitCode::SUCCESS
}

fn untar(host: &mut impl Read, into: &str) -> std::io::Result<()> {
    fs::create_dir_all(into)?;
    let mut tar = Command::new("tar")
        .args(["-xf", "-", "-C", into])
        .stdin(Stdio::piped())
        .spawn()?;
    let mut stdin = tar.stdin.take().ok_or_else(|| std::io::Error::other("tar has no stdin"))?;
    let fed = receive(host, &mut stdin);
    drop(stdin); // EOF, so tar can finish
    let extracted = tar.wait()?.success();
    fed?;
    match extracted {
        true => Ok(()),
        false => Err(std::io::Error::other("tar could not extract the folder")),
    }
}

/// An empty chunk ends the stream.
fn receive(host: &mut impl Read, sink: &mut impl Write) -> std::io::Result<()> {
    loop {
        let chunk = read_frame(host, MAX_CTL_REPLY_FRAME)
            .map_err(|e| std::io::Error::other(format!("cut off: {e}")))?;
        match chunk {
            Frame::CtlReply { status: CtlStatus::Ok, payload, .. } if payload.is_empty() => return Ok(()),
            Frame::CtlReply { status: CtlStatus::Ok, payload, .. } => sink.write_all(&payload)?,
            Frame::CtlReply { message, .. } => return Err(std::io::Error::other(message)),
            _ => return Err(std::io::Error::other("host sent an unexpected frame")),
        }
    }
}

fn clear(landing: &str) {
    let _ = fs::remove_dir_all(landing).or_else(|_| fs::remove_file(landing));
}

/// Reads one byte past the cap to catch oversize input.
fn read_copy_text(source: impl Read) -> Result<Vec<u8>, String> {
    let mut text = Vec::new();
    match source.take(u64::from(MAX_COPY_PAYLOAD) + 1).read_to_end(&mut text) {
        Ok(_) if text.len() > MAX_COPY_PAYLOAD as usize => {
            Err("copy text exceeds the 256 KiB cap".into())
        }
        Ok(_) => match std::str::from_utf8(&text) {
            Ok(_) => Ok(text),
            Err(_) => Err("copy text must be valid UTF-8".into()),
        },
        Err(e) => Err(format!("could not read stdin: {e}")),
    }
}

fn fail(code: u8, message: &str) -> ExitCode {
    eprintln!("sk-agent: {message}");
    ExitCode::from(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(args: &[&str]) -> Result<Request, String> {
        parse(&args.iter().map(|a| a.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn every_verb_parses_to_its_contract_payload() {
        assert_eq!(parsed(&["ctl", "save", "1"]).unwrap().payload, vec![1]);
        assert_eq!(parsed(&["ctl", "save", "0"]).unwrap().payload, vec![0]);
        assert_eq!(parsed(&["ctl", "clip"]).unwrap().payload, Vec::<u8>::new());
        assert_eq!(parsed(&["ctl", "copy"]).unwrap().payload, Vec::<u8>::new());
        assert_eq!(parsed(&["ctl", "net", "off"]).unwrap().payload, b"off".to_vec());
        assert_eq!(parsed(&["ctl", "drop", "/Users/me/notes.txt"]).unwrap().payload,
                   b"/Users/me/notes.txt".to_vec());
    }

    #[test]
    fn loose_arguments_are_refused() {
        for bad in [
            vec!["ctl"], vec!["ctl", "save"], vec!["ctl", "save", "yes"],
            vec!["ctl", "clip", "extra"], vec!["ctl", "copy", "extra"],
            vec!["ctl", "net", "ON"], vec!["ctl", "net", "0"],
            vec!["ctl", "reboot"], vec!["serve"], vec!["ctl", "net", "on", "extra"],
        ] {
            assert!(parsed(&bad).is_err(), "{bad:?} must not parse");
        }
    }

    #[test]
    fn copy_text_is_read_whole_and_bounded() {
        assert_eq!(read_copy_text(&b"echo hi\n"[..]).unwrap(), b"echo hi\n");
        assert_eq!(read_copy_text(&b""[..]).unwrap(), Vec::<u8>::new());
        let at_cap = vec![b'a'; MAX_COPY_PAYLOAD as usize];
        assert_eq!(read_copy_text(&at_cap[..]).unwrap().len(), at_cap.len());
        let over = vec![b'a'; MAX_COPY_PAYLOAD as usize + 1];
        assert!(read_copy_text(&over[..]).is_err(), "one byte past the cap must refuse");
        assert!(read_copy_text(&[0xff, 0xfe][..]).is_err(), "non-UTF-8 must refuse");
    }

    #[test]
    fn drop_paths_are_bounded_and_must_name_something() {
        assert!(parsed(&["ctl", "drop", "relative/path"]).is_err());
        let long = format!("/{}", "a".repeat(MAX_CTL_PAYLOAD as usize));
        assert!(parsed(&["ctl", "drop", &long]).is_err());
        for no_name in ["/", "///", "/Users/me/..", "/."] {
            assert!(parsed(&["ctl", "drop", no_name]).is_err(), "{no_name} must not parse");
        }
    }

    #[test]
    fn basename_is_the_final_component_and_never_traverses() {
        assert_eq!(basename("/a/b/c.txt").unwrap(), "c.txt");
        assert_eq!(basename("/weird name.png").unwrap(), "weird name.png");
        assert!(basename("/a/..").is_err());
        assert_eq!(basename("/Users/me/project/").unwrap(), "project");
        assert_eq!(basename("/Users/me/project//").unwrap(), "project");
        assert!(basename("/").is_err());
    }

    #[test]
    fn a_dropped_folder_lands_where_parse_said_and_nowhere_else() {
        let request = parsed(&["ctl", "drop", "/Users/me/project/"]).unwrap();
        assert_eq!(request.landing, format!("{DROPS_DIR}/project"));
    }

    fn wire(chunks: &[Frame]) -> Vec<u8> {
        chunks.iter().flat_map(Frame::encode).collect()
    }

    #[test]
    fn a_drop_is_whole_only_once_its_empty_chunk_arrives() {
        let ok = |bytes: &[u8]| Frame::CtlReply { status: CtlStatus::Ok, message: String::new(), payload: bytes.to_vec() };
        let failed = Frame::CtlReply { status: CtlStatus::Err, message: "copy failed".into(), payload: Vec::new() };

        let mut landed = Vec::new();
        receive(&mut &wire(&[ok(b"hello "), ok(b"world"), ok(b"")])[..], &mut landed).unwrap();
        assert_eq!(landed, b"hello world");
        let cut_off = wire(&[ok(b"hello "), ok(b"world")]);
        assert!(receive(&mut &cut_off[..], &mut std::io::sink()).is_err(), "no end chunk means cut off");
        let broken = wire(&[ok(b"hello "), failed]);
        assert_eq!(receive(&mut &broken[..], &mut std::io::sink()).unwrap_err().to_string(), "copy failed");
    }
}
