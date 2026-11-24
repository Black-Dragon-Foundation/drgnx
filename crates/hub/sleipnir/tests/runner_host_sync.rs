//! Sync's runner-host tests: they run inside a fake runner (`test/runners/`), as the user `runner`, with the real
//! `sleipnir` binary beside them (`SLEIPNIR_TEST_BIN`), never on a developer's machine:
//!
//! ```text
//! cargo test -p sleipnir --features test-hooks --test runner_host_sync --no-run
//! fleet.sh host <the test binary> [FILTER]      # --ignored, in every runner
//! ```
//!
//! Each names its pattern.
#![cfg(target_os = "linux")]

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

mod support;

use secrecy::SecretString;
use sleipnir::sync::cred::OriginCred;
use sleipnir::sync::mirror::Mirror;

/// The sleipnir binary in the runner (`fleet.sh host` puts it in /fleet/share).
fn sleipnir_bin() -> PathBuf {
    std::env::var_os("SLEIPNIR_TEST_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_sleipnir")))
}

/// How long one tool call of these rows may take.
const TOOL_LIMIT: std::time::Duration = std::time::Duration::from_secs(300);

/// The user's git: no system or global config, a fixed identity.
fn user_git(dir: &Path, args: &[&str]) -> String {
    let mut spec = sleipnir::tool::spec(
        Path::new("git"),
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "-c",
            "init.defaultBranch=main",
        ],
        &[
            ("GIT_CONFIG_NOSYSTEM", "1"),
            ("GIT_CONFIG_GLOBAL", "/dev/null"),
        ],
    );
    spec.args.extend(args.iter().map(std::ffi::OsString::from));
    spec.cwd = Some(dir.to_path_buf());
    let out = draugr::run(spec, TOOL_LIMIT).unwrap();
    assert!(out.status.success(), "git {args:?}: {}", out.stderr);
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// A repository at `dir` with one commit; returns the commit.
fn repo(dir: &Path) -> String {
    fs::create_dir_all(dir).unwrap();
    user_git(dir, &["init", "-q"]);
    sleipnir::fsio::write(dir.join("a"), "a\n").unwrap();
    user_git(dir, &["add", "-A"]);
    user_git(dir, &["commit", "-qm", "one"]);
    user_git(dir, &["rev-parse", "HEAD"])
}

fn marker_script(at: &Path, marker: &Path, name: &str) {
    fs::create_dir_all(at.parent().unwrap()).unwrap();
    hlaup::write(
        at,
        format!("#!/bin/sh\necho {name} >> '{}'\n", marker.display()),
    )
    .unwrap();
}

fn base64(bytes: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16
            | (*c.get(1).unwrap_or(&0) as u32) << 8
            | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                s.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

/// A smart-HTTP origin on 127.0.0.1 (git's own `http-backend` behind a minimal HTTP/1.1 server) that answers only
/// requests carrying `auth` as their Authorization header, and counts them.
fn origin_server(project_root: PathBuf, auth: String) -> (u16, Arc<AtomicUsize>) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let h = hits.clone();
    saman::spawn_thread("origin-server", move || {
        for s in l.incoming().flatten() {
            serve_one(s, &project_root, &auth, &h);
        }
    })
    .unwrap();
    (port, hits)
}

fn serve_one(mut s: TcpStream, root: &Path, auth: &str, hits: &AtomicUsize) {
    let mut r = BufReader::new(s.try_clone().unwrap());
    let mut line = String::new();
    r.read_line(&mut line).unwrap();
    let mut words = line.split_whitespace();
    let (method, target) = (
        words.next().unwrap_or("").to_string(),
        words.next().unwrap_or("").to_string(),
    );
    let mut headers = BTreeMap::new();
    loop {
        let mut h = String::new();
        if r.read_line(&mut h).unwrap() == 0 || h == "\r\n" || h == "\n" {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    if headers
        .get("expect")
        .is_some_and(|v| v.eq_ignore_ascii_case("100-continue"))
    {
        s.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap();
    }
    let mut body = Vec::new();
    if let Some(n) = headers.get("content-length") {
        body.resize(n.parse().unwrap(), 0);
        r.read_exact(&mut body).unwrap();
    } else if headers
        .get("transfer-encoding")
        .is_some_and(|v| v.eq_ignore_ascii_case("chunked"))
    {
        loop {
            let mut size = String::new();
            r.read_line(&mut size).unwrap();
            let n = usize::from_str_radix(size.trim().split(';').next().unwrap(), 16).unwrap();
            let mut chunk = vec![0; n + 2];
            r.read_exact(&mut chunk).unwrap();
            if n == 0 {
                break;
            }
            body.extend_from_slice(&chunk[..n]);
        }
    }
    if headers.get("authorization").map(String::as_str) != Some(auth) {
        s.write_all(
            b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"origin\"\r\n\
              Content-Length: 0\r\nConnection: close\r\n\r\n",
        )
        .unwrap();
        return;
    }
    hits.fetch_add(1, Ordering::SeqCst);
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    let mut vars: Vec<(&str, std::ffi::OsString)> = vec![
        ("PATH", std::env::var_os("PATH").unwrap()),
        ("GIT_CONFIG_NOSYSTEM", "1".into()),
        ("GIT_CONFIG_GLOBAL", "/dev/null".into()),
        ("GIT_PROJECT_ROOT", root.into()),
        ("GIT_HTTP_EXPORT_ALL", "1".into()),
        ("PATH_INFO", path.into()),
        ("QUERY_STRING", query.into()),
        ("REQUEST_METHOD", method.as_str().into()),
        ("REMOTE_ADDR", "127.0.0.1".into()),
        ("CONTENT_LENGTH", body.len().to_string().into()),
    ];
    for (h, var) in [
        ("content-type", "CONTENT_TYPE"),
        ("content-encoding", "HTTP_CONTENT_ENCODING"),
        ("git-protocol", "GIT_PROTOCOL"),
    ] {
        if let Some(v) = headers.get(h) {
            vars.push((var, v.into()));
        }
    }
    // exactly these variables: the backend's environment is the request's
    let mut cgi = support::spec("git", &["http-backend"], &[]);
    cgi.env = vars.into_iter().map(|(k, v)| (k.into(), v)).collect();
    let out = support::run_with_input(cgi, &body);
    let o = out.stdout;
    let split = o
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| (i, 4))
        .or_else(|| o.windows(2).position(|w| w == b"\n\n").map(|i| (i, 2)))
        .unwrap();
    let head = String::from_utf8_lossy(&o[..split.0]).to_string();
    let rest = &o[split.0 + split.1..];
    let mut status = "200 OK".to_string();
    let mut reply = Vec::new();
    for h in head.lines() {
        match h.strip_prefix("Status:") {
            Some(st) => status = st.trim().to_string(),
            None => reply.extend_from_slice(format!("{h}\r\n").as_bytes()),
        }
    }
    let mut msg = format!("HTTP/1.1 {status}\r\n").into_bytes();
    msg.extend_from_slice(&reply);
    msg.extend_from_slice(
        format!(
            "Content-Length: {}\r\nConnection: close\r\n\r\n",
            rest.len()
        )
        .as_bytes(),
    );
    msg.extend_from_slice(rest);
    s.write_all(&msg).unwrap();
}

/// Every regular file under `dir` (never following a link) that holds one of `needles`.
fn files_holding(dir: &Path, needles: &[&[u8]], found: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_dir() {
            files_holding(&e.path(), needles, found);
        } else if ft.is_file()
            && e.metadata().is_ok_and(|m| m.len() <= 64 << 20)
            && let Ok(bytes) = fs::read(e.path())
            && needles
                .iter()
                .any(|n| bytes.windows(n.len()).any(|w| w == *n))
        {
            found.push(e.path());
        }
    }
}

// [C] a real git and a real credential-helper child over a real socket; the origin's answers are the handshake
#[test]
#[ignore = "runner-host"]
fn origin_fetch_with_a_token_leaves_no_file() {
    let home = PathBuf::from(std::env::var_os(stig::HOME_VAR).expect("the home variable"));
    let work = tempfile::tempdir().unwrap();
    let origin = work.path().join("origin.git");
    let src = work.path().join("src");
    let commit = repo(&src);
    user_git(work.path(), &["clone", "-q", "--bare", "src", "origin.git"]);

    // unique per run: the process and the temp folder's own random name
    let unique = work.path().file_name().unwrap().to_string_lossy();
    let token = format!("tok{unique}p{}", std::process::id());
    let auth = format!(
        "Basic {}",
        base64(format!("x-access-token:{token}").as_bytes())
    );
    let (port, hits) = origin_server(work.path().to_path_buf(), auth.clone());
    let url = format!("http://127.0.0.1:{port}/origin.git");
    assert!(origin.is_dir());

    let root = home.join(format!("sync-cred-{}", std::process::id()));
    let mut m = Mirror::ensure(&root, "o").unwrap();
    m.helper = sleipnir_bin();
    assert!(
        m.fetch_origin(&url, None).is_err(),
        "the origin refuses a fetch without the token"
    );
    assert_eq!(hits.load(Ordering::SeqCst), 0);
    m.fetch_origin(
        &url,
        Some(OriginCred::Https(SecretString::from(token.clone()))),
    )
    .unwrap();
    assert!(
        hits.load(Ordering::SeqCst) >= 1,
        "the token reached the origin"
    );
    assert!(m.has_commit(&commit).unwrap());

    let mut found = Vec::new();
    let needles: [&[u8]; 2] = [token.as_bytes(), auth.as_bytes()];
    for d in [root.as_path(), Path::new("/tmp"), home.as_path()] {
        files_holding(d, &needles, &mut found);
    }
    // the folder may never have been made
    drop(fs::remove_dir_all(&root));
    assert!(found.is_empty(), "the token is in {found:?}");
}

// [C] a real git push into the real `sleipnir git-receive` child; the push's answer is the handshake
#[test]
#[ignore = "runner-host"]
fn push_into_the_mirror_runs_no_hook() {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().join("runner");
    let m = Mirror::ensure(&root, "r").unwrap();
    let marker = t.path().join("marker");
    let hooks = [
        "pre-receive",
        "update",
        "post-receive",
        "post-update",
        "reference-transaction",
        "proc-receive",
        "push-to-checkout",
    ];
    // hooks where git looks by default, and a planted config pointing at more
    let planted = t.path().join("planted-hooks");
    for h in hooks {
        marker_script(&m.git_dir.join("hooks").join(h), &marker, h);
        marker_script(&planted.join(h), &marker, h);
    }
    let config = m.git_dir.join("config");
    let mut text = sleipnir::fsio::read_to_string(&config).unwrap();
    text.push_str(&format!("[core]\n\thooksPath = {}\n", planted.display()));
    sleipnir::fsio::write(&config, text).unwrap();

    let src = t.path().join("src");
    let commit = repo(&src);
    let receive = format!(
        "{} git-receive --root {}",
        sleipnir_bin().display(),
        root.display()
    );
    user_git(
        &src,
        &[
            "push",
            "-q",
            &format!("--receive-pack={receive}"),
            m.git_dir.to_str().unwrap(),
            "main:refs/hub/heads/main",
        ],
    );
    assert!(
        !marker.exists(),
        "a hook ran: {:?}",
        sleipnir::fsio::read_to_string(&marker)
    );
    assert!(m.has_commit(&commit).unwrap(), "the push arrived");

    // a path outside the runner folder's mirrors is refused
    let out = sleipnir::tool::limited(
        &sleipnir_bin(),
        &[
            std::ffi::OsString::from("git-receive"),
            "--root".into(),
            root.clone().into(),
            t.path().join("src/.git").into(),
        ],
        &[],
        TOOL_LIMIT,
    )
    .unwrap();
    assert!(!out.status.success());
}

/// The fake origin's `ssh`, first on PATH for the fetch: it records what the per-fetch agent holds (`ssh-add -L`) and
/// where it listens, says `ready`, waits on the FIFO `go` while the test looks at the disk, then runs the remote
/// command here (`git-upload-pack` on the local origin), or fails when `FAKE_SSH_FAIL` is set.
const FAKE_SSH: &str = r#"#!/bin/sh
d="$FAKE_SSH_DIR"
printf '%s\n' "$SSH_AUTH_SOCK" > "$d/agent.path"
ssh-add -L > "$d/agent.keys" 2>&1
: > "$d/ssh.ready"
read go < "$d/go"
[ -z "$FAKE_SSH_FAIL" ] || exit 128
for last; do :; done
exec sh -c "$last"
"#;

/// The processes whose command line holds NEEDLE.
fn processes_naming(needle: &str) -> Vec<u32> {
    let mut found = vec![];
    for e in fs::read_dir("/proc").unwrap().flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|p| p.parse::<u32>().ok()) else {
            continue;
        };
        if fs::read(e.path().join("cmdline"))
            .is_ok_and(|c| c.windows(needle.len()).any(|w| w == needle.as_bytes()))
        {
            found.push(pid);
        }
    }
    found
}

/// [C] An origin fetch over SSH with a deploy key: real `sleipnir sync-fetch` children (the test-hooks mode an
/// `origin-fetch` frame's key drives), a real git and ssh-agent, and a fake `ssh` that announces `ready` and parks on
/// a FIFO. While git talks to the origin the key is in the per-fetch agent and in no file on the runner; after the
/// fetch the agent is gone, and so it is after a fetch that fails at the origin and after a key the agent can't load.
#[test]
#[ignore = "runner-host"]
fn origin_fetch_with_a_deploy_key_leaves_no_file_and_no_agent() {
    let home = PathBuf::from(std::env::var_os(stig::HOME_VAR).expect("the home variable"));
    let work = tempfile::tempdir().unwrap();
    let w = work.path();
    let src = w.join("src");
    let commit = repo(&src);
    user_git(w, &["clone", "-q", "--bare", "src", "origin.git"]);
    // a generated deploy key, read into memory; its files go before any fetch
    let out = sleipnir::tool::limited(
        Path::new("ssh-keygen"),
        &[
            std::ffi::OsString::from("-q"),
            "-t".into(),
            "ed25519".into(),
            "-N".into(),
            "".into(),
            "-C".into(),
            "deploy".into(),
            "-f".into(),
            w.join("k").into(),
        ],
        &[],
        TOOL_LIMIT,
    )
    .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let private = sleipnir::fsio::read_to_string(w.join("k")).unwrap();
    let public = sleipnir::fsio::read_to_string(w.join("k.pub")).unwrap();
    fs::remove_file(w.join("k")).unwrap();
    fs::remove_file(w.join("k.pub")).unwrap();
    let blob = public.split_whitespace().nth(1).unwrap().to_string();
    // the key's base64 body, line by line: none may be in any file
    let body: Vec<String> = private
        .lines()
        .filter(|l| !l.starts_with("-----") && l.len() >= 32)
        .map(String::from)
        .collect();
    assert!(!body.is_empty());
    let bin = w.join("bin");
    fs::create_dir_all(&bin).unwrap();
    hlaup::write(&bin.join("ssh"), FAKE_SSH).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let root = home.join(format!("sync-deploy-{}", std::process::id()));
    let url = format!("ssh://origin.invalid{}", w.join("origin.git").display());
    let fetch = |key: &str, fail: bool| {
        // left from the last fetch, or not there
        drop(fs::remove_file(w.join("ssh.ready")));
        drop(fs::remove_file(w.join("go")));
        let ok =
            sleipnir::tool::limited(Path::new("mkfifo"), &[w.join("go")], &[], TOOL_LIMIT).unwrap();
        assert!(ok.status.success());
        let mut extra: Vec<(&str, &std::ffi::OsStr)> =
            vec![("PATH", path.as_ref()), ("FAKE_SSH_DIR", w.as_os_str())];
        if fail {
            extra.push(("FAKE_SSH_FAIL", "1".as_ref()));
        }
        let args: Vec<&std::ffi::OsStr> = vec![
            "sync-fetch".as_ref(),
            "--root".as_ref(),
            root.as_os_str(),
            "--repo".as_ref(),
            "o".as_ref(),
            "--url".as_ref(),
            url.as_ref(),
        ];
        let mut child = support::start(
            &support::spec(sleipnir_bin(), &args, &extra),
            true,
            draugr::Redirect::Null,
            draugr::Redirect::Pipe,
        );
        child
            .stdin
            .take()
            .unwrap()
            .write_all(key.as_bytes())
            .unwrap();
        child
    };
    let scan = |found: &mut Vec<PathBuf>| {
        for line in &body {
            for d in [root.as_path(), Path::new("/tmp"), home.as_path()] {
                files_holding(d, &[line.as_bytes()], found);
            }
        }
    };
    let agent_gone = |sock: &str| {
        assert!(
            !Path::new(sock).exists(),
            "the agent's socket is still there"
        );
        assert_eq!(
            processes_naming(sock),
            Vec::<u32>::new(),
            "the agent still runs"
        );
    };

    for fail in [false, true] {
        let child = fetch(&private, fail);
        skuld::wait_until("the fake ssh ready", 120, || {
            w.join("ssh.ready").exists().then_some(())
        });
        let sock = sleipnir::fsio::read_to_string(w.join("agent.path"))
            .unwrap()
            .trim()
            .to_string();
        assert!(
            sock.starts_with(root.to_str().unwrap()),
            "the agent listens in the runner folder"
        );
        let held = sleipnir::fsio::read_to_string(w.join("agent.keys")).unwrap();
        assert!(
            held.contains(&blob),
            "the per-fetch agent doesn't hold the deploy key"
        );
        let mut found = vec![];
        scan(&mut found);
        assert!(
            found.is_empty(),
            "the deploy key is in {found:?} during the fetch"
        );
        sleipnir::fsio::write(w.join("go"), "go\n").unwrap();
        let out = child.wait_with_output().unwrap();
        assert_eq!(
            out.status.success(),
            !fail,
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        if !fail {
            let m = Mirror::ensure(&root, "o").unwrap();
            assert!(m.has_commit(&commit).unwrap(), "the fetch arrived");
        }
        agent_gone(&sock);
    }

    // a key the agent can't load: the fetch fails before git runs, and no agent of ours is left
    let child = fetch("not a key\n", false);
    let out = child.wait_with_output().unwrap();
    assert!(!out.status.success());
    assert!(!w.join("ssh.ready").exists(), "git ran without the key");
    assert_eq!(
        processes_naming(root.join("run").to_str().unwrap()),
        Vec::<u32>::new(),
        "an agent of this runner folder still runs"
    );
    let mut found = vec![];
    scan(&mut found);
    // the folder may never have been made
    drop(fs::remove_dir_all(&root));
    assert!(
        found.is_empty(),
        "the deploy key is in {found:?} after the fetches"
    );
}

mod guard {
    use super::*;
    use forseti::disk::{DiskItem, DiskRules, ItemKind};
    use sleipnir::sync::guard::{self, Df, Evict, Pins, Why};
    use sleipnir::sync::register::Register;

    /// Always below the floor, so every eviction for the floor is done.
    fn low() -> Df {
        Df {
            total: 1 << 40,
            avail: 1,
        }
    }

    /// A week after every item's last use: all are past their age.
    const NOW: u64 = 7 * 24 * 3600;

    fn cache(rel: &str) -> DiskItem {
        DiskItem {
            id: format!("cache:{rel}"),
            kind: ItemKind::Cache,
            owner: "p".into(),
            machine: String::new(),
            bytes: 1,
            last_used: 0,
            created: 0,
            name: None,
            budget_bytes: None,
            trust: forseti::JobTrust::Public,
        }
    }

    fn apply(reg: &mut Register, plan: &[Evict]) -> Vec<guard::Evicted> {
        guard::apply(
            reg,
            plan,
            &|_| false,
            &mut || Ok(low()),
            &mut || 0.0,
            &DiskRules::standard(),
            &mut |_| {},
        )
    }

    // [C] real files and links under a real runner folder; the register, plan and apply as the guard runs them
    #[test]
    #[ignore = "runner-host"]
    fn a_symlink_planted_in_a_cache_is_never_followed() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("runner");
        let outside = t.path().join("outside");
        fs::create_dir_all(outside.join("public/x")).unwrap();
        sleipnir::fsio::write(outside.join("sentinel"), "keep\n").unwrap();
        sleipnir::fsio::write(outside.join("public/x/sentinel"), "keep\n").unwrap();
        let before = fs::read_dir(&outside).unwrap().count();

        // what a job could write into its cache mount: links out of it
        let a = root.join("cache/p/public/a");
        fs::create_dir_all(a.join("sub")).unwrap();
        sleipnir::fsio::write(a.join("sub/f"), "cached\n").unwrap();
        std::os::unix::fs::symlink(&outside, a.join("dir-link")).unwrap();
        std::os::unix::fs::symlink(outside.join("sentinel"), a.join("sub/file-link")).unwrap();
        // links where the runner's own folders belong
        fs::create_dir_all(root.join("cache/p/private")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("cache/p/private/b")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("cache/q")).unwrap();

        let mut reg = Register::open(&root).unwrap();
        // the cache, and a stale record whose path now runs through a planted link
        for rel in ["cache/p/public/a", "cache/q/public/x"] {
            reg.add(cache(rel), Path::new(rel)).unwrap();
        }
        let plan = guard::plan(
            low(),
            0,
            &reg.items(),
            &Pins::default(),
            &DiskRules::standard(),
            NOW,
        );
        assert!(
            plan.iter()
                .any(|e| e.id == "cache:cache/p/public/a" && e.why == Why::Floor),
            "{plan:?}"
        );
        let done = apply(&mut reg, &plan);
        let through = done
            .iter()
            .find(|e| e.id == "cache:cache/q/public/x")
            .unwrap();
        assert!(
            through.refused.is_some(),
            "an eviction through a link is refused"
        );

        assert!(!a.exists(), "the cache is pruned");
        assert_eq!(
            sleipnir::fsio::read_to_string(outside.join("sentinel")).unwrap(),
            "keep\n"
        );
        assert_eq!(
            sleipnir::fsio::read_to_string(outside.join("public/x/sentinel")).unwrap(),
            "keep\n"
        );
        assert_eq!(fs::read_dir(&outside).unwrap().count(), before);
    }

    fn podman(args: &[&str]) -> (bool, String) {
        let out = sleipnir::tool::limited(Path::new("podman"), args, &[], TOOL_LIMIT).unwrap();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).trim().to_string(),
        )
    }

    // [C] the runner's real podman store: the fake runner's base image (not ours) and an image recorded as ours
    #[test]
    #[ignore = "runner-host"]
    fn never_removes_an_image_we_did_not_pull() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("runner");
        fs::create_dir_all(&root).unwrap();
        let base = "registry.fedoraproject.org/fedora:45";
        let (ok, base_id) = podman(&["image", "inspect", "--format", "{{.Id}}", base]);
        assert!(ok, "the fake runner has its base image");

        // an image of our own: one file, imported under a name of this test's
        let layer = t.path().join("layer");
        fs::create_dir(&layer).unwrap();
        sleipnir::fsio::write(layer.join("f"), format!("{}\n", std::process::id())).unwrap();
        let tar = t.path().join("layer.tar");
        assert!(
            sleipnir::tool::limited(
                Path::new("tar"),
                &[
                    std::ffi::OsString::from("-C"),
                    layer.clone().into(),
                    "-cf".into(),
                    tar.clone().into(),
                    "f".into(),
                ],
                &[],
                TOOL_LIMIT,
            )
            .unwrap()
            .status
            .success()
        );
        let name = format!("localhost/sleipnir-guard-test:{}", std::process::id());
        assert!(podman(&["import", "-q", tar.to_str().unwrap(), &name]).0);
        let (_, ours) = podman(&["image", "inspect", "--format", "{{.Id}}", &name]);
        // registered as a pull registers it; two newer of its name, so it is past the newest two
        let mut reg = Register::open(&root).unwrap();
        let ours_id = format!("image:{}", ours.trim_start_matches("sha256:"));
        reg.add(
            guard::image_item(ours.trim_start_matches("sha256:"), &name, "p", 0),
            Path::new(""),
        )
        .unwrap();
        for (n, at) in [("a", 1), ("b", 2)] {
            let newer = guard::image_item(n, &name, "p", at);
            reg.add(newer, Path::new("")).unwrap();
        }
        let items = reg.items();
        let r = DiskRules::standard();

        // a queued job naming ours keeps it
        let pins = Pins {
            pinned: [ours_id.clone()].into(),
            ..Pins::default()
        };
        assert!(guard::plan(low(), 0, &items, &pins, &r, NOW).is_empty());

        let mut plan = guard::plan(low(), 0, &items, &Pins::default(), &r, NOW);
        assert_eq!(plan.len(), 1, "{plan:?}");
        // and an order naming the base image, which the register doesn't hold
        plan.push(Evict {
            id: format!("image:{}", base_id.trim_start_matches("sha256:")),
            why: Why::Ordered("test".into()),
        });
        let done = apply(&mut reg, &plan);
        assert_eq!(done[0].refused, None, "{:?}", done[0]);
        assert!(done[1].refused.is_some(), "{:?}", done[1]);
        assert!(!podman(&["image", "exists", &name]).0, "ours is removed");
        assert!(podman(&["image", "exists", base]).0, "the base image stays");
    }
}
