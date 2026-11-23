//! An environment as a value: the variables a path rule reads and the uid it runs as, so a rule is tested against any
//! environment and never against this process's. [`Env::process`] is the one reader of the real one.

use std::collections::BTreeMap;

use crate::HOME_VAR;

/// The XDG base directories (`XDG_*_HOME`, `XDG_RUNTIME_DIR`), each with its variable's name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Xdg {
    Data,
    Config,
    State,
    Cache,
    Runtime,
}

impl Xdg {
    /// The name of the variable that holds this directory.
    pub const fn var(self) -> &'static str {
        match self {
            Xdg::Data => "XDG_DATA_HOME",
            Xdg::Config => "XDG_CONFIG_HOME",
            Xdg::State => "XDG_STATE_HOME",
            Xdg::Cache => "XDG_CACHE_HOME",
            Xdg::Runtime => crate::SYSTEM_RUNTIME_VAR,
        }
    }
}

/// The environment a path rule sees (only the variables the rule reads matter) and the uid it runs as.
#[derive(Clone, Debug, Default)]
pub struct Env {
    pub vars: BTreeMap<String, String>,
    pub uid: u32,
}

impl Env {
    pub fn new(vars: &[(&str, &str)], uid: u32) -> Env {
        Env {
            vars: vars
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            uid,
        }
    }

    /// This process's own environment and effective uid.
    pub fn process() -> Env {
        Env {
            vars: std::env::vars_os()
                .map(|(k, v)| {
                    (
                        k.to_string_lossy().into_owned(),
                        v.to_string_lossy().into_owned(),
                    )
                })
                .collect(),
            uid: rustix::process::geteuid().as_raw(),
        }
    }

    /// The variable NAME's value, set or not.
    pub fn get(&self, name: &str) -> Option<&str> {
        self.vars.get(name).map(String::as_str)
    }

    /// The value of NAME when it begins with "/", else nothing (unset, empty, relative and "~/..." all mean the
    /// default).
    pub fn absolute(&self, name: &str) -> Option<&str> {
        self.get(name).filter(|v| v.starts_with('/'))
    }

    /// `HOME`, as it is set (absolute or not).
    pub fn home(&self) -> Option<&str> {
        self.get(HOME_VAR)
    }

    /// The absolute value of the XDG variable for WHICH.
    pub fn xdg(&self, which: Xdg) -> Option<&str> {
        self.absolute(which.var())
    }
}
