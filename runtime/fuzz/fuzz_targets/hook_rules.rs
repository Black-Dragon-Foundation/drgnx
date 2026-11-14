//! Arbitrary JSON as the `drgnx-agents-hook-rules` list through `norn::hooks::parse_rules`: nothing may panic (a regex
//! or glob that does not compile is a refusal), and a list that is taken keeps its promises: an id is 1 to 32 of
//! `[a-z0-9-]` and unique in the list, and every rule has a reason.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) else {
        return;
    };
    let Ok(rules) = norn::hooks::parse_rules(&v) else {
        return;
    };
    let mut ids: Vec<&str> = rules.iter().filter_map(|r| r.id.as_deref()).collect();
    for id in &ids {
        assert!((1..=32).contains(&id.len()));
        assert!(
            id.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        );
    }
    assert!(rules.iter().all(|r| !r.reason.trim().is_empty()));
    let n = ids.len();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), n, "ids are unique");
});
