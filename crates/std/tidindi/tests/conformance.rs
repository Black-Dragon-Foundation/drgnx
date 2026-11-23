//! The attention standard's conformance test: one list, the same key updates a notice in place, and the list is
//! rows (docs/develop/standards/attention.md).

use tidindi::{Action, DedupTag, Level, Notice, NoticeId, Notices};

fn notice(level: Level, title: &str, key: Option<&str>) -> Notice {
    Notice {
        level,
        title: title.into(),
        body: "details".into(),
        actions: vec![Action {
            id: "open".into(),
            label: "Open".into(),
        }],
        key: key.map(|k| DedupTag(k.into())),
    }
}

#[test]
fn notice_dedup_updates_in_place() {
    let n = Notices::new();
    let a = n.post(notice(Level::Info, "Indexing", Some("index")));
    let other = n.post(notice(Level::Warning, "Low disk", Some("disk")));
    let again = n.post(notice(Level::Info, "Indexing 80%", Some("index")));
    assert_eq!(again, a, "the same key is the same notice");
    assert_ne!(other, a);
    assert_eq!(n.len(), 2, "no second notice was added");
    assert_eq!(n.get(a).expect("kept").title, "Indexing 80%");
    // without a key, every posting is its own notice
    n.post(notice(Level::Error, "Failed", None));
    n.post(notice(Level::Error, "Failed", None));
    assert_eq!(n.len(), 4);
    // a dismissed notice's key starts a new one
    n.dismiss(a).expect("dismisses");
    assert!(n.get(a).is_none());
    let fresh = n.post(notice(Level::Info, "Indexing", Some("index")));
    assert_ne!(fresh, a);
    assert_eq!(
        n.dismiss(NoticeId(999)).expect_err("gone").kind(),
        villa::Kind::NotFound
    );
}

#[test]
fn the_list_is_rows_with_a_text_projection() {
    let n = Notices::new();
    let a = n.post(notice(Level::Info, "Indexing", Some("index")));
    n.post(notice(Level::Info, "Indexing", Some("index")));
    n.post(notice(Level::Error, "Failed", None));
    let rows = n.rows();
    assert_eq!(rows.len(), 2);
    // newest first, each keyed by its id, the text is what search and a screen reader see
    assert_eq!(rows[0].text, "error: Failed: details");
    assert_eq!(rows[1].key, format!("notice:{}", a.0));
    assert_eq!(rows[1].text, "info: Indexing (\u{d7}2): details");
    // the level is a standard face, so a theme colours it
    assert!(
        rows[0].runs.iter().any(|(_, _, f)| f == "error"),
        "{:?}",
        rows[0].runs
    );
}

#[test]
fn levels_have_names_both_hosts_use() {
    for l in [Level::Info, Level::Warning, Level::Error] {
        assert_eq!(Level::from_name(l.name()), Some(l));
    }
    assert_eq!(Level::from_name("fatal"), None);
}
