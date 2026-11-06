//! Bytes as a web proxy's plain-HTTP request head: the head's end, the absolute-form line and headers, the target
//! through `parse_target`, then the rewritten head. Nothing may panic, and the rewritten head has exactly one blank
//! line, at its end, and no bare CR or LF: no header or request is smuggled into it.
#![no_main]

use gleipnir::net::proxy::fuzz_absolute_head;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some(head) = fuzz_absolute_head(data) else {
        return;
    };
    assert!(head.ends_with(b"\r\n\r\n"));
    let body = &head[..head.len() - 2];
    assert!(!body.windows(4).any(|w| w == b"\r\n\r\n"));
    for (i, &c) in head.iter().enumerate() {
        match c {
            b'\r' => assert_eq!(head.get(i + 1), Some(&b'\n')),
            b'\n' => assert!(i > 0 && head[i - 1] == b'\r'),
            0 => panic!("a NUL in the head"),
            _ => {}
        }
    }
    assert!(head.ends_with(b"Connection: close\r\n\r\n"));
});
