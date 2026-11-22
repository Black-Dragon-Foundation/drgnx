//! `bwrap --version` output from arbitrary text.
#![no_main]

use gleipnir::bwrap::{parse_version, version_at_floor};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|s: &str| {
    let parsed = parse_version(s);
    let floored = version_at_floor(s);
    if let Ok(v) = floored {
        assert_eq!(parsed.ok(), Some(v));
    }
});
