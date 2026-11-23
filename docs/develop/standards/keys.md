# Keys

**The rule.** Keys go through `lykill`: one engine, profiles read from `.eld` files, contexts as expressions. Nothing
else reads the shell's raw key events.

**Doing it right.**

```rust
let profiles = lykill::Profiles::load(&keys_dir)?;            // emacs.eld, vscode.eld, …
let keymap = lykill::Keymap::from_profile(profiles.get("emacs").unwrap());
match keymap.resolve(&chord, &cx) {                           // Command(id) | Prefix | None
    lykill::Resolution::Command(id) => registry.run(&id, args, &mut cx)?,
    lykill::Resolution::Prefix => { /* wait for more keys */ }
    lykill::Resolution::None => {}
}
```

A profile is `(drgnx-keys :version 1 (COMMAND KEYS)…)`. KEYS is `"C-x C-f"`, or a list of them, each either that text or
`("keys" "context")`. Both spellings are the same keys: `C-x C-f` and `ctrl+x ctrl+f`.

A context is the design's expression over the terms of the document, view, pane and features:
`language == rust && view == excerpts && !readonly`. The language has `==`, `!=`, `&&`, `||`, `!`, parentheses,
identifiers and string or bool literals, and nothing more. A bare word on the right of `==` is a string. A later
binding wins; a command beats a prefix.

A `Session` holds the chord typed so far; a prefix that waits longer than its timeout is dropped (on the `stund` clock,
so a test moves it by hand).

**Reserved keys.** `lykill::RESERVED` (cancel `C-g`, `M-x`, the palette's `ctrl+shift+p` and `f1`) cannot be bound, or
started a chord with, by an extension: `Keymap::bind_by` refuses an extension origin with `Refused`.

**Enforced by:** the scan rule `no-raw-key-event` (a path into skel's key event types, or `Event::Key`, anywhere but
`lykill`), and the layer rows that keep the UI crates off huginn. Owner: `lykill`. Conformance:
`crates/std/lykill/tests/conformance.rs`.

**Why.** A second place that reads keys is a second keymap, which the cheat sheet and find-the-source cannot see.
