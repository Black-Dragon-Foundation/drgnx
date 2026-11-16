//! The Source Control Graph: the history of the branch and its upstream (`git log --topo-order`), each commit a row
//! whose lanes are drawn as text (`●` the commit, `│` a lane passing, `╮` a lane a merge's other parent starts, `╯` a
//! lane ending in a commit), marked incoming (`↓`, on the upstream only) or outgoing (`↑`, not pushed).

use std::collections::BTreeSet;

/// How many commits a graph reads at first, and how many more each `more` adds.
pub const PAGE: usize = 200;

/// The format of `git log` the graph reads: fields split by 0x1f, records by NUL (`-z`).
pub const FORMAT: &str = "--format=%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s";

/// One commit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commit {
    pub sha: String,
    pub parents: Vec<String>,
    pub author: String,
    /// Seconds since the epoch.
    pub time: i64,
    /// Its refs as `git log` decorates them (`HEAD -> main`, `origin/main`, `tag: v1`).
    pub refs: Vec<String>,
    pub subject: String,
}

/// Read `git log -z` OUTPUT in [`FORMAT`].
pub fn parse(output: &[u8]) -> Vec<Commit> {
    String::from_utf8_lossy(output)
        .split('\0')
        .filter_map(|rec| {
            let rec = rec.trim_start_matches('\n');
            let f: Vec<&str> = rec.splitn(6, '\u{1f}').collect();
            let [sha, parents, author, time, refs, subject] = f[..] else {
                return None;
            };
            Some(Commit {
                sha: sha.to_owned(),
                parents: parents.split_whitespace().map(str::to_owned).collect(),
                author: author.to_owned(),
                time: time.parse().unwrap_or(0),
                refs: refs
                    .split(", ")
                    .filter(|r| !r.is_empty())
                    .map(str::to_owned)
                    .collect(),
                subject: subject.to_owned(),
            })
        })
        .collect()
}

/// `git rev-list --left-right HEAD...UPSTREAM` OUTPUT: the outgoing commits (`<`) and the incoming ones (`>`).
pub fn sides(output: &[u8]) -> (BTreeSet<String>, BTreeSet<String>) {
    let (mut out, mut inc) = (BTreeSet::new(), BTreeSet::new());
    for l in String::from_utf8_lossy(output).lines() {
        if let Some(s) = l.strip_prefix('<') {
            out.insert(s.to_owned());
        } else if let Some(s) = l.strip_prefix('>') {
            inc.insert(s.to_owned());
        }
    }
    (out, inc)
}

/// Each commit's lanes as text, in COMMITS' order (newest first, topologically).
pub fn lanes(commits: &[Commit]) -> Vec<String> {
    let mut lanes: Vec<Option<&str>> = Vec::new();
    let mut out = Vec::with_capacity(commits.len());
    for c in commits {
        let col = match lanes.iter().position(|l| *l == Some(c.sha.as_str())) {
            Some(i) => i,
            None => match lanes.iter().position(Option::is_none) {
                Some(i) => i,
                None => {
                    lanes.push(None);
                    lanes.len() - 1
                }
            },
        };
        let ending: Vec<usize> = (0..lanes.len())
            .filter(|&i| i != col && lanes[i] == Some(c.sha.as_str()))
            .collect();
        let mut glyphs: Vec<char> = (0..lanes.len())
            .map(|i| {
                if i == col {
                    '●'
                } else if ending.contains(&i) {
                    '╯'
                } else if lanes[i].is_some() {
                    '│'
                } else {
                    ' '
                }
            })
            .collect();
        for &i in &ending {
            lanes[i] = None;
        }
        lanes[col] = c.parents.first().map(String::as_str);
        for p in c.parents.iter().skip(1) {
            if lanes.contains(&Some(p.as_str())) {
                continue;
            }
            let j = match lanes.iter().position(Option::is_none) {
                Some(j) => j,
                None => {
                    lanes.push(None);
                    lanes.len() - 1
                }
            };
            lanes[j] = Some(p.as_str());
            if glyphs.len() <= j {
                glyphs.resize(j + 1, ' ');
            }
            glyphs[j] = '╮';
        }
        while lanes.last() == Some(&None) {
            lanes.pop();
        }
        let text: String = glyphs.into_iter().collect();
        out.push(text.trim_end().to_owned());
    }
    out
}

/// How long ago TIME was at NOW (seconds since the epoch), as the graph shows it: `now`, `5m`, `3h`, `2d`, `4w`,
/// `7mo`, `2y`.
pub fn age(time: i64, now: i64) -> String {
    let s = (now - time).max(0);
    match s {
        0..60 => "now".to_owned(),
        60..3600 => format!("{}m", s / 60),
        3600..86_400 => format!("{}h", s / 3600),
        86_400..604_800 => format!("{}d", s / 86_400),
        604_800..2_592_000 => format!("{}w", s / 604_800),
        2_592_000..31_536_000 => format!("{}mo", s / 2_592_000),
        _ => format!("{}y", s / 31_536_000),
    }
}
