//! The three CLIs' session formats, from hand-written fixtures (invented content, the documented and source-read
//! shapes): what a file reads as, what is skipped, and that reading on from an offset gives what reading it whole does.

use minni::{Provider, Reader};
use proptest::prelude::*;
use serde_json::Value;

fn kinds(r: &Reader) -> Vec<&str> {
    r.entries()
        .iter()
        .map(|e| e["type"].as_str().unwrap())
        .collect()
}

fn text(e: &Value) -> &str {
    e["text"].as_str().unwrap_or("")
}

const CLAUDE: &str = concat!(
    r#"{"type":"summary","summary":"Counting apples","leafUuid":"u0"}"#,
    "\n",
    r#"{"type":"user","uuid":"u1","parentUuid":null,"sessionId":"5f0c","cwd":"/w/orchard","gitBranch":"main","timestamp":"2026-11-01T10:00:00Z","message":{"role":"user","content":"count the apples"}}"#,
    "\n",
    r#"{"type":"assistant","uuid":"u2","parentUuid":"u1","sessionId":"5f0c","cwd":"/w/orchard","timestamp":"2026-11-01T10:00:05Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"a basket first"},{"type":"text","text":"Reading the basket."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"basket.txt"}}]}}"#,
    "\n",
    r#"{"type":"user","uuid":"u3","parentUuid":"u2","sessionId":"5f0c","timestamp":"2026-11-01T10:00:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"3 apples"}]}}"#,
    "\n",
    r#"{"type":"file-history-snapshot","messageId":"u3","snapshot":{}}"#,
    "\n",
    r#"{"type":"system","subtype":"compact_boundary","uuid":"u4","timestamp":"2026-11-01T10:01:00Z","content":"Conversation compacted"}"#,
    "\n",
    r#"{"type":"assistant","uuid":"u5","sessionId":"5f0c","timestamp":"2026-11-01T10:02:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Three."}]}}"#,
    "\n",
);

#[test]
fn a_claude_code_session() {
    let r = minni::parse(Provider::Claude, CLAUDE.as_bytes());
    assert_eq!(
        kinds(&r),
        ["user", "thought", "agent", "tool", "compaction", "agent"]
    );
    let e = r.entries();
    assert_eq!(text(&e[0]), "count the apples");
    assert_eq!(text(&e[1]), "a basket first");
    assert_eq!(e[3]["title"], "Read");
    assert_eq!(e[3]["status"], "completed", "its result came");
    assert_eq!(e[3]["content"], "3 apples");
    let m = r.meta();
    assert_eq!(m.id.as_deref(), Some("5f0c"));
    assert_eq!(m.cwd.as_deref(), Some("/w/orchard"));
    assert_eq!(m.branch.as_deref(), Some("main"));
    assert_eq!(m.title.as_deref(), Some("Counting apples"));
    assert_eq!(m.started.as_deref(), Some("2026-11-01T10:00:00Z"));
    assert_eq!(m.updated.as_deref(), Some("2026-11-01T10:02:00Z"));
    assert_eq!(m.turns, 1);
    assert_eq!(r.skipped().get("file-history-snapshot"), Some(&1));
    assert_eq!(r.offset(), CLAUDE.len() as u64);
}

#[test]
fn a_custom_title_wins_and_without_one_the_first_prompt_names_it() {
    let named = format!(
        "{CLAUDE}{}\n",
        r#"{"type":"custom-title","customTitle":"Apples","sessionId":"5f0c"}"#
    );
    assert_eq!(
        minni::parse(Provider::Claude, named.as_bytes())
            .meta()
            .title
            .as_deref(),
        Some("Apples")
    );
    let bare = CLAUDE.split_once('\n').unwrap().1;
    assert_eq!(
        minni::parse(Provider::Claude, bare.as_bytes())
            .meta()
            .title
            .as_deref(),
        Some("count the apples")
    );
}

#[test]
fn a_truncated_last_line_waits_for_the_rest() {
    let cut = CLAUDE.len() - 20;
    let mut r = Reader::new(Provider::Claude);
    let used = r.feed(&CLAUDE.as_bytes()[..cut]);
    assert!(used < cut, "the half line is not consumed");
    assert_eq!(kinds(&r).len(), 5);
    r.feed(&CLAUDE.as_bytes()[used..]);
    assert_eq!(kinds(&r).len(), 6);
    assert_eq!(r.offset(), CLAUDE.len() as u64);
}

#[test]
fn a_line_that_is_not_json_is_skipped_and_counted() {
    let r = minni::parse(
        Provider::Claude,
        b"not json\n{\"type\":\"weird-new-kind\"}\n",
    );
    assert!(r.entries().is_empty());
    assert_eq!(r.skipped().get("unreadable"), Some(&1));
    assert_eq!(r.skipped().get("weird-new-kind"), Some(&1));
}

const GEMINI: &str = concat!(
    r#"{"sessionId":"9a1b2c3d","projectHash":"ab12","startTime":"2026-11-02T09:00:00Z","lastUpdated":"2026-11-02T09:00:00Z","kind":"main","directories":["/w/pear"]}"#,
    "\n",
    r#"{"id":"m1","timestamp":"2026-11-02T09:00:01Z","type":"user","content":[{"text":"weigh the pears"}]}"#,
    "\n",
    r#"{"id":"m2","timestamp":"2026-11-02T09:00:04Z","type":"gemini","content":"Weighing.","thoughts":[{"subject":"Scale","description":"use the kitchen scale"}],"toolCalls":[{"id":"c1","name":"read_file","displayName":"ReadFile","args":{"path":"pears"},"status":"success","result":[{"functionResponse":{"response":{"output":"2 kg"}}}]}]}"#,
    "\n",
    r#"{"id":"m3","timestamp":"2026-11-02T09:00:09Z","type":"user","content":"no, the plums"}"#,
    "\n",
    r#"{"$rewindTo":"m3"}"#,
    "\n",
    r#"{"id":"m4","timestamp":"2026-11-02T09:00:12Z","type":"info","content":"Request cancelled."}"#,
    "\n",
    r#"{"$set":{"summary":"Weighing pears","lastUpdated":"2026-11-02T09:00:12Z"}}"#,
    "\n",
    r#"{"$patch":{"m2":{"tokens":{"input":5}}}}"#,
    "\n",
);

#[test]
fn a_gemini_cli_session_with_a_rewind() {
    let r = minni::parse(Provider::Gemini, GEMINI.as_bytes());
    assert_eq!(kinds(&r), ["user", "thought", "agent", "tool", "notice"]);
    let e = r.entries();
    assert_eq!(text(&e[0]), "weigh the pears");
    assert_eq!(text(&e[1]), "Scale: use the kitchen scale");
    assert_eq!(e[3]["title"], "ReadFile");
    assert_eq!(e[3]["status"], "completed");
    assert!(
        !r.entries().iter().any(|e| text(e).contains("plums")),
        "rewound"
    );
    let m = r.meta();
    assert_eq!(m.id.as_deref(), Some("9a1b2c3d"));
    assert_eq!(m.title.as_deref(), Some("Weighing pears"));
    assert_eq!(m.cwd.as_deref(), Some("/w/pear"));
    assert_eq!(m.updated.as_deref(), Some("2026-11-02T09:00:12Z"));
    assert_eq!(m.turns, 1);
    assert_eq!(r.skipped().get("$patch"), Some(&1));
}

#[test]
fn an_old_gemini_json_file() {
    let old = r#"{"sessionId":"77","startTime":"2026-10-01T08:00:00Z","lastUpdated":"2026-10-01T08:05:00Z","messages":[{"id":"a","type":"user","content":"hello"},{"id":"b","type":"gemini","content":"Hi."}]}"#;
    let r = minni::parse_whole(Provider::Gemini, old.as_bytes());
    assert_eq!(kinds(&r), ["user", "agent"]);
    assert_eq!(r.meta().id.as_deref(), Some("77"));
    assert_eq!(r.meta().title.as_deref(), Some("hello"));
}

const CODEX: &str = concat!(
    r#"{"timestamp":"2026-11-03T07:00:00Z","type":"session_meta","payload":{"id":"0199-c0de","timestamp":"2026-11-03T07:00:00Z","cwd":"/w/plum","originator":"codex_cli_rs","cli_version":"0.50.0","git":{"branch":"plums"}}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:01Z","type":"turn_context","payload":{"cwd":"/w/plum","model":"m"}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/w/plum</cwd>\n</environment_context>"}]}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"sort the plums"}]}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"sort the plums"}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:03Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"by colour"}]}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:04Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\"]}","call_id":"k1"}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":"k1","output":"plums.txt"}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:06Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Sorted."}]}}"#,
    "\n",
    r#"{"timestamp":"2026-11-03T07:00:07Z","type":"compacted","payload":{"message":"summary of the plums"}}"#,
    "\n",
);

#[test]
fn a_codex_session() {
    let r = minni::parse(Provider::Codex, CODEX.as_bytes());
    assert_eq!(
        kinds(&r),
        ["user", "thought", "tool", "agent", "compaction"]
    );
    let e = r.entries();
    assert_eq!(text(&e[0]), "sort the plums");
    assert_eq!(e[2]["title"], "shell");
    assert_eq!(e[2]["status"], "completed");
    assert_eq!(e[2]["content"], "plums.txt");
    let m = r.meta();
    assert_eq!(m.id.as_deref(), Some("0199-c0de"));
    assert_eq!(m.cwd.as_deref(), Some("/w/plum"));
    assert_eq!(m.branch.as_deref(), Some("plums"));
    assert_eq!(m.title.as_deref(), Some("sort the plums"));
    assert_eq!(m.updated.as_deref(), Some("2026-11-03T07:00:07Z"));
    assert_eq!(m.turns, 1);
    assert_eq!(r.skipped().get("turn_context"), Some(&1));
    assert_eq!(r.skipped().get("event_msg"), Some(&1));
}

#[test]
fn an_old_codex_file_without_the_envelope() {
    let old = concat!(
        r#"{"id":"0042","timestamp":"2025-06-01T12:00:00Z","instructions":null,"git":{"branch":"old"}}"#,
        "\n",
        r#"{"record_type":"state"}"#,
        "\n",
        r#"{"type":"message","role":"user","content":[{"type":"input_text","text":"list the pits"}]}"#,
        "\n",
        r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Two pits."}]}"#,
        "\n",
    );
    let r = minni::parse(Provider::Codex, old.as_bytes());
    assert_eq!(kinds(&r), ["user", "agent"]);
    assert_eq!(r.meta().id.as_deref(), Some("0042"));
    assert_eq!(r.meta().branch.as_deref(), Some("old"));
    assert_eq!(r.skipped().get("state"), Some(&1));
}

/// Whole, or fed in two parts split anywhere: the same entries and meta.
fn same_split(p: Provider, text: &str, at: usize) -> Result<(), TestCaseError> {
    let whole = minni::parse(p, text.as_bytes());
    let mut r = Reader::new(p);
    let bytes = text.as_bytes();
    let used = r.feed(&bytes[..at]);
    r.feed(&bytes[used..]);
    prop_assert_eq!(r.entries(), whole.entries());
    prop_assert_eq!(r.meta(), whole.meta());
    Ok(())
}

proptest! {
    #[test]
    fn reading_on_from_an_offset_is_reading_it_whole(at in 0usize..1000) {
        same_split(Provider::Claude, CLAUDE, at.min(CLAUDE.len()))?;
        same_split(Provider::Gemini, GEMINI, at.min(GEMINI.len()))?;
        same_split(Provider::Codex, CODEX, at.min(CODEX.len()))?;
    }

    #[test]
    fn no_input_makes_it_panic(bytes in proptest::collection::vec(any::<u8>(), 0..400)) {
        for p in [Provider::Claude, Provider::Gemini, Provider::Codex] {
            let _ = minni::parse(p, &bytes);
            let _ = minni::parse_whole(p, &bytes);
        }
    }
}
