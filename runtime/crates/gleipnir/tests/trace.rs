//! Gleipnir's open tracer against real children, under the layers the sandbox applies: Landlock, Gleipnir's
//! deny-list, then the listener (docs/develop/sandbox.md, "Seeing the files a shell step opens"). Run in the sandbox
//! container (`ctr.sh --sandbox`): seccomp user notification and Landlock need a real kernel.
//!
//! Pattern C (handshake), every test: the child announces itself with its hand-off hello and parks on the reply; the
//! test polls the socket and the child's pidfd together (`trace_support`), so nothing waits on time.
// Linux only: the tracer is seccomp's (Android: no backend; fails closed).
#![cfg(target_os = "linux")]

mod trace_support;

use trace_support::CHILD_ENV;

/// The child's entry: does nothing unless this binary was run as a child.
#[test]
fn child() {
    if let Ok(json) = std::env::var(CHILD_ENV) {
        trace_support::child_main(&json);
    }
}

mod trace {
    use crate::trace_support::{
        Kid, Sup, WRAPPER, child_command, child_line, marker_value, run, spawn,
    };
    use gleipnir::trace::{self as gt, ListenOptions, Scope};
    use std::process::Command;

    fn text(b: &[u8]) -> String {
        String::from_utf8_lossy(b).into_owned()
    }

    /// `cat a; sed -n 1,5p b > c` reads a and b, and writes c (the redirect), each path resolved against the
    /// command's working directory.
    #[test]
    fn cat_and_sed_reads_and_a_redirect_write() {
        let s = Sup::new();
        let a = s.file("a", "one\n");
        let b = s.file("b", "1\n2\n3\n4\n5\n6\n");
        let cmd = "cat a; sed -n 1,5p b > c";
        let mut child = spawn(s.wrapper(cmd));
        let t = s.trace(&mut child, ListenOptions::default());
        assert_eq!(t.hello.command, cmd);
        assert_eq!(t.hello.scope, Scope::Step);
        let out = run(child);
        assert!(out.status.success(), "{}", text(&out.stderr));
        let seen = t.finish();
        let c = s.root.join("c");
        assert!(seen.reads.contains(&a), "{seen:?}");
        assert!(seen.reads.contains(&b), "{seen:?}");
        assert!(seen.writes.contains(&c), "{seen:?}");
        assert!(
            !seen.writes.contains(&a) && !seen.reads.contains(&c),
            "{seen:?}"
        );
        assert_eq!(std::fs::read_to_string(c).unwrap(), "1\n2\n3\n4\n5\n");
    }

    /// Every call is continued: stdout, stderr and the exit code are the untraced run's.
    #[test]
    fn output_is_unchanged() {
        let s = Sup::new();
        s.file("a", "alpha\n");
        s.file("b", "1\n2\n3\n");
        let cmd = r#"cat a; printf 'x%sy\n' "$(wc -l < b)"; ls; echo to-stderr >&2; exit 3"#;
        let plain = Command::new("bash")
            .args(["-c", cmd])
            .current_dir(&s.root)
            .output()
            .unwrap();
        let mut child = spawn(s.wrapper(cmd));
        let t = s.trace(&mut child, ListenOptions::default());
        let traced = run(child);
        let seen = t.finish();
        assert!(seen.notifications > 0, "it was traced");
        assert_eq!(text(&traced.stdout), text(&plain.stdout));
        assert_eq!(text(&traced.stderr), text(&plain.stderr));
        assert_eq!(traced.status.code(), Some(3));
        assert_eq!(traced.status.code(), plain.status.code());
    }

    /// A call a seccomp deny rule refuses never reaches the listener (`ERRNO` outranks `USER_NOTIF`): an `openat` with
    /// `O_NOATIME`, refused by a deny rule installed with Gleipnir's own, fails EPERM and is not notified; the same
    /// file opened plainly is.
    #[test]
    fn a_denied_call_is_never_notified() {
        let s = Sup::new();
        let f = s.file("f", "data\n");
        let jail = Kid {
            mode: "jail".into(),
            deny: true,
            noatime_denied: true,
            exec: vec![
                WRAPPER.into(),
                child_line(&Kid {
                    mode: "noatime".into(),
                    file: Some(f.clone()),
                    ..Kid::default()
                }),
            ],
            ..Kid::default()
        };
        let mut cmd = child_command(&jail);
        cmd.current_dir(&s.root).env(gt::SOCK_ENV, &s.sock);
        let mut child = spawn(cmd);
        let t = s.trace(&mut child, ListenOptions::default());
        let out = run(child);
        assert_eq!(
            marker_value(&out.stdout, "noatime: errno ").as_deref(),
            Some("1"),
            "{}",
            text(&out.stderr)
        );
        assert_eq!(marker_value(&out.stdout, "plain: ").as_deref(), Some("ok"));
        let seen = t.finish();
        let of_f: Vec<_> = seen
            .opens
            .iter()
            .filter(|o| o.full().as_ref() == Some(&f))
            .collect();
        assert!(!of_f.is_empty(), "the plain open is seen: {seen:?}");
        assert!(
            of_f.iter().all(|o| o.flags & libc::O_NOATIME as u64 == 0),
            "the refused open was notified: {of_f:?}"
        );
    }

    /// Landlock still refuses what lies outside its roots: the continued open is checked by the kernel as before.
    #[test]
    fn landlock_still_refuses() {
        if gleipnir::landlock::kernel_abi() == 0 {
            eprintln!("SKIP landlock_still_refuses: the kernel has no Landlock");
            return;
        }
        let s = Sup::new();
        s.file("in/a", "inside\n");
        s.file("out/x", "outside\n");
        let bin = std::path::Path::new(WRAPPER)
            .parent()
            .unwrap()
            .to_path_buf();
        let mut roots: Vec<std::path::PathBuf> = ["/usr", "/etc", "/lib", "/lib64", "/bin"]
            .iter()
            .map(Into::into)
            .collect();
        roots.extend([bin, s.root.join("in")]);
        let jail = Kid {
            mode: "jail".into(),
            deny: true,
            landlock: Some(roots),
            unix: vec![s.root.clone()],
            exec: vec![WRAPPER.into(), "cat in/a; cat out/x".into()],
            ..Kid::default()
        };
        let mut cmd = child_command(&jail);
        cmd.current_dir(&s.root).env(gt::SOCK_ENV, &s.sock);
        let mut child = spawn(cmd);
        let t = s.trace(&mut child, ListenOptions::default());
        let out = run(child);
        let seen = t.finish();
        assert!(
            text(&out.stdout).ends_with("inside\n"),
            "{}",
            text(&out.stdout)
        );
        assert!(!text(&out.stdout).contains("outside"));
        assert!(
            text(&out.stderr).contains("Permission denied"),
            "{}",
            text(&out.stderr)
        );
        assert!(!out.status.success());
        assert!(seen.reads.contains(&s.root.join("in/a")), "{seen:?}");
    }

    /// io_uring cannot open behind the listener's back: Gleipnir's deny-list still refuses its setup (EPERM).
    #[test]
    fn io_uring_stays_refused() {
        let s = Sup::new();
        let jail = Kid {
            mode: "jail".into(),
            deny: true,
            exec: vec![
                WRAPPER.into(),
                child_line(&Kid {
                    mode: "io_uring".into(),
                    ..Kid::default()
                }),
            ],
            ..Kid::default()
        };
        let mut cmd = child_command(&jail);
        cmd.current_dir(&s.root).env(gt::SOCK_ENV, &s.sock);
        let mut child = spawn(cmd);
        let t = s.trace(&mut child, ListenOptions::default());
        assert_eq!(t.handed, "listener");
        let out = run(child);
        let _ = t.finish();
        assert_eq!(
            marker_value(&out.stdout, "io_uring: errno ").as_deref(),
            Some("1"),
            "{}",
            text(&out.stderr)
        );
    }

    /// The listener's fd and the hand-off socket never reach the traced command: close-on-exec, sent by `SCM_RIGHTS`.
    #[test]
    fn the_fd_never_reaches_the_agent() {
        let s = Sup::new();
        let cmd = r#"for f in /proc/$$/fd/*; do printf '%s %s\n' "$f" "$(readlink "$f")"; done"#;
        let mut child = spawn(s.wrapper(cmd));
        let t = s.trace(&mut child, ListenOptions::default());
        assert_eq!(t.handed, "listener");
        let out = run(child);
        let _ = t.finish();
        let fds = text(&out.stdout);
        assert!(fds.lines().count() >= 3, "{fds}");
        assert!(!fds.contains("seccomp"), "the listener leaked: {fds}");
        assert!(
            !fds.contains("socket:"),
            "the hand-off socket leaked: {fds}"
        );
    }

    /// A command that already runs under a listener (the whole tree is traced) cannot install a second one: the
    /// wrapper reports `busy` to the supervisor and runs the command, which the first listener still sees.
    #[test]
    fn a_second_listener_is_ebusy_and_reported() {
        let s = Sup::new();
        let a = s.file("a", "one\n");
        let jail = Kid {
            mode: "jail".into(),
            outer: Some(s.sock.clone()),
            exec: vec![WRAPPER.into(), "cat a".into()],
            ..Kid::default()
        };
        let mut cmd = child_command(&jail);
        cmd.current_dir(&s.root).env(gt::SOCK_ENV, &s.sock);
        let mut child = spawn(cmd);
        let outer = s.trace(&mut child, ListenOptions::default());
        assert_eq!((outer.hello.scope, outer.handed), (Scope::Tree, "listener"));
        let second = s.trace(&mut child, ListenOptions::default());
        assert_eq!(second.hello.command, "cat a");
        assert_eq!(second.handed, "busy");
        let out = run(child);
        assert!(
            text(&out.stdout).ends_with("one\n"),
            "{}",
            text(&out.stderr)
        );
        let seen = outer.finish();
        assert!(seen.reads.contains(&a), "{seen:?}");
    }

    /// No sync wake-up by default: the plain mode traces. Asked for, a kernel without it (`ENOSYS`, forced by the
    /// test hook) falls back to the plain mode and still traces.
    #[test]
    fn falls_back_without_sync_wakeup() {
        let s = Sup::new();
        let a = s.file("a", "one\n");
        let mut child = spawn(s.wrapper("cat a"));
        let t = s.trace(&mut child, ListenOptions::default());
        assert!(!t.listener.as_ref().unwrap().sync(), "plain by default");
        run(child);
        assert!(t.finish().reads.contains(&a));
        #[cfg(feature = "test-hooks")]
        {
            let mut child = spawn(s.wrapper("cat a"));
            let opts = ListenOptions {
                sync_wakeup: true,
                set_flags_errno: Some(libc::ENOSYS),
                ..ListenOptions::default()
            };
            let t = s.trace(&mut child, opts);
            assert!(!t.listener.as_ref().unwrap().sync(), "ENOSYS falls back");
            run(child);
            assert!(t.finish().reads.contains(&a));
        }
    }

    /// Only the open calls are notified: a million `getppid` + `fstat` calls add no notification to the run's count
    /// (the loader's opens, the same in both runs).
    #[test]
    fn other_syscalls_never_notify() {
        let s = Sup::new();
        let mut counts = Vec::new();
        for n in [0, 1_000_000] {
            let line = child_line(&Kid {
                mode: "spin".into(),
                n,
                ..Kid::default()
            });
            let mut child = spawn(s.wrapper(&line));
            let t = s.trace(&mut child, ListenOptions::default());
            let out = run(child);
            assert_eq!(marker_value(&out.stdout, "spin: ").as_deref(), Some("done"));
            counts.push(t.finish().notifications);
        }
        assert!(counts[0] > 0, "{counts:?}");
        assert_eq!(counts[0], counts[1], "the spin's calls were notified");
    }

    /// `skip`, or no supervisor at all, runs the command untraced and unchanged; a listener is never installed.
    #[test]
    fn a_skip_or_no_supervisor_runs_untraced() {
        let s = Sup::new();
        s.file("a", "one\n");
        let mut child = spawn(s.wrapper("cat a; grep -c '^Seccomp_filters:' /proc/self/status"));
        let offer = s.next(&mut child);
        assert_eq!(
            offer.hello.command,
            "cat a; grep -c '^Seccomp_filters:' /proc/self/status"
        );
        offer.skip().unwrap();
        let out = run(child);
        assert!(out.status.success(), "{}", text(&out.stderr));
        assert!(
            text(&out.stdout).starts_with("one\n"),
            "{}",
            text(&out.stdout)
        );
        let mut none = s.wrapper("cat a");
        none.env(gt::SOCK_ENV, s.root.join("nobody.sock"));
        let out = none.output().unwrap();
        assert_eq!(text(&out.stdout), "one\n");
        assert_eq!(text(&out.stderr), "");
    }
}
