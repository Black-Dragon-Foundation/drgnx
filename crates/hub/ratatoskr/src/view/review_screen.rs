//! The review screen (frontend flow plan, Task 28): one screen for a change under review, code or document, in this
//! order: what changed since the last version, the effect on tasks, the reason of each change, then the actions.
//! Rows are the hub's; the editor draws nothing of it. The data is the Changes view's (`work::changes`: hunks, their
//! provenance reasons) and `review/effects`' (`work::task_effects`); a document's change is its text against the last
//! reviewed base (`from`: a git blob id; the document as the last commit has it when none is given).
//!
//! Row keys, in order: `changes-head`, then per file `file:N` and per hunk `hunk:N:M` with its `line:N:M:K` rows;
//! `effects-head`, then `effect:N` (or `effects-none`); `reasons-head`, then `reason:N:M`; `actions`, `actions-note`.
//! The actions are text properties the editor's keys read: `drgnx-action` (`accept`, `request-changes`, `open`) on the
//! buttons and files, and `drgnx-review-hunk` (path, index, hash, session) on a hunk's rows, for `a` and `D`.

use crate::dispatch::Caller;
use crate::front::Front;
use crate::view::{Key, Views, kit_env};
use crate::work::changes::HunkRef;
use rodd::faces::FaceId;
use rodd::kit::{self, ButtonStyle, Comp, KitEnv, Size, State as KitState, Status};
use rodd::{Row, RowBuilder};
use runstav::methods::review_screen::{Set, Subscribe, ViewId};
use runstav::methods::work::{
    ChangeRef, CodeChange, DocChange, EffectsParams, TaskEffect, TaskState,
};
use runstav::wire::{Error, ErrorCode};
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The lines of one hunk shown before "… N more".
const HUNK_LINES: usize = 40;

/// One hunk of the change: its header, its lines, and what the provenance says of it.
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenHunk {
    pub index: u32,
    pub header: String,
    pub lines: Vec<String>,
    /// The hash a review mark for this hunk carries (the text of the hunk).
    pub hash: String,
    /// Its lines in the new text.
    pub start_line: u32,
    pub end_line: u32,
    pub agent: Option<String>,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScreenFile {
    pub path: String,
    pub hunks: Vec<ScreenHunk>,
}

/// Everything the screen shows.
#[derive(Clone, Debug, PartialEq)]
pub struct Screen {
    /// The agent session of a code change (the review marks and steers go there).
    pub session: Option<String>,
    pub files: Vec<ScreenFile>,
    pub effects: Vec<TaskEffect>,
}

/// What a view shows: where its change comes from.
#[derive(Clone, Debug)]
struct Source {
    session: Option<String>,
    doc: Option<PathBuf>,
    from: Option<String>,
    screen: Screen,
}

/// The review screens of every connection.
#[derive(Default)]
pub struct ReviewScreens {
    views: Mutex<HashMap<(u64, String), Source>>,
}

impl ReviewScreens {
    pub(super) fn gone(&self, conn: u64) {
        lock(&self.views).retain(|(c, _), _| *c != conn);
    }
}

impl Views {
    /// The rows of KEY's review screen for its class; false when the view is none.
    pub(super) fn review_screen_build(&self, f: &Front, key: &Key) -> bool {
        let Some(screen) = lock(&self.review_screens.views)
            .get(&(key.0, key.1.clone()))
            .map(|s| s.screen.clone())
        else {
            return false;
        };
        self.publish_built(f, key, |env, _| (rows(&screen, &kit_env(env)), Vec::new()));
        true
    }

    fn review_screen_show(&self, f: &Front, conn: u64, view: &str, source: Source) {
        lock(&self.review_screens.views).insert((conn, view.to_owned()), source.clone());
        for key in self.keys_of(view).into_iter().filter(|k| k.0 == conn) {
            self.publish_built(f, &key, |env, _| {
                (rows(&source.screen, &kit_env(env)), Vec::new())
            });
        }
    }
}

fn invalid(path: &str, message: &str) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.into(),
        path: Some(path.into()),
    }
}

/// `review-screen/subscribe`.
pub async fn subscribe(f: &Front, c: &Caller, p: Subscribe) -> Result<bool, Error> {
    let source = read(f, c, p.session, p.doc, p.from).await?;
    f.core
        .views
        .review_screen_show(f, c.conn_id, &p.view, source);
    Ok(true)
}

/// `review-screen/set`: refresh reads the change and its effects again.
pub async fn set(f: &Front, c: &Caller, p: Set) -> Result<bool, Error> {
    let known = lock(&f.core.views.review_screens.views)
        .get(&(c.conn_id, p.view.clone()))
        .cloned();
    let Some(known) = known else {
        return Err(invalid(
            "view",
            "not a review screen (review-screen/subscribe first)",
        ));
    };
    if p.refresh {
        let source = read(f, c, known.session, known.doc, known.from).await?;
        f.core
            .views
            .review_screen_show(f, c.conn_id, &p.view, source);
    }
    Ok(true)
}

/// `review-screen/close`.
pub fn close(f: &Front, c: &Caller, p: ViewId) -> Result<bool, Error> {
    Ok(lock(&f.core.views.review_screens.views)
        .remove(&(c.conn_id, p.view))
        .is_some())
}

/// The change of SESSION (code) or DOC (a document against FROM) with its effects on the tasks.
async fn read(
    f: &Front,
    c: &Caller,
    session: Option<String>,
    doc: Option<PathBuf>,
    from: Option<String>,
) -> Result<Source, Error> {
    let (files, effects) = match (&session, &doc) {
        (Some(sid), None) => {
            let (files, paths) = code_files(f, sid).await?;
            let effects = crate::work::task_effects::effects(
                f,
                c,
                EffectsParams {
                    change: ChangeRef::Code(CodeChange {
                        paths,
                        branch: None,
                    }),
                },
            )
            .await?;
            (files, effects)
        }
        (None, Some(doc)) => {
            let (file, base) = doc_file(doc, from.as_deref())?;
            let effects = crate::work::task_effects::effects(
                f,
                c,
                EffectsParams {
                    change: ChangeRef::Doc(DocChange {
                        doc: doc.clone(),
                        from: base,
                    }),
                },
            )
            .await?;
            (vec![file], effects)
        }
        _ => return Err(invalid("session", "exactly one of `session` and `doc`")),
    };
    Ok(Source {
        screen: Screen {
            session: session.clone(),
            files,
            effects,
        },
        session,
        doc,
        from,
    })
}

/// The session's changed files as screen files, and their paths.
async fn code_files(f: &Front, sid: &str) -> Result<(Vec<ScreenFile>, Vec<String>), Error> {
    let Some(changed) = crate::work::edits::edited(f, sid).await? else {
        return Ok((Vec::new(), Vec::new()));
    };
    let name = f
        .core
        .agents
        .live_sessions()
        .iter()
        .map(|s| s.snapshot())
        .find(|s| s.id == sid)
        .map(|s| s.name.unwrap_or_else(|| s.id.clone()))
        .unwrap_or_else(|| sid.to_owned());
    let groups = crate::work::changes::by_task(f).await?;
    let mut files = Vec::new();
    let mut paths = Vec::new();
    for c in changed.files {
        let diff = crate::work::edits::diff_of(f, sid, &c.path)
            .await
            .unwrap_or_default();
        let refs: Vec<HunkRef> = groups
            .iter()
            .flat_map(|g| g.files.iter())
            .filter(|fg| fg.path == c.path)
            .flat_map(|fg| fg.hunks.iter().cloned())
            .collect();
        paths.push(c.path.clone());
        files.push(ScreenFile {
            hunks: split_hunks(&diff, &refs, Some(&name)),
            path: c.path,
        });
    }
    Ok((files, paths))
}

/// DOC against its base: FROM, else the blob the last commit has. The file, and the blob id the effects read.
fn doc_file(doc: &PathBuf, from: Option<&str>) -> Result<(ScreenFile, String), Error> {
    if !doc.is_absolute() {
        return Err(invalid("doc", "an absolute path"));
    }
    let main = crate::work::presence::main_checkout(doc)
        .ok_or_else(|| invalid("doc", "the document is not in a git repository"))?;
    let rel = std::fs::canonicalize(doc)
        .unwrap_or_else(|_| doc.clone())
        .strip_prefix(&main)
        .map_err(|_| invalid("doc", "the document is not in its main checkout"))?
        .to_string_lossy()
        .into_owned();
    let base = match from {
        Some(b) => b.to_owned(),
        None => git(&main, &["rev-parse", &format!("HEAD:{rel}")])
            .map(|s| s.trim().to_owned())
            .ok_or_else(|| invalid("from", "the document has no committed version"))?,
    };
    let old = git(&main, &["cat-file", "blob", &base])
        .ok_or_else(|| invalid("from", "no such blob in the document's repository"))?;
    let new = std::fs::read_to_string(doc).unwrap_or_default();
    let diff = similar::TextDiff::from_lines(&old, &new)
        .unified_diff()
        .context_radius(2)
        .to_string();
    Ok((
        ScreenFile {
            path: doc.to_string_lossy().into_owned(),
            hunks: split_hunks(&diff, &[], None),
        },
        base,
    ))
}

fn git(dir: &std::path::Path, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8(out.stdout).ok())
        .flatten()
}

/// The new-file range of a hunk header `@@ -a,b +c,d @@`.
fn new_range(header: &str) -> (u32, u32) {
    let new = header
        .split_whitespace()
        .find(|w| w.starts_with('+'))
        .map(|w| w.trim_start_matches('+'))
        .unwrap_or("1");
    let (start, len) = new.split_once(',').unwrap_or((new, "1"));
    let (start, len) = (start.parse().unwrap_or(1u32), len.parse().unwrap_or(1u32));
    (start, start + len.saturating_sub(1))
}

/// The hunks of a unified DIFF, each with the reason of the REFS hunk whose lines it overlaps (NAME wrote them).
pub fn split_hunks(diff: &str, refs: &[HunkRef], name: Option<&str>) -> Vec<ScreenHunk> {
    use sha2::Digest;
    let mut out: Vec<ScreenHunk> = Vec::new();
    for line in diff.lines() {
        if line.starts_with("@@") {
            let (start_line, end_line) = new_range(line);
            let r = refs
                .iter()
                .find(|r| r.start_line <= end_line && start_line <= r.end_line);
            out.push(ScreenHunk {
                index: u32::try_from(out.len()).unwrap_or(u32::MAX),
                header: line.to_owned(),
                lines: Vec::new(),
                hash: String::new(),
                start_line,
                end_line,
                agent: r.and_then(|r| r.agent.clone()).or(name.map(str::to_owned)),
                reason: r.and_then(|r| r.reason.clone()),
            });
        } else if let Some(h) = out.last_mut() {
            h.lines.push(line.to_owned());
        }
    }
    for h in &mut out {
        let text = format!("{}\n{}", h.header, h.lines.join("\n"));
        h.hash = sha2::Sha256::digest(text.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
    }
    out
}

/// PATH as the screen names it: a document's absolute path by its file name, a repository path as it is.
fn shown(path: &str) -> &str {
    if path.starts_with('/') {
        path.rsplit('/').next().unwrap_or(path)
    } else {
        path
    }
}

fn counts(h: &ScreenHunk) -> (u32, u32) {
    let add = |p: char| {
        u32::try_from(h.lines.iter().filter(|l| l.starts_with(p)).count()).unwrap_or(u32::MAX)
    };
    (add('+'), add('-'))
}

fn head(env: &KitEnv, key: &str, title: &str) -> Row {
    let mut b = RowBuilder::new(key);
    kit::expand(
        &mut b,
        env,
        &Comp::SectionHeader {
            title: title.to_owned(),
            collapsible: false,
            collapsed: false,
            count: None,
            state: KitState::Rest,
            action: None,
        },
    );
    b.finish()
}

fn status_of(s: TaskState) -> Status {
    match s {
        TaskState::Running => Status::Running,
        TaskState::NeedsInput | TaskState::InReview => Status::NeedsYou,
        TaskState::Queued => Status::Idle,
    }
}

fn button(b: &mut RowBuilder, env: &KitEnv, label: &str, key: &str, primary: bool, act: &str) {
    let from = b.pos();
    kit::expand(
        b,
        env,
        &Comp::Button {
            label: label.to_owned(),
            style: if primary {
                ButtonStyle::Primary
            } else {
                ButtonStyle::Secondary
            },
            size: Size::Md,
            state: KitState::Rest,
            key: Some(key.to_owned()),
            action: None,
        },
    );
    let to = b.pos();
    b.prop(from, to, "drgnx-action", json!([act]));
}

/// The screen's rows, in the order the plan gives.
pub fn rows(s: &Screen, env: &KitEnv) -> Vec<Row> {
    let mut out = Vec::new();
    out.push(head(
        env,
        "changes-head",
        "What changed since the last version",
    ));
    for (n, f) in s.files.iter().enumerate() {
        let (plus, minus) = f
            .hunks
            .iter()
            .map(counts)
            .fold((0, 0), |a, c| (a.0 + c.0, a.1 + c.1));
        let mut b = RowBuilder::new(format!("file:{n}"));
        b.push(&format!("{}  +{plus} −{minus}", shown(&f.path)), None);
        let end = b.pos();
        b.prop(0, end, "drgnx-action", json!(["open", f.path, 1]));
        out.push(b.finish());
        for h in &f.hunks {
            let hunk_prop =
                json!({"path": f.path, "index": h.index, "hash": h.hash, "session": s.session});
            let mut b = RowBuilder::new(format!("hunk:{n}:{}", h.index));
            b.push(&format!("  {}", h.header), Some(FaceId::TextMuted.name()));
            let end = b.pos();
            b.prop(
                0,
                end,
                "drgnx-action",
                json!(["open", f.path, h.start_line]),
            );
            b.prop(0, end, "drgnx-review-hunk", hunk_prop.clone());
            out.push(b.finish());
            for (k, l) in h.lines.iter().take(HUNK_LINES).enumerate() {
                let face = match l.chars().next() {
                    Some('+') => Some(FaceId::AgentPanelAdded.name()),
                    Some('-') => Some(FaceId::AgentPanelRemoved.name()),
                    _ => None,
                };
                let mut b = RowBuilder::new(format!("line:{n}:{}:{k}", h.index));
                b.push(&format!("  {l}"), face);
                let end = b.pos();
                b.prop(0, end, "drgnx-review-hunk", hunk_prop.clone());
                out.push(b.finish());
            }
            if h.lines.len() > HUNK_LINES {
                let mut b = RowBuilder::new(format!("line:{n}:{}:more", h.index));
                b.push(
                    &format!("  … {} more lines", h.lines.len() - HUNK_LINES),
                    Some(FaceId::TextMuted.name()),
                );
                out.push(b.finish());
            }
        }
    }
    out.push(head(env, "effects-head", "The effect on tasks"));
    if s.effects.is_empty() {
        let mut b = RowBuilder::new("effects-none");
        b.push("No task is affected.", Some(FaceId::TextMuted.name()));
        out.push(b.finish());
    }
    for (n, e) in s.effects.iter().enumerate() {
        let mut b = RowBuilder::new(format!("effect:{n}"));
        kit::expand(
            &mut b,
            env,
            &Comp::StatusDot {
                status: status_of(e.state),
                word: true,
            },
        );
        b.push(&format!("  {}", e.why), None);
        out.push(b.finish());
    }
    let reasons: Vec<(&ScreenFile, &ScreenHunk)> = s
        .files
        .iter()
        .flat_map(|f| f.hunks.iter().map(move |h| (f, h)))
        .collect();
    out.push(head(env, "reasons-head", "The agent's reasons"));
    for (n, (f, h)) in reasons.iter().enumerate() {
        let mut b = RowBuilder::new(format!("reason:{n}"));
        b.push(
            &format!("{} lines {}–{}: ", shown(&f.path), h.start_line, h.end_line),
            None,
        );
        match &h.reason {
            Some(r) => b.push(r, None),
            None => b.push("No reason recorded", Some(FaceId::TextMuted.name())),
        };
        out.push(b.finish());
    }
    let mut b = RowBuilder::new("actions");
    button(&mut b, env, "Accept", "A", true, "accept");
    b.push("  ", None);
    button(
        &mut b,
        env,
        "Request changes",
        "r",
        false,
        "request-changes",
    );
    out.push(b.finish());
    let mut b = RowBuilder::new("actions-note");
    b.push(
        "a accepts the hunk, D rejects it. Merges and pushes go through their cards.",
        Some(FaceId::TextMuted.name()),
    );
    out.push(b.finish());
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodd::kit::Density;

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

    fn effect(n: u32, state: TaskState, why: &str) -> TaskEffect {
        TaskEffect {
            task: format!("J#{n}"),
            task_title: format!("task {n}"),
            plan: None,
            agent: None,
            state,
            effect: runstav::methods::work::Effect::Stops,
            why: why.into(),
        }
    }

    const DIFF: &str = "@@ -1,2 +1,3 @@\n a\n-b\n+B\n+c\n@@ -9,1 +10,1 @@\n-x\n+y\n";

    fn screen() -> Screen {
        let refs = [HunkRef {
            op: None,
            index: 0,
            start_line: 1,
            end_line: 3,
            agent: Some("ann".into()),
            session: Some("s1".into()),
            reason: Some("fixed the race".into()),
        }];
        Screen {
            session: Some("s1".into()),
            files: vec![ScreenFile {
                path: "a.rs".into(),
                hunks: split_hunks(DIFF, &refs, Some("ann")),
            }],
            effects: vec![effect(
                3,
                TaskState::Running,
                "Task 3 running: it would stop.",
            )],
        }
    }

    #[test]
    fn review_lists_changes_then_effects_then_reasons() {
        let rows = rows(&screen(), &env());
        let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        let at = |k: &str| {
            keys.iter()
                .position(|x| *x == k)
                .unwrap_or_else(|| panic!("{k} in {keys:?}"))
        };
        assert!(at("changes-head") < at("hunk:0:0") && at("hunk:0:1") < at("effects-head"));
        assert!(at("effects-head") < at("effect:0") && at("effect:0") < at("reasons-head"));
        assert!(at("reasons-head") < at("reason:0") && at("reason:1") < at("actions"));
        let text = |k: &str| rows[at(k)].text.clone();
        assert!(
            text("effect:0").contains("Task 3 running: it would stop."),
            "{}",
            text("effect:0")
        );
        assert!(
            text("reason:0").contains("fixed the race"),
            "{}",
            text("reason:0")
        );
        assert!(
            text("reason:1").contains("No reason recorded"),
            "{}",
            text("reason:1")
        );
        // the status dot of the effect is the kit's, with its word
        assert!(
            rows[at("effect:0")].text.contains("running"),
            "{}",
            text("effect:0")
        );
        // the two primary actions and the hunk's marks are properties the keys read
        let actions = &rows[at("actions")];
        assert!(
            actions
                .props
                .iter()
                .any(|p| p.2 == "drgnx-action" && p.3 == json!(["accept"]))
        );
        assert!(
            actions
                .props
                .iter()
                .any(|p| p.2 == "drgnx-action" && p.3 == json!(["request-changes"]))
        );
        assert!(
            rows[at("hunk:0:0")]
                .props
                .iter()
                .any(|p| p.2 == "drgnx-review-hunk")
        );
    }

    /// A plan edit that drops task 3, through the hub's own effect computation, reads on the screen as the line "Task 3
    /// is running: it would stop." under the effects heading (the UI row `a-plan-edit-shows-it-would-stop-task-3`).
    #[test]
    fn a_plan_edit_shows_it_would_stop_task_3() {
        use crate::work::task_effects::{Live, of_plan_edit};
        let old = "# Plan\n\n### Task 1: One\n\nDo one.\n\n### Task 3: Three\n\nDo three.\n";
        let new = "# Plan\n\n### Task 1: One\n\nDo one.\n";
        let live = Live {
            task: "J1#3".into(),
            n: 3,
            title: "Three".into(),
            plan: None,
            state: TaskState::Running,
            session: Some("s3".into()),
            agent: Some("agent 3".into()),
            edits: Vec::new(),
            reads: Vec::new(),
        };
        let mut s = screen();
        s.effects = of_plan_edit(old, Some(new), &[live]);
        let r = rows(&s, &env());
        let e = r.iter().find(|r| r.key == "effect:0").expect("effect row");
        assert!(
            e.text.contains("Task 3 is running: it would stop."),
            "{}",
            e.text
        );
    }

    #[test]
    fn a_queued_task_is_idle_not_started_and_no_effect_says_so() {
        let mut s = screen();
        s.effects = vec![effect(
            4,
            TaskState::Queued,
            "Task 4 queued: its brief changes.",
        )];
        let r = rows(&s, &env());
        let e = r.iter().find(|r| r.key == "effect:0").expect("effect row");
        assert!(e.text.contains("not started"), "{}", e.text);
        s.effects.clear();
        let r = rows(&s, &env());
        assert!(r.iter().any(|r| r.key == "effects-none"));
    }

    #[test]
    fn split_hunks_numbers_hunks_and_hashes_each_by_its_own_text() {
        let h = split_hunks(DIFF, &[], None);
        assert_eq!(h.len(), 2);
        assert_eq!((h[0].start_line, h[0].end_line), (1, 3));
        assert_eq!((h[1].start_line, h[1].end_line), (10, 10));
        assert_ne!(h[0].hash, h[1].hash);
        assert!(h[1].reason.is_none());
    }
}
