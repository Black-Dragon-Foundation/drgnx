//! The `regex:PATTERN` parser: one row per line the pattern matches, from its named groups.

use forseti::{Row, RowClass};
use regex::Regex;

use super::Parsed;

/// PATTERN as a regex with the named groups `name` and `verdict`; anything else is refused.
pub(super) fn compile(pattern: &str) -> villa::Result<Regex> {
    let re = Regex::new(pattern)
        .map_err(|e| villa::Error::invalid(format!("the regex parser's pattern: {e}")))?;
    let has = |g: &str| re.capture_names().flatten().any(|n| n == g);
    if has("name") && has("verdict") {
        Ok(re)
    } else {
        Err(villa::Error::invalid(
            "the regex parser's pattern needs the named groups (?P<name>…) and (?P<verdict>…)",
        ))
    }
}

pub(super) fn parse(pattern: &str, log: &[u8]) -> Parsed {
    let mut p = Parsed::counting();
    let Ok(re) = compile(pattern) else {
        return p.finish();
    };
    for line in String::from_utf8_lossy(log).lines() {
        let Some(c) = re.captures(line) else { continue };
        let (Some(name), Some(verdict)) = (c.name("name"), c.name("verdict")) else {
            continue;
        };
        let name = name.as_str();
        let row = match verdict.as_str().to_ascii_lowercase().as_str() {
            "pass" | "passed" | "ok" => Row::pass(name),
            "fail" | "failed" => Row::fail(name, RowClass::Assert),
            "skip" | "skipped" | "ignored" => Row::skip(name),
            "crash" | "crashed" => Row::fail(name, RowClass::Crash),
            _ => continue,
        };
        p.push(row);
    }
    p.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D]
    #[test]
    fn the_regex_parser_reads_named_groups() {
        let pat = r"^(?P<name>\S+): (?P<verdict>pass|fail|skip|crash)$";
        let p = parse(pat, b"a: pass\nnoise\nb: fail\nc: skip\nd: crash\n");
        assert_eq!(
            (
                p.counts.passed,
                p.counts.failed,
                p.counts.skipped,
                p.counts.crashed
            ),
            (1, 1, 1, 1)
        );
        assert!(
            compile(r"^(\S+)$").is_err(),
            "without the named groups it is refused"
        );
    }
}
