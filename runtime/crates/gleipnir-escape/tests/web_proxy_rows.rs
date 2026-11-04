//! The web proxy's rows (`rows/linux/web-proxy.jsonl`) hold without a sandbox. The web policy runs outside the
//! sandbox, so each row's probes, run as a plain child against the fixture's web proxy, must already give the lines,
//! the proxy events and the silent listeners the row expects; the sandboxed run (the VM, or a `ctr.sh --sandbox`
//! container with `--bwrap-in-container`) only puts the relay in front. This runs in every container.
#![cfg(target_os = "linux")]

use gleipnir_escape::row::{self, Platform};
use gleipnir_escape::run::{self, Host, Opts, Outcome};
use std::path::{Path, PathBuf};

const PROBE: &str = env!("CARGO_BIN_EXE_gleipnir-probe");

#[test]
fn web_proxy_rows_hold_without_the_sandbox() {
    let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("rows/linux/web-proxy.jsonl");
    let rows = row::parse_file(&file, Platform::Linux).unwrap();
    assert_eq!(rows.len(), 10, "the web proxy's rows");
    let opts = Opts {
        ratatoskr: PathBuf::from("/nonexistent/ratatoskr"),
        probe: PathBuf::from(PROBE),
    };
    let host = Host {
        in_container: false,
        root: false,
        landlock_abi: 0,
        x32: false,
    };
    let mut failed = Vec::new();
    for mut r in rows {
        assert!(
            r.web.is_some() && r.control,
            "{}: a web row with a control run",
            r.row
        );
        r.needs.clear();
        r.unsandboxed = true;
        r.control = false;
        r.control_expect = None;
        if let Outcome::Fail(e) | Outcome::Skip(e) = run::run_row(&opts, &host, &r) {
            failed.push(format!("{}: {e}", r.row));
        }
    }
    assert!(failed.is_empty(), "{failed:#?}");
}
