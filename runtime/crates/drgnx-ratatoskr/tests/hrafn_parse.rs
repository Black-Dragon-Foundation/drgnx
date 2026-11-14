//! The `hrafn-parse` worker as a real process (language packs Task 6b-1): the hub's own binary loads a grammar library and
//! answers framed requests. These tests start it plainly (no sandbox: that lane is `hrafn_parse_sandbox.rs`) and check
//! what must hold whatever a grammar does: the answer equals the in-process chunker's, a library with the wrong hash is
//! refused, and a grammar that faults or spins on its first token costs the worker, never the caller, which gets an error
//! (its file reads as text) and finds the process gone.
//!
//! The libraries come from the pack job's folder (`DRGNX_PACK_LOCK`, `DRGNX_PACK_GRAMMARS`, `test/packs/hub-grammars.sh`):
//! the C# grammar, and `fixtures/libloopy.so` and `fixtures/libcrashy.so` beside the lock.
//!
//! test-pattern: process (P). The waits are the worker's deadlines, set to what a failing grammar needs, never more.

use hrafn::Lang;
use hrafn::chunk::worker::{Init, Launch, Started, Worker, WorkerError, WorkerSpec};
use hrafn::chunk::{BUDGET, chunk_file_refs};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const BIN: &str = env!("CARGO_BIN_EXE_ratatoskr");

/// Starts the worker plainly, in a process group of its own; the pids it started are kept.
struct Plain {
    pids: Arc<Mutex<Vec<i32>>>,
}

impl Launch for Plain {
    fn start(&self, spec: &WorkerSpec) -> Result<Started, String> {
        let mut c = Command::new(BIN)
            .arg("hrafn-parse")
            .arg("--lib")
            .arg(&spec.lib)
            .arg("--grammar")
            .arg(&spec.grammar)
            .arg("--sha256")
            .arg(&spec.sha256)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()
            .map_err(|e| e.to_string())?;
        let pid = c.id() as i32;
        self.pids.lock().unwrap().push(pid);
        let stdin = c.stdin.take().ok_or("no stdin")?;
        let mut stderr = c.stderr.take().ok_or("no stderr")?;
        let tail = Arc::new(Mutex::new(String::new()));
        let t2 = tail.clone();
        std::thread::spawn(move || {
            let mut s = String::new();
            let _ = std::io::Read::read_to_string(&mut stderr, &mut s);
            *t2.lock().unwrap() = s;
        });
        let stdout = c.stdout.take().ok_or("no stdout")?;
        Ok(Started {
            stdin: Box::new(stdin),
            stdout: Box::new(stdout),
            kill: Box::new(move || {
                // SAFETY: killpg(2) of a process group this launcher made.
                unsafe { libc::killpg(pid, libc::SIGKILL) };
                let _ = c.kill();
                let _ = c.wait();
            }),
            stderr: Box::new(move || tail.lock().unwrap().clone()),
        })
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: kill(2) with signal 0 only asks whether the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// (library path, sha256) of the grammar NAME the pack job built, or of FILE in its `fixtures`.
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
        let entries =
            skald::registry::from_lock(&std::fs::read(&lock).unwrap(), &grammars).unwrap();
        entries
            .into_iter()
            .find(|e| e.name == name)
            .unwrap_or_else(|| panic!("{name} is not in the lock"))
            .lib
    };
    let sha = skald::job::file_sha256(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
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

fn fixture_init() -> Init {
    // any pattern the JSON grammar accepts: the lexer is what the fixtures break
    Init {
        chunks_scm: "(object) @container".into(),
        ..Init::default()
    }
}

fn worker(
    pack: &str,
    grammar: &str,
    lib: PathBuf,
    sha256: String,
    init: Init,
) -> (Worker, Arc<Mutex<Vec<i32>>>) {
    let pids = Arc::new(Mutex::new(Vec::new()));
    let spec = WorkerSpec {
        pack: pack.into(),
        lib,
        grammar: grammar.into(),
        sha256,
    };
    (
        Worker::new(spec, init, Arc::new(Plain { pids: pids.clone() })),
        pids,
    )
}

#[test]
fn the_worker_chunks_a_file_exactly_as_the_in_process_chunker_does() {
    let text = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../hrafn/tests/fixtures/langs/Cache.cs"),
    )
    .unwrap();
    let (lib, sha) = lib_of("c-sharp");
    let (mut w, pids) = worker("csharp", "c-sharp", lib, sha, csharp_init());
    let (chunks, symbols, refs) = w.chunk("Cache.cs", false, &text, BUDGET).unwrap();
    let (c2, s2, r2) = chunk_file_refs("Cache.cs", Lang::Csharp, false, &text, BUDGET);
    assert_eq!(chunks, c2);
    assert_eq!(symbols, s2);
    assert_eq!(refs, r2);
    assert!(!symbols.is_empty());
    // a second file reuses the same process
    w.chunk("Other.cs", false, "class A { void F() {} }", BUDGET)
        .unwrap();
    assert_eq!(pids.lock().unwrap().len(), 1);
    w.stop();
    let pid = pids.lock().unwrap()[0];
    assert!(!alive(pid), "the worker is gone after stop");
}

#[test]
fn a_library_whose_hash_is_not_the_given_one_is_refused_and_the_pack_ends_up_text() {
    let (lib, _) = lib_of("c-sharp");
    let (mut w, _) = worker("csharp", "c-sharp", lib, "0".repeat(64), csharp_init());
    for _ in 0..2 {
        assert!(matches!(
            w.chunk("a.cs", false, "class A {}", BUDGET),
            Err(WorkerError::File(_))
        ));
    }
    assert!(matches!(
        w.chunk("a.cs", false, "class A {}", BUDGET),
        Err(WorkerError::Dead(_))
    ));
    assert!(w.dead().is_some());
}

/// A grammar that faults on its first token: the worker dies, the caller gets an error for the file, and the next file
/// gets a new worker (until three failures make the pack text). This test process is the proof the caller survives.
#[test]
fn a_grammar_that_faults_costs_the_worker_never_the_caller() {
    let (lib, sha) = lib_of("fixture:crashy");
    let (mut w, pids) = worker("crashy", "crashy", lib, sha, fixture_init());
    for _ in 0..2 {
        let e = w.chunk("a.json", false, "{\"a\": 1}", BUDGET).unwrap_err();
        assert!(matches!(e, WorkerError::File(_)), "{e:?}");
    }
    assert!(matches!(
        w.chunk("a.json", false, "{}", BUDGET),
        Err(WorkerError::Dead(_))
    ));
    let pids = pids.lock().unwrap().clone();
    assert_eq!(pids.len(), 3, "a new process for each of the three tries");
    assert!(
        pids.iter().all(|p| !alive(*p)),
        "no worker is left: {pids:?}"
    );
}

/// A grammar that spins on its first token (a scanner that never returns): the hub's deadline ends it, the whole process
/// group, and the file reads as text.
#[test]
fn a_grammar_that_spins_is_cut_at_the_deadline_and_killed() {
    let (lib, sha) = lib_of("fixture:loopy");
    let (mut w, pids) = worker("loopy", "loopy", lib, sha, fixture_init());
    w.request_deadline = Duration::from_secs(2);
    let e = w.chunk("a.json", false, "{\"a\": 1}", BUDGET).unwrap_err();
    assert!(
        matches!(&e, WorkerError::File(m) if m.contains("no answer")),
        "{e:?}"
    );
    let pid = pids.lock().unwrap()[0];
    assert!(!alive(pid), "the spinning worker was killed");
}

/// The hub reads the fetched packs from `active.eld` and the lock: a pack the built-in set does not have, with `:hrafn`
/// queries and a built, hashed library; the built-in ones, and one whose library is missing, are left out.
#[test]
fn the_hub_finds_the_fetched_packs_in_active_eld() {
    use runstav::paths::{Env, config_dir, data_dir, state_dir};
    let dir = tempfile::tempdir().unwrap();
    let b = dir.path().to_str().unwrap().to_owned();
    let env = Env::new(
        &[
            ("HOME", b.as_str()),
            ("XDG_DATA_HOME", &format!("{b}/data")),
            ("XDG_STATE_HOME", &format!("{b}/state")),
            ("XDG_CONFIG_HOME", &format!("{b}/config")),
            ("XDG_RUNTIME_DIR", &format!("{b}/run")),
        ],
        rustix::process::geteuid().as_raw(),
    );
    let (real_lib, sha) = lib_of("c-sharp");
    let libdir = data_dir(&env).join("grammars/c-sharp/abc123");
    std::fs::create_dir_all(&libdir).unwrap();
    std::fs::copy(&real_lib, libdir.join("libtree-sitter-c-sharp.so")).unwrap();
    std::fs::create_dir_all(config_dir(&env)).unwrap();
    std::fs::write(
        config_dir(&env).join("drgnx.lock.eld"),
        format!("(:grammars ((c-sharp :commit \"abc123\" :lib-sha256 \"{sha}\")))"),
    )
    .unwrap();
    // the fetched pack's folder: the csharp pack under another name and extension
    let pack = dir.path().join("packs/csx");
    std::fs::create_dir_all(pack.join("queries")).unwrap();
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packs/csharp");
    let manifest = std::fs::read_to_string(src.join("pack.eld"))
        .unwrap()
        .replace(":pack \"csharp\"", ":pack \"csx\"")
        .replace(":extensions (\"cs\")", ":extensions (\"xcs\")");
    std::fs::write(pack.join("pack.eld"), manifest).unwrap();
    for f in ["chunks.scm", "tags.scm"] {
        std::fs::copy(src.join("queries").join(f), pack.join("queries").join(f)).unwrap();
    }
    let active = format!(
        "(:version 1 :packs ((csx :manifest \"{m}\" :grammars ((c-sharp . \"{l}\")))
           (csharp :manifest \"{src}/pack.eld\" :grammars ((c-sharp . \"{l}\")))
           (gone :manifest \"{dir}/packs/gone/pack.eld\" :grammars nil)))",
        m = pack.join("pack.eld").display(),
        l = libdir.display(),
        src = src.display(),
        dir = dir.path().display(),
    );
    std::fs::create_dir_all(state_dir(&env).join("packs")).unwrap();
    std::fs::write(state_dir(&env).join("packs/active.eld"), active).unwrap();

    let got = drgnx_ratatoskr::parse_worker::fetched(&env);
    assert_eq!(got.len(), 1, "csharp is built in and gone has no folder");
    let f = &got[0];
    assert_eq!(f.spec.pack, "csx");
    assert_eq!(f.spec.grammar, "c-sharp");
    assert_eq!(f.spec.sha256, sha);
    assert_eq!(f.spec.lib, libdir.join("libtree-sitter-c-sharp.so"));
    assert_eq!(f.extensions, ["xcs"]);
    assert!(f.init.chunks_scm.contains("@definition.class"));
    assert!(
        f.init
            .tags_scm
            .as_deref()
            .is_some_and(|t| t.contains("@reference.call"))
    );
    // no library, no pack
    std::fs::remove_file(libdir.join("libtree-sitter-c-sharp.so")).unwrap();
    assert!(drgnx_ratatoskr::parse_worker::fetched(&env).is_empty());
}

/// What is hashed is what is loaded: the library's file is replaced between the two (as a writer of the folder could), and
/// the worker still serves the grammar it hashed, because it loads through the descriptor it hashed.
#[test]
fn the_library_loaded_is_the_one_hashed_whatever_the_path_becomes() {
    use hrafn::chunk::worker::{Reply, read_frame, serve_with, write_frame};
    let (real, sha) = lib_of("c-sharp");
    let (other, _) = lib_of("fixture:loopy");
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("libx.so");
    std::fs::copy(&real, &path).unwrap();
    let mut input = Vec::new();
    write_frame(&mut input, &serde_json::to_vec(&csharp_init()).unwrap()).unwrap();
    let mut out = Vec::new();
    let swap = || {
        let tmp = dir.path().join("swap");
        std::fs::copy(&other, &tmp).unwrap();
        std::fs::rename(&tmp, &path).unwrap();
    };
    let code = serve_with(&path, "c-sharp", &sha, &mut &input[..], &mut out, &swap);
    assert_eq!(code, 0, "the swapped file was loaded, not the hashed one");
    let first = read_frame(&mut &out[..], 1 << 20).unwrap().unwrap();
    assert!(matches!(
        serde_json::from_slice::<Reply>(&first).unwrap(),
        Reply::Ready { .. }
    ));
}

const PROBE_TEXT: &str = "class G { void M() { Foo(2); Foo(3); } }";
const SCAN_TEXT: &str = "class C {\n  int F(int a) {\n    int b = a + 1;\n    return b;\n  }\n}\n";

/// What the worker answers to a structural find and an inline scan is what the hub's own C# grammar answers.
#[test]
fn the_worker_finds_and_scans_exactly_as_the_built_in_c_sharp_does() {
    let (lib, sha) = lib_of("c-sharp");
    let (mut w, _) = worker("csharp", "c-sharp", lib, sha, csharp_init());
    let found = w.find("Foo($A)", PROBE_TEXT).unwrap();
    let own = hrafn::structural::Pattern::new(Lang::Csharp, "Foo($A)", None).unwrap();
    assert_eq!(found, own.find(PROBE_TEXT.as_bytes()).unwrap());
    assert_eq!(found.len(), 2);
    assert!(matches!(
        w.find("Foo(", PROBE_TEXT),
        Err(WorkerError::Pattern(_))
    ));
    // the worker is still the same process after a refused pattern
    assert_eq!(w.find("Foo($A)", PROBE_TEXT).unwrap(), found);
    let i = skald::builtin::get("csharp")
        .unwrap()
        .inline
        .as_ref()
        .unwrap();
    let lists = hrafn::inline_scan::Lists {
        functions: i.functions.clone(),
        loops: i.loops.clone(),
        names: i.names.clone(),
    };
    let mut parser = tree_sitter::Parser::new();
    parser
        .set_language(&skald::registry::language("c-sharp").unwrap())
        .unwrap();
    let tree = parser.parse(SCAN_TEXT, None).unwrap();
    let want = hrafn::inline_scan::scan(&tree, SCAN_TEXT, 3, &lists);
    assert!(!want.is_empty());
    assert_eq!(w.scan(SCAN_TEXT, 3).unwrap(), want);
    w.stop();
}

/// The same containment for the other two operations: a grammar that faults or spins on its first token costs the worker
/// whatever is asked of it.
#[test]
fn a_faulting_or_spinning_grammar_costs_the_worker_for_a_find_and_a_scan_too() {
    let (lib, sha) = lib_of("fixture:crashy");
    let (mut w, pids) = worker("crashy", "crashy", lib, sha, fixture_init());
    assert!(matches!(
        w.find("x", "{\"a\": 1}"),
        Err(WorkerError::File(_))
    ));
    assert!(matches!(w.scan("{\"a\": 1}", 0), Err(WorkerError::File(_))));
    assert!(pids.lock().unwrap().iter().all(|p| !alive(*p)));
    let (lib, sha) = lib_of("fixture:loopy");
    let (mut w, pids) = worker("loopy", "loopy", lib, sha, fixture_init());
    w.request_deadline = Duration::from_secs(2);
    assert!(
        matches!(w.scan("{\"a\": 1}", 0), Err(WorkerError::File(m)) if m.contains("no answer"))
    );
    assert!(pids.lock().unwrap().iter().all(|p| !alive(*p)));
}
