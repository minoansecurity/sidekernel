//! The wire contract; mirrors Host/Contract.swift.

pub const CONTROL_PORT: u32 = 4243;
pub const SERVICE_PORT: u32 = 4244;
pub const RELAY_PORT: u16 = 4242;
pub const VMADDR_CID_HOST: u32 = 2;

// Checked against the declared length before anything is copied.
pub const MAX_CONTROL_FRAME: u32 = 1_048_576;
pub const MAX_CTL_REPLY_FRAME: u32 = 67_112_960;
pub const MAX_ADOPT_BLOB: u32 = 65_536;
pub const MAX_CTL_PAYLOAD: u32 = 4_096;
pub const MAX_COPY_PAYLOAD: u32 = 262_144;
pub const MAX_CTL_REPLY_PAYLOAD: u32 = 67_108_864;
pub const NONCE_LENGTH: usize = 32;

pub const CMDLINE_OVERLAY: &str = "sk_boot=overlay";
pub const CMDLINE_NETWAIT: &str = "sk_netwait";
pub const LABEL_BASE: &str = "sk-base";
pub const LABEL_PERSONAL: &str = "sk-personal";
pub const LABEL_STAGING: &str = "sk-staging";
pub const EXT4_MAGIC_OFFSET: u64 = 0x438;
pub const EXT4_LABEL_OFFSET: u64 = 0x478;
pub const STAGING_MOUNT: &str = "/staging";
pub const DEGRADED_MARKER: &str = "/run/sk-degraded";
// Delivered at boot from the initramfs, so script edits never rebuild the base image.
pub const GUEST_TOOLS_STAGE: &str = "/sidekernel";
pub const GUEST_TOOLS: &str = "/run/sidekernel";
pub const CTL_CLIENT: &str = "/run/sidekernel/libexec/sk-agent";
pub const DROPS_DIR: &str = "/root/.sk-drops";
// Host-owned shares: per-project state (rw) and this boot's seed (ro).
pub const TAG_PROJECT: &str = "project";
pub const TAG_SEED: &str = "seed";
pub const PROJECT_MOUNT: &str = "/run/sk-project";
pub const SEED_MOUNT: &str = "/run/sk-seed";
pub const CREDENTIAL_FILE: &str = "/run/sk-project/claude/.credentials.json";

/// The stand-in written over an adopted login; byte-identical to the host's `placeholderBlob`.
pub const PLACEHOLDER_BLOB: &str = r#"{"claudeAiOauth":{"accessToken":"sk-sidekernel-proxy-placeholder","refreshToken":"sk-sidekernel-proxy-placeholder","expiresAt":4102444800000,"scopes":["user:inference","user:profile"]}}"#;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StdioStream { Stdin = 0, Stdout = 1 }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtlVerb { Save = 1, Clip = 2, Drop = 3, Net = 4, Copy = 5 }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtlStatus { Ok = 0, Deny = 1, Err = 2 }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    HelloExec { network_on: bool },
    HelloTunnel { port: u16 },
    HelloNetChanged { on: bool },
    Exec { nonce: String, workdir: String, argv: Vec<String>, env: Vec<String>, cols: u16, rows: u16 },
    Resize { cols: u16, rows: u16 },
    Started,
    Error { reason: String },
    Exited { code: i32 },
    HelloStdio { which: StdioStream, nonce: String },
    HelloPortEvents,
    HelloProxy,
    Adopt { blob: Vec<u8> },
    Ctl { verb: CtlVerb, payload: Vec<u8> },
    PortEvent { port: u16, open: bool },
    /// A ctl verb's answer. An allowed drop streams instead: an Ok `dir`/`file` header, its bytes as
    /// Ok payload chunks, then an empty chunk, or an Err reply if the copy fails partway.
    CtlReply { status: CtlStatus, message: String, payload: Vec<u8> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeError(pub &'static str);

impl Frame {
    /// None if a string or list outgrows its u16 length.
    pub fn try_encode(&self) -> Option<Vec<u8>> {
        let mut e = Enc(Vec::new(), false);
        match self {
            Frame::HelloExec { network_on } => { e.tag(0x01); e.flag(*network_on); }
            Frame::HelloTunnel { port } => { e.tag(0x02); e.u16(*port); }
            Frame::HelloNetChanged { on } => { e.tag(0x03); e.flag(*on); }
            Frame::Exec { nonce, workdir, argv, env, cols, rows } => {
                e.tag(0x05); e.str(nonce); e.str(workdir);
                e.list(argv); e.list(env); e.u16(*cols); e.u16(*rows);
            }
            Frame::Resize { cols, rows } => { e.tag(0x06); e.u16(*cols); e.u16(*rows); }
            Frame::Started => e.tag(0x07),
            Frame::Error { reason } => { e.tag(0x08); e.str(reason); }
            Frame::Exited { code } => { e.tag(0x09); e.0.extend(code.to_be_bytes()); }
            Frame::HelloStdio { which, nonce } => { e.tag(0x11); e.u8(*which as u8); e.str(nonce); }
            Frame::HelloPortEvents => e.tag(0x12),
            Frame::HelloProxy => e.tag(0x13),
            Frame::Adopt { blob } => { e.tag(0x14); e.bytes(blob); }
            Frame::Ctl { verb, payload } => { e.tag(0x15); e.u8(*verb as u8); e.bytes(payload); }
            Frame::PortEvent { port, open } => { e.tag(0x16); e.u16(*port); e.flag(*open); }
            Frame::CtlReply { status, message, payload } => {
                e.tag(0x17); e.u8(*status as u8); e.str(message); e.bytes(payload);
            }
        }
        if e.1 { return None; }
        let mut out = (e.0.len() as u32).to_be_bytes().to_vec();
        out.extend(e.0);
        Some(out)
    }

    #[cfg(test)]
    pub fn encode(&self) -> Vec<u8> {
        self.try_encode().expect("test frames fit their length prefixes")
    }

    #[cfg(test)]
    pub fn decode(bytes: &[u8]) -> Result<Frame, DecodeError> {
        let mut d = Dec::new(bytes);
        let declared = d.u32().map_err(|_| DecodeError("incomplete length prefix"))?;
        if declared == 0 { return Err(DecodeError("frame length must be at least 1")); }
        let payload = d.take(declared as usize)
            .map_err(|_| DecodeError("declared length exceeds available bytes"))?;
        if !d.finished() { return Err(DecodeError("trailing bytes after frame")); }
        let frame = Frame::decode_payload(payload)?;
        let cap = if matches!(frame, Frame::CtlReply { .. }) { MAX_CTL_REPLY_FRAME } else { MAX_CONTROL_FRAME };
        if declared > cap { return Err(DecodeError("frame exceeds cap")); }
        Ok(frame)
    }

    /// The transport has already read the length prefix.
    pub fn decode_payload(payload: &[u8]) -> Result<Frame, DecodeError> {
        let mut d = Dec::new(payload);
        let frame = match d.u8()? {
            0x01 => Frame::HelloExec { network_on: d.flag()? },
            0x02 => Frame::HelloTunnel { port: d.u16()? },
            0x03 => Frame::HelloNetChanged { on: d.flag()? },
            0x05 => Frame::Exec {
                nonce: d.nonce()?, workdir: d.str()?,
                argv: d.list_min_one()?, env: d.list()?,
                cols: d.u16()?, rows: d.u16()?,
            },
            0x06 => Frame::Resize { cols: d.u16()?, rows: d.u16()? },
            0x07 => Frame::Started,
            0x08 => Frame::Error { reason: d.str()? },
            0x09 => Frame::Exited { code: d.i32()? },
            0x11 => Frame::HelloStdio {
                which: match d.u8()? {
                    0 => StdioStream::Stdin,
                    1 => StdioStream::Stdout,
                    _ => return Err(DecodeError("which must be 0 or 1")),
                },
                nonce: d.nonce()?,
            },
            0x12 => Frame::HelloPortEvents,
            0x13 => Frame::HelloProxy,
            0x14 => Frame::Adopt { blob: d.bytes(MAX_ADOPT_BLOB)? },
            0x15 => {
                let verb = match d.u8()? {
                    1 => CtlVerb::Save,
                    2 => CtlVerb::Clip,
                    3 => CtlVerb::Drop,
                    4 => CtlVerb::Net,
                    5 => CtlVerb::Copy,
                    _ => return Err(DecodeError("unknown ctl verb")),
                };
                let cap = if verb == CtlVerb::Copy { MAX_COPY_PAYLOAD } else { MAX_CTL_PAYLOAD };
                Frame::Ctl { verb, payload: d.bytes(cap)? }
            }
            0x16 => Frame::PortEvent { port: d.u16()?, open: d.flag()? },
            0x17 => Frame::CtlReply {
                status: match d.u8()? {
                    0 => CtlStatus::Ok,
                    1 => CtlStatus::Deny,
                    2 => CtlStatus::Err,
                    _ => return Err(DecodeError("unknown ctl reply status")),
                },
                message: d.str()?,
                payload: d.bytes(MAX_CTL_REPLY_PAYLOAD)?,
            },
            _ => return Err(DecodeError("unknown tag")),
        };
        if !d.finished() { return Err(DecodeError("body not fully consumed")); }
        Ok(frame)
    }

    #[cfg(test)]
    pub fn name(&self) -> &'static str {
        match self {
            Frame::HelloExec { .. } => "HelloExec",
            Frame::HelloTunnel { .. } => "HelloTunnel",
            Frame::HelloNetChanged { .. } => "HelloNetChanged",
            Frame::Exec { .. } => "Exec",
            Frame::Resize { .. } => "Resize",
            Frame::Started => "Started",
            Frame::Error { .. } => "Error",
            Frame::Exited { .. } => "Exited",
            Frame::HelloStdio { .. } => "HelloStdio",
            Frame::HelloPortEvents => "HelloPortEvents",
            Frame::HelloProxy => "HelloProxy",
            Frame::Adopt { .. } => "Adopt",
            Frame::Ctl { .. } => "Ctl",
            Frame::PortEvent { .. } => "PortEvent",
            Frame::CtlReply { .. } => "CtlReply",
        }
    }
}

/// The bool flags a length too long for its u16 prefix.
struct Enc(Vec<u8>, bool);

impl Enc {
    fn tag(&mut self, t: u8) { self.0.push(t); }
    fn u8(&mut self, v: u8) { self.0.push(v); }
    fn u16(&mut self, v: u16) { self.0.extend(v.to_be_bytes()); }
    fn flag(&mut self, v: bool) { self.0.push(v as u8); }

    fn count(&mut self, n: usize) {
        match u16::try_from(n) {
            Ok(n) => self.u16(n),
            Err(_) => self.1 = true,
        }
    }

    fn str(&mut self, s: &str) {
        self.count(s.len());
        self.0.extend(s.as_bytes());
    }

    fn bytes(&mut self, b: &[u8]) {
        self.0.extend((b.len() as u32).to_be_bytes());
        self.0.extend(b);
    }

    fn list(&mut self, items: &[String]) {
        self.count(items.len());
        for item in items { self.str(item); }
    }
}

/// A bounds-checked cursor.
pub struct Dec<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Dec<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Dec { bytes, pos: 0 }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.pos.checked_add(n).ok_or(DecodeError("length overflow"))?;
        if end > self.bytes.len() { return Err(DecodeError("truncated")); }
        let slice = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn finished(&self) -> bool { self.pos == self.bytes.len() }

    fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, DecodeError> {
        let b = self.take(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }

    fn u32(&mut self) -> Result<u32, DecodeError> {
        let b = self.take(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn i32(&mut self) -> Result<i32, DecodeError> {
        let b = self.take(4)?;
        Ok(i32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn flag(&mut self) -> Result<bool, DecodeError> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(DecodeError("bool must be 0 or 1")),
        }
    }

    fn str(&mut self) -> Result<String, DecodeError> {
        let len = self.u16()? as usize;
        let raw = self.take(len)?;
        String::from_utf8(raw.to_vec()).map_err(|_| DecodeError("str must be valid UTF-8"))
    }

    fn nonce(&mut self) -> Result<String, DecodeError> {
        let s = self.str()?;
        if s.len() != NONCE_LENGTH { return Err(DecodeError("nonce must be exactly 32 bytes")); }
        Ok(s)
    }

    fn bytes(&mut self, cap: u32) -> Result<Vec<u8>, DecodeError> {
        let len = self.u32()?;
        if len > cap { return Err(DecodeError("field exceeds cap")); }
        Ok(self.take(len as usize)?.to_vec())
    }

    fn list(&mut self) -> Result<Vec<String>, DecodeError> {
        let count = self.u16()?;
        let mut items = Vec::new();
        for _ in 0..count { items.push(self.str()?); }
        Ok(items)
    }

    fn list_min_one(&mut self) -> Result<Vec<String>, DecodeError> {
        let items = self.list()?;
        if items.is_empty() { return Err(DecodeError("argv must not be empty")); }
        Ok(items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn every_variant() -> Vec<Frame> {
        vec![
            Frame::HelloExec { network_on: true },
            Frame::HelloTunnel { port: 3000 },
            Frame::HelloNetChanged { on: false },
            Frame::Exec {
                nonce: "9f3a6c0d5e8b12474455aabbccdd0011".into(), workdir: "/workspace".into(),
                argv: vec!["/bin/sh".into(), "-c".into(), "ls".into()],
                env: vec!["A=1".into()], cols: 203, rows: 51,
            },
            Frame::Resize { cols: 80, rows: 24 },
            Frame::Started,
            Frame::Error { reason: "busy".into() },
            Frame::Exited { code: 130 },
            Frame::HelloStdio { which: StdioStream::Stdout, nonce: "0".repeat(32) },
            Frame::HelloPortEvents,
            Frame::HelloProxy,
            Frame::Adopt { blob: vec![1, 2, 3] },
            Frame::Ctl { verb: CtlVerb::Net, payload: b"off".to_vec() },
            Frame::Ctl { verb: CtlVerb::Copy, payload: b"echo hi\n".to_vec() },
            Frame::PortEvent { port: 8080, open: true },
            Frame::CtlReply { status: CtlStatus::Err, message: "nope".into(), payload: vec![] },
        ]
    }

    #[test]
    fn every_variant_round_trips() {
        for frame in every_variant() {
            let bytes = frame.encode();
            assert_eq!(Frame::decode(&bytes), Ok(frame.clone()), "{}", frame.name());
        }
    }

    #[test]
    fn every_strict_prefix_of_every_variant_errors() {
        for frame in every_variant() {
            let bytes = frame.encode();
            for cut in 0..bytes.len() {
                assert!(Frame::decode(&bytes[..cut]).is_err(),
                        "{}: prefix of {} bytes decoded", frame.name(), cut);
            }
            let payload = &bytes[4..];
            for cut in 0..payload.len() {
                assert!(Frame::decode_payload(&payload[..cut]).is_err(),
                        "{}: payload prefix of {} bytes decoded", frame.name(), cut);
            }
        }
    }

    #[test]
    fn unknown_tags_and_enum_values_are_refused() {
        assert!(Frame::decode_payload(&[0xFF]).is_err());
        assert!(Frame::decode_payload(&[0x15, 0x63, 0, 0, 0, 0]).is_err());
        assert!(Frame::decode_payload(&[0x11, 0x07]).is_err());
    }

    #[test]
    fn hostile_declared_lengths_never_allocate_past_the_frame() {
        let mut body = vec![0x08];
        body.extend(u16::MAX.to_be_bytes());
        assert!(Frame::decode_payload(&body).is_err());
        let mut body = vec![0x14];
        body.extend(u32::MAX.to_be_bytes());
        assert!(Frame::decode_payload(&body).is_err());
    }

    #[test]
    fn copy_cap_is_the_contract_value() {
        assert_eq!(MAX_COPY_PAYLOAD, 262_144);
    }

    #[test]
    fn copy_alone_gets_the_larger_payload_cap() {
        let text = vec![b'a'; MAX_CTL_PAYLOAD as usize + 1];
        let ok = Frame::Ctl { verb: CtlVerb::Copy, payload: text.clone() };
        assert_eq!(Frame::decode(&ok.encode()), Ok(ok));
        let over = Frame::Ctl { verb: CtlVerb::Drop, payload: text };
        assert!(Frame::decode(&over.encode()).is_err());
        let big = Frame::Ctl { verb: CtlVerb::Copy, payload: vec![b'a'; MAX_COPY_PAYLOAD as usize + 1] };
        assert!(Frame::decode(&big.encode()).is_err());
    }

    #[test]
    fn an_oversize_string_or_list_is_refused_not_truncated() {
        let long = Frame::Error { reason: "a".repeat(u16::MAX as usize + 1) };
        assert_eq!(long.try_encode(), None);
        let fits = Frame::Error { reason: "a".repeat(u16::MAX as usize) };
        assert!(fits.try_encode().is_some());
        let many = Frame::Exec {
            nonce: "n".into(), workdir: "/".into(), argv: vec!["x".into(); u16::MAX as usize + 1],
            env: vec![], cols: 80, rows: 24,
        };
        assert_eq!(many.try_encode(), None);
    }
}
