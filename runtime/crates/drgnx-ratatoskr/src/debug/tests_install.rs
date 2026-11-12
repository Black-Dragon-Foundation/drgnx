//! Debug: Install Adapter (spec §9.3, tier 2): pinned archives checked against their sha256 and unpacked safely into
//! the tools folder, debugpy into the tools venv with `--require-hashes`, system packages named.
use super::adapters::Table;
use super::install::{self, Plan, Source};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// A tar.gz of ENTRIES (path, bytes, mode); a path ending in `/` is a folder, a mode of 0o120777 a symlink to BYTES.
fn tgz(entries: &[(&str, &[u8], u32)]) -> Vec<u8> {
    let gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    let mut t = tar::Builder::new(gz);
    for (path, bytes, mode) in entries {
        let mut h = tar::Header::new_gnu();
        h.set_mode(*mode & 0o7777);
        if path.ends_with('/') {
            h.set_entry_type(tar::EntryType::Directory);
            h.set_size(0);
            t.append_data(&mut h, path, std::io::empty()).unwrap();
        } else if *mode == 0o120777 {
            h.set_entry_type(tar::EntryType::Symlink);
            h.set_size(0);
            t.append_link(&mut h, path, std::str::from_utf8(bytes).unwrap())
                .unwrap();
        } else {
            h.set_size(bytes.len() as u64);
            // set_path refuses `..`: write the name bytes directly so the unsafe case can be built
            let name: &mut [u8; 100] = &mut h.as_old_mut().name;
            name[..path.len()].copy_from_slice(path.as_bytes());
            h.set_cksum();
            t.append(&h, *bytes).unwrap();
        }
    }
    t.into_inner().unwrap().finish().unwrap()
}

/// A zip of ENTRIES (path, bytes, mode).
fn zip_of(entries: &[(&str, &[u8], u32)]) -> Vec<u8> {
    let mut w = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    for (name, bytes, mode) in entries {
        let o = zip::write::SimpleFileOptions::default().unix_permissions(*mode);
        w.start_file(*name, o).unwrap();
        w.write_all(bytes).unwrap();
    }
    w.finish().unwrap().into_inner()
}

/// A plan for an archive at `https://example.invalid/NAME` with digest SHA.
fn archive(name: &str, sha: &str, into: &str, root: Option<&str>) -> Plan {
    install::plan(
        &serde_json::json!({"url": format!("https://example.invalid/{name}"), "sha256": sha,
                            "into": into, "root": root}),
        "linux-x64",
    )
    .unwrap()
}

#[test]
fn the_tables_install_entries_read_as_plans() {
    let t = Table::builtin();
    let js = install::plan(
        t.by_id("js-debug").unwrap().install.as_ref().unwrap(),
        "linux-x64",
    )
    .unwrap();
    assert!(
        matches!(js, Plan::Archive { ref into, ref root, .. } if into == "js-debug" && root.as_deref() == Some("js-debug"))
    );
    let py = install::plan(
        t.by_id("debugpy").unwrap().install.as_ref().unwrap(),
        "linux-x64",
    )
    .unwrap();
    assert!(
        matches!(py, Plan::Pip { ref requirement, .. } if requirement.starts_with("debugpy=="))
    );
    let lldb = install::plan(
        t.by_id("codelldb").unwrap().install.as_ref().unwrap(),
        "linux-x64",
    )
    .unwrap();
    assert!(
        matches!(lldb, Plan::Archive { ref url, .. } if url.ends_with("codelldb-linux-x64.vsix"))
    );
    let mac = install::plan(
        t.by_id("codelldb").unwrap().install.as_ref().unwrap(),
        "darwin-arm64",
    )
    .unwrap();
    assert!(
        matches!(mac, Plan::Archive { ref url, .. } if url.ends_with("codelldb-darwin-arm64.vsix"))
    );
    let e = install::plan(
        t.by_id("codelldb").unwrap().install.as_ref().unwrap(),
        "plan9-mips",
    )
    .unwrap_err();
    assert!(e.contains("plan9-mips"), "{e}");
    let dlv = install::plan(
        t.by_id("delve").unwrap().install.as_ref().unwrap(),
        "linux-x64",
    )
    .unwrap();
    assert_eq!(dlv, Plan::System("dnf install delve".into()));
}

#[tokio::test]
async fn a_pinned_tarball_is_checked_and_unpacked_under_its_folder() {
    let src = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bytes = tgz(&[
        ("js-debug/", b"", 0o755),
        ("js-debug/src/dapDebugServer.js", b"// server", 0o644),
        ("js-debug/bin/run", b"#!/bin/sh", 0o755),
    ]);
    std::fs::write(src.path().join("js.tgz"), &bytes).unwrap();
    let plan = archive("js.tgz", &sha(&bytes), "js-debug", Some("js-debug"));
    install::install(&plan, tools.path(), &Source::Dir(src.path().into()), &[])
        .await
        .unwrap();
    let dir = tools.path().join("js-debug");
    assert_eq!(
        std::fs::read(dir.join("src/dapDebugServer.js")).unwrap(),
        b"// server"
    );
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&dir.join("bin/run")), 0o755);
    assert_eq!(mode(&dir.join("src/dapDebugServer.js")), 0o644);
    // only the folder: no partial or download left beside it
    let names: Vec<_> = std::fs::read_dir(tools.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, ["js-debug"]);
}

#[tokio::test]
async fn a_download_with_another_digest_installs_nothing() {
    let src = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bytes = tgz(&[("js-debug/a.js", b"x", 0o644)]);
    std::fs::write(src.path().join("js.tgz"), &bytes).unwrap();
    let plan = archive("js.tgz", &"0".repeat(64), "js-debug", Some("js-debug"));
    let e = install::install(&plan, tools.path(), &Source::Dir(src.path().into()), &[])
        .await
        .unwrap_err();
    assert!(
        e.contains(&sha(&bytes)) && e.contains(&"0".repeat(64)),
        "{e}"
    );
    assert_eq!(std::fs::read_dir(tools.path()).unwrap().count(), 0);
}

#[tokio::test]
async fn an_archive_that_climbs_or_links_installs_nothing() {
    let src = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    for (name, bytes) in [
        ("climb.tgz", tgz(&[("js-debug/../../evil", b"x", 0o644)])),
        ("link.tgz", tgz(&[("js-debug/l", b"/etc/passwd", 0o120777)])),
    ] {
        std::fs::write(src.path().join(name), &bytes).unwrap();
        let plan = archive(name, &sha(&bytes), "js-debug", Some("js-debug"));
        let e = install::install(&plan, tools.path(), &Source::Dir(src.path().into()), &[])
            .await
            .unwrap_err();
        assert!(e.contains("unsafe"), "{name}: {e}");
        assert_eq!(
            std::fs::read_dir(tools.path()).unwrap().count(),
            0,
            "{name}"
        );
    }
    assert!(!tools.path().parent().unwrap().join("evil").exists());
}

#[tokio::test]
async fn installing_again_replaces_the_folder_whole() {
    let src = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(tools.path().join("js-debug")).unwrap();
    std::fs::write(tools.path().join("js-debug/old.js"), "old").unwrap();
    let bytes = tgz(&[("js-debug/new.js", b"new", 0o644)]);
    std::fs::write(src.path().join("js.tgz"), &bytes).unwrap();
    let plan = archive("js.tgz", &sha(&bytes), "js-debug", Some("js-debug"));
    install::install(&plan, tools.path(), &Source::Dir(src.path().into()), &[])
        .await
        .unwrap();
    assert!(!tools.path().join("js-debug/old.js").exists());
    assert!(tools.path().join("js-debug/new.js").exists());
}

#[tokio::test]
async fn a_vsix_is_unpacked_whole_with_its_modes() {
    let src = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bytes = zip_of(&[
        ("extension/adapter/codelldb", b"\x7fELF", 0o755),
        ("extension/package.json", b"{}", 0o644),
    ]);
    std::fs::write(src.path().join("c.vsix"), &bytes).unwrap();
    let plan = archive("c.vsix", &sha(&bytes), "codelldb", None);
    install::install(&plan, tools.path(), &Source::Dir(src.path().into()), &[])
        .await
        .unwrap();
    let bin = tools.path().join("codelldb/extension/adapter/codelldb");
    assert_eq!(
        std::fs::metadata(&bin).unwrap().permissions().mode() & 0o777,
        0o755
    );
}

#[test]
fn debugpy_goes_into_the_tools_venv_with_its_hash_required() {
    let tools = Path::new("/t");
    let plan = Plan::Pip {
        requirement: "debugpy==1.8.22".into(),
        hash: "sha256:ab".into(),
    };
    let (venv, pip, requirements) = install::pip_commands(&plan, tools, "python3").unwrap();
    assert_eq!(venv, ["python3", "-m", "venv", "/t/venv"]);
    assert_eq!(
        pip,
        [
            "/t/venv/bin/python3",
            "-m",
            "pip",
            "install",
            "--require-hashes",
            "--no-deps",
            "-r",
            "/t/venv/drgnx-requirements.txt"
        ]
    );
    assert_eq!(requirements, "debugpy==1.8.22 --hash=sha256:ab\n");
}

#[tokio::test]
async fn a_system_package_is_named_not_installed() {
    let tools = tempfile::tempdir().unwrap();
    let e = install::install(
        &Plan::System("dnf install delve".into()),
        tools.path(),
        &Source::Https,
        &[],
    )
    .await
    .unwrap_err();
    assert!(e.contains("dnf install delve"), "{e}");
}
