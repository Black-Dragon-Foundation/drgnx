//! stig (*stígr*, a path): the editor's directories (docs/develop/standards/paths.md).
//!
//! [`config`], [`state`], [`cache`], [`data`] and [`runtime`] come from XDG (`XDG_CONFIG_HOME` …, else under `HOME`),
//! each ending in `drgnx`, plus the profile as a subfolder when it is not the default: `DRGNX_PROFILE=dev` gives
//! `~/.config/drgnx/dev`, so a dev build never touches the user's own files. A test calls [`init_for_test`] (raun's
//! sandbox does) and every directory is under its temp root, with the `test` profile.
//!
//! This crate owns the `paths` standard: nothing else reads `HOME` or an `XDG_` variable.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};

/// Which install's files: the user's (`default`), a development build's (`dev`) or a test's (`test`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Profile {
    Default,
    Dev,
    Test,
}

impl Profile {
    fn subfolder(self) -> Option<&'static str> {
        match self {
            Profile::Default => None,
            Profile::Dev => Some("dev"),
            Profile::Test => Some("test"),
        }
    }
}

/// The resolved directories.
#[derive(Debug, Clone)]
pub struct Dirs {
    pub profile: Profile,
    pub config: PathBuf,
    pub state: PathBuf,
    pub cache: PathBuf,
    pub data: PathBuf,
    pub runtime: PathBuf,
}

impl Dirs {
    /// The directories from the environment LOOKUP gives (this process's, for [`config`] and the rest). A relative XDG
    /// value is ignored (the XDG spec). An unknown `DRGNX_PROFILE` is refused rather than read as the default.
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<OsString>) -> villa::Result<Dirs> {
        let profile = match lookup("DRGNX_PROFILE").as_ref().and_then(|v| v.to_str()) {
            None | Some("" | "default") => Profile::Default,
            Some("dev") => Profile::Dev,
            Some("test") => Profile::Test,
            Some(other) => {
                return Err(villa::Error::invalid(format!(
                    "DRGNX_PROFILE is `{other}`: it must be default, dev or test."
                )));
            }
        };
        let absolute = |var: &str| lookup(var).map(PathBuf::from).filter(|p| p.is_absolute());
        let home = absolute("HOME");
        let base = |var: &str, under_home: &str| -> villa::Result<PathBuf> {
            absolute(var)
                .or_else(|| home.as_ref().map(|h| h.join(under_home)))
                .ok_or_else(|| {
                    villa::Error::unavailable(
                        "The editor's folders can't be found: neither HOME nor XDG is set.",
                    )
                    .with_detail(format!("{var} and HOME are unset or relative"))
                })
        };
        let finish = |p: PathBuf| {
            let p = p.join("drgnx");
            match profile.subfolder() {
                Some(s) => p.join(s),
                None => p,
            }
        };
        let state = base("XDG_STATE_HOME", ".local/state")?;
        Ok(Dirs {
            profile,
            config: finish(base("XDG_CONFIG_HOME", ".config")?),
            cache: finish(base("XDG_CACHE_HOME", ".cache")?),
            data: finish(base("XDG_DATA_HOME", ".local/share")?),
            runtime: finish(absolute("XDG_RUNTIME_DIR").unwrap_or_else(|| state.join("run"))),
            state: finish(state),
        })
    }

    /// Every directory under ROOT, with the test profile.
    pub fn under(root: &Path) -> Dirs {
        let d = |name: &str| root.join(name).join("drgnx").join("test");
        Dirs {
            profile: Profile::Test,
            config: d("config"),
            state: d("state"),
            cache: d("cache"),
            data: d("data"),
            runtime: d("run"),
        }
    }
}

static FROM_ENV: OnceLock<&'static Dirs> = OnceLock::new();
static FOR_TEST: RwLock<Option<&'static Dirs>> = RwLock::new(None);

fn current() -> &'static Dirs {
    if let Some(d) = *FOR_TEST.read().unwrap_or_else(|e| e.into_inner()) {
        return d;
    }
    FROM_ENV.get_or_init(|| {
        let dirs = Dirs::from_lookup(|k| std::env::var_os(k))
            .unwrap_or_else(|e| panic!("{e} ({})", e.detail().unwrap_or("")));
        Box::leak(Box::new(dirs))
    })
}

/// The test's directories, until [`reset_for_test`]: every one under ROOT, profile `test`. Process-wide (one test per
/// process under nextest; raun's sandbox serialises the tests of one process).
pub fn init_for_test(root: &Path) {
    let dirs: &'static Dirs = Box::leak(Box::new(Dirs::under(root)));
    *FOR_TEST.write().unwrap_or_else(|e| e.into_inner()) = Some(dirs);
}

/// Back to the environment's directories.
pub fn reset_for_test() {
    *FOR_TEST.write().unwrap_or_else(|e| e.into_inner()) = None;
}

/// The name of the variable a child process needs to find its own home (a toolchain, a compiler cache). It is passed
/// through to the child by name and never read here: the editor's own directories come from the functions below.
pub const HOME_VAR: &str = "HOME";

pub fn profile() -> Profile {
    current().profile
}

/// Settings and keys the user writes (`$XDG_CONFIG_HOME/drgnx[/profile]`).
pub fn config() -> &'static Path {
    &current().config
}

/// State the editor keeps across runs: logs, history, sessions (`$XDG_STATE_HOME/drgnx[/profile]`).
pub fn state() -> &'static Path {
    &current().state
}

/// What can be rebuilt (`$XDG_CACHE_HOME/drgnx[/profile]`).
pub fn cache() -> &'static Path {
    &current().cache
}

/// Data the editor installs: packs, grammars, models (`$XDG_DATA_HOME/drgnx[/profile]`).
pub fn data() -> &'static Path {
    &current().data
}

/// Sockets and locks for this login (`$XDG_RUNTIME_DIR/drgnx[/profile]`, else `$XDG_STATE_HOME/run/drgnx[/profile]`).
pub fn runtime() -> &'static Path {
    &current().runtime
}
