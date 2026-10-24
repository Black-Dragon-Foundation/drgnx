//! Your settings files and a job's sandbox (unified settings design §13; docs/develop/gleipnir.md, "Your settings
//! files"): [`closed_config_targets`], the true paths of the files drgnx loads as you, for `Context.closed`, and
//! [`settings_pins`], read-only binds over the existing `.dir-locals.el`, `.dir-locals-2.el` and `.drgnx/` of a
//! job's write roots. Nothing calls them for a job yet: phase 6's job spec builder will (`sandbox run
//! --settings-guards` applies both for the escape rows).

use gleipnir::{BackendKind, Bind, Mode};
use huginn::form::{SettingsFile, parse_settings};
use huginn::read::Limits;
use huginn::value::Datum;
use std::path::{Component, Path, PathBuf};

/// The files and the folder in your config folder that drgnx reads or loads as you.
pub const CONFIG_FILES: &[&str] = &[
    "settings.el",
    "config.el",
    "custom.el",
    "described.el",
    "workspaces",
];

/// What [`settings_pins`] pins in each write root, when it exists: what Emacs reads as a folder's settings, and the
/// folder's drgnx settings.
pub const PINNED: &[&str] = &[".dir-locals.el", ".dir-locals-2.el", ".drgnx"];

/// How many links one name may go through (the kernel's `MAXSYMLINKS`); a longer chain is a loop.
const MAX_LINKS: u32 = 40;

/// What the check and the doctor say where pins cannot hold.
pub const REDUCED_CANNOT_PIN: &str = "the reduced tier cannot pin .dir-locals.el, .dir-locals-2.el or .drgnx/ \
     read-only in a job's write roots (it has no mount namespace): the review gate guards them, so their code runs \
     only after you review it";

/// The true paths of `settings.el`, `config.el`, `custom.el`, `described.el` and `workspaces/` in `config_dir`, and of
/// each of `user_lisp_files` (a relative one is in `config_dir`), for `Context.closed`: a write root that holds one
/// is refused (`Rule::ExposesUser`) in every tier. Each name is taken as Emacs loads it: `..` first collapsed as
/// `expand-file-name` does, then every link followed as the kernel does, a dangling one too (a stow link whose target
/// is not there yet still names the place it would be made); a part that does not exist is kept as written. One that
/// cannot be named (not UTF-8, a loop) is left out. Sorted, once each.
pub fn closed_config_targets(config_dir: &Path, user_lisp_files: &[PathBuf]) -> Vec<PathBuf> {
    let names = CONFIG_FILES
        .iter()
        .map(|f| config_dir.join(f))
        .chain(user_lisp_files.iter().map(|f| config_dir.join(f)));
    let mut out: Vec<PathBuf> = names
        .filter_map(|p| followed(&lexical(&p), &mut 0))
        .collect();
    out.sort();
    out.dedup();
    out
}

/// `p` with `.` dropped and `..` taken off the name before it, as `expand-file-name` does: nothing is looked up.
fn lexical(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// `p` with every link followed as the kernel does (a link's `..` from its true folder), a dangling one too, and the
/// part that does not exist kept as written. `None` for a relative or non-UTF-8 name, or more than [`MAX_LINKS`]
/// links.
fn followed(p: &Path, links: &mut u32) -> Option<PathBuf> {
    p.to_str()?;
    if !p.is_absolute() {
        return None;
    }
    let mut out = PathBuf::from("/");
    for c in p.components() {
        match c {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(name) => {
                out.push(name);
                // A link is followed; anything else, there or not, stays as written.
                if let Ok(m) = std::fs::symlink_metadata(&out)
                    && m.file_type().is_symlink()
                {
                    *links += 1;
                    if *links > MAX_LINKS {
                        return None;
                    }
                    let target = std::fs::read_link(&out).ok()?;
                    out.pop();
                    out = followed(&out.join(target), links)?;
                }
            }
            Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

/// `Bind { mode: Ro, source: p, dest: p }` for each existing `.dir-locals.el`, `.dir-locals-2.el` and `.drgnx/` in
/// each of `write_roots` (true names, as in a validated spec), so a job can neither change nor replace them; missing
/// ones are not pinned. One that is a link is pinned at its target when that lies in a write root (elsewhere it is
/// not writable); the link itself stays replaceable, as a missing file stays creatable. Each place once.
pub fn settings_pins(write_roots: &[PathBuf]) -> Vec<Bind> {
    let mut out: Vec<Bind> = Vec::new();
    for root in write_roots {
        for name in PINNED {
            let Some(p) = pin_source(&root.join(name), write_roots) else {
                continue;
            };
            if !out.iter().any(|b| b.source == p) {
                out.push(Bind {
                    mode: Mode::Ro,
                    source: p.clone(),
                    dest: p,
                });
            }
        }
    }
    out
}

/// What to pin for `p`: itself, its target when it is a link into one of `roots`, or nothing.
fn pin_source(p: &Path, roots: &[PathBuf]) -> Option<PathBuf> {
    let meta = std::fs::symlink_metadata(p).ok()?;
    if !meta.file_type().is_symlink() {
        return Some(p.to_path_buf());
    }
    let target = std::fs::canonicalize(p).ok()?;
    roots
        .iter()
        .any(|r| target.starts_with(r))
        .then_some(target)
}

/// The files `file`'s global `drgnx-user-lisp-files` entry lists (`FILE` or `(FILE . PLIST)`, on or off: a file
/// that is off can be turned on; a dotted `(FILE . X)` is not a list drgnx loads), as absolute names: `~` and `~/…` in `home`, a relative one in `config_dir`. A name
/// drgnx would not load (empty, `~user/…`) is left out.
pub fn user_lisp_files(file: &SettingsFile, config_dir: &Path, home: &Path) -> Vec<PathBuf> {
    let Some(entry) = file
        .entries
        .iter()
        .find(|e| e.var == "drgnx-user-lisp-files" && e.scope.is_empty())
    else {
        return Vec::new();
    };
    let Datum::List(items) = &entry.value.datum else {
        return Vec::new();
    };
    let name = |d: &Datum| match d {
        Datum::Str(s) => Some(s.clone()),
        Datum::List(xs) => match xs.first().map(|x| &x.datum) {
            Some(Datum::Str(s)) => Some(s.clone()),
            _ => None,
        },
        _ => None,
    };
    items
        .iter()
        .filter_map(|n| name(&n.datum))
        .filter_map(|s| match s.as_str() {
            "" => None,
            "~" => Some(home.to_path_buf()),
            _ if s.starts_with("~/") => Some(home.join(&s[2..])),
            _ if s.starts_with('~') => None,
            _ => Some(config_dir.join(s)),
        })
        .collect()
}

/// [`user_lisp_files`] of `config_dir`'s `settings.el`, read as the runtime reads it (`load::read_checked`): none
/// when it is absent, refused or does not read.
pub fn read_user_lisp_files(config_dir: &Path, home: &Path) -> Vec<PathBuf> {
    let path = config_dir.join(crate::settings::load::FILE);
    let Ok(Some(bytes)) = crate::settings::load::read_checked(&path) else {
        return Vec::new();
    };
    match parse_settings(&bytes, "drgnx-settings", Limits::default()) {
        Ok(file) => user_lisp_files(&file, config_dir, home),
        Err(_) => Vec::new(),
    }
}

/// What `sandbox check` and the doctor add for `backend`: [`REDUCED_CANNOT_PIN`] for the reduced tier, else nothing.
pub fn pins_note(backend: BackendKind) -> Option<&'static str> {
    (backend == BackendKind::Reduced).then_some(REDUCED_CANNOT_PIN)
}

#[cfg(test)]
mod tests;
