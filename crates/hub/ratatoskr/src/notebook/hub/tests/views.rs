//! What the hub keeps for the notebook's views.

use super::*;

#[test]
fn a_message_that_answers_no_cell_goes_to_the_kernel_log_and_never_to_a_cell() {
    saman::Executor::new(2).unwrap().block_on(async move {
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
    })
}

/// What the notebook holds of CELL's output as lines of text (what a full-output view shows).
async fn held(w: &World, id: &str, cell: &str) -> Vec<String> {
    let run = w.hub.run_of(7, id, cell).await.unwrap();
    crate::notebook::tail::lines(&run, 50)
        .1
        .into_iter()
        .map(|l| l.text)
        .collect()
}

#[test]
fn the_output_a_running_cell_has_printed_is_what_its_output_view_reads() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let w = world("signal");
        let (id, _seen) = started(&w).await;
        w.hub.watch_output(7, &id, "a", true);
        w.hub
            .execute(7, &id, &[sync("a", "PRINTHOLD")])
            .await
            .unwrap();
        skuld::wait_until("the tail has it", 30, || {
            w.events
                .tail("a")
                .filter(|t| t["head"]["state"] == "running" && t["text"] == "PRINTHOLD")
        });
        skuld::wait_until_async("the notebook has it too", 30, || async {
            (held(&w, &id, "a").await == ["PRINTHOLD"]).then_some(())
        })
        .await;
        w.hub.close(7, &id).await;
    })
}

#[test]
fn a_view_asked_for_after_the_cell_printed_gets_what_it_printed_without_a_new_message() {
    saman::Executor::new(2).unwrap().block_on(async move {
        let w = world("signal");
        let (id, _seen) = started(&w).await;
        w.hub
            .execute(7, &id, &[sync("a", "PRINTHOLD")])
            .await
            .unwrap();
        skuld::wait_until("the tail has it", 30, || {
            w.events
                .tail("a")
                .filter(|t| t["head"]["state"] == "running" && t["text"] == "PRINTHOLD")
        });
        // nothing more is coming from the kernel: the view must still be given what was printed
        w.hub.watch_output(7, &id, "a", true);
        skuld::wait_until_async("the notebook has it", 30, || async {
            (held(&w, &id, "a").await == ["PRINTHOLD"]).then_some(())
        })
        .await;
        // a view that is closed no longer asks for it
        w.hub.watch_output(7, &id, "a", false);
        w.hub.close(7, &id).await;
    })
}
