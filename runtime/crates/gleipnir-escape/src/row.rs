//! Rows: JSON lines under `rows/{any,linux,macos}/`, and their parse (Task 14).
//!
//! A row is data. Parsing refuses what would make a row prove nothing: an unknown key, a placeholder outside the
//! closed list ([`PLACEHOLDERS`]), an expectation that says `blocked` without a control run, an unknown errno name,
//! a different number of expectations than probes.

use crate::errno_from_name;
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// The closed list of placeholders a row may use. An undefined one fails the parse (review B2).
///
/// The plan's list is the first eleven. The rest are what Tasks 15 and 16 need to name things the fixture makes at
/// run time (addresses and ports, the abstract socket, a pid, the fake bwrap and its marker, the git).
pub const PLACEHOLDERS: &[&str] = &[
    "HOME",
    "RUNTIME",
    "RUN",
    "TASK",
    "TASK2",
    "W",
    "DATA",
    "CANARY_DIR",
    "FIXTURE",
    "TMP",
    "USERS_SHARED",
    // Added by Task 14.
    "ABSTRACT",
    "TCP_LO",
    "TCP_NL",
    "UDP_LO",
    "UDP_NL",
    "UPSTREAM",
    "PROXY_TCP",
    "HARNESS_PID",
    "SLEEP_PID",
    "FAKE_BWRAP",
    "MARKER",
    // Added by Task 16: the git draugr runs (`draugr::git::git_program()`; on macOS the developer dir's, not the shim).
    "GIT",
];

/// The listeners a row may name in `listeners_silent`.
pub const LISTENERS: &[&str] = &[
    "hub",
    "backend",
    "session2",
    "emacs",
    "bus",
    "ssh-agent",
    "abstract",
    "tcp-lo",
    "tcp-nl",
    "udp-lo",
    "udp-nl",
    "upstream",
    "gateway",
];

/// Where a row's file lives: `rows/<platform>/`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Any,
    Linux,
    Macos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Need {
    Bwrap,
    Reduced,
    Landlock,
    Seccomp,
    Netns,
    Root,
    Macos,
    Linux,
    #[serde(rename = "x86_64")]
    X86_64,
    X32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum TierName {
    #[default]
    Full,
    Reduced,
}

impl TierName {
    pub fn arg(self) -> &'static str {
        match self {
            TierName::Full => "full",
            TierName::Reduced => "reduced",
        }
    }
}

/// What one probe's line must say.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Expect {
    pub result: ResultKind,
    /// Allowed errno names, so the layer that blocked is visible. Only for `blocked`.
    #[serde(default)]
    pub errno: Vec<String>,
    /// Exact text of the line's `detail`.
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ResultKind {
    Reached,
    Blocked,
}

/// Setup steps; those that need root run through `sudo -n` when the harness is not uid 0.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Setup {
    /// A script in a root-owned `/var/lib/glp-XXXXXX/`: `bubblewrap VERSION` for `--version`, and it writes
    /// `${MARKER}` only for any other argv (review S11). `${FAKE_BWRAP}` is its path.
    FakeBwrap { version: String },
    /// A fake `NAME` (default `bwrap`) first on the harness's `PATH`, which writes `${MARKER}`.
    PathBwrap { name: Option<String> },
    /// At `--pause-before-spawn`: move `path` aside and put a link to `target` in its place.
    SwapToLink { path: String, target: String },
    /// Before the run: a symbolic link `path` to `target`.
    PlantLink { path: String, target: String },
    /// An open fd `n` on a canary file, inherited by `ratatoskr`.
    CanaryFd { n: i32 },
    /// A `sleep` the harness starts; `${SLEEP_PID}` is its pid.
    StartSleep {},
    /// Before the run, in the control run's fixture too: a directory `path` (parents made).
    MakeDir { path: String },
    /// Before the run, in the control run's fixture too: a file `path` holding `text` (parents made).
    MakeFile {
        path: String,
        #[serde(default)]
        text: String,
    },
}

/// Something the harness does to the run while it is going.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct After {
    /// Acts once this many probe lines have been read.
    pub after_lines: usize,
    /// `run`: the `sandbox run` process; `group`: the process group of its child (the sandbox).
    pub kill: KillWho,
    #[serde(default = "nine")]
    pub signal: i32,
    /// Then this process must be gone: a command line containing `match` (arguments joined by spaces) must vanish.
    pub gone: Option<Gone>,
}

fn nine() -> i32 {
    9
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KillWho {
    Run,
    Group,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Gone {
    #[serde(rename = "match")]
    pub matching: String,
    pub within_ms: u64,
}

/// A row that runs `ratatoskr` with these arguments and no probe (`sandbox check`).
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Raw {
    pub args: Vec<String>,
    pub exit: Option<i32>,
    /// A subset the stdout's JSON must contain (see `run::subset`).
    pub json: Option<Value>,
    #[serde(default)]
    pub stdout_contains: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Row {
    pub row: String,
    #[serde(default)]
    pub needs: Vec<Need>,
    #[serde(default)]
    pub tier: TierName,
    /// The spec with placeholders. The harness fills what a row leaves out: `chdir` (`${W}`); `net` (isolated, with
    /// a relay from a free port to `${RUN}/proxy.sock`, and then `run` and `sockets` to match, and `HTTPS_PROXY` in
    /// the default `env`); `env` (a `PATH`); `layers` (the tier's floor); `tmp` (reduced: `${TMP}`). It adds the
    /// probe's directory to `read`.
    #[serde(default)]
    pub spec: Value,
    #[serde(default)]
    pub setup: Vec<Setup>,
    /// One argument list per probe (no `--and`).
    #[serde(default)]
    pub probes: Vec<Vec<String>>,
    #[serde(default)]
    pub expect: Vec<Expect>,
    /// Run the probes without the sandbox first (in a fixture of their own); each must reach.
    #[serde(default)]
    pub control: bool,
    /// What the control run gives instead of `reached` (such as `mount-missing` giving ENOENT).
    pub control_expect: Option<Vec<Expect>>,
    #[serde(default)]
    pub listeners_silent: Vec<String>,
    /// Without it, the run itself is asserted: not refused, exit 0, one line per probe. With it: a subset of
    /// `{"refused", "layers", "exit"}` (`refused: {"message_contains": …}` for a part of the text).
    pub result: Option<Value>,
    /// Run the probes with no sandbox at all and judge `expect` on them (the probes are real).
    #[serde(default)]
    pub unsandboxed: bool,
    /// `--bwrap`: a path, or `${FAKE_BWRAP}`.
    pub bwrap: Option<String>,
    #[serde(default)]
    pub landlock_omit: Vec<String>,
    pub landlock_abi_cap: Option<u8>,
    /// Paths that must not exist after the run (a marker a refused run must not have written).
    #[serde(default)]
    pub files_absent: Vec<String>,
    /// The proxy's events, sorted: `Denied host:port` or `Refused <Why> target`. Exactly these.
    pub proxy_events: Option<Vec<String>>,
    pub after: Option<After>,
    pub raw: Option<Raw>,
    #[serde(skip)]
    pub platform: Option<Platform>,
    #[serde(skip)]
    pub source: PathBuf,
}

impl Row {
    pub fn platform(&self) -> Platform {
        self.platform.unwrap_or(Platform::Any)
    }

    pub fn has_probes(&self) -> bool {
        !self.probes.is_empty()
    }
}

/// Every `${NAME}` in `s`.
pub fn placeholders_in(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = s;
    while let Some(i) = rest.find("${") {
        let after = &rest[i + 2..];
        match after.find('}') {
            Some(j) => {
                out.push(&after[..j]);
                rest = &after[j + 1..];
            }
            None => break,
        }
    }
    out
}

fn strings<'a>(v: &'a Value, out: &mut Vec<&'a str>) {
    match v {
        Value::String(s) => out.push(s),
        Value::Array(a) => a.iter().for_each(|x| strings(x, out)),
        Value::Object(o) => o.values().for_each(|x| strings(x, out)),
        _ => {}
    }
}

impl Row {
    /// Every string in the row that may carry a placeholder.
    fn texts(&self) -> Vec<String> {
        let mut t: Vec<String> = Vec::new();
        let mut spec = Vec::new();
        strings(&self.spec, &mut spec);
        t.extend(spec.into_iter().map(String::from));
        t.extend(self.probes.iter().flatten().cloned());
        t.extend(self.bwrap.iter().cloned());
        t.extend(self.landlock_omit.iter().cloned());
        t.extend(self.files_absent.iter().cloned());
        t.extend(self.proxy_events.iter().flatten().cloned());
        for s in &self.setup {
            match s {
                Setup::SwapToLink { path, target } | Setup::PlantLink { path, target } => {
                    t.push(path.clone());
                    t.push(target.clone());
                }
                Setup::MakeDir { path } => t.push(path.clone()),
                Setup::MakeFile { path, text } => {
                    t.push(path.clone());
                    t.push(text.clone());
                }
                _ => {}
            }
        }
        if let Some(r) = &self.raw {
            t.extend(r.args.iter().cloned());
        }
        for e in self
            .expect
            .iter()
            .chain(self.control_expect.iter().flatten())
        {
            t.extend(e.detail.iter().cloned());
        }
        t
    }

    /// The parse checks that need the whole row.
    pub fn check(&self) -> Result<(), String> {
        let name = &self.row;
        for text in self.texts() {
            for p in placeholders_in(&text) {
                if !PLACEHOLDERS.contains(&p) {
                    return Err(format!(
                        "{name}: undefined placeholder ${{{p}}} in {text:?}"
                    ));
                }
            }
        }
        if self.raw.is_some() == self.has_probes() {
            return Err(format!(
                "{name}: a row has probes or a raw command, not both and not neither"
            ));
        }
        // One expectation per probe. A refused row (`result` and none) expects no line; a run cut short by `after`
        // expects the lines that came before the cut.
        let (e, p) = (self.expect.len(), self.probes.len());
        let counts_ok =
            e == p || (self.result.is_some() && e == 0) || (self.after.is_some() && e <= p);
        if self.has_probes() && !counts_ok {
            return Err(format!("{name}: {e} expectations for {p} probes"));
        }
        if let Some(c) = &self.control_expect
            && c.len() != self.probes.len()
        {
            return Err(format!(
                "{name}: control_expect has {} entries for {} probes",
                c.len(),
                self.probes.len()
            ));
        }
        let all = self
            .expect
            .iter()
            .chain(self.control_expect.iter().flatten());
        for e in all {
            for n in &e.errno {
                if errno_from_name(n).is_none() {
                    return Err(format!("{name}: unknown errno name {n:?}"));
                }
            }
            if e.result == ResultKind::Reached && !e.errno.is_empty() {
                return Err(format!("{name}: an errno list on a reached expectation"));
            }
        }
        let says_blocked = self.expect.iter().any(|e| e.result == ResultKind::Blocked);
        if says_blocked && !self.control && !self.unsandboxed {
            return Err(format!(
                "{name}: an expectation says blocked, so the row needs control: true (a typo must not pass as ENOENT)"
            ));
        }
        if self.unsandboxed && (self.control || self.control_expect.is_some()) {
            return Err(format!("{name}: an unsandboxed row is its own control"));
        }
        if self.control_expect.is_some() && !self.control {
            return Err(format!("{name}: control_expect without control"));
        }
        for l in &self.listeners_silent {
            if !LISTENERS.contains(&l.as_str()) {
                return Err(format!("{name}: unknown listener {l:?}"));
            }
        }
        if self.after.is_some() && self.raw.is_some() {
            return Err(format!("{name}: after needs probes"));
        }
        Ok(())
    }
}

/// The rows of one `.jsonl` file (blank lines skipped).
pub fn parse_file(path: &Path, platform: Platform) -> Result<Vec<Row>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut rows = Vec::new();
    for (i, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let at = format!("{}:{}", path.display(), i + 1);
        let mut row: Row = serde_json::from_str(line).map_err(|e| format!("{at}: {e}"))?;
        row.platform = Some(platform);
        row.source = path.to_path_buf();
        row.check().map_err(|e| format!("{at}: {e}"))?;
        rows.push(row);
    }
    Ok(rows)
}

/// Every row under `dir`: `dir` itself when it holds `.jsonl` files (its own name says the platform), and each of
/// its `any`, `linux`, `macos` subdirectories. Row names must be unique.
pub fn load_dir(dir: &Path) -> Result<Vec<Row>, String> {
    let mut rows = Vec::new();
    let mut dirs: Vec<(PathBuf, Platform)> = Vec::new();
    let own = match dir.file_name().and_then(|n| n.to_str()) {
        Some("linux") => Platform::Linux,
        Some("macos") => Platform::Macos,
        _ => Platform::Any,
    };
    dirs.push((dir.to_path_buf(), own));
    for (sub, p) in [
        ("any", Platform::Any),
        ("linux", Platform::Linux),
        ("macos", Platform::Macos),
    ] {
        let d = dir.join(sub);
        if d.is_dir() {
            dirs.push((d, p));
        }
    }
    for (d, p) in dirs {
        let mut files: Vec<PathBuf> = std::fs::read_dir(&d)
            .map_err(|e| format!("{}: {e}", d.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|f| f.extension().is_some_and(|x| x == "jsonl"))
            .collect();
        files.sort();
        for f in files {
            rows.extend(parse_file(&f, p)?);
        }
    }
    let mut seen = BTreeSet::new();
    for r in &rows {
        if !seen.insert(r.row.clone()) {
            return Err(format!("row {:?} appears twice", r.row));
        }
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("rows")
    }

    fn parse(line: &str) -> Result<Vec<Row>, String> {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("t.jsonl");
        std::fs::write(&f, line).unwrap();
        parse_file(&f, Platform::Any)
    }

    #[test]
    fn parses_every_shipped_row() {
        let rows = load_dir(&rows_dir()).unwrap();
        assert!(rows.len() >= 2, "the shipped rows are missing");
        // `rows/container/` holds what only a container shows (`--rows rows/container`, never on the VM).
        let inside = load_dir(&rows_dir().join("container")).unwrap();
        assert!(!inside.is_empty(), "the container rows are missing");
        let mut names: BTreeSet<&str> = rows.iter().map(|r| r.row.as_str()).collect();
        for r in &inside {
            assert!(names.insert(&r.row), "{} appears twice", r.row);
        }
    }

    #[test]
    fn an_undefined_placeholder_fails_the_parse() {
        let e =
            parse(r#"{"row":"x","probes":[["read","${NOPE}/f"]],"expect":[{"result":"reached"}]}"#)
                .unwrap_err();
        assert!(e.contains("undefined placeholder ${NOPE}"), "{e}");
        parse(r#"{"row":"x","probes":[["read","${HOME}/f"]],"expect":[{"result":"reached"}]}"#)
            .unwrap();
    }

    #[test]
    fn a_blocked_expectation_without_control_fails_the_parse() {
        let blocked =
            r#""probes":[["read","/x"]],"expect":[{"result":"blocked","errno":["ENOENT"]}]"#;
        let e = parse(&format!(r#"{{"row":"x",{blocked}}}"#)).unwrap_err();
        assert!(e.contains("needs control: true"), "{e}");
        parse(&format!(r#"{{"row":"x","control":true,{blocked}}}"#)).unwrap();
    }

    #[test]
    fn typos_and_miscounts_fail_the_parse() {
        let e = parse(r#"{"row":"x","probe":[]}"#).unwrap_err();
        assert!(e.contains("unknown field"), "{e}");
        let e = parse(r#"{"row":"x","probes":[["fds"],["fds"]],"expect":[{"result":"reached"}]}"#)
            .unwrap_err();
        assert!(e.contains("1 expectations for 2 probes"), "{e}");
        let e = parse(r#"{"row":"x","control":true,"probes":[["fds"]],"expect":[{"result":"blocked","errno":["EBOGUS"]}]}"#)
            .unwrap_err();
        assert!(e.contains("unknown errno"), "{e}");
    }
}
