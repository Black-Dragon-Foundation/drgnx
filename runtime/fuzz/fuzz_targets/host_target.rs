//! `parse_target` on arbitrary text; a success must print back to a string that parses to the same target.
#![no_main]

use gleipnir::net::host::parse_target;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|s: &str| {
    if let Ok(t) = parse_target(s) {
        let shown = t.to_string();
        let again = parse_target(&shown).expect("a displayed target parses");
        assert_eq!(again, t, "{s:?} shown as {shown:?}");
    }
});
