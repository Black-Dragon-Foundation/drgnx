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

/// A relative link that stays inside the archive's tree is made (a JDK's `legal/` files point at each other); one that is
/// absolute, climbs out of the tree, is a hard link or is written through, is not.
#[tokio::test]
async fn a_link_inside_the_archive_is_made_and_one_that_leaves_it_is_not() {
    let src = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let good = tgz(&[
        ("jdk/legal/a/", b"", 0o755),
        ("jdk/legal/a/LICENSE", b"text", 0o644),
        ("jdk/legal/b/", b"", 0o755),
        ("jdk/legal/b/LICENSE", b"../a/LICENSE", 0o120777),
    ]);
    std::fs::write(src.path().join("ok.tgz"), &good).unwrap();
    let plan = archive("ok.tgz", &sha(&good), "jdk", Some("jdk"));
    install::install(&plan, tools.path(), &Source::Dir(src.path().into()), &[])
        .await
        .unwrap();
    let link = tools.path().join("jdk/legal/b/LICENSE");
    assert!(link.is_symlink());
    assert_eq!(std::fs::read(&link).unwrap(), b"text");
    for (name, entries) in [
        ("up.tgz", vec![("jdk/l", &b"../../outside"[..], 0o120777)]),
        ("deep.tgz", vec![("jdk/a/l", &b"../../x"[..], 0o120777)]),
        ("abs.tgz", vec![("jdk/l", &b"/etc/passwd"[..], 0o120777)]),
        (
            "through.tgz",
            vec![
                ("jdk/d", &b"."[..], 0o120777),
                ("jdk/d/d/d/l", &b"../../../../x"[..], 0o120777),
            ],
        ),
        (
            "write.tgz",
            vec![
                ("jdk/d", &b"."[..], 0o120777),
                ("jdk/d/f", &b"x"[..], 0o644),
            ],
        ),
    ] {
        let bytes = tgz(&entries);
        std::fs::write(src.path().join(name), &bytes).unwrap();
        let t2 = tempfile::tempdir().unwrap();
        let plan = archive(name, &sha(&bytes), "jdk", Some("jdk"));
        let e = install::install(&plan, t2.path(), &Source::Dir(src.path().into()), &[])
            .await
            .unwrap_err();
        assert!(e.contains("unsafe"), "{name}: {e}");
        assert_eq!(std::fs::read_dir(t2.path()).unwrap().count(), 0, "{name}");
    }
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

/// Several downloads for one adapter (a JDK, a language server, a plugin jar): every part is downloaded, checked and
/// unpacked before any is put in place, so one wrong digest changes nothing; a `:file` part is one checked file.
#[tokio::test]
async fn an_install_of_parts_is_all_or_none_and_a_file_part_is_one_checked_file() {
    let dir = tempfile::tempdir().unwrap();
    let (src, tools) = (dir.path().join("src"), dir.path().join("tools"));
    std::fs::create_dir_all(&src).unwrap();
    let jdk = tgz(&[("jdk-1/", b"", 0o755), ("jdk-1/bin/java", b"#!java", 0o755)]);
    let jar = b"PK-the-plugin".to_vec();
    std::fs::write(src.join("jdk.tar.gz"), &jdk).unwrap();
    std::fs::write(src.join("plugin.jar"), &jar).unwrap();
    let recipe = |jar_sha: &str| {
        serde_json::json!({"parts": [
            {"url": "https://example.invalid/jdk.tar.gz", "sha256": sha(&jdk), "into": "jdk", "root": "jdk-1"},
            {"url": "https://example.invalid/plugin.jar", "sha256": jar_sha, "into": "jv", "file": "plugin.jar"},
        ]})
    };
    let source = Source::Dir(src.clone());
    // a wrong digest on the second part: nothing at all is installed, no scratch left behind
    let bad = install::plan(&recipe(&"0".repeat(64)), "linux-x64").unwrap();
    let e = install::install(&bad, &tools, &source, &[])
        .await
        .unwrap_err();
    assert!(e.contains("digest") || e.contains("sha256"), "{e}");
    assert!(
        !tools.join("jdk").exists() && !tools.join("jv").exists(),
        "{e}"
    );
    assert!(
        std::fs::read_dir(&tools).map_or(true, |d| d.count() == 0),
        "scratch left in {tools:?}"
    );
    // right digests: the folder and the file, and the file is exactly the download
    let good = install::plan(&recipe(&sha(&jar)), "linux-x64").unwrap();
    assert!(matches!(good, Plan::Parts(ref p) if p.len() == 2));
    install::install(&good, &tools, &source, &[]).await.unwrap();
    assert_eq!(
        std::fs::read(tools.join("jdk/bin/java")).unwrap(),
        b"#!java"
    );
    assert_eq!(std::fs::read(tools.join("jv/plugin.jar")).unwrap(), jar);
    // it can be installed again over itself
    install::install(&good, &tools, &source, &[]).await.unwrap();
    // a part must be a download, and a file name is a name
    assert!(
        install::plan(
            &serde_json::json!({"parts": [{"system": "dnf install x"}]}),
            "linux-x64"
        )
        .is_err()
    );
    assert!(
        install::plan(
            &serde_json::json!({"url": "https://e/x.jar", "sha256": sha(&jar), "into": "jv", "file": "../x.jar"}),
            "linux-x64"
        )
        .is_err()
    );
    // the pins of the recipe as the table reads them
    let t = serde_json::json!({"parts": [{"into": "jdk", "platforms": [
        {"platform": "linux-x64", "url": "https://e/a.tar.gz", "sha256": "a"},
        {"platform": "darwin-arm64", "url": "https://e/b.tar.gz", "sha256": "b"}]}]});
    assert!(install::plan(&t, "linux-arm64").is_err());
}

/// What the doctor says of an adapter's downloads: the pinned version and the installed one, per part.
#[tokio::test]
async fn the_parts_of_an_adapter_say_what_is_pinned_and_what_is_installed() {
    use super::adapters::{self, Adapter, PartStatus};
    let dir = tempfile::tempdir().unwrap();
    let (src, tools) = (dir.path().join("src"), dir.path().join("tools"));
    std::fs::create_dir_all(&src).unwrap();
    let jar = b"jar".to_vec();
    std::fs::write(src.join("p.jar"), &jar).unwrap();
    let recipe = serde_json::json!({"parts": [
        {"url": "https://example.invalid/p.jar", "sha256": sha(&jar), "into": "jv", "file": "p.jar", "version": "0.53.1"},
        {"into": "jdk", "version": "21.0.5", "platforms": []},
    ]});
    let a = Adapter {
        id: "java".into(),
        name: "Java".into(),
        types: vec!["java".into()],
        languages: vec![],
        tested: false,
        find: None,
        start: None,
        defaults: vec![],
        install: Some(recipe.clone()),
        not_built_in: false,
    };
    let status = |tools: &Path| adapters::parts(&a, tools);
    assert_eq!(
        status(&tools),
        [
            PartStatus {
                part: "jv".into(),
                pinned: Some("0.53.1".into()),
                installed: None
            },
            PartStatus {
                part: "jdk".into(),
                pinned: Some("21.0.5".into()),
                installed: None
            },
        ]
    );
    // installing the jar part records its pin; a folder with no record is `unknown`
    let plan = install::plan(
        &serde_json::json!({"parts": [recipe["parts"][0].clone()]}),
        "linux-x64",
    )
    .unwrap();
    install::install(&plan, &tools, &Source::Dir(src), &[])
        .await
        .unwrap();
    std::fs::create_dir_all(tools.join("jdk")).unwrap();
    let s = status(&tools);
    assert_eq!(s[0].installed.as_deref(), Some("0.53.1"));
    assert_eq!(s[1].installed.as_deref(), Some("unknown"));
}
