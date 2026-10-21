//! A failed exec is reported even when the targets cover the low descriptor numbers. Its own test binary with one
//! test: no other test thread opens or closes descriptors while it runs (in the hub such a close during a spawn can
//! still free a number for std's socket; docs/develop/runtime.md, "draugr").

use std::io;
use std::os::fd::{FromRawFd, OwnedFd};
use std::sync::Arc;

use draugr::{PassFd, Spec, env, spawn};

#[tokio::test]
async fn exec_failure_is_reported_when_targets_cover_low_numbers() {
    // std reports a failed exec over a socket it opens in the parent just before the fork, at the lowest free
    // number. With targets 3–63 and holes among them, that socket must not land on a target: the child's dup2
    // would close it, and the failure would look like a start.
    let mut fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    // SAFETY: pipe(2) just returned these two descriptors.
    let (_r, w) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    let w = Arc::new(w);
    let spec = Spec {
        program: "/nonexistent-glp/prog".into(),
        args: vec![],
        env: env::build(&["PATH"], &[], &[]),
        cwd: None,
        stdin_null: true,
        pass_fds: (3..64)
            .map(|target| PassFd {
                fd: Arc::clone(&w),
                target,
            })
            .collect(),
    };
    let err = spawn(spec).await.err().expect("an exec failure");
    assert_eq!(err.kind(), io::ErrorKind::NotFound, "{err}");
}
