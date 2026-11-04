//! `env/set`: the variables an editor read from the user's login shell (PATH above all), kept in the hub's memory as an
//! overlay on its own environment.  A hub started by systemd or launchd has a bare PATH, so what it starts next (agent
//! sessions, jobs, git, podman) takes its base environment from [`ShellEnv::vars_os`], never from the process's own.
//! The process environment itself is never changed (`std::env::set_var` is not called).  The overlay is in memory only:
//! the editor sends it again whenever it connects.

use runstav::methods::hub::{DIR_LISTS, refused_env_name};
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::sync::{Arc, RwLock};

/// The names the hub's own path rules read (`runstav::paths`, `sandbox::context`: its state, data and config
/// folders, socket, scratch and session folders, what is closed to a sandbox and what is the user's): `env/set` never
/// takes them, so the login shell's overlay only reaches what children inherit (their `PATH` and the like), never where
/// the hub keeps its sockets and scratch folders.  `PATH` is not here: the sandbox's program folders read it, on purpose.
pub const PATH_RULE_NAMES: [&str; 13] = [
    "HOME",
    "TMPDIR",
    "TMP",
    "TEMP",
    "XDG_RUNTIME_DIR",
    "XDG_DATA_HOME",
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "DRGNX_DATA_DIR",
    "DRGNX_CONFIG_DIR",
    "DRGNX_DIR",
    "SSH_AUTH_SOCK",
    "DBUS_SESSION_BUS_ADDRESS",
];

/// The overlay.  A clone shares it.
#[derive(Clone, Debug, Default)]
pub struct ShellEnv {
    overlay: Arc<RwLock<BTreeMap<String, String>>>,
}

impl ShellEnv {
    /// Apply VARS and answer the names applied.  A name that looks like a secret, that one of the hub's path rules
    /// reads ([`PATH_RULE_NAMES`]), or that is a provider's key variable (KEY_ENVS), is left out; it is never an error.  A directory list (`PATH`, …) is the shell's directories, then the
    /// hub's own that the shell's do not name.
    pub fn set(&self, vars: Vec<(String, String)>, key_envs: &[String]) -> Vec<String> {
        let mut applied = Vec::new();
        let mut overlay = self.overlay.write().expect("shell env");
        for (name, value) in vars {
            if refused_env_name(&name)
                || PATH_RULE_NAMES.contains(&name.as_str())
                || key_envs.contains(&name)
                || applied.contains(&name)
            {
                continue;
            }
            let value = if DIR_LISTS.contains(&name.as_str()) {
                merge_dirs(&value, std::env::var(&name).ok().as_deref())
            } else {
                value
            };
            overlay.insert(name.clone(), value);
            applied.push(name);
        }
        applied
    }

    /// The process environment with the overlay applied: an overlaid name replaces the process's value, the others keep
    /// it.  For `draugr::env::build_from`.
    pub fn vars_os(&self) -> Vec<(OsString, OsString)> {
        let overlay = self.overlay.read().expect("shell env");
        let mut out: Vec<(OsString, OsString)> = std::env::vars_os()
            .filter(|(k, _)| !k.to_str().is_some_and(|k| overlay.contains_key(k)))
            .collect();
        out.extend(overlay.iter().map(|(k, v)| (k.into(), v.into())));
        out
    }

    /// The overlay alone, for a command that inherits the process environment and only needs these changed.
    pub fn overlay(&self) -> Vec<(String, String)> {
        let overlay = self.overlay.read().expect("shell env");
        overlay
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    /// NAME's value: the overlay's, else the process's.
    pub fn var_os(&self, name: &str) -> Option<OsString> {
        match self.overlay.read().expect("shell env").get(name) {
            Some(v) => Some(v.into()),
            None => std::env::var_os(name),
        }
    }

    /// The same as the hub's `Env` (the paths rule and the sandbox's context read it), with the overlay applied.
    pub fn paths_env(&self) -> runstav::paths::Env {
        let mut env = runstav::paths::Env::process();
        for (k, v) in self.overlay.read().expect("shell env").iter() {
            env.vars.insert(k.clone(), v.clone());
        }
        env
    }

    /// The base for `draugr::env::build_from`'s `allow` list: see [`ShellEnv::vars_os`].
    pub fn build(
        &self,
        allow: &[&str],
        allow_prefixes: &[&str],
        set: &[(&str, &OsStr)],
    ) -> Vec<(OsString, OsString)> {
        draugr::env::build_from(self.vars_os(), allow, allow_prefixes, set)
    }
}

/// VALUE's directories, then the ones of OLD (the hub's own) that VALUE does not have; empty entries dropped.
fn merge_dirs(value: &str, old: Option<&str>) -> String {
    let mut dirs: Vec<&str> = Vec::new();
    for d in value.split(':').chain(old.unwrap_or("").split(':')) {
        if !d.is_empty() && !dirs.contains(&d) {
            dirs.push(d);
        }
    }
    dirs.join(":")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair(k: &str, v: &str) -> (String, String) {
        (k.into(), v.into())
    }

    fn get(env: &ShellEnv, name: &str) -> Option<OsString> {
        env.vars_os()
            .into_iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v)
    }

    #[test]
    fn overlay_wins_over_process_env() {
        let env = ShellEnv::default();
        let applied = env.set(
            vec![
                pair("PATH", "/opt/x/bin:/usr/bin"),
                pair("DRGNX_SHELL_ENV_TEST_A", "a"),
            ],
            &[],
        );
        assert_eq!(applied, ["PATH", "DRGNX_SHELL_ENV_TEST_A"]);
        let path = get(&env, "PATH").unwrap();
        let path = path.to_str().unwrap();
        assert!(path.starts_with("/opt/x/bin:/usr/bin"), "{path}");
        assert_eq!(get(&env, "DRGNX_SHELL_ENV_TEST_A").unwrap(), "a");
        // once each: the process's own PATH is not also in the list
        assert_eq!(env.vars_os().iter().filter(|(k, _)| k == "PATH").count(), 1);
        // a repeat is the same: the overlay is not built on its own last answer
        env.set(vec![pair("PATH", "/opt/x/bin:/usr/bin")], &[]);
        assert_eq!(get(&env, "PATH").unwrap().to_str().unwrap(), path);
        // the process itself is untouched
        assert!(std::env::var_os("DRGNX_SHELL_ENV_TEST_A").is_none());
    }

    #[test]
    fn unset_names_keep_process_value() {
        let env = ShellEnv::default();
        env.set(vec![pair("DRGNX_SHELL_ENV_TEST_B", "b")], &[]);
        for (k, v) in std::env::vars_os() {
            assert_eq!(get(&env, k.to_str().unwrap()), Some(v));
        }
        assert_eq!(env.var_os("HOME"), std::env::var_os("HOME"));
        assert_eq!(env.var_os("DRGNX_SHELL_ENV_TEST_B").unwrap(), "b");
    }

    #[test]
    fn the_names_the_paths_rules_read_are_refused() {
        let env = ShellEnv::default();
        let mut vars: Vec<(String, String)> = PATH_RULE_NAMES
            .iter()
            .map(|n| pair(n, "/elsewhere"))
            .collect();
        for n in [
            "TMPDIR",
            "TMP",
            "TEMP",
            "XDG_RUNTIME_DIR",
            "XDG_DATA_HOME",
            "XDG_CONFIG_HOME",
            "XDG_STATE_HOME",
            "DRGNX_DATA_DIR",
            "DRGNX_CONFIG_DIR",
            "DRGNX_DIR",
            "SSH_AUTH_SOCK",
            "DBUS_SESSION_BUS_ADDRESS",
            "HOME",
        ] {
            assert!(PATH_RULE_NAMES.contains(&n), "{n} is not refused");
        }
        vars.push(pair("PATH", "/opt/x/bin"));
        vars.push(pair("DRGNX_SHELL_ENV_TEST_C", "c"));
        // left out of the answer, never an error, and never in what the hub computes its own paths from
        assert_eq!(env.set(vars, &[]), ["PATH", "DRGNX_SHELL_ENV_TEST_C"]);
        let paths = env.paths_env();
        for n in PATH_RULE_NAMES {
            assert_eq!(paths.vars.get(n), std::env::var(n).ok().as_ref(), "{n}");
            assert_ne!(get(&env, n), Some(OsString::from("/elsewhere")), "{n}");
        }
        assert!(paths.vars.get("PATH").unwrap().starts_with("/opt/x/bin"));
    }

    #[test]
    fn applied_lists_only_allowed() {
        let env = ShellEnv::default();
        let applied = env.set(
            vec![
                pair("OPENAI_API_KEY", "k"),
                pair("gh_token", "t"),
                pair("MY_PASSPHRASE", "p"),
                pair("ACME_ACCESS", "v"),
                pair("MANPATH", "/usr/share/man"),
            ],
            &["ACME_ACCESS".to_string()],
        );
        assert_eq!(applied, ["MANPATH"]);
        assert!(get(&env, "OPENAI_API_KEY").is_none());
        assert!(get(&env, "gh_token").is_none());
        assert!(get(&env, "ACME_ACCESS").is_none());
    }
}
