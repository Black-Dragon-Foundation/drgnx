//! The trail's and the Timeline's models for the editor's replica (docs/develop/hub.md, "The native view model"):
//! steps (and a trail's conclusions) as nodes with the links the keys follow, in the rows' order. Pure: the steps in,
//! the model out.
//!
//! - A trail: each step, then the conclusions stamped on it, then those on no step shown; up and left go to the row
//!   before, down and right to the row after. A conclusion `rests-on` its steps (the chain kind: selecting one lights
//!   them). The list `steps` holds [`WINDOW`] steps, a window of the session's when there are more: the last ones, or
//!   where the editor asked (`view/window`).
//! - A Timeline: a lane node per session (`lane:SID`), then its steps (`step:SID:SEQ`); left and right run along the
//!   lane (left of the first step: its lane), up and down to the step of the lane above or below nearest in time
//!   (wrapping). Lists: `lanes`, `lasts` (each lane's last step, else the lane: where the keys start) and `near` (the
//!   lanes the map's selection lights, `Map::near`).

use crate::view::model::Doc;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use vegvisir::trail::{self, Conclusion, Lane, Step};

/// The steps a trail's model holds; more are a window of the session's.
pub(crate) const WINDOW: usize = 500;

/// A trail step's node id.
pub(crate) fn step_id(id: i64) -> String {
    format!("step:{id}")
}

/// A conclusion's node id.
pub(crate) fn conc_id(n: u32) -> String {
    format!("conc:{n}")
}

/// A Timeline lane's node id.
pub(crate) fn lane_id(session: &str) -> String {
    format!("lane:{session}")
}

/// A Timeline step's node id.
pub(crate) fn lane_step_id(session: &str, seq: u64) -> String {
    format!("step:{session}:{seq}")
}

fn descriptor(lists: &[&str], chain: &[&str], start: &str) -> Value {
    json!({
        "scheme": "links",
        "chain_kinds": chain,
        "match_fields": ["label"],
        "lists": lists,
        "classes": ["selected", "match", "chain", "lit", "dim"],
        "flags": [],
        "forms": [{"name": "rows"}],
        "start": start,
    })
}

/// What opening a step needs: its label, seq, class, tool and detail (and, in a Timeline, its session).
fn step_fields(s: &Step, session: Option<&str>) -> Vec<Value> {
    let mut f = vec![
        json!(["label", trail::title(s)]),
        json!(["seq", s.seq]),
        json!(["class", s.class]),
    ];
    if let Some(t) = &s.tool {
        f.push(json!(["tool", t]));
    }
    let d = &s.detail;
    for (name, v) in [
        ("detail-kind", &d.kind),
        ("path", &d.path),
        ("query", &d.query),
        ("url", &d.url),
    ] {
        if let Some(v) = v {
            f.push(json!([name, v]));
        }
    }
    if let Some(l) = d.line_start {
        f.push(json!(["line", l]));
    }
    if let Some(sid) = session {
        f.push(json!(["session", sid]));
    }
    f
}

fn node(id: &str, kind: &str, fields: Vec<Value>, links: [(&str, Option<&String>); 4]) -> Value {
    let mut nav = serde_json::Map::new();
    for (name, to) in links {
        if let Some(to) = to {
            nav.insert(name.into(), json!(to));
        }
    }
    json!({"id": id, "kind": kind, "flags": 0, "nav": nav, "fields": fields})
}

/// A trail's model: STEPS (the last [`WINDOW`] of them by seq) of the session's TOTAL, and CONCS. Steps that are not
/// all of the session's are a window of them in `steps`, from the first one's seq.
pub(crate) fn trail_doc(steps: &[Step], concs: &[Conclusion], total: usize) -> Doc {
    let mut steps: Vec<&Step> = steps.iter().collect();
    steps.sort_by_key(|s| (s.seq, s.id));
    let steps = &steps[steps.len().saturating_sub(WINDOW)..];
    let mut concs: Vec<&Conclusion> = concs.iter().collect();
    concs.sort_by_key(|c| c.n);
    let shown: BTreeSet<i64> = steps.iter().map(|s| s.id).collect();
    // the rows' order, as `vegvisir::trail::trail_rows` draws them
    let mut order: Vec<(String, &str, Vec<Value>)> = Vec::new();
    let conc_node = |c: &Conclusion| {
        (
            conc_id(c.n),
            "conclusion",
            vec![
                json!(["label", c.text]),
                json!(["n", c.n]),
                json!(["conclusion-kind", c.kind]),
            ],
        )
    };
    for s in steps {
        order.push((step_id(s.id), "step", step_fields(s, None)));
        order.extend(
            concs
                .iter()
                .filter(|c| c.step == Some(s.id))
                .map(|c| conc_node(c)),
        );
    }
    order.extend(
        concs
            .iter()
            .filter(|c| !c.step.is_some_and(|id| shown.contains(&id)))
            .map(|c| conc_node(c)),
    );
    let mut d = Doc {
        descriptor: descriptor(&["steps"], &["rests-on"], "steps"),
        ..Doc::default()
    };
    for (i, (id, kind, fields)) in order.iter().enumerate() {
        let before = i.checked_sub(1).map(|j| &order[j].0);
        let after = order.get(i + 1).map(|o| &o.0);
        let links = [
            ("up", before),
            ("left", before),
            ("down", after),
            ("right", after),
        ];
        d.nodes
            .insert(id.clone(), node(id, kind, fields.clone(), links));
    }
    for c in &concs {
        for s in c.rests_on.iter().filter(|s| shown.contains(s)) {
            d.edges
                .insert((conc_id(c.n), step_id(*s), "rests-on".into()));
        }
    }
    d.lists.insert(
        "steps".into(),
        steps.iter().map(|s| step_id(s.id)).collect(),
    );
    // seq counts a session's steps from 1: the window starts after the ones before its first
    let from = steps
        .first()
        .map_or(0, |s| s.seq.saturating_sub(1) as usize);
    let total = total.max(from + steps.len());
    if from > 0 || from + steps.len() < total {
        d.windows.insert("steps".into(), (total, from));
    }
    d
}

/// The step of STEPS (sorted) nearest in time to AT, else none.
fn nearest(steps: &[&Step], at: Option<f64>) -> Option<u64> {
    let at = at?;
    steps
        .iter()
        .min_by(|a, b| (a.start - at).abs().total_cmp(&(b.start - at).abs()))
        .map(|s| s.seq)
}

/// A Timeline's model: a lane per LANES (in their order), the lanes of the sessions NEAR lit.
pub(crate) fn timeline_doc(lanes: &[Lane], near: &[String]) -> Doc {
    let sorted: Vec<Vec<&Step>> = lanes
        .iter()
        .map(|l| {
            let mut v: Vec<&Step> = l.steps.iter().collect();
            v.sort_by_key(|s| (s.seq, s.id));
            v
        })
        .collect();
    let n = lanes.len();
    let mut d = Doc {
        descriptor: descriptor(&["lanes", "lasts", "near"], &[], "lasts"),
        ..Doc::default()
    };
    let lane_ids: Vec<String> = lanes.iter().map(|l| lane_id(&l.id)).collect();
    let lasts: Vec<String> = lanes
        .iter()
        .zip(&sorted)
        .map(|(l, s)| {
            s.last()
                .map_or_else(|| lane_id(&l.id), |s| lane_step_id(&l.id, s.seq))
        })
        .collect();
    // the lane above and below lane I, wrapping; none with one lane
    let other =
        |i: usize, up: bool| (n > 1).then(|| if up { (i + n - 1) % n } else { (i + 1) % n });
    // the node of lane J nearest in time to AT: its step, else the lane
    let across = |j: usize, at: Option<f64>| match nearest(&sorted[j], at) {
        Some(seq) => lane_step_id(&lanes[j].id, seq),
        None => lane_ids[j].clone(),
    };
    for (i, lane) in lanes.iter().enumerate() {
        let up = other(i, true).map(|j| lane_ids[j].clone());
        let down = other(i, false).map(|j| lane_ids[j].clone());
        d.nodes.insert(
            lane_ids[i].clone(),
            node(
                &lane_ids[i],
                "lane",
                vec![json!(["label", lane.label]), json!(["session", lane.id])],
                [
                    ("up", up.as_ref()),
                    ("down", down.as_ref()),
                    ("right", Some(&lasts[i]).filter(|l| **l != lane_ids[i])),
                    ("left", None),
                ],
            ),
        );
        let steps = &sorted[i];
        for (k, s) in steps.iter().enumerate() {
            let id = lane_step_id(&lane.id, s.seq);
            let left = Some(k.checked_sub(1).map_or_else(
                || lane_ids[i].clone(),
                |p| lane_step_id(&lane.id, steps[p].seq),
            ));
            let right = steps.get(k + 1).map(|r| lane_step_id(&lane.id, r.seq));
            let up = other(i, true).map(|j| across(j, Some(s.start)));
            let down = other(i, false).map(|j| across(j, Some(s.start)));
            d.nodes.insert(
                id.clone(),
                node(
                    &id,
                    "step",
                    step_fields(s, Some(&lane.id)),
                    [
                        ("left", left.as_ref()),
                        ("right", right.as_ref()),
                        ("up", up.as_ref()),
                        ("down", down.as_ref()),
                    ],
                ),
            );
        }
    }
    d.lists.insert(
        "near".into(),
        lanes
            .iter()
            .filter(|l| near.contains(&l.id))
            .map(|l| lane_id(&l.id))
            .collect(),
    );
    d.lists.insert("lanes".into(), lane_ids);
    d.lists.insert("lasts".into(), lasts);
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    use vegvisir::trail::Detail;

    fn step(id: i64, start: f64) -> Step {
        Step {
            id,
            seq: id as u64,
            class: "tool".into(),
            tool: Some("Read".into()),
            detail: Detail {
                kind: Some("read".into()),
                path: Some(format!("src/f{id}.rs")),
                line_start: Some(3),
                line_end: None,
                query: None,
                url: None,
                title: None,
            },
            start,
            end: Some(start + 1.0),
        }
    }

    fn conc(n: u32, step: i64, rests_on: Vec<i64>) -> Conclusion {
        Conclusion {
            n,
            kind: "finding".into(),
            text: format!("c{n}"),
            step: Some(step),
            rests_on,
            unmatched: Vec::new(),
        }
    }

    /// [D] A trail past 500 steps holds the last 500, as a window of the session's: `steps` says total 600 from 100,
    /// in the wire's list too. A conclusion sits after its step in the links and rests on the shown steps only; one
    /// on a step not shown comes last. 400 steps are no window.
    #[test]
    fn trail_model_windows_past_500() {
        let steps: Vec<Step> = (1..=600).map(|i| step(i, i as f64)).collect();
        let concs = vec![conc(1, 550, vec![50, 549, 550]), conc(2, 50, vec![50])];
        let d = trail_doc(&steps, &concs, 600);
        let list = &d.lists["steps"];
        assert_eq!(list.len(), WINDOW);
        assert_eq!(list[0], "step:101");
        assert_eq!(list[WINDOW - 1], "step:600");
        assert_eq!(d.windows["steps"], (600, 100));
        let reset = d.reset();
        let wire = &reset["reset"]["lists"][0];
        assert_eq!(
            (wire["total"].as_u64(), wire["from"].as_u64()),
            (Some(600), Some(100))
        );
        assert!(!d.nodes.contains_key("step:100"));
        assert_eq!(d.nodes["step:550"]["nav"]["down"], "conc:1");
        assert_eq!(d.nodes["conc:1"]["nav"]["up"], "step:550");
        assert_eq!(d.nodes["conc:1"]["nav"]["down"], "step:551");
        assert_eq!(d.nodes["step:600"]["nav"]["down"], "conc:2");
        assert!(d.nodes["step:101"]["nav"].get("up").is_none());
        let rests: Vec<&str> = d
            .edges
            .iter()
            .filter(|e| e.0 == "conc:1")
            .map(|e| e.1.as_str())
            .collect();
        assert_eq!(rests, ["step:549", "step:550"]);
        let fields = d.nodes["step:550"]["fields"].as_array().expect("fields");
        assert!(
            fields.contains(&json!(["path", "src/f550.rs"])),
            "{fields:?}"
        );
        let short = trail_doc(&steps[..400], &[], 400);
        assert!(short.windows.is_empty());
        assert_eq!(short.lists["steps"].len(), 400);
    }

    /// [D] A trail paged to its start (`view/window` from 0): the first 500 of 2,000 steps, a window from 0 of 2000;
    /// the first row has no row above.
    #[test]
    fn trail_model_paged_to_the_start() {
        let steps: Vec<Step> = (1..=500).map(|i| step(i, i as f64)).collect();
        let d = trail_doc(&steps, &[], 2000);
        assert_eq!(d.windows["steps"], (2000, 0));
        assert_eq!(d.lists["steps"][0], "step:1");
        assert!(d.nodes["step:1"]["nav"].get("up").is_none());
    }

    /// [D] A Timeline's links: along a lane by seq (left of the first step: the lane), across to the nearest step in
    /// time of the lane above or below, wrapping; `lasts` holds each lane's last step (the lane when it has none) and
    /// `near` the lanes of the sessions given.
    #[test]
    fn timeline_model_links_lanes() {
        let lanes = vec![
            Lane {
                id: "a".into(),
                label: "alpha".into(),
                steps: vec![step(2, 10.0), step(1, 0.0)],
            },
            Lane {
                id: "b".into(),
                label: "beta".into(),
                steps: vec![step(1, 9.0)],
            },
            Lane {
                id: "c".into(),
                label: "gamma".into(),
                steps: Vec::new(),
            },
        ];
        let d = timeline_doc(&lanes, &["b".to_string()]);
        let nav = |id: &str, link: &str| d.nodes[id]["nav"][link].as_str().map(str::to_owned);
        assert_eq!(nav("step:a:1", "right").as_deref(), Some("step:a:2"));
        assert_eq!(nav("step:a:1", "left").as_deref(), Some("lane:a"));
        assert_eq!(nav("step:a:2", "down").as_deref(), Some("step:b:1"));
        assert_eq!(nav("step:b:1", "up").as_deref(), Some("step:a:2"));
        assert_eq!(nav("step:b:1", "down").as_deref(), Some("lane:c"));
        assert_eq!(nav("step:a:1", "up").as_deref(), Some("lane:c"), "wraps");
        assert_eq!(nav("lane:a", "right").as_deref(), Some("step:a:2"));
        assert_eq!(nav("lane:c", "right"), None);
        assert_eq!(d.lists["lanes"], ["lane:a", "lane:b", "lane:c"]);
        assert_eq!(d.lists["lasts"], ["step:a:2", "step:b:1", "lane:c"]);
        assert_eq!(d.lists["near"], ["lane:b"]);
        assert_eq!(d.descriptor["start"], "lasts");
    }
}
