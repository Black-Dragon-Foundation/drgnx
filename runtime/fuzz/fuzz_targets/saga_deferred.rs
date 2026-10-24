//! Any text through `saga::deferred::parse` and back through `render`: DEFERRED.md registers are rendered back byte-exact, so the output
//! must equal the input, and nothing may panic.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let doc = saga::deferred::parse(text);
    assert_eq!(saga::deferred::render(&doc), text);
});
