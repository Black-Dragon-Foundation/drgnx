//! Adopting the workers a hub before this one left running (docs/develop/terminal.md, "Lifetime"): each record in
//! `<state>/term/` names a worker by its scope, or its pid and start time; a live one is connected to again, and its
//! hello says whether this hub speaks its protocol. A dead one's record and socket go.

use drgnx_term::proto::{Out, PROTO};
use drgnx_term::registry::Record;
use std::io;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

/// What a worker said when connected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hello {
    pub proto: (u32, u32),
    pub pid: u32,
    pub shell_pid: u32,
}

impl Hello {
    /// A worker of another major protocol is "from before the update": its program keeps running, nothing is sent to
    /// it but `close`.
    pub fn old(&self) -> bool {
        self.proto.0 != PROTO.0
    }
}

/// Whether the worker REC names still runs: its scope is active (with a user systemd), else its pid is the process
/// that started at its start time (a reused pid is not).
pub fn alive(rec: &Record) -> bool {
    if let Some(unit) = &rec.unit
        && crate::exec::unit::systemd_user()
        && let Ok(s) = std::process::Command::new("systemctl")
            .args(["--user", "is-active", "--quiet", &scope_unit(unit)])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
        && !s.success()
    {
        return false;
    }
    crate::exec::unit::same_process(rec.pid, rec.start_time)
}

/// The scope's full unit name (`systemctl` reads a bare name as a `.service`).
fn scope_unit(unit: &str) -> String {
    if unit.ends_with(".scope") {
        unit.to_owned()
    } else {
        format!("{unit}.scope")
    }
}

/// A connection to the worker on SOCKET and its hello (read within WITHIN).
pub async fn connect(
    socket: &std::path::Path,
    within: Duration,
) -> io::Result<(BufReader<OwnedReadHalf>, OwnedWriteHalf, Hello)> {
    hello(UnixStream::connect(socket).await?, within).await
}

/// A connection to the worker just started on SOCKET, tried every 20 ms until it binds, for at most BIND_WITHIN of real
/// time, and its hello (read within WITHIN).  The worker is a process outside the hub, and `term/open` waits for it
/// inside its serving step, under which the test clock stands still: the retries cannot wait on the hub's clock.
pub async fn connect_started(
    socket: &std::path::Path,
    bind_within: Duration,
    within: Duration,
) -> io::Result<(BufReader<OwnedReadHalf>, OwnedWriteHalf, Hello)> {
    let path = socket.to_owned();
    let s = crate::clock::blocking(move || {
        let deadline = crate::clock::real_now() + bind_within;
        loop {
            match std::os::unix::net::UnixStream::connect(&path) {
                Ok(s) => return Ok(s),
                Err(e) if crate::clock::real_now() >= deadline => return Err(e),
                Err(_) => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    })
    .await
    .map_err(io::Error::other)??;
    s.set_nonblocking(true)?;
    hello(UnixStream::from_std(s)?, within).await
}

/// The hello the worker on S says first, read within WITHIN.
async fn hello(
    s: UnixStream,
    within: Duration,
) -> io::Result<(BufReader<OwnedReadHalf>, OwnedWriteHalf, Hello)> {
    let (r, w) = s.into_split();
    let mut r = BufReader::new(r);
    let mut line = String::new();
    crate::clock::timeout(within, r.read_line(&mut line))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "no hello from the worker"))??;
    match serde_json::from_str::<Out>(&line) {
        Ok(Out::Hello {
            proto,
            pid,
            shell_pid,
        }) => Ok((
            r,
            w,
            Hello {
                proto,
                pid,
                shell_pid,
            },
        )),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the worker's first line is not a hello",
        )),
    }
}
