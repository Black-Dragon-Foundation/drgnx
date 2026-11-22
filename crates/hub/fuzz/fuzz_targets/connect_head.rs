//! Bytes as a proxy request head: the head's end, the exactly-`CONNECT target HTTP/1.x` line, then the target text
//! through `parse_target`. Nothing may panic.
#![no_main]

use gleipnir::net::host::parse_target;
use gleipnir::net::proxy::fuzz_connect_head;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some(raw) = fuzz_connect_head(data) else {
        return;
    };
    if let Ok(text) = std::str::from_utf8(raw) {
        let _ = parse_target(text);
    }
});
