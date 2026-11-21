//! The frames: what the hub and a runner say to each other (`docs/develop/sleipnir.md`, "The protocol").

use forseti::{Expected, Grant, JobSpec, Priority, Psi, WaitReason};
use secrecy::{ExposeSecret, SecretString};
use serde::de::Error as _;
use serde::ser::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::cell::Cell;
use std::fmt;

/// An attempt's nonce: 16 random bytes the hub makes when it places the attempt. Every frame about the attempt carries
/// it, so a frame from an older attempt, or about an attempt the hub never gave that runner, never counts. It reads
/// and writes as 32 hex digits; `Debug` shows only the first 8.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Nonce(pub [u8; 16]);

impl Nonce {
    /// The 32 hex digits.
    pub fn hex(&self) -> String {
        hex(&self.0)
    }

    /// The nonce written as HEX (exactly 32 hex digits).
    pub fn from_hex(text: &str) -> Option<Nonce> {
        from_hex::<16>(text).map(Nonce)
    }
}

impl fmt::Debug for Nonce {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Nonce({})", &self.hex()[..8])
    }
}

impl Serialize for Nonce {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.hex())
    }
}

impl<'de> Deserialize<'de> for Nonce {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Nonce, D::Error> {
        let s = String::deserialize(d)?;
        Nonce::from_hex(&s).ok_or_else(|| D::Error::custom("a nonce is 32 hex digits"))
    }
}

/// A sha256, written as 64 hex digits.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Sha256(pub [u8; 32]);

impl fmt::Debug for Sha256 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Sha256({})", &hex(&self.0)[..12])
    }
}

impl Serialize for Sha256 {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&hex(&self.0))
    }
}

impl<'de> Deserialize<'de> for Sha256 {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Sha256, D::Error> {
        let s = String::deserialize(d)?;
        from_hex::<32>(&s)
            .map(Sha256)
            .ok_or_else(|| D::Error::custom("a sha256 is 64 hex digits"))
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex<const N: usize>(text: &str) -> Option<[u8; N]> {
    let t = text.as_bytes();
    if t.len() != 2 * N {
        return None;
    }
    let digit = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
    let mut out = [0u8; N];
    for (i, o) in out.iter_mut().enumerate() {
        *o = digit(t[2 * i])? << 4 | digit(t[2 * i + 1])?;
    }
    Some(out)
}

/// Which attempt of which job a frame is about. Every job frame carries one, nonce included: a job frame without it
/// does not parse.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct JobRef {
    pub job: String,
    pub attempt: u32,
    pub nonce: Nonce,
}

/// An attempt as the runner finds it in its folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AttemptState {
    /// Its unit runs.
    Running,
    /// Its `result.json` is written.
    Finished,
    /// Neither: its unit is gone without a result.
    Lost,
    /// A state a newer runner names.
    #[serde(other)]
    Unknown,
}

/// One attempt in the runner's `hello-ok`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttemptInfo {
    pub r: JobRef,
    pub state: AttemptState,
    /// How many bytes of its log the runner holds.
    #[serde(default)]
    pub log_offset: u64,
}

/// What a host is, once it meets the runner contract (`linux::probe::contract`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Facts {
    pub arch: String,
    pub os: String,
    pub cores: u32,
    pub mem_mib: u64,
    pub disk_free_gb: u64,
    pub podman_version: String,
    pub linger: bool,
    pub landlock_abi: u32,
    pub graphical: bool,
    pub battery: bool,
    pub swap_max_settable: bool,
    /// systemd writes `AllowedCPUs` into our slices' `cpuset.cpus`; when false the executor writes the delegated files
    /// itself (`linux::probe::Probe::cpuset_by_systemd`).
    pub cpuset_by_systemd: bool,
    /// Other schedulers with a live reservation here (`jobq`, another hub).
    pub others_present: Vec<String>,
}

/// One thing the host lacks, and what the user runs there to fix it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Missing {
    pub what: String,
    pub fix: String,
}

/// One entry of an overlay manifest: a file with its mode, hash and size, or a deletion. Paths are raw bytes,
/// exactly as git gave them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "k", rename_all = "lowercase")]
pub enum ManifestEntry {
    File {
        path: Vec<u8>,
        mode: u32,
        sha256: Sha256,
        size: u64,
    },
    Deleted {
        path: Vec<u8>,
    },
}

/// A key's value inside a `key` frame. It has no `Clone`, its `Debug` never shows it, and it serializes only while the
/// frame codec writes a frame ([`super::FrameWriter`]): anywhere else serializing it fails, so it can't reach a log or
/// a file by way of serde. The value is zeroed when it is dropped.
pub struct KeyValue(SecretString);

impl KeyValue {
    pub fn new(value: SecretString) -> KeyValue {
        KeyValue(value)
    }

    /// The value, for the one place that hands it on (the job helper's socket).
    pub fn expose(&self) -> &str {
        self.0.expose_secret()
    }
}

impl fmt::Debug for KeyValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

impl PartialEq for KeyValue {
    fn eq(&self, other: &KeyValue) -> bool {
        self.expose() == other.expose()
    }
}

thread_local! {
    static CODEC_WRITES: Cell<bool> = const { Cell::new(false) };
}

/// While it lives, this thread's codec is writing a frame, and a [`KeyValue`] may serialize.
pub(super) struct CodecWrites(());

impl CodecWrites {
    pub(super) fn begin() -> CodecWrites {
        CODEC_WRITES.with(|c| c.set(true));
        CodecWrites(())
    }
}

impl Drop for CodecWrites {
    fn drop(&mut self) {
        CODEC_WRITES.with(|c| c.set(false));
    }
}

impl Serialize for KeyValue {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        if CODEC_WRITES.with(Cell::get) {
            s.serialize_str(self.expose())
        } else {
            Err(S::Error::custom(
                "a key's value is written only by the frame codec",
            ))
        }
    }
}

impl<'de> Deserialize<'de> for KeyValue {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<KeyValue, D::Error> {
        SecretString::deserialize(d).map(KeyValue)
    }
}

/// A key the hub sends for a running attempt: never logged, sent only after `started`, and only where the runner's
/// trust allows it.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Key {
    pub r: JobRef,
    pub name: String,
    pub value: KeyValue,
}

/// A wait reason a newer peer may name differently: one this side can't read is `None`, never a frame that fails.
fn lenient<'de, D: Deserializer<'de>>(d: D) -> Result<Option<WaitReason>, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    Ok(serde_json::from_value(v).ok())
}

/// One frame. On the wire each is one JSON line tagged by `t`; `log`, `blob` and `bundle` are followed by their bytes
/// as one length-prefixed binary chunk ([`super::codec`]). Fields a side doesn't know are ignored, fields it misses
/// take their defaults, and a `t` it doesn't know reads as [`Frame::Unknown`].
#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum Frame {
    // ---- connection
    /// hub → runner, first on a new channel.
    Hello {
        version: u32,
        hub_id: String,
    },
    /// runner → hub: who it is, whether its jobs outlive the link, its attempts, and what the contract finds missing
    /// (re-probed at every hello).
    HelloOk {
        version: u32,
        #[serde(default)]
        bundle: String,
        #[serde(default)]
        hub_id: String,
        #[serde(default)]
        runner_id: String,
        #[serde(default)]
        boot_id: String,
        #[serde(default)]
        linger: bool,
        #[serde(default)]
        attempts: Vec<AttemptInfo>,
        #[serde(default)]
        missing: Vec<Missing>,
    },
    /// hub → runner: read the host again.
    Probe,
    /// runner → hub.
    ProbeResult {
        #[serde(default)]
        facts: Option<Facts>,
        #[serde(default)]
        missing: Vec<Missing>,
        /// Why container jobs can't be capped here (`check_limits`), if they can't.
        #[serde(default)]
        limits: Option<String>,
        #[serde(default)]
        features: Vec<String>,
        /// The memory the machine has available now, MiB (0 when it can't be read): with the profile's floor and
        /// reserve, the hub tells a user whose machine leaves no room for jobs.
        mem_available_mib: u64,
    },
    /// runner → hub, every 2 s and at every job end.
    Ready {
        #[serde(default)]
        free_mib: i64,
        /// As in `ProbeResult`: what `free_mib` was counted from.
        mem_available_mib: u64,
        #[serde(default)]
        free_cpu: f64,
        #[serde(default)]
        psi: Psi,
        #[serde(default)]
        running: Vec<JobRef>,
        #[serde(default)]
        slots: Vec<String>,
        #[serde(default)]
        images: Vec<String>,
        /// The machine runs on battery: a Mac that then goes quiet is asleep, not lost.
        #[serde(default)]
        on_battery: bool,
    },

    // ---- placement
    /// hub → runner: the job spec, its frozen input key and the hub's grant hint.
    Offer {
        r: JobRef,
        spec: Box<JobSpec>,
        priority: Priority,
        #[serde(default)]
        input_key: String,
        #[serde(default)]
        grant_hint: Option<Grant>,
        #[serde(default)]
        expected: Option<Expected>,
    },
    /// runner → hub: admitted with this grant, and reserved.
    Admit {
        r: JobRef,
        grant: Grant,
    },
    /// runner → hub: not now, and why.
    Refuse {
        r: JobRef,
        why: String,
        #[serde(default, deserialize_with = "lenient")]
        reason: Option<WaitReason>,
    },

    /// hub → runner: the queue's head is reserved on this runner, to start at AT (epoch seconds) with MEM_MIB and
    /// CPU, so a grow here leaves it that room ([`crate::linux::resize::Head`]). AT 0: no head is reserved here now.
    Head {
        #[serde(default)]
        at: u64,
        #[serde(default)]
        mem_mib: u64,
        #[serde(default)]
        cpu: f64,
    },

    // ---- sync
    /// hub → runner: what the attempt's inputs are: the commit of repository REPO (its mirror's id) and the overlay
    /// the runner's trust may get. The runner answers with a `sync-need`.
    SyncHave {
        r: JobRef,
        #[serde(default)]
        repo: String,
        #[serde(default)]
        input_key: String,
        commit: String,
        #[serde(default)]
        tree: String,
        #[serde(default)]
        manifest: Vec<ManifestEntry>,
    },
    /// runner → hub: the blobs it lacks, whether it lacks the commit, and the commits its mirror's refs hold (what a
    /// bundle leaves out). Sent for every `sync-have`, and again once an origin fetch or a bundle is in.
    SyncNeed {
        r: JobRef,
        #[serde(default)]
        blobs: Vec<Sha256>,
        #[serde(default)]
        commit: bool,
        #[serde(default)]
        refs: Vec<String>,
    },
    /// hub → runner: a blob's chunk at OFFSET of TOTAL bytes (its bytes follow); TOTAL 0 (an older hub): the bytes
    /// are the whole blob.
    Blob {
        r: JobRef,
        sha256: Sha256,
        #[serde(default)]
        offset: u64,
        #[serde(default)]
        total: u64,
        #[serde(skip)]
        bytes: Vec<u8>,
    },
    /// hub → runner: a bundle chunk at OFFSET of TOTAL (its bytes follow), each with the bundle's hash.
    Bundle {
        r: JobRef,
        id: String,
        offset: u64,
        #[serde(default)]
        total: u64,
        #[serde(default)]
        sha256: Option<Sha256>,
        #[serde(skip)]
        bytes: Vec<u8>,
    },
    /// hub → runner: fetch COMMIT from the project's origin; with CRED, through the deploy key or token of that name,
    /// sent just before in a `key` frame of the attempt's (held in memory for the fetch only).
    OriginFetch {
        r: JobRef,
        repo: String,
        url: String,
        commit: String,
        #[serde(default)]
        cred: Option<String>,
    },

    // ---- a job's run
    /// hub → runner: run the admitted attempt.
    Start {
        r: JobRef,
        #[serde(default)]
        image: Option<String>,
        /// Plain variables (never keys: those come as `key` frames).
        #[serde(default)]
        env: Vec<(String, String)>,
        #[serde(default)]
        net_hosts: Vec<String>,
        /// Names the job's proxy resolves to a fixed address instead of asking DNS (the hub's
        /// `drgnx-sandbox-proxy-pinned-addresses`); an older hub sends none.
        #[serde(default)]
        pins: Vec<(String, std::net::IpAddr)>,
        /// The row parser (`ert`, `cargo-test`, `plist`, `exit`).
        #[serde(default)]
        parser: String,
    },
    /// runner → hub: its unit runs.
    Started {
        r: JobRef,
        #[serde(default)]
        unit: String,
        #[serde(default)]
        at: u64,
    },
    /// runner → hub: the attempt's log from OFFSET (its bytes follow), read from the log file, never a pipe.
    Log {
        r: JobRef,
        offset: u64,
        #[serde(skip)]
        bytes: Vec<u8>,
    },
    /// runner → hub, before `finished`: a piece of what the attempt gives back (`what`: `patch` or `outputs`, see
    /// `sync::returned`) at OFFSET of TOTAL bytes (its bytes follow), each with the whole's hash; the first piece also
    /// lists what was left out of it (path, why). TOTAL 0: nothing of that kind. `kept`: the whole is over its limit
    /// and stays on the runner, for a `fetch`.
    Returned {
        r: JobRef,
        what: String,
        offset: u64,
        total: u64,
        sha256: Sha256,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        left: Vec<(String, String)>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        kept: bool,
        #[serde(skip)]
        bytes: Vec<u8>,
    },
    /// runner → hub: a parsed test row.
    Row {
        r: JobRef,
        name: String,
        verdict: String,
    },
    /// hub → runner: a key. Never logged ([`Frame::loggable`]).
    Key(Key),
    /// runner → hub: the job asked for key NAME.
    KeyUse {
        r: JobRef,
        name: String,
        #[serde(default)]
        at: u64,
    },
    /// runner → hub: the attempt's `result.json`, the only source of a verdict.
    Finished {
        r: JobRef,
        result: serde_json::Value,
    },
    /// hub → runner: stop the attempt.
    Cancel {
        r: JobRef,
    },
    /// hub → runner: send back a file of the attempt.
    Fetch {
        r: JobRef,
        path: String,
    },
    /// hub → runner, after a `hello-ok` listed the attempt: stream its log from LOG_OFFSET (where the hub's copy
    /// ends), then its `finished` when it ends. A new attempt streams from 0 without it.
    Attach {
        r: JobRef,
        #[serde(default)]
        log_offset: u64,
    },
    /// hub → runner: the hub has recorded the attempt's result, so its folder may go at the next cleanup.
    Done {
        r: JobRef,
    },

    // ---- runner state
    Preempting {
        #[serde(default)]
        at: u64,
    },
    Draining,
    Idle {
        #[serde(default)]
        since: u64,
    },

    // ---- keep-alive and end
    Ping {
        #[serde(default)]
        at: u64,
    },
    Pong {
        #[serde(default)]
        at: u64,
    },
    /// A clean end; an EOF without it is `link-lost`.
    Bye {
        #[serde(default)]
        why: String,
    },

    /// A frame a newer peer sends that this side doesn't know.
    #[serde(other)]
    Unknown,
}

impl Frame {
    /// The frame as a log line may show it, without its bytes; `None` for a `key` frame, which is never logged.
    pub fn loggable(&self) -> Option<String> {
        match self {
            Frame::Key(_) => None,
            f => serde_json::to_string(f).ok(),
        }
    }

    /// The attempt a job frame is about.
    pub fn job(&self) -> Option<&JobRef> {
        match self {
            Frame::Offer { r, .. }
            | Frame::Admit { r, .. }
            | Frame::Refuse { r, .. }
            | Frame::SyncHave { r, .. }
            | Frame::SyncNeed { r, .. }
            | Frame::Blob { r, .. }
            | Frame::Bundle { r, .. }
            | Frame::OriginFetch { r, .. }
            | Frame::Start { r, .. }
            | Frame::Started { r, .. }
            | Frame::Log { r, .. }
            | Frame::Returned { r, .. }
            | Frame::Row { r, .. }
            | Frame::Key(Key { r, .. })
            | Frame::KeyUse { r, .. }
            | Frame::Finished { r, .. }
            | Frame::Cancel { r }
            | Frame::Fetch { r, .. }
            | Frame::Attach { r, .. }
            | Frame::Done { r } => Some(r),
            _ => None,
        }
    }

    /// The bytes that follow the frame on the wire (`log`, `returned`, `blob`, `bundle`).
    pub fn payload(&self) -> Option<&[u8]> {
        match self {
            Frame::Log { bytes, .. }
            | Frame::Returned { bytes, .. }
            | Frame::Blob { bytes, .. }
            | Frame::Bundle { bytes, .. } => Some(bytes),
            _ => None,
        }
    }

    pub(super) fn payload_mut(&mut self) -> Option<&mut Vec<u8>> {
        match self {
            Frame::Log { bytes, .. }
            | Frame::Returned { bytes, .. }
            | Frame::Blob { bytes, .. }
            | Frame::Bundle { bytes, .. } => Some(bytes),
            _ => None,
        }
    }
}
