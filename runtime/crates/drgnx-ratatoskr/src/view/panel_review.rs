//! The agent panel's cards under the transcript, built in the hub (offload step F1): a diff card for each hunk of each
//! file the agent edited, a permission card for each request the agent waits on, and a row for each note queued for the
//! agent (`c:q:N`, `drgnx-agent-panel-queued` N, which the editor's edit and drop commands read at point).  A diff card is a header (the file's
//! icon and name, which hunk, Reject and Accept) over the hunk's numbered lines in the card faces; a permission card is
//! one ringed line (what the agent asks) over Allow, Always and Deny.  The buttons carry `drgnx-agent-panel-action`
//! (`card:accept:PATH:I`, `card:reject:PATH:I`, `card:allow:ID`, `card:always:ID`, `card:deny:ID`) for the editor's one
//! click dispatcher; each row of a card carries `drgnx-agent-panel-card` (`["diff", PATH, I]` or `["perm", ID]`), which
//! the keys (`a`, `D`, `RET`, `A`) read at point.

use super::icons;
use crate::agents::session::rows::one_line;
use drgnx_rows::fit::{self, FontSet};
use drgnx_rows::{ImageId, Row, RowBuilder};
use runstav::methods::agents::{Permission, RpcId};
use runstav::methods::view::{Display, ViewEnv};
use serde_json::{Value, json};

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

/// TEXT's width drawn in FACE (none: the panel's default), in the font the editor says FACE draws in.
fn text_width(i: &In, face: Option<&str>, text: &str) -> u32 {
    match i.env.display {
        Display::Gui => fit::width_in(i.fonts, face, text).ceil() as u32,
        Display::Tty => text.chars().count() as u32 * i.env.cell.0.max(1),
    }
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

fn shape(n: usize, i: usize) -> &'static str {
    if n == 1 {
        "drgnx-card-single"
    } else if i == 0 {
        "drgnx-card-top"
    } else if i + 1 == n {
        "drgnx-card-bottom"
    } else {
        "drgnx-card-mid"
    }
}

/// One icon: its image (the SVG goes with the row) or, on a terminal, its alternative.
fn icon(
    b: &mut RowBuilder,
    images: &mut Vec<(ImageId, String)>,
    name: &str,
    alt: &str,
    size: u32,
    face: &str,
) {
    let start = b.pos();
    match icons::svg(name, size) {
        Some((id, svg)) => {
            images.push((id, svg));
            b.image(id, alt);
        }
        None => {
            b.push(alt, None);
        }
    }
    let end = b.pos();
    b.face(start, end, face);
}

/// A diff card's header: the file's icon and name, which lines and hunk, Reject and Accept at the right.  In a narrow
/// panel the name gives way, then the label, so the buttons stay inside the edge.
fn diff_header(
    i: &In,
    images: &mut Vec<(ImageId, String)>,
    path: &str,
    n: usize,
    total: usize,
    h: &Hunk,
    key: String,
) -> Row {
    let env = i.env;
    let (start, len) = range(&h.header, '+');
    let label = format!(
        "{start}–{} · hunk {} of {total}",
        start + len.saturating_sub(1),
        n + 1
    );
    let icon_px = px(env, 16.0);
    let mut b = RowBuilder::new(key);
    b.push(" ", None);
    icon(
        &mut b,
        images,
        icons::file_icon(path.rsplit('/').next().unwrap_or(path)),
        "▤",
        icon_px,
        "drgnx-text-muted",
    );
    b.push(" ", None);
    let button = Some("drgnx-ui-button");
    let actions_w = text_width(i, button, " Reject ")
        + text_width(i, None, " ")
        + text_width(i, button, " Accept ");
    // what is left for the name and the label: the icon, then the buttons and 20 px of margin
    let room = i64::from(env.width_px)
        - i64::from(icon_px)
        - i64::from(text_width(i, None, "   "))
        - i64::from(actions_w)
        - i64::from(px(env, 20.0));
    let name = one_line(path, 50);
    let both = text_width(i, Some("bold"), &name)
        + text_width(i, None, " ")
        + text_width(i, Some("drgnx-agent-panel-subtle"), &label);
    let (name, label) = if env.width_px == 0 || i64::from(both) <= room {
        (name, label)
    } else if room > 0 {
        let name = if i64::from(text_width(i, Some("bold"), &name)) <= room {
            name
        } else {
            fit::fit_in(i.fonts, Some("bold"), &name, room as f32)
        };
        (name, String::new())
    } else {
        (String::new(), String::new())
    };
    b.push(&name, Some("bold"));
    b.push(" ", None);
    b.push(&label, Some("drgnx-agent-panel-subtle"));
    b.stop(
        env.width_px
            .saturating_sub(actions_w + px(env, 20.0))
            .max(1),
    );
    let r = b.pos();
    b.push(" Reject ", Some("drgnx-ui-button"));
    let r_end = b.pos();
    b.prop(
        r,
        r_end,
        "drgnx-agent-panel-action",
        json!(format!("card:reject:{path}:{n}")),
    );
    b.prop(r, r_end, "help-echo", json!("D: take the change back"));
    b.push(" ", None);
    let a = b.pos();
    b.push(" Accept ", Some("drgnx-ui-button"));
    let a_end = b.pos();
    b.prop(
        a,
        a_end,
        "drgnx-agent-panel-action",
        json!(format!("card:accept:{path}:{n}")),
    );
    b.prop(a, a_end, "help-echo", json!("a: keep the change"));
    let end = b.pos();
    b.prop(0, end, "drgnx-agent-panel-card", json!(["diff", path, n]));
    b.finish()
}

/// Hunk N of PATH as a card: the header over the hunk's lines, numbered (the new file's numbers, a removed line the old
/// file's), in the panel's added, removed and context faces, each cut to the room.
fn diff_card(
    i: &In,
    images: &mut Vec<(ImageId, String)>,
    path: &str,
    n: usize,
    total: usize,
    h: &Hunk,
) -> Vec<Row> {
    let env = i.env;
    let mut rows = vec![diff_header(
        i,
        images,
        path,
        n,
        total,
        h,
        format!("c:diff:{path}:{n}:h"),
    )];
    let (mut old, _) = range(&h.header, '-');
    let (mut new, _) = range(&h.header, '+');
    let body: Vec<&String> = h.lines.iter().take(MAX_LINES).collect();
    let count = body.len();
    for (k, l) in body.into_iter().enumerate() {
        let c = l.chars().next();
        let num = match c {
            Some('-') => {
                old += 1;
                old - 1
            }
            Some('+') => {
                new += 1;
                new - 1
            }
            _ => {
                old += 1;
                new += 1;
                new - 1
            }
        };
        let (sign, rest, face) = match c {
            Some('+') => ("+", &l[1..], "drgnx-agent-panel-added"),
            Some('-') => ("-", &l[1..], "drgnx-agent-panel-removed"),
            Some(' ') => (" ", &l[1..], "drgnx-agent-panel-context"),
            _ => (" ", l.as_str(), "drgnx-agent-panel-context"),
        };
        let mut b = RowBuilder::new(format!("c:diff:{path}:{n}:{k}"));
        b.push(" ", None);
        // the line number in the muted colour, the line's tint under it
        let gutter = b.pos();
        b.push(&format!("{num:4} "), Some("drgnx-text-muted"));
        let gutter_end = b.pos();
        b.face(gutter, gutter_end, face);
        // cut at the card's edge by the row fit, which measures the line in its font
        b.push(&format!("{sign}{}", cut(rest, MAX_CHARS)), Some(face));
        b.stop(env.width_px.saturating_sub(px(env, 12.0)));
        let end = b.pos();
        b.face(0, end, shape(count, k));
        b.prop(0, end, "drgnx-agent-panel-card", json!(["diff", path, n]));
        rows.push(b.finish());
    }
    rows
}

/// Request P as a card: what the agent asks, one line ringed in the attention colour, and under it Allow, Always and
/// Deny.
fn perm_card(i: &In, images: &mut Vec<(ImageId, String)>, p: &Permission) -> Vec<Row> {
    let env = i.env;
    let id = id_of(&p.id);
    let title = p.title.as_deref().unwrap_or("the agent asks");
    let card = json!(["perm", id]);
    let mut b = RowBuilder::new(format!("c:perm:{id}:0"));
    b.push(" ", None);
    icon(
        &mut b,
        images,
        "shield",
        "⛨",
        px(env, 16.0),
        "drgnx-agent-panel-perm-head",
    );
    b.push(&format!(" {}?", one_line(title, 70)), None);
    b.stop(env.width_px.saturating_sub(px(env, 12.0)));
    let end = b.pos();
    b.face(0, end, "drgnx-agent-panel-perm-head");
    b.face(0, end, "drgnx-card-single");
    b.prop(0, end, "drgnx-agent-panel-card", card.clone());
    let head = b.finish();
    let mut b = RowBuilder::new(format!("c:perm:{id}:1"));
    b.push(" ", None);
    for (k, (label, face, action, help)) in [
        (
            " Allow ",
            "drgnx-ui-button-primary",
            "allow",
            "RET: allow it once",
        ),
        (
            " Always ",
            "drgnx-ui-button",
            "always",
            "A: allow it from now on",
        ),
        (" Deny ", "drgnx-ui-button", "deny", "D: deny it"),
    ]
    .into_iter()
    .enumerate()
    {
        if k > 0 {
            b.push(" ", None);
        }
        let s = b.pos();
        b.push(label, Some(face));
        let e = b.pos();
        b.prop(
            s,
            e,
            "drgnx-agent-panel-action",
            json!(format!("card:{action}:{id}")),
        );
        b.prop(s, e, "help-echo", Value::String(help.to_owned()));
    }
    let end = b.pos();
    b.prop(0, end, "drgnx-agent-panel-card", card);
    vec![head, b.finish()]
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
        Some("drgnx-agent-panel-subtle"),
    );
    b.stop(env.width_px.saturating_sub(px(env, 12.0)));
    let end = b.pos();
    b.face(0, end, "drgnx-card-single");
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
            out.extend(diff_card(i, &mut images, path, n, hunks.len(), h));
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
