//! Results the hub means to go on past: a best-effort cleanup, a note for a human, a line to a terminal that may be gone.
//! Each is logged at debug with what it was, so a failure is never silent (docs/develop/standards/errors.md).

/// Whether R succeeded; a failure is logged at debug as WHAT that failed (the error's type is any: a closed channel's
/// carries the message it could not send, which has no business in a log).
pub fn done<T, E>(r: Result<T, E>, what: &str) -> bool {
    let ok = r.is_ok();
    if !ok {
        tracing::debug!(what, "went on past a failure");
    }
    ok
}

/// LINE and a newline on stderr (a command's diagnostics); a stderr that is gone is logged and ignored.
pub fn err_line(line: &str) {
    done(annall::cli_err(line), "a line to stderr");
}

/// LINE and a newline on stdout (a command's output); a stdout that is gone is logged and ignored.
pub fn out_line(line: &str) {
    done(annall::cli_out(line), "a line to stdout");
}

/// TEXT on stdout as it is (no newline added), flushed; a stdout that is gone is logged and ignored.
pub fn out_text(text: &str) {
    use std::io::Write;
    let mut out = annall::raw_out();
    done(
        out.write_all(text.as_bytes()).and_then(|()| out.flush()),
        "text to stdout",
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn done_says_whether_the_result_was_ok() {
        assert!(done(Ok::<_, String>(1), "a sum"));
        assert!(!done(Err::<(), _>("no".to_string()), "a failure"));
    }
}
