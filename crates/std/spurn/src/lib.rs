//! spurn (*spurn*, an inquiry, a question): the one ask API (docs/develop/standards/prompts.md).
//!
//! [`Ask::choose`] never blocks: it returns a [`saman::Task`] that resolves to the [`Answer`]. The user answers
//! through a [`Presenter`] (the UI's modal, in B1). A headless or daemon [`Ask`] has none: it answers the question's
//! default at once, and logs that it did, so no prompt ever blocks a daemon. A question may have a timeout; when it
//! runs out (on the `stund` clock, so a test moves it by hand) the default is the answer.

use std::sync::Arc;
use std::time::Duration;

pub use bod::Origin;

/// One of the answers offered.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Choice {
    pub id: String,
    pub label: String,
}

impl Choice {
    pub fn new(id: &str, label: &str) -> Choice {
        Choice {
            id: id.to_string(),
            label: label.to_string(),
        }
    }
}

/// A question: a title, a body, the choices, which one is the default, how long to wait, and who asks.
#[derive(Clone, Debug)]
pub struct Question {
    pub title: String,
    pub body: String,
    pub choices: Vec<Choice>,
    /// The id of the choice taken when nobody answers.
    pub default: String,
    pub timeout: Option<Duration>,
    pub origin: Origin,
}

impl Question {
    /// A question whose default is one of its choices.
    pub fn new(
        title: &str,
        body: &str,
        choices: Vec<Choice>,
        default: &str,
        timeout: Option<Duration>,
        origin: Origin,
    ) -> villa::Result<Question> {
        if !choices.iter().any(|c| c.id == default) {
            return Err(
                villa::Error::invalid("A question's default must be one of its choices.")
                    .with_detail(format!("default `{default}`")),
            );
        }
        Ok(Question {
            title: title.to_string(),
            body: body.to_string(),
            choices,
            default: default.to_string(),
            timeout,
            origin,
        })
    }
}

/// Who gave the answer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AnswerBy {
    User,
    /// A headless context, or the presenter went away.
    Default,
    /// The timeout ran out.
    Timeout,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Answer {
    /// The id of the chosen choice.
    pub choice: String,
    pub by: AnswerBy,
}

/// What shows a question to the user. It must not block: it keeps REPLY and sends the chosen id when the user answers.
pub trait Presenter: Send + Sync + 'static {
    fn present(&self, question: &Question, reply: tokio::sync::oneshot::Sender<String>);
}

/// The ask API.
#[derive(Clone)]
pub struct Ask {
    executor: Arc<saman::Executor>,
    presenter: Option<Arc<dyn Presenter>>,
}

impl Ask {
    /// For a daemon or a headless run: every question is answered with its default at once.
    pub fn headless(executor: Arc<saman::Executor>) -> Ask {
        Ask {
            executor,
            presenter: None,
        }
    }

    pub fn interactive(executor: Arc<saman::Executor>, presenter: Arc<dyn Presenter>) -> Ask {
        Ask {
            executor,
            presenter: Some(presenter),
        }
    }

    /// Ask Q. Dropping the task withdraws the question.
    pub fn choose(&self, q: Question) -> saman::Task<Answer> {
        let presenter = self.presenter.clone();
        self.executor.spawn("ask", async move {
            let default = Answer { choice: q.default.clone(), by: AnswerBy::Default };
            let Some(presenter) = presenter else {
                tracing::info!(title = %q.title, answer = %q.default, "headless: a question answered with its default");
                return default;
            };
            let (tx, rx) = tokio::sync::oneshot::channel();
            presenter.present(&q, tx);
            let reply = match q.timeout {
                Some(d) => match stund::timeout(d, rx).await {
                    Ok(r) => r,
                    Err(_) => {
                        tracing::info!(title = %q.title, answer = %q.default, "a question timed out: its default is the answer");
                        return Answer { choice: q.default, by: AnswerBy::Timeout };
                    }
                },
                None => rx.await,
            };
            match reply {
                Ok(id) if q.choices.iter().any(|c| c.id == id) => Answer { choice: id, by: AnswerBy::User },
                Ok(id) => {
                    tracing::warn!(title = %q.title, answer = %id, "the presenter answered with a choice that was not offered: the default stands");
                    default
                }
                Err(_) => default,
            }
        })
    }
}
