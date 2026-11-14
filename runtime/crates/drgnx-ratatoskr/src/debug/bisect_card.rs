//! The bisect card's rows (docs/develop/hub.md "Rows"): the hub keeps each bisect's state (its events merged) and
//! sends the card with every `debug-bisect` event; the editor only inserts it.  A head (the states, the estimate, what
//! it does now), a dot per state, then the result (the first bad state, who made it, its step and decision; the
//! skipped and flaky states) with its actions, or why it stopped, and the hunks narrowing kept.

use drgnx_rows::{Row, RowBuilder};
use serde_json::{Value, json};

/// The longest hunk line a card shows, in characters.
const HUNK_LINE: usize = 80;

/// STATE with EVENT's fields put over it (the card's state).
pub fn merge(state: &mut Value, event: &Value) {
    if !state.is_object() {
        *state = json!({});
    }
    if let (Some(s), Some(e)) = (state.as_object_mut(), event.as_object()) {
        for (k, v) in e {
            if k == "dots" && v.as_array().is_some_and(Vec::is_empty) {
                continue;
            }
            s.insert(k.clone(), v.clone());
        }
    }
}

fn plural(n: u64, one: &str) -> String {
    format!("{n} {one}{}", if n == 1 { "" } else { "s" })
}

/// Who made a state, in words: a commit's author, "you", an agent, a run.
pub fn author(a: &Value) -> Option<String> {
    if let Some(n) = a["name"].as_str() {
        return Some(n.to_owned());
    }
    if !a["user"].is_null() {
        return Some("you".into());
    }
    if let Some(r) = a["agent"].as_str().or_else(|| a["profile"].as_str()) {
        return Some(r.to_owned());
    }
    a["run"].as_str().map(|r| format!("the agent of {r}"))
}

fn action(r: &mut RowBuilder, label: &str, act: &str, help: &str) {
    let at = r.pos();
    r.push(label, Some("drgnx-chip-accent"));
    let end = r.pos();
    r.prop(at, end, "drgnx-debug-bisect-action", json!(act));
    r.prop(at, end, "help-echo", json!(help));
    r.push("  ", None);
}

/// The card of the bisect state STATE (its events merged).
pub fn rows(state: &Value) -> Vec<Row> {
    let mut out = Vec::new();
    let est = &state["estimate"];
    let mut head = RowBuilder::new("head");
    head.push("Bisect", Some("drgnx-debug-timeline-head"));
    let doing = match state["state"].as_str().unwrap_or_default() {
        "checking-good" => "checking the good state".to_owned(),
        "running" => "running".to_owned(),
        "found" => "found".to_owned(),
        "cancelled" => "cancelled".to_owned(),
        "needs-good" => "the good state fails".to_owned(),
        "failed" => "failed".to_owned(),
        "narrowing" => format!(
            "narrowing {}",
            plural(state["hunks"].as_u64().unwrap_or(0), "hunk")
        ),
        "narrowed" => "narrowed".to_owned(),
        s => s.to_owned(),
    };
    head.push(
        &format!(
            " · {} · about {} in {} · {doing}",
            plural(est["states"].as_u64().unwrap_or(0), "state"),
            plural(est["runs"].as_u64().unwrap_or(0), "run"),
            plural(est["slots"].as_u64().unwrap_or(1), "slot"),
        ),
        Some("drgnx-debug-timeline-dim"),
    );
    out.push(head.finish());

    let dots = state["dots"].as_array().cloned().unwrap_or_default();
    if !dots.is_empty() {
        let mut lane = RowBuilder::new("dots");
        let bad = state["result"]["first_bad"]["id"].as_str();
        for (k, d) in dots.iter().enumerate() {
            if k > 0 {
                lane.push(" ", None);
            }
            let (g, face) = match d["outcome"].as_str().unwrap_or_default() {
                "good" => ("●", "drgnx-debug-bisect-good"),
                "bad" => ("✕", "drgnx-debug-bisect-bad"),
                "skip" => ("◌", "drgnx-debug-bisect-skip"),
                _ => ("·", "drgnx-debug-timeline-step"),
            };
            let at = lane.pos();
            let first = bad.is_some() && d["id"].as_str() == bad;
            lane.push(
                g,
                Some(if first {
                    "drgnx-debug-timeline-current"
                } else {
                    face
                }),
            );
            let end = lane.pos();
            lane.prop(
                at,
                end,
                "help-echo",
                json!(d["id"].as_str().unwrap_or_default()),
            );
        }
        out.push(lane.finish());
    }

    let r = &state["result"];
    if r.is_object() {
        let fb = &r["first_bad"];
        let mut line = RowBuilder::new("first-bad");
        line.push("First bad: ", Some("drgnx-debug-timeline-head"));
        line.push(fb["label"].as_str().unwrap_or_default(), None);
        if let Some(a) = author(&fb["author"]) {
            line.push(&format!(" · {a}"), Some("drgnx-debug-timeline-dim"));
        }
        out.push(line.finish());
        let mut facts = Vec::new();
        if let Some(s) = fb["step"].as_str() {
            facts.push(format!("step {s}"));
        }
        if let Some(d) = fb["decision"].as_str() {
            facts.push(format!("decision {d}"));
        }
        facts.push(fb["kind"].as_str().unwrap_or_default().replace('_', " "));
        let mut why = RowBuilder::new("why");
        why.push(&facts.join(" · "), Some("drgnx-debug-timeline-dim"));
        out.push(why.finish());
        let skipped = r["skipped"].as_array().map_or(0, Vec::len) as u64;
        if skipped > 0 {
            let mut s = RowBuilder::new("skipped");
            s.push(
                &format!(
                    "Or one of the {} before it, which could not be judged",
                    plural(skipped, "state")
                ),
                Some("drgnx-status-warn"),
            );
            out.push(s.finish());
        }
        for f in r["flaky"].as_array().into_iter().flatten() {
            let mut s = RowBuilder::new(format!("flaky:{}", f.as_str().unwrap_or_default()));
            s.push(
                &format!(
                    "Flaky: the two runs of {} disagreed",
                    f.as_str().unwrap_or_default()
                ),
                Some("drgnx-status-warn"),
            );
            out.push(s.finish());
        }
        let mut acts = RowBuilder::new("actions");
        action(
            &mut acts,
            "Show Step",
            "show",
            "the change the first bad state made",
        );
        if fb["step"].is_string() && fb["session"].is_string() {
            action(
                &mut acts,
                "Revert Step",
                "revert",
                "the revert card of this step (nothing changes until Apply)",
            );
            action(
                &mut acts,
                "Ask the Agent",
                "ask",
                "tell the agent that made it what broke",
            );
        }
        if state["state"] == "found" {
            action(
                &mut acts,
                "Narrow",
                "narrow",
                "the hunks of the change that make it fail",
            );
        }
        out.push(acts.finish());
    }
    if let Some(why) = state["why"].as_str() {
        let mut s = RowBuilder::new("stopped");
        let what = match state["state"].as_str().unwrap_or_default() {
            "needs-good" => format!("{why}: pick an earlier good state"),
            _ => why.to_owned(),
        };
        s.push(&what, Some("drgnx-status-fail"));
        out.push(s.finish());
    }
    if state["state"] == "narrowed" {
        let hunks = state["hunks"].as_array().cloned().unwrap_or_default();
        let mut s = RowBuilder::new("narrowed");
        s.push(
            &format!(
                "It fails with {} of the {}:",
                plural(hunks.len() as u64, "hunk"),
                state["of"].as_u64().unwrap_or(0)
            ),
            Some("drgnx-debug-timeline-head"),
        );
        out.push(s.finish());
        for (k, h) in hunks.iter().enumerate() {
            let mut s = RowBuilder::new(format!("hunk:{k}"));
            s.push(
                &format!("  {}", h["path"].as_str().unwrap_or_default()),
                None,
            );
            let first: String = h["hunk"]
                .as_str()
                .unwrap_or_default()
                .lines()
                .find(|l| l.starts_with('+') || l.starts_with('-'))
                .unwrap_or_default()
                .chars()
                .take(HUNK_LINE)
                .collect();
            s.push(&format!("  {first}"), Some("drgnx-debug-timeline-dim"));
            out.push(s.finish());
        }
    }
    if matches!(
        state["state"].as_str(),
        Some("checking-good" | "running" | "narrowing")
    ) {
        let mut acts = RowBuilder::new("cancel");
        action(
            &mut acts,
            "Cancel",
            "cancel",
            "stop the bisect and its runs",
        );
        out.push(acts.finish());
    }
    out
}
