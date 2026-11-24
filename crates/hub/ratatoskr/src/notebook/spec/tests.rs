use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};

use super::*;

fn put(dir: &Path, name: &str, json: &str) {
    fs::create_dir_all(dir.join(name)).unwrap();
    crate::fsio::write(dir.join(name).join("kernel.json"), json).unwrap();
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
    crate::fsio::write(d.join("a-file"), "x").unwrap();
    fs::create_dir_all(d.join("no-json")).unwrap();
    put(
        d,
        "huge",
        &format!("{PY}{}", " ".repeat(MAX_SPEC_BYTES as usize)),
    );
    // a kernel.json that is a link out of the folder is not followed
    fs::create_dir_all(d.join("linked")).unwrap();
    crate::fsio::write(t.path().join("elsewhere.json"), PY).unwrap();
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
        transport: Transport::Ipc,
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
    assert!(private_folder(&p).unwrap_err().message().contains("0700"));
    fs::set_permissions(&p, fs::Permissions::from_mode(0o770)).unwrap();
    assert!(private_folder(&p).is_err());
    // a link is refused even when it points at a good folder
    let good = t.path().join("good");
    private_folder(&good).unwrap();
    let link = t.path().join("link");
    symlink(&good, &link).unwrap();
    assert!(
        private_folder(&link)
            .unwrap_err()
            .message()
            .contains("link")
    );
    // a file is refused
    let f = t.path().join("file");
    crate::fsio::write(&f, "").unwrap();
    assert!(private_folder(&f).is_err());
}

#[test]
fn a_kernelspec_names_its_transport_ipc_unless_it_says_it_cannot() {
    let t = tempfile::tempdir().unwrap();
    let d = t.path();
    let spec = |name: &str, meta: &str| {
        put(
            d,
            name,
            &format!(r#"{{"argv":["k","{{connection_file}}"],"language":"x"{meta}}}"#),
        )
    };
    spec("plain", "");
    spec("ipc", r#","metadata":{"drgnx_transport":"ipc"}"#);
    spec(
        "tcp",
        r#","metadata":{"drgnx_transport":"tcp","debugger":true}"#,
    );
    spec("other-metadata", r#","metadata":{"debugger":true}"#);
    spec("bad", r#","metadata":{"drgnx_transport":"carrier-pigeon"}"#);
    spec("not-text", r#","metadata":{"drgnx_transport":3}"#);
    let (specs, skipped) = discover_with_skips(&[d.to_path_buf()]);
    let of = |n: &str| specs.iter().find(|s| s.name == n).map(|s| s.transport);
    assert_eq!(of("plain"), Some(Transport::Ipc));
    assert_eq!(of("ipc"), Some(Transport::Ipc));
    assert_eq!(of("tcp"), Some(Transport::Tcp));
    assert_eq!(of("other-metadata"), Some(Transport::Ipc));
    // an unknown transport is a kernelspec not used, said so: never ipc by guess
    assert_eq!(of("bad"), None);
    assert_eq!(of("not-text"), None);
    assert!(skipped.iter().any(|s| s.name == "bad"));
}

#[test]
fn a_tcp_connection_file_names_loopback_and_its_five_ports_and_goes_with_the_connection() {
    let t = tempfile::tempdir().unwrap();
    let folder = private_folder(&t.path().join("s")).unwrap();
    let ports = [47001, 47002, 47003, 47004, 47005];
    let c = Connection::create_tcp(&folder, "k1", "python3", ports).unwrap();
    assert_eq!(fs::metadata(&c.path).unwrap().mode() & 0o777, 0o600);
    let v: serde_json::Value = serde_json::from_slice(&fs::read(&c.path).unwrap()).unwrap();
    assert_eq!(v["transport"], "tcp");
    assert_eq!(v["ip"], "127.0.0.1", "loopback only, never a wildcard");
    for (ch, port) in CHANNELS.iter().zip(ports) {
        assert_eq!(v[format!("{ch}_port")], port);
    }
    assert_eq!(v["key"], c.key.to_connection_file());
    assert_eq!(c.endpoint(1), "tcp://127.0.0.1:47001");
    assert_eq!(c.endpoint(4), "tcp://127.0.0.1:47004");
    // a file that exists is never overwritten, as for ipc
    assert!(Connection::create_tcp(&folder, "k1", "p", ports).is_err());
    let path = c.path.clone();
    drop(c);
    assert!(!path.exists());
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
fn the_ipc_socket_files_a_kernel_left_go_with_the_connection() {
    let t = tempfile::tempdir().unwrap();
    let folder = private_folder(&t.path().join("s")).unwrap();
    let c = Connection::create(&folder, "k1", "python3").unwrap();
    let socks: Vec<PathBuf> = CHANNELS.iter().filter_map(|ch| c.socket(ch)).collect();
    for s in &socks {
        crate::fsio::write(s, b"").unwrap();
    }
    drop(c);
    assert!(socks.iter().all(|s| !s.exists()), "a socket file is left");
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
    assert!(err.message().contains("socket path"), "{err}");
}

#[test]
fn the_sweep_removes_only_connection_files_of_kernels_that_are_gone() {
    let t = tempfile::tempdir().unwrap();
    let folder = private_folder(&t.path().join("s")).unwrap();
    let live = Connection::create(&folder, "live", "p").unwrap();
    let dead = folder.join("kernel-dead.json");
    crate::fsio::write(&dead, "{}").unwrap();
    let other = folder.join("notes.txt");
    crate::fsio::write(&other, "keep").unwrap();
    let dir = folder.join("kernel-dir.json");
    fs::create_dir(&dir).unwrap();
    assert_eq!(sweep(&folder, std::slice::from_ref(&live.path)), 1);
    assert!(live.path.exists() && !dead.exists() && other.exists() && dir.exists());
}

#[test]
fn a_kernelspec_writable_by_others_is_not_trusted_and_a_fifo_for_kernel_json_is_not_waited_on() {
    let t = tempfile::tempdir().unwrap();
    let d = t.path();
    put(d, "ok", PY);
    put(d, "dir-open", PY);
    fs::set_permissions(d.join("dir-open"), fs::Permissions::from_mode(0o777)).unwrap();
    put(d, "file-open", PY);
    fs::set_permissions(
        d.join("file-open/kernel.json"),
        fs::Permissions::from_mode(0o666),
    )
    .unwrap();
    fs::create_dir_all(d.join("fifo")).unwrap();
    mkfifo(&d.join("fifo/kernel.json"));
    let names: Vec<_> = discover(&[d.to_path_buf()])
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert_eq!(names, ["ok"]);
}

#[test]
fn trust_is_ours_or_roots_and_group_write_only_for_the_users_own_private_group() {
    let me = (1000, 1000);
    let private = |g: u32| g == 1000;
    assert_eq!(trust(1000, 1000, 0o644, me, private), Ok(()));
    assert_eq!(trust(0, 0, 0o755, me, private), Ok(()), "root's");
    // `ipykernel install --user` under umask 0002 with a user private group
    assert_eq!(trust(1000, 1000, 0o664, me, private), Ok(()));
    assert_eq!(trust(1000, 1000, 0o775, me, private), Ok(()));
    assert!(
        trust(1000, 1000, 0o664, me, |_| false)
            .unwrap_err()
            .contains("other members"),
        "a group with other members"
    );
    assert!(
        trust(1000, 50, 0o664, me, |_| true)
            .unwrap_err()
            .contains("other members"),
        "a group that is not the primary one"
    );
    assert!(
        trust(1000, 1000, 0o646, me, private)
            .unwrap_err()
            .contains("everyone")
    );
    assert!(
        trust(1001, 1000, 0o644, me, private)
            .unwrap_err()
            .contains("another user")
    );
}

#[test]
fn a_skipped_kernelspec_says_why() {
    let t = tempfile::tempdir().unwrap();
    let d = t.path();
    put(d, "ok", PY);
    put(d, "open", PY);
    fs::set_permissions(
        d.join("open/kernel.json"),
        fs::Permissions::from_mode(0o666),
    )
    .unwrap();
    put(d, "broken", "{");
    fs::create_dir_all(d.join("empty")).unwrap();
    let (specs, skipped) = discover_with_skips(&[d.to_path_buf()]);
    assert_eq!(
        specs.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
        ["ok"]
    );
    let mut by_name: Vec<_> = skipped
        .iter()
        .map(|s| (s.name.as_str(), s.why.as_str()))
        .collect();
    by_name.sort();
    assert_eq!(by_name.len(), 2, "{by_name:?}");
    assert!(
        by_name[0].0 == "broken" && by_name[0].1.contains("not a valid kernelspec"),
        "{by_name:?}"
    );
    assert!(
        by_name[1].0 == "open" && by_name[1].1.contains("writable by everyone"),
        "{by_name:?}"
    );
}

#[test]
fn kernel_json_is_opened_without_waiting_on_a_fifo_and_without_following_a_link() {
    let t = tempfile::tempdir().unwrap();
    let fifo = t.path().join("kernel.json");
    mkfifo(&fifo);
    // an open that waits for a writer never comes back: the test would hang, so it asks from a thread and waits with a deadline
    let done = std::sync::Arc::new(std::sync::Mutex::new(None));
    let d2 = done.clone();
    std::thread::spawn(move || *d2.lock().unwrap() = Some(open_spec_file(&fifo).err()));
    let why = skuld::wait_until("the open to come back", 30, || done.lock().unwrap().take());
    assert_eq!(why.as_deref(), Some("kernel.json is not a regular file"));
    let real = t.path().join("real.json");
    crate::fsio::write(&real, PY).unwrap();
    let link = t.path().join("link.json");
    symlink(&real, &link).unwrap();
    assert!(open_spec_file(&link).is_err());
    assert!(open_spec_file(&real).is_ok());
}

#[test]
fn a_shared_primary_group_is_not_the_users_private_one() {
    let passwd = "root:x:0:0:r:/root:/bin/sh\nme:x:1000:100:me:/home/me:/bin/sh\nyou:x:1001:100:you:/home/you:/bin/sh\nsolo:x:1002:1002::/home/solo:/bin/sh\nbad line\n";
    assert!(
        !only_primary_of(passwd, 100, 1000),
        "`users` is two accounts' group"
    );
    assert!(only_primary_of(passwd, 1002, 1002));
    assert!(
        !only_primary_of(passwd, 1002, 1000),
        "another account has it"
    );
    assert!(only_primary_of(passwd, 555, 1000), "nobody has it");
    assert!(only_primary_of("", 100, 1000));
}

/// A FIFO at PATH (rustix has no mknodat on macOS).
fn mkfifo(path: &std::path::Path) {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: mkfifo(2) on a NUL-terminated path that lives through the call.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
}
