//! Running one scenario: every verb of the format (docs/develop/runtime.md).

use crate::hub::{self, Conn, Hub, Root, StartSpec, client_proof, hub_proof, random_hex};
use crate::matcher::{self, Captures};
use crate::scenario::{Scenario, Step};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub struct Config {
    pub lisp_target: bool,
    pub hub_bin: PathBuf,
    pub lisp_hub: Option<PathBuf>,
    pub fake_backend: Option<PathBuf>,
}

pub struct Runner<'a> {
    cfg: &'a Config,
    requires: Vec<String>,
    hubs: Vec<Hub>,
    conns: BTreeMap<String, Conn>,
    spawned: BTreeMap<String, Child>,
    caps: Captures,
    perf: &'a mut Vec<(String, Vec<f64>)>,
    started: usize,
}

type R<T = ()> = Result<T, String>;

/// Longest first, so `$SOCKET_DIR` is not read as `$SOCKET` and `_DIR`.
const VAR_NAMES: [&str; 11] = [
    "SOCKET_DIR",
    "HARNESS_PID",
    "SOCKET",
    "CONFIG",
    "STATE",
    "ROOT",
    "HOME",
    "DATA",
    "LOCK",
    "CAP",
    "RUN",
];

/// Run `scenario`; the error says which step failed and why.  Every hub, helper and root is gone afterwards.
pub fn run_scenario(cfg: &Config, s: &Scenario, perf: &mut Vec<(String, Vec<f64>)>) -> R {
    let mut r = Runner {
        cfg,
        requires: s.requires.clone(),
        hubs: vec![],
        conns: BTreeMap::new(),
        spawned: BTreeMap::new(),
        caps: Captures::default(),
        perf,
        started: 0,
    };
    for (i, step) in s.steps.iter().enumerate() {
        r.step(step)
            .map_err(|e| format!("step {} ({}): {e}", i + 1, step.verb))?;
    }
    Ok(())
}

impl Drop for Runner<'_> {
    fn drop(&mut self) {
        self.conns.clear();
        for h in &mut self.hubs {
            h.terminate();
        }
        for c in self.spawned.values_mut() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn str_of<'a>(o: &'a Map<String, Value>, k: &str) -> Option<&'a str> {
    o.get(k).and_then(Value::as_str)
}

fn ms(o: &Map<String, Value>, k: &str, default: u64) -> Duration {
    Duration::from_millis(o.get(k).and_then(Value::as_u64).unwrap_or(default))
}

fn signal_number(name: &str) -> R<i32> {
    let n = name.trim_start_matches("SIG");
    Ok(match n {
        "TERM" => libc::SIGTERM,
        "KILL" => libc::SIGKILL,
        "STOP" => libc::SIGSTOP,
        "CONT" => libc::SIGCONT,
        "INT" => libc::SIGINT,
        "HUP" => libc::SIGHUP,
        "QUIT" => libc::SIGQUIT,
        "USR1" => libc::SIGUSR1,
        "USR2" => libc::SIGUSR2,
        _ => return Err(format!("unknown signal {name}")),
    })
}

/// A process's start time as the system prints it (to tell a pid reused later from the process captured).
pub fn start_time(pid: u32) -> Option<String> {
    if let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        let after = stat.rsplit_once(')')?.1;
        return after.split_whitespace().nth(19).map(str::to_string);
    }
    let out = Command::new("ps")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    let t = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!t.is_empty()).then_some(t)
}

/// Whether `schema` (a property of `root`'s, `$ref`s resolved against its `$defs`) takes a list: then the wrong type
/// `bad_params` sends is `true`, else `[]`.
fn accepts_array(root: &Value, schema: &Value) -> bool {
    if let Some(r) = schema.get("$ref").and_then(Value::as_str) {
        let name = r.trim_start_matches("#/$defs/");
        return accepts_array(root, &root["$defs"][name]);
    }
    let typed = match schema.get("type") {
        Some(Value::String(t)) => t == "array",
        Some(Value::Array(ts)) => ts.iter().any(|t| t == "array"),
        _ => false,
    };
    typed
        || ["anyOf", "oneOf"].iter().any(|k| {
            schema
                .get(*k)
                .and_then(Value::as_array)
                .is_some_and(|alts| alts.iter().any(|a| accepts_array(root, a)))
        })
}

fn is_zombie(pid: u32) -> bool {
    if let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        return stat
            .rsplit_once(')')
            .is_some_and(|(_, rest)| rest.trim_start().starts_with('Z'));
    }
    Command::new("ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .is_ok_and(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim_start()
                .starts_with('Z')
        })
}

impl Runner<'_> {
    // ------------------------------------------------------------ names, variables, captures

    fn hub_index(&self, name: Option<&str>) -> R<usize> {
        match name {
            Some(n) => self
                .hubs
                .iter()
                .rposition(|h| h.name == n)
                .ok_or_else(|| format!("no hub named {n:?} was started")),
            None => self
                .hubs
                .len()
                .checked_sub(1)
                .ok_or_else(|| "no hub was started".to_string()),
        }
    }

    fn vars_of(&self, hub: Option<usize>) -> BTreeMap<String, String> {
        let mut m: BTreeMap<String, String> = hub
            .and_then(|i| self.hubs.get(i))
            .map(|h| {
                h.vars()
                    .into_iter()
                    .map(|(k, v)| (k.to_string(), v))
                    .collect()
            })
            .unwrap_or_default();
        m.insert("HARNESS_PID".into(), std::process::id().to_string());
        m
    }

    fn capture_text(v: &Value) -> String {
        v.as_str().map_or_else(|| v.to_string(), str::to_string)
    }

    /// Replace `$ROOT $HOME $RUN...` and `$PID(hub)` (and, with `captures`, `$NAME`) in a string.  A string that is
    /// just a pid, or just a capture, keeps its JSON type.
    fn subst_str(&self, hub: Option<usize>, s: &str, captures: bool) -> Value {
        let vars = self.vars_of(hub);
        let pid_of = |name: &str| {
            self.hubs
                .iter()
                .rposition(|h| h.name == name)
                .map(|i| self.hubs[i].pid)
        };
        if s == "$HARNESS_PID" {
            return json!(std::process::id());
        }
        if let Some(name) = s
            .strip_prefix("$PID(")
            .and_then(|r| r.strip_suffix(')'))
            .filter(|n| !n.contains(')'))
            && let Some(p) = pid_of(name)
        {
            return json!(p);
        }
        if captures && let Some(v) = s.strip_prefix('$').and_then(|n| self.caps.0.get(n)) {
            return v.clone();
        }
        let mut out = String::new();
        let mut rest = s;
        while let Some(pos) = rest.find('$') {
            out.push_str(&rest[..pos]);
            rest = &rest[pos..];
            if let Some(r) = rest.strip_prefix("$PID(")
                && let Some((name, after)) = r.split_once(')')
                && let Some(p) = pid_of(name)
            {
                out.push_str(&p.to_string());
                rest = after;
                continue;
            }
            if let Some(name) = VAR_NAMES.iter().find(|n| rest[1..].starts_with(**n))
                && let Some(v) = vars.get(*name)
            {
                out.push_str(v);
                rest = &rest[1 + name.len()..];
                continue;
            }
            if captures {
                let n: String = rest[1..]
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                    .collect();
                if let Some(v) = self.caps.0.get(&n) {
                    out.push_str(&Self::capture_text(v));
                    rest = &rest[1 + n.len()..];
                    continue;
                }
            }
            out.push('$');
            rest = &rest[1..];
        }
        out.push_str(rest);
        Value::String(out)
    }

    fn subst(&self, hub: Option<usize>, v: &Value, captures: bool) -> Value {
        match v {
            Value::String(s) => self.subst_str(hub, s, captures),
            Value::Array(a) => {
                Value::Array(a.iter().map(|x| self.subst(hub, x, captures)).collect())
            }
            Value::Object(o) => Value::Object(
                o.iter()
                    .map(|(k, x)| (k.clone(), self.subst(hub, x, captures)))
                    .collect(),
            ),
            other => other.clone(),
        }
    }

    fn text(&self, hub: Option<usize>, step: &Step, key: &str) -> R<String> {
        let v = step
            .obj
            .get(key)
            .ok_or_else(|| format!("the step needs \"{key}\""))?;
        match self.subst(hub, v, true) {
            Value::String(s) => Ok(s),
            other => Ok(other.to_string()),
        }
    }

    fn strings(&self, hub: Option<usize>, step: &Step, key: &str) -> R<Vec<String>> {
        let Some(v) = step.obj.get(key) else {
            return Ok(vec![]);
        };
        let a = v
            .as_array()
            .ok_or_else(|| format!("\"{key}\" is an array of strings"))?;
        Ok(a.iter()
            .map(|x| Self::capture_text(&self.subst(hub, x, true)))
            .collect())
    }

    fn env_pairs(&self, hub: Option<usize>, step: &Step) -> R<Vec<(String, String)>> {
        let Some(v) = step.obj.get("env") else {
            return Ok(vec![]);
        };
        let o = v.as_object().ok_or("\"env\" is an object")?;
        Ok(o.iter()
            .map(|(k, x)| (k.clone(), Self::capture_text(&self.subst(hub, x, true))))
            .collect())
    }

    fn bin(&self, step: &Step) -> R<PathBuf> {
        match str_of(&step.obj, "bin").unwrap_or("under-test") {
            "under-test" => Ok(self.cfg.hub_bin.clone()),
            "lisp" => self
                .cfg
                .lisp_hub
                .clone()
                .ok_or_else(|| "bin \"lisp\" needs --lisp-hub".to_string()),
            other => Err(format!(
                "\"bin\" is \"under-test\" or \"lisp\", not {other:?}"
            )),
        }
    }

    fn pid_arg(&self, step: &Step) -> R<u32> {
        if let Some(h) = str_of(&step.obj, "hub") {
            return Ok(self.hubs[self.hub_index(Some(h))?].pid);
        }
        match step.obj.get("pid") {
            Some(Value::Number(n)) => n
                .as_u64()
                .map(|p| p as u32)
                .ok_or_else(|| "bad pid".to_string()),
            Some(Value::String(name)) => self
                .caps
                .0
                .get(name.trim_start_matches('$'))
                .and_then(Value::as_u64)
                .map(|p| p as u32)
                .ok_or_else(|| format!("no pid captured as {name:?}")),
            _ => self.hub_index(None).map(|i| self.hubs[i].pid),
        }
    }

    fn process_alive(&mut self, name: Option<&str>, pid: u32) -> bool {
        if let Some(h) = self.hubs.iter_mut().find(|h| h.pid == pid) {
            return h.exited().is_none();
        }
        if let Some(c) = name.and_then(|n| self.spawned.get_mut(n)) {
            return c.try_wait().ok().flatten().is_none();
        }
        if unsafe { libc::kill(pid as i32, 0) } != 0 || is_zombie(pid) {
            return false;
        }
        match name
            .and_then(|n| self.caps.0.get(&format!("{n}_start")))
            .and_then(Value::as_str)
        {
            Some(want) => start_time(pid).is_some_and(|t| t == want),
            None => true,
        }
    }

    // ------------------------------------------------------------ steps

    fn step(&mut self, step: &Step) -> R {
        match step.verb.as_str() {
            "start" => self.start(step),
            "run" => self.run(step),
            "spawn" => self.spawn(step),
            "connect" => self.connect(step),
            "hello" => self.hello(step),
            "chmod" => self.chmod(step),
            "send" => self.send(step),
            "expect" | "expect_next" => self.expect(step),
            "expect_closed" => self
                .conn(step)?
                .expect_closed(ms(&step.obj, "within_ms", 5000)),
            "expect_silent" => self.conn(step)?.expect_silent(ms(&step.obj, "for_ms", 300)),
            "kill" => self.kill(step),
            "expect_exit" => self.expect_exit(step),
            "file" => self.file(step),
            "write_file" => self.write_file(step),
            "sqlite" => self.sqlite(step),
            "backend_log" => self.backend_log(step),
            "pid" => self.pid(step),
            "class_matrix" => {
                Err("class_matrix is filled by the hello task (14): no table reader yet".into())
            }
            "bad_params" => self.bad_params(step),
            "measure" => self.measure(step),
            v => Err(format!("verb {v} has no executor")),
        }
    }

    fn conn(&mut self, step: &Step) -> R<&mut Conn> {
        let name = str_of(&step.obj, "conn").unwrap_or("c").to_string();
        self.conns
            .get_mut(&name)
            .ok_or_else(|| format!("no connection named {name:?}"))
    }

    fn start(&mut self, step: &Step) -> R {
        let name = str_of(&step.obj, "hub").unwrap_or("hub").to_string();
        let bin = self.bin(step)?;
        let same = str_of(&step.obj, "same_root_as")
            .map(|n| self.hub_index(Some(n)))
            .transpose()?;
        let root = match same {
            Some(i) => Arc::clone(&self.hubs[i].root),
            None => Root::new()?,
        };
        // variables that exist before the hub does: the root's own directories
        let r = root.path().to_string_lossy().into_owned();
        let pre: BTreeMap<&str, String> = BTreeMap::from([
            ("ROOT", r.clone()),
            ("HOME", format!("{r}/home")),
            ("RUN", format!("{r}/run")),
            ("DATA", format!("{r}/data")),
            ("CONFIG", format!("{r}/config")),
            ("STATE", format!("{r}/state/drgnx")),
        ]);
        let pre_sub = |s: String| -> String {
            let mut out = s;
            for (k, v) in &pre {
                out = out.replace(&format!("${k}"), v);
            }
            out
        };
        let args: Vec<String> = self
            .strings(None, step, "args")?
            .into_iter()
            .map(pre_sub)
            .collect();
        let mut env: Vec<(String, String)> = self
            .env_pairs(None, step)?
            .into_iter()
            .map(|(k, v)| (k, pre_sub(v)))
            .collect();
        if !self.cfg.lisp_target {
            if self.requires.iter().any(|t| t == "lisp-backend") {
                if let Some(p) = &self.cfg.lisp_hub {
                    env.push((
                        "DRGNX_RATATOSKR_BACKEND".into(),
                        p.to_string_lossy().into_owned(),
                    ));
                }
            } else if self.requires.iter().any(|t| t == "fake-backend")
                && let Some(p) = &self.cfg.fake_backend
            {
                env.push((
                    "DRGNX_RATATOSKR_BACKEND".into(),
                    p.to_string_lossy().into_owned(),
                ));
            }
        }
        self.started += 1;
        let mut hub = Hub::start(StartSpec {
            name: &name,
            root,
            bin: &bin,
            args,
            env,
            parent_pid: std::process::id(),
            index: self.started,
        })?;
        let ready = if step
            .obj
            .get("wait")
            .and_then(Value::as_bool)
            .unwrap_or(true)
        {
            hub.wait_ready(Duration::from_secs(10))
        } else {
            Ok(())
        };
        self.hubs.push(hub);
        ready
    }

    fn run(&mut self, step: &Step) -> R {
        let bin = self.bin(step)?;
        let idx = match str_of(&step.obj, "hub") {
            Some(n) => Some(self.hub_index(Some(n))?),
            None => self.hub_index(None).ok(),
        };
        let root = match idx {
            Some(i) => Arc::clone(&self.hubs[i].root),
            None => Root::new()?,
        };
        let args = self.strings(idx, step, "args")?;
        let env = root.base_env(self.env_pairs(idx, step)?);
        self.started += 1;
        let (out_path, err_path) = (
            root.path().join(format!("run-{}.out", self.started)),
            root.path().join(format!("run-{}.err", self.started)),
        );
        let mut child = Command::new(&bin)
            .args(&args)
            .env_clear()
            .envs(&env)
            .current_dir(root.path())
            .stdin(Stdio::null())
            .stdout(std::fs::File::create(&out_path).map_err(|e| e.to_string())?)
            .stderr(std::fs::File::create(&err_path).map_err(|e| e.to_string())?)
            .spawn()
            .map_err(|e| format!("cannot run {}: {e}", bin.display()))?;
        let deadline = Instant::now() + Duration::from_secs(30);
        let status = loop {
            if let Some(s) = child.try_wait().map_err(|e| e.to_string())? {
                break s;
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "{} {} did not end within 30 s",
                    bin.display(),
                    args.join(" ")
                ));
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let stdout = std::fs::read_to_string(&out_path).unwrap_or_default();
        let stderr = std::fs::read_to_string(&err_path).unwrap_or_default();
        let code = status.code();
        if let Some(name) = str_of(&step.obj, "capture") {
            self.caps.0.insert(name.to_string(), json!({"stdout": stdout, "code": code, "json": serde_json::from_str::<Value>(&stdout).ok()}));
        }
        if let Some(want) = step.obj.get("expect_code").and_then(Value::as_i64)
            && code != Some(want as i32)
        {
            return Err(format!(
                "exit code {code:?}, wanted {want}; stdout: {} stderr: {}",
                stdout.trim(),
                stderr.trim()
            ));
        }
        if let Some(want) = step.obj.get("expect_stdout") {
            let want = self.subst(idx, want, false);
            match &want {
                Value::String(s) if !stdout.contains(s.as_str()) => {
                    return Err(format!("stdout lacks {s:?}: {}", stdout.trim()));
                }
                Value::String(_) => {}
                pattern => {
                    let got: Value = serde_json::from_str(&stdout)
                        .map_err(|_| format!("stdout is not JSON: {}", stdout.trim()))?;
                    matcher::matches(pattern, &got, &mut self.caps)
                        .map_err(|e| format!("stdout: {e}"))?;
                }
            }
        }
        Ok(())
    }

    fn spawn(&mut self, step: &Step) -> R {
        let argv = self.strings(None, step, "argv")?;
        let (prog, rest) = argv.split_first().ok_or("\"argv\" needs a program")?;
        let child = Command::new(prog)
            .args(rest)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("cannot start {prog}: {e}"))?;
        let name = str_of(&step.obj, "capture")
            .ok_or("\"capture\" names the pid")?
            .to_string();
        self.caps.0.insert(name.clone(), json!(child.id()));
        if let Some(t) = start_time(child.id()) {
            self.caps.0.insert(format!("{name}_start"), json!(t));
        }
        self.spawned.insert(name, child);
        Ok(())
    }

    fn connect(&mut self, step: &Step) -> R {
        let idx = self.hub_index(str_of(&step.obj, "hub"))?;
        let name = str_of(&step.obj, "conn").unwrap_or("c").to_string();
        let hub = &self.hubs[idx];
        let path = match str_of(&step.obj, "socket").unwrap_or("main") {
            "main" => hub.socket.clone(),
            s if s.starts_with("agent:") => {
                let hash = hub
                    .socket
                    .file_stem()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                hub.socket_dir()
                    .join(format!("{hash}.d"))
                    .join(format!("agent-{}.sock", &s[6..]))
            }
            other => {
                return Err(format!(
                    "\"socket\" is \"main\" or \"agent:SID\", not {other:?}"
                ));
            }
        };
        let who = str_of(&step.obj, "as").unwrap_or("user");
        let conn = match who {
            "user" | "service" => Conn::open(&path, Duration::from_secs(2))?,
            "other-uid" => {
                if !crate::scenario::sudo_available() {
                    return Err("\"other-uid\" needs root or passwordless sudo".into());
                }
                Conn::open_as_other_uid(&path, hub.root.path())?
            }
            other => {
                return Err(format!(
                    "\"as\" is user, service or other-uid, not {other:?}"
                ));
            }
        };
        self.conns.insert(name.clone(), conn);
        if who == "user" && !self.cfg.lisp_target {
            let cap = self.hubs[idx].cap();
            let conn = self.conns.get_mut(&name).expect("just inserted");
            Self::do_hello(
                conn,
                &cap,
                &HelloSpec {
                    proof: Proof::Valid,
                    proto: 1,
                    class: Some("user".into()),
                    error: None,
                },
                &mut self.caps,
                None,
            )?;
        }
        Ok(())
    }

    fn hello(&mut self, step: &Step) -> R {
        if self.cfg.lisp_target {
            return Err("hello is a v1 verb: it has no meaning against --target lisp".into());
        }
        let idx = self.hub_index(str_of(&step.obj, "hub")).ok();
        let proof = match str_of(&step.obj, "proof").unwrap_or("valid") {
            "valid" => Proof::Valid,
            "wrong" => Proof::Wrong,
            "none" => Proof::None,
            r if r.starts_with("replay:") => Proof::Replay(r[7..].to_string()),
            other => {
                return Err(format!(
                    "\"proof\" is valid, wrong, none or replay:NAME, not {other:?}"
                ));
            }
        };
        let spec = HelloSpec {
            proof,
            proto: step.obj.get("proto").and_then(Value::as_u64).unwrap_or(1),
            class: str_of(&step.obj, "expect_class").map(str::to_string),
            error: str_of(&step.obj, "expect_error").map(str::to_string),
        };
        let cap = idx.map(|i| self.hubs[i].cap()).unwrap_or_default();
        let capture = str_of(&step.obj, "capture").map(str::to_string);
        let name = str_of(&step.obj, "conn").unwrap_or("c").to_string();
        let conn = self
            .conns
            .get_mut(&name)
            .ok_or_else(|| format!("no connection named {name:?}"))?;
        Self::do_hello(conn, &cap, &spec, &mut self.caps, capture.as_deref())
    }

    /// The v1 hello macro: read the challenge, send `hello` with the proof, check the class and (for a valid proof) the hub's proof.
    fn do_hello(
        conn: &mut Conn,
        cap_file: &Path,
        spec: &HelloSpec,
        caps: &mut Captures,
        capture: Option<&str>,
    ) -> R {
        let hub_nonce = conn.challenge(Duration::from_secs(5))?;
        let client_nonce = random_hex(16);
        let cap = std::fs::read_to_string(cap_file)
            .map(|t| t.trim().to_string())
            .unwrap_or_default();
        let id = conn.next_id;
        conn.next_id += 1;
        let line = if let Proof::Replay(name) = &spec.proof {
            Self::capture_text(
                caps.0
                    .get(name)
                    .ok_or_else(|| format!("no line captured as {name:?}"))?,
            )
        } else {
            let mut params =
                json!({"proto": spec.proto, "nonce": client_nonce, "client": "conformance"});
            match &spec.proof {
                Proof::Valid => {
                    params["proof"] = json!(client_proof(&cap, &hub_nonce, &client_nonce))
                }
                Proof::Wrong => params["proof"] = json!("0".repeat(64)),
                _ => {}
            }
            json!({"id": id, "method": "hello", "params": params}).to_string()
        };
        if let Some(name) = capture {
            caps.0.insert(name.to_string(), Value::String(line.clone()));
        }
        conn.send_line(&line, true)?;
        let reply_id = serde_json::from_str::<Value>(&line)
            .ok()
            .map_or(json!(id), |v| v["id"].clone());
        let reply = conn.expect(
            &json!({"id": reply_id}),
            Duration::from_secs(5),
            &mut Captures::default(),
        )?;
        if let Some(err) = reply.get("error") {
            return match &spec.error {
                Some(code) if err["code"] == json!(code) => Ok(()),
                Some(code) => Err(format!("hello was refused with {err}, wanted code {code}")),
                None => Err(format!("hello was refused: {err}")),
            };
        }
        if let Some(code) = &spec.error {
            return Err(format!(
                "hello was answered, wanted the error {code}: {reply}"
            ));
        }
        let result = &reply["result"];
        if let Some(class) = &spec.class
            && result["class"] != json!(class)
        {
            return Err(format!(
                "hello made the connection {}, wanted {class:?}",
                result["class"]
            ));
        }
        if matches!(spec.proof, Proof::Valid) {
            let want = hub_proof(&cap, &client_nonce, &hub_nonce);
            if result["proof"] != json!(want) {
                return Err(format!(
                    "the hub's proof is {}, wanted {want}",
                    result["proof"]
                ));
            }
        }
        Ok(())
    }

    fn chmod(&mut self, step: &Step) -> R {
        let idx = self.hub_index(str_of(&step.obj, "hub")).ok();
        let path = self.text(idx, step, "path")?;
        let mode = str_of(&step.obj, "mode").ok_or("\"mode\" is an octal string")?;
        let bits = u32::from_str_radix(mode, 8).map_err(|_| format!("bad mode {mode:?}"))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(bits))
            .map_err(|e| format!("chmod {path}: {e}"))
    }

    fn send(&mut self, step: &Step) -> R {
        let idx = self.hub_index(None).ok();
        let (data, newline): (Vec<u8>, bool) = if let Some(j) = step.obj.get("json") {
            (self.subst(idx, j, true).to_string().into_bytes(), true)
        } else if step.obj.contains_key("raw") {
            let nl = !step
                .obj
                .get("no_newline")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            (self.text(idx, step, "raw")?.into_bytes(), nl)
        } else if let Some(b) = step.obj.get("bytes").and_then(Value::as_object) {
            let fill = str_of(b, "fill").unwrap_or("a");
            let n = b
                .get("n")
                .and_then(Value::as_u64)
                .ok_or("bytes needs \"n\"")? as usize;
            (
                fill.repeat(n).into_bytes(),
                b.get("newline").and_then(Value::as_bool).unwrap_or(true),
            )
        } else {
            return Err("send needs one of json, raw, bytes".into());
        };
        let mut data = data;
        if newline {
            data.push(b'\n');
        }
        self.conn(step)?.send_bytes(&data)
    }

    fn expect(&mut self, step: &Step) -> R {
        let idx = self.hub_index(None).ok();
        let pattern = self.subst(
            idx,
            step.obj.get("json").ok_or("expect needs \"json\"")?,
            false,
        );
        let within = ms(&step.obj, "within_ms", 5000);
        let name = str_of(&step.obj, "conn").unwrap_or("c").to_string();
        let conn = self
            .conns
            .get_mut(&name)
            .ok_or_else(|| format!("no connection named {name:?}"))?;
        if step.verb == "expect" {
            conn.expect(&pattern, within, &mut self.caps)
        } else {
            conn.expect_next(&pattern, within, &mut self.caps)
        }
        .map(|_| ())
    }

    /// Every method of `registry` (`methods.json`; a relative path is from the current directory) with required
    /// params gets `{}` and a wrong type for its first required key, on `conn`.  Each must be refused
    /// `invalid-params` with a `path`: for `{}` one of the required keys, for the wrong type that key.  `hello`, which
    /// a connection says once, goes on a fresh connection each time.
    fn bad_params(&mut self, step: &Step) -> R {
        let file = self.text(None, step, "registry")?;
        let text = std::fs::read_to_string(&file).map_err(|e| format!("{file}: {e}"))?;
        let reg: Value = serde_json::from_str(&text).map_err(|e| format!("{file}: {e}"))?;
        let methods = reg
            .get("methods")
            .and_then(Value::as_array)
            .ok_or_else(|| format!("{file} has no \"methods\""))?;
        let conn_name = str_of(&step.obj, "conn").unwrap_or("c").to_string();
        let socket = self.hubs[self.hub_index(str_of(&step.obj, "hub"))?]
            .socket
            .clone();
        let within = ms(&step.obj, "within_ms", 5000);
        let (mut id, mut probed, mut failed) = (1_000_000u64, 0, Vec::new());
        for m in methods {
            let name = m["name"].as_str().unwrap_or_default();
            let params = &m["params"];
            let required: Vec<&str> = params["required"]
                .as_array()
                .map(|r| r.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let Some(first) = required.first().copied() else {
                continue;
            };
            probed += 1;
            let wrong = if accepts_array(params, &params["properties"][first]) {
                json!(true)
            } else {
                json!([])
            };
            let mut one = Map::new();
            one.insert(first.to_string(), wrong);
            for (p, want) in [
                (json!({}), required.clone()),
                (Value::Object(one), vec![first]),
            ] {
                id += 1;
                let line = json!({"id": id, "method": name, "params": p}).to_string();
                let pattern = json!({ "id": id });
                let answer = if name == "hello" {
                    let mut fresh = Conn::open(&socket, Duration::from_secs(2))?;
                    fresh.send_line(&line, true)?;
                    fresh.expect(&pattern, within, &mut self.caps)
                } else {
                    let conn = self
                        .conns
                        .get_mut(&conn_name)
                        .ok_or_else(|| format!("no connection named {conn_name:?}"))?;
                    conn.send_line(&line, true)?;
                    conn.expect(&pattern, within, &mut self.caps)
                };
                match answer {
                    Err(e) => failed.push(format!("{name} {p}: {e}")),
                    Ok(a) => {
                        let code = a["error"]["code"].as_str();
                        let path = a["error"]["path"].as_str();
                        if code != Some("invalid-params")
                            || !path.is_some_and(|x| want.contains(&x))
                        {
                            failed.push(format!(
                                "{name} {p}: wanted invalid-params at one of {want:?}, got {a}"
                            ));
                        }
                    }
                }
            }
        }
        if probed == 0 {
            return Err(format!("{file}: no method has required params"));
        }
        if failed.is_empty() {
            Ok(())
        } else {
            Err(failed.join("; "))
        }
    }

    fn kill(&mut self, step: &Step) -> R {
        let pid = self.pid_arg(step)?;
        let sig = signal_number(str_of(&step.obj, "signal").unwrap_or("TERM"))?;
        if unsafe { libc::kill(pid as i32, sig) } != 0 {
            return Err(format!(
                "kill({pid}, {sig}) failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }

    fn expect_exit(&mut self, step: &Step) -> R {
        use std::os::unix::process::ExitStatusExt;
        let within = ms(&step.obj, "within_ms", 10000);
        let deadline = Instant::now() + within;
        let status = if let Some(h) = str_of(&step.obj, "hub") {
            let i = self.hub_index(Some(h))?;
            loop {
                if let Some(s) = self.hubs[i].exited() {
                    break s;
                }
                if Instant::now() > deadline {
                    return Err(format!(
                        "the hub is still running after {} ms",
                        within.as_millis()
                    ));
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        } else {
            let name = str_of(&step.obj, "pid")
                .map(|n| n.trim_start_matches('$').to_string())
                .ok_or("expect_exit needs \"hub\" or \"pid\"")?;
            let child = self.spawned.get_mut(&name).ok_or_else(|| {
                format!(
                    "{name:?} is not a process this scenario spawned (only those can be waited for)"
                )
            })?;
            loop {
                if let Some(s) = child.try_wait().map_err(|e| e.to_string())? {
                    break s;
                }
                if Instant::now() > deadline {
                    return Err(format!(
                        "{name} is still running after {} ms",
                        within.as_millis()
                    ));
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        };
        if let Some(want) = step.obj.get("code").and_then(Value::as_i64)
            && status.code() != Some(want as i32)
        {
            return Err(format!(
                "ended with {}, wanted exit code {want}",
                hub::describe(status)
            ));
        }
        if let Some(sig) = str_of(&step.obj, "signal")
            && status.signal() != Some(signal_number(sig)?)
        {
            return Err(format!(
                "ended with {}, wanted signal {sig}",
                hub::describe(status)
            ));
        }
        Ok(())
    }

    fn file(&mut self, step: &Step) -> R {
        let idx = self.hub_index(None).ok();
        let path = self.text(idx, step, "path")?;
        let want = step
            .obj
            .get("exists")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let meta = std::fs::metadata(&path);
        if !want {
            return if meta.is_err() {
                Ok(())
            } else {
                Err(format!("{path} exists"))
            };
        }
        let meta = meta.map_err(|e| format!("{path}: {e}"))?;
        if let Some(mode) = str_of(&step.obj, "mode") {
            let bits = u32::from_str_radix(mode, 8).map_err(|_| format!("bad mode {mode:?}"))?;
            if meta.permissions().mode() & 0o7777 != bits {
                return Err(format!(
                    "{path} has mode {:o}, wanted {bits:o}",
                    meta.permissions().mode() & 0o7777
                ));
            }
        }
        if let Some(owner) = step.obj.get("owner") {
            let me = unsafe { libc::geteuid() };
            let ok = match owner {
                Value::String(s) if s == "user" => meta.uid() == me,
                Value::Number(n) => n.as_u64() == Some(u64::from(meta.uid())),
                _ => return Err("\"owner\" is \"user\" or a uid".into()),
            };
            if !ok {
                return Err(format!(
                    "{path} belongs to uid {}, wanted {owner}",
                    meta.uid()
                ));
            }
        }
        if let Some(pattern) = step.obj.get("json") {
            let pattern = self.subst(idx, pattern, false);
            let text = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
            let got: Value =
                serde_json::from_str(&text).map_err(|e| format!("{path} is not JSON: {e}"))?;
            matcher::matches(&pattern, &got, &mut self.caps).map_err(|e| format!("{path}: {e}"))?;
        }
        Ok(())
    }

    fn write_file(&mut self, step: &Step) -> R {
        let idx = self.hub_index(None).ok();
        let path = PathBuf::from(self.text(idx, step, "path")?);
        let text = self.text(idx, step, "text")?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))
    }

    fn sqlite(&mut self, step: &Step) -> R {
        let idx = self.hub_index(None).ok();
        let path = PathBuf::from(self.text(idx, step, "path")?);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let db =
            rusqlite::Connection::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        for sql in self.strings(idx, step, "sql")? {
            db.execute_batch(&sql).map_err(|e| format!("{sql}: {e}"))?;
        }
        Ok(())
    }

    fn backend_log(&mut self, step: &Step) -> R {
        let i = self.hub_index(str_of(&step.obj, "hub"))?;
        let file = self.hubs[i].state_dir().join("fake-backend.log");
        let found = |this: &mut Self, pattern: &Value| -> bool {
            let text = std::fs::read_to_string(&file).unwrap_or_default();
            text.lines().any(|l| match pattern {
                Value::String(s) => l.contains(s.as_str()),
                p => serde_json::from_str::<Value>(l)
                    .is_ok_and(|v| matcher::matches(p, &v, &mut this.caps.clone()).is_ok()),
            })
        };
        if let Some(p) = step.obj.get("expect_line") {
            let p = self.subst(Some(i), p, false);
            let deadline = Instant::now() + ms(&step.obj, "within_ms", 5000);
            while !found(self, &p) {
                if Instant::now() > deadline {
                    return Err(format!(
                        "the fake backend never logged {p} ({})",
                        file.display()
                    ));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Ok(())
        } else if let Some(p) = step.obj.get("expect_no_line") {
            let p = self.subst(Some(i), p, false);
            std::thread::sleep(ms(&step.obj, "for_ms", 500));
            if found(self, &p) {
                Err(format!("the fake backend logged {p}"))
            } else {
                Ok(())
            }
        } else {
            Err("backend_log needs expect_line or expect_no_line".into())
        }
    }

    fn pid(&mut self, step: &Step) -> R {
        let name = str_of(&step.obj, "capture")
            .ok_or("\"capture\" names the pid")?
            .to_string();
        let pid = self
            .caps
            .0
            .get(&name)
            .and_then(Value::as_u64)
            .ok_or_else(|| format!("no pid captured as {name:?}"))? as u32;
        let want = step
            .obj
            .get("alive")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let deadline = Instant::now() + ms(&step.obj, "within_ms", 5000);
        while self.process_alive(Some(&name), pid) != want {
            if Instant::now() > deadline {
                return Err(format!(
                    "pid {pid} ({name}) is {} after {} ms",
                    if want { "not running" } else { "still running" },
                    ms(&step.obj, "within_ms", 5000).as_millis()
                ));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        Ok(())
    }

    fn measure(&mut self, step: &Step) -> R {
        let name = str_of(&step.obj, "name")
            .ok_or("\"name\" names the measurement")?
            .to_string();
        let repeat = step.obj.get("repeat").and_then(Value::as_u64).unwrap_or(1);
        let mut inner = Vec::new();
        for v in step
            .obj
            .get("steps")
            .and_then(Value::as_array)
            .ok_or("\"steps\" is an array of steps")?
        {
            let obj = v.as_object().ok_or("a step is an object")?.clone();
            let verb = str_of(&obj, "do").ok_or("a step needs \"do\"")?.to_string();
            inner.push(Step {
                line: step.line,
                verb,
                obj,
            });
        }
        let mut samples = Vec::new();
        for _ in 0..repeat {
            let t = Instant::now();
            for s in &inner {
                self.step(s)
                    .map_err(|e| format!("in {} ({}): {e}", s.verb, name))?;
            }
            samples.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        self.perf.push((name, samples));
        Ok(())
    }
}

enum Proof {
    Valid,
    Wrong,
    None,
    Replay(String),
}

struct HelloSpec {
    proof: Proof,
    proto: u64,
    class: Option<String>,
    error: Option<String>,
}
