//! A repository's status as the Source Control view lists it: `git status --porcelain=v2 --branch -z
//! --untracked-files=all` read into the branch and three sections, staged, unstaged and conflicted changes (a file
//! staged and changed again is in both).

use super::super::git::Kind;

/// Which list a change is in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Section {
    /// Conflicts of a merge, a rebase or a cherry-pick.
    Merge,
    Staged,
    Changes,
}

impl Section {
    pub const ALL: [Section; 3] = [Section::Merge, Section::Staged, Section::Changes];

    pub fn id(self) -> &'static str {
        match self {
            Section::Merge => "merge",
            Section::Staged => "staged",
            Section::Changes => "changes",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Section::Merge => "Merge Changes",
            Section::Staged => "Staged Changes",
            Section::Changes => "Changes",
        }
    }
}

/// One changed path in one section: its letter (M A D R C U, as VS Code shows them) and the kind its face follows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub path: String,
    /// A rename's or copy's old path.
    pub orig: Option<String>,
    pub letter: char,
    pub kind: Kind,
}

/// The branch and where it stands against its upstream.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Head {
    /// None: detached.
    pub name: Option<String>,
    /// The commit (none before the first).
    pub oid: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
}

/// A repository's status: the branch and the changes of each section, in path order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub head: Head,
    pub merge: Vec<Change>,
    pub staged: Vec<Change>,
    pub changes: Vec<Change>,
}

impl Status {
    pub fn section(&self, s: Section) -> &[Change] {
        match s {
            Section::Merge => &self.merge,
            Section::Staged => &self.staged,
            Section::Changes => &self.changes,
        }
    }

    /// How many paths changed (a path in two sections counts once).
    pub fn count(&self) -> usize {
        let mut paths: Vec<&str> = self
            .merge
            .iter()
            .chain(&self.staged)
            .chain(&self.changes)
            .map(|c| c.path.as_str())
            .collect();
        paths.sort_unstable();
        paths.dedup();
        paths.len()
    }
}

/// The letter and kind of a status letter X (or Y) of porcelain v2.
fn letter(c: u8) -> Option<(char, Kind)> {
    Some(match c {
        b'M' | b'T' => ('M', Kind::Modified),
        b'A' => ('A', Kind::Added),
        b'D' => ('D', Kind::Deleted),
        b'R' => ('R', Kind::Renamed),
        b'C' => ('C', Kind::Added),
        _ => return None,
    })
}

/// The path after N space-separated fields of ENTRY (a path may hold spaces).
fn after_fields(entry: &str, n: usize) -> Option<&str> {
    let mut rest = entry;
    for _ in 0..n {
        rest = &rest[rest.find(' ')? + 1..];
    }
    Some(rest)
}

fn push(list: &mut Vec<Change>, path: &str, orig: Option<&str>, c: u8) {
    if let Some((letter, kind)) = letter(c) {
        list.push(Change {
            path: path.to_owned(),
            orig: orig.map(str::to_owned),
            letter,
            kind,
        });
    }
}

/// Read OUTPUT of `git status --porcelain=v2 --branch -z --untracked-files=all`.
pub fn parse(output: &[u8]) -> Status {
    let text = String::from_utf8_lossy(output);
    let mut st = Status::default();
    let mut records = text.split('\0').filter(|e| !e.is_empty());
    while let Some(e) = records.next() {
        let xy = e.as_bytes().get(2..4).unwrap_or(b"..");
        match e.as_bytes()[0] {
            b'1' => {
                if let Some(p) = after_fields(e, 8) {
                    push(&mut st.staged, p, None, xy[0]);
                    push(&mut st.changes, p, None, xy[1]);
                }
            }
            b'2' => {
                let orig = records.next();
                if let Some(p) = after_fields(e, 9) {
                    push(&mut st.staged, p, orig, xy[0]);
                    push(&mut st.changes, p, orig, xy[1]);
                }
            }
            b'u' => {
                if let Some(p) = after_fields(e, 10) {
                    st.merge.push(Change {
                        path: p.to_owned(),
                        orig: None,
                        letter: 'C',
                        kind: Kind::Conflict,
                    });
                }
            }
            b'?' => st.changes.push(Change {
                path: e[2..].to_owned(),
                orig: None,
                letter: 'U',
                kind: Kind::Untracked,
            }),
            b'#' => {
                if let Some(h) = e.strip_prefix("# branch.head ") {
                    st.head.name = (h != "(detached)").then(|| h.to_owned());
                } else if let Some(o) = e.strip_prefix("# branch.oid ") {
                    st.head.oid = (o != "(initial)").then(|| o.to_owned());
                } else if let Some(u) = e.strip_prefix("# branch.upstream ") {
                    st.head.upstream = Some(u.to_owned());
                } else if let Some(ab) = e.strip_prefix("# branch.ab ") {
                    let mut it = ab.split(' ');
                    let num =
                        |s: Option<&str>| s.and_then(|s| s.get(1..)?.parse().ok()).unwrap_or(0);
                    st.head.ahead = num(it.next());
                    st.head.behind = num(it.next());
                }
            }
            _ => {}
        }
    }
    for list in [&mut st.merge, &mut st.staged, &mut st.changes] {
        list.sort_by(|a, b| a.path.cmp(&b.path));
    }
    st
}
