//! The stop timeline's strip (spec §19.2), as hub rows (`drgnx_rows`; Lisp only inserts them): a head row ("Run 4 ·
//! 3 stops · 58 probe hits"), the lane of stops (numbered, one glyph per reason: a breakpoint, a step, an exception;
//! the current one ringed) and one lane per probe with its values as a sparkline and the last value.

use drgnx_rows::{Row, RowBuilder};
use serde_json::{Value, json};

/// The most values a probe's sparkline shows (the newest).
pub const SPARK: usize = 24;
const BARS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

/// VALUES (a probe's hits' text) as a sparkline of the numeric ones, the newest SPARK; empty when none is a number.
pub fn sparkline(values: &[&str]) -> String {
    let nums: Vec<f64> = values
        .iter()
        .filter_map(|v| v.trim().trim_matches(['\'', '"']).parse::<f64>().ok())
        .filter(|n| n.is_finite())
        .collect();
    let nums = &nums[nums.len().saturating_sub(SPARK)..];
    let (lo, hi) = nums
        .iter()
        .fold((f64::INFINITY, f64::NEG_INFINITY), |(l, h), n| {
            (l.min(*n), h.max(*n))
        });
    nums.iter()
        .map(|n| {
            if hi <= lo {
                BARS[3]
            } else {
                let i = ((n - lo) / (hi - lo) * 7.0).round() as usize;
                BARS[i.min(7)]
            }
        })
        .collect()
}

/// A stop's glyph and face by its reason.
fn glyph(reason: &str) -> (&'static str, &'static str) {
    match reason {
        "breakpoint" | "function breakpoint" | "data breakpoint" => ("●", "drgnx-debug-breakpoint"),
        "exception" => ("▲", "drgnx-debug-exception"),
        "step" | "goto" => ("·", "drgnx-debug-timeline-step"),
        _ => ("○", "drgnx-debug-timeline-step"),
    }
}

/// The strip's rows for VIEW (`Records::get`'s answer), FROM the page's first stop's number, with stop CURRENT (an
/// `index`) ringed.
pub fn rows(view: &Value, from: usize, current: Option<u64>) -> Vec<Row> {
    let run = &view["run"];
    let total = view["total"].as_u64().unwrap_or(0);
    let mut head = RowBuilder::new("head");
    head.push(
        &format!("Run {}", run["n"].as_u64().unwrap_or(0)),
        Some("drgnx-debug-timeline-head"),
    );
    let mut facts = vec![
        format!("{total} stop{}", if total == 1 { "" } else { "s" }),
        format!(
            "{} probe hit{}",
            run["hits"],
            if run["hits"] == 1 { "" } else { "s" }
        ),
    ];
    let thinned = run["thinned"].as_u64().unwrap_or(0) + run["dropped"].as_u64().unwrap_or(0);
    if thinned > 0 {
        facts.push(format!("{thinned} thinned"));
    }
    if run["stops_to_probe"] == true {
        facts.push("probes stop and resume the program".into());
    }
    if run["ended"].is_null() {
        facts.push("recording".into());
    }
    head.push(
        &format!(" · {}", facts.join(" · ")),
        Some("drgnx-debug-timeline-dim"),
    );
    let mut out = vec![head.finish()];

    let mut lane = RowBuilder::new("stops");
    for (k, s) in view["stops"].as_array().into_iter().flatten().enumerate() {
        let index = s["index"].as_u64().unwrap_or(0);
        let (g, face) = glyph(s["reason"].as_str().unwrap_or_default());
        let ring = current == Some(index);
        if k > 0 {
            lane.push(" ", None);
        }
        let at = lane.pos();
        if ring {
            lane.push("(", Some("drgnx-debug-timeline-current"));
        }
        lane.push(g, Some(face));
        lane.push(
            &(from + k + 1).to_string(),
            Some(if ring {
                "drgnx-debug-timeline-current"
            } else {
                "drgnx-debug-timeline-dim"
            }),
        );
        if ring {
            lane.push(")", Some("drgnx-debug-timeline-current"));
        }
        let end = lane.pos();
        lane.prop(at, end, "drgnx-debug-stop", json!(index));
        let help = format!(
            "{} {} at {}:{}",
            s["reason"].as_str().unwrap_or_default(),
            from + k + 1,
            s["path"]
                .as_str()
                .unwrap_or_default()
                .rsplit('/')
                .next()
                .unwrap_or_default(),
            s["line"]
        );
        lane.prop(at, end, "help-echo", json!(help));
    }
    out.push(lane.finish());

    for l in view["lanes"].as_array().into_iter().flatten() {
        let probe = l["probe"].as_str().unwrap_or_default();
        let values: Vec<&str> = l["hits"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|h| h["value"].as_str())
            .collect();
        let mut r = RowBuilder::new(format!("probe:{probe}"));
        let name_end = {
            r.push("◉ ", Some("drgnx-debug-probe"));
            r.push(
                l["expr"].as_str().unwrap_or(probe),
                Some("drgnx-debug-timeline-head"),
            );
            r.pos()
        };
        r.prop(0, name_end, "drgnx-debug-probe", json!(probe));
        let spark = sparkline(&values);
        if !spark.is_empty() {
            r.push("  ", None);
            r.push(&spark, Some("drgnx-debug-probe"));
        }
        let last = values.last().copied().unwrap_or("no hits");
        let last: String = last.chars().take(60).collect();
        r.push(&format!("  {last}"), Some("drgnx-debug-timeline-dim"));
        r.push(
            &format!(
                "  {} hit{}",
                values.len(),
                if values.len() == 1 { "" } else { "s" }
            ),
            Some("drgnx-debug-timeline-dim"),
        );
        out.push(r.finish());
    }
    out
}
