//! The user's global excludes reach the overlay through the real lookup: `capture()` finds `~/.gitconfig` by `HOME`,
//! although git itself runs with no global config. The test sets `HOME`, so it runs alone in its own binary.

#![cfg(feature = "sync")]

mod capture {
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    use sleipnir::sync::capture::capture;

    fn user_git(dir: &Path, args: &[&str]) {
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
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    // [D] pure (a temp HOME and repo, real git)
    #[test]
    fn a_globally_ignored_file_never_enters_the_overlay() {
        let t = tempfile::tempdir().unwrap();
        let t = t.path();
        let repo = t.join("repo");
        fs::create_dir(&repo).unwrap();
        user_git(&repo, &["init", "-q"]);
        fs::write(repo.join("a"), "a\n").unwrap();
        user_git(&repo, &["add", "-A"]);
        user_git(&repo, &["commit", "-qm", "one"]);
        fs::write(repo.join("key.secret"), "hush\n").unwrap();
        fs::write(repo.join("kept"), "kept\n").unwrap();

        let home = t.join("home");
        fs::create_dir(&home).unwrap();
        fs::write(home.join("global-ignore"), "*.secret\n").unwrap();
        fs::write(
            home.join(".gitconfig"),
            "[core]\n\texcludesFile = ~/global-ignore\n",
        )
        .unwrap();
        // SAFETY: this binary's only test, before any thread of ours runs
        unsafe {
            std::env::set_var("HOME", &home);
            std::env::remove_var("GIT_CONFIG_GLOBAL");
            std::env::remove_var("XDG_CONFIG_HOME");
        }

        let i = capture(&repo, &[]).unwrap();
        let paths: Vec<&[u8]> = i.manifest.iter().map(|e| e.path()).collect();
        assert_eq!(
            paths,
            vec![&b"kept"[..]],
            "key.secret is ignored by the user's ~/.gitconfig"
        );
    }
}
