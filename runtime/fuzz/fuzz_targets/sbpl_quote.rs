//! `quote` on arbitrary text; a success must read back as exactly one string equal to the input.
#![no_main]

use gleipnir::sbpl::{quote, sexp};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|s: &str| {
    if let Ok(q) = quote(s) {
        let forms = sexp::read(&q).expect("a quoted string reads");
        assert_eq!(forms, vec![sexp::Sexp::Str(s.to_string())], "{s:?} quoted as {q:?}");
    }
});
