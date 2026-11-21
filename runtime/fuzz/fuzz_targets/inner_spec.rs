//! The helper's inner spec decoded from arbitrary bytes (serde, `deny_unknown_fields`; version 1, and version 2 with
//! the browser host's plan, `corpus/inner_spec/browser.json`); a success re-encodes and decodes to the same value.
#![no_main]

use gleipnir::inner::InnerSpec;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(spec) = serde_json::from_slice::<InnerSpec>(data) {
        let again = serde_json::to_vec(&spec).expect("a spec encodes");
        let back: InnerSpec = serde_json::from_slice(&again).expect("an encoded spec decodes");
        assert_eq!(back, spec);
    }
});
