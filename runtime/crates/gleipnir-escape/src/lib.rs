//! The escape harness: rows as data, run against the `ratatoskr` binary with the probe inside (Task 14; docs/develop/
//! gleipnir.md, "Proving it"). Test tooling, never shipped or installed.
//!
//! - [`row`]: the row format and its parse (closed placeholders, a control run for every `blocked`).
//! - [`fixture`]: the fixture under `/tmp/glp-XXXXXX/`, with random canaries and recording listeners.
//! - [`run`]: one row: skip with a listed reason, the control run, the sandboxed run, the comparison.
//! - [`report`]: the report file.
//!
//! This file also holds what the probe and the harness share: the line a probe prints ([`ProbeLine`]) and the errno
//! names it uses.

pub mod fixture;
pub mod report;
pub mod row;
pub mod run;

use serde::{Deserialize, Serialize};

/// A probe run without a sandbox (the control run, an `unsandboxed` row, the probe's own tests) gets 0–2 and nothing
/// the harness inherited: every descriptor from 3 up is closed at the exec. A GitHub Actions step inherits the
/// runner's IPC pipes (Runner.Worker gets them as inheritable handles), which `fds` would list. The sandboxed runs
/// keep whatever `ratatoskr` inherited on purpose: closing it is the sandbox's job (the `fds-closed` rows).
pub fn only_stdio(cmd: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;
    // SAFETY: between the fork and the exec; cloexec_from makes system calls only and allocates nothing.
    unsafe {
        cmd.pre_exec(|| {
            draugr::spawn::cloexec_from(3);
            Ok(())
        });
    }
}

/// The line `gleipnir-probe` prints for each probe. `result` is `reached` or `blocked`; `errno` is a name from
/// [`ERRNOS`] (or `E<number>`); `detail` is the probe's own word (a size, a status code, a pid, a list).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProbeLine {
    pub probe: String,
    pub arg: String,
    pub result: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub errno: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// Only `run`: the bytes its child wrote to stdout and stderr, counted and never printed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out_bytes: Option<u64>,
}

/// The errno names rows may use. `ENOTSUP` is read as `EOPNOTSUPP` (the same number on Linux).
pub const ERRNOS: &[(&str, i32)] = &[
    ("EPERM", libc::EPERM),
    ("ENOENT", libc::ENOENT),
    ("ESRCH", libc::ESRCH),
    ("EINTR", libc::EINTR),
    ("EIO", libc::EIO),
    ("ENXIO", libc::ENXIO),
    ("E2BIG", libc::E2BIG),
    ("ENOEXEC", libc::ENOEXEC),
    ("EBADF", libc::EBADF),
    ("ECHILD", libc::ECHILD),
    ("EAGAIN", libc::EAGAIN),
    ("ENOMEM", libc::ENOMEM),
    ("EACCES", libc::EACCES),
    ("EFAULT", libc::EFAULT),
    ("EBUSY", libc::EBUSY),
    ("EEXIST", libc::EEXIST),
    ("EXDEV", libc::EXDEV),
    ("ENODEV", libc::ENODEV),
    ("ENOTDIR", libc::ENOTDIR),
    ("EISDIR", libc::EISDIR),
    ("EINVAL", libc::EINVAL),
    ("EMFILE", libc::EMFILE),
    ("ENOTTY", libc::ENOTTY),
    ("EROFS", libc::EROFS),
    ("EPIPE", libc::EPIPE),
    ("ENAMETOOLONG", libc::ENAMETOOLONG),
    ("ENOSYS", libc::ENOSYS),
    ("ELOOP", libc::ELOOP),
    ("ENOTSOCK", libc::ENOTSOCK),
    ("EPROTONOSUPPORT", libc::EPROTONOSUPPORT),
    ("EOPNOTSUPP", libc::EOPNOTSUPP),
    ("EAFNOSUPPORT", libc::EAFNOSUPPORT),
    ("EADDRINUSE", libc::EADDRINUSE),
    ("EADDRNOTAVAIL", libc::EADDRNOTAVAIL),
    ("ENETUNREACH", libc::ENETUNREACH),
    ("ECONNRESET", libc::ECONNRESET),
    ("ETIMEDOUT", libc::ETIMEDOUT),
    ("ECONNREFUSED", libc::ECONNREFUSED),
    ("EHOSTUNREACH", libc::EHOSTUNREACH),
];

/// The name of `n` (`E<n>` when [`ERRNOS`] has none).
pub fn errno_name(n: i32) -> String {
    ERRNOS
        .iter()
        .find(|(_, v)| *v == n)
        .map_or_else(|| format!("E{n}"), |(name, _)| (*name).to_string())
}

/// The number of an errno name (or `E<n>`, or a plain number).
pub fn errno_from_name(s: &str) -> Option<i32> {
    if s == "ENOTSUP" {
        return Some(libc::EOPNOTSUPP);
    }
    if let Some((_, v)) = ERRNOS.iter().find(|(name, _)| *name == s) {
        return Some(*v);
    }
    s.strip_prefix('E').unwrap_or(s).parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errno_names_round_trip() {
        for (name, n) in ERRNOS {
            assert_eq!(errno_from_name(name), Some(*n));
            assert_eq!(errno_from_name(&errno_name(*n)), Some(*n));
        }
        assert_eq!(errno_name(9999), "E9999");
        assert_eq!(errno_from_name("E9999"), Some(9999));
        assert_eq!(errno_from_name("ENOTSUP"), Some(libc::EOPNOTSUPP));
        assert_eq!(errno_from_name("EBOGUS"), None);
    }
}
