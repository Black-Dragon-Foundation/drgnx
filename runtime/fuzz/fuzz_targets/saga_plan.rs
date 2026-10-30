//! Any text through `saga::plan::parse` and back through `render`: Plans are rendered back byte-exact, so the output
//! must equal the input, and nothing may panic.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let doc = saga::plan::parse(text);
    assert_eq!(saga::plan::render(&doc), text);
});
