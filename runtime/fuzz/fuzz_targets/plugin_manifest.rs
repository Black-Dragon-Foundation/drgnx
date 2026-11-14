//! Arbitrary bytes as a plugin manifest through `brokkr::manifest::parse`: nothing may panic, and a manifest that is
//! taken keeps the limits the approval card relies on (at most 16 hosts, a `kv_bytes` within 1 MiB, at most one hook
//! per point, a deadline within its point's budget, an ability name that fits the tool-name length).
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(m) = brokkr::manifest::parse(data) else {
        return;
    };
    assert!(m.hosts.len() <= 16);
    assert!(m.kv_bytes.is_none_or(|k| k <= 1 << 20));
    let mut points: Vec<_> = m.hooks.iter().map(|h| h.point).collect();
    points.sort();
    points.dedup();
    assert_eq!(points.len(), m.hooks.len(), "one hook per point");
    for h in &m.hooks {
        assert!(!h.verdicts.is_empty());
        assert!(h.deadline_ms.is_none_or(|d| (1..=h.point.budget_ms()).contains(&d)));
    }
    for a in &m.abilities {
        assert!(a.description.chars().count() <= 1024);
        assert_eq!(a.input_schema["type"], "object");
        assert!(m.name.as_str().len() + 1 + a.name.as_str().len() <= 44);
    }
});
