//! gleipnir-escape: runs the escape rows against `ratatoskr` and writes the report (Task 14).
//!
//! `gleipnir-escape --ratatoskr BIN --probe BIN --rows DIR… [--only GLOB] [--require-all] --report FILE`
//!
//! Exits 1 when a row fails (with `--require-all`, when one is skipped too), 2 on a usage error or a row that does
//! not parse.

use gleipnir_escape::report::{self, Entry};
use gleipnir_escape::row::{self, Row};
use gleipnir_escape::run::{self, Opts, Outcome};
use std::path::PathBuf;

fn die(msg: &str) -> ! {
    eprintln!("gleipnir-escape: {msg}");
    std::process::exit(2);
}

/// `*` matches any run of characters, `?` one.
fn glob(pattern: &str, text: &str) -> bool {
    fn go(p: &[char], t: &[char]) -> bool {
        match p.split_first() {
            None => t.is_empty(),
            Some(('*', rest)) => (0..=t.len()).any(|i| go(rest, &t[i..])),
            Some(('?', rest)) => !t.is_empty() && go(rest, &t[1..]),
            Some((c, rest)) => t.first() == Some(c) && go(rest, &t[1..]),
        }
    }
    go(
        &pattern.chars().collect::<Vec<_>>(),
        &text.chars().collect::<Vec<_>>(),
    )
}

fn main() {
    let mut args = std::env::args().skip(1);
    let (mut ratatoskr, mut probe, mut report_path, mut only) = (None, None, None, None);
    let mut dirs: Vec<PathBuf> = Vec::new();
    let mut require_all = false;
    while let Some(a) = args.next() {
        let mut value = |name: &str| {
            args.next()
                .unwrap_or_else(|| die(&format!("{name} needs a value")))
        };
        match a.as_str() {
            "--ratatoskr" => ratatoskr = Some(PathBuf::from(value("--ratatoskr"))),
            "--probe" => probe = Some(PathBuf::from(value("--probe"))),
            "--rows" => dirs.push(PathBuf::from(value("--rows"))),
            "--only" => only = Some(value("--only")),
            "--report" => report_path = Some(PathBuf::from(value("--report"))),
            "--require-all" => require_all = true,
            other => die(&format!("unknown argument {other:?}")),
        }
    }
    let ratatoskr = ratatoskr.unwrap_or_else(|| die("--ratatoskr BIN is required"));
    let probe = probe.unwrap_or_else(|| die("--probe BIN is required"));
    let report_path = report_path.unwrap_or_else(|| die("--report FILE is required"));
    if dirs.is_empty() {
        die("--rows DIR is required");
    }
    let canon = |p: PathBuf| {
        p.canonicalize()
            .unwrap_or_else(|e| die(&format!("{}: {e}", p.display())))
    };
    let opts = Opts {
        ratatoskr: canon(ratatoskr),
        probe: canon(probe),
    };

    let mut rows: Vec<Row> = Vec::new();
    for d in &dirs {
        match row::load_dir(d) {
            Ok(r) => rows.extend(r),
            Err(e) => die(&e),
        }
    }
    if let Some(g) = &only {
        rows.retain(|r| glob(g, &r.row));
    }

    let host = run::detect_host(&opts.probe);
    let mut entries = Vec::new();
    for r in &rows {
        let outcome = run::run_row(&opts, &host, r);
        let (word, why) = match &outcome {
            Outcome::Pass => ("pass", String::new()),
            Outcome::Fail(w) => ("FAIL", format!(": {w}")),
            Outcome::Skip(w) => ("skip", format!(": {w}")),
        };
        eprintln!("{word} {}{why}", r.row);
        entries.push(Entry::new(&r.row, outcome));
    }
    let (pass, fail, skip) = report::counts(&entries);
    eprintln!("{pass} passed, {fail} failed, {skip} skipped");
    if let Err(e) = report::write(&report_path, &entries) {
        die(&format!("{}: {e}", report_path.display()));
    }
    std::process::exit(report::exit_code(&entries, require_all));
}

#[cfg(test)]
mod tests {
    use super::glob;

    #[test]
    fn globs() {
        assert!(glob("k*-reduced", "k5-reduced"));
        assert!(glob("k?-reduced", "k5-reduced"));
        assert!(!glob("k?-reduced", "k55-reduced"));
        assert!(glob("*", ""));
        assert!(!glob("works", "works2"));
    }
}
