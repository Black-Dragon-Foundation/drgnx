//! Probes: the marker per adapter and its parse, "Probe the result"'s line, the rate caps, the project's table.
use super::probes::{self, Lang, Op, Probes, Rate};
use serde_json::json;
use std::time::Duration;

#[test]
fn the_marker_carries_the_probe_the_thread_and_the_value() {
    assert_eq!(
        probes::marker("p3", "tid()", "x + 1"),
        "\u{1e}drgnx:p3:{tid()}:{x + 1}"
    );
    // no thread expression: the field stays, empty
    assert_eq!(probes::marker("p3", "", "x"), "\u{1e}drgnx:p3::{x}");
}

#[test]
fn each_adapter_gets_its_own_thread_expression_and_value_text() {
    assert_eq!(
        probes::log_message("debugpy", "p1", "shortfall"),
        "\u{1e}drgnx:p1:{__import__('threading').get_ident()}:{repr(shortfall)}"
    );
    assert_eq!(
        probes::thread_expr("python"),
        "__import__('threading').get_ident()"
    );
    assert_eq!(
        probes::log_message("pwa-node", "p1", "order.total"),
        "\u{1e}drgnx:p1::{order.total}"
    );
    assert_eq!(probes::log_message("go", "p2", "n"), "\u{1e}drgnx:p2::{n}");
    assert_eq!(probes::thread_expr("lldb-dap"), "");
}

#[test]
fn a_hit_parses_back_and_a_value_may_hold_colons() {
    assert_eq!(
        probes::parse("\u{1e}drgnx:p1:140213:{'a': 1}\n"),
        Some(("p1".into(), "140213".into(), "{'a': 1}".into()))
    );
    assert_eq!(
        probes::parse("\u{1e}drgnx:p7::16\r\n"),
        Some(("p7".into(), String::new(), "16".into()))
    );
    assert_eq!(probes::parse("drgnx:p1:1:2"), None);
    assert_eq!(probes::parse("\u{1e}drgnx:p 1:1:2"), None);
    assert_eq!(probes::parse("\u{1e}drgnx:p1"), None);
}

#[test]
fn hits_are_split_from_the_console_text() {
    let (hits, rest) = probes::split("before\n\u{1e}drgnx:p1:9:3\n\u{1e}drgnx:p1:9:4\nafter\n");
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[1].2, "4");
    assert_eq!(rest, "before\nafter\n");
    let (hits, rest) = probes::split("plain output\n");
    assert!(hits.is_empty());
    assert_eq!(rest, "plain output\n");
}

#[test]
fn probe_the_result_goes_on_the_next_line_that_runs() {
    let py = "def f(item):\n    shortfall = (item.min\n                 - item.qty)  # (\n\n    # a comment\n    log(shortfall)\n";
    // line 2 assigns over two lines: the probe goes past the blank line and the comment
    assert_eq!(probes::next_line(py, 2, Lang::Python), Some(6));
    let js = "let a = f(\"(\", 1);\n// note\n}\nreturn a;\n";
    assert_eq!(probes::next_line(js, 1, Lang::Js), Some(4));
    // a continuation backslash
    assert_eq!(
        probes::next_line("x = 1 + \\\n    2\ny = x\n", 1, Lang::Python),
        Some(3)
    );
    // nothing runs after the last line
    assert_eq!(probes::next_line("x = 1\n", 1, Lang::Python), None);
    assert_eq!(probes::next_line("x = 1\n", 9, Lang::Python), None);
}

#[test]
fn the_rate_cap_thins_per_second_and_a_fork_keeps_every_hit() {
    assert_eq!(probes::cap("debugpy"), 2000);
    assert_eq!(probes::cap("pwa-node"), 2000);
    assert_eq!(probes::cap("go"), 200);
    assert_eq!(probes::cap("lldb-dap"), 200);
    assert!(probes::stops_to_probe("go") && !probes::stops_to_probe("debugpy"));
    let mut r = Rate::new(Some(3));
    let kept: Vec<bool> = [0, 10, 20, 30, 40, 1000, 1001]
        .into_iter()
        .map(|ms| r.admit(Duration::from_millis(ms)))
        .collect();
    assert_eq!(kept, [true, true, true, false, false, true, true]);
    assert_eq!(r.thinned, 2);
    let mut fork = Rate::new(None);
    assert!((0..10_000).all(|_| fork.admit(Duration::ZERO)));
    assert_eq!(fork.thinned, 0);
}

#[tokio::test]
async fn the_table_adds_places_edits_and_saves_probes() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("p.json");
    let mut p = Probes::open(Some(f.clone()));
    let (path, id) = p
        .apply(Op::Result {
            path: "/p/stock.py".into(),
            line: 1,
            expr: "shortfall".into(),
            text: "shortfall = 3\n\nprint(shortfall)\n".into(),
            lang: Lang::Python,
        })
        .unwrap();
    assert_eq!((path.as_str(), id.as_deref()), ("/p/stock.py", Some("p1")));
    assert_eq!(p.list()[0].line, 3);
    p.apply(Op::Add {
        path: "/p/stock.py".into(),
        line: 5,
        expr: "n".into(),
    })
    .unwrap();
    p.apply(Op::Edit {
        id: "p2".into(),
        expr: None,
        enabled: Some(false),
        line: None,
    })
    .unwrap();
    assert!(p.apply(Op::Remove { id: "p9".into() }).is_err());
    p.disk().unwrap().written().await;
    // saved: the next open has them
    let again = Probes::open(Some(f));
    assert_eq!(again.list().len(), 2);
    assert!(!again.list()[1].enabled);
    let caps = json!({"supportsLogPoints": true});
    // the disabled probe is not sent; a line the user's breakpoint takes is not either
    assert_eq!(
        again.source_bps("/p/stock.py", "debugpy", &caps, &[]).len(),
        1
    );
    assert!(
        again
            .source_bps("/p/stock.py", "debugpy", &caps, &[3])
            .is_empty()
    );
    // no logpoints: no probes at all
    assert!(
        again
            .source_bps("/p/stock.py", "debugpy", &json!({}), &[])
            .is_empty()
    );
}

#[test]
fn a_probe_is_left_out_where_the_adapter_has_no_logpoints() {
    let bps = vec![
        json!({"line": 3}),
        json!({"line": 4, "logMessage": probes::marker("p1", "", "x")}),
        json!({"line": 5, "logMessage": "plain {x}"}),
    ];
    let fitted = super::breakpoints::fit(&bps, &json!({}));
    // the plain logpoint loses its message (as before); the probe goes, it would stop the program
    assert_eq!(fitted, vec![json!({"line": 3}), json!({"line": 5})]);
    assert_eq!(
        super::breakpoints::fit(&bps, &json!({"supportsLogPoints": true})).len(),
        3
    );
}

#[test]
fn a_sparkline_scales_the_numeric_values() {
    use super::strip::sparkline;
    assert_eq!(sparkline(&["1", "5", "9"]), "▁▅█");
    // equal values sit mid-height; text values are left out
    assert_eq!(sparkline(&["3", "'x'", "3"]), "▄▄");
    assert_eq!(sparkline(&["'a'", "None"]), "");
    let many: Vec<String> = (0..100).map(|i| i.to_string()).collect();
    let refs: Vec<&str> = many.iter().map(String::as_str).collect();
    assert_eq!(sparkline(&refs).chars().count(), super::strip::SPARK);
}

#[test]
fn the_strip_is_a_head_the_stops_and_a_lane_per_probe() {
    use super::strip::rows;
    let view = json!({
        "run": {"n": 4, "hits": 3, "thinned": 0, "dropped": 0, "stops_to_probe": false, "ended": 1.0},
        "total": 3,
        "stops": [
            {"index": 3, "reason": "breakpoint", "path": "/p/stock.py", "line": 20},
            {"index": 4, "reason": "step", "path": "/p/stock.py", "line": 21},
            {"index": 9, "reason": "exception", "path": "/p/stock.py", "line": 24}
        ],
        "lanes": [{"probe": "p1", "expr": "shortfall", "hits": [{"value": "12"}, {"value": "16"}, {"value": "11"}]}]
    });
    let r = rows(&view, 0, Some(4));
    assert_eq!(r.len(), 3);
    let text = |i: usize| {
        serde_json::to_value(&r[i]).unwrap()["text"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    assert_eq!(text(0), "Run 4 · 3 stops · 3 probe hits");
    assert_eq!(text(1), "●1 (·2) ▲3");
    assert!(
        text(2).starts_with("◉ shortfall  ▂█▁  11  3 hits"),
        "{}",
        text(2)
    );
    // each stop carries its index for the editor
    let props = serde_json::to_value(&r[1]).unwrap()["props"].clone();
    assert!(
        props
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p[2] == "drgnx-debug-stop" && p[3] == 9)
    );
}
