//! The `hrafn-parse` worker under a real Gleipnir sandbox (language packs Task 6b-1): the sandbox lane's (`#[ignore]`, run
//! with `-- --ignored` in a `ctr.sh --sandbox` container; the `ratatoskr` binary is the sandbox's helper and the worker).
//!
//! What must hold: the worker still does its job inside the sandbox (its answer equals the in-process chunker's), and a
//! grammar that tries to leave it cannot. The `probe` fixture grammar (`test/packs/hub-grammars.sh`) tries, as soon as
//! its library loads, to write beside itself and elsewhere, to read a secret file, to connect to a TCP port the test
//! listens on and to a Unix socket the test serves; it exits 77 if any worked and says `PROBE CLEAN` on stderr if none
//! did. The same library started plainly (the control) must exit 77: the probe sees what it claims to see.
//!
//! test-pattern: process (P), in the sandbox lane.
#![cfg(target_os = "linux")]

use drgnx_ratatoskr::parse_worker::Sandboxed;
use gleipnir::{Sandbox, Tier};
use hrafn::Lang;
use hrafn::chunk::worker::{Init, Launch, Worker, WorkerError, WorkerSpec};
use hrafn::chunk::{BUDGET, chunk_file_refs};
use runstav::paths::Env;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const BIN: &str = env!("CARGO_BIN_EXE_ratatoskr");

struct Fx {
    _dir: tempfile::TempDir,
    b: PathBuf,
}

impl Fx {
    fn new() -> Fx {
        let dir = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let b = std::fs::canonicalize(dir.path()).unwrap();
        for d in ["home", "run", "t"] {
            std::fs::create_dir_all(b.join(d)).unwrap();
        }
        Fx { _dir: dir, b }
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.b.join(rel)
    }

    fn env(&self) -> Env {
        let s = |rel: &str| self.p(rel).to_str().unwrap().to_owned();
        Env::new(
            &[
                ("HOME", &s("home")),
                ("XDG_RUNTIME_DIR", &s("run")),
                ("TMPDIR", &s("t")),
                ("PATH", "/usr/bin:/bin"),
            ],
            rustix::process::geteuid().as_raw(),
        )
    }
}

fn launcher(fx: &Fx) -> Sandboxed {
    let bin = PathBuf::from(BIN);
    let sb = Sandbox::detect(Tier::Full, drgnx_ratatoskr::sandbox::helper_at(&bin), None)
        .unwrap_or_else(|r| panic!("the full tier is not usable here: {r}"));
    Sandboxed::new(sb, drgnx_ratatoskr::sandbox::context(&fx.env()), bin)
}

/// (library path, sha256) of the grammar NAME the pack job built, or of `fixture:NAME` beside the lock.
fn lib_of(name: &str) -> (PathBuf, String) {
    let lock = PathBuf::from(std::env::var_os("DRGNX_PACK_LOCK").expect("DRGNX_PACK_LOCK"));
    let grammars =
        PathBuf::from(std::env::var_os("DRGNX_PACK_GRAMMARS").expect("DRGNX_PACK_GRAMMARS"));
    let path = if let Some(fx) = name.strip_prefix("fixture:") {
        lock.parent()
            .unwrap()
            .join("fixtures")
            .join(format!("lib{fx}.so"))
    } else {
        skald::registry::from_lock(&std::fs::read(&lock).unwrap(), &grammars)
            .unwrap()
            .into_iter()
            .find(|e| e.name == name)
            .unwrap_or_else(|| panic!("{name} is not in the lock"))
            .lib
    };
    let sha = skald::job::file_sha256(&path).unwrap();
    (path, sha)
}

fn csharp_init() -> Init {
    let m = skald::builtin::get("csharp").expect("the csharp pack");
    let pack = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packs/csharp/queries");
    Init::from_manifest(
        m,
        std::fs::read_to_string(pack.join("chunks.scm")).unwrap(),
        Some(std::fs::read_to_string(pack.join("tags.scm")).unwrap()),
    )
}

fn spec(pack: &str, grammar: &str, name: &str) -> WorkerSpec {
    let (lib, sha256) = lib_of(name);
    WorkerSpec {
        pack: pack.into(),
        lib,
        grammar: grammar.into(),
        sha256,
    }
}

#[test]
#[ignore = "the sandbox lane: a real Gleipnir child"]
fn the_worker_chunks_inside_the_sandbox_exactly_as_the_in_process_chunker_does() {
    let fx = Fx::new();
    let text = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../hrafn/tests/fixtures/langs/Cache.cs"),
    )
    .unwrap();
    let mut w = Worker::new(
        spec("csharp", "c-sharp", "c-sharp"),
        csharp_init(),
        Arc::new(launcher(&fx)),
    );
    let got = w.chunk("Cache.cs", false, &text, BUDGET);
    let (chunks, symbols, refs) = got.unwrap_or_else(|e| panic!("{e}"));
    let (c2, s2, r2) = chunk_file_refs("Cache.cs", Lang::Csharp, false, &text, BUDGET);
    assert_eq!((chunks, symbols, refs), (c2, s2, r2));
    // structural search and inline values over the same sandboxed process
    let probe = "class G { void M() { Foo(2); Foo(3); } }";
    let own = hrafn::structural::Pattern::new(Lang::Csharp, "Foo($A)", None).unwrap();
    assert_eq!(
        w.find("Foo($A)", probe).unwrap_or_else(|e| panic!("{e}")),
        own.find(probe.as_bytes()).unwrap()
    );
    let scan_text = "class C {\n  int F(int a) {\n    int b = a + 1;\n    return b;\n  }\n}\n";
    let found = w.scan(scan_text, 3).unwrap_or_else(|e| panic!("{e}"));
    assert!(found.iter().any(|(_, _, n)| n == "b"), "{found:?}");
    w.stop();
}

fn probe_init() -> Init {
    Init {
        chunks_scm: "(object) @container".into(),
        ..Init::default()
    }
}

/// What the probe tries to reach, outside any sandbox: a secret file, a TCP listener, a Unix socket server.
struct Bait {
    _secret: PathBuf,
    _tcp: std::net::TcpListener,
    _unix: std::os::unix::net::UnixListener,
    env: Vec<(String, String)>,
}

fn bait(fx: &Fx) -> Bait {
    let secret = fx.p("home/secret.txt");
    std::fs::write(&secret, "do not read me").unwrap();
    let tcp = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let sock = fx.p("run/bait.sock");
    let unix = std::os::unix::net::UnixListener::bind(&sock).unwrap();
    let env = vec![
        (
            "PROBE_SECRET".to_owned(),
            secret.to_string_lossy().into_owned(),
        ),
        (
            "PROBE_PORT".to_owned(),
            tcp.local_addr().unwrap().port().to_string(),
        ),
        ("PROBE_SOCK".to_owned(), sock.to_string_lossy().into_owned()),
    ];
    Bait {
        _secret: secret,
        _tcp: tcp,
        _unix: unix,
        env,
    }
}

/// The control: the probe started plainly reaches everything, so it exits 77 and says so; the worker's reason carries it.
#[test]
#[ignore = "the sandbox lane: a real Gleipnir child"]
fn the_probe_started_plainly_reaches_what_it_tries_so_its_silence_in_the_sandbox_means_something() {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    let fx = Fx::new();
    let b = bait(&fx);
    let w = spec("probe", "probe", "fixture:probe");
    let out = Command::new(BIN)
        .arg("hrafn-parse")
        .arg("--lib")
        .arg(&w.lib)
        .arg("--grammar")
        .arg("probe")
        .arg("--sha256")
        .arg(&w.sha256)
        .envs(b.env.iter().cloned())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .process_group(0)
        .output()
        .unwrap();
    let said = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(77), "{said}");
    for what in [
        "read secret",
        "connect tcp",
        "connect unix",
        "allocate 2 GiB",
    ] {
        assert!(
            said.contains(&format!("PROBE ESCAPE {what}")),
            "{what}: {said}"
        );
    }
    // and it wrote beside its library and in /var/tmp, where the test sees the files
    assert!(said.contains("PROBE WROTE"), "{said}");
    assert!(
        !leftovers(&w.lib).is_empty(),
        "the plain probe left no file"
    );
    clean(&w.lib);
}

/// The files the probe creates when it can, on the outside: beside LIB and in /etc, /usr and /var/tmp.
fn leftovers(lib: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for dir in [
        lib.parent().unwrap(),
        Path::new("/etc"),
        Path::new("/usr"),
        Path::new("/var/tmp"),
    ] {
        if let Ok(rd) = std::fs::read_dir(dir) {
            out.extend(rd.flatten().map(|e| e.path()).filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("probe-wrote-") || n.starts_with("drgnx-probe-"))
            }));
        }
    }
    out
}

fn clean(lib: &Path) {
    for p in leftovers(lib) {
        let _ = std::fs::remove_file(p);
    }
}

/// The sandbox: the same probe, the same bait, and every attempt is refused: the worker starts (a probe that escaped would
/// have exited 77) and serves a request.
#[test]
#[ignore = "the sandbox lane: a real Gleipnir child"]
fn a_grammar_that_tries_to_write_read_secrets_or_connect_gets_nowhere() {
    let fx = Fx::new();
    let b = bait(&fx);
    let mut l = launcher(&fx);
    l.extra_env = b.env.clone();
    let wspec = spec("probe", "probe", "fixture:probe");
    let lib = wspec.lib.clone();
    let mut w = Worker::new(wspec, probe_init(), Arc::new(l));
    w.request_deadline = Duration::from_secs(20);
    clean(&lib);
    w.chunk("a.json", false, "{\"a\": 1}", BUDGET)
        .unwrap_or_else(|e| panic!("the probe was not held: {e}"));
    w.stop();
    // nothing it created is on the outside: a write the sandbox let through would be a file here
    let left = leftovers(&lib);
    clean(&lib);
    assert!(
        left.is_empty(),
        "the sandboxed probe wrote outside: {left:?}"
    );
}

/// The reduced tier cannot keep a grammar out of the user's files and the network: nothing is started, the pack is text.
#[test]
#[ignore = "the sandbox lane: a real Gleipnir child"]
fn the_reduced_tier_starts_nothing_and_says_why() {
    let fx = Fx::new();
    let bin = PathBuf::from(BIN);
    let Ok(sb) = Sandbox::detect(
        Tier::Reduced,
        drgnx_ratatoskr::sandbox::helper_at(&bin),
        None,
    ) else {
        eprintln!("SKIP: no reduced tier here");
        return;
    };
    let l = Sandboxed::new(sb, drgnx_ratatoskr::sandbox::context(&fx.env()), bin);
    let w = spec("csharp", "c-sharp", "c-sharp");
    match l.start(&w) {
        Ok(_) => panic!("a worker started on the reduced tier"),
        Err(e) => assert!(e.contains("reduced tier"), "{e}"),
    }
    let mut worker = Worker::new(w, csharp_init(), Arc::new(l));
    assert!(matches!(
        worker.chunk("a.cs", false, "class A {}", BUDGET),
        Err(WorkerError::Dead(_))
    ));
}
