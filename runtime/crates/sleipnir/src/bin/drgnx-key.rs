//! `drgnx-key`: what a keyed job runs in front of its command (docs/develop/sleipnir.md, "Keys"). Std only, so its
//! static build starts in any image.
//!
//! ```text
//! drgnx-key exec NAME=VAR… -- CMD…   each key NAME into the variable VAR, in this process only, then exec CMD
//! drgnx-key get NAME                 one key on stdout, for a tool that reads it from a pipe
//! ```
//!
//! Keys come from the job's relay sidecar, the abstract socket `@drgnx-key` in the network namespace the job shares
//! with it, which carries each request to the job helper (`DRGNX_KEY_SOCK` names another: `@NAME` or a path).
//! A request waits for its key up to 60 s; when it never comes the helper records it and `drgnx-key` exits 75, which
//! the job's result reads as `infra: key not delivered`. Nothing is written to a file, and the values go only into the
//! environment of the command `exec` starts.

use std::ffi::OsString;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};
use std::time::Duration;

const SOCKET: &str = "@drgnx-key";
/// The helper answers by 60 s; past that (and a margin) the helper is gone.
const WAIT: Duration = Duration::from_secs(65);
const NOT_DELIVERED: u8 = 75;
const USAGE: u8 = 64;
const MAX_KEY: usize = 64 << 10;

enum Fail {
    /// The key never came (the helper recorded it), or the helper can't be reached.
    NotDelivered(String),
    /// Anything else: a wrong request, a refusal.
    Other(String),
}

fn socket() -> OsString {
    std::env::var_os("DRGNX_KEY_SOCK").unwrap_or_else(|| SOCKET.into())
}

/// Connects to SOCK: `@NAME` is an abstract name (Linux), anything else a path.
fn connect(sock: &std::ffi::OsStr) -> io::Result<UnixStream> {
    use std::os::unix::ffi::OsStrExt;
    match sock.as_bytes().strip_prefix(b"@") {
        #[cfg(target_os = "linux")]
        Some(name) => {
            use std::os::linux::net::SocketAddrExt;
            UnixStream::connect_addr(&std::os::unix::net::SocketAddr::from_abstract_name(name)?)
        }
        #[cfg(not(target_os = "linux"))]
        Some(_) => Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "abstract sockets are Linux's",
        )),
        None => UnixStream::connect(sock),
    }
}

/// Key NAME's bytes from the helper.
fn fetch(name: &str) -> Result<Vec<u8>, Fail> {
    let sock = socket();
    let mut s = connect(&sock).map_err(|e| {
        Fail::NotDelivered(format!("the key socket {}: {e}", sock.to_string_lossy()))
    })?;
    let _ = s.set_read_timeout(Some(WAIT));
    s.write_all(format!("get {name}\n").as_bytes())
        .map_err(|e| Fail::NotDelivered(format!("the key socket: {e}")))?;
    let mut r = BufReader::new(s);
    let mut head = String::new();
    r.by_ref()
        .take(512)
        .read_line(&mut head)
        .map_err(|e| Fail::NotDelivered(format!("key {name}: {e}")))?;
    let head = head.trim_end();
    if head == "timeout" {
        return Err(Fail::NotDelivered(format!("key {name} was not delivered")));
    }
    if let Some(why) = head.strip_prefix("no ") {
        return Err(Fail::Other(format!("key {name}: {why}")));
    }
    let len: usize = head
        .strip_prefix("ok ")
        .and_then(|n| n.parse().ok())
        .filter(|n| *n <= MAX_KEY)
        .ok_or_else(|| Fail::NotDelivered(format!("key {name}: no answer")))?;
    let mut v = vec![0; len];
    r.read_exact(&mut v)
        .map_err(|e| Fail::NotDelivered(format!("key {name}: {e}")))?;
    Ok(v)
}

fn fail(f: Fail) -> ExitCode {
    match f {
        Fail::NotDelivered(m) => {
            eprintln!("drgnx-key: {m}");
            ExitCode::from(NOT_DELIVERED)
        }
        Fail::Other(m) => {
            eprintln!("drgnx-key: {m}");
            ExitCode::from(USAGE)
        }
    }
}

fn plain(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b))
}

fn exec(args: &[String]) -> ExitCode {
    let Some(sep) = args.iter().position(|a| a == "--") else {
        return usage();
    };
    let (pairs, cmd) = (&args[..sep], &args[sep + 1..]);
    if cmd.is_empty() {
        return usage();
    }
    let mut vars = Vec::new();
    for p in pairs {
        let Some((name, var)) = p.split_once('=') else {
            return usage();
        };
        if !plain(name) || var.is_empty() || var.contains(['=', '\0']) {
            return usage();
        }
        match fetch(name) {
            Ok(v) if v.contains(&0) => {
                return fail(Fail::Other(format!("key {name}: a NUL in it")));
            }
            Ok(v) => vars.push((var.to_string(), OsString::from_vec(v))),
            Err(f) => return fail(f),
        }
    }
    let e = Command::new(&cmd[0]).args(&cmd[1..]).envs(vars).exec();
    eprintln!("drgnx-key: {}: {e}", cmd[0]);
    ExitCode::from(127)
}

fn get(name: &str) -> ExitCode {
    if !plain(name) {
        return usage();
    }
    match fetch(name) {
        Ok(mut v) => {
            let mut out = io::stdout().lock();
            let r = out.write_all(&v).and_then(|()| out.flush());
            v.fill(0);
            std::hint::black_box(&v);
            match r {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(Fail::Other(format!("stdout: {e}"))),
            }
        }
        Err(f) => fail(f),
    }
}

fn usage() -> ExitCode {
    eprintln!("usage: drgnx-key exec NAME=VAR... -- CMD...\n       drgnx-key get NAME");
    ExitCode::from(USAGE)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("exec") => exec(&args[1..]),
        Some("get") if args.len() == 2 => get(&args[1]),
        _ => usage(),
    }
}
