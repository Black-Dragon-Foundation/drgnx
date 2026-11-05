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
}
