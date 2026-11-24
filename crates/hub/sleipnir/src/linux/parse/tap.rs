//! TAP 13/14: `ok N - name`, `not ok N - name`, `# SKIP` and `# TODO` directives, `Bail out!`.

use forseti::{Row, RowClass};

use super::Parsed;

pub(super) fn parse(log: &[u8]) -> Parsed {
    let text = String::from_utf8_lossy(log);
    let mut p = Parsed::counting();
    for line in text.lines() {
        // an indented line is a subtest's: only the top level's rows count
        if line.starts_with("Bail out!") {
            p.anonymous_crashes += 1;
            continue;
        }
        let (ok, rest) = if let Some(r) = line.strip_prefix("not ok") {
            (false, r)
        } else if let Some(r) = line.strip_prefix("ok") {
            (true, r)
        } else {
            continue;
        };
        // `ok` must end the word: `okay` is no row
        if !rest.is_empty() && !rest.starts_with(' ') {
            continue;
        }
        let rest = rest.trim_start();
        let (num, rest) = rest.split_once(' ').unwrap_or((rest, ""));
        if num.is_empty() || !num.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let (desc, directive) = match rest.split_once(" # ") {
            Some((d, dir)) => (d, dir.trim()),
            None => (rest, ""),
        };
        let name = desc.trim().trim_start_matches('-').trim();
        let name = if name.is_empty() { num } else { name };
        let upper = directive.to_ascii_uppercase();
        let row = if upper.starts_with("SKIP") {
            Row::skip(name)
        } else if ok || upper.starts_with("TODO") {
            // a TODO that fails is a result as expected
            Row::pass(name)
        } else {
            Row::fail(name, RowClass::Assert)
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
    fn tap_rows_directives_and_bail_out() {
        let log = b"TAP version 13\n1..5\nok 1 - a\nnot ok 2 - b\nok 3 - c # SKIP no gpu\n\
            not ok 4 - d # TODO later\nokay not a row\n";
        let p = parse(log);
        assert_eq!(
            (
                p.counts.passed,
                p.counts.failed,
                p.counts.skipped,
                p.counts.ran
            ),
            (2, 1, 1, 3)
        );
        assert_eq!(p.rows[1].name, "b");
    }

    /// [D] mutation m6: `Bail out!` read as a pass.
    #[test]
    fn bail_out_is_a_crash_never_a_pass() {
        let p = parse(b"ok 1 - a\nBail out! the database is gone\n");
        assert_eq!((p.counts.passed, p.counts.crashed), (1, 1));
        let ex = forseti::Expect::default();
        assert_eq!(super::super::judge(&p, &ex), forseti::Verdict::Crash);
    }
}
