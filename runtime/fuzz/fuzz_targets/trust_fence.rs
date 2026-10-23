//! Text, an author and a project (split at the first two NUL bytes) through `trust::fence`: the output is one fence,
//! with exactly one opening tag at the start and exactly one closing tag, at the end (ASCII case ignored), whatever
//! the text and the names hold.
#![no_main]

use libfuzzer_sys::fuzz_target;
use norn::trust::fence;

fuzz_target!(|data: &[u8]| {
    let Ok(all) = std::str::from_utf8(data) else {
        return;
    };
    let mut parts = all.splitn(3, '\0');
    let (text, by, project) = (
        parts.next().unwrap_or(""),
        parts.next().unwrap_or(""),
        parts.next().unwrap_or(""),
    );
    let out = fence(text, by, project);
    let lower = out.to_ascii_lowercase();
    assert!(out.starts_with("<untrusted-data by=\""), "{out:?}");
    assert!(out.ends_with("</untrusted-data>"), "{out:?}");
    assert_eq!(lower.matches("</untrusted-data").count(), 1, "{out:?}");
    assert_eq!(lower.matches("<untrusted-data").count(), 1, "{out:?}");
});
