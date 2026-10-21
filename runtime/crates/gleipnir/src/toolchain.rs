//! Toolchain roots from `PATH` (mise, cargo, go, nvm, npm, pipx, uv, claude) and the credential files beside them
//! to hide (docs/develop/gleipnir.md, "Toolchain roots").
//!
//! An agent needs the user's compilers under `~`, and binding `~` is refused. So the roots are the bin dirs and
//! install roots the `PATH` entries lead into, never a whole tool home: `~/.cargo/credentials.toml` is not inside
//! `~/.cargo/bin`. Everything here is pure path and metadata reading (no process, no write), identical on every
//! unix target; nothing is `cfg`-gated, so Android builds it unchanged (it has no backend to use it).

use crate::spec::{Layers, Net, SECRET_DIRS, Spec, Target};
use crate::validate::{Context, validate};
use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// File names (relative to a root) that hold credentials; [`hide_list`] hides the ones that exist, and a link
/// leading to a file of one of these names gives nothing.
pub const SECRET_FILES: &[&str] = &[
    ".npmrc",
    "etc/npmrc",
    ".yarnrc",
    ".yarnrc.yml",
    ".pypirc",
    ".netrc",
    ".git-credentials",
    ".env",
    "credentials",
    "credentials.toml",
    "credentials.json",
    "auth.json",
];

/// Read-only roots under the home: directories and single files, as sorted true names.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Roots {
    pub dirs: Vec<PathBuf>,
    pub files: Vec<PathBuf>,
}

/// Home subtrees where only a layout root may be taken from (never the subtree or a plain dir inside it).
const CONFIG_AREAS: &[&str] = &[".config", ".local/share", ".local/state", ".cache"];

/// The roots the `PATH` entries need under `home`. `path_dirs` must be absolute (a relative entry is skipped, as is
/// one that does not resolve or lies outside `home`: the system's reads are not this function's). `mise_data_dir`
/// is mise's data dir when it is not `~/.local/share/mise`. `exclude` holds drgnx's own checkout and data dir: a
/// link into one gives nothing.
pub fn roots(
    path_dirs: &[PathBuf],
    home: &Path,
    mise_data_dir: Option<&Path>,
    exclude: &[PathBuf],
) -> Roots {
    let home = canon(home);
    let mise = mise_data_dir
        .map(canon)
        .unwrap_or_else(|| home.join(".local/share/mise"));
    let exclude: Vec<PathBuf> = exclude.iter().map(|e| canon(e)).collect();
    let ctx = Ctx {
        home,
        mise,
        exclude,
    };
    let mut dirs = BTreeSet::new();
    let mut files = BTreeSet::new();
    for pd in path_dirs {
        if !pd.is_absolute() {
            continue;
        }
        let Ok(dir) = fs::canonicalize(pd) else {
            continue;
        };
        if !dir.starts_with(&ctx.home) || ctx.excluded(&dir) || ctx.closed(&dir) {
            continue;
        }
        let from_layout = ctx.layout(&dir);
        if from_layout.is_empty() {
            if ctx.plain_dir_ok(&dir) {
                dirs.insert(dir.clone());
            }
        } else {
            dirs.extend(from_layout);
        }
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for entry in rd.flatten() {
            let p = entry.path();
            if !fs::symlink_metadata(&p).is_ok_and(|m| m.file_type().is_symlink()) {
                continue;
            }
            let Ok(target) = fs::canonicalize(&p) else {
                continue;
            };
            if !target.starts_with(&ctx.home) || ctx.excluded(&target) || ctx.closed(&target) {
                continue;
            }
            let lay = ctx.layout(&target);
            if !lay.is_empty() {
                dirs.extend(lay);
            } else if ctx.program_file_ok(&target) {
                files.insert(target);
            }
        }
    }
    // A root inside another is left to the outer one.
    let dirs: Vec<PathBuf> = dirs
        .iter()
        .filter(|d| !dirs.iter().any(|o| o != *d && d.starts_with(o)))
        .cloned()
        .collect();
    let files: Vec<PathBuf> = files
        .into_iter()
        .filter(|f| !dirs.iter().any(|d| f.starts_with(d)))
        .collect();
    Roots { dirs, files }
}

/// How deep [`hide_list`] looks below a directory root for the dot-names of [`SECRET_FILES`]: `root/NAME`,
/// `root/a/NAME` and `root/a/b/NAME` (GL-T3-3). It reads every directory down to `root/a/b` once.
pub const SCAN_DEPTH: usize = 3;

/// The credential files inside the directory roots, as true names:
/// - each existing `root/SECRET_FILES[i]` (the fixed places: `etc/npmrc`, `credentials.toml`, …);
/// - each file or link named like one of the dot-names of [`SECRET_FILES`] (`.npmrc`, `.pypirc`, `.env`, …) down to
///   [`SCAN_DEPTH`], following no link while walking. The plain names (`credentials`, `auth.json`, …) are common
///   file names inside packages, and hiding a package's own data file would break it, so they count only at their
///   fixed place.
pub fn hide_list(roots: &Roots) -> Vec<PathBuf> {
    let mut out = BTreeSet::new();
    for root in &roots.dirs {
        for name in SECRET_FILES {
            let p = root.join(name);
            if let Ok(t) = fs::canonicalize(&p) {
                out.insert(t);
            }
        }
        scan(root, 1, &mut out);
    }
    out.into_iter().collect()
}

/// The dot-names [`hide_list`] looks for at every depth.
fn scanned(name: &std::ffi::OsStr) -> bool {
    SECRET_FILES
        .iter()
        .any(|s| s.starts_with('.') && !s.contains('/') && name == *s)
}

/// Every entry of `dir` named by [`scanned`], and the directories below it down to [`SCAN_DEPTH`]. A link is
/// hidden at its true name, as the fixed places are, but never walked into.
fn scan(dir: &Path, depth: usize, out: &mut BTreeSet<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for entry in rd.flatten() {
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if scanned(&entry.file_name()) && !kind.is_dir() {
            if let Ok(t) = fs::canonicalize(entry.path()) {
                out.insert(t);
            }
        } else if kind.is_dir() && depth < SCAN_DEPTH {
            scan(&entry.path(), depth + 1, out);
        }
    }
}

/// The roots `ctx` lets a sandbox read for `target` (GL-T3-1): each root is checked as a spec's lone `read` entry,
/// and one that is refused (it holds the home, a closed or secret dir, a session dir, …) or no longer exists is
/// dropped. A context that is itself refused drops every root. The read rules do not depend on the Linux tier, so
/// the reduced tier is checked as the full one.
pub fn readable(roots: Roots, ctx: &Context, target: Target) -> Roots {
    let target = match target {
        Target::Macos => Target::Macos,
        Target::LinuxBwrap | Target::LinuxReduced => Target::LinuxBwrap,
    };
    let ok = |p: &PathBuf| {
        let spec = Spec {
            read: vec![p.clone()],
            write: vec![],
            hide: vec![],
            sockets: vec![],
            binds: vec![],
            home: None,
            run: None,
            env: vec![],
            chdir: PathBuf::from("/"),
            net: Net::Shared,
            tmp: None,
            layers: Layers::for_target(target),
            extra_tcp_ports: vec![],
        };
        validate(spec, ctx, target).is_ok_and(|v| v.spec().read.len() == 1)
    };
    Roots {
        dirs: roots.dirs.into_iter().filter(ok).collect(),
        files: roots.files.into_iter().filter(ok).collect(),
    }
}

fn canon(p: &Path) -> PathBuf {
    fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

struct Ctx {
    home: PathBuf,
    mise: PathBuf,
    exclude: Vec<PathBuf>,
}

impl Ctx {
    fn excluded(&self, p: &Path) -> bool {
        self.exclude.iter().any(|e| p.starts_with(e))
    }

    /// Never the home or a parent of it, never `~/.local` itself, never inside a secret dir.
    fn closed(&self, p: &Path) -> bool {
        if self.home.starts_with(p) || p == self.home.join(".local") {
            return true;
        }
        SECRET_DIRS.iter().any(|s| p.starts_with(self.home.join(s)))
    }

    /// A plain dir (no layout) must not be, hold or lie in a config area.
    fn plain_dir_ok(&self, p: &Path) -> bool {
        !CONFIG_AREAS.iter().any(|a| {
            let area = self.home.join(a);
            p.starts_with(&area) || area.starts_with(p)
        })
    }

    /// A file from a link into no layout: an executable regular file, not directly in `~`, not a credential
    /// name, and not in a config area.
    fn program_file_ok(&self, p: &Path) -> bool {
        if p.parent() == Some(self.home.as_path()) {
            return false;
        }
        let name_secret = SECRET_FILES.iter().any(|s| {
            let s = Path::new(s);
            p.file_name() == s.file_name() && p.ends_with(s)
        });
        if name_secret || !self.plain_dir_ok(p) {
            return false;
        }
        fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }

    /// The roots of the layout `p` (a true name under the home) lies in; empty when it lies in none.
    fn layout(&self, p: &Path) -> Vec<PathBuf> {
        let h = &self.home;
        // mise: DATA/installs/TOOL/VER
        if let Ok(rel) = p.strip_prefix(self.mise.join("installs")) {
            let c: Vec<_> = rel.components().take(2).collect();
            if c.len() == 2 {
                return vec![self.mise.join("installs").join(c[0]).join(c[1])];
            }
            return vec![];
        }
        // cargo's proxies run the toolchains.
        if p.starts_with(h.join(".cargo/bin")) {
            let mut v = vec![h.join(".cargo/bin")];
            let tc = h.join(".rustup/toolchains");
            if tc.is_dir() {
                v.push(canon(&tc));
            }
            return v;
        }
        if p.starts_with(h.join(".rustup/toolchains")) {
            return vec![h.join(".rustup/toolchains")];
        }
        if p.starts_with(h.join("go/bin")) {
            return vec![h.join("go/bin")];
        }
        // One component deeper than the prefix: the version / package / app.
        for (prefix, depth) in [
            (".nvm/versions/node", 1),
            (".local/lib/node_modules", 1),
            (".local/share/pipx/venvs", 1),
            (".local/pipx/venvs", 1),
            (".local/share/uv/tools", 1),
            (".local/share/uv/python", 1),
        ] {
            let base = h.join(prefix);
            if let Ok(rel) = p.strip_prefix(&base) {
                let c: Vec<_> = rel.components().take(depth).collect();
                return match c.first() {
                    Some(first) => vec![base.join(first)],
                    None => vec![],
                };
            }
        }
        for whole in [".npm-global", ".local/share/claude/versions"] {
            if p.starts_with(h.join(whole)) {
                return vec![h.join(whole)];
            }
        }
        vec![]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    struct Fx {
        _t: tempfile::TempDir,
        home: PathBuf,
    }

    fn fx() -> Fx {
        let t = tempfile::Builder::new().prefix("glt-").tempdir().unwrap();
        let home = fs::canonicalize(t.path()).unwrap().join("home");
        fs::create_dir_all(&home).unwrap();
        Fx { _t: t, home }
    }

    impl Fx {
        fn p(&self, rel: &str) -> PathBuf {
            self.home.join(rel)
        }
        fn dir(&self, rel: &str) -> PathBuf {
            fs::create_dir_all(self.p(rel)).unwrap();
            self.p(rel)
        }
        fn file(&self, rel: &str, mode: u32) -> PathBuf {
            let p = self.p(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(&p, "x").unwrap();
            fs::set_permissions(&p, fs::Permissions::from_mode(mode)).unwrap();
            p
        }
        fn link(&self, rel: &str, to: &Path) {
            let p = self.p(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            symlink(to, p).unwrap();
        }
    }

    #[test]
    fn roots_from_path() {
        let f = fx();
        f.file(".local/share/mise/installs/node/22.1/bin/node", 0o755);
        f.file(".local/share/mise/installs/node/22.1/lib/x.js", 0o644);
        f.dir(".cargo/bin");
        f.dir(".rustup/toolchains/stable");
        let py = f.file(".local/share/mise/installs/python/3.13/bin/python", 0o755);
        f.link(".local/bin/python", &py);
        let sync = f.file("dotfiles/sync.sh", 0o755);
        f.link(".local/bin/sync", &sync);
        f.file("dotfiles/id_ed25519", 0o755);
        let r = roots(
            &[
                f.p(".local/share/mise/installs/node/22.1/bin"),
                f.p(".cargo/bin"),
                f.p(".local/bin"),
                PathBuf::from("/usr/bin"),
                PathBuf::from("relative/bin"),
            ],
            &f.home,
            None,
            &[],
        );
        assert_eq!(
            r.dirs,
            vec![
                f.p(".cargo/bin"),
                f.p(".local/bin"),
                f.p(".local/share/mise/installs/node/22.1"),
                f.p(".local/share/mise/installs/python/3.13"),
                f.p(".rustup/toolchains"),
            ]
        );
        // The dotfiles script alone is bound, never ~/dotfiles with the key beside it.
        assert_eq!(r.files, vec![sync]);
    }

    #[test]
    fn local_bin_plain_dir_is_a_root() {
        let f = fx();
        f.dir(".local/bin");
        let r = roots(&[f.p(".local/bin")], &f.home, None, &[]);
        assert_eq!(r.dirs, vec![f.p(".local/bin")]);
    }

    #[test]
    fn hide_credentials() {
        let f = fx();
        f.file(".cargo/bin/cargo", 0o755);
        f.file(".cargo/credentials.toml", 0o600);
        f.file(".npm-global/bin/tool", 0o755);
        let npmrc = f.file(".npm-global/etc/npmrc", 0o600);
        let r = roots(
            &[f.p(".cargo/bin"), f.p(".npm-global/bin")],
            &f.home,
            None,
            &[],
        );
        assert_eq!(r.dirs, vec![f.p(".cargo/bin"), f.p(".npm-global")]);
        assert_eq!(hide_list(&r), vec![npmrc]);
    }

    /// GL-T3-3: a dot-named credential file nested in a root is hidden down to depth 3; deeper, a plain name away
    /// from its fixed place, or a dir walked through a link, is not.
    #[test]
    fn nested_dot_credentials_hidden_to_depth_3() {
        let f = fx();
        f.file(".local/share/mise/installs/node/22.1/bin/node", 0o755);
        let n = ".local/share/mise/installs/node/22.1";
        let d1 = f.file(&format!("{n}/.npmrc"), 0o600);
        let d2 = f.file(&format!("{n}/lib/.pypirc"), 0o600);
        let d3 = f.file(&format!("{n}/lib/node_modules/.env"), 0o600);
        f.file(&format!("{n}/lib/node_modules/pkg/.npmrc"), 0o600); // depth 4
        f.file(&format!("{n}/lib/node_modules/auth.json"), 0o644); // a plain name, not at its place
        let fixed = f.file(&format!("{n}/auth.json"), 0o600);
        let outside = f.file("elsewhere/deep/.netrc", 0o600);
        f.link(&format!("{n}/lib/linked"), &f.p("elsewhere"));
        let linked = f.file("other/.git-credentials", 0o600);
        f.link(&format!("{n}/lib/.git-credentials"), &linked);
        let r = roots(&[f.p(&format!("{n}/bin"))], &f.home, None, &[]);
        assert_eq!(r.dirs, vec![f.p(n)]);
        let mut want = vec![d1, d2, d3, fixed, linked];
        want.sort();
        assert_eq!(hide_list(&r), want);
        assert!(!hide_list(&r).contains(&outside));
    }

    /// GL-T3-1: every root is checked by validation's read rules for the target; a refused one is dropped.
    #[test]
    fn readable_drops_what_validation_refuses() {
        let f = fx();
        f.file(".cargo/bin/cargo", 0o755);
        f.file(".local/share/mise/installs/node/22.1/bin/node", 0o755);
        f.file("state/drgnx/bin/x", 0o755);
        let tool = f.file("state/drgnx/tool", 0o755);
        let ok_tool = f.file("dotfiles/sync.sh", 0o755);
        let r = Roots {
            dirs: vec![
                f.p(".cargo/bin"),
                f.p(".local/share/mise/installs/node/22.1"),
                f.p("state/drgnx/bin"),
                f.p("gone"),
            ],
            files: vec![tool, ok_tool.clone()],
        };
        let ctx = Context {
            home: f.home.clone(),
            closed: vec![f.p("state/drgnx")],
            ..Context::default()
        };
        for t in [Target::LinuxBwrap, Target::LinuxReduced, Target::Macos] {
            let kept = readable(r.clone(), &ctx, t);
            assert_eq!(
                kept,
                Roots {
                    dirs: vec![
                        f.p(".cargo/bin"),
                        f.p(".local/share/mise/installs/node/22.1")
                    ],
                    files: vec![ok_tool.clone()],
                },
                "{t:?}"
            );
        }
        // A context that is refused (a relative PATH entry) keeps nothing.
        let bad = Context {
            program_dirs: vec![".".into()],
            ..ctx
        };
        assert_eq!(readable(r, &bad, Target::LinuxBwrap), Roots::default());
    }

    #[test]
    fn never_home_or_local() {
        let f = fx();
        f.dir(".local/bin");
        f.file("x", 0o755);
        let r = roots(
            &[
                f.home.clone(),
                f.p(".local"),
                f.home.parent().unwrap().into(),
            ],
            &f.home,
            None,
            &[],
        );
        assert_eq!(r, Roots::default());
        // A secret dir on PATH, and a link into one.
        f.dir(".ssh/bin");
        f.dir(".gnupg");
        let r = roots(&[f.p(".ssh/bin"), f.p(".gnupg")], &f.home, None, &[]);
        assert_eq!(r, Roots::default());
    }

    #[test]
    fn link_to_secret_gives_nothing() {
        let f = fx();
        let netrc = f.file(".netrc", 0o755);
        f.link(".local/bin/x", &netrc);
        let key = f.file("dotfiles/.npmrc", 0o755);
        f.link(".local/bin/y", &key);
        let ssh = f.file(".ssh/id_ed25519", 0o755);
        f.link(".local/bin/z", &ssh);
        let data = f.file("dotfiles/notes.txt", 0o644);
        f.link(".local/bin/w", &data);
        let dir = f.dir("dotfiles/tools");
        f.link(".local/bin/v", &dir);
        let r = roots(&[f.p(".local/bin")], &f.home, None, &[]);
        assert_eq!(r.files, Vec::<PathBuf>::new());
        assert_eq!(r.dirs, vec![f.p(".local/bin")]);
    }

    #[test]
    fn link_into_excluded_gives_nothing() {
        let f = fx();
        let bin = f.file(".local/share/drgnx/drgnx/bin/drgnx", 0o755);
        f.link(".local/bin/drgnx", &bin);
        let other = f.file("dotfiles/ok.sh", 0o755);
        f.link(".local/bin/ok", &other);
        let ex = f.p(".local/share/drgnx");
        let r = roots(
            &[f.p(".local/bin")],
            &f.home,
            None,
            std::slice::from_ref(&ex),
        );
        assert_eq!(r.files, vec![other]);
        // An excluded PATH dir gives nothing either.
        let r = roots(&[f.p(".local/share/drgnx/drgnx/bin")], &f.home, None, &[ex]);
        assert_eq!(r, Roots::default());
    }

    #[test]
    fn config_dirs_dropped_unless_layout() {
        let f = fx();
        f.file(".config/emacs/bin/doom", 0o755);
        f.file(".cache/tool/bin/x", 0o755);
        f.file(".local/state/s/bin/x", 0o755);
        f.file(".local/share/shims/x", 0o755);
        f.file(".local/share/uv/tools/ruff/bin/ruff", 0o755);
        f.file(".local/share/pipx/venvs/black/bin/black", 0o755);
        let tool = f.file(".config/emacs/bin/runner", 0o755);
        f.link(".local/bin/runner", &tool);
        let r = roots(
            &[
                f.p(".config/emacs/bin"),
                f.p(".cache/tool/bin"),
                f.p(".local/state/s/bin"),
                f.p(".local/share/shims"),
                f.p(".local/share/uv/tools/ruff/bin"),
                f.p(".local/share/pipx/venvs/black/bin"),
                f.p(".local/bin"),
            ],
            &f.home,
            None,
            &[],
        );
        assert_eq!(
            r.dirs,
            vec![
                f.p(".local/bin"),
                f.p(".local/share/pipx/venvs/black"),
                f.p(".local/share/uv/tools/ruff"),
            ]
        );
        assert!(r.files.is_empty());
    }

    #[test]
    fn mise_data_dir_honoured() {
        let f = fx();
        f.file("mise-data/installs/go/1.23/bin/go", 0o755);
        f.file(".local/share/mise/installs/go/1.22/bin/go", 0o755);
        let r = roots(
            &[
                f.p("mise-data/installs/go/1.23/bin"),
                f.p(".local/share/mise/installs/go/1.22/bin"),
            ],
            &f.home,
            Some(&f.p("mise-data")),
            &[],
        );
        // The default location is a data-area dir in no layout once the data dir moved.
        assert_eq!(r.dirs, vec![f.p("mise-data/installs/go/1.23")]);
    }

    #[test]
    fn links_into_other_layouts() {
        let f = fx();
        f.file(".local/share/claude/versions/2.1/claude", 0o755);
        let c = f.p(".local/share/claude/versions/2.1/claude");
        f.link(".local/bin/claude", &c);
        let n = f.file(".nvm/versions/node/v22/bin/node", 0o755);
        f.link(".local/bin/node", &n);
        let g = f.file("go/bin/gofmt", 0o755);
        f.link(".local/bin/gofmt", &g);
        let r = roots(&[f.p(".local/bin")], &f.home, None, &[]);
        assert_eq!(
            r.dirs,
            vec![
                f.p(".local/bin"),
                f.p(".local/share/claude/versions"),
                f.p(".nvm/versions/node/v22"),
                f.p("go/bin"),
            ]
            .into_iter()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>()
        );
    }
}
