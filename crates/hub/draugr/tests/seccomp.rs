//! `Opts::deny_syscall` (the child runs under an outer seccomp filter that refuses one call with EPERM) and
//! `Opts::inherit_group`.

use draugr::{Opts, Redirect, Spec, env, spawn_std};

fn spec(program: &str) -> Spec {
    Spec {
        program: program.into(),
        args: vec![],
        env: env::build(&["PATH"], &[], &[]),
        cwd: None,
        stdin_null: true,
        pass_fds: vec![],
        new_session: false,
    }
}

fn quiet(deny: Option<libc::c_long>) -> Opts {
    Opts {
        stdout: Redirect::Null,
        stderr: Redirect::Null,
        deny_syscall: deny,
        ..Opts::default()
    }
}

/// `uname` asks the kernel for `uname(2)`: the same program ends 0 without the filter and not 0 with it.
#[cfg(target_os = "linux")]
#[test]
fn a_denied_syscall_fails_in_the_child_and_only_there() {
    let plain = spawn_std(&spec("uname"), &quiet(None))
        .expect("spawn")
        .wait()
        .expect("wait");
    assert!(plain.success(), "uname without a filter: {plain:?}");
    let denied = spawn_std(&spec("uname"), &quiet(Some(libc::SYS_uname)))
        .expect("spawn")
        .wait()
        .expect("wait");
    assert!(!denied.success(), "uname under the filter: {denied:?}");
}

#[cfg(target_os = "linux")]
#[test]
fn a_syscall_number_out_of_range_is_refused_before_the_fork() {
    let err = spawn_std(&spec("uname"), &quiet(Some(-1))).expect_err("a refusal");
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput, "{err}");
}

/// Outside Linux there is no seccomp: a filter is refused before the fork, never silently dropped.
#[cfg(not(target_os = "linux"))]
#[test]
fn a_filter_is_refused_where_there_is_no_seccomp() {
    let err = spawn_std(&spec("uname"), &quiet(Some(1))).expect_err("a refusal");
    assert_eq!(err.kind(), std::io::ErrorKind::Unsupported, "{err}");
}

/// `Opts::inherit_group`: the child is in the parent's group, not a group of its own.
#[test]
fn an_inherited_group_is_the_parents_and_the_default_is_a_group_of_its_own() {
    let group_of = |inherit: bool| {
        let mut child = spawn_std(
            &Spec {
                args: vec!["5".into()],
                ..spec("sleep")
            },
            &Opts {
                inherit_group: inherit,
                ..quiet(None)
            },
        )
        .expect("spawn");
        let pid = child.id() as libc::pid_t;
        // SAFETY: getpgid(2) reads the group of a child that is still running.
        let group = unsafe { libc::getpgid(pid) };
        draugr_test_end(&mut child);
        (pid, group)
    };
    // SAFETY: getpgrp(2) has no preconditions.
    let mine = unsafe { libc::getpgrp() };
    let (pid, group) = group_of(true);
    assert_eq!(group, mine, "inherited: the parent's group");
    assert_ne!(pid, group);
    let (pid, group) = group_of(false);
    assert_eq!(
        group, pid,
        "by default: a group of its own, led by the child"
    );
}

fn draugr_test_end(child: &mut std::process::Child) {
    child.kill().expect("kill");
    child.wait().expect("wait");
}
