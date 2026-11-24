//! annall (*annáll*, annals): logging, and the one way to print (docs/develop/standards/logging.md).
//!
//! [`init`] sends `tracing`'s events to a JSON file, `<stig::state()>/log/drgnx.log`, one object per line. Code logs
//! through `tracing`'s macros; an error through [`log_error`] (its kind, sentence, detail and whole source chain, as
//! `Debug`, which `hulda::Secret` redacts); a value that implements `hulda::Redact` through [`redact`]. A command line
//! prints only through [`cli_out`] and [`cli_err`]: `println!` and the rest are denied everywhere else.

use std::io::Write;

/// The log file's name, under `<state>/log/`.
pub const LOG_FILE: &str = "drgnx.log";

/// Where the log's lines go.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Sink {
    /// `<state>/log/drgnx.log`.
    #[default]
    File,
    /// This process's stderr: for a child whose stderr the hub keeps in a log of its own (a terminal worker).
    Stderr,
}

/// How the log is set up.
#[derive(Debug, Clone)]
pub struct LogConfig {
    /// The least severe level written.
    pub level: tracing::Level,
    pub sink: Sink,
}

impl Default for LogConfig {
    fn default() -> LogConfig {
        LogConfig {
            level: tracing::Level::INFO,
            sink: Sink::File,
        }
    }
}

/// Keeps the log's writer thread; dropping it flushes what is queued.
pub struct Guard {
    _worker: tracing_appender::non_blocking::WorkerGuard,
}

/// Logging to `<state>/log/drgnx.log` (or stderr, by `cfg.sink`), for the rest of the process. A second call is a [`villa::Kind::Conflict`].
pub fn init(cfg: LogConfig) -> villa::Result<Guard> {
    let (writer, worker) = match cfg.sink {
        Sink::File => {
            let dir = stig::state().join("log");
            std::fs::create_dir_all(&dir).map_err(|e| {
                villa::Error::from(e)
                    .with_detail(format!("creating the log folder {}", dir.display()))
            })?;
            tracing_appender::non_blocking(tracing_appender::rolling::never(&dir, LOG_FILE))
        }
        Sink::Stderr => tracing_appender::non_blocking(std::io::stderr()),
    };
    let subscriber = tracing_subscriber::fmt()
        .json()
        .with_max_level(cfg.level)
        .with_writer(writer)
        .finish();
    tracing::subscriber::set_global_default(subscriber)
        .map_err(|e| villa::Error::conflict("Logging is already set up.").with_source(e))?;
    Ok(Guard { _worker: worker })
}

/// One error event for E: its kind, its sentence, and everything `Debug` shows (detail and source chain).
pub fn log_error(e: &villa::Error) {
    tracing::error!(kind = e.kind().wire(), error = ?e, "{e}");
}

/// A field value for a `tracing` event that prints V's redacted form: `tracing::info!(token = annall::redact(&t))`.
pub fn redact<T: hulda::Redact + ?Sized>(v: &T) -> tracing::field::DisplayValue<String> {
    tracing::field::display(v.redacted())
}

/// LINE and a newline on stdout: a command's output.
pub fn cli_out(line: &str) -> villa::Result<()> {
    writeln!(std::io::stdout().lock(), "{line}").map_err(villa::Error::from)
}

/// LINE and a newline on stderr: a command's diagnostics.
pub fn cli_err(line: &str) -> villa::Result<()> {
    writeln!(std::io::stderr().lock(), "{line}").map_err(villa::Error::from)
}
