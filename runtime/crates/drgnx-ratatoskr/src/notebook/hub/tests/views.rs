//! What the hub keeps for the notebook's views.

use super::*;

#[tokio::test(flavor = "multi_thread")]
async fn a_message_that_answers_no_cell_goes_to_the_kernel_log_and_never_to_a_cell() {
    let w = world("signal");
    let (id, _seen) = started(&w).await;
    w.hub.execute(7, &id, &[sync("a", "LOGIT")]).await.unwrap();
    skuld::wait_until("a done", 30, || {
        w.events
            .tail("a")
            .filter(|t| t["head"]["state"] == "idle" && t["text"] == "LOGIT")
    });
    skuld::wait_until("the editor is told", 30, || {
        (!w.events.of("notebook-log").is_empty()).then_some(())
    });
    assert_eq!(w.events.of("notebook-log"), [json!({"id": id, "seq": 1})]);
    let (entries, next, lost) = w.hub.kernel_log(7, &id, 0).unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(
        (entries[0].seq, entries[0].msg_type.as_str()),
        (1, "stream")
    );
    assert_eq!(entries[0].text, "kernel log line\nsecond");
    assert_eq!((next, lost), (1, 0));
    // what is asked after the newest is nothing; another connection has no log at all
    assert!(w.hub.kernel_log(7, &id, 1).unwrap().0.is_empty());
    assert!(w.hub.kernel_log(8, &id, 0).is_err());
    w.hub.close(7, &id).await;
}
