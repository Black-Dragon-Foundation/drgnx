//! Runners: other machines that run the hub's jobs (docs/develop/hub.md, "Runners: the transport").
//!
//! - [`ssh_config`]: the ssh config the hub writes for each runner: the forced options first, then the user's own.
//! - [`transport`]: how the hub reaches a runner: [`transport::Transport`], one OpenSSH master per runner, at most
//!   three sessions, a real round trip for health, redial with backoff, logins classified and never answered.
//! - [`link`]: a runner's link session over those sessions: frames, pings, a lost link, logs at the hub's offset.
//! - [`attempts`]: the attempt state machine (nonces, `detached`, grace, reattach, requeue, late results), pure.
//! - [`sync`]: a job's inputs frozen at submit, its trust from what the public origin has, and how its code reaches
//!   a runner (origin, bundle or push; the overlay a runner may get).

use std::path::{Path, PathBuf};
use std::time::Duration;

pub mod attempts;
pub mod health;
pub mod link;
pub mod local;
pub mod methods;
pub mod queue;
#[cfg(all(unix, not(target_os = "android")))]
pub mod registry;
pub mod ssh_config;
pub mod sync;
pub mod transport;

/// The longest runner name: it names the runner's folder under `$XDG_RUNTIME_DIR/drgnx-runners/`, which holds the
/// master's socket, and a socket's path has at most 108 bytes.
pub const NAME_MAX: usize = 32;

/// How the hub reaches one runner, built from its registry record. [`RunnerCfg::check`] passes before anything is
/// written or started for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunnerCfg {
    /// The registry's name: ASCII letters, digits, `_` and `-`, not starting with `-`, at most [`NAME_MAX`] bytes.
    pub name: String,
    /// The host as the user's ssh knows it (`ssh <host>`), or a cloud machine's address.
    pub host: String,
    /// Whether the runner's user lingers: it sets an attempt's grace ([`RunnerCfg::grace`]).
    pub linger: bool,
    /// A cloud machine's own agent, certificate and pinned host key. `None` for an SSH runner, which is reached
    /// through the user's own ssh config.
    pub cloud: Option<CloudSsh>,
    /// What each of the three sessions runs on the runner.
    pub remote: Remote,
}

/// The lines a cloud runner's ssh config adds: the hub's private agent, the machine's short-lived certificate and its
/// pinned host key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CloudSsh {
    pub identity_agent: PathBuf,
    pub certificate: PathBuf,
    pub known_hosts: PathBuf,
}

/// The argv of each session. The runner's login shell runs it, every word quoted, so nothing in it is expanded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Remote {
    pub control: Vec<String>,
    pub bulk_in: Vec<String>,
    pub bulk_out: Vec<String>,
}

impl RunnerCfg {
    /// An attempt's grace on this runner: 600 s when its user lingers (its jobs outlive the link), 0 without.
    pub fn grace(&self) -> Duration {
        Duration::from_secs(if self.linger { 600 } else { 0 })
    }

    /// Refuses a config that could reach ssh as anything but a value: a host or name that reads as an option or
    /// holds a space, a path ssh would expand or that would break its line, an empty argv.
    pub fn check(&self) -> Result<(), String> {
        let n = &self.name;
        let name_ok = !n.is_empty()
            && n.len() <= NAME_MAX
            && !n.starts_with('-')
            && n.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
        if !name_ok {
            return Err(format!(
                "the runner name {n:?} must be 1 to {NAME_MAX} letters, digits, `_` or `-`, not starting with `-`"
            ));
        }
        let h = &self.host;
        if h.is_empty()
            || h.len() > 255
            || h.starts_with('-')
            || h.chars().any(|c| c.is_whitespace() || c.is_control())
        {
            return Err(format!(
                "the host {h:?} must be a host as ssh knows it: no spaces, not starting with `-`"
            ));
        }
        if let Some(c) = &self.cloud {
            for p in [&c.identity_agent, &c.certificate, &c.known_hosts] {
                config_path(p)?;
            }
        }
        for (what, argv) in [
            ("control", &self.remote.control),
            ("bulk in", &self.remote.bulk_in),
            ("bulk out", &self.remote.bulk_out),
        ] {
            if argv.is_empty() || argv.iter().any(|w| w.contains('\0')) {
                return Err(format!(
                    "the {what} session's argv must be non-empty, without NUL bytes"
                ));
            }
        }
        Ok(())
    }
}

/// A path the generated config may hold: absolute, UTF-8, with no `"` (it is written quoted), no `%` (ssh would
/// expand it) and no control character (it would end the line).
fn config_path(p: &Path) -> Result<&str, String> {
    let s = p
        .to_str()
        .filter(|s| p.is_absolute() && !s.contains(['"', '%']) && !s.chars().any(char::is_control));
    s.ok_or_else(|| {
        format!("the path {p:?} must be absolute UTF-8 without `\"`, `%` or control characters")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn ssh_runner(name: &str, host: &str) -> RunnerCfg {
        RunnerCfg {
            name: name.into(),
            host: host.into(),
            linger: true,
            cloud: None,
            remote: Remote {
                control: vec!["sleipnir".into(), "serve".into()],
                bulk_in: vec!["cat".into()],
                bulk_out: vec!["cat".into()],
            },
        }
    }

    // [D] pure
    #[test]
    fn a_host_or_name_that_could_inject_is_refused() {
        assert_eq!(ssh_runner("desktop", "desktop").check(), Ok(()));
        assert_eq!(ssh_runner("r-1_b", "runner@10.0.0.7").check(), Ok(()));
        for host in ["-oProxyCommand=sh", "desk top", "desk\ntop", "", "a\u{7f}b"] {
            let e = ssh_runner("desktop", host).check().unwrap_err();
            assert!(e.contains("host"), "{host:?}: {e}");
        }
        for name in ["", "-x", "a/b", "..", "a b", &"n".repeat(NAME_MAX + 1)] {
            let e = ssh_runner(name, "desktop").check().unwrap_err();
            assert!(e.contains("name"), "{name:?}: {e}");
        }
        let mut r = ssh_runner("c1", "10.0.0.9");
        for bad in [
            "relative/agent.sock",
            "/run/a%h.sock",
            "/run/a\"b",
            "/run/a\nb",
        ] {
            r.cloud = Some(CloudSsh {
                identity_agent: bad.into(),
                certificate: "/run/c.pub".into(),
                known_hosts: "/run/k".into(),
            });
            let e = r.check().unwrap_err();
            assert!(e.contains("path"), "{bad:?}: {e}");
        }
        let mut r = ssh_runner("desktop", "desktop");
        r.remote.bulk_in.clear();
        assert!(r.check().unwrap_err().contains("argv"));
        r.remote.bulk_in = vec!["a\0b".into()];
        assert!(r.check().unwrap_err().contains("argv"));
    }

    // [D] pure
    #[test]
    fn grace_follows_linger() {
        let mut r = ssh_runner("desktop", "desktop");
        assert_eq!(r.grace(), Duration::from_secs(600));
        r.linger = false;
        assert_eq!(r.grace(), Duration::ZERO);
    }
}
