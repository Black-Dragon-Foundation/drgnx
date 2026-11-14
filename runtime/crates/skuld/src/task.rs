//! Waiting beside a spawned call. A panic in a spawned task only ends that task: a test that waits for something the
//! task would have done (a channel whose sender the test holds too, a watch, a card) waits forever. A test waits through
//! [`while_running`] instead, so the task's early end fails it.

use std::fmt::Debug;
use std::future::{Future, poll_fn};
use std::pin::{Pin, pin};
use std::task::Poll;

/// FUT's output, while TASK (a spawned call's `JoinHandle`, or any future the test waits beside) is still running.
/// When TASK ends first, the test fails naming `what` and what the task ended with (its panic, or its value). TASK is
/// left running when FUT ends first, so the test can go on and await it.
pub async fn while_running<T: Debug, R>(
    what: &str,
    task: &mut (impl Future<Output = T> + Unpin),
    fut: impl Future<Output = R>,
) -> R {
    let mut fut = pin!(fut);
    poll_fn(|cx| {
        if let Poll::Ready(r) = fut.as_mut().poll(cx) {
            return Poll::Ready(r);
        }
        if let Poll::Ready(ended) = Pin::new(&mut *task).poll(cx) {
            panic!("skuld::while_running: {what}: the task ended first: {ended:?}");
        }
        Poll::Pending
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::while_running;

    /// The task panics before it sends; the test still holds a sender, so the receiver alone would wait forever.
    #[tokio::test]
    #[should_panic(expected = "skuld::while_running: the reply: the task ended first")]
    async fn a_task_that_panics_first_fails_the_wait() {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<u32>(1);
        let held = tx.clone();
        let mut call = tokio::spawn(async move {
            let list: Vec<u32> = Vec::new();
            tx.send(list[0]).await.unwrap();
        });
        while_running("the reply", &mut call, rx.recv()).await;
        drop(held);
    }

    /// What the test waits for comes first: its value, and the task still runs to its own end.
    #[tokio::test]
    async fn the_wait_ends_with_its_own_value_and_the_task_runs_on() {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<u32>(1);
        let (go, gate) = tokio::sync::oneshot::channel::<()>();
        let mut call = tokio::spawn(async move {
            tx.send(7).await.unwrap();
            gate.await.unwrap();
            8
        });
        assert_eq!(
            while_running("the reply", &mut call, rx.recv()).await,
            Some(7)
        );
        assert!(!call.is_finished());
        go.send(()).unwrap();
        assert_eq!(call.await.unwrap(), 8);
    }
}
