//! `dump FILE`: reads the file's top-level data with huginn and prints one canonical dump per datum, one JSON per line
//! (test/fixtures/huginn/README.md); a refused file prints `["refused", KIND, START]` (the kind as `RefusalKind`
//! names it, START a byte offset) and nothing else. The editor's differential test (test/unit/huginn-diff-test.el)
//! runs it on files of random data and compares the lines with its own dumps. Exit 0 when the file was read or
//! refused, 2 on a usage or I/O error.
#[path = "../tests/common/mod.rs"]
mod common;

use huginn::read::{Limits, read_all};
use serde_json::json;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [path] = args.as_slice() else {
        usage_error("usage: dump FILE");
    };
    let bytes = std::fs::read(path).unwrap_or_else(|e| usage_error(&format!("dump: {path}: {e}")));
    match read_all(&bytes, Limits::default()) {
        Ok(nodes) => {
            for node in &nodes {
                out(&common::dump(node).to_string());
            }
        }
        Err(r) => out(&json!(["refused", format!("{:?}", r.kind), r.span.start]).to_string()),
    }
}

/// One line of the dump on stdout; a closed pipe ends the run.
fn out(line: &str) {
    if annall::cli_out(line).is_err() {
        std::process::exit(2);
    }
}

/// A usage or I/O problem: the line on stderr, exit 2.
fn usage_error(line: &str) -> ! {
    // with stderr gone too there is nowhere left to say it: the exit code does
    annall::cli_err(line).unwrap_or_default();
    std::process::exit(2)
}
