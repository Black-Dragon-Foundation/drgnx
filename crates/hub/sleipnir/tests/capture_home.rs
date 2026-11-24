//! The user's global excludes reach the overlay through the real lookup: `capture()` finds `~/.gitconfig` by `HOME`,
//! although git itself runs with no global config. The test sets `HOME`, so it runs alone in its own binary.

#![cfg(feature = "sync")]

mod capture {
    use std::fs;
    use std::path::Path;

    use sleipnir::sync::capture::capture;

    fn user_git(dir: &Path, args: &[&str]) {
        let mut spec = sleipnir::tool::spec(
            Path::new("git"),
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@example.invalid",
                "-c",
                "init.defaultBranch=main",
            ],
            &[
                ("GIT_CONFIG_NOSYSTEM", "1"),
                ("GIT_CONFIG_GLOBAL", "/dev/null"),
            ],
        );
        spec.args.extend(args.iter().map(std::ffi::OsString::from));
        spec.cwd = Some(dir.to_path_buf());
        let out = draugr::run(spec, std::time::Duration::from_secs(120)).unwrap();
        assert!(out.status.success(), "{args:?}: {}", out.stderr);
    }

    // [D] pure (a temp HOME and repo, real git)
    #[test]
    fn a_globally_ignored_file_never_enters_the_overlay() {
        let t = tempfile::tempdir().unwrap();
        let t = t.path();
        let repo = t.join("repo");
        fs::create_dir(&repo).unwrap();
        user_git(&repo, &["init", "-q"]);
        sleipnir::fsio::write(repo.join("a"), "a\n").unwrap();
        user_git(&repo, &["add", "-A"]);
        user_git(&repo, &["commit", "-qm", "one"]);
        sleipnir::fsio::write(repo.join("key.secret"), "hush\n").unwrap();
        sleipnir::fsio::write(repo.join("kept"), "kept\n").unwrap();

        let home = t.join("home");
        fs::create_dir(&home).unwrap();
        sleipnir::fsio::write(home.join("global-ignore"), "*.secret\n").unwrap();
        sleipnir::fsio::write(
            home.join(".gitconfig"),
            "[core]\n\texcludesFile = ~/global-ignore\n",
        )
        .unwrap();
        // SAFETY: this binary's only test, before any thread of ours runs
        unsafe {
            std::env::set_var(stig::HOME_VAR, &home);
            std::env::remove_var("GIT_CONFIG_GLOBAL");
            std::env::remove_var(stig::Xdg::Config.var());
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
