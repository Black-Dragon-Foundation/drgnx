//! A fork's tree and sandbox, without a sandbox: the tree's manifest and what an edit changed, the `.env` files bound
//! (never copied), and that the spec validates for the full tier with no way out.
use super::fork_seal::{Shape, differ, env_files, link_env_files, mac_spec, manifest, spec};
use gleipnir::{Mode, Net, Target};
use serde_json::json;
use std::path::PathBuf;

#[test]
fn an_edit_is_measured_from_the_manifest_and_env_files_are_not() {
    let d = tempfile::tempdir().unwrap();
    let t = d.path();
    std::fs::create_dir_all(t.join("pkg")).unwrap();
    std::fs::write(t.join("stock.py"), "a = 1\n").unwrap();
    std::fs::write(t.join("pkg/m.py"), "b = 2\n").unwrap();
    std::fs::write(t.join(".env"), "").unwrap();
    let before = manifest(t);
    assert_eq!(
        before.keys().cloned().collect::<Vec<_>>(),
        ["pkg/m.py", "stock.py"]
    );
    std::fs::write(t.join("stock.py"), "a = 2\n").unwrap();
    std::fs::write(t.join("new.py"), "c = 3\n").unwrap();
    std::fs::remove_file(t.join("pkg/m.py")).unwrap();
    std::fs::write(t.join(".env.local"), "X=1").unwrap();
    assert_eq!(
        differ(&before, &manifest(t)),
        ["new.py", "pkg/m.py", "stock.py"]
    );
}

#[test]
fn env_files_are_bound_at_their_places_in_the_tree() {
    let d = tempfile::tempdir().unwrap();
    let root = d.path().join("p");
    let tree = d.path().join("forks/f1/w");
    std::fs::create_dir_all(root.join("app")).unwrap();
    std::fs::create_dir_all(&tree).unwrap();
    for f in [".env", ".env.test", "app/.env", "app/settings.env", "envrc"] {
        std::fs::write(root.join(f), "").unwrap();
    }
    let config = json!({
        "cwd": tree.join("app").to_string_lossy(),
        "envFile": tree.join("app/settings.env").to_string_lossy(),
    });
    let got = env_files(&root, &tree, &config);
    let names: Vec<(PathBuf, PathBuf)> = ["/.env", "/.env.test", "/app/.env", "/app/settings.env"]
        .iter()
        .map(|n| {
            (
                PathBuf::from(format!("{}{n}", root.display())),
                PathBuf::from(format!("{}{n}", tree.display())),
            )
        })
        .collect();
    assert_eq!(got, names);
    // an envFile outside the project is not bound
    let out = json!({"envFile": "/etc/passwd"});
    assert_eq!(env_files(&root, &tree, &out).len(), 2);
}

#[test]
fn the_spec_is_sealed_and_validates() {
    let d = tempfile::tempdir().unwrap();
    // the hub's folders are named by their true names; a temporary folder may sit under a link (macOS's /var)
    let base = d.path().canonicalize().unwrap();
    let tree = base.join("f1/w");
    let tmp = base.join("f1/tmp");
    let root = base.join("p");
    for p in [&tree, &tmp, &root] {
        std::fs::create_dir_all(p).unwrap();
    }
    std::fs::write(root.join(".env"), "").unwrap();
    std::fs::write(tree.join(".env"), "").unwrap();
    let shape = Shape {
        tree: &tree,
        tmp: &tmp,
        read: vec![],
        env_files: vec![(root.join(".env"), tree.join(".env"))],
        path: "/usr/bin:/bin".into(),
        cwd: tree.clone(),
    };
    let s = spec(&shape, Target::LinuxBwrap);
    assert_eq!(s.write, [tree.clone(), tmp.clone()]);
    assert!(matches!(
        &s.net,
        Net::Isolated { relay, loopback: true, .. } if relay.is_empty()
    ));
    assert_eq!(s.binds.len(), 1);
    assert_eq!(s.binds[0].mode, Mode::Ro);
    assert_eq!(s.binds[0].dest, tree.join(".env"));
    let ctx = gleipnir::Context {
        home: PathBuf::from("/nonexistent-home"),
        closed: vec![],
        open_inside_closed: vec![],
        user_sockets: vec![],
        run_parents: vec![],
        program_dirs: vec![],
        env_deny: vec![],
    };
    gleipnir::validate(s, &ctx, Target::LinuxBwrap).expect("a fork's spec validates");
}

/// macOS (spec §21): no mount namespace and no network namespace. The block's ports are the only loopback ports, each
/// `.env` is read where it is (a link in the tree to it, pinned read-only at its source: never copied), and the spec
/// validates for Seatbelt.
#[test]
fn the_mac_spec_keeps_to_its_block_and_reads_env_files_in_place() {
    let d = tempfile::tempdir().unwrap();
    let base = d.path().canonicalize().unwrap();
    let tree = base.join("f1/w");
    let tmp = base.join("f1/tmp");
    let root = base.join("p");
    for p in [&tree, &tmp, &root] {
        std::fs::create_dir_all(p).unwrap();
    }
    std::fs::write(root.join(".env"), "API_TOKEN=x\n").unwrap();
    let env_files = vec![(root.join(".env"), tree.join(".env"))];
    link_env_files(&env_files).unwrap();
    assert_eq!(
        std::fs::read_link(tree.join(".env")).unwrap(),
        root.join(".env")
    );
    assert_eq!(
        std::fs::read_to_string(tree.join(".env")).unwrap(),
        "API_TOKEN=x\n"
    );
    // a second fork of the same tree finds the link there
    link_env_files(&env_files).unwrap();
    let shape = Shape {
        tree: &tree,
        tmp: &tmp,
        read: vec![],
        env_files,
        path: "/usr/bin:/bin".into(),
        cwd: tree.clone(),
    };
    let block = [47008, 47009, 47010, 47011, 47012, 47013, 47014, 47015];
    let s = mac_spec(&shape, &block);
    assert_eq!(s.write, [tree.clone(), tmp.clone()]);
    assert!(matches!(
        &s.net,
        Net::Isolated { relay, mac_tcp_ports, loopback: true, mac_loopback_ports }
            if relay.is_empty() && mac_tcp_ports.is_empty() && mac_loopback_ports == &block
    ));
    assert_eq!(s.binds.len(), 1);
    assert_eq!(s.binds[0].mode, Mode::Ro);
    assert_eq!(s.binds[0].source, root.join(".env"));
    assert_eq!(s.binds[0].dest, root.join(".env"));
    let ctx = gleipnir::Context {
        home: PathBuf::from("/nonexistent-home"),
        closed: vec![],
        open_inside_closed: vec![],
        user_sockets: vec![],
        run_parents: vec![],
        program_dirs: vec![],
        env_deny: vec![],
    };
    gleipnir::validate(s, &ctx, Target::Macos).expect("a fork's macOS spec validates");
}
