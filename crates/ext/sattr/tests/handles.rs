//! The handle table every extension instance holds for its resources (generated into every host's `rt`): generational
//! handles, a cap, a kind per handle, and a drain. The hosts' behaviour on top of it is in resources.rs.

use sattr::Limits;
use sattr::generated::rt::{HandleError, HandleTable, RHandle};

#[test]
fn a_handle_gets_its_rep_back_and_is_gone_after_remove() {
    let mut t = HandleTable::new(8);
    let h = t.insert(0, 41).expect("room");
    assert_eq!(t.live(), 1);
    assert_eq!(t.get(h, 0), Ok(41));
    assert_eq!(t.remove(h, 0), Ok(41));
    assert_eq!(t.live(), 0);
    assert_eq!(t.get(h, 0), Err(HandleError::Stale));
    assert_eq!(
        t.remove(h, 0),
        Err(HandleError::Stale),
        "a second drop is refused"
    );
}

#[test]
fn a_reused_slot_does_not_revive_the_old_handle() {
    let mut t = HandleTable::new(8);
    let old = t.insert(0, 1).expect("room");
    t.remove(old, 0).expect("live");
    let new = t.insert(0, 2).expect("room");
    assert_eq!(new.index(), old.index(), "the freed slot is reused");
    assert_ne!(new.generation(), old.generation());
    assert_eq!(
        t.get(old, 0),
        Err(HandleError::Stale),
        "the old one never reaches the new rep"
    );
    assert_eq!(t.get(new, 0), Ok(2));
}

#[test]
fn the_default_cap_is_4096_and_the_next_handle_is_refused_with_the_number() {
    assert_eq!(Limits::DEFAULT.handles, 4096);
    let mut t = HandleTable::new(Limits::DEFAULT.handles);
    let mut first = None;
    for i in 0..4096 {
        let h = t.insert(0, i).expect("within the cap");
        first.get_or_insert(h);
    }
    assert_eq!(t.live(), 4096);
    let e = t.insert(0, 4096).expect_err("the 4097th");
    assert_eq!(e, HandleError::Full(4096));
    assert!(e.to_string().contains("4096 handles"), "{e}");
    assert_eq!(t.has_room(), Err(HandleError::Full(4096)));
    assert_eq!(t.live(), 4096, "a refused insert holds nothing");
    // a drop makes room again
    t.remove(first.expect("one"), 0).expect("live");
    assert_eq!(t.has_room(), Ok(()));
    t.insert(0, 1).expect("room again");
}

#[test]
fn a_handle_of_another_kind_is_refused_and_stays_valid() {
    let mut t = HandleTable::new(8);
    let h = t.insert(1, 7).expect("room");
    assert_eq!(t.get(h, 0), Err(HandleError::WrongKind));
    assert_eq!(t.remove(h, 0), Err(HandleError::WrongKind));
    assert_eq!(t.get(h, 1), Ok(7), "the refusal did not drop it");
}

#[test]
fn a_handle_never_issued_or_from_another_table_is_refused() {
    let mut mine = HandleTable::new(8);
    let mut other = HandleTable::new(8);
    for r in 0..3 {
        other.insert(0, r).expect("room");
    }
    let theirs = other.insert(0, 99).expect("room");
    // the same slot number is not live in this table: the handle is refused, not read as something else
    assert_eq!(mine.get(theirs, 0), Err(HandleError::Stale));
    assert_eq!(mine.remove(theirs, 0), Err(HandleError::Stale));
    mine.insert(0, 5).expect("room");
    assert_eq!(
        mine.get(RHandle(0), 0),
        Err(HandleError::Stale),
        "handle 0 is never issued"
    );
    assert_eq!(mine.get(RHandle(u64::MAX), 0), Err(HandleError::Stale));
    assert_eq!(
        mine.get(RHandle(1 << 32 | 1_000_000), 0),
        Err(HandleError::Stale)
    );
    // a handle with the right slot and a generation from the future
    let h = mine.insert(0, 6).expect("room");
    let future = RHandle(h.0 + (1 << 32));
    assert_eq!(mine.get(future, 0), Err(HandleError::Stale));
}

#[test]
fn a_generation_that_would_wrap_retires_the_slot_instead() {
    let mut t = HandleTable::new(8);
    // a table whose slots start one before the last generation
    let mut t2 = HandleTable::new_at(8, u32::MAX - 1);
    let a = t2.insert(0, 1).expect("room");
    assert_eq!(a.generation(), u32::MAX - 1);
    t2.remove(a, 0).expect("live");
    let b = t2.insert(0, 2).expect("room");
    assert_eq!(
        (b.index(), b.generation()),
        (a.index(), u32::MAX),
        "the last generation is used once"
    );
    t2.remove(b, 0).expect("live");
    // the slot is spent: it is never handed out again, so no old handle can match a new one
    let c = t2.insert(0, 3).expect("room");
    assert_ne!(c.index(), a.index());
    assert_eq!(t2.get(a, 0), Err(HandleError::Stale));
    assert_eq!(t2.get(b, 0), Err(HandleError::Stale));
    assert_eq!(t2.get(c, 0), Ok(3));
    // the cap counts live handles, not spent slots
    for r in 0..7 {
        t2.insert(0, r)
            .expect("room: the spent slot does not count");
    }
    assert_eq!(t2.live(), 8);
    assert_eq!(t2.has_room(), Err(HandleError::Full(8)));
    // and an ordinary table keeps its first generation non-zero
    let h = t.insert(0, 1).expect("room");
    assert_ne!(h.generation(), 0);
    assert_ne!(h, RHandle(0));
}

#[test]
fn drain_hands_back_every_live_handle_once_and_leaves_them_stale() {
    let mut t = HandleTable::new(8);
    let a = t.insert(0, 10).expect("room");
    let b = t.insert(1, 20).expect("room");
    let c = t.insert(0, 30).expect("room");
    t.remove(b, 1).expect("live");
    let mut got = t.drain();
    got.sort_unstable();
    assert_eq!(got, [(0, 10), (0, 30)]);
    assert_eq!(t.live(), 0);
    assert!(t.drain().is_empty(), "a second drain has nothing");
    assert_eq!(t.get(a, 0), Err(HandleError::Stale));
    assert_eq!(t.get(c, 0), Err(HandleError::Stale));
    // the table still works after a drain, and the drained handles stay dead
    let d = t.insert(0, 40).expect("room");
    assert_eq!(t.get(d, 0), Ok(40));
    assert_eq!(t.get(a, 0), Err(HandleError::Stale));
}

#[test]
fn a_wasm_rep_is_its_slot_index_and_finds_the_live_handle() {
    let mut t = HandleTable::new(8);
    let a = t.insert(0, 10).expect("room");
    let b = t.insert(0, 20).expect("room");
    assert_eq!(t.at_index(b.index()), Some(b));
    t.remove(a, 0).expect("live");
    assert_eq!(t.at_index(a.index()), None, "a freed slot has no handle");
    assert_eq!(t.at_index(1_000_000), None);
}

#[test]
fn drops_deferred_while_the_api_was_busy_come_back_once() {
    let mut t = HandleTable::new(8);
    t.defer(0, 5);
    t.defer(1, 6);
    assert_eq!(t.take_deferred(), [(0, 5), (1, 6)]);
    assert!(t.take_deferred().is_empty());
}
