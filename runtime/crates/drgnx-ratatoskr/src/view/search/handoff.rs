//! Ask an Agent (the Search view's spec §4.4): `search/handoff` hands a view's matches to an agent with a brief: the
//! instruction, the query, the matches grouped by file as `path:line:col  in <definition>  <line>`, at most
//! [`BRIEF_LINES`] lines or [`BRIEF_CHARS`] characters (~8k tokens at four characters a token), then a pointer to the
//! drgnx-search tool `search_results`, which serves the rest to that session only ([`Handoffs::page`]). The agent is a
//! new worker in a worktree of its own, or a live session (a paired chat edits in this checkout). Paths the index never
//! reads (dot paths, secret-looking names) stay out of the brief unless the user ticks them in.
//!
//! The loop closes in the view: the agent's edit records (`history/op/hunks` of its session) map back onto the
//! handed-off matches ([`map_back`]): a hunk that took out a match's line, or its old text, near where it was makes the
//! match done; a match whose line is still there near its place is left; one that is neither is unknown, never done.
//! A watcher per hand-off sends `search-handoff-state` after the agent's steps settle, until the session ends or
//! [`TTL`] passes.

use super::run::Snap;
use crate::front::Front;
use runstav::methods::search::{HandoffPhase, HandoffState};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::time::Instant;

/// The brief's match lines at most; the rest are `search_results`'.
pub(super) const BRIEF_LINES: usize = 300;
/// The brief's match lines' characters at most (~8k tokens, chars / 4 as the repo map estimates).
pub(super) const BRIEF_CHARS: usize = 32_000;
/// `search_results` rows a page.
pub(crate) const PAGE_ROWS: usize = 100;
/// `search_results` serves at most this many bytes of rows over a hand-off's life.
pub(crate) const SERVED_MAX: usize = 2 * 1024 * 1024;
/// A hand-off is served and watched this long at most.
pub(crate) const TTL: Duration = Duration::from_secs(24 * 3600);
/// How far from its line a match's line, or the hunk that took it, is looked for.
const NEAR: i64 = 20;
/// The agent's steps settle this long before the state is worked out again.
const SETTLE: Duration = Duration::from_millis(500);

/// One handed-off match: its id, its file (absolute, and relative to the search's folder), line (from 1) and column
/// (from 0), its old text, its whole line, the definition it is in, and its file as the search read it.
#[derive(Clone, Debug)]
pub(super) struct Handed {
    pub id: String,
    pub path: String,
    pub rel: String,
    pub line: u32,
    pub col: u32,
    pub old: String,
    pub text: String,
    pub ctx: Option<String>,
    pub snap: Option<Snap>,
}

/// One hand-off: who asked (connection, view), the session it went to, the folder its agent edits in (its worktree,
/// or the project's), the matches, the brief's rows (all of them: the brief holds the first), when it was made, and
/// how many bytes `search_results` served.
pub(super) struct Handoff {
    pub conn: u64,
    pub view: String,
    pub session: String,
    pub tree: PathBuf,
    pub matches: Vec<Handed>,
    pub rows: Vec<String>,
    pub at: Instant,
    pub served: usize,
    pub edited: bool,
}

/// The hand-offs, by id (`h:N`).
#[derive(Default)]
pub(crate) struct Handoffs {
    map: Mutex<BTreeMap<String, Handoff>>,
    next: AtomicU64,
}

impl Handoffs {
    /// Keep H; its id.
    pub(super) fn add(&self, h: Handoff) -> String {
        let id = format!("h:{}", self.next.fetch_add(1, Ordering::Relaxed) + 1);
        super::lock(&self.map).insert(id.clone(), h);
        id
    }

    /// F of hand-off ID (none: no such hand-off, or past its [`TTL`]).
    pub(super) fn with<R>(&self, id: &str, f: impl FnOnce(&mut Handoff) -> R) -> Option<R> {
        self.with_at(id, crate::clock::now(), f)
    }

    /// [`Handoffs::with`] at NOW.
    fn with_at<R>(&self, id: &str, now: Instant, f: impl FnOnce(&mut Handoff) -> R) -> Option<R> {
        let mut map = super::lock(&self.map);
        let h = map.get_mut(id)?;
        if now.saturating_duration_since(h.at) > TTL {
            map.remove(id);
            return None;
        }
        Some(f(h))
    }

    /// Forget hand-off ID.
    pub(super) fn forget(&self, id: &str) {
        super::lock(&self.map).remove(id);
    }

    /// `search_results`: page PAGE (from 0) of hand-off ID's rows for SESSION, the session it went to only, each page
    /// naming the files changed since the search; refused for another session, past [`TTL`] or past [`SERVED_MAX`].
    pub(crate) fn page(&self, id: &str, session: &str, page: usize) -> Result<String, String> {
        let unknown = || {
            format!(
                "no hand-off {id} for this session (another session's, ended, or older than 24 h)"
            )
        };
        let (rows, changed, total) = self
            .with(id, |h| {
                if h.session != session {
                    return None;
                }
                let rows: Vec<String> = h
                    .rows
                    .iter()
                    .skip(page * PAGE_ROWS)
                    .take(PAGE_ROWS)
                    .cloned()
                    .collect();
                let bytes: usize = rows.iter().map(|r| r.len() + 1).sum();
                if h.served + bytes > SERVED_MAX {
                    return Some(Err(format!(
                        "hand-off {id} has served its 2 MB: ask the user for a narrower search"
                    )));
                }
                h.served += bytes;
                Some(Ok((rows, changed_since(&h.matches), h.rows.len())))
            })
            .flatten()
            .ok_or_else(unknown)??;
        let pages = total.div_ceil(PAGE_ROWS).max(1);
        let mut out = format!("hand-off {id}, page {} of {pages}\n", page + 1);
        if !changed.is_empty() {
            out.push_str(&format!(
                "changed since the search: {}\n",
                changed.join(", ")
            ));
        }
        out.push_str(&rows.join("\n"));
        Ok(out)
    }
}

/// The brief's row of match M: `path:line:col  in <definition>  <line>` (the column from 1, the line trimmed).
pub(super) fn row(m: &Handed) -> String {
    let ctx = m
        .ctx
        .as_deref()
        .map(|c| format!("  in {c}"))
        .unwrap_or_default();
    format!("{}:{}:{}{ctx}  {}", m.rel, m.line, m.col + 1, m.text.trim())
}

/// The brief of hand-off ID: INSTRUCTION, QUERY (what was searched) and REPLACE (the replacement, if any), then ROWS
/// up to [`BRIEF_LINES`] / [`BRIEF_CHARS`] and the pointer to `search_results` for the rest, the files CHANGED since the
/// search, and the rule to edit only these places. With the rows it holds and the rows it leaves to the tool.
pub(super) fn brief(
    id: &str,
    instruction: &str,
    query: &str,
    replace: Option<&str>,
    rows: &[String],
    changed: &[String],
) -> (String, u32, u32) {
    let mut out = format!("{}\n\nThe search: {query}\n", instruction.trim());
    if let Some(r) = replace {
        out.push_str(&format!("The replacement: {r}\n"));
    }
    out.push_str(&format!(
        "\nThe places ({} in all; path:line:col, the definition, the line):\n",
        rows.len()
    ));
    let (mut sent, mut chars) = (0usize, 0usize);
    for r in rows {
        if sent == BRIEF_LINES || chars + r.len() + 1 > BRIEF_CHARS {
            break;
        }
        out.push_str(r);
        out.push('\n');
        sent += 1;
        chars += r.len() + 1;
    }
    let more = rows.len() - sent;
    if more > 0 {
        out.push_str(&format!(
            "{more} more: call the `search_results` tool with handoff id {id} (pages of {PAGE_ROWS}, from page 0)\n"
        ));
    }
    if !changed.is_empty() {
        out.push_str(&format!(
            "\nThese files changed since the search, so lines may have moved: {}\n",
            changed.join(", ")
        ));
    }
    out.push_str(
        "\nEdit only these places unless asked otherwise. When you finish, say which places you skipped and why.\n",
    );
    (out, sent as u32, more as u32)
}

/// The files of MATCHES (relative) whose text is not the one the search read; each once.
pub(super) fn changed_since(matches: &[Handed]) -> Vec<String> {
    let mut seen: BTreeMap<&str, bool> = BTreeMap::new();
    for m in matches {
        seen.entry(m.rel.as_str())
            .or_insert_with(|| changed(Path::new(&m.path), m.snap.as_ref()));
    }
    seen.into_iter()
        .filter(|(_, c)| *c)
        .map(|(p, _)| p.to_owned())
        .collect()
}

/// FILE is not as SNAP has it (gone, another size or digest); a file with no snapshot is taken as unchanged.
fn changed(file: &Path, snap: Option<&Snap>) -> bool {
    let Some(s) = snap else { return false };
    match std::fs::read(file) {
        Err(_) => true,
        Ok(bytes) => match s.xxh3 {
            Some(d) => d != xxhash_rust::xxh3::xxh3_64(&bytes),
            None => bytes.len() as u64 != s.size,
        },
    }
}

/// One of the agent's edit hunks: its file (relative to the folder it edits in), its first line, the lines it took out.
#[derive(Clone, Debug)]
pub(super) struct Taken {
    pub rel: String,
    pub start: i64,
    pub deleted: String,
}

/// MATCHES mapped back onto the agent's hunks TAKEN: (done, left, unknown) ids. A match is done when a hunk near its
/// line took out its line or its old text; else left when its line is still in its file (NOW gives a file's text by
/// relative path) near its line; else unknown.
pub(super) fn map_back(
    matches: &[Handed],
    taken: &[Taken],
    now: impl Fn(&str) -> Option<String>,
) -> (Vec<String>, Vec<String>, Vec<String>) {
    let (mut done, mut left, mut unknown) = (Vec::new(), Vec::new(), Vec::new());
    let mut texts: BTreeMap<&str, Option<String>> = BTreeMap::new();
    for m in matches {
        let line = i64::from(m.line);
        let took = taken.iter().any(|t| {
            t.rel == m.rel
                && (t.start - line).abs() <= NEAR
                && (t.deleted.lines().any(|l| l == m.text)
                    || (!m.old.is_empty() && t.deleted.contains(&m.old)))
        });
        if took {
            done.push(m.id.clone());
            continue;
        }
        let text = texts.entry(m.rel.as_str()).or_insert_with(|| now(&m.rel));
        let still = text.as_deref().is_some_and(|t| {
            let from = (line - 1 - NEAR).max(0) as usize;
            t.lines()
                .skip(from)
                .take((2 * NEAR + 1) as usize)
                .any(|l| l == m.text)
        });
        if still {
            left.push(m.id.clone())
        } else {
            unknown.push(m.id.clone())
        }
    }
    (done, left, unknown)
}

/// Hand-off ID's state now: its agent's edit records mapped back, its phase from whether it edited and is busy.
pub(super) async fn state_of(
    f: &Front,
    c: &crate::dispatch::Caller,
    id: &str,
) -> Option<HandoffState> {
    let (view, session, tree, matches, edited) = f.core.views.greps.handoffs.with(id, |h| {
        (
            h.view.clone(),
            h.session.clone(),
            h.tree.clone(),
            h.matches.clone(),
            h.edited,
        )
    })?;
    let hunks = crate::history::hunk::op_hunks(
        f,
        c,
        runstav::methods::history::OpHunksParams {
            worktree: tree.to_string_lossy().into_owned(),
            op: None,
            session: Some(session.clone()),
        },
    )
    .await
    .map(|h| h.hunks)
    .unwrap_or_default();
    let taken: Vec<Taken> = hunks
        .into_iter()
        .filter(|h| h.state != runstav::methods::history::HunkState::Undone)
        .map(|h| Taken {
            rel: h.path,
            start: h.start_line,
            deleted: h.deleted,
        })
        .collect();
    let edited = edited || !taken.is_empty();
    let t2 = tree.clone();
    let (done, left, unknown) = crate::clock::blocking(move || {
        map_back(&matches, &taken, |rel| {
            std::fs::read_to_string(t2.join(rel)).ok()
        })
    })
    .await
    .ok()?;
    let busy = f.core.agents.find(&session).is_ok_and(|s| {
        matches!(
            s.status(),
            runstav::methods::agents::SessionStatus::Busy
                | runstav::methods::agents::SessionStatus::Starting
                | runstav::methods::agents::SessionStatus::Waiting
        )
    });
    let phase = match (edited, busy) {
        (false, _) => HandoffPhase::Sent,
        (true, true) => HandoffPhase::Editing,
        (true, false) => HandoffPhase::Done,
    };
    Some(HandoffState {
        handoff: id.to_owned(),
        view,
        session,
        phase,
        done,
        left,
        unknown,
    })
}

/// Watch hand-off ID: after each settled burst of its session's steps, its state goes to the asking connection
/// (`search-handoff-state`); the watch ends with the session, the hand-off, or [`TTL`].
pub(super) fn watch(
    f: std::sync::Arc<Front>,
    c: crate::dispatch::Caller,
    id: String,
    session: String,
) {
    let mut steps = f.core.agents.subscribe_steps();
    crate::clock::spawn("search:handoff", async move {
        let end = crate::clock::now() + TTL;
        loop {
            // wait for a step of the session, then for its steps to settle
            let got =
                crate::clock::timeout(end.saturating_duration_since(crate::clock::now()), async {
                    loop {
                        match steps.recv().await {
                            Ok(s) if s.session == session => return true,
                            Ok(_) => {}
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                                return true;
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => return false,
                        }
                    }
                })
                .await;
            if !matches!(got, Ok(true)) {
                break;
            }
            while let Ok(Ok(s)) = crate::clock::timeout(SETTLE, steps.recv()).await {
                let _ = s;
            }
            let Some(state) = state_of(&f, &c, &id).await else {
                break;
            };
            if state.phase != HandoffPhase::Sent {
                f.core.views.greps.handoffs.with(&id, |h| h.edited = true);
            }
            let conn = f.core.views.greps.handoffs.with(&id, |h| h.conn);
            if let Some(conn) = conn {
                f.send_to(conn, "search-handoff-state", serde_json::json!(state));
            }
            if f.core.agents.find(&session).is_err() {
                break;
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(id: &str, rel: &str, line: u32, text: &str, old: &str) -> Handed {
        Handed {
            id: id.into(),
            path: format!("/r/{rel}"),
            rel: rel.into(),
            line,
            col: text.find(old).unwrap_or(0) as u32,
            old: old.into(),
            text: text.into(),
            ctx: None,
            snap: None,
        }
    }

    #[test]
    fn a_brief_groups_the_rows_and_points_past_its_cap_to_the_tool() {
        let mut a = m("m:1:1", "a.el", 3, "  (foo pending)", "pending");
        a.ctx = Some("drgnx-foo".into());
        assert_eq!(row(&a), "a.el:3:8  in drgnx-foo  (foo pending)");
        let rows: Vec<String> = (0..BRIEF_LINES + 5)
            .map(|i| format!("a.el:{i}:1  x"))
            .collect();
        let (text, sent, more) = brief(
            "h:7",
            "Rename it",
            "\"pending\" (text)",
            Some("queued"),
            &rows,
            &["b.el".into()],
        );
        assert_eq!((sent, more), (BRIEF_LINES as u32, 5));
        assert!(
            text.starts_with(
                "Rename it\n\nThe search: \"pending\" (text)\nThe replacement: queued\n"
            )
        );
        assert!(
            text.contains(
                "a.el:299:1  x\n5 more: call the `search_results` tool with handoff id h:7"
            )
        );
        assert!(!text.contains("a.el:300:1"));
        assert!(text.contains("changed since the search, so lines may have moved: b.el"));
        assert!(text.ends_with("say which places you skipped and why.\n"));
        // the character cap counts too
        let long: Vec<String> = (0..10)
            .map(|i| format!("{i}{}", "x".repeat(BRIEF_CHARS / 4)))
            .collect();
        let (_, sent, more) = brief("h:1", "i", "q", None, &long, &[]);
        assert_eq!((sent, more), (3, 7));
    }

    #[test]
    fn matches_map_back_by_their_old_text_near_their_line_else_unknown() {
        let ms = vec![
            m("m:1:1", "a.el", 10, "(gethash p pending)", "pending"), // its line taken out: done
            m("m:1:2", "a.el", 40, "(remhash p pending)", "pending"), // still there, moved by 3: left
            m("m:1:3", "a.el", 90, "(puthash p pending)", "pending"), // gone, no hunk near: unknown
            m("m:1:4", "b.el", 10, "(gethash p pending)", "pending"), // a hunk far from it: still there
        ];
        let taken = vec![
            Taken {
                rel: "a.el".into(),
                start: 12,
                deleted: "(gethash p pending)\n".into(),
            },
            Taken {
                rel: "b.el".into(),
                start: 80,
                deleted: "(gethash p pending)\n".into(),
            },
        ];
        let a: String = (1..=100)
            .map(|i| {
                if i == 43 {
                    "(remhash p pending)\n".to_owned()
                } else {
                    format!("line {i}\n")
                }
            })
            .collect();
        let b: String = (1..=20)
            .map(|i| {
                if i == 10 {
                    "(gethash p pending)\n".to_owned()
                } else {
                    format!("line {i}\n")
                }
            })
            .collect();
        let (done, left, unknown) = map_back(&ms, &taken, |rel| match rel {
            "a.el" => Some(a.clone()),
            "b.el" => Some(b.clone()),
            _ => None,
        });
        assert_eq!(done, vec!["m:1:1"]);
        assert_eq!(left, vec!["m:1:2", "m:1:4"]);
        assert_eq!(unknown, vec!["m:1:3"]);
    }

    #[test]
    fn search_results_serves_only_its_session_in_pages() {
        let hs = Handoffs::default();
        let rows: Vec<String> = (0..250).map(|i| format!("a.el:{i}:1  x")).collect();
        let id = hs.add(Handoff {
            conn: 1,
            view: "s".into(),
            session: "a1".into(),
            tree: "/r".into(),
            matches: Vec::new(),
            rows,
            at: crate::clock::now(),
            served: 0,
            edited: false,
        });
        let p = hs.page(&id, "a1", 2).unwrap();
        assert!(p.starts_with(&format!("hand-off {id}, page 3 of 3\na.el:200:1  x\n")));
        assert_eq!(p.lines().count(), 1 + 50);
        assert!(hs.page(&id, "a2", 0).unwrap_err().contains("no hand-off"));
        hs.with(&id, |h| h.served = SERVED_MAX);
        assert!(hs.page(&id, "a1", 0).unwrap_err().contains("2 MB"));
        hs.forget(&id);
        assert!(hs.page(&id, "a1", 0).is_err());
    }

    #[test]
    fn a_hand_off_expires() {
        let hs = Handoffs::default();
        let at = crate::clock::now();
        let id = hs.add(Handoff {
            conn: 1,
            view: "s".into(),
            session: "a1".into(),
            tree: "/r".into(),
            matches: Vec::new(),
            rows: vec!["a.el:1:1  x".into()],
            at,
            served: 0,
            edited: false,
        });
        assert_eq!(hs.with_at(&id, at + TTL, |h| h.conn), Some(1));
        assert_eq!(
            hs.with_at(&id, at + TTL + Duration::from_secs(1), |h| h.conn),
            None
        );
        // and it is gone
        assert!(hs.page(&id, "a1", 0).is_err());
    }
}
