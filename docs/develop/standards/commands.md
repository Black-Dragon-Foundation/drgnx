# Commands

**The rule.** Every action of the editor is a command in `bod`'s registry: an id, a title, a doc, its arguments, its
source and its exposure. Keys, the palette, the cheat sheet and the agents' tools are read from it; nothing keeps a
second list.

**Doing it right.**

```rust
bod::command! {
    id: "buffer.save",
    title: "Save buffer",
    doc: "Write the buffer to its file.",
    args: bod::ArgSpec::NONE,
    exposure: bod::Exposure::Palette,      // Palette | Agent | KeyOnly
    handler: |cx, args| { /* … */ Ok(serde_json::Value::Null) },
}
let r = bod::Registry::linked()?;          // every `command!` of the program
r.run("buffer.save", args, &mut bod::Cx::user())?;
r.find_source("buffer.save")?;             // file and line of the definition
```

- A second command with an id already taken is a `Conflict` that says where the first is.
- `Registry::advise(id, bod::advice(|cx, args, next| …))` wraps a handler; `unadvise` takes it off. The last advice added
  is the outermost.
- An agent runs only a command exposed to agents (`Exposure::Agent`); those are `bod::tool_specs`, plain descriptions
  (name, text, JSON schema) that the agent runtime turns into its own tool type. `bod` depends on no hub crate.

**Who may run a command.** A call carries who started it (`Cx::origin`: the user, an agent, an extension) and, when it
comes through an extension, which one (`Cx::via`). An agent runs only `Exposure::Agent` commands. A call through an
extension runs only `Exposure::Extension` commands (which the palette and the tools do not list). The origin that started
the chain stays: an agent that has an extension run a command must pass both doors, and no exposure does, so it is
refused (the confused deputy).

**Enforced by:** the scan rule `command-has-doc` (a `command!` with no `doc:`, or an empty one, is a finding), and the
registry itself (a title and a doc are required at registration). Owner: `bod`. Conformance:
`crates/std/bod/tests/conformance.rs`.

**Why.** A command that is not in the registry has no key, no palette entry, no doc and no agent tool; a registry that
holds only some commands means every list is a guess.
