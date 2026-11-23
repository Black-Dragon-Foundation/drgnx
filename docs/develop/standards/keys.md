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

**An extension's bindings** (the API's `keys.bind`) name its own commands (`ext/<extension>/…`) or commands exposed to extensions, never
the editor's, and may not be the start of a chord that is bound (`C-x` over `C-x C-f`).

When a profile is layered after an extension's binding (`Keymap::layer`), the prefix check runs again: an extension binding that
the profile makes a prefix is dropped, and the editor posts a notice naming the extension and the command.

**Contexts.** The prefix checks (`bind_by`, `layer`) compare two bindings only when they have the same context: a binding for
Rust files is not a prefix of one for Go files. An extension also may not bind a chord that *extends* a bound chord (A binds
`C-y`, B asks for `C-y C-z`: `C-y` is reached first, so B's chord could never run); that is refused with `refused`, in
the same context only.

**The user rebinds a clash without touching the extension.** Every binding an extension asks for is kept as a `Wanted`
(extension, command, chord, context, and what became of it: bound, refused, dropped, rebound or unbound). A refused or dropped
one comes with a notice and the action "Bind to another key…": the user types a chord (a prompt is fine, the user asked for it)
and `Keymap::rebind_by_user` writes it to the user's own level as an `Override` (extension command, the chord it asked for,
the chord chosen), never to the extension. The user's level wins over every extension; the override is keyed by the command and
the chord asked for, so it holds when the extension reloads (`unload_extension`, then its `keys.bind` meets the override and is
accepted, not refused) and when it updates. `unbind_by_user` removes an extension's chord the same way. `Keymap::overrides()` and
`set_overrides` are for the host to keep the user's level.

**The shell's keys.** `KeyEvent::from_skel` turns skel's raw key event (a keysym and the modifier mask) into a `KeyEvent`: a
character is itself with the case it produced; with `ctrl` or `alt` it is the plain letter, with `shift` as a modifier;
a named key carries `shift`; a release or a bare modifier is none.

**Enforced by:** the scan rule `no-raw-key-event` (a path into skel's key event types, or `Event::Key`, anywhere but
`lykill`), and the layer rows that keep the UI crates off huginn. Owner: `lykill`. Conformance:
`crates/std/lykill/tests/conformance.rs`.

**Why.** A second place that reads keys is a second keymap, which the cheat sheet and find-the-source cannot see.
