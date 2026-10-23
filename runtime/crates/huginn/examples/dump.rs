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
        eprintln!("usage: dump FILE");
        std::process::exit(2);
    };
    let bytes = std::fs::read(path).unwrap_or_else(|e| {
        eprintln!("dump: {path}: {e}");
        std::process::exit(2);
    });
    match read_all(&bytes, Limits::default()) {
        Ok(nodes) => {
            for node in &nodes {
                println!("{}", common::dump(node));
            }
        }
        Err(r) => println!(
            "{}",
            json!(["refused", format!("{:?}", r.kind), r.span.start])
        ),
    }
}
