//! The slot's locks. A `flock` belongs to an open file description, and a child forked by another thread shares it
//! until it execs; the other tests spawn git all the time, so this test runs alone in its own binary, where no other
//! thread forks while it holds a lock.

#![cfg(feature = "sync")]

mod slot {
    use sleipnir::sync::slot::{Locks, SlotKey, paths};

    // [D] pure: one open file description per lock, in one process with no other thread
    #[test]
    fn an_update_waits_for_its_readers_and_the_target_is_exclusive() {
        let t = tempfile::tempdir().unwrap();
        let key = SlotKey {
            project: "p".into(),
            worktree: "w".into(),
            trust: forseti::JobTrust::Private,
            toolchain: "t".into(),
        };
        let l = Locks::of(&paths(t.path(), &key));
        let r1 = l.read().unwrap();
        let r2 = l.read().unwrap();
        assert!(
            l.try_update().unwrap().is_none(),
            "two readers hold the slot"
        );
        drop(r1);
        assert!(
            l.try_update().unwrap().is_none(),
            "one reader still holds it"
        );
        drop(r2);
        let u = l.try_update().unwrap().expect("no reader left");
        assert!(l.try_update().unwrap().is_none(), "one update at a time");
        drop(u);
        let w = l.target().unwrap();
        assert!(
            l.try_target().unwrap().is_none(),
            "a writer into the target is exclusive"
        );
        drop(w);
        assert!(l.try_target().unwrap().is_some());
    }

    fn slot_at(t: &std::path::Path) -> sleipnir::sync::slot::SlotPaths {
        paths(
            t,
            &SlotKey {
                project: "p".into(),
                worktree: "w".into(),
                trust: forseti::JobTrust::Private,
                toolchain: "t".into(),
            },
        )
    }

    // [D] pure: a job held at its inputs keeps the slot there, whoever asks next: a `serve` of another hub (which
    // never sees the job) asking for other inputs gets `None` and moves nothing; one asking for the same inputs shares
    // it without a move; once the reader is gone the slot moves. Before the hold, only `serve`'s own list of its
    // running jobs kept a slot still, so another hub's checkout moved it under a running job.
    #[test]
    fn a_slot_held_at_its_inputs_is_never_moved_under_its_job() {
        use sleipnir::sync::slot::hold;
        let t = tempfile::tempdir().unwrap();
        let p = slot_at(t.path());
        let moves = std::cell::RefCell::new(vec![]);
        let to = |k: &'static str| {
            let moves = &moves;
            move || {
                moves.borrow_mut().push(k);
                Ok(())
            }
        };
        let job = hold(&p, "k1", to("k1"))
            .unwrap()
            .expect("a free slot moves");
        assert_eq!(*moves.borrow(), ["k1"]);
        assert!(hold(&p, "k2", to("k2")).unwrap().is_none(), "k1 is read");
        let same = hold(&p, "k1", to("k1"))
            .unwrap()
            .expect("same inputs share");
        assert_eq!(*moves.borrow(), ["k1"], "no move under a reader");
        drop(job);
        assert!(
            hold(&p, "k2", to("k2")).unwrap().is_none(),
            "one reader is left"
        );
        drop(same);
        let next = hold(&p, "k2", to("k2")).unwrap().expect("no reader left");
        assert_eq!(*moves.borrow(), ["k1", "k2"]);
        drop(next);
        // a move that fails leaves no record: the next hold moves again
        let failed = hold(&p, "k3", || {
            Err(sleipnir::sync::SyncError::Io(std::io::Error::other("x")))
        });
        assert!(failed.is_err());
        assert!(hold(&p, "k2", to("k2")).unwrap().is_some());
        assert_eq!(*moves.borrow(), ["k1", "k2", "k2"]);
    }

    // [D] pure: job-exec takes its own read lock on the slot its folder names, and refuses to start when the slot
    // moved between its `serve`'s checkout and its start (that `serve` gone); a folder that names none holds nothing
    #[test]
    fn a_job_refuses_a_slot_moved_since_its_checkout() {
        use sleipnir::sync::slot::{Locks, hold, hold_for_job, write_job_hold};
        let t = tempfile::tempdir().unwrap();
        let p = slot_at(t.path());
        let (a, b) = (t.path().join("a.1"), t.path().join("b.1"));
        for d in [&a, &b] {
            std::fs::create_dir_all(d).unwrap();
        }
        assert!(hold_for_job(&a).unwrap().is_none());
        let serve_a = hold(&p, "k1", || Ok(())).unwrap().unwrap();
        write_job_hold(&a, &p, "k1").unwrap();
        let job_a = hold_for_job(&a).unwrap().expect("at k1");
        drop(serve_a);
        assert!(
            Locks::of(&p).try_update().unwrap().is_none(),
            "the job's own lock holds the slot"
        );
        drop(job_a);
        // A's serve went before its job started; B moved the slot meanwhile
        let serve_b = hold(&p, "k2", || Ok(())).unwrap().unwrap();
        write_job_hold(&b, &p, "k2").unwrap();
        let why = hold_for_job(&a).err().expect("moved");
        assert!(why.contains("moved to other inputs"), "{why}");
        assert!(hold_for_job(&b).unwrap().is_some());
        drop(serve_b);
    }
}
