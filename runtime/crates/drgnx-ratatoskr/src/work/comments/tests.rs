use super::*;
use crate::agents::queue::{Origin as QOrigin, Queue};
use crate::agents::session::turn_core::{QueueEdit, TurnCore, TurnEffect, TurnEvent};
use urdr::graph::entity::{self, EntityNew, Origin};

const SPEC: &str = "# Comments\n\n## Anchors\n\nComments are stored as record links and every one reaches the agent as a steer.\n\nA second paragraph about something else entirely, with its own words.\n";

struct Fix {
    _dir: tempfile::TempDir,
    db: CoordDb,
    file: PathBuf,
}

/// A store with `spec:s`, whose records file holds SPEC.
async fn fix() -> Fix {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("s.md");
    std::fs::write(&file, SPEC).unwrap();
    let db = CoordDb::spawn(dir.path().join("work.db"));
    let f = file.to_string_lossy().into_owned();
    db.write(hub_meta("test"), move |tx| {
        entity::create(
            tx,
            EntityNew {
                id: "spec:s".into(),
                kind: "spec".into(),
                project: None,
                title: Some("Comments".into()),
                status: None,
                body: None,
                priority: None,
                assignee: None,
                data: json!({"records": {"file": f, "kind": "spec"}}),
                origin: Origin::Recorded,
                source: None,
            },
        )?;
        Ok(())
    })
    .await
    .unwrap();
    Fix {
        _dir: dir,
        db,
        file,
    }
}

fn by_quote(q: &str) -> Anchor {
    Anchor {
        heading: Vec::new(),
        key: String::new(),
        quote: q.into(),
        state: "here".into(),
    }
}

#[test]
fn paragraphs_carry_their_headings_and_keys() {
    let ps = paragraphs(SPEC);
    assert_eq!(ps.len(), 2);
    assert_eq!(ps[0].heading, ["Comments", "Anchors"]);
    assert_eq!(ps[0].key.len(), 16);
    // whitespace does not change the key
    assert_eq!(key_of("a  b\nc"), key_of("a b c"));
}

/// The newest write in the record's file names the writer; with none, the session on a task of its plan; with
/// neither, no one (the thread waits).  The steer says where the comment sits and how to answer.
#[test]
fn a_comment_steers_the_records_writer() {
    let edits = [(5, "a".to_string()), (9, "b".to_string())];
    assert_eq!(writer(&edits, &["c".into()]), Some("b".into()));
    assert_eq!(writer(&[], &["c".into()]), Some("c".into()));
    assert_eq!(writer(&[], &[]), None);
    let a = anchor_at(&paragraphs(SPEC)[0], "here");
    assert_eq!(
        steer_text("Comments", &a, "shorter, please", "comment:1"),
        "Comment on \"Anchors\" ¶ \"Comments are stored as record links and every one reaches the…\": \
         shorter, please (reply with comment_reply, id comment:1)"
    );
}

#[tokio::test]
async fn a_reply_from_another_session_is_refused() {
    let f = fix().await;
    let (id, _) = add_thread(
        &f.db,
        "spec:s",
        &by_quote("every one reaches the agent"),
        "why links?",
        1.0,
    )
    .await
    .unwrap();
    // not sent anywhere yet: no session may answer
    assert!(agent_reply(&f.db, "s1", &id, "x", 2.0).await.is_err());
    let i = id.clone();
    f.db.write(hub_meta("test"), move |tx| {
        w::comment_patch(tx, &i, json!({"sent_to": "s1"}))
    })
    .await
    .unwrap();
    let refused = agent_reply(&f.db, "s2", &id, "not mine", 2.0).await;
    assert!(refused.unwrap_err().contains("not sent to you"));
    let r = agent_reply(&f.db, "s1", &id, "they version", 3.0)
        .await
        .unwrap();
    // a reply to the reply joins the same thread, and is still s1's alone
    assert!(agent_reply(&f.db, "s2", &r, "x", 4.0).await.is_err());
    let ts = threads(&f.db, "spec:s").await.unwrap();
    assert_eq!(ts.len(), 1);
    assert_eq!(ts[0].sent_to.as_deref(), Some("s1"));
    let replies: Vec<(&str, &str)> = ts[0]
        .replies
        .iter()
        .map(|c| (c.author.as_str(), c.text.as_str()))
        .collect();
    assert_eq!(replies, [("s1", "they version")]);
}

#[tokio::test]
async fn a_comment_survives_its_paragraph_being_rewritten() {
    let f = fix().await;
    let (_, a) = add_thread(
        &f.db,
        "spec:s",
        &by_quote("every one reaches"),
        "tighten",
        1.0,
    )
    .await
    .unwrap();
    assert_eq!(a.state, "here");
    // nothing changed: nothing moves
    assert_eq!(reanchor(&f.db, &f.file).await.unwrap(), 0);
    let rewritten = SPEC.replace(
        "Comments are stored as record links and every one reaches the agent as a steer.",
        "Comments are stored as record links; each one reaches the writing agent as a steer.",
    );
    std::fs::write(&f.file, &rewritten).unwrap();
    assert_eq!(reanchor(&f.db, &f.file).await.unwrap(), 1);
    let t = &threads(&f.db, "spec:s").await.unwrap()[0];
    assert_eq!(t.anchor.state, "moved");
    assert!(
        t.anchor.quote.contains("the writing agent"),
        "{:?}",
        t.anchor
    );
    assert_eq!(t.anchor.heading, ["Comments", "Anchors"]);
    assert_eq!(t.anchor.key, key_of(&paragraphs(&rewritten)[0].text));
    // found by its new key from now on
    assert_eq!(reanchor(&f.db, &f.file).await.unwrap(), 0);
}

#[tokio::test]
async fn a_comment_survives_its_paragraph_being_deleted() {
    let f = fix().await;
    let (_, a) = add_thread(
        &f.db,
        "spec:s",
        &by_quote("every one reaches"),
        "drop this?",
        1.0,
    )
    .await
    .unwrap();
    let deleted = SPEC.replace(
        "Comments are stored as record links and every one reaches the agent as a steer.\n\n",
        "",
    );
    std::fs::write(&f.file, deleted).unwrap();
    assert_eq!(reanchor(&f.db, &f.file).await.unwrap(), 1);
    let ts = threads(&f.db, "spec:s").await.unwrap();
    assert_eq!(ts.len(), 1, "never dropped");
    assert_eq!(ts[0].anchor.state, "removed");
    assert_eq!((&ts[0].anchor.quote, &ts[0].anchor.key), (&a.quote, &a.key));
    assert_eq!(ts[0].root.text, "drop this?");
    // the paragraph comes back: the thread is here again
    std::fs::write(&f.file, SPEC).unwrap();
    reanchor(&f.db, &f.file).await.unwrap();
    assert_eq!(
        threads(&f.db, "spec:s").await.unwrap()[0].anchor.state,
        "here"
    );
}

#[tokio::test]
async fn a_comment_on_no_paragraph_is_refused() {
    let f = fix().await;
    assert!(
        add_thread(&f.db, "spec:s", &by_quote("not in the text"), "x", 1.0)
            .await
            .is_err()
    );
    assert!(
        add_thread(&f.db, "spec:none", &by_quote("every"), "x", 1.0)
            .await
            .is_err()
    );
}

/// A comment's steer, given while a turn runs, queues ahead of the user's prompts: the turn is neither cancelled nor
/// ended, and the steer is the next turn's prompt.
#[test]
fn comments_never_cancel_a_turn() {
    let mut q = Queue::default();
    q.push("write the spec".into(), QOrigin::User, false);
    q.push("then the plan".into(), QOrigin::User, false);
    let mut c = TurnCore::new();
    c.resume(q, false, None);
    c.ready(false);
    let turn = c
        .next()
        .into_iter()
        .find_map(|e| match e {
            TurnEffect::StartTurn { turn, .. } => Some(turn),
            _ => None,
        })
        .unwrap();
    c.step(TurnEvent::Sending { turn });
    c.step(TurnEvent::Written { turn });
    let (status, before) = (c.status(), c.turn());
    let a = anchor_at(&paragraphs(SPEC)[0], "here");
    let steer = steer_text("Comments", &a, "tighten", "comment:1");
    let fx = c.step(TurnEvent::QueueEdited(QueueEdit::SteerIn(steer.clone())));
    assert!(
        !fx.iter()
            .any(|e| matches!(e, TurnEffect::CancelTurn | TurnEffect::EndTurn { .. })),
        "{fx:?}"
    );
    assert_eq!((c.status(), c.turn()), (status, before));
    assert_eq!(
        c.queue().items().next().map(|i| i.text.as_str()),
        Some(steer.as_str())
    );
}
