//! Exact-value unit tests of the scope, the overlaps and keep mine on hand-made Loro documents (no history, no clock):
//! the cases the seeded property run did not pin down.  Peer 1 is the agent (the scope), peer 2 the user.

use super::*;

const AGENT: u64 = 1;
const USER: u64 = 2;

/// D with PEER's next edit made and committed.
fn edit(d: &LoroDoc, peer: u64, f: impl FnOnce(&LoroText)) {
    d.set_peer_id(peer).unwrap();
    f(&d.get_text(TEXT));
    d.commit();
}

fn span(peer: u64, start: u32, end: u32) -> Span {
    Span {
        peer: PeerId(peer),
        start,
        end,
    }
}

fn ids(list: &[(u64, i32)]) -> HashSet<ID> {
    list.iter().map(|(p, c)| ID::new(*p, *c)).collect()
}

/// The user types "U", merges from a second user's "C" (counter 0 of peer 3), and the agent then makes two
/// changes at counters 3.. : "XY" and, apart from it, "Z".
fn agent_after_others() -> LoroDoc {
    let d = LoroDoc::new();
    edit(&d, AGENT, |t| t.insert(0, "abc").unwrap());
    let u = LoroDoc::new();
    u.import(&d.export(ExportMode::all_updates()).unwrap())
        .unwrap();
    edit(&u, USER, |t| t.insert(0, "U").unwrap());
    d.import(&u.export(ExportMode::all_updates()).unwrap())
        .unwrap();
    d.set_peer_id(AGENT).unwrap();
    let t = d.get_text(TEXT);
    t.insert(0, "XY").unwrap();
    t.insert(6, "Z").unwrap();
    d.commit();
    d
}

use ::loro::ExportMode;

#[test]
fn scope_takes_only_the_ops_inside_its_spans() {
    let d = agent_after_others();
    // the second change holds XY (counters 3, 4) and Z (counter 5): the scope is Z alone
    let sc = scope_of(&d, &[span(AGENT, 5, 6)]);
    assert_eq!(sc.inserted, ids(&[(AGENT, 5)]));
    assert!(sc.deletions.is_empty());
    // Z is the second op of its change (which starts at counter 3, lamport 4): lamport 4 + 2, and the version
    // right before it is the XY op's end, counter 4
    assert_eq!(sc.first, Some((6, AGENT)));
    assert_eq!(sc.before, Frontiers::from(ID::new(AGENT, 4)));
    assert_eq!(sc.after, Frontiers::from(ID::new(AGENT, 5)));
    // XY alone: the first op of its change, so the version before is the change's own deps (the user's "U")
    let sc = scope_of(&d, &[span(AGENT, 3, 5)]);
    assert_eq!(sc.inserted, ids(&[(AGENT, 3), (AGENT, 4)]));
    assert_eq!(sc.first, Some((4, AGENT)));
    assert_eq!(sc.before, Frontiers::from(ID::new(USER, 0)));
}

#[test]
fn an_empty_span_ends_no_scope() {
    let d = agent_after_others();
    // a third peer's operation the scope has nothing to do with
    let c = LoroDoc::new();
    edit(&c, 3, |t| t.insert(0, "C").unwrap());
    d.import(&c.export(ExportMode::all_updates()).unwrap())
        .unwrap();
    let sc = scope_of(&d, &[span(AGENT, 5, 6), span(3, 1, 1)]);
    assert_eq!(sc.after, Frontiers::from(ID::new(AGENT, 5)));
}

#[test]
fn a_backward_delete_run_is_one_deletion_with_its_range() {
    let d = LoroDoc::new();
    edit(&d, USER, |t| t.insert(0, "abcdefgh").unwrap());
    // backspacing "f", "e", "d": Loro keeps one delete op (position 5, length -3)
    edit(&d, AGENT, |t| {
        t.delete(5, 1).unwrap();
        t.delete(4, 1).unwrap();
        t.delete(3, 1).unwrap();
    });
    let sc = scope_of(&d, &[span(AGENT, 0, 3)]);
    assert_eq!(sc.deletions.len(), 1);
    assert_eq!((sc.deletions[0].start, sc.deletions[0].end), (3, 6));
}

#[test]
fn a_forward_delete_is_its_range() {
    let d = LoroDoc::new();
    edit(&d, USER, |t| t.insert(0, "abcdefgh").unwrap());
    edit(&d, AGENT, |t| t.delete(2, 3).unwrap());
    let sc = scope_of(&d, &[span(AGENT, 0, 3)]);
    assert_eq!(sc.deletions.len(), 1);
    assert_eq!((sc.deletions[0].start, sc.deletions[0].end), (2, 5));
}

#[test]
fn interleaved_is_false_when_the_scope_is_all_there_is() {
    let d = LoroDoc::new();
    edit(&d, AGENT, |t| t.insert(0, "abc").unwrap());
    let spans = [span(AGENT, 0, 3)];
    let sc = scope_of(&d, &spans);
    assert!(!interleaved(&d, &sc, &spans));
}

#[test]
fn interleaved_is_true_when_the_user_typed_between_two_records() {
    let d = LoroDoc::new();
    edit(&d, AGENT, |t| t.insert(0, "abc").unwrap());
    edit(&d, USER, |t| t.insert(0, "U").unwrap());
    edit(&d, AGENT, |t| t.insert(4, "def").unwrap());
    let spans = [span(AGENT, 0, 3), span(AGENT, 3, 6)];
    let sc = scope_of(&d, &spans);
    assert!(interleaved(&d, &sc, &spans));
}

#[test]
fn interleaved_is_true_when_the_scope_skips_some_of_its_peers_operations() {
    let d = LoroDoc::new();
    edit(&d, AGENT, |t| t.insert(0, "abc").unwrap());
    edit(&d, AGENT, |t| t.insert(0, "xy").unwrap());
    edit(&d, AGENT, |t| t.insert(5, "def").unwrap());
    // counters 3..5 belong to no span of the scope
    let spans = [span(AGENT, 0, 3), span(AGENT, 5, 8)];
    let sc = scope_of(&d, &spans);
    assert!(interleaved(&d, &sc, &spans));
}

#[test]
fn overlap_from_typing_between_scoped_characters() {
    let d = LoroDoc::new();
    edit(&d, USER, |t| t.insert(0, "Z").unwrap());
    edit(&d, AGENT, |t| t.insert(1, "AB").unwrap());
    edit(&d, USER, |t| t.insert(2, "u").unwrap());
    // ZAuB: the user's "u" (counter 1) sits between A and B
    let sc = scope_of(&d, &[span(AGENT, 0, 2)]);
    let found = overlaps(&d, &sc).unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].users, vec![ID::new(USER, 1)]);
    assert_eq!(found[0].at, 2);
}

#[test]
fn a_deleted_run_of_scoped_characters_is_one_overlap_after_the_last_alive_one() {
    let d = LoroDoc::new();
    edit(&d, USER, |t| t.insert(0, "Z").unwrap());
    edit(&d, AGENT, |t| t.insert(1, "ABC").unwrap());
    edit(&d, USER, |t| t.delete(1, 3).unwrap());
    let sc = scope_of(&d, &[span(AGENT, 0, 3)]);
    let found = overlaps(&d, &sc).unwrap();
    assert_eq!(found.len(), 1, "one hunk for the run");
    assert!(found[0].users.is_empty());
    assert_eq!(found[0].at, 1);
}

#[test]
fn keep_mine_deletes_a_run_of_scoped_characters_as_one_change() {
    let d = LoroDoc::new();
    edit(&d, USER, |t| t.insert(0, "Z").unwrap());
    edit(&d, AGENT, |t| t.insert(1, "ABC").unwrap());
    let sc = scope_of(&d, &[span(AGENT, 0, 3)]);
    let mut log = Vec::new();
    keep_mine(&d, &sc, &[], &[], &mut log).unwrap();
    assert_eq!(d.get_text(TEXT).to_string(), "Z");
    assert_eq!(
        log,
        vec![Change {
            start: 1,
            old_len: 3,
            inserted: String::new()
        }]
    );
}

#[test]
fn keep_mine_puts_back_only_what_the_scope_did_not_insert() {
    let d = LoroDoc::new();
    edit(&d, USER, |t| t.insert(0, "ab").unwrap());
    // the scope inserts X between them, then deletes all three in one range
    edit(&d, AGENT, |t| {
        t.insert(1, "X").unwrap();
        t.delete(0, 3).unwrap();
    });
    let sc = scope_of(&d, &[span(AGENT, 0, 4)]);
    keep_mine(&d, &sc, &[], &[], &mut Vec::new()).unwrap();
    assert_eq!(d.get_text(TEXT).to_string(), "ab");
}

#[test]
fn keep_mine_finds_a_neighbour_the_scope_deleted_and_put_back() {
    let d = LoroDoc::new();
    edit(&d, USER, |t| t.insert(0, "zabc").unwrap());
    // the scope deletes "b", types a "Q" elsewhere, then deletes "a": b's left neighbour is a put-back character
    edit(&d, AGENT, |t| {
        t.delete(2, 1).unwrap();
        t.insert(3, "Q").unwrap();
        t.delete(1, 1).unwrap();
    });
    assert_eq!(d.get_text(TEXT).to_string(), "zcQ");
    let sc = scope_of(&d, &[span(AGENT, 0, 3)]);
    keep_mine(&d, &sc, &[], &[], &mut Vec::new()).unwrap();
    assert_eq!(d.get_text(TEXT).to_string(), "zabc");
}
