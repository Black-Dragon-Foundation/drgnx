//! The `junit` parser: every `<testcase>` of the JUnit XML in the log is one row, named `classname::name` (`name` alone
//! with no classname). The report is what the stage printed (`cat report.xml`); text around it is skipped.
//!
//! - `<failure>`: a failed row (class timeout when its type, message or text says so, else assert); `<error>`: error.
//! - `<skipped>`: a skipped row.
//! - `<flakyFailure>`, `<flakyError>` (nextest's retried-then-passed) and `<rerunFailure>`: no verdict of their own;
//!   the row's final outcome decides, and a flaky pass keeps its first failure as the excerpt.

use forseti::{Row, RowClass};
use quick_xml::{
    Reader,
    events::{BytesStart, Event},
};

use super::Parsed;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Failure,
    Error,
    Skipped,
    /// `flakyFailure` and friends: they say nothing of the final outcome.
    Flaky,
}

fn kind_of(local: &str) -> Option<Kind> {
    match local {
        "failure" => Some(Kind::Failure),
        "error" => Some(Kind::Error),
        "skipped" => Some(Kind::Skipped),
        "flakyFailure" | "flakyError" | "rerunFailure" | "rerunError" => Some(Kind::Flaky),
        _ => None,
    }
}

type Attrs = Vec<(String, String)>;

fn attrs(e: &BytesStart<'_>) -> Attrs {
    e.attributes()
        .flatten()
        .map(|a| {
            (
                a.key.local_name().as_ref().to_string(),
                a.normalized_value(quick_xml::XmlVersion::Implicit1_0)
                    .map(|c| c.into_owned())
                    .unwrap_or_default(),
            )
        })
        .collect()
}

fn attr<'a>(a: &'a Attrs, key: &str) -> &'a str {
    a.iter()
        .find(|(k, _)| k == key)
        .map_or("", |(_, v)| v.as_str())
}

/// A testcase being read.
#[derive(Default)]
struct Case {
    name: String,
    classname: String,
    /// The final outcome so far: the kind and the failure's class and excerpt.
    outcome: Option<(Kind, RowClass, Option<String>)>,
    /// A flaky attempt's excerpt, kept for a row that passed in the end.
    flaky: Option<String>,
}

impl Case {
    fn new(a: &Attrs) -> Case {
        Case {
            name: attr(a, "name").to_string(),
            classname: attr(a, "classname").to_string(),
            ..Case::default()
        }
    }

    /// A child (`failure`, `skipped`, …) with its attributes A and its text BODY.
    fn child(&mut self, kind: Kind, a: &Attrs, body: &str) {
        let body = body.trim();
        let text = [attr(a, "message"), body]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        let excerpt = (!text.is_empty()).then(|| super::libtest::excerpt(&text));
        let said = format!("{} {text}", attr(a, "type")).to_ascii_lowercase();
        let class = if said.contains("timeout") || said.contains("timed out") {
            RowClass::Timeout
        } else if kind == Kind::Error {
            RowClass::Error
        } else {
            RowClass::Assert
        };
        match kind {
            Kind::Flaky => self.flaky = self.flaky.take().or(excerpt),
            _ => self.outcome = Some((kind, class, excerpt)),
        }
    }

    fn row(self) -> Row {
        let name = if self.classname.is_empty() {
            self.name
        } else {
            format!("{}::{}", self.classname, self.name)
        };
        match self.outcome {
            None => {
                let r = Row::pass(&name);
                match self.flaky {
                    Some(f) => r.with_excerpt(format!("flaky: passed after a failed attempt\n{f}")),
                    None => r,
                }
            }
            Some((Kind::Skipped, ..)) => Row::skip(&name),
            Some((_, class, excerpt)) => {
                let r = Row::fail(&name, class);
                match excerpt {
                    Some(x) => r.with_excerpt(x),
                    None => r,
                }
            }
        }
    }
}

pub(super) fn parse(log: &[u8]) -> Parsed {
    let text = String::from_utf8_lossy(log);
    let mut p = Parsed::counting();
    let mut r = Reader::from_str(&text);
    r.config_mut().check_end_names = false;
    let mut case: Option<Case> = None;
    // the open child of the case: its kind, its attributes and the text it collects
    let mut child: Option<(Kind, Attrs, String)> = None;
    // text that is not XML after the report ends the read: what was read stands
    while let Ok(ev) = r.read_event() {
        match ev {
            Event::Start(e) => {
                let local = e.local_name().as_ref().to_string();
                if local == "testcase" {
                    case = Some(Case::new(&attrs(&e)));
                } else if case.is_some()
                    && let Some(kind) = kind_of(&local)
                {
                    child = Some((kind, attrs(&e), String::new()));
                }
            }
            Event::Empty(e) => {
                let local = e.local_name().as_ref().to_string();
                if local == "testcase" {
                    p.push(Case::new(&attrs(&e)).row());
                } else if let (Some(c), Some(kind)) = (case.as_mut(), kind_of(&local)) {
                    c.child(kind, &attrs(&e), "");
                }
            }
            Event::Text(t) => {
                if let Some((_, _, buf)) = child.as_mut() {
                    buf.push_str(&t);
                }
            }
            Event::CData(t) => {
                if let Some((_, _, buf)) = child.as_mut() {
                    buf.push_str(&t);
                }
            }
            // quick-xml 0.42 hands an entity in text over as its own event
            Event::GeneralRef(g) => {
                if let Some((_, _, buf)) = child.as_mut() {
                    let name: &str = &g;
                    buf.push(match name {
                        "lt" => '<',
                        "gt" => '>',
                        "amp" => '&',
                        "quot" => '"',
                        "apos" => '\'',
                        _ => ' ',
                    });
                }
            }
            Event::End(e) => {
                let local = e.local_name().as_ref().to_string();
                if local == "testcase" {
                    if let Some(c) = case.take() {
                        p.push(c.row());
                    }
                } else if kind_of(&local).is_some()
                    && let (Some(c), Some((kind, a, body))) = (case.as_mut(), child.take())
                {
                    c.child(kind, &a, &body);
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    p.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::RowVerdict;

    fn row<'a>(p: &'a Parsed, name: &str) -> &'a Row {
        p.rows.iter().find(|r| r.name == name).expect(name)
    }

    /// [D] A report as nextest writes it: a failure, a flaky pass (its first attempt in `flakyFailure`), a skip.
    #[test]
    fn junit_from_nextest_reads_flaky_and_failures() {
        let xml = include_str!("fixtures/nextest.xml");
        let p = parse(format!("running\n{xml}\ndone\n").as_bytes());
        assert_eq!((p.counts.ran, p.counts.failed, p.counts.skipped), (3, 1, 1));
        let bad = row(&p, "mycrate::bin/mycrate::tests::bad");
        assert_eq!(bad.verdict, RowVerdict::Fail);
        assert!(bad.excerpt.as_deref().unwrap().contains("assertion"));
        let flaky = row(&p, "mycrate::bin/mycrate::tests::flaky");
        assert_eq!(flaky.verdict, RowVerdict::Pass);
        assert!(flaky.excerpt.as_deref().unwrap().starts_with("flaky"));
        assert_eq!(
            row(&p, "mycrate::bin/mycrate::tests::off").verdict,
            RowVerdict::Skip
        );
    }

    /// [D] Four tools' reports, small captured shapes: pytest, gotestsum, gradle and ctest. The parser knows none of
    /// them: only classname, name, failure, error and skipped.
    #[test]
    fn junit_reads_pytest_gotestsum_gradle_and_ctest_reports() {
        let pytest = r#"<?xml version="1.0"?><testsuites><testsuite name="pytest" tests="3">
            <testcase classname="tests.test_a" name="test_ok" time="0.01"/>
            <testcase classname="tests.test_a" name="test_bad"><failure message="assert 1 == 2">E assert 1 == 2</failure></testcase>
            <testcase classname="tests.test_a" name="test_skip"><skipped type="pytest.skip" message="no gpu"/></testcase>
            </testsuite></testsuites>"#;
        let p = parse(pytest.as_bytes());
        assert_eq!(
            (p.counts.passed, p.counts.failed, p.counts.skipped),
            (1, 1, 1)
        );
        assert_eq!(row(&p, "tests.test_a::test_bad").verdict, RowVerdict::Fail);

        let gotest = r#"<testsuites><testsuite name="pkg/x" tests="2">
            <testcase classname="pkg/x" name="TestA" time="0.00"></testcase>
            <testcase classname="pkg/x" name="TestB" time="0.10"><failure message="Failed" type="">--- FAIL: TestB</failure></testcase>
            </testsuite></testsuites>"#;
        let p = parse(gotest.as_bytes());
        assert_eq!((p.counts.ran, p.counts.failed), (2, 1));
        assert!(
            row(&p, "pkg/x::TestB")
                .excerpt
                .as_deref()
                .unwrap()
                .contains("FAIL")
        );

        let gradle = r#"<testsuite name="com.x.FooTest" tests="2" errors="1">
            <testcase name="works" classname="com.x.FooTest" time="0.1"/>
            <testcase name="breaks" classname="com.x.FooTest" time="0.1"><error message="boom" type="java.lang.IllegalStateException">trace</error></testcase>
            </testsuite>"#;
        let p = parse(gradle.as_bytes());
        let e = row(&p, "com.x.FooTest::breaks");
        assert_eq!(
            (e.verdict, e.class),
            (RowVerdict::Fail, Some(RowClass::Error))
        );

        let ctest = r#"<testsuite name="ctest" tests="2"><testcase name="unit" classname="unit" time="0.1"/>
            <testcase name="slow" classname="slow"><failure message="Timeout">timed out after 30s</failure></testcase></testsuite>"#;
        let p = parse(ctest.as_bytes());
        assert_eq!(row(&p, "slow::slow").class, Some(RowClass::Timeout));
        assert_eq!(p.counts.passed, 1);
    }
}
