# Attention

**The rule.** What wants the user's attention is a notice in `tidindi`'s one list, never a bespoke popup or a line of
stderr. The same key updates a notice in place instead of adding one. The list is shown as rows.

**Doing it right.**

```rust
let id = notices.post(tidindi::Notice {
    level: tidindi::Level::Warning, title: "Low disk".into(), body: "2 GB left".into(),
    actions: vec![], key: Some(tidindi::DedupTag("disk".into())),
});                                   // posting "disk" again updates this notice
let rows: Vec<rodd::Row> = notices.rows();   // newest first; a Sjá list
```

- A deduplicated notice keeps its id and counts its postings (`(×3)` in its row).
- The row's text is `level: title: body`, which is what search, copy and the accessibility tree see; the level's mark
  uses the standard faces (`shadow`, `warning`, `error`).

**Enforced by:** the conformance test. Owner: `tidindi`. Conformance: `crates/std/tidindi/tests/conformance.rs`.

**Why.** Every ad-hoc notification is one more place that cannot be searched, silenced or read by a screen reader.
