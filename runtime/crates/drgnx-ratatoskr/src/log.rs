//! Logging (design 11): tracing as JSON lines to `<state>/hub/log/hub-YYYY-MM-DD.jsonl` (UTC days, 0600, the newest 7
//! kept), written by tracing-appender's non-blocking worker; warnings and errors also to stderr, with `<4>` / `<3>`
//! priority prefixes when `JOURNAL_STREAM` says stderr is the journal, through a worker of their own too (a stderr that
//! does not drain holds no hub thread; lines a full queue drops are counted and told, [`to_stderr`]).  The level comes from `DRGNX_RATATOSKR_LOG` (a
//! `Targets` string such as `info` or `warn,drgnx_ratatoskr::conn=debug`; default `info`).  Never logged: the cap,
//! keys, params.

use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// How many daily files are kept.
pub const KEEP: usize = 7;

/// Flushes the log when dropped (at the end of `serve`): the lines stderr dropped are told first, then both queues
/// are written out.
pub struct Guard {
    stderr: ToStderr,
    _stderr_flush: Flush,
    _file: tracing_appender::non_blocking::WorkerGuard,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.stderr.send(None, b"");
    }
}

/// Start logging into DIR (made 0700 by the caller).
pub fn init(dir: &Path) -> io::Result<Guard> {
    use tracing_subscriber::Layer;
    use tracing_subscriber::filter::{LevelFilter, Targets};
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    let (file, guard) = tracing_appender::non_blocking(Daily::open(dir)?);
    let level = std::env::var("DRGNX_RATATOSKR_LOG").unwrap_or_default();
    let targets = if level.is_empty() {
        Targets::new().with_default(LevelFilter::INFO)
    } else {
        level.parse::<Targets>().map_err(|e| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("DRGNX_RATATOSKR_LOG={level:?}: {e}"),
            )
        })?
    };
    let journal = std::env::var_os("JOURNAL_STREAM").is_some();
    let (stderr, stderr_flush) = to_stderr(io::stderr(), journal, STDERR_LINES);
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_writer(file)
                .with_filter(targets),
        )
        .with(stderr_layer(stderr.clone()))
        .try_init()
        .map_err(|e| io::Error::other(format!("cannot start logging: {e}")))?;
    Ok(Guard {
        stderr,
        _stderr_flush: stderr_flush,
        _file: guard,
    })
}

/// The UTC day of SECS since the epoch, as `YYYY-MM-DD` (H. Hinnant's `civil_from_days`).
pub fn day(secs: u64) -> String {
    let z = (secs / 86_400) as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

/// SECS since the epoch as RFC 3339 in UTC: `YYYY-MM-DDTHH:MM:SSZ` (`status`'s `started`, a refusal's `at`).
pub fn rfc3339(secs: u64) -> String {
    let s = secs % 86_400;
    format!(
        "{}T{:02}:{:02}:{:02}Z",
        day(secs),
        s / 3600,
        s / 60 % 60,
        s % 60
    )
}

fn today() -> String {
    let secs = crate::clock::wall()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    day(secs)
}

/// How many lines stderr's queue holds before it drops (and counts) them.
const STDERR_LINES: usize = 4096;

/// What a [`ToStderr`]'s queue flushes when dropped.
type Flush = tracing_appender::non_blocking::WorkerGuard;

/// W as the stderr of warnings and errors, each event behind a journal priority (`<3>` error, `<4>` warning) when
/// JOURNAL says it is the journal.  Written by tracing-appender's own thread: a stderr that does not drain (a pipe
/// its reader left full, a file on a disk that waits) holds no hub thread.  The queue holds LINES; a full one drops
/// lines, counted, and the next line that finds room says how many first ("N log lines dropped"), as does the hub's
/// end ([`Guard`]), so a loss is never silent.
fn to_stderr(w: impl Write + Send + 'static, journal: bool, lines: usize) -> (ToStderr, Flush) {
    let (to, flush) = tracing_appender::non_blocking::NonBlockingBuilder::default()
        .lossy(true)
        .buffered_lines_limit(lines)
        .thread_name("ratatoskr-stderr")
        .finish(w);
    let dropped = to.error_counter();
    (
        ToStderr {
            journal,
            to,
            dropped,
            told: std::sync::Arc::default(),
        },
        flush,
    )
}

/// See [`to_stderr`].
#[derive(Clone)]
struct ToStderr {
    journal: bool,
    to: tracing_appender::non_blocking::NonBlocking,
    dropped: tracing_appender::non_blocking::ErrorCounter,
    /// Of the lines dropped, the ones told.
    told: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl ToStderr {
    /// Lines the queue could not take.
    #[cfg(test)]
    fn dropped(&self) -> usize {
        self.dropped.dropped_lines()
    }

    /// Of those, the ones told.
    #[cfg(test)]
    fn told(&self) -> usize {
        self.told.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// BUF behind PREFIX, with the count of the lines dropped since the last told ahead of it (nothing when both are
    /// empty).  A notice the queue drops too is told again with the next line.
    fn send(&self, prefix: Option<&'static str>, buf: &[u8]) {
        use std::sync::atomic::Ordering::SeqCst;
        let (dropped, told) = (self.dropped.dropped_lines(), self.told.load(SeqCst));
        let telling = dropped > told
            && self
                .told
                .compare_exchange(told, dropped, SeqCst, SeqCst)
                .is_ok();
        let mut line = Vec::with_capacity(buf.len() + 64);
        if telling {
            if self.journal {
                line.extend_from_slice(b"<4>");
            }
            line.extend_from_slice(
                format!(
                    "ratatoskr: {} log lines dropped (stderr was full)\n",
                    dropped - told
                )
                .as_bytes(),
            );
        }
        if !buf.is_empty() {
            line.extend_from_slice(prefix.unwrap_or_default().as_bytes());
            line.extend_from_slice(buf);
        }
        if line.is_empty() {
            return;
        }
        let _ = self.to.clone().write_all(&line);
        if telling && self.dropped.dropped_lines() > dropped {
            self.told.fetch_sub(dropped - told, SeqCst);
        }
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for ToStderr {
    type Writer = Prefixed;

    fn make_writer(&'a self) -> Prefixed {
        Prefixed(None, self.clone())
    }

    fn make_writer_for(&'a self, meta: &tracing::Metadata<'_>) -> Prefixed {
        let prefix = self.journal.then(|| {
            if *meta.level() == tracing::Level::ERROR {
                "<3>"
            } else {
                "<4>"
            }
        });
        Prefixed(prefix, self.clone())
    }
}

/// One event's writer: its priority, then the event.
struct Prefixed(Option<&'static str>, ToStderr);

impl Write for Prefixed {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.1.send(self.0.take(), buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// stderr's layer: warnings and errors, without times or targets.
fn stderr_layer<S>(to: ToStderr) -> impl tracing_subscriber::Layer<S>
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    use tracing_subscriber::Layer;
    tracing_subscriber::fmt::layer()
        .with_ansi(false)
        .without_time()
        .with_target(false)
        .with_writer(to)
        .with_filter(tracing_subscriber::filter::LevelFilter::WARN)
}

/// The daily file writer.
struct Daily {
    dir: PathBuf,
    day: String,
    file: File,
}

impl Daily {
    /// Today's file opened now, so a log that cannot be written stops the start.
    fn open(dir: &Path) -> io::Result<Daily> {
        let day = today();
        let file = open_day(dir, &day)?;
        prune(dir);
        Ok(Daily {
            dir: dir.to_path_buf(),
            day,
            file,
        })
    }
}

fn open_day(dir: &Path, day: &str) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(dir.join(format!("hub-{day}.jsonl")))
}

/// Keep the newest [`KEEP`] `hub-YYYY-MM-DD.jsonl` (their names sort by day).
fn prune(dir: &Path) {
    let mut logs: Vec<PathBuf> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            let n = e.file_name();
            let n = n.to_string_lossy();
            n.len() == "hub-YYYY-MM-DD.jsonl".len()
                && n.starts_with("hub-")
                && n.ends_with(".jsonl")
        })
        .map(|e| e.path())
        .collect();
    logs.sort();
    let extra = logs.len().saturating_sub(KEEP);
    for old in &logs[..extra] {
        let _ = std::fs::remove_file(old);
    }
}

impl Write for Daily {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let day = today();
        if day != self.day {
            // a file that cannot be opened keeps the old one in use rather than losing the line
            if let Ok(f) = open_day(&self.dir, &day) {
                self.file = f;
                self.day = day;
                prune(&self.dir);
            }
        }
        self.file.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

#[cfg(test)]
#[path = "log_tests.rs"]
mod stderr_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_days() {
        assert_eq!(day(0), "1970-01-01");
        assert_eq!(day(86_399), "1970-01-01");
        assert_eq!(day(86_400), "1970-01-02");
        assert_eq!(day(11_017 * 86_400), "2000-03-01");
        assert_eq!(day(19_782 * 86_400 + 3_600), "2024-02-29");
        assert_eq!(day(19_783 * 86_400), "2024-03-01");
    }

    #[test]
    fn rfc3339_times() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(19_782 * 86_400 + 3_661), "2024-02-29T01:01:01Z");
        assert_eq!(rfc3339(86_399), "1970-01-01T23:59:59Z");
    }

    #[test]
    fn daily_files_are_0600_and_seven_are_kept() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        for d in 1..=9 {
            std::fs::write(dir.path().join(format!("hub-2020-01-0{d}.jsonl")), "old\n").unwrap();
        }
        std::fs::write(dir.path().join("other.txt"), "kept").unwrap();
        let mut w = Daily::open(dir.path()).unwrap();
        w.write_all(b"{\"a\":1}\n").unwrap();
        w.flush().unwrap();
        let today = dir.path().join(format!("hub-{}.jsonl", w.day));
        assert_eq!(std::fs::read_to_string(&today).unwrap(), "{\"a\":1}\n");
        assert_eq!(
            std::fs::metadata(&today).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let mut logs: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with("hub-"))
            .collect();
        logs.sort();
        assert_eq!(logs.len(), KEEP, "{logs:?}");
        assert_eq!(logs[0], "hub-2020-01-04.jsonl", "the oldest went first");
        assert!(
            dir.path().join("other.txt").exists(),
            "only hub-*.jsonl are pruned"
        );
    }
}
