//! The comment threads of a document (frontend flow plan, Task 26): the view `doc-comments/RECORD`, a kit card for each
//! thread: the quoted paragraph (with "paragraph removed" when its anchor is gone, the quote kept), the comment, its
//! replies, whom it was steered to ("No agent is writing it" when nobody), and the thread's actions as the text
//! property `drgnx-action`: `reply` (the editor opens a `text-input`) and `resolve`. The threads are
//! [`crate::work::comments::threads`]; an agent's answer or the user's reply makes the editor ask `doc-comments/set`.
//!
//! Row keys: `empty` when there are none, else `thread:N/L` for line L of thread N's card.

use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::{Key, Views, kit_env};
use rodd::faces::FaceId;
use rodd::kit::{self, CardKind, Comp, KitEnv, Size, State as KitState};
use rodd::{Row, RowBuilder};
use runstav::methods::comments::Thread;
use runstav::methods::doc_comments::{Set, Subscribe, ViewId};
use runstav::wire::{Error, ErrorCode};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A view's record and the threads it last read, by (connection, view).
type Shown = HashMap<(u64, String), (String, Vec<Thread>)>;

/// What each view shows: its record and the threads last read.
#[derive(Default)]
pub struct DocComments {
    views: Mutex<Shown>,
}

impl DocComments {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
    }
}

impl Views {
    /// The rows of KEY's comment-threads view for its class; false when the view is none.
    pub(super) fn doc_comments_build(&self, f: &Front, key: &Key) -> bool {
        let Some(threads) = lock(&self.doc_comments.views)
            .get(&(key.0, key.1.clone()))
            .map(|(_, t)| t.clone())
        else {
            return false;
        };
        self.publish_built(f, key, |env, _| (rows(&threads, &kit_env(env)), Vec::new()));
        true
    }

    fn doc_comments_show(
        &self,
        f: &Front,
        conn: u64,
        view: &str,
        record: &str,
        threads: Vec<Thread>,
    ) {
        lock(&self.doc_comments.views).insert(
            (conn, view.to_owned()),
            (record.to_owned(), threads.clone()),
        );
        for key in self.keys_of(view).into_iter().filter(|k| k.0 == conn) {
            self.publish_built(f, &key, |env, _| {
                (rows(&threads, &kit_env(env)), Vec::new())
            });
        }
    }
}

async fn read(f: &Front, record: &str) -> Result<Vec<Thread>, Error> {
    crate::work::comments::threads(&f.writer.db, record)
        .await
        .map_err(|e| Error {
            code: ErrorCode::Internal,
            message: e.to_string(),
            path: None,
        })
}

/// `doc-comments/subscribe`.
pub async fn subscribe(f: &Front, c: &Caller, p: Subscribe) -> Result<bool, Error> {
    let threads = read(f, &p.record).await?;
    f.core
        .views
        .doc_comments_show(f, c.conn_id, &p.view, &p.record, threads);
    Ok(true)
}

/// `doc-comments/set`.
pub async fn set(f: &Front, c: &Caller, p: Set) -> Result<bool, Error> {
    let record = lock(&f.core.views.doc_comments.views)
        .get(&(c.conn_id, p.view.clone()))
        .map(|(r, _)| r.clone());
    let Some(record) = record else {
        return Err(Error {
            code: ErrorCode::InvalidParams,
            message: "not a comment-threads view (doc-comments/subscribe first)".into(),
            path: Some("view".into()),
        });
    };
    if p.refresh {
        let threads = read(f, &record).await?;
        f.core
            .views
            .doc_comments_show(f, c.conn_id, &p.view, &record, threads);
    }
    Ok(true)
}

/// `doc-comments/close`.
pub fn close(f: &Front, c: &Caller, p: ViewId) -> Result<bool, Error> {
    Ok(lock(&f.core.views.doc_comments.views)
        .remove(&(c.conn_id, p.view))
        .is_some())
}

fn button(b: &mut RowBuilder, env: &KitEnv, label: &str, action: serde_json::Value) {
    let from = b.pos();
    kit::expand(
        b,
        env,
        &Comp::Button {
            label: label.to_owned(),
            style: kit::ButtonStyle::Secondary,
            size: Size::Sm,
            state: KitState::Rest,
            key: None,
            action: None,
        },
    );
    let to = b.pos();
    b.prop(from, to, "drgnx-action", action);
}

/// The rows of THREADS: one card each (a waiting thread, which no agent is writing, is the needs-you card).
pub fn rows(threads: &[Thread], env: &KitEnv) -> Vec<Row> {
    let muted = FaceId::TextMuted.name();
    if threads.is_empty() {
        let mut b = RowBuilder::new("empty");
        b.push(
            "No comments on this document yet. C-c w c comments on a paragraph.",
            Some(muted),
        );
        return vec![b.finish()];
    }
    let mut out = Vec::new();
    for (n, t) in threads.iter().enumerate() {
        let mut lines: Vec<Row> = Vec::new();
        let line = |lines: &mut Vec<Row>, build: &dyn Fn(&mut RowBuilder)| {
            let mut b = RowBuilder::new(format!("thread:{n}/{}", lines.len()));
            build(&mut b);
            lines.push(b.finish());
        };
        let removed = t.anchor.state == "removed";
        line(&mut lines, &|b| {
            b.push(&format!("\u{201c}{}\u{201d}", t.anchor.quote), Some(muted));
            if removed {
                b.push(" \u{b7} paragraph removed", Some(muted));
            }
        });
        for c in std::iter::once(&t.root).chain(t.replies.iter()) {
            line(&mut lines, &|b| {
                b.push(
                    &format!("{}: ", if c.author == "user" { "you" } else { &c.author }),
                    Some(muted),
                );
                b.push(&c.text, None);
                let end = b.pos();
                b.prop(0, end, "drgnx-comment", json!(c.id));
            });
        }
        let waiting = t.sent_to.is_none() && !t.resolved;
        if waiting {
            line(&mut lines, &|b| {
                b.push("No agent is writing it", Some(muted));
            });
        }
        if t.resolved {
            line(&mut lines, &|b| {
                b.push("Resolved", Some(muted));
            });
        }
        let id = t.root.id.clone();
        line(&mut lines, &|b| {
            button(b, env, "Reply", json!(["reply", id]));
            b.push(" ", None);
            if !t.resolved {
                button(b, env, "Resolve", json!(["resolve", id]));
            }
        });
        out.extend(kit::card_rows(
            env,
            if waiting {
                CardKind::NeedsYou
            } else {
                CardKind::Plain
            },
            lines,
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodd::kit::Density;
    use runstav::methods::comments::{Anchor, Comment};

    fn env() -> KitEnv<'static> {
        KitEnv {
            scale: 1.0,
            tty: false,
            glyphs: &[],
            ascii: false,
            density: Density::Comfortable,
            icons: None,
        }
    }

    fn comment(id: &str, author: &str, text: &str) -> Comment {
        Comment {
            id: id.into(),
            text: text.into(),
            author: author.into(),
            at: 1.0,
        }
    }

    fn thread(
        id: &str,
        quote: &str,
        state: &str,
        sent_to: Option<&str>,
        replies: Vec<Comment>,
    ) -> Thread {
        Thread {
            root: comment(id, "user", "keep this short"),
            anchor: Anchor {
                heading: vec![],
                key: "0123456789abcdef".into(),
                quote: quote.into(),
                state: state.into(),
            },
            replies,
            sent_to: sent_to.map(Into::into),
            resolved: false,
        }
    }

    #[test]
    fn doc_comments_rows_a_card_per_thread_with_its_replies() {
        let ts = vec![
            thread(
                "c1",
                "The left rail",
                "here",
                Some("s1"),
                vec![comment("c2", "writer", "Done, see 2.")],
            ),
            thread("c3", "Agents on the right", "here", Some("s1"), vec![]),
        ];
        let r = rows(&ts, &env());
        let text: Vec<&str> = r.iter().map(|r| r.text.as_str()).collect();
        let at = |needle: &str| {
            text.iter()
                .position(|t| t.contains(needle))
                .unwrap_or_else(|| panic!("{needle} in {text:?}"))
        };
        assert!(at("The left rail") < at("keep this short"));
        assert!(at("keep this short") < at("Done, see 2."));
        assert!(at("Done, see 2.") < at("Agents on the right"));
        assert!(text.iter().any(|t| t.contains("you: keep this short")));
        assert!(text.iter().any(|t| t.contains("writer: Done, see 2.")));
        // each thread's Reply button carries its action
        let replies: Vec<_> = r
            .iter()
            .flat_map(|r| r.props.iter())
            .filter(|p| p.2 == "drgnx-action" && p.3 == json!(["reply", "c1"]))
            .collect();
        assert_eq!(replies.len(), 1, "{r:?}");
    }

    #[test]
    fn a_removed_anchor_keeps_its_quote_and_says_the_paragraph_is_removed() {
        let ts = vec![thread(
            "c1",
            "A paragraph that is gone",
            "removed",
            Some("s1"),
            vec![],
        )];
        let r = rows(&ts, &env());
        let line = r
            .iter()
            .find(|r| r.text.contains("A paragraph that is gone"))
            .expect("the quote stays");
        assert!(line.text.contains("paragraph removed"), "{}", line.text);
    }

    #[test]
    fn a_thread_nobody_is_writing_says_so_and_is_the_needs_you_card() {
        let ts = vec![thread("c1", "Q", "here", None, vec![])];
        let r = rows(&ts, &env());
        assert!(
            r.iter().any(|r| r.text.contains("No agent is writing it")),
            "{r:?}"
        );
        assert!(
            r.iter()
                .any(|r| r.runs.iter().any(|x| x.2.contains("needs-you"))),
            "{r:?}"
        );
    }

    #[test]
    fn no_threads_is_a_real_empty_state() {
        let r = rows(&[], &env());
        assert_eq!(r.len(), 1);
        assert!(r[0].text.contains("No comments"), "{}", r[0].text);
    }
}
