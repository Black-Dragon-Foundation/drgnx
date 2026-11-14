//! `sleipnir watchdog`: a cloud machine's own end (`docs/develop/sleipnir.md`, "The watchdog"; design §6.7.6).
//!
//! ```text
//! sleipnir watchdog --provider aws|gcp --idle S --lifetime S --unattended S --root RUNNER_ROOT --dir DIR
//! ```
//!
//! A system unit in drgnx's image, so it runs with the hub gone. Every 5 s it looks at:
//!
//! - **the jobs:** the attempt folders under `RUNNER_ROOT/jobs/` the hub hasn't collected (running, or a result that
//!   waits for the hub), read from the folder so it needs no `serve`;
//! - **the hub:** `RUNNER_ROOT/heartbeat.json`, which `serve --watchdog DIR` writes: `contact`, the hub's last frame,
//!   and `offer`, its last offer;
//! - **the provider's notice:** AWS IMDSv2 `spot/instance-action` (a token first), GCE's `instance/preempted`.
//!
//! What it decides is [`decide`], pure. On AWS it runs `systemctl poweroff` (never `halt`: the instance is started with
//! `InstanceInitiatedShutdownBehavior=terminate`, so a power-off ends it and its bill): with no job for the idle time
//! counted from the last job and the last offer, at the unattended lifetime after the hub's last contact, and at the
//! lifetime since boot whatever runs. On GCP it never powers off (a guest stop leaves a billed disk and clears the
//! deadline); it writes `DIR/idle` for `serve` to report, and the hub deletes the machine. A notice is written to
//! `DIR/preempting` (its time, Unix seconds); `serve` sends `preempting {at}`.
//!
//! It writes only in DIR, its own folder (root's in the image), and reads the runner's files without following a
//! link, with a cap. A test build adds `--clock-file F` (the time is F's number), `--poweroff-cmd PATH` and
//! `--metadata-url URL` (`ratatoskr-mock cloud`'s `/__metadata/<instance>`).

use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How often it looks.
pub const POLL: Duration = Duration::from_secs(5);
/// In the runner's root: what `serve` writes for it.
pub const HEARTBEAT: &str = "heartbeat.json";
/// In its own folder: the notice's time.
pub const PREEMPTING: &str = "preempting";
/// In its own folder (GCP): since when the machine is idle.
pub const IDLE: &str = "idle";
/// In its own folder: why it powered the machine off.
pub const POWEROFF: &str = "poweroff";
/// The instance metadata, AWS's and GCE's.
const METADATA: &str = "http://169.254.169.254";
/// The most read from any file or answer.
const MAX_READ: u64 = 64 << 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Aws,
    Gcp,
}

/// The user's limits, in seconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub idle_s: u64,
    pub lifetime_s: u64,
    pub unattended_s: u64,
}

/// `heartbeat.json`: when the hub last sent a frame, and its last offer (Unix seconds).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Heartbeat {
    #[serde(default)]
    pub contact: u64,
    #[serde(default)]
    pub offer: u64,
}

/// Why the machine powers off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Why {
    Idle,
    Unattended,
    Lifetime,
}

impl Why {
    pub fn as_str(self) -> &'static str {
        match self {
            Why::Idle => "idle",
            Why::Unattended => "unattended",
            Why::Lifetime => "lifetime",
        }
    }
}

/// What the watchdog does now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Act {
    /// AWS: `systemctl poweroff`.
    Poweroff(Why),
    /// GCP: report the machine idle since SINCE (the hub deletes it).
    Idle { since: u64 },
}

/// One look at the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Look {
    pub now: u64,
    pub booted: u64,
    /// The last time a job was seen.
    pub last_job: u64,
    pub jobs: usize,
    pub heartbeat: Option<Heartbeat>,
}

/// What LOOK means under LIMITS on PROVIDER. Times before the boot (a file left in the image) count as the boot.
pub fn decide(provider: Provider, limits: &Limits, look: &Look) -> Option<Act> {
    let hb = look.heartbeat.unwrap_or_default();
    let since = |t: u64| look.now.saturating_sub(t.max(look.booted));
    let idle_since = look.last_job.max(hb.offer).max(look.booted);
    let idle = look.jobs == 0 && since(idle_since) >= limits.idle_s;
    match provider {
        Provider::Gcp => idle.then_some(Act::Idle { since: idle_since }),
        Provider::Aws => {
            if since(look.booted) >= limits.lifetime_s {
                Some(Act::Poweroff(Why::Lifetime))
            } else if since(hb.contact) >= limits.unattended_s {
                Some(Act::Poweroff(Why::Unattended))
            } else if idle {
                Some(Act::Poweroff(Why::Idle))
            } else {
                None
            }
        }
    }
}

/// [`decide`] over time: it keeps the last time it saw a job.
#[derive(Clone, Debug)]
pub struct Watch {
    provider: Provider,
    limits: Limits,
    booted: u64,
    last_job: u64,
}

impl Watch {
    /// A watch of a machine BOOTED then, started at STARTED: a restarted watchdog counts the idle time from its own
    /// start, never from before it (it can't know when the last job ended).
    pub fn new(provider: Provider, limits: Limits, booted: u64, started: u64) -> Watch {
        Watch {
            provider,
            limits,
            booted,
            last_job: started,
        }
    }

    /// NOW, with JOBS of ours on the machine and the hub's HEARTBEAT.
    pub fn step(&mut self, now: u64, jobs: usize, heartbeat: Option<Heartbeat>) -> Option<Act> {
        if jobs > 0 {
            self.last_job = now;
        }
        decide(
            self.provider,
            &self.limits,
            &Look {
                now,
                booted: self.booted,
                last_job: self.last_job,
                jobs,
                heartbeat,
            },
        )
    }
}

/// `2026-11-06T00:02:00Z` (fractions and `+hh:mm` taken) as Unix seconds.
pub fn parse_iso(s: &str) -> Option<u64> {
    let (date, rest) = s.trim().split_once('T')?;
    let mut d = date.split('-');
    let (y, m, day): (i64, i64, i64) = (
        d.next()?.parse().ok()?,
        d.next()?.parse().ok()?,
        d.next()?.parse().ok()?,
    );
    let (clock, offset) = match rest.find(['Z', '+', '-']) {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "Z"),
    };
    let mut t = clock.split(':');
    let h: i64 = t.next()?.parse().ok()?;
    let mi: i64 = t.next()?.parse().ok()?;
    let sec: i64 = t.next()?.split('.').next()?.parse().ok()?;
    let off = match offset {
        "Z" => 0,
        o => {
            let sign = if o.starts_with('-') { -1 } else { 1 };
            let (oh, om) = o[1..].split_once(':').unwrap_or((&o[1..], "0"));
            sign * (oh.parse::<i64>().ok()? * 3600 + om.parse::<i64>().ok()? * 60)
        }
    };
    // days from the civil date (Howard Hinnant's algorithm)
    let yy = if m <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    u64::try_from(days * 86_400 + h * 3600 + mi * 60 + sec - off).ok()
}

/// IMDSv2 `spot/instance-action`'s answer (`{"action": "terminate"|"stop"|"hibernate", "time": …}`): when.
pub fn aws_notice(body: &str) -> Option<u64> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    v["action"].as_str()?;
    parse_iso(v["time"].as_str()?)
}

/// GCE's `instance/preempted`: `TRUE` once the machine is being preempted.
pub fn gcp_preempted(body: &str) -> bool {
    body.trim() == "TRUE"
}

/// An HTTP/1.1 answer's status and body (by its `Content-Length`, else all that came).
pub fn http_answer(raw: &[u8]) -> Option<(u16, String)> {
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = std::str::from_utf8(&raw[..end]).ok()?;
    let mut lines = head.split("\r\n");
    let status: u16 = lines
        .next()?
        .strip_prefix("HTTP/1.")?
        .split(' ')
        .nth(1)?
        .parse()
        .ok()?;
    let len = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse::<usize>().ok());
    let body = &raw[end + 4..];
    let body = &body[..len.map_or(body.len(), |n| n.min(body.len()))];
    Some((status, String::from_utf8_lossy(body).into_owned()))
}

/// RAW holds a whole answer by its `Content-Length` (so the read needn't wait for the server to close).
fn whole(raw: &[u8]) -> bool {
    let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") else {
        return false;
    };
    let head = String::from_utf8_lossy(&raw[..end]).to_ascii_lowercase();
    head.split("\r\n")
        .filter_map(|l| l.strip_prefix("content-length:"))
        .find_map(|v| v.trim().parse::<usize>().ok())
        .is_some_and(|n| raw.len() >= end + 4 + n)
}

/// One plain-HTTP request to the metadata server (it is on the machine's own link: no TLS, a 2 s limit).
fn http(method: &str, url: &str, headers: &[(&str, &str)]) -> io::Result<(u16, String)> {
    use std::net::ToSocketAddrs;
    let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidInput, format!("{what}: {url}"));
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| bad("not http://"))?;
    let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
    let addr = if host.contains(':') {
        host.to_string()
    } else {
        format!("{host}:80")
    };
    let to = Duration::from_secs(2);
    let sock = addr
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| bad("no address"))?;
    let mut s = std::net::TcpStream::connect_timeout(&sock, to)?;
    s.set_read_timeout(Some(to))?;
    s.set_write_timeout(Some(to))?;
    let mut req = format!(
        "{method} /{path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nContent-Length: 0\r\n"
    );
    for (k, v) in headers {
        req.push_str(&format!("{k}: {v}\r\n"));
    }
    req.push_str("\r\n");
    s.write_all(req.as_bytes())?;
    let mut raw = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match s.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => raw.extend_from_slice(&buf[..n]),
            Err(e) if raw.is_empty() => return Err(e),
            Err(_) => break,
        }
        if raw.len() as u64 > MAX_READ || whole(&raw) {
            break;
        }
    }
    http_answer(&raw).ok_or_else(|| bad("an answer that is not HTTP"))
}

/// How the watchdog was started.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Args {
    pub provider: Provider,
    pub limits: Limits,
    /// The runner's root: its `jobs/` and `heartbeat.json`.
    pub root: PathBuf,
    /// Its own folder.
    pub dir: PathBuf,
    pub metadata: String,
    pub clock_file: Option<PathBuf>,
    pub poweroff: Vec<String>,
}

impl Args {
    /// `--provider aws|gcp --idle S --lifetime S --unattended S --root DIR --dir DIR` (and in a test build
    /// `--clock-file F --poweroff-cmd PATH --metadata-url URL`).
    pub fn parse(args: &[&str]) -> Result<Args, String> {
        let (mut provider, mut idle, mut lifetime, mut unattended) = (None, None, None, None);
        let (mut root, mut dir) = (None, None);
        // a test build may set these three
        #[cfg_attr(not(feature = "test-hooks"), allow(unused_mut))]
        let mut metadata = METADATA.to_string();
        #[cfg_attr(not(feature = "test-hooks"), allow(unused_mut))]
        let mut clock_file = None;
        #[cfg_attr(not(feature = "test-hooks"), allow(unused_mut))]
        let mut poweroff = vec!["systemctl".to_string(), "poweroff".to_string()];
        let mut it = args.iter();
        while let Some(a) = it.next() {
            let v = it.next().ok_or_else(|| format!("{a} needs a value"))?;
            let secs = || {
                v.parse::<u64>()
                    .map_err(|_| format!("{a} is seconds, not {v}"))
            };
            let abs = || {
                let p = PathBuf::from(v);
                if p.is_absolute() {
                    Ok(p)
                } else {
                    Err(format!("{a} must be absolute: {v}"))
                }
            };
            match *a {
                "--provider" => {
                    provider = Some(match *v {
                        "aws" => Provider::Aws,
                        "gcp" => Provider::Gcp,
                        p => return Err(format!("--provider is aws or gcp, not {p}")),
                    })
                }
                "--idle" => idle = Some(secs()?),
                "--lifetime" => lifetime = Some(secs()?),
                "--unattended" => unattended = Some(secs()?),
                "--root" => root = Some(abs()?),
                "--dir" => dir = Some(abs()?),
                #[cfg(feature = "test-hooks")]
                "--clock-file" => clock_file = Some(abs()?),
                #[cfg(feature = "test-hooks")]
                "--poweroff-cmd" => poweroff = vec![abs()?.display().to_string()],
                #[cfg(feature = "test-hooks")]
                "--metadata-url" => metadata = v.trim_end_matches('/').to_string(),
                other => return Err(format!("unknown option {other}")),
            }
        }
        let need = |v: Option<u64>, n: &str| v.ok_or_else(|| format!("{n} is needed"));
        Ok(Args {
            provider: provider.ok_or("--provider is needed")?,
            limits: Limits {
                idle_s: need(idle, "--idle")?,
                lifetime_s: need(lifetime, "--lifetime")?,
                unattended_s: need(unattended, "--unattended")?,
            },
            root: root.ok_or("--root is needed")?,
            dir: dir.ok_or("--dir is needed")?,
            metadata,
            clock_file,
            poweroff,
        })
    }
}

/// A small regular file's text, read without following a link and without blocking on a FIFO; none otherwise.
pub fn read_small(path: &Path) -> Option<String> {
    use std::os::unix::fs::OpenOptionsExt;
    let f = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    if !f.metadata().ok()?.is_file() {
        return None;
    }
    let mut s = String::new();
    f.take(MAX_READ).read_to_string(&mut s).ok()?;
    Some(s)
}

/// Writes TEXT to DIR/NAME by rename (a new file each time: never through a link).
fn put(dir: &Path, name: &str, text: &str) -> io::Result<()> {
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let _ = fs::remove_file(&tmp);
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)?;
    f.write_all(text.as_bytes())?;
    drop(f);
    fs::rename(&tmp, dir.join(name))
}

/// The attempts under ROOT the hub hasn't collected: running, or a result waiting for the hub.
pub fn jobs(root: &Path) -> usize {
    use crate::serve::attempts::{COLLECTED, META, jobs};
    fs::read_dir(jobs(root)).map_or(0, |rd| {
        rd.flatten()
            .filter(|e| {
                let d = e.path();
                d.join(META).exists() && !d.join(COLLECTED).exists()
            })
            .count()
    })
}

/// The provider's notice now: when the machine goes.
fn notice(args: &Args, now: u64) -> Option<u64> {
    let base = &args.metadata;
    match args.provider {
        Provider::Aws => {
            let (status, token) = http(
                "PUT",
                &format!("{base}/latest/api/token"),
                &[("X-aws-ec2-metadata-token-ttl-seconds", "300")],
            )
            .ok()?;
            if status != 200 {
                return None;
            }
            let (status, body) = http(
                "GET",
                &format!("{base}/latest/meta-data/spot/instance-action"),
                &[("X-aws-ec2-metadata-token", token.trim())],
            )
            .ok()?;
            (status == 200).then(|| aws_notice(&body)).flatten()
        }
        Provider::Gcp => {
            let (status, body) = http(
                "GET",
                &format!("{base}/computeMetadata/v1/instance/preempted"),
                &[("Metadata-Flavor", "Google")],
            )
            .ok()?;
            (status == 200 && gcp_preempted(&body)).then_some(now)
        }
    }
}

fn wall() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The time: the clock file's number in a test build, else the wall clock.
fn clock(args: &Args, last: u64) -> u64 {
    match &args.clock_file {
        Some(f) => read_small(f)
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(last),
        None => wall(),
    }
}

/// When the machine booted: from its uptime (so a restarted watchdog keeps the lifetime), or with a clock file its
/// first reading.
fn booted(args: &Args, now: u64) -> u64 {
    if args.clock_file.is_some() {
        return now;
    }
    let up = read_small(Path::new("/proc/uptime"))
        .and_then(|s| s.split('.').next()?.trim().parse::<u64>().ok())
        .unwrap_or(0);
    now.saturating_sub(up)
}

/// Runs the watchdog with ARGS until it is stopped (it never exits on its own once it has started).
pub fn run(args: Args) -> i32 {
    if let Err(e) = fs::create_dir_all(&args.dir) {
        eprintln!("sleipnir watchdog: {}: {e}", args.dir.display());
        return 1;
    }
    let mut now = clock(&args, 0);
    let mut w = Watch::new(args.provider, args.limits, booted(&args, now), now);
    let (mut noticed, mut idle, mut off) = (false, None, false);
    eprintln!(
        "sleipnir watchdog: {:?}, idle {} s, lifetime {} s, unattended {} s",
        args.provider, args.limits.idle_s, args.limits.lifetime_s, args.limits.unattended_s
    );
    loop {
        now = clock(&args, now);
        if !noticed && let Some(at) = notice(&args, now) {
            match put(&args.dir, PREEMPTING, &at.to_string()) {
                Ok(()) => {
                    noticed = true;
                    eprintln!("sleipnir watchdog: the provider's notice: the machine goes at {at}");
                }
                Err(e) => eprintln!("sleipnir watchdog: writing the notice: {e}"),
            }
        }
        let hb = read_small(&args.root.join(HEARTBEAT)).and_then(|s| serde_json::from_str(&s).ok());
        match w.step(now, jobs(&args.root), hb) {
            Some(Act::Poweroff(why)) if !off => {
                let _ = put(&args.dir, POWEROFF, why.as_str());
                eprintln!("sleipnir watchdog: powering off ({})", why.as_str());
                match std::process::Command::new(&args.poweroff[0])
                    .args(&args.poweroff[1..])
                    .stdin(std::process::Stdio::null())
                    .status()
                {
                    Ok(s) if s.success() => off = true,
                    // tried again at the next look
                    Ok(s) => eprintln!("sleipnir watchdog: the power-off failed: {s}"),
                    Err(e) => eprintln!("sleipnir watchdog: the power-off: {e}"),
                }
            }
            Some(Act::Idle { since }) if idle != Some(since) => {
                if put(&args.dir, IDLE, &since.to_string()).is_ok() {
                    idle = Some(since);
                }
            }
            None if idle.is_some() => {
                let _ = fs::remove_file(args.dir.join(IDLE));
                idle = None;
            }
            _ => {}
        }
        std::thread::sleep(POLL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const L: Limits = Limits {
        idle_s: 900,
        lifetime_s: 8 * 3600,
        unattended_s: 2 * 3600,
    };

    fn hb(contact: u64, offer: u64) -> Option<Heartbeat> {
        Some(Heartbeat { contact, offer })
    }

    fn look(now: u64, jobs: usize, last_job: u64, heartbeat: Option<Heartbeat>) -> Look {
        Look {
            now,
            booted: 0,
            last_job,
            jobs,
            heartbeat,
        }
    }

    // [D] pure: a test clock (every row's time is a value)
    #[test]
    fn watchdog_aws_idle_unattended_lifetime_table() {
        use Act::Poweroff;
        let rows: &[(&str, Look, Option<Act>)] = &[
            ("just booted", look(10, 0, 0, None), None),
            ("no job, no hub: 899 s", look(899, 0, 0, None), None),
            (
                "no job, no hub: the idle time",
                look(900, 0, 0, None),
                Some(Poweroff(Why::Idle)),
            ),
            (
                "pings without an offer never keep an idle machine",
                look(900, 0, 0, hb(899, 0)),
                Some(Poweroff(Why::Idle)),
            ),
            (
                "an offer 100 s ago keeps it",
                look(1000, 0, 0, hb(999, 900)),
                None,
            ),
            (
                "the idle time counts from the last offer",
                look(1800, 0, 0, hb(1799, 900)),
                Some(Poweroff(Why::Idle)),
            ),
            (
                "a job that ended 899 s ago keeps it",
                look(3899, 0, 3000, hb(3898, 2000)),
                None,
            ),
            (
                "the idle time counts from the last job",
                look(3900, 0, 3000, hb(3899, 2000)),
                Some(Poweroff(Why::Idle)),
            ),
            (
                "a job keeps it past the idle time",
                look(5000, 1, 5000, hb(4999, 100)),
                None,
            ),
            (
                "busy, the hub gone 7199 s",
                look(7299, 1, 7299, hb(100, 100)),
                None,
            ),
            (
                "busy, the hub gone for the unattended lifetime",
                look(7300, 1, 7300, hb(100, 100)),
                Some(Poweroff(Why::Unattended)),
            ),
            (
                "busy, the hub never came: unattended from boot",
                look(7200, 1, 7200, None),
                Some(Poweroff(Why::Unattended)),
            ),
            (
                "busy, the hub there, 1 s before the lifetime",
                look(28_799, 1, 28_799, hb(28_798, 28_000)),
                None,
            ),
            (
                "the lifetime, whatever runs",
                look(28_800, 1, 28_800, hb(28_799, 28_799)),
                Some(Poweroff(Why::Lifetime)),
            ),
            (
                "the lifetime comes first when all three are due",
                look(28_800, 0, 0, None),
                Some(Poweroff(Why::Lifetime)),
            ),
        ];
        for (what, l, want) in rows {
            assert_eq!(decide(Provider::Aws, &L, l), *want, "{what}: {l:?}");
        }
        // a heartbeat from before this boot (a file left in the image) counts from the boot
        let stale = Look {
            now: 1000,
            booted: 100,
            last_job: 100,
            jobs: 0,
            heartbeat: hb(5, 5),
        };
        assert_eq!(decide(Provider::Aws, &L, &stale), Some(Poweroff(Why::Idle)));
        assert_eq!(decide(Provider::Aws, &L, &Look { now: 999, ..stale }), None);

        // the watch keeps the last time it saw a job; a restarted watchdog counts from its own start
        let mut w = Watch::new(Provider::Aws, L, 0, 0);
        assert_eq!(w.step(100, 1, None), None);
        assert_eq!(w.step(500, 0, hb(499, 0)), None);
        assert_eq!(w.step(999, 0, hb(998, 0)), None);
        assert_eq!(w.step(1000, 0, hb(999, 0)), Some(Poweroff(Why::Idle)));
        let mut again = Watch::new(Provider::Aws, L, 0, 5000);
        assert_eq!(again.step(5899, 0, None), None);
        assert_eq!(again.step(5900, 0, None), Some(Poweroff(Why::Idle)));
    }

    // [D] pure
    #[test]
    fn watchdog_gcp_never_powers_off() {
        for now in [0, 899, 900, 1800, 7200, 7300, 28_800, 100_000] {
            for jobs in [0, 1] {
                for heartbeat in [None, hb(0, 0), hb(now, 0), hb(now, now)] {
                    let l = look(now, jobs, 0, heartbeat);
                    let got = decide(Provider::Gcp, &L, &l);
                    assert!(
                        !matches!(got, Some(Act::Poweroff(_))),
                        "GCP powered off: {l:?} -> {got:?}"
                    );
                }
            }
        }
        // it reports the idle time to serve instead, from when it began
        assert_eq!(
            decide(Provider::Gcp, &L, &look(1800, 0, 0, hb(1799, 900))),
            Some(Act::Idle { since: 900 })
        );
        assert_eq!(
            decide(Provider::Gcp, &L, &look(1799, 0, 0, hb(1798, 900))),
            None
        );
        assert_eq!(
            decide(Provider::Gcp, &L, &look(28_800, 1, 28_800, None)),
            None
        );
    }

    // [D] pure
    #[test]
    fn notices_and_files_parse() {
        // IMDSv2 `spot/instance-action`
        assert_eq!(
            aws_notice(r#"{"action": "terminate", "time": "2026-11-06T00:02:00Z"}"#),
            Some(1_793_923_320)
        );
        assert_eq!(
            aws_notice(r#"{"action": "stop", "time": "2026-11-06T00:02:00Z"}"#),
            Some(1_793_923_320)
        );
        assert_eq!(aws_notice("not json"), None);
        assert_eq!(parse_iso("2026-11-06T00:00:00.250Z"), Some(1_793_923_200));
        assert_eq!(parse_iso("2026-11-06"), None);
        // GCE's `instance/preempted`
        assert!(gcp_preempted("TRUE\n"));
        assert!(!gcp_preempted("FALSE"));
        // an answer's status and body
        let (status, body) =
            http_answer(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nTRUE").unwrap();
        assert_eq!((status, body.as_str()), (200, "TRUE"));
        assert_eq!(http_answer(b"garbage"), None);
        // the heartbeat file serve writes
        let h: Heartbeat = serde_json::from_str(r#"{"contact": 7, "offer": 3}"#).unwrap();
        assert_eq!(
            h,
            Heartbeat {
                contact: 7,
                offer: 3
            }
        );
        assert_eq!(
            Args::parse(&[
                "--provider",
                "aws",
                "--idle",
                "900",
                "--lifetime",
                "28800",
                "--unattended",
                "7200",
                "--root",
                "/r",
                "--dir",
                "/run/w",
            ])
            .map(|a| (a.provider, a.limits)),
            Ok((Provider::Aws, L))
        );
        assert!(Args::parse(&["--provider", "azure"]).is_err());
        assert!(
            Args::parse(&[
                "--provider",
                "gcp",
                "--idle",
                "900",
                "--lifetime",
                "28800",
                "--unattended",
                "7200",
                "--root",
                "relative",
                "--dir",
                "/run/w",
            ])
            .is_err()
        );
    }
}
