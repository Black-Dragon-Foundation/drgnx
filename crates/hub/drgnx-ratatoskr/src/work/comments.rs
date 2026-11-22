//! Paragraph comments (docs/develop/hub.md, "Paragraph comments"; docs/develop/records.md, "Comment anchors"): a thread
//! on one paragraph of a spec, plan, decision or task, steered to the agent writing the record and answered there.
//!
//! - A thread is a `comment` record with a `comments_on` link to the record; the link's data is its [`Anchor`]: the
//!   headings above the paragraph, a key (a digest of its text, whitespace folded), a quote and a state.  Replies are
//!   `comment` records with a `replies_to` link to the thread's first comment.
//! - Each time the record's file syncs ([`reanchor`]) every thread finds its paragraph again: by key (as it was),
//!   else the most similar paragraph by words (`moved`: the rewrite that replaced it), else none (`removed`, the quote
//!   kept).  A thread is never dropped.
//! - The writer ([`writer`]) is the live session whose write is the newest in the record's file; failing that, the
//!   session working on a task of the plan the record is.  The comment reaches it ([`steer_text`]) as a prompt when it
//!   is free, else as a steer ahead of its queued prompts: never cancelling its turn.  With no writer the thread waits; [`deliver_waiting`] tries again as sessions come.
//! - Only the session a thread was steered to answers in it (`comment_reply`, [`agent_reply`]).
//!
//! The pure parts ([`paragraphs`], [`realign`], [`writer`], [`steer_text`]) take no clock and do no I/O.

use crate::agents::session::{internal, invalid};
use crate::dispatch::Caller;
use crate::front::Front;
use norn::store::{CoordDb, CoordError};
use norn::write::work::{self as w, CommentNew};
use runstav::methods::comments::{
    AddParams, Added, Anchor, Comment, ListParams, ReplyParams, ResolveParams, Thread, Threads,
};
use runstav::wire::Error;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use urdr::graph::schema::SENTINEL;
use urdr::graph::{Class, TxMeta};

/// The longest quote an anchor keeps, in characters.
pub const QUOTE_MAX: usize = 200;

/// How similar (`similar`'s word ratio) a paragraph must be to a thread's quote to be the rewrite that replaced it.
const SAME_PARAGRAPH: f32 = 0.4;

/// How often, at most, waiting threads look for a writer again (seconds).
const RETRY_SECS: u64 = 5;

/// One paragraph of a document: the headings above it, its key and its text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Para {
    pub heading: Vec<String>,
    pub key: String,
    pub text: String,
}

/// TEXT with its whitespace folded to single spaces.
fn fold(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A paragraph's key: 16 hex digits of the SHA-256 of its folded text.
pub fn key_of(text: &str) -> String {
    let d = Sha256::digest(fold(text).as_bytes());
    d.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// A paragraph's quote: its folded text, cut at [`QUOTE_MAX`] characters.
pub fn quote_of(text: &str) -> String {
    fold(text).chars().take(QUOTE_MAX).collect()
}

/// The paragraphs of a Markdown TEXT: runs of non-blank lines, a fenced block as one, under the headings above them
/// (a heading is a line, not a paragraph).
pub fn paragraphs(text: &str) -> Vec<Para> {
    let mut out = Vec::new();
    let mut heading: Vec<(usize, String)> = Vec::new();
    let mut cur: Vec<&str> = Vec::new();
    let mut fence: Option<&str> = None;
    let flush = |cur: &mut Vec<&str>, heading: &[(usize, String)], out: &mut Vec<Para>| {
        if !cur.is_empty() {
            let text = cur.join("\n");
            out.push(Para {
                heading: heading.iter().map(|(_, h)| h.clone()).collect(),
                key: key_of(&text),
                text,
            });
            cur.clear();
        }
    };
    for line in text.lines() {
        let t = line.trim_start();
        if let Some(f) = fence {
            cur.push(line);
            if t.starts_with(f) {
                fence = None;
                flush(&mut cur, &heading, &mut out);
            }
            continue;
        }
        if t.starts_with("```") || t.starts_with("~~~") {
            flush(&mut cur, &heading, &mut out);
            fence = Some(&t[..3]);
            cur.push(line);
            continue;
        }
        let level = t.chars().take_while(|c| *c == '#').count();
        if (1..=6).contains(&level) && t[level..].starts_with(' ') {
            flush(&mut cur, &heading, &mut out);
            heading.retain(|(l, _)| *l < level);
            heading.push((level, t[level..].trim().to_owned()));
            continue;
        }
        if t.is_empty() {
            flush(&mut cur, &heading, &mut out);
        } else {
            cur.push(line);
        }
    }
    flush(&mut cur, &heading, &mut out);
    out
}

/// The anchor of paragraph P, in STATE.
fn anchor_at(p: &Para, state: &str) -> Anchor {
    Anchor {
        heading: p.heading.clone(),
        key: p.key.clone(),
        quote: quote_of(&p.text),
        state: state.into(),
    }
}

/// The paragraph of PARAS a new comment's anchor A names: by key, else the one whose text holds A's quote.
pub fn find<'a>(paras: &'a [Para], a: &Anchor) -> Option<&'a Para> {
    if !a.key.is_empty() {
        return paras.iter().find(|p| p.key == a.key);
    }
    let q = fold(&a.quote);
    if q.is_empty() {
        return None;
    }
    paras.iter().find(|p| fold(&p.text).contains(&q))
}

/// Where thread anchor A sits in PARAS now: its paragraph by key, as it was (a `removed` one that is back is `here`);
/// else the most similar paragraph by words, at least [`SAME_PARAGRAPH`], `moved` (under the same headings first on
/// a tie); else `removed`, with its quote, key and headings kept.
pub fn realign(a: &Anchor, paras: &[Para]) -> Anchor {
    if let Some(p) = paras.iter().find(|p| p.key == a.key) {
        let state = if a.state == "removed" {
            "here"
        } else {
            a.state.as_str()
        };
        return anchor_at(p, state);
    }
    // words only: `similar`'s word diff counts the spaces between them as tokens too, which makes any two sentences
    // look alike
    let q: Vec<&str> = a.quote.split_whitespace().collect();
    let best = paras
        .iter()
        .map(|p| {
            let quote = quote_of(&p.text);
            let words: Vec<&str> = quote.split_whitespace().collect();
            let r = similar::TextDiff::from_slices(&q, &words).ratio();
            (r, p.heading == a.heading, p)
        })
        .filter(|(r, _, _)| *r >= SAME_PARAGRAPH)
        .max_by(|x, y| x.0.total_cmp(&y.0).then(x.1.cmp(&y.1)));
    match best {
        Some((_, _, p)) => anchor_at(p, "moved"),
        None => Anchor {
            state: "removed".into(),
            ..a.clone()
        },
    }
}

/// The record's writer: of EDITS (a record's id in the history, and the live session that made it, for each live
/// session's newest write in the record's file), the newest; else the first of PLANNED (the live sessions working on
/// a task of the plan the record is, newest first).
pub fn writer(edits: &[(i64, String)], planned: &[String]) -> Option<String> {
    edits
        .iter()
        .max_by_key(|(op, _)| *op)
        .map(|(_, s)| s.clone())
        .or_else(|| planned.first().cloned())
}

/// The steer a comment reaches its writer as: where it sits, the comment, and how to answer.
pub fn steer_text(record_title: &str, a: &Anchor, text: &str, id: &str) -> String {
    let heading = a
        .heading
        .last()
        .map_or(record_title, String::as_str)
        .to_owned();
    let mut quote: String = a.quote.chars().take(60).collect();
    if a.quote.chars().count() > 60 {
        quote.push('…');
    }
    format!("Comment on \"{heading}\" ¶ \"{quote}\": {text} (reply with comment_reply, id {id})")
}

// ------------------------------------------------------------------------------------------------------------ store

fn hub_meta(what: &str) -> TxMeta {
    TxMeta::new("hub", Class::System, what)
}

/// A record's title, its file (a records file) and body.
#[derive(Clone, Debug)]
struct Record {
    title: String,
    file: Option<PathBuf>,
    body: String,
}

async fn fetch_record(db: &CoordDb, id: &str) -> Result<Option<Record>, CoordError> {
    let id = id.to_owned();
    db.read(move |c| {
        Ok(urdr::graph::entity::by_id(c, &id)?
            .filter(|e| e.retired_tx.is_none())
            .map(|e| Record {
                title: e.title.clone().unwrap_or_default(),
                file: e.data["records"]["file"].as_str().map(PathBuf::from),
                body: e.body.clone().unwrap_or_default(),
            }))
    })
    .await
}

/// The text a record's paragraphs are read from: its file (the view header left out), else its body.
fn text_of(r: &Record) -> String {
    r.file
        .as_ref()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .map(|t| saga::view::strip_header(&t).to_owned())
        .unwrap_or_else(|| r.body.clone())
}

/// A thread's first comment: COMMENT itself, or the one it replies to.
async fn root_of(db: &CoordDb, comment: &str) -> Result<Option<String>, CoordError> {
    let id = comment.to_owned();
    db.read(move |c| {
        let mut st = c.prepare(
            "select coalesce((select r.id from link l join entity r on r.n = l.dst \
               where l.src = e.n and l.kind = 'replies_to' and l.tx_to = ?2), e.id) \
             from entity e where e.id = ?1 and e.kind = 'comment' and e.retired_tx is null",
        )?;
        let mut rows = st.query_map(rusqlite::params![id, SENTINEL], |r| r.get::<_, String>(0))?;
        Ok(rows.next().transpose()?)
    })
    .await
}

/// A thread's root as stored: its record, anchor and data.
#[derive(Clone, Debug)]
struct Root {
    id: String,
    record: String,
    anchor: Anchor,
    data: Value,
}

/// The threads (first comments) of RECORD, or of every record whose file is FILE, or (neither) those still waiting.
async fn roots(
    db: &CoordDb,
    record: Option<String>,
    file: Option<String>,
) -> Result<Vec<Root>, CoordError> {
    db.read(move |c| {
        let mut st = c.prepare(
            "select c.id, r.id, coalesce(l.data, '{}'), c.data from link l \
             join entity c on c.n = l.src join entity r on r.n = l.dst \
             where l.kind = 'comments_on' and l.tx_to = ?1 and c.retired_tx is null \
               and (?2 is null or r.id = ?2) \
               and (?3 is null or json_extract(r.data, '$.records.file') = ?3) \
               and (?2 is not null or ?3 is not null \
                    or (json_extract(c.data, '$.sent_to') is null \
                        and coalesce(json_extract(c.data, '$.resolved'), 0) = 0)) \
             order by c.n",
        )?;
        let rows = st
            .query_map(rusqlite::params![SENTINEL, record, file], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows
            .into_iter()
            .map(|(id, record, anchor, data)| Root {
                id,
                record,
                anchor: serde_json::from_str(&anchor).unwrap_or(Anchor {
                    heading: Vec::new(),
                    key: String::new(),
                    quote: String::new(),
                    state: "removed".into(),
                }),
                data: serde_json::from_str(&data).unwrap_or_default(),
            })
            .collect())
    })
    .await
}

fn comment_of(id: &str, data: &Value) -> Comment {
    Comment {
        id: id.to_owned(),
        text: data["text"].as_str().unwrap_or_default().to_owned(),
        author: data["author"].as_str().unwrap_or("user").to_owned(),
        at: data["at"].as_f64().unwrap_or(0.0),
    }
}

/// RECORD's threads, each with its replies in order.
pub async fn threads(db: &CoordDb, record: &str) -> Result<Vec<Thread>, CoordError> {
    let mut out = Vec::new();
    for r in roots(db, Some(record.to_owned()), None).await? {
        let id = r.id.clone();
        let replies = db
            .read(move |c| {
                let mut st = c.prepare(
                    "select e.id, e.data from link l join entity e on e.n = l.src \
                     join entity root on root.n = l.dst \
                     where l.kind = 'replies_to' and l.tx_to = ?2 and root.id = ?1 and e.retired_tx is null \
                     order by e.n",
                )?;
                let rows = st
                    .query_map(rusqlite::params![id, SENTINEL], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(rows)
            })
            .await?;
        out.push(Thread {
            root: comment_of(&r.id, &r.data),
            anchor: r.anchor,
            replies: replies
                .iter()
                .map(|(id, d)| comment_of(id, &serde_json::from_str(d).unwrap_or_default()))
                .collect(),
            sent_to: r.data["sent_to"].as_str().map(str::to_owned),
            resolved: r.data["resolved"].as_bool().unwrap_or(false),
        });
    }
    Ok(out)
}

/// A new thread on RECORD at the paragraph anchor A names (by key, or by its text as the quote), by the user: its id
/// and full anchor.  Refused when the record or the paragraph is not there.
pub async fn add_thread(
    db: &CoordDb,
    record: &str,
    a: &Anchor,
    text: &str,
    at: f64,
) -> Result<(String, Anchor), String> {
    let r = record_of(db, record).await?;
    let paras = paragraphs(&text_of(&r));
    let p = find(&paras, a).ok_or("no paragraph of the record has that key or text")?;
    let anchor = anchor_at(p, "here");
    let (rec, data) = (record.to_owned(), json!(anchor));
    let c = CommentNew {
        text: text.to_owned(),
        author: "user".into(),
        at,
        project: None,
    };
    let id = db
        .write(hub_meta("comments/add"), move |tx| {
            w::new_comment(tx, c, &rec, data)
        })
        .await
        .map_err(|e| e.to_string())?;
    Ok((id, anchor))
}

async fn record_of(db: &CoordDb, record: &str) -> Result<Record, String> {
    fetch_record(db, record)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no record {record}"))
}

/// Session SID's answer TEXT in COMMENT's thread: refused unless the thread was steered to SID.  The reply's id.
pub async fn agent_reply(
    db: &CoordDb,
    sid: &str,
    comment: &str,
    text: &str,
    at: f64,
) -> Result<String, String> {
    let root = root_of(db, comment)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no comment {comment}"))?;
    let sent: Option<String> = {
        let id = root.clone();
        db.read(move |c| {
            Ok(urdr::graph::entity::by_id(c, &id)?
                .and_then(|e| e.data["sent_to"].as_str().map(str::to_owned)))
        })
        .await
        .map_err(|e| e.to_string())?
    };
    if sent.as_deref() != Some(sid) {
        return Err(format!(
            "{root} was not sent to you: only the agent it was sent to answers it"
        ));
    }
    let c = CommentNew {
        text: text.to_owned(),
        author: sid.to_owned(),
        at,
        project: None,
    };
    db.write(hub_meta("comment_reply"), move |tx| {
        w::new_reply(tx, c, &root)
    })
    .await
    .map_err(|e| e.to_string())
}

/// Every thread on a record whose file is PATH finds its paragraph again in the file as it is now ([`realign`]); the
/// threads whose anchor changed.
pub async fn reanchor(db: &CoordDb, path: &Path) -> Result<usize, CoordError> {
    let file = path.to_string_lossy().into_owned();
    let rs = roots(db, None, Some(file)).await?;
    if rs.is_empty() {
        return Ok(0);
    }
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Ok(0);
    };
    let paras = paragraphs(saga::view::strip_header(&raw));
    let moved: Vec<(String, Anchor)> = rs
        .into_iter()
        .filter_map(|r| {
            let now = realign(&r.anchor, &paras);
            (now != r.anchor).then_some((r.id, now))
        })
        .collect();
    let n = moved.len();
    if n > 0 {
        db.write(hub_meta("comments/reanchor"), move |tx| {
            for (id, a) in &moved {
                w::move_anchor(tx, id, json!(a))?;
            }
            Ok(())
        })
        .await?;
    }
    Ok(n)
}

// ---------------------------------------------------------------------------------------------------------- the hub

/// PATH by its true name (as written when it does not exist).
fn true_path(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// The top of the git checkout FILE is in (the first folder up with a `.git`).
fn checkout_of(file: &Path) -> Option<PathBuf> {
    file.ancestors()
        .skip(1)
        .find(|d| d.join(".git").exists())
        .map(Path::to_path_buf)
}

/// For each live session, its newest write in FILE (a records file): FILE as the same path in its tree (its own
/// worktree of the same repository, or the checkout it shares), the newest history record of its text there that the
/// session made.
fn newest_writes(f: &Front, file: &Path) -> Vec<(i64, String)> {
    let Some(state) = f.dirs.get().map(|d| d.hub.clone()) else {
        return Vec::new();
    };
    let file = true_path(file);
    let rel_in_repo = checkout_of(&file).and_then(|top| {
        file.strip_prefix(&top)
            .ok()
            .map(|r| r.to_string_lossy().into_owned())
    });
    let live: HashSet<String> = f
        .core
        .agents
        .live_sessions()
        .iter()
        .map(|s| s.id.clone())
        .collect();
    let mut out = Vec::new();
    for sid in &live {
        let Some(tree_root) = f.core.agents.worktree(sid).map(|t| true_path(&t)) else {
            continue;
        };
        let rel = match file.strip_prefix(&tree_root) {
            Ok(r) => r.to_string_lossy().into_owned(),
            Err(_) => match &rel_in_repo {
                Some(r) if tree_root.join(r).exists() => r.clone(),
                _ => continue,
            },
        };
        let Ok((hub, tree)) = f.core.history.of_tree(&state, &tree_root) else {
            continue;
        };
        let Ok(Some(text)) = hub.text(&tree, &rel) else {
            continue;
        };
        let len = text.chars().count();
        let Ok(spans) = hub.blame(&tree, &rel, 0..len) else {
            continue;
        };
        if let Some(op) = spans
            .iter()
            .filter(|b| b.session.as_deref() == Some(sid.as_str()))
            .map(|b| b.record)
            .max()
        {
            out.push((op, sid.clone()));
        }
    }
    out
}

/// The live sessions working on a task of the plan whose file is FILE, newest first.
async fn planned(f: &Front, file: &Path) -> Vec<String> {
    let plan = file.to_string_lossy().into_owned();
    let found = f
        .writer
        .db
        .read(move |c| {
            let mut st = c.prepare(
                "select s.id from entity t join job j on j.id = json_extract(t.data, '$.job') \
                 join link l on l.dst = t.n and l.kind = 'works_on' and l.tx_to = ?2 \
                 join entity s on s.n = l.src \
                 where t.kind = 'task' and t.retired_tx is null and j.plan = ?1 \
                 order by l.id desc",
            )?;
            let rows = st
                .query_map(rusqlite::params![plan, SENTINEL], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .unwrap_or_default();
    let live: HashSet<String> = f
        .core
        .agents
        .live_sessions()
        .iter()
        .map(|s| s.id.clone())
        .collect();
    found
        .into_iter()
        .map(|s| s.trim_start_matches("session:").to_owned())
        .filter(|s| live.contains(s))
        .collect()
}

/// TEXT to session S for comment ID: a prompt when it is free (so an idle writer answers now), else a steer ahead of
/// its queued prompts.  Neither cancels a turn.
fn deliver(s: &std::sync::Arc<crate::agents::session::Session>, text: String, id: &str) {
    if s.is_free()
        && s.prompt_keyed(
            text.clone(),
            crate::agents::queue::Origin::User,
            Some(id.to_owned()),
        )
        .is_ok()
    {
        return;
    }
    s.steer_in(text);
}

/// Steer the thread ROOT (on RECORD, at ANCHOR) to its record's writer with TEXT, and note where it went; none when
/// no agent is writing the record.  A steer goes ahead of the session's queued prompts and never cancels its turn.
async fn send(f: &Front, root: &str, record: &str, anchor: &Anchor, text: &str) -> Option<String> {
    let r = record_of(&f.writer.db, record).await.ok()?;
    let file = r.file.clone()?;
    let edits = newest_writes(f, &file);
    let planned = planned(f, &file).await;
    let sid = writer(&edits, &planned)?;
    let s = f.core.agents.find(&sid).ok()?;
    deliver(&s, steer_text(&r.title, anchor, text, root), root);
    let (id, to) = (root.to_owned(), sid.clone());
    let noted = f
        .writer
        .db
        .write(hub_meta("comments/send"), move |tx| {
            w::comment_patch(tx, &id, json!({"sent_to": to}))
        })
        .await;
    if let Err(e) = noted {
        tracing::warn!(comment = root, "steered but not noted: {e}");
    }
    f.writer.signals.wrote();
    Some(sid)
}

/// `comments/add`.
pub async fn add(f: &Front, _: &Caller, p: AddParams) -> Result<Added, Error> {
    if p.text.trim().is_empty() {
        return Err(invalid("text", "a comment says something"));
    }
    let at = crate::clock::wall_secs();
    let (id, anchor) = add_thread(&f.writer.db, &p.record, &p.anchor, &p.text, at)
        .await
        .map_err(|e| {
            let at = if e.starts_with("no record") {
                "record"
            } else {
                "anchor"
            };
            invalid(at, e)
        })?;
    f.writer.signals.wrote();
    let sent_to = send(f, &id, &p.record, &anchor, &p.text).await;
    Ok(Added {
        comment: id,
        sent_to,
        anchor,
    })
}

/// `comments/reply`: the user's reply, steered to the session the thread went to (or, when that one is gone, to the
/// record's writer now).
pub async fn reply(f: &Front, _: &Caller, p: ReplyParams) -> Result<Comment, Error> {
    let db = &f.writer.db;
    let root = root_of(db, &p.comment)
        .await
        .map_err(|e| internal(e.to_string()))?
        .ok_or_else(|| invalid("comment", format!("no comment {}", p.comment)))?;
    let at = crate::clock::wall_secs();
    let c = CommentNew {
        text: p.text.clone(),
        author: "user".into(),
        at,
        project: None,
    };
    let r = root.clone();
    let id = db
        .write(hub_meta("comments/reply"), move |tx| {
            w::new_reply(tx, c, &r)
        })
        .await
        .map_err(|e| invalid("comment", e.to_string()))?;
    f.writer.signals.wrote();
    let thread = root_thread(db, &root).await;
    if let Some(t) = thread {
        let to = t.data["sent_to"].as_str().map(str::to_owned);
        match to.and_then(|s| f.core.agents.find(&s).ok()) {
            Some(s) => {
                let title = record_of(db, &t.record)
                    .await
                    .map(|r| r.title)
                    .unwrap_or_default();
                deliver(&s, steer_text(&title, &t.anchor, &p.text, &root), &id);
            }
            None => {
                let _ = send(f, &root, &t.record, &t.anchor, &p.text).await;
            }
        }
    }
    Ok(Comment {
        id,
        text: p.text,
        author: "user".into(),
        at,
    })
}

/// The stored root ROOT.
async fn root_thread(db: &CoordDb, root: &str) -> Option<Root> {
    let id = root.to_owned();
    let rec: Option<String> = db
        .read(move |c| {
            let mut st = c.prepare(
                "select r.id from link l join entity c on c.n = l.src join entity r on r.n = l.dst \
                 where c.id = ?1 and l.kind = 'comments_on' and l.tx_to = ?2",
            )?;
            let mut rows =
                st.query_map(rusqlite::params![id, SENTINEL], |r| r.get::<_, String>(0))?;
            Ok(rows.next().transpose()?)
        })
        .await
        .ok()?;
    roots(db, Some(rec?), None)
        .await
        .ok()?
        .into_iter()
        .find(|r| r.id == root)
}

/// `comments/list`.
pub async fn list(f: &Front, _: &Caller, p: ListParams) -> Result<Threads, Error> {
    let threads = threads(&f.writer.db, &p.record)
        .await
        .map_err(|e| internal(e.to_string()))?;
    Ok(Threads { threads })
}

/// `comments/resolve`.
pub async fn resolve(f: &Front, _: &Caller, p: ResolveParams) -> Result<bool, Error> {
    let db = &f.writer.db;
    let root = root_of(db, &p.comment)
        .await
        .map_err(|e| internal(e.to_string()))?
        .ok_or_else(|| invalid("comment", format!("no comment {}", p.comment)))?;
    db.write(hub_meta("comments/resolve"), move |tx| {
        w::comment_patch(tx, &root, json!({"resolved": true}))
    })
    .await
    .map_err(|e| internal(e.to_string()))?;
    f.writer.signals.wrote();
    Ok(true)
}

/// `comment_reply` from session SID.
pub async fn reply_from(f: &Front, sid: &str, comment: &str, text: &str) -> Result<String, String> {
    let id = agent_reply(&f.writer.db, sid, comment, text, crate::clock::wall_secs()).await?;
    f.writer.signals.wrote();
    Ok(format!("replied as {id}"))
}

/// The waiting threads (steered to no one, not resolved) each look for their record's writer again, at most every
/// [`RETRY_SECS`].
pub async fn deliver_waiting(f: &Front) {
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = crate::clock::wall_secs() as u64;
    if now.saturating_sub(LAST.load(Ordering::Relaxed)) < RETRY_SECS {
        return;
    }
    LAST.store(now, Ordering::Relaxed);
    let Ok(waiting) = roots(&f.writer.db, None, None).await else {
        return;
    };
    for r in waiting {
        let text = r.data["text"].as_str().unwrap_or_default().to_owned();
        let _ = send(f, &r.id, &r.record, &r.anchor, &text).await;
    }
}

#[cfg(test)]
mod tests;
