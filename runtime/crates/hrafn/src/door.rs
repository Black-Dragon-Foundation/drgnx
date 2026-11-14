//! The git door per tree (`TreeGit`): what the overlay asks of git in one checkout. A user tree gets `GitCli`; a tree
//! a sandboxed agent has worked in ("touched") gets `GixDoor`, which reads in-process and runs nothing of the repo's.
use crate::files::Git;
use std::io;
use std::path::Path;

/// HEAD of a tree: the commit (`None` while the branch is unborn) and the branch it names (`None` when detached).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Head {
    pub id: Option<String>,
    pub symref: Option<String>,
}

/// A blob or link in a tree: its mode (`0o100644`, `0o100755`, `0o120000`) and its id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Obj {
    pub mode: u32,
    pub blob: String,
}

/// One entry of `ls_tree`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeEntry {
    pub path: String,
    pub mode: u32,
    pub blob: String,
}

/// One path that differs between two commits; `None` is "absent". No rename detection: a rename is two changes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeChange {
    pub path: String,
    pub old: Option<Obj>,
    pub new: Option<Obj>,
}

/// The stat-based status of a tree. `dirty`: tracked paths whose content may differ from HEAD's (staged, stat-dirty,
/// deleted or unmerged; a superset is allowed). `untracked`: files git does not track or ignore. Both sorted.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub dirty: Vec<String>,
    pub untracked: Vec<String>,
}

/// A working-tree file's blob id. `uncertain`: hashed raw while `.gitattributes` names a conversion for it, so the id
/// may differ from the one git would store; the overlay writes such a path's row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Blob {
    pub id: String,
    pub uncertain: bool,
}

/// Which door a tree uses; stored in the store's `tree.door`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DoorKind {
    Cli,
    Gix,
}

impl DoorKind {
    /// A touched tree (an agent has worked in it) gets the gix door; any other tree the git binary.
    pub fn for_tree(touched: bool) -> Self {
        if touched {
            DoorKind::Gix
        } else {
            DoorKind::Cli
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            DoorKind::Cli => "cli",
            DoorKind::Gix => "gix",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "cli" => Some(DoorKind::Cli),
            "gix" => Some(DoorKind::Gix),
            _ => None,
        }
    }
}

/// What the overlay asks of git in one tree. Paths are relative to `root`, with `/` separators. Gitlinks (submodule
/// entries) are never reported: the overlay skips them.
pub trait TreeGit {
    fn kind(&self) -> DoorKind;
    fn head(&self, root: &Path) -> io::Result<Head>;
    /// The blobs and links that differ between commits `a` and `b`, sorted by path.
    fn tree_diff(&self, root: &Path, a: &str, b: &str) -> io::Result<Vec<TreeChange>>;
    fn stat_status(&self, root: &Path) -> io::Result<Status>;
    /// Every blob and link of `commit`'s tree, sorted by path.
    fn ls_tree(&self, root: &Path, commit: &str) -> io::Result<Vec<TreeEntry>>;
    /// The blob of each path's working-tree content, in order.
    fn blobs(&self, root: &Path, paths: &[String]) -> io::Result<Vec<Blob>>;
    /// The subset of `paths` for which `.gitattributes` (or `core.autocrlf`) names a conversion: a `filter`, `text`,
    /// `eol`, `ident` or `working-tree-encoding`.
    fn filtered(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>>;
    /// The same door as the file list's `Git` (the fallback listing runs on it).
    fn as_git(&self) -> &dyn Git;
}

/// The door of `kind`.
#[cfg(feature = "host")]
pub fn door(kind: DoorKind) -> Box<dyn TreeGit + Send + Sync> {
    match kind {
        DoorKind::Cli => Box::new(crate::files::GitCli),
        DoorKind::Gix => Box::new(GixDoor),
    }
}

#[cfg(feature = "host")]
mod gix_door;
#[cfg(feature = "host")]
pub use gix_door::GixDoor;

/// The attributes that name a conversion between the working tree and the blob.
#[cfg(feature = "host")]
const CONVERSIONS: [&str; 5] = ["filter", "text", "eol", "ident", "working-tree-encoding"];

/// Whether a path converts, from its values of `CONVERSIONS` in order, as `git check-attr` prints them (`set`,
/// `unset`, `unspecified` or the value), and whether `core.autocrlf` is on (`true` or `input`).
#[cfg(feature = "host")]
fn converts(values: &[&str; 5], autocrlf: bool) -> bool {
    let given = |v: &str| v != "unspecified" && v != "unset";
    let [filter, text, eol, ident, encoding] = *values;
    given(filter)
        || match text {
            "unset" => false,
            "unspecified" => autocrlf || given(eol),
            _ => true,
        }
        || ident == "set"
        || given(encoding)
}

#[cfg(feature = "host")]
fn autocrlf_on(value: Option<&str>) -> bool {
    matches!(value.map(str::trim), Some("true" | "input"))
}

#[cfg(feature = "host")]
mod cli_door {
    use super::*;
    use crate::files::GitCli;
    use crate::files::cli::{nul_list, run, try_run};

    fn mode(s: &str) -> io::Result<u32> {
        u32::from_str_radix(s, 8).map_err(|_| io::Error::other(format!("git: bad mode {s}")))
    }

    fn trimmed(out: Option<Vec<u8>>) -> Option<String> {
        out.map(|o| String::from_utf8_lossy(&o).trim().to_string())
            .filter(|s| !s.is_empty())
    }

    impl TreeGit for GitCli {
        fn kind(&self) -> DoorKind {
            DoorKind::Cli
        }

        fn head(&self, root: &Path) -> io::Result<Head> {
            Ok(Head {
                id: trimmed(try_run(
                    root,
                    &["rev-parse", "-q", "--verify", "HEAD^{commit}"],
                )?),
                symref: trimmed(try_run(root, &["symbolic-ref", "-q", "HEAD"])?),
            })
        }

        fn tree_diff(&self, root: &Path, a: &str, b: &str) -> io::Result<Vec<TreeChange>> {
            let out = run(
                root,
                &[
                    "diff-tree",
                    "-r",
                    "-z",
                    "--no-renames",
                    "--no-ext-diff",
                    "--no-textconv",
                    a,
                    b,
                ],
                vec![],
            )?;
            // ":<old mode> <new mode> <old id> <new id> <status>" NUL "<path>" NUL, repeated
            let f = nul_list(&out);
            let mut changes = Vec::new();
            for rec in f.chunks(2) {
                let [meta, path] = rec else { break };
                let m: Vec<&str> = meta.trim_start_matches(':').split(' ').collect();
                let [om, nm, oid, nid, ..] = m[..] else {
                    return Err(io::Error::other(format!("git diff-tree: {meta}")));
                };
                let side = |m: &str, id: &str| -> io::Result<Option<Obj>> {
                    let m = mode(m)?;
                    Ok((m != 0 && m != 0o160000).then(|| Obj {
                        mode: m,
                        blob: id.to_string(),
                    }))
                };
                let (old, new) = (side(om, oid)?, side(nm, nid)?);
                if old != new {
                    changes.push(TreeChange {
                        path: path.clone(),
                        old,
                        new,
                    });
                }
            }
            changes.sort_by(|x, y| x.path.cmp(&y.path));
            Ok(changes)
        }

        fn stat_status(&self, root: &Path) -> io::Result<Status> {
            let out = run(
                root,
                &[
                    "status",
                    "--porcelain=v2",
                    "-z",
                    "--untracked-files=all",
                    "--no-renames",
                    "--ignore-submodules=all",
                ],
                vec![],
            )?;
            let mut st = Status::default();
            for rec in nul_list(&out) {
                // "1 XY sub mH mI mW hH hI path", "u XY sub m1 m2 m3 mW h1 h2 h3 path", "? path"
                let (kind, fields) = match rec.as_bytes().first() {
                    Some(b'1') => ("1", 9),
                    Some(b'u') => ("u", 11),
                    Some(b'?') => ("?", 2),
                    _ => continue,
                };
                let parts: Vec<&str> = rec.splitn(fields, ' ').collect();
                let Some(path) = parts.get(fields - 1) else {
                    continue;
                };
                match kind {
                    "?" if !path.ends_with('/') => st.untracked.push(path.to_string()),
                    "?" => {}
                    _ if parts.get(2).is_some_and(|sub| sub.starts_with('S')) => {}
                    _ => st.dirty.push(path.to_string()),
                }
            }
            st.dirty.sort();
            st.untracked.sort();
            Ok(st)
        }

        fn ls_tree(&self, root: &Path, commit: &str) -> io::Result<Vec<TreeEntry>> {
            let out = run(
                root,
                &["ls-tree", "-r", "-z", "--full-tree", commit],
                vec![],
            )?;
            let mut v = Vec::new();
            for rec in nul_list(&out) {
                // "<mode> <type> <id>\t<path>"
                let Some((meta, path)) = rec.split_once('\t') else {
                    continue;
                };
                let m: Vec<&str> = meta.split(' ').collect();
                if let [md, "blob", id] = m[..] {
                    v.push(TreeEntry {
                        path: path.to_string(),
                        mode: mode(md)?,
                        blob: id.to_string(),
                    });
                }
            }
            v.sort_by(|x, y| x.path.cmp(&y.path));
            Ok(v)
        }

        fn blobs(&self, root: &Path, paths: &[String]) -> io::Result<Vec<Blob>> {
            // with the repository's filters, as the base's blobs: never uncertain
            Ok(Git::blobs(self, root, paths)?
                .into_iter()
                .map(|id| Blob {
                    id,
                    uncertain: false,
                })
                .collect())
        }

        fn filtered(&self, root: &Path, paths: &[String]) -> io::Result<Vec<String>> {
            if paths.is_empty() {
                return Ok(vec![]);
            }
            let autocrlf = autocrlf_on(
                trimmed(try_run(root, &["config", "--get", "core.autocrlf"])?).as_deref(),
            );
            let mut input = Vec::new();
            for p in paths {
                input.extend_from_slice(p.as_bytes());
                input.push(0);
            }
            let mut args = vec!["check-attr", "-z", "--stdin"];
            args.extend(CONVERSIONS);
            let out = run(root, &args, input)?;
            // path NUL attribute NUL value NUL, the attributes in the order asked, per path
            let f = nul_list(&out);
            let mut hit = Vec::new();
            for per_path in f.chunks(3 * CONVERSIONS.len()) {
                let mut values = ["unspecified"; 5];
                for (i, rec) in per_path.chunks(3).enumerate() {
                    if let ([_, _, v], Some(slot)) = (rec, values.get_mut(i)) {
                        *slot = v.as_str();
                    }
                }
                if converts(&values, autocrlf) {
                    hit.push(per_path[0].clone());
                }
            }
            hit.sort();
            hit.dedup();
            Ok(hit)
        }

        fn as_git(&self) -> &dyn Git {
            self
        }
    }
}
