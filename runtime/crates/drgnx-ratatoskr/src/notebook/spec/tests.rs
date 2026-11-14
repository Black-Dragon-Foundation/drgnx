use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};

use super::*;

fn put(dir: &Path, name: &str, json: &str) {
    fs::create_dir_all(dir.join(name)).unwrap();
    fs::write(dir.join(name).join("kernel.json"), json).unwrap();
}

const PY: &str = r#"{"argv":["python3","-m","ipykernel_launcher","-f","{connection_file}"],"display_name":"Python 3","language":"python","env":{"A":"1"}}"#;

#[test]
fn the_standard_directories_come_in_order() {
    let d = standard_dirs(Path::new("/h"), Some("/j1:/j2"), Some("/x1:/x2"));
    let s: Vec<&str> = d.iter().map(|p| p.to_str().unwrap()).collect();
    assert_eq!(
        s,
        [
            "/j1/kernels",
            "/j2/kernels",
            "/h/.local/share/jupyter/kernels",
            "/x1/jupyter/kernels",
            "/x2/jupyter/kernels",
            "/usr/local/share/jupyter/kernels",
            "/usr/share/jupyter/kernels"
        ]
    );
    let d = standard_dirs(Path::new("/h"), None, None);
    assert_eq!(d.len(), 3);
    // relative or empty entries are not directories to trust
    let d = standard_dirs(Path::new("/h"), Some(":rel:/ok"), Some(""));
    assert!(d.iter().all(|p| p.is_absolute()));
    assert!(d.contains(&PathBuf::from("/ok/kernels")));
}

#[test]
fn kernelspecs_are_read_and_the_first_directory_wins() {
    let t = tempfile::tempdir().unwrap();
    let (a, b) = (t.path().join("a"), t.path().join("b"));
    put(&a, "python3", PY);
    put(&b, "python3", &PY.replace("Python 3", "Shadowed"));
    put(
        &b,
        "julia",
        r#"{"argv":["julia","{connection_file}"],"display_name":"Julia","language":"julia","interrupt_mode":"message"}"#,
    );
    let specs = discover(&[a.clone(), b, t.path().join("missing")]);
    assert_eq!(
        specs.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
        ["julia", "python3"]
    );
    let py = &specs[1];
    assert_eq!(py.display_name, "Python 3");
    assert_eq!(py.env, [("A".to_string(), "1".to_string())]);
    assert_eq!(py.interrupt, Interrupt::Signal);
    assert_eq!(py.dir, a.join("python3"));
    assert_eq!(specs[0].interrupt, Interrupt::Message);
}

#[test]
fn a_bad_kernelspec_is_skipped_not_fatal() {
    let t = tempfile::tempdir().unwrap();
    let d = t.path();
    put(d, "ok", PY);
    put(d, "no-argv", r#"{"display_name":"x","language":"x"}"#);
    put(d, "empty-argv", r#"{"argv":[],"language":"x"}"#);
    put(d, "no-placeholder", r#"{"argv":["a","b"],"language":"x"}"#);
    put(
        d,
        "argv-not-strings",
        r#"{"argv":["a",3,"{connection_file}"],"language":"x"}"#,
    );
    put(d, "not-json", "{");
    put(
        d,
        "bad-mode",
        r#"{"argv":["a","{connection_file}"],"language":"x","interrupt_mode":"carrier-pigeon"}"#,
    );
    put(
        d,
        "env-not-strings",
        r#"{"argv":["a","{connection_file}"],"language":"x","env":{"A":1}}"#,
    );
    put(d, ".hidden", PY);
    put(d, "has space", PY);
    fs::write(d.join("a-file"), "x").unwrap();
    fs::create_dir_all(d.join("no-json")).unwrap();
    put(
        d,
        "huge",
        &format!("{PY}{}", " ".repeat(MAX_SPEC_BYTES as usize)),
    );
    // a kernel.json that is a link out of the folder is not followed
    fs::create_dir_all(d.join("linked")).unwrap();
    fs::write(t.path().join("elsewhere.json"), PY).unwrap();
    symlink(
        t.path().join("elsewhere.json"),
        d.join("linked/kernel.json"),
    )
    .unwrap();
    let names: Vec<_> = discover(&[d.to_path_buf()])
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert_eq!(names, ["ok"]);
}

fn spec(name: &str, lang: &str) -> Kernelspec {
    Kernelspec {
        name: name.into(),
        display_name: name.into(),
        language: lang.into(),
        argv: vec!["k".into(), "{connection_file}".into()],
        env: vec![],
        interrupt: Interrupt::Signal,
        dir: PathBuf::from("/k"),
    }
}

#[test]
fn the_notebooks_kernelspec_name_beats_its_language() {
    let specs = [
        spec("python3", "python"),
        spec("pypy", "python"),
        spec("julia", "julia"),
    ];
    assert_eq!(
        choose(&specs, Some("pypy"), Some("python")),
        Choice::Found(specs[1].clone())
    );
    // an installed name wins even when the language says otherwise
    assert_eq!(
        choose(&specs, Some("julia"), Some("python")),
        Choice::Found(specs[2].clone())
    );
    // a name that is not installed falls to the language: one match is taken, several are asked
    assert_eq!(
        choose(&specs, Some("gone"), Some("julia")),
        Choice::Found(specs[2].clone())
    );
    assert_eq!(
        choose(&specs, Some("gone"), Some("python")),
        Choice::Ask(vec!["python3".into(), "pypy".into()])
    );
    assert_eq!(
        choose(&specs, None, Some("PYTHON")),
        Choice::Ask(vec!["python3".into(), "pypy".into()])
    );
    assert_eq!(choose(&specs, Some("gone"), Some("r")), Choice::Missing);
    assert_eq!(choose(&specs, None, None), Choice::Missing);
    assert_eq!(
        choose(&[], Some("python3"), Some("python")),
        Choice::Missing
    );
}

#[test]
fn argv_gets_the_connection_file_path_and_nothing_else() {
    let mut s = spec("k", "x");
    s.argv = vec![
        "py".into(),
        "-f".into(),
        "{connection_file}".into(),
        "--x={connection_file}".into(),
    ];
    assert_eq!(
        s.argv_for(Path::new("/s/kernel-1.json")),
        ["py", "-f", "/s/kernel-1.json", "--x=/s/kernel-1.json"]
    );
}

#[test]
fn the_private_folder_is_made_0700_and_a_loose_or_foreign_one_is_refused() {
    let t = tempfile::tempdir().unwrap();
    let p = t.path().join("session");
    let made = private_folder(&p).unwrap();
    assert_eq!(fs::metadata(&made).unwrap().mode() & 0o777, 0o700);
    assert!(
        private_folder(&p).is_ok(),
        "an existing good folder is fine"
    );
    fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(private_folder(&p).unwrap_err().contains("0700"));
    fs::set_permissions(&p, fs::Permissions::from_mode(0o770)).unwrap();
    assert!(private_folder(&p).is_err());
    // a link is refused even when it points at a good folder
    let good = t.path().join("good");
    private_folder(&good).unwrap();
    let link = t.path().join("link");
    symlink(&good, &link).unwrap();
    assert!(private_folder(&link).unwrap_err().contains("link"));
    // a file is refused
    let f = t.path().join("file");
    fs::write(&f, "").unwrap();
    assert!(private_folder(&f).is_err());
}

#[test]
fn a_connection_file_is_0600_ipc_holds_the_key_and_goes_with_the_connection() {
    let t = tempfile::tempdir().unwrap();
    let folder = private_folder(&t.path().join("s")).unwrap();
    let c = Connection::create(&folder, "k1", "python3").unwrap();
    let meta = fs::metadata(&c.path).unwrap();
    assert_eq!(meta.mode() & 0o777, 0o600);
    assert_eq!(c.path, folder.join("kernel-k1.json"));
    let v: serde_json::Value = serde_json::from_slice(&fs::read(&c.path).unwrap()).unwrap();
    assert_eq!(v["transport"], "ipc");
    assert_eq!(v["ip"], c.prefix.to_str().unwrap());
    assert!(c.prefix.starts_with(&folder));
    assert_eq!(v["signature_scheme"], "hmac-sha256");
    assert_eq!(v["kernel_name"], "python3");
    assert_eq!(v["key"], c.key.to_connection_file());
    let ports: Vec<u64> = CHANNELS
        .iter()
        .map(|ch| v[format!("{ch}_port")].as_u64().unwrap())
        .collect();
    assert_eq!(ports, [1, 2, 3, 4, 5]);
    assert_eq!(
        c.socket("iopub").unwrap(),
        PathBuf::from(format!("{}-2", c.prefix.display()))
    );
    assert!(c.socket("nope").is_none());
    let path = c.path.clone();
    drop(c);
    assert!(!path.exists(), "the file goes when the connection does");
}

#[test]
fn a_connection_file_is_never_overwritten_and_each_has_its_own_key() {
    let t = tempfile::tempdir().unwrap();
    let folder = private_folder(&t.path().join("s")).unwrap();
    let a = Connection::create(&folder, "k1", "p").unwrap();
    let before = fs::read(&a.path).unwrap();
    assert!(Connection::create(&folder, "k1", "p").is_err(), "O_EXCL");
    assert_eq!(fs::read(&a.path).unwrap(), before);
    // a planted link at the name is not followed
    symlink(t.path().join("victim"), folder.join("kernel-k2.json")).unwrap();
    assert!(Connection::create(&folder, "k2", "p").is_err());
    assert!(!t.path().join("victim").exists());
    let b = Connection::create(&folder, "k3", "p").unwrap();
    assert_ne!(a.key.to_connection_file(), b.key.to_connection_file());
}

#[test]
fn an_id_that_would_escape_or_a_path_too_long_for_a_socket_is_refused() {
    let t = tempfile::tempdir().unwrap();
    let folder = private_folder(&t.path().join("s")).unwrap();
    for id in ["", "../x", "a/b", "a b", ".."] {
        assert!(Connection::create(&folder, id, "p").is_err(), "{id:?}");
    }
    let long = "x".repeat(MAX_SOCKET_PATH);
    let err = Connection::create(&folder, &long, "p").unwrap_err();
    assert!(err.contains("socket path"), "{err}");
}

#[test]
fn the_sweep_removes_only_connection_files_of_kernels_that_are_gone() {
    let t = tempfile::tempdir().unwrap();
    let folder = private_folder(&t.path().join("s")).unwrap();
    let live = Connection::create(&folder, "live", "p").unwrap();
    let dead = folder.join("kernel-dead.json");
    fs::write(&dead, "{}").unwrap();
    let other = folder.join("notes.txt");
    fs::write(&other, "keep").unwrap();
    let dir = folder.join("kernel-dir.json");
    fs::create_dir(&dir).unwrap();
    assert_eq!(sweep(&folder, std::slice::from_ref(&live.path)), 1);
    assert!(live.path.exists() && !dead.exists() && other.exists() && dir.exists());
}
