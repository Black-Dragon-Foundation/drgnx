# Settings

**The rule.** A setting is defined once in `skipan`, with a kind, a default and a doc, and is read from there. Its
value comes from the stack of levels, most specific last: built-in, user, machine, project, stream, language, document,
pane. Any setting answers "why do I have this value?".

**Doing it right.**

```rust
settings.define("editor.tab-width", skipan::Kind::Int, json!(8))?;
settings.attach(skipan::Level::User, user_file)?;        // also machine and project
settings.reload()?;                                      // files are read through huginn
let snap = settings.snapshot();                          // a command reads ONE snapshot
let w: i64 = snap.get("editor.tab-width")?;
let why = snap.provenance("editor.tab-width")?;          // level, and file:line for a file
settings.set("editor.tab-width", json!(4), skipan::Level::User)?;   // the file is replaced atomically
settings.set_scoped("editor.tab-width", json!(2), skipan::Level::Language, "rust")?;
```

- A settings file is `(drgnx-settings :version 1 (KEY VALUE)…)`; it is written only through `Settings::set`.
- Stream, language, document and pane values belong to one stream, language, document or pane; `snap.get_in(key,
  &Scope{ language: Some("rust".into()), .. })` reads for that scope.
- A snapshot never changes: a reload or a `set` while a command runs does not alter what it sees. `Settings::watch`
  announces the keys that changed.
- A bad entry is reported with its file and line and the rest of the file stands; a file that does not parse keeps its
  level as it was; a failed write changes nothing in memory.

**Extensions** set values through `Settings::set_by_extension(extension, key, value, level, scope_id)`, which takes the
scoped levels only: the user's levels (user, machine, project) and the built-in one are refused. The value is kept in
memory, never written to a file, and its provenance names the extension.

**Enforced by:** the layer rows (a UI crate may not depend on huginn: files are read through skipan), and the
conformance test. Owner: `skipan`. Conformance: `crates/std/skipan/tests/conformance.rs`.

**Why.** Settings read from a second place have no provenance and no reload; a value read twice in one command can
change between the reads.
