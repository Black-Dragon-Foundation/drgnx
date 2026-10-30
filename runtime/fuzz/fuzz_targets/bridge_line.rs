//! Arbitrary bytes through the bridge's line handling: `read_bounded` (a limit from the first byte), `classify` on every
//! line that is text, and `id_in_prefix` on every line and on the line cut at every position.
#![no_main]

use libfuzzer_sys::fuzz_target;
use mimir::bridge::fuzzing::{classify_id, prefix_id, read_lines};

fuzz_target!(|data: &[u8]| {
    let Some((&cut, rest)) = data.split_first() else {
        return;
    };
    let max = usize::from(cut) % 96 + 1;
    for (line, over) in read_lines(rest, max) {
        // a line is never kept past the limit, and a line has no newline
        assert!(line.len() <= max, "kept {} bytes over a limit of {max}", line.len());
        assert!(!line.contains(&b'\n'));
        let _ = over;
        if let Ok(text) = std::str::from_utf8(&line) {
            let _ = classify_id(text);
        }
        for end in 0..=line.len().min(64) {
            let _ = prefix_id(&line[..end]);
        }
        let _ = prefix_id(&line);
    }
});
