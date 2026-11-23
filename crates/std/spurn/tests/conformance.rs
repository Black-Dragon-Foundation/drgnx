//! The prompts standard's conformance test: a question never blocks, a headless context answers the default at
//! once, a timeout answers the default on the virtual clock (docs/develop/standards/prompts.md).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use spurn::{Answer, AnswerBy, Ask, Choice, Origin, Presenter, Question};
use tokio::sync::oneshot::Sender;

fn question(timeout: Option<Duration>) -> Question {
    Question::new(
        "Save?",
        "The buffer changed.",
        vec![
            Choice::new("save", "Save"),
            Choice::new("discard", "Discard"),
        ],
        "save",
        timeout,
        Origin::Agent("a1".into()),
    )
    .expect("a valid question")
}

/// Keeps every reply it is handed: the test answers, or never does.
#[derive(Default)]
struct Held(Mutex<Vec<Sender<String>>>);

impl Presenter for Held {
    fn present(&self, _q: &Question, reply: Sender<String>) {
        saman::lock(&self.0).push(reply);
    }
}

struct Answers(&'static str);

impl Presenter for Answers {
    fn present(&self, _q: &Question, reply: Sender<String>) {
        let _sent = reply.send(self.0.to_string());
    }
}

#[test]
fn headless_ask_returns_default_without_waiting() {
    let _sb = raun::Sandbox::new();
    let ex = Arc::new(saman::Executor::new(1).expect("a pool"));
    let ask = Ask::headless(Arc::clone(&ex));
    // a long timeout, and the virtual clock never moves: the answer is not waiting for it
    let a = ex
        .block_on(ask.choose(question(Some(Duration::from_secs(3600)))))
        .expect("answers");
    assert_eq!(
        a,
        Answer {
            choice: "save".into(),
            by: AnswerBy::Default
        }
    );
}

#[test]
fn ask_timeout_returns_default() {
    let sb = raun::Sandbox::new();
    let ex = Arc::new(saman::Executor::new(2).expect("a pool"));
    let held = Arc::new(Held::default());
    let ask = Ask::interactive(Arc::clone(&ex), held.clone());
    let a = ex.block_on(async {
        let mut t = ask.choose(question(Some(Duration::from_secs(5))));
        // the clock moves by hand until the question times out: nothing real is waited for
        loop {
            tokio::select! {
                r = &mut t => break r,
                () = tokio::task::yield_now() => sb.advance(Duration::from_secs(1)),
            }
        }
    });
    assert_eq!(
        a.expect("answers"),
        Answer {
            choice: "save".into(),
            by: AnswerBy::Timeout
        }
    );
    assert_eq!(saman::lock(&held.0).len(), 1, "the question was shown once");
}

#[test]
fn the_user_answers_and_a_choice_not_offered_is_not_taken() {
    let _sb = raun::Sandbox::new();
    let ex = Arc::new(saman::Executor::new(1).expect("a pool"));
    let ask = Ask::interactive(Arc::clone(&ex), Arc::new(Answers("discard")));
    let a = ex.block_on(ask.choose(question(None))).expect("answers");
    assert_eq!(
        a,
        Answer {
            choice: "discard".into(),
            by: AnswerBy::User
        }
    );
    let ask = Ask::interactive(Arc::clone(&ex), Arc::new(Answers("format-disk")));
    let a = ex.block_on(ask.choose(question(None))).expect("answers");
    assert_eq!(
        a,
        Answer {
            choice: "save".into(),
            by: AnswerBy::Default
        }
    );
    // a presenter that goes away answers the default too
    struct Gone;
    impl Presenter for Gone {
        fn present(&self, _q: &Question, reply: Sender<String>) {
            drop(reply);
        }
    }
    let ask = Ask::interactive(Arc::clone(&ex), Arc::new(Gone));
    let a = ex.block_on(ask.choose(question(None))).expect("answers");
    assert_eq!(a.by, AnswerBy::Default);
}

#[test]
fn a_default_that_is_not_a_choice_is_refused() {
    let e = Question::new(
        "t",
        "b",
        vec![Choice::new("a", "A")],
        "z",
        None,
        Origin::User,
    )
    .expect_err("no such default");
    assert_eq!(e.kind(), villa::Kind::Invalid);
}

#[test]
fn dropping_the_task_withdraws_the_question() {
    let _sb = raun::Sandbox::new();
    let ex = Arc::new(saman::Executor::new(1).expect("a pool"));
    let held = Arc::new(Held::default());
    let ask = Ask::interactive(Arc::clone(&ex), held.clone());
    let t = ask.choose(question(None));
    drop(t);
    // the task is aborted; nothing awaits the reply, and the process goes on
    assert!(saman::lock(&held.0).len() <= 1);
}
