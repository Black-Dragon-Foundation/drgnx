//! H1: every git command sleipnir's sync runs is hardened. A fake `git` first on `PATH` records each command's
//! arguments and `GIT_*` environment, then runs the real git. The test process carries hostile `GIT_*` variables
//! (a config that would start an fsmonitor program, another git dir) that must never reach git.
//!
//! This file holds one test: it sets the process environment, so it runs alone in its own binary.

#![cfg(feature = "sync")]

mod git {
    use std::ffi::OsStr;
    use std::fs;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use sleipnir::sync::capture::{self, Entry};
    use sleipnir::sync::slot::{self, Blobs, Overlay, SlotKey};

    struct DirBlobs(PathBuf);

    impl Blobs for DirBlobs {
        fn path(&self, sha256: &[u8; 32]) -> PathBuf {
            self.0.join(
                sha256
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>(),
            )
        }
    }

    fn real_git(dir: &Path, git: &Path, args: &[&str]) {
        let out = Command::new(git)
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
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn script(at: &Path, body: &str) {
        fs::write(at, body).unwrap();
        fs::set_permissions(at, fs::Permissions::from_mode(0o755)).unwrap();
    }

    // [D] pure (real git behind a recording fake; no clock, no other process waited on)
    #[test]
    fn every_command_is_hardened() {
        let t = tempfile::tempdir().unwrap();
        let t = t.path();
        let path = std::env::var_os("PATH").unwrap();
        let git = std::env::split_paths(&path)
            .map(|d| d.join("git"))
            .find(|g| g.is_file())
            .expect("git on PATH");

        // the user's repository, made with the real git before anything hostile is set
        let repo = t.join("repo");
        fs::create_dir(&repo).unwrap();
        real_git(&repo, &git, &["init", "-q"]);
        fs::write(repo.join("a"), "a\n").unwrap();
        fs::write(repo.join(".gitignore"), "cache/\n").unwrap();
        real_git(&repo, &git, &["add", "-A"]);
        real_git(&repo, &git, &["commit", "-qm", "one"]);
        fs::write(repo.join("a"), "a in the overlay\n").unwrap();
        fs::create_dir(repo.join("cache")).unwrap();
        fs::write(repo.join("cache/x"), "x\n").unwrap();
        let global = t.join("home/.gitconfig");
        fs::create_dir_all(global.parent().unwrap()).unwrap();
        fs::write(&global, "[core]\n\texcludesFile = /dev/null\n").unwrap();

        let bin = t.join("bin");
        fs::create_dir(&bin).unwrap();
        let log = t.join("git.log");
        script(
            &bin.join("git"),
            "#!/bin/sh\n{ echo CALL; for a in \"$@\"; do printf 'ARG %s\\n' \"$a\"; done; \
             env | grep '^GIT_' | sed 's/^/ENV /'; } >> \"$SLEIPNIR_TEST_GIT_LOG\"\n\
             exec \"$SLEIPNIR_TEST_REAL_GIT\" \"$@\"\n",
        );
        let marker = t.join("marker");
        let monitor = t.join("monitor.sh");
        script(
            &monitor,
            &format!("#!/bin/sh\necho ran >> '{}'\n", marker.display()),
        );
        let mut search = vec![bin.clone()];
        search.extend(std::env::split_paths(&path));
        // SAFETY: this binary's only test, before any thread of ours runs
        unsafe {
            std::env::set_var("PATH", std::env::join_paths(search).unwrap());
            std::env::set_var("SLEIPNIR_TEST_GIT_LOG", &log);
            std::env::set_var("SLEIPNIR_TEST_REAL_GIT", &git);
            std::env::set_var("HOME", t.join("home"));
            std::env::set_var("GIT_DIR", t.join("not-ours"));
            std::env::set_var("GIT_WORK_TREE", t.join("not-ours"));
            std::env::set_var("GIT_CONFIG_COUNT", "1");
            std::env::set_var("GIT_CONFIG_KEY_0", "core.fsmonitor");
            std::env::set_var("GIT_CONFIG_VALUE_0", &monitor);
            std::env::set_var(
                "GIT_CONFIG_PARAMETERS",
                format!("'core.fsmonitor'='{}'", monitor.display()),
            );
        }

        let i = capture::capture(&repo, &[PathBuf::from("cache")]).unwrap();
        let blobs = t.join("blobs");
        fs::create_dir(&blobs).unwrap();
        for e in i.manifest.iter().chain(&i.extras) {
            if let Entry::File { path, sha256, .. } = e {
                let b = DirBlobs(blobs.clone()).path(sha256);
                fs::copy(repo.join(OsStr::from_bytes(path)), b).unwrap();
            }
        }
        let key = SlotKey {
            project: "p".into(),
            worktree: "w".into(),
            trust: "private".into(),
            toolchain: "t".into(),
        };
        let p = slot::paths(&t.join("runner"), &key);
        let store = DirBlobs(blobs);
        slot::update(&p, &repo.join(".git"), &i.commit, &Overlay::of(&i, &store)).unwrap();
        slot::update(&p, &repo.join(".git"), &i.commit, &Overlay::of(&i, &store)).unwrap();
        assert_eq!(fs::read(p.slot.join("a")).unwrap(), b"a in the overlay\n");
        assert_eq!(fs::read(p.slot.join("cache/x")).unwrap(), b"x\n");

        let text = fs::read_to_string(&log).unwrap();
        let calls: Vec<&str> = text.split("CALL\n").filter(|c| !c.is_empty()).collect();
        assert!(
            calls.len() >= 10,
            "capture and two updates ran {} git commands",
            calls.len()
        );
        for call in &calls {
            let args: Vec<&str> = call
                .lines()
                .filter_map(|l| l.strip_prefix("ARG "))
                .collect();
            let env: Vec<&str> = call
                .lines()
                .filter_map(|l| l.strip_prefix("ENV "))
                .collect();
            assert_eq!(
                args[..6],
                [
                    "-c",
                    "core.hooksPath=/dev/null",
                    "-c",
                    "core.fsmonitor=false",
                    "-c",
                    "transfer.fsckObjects=true"
                ],
                "{call}"
            );
            assert!(env.contains(&"GIT_CONFIG_NOSYSTEM=1"), "{call}");
            assert!(env.contains(&"GIT_CONFIG_GLOBAL=/dev/null"), "{call}");
            let dir = env
                .iter()
                .find_map(|e| e.strip_prefix("GIT_DIR="))
                .expect("GIT_DIR is always set");
            assert!(!dir.contains("not-ours"), "{call}");
            for name in env.iter().map(|e| e.split('=').next().unwrap()) {
                assert!(
                    [
                        "GIT_DIR",
                        "GIT_CONFIG_NOSYSTEM",
                        "GIT_CONFIG_GLOBAL",
                        "GIT_TERMINAL_PROMPT",
                        "GIT_INDEX_FILE"
                    ]
                    .contains(&name),
                    "{name} reached git: {call}"
                );
            }
            if args
                .iter()
                .any(|a| ["read-tree", "update-index", "diff", "ls-files"].contains(a))
            {
                assert!(args.iter().any(|a| a.starts_with("--work-tree=")), "{call}");
            }
        }
        assert!(!marker.exists(), "an inherited config started a program");
    }
}
