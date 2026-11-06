//! `ratatoskr-mock acp --replay DIR --as KIND [--speed N] [--misses FILE] [--roots JSON] [--strict]`: an outside
//! agent replayed from a recorded run (docs/develop/recordings.md, "The ACP replayer").  Std and runstav only.
//!
//! - **Streams.** Each `acp/<n>.jsonl` is one recorded connection; the gateway exchanges of its session
//!   (`llm.jsonl`, first attempts) join it at their `seq`.  `in` lines are expectations (what the hub sends);
//!   `out`, `mcp`, `effect`, `llm` and `exit` lines are actions.
//! - **The causal rule.** An action is taken once every expectation before it has arrived and matched, after its
//!   recorded gap times `--speed` (0: no waits).  Expectations are matched in order within an ACP session, freely
//!   across sessions; a message matches on its method and normalized params, an answer to the agent's own request
//!   on its normalized result.  The hub's request ids are mapped to the recorded ones; the agent's are sent as
//!   recorded.  Both sides go through the normalizers (each with its own roots: the manifest's and `--roots`, plus
//!   `$WT`, the cwd its session opened in), the received one through the scrub first.
//! - **Claims.** A process answers from every unclaimed connection that matches so far, and claims the lowest one
//!   at its first session request (`session/new`, `session/fork`, `session/load`, `session/resume`): a lock file
//!   `claims/<n>` beside the misses file.  So a fork or a resume in a second process takes the next connection.
//! - **Actions.** `out` is written (an answer with the hub's id); `mcp` calls the tool through the session's first
//!   `mcpServers` entry; `effect` writes the recorded worktree changes into the session's cwd (files, deletions,
//!   the commits' bundle and the head); `llm` re-sends the agent's recorded model call to its own
//!   `$ANTHROPIC_BASE_URL` with `$ANTHROPIC_AUTH_TOKEN`, through the real gateway; `exit` with a code other than 0
//!   ends the process with it and its stderr (a clean end waits for stdin to close).
//! - **A miss** never improvises: the unmatched request is answered with JSON-RPC error -32099 (`replay miss: …;
//!   re-record`), the expected and received lines and their first differing path go to the misses file, and the
//!   process exits 3.  With `--strict`, recorded lines left unused when stdin closes are a miss too.

use runstav::recording::{self as rec, Normalizer, Roots, Scrub};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The JSON-RPC error code of a miss.
const MISS: i64 = -32099;

/// The requests that open a session: the first one claims a connection.
const OPENERS: [&str; 4] = [
    "session/new",
    "session/fork",
    "session/load",
    "session/resume",
];

#[derive(Clone)]
struct Line {
    seq: u64,
    t_ms: u64,
    dir: String,
    msg: Value,
    done: bool,
}

/// One recorded connection, as far as this process has replayed it.
#[derive(Clone)]
struct Conn {
    n: u64,
    lines: Vec<Line>,
    /// The cwd its first session request named (`$WT`).
    wt: Option<String>,
    /// The agent's own requests: id → the session they name.
    asked: HashMap<String, String>,
    /// The `t_ms` of the last line used (the next action's gap is from it).
    last_t: u64,
}

struct Replay {
    /// The connections this process may still be: one once it has claimed.
    conns: Vec<Conn>,
    claimed: bool,
    dir: PathBuf,
    claims: PathBuf,
    misses: PathBuf,
    speed: f64,
    strict: bool,
    rec_roots: Value,
    live_roots: Value,
    /// The cwd the hub's session request named (`$WT` on this side; the effects land there).
    live_wt: Option<String>,
    /// The recorded hub request ids → the ones this hub used.
    ids: HashMap<String, Value>,
    /// The session's first `mcpServers` entry, as this hub gave it.
    mcp: Option<Value>,
    /// A clean recorded exit: its code, once its line was reached.
    exit: Option<i32>,
}

fn flag(args: &[String], name: &str) -> Option<String> {
    super::flag(args, name)
}

pub fn run(args: &[String]) -> ! {
    let Some(dir) = flag(args, "--replay").map(PathBuf::from) else {
        crate::die(
            "usage: ratatoskr-mock acp --replay DIR --as KIND [--speed N] [--misses FILE] [--roots JSON] [--strict]",
        )
    };
    let manifest = rec::read_manifest(&dir).unwrap_or_else(|e| crate::die(&e));
    let conns = load(&dir, &manifest).unwrap_or_else(|e| crate::die(&e));
    if conns.is_empty() {
        crate::die(&format!(
            "the recording {} has no agent connection",
            dir.display()
        ));
    }
    let misses = flag(args, "--misses")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("DRGNX_RUN_TMP")
                .or_else(|| std::env::var_os("TMPDIR"))
                .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from)
                .join("replay")
                .join("misses.jsonl")
        });
    let live_roots: Value = match flag(args, "--roots") {
        Some(r) => {
            serde_json::from_str(&r).unwrap_or_else(|e| crate::die(&format!("--roots: {e}")))
        }
        None => Roots::of_env(&runstav::paths::Env::process()).to_json(),
    };
    let mut r = Replay {
        conns,
        claimed: false,
        claims: misses
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("claims"),
        misses,
        speed: flag(args, "--speed")
            .and_then(|s| s.parse().ok())
            .unwrap_or(0.0),
        strict: args.iter().any(|a| a == "--strict"),
        rec_roots: manifest.get("roots").cloned().unwrap_or(json!({})),
        live_roots,
        live_wt: None,
        ids: HashMap::new(),
        mcp: None,
        exit: None,
        dir,
    };
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if let Ok(v) = serde_json::from_str::<Value>(&line)
                && tx.send(v).is_err()
            {
                break;
            }
        }
    });
    loop {
        r.act();
        match rx.recv() {
            Ok(m) => r.receive(&m),
            Err(_) => r.finish(),
        }
    }
}

fn read_jsonl(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// The recorded connections of DIR, in their number's order, each with its session's model calls joined.
fn load(dir: &Path, manifest: &Value) -> Result<Vec<Conn>, String> {
    let llm = read_jsonl(&dir.join("llm.jsonl"));
    let mut conns = Vec::new();
    let entries = std::fs::read_dir(dir.join("acp"))
        .map_err(|e| format!("no agent connections in {}: {e}", dir.display()))?;
    for e in entries.flatten() {
        let path = e.path();
        let Some(n) = path
            .file_name()
            .and_then(|f| f.to_str())
            .and_then(|f| f.strip_suffix(".jsonl"))
            .and_then(|n| n.parse::<u64>().ok())
        else {
            continue;
        };
        let mut lines: Vec<Line> = read_jsonl(&path)
            .into_iter()
            .filter_map(|v| {
                Some(Line {
                    seq: v["seq"].as_u64()?,
                    t_ms: v["t_ms"].as_u64().unwrap_or(0),
                    dir: v["dir"].as_str()?.to_owned(),
                    msg: v["msg"].clone(),
                    done: false,
                })
            })
            .collect();
        lines.sort_by_key(|l| l.seq);
        let entry = manifest["connections"]
            .as_array()
            .and_then(|cs| cs.iter().find(|c| c["n"] == n))
            .cloned()
            .unwrap_or(Value::Null);
        let who: Vec<&str> = ["sid", "job"]
            .iter()
            .filter_map(|k| entry[*k].as_str())
            .collect();
        let (first, last) = (
            lines.first().map_or(0, |l| l.seq),
            lines.last().map_or(0, |l| l.seq),
        );
        for x in &llm {
            let seq = x["seq"].as_u64().unwrap_or(0);
            let mine = x["session"].as_str().is_some_and(|s| who.contains(&s));
            if !mine || x["attempt"] != 1 || seq <= first || seq >= last {
                continue;
            }
            let body = x
                .pointer("/client/body")
                .or_else(|| x.pointer("/request/body"))
                .cloned()
                .unwrap_or(Value::Null);
            lines.push(Line {
                seq,
                t_ms: x["t_ms"].as_u64().unwrap_or(0),
                dir: "llm".into(),
                msg: json!({"path": x["path"], "body": body, "headers": x.pointer("/request/headers")}),
                done: false,
            });
        }
        lines.sort_by_key(|l| l.seq);
        let wt = lines
            .iter()
            .find(|l| {
                l.dir == "in"
                    && l.msg["method"]
                        .as_str()
                        .is_some_and(|m| OPENERS.contains(&m))
            })
            .and_then(|l| l.msg.pointer("/params/cwd"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let asked = lines
            .iter()
            .filter(|l| l.dir == "out" && l.msg.get("method").is_some())
            .filter_map(|l| {
                Some((
                    l.msg.get("id")?.to_string(),
                    l.msg.pointer("/params/sessionId")?.as_str()?.to_owned(),
                ))
            })
            .collect();
        conns.push(Conn {
            n,
            lines,
            wt,
            asked,
            last_t: 0,
        });
    }
    conns.sort_by_key(|c| c.n);
    Ok(conns)
}

/// The session a message is about: its `sessionId`, or for an answer to the agent's request, that request's.
fn session_of(m: &Value, asked: &HashMap<String, String>) -> String {
    if let Some(s) = m.pointer("/params/sessionId").and_then(Value::as_str) {
        return s.to_owned();
    }
    match (m.get("method"), m.get("id")) {
        (None, Some(id)) => asked.get(&id.to_string()).cloned().unwrap_or_default(),
        _ => String::new(),
    }
}

/// What of a message is compared: its method and params, or its result or error (never its id).
fn shape(m: &Value) -> Value {
    let mut o = Map::new();
    for k in ["method", "params", "result", "error"] {
        if let Some(v) = m.get(k) {
            o.insert(k.into(), v.clone());
        }
    }
    Value::Object(o)
}

fn roots(base: &Value, wt: Option<&str>) -> Roots {
    let mut pairs: Vec<(String, String)> = base
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(n, p)| Some((n.clone(), p.as_str()?.to_owned())))
        .collect();
    if let Some(w) = wt {
        pairs.push(("$WT".into(), w.to_owned()));
    }
    Roots::new(pairs)
}

/// The first unused expectation of a connection, when every expectation before it is used.
fn next_action(c: &Conn) -> Option<usize> {
    let i = c.lines.iter().position(|l| !l.done)?;
    (c.lines[i].dir != "in").then_some(i)
}

impl Replay {
    /// The first place REC (a recorded line's message) and LIVE (what the hub sent) differ, after the normalizers.
    fn differs(&self, conn: &Conn, rec: &Value, live: &Value) -> Option<String> {
        let (rr, lr) = (
            roots(&self.rec_roots, conn.wt.as_deref()),
            roots(&self.live_roots, self.live_wt.as_deref()),
        );
        let a = Normalizer::new(&rr).value(&shape(rec));
        let b = Normalizer::new(&lr).value(&Scrub::default().value(&shape(live)));
        rec::first_diff(&a, &b)
    }

    /// The line of CONN that M is: the first unused expectation of M's session, when it matches.  Else that
    /// expectation (if any) and the path where it differs.
    fn find(&self, conn: &Conn, m: &Value) -> Result<usize, (Option<usize>, String)> {
        let key = session_of(m, &conn.asked);
        let i = conn
            .lines
            .iter()
            .position(|l| !l.done && l.dir == "in" && session_of(&l.msg, &conn.asked) == key)
            .ok_or((None, String::new()))?;
        match self.differs(conn, &conn.lines[i].msg, m) {
            None => Ok(i),
            Some(path) => Err((Some(i), path)),
        }
    }

    /// A message from the hub: matched against every connection this process may still be; a session request
    /// claims the lowest that matched.
    fn receive(&mut self, m: &Value) {
        let method = m["method"].as_str().map(str::to_owned);
        let opener = method.as_deref().is_some_and(|x| OPENERS.contains(&x));
        if opener {
            if let Some(c) = m.pointer("/params/cwd").and_then(Value::as_str) {
                self.live_wt = Some(c.to_owned());
            }
            self.mcp = m.pointer("/params/mcpServers/0").cloned();
        }
        if !self.claimed {
            let claims = self.claims.clone();
            self.conns
                .retain(|c| !claims.join(c.n.to_string()).exists());
        }
        let mut kept = Vec::new();
        let mut nearest: Option<(u64, Option<Value>, String)> = None;
        for c in std::mem::take(&mut self.conns) {
            match self.find(&c, m) {
                Ok(i) => kept.push((c, i)),
                Err((i, path)) if nearest.is_none() => {
                    nearest = Some((c.n, i.map(|i| c.lines[i].msg.clone()), path));
                }
                Err(_) => {}
            }
        }
        if kept.is_empty() {
            let what = method.as_deref().unwrap_or("an answer");
            match nearest {
                Some((n, Some(expected), path)) => self.miss(
                    m,
                    Some(n),
                    Some(&expected),
                    Some(&path),
                    &format!("{what} differs from the recorded line at {path}"),
                ),
                Some((n, None, _)) => self.miss(
                    m,
                    Some(n),
                    None,
                    None,
                    &format!("{what} was never sent live (nothing more is expected)"),
                ),
                None => self.miss(
                    m,
                    None,
                    None,
                    None,
                    &format!("no unclaimed connection of the recording expects {what}"),
                ),
            }
        }
        for (c, i) in &mut kept {
            c.lines[*i].done = true;
            c.last_t = c.lines[*i].t_ms;
        }
        if method.is_some()
            && let (Some(live), Some(recorded)) =
                (m.get("id"), kept[0].0.lines[kept[0].1].msg.get("id"))
        {
            self.ids.insert(recorded.to_string(), live.clone());
        }
        self.conns = kept.into_iter().map(|(c, _)| c).collect();
        if opener && !self.claimed {
            self.claim(m);
        }
    }

    /// Take the lowest connection still possible whose claim file this process can make.
    fn claim(&mut self, m: &Value) {
        let _ = std::fs::create_dir_all(&self.claims);
        let pick = self.conns.iter().position(|c| {
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(self.claims.join(c.n.to_string()))
                .is_ok()
        });
        match pick {
            Some(i) => {
                let c = self.conns.swap_remove(i);
                self.conns = vec![c];
                self.claimed = true;
            }
            None => self.miss(
                m,
                None,
                None,
                None,
                "no unclaimed connection of the recording opens like this",
            ),
        }
    }

    /// Every action whose expectations have all arrived, in order (before a claim, the first candidate's; the
    /// others keep step).
    fn act(&mut self) {
        while let Some(j) = next_action(&self.conns[0]) {
            let line = self.conns[0].lines[j].clone();
            let gap = line.t_ms.saturating_sub(self.conns[0].last_t);
            if self.speed > 0.0 && gap > 0 {
                std::thread::sleep(Duration::from_secs_f64(gap as f64 * self.speed / 1000.0));
            }
            for c in &mut self.conns {
                if let Some(k) = next_action(c) {
                    c.lines[k].done = true;
                    c.last_t = c.lines[k].t_ms;
                }
            }
            self.perform(&line);
        }
    }

    /// V as this run sends it: the recorded run's roots (raw paths, or the `$STATE`-style names an exported recording
    /// holds) and its session's cwd (`$WT`) replaced by this run's, so a recording made under one root replays under
    /// another.
    fn to_live(&self, v: &Value) -> Value {
        let mut pairs: Vec<(String, String)> = Vec::new();
        for (name, p) in self.rec_roots.as_object().into_iter().flatten() {
            if let (Some(rec), Some(live)) = (p.as_str(), self.live_roots[name].as_str()) {
                pairs.push((rec.to_owned(), live.to_owned()));
                pairs.push((name.clone(), live.to_owned()));
            }
        }
        if let (Some(rec), Some(live)) = (
            self.conns.first().and_then(|c| c.wt.as_deref()),
            self.live_wt.as_deref(),
        ) {
            pairs.push((rec.to_owned(), live.to_owned()));
            pairs.push(("$WT".to_owned(), live.to_owned()));
        }
        pairs.retain(|(from, to)| !from.is_empty() && from != to);
        pairs.sort_by_key(|(from, _)| std::cmp::Reverse(from.len()));
        fn walk(v: &Value, pairs: &[(String, String)]) -> Value {
            match v {
                Value::String(s) => {
                    Value::String(pairs.iter().fold(s.clone(), |t, (f, to)| t.replace(f, to)))
                }
                Value::Array(a) => Value::Array(a.iter().map(|x| walk(x, pairs)).collect()),
                Value::Object(o) => {
                    Value::Object(o.iter().map(|(k, x)| (k.clone(), walk(x, pairs))).collect())
                }
                other => other.clone(),
            }
        }
        walk(v, &pairs)
    }

    fn perform(&mut self, line: &Line) {
        match line.dir.as_str() {
            "out" => {
                let mut m = self.to_live(&line.msg);
                if m.get("method").is_none()
                    && let Some(live) = m.get("id").and_then(|id| self.ids.get(&id.to_string()))
                {
                    m["id"] = live.clone();
                }
                super::send(&m);
            }
            "mcp" => {
                let tool = line.msg["tool"].as_str().unwrap_or_default();
                let args = self.to_live(&line.msg["args"]).to_string();
                let _ = super::mcp_call(self.mcp.as_ref(), tool, &args);
            }
            "effect" => self.effect(line),
            "llm" => self.resend(line),
            "exit" => {
                if let Some(s) = line.msg["stderr"].as_str() {
                    eprint!("{s}");
                }
                match line.msg["code"].as_i64() {
                    Some(c) if c != 0 => std::process::exit(c as i32),
                    _ => self.exit = Some(0),
                }
            }
            _ => {}
        }
    }

    /// The recorded worktree changes of LINE, into the session's cwd: files, deletions, then the commits and the head.
    fn effect(&self, line: &Line) {
        let Some(wt) = self.live_wt.as_deref().map(PathBuf::from) else {
            return;
        };
        let from = self.dir.join(line.msg["path"].as_str().unwrap_or_default());
        let files = from.join("files");
        let mut dirs = vec![files.clone()];
        while let Some(d) = dirs.pop() {
            for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
                let p = e.path();
                if p.is_dir() {
                    dirs.push(p);
                } else if let Ok(rel) = p.strip_prefix(&files) {
                    let to = wt.join(rel);
                    if let Some(parent) = to.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    if let Err(e) = std::fs::copy(&p, &to) {
                        eprintln!("ratatoskr-mock: cannot write {}: {e}", to.display());
                    }
                }
            }
        }
        for gone in std::fs::read_to_string(from.join("deleted.txt"))
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.is_empty())
        {
            let _ = std::fs::remove_file(wt.join(gone));
        }
        let Some(head) = line.msg["head"].as_str() else {
            return;
        };
        let bundle = from.join("commits.bundle");
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&wt)
                .args(args)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
        };
        let b = bundle.to_string_lossy().into_owned();
        let unbundled = !bundle.exists() || git(&["bundle", "unbundle", b.as_str()]);
        if !(unbundled && git(&["update-ref", "HEAD", head]) && git(&["read-tree", "HEAD"])) {
            self.miss(
                &json!({}),
                Some(self.conns[0].n),
                Some(&line.msg),
                None,
                &format!(
                    "the recorded head {head} cannot be restored in {} (the worktree did not start where live did)",
                    wt.display()
                ),
            );
        }
    }

    /// The agent's recorded model call, re-sent to its own gateway (which forwards it to the LLM replayer).
    fn resend(&self, line: &Line) {
        let Ok(base) = std::env::var("ANTHROPIC_BASE_URL") else {
            self.miss(
                &json!({}),
                Some(self.conns[0].n),
                Some(&line.msg),
                None,
                "a recorded model call, and no ANTHROPIC_BASE_URL to re-send it to",
            )
        };
        let token = std::env::var("ANTHROPIC_AUTH_TOKEN").unwrap_or_default();
        let url = format!(
            "{}{}",
            base.trim_end_matches('/'),
            line.msg["path"].as_str().unwrap_or("/v1/messages")
        );
        let rest = url.strip_prefix("http://").unwrap_or(&url);
        let (hostport, path) = match rest.split_once('/') {
            Some((h, p)) => (h, format!("/{p}")),
            None => (rest, "/".to_owned()),
        };
        let body = rec::body_bytes(&line.msg["body"]).unwrap_or_default();
        let mut head = format!(
            "POST {path} HTTP/1.1\r\nHost: {hostport}\r\nAuthorization: Bearer {token}\r\nContent-Length: {}\r\nConnection: close\r\n",
            body.len()
        );
        for (k, v) in line.msg["headers"].as_object().into_iter().flatten() {
            if matches!(
                k.as_str(),
                "content-type" | "anthropic-version" | "anthropic-beta" | "accept"
            ) && let Some(v) = v.as_str()
            {
                head.push_str(&format!("{k}: {v}\r\n"));
            }
        }
        head.push_str("\r\n");
        let Ok(mut s) = std::net::TcpStream::connect(hostport) else {
            eprintln!("ratatoskr-mock: cannot reach the gateway at {hostport}");
            return;
        };
        let _ = s.set_read_timeout(Some(Duration::from_secs(60)));
        if s.write_all(head.as_bytes())
            .and_then(|()| s.write_all(&body))
            .is_err()
        {
            return;
        }
        // read it to its end, as the agent did: the turn goes on once the model has answered
        let mut sink = Vec::new();
        let _ = s.read_to_end(&mut sink);
    }

    /// A line in the misses file, the request (if M is one) answered -32099, and the end (exit 3).
    fn miss(
        &self,
        m: &Value,
        n: Option<u64>,
        expected: Option<&Value>,
        path: Option<&str>,
        why: &str,
    ) -> ! {
        let line = json!({"connection": n, "code": MISS, "why": why, "path": path,
            "expected": expected, "received": Scrub::default().value(m)});
        if let Some(parent) = self.misses.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.misses)
        {
            Ok(mut f) => {
                let _ = f.write_all(format!("{line}\n").as_bytes());
            }
            Err(e) => eprintln!(
                "ratatoskr-mock: cannot write {}: {e}",
                self.misses.display()
            ),
        }
        eprintln!("ratatoskr-mock: replay miss: {why}");
        if m.get("method").is_some()
            && let Some(id) = m.get("id")
        {
            super::rpc_error(id, MISS, &format!("replay miss: {why}; re-record"));
        }
        std::process::exit(3)
    }

    /// Stdin closed: with `--strict`, recorded lines never used are a miss; else the recorded clean exit.
    fn finish(&mut self) -> ! {
        if self.strict && self.claimed {
            let c = &self.conns[0];
            let left: Vec<u64> = c
                .lines
                .iter()
                .filter(|l| !l.done && l.dir != "exit")
                .map(|l| l.seq)
                .collect();
            if let Some(first) = left.first() {
                self.miss(
                    &json!({}),
                    Some(c.n),
                    None,
                    None,
                    &format!(
                        "{} recorded lines were never used (the first: seq {first}): the replay did less than live",
                        left.len()
                    ),
                );
            }
        }
        std::process::exit(self.exit.unwrap_or(0))
    }
}
