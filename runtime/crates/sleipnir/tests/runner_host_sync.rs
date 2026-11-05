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
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use secrecy::SecretString;
use sleipnir::sync::cred::OriginCred;
use sleipnir::sync::mirror::Mirror;

/// The sleipnir binary in the runner (`fleet.sh host` puts it in /fleet/share).
fn sleipnir_bin() -> PathBuf {
    std::env::var_os("SLEIPNIR_TEST_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_sleipnir")))
}

/// The user's git: no system or global config, a fixed identity.
fn user_git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// A repository at `dir` with one commit; returns the commit.
fn repo(dir: &Path) -> String {
    fs::create_dir_all(dir).unwrap();
    user_git(dir, &["init", "-q"]);
    fs::write(dir.join("a"), "a\n").unwrap();
    user_git(dir, &["add", "-A"]);
    user_git(dir, &["commit", "-qm", "one"]);
    user_git(dir, &["rev-parse", "HEAD"])
}

fn marker_script(at: &Path, marker: &Path, name: &str) {
    fs::create_dir_all(at.parent().unwrap()).unwrap();
    fs::write(
        at,
        format!("#!/bin/sh\necho {name} >> '{}'\n", marker.display()),
    )
    .unwrap();
    fs::set_permissions(at, fs::Permissions::from_mode(0o755)).unwrap();
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
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            serve_one(s, &project_root, &auth, &h);
        }
    });
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
    let mut cgi = Command::new("git");
    cgi.arg("http-backend")
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_PROJECT_ROOT", root)
        .env("GIT_HTTP_EXPORT_ALL", "1")
        .env("PATH_INFO", path)
        .env("QUERY_STRING", query)
        .env("REQUEST_METHOD", &method)
        .env("REMOTE_ADDR", "127.0.0.1")
        .env("CONTENT_LENGTH", body.len().to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());
    for (h, var) in [
        ("content-type", "CONTENT_TYPE"),
        ("content-encoding", "HTTP_CONTENT_ENCODING"),
        ("git-protocol", "GIT_PROTOCOL"),
    ] {
        if let Some(v) = headers.get(h) {
            cgi.env(var, v);
        }
    }
    let mut child = cgi.spawn().unwrap();
    child.stdin.take().unwrap().write_all(&body).unwrap();
    let out = child.wait_with_output().unwrap();
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
    let home = PathBuf::from(std::env::var_os("HOME").expect("HOME"));
    let work = tempfile::tempdir().unwrap();
    let origin = work.path().join("origin.git");
    let src = work.path().join("src");
    let commit = repo(&src);
    user_git(work.path(), &["clone", "-q", "--bare", "src", "origin.git"]);

    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let token = format!("tok{nanos:x}p{}", std::process::id());
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
    let _ = fs::remove_dir_all(&root);
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
    let mut text = fs::read_to_string(&config).unwrap();
    text.push_str(&format!("[core]\n\thooksPath = {}\n", planted.display()));
    fs::write(&config, text).unwrap();

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
        fs::read_to_string(&marker)
    );
    assert!(m.has_commit(&commit).unwrap(), "the push arrived");

    // a path outside the runner folder's mirrors is refused
    let out = Command::new(sleipnir_bin())
        .args(["git-receive", "--root"])
        .arg(&root)
        .arg(t.path().join("src/.git"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(!out.status.success());
}

mod guard {
    use super::*;
    use sleipnir::sync::guard::{self, Df, Item, Needs, What};

    /// Always below the floor, so every prune for the floor is done.
    fn low() -> Df {
        Df {
            total: 1 << 40,
            avail: 1,
        }
    }

    // [C] real files and links under a real runner folder; scan, plan and apply as the guard runs them
    #[test]
    #[ignore = "runner-host"]
    fn a_symlink_planted_in_a_cache_is_never_followed() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("runner");
        let outside = t.path().join("outside");
        fs::create_dir_all(outside.join("public/x")).unwrap();
        fs::write(outside.join("sentinel"), "keep\n").unwrap();
        fs::write(outside.join("public/x/sentinel"), "keep\n").unwrap();
        let before = fs::read_dir(&outside).unwrap().count();

        // what a job could write into its cache mount: links out of it
        let a = root.join("cache/p/public/a");
        fs::create_dir_all(a.join("sub")).unwrap();
        fs::write(a.join("sub/f"), "cached\n").unwrap();
        std::os::unix::fs::symlink(&outside, a.join("dir-link")).unwrap();
        std::os::unix::fs::symlink(outside.join("sentinel"), a.join("sub/file-link")).unwrap();
        // links where the runner's own folders belong
        fs::create_dir_all(root.join("cache/p/private")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("cache/p/private/b")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("cache/q")).unwrap();

        let items = guard::scan(&root, std::time::SystemTime::now(), 10 << 30).unwrap();
        let mut plan = guard::plan(low(), &items, &Needs::default());
        assert!(
            plan.iter()
                .any(|p| p.what == What::Path("cache/p/public/a".into())),
            "{plan:?}"
        );
        // and a prune through a planted link, as a stale record could name it
        plan.push(guard::Prune {
            what: What::Path("cache/q/public/x".into()),
            for_floor: true,
        });
        let done = guard::apply(&root, &plan, &mut || Ok(low()));
        let through = done
            .iter()
            .find(|(p, _)| p.what == What::Path("cache/q/public/x".into()))
            .unwrap();
        assert!(through.1.is_err(), "a prune through a link is refused");

        assert!(!a.exists(), "the cache is pruned");
        assert_eq!(
            fs::read_to_string(outside.join("sentinel")).unwrap(),
            "keep\n"
        );
        assert_eq!(
            fs::read_to_string(outside.join("public/x/sentinel")).unwrap(),
            "keep\n"
        );
        assert_eq!(fs::read_dir(&outside).unwrap().count(), before);
    }

    fn podman(args: &[&str]) -> (bool, String) {
        let out = Command::new("podman").args(args).output().unwrap();
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
        fs::write(layer.join("f"), format!("{}\n", std::process::id())).unwrap();
        let tar = t.path().join("layer.tar");
        assert!(
            Command::new("tar")
                .arg("-C")
                .arg(&layer)
                .arg("-cf")
                .arg(&tar)
                .arg("f")
                .status()
                .unwrap()
                .success()
        );
        let name = format!("localhost/sleipnir-guard-test:{}", std::process::id());
        assert!(podman(&["import", "-q", tar.to_str().unwrap(), &name]).0);
        let (_, ours) = podman(&["image", "inspect", "--format", "{{.Id}}", &name]);
        fs::write(root.join("images"), format!("{ours} {name}\n")).unwrap();

        let items = guard::images(&root).unwrap();
        let is = |id: &str| {
            items
                .iter()
                .find(|i| matches!(i, Item::Image { id: x, .. } if x == id))
                .cloned()
        };
        assert!(
            matches!(is(&base_id), Some(Item::Image { pulled_as, .. }) if pulled_as.is_empty())
        );
        assert!(
            matches!(is(&ours), Some(Item::Image { pulled_as, .. }) if pulled_as == [name.clone()])
        );

        // a queued job naming ours keeps it
        let needs = Needs {
            images: [name.clone()].into(),
            ..Needs::default()
        };
        assert!(guard::plan(low(), &items, &needs).is_empty());

        let plan = guard::plan(low(), &items, &Needs::default());
        assert_eq!(plan.len(), 1, "{plan:?}");
        let done = guard::apply(&root, &plan, &mut || Ok(low()));
        assert!(done[0].1.is_ok(), "{:?}", done[0].1);
        assert!(!podman(&["image", "exists", &name]).0, "ours is removed");
        assert!(podman(&["image", "exists", base]).0, "the base image stays");
    }
}
