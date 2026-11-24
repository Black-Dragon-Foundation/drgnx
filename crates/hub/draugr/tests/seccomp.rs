//! `Opts::deny_syscall`: the child runs under an outer seccomp filter that refuses one call with EPERM.

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

#[test]
fn a_syscall_number_out_of_range_is_refused_before_the_fork() {
    let err = spawn_std(&spec("uname"), &quiet(Some(-1))).expect_err("a refusal");
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput, "{err}");
}
