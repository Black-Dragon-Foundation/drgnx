//! The agent panel's cards under the transcript, built in the hub (offload step F1): a diff card for each hunk of each
//! file the agent edited, a permission card for each request the agent waits on, and a row for each note queued for the
//! agent (`c:q:N`, `drgnx-agent-panel-queued` N, which the editor's edit and drop commands read at point).  A diff card is a header (the file's
//! icon and name, which hunk, Reject and Accept) over the hunk's numbered lines in the card faces; a permission card is
//! the kit's question card (what the agent asks over Allow, Always and Deny, keys `y` `a` `n`; its buttons run the kit
//! action `agent-panel-card`).  A diff card's buttons carry `drgnx-agent-panel-action`
//! (`card:accept:PATH:I`, `card:reject:PATH:I`) for the editor's one click dispatcher; each row of a card carries `drgnx-agent-panel-card` (`["diff", PATH, I]` or `["perm", ID]`), which
//! the keys (`a`, `D`, `RET`, `A`) read at point.

use super::icons;
use super::kit_env;
use crate::agents::session::rows::one_line;
use rodd::faces::FaceId;
use rodd::fit::FontSet;
use rodd::kit::{self, Action, Choice, Comp, DiffLine, Hunk as KitHunk, QuestionKind};
use rodd::{ImageId, Row, RowBuilder};
use runstav::methods::agents::{Permission, RpcId};
use runstav::methods::view::ViewEnv;
use serde_json::json;

/// The most files that get diff cards, and the most lines of a hunk a card shows.
pub const MAX_FILES: usize = 20;
const MAX_LINES: usize = 30;
/// The most chars of a diff line a row carries (a minified file's line would make rows of megabytes); the window's
/// width cuts it well before.
const MAX_CHARS: usize = 400;

/// What the cards read.
pub struct In<'a> {
    pub env: &'a ViewEnv,
    pub fonts: &'a FontSet,
    /// Each edited file's path and its unified diff against the base.
    pub diffs: &'a [(String, String)],
    pub permissions: &'a [Permission],
    /// The notes waiting for the turn to end, oldest first.
    pub queue: &'a [String],
}

/// One hunk of a unified diff: its `@@` line and its lines (a leading `+`, `-` or space).
#[derive(Debug, PartialEq)]
pub struct Hunk {
    pub header: String,
    pub lines: Vec<String>,
}

/// The hunks of the unified DIFF; what comes before the first `@@` line, and the "no newline" notes, are left out.
pub fn parse_hunks(diff: &str) -> Vec<Hunk> {
    let mut hunks: Vec<Hunk> = Vec::new();
    for line in diff.split('\n') {
        if line.starts_with("@@") {
            hunks.push(Hunk {
                header: line.to_owned(),
                lines: Vec::new(),
            });
        } else if let Some(h) = hunks.last_mut()
            && !line.is_empty()
            && !line.starts_with('\\')
        {
            h.lines.push(line.to_owned());
        }
    }
    hunks
}

/// The first number after the SIGN (`-` or `+`) in a `@@ -A,B +C,D @@` header, and the count after it (1 when none).
fn range(header: &str, sign: char) -> (u32, u32) {
    let Some(at) = header.find(&format!(" {sign}")) else {
        return (1, 1);
    };
    let rest = &header[at + 2..];
    let end = rest.find([' ', '@']).unwrap_or(rest.len());
    let mut it = rest[..end].split(',');
    let start = it.next().and_then(|n| n.parse().ok()).unwrap_or(1);
    let len = it.next().and_then(|n| n.parse().ok()).unwrap_or(1);
    (start, len)
}

fn px(env: &ViewEnv, v: f32) -> u32 {
    let scale = if env.scale > 0.0 { env.scale } else { 1.0 };
    (f64::from(v) * f64::from(scale) + 0.5 + 1e-9).floor() as u32
}

/// TEXT kept to COLS chars (the last an ellipsis): a bound on a row's size, not its fit (the hub fits each row to its
/// window, in the fonts it draws in).
fn cut(text: &str, cols: usize) -> String {
    if text.chars().count() <= cols {
        text.to_owned()
    } else {
        let mut s: String = text.chars().take(cols.saturating_sub(1)).collect();
        s.push('…');
        s
    }
}

fn id_of(id: &Option<RpcId>) -> String {
    match id {
        Some(RpcId::Int(n)) => n.to_string(),
        Some(RpcId::Str(s)) => s.clone(),
        None => String::new(),
    }
}

/// Hunk N of PATH as a kit diff block (`rodd::kit::Comp::DiffBlock`): the head row (the file, which hunk, the
/// counts, Reject and Accept) over the hunk's lines, numbered (the new file's numbers, a removed line the old file's),
/// each cut to MAX_CHARS.  The buttons keep the panel's own click props, which the editor's dispatcher reads.
fn diff_card(
    path: &str,
    n: usize,
    total: usize,
    h: &Hunk,
    i: &In,
    images: &mut Vec<(ImageId, String)>,
) -> Vec<Row> {
    let (mut old, _) = range(&h.header, '-');
    let (mut new, _) = range(&h.header, '+');
    let (mut added, mut removed) = (0, 0);
    let mut lines = Vec::new();
    for l in h.lines.iter().take(MAX_LINES) {
        let (kind, rest, num) = match l.chars().next() {
            Some('-') => {
                old += 1;
                removed += 1;
                (DiffLine::Del, &l[1..], old - 1)
            }
            Some('+') => {
                new += 1;
                added += 1;
                (DiffLine::Add, &l[1..], new - 1)
            }
            c => {
                old += 1;
                new += 1;
                let rest = if c == Some(' ') { &l[1..] } else { l.as_str() };
                (DiffLine::Ctx, rest, new - 1)
            }
        };
        lines.push((kind, num, cut(rest, MAX_CHARS)));
    }
    let file = if total > 1 {
        format!("{path} · hunk {} of {total}", n + 1)
    } else {
        path.to_owned()
    };
    let button = |label: &str, verb: &str| {
        (
            label.to_owned(),
            Action {
                kind: "card".into(),
                args: vec![json!(verb), json!(path), json!(n)],
            },
        )
    };
    let block = Comp::DiffBlock {
        file,
        added,
        removed,
        hunks: vec![KitHunk {
            header: h.header.clone(),
            lines,
        }],
        buttons: vec![button("Reject", "reject"), button("Accept", "accept")],
        icon: Some(icons::file_icon(path.rsplit('/').next().unwrap_or(path)).to_owned()),
        // the head's room in logical px: the name gives way to the buttons in a narrow panel
        width: (i.env.width_px > 0)
            .then(|| (f64::from(i.env.width_px) / f64::from(i.env.scale.max(0.01))).round() as u32),
    };
    // the icons the head draws: their SVG goes with the rows
    let drawn = std::cell::RefCell::new(Vec::new());
    let icon_image = |name: &str, size: u32| {
        icons::svg(name, size).map(|(id, svg)| {
            drawn.borrow_mut().push((id, svg));
            id
        })
    };
    let env = kit::KitEnv {
        icons: Some(kit::Icons(&icon_image)),
        ..kit_env(i.env)
    };
    let mut rows = kit::diff_block_rows(&env, &format!("c:diff:{path}:{n}"), &block, i.fonts);
    images.extend(drawn.into_inner());
    for r in &mut rows {
        let end = u32::try_from(r.text.chars().count()).unwrap_or(u32::MAX);
        // the kit's button action is the panel's: `card:VERB:PATH:N`, which the editor's one dispatcher reads
        let panel: Vec<_> = r
            .props
            .iter()
            .filter(|p| p.2 == "drgnx-action" && p.3[0] == "card")
            .map(|p| {
                let verb = p.3[1].as_str().unwrap_or_default();
                (p.0, p.1, format!("card:{verb}:{path}:{n}"))
            })
            .collect();
        r.props
            .retain(|p| !(p.2 == "drgnx-action" && p.3[0] == "card"));
        for (from, to, action) in panel {
            let help = if action.starts_with("card:reject") {
                "D: take the change back"
            } else {
                "a: keep the change"
            };
            r.props
                .push((from, to, "drgnx-agent-panel-action".into(), json!(action)));
            r.props.push((from, to, "help-echo".into(), json!(help)));
        }
        r.props.push((
            0,
            end,
            "drgnx-agent-panel-card".into(),
            json!(["diff", path, n]),
        ));
    }
    rows
}

/// Request P as a kit question card: the needs-you ring, the head (the status dot and what the agent asks) on the
/// attention tint, then Allow, Always and Deny as kit buttons with their key hints (`y a n`). A click runs the panel's
/// own action (`drgnx-agent-panel-action` = `card:allow:ID`…), and every row carries the card for the commands that read
/// the card at point.
fn perm_card(i: &In, _images: &mut Vec<(ImageId, String)>, p: &Permission) -> Vec<Row> {
    let id = id_of(&p.id);
    let title = format!(
        "{}?",
        one_line(p.title.as_deref().unwrap_or("the agent asks"), 70)
    );
    let choices = [("Allow", "allow"), ("Always", "always"), ("Deny", "deny")]
        .iter()
        .map(|(label, act)| Choice {
            label: (*label).to_owned(),
            key: String::new(),
            action: Action {
                kind: "agent-panel-card".to_owned(),
                args: vec![json!(format!("card:{act}:{id}"))],
            },
        })
        .collect();
    let card = Comp::QuestionCard {
        kind: QuestionKind::Permission,
        title,
        body: String::new(),
        choices,
    };
    let mut rows = kit::expand_rows(&i.env.kit(), &format!("c:perm:{id}"), &card);
    let at = json!(["perm", id]);
    for r in &mut rows {
        let clicks: Vec<(u32, u32, String)> = r
            .props
            .iter()
            .filter(|p| p.2 == "drgnx-action")
            .filter_map(|p| Some((p.0, p.1, p.3.get(1)?.as_str()?.to_owned())))
            .collect();
        for (from, to, act) in clicks {
            r.props
                .push((from, to, "drgnx-agent-panel-action".to_owned(), json!(act)));
        }
        // the card takes the panel's width: a last character stretches to the right edge (as the other cards') and the
        // ring and the head's tint run to it, so every row closes the ring at the same place
        let len = u32::try_from(r.text.chars().count()).unwrap_or(u32::MAX);
        r.text.push(' ');
        r.stops
            .push((len, i.env.width_px.saturating_sub(px(i.env, 12.0))));
        for run in &mut r.runs {
            if run.0 == 0 && run.1 == len {
                run.1 = len + 1;
            }
        }
        r.props
            .push((0, len + 1, "drgnx-agent-panel-card".to_owned(), at.clone()));
    }
    rows
}

/// Queued note N as one line: "  ⏸ queued 1  text   (e edit · d drop)".
fn queue_row(env: &ViewEnv, n: usize, note: &str) -> Row {
    let mut b = RowBuilder::new(format!("c:q:{n}"));
    b.push(
        &format!(
            " ⏸ queued {}  {}   (e edit · d drop)",
            n + 1,
            one_line(note, 60)
        ),
        Some(FaceId::AgentPanelSubtle.name()),
    );
    b.stop(env.width_px.saturating_sub(px(env, 12.0)));
    let end = b.pos();
    b.face(0, end, FaceId::CardSingle.name());
    b.prop(0, end, "drgnx-agent-panel-queued", json!(n));
    b.finish()
}

/// The cards: each hunk of each edited file, then each permission request, then each queued note.  The images the icons need go with them.
pub fn rows(i: &In) -> (Vec<Row>, Vec<(ImageId, String)>) {
    let mut images = Vec::new();
    let mut out = Vec::new();
    for (path, diff) in i.diffs.iter().take(MAX_FILES) {
        let hunks = parse_hunks(diff);
        for (n, h) in hunks.iter().enumerate() {
            out.extend(diff_card(path, n, hunks.len(), h, i, &mut images));
        }
    }
    for p in i.permissions {
        out.extend(perm_card(i, &mut images, p));
    }
    out.extend(
        i.queue
            .iter()
            .enumerate()
            .map(|(n, q)| queue_row(i.env, n, q)),
    );
    // one blank row between the transcript and the cards, as the mockup has it
    if !out.is_empty() {
        let mut gap = RowBuilder::new("c:gap");
        gap.push(" ", None);
        out.insert(0, gap.finish());
    }
    (out, images)
}

#[cfg(test)]
#[path = "panel_review/tests.rs"]
mod tests;
