//! Scenario files: parsing and the gate that decides whether a row runs here.

use serde_json::{Map, Value};

pub const VERBS: [&str; 26] = [
    "start",
    "root",
    "rename",
    "remove",
    "install_bin",
    "run",
    "spawn",
    "connect",
    "hello",
    "chmod",
    "send",
    "pause",
    "expect",
    "expect_next",
    "expect_closed",
    "expect_silent",
    "kill",
    "expect_exit",
    "file",
    "write_file",
    "sqlite",
    "backend_log",
    "pid",
    "class_matrix",
    "bad_params",
    "measure",
];

#[derive(Debug)]
pub struct Step {
    pub line: usize,
    pub verb: String,
    pub obj: Map<String, Value>,
}

#[derive(Debug)]
pub struct Scenario {
    pub name: String,
    pub requires: Vec<String>,
    /// What the row pins, for whoever reads the file (the runner does not use it).
    #[allow(dead_code)]
    pub doc: String,
    pub steps: Vec<Step>,
}

#[derive(Debug)]
pub struct ParseError {
    pub line: usize,
    pub msg: String,
}

pub const TAGS: [&str; 9] = [
    "v0",
    "v1",
    "fake-backend",
    "lisp-backend",
    "sudo",
    "test-hooks",
    "linux",
    "macos",
    "perf",
];

fn err(line: usize, msg: impl Into<String>) -> ParseError {
    ParseError {
        line,
        msg: msg.into(),
    }
}

/// One scenario file: line 1 is the header, every other non-blank line a step.
pub fn parse(text: &str) -> Result<Scenario, ParseError> {
    let mut lines = text
        .lines()
        .enumerate()
        .map(|(i, l)| (i + 1, l))
        .filter(|(_, l)| !l.trim().is_empty());
    let (hl, header) = lines
        .next()
        .ok_or_else(|| err(1, "an empty scenario file"))?;
    let h: Value = serde_json::from_str(header)
        .map_err(|e| err(hl, format!("the header is not JSON: {e}")))?;
    let name = h
        .get("scenario")
        .and_then(Value::as_str)
        .ok_or_else(|| err(hl, "the header needs a \"scenario\" name"))?;
    let mut requires = Vec::new();
    for t in h
        .get("requires")
        .map(|r| {
            r.as_array()
                .ok_or_else(|| err(hl, "\"requires\" is an array of tags"))
        })
        .transpose()?
        .into_iter()
        .flatten()
    {
        let t = t.as_str().ok_or_else(|| err(hl, "a tag is a string"))?;
        if !TAGS.contains(&t) {
            return Err(err(
                hl,
                format!("unknown tag {t:?} (known: {})", TAGS.join(", ")),
            ));
        }
        requires.push(t.to_string());
    }
    let doc = h
        .get("doc")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let mut steps = Vec::new();
    for (line, text) in lines {
        let v: Value =
            serde_json::from_str(text).map_err(|e| err(line, format!("not JSON: {e}")))?;
        let Value::Object(obj) = v else {
            return Err(err(line, "a step is a JSON object"));
        };
        let verb = obj
            .get("do")
            .and_then(Value::as_str)
            .ok_or_else(|| err(line, "a step needs a \"do\" verb"))?
            .to_string();
        if !VERBS.contains(&verb.as_str()) {
            return Err(err(line, format!("unknown verb {verb:?}")));
        }
        steps.push(Step { line, verb, obj });
    }
    Ok(Scenario {
        name: name.to_string(),
        requires,
        doc,
        steps,
    })
}

/// Every `*.jsonl` under `dir`, parsed, in path order.  A file that does not parse is an error naming file and line.
pub fn load_dir(dir: &std::path::Path) -> Result<Vec<Scenario>, String> {
    fn walk(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) -> std::io::Result<()> {
        for e in std::fs::read_dir(dir)? {
            let p = e?.path();
            if p.is_dir() {
                walk(&p, out)?;
            } else if p.extension().is_some_and(|x| x == "jsonl") {
                out.push(p);
            }
        }
        Ok(())
    }
    let mut files = Vec::new();
    walk(dir, &mut files).map_err(|e| format!("{}: {e}", dir.display()))?;
    files.sort();
    files
        .iter()
        .map(|f| {
            let text = std::fs::read_to_string(f).map_err(|e| format!("{}: {e}", f.display()))?;
            parse(&text).map_err(|e| format!("{}:{}: {}", f.display(), e.line, e.msg))
        })
        .collect()
}

/// `*` and `?` globs (the whole name must match).
pub fn glob(pattern: &str, name: &str) -> bool {
    fn go(p: &[u8], n: &[u8]) -> bool {
        match (p.first(), n.first()) {
            (None, None) => true,
            (Some(b'*'), _) => go(&p[1..], n) || (!n.is_empty() && go(p, &n[1..])),
            (Some(b'?'), Some(_)) => go(&p[1..], &n[1..]),
            (Some(a), Some(b)) if a == b => go(&p[1..], &n[1..]),
            _ => false,
        }
    }
    go(pattern.as_bytes(), name.as_bytes())
}

#[derive(Debug, Clone, Default)]
pub struct Host {
    pub lisp_target: bool,
    pub sudo: bool,
    pub linux: bool,
    pub macos: bool,
    pub test_hooks: bool,
    pub fake_backend: bool,
    pub lisp_backend: bool,
    pub perf: bool,
}

#[derive(Debug, PartialEq)]
pub enum Gate {
    Run,
    /// Not selected on this target (a lisp run keeps only `v0` rows): not listed.
    Exclude,
    /// Listed as SKIP; `excused` skips do not fail `--require-all`.
    Skip {
        reason: String,
        excused: bool,
    },
}

pub fn gate(s: &Scenario, h: &Host) -> Gate {
    let has = |t: &str| s.requires.iter().any(|r| r == t);
    if h.lisp_target && !has("v0") {
        return Gate::Exclude;
    }
    let skip = |reason: &str, excused: bool| Gate::Skip {
        reason: reason.to_string(),
        excused,
    };
    if has("linux") && !h.linux {
        return skip("linux only", true);
    }
    if has("macos") && !h.macos {
        return skip("macos only", true);
    }
    if has("sudo") && !h.sudo {
        return skip("needs root or passwordless sudo", true);
    }
    if has("fake-backend") && !h.fake_backend {
        return skip("needs --fake-backend", false);
    }
    if has("lisp-backend") && !h.lisp_backend {
        return skip("needs --lisp-hub", false);
    }
    if has("test-hooks") && !h.test_hooks {
        return skip("the hub binary is built without test-hooks", false);
    }
    if has("perf") && !h.perf {
        return skip("needs --perf", true); // a mode of the run, not a missing capability: --require-all lets it be
    }
    Gate::Run
}

/// Does `CMD -n true` succeed (passwordless sudo)?
pub fn probe_sudo(cmd: &str) -> bool {
    std::process::Command::new(cmd)
        .args(["-n", "true"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// May another uid be used?  Root can; otherwise passwordless sudo (the command is $SUDO, default `sudo`).
pub fn sudo_available() -> bool {
    (unsafe { libc::geteuid() } == 0)
        || probe_sudo(&std::env::var("SUDO").unwrap_or_else(|_| "sudo".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const EVERY_VERB: &str = r#"
{"scenario": "t/every", "requires": ["v0", "v1", "fake-backend", "lisp-backend", "sudo", "test-hooks", "linux", "macos", "perf"], "doc": "d"}
{"do": "start", "hub": "h"}
{"do": "root"}
{"do": "rename", "from": "$ROOT/a", "to": "$ROOT/b"}
{"do": "remove", "path": "$ROOT/b"}
{"do": "install_bin", "to": "$ROOT/bin/x"}
{"do": "run", "capture": "r", "args": ["status"]}
{"do": "spawn", "capture": "s", "argv": ["sleep", "60"]}
{"do": "connect", "conn": "c", "hub": "h", "socket": "main", "as": "user"}
{"do": "hello", "conn": "c", "proof": "valid", "proto": 1, "expect_class": "user"}
{"do": "chmod", "path": "$SOCKET_DIR", "mode": "0711"}
{"do": "send", "conn": "c", "json": {"id": 1, "method": "ping"}}
{"do": "pause", "conn": "c"}
{"do": "expect", "conn": "c", "json": {"id": 1}, "within_ms": 100}
{"do": "expect_next", "conn": "c", "json": {"id": 2}}
{"do": "expect_closed", "conn": "c"}
{"do": "expect_silent", "conn": "c", "for_ms": 50}
{"do": "kill", "hub": "h", "signal": "TERM"}
{"do": "expect_exit", "hub": "h", "code": 0}
{"do": "file", "path": "$CAP", "exists": true, "mode": "0600"}
{"do": "write_file", "path": "$ROOT/x", "text": "t"}
{"do": "sqlite", "path": "$DATA/work.db", "sql": ["select 1"]}
{"do": "backend_log", "expect_line": "x"}
{"do": "pid", "capture": "s", "alive": false}
{"do": "class_matrix", "table": "t.json"}
{"do": "bad_params", "registry": "r.json"}
{"do": "measure", "name": "m", "repeat": 2, "steps": []}
"#;

    #[test]
    fn every_verb_parses() {
        let s = parse(EVERY_VERB).unwrap();
        assert_eq!(s.name, "t/every");
        assert_eq!(s.requires.len(), 9);
        let verbs: Vec<&str> = s.steps.iter().map(|x| x.verb.as_str()).collect();
        for v in VERBS {
            assert!(verbs.contains(&v), "verb {v} did not parse");
        }
        assert_eq!(s.steps[0].line, 3, "steps remember their file line");
    }

    #[test]
    fn unknown_verb_is_an_error_with_its_line() {
        let e = parse("{\"scenario\": \"t/x\"}\n{\"do\": \"start\"}\n{\"do\": \"frobnicate\"}\n")
            .unwrap_err();
        assert_eq!(e.line, 3);
        assert!(e.msg.contains("frobnicate"), "{}", e.msg);
        assert_eq!(parse("not json").unwrap_err().line, 1);
        assert!(
            parse("{\"scenario\": \"t/x\", \"requires\": [\"nonsense\"]}").is_err(),
            "an unknown tag is an error"
        );
    }

    fn row(requires: &str) -> Scenario {
        parse(&format!(
            "{{\"scenario\": \"t/row\", \"requires\": [{requires}]}}\n"
        ))
        .unwrap()
    }

    #[test]
    fn a_sudo_row_is_skipped_without_sudo() {
        let s = row("\"sudo\"");
        let without = Host {
            sudo: probe_sudo("false"),
            linux: true,
            ..Host::default()
        };
        assert!(
            !without.sudo,
            "`false -n true` is the SUDO=false stub: no sudo"
        );
        assert_eq!(
            gate(&s, &without),
            Gate::Skip {
                reason: "needs root or passwordless sudo".into(),
                excused: true
            }
        );
        // where sudo works the row runs, so --require-all has nothing to excuse
        let with = Host {
            sudo: probe_sudo("true"),
            linux: true,
            ..Host::default()
        };
        assert_eq!(gate(&s, &with), Gate::Run);
    }

    #[test]
    fn other_skips_are_not_excused() {
        let host = Host {
            linux: true,
            ..Host::default()
        };
        assert!(matches!(
            gate(&row("\"fake-backend\""), &host),
            Gate::Skip { excused: false, .. }
        ));
        assert!(matches!(
            gate(&row("\"macos\""), &host),
            Gate::Skip { excused: true, .. }
        ));
        let lisp = Host {
            lisp_target: true,
            ..host.clone()
        };
        // the perf rows wait for --perf; a run without it (CI's --require-all) is not failed by them
        assert!(matches!(
            gate(&row("\"perf\""), &host),
            Gate::Skip { excused: true, .. }
        ));
        assert_eq!(gate(&row("\"v1\""), &lisp), Gate::Exclude);
        assert_eq!(gate(&row("\"v0\""), &lisp), Gate::Run);
    }
}
