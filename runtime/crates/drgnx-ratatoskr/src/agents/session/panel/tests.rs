//! The panel extension's checks of what an agent sends, and its context gate. All pattern D (pure).

use super::*;

fn all() -> Vec<String> {
    FEATURES.iter().map(|f| (*f).to_owned()).collect()
}

fn caps(panel: Value) -> Value {
    json!({"loadSession": false, "_meta": {"_drgnx/panel": panel}})
}

#[test]
fn features_are_version_1_and_known_names_only() {
    let got = features(Some(&caps(
        json!({"version": 1, "features": ["before-tool", "bogus", "context", "context", 7]}),
    )));
    assert_eq!(got, vec!["context", "before-tool"]);
    assert!(features(Some(&caps(json!({"version": 2, "features": ["context"]})))).is_empty());
    assert!(features(Some(&caps(json!({"features": ["context"]})))).is_empty());
    assert!(features(Some(&json!({"loadSession": true}))).is_empty());
    assert!(features(None).is_empty());
    assert_eq!(
        client_meta(),
        json!({"_drgnx/panel": {"version": 1}}),
        "what initialize advertises"
    );
}

/// Breakdowns every 10 ms for a second, with the armed timer fired at its time: at most 4 a second are shown (plus
/// the first), and the last one is.
#[test]
fn context_is_shown_at_most_4_a_second_and_the_last_is_never_lost() {
    let mut g = Coalesce::default();
    let (mut shown, mut timer): (Vec<usize>, Option<f64>) = (vec![], None);
    let mut latest = 0;
    let mut t = 0.0_f64;
    for i in 1..=100 {
        t = f64::from(i) * 0.01;
        if let Some(at) = timer.filter(|at| *at <= t) {
            g.fired(at);
            shown.push(latest);
            timer = None;
        }
        latest = i as usize;
        match g.offer(t) {
            Offer::Now => shown.push(latest),
            Offer::Arm(d) => {
                assert!(timer.is_none(), "one timer at a time");
                timer = Some(t + d.as_secs_f64());
            }
            Offer::Wait => assert!(timer.is_some(), "waits only on an armed timer"),
        }
    }
    if let Some(at) = timer {
        assert!(at >= t);
        g.fired(at);
        shown.push(latest);
    }
    assert!(shown.len() <= 6, "at most 4 a second: {shown:?}");
    assert!(shown.len() >= 4, "the breakdown keeps coming: {shown:?}");
    assert_eq!(shown.last(), Some(&100), "{shown:?}");
}

fn ctx() -> Value {
    json!({"sessionId": "s1", "used": 1200, "size": 200000, "compact_frees": 300,
           "parts": [{"kind": "system", "tokens": 200},
                     {"kind": "tool-output", "tokens": 1000, "items": [{"id": "t1", "label": "Bash ls", "tokens": 1000}]}]})
}

#[test]
fn a_context_breakdown_is_checked_against_its_schema() {
    let f = all();
    let c = check_context(&f, "s1", "_drgnx/context", ctx()).expect("a good one");
    assert_eq!((c.used, c.size, c.parts.len()), (1200, 200000, 2));
    let refused = |features: &[String], method: &str, v: Value| {
        check_context(features, "s1", method, v).expect_err("refused")
    };
    let mut extra = ctx();
    extra["grants"] = json!({"execute": "allow"});
    assert!(
        refused(&f, "_drgnx/context", extra)
            .1
            .contains("unknown field")
    );
    let mut bad_kind = ctx();
    bad_kind["parts"][0]["kind"] = json!("secrets");
    refused(&f, "_drgnx/context", bad_kind);
    let mut many = ctx();
    many["parts"] = json!(vec![json!({"kind": "files", "tokens": 1}); 9]);
    assert!(refused(&f, "_drgnx/context", many).1.contains("at most 8"));
    let mut other = ctx();
    other["sessionId"] = json!("s2");
    assert!(
        refused(&f, "_drgnx/context", other)
            .1
            .contains("not this agent's session")
    );
    let mut big = ctx();
    big["parts"][1]["items"][0]["label"] = json!("x".repeat(MAX_PARAMS));
    assert!(
        refused(&f, "_drgnx/context", big)
            .1
            .contains("over 256 KiB")
    );
    assert!(
        refused(&["drop".to_owned()], "_drgnx/context", ctx())
            .1
            .contains("did not offer context")
    );
    let (code, why) = refused(&f, "_drgnx/grant", ctx());
    assert_eq!(code, jsonrpc::METHOD_NOT_FOUND);
    assert!(why.starts_with("drgnx refuses it:"), "{why}");
}

fn ask(extra: Value) -> Value {
    let mut v = json!({"sessionId": "s1", "toolCall": {"toolCallId": "tc-1", "title": "rm -rf x", "kind": "execute",
                       "rawInput": {"command": "rm -rf x"}, "_meta": {"claudeCode": {"toolName": "Bash"}}}});
    if let (Some(o), Value::Object(e)) = (v.as_object_mut(), extra) {
        o.extend(e);
    }
    v
}

#[test]
fn a_before_tool_request_is_checked_and_carries_no_verdict_of_the_agents() {
    let f = all();
    let tool =
        check_before_tool(&f, "s1", "_drgnx/before_tool", ask(json!({}))).expect("a good one");
    assert_eq!(tool["toolCallId"], "tc-1");
    assert_eq!(tool["rawInput"]["command"], "rm -rf x");
    let refused = |features: &[String], method: &str, v: Value| {
        check_before_tool(features, "s1", method, v).expect_err("refused")
    };
    // the agent cannot answer its own ask: an outcome, a verdict or a grant of its own is not a field
    for extra in [
        json!({"outcome": "allow"}),
        json!({"verdict": "allow"}),
        json!({"grants": {"execute": "allow"}}),
    ] {
        let (code, why) = refused(&f, "_drgnx/before_tool", ask(extra));
        assert_eq!(code, jsonrpc::INVALID_PARAMS);
        assert!(why.contains("unknown field"), "{why}");
    }
    // methods the hub sends, or does not know, are not the agent's to call
    for m in [
        "_drgnx/context/drop",
        "_drgnx/compact/preview",
        "_drgnx/grant",
        "_claude/x",
    ] {
        let (code, why) = refused(&f, m, ask(json!({})));
        assert_eq!(code, jsonrpc::METHOD_NOT_FOUND, "{m}");
        assert!(why.starts_with("drgnx refuses it:"), "{why}");
    }
    assert!(
        refused(
            &["context".to_owned()],
            "_drgnx/before_tool",
            ask(json!({}))
        )
        .1
        .contains("did not offer before-tool")
    );
    assert!(
        refused(&f, "_drgnx/before_tool", ask(json!({"sessionId": "s9"})))
            .1
            .contains("not this agent's session")
    );
    let mut big = ask(json!({}));
    big["toolCall"]["rawInput"]["command"] = json!("x".repeat(MAX_PARAMS));
    assert!(
        refused(&f, "_drgnx/before_tool", big)
            .1
            .contains("over 256 KiB")
    );
    let no_id = json!({"sessionId": "s1", "toolCall": {"title": "ls"}});
    refused(&f, "_drgnx/before_tool", no_id);
    refused(&f, "_drgnx/before_tool", json!("rm -rf x"));
}
