//! The shell's edges, which the core's every-order test takes as given: over a real socket pair.

use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn a_write_is_reported_after_its_push() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    let (_r, w) = ours.into_split();
    let out = Arc::new(Outbox::new(1));
    let writer = tokio::spawn(write_loop(w, out.clone()));
    for l in ["one\n", "two\n", "three\n"] {
        assert!(out.push(l.into()));
    }
    out.finish();
    let w = writer.await.unwrap();
    assert!(w.is_some(), "written whole, the write half handed back");
    drop(w);
    let mut got = String::new();
    let (mut tr, _tw) = theirs.into_split();
    tr.read_to_string(&mut got).await.unwrap();
    assert_eq!(got, "one\ntwo\nthree\n");
    // each line reported written after its push, in the order pushed
    let events = out.events();
    let mut queued = VecDeque::new();
    for ev in &events {
        match *ev {
            ConnEvent::Push { len } => queued.push_back(len),
            ConnEvent::Written { len } => {
                assert_eq!(queued.pop_front(), Some(len), "{events:?}");
            }
            _ => {}
        }
    }
    assert!(queued.is_empty(), "{events:?}");
}

#[tokio::test]
async fn a_refused_write_is_reported_once_and_reading_goes_on() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    drop(theirs);
    let (_r, w) = ours.into_split();
    let out = Arc::new(Outbox::new(1));
    let writer = tokio::spawn(write_loop(w, out.clone()));
    assert!(out.push("one\n".into()));
    assert!(writer.await.unwrap().is_none(), "the client left");
    let events = out.events();
    let ends = events
        .iter()
        .filter(|e| matches!(e, ConnEvent::WriteRefused | ConnEvent::WriteStuck))
        .count();
    assert_eq!(ends, 1, "{events:?}");
    assert!(
        out.reading(),
        "the lines it sent before it left are still read: {events:?}"
    );
    assert!(!out.push("two\n".into()), "nothing more is queued");
}

#[tokio::test]
async fn eof_is_the_last_read_event() {
    let (ours, mut theirs) = UnixStream::pair().unwrap();
    let (mut r, _w) = ours.into_split();
    let out = Outbox::new(1);
    // three lines, the third cut across two writes, then part of a fourth, which the end of file drops
    theirs
        .write_all(b"{\"id\":1}\n{\"id\":2}\n{\"id\"")
        .await
        .unwrap();
    theirs.write_all(b":3}\n{\"half").await.unwrap();
    theirs.shutdown().await.unwrap();
    let mut reader = Reader::new();
    let mut lines = Vec::new();
    while let Some(l) = reader.next(&mut r, &out).await {
        lines.push(l);
    }
    assert_eq!(lines, [r#"{"id":1}"#, r#"{"id":2}"#, r#"{"id":3}"#]);
    let reads: Vec<ConnEvent> = out
        .events()
        .into_iter()
        .filter(|e| {
            matches!(
                e,
                ConnEvent::LineRead | ConnEvent::ClientEof | ConnEvent::ReadError
            )
        })
        .collect();
    assert_eq!(
        reads,
        [
            ConnEvent::LineRead,
            ConnEvent::LineRead,
            ConnEvent::LineRead,
            ConnEvent::ClientEof
        ]
    );
    assert!(!out.reading());
}
