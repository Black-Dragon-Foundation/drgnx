//! The runner's lines on stderr (its diagnostics) and stdout (a mode's answer), through `annall`.
//!
//! A line that cannot be written has nobody left to tell (the pipe is closed), so the result is dropped here, once.

/// LINE and a newline on stderr.
pub fn err(line: &str) {
    drop(annall::cli_err(line));
}

/// LINE and a newline on stdout.
pub fn out(line: &str) {
    drop(annall::cli_out(line));
}

/// `eline!("…{x}")`: a formatted line on stderr.
#[macro_export]
macro_rules! eline {
    ($($arg:tt)*) => { $crate::say::err(&format!($($arg)*)) };
}

/// `oline!("…{x}")`: a formatted line on stdout.
#[macro_export]
macro_rules! oline {
    ($($arg:tt)*) => { $crate::say::out(&format!($($arg)*)) };
}
