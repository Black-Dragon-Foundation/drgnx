//! stderr's warnings: a stderr nobody reads holds no hub thread, and the lines its queue could not take are told.

use super::*;
use std::io::Read;
use tracing::instrument::WithSubscriber;
use tracing_subscriber::layer::SubscriberExt;

fn subscriber(to: &ToStderr) -> impl tracing::Subscriber + Send + Sync {
    tracing_subscriber::registry().with(stderr_layer(to.clone()))
}

#[test]
fn a_stderr_nobody_reads_holds_no_worker_and_its_dropped_lines_are_told() {
    let (r, w) = std::io::pipe().unwrap();
    let (to, flush) = to_stderr(w, false, 8);
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .build()
        .unwrap();
    // far more than the pipe (64 KiB) and the queue hold, from the runtime's one worker
    let wide = "x".repeat(200);
    let warn = async move {
        for i in 0..2000 {
            tracing::warn!("line {i} {wide}");
        }
    };
    rt.block_on(rt.spawn(warn.with_subscriber(subscriber(&to))))
        .unwrap();
    // the worker is free for the next task
    rt.block_on(rt.spawn(async {})).unwrap();
    assert!(to.dropped() > 0, "the queue took every line");
    // the reader comes: a later line that finds room tells the count first
    let read = std::thread::spawn(move || {
        let mut r = r;
        let mut text = String::new();
        r.read_to_string(&mut text).unwrap();
        text
    });
    skuld::wait_until("the dropped lines told", 30, || {
        tracing::subscriber::with_default(subscriber(&to), || tracing::warn!("after"));
        (to.told() == to.dropped()).then_some(())
    });
    let dropped = to.dropped();
    drop((to, rt));
    drop(flush);
    let text = read.join().unwrap();
    assert!(text.contains("line 0 x"), "the first lines written");
    let told: usize = text
        .lines()
        .filter_map(|l| l.strip_prefix("ratatoskr: "))
        .filter_map(|l| l.strip_suffix(" log lines dropped (stderr was full)"))
        .map(|n| n.parse::<usize>().unwrap())
        .sum();
    assert_eq!(told, dropped, "every dropped line told once");
}
