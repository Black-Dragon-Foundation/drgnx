//! One line on stderr from a process that has no log of its own: the sandbox's helpers (the inner process, the relay,
//! the trace wrapper), which tell their parent what went wrong the only way they can.

/// LINE and a newline on stderr. A stderr that cannot be written leaves nobody to tell, so that is only logged.
pub(crate) fn say(line: &str) {
    if let Err(e) = annall::cli_err(line) {
        tracing::debug!(error = %e, "stderr could not be written");
    }
}
