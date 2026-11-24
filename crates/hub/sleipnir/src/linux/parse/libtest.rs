//! libtest's two outputs: the text lines and the `--format json` events.

use forseti::{Row, RowClass};

use super::Parsed;

/// `test NAME ... ok|FAILED|ignored[, why]`; a process that died on a signal is one anonymous crash.
pub(super) fn parse(log: &[u8]) -> Parsed {
    let text = String::from_utf8_lossy(log);
    let mut p = Parsed::counting();
    for line in text.lines() {
        if line.contains("process didn't exit successfully") && line.contains("(signal: ") {
            p.anonymous_crashes += 1;
            continue;
        }
        let Some(rest) = line.strip_prefix("test ") else {
            continue;
        };
        let Some((name, outcome)) = rest.split_once(" ... ") else {
            continue;
        };
        let name = name.trim();
        let row = match outcome.trim() {
            "ok" => Row::pass(name),
            "FAILED" => Row::fail(name, RowClass::Assert),
            o if o == "ignored" || o.starts_with("ignored, ") => Row::skip(name),
            _ => continue,
        };
        p.push(row);
    }
    p.finish()
}

/// One JSON object per line: `{"type":"test","event":"ok|failed|ignored","name":…,"stdout":…}`. Lines that are not
/// JSON (cargo's own) are skipped; `timeout` is a failure of class timeout.
pub(super) fn parse_json(log: &[u8]) -> Parsed {
    let text = String::from_utf8_lossy(log);
    let mut p = Parsed::counting();
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            continue;
        };
        if v["type"] != "test" {
            continue;
        }
        let Some(name) = v["name"].as_str() else {
            continue;
        };
        let row = match v["event"].as_str() {
            Some("ok") => Row::pass(name),
            Some("ignored") => Row::skip(name),
            Some("failed") => {
                let r = Row::fail(name, RowClass::Assert);
                match v["stdout"].as_str().filter(|s| !s.is_empty()) {
                    Some(out) => r.with_excerpt(excerpt(out)),
                    None => r,
                }
            }
            Some("timeout") => Row::fail(name, RowClass::Timeout),
            _ => continue,
        };
        p.push(row);
    }
    p.finish()
}

/// The first lines of a failure's output.
pub(super) fn excerpt(s: &str) -> String {
    s.lines().take(12).collect::<Vec<_>>().join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::RowVerdict;

    /// [D]
    #[test]
    fn libtest_json_reads_events_and_skips_cargos_lines() {
        let log = b"   Compiling x v0.1.0\n\
            {\"type\":\"suite\",\"event\":\"started\",\"test_count\":3}\n\
            {\"type\":\"test\",\"event\":\"started\",\"name\":\"a::one\"}\n\
            {\"type\":\"test\",\"event\":\"ok\",\"name\":\"a::one\"}\n\
            {\"type\":\"test\",\"event\":\"failed\",\"name\":\"a::two\",\"stdout\":\"thread panicked\\nat x.rs:1\"}\n\
            {\"type\":\"test\",\"event\":\"ignored\",\"name\":\"a::three\"}\n";
        let p = parse_json(log);
        assert_eq!((p.counts.ran, p.counts.failed, p.counts.skipped), (2, 1, 1));
        let two = &p.rows[1];
        assert_eq!(two.verdict, RowVerdict::Fail);
        assert!(two.excerpt.as_deref().unwrap().contains("at x.rs:1"));
    }
}
