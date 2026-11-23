# The extension API

**The rule.** The extension API is one WIT package, `drgnx:api` (`crates/ext/mal/drgnx.wit`). Both hosts, WebAssembly
components and Luau, are generated from it by `mal-gen` into `sattr`; nothing binds a function of the API by hand. A
change to the package needs the version bump it deserves.

**Doing it right.**

- Edit the WIT, then run the xtask's `wit-check`: it compares the file with the one at the last `api-v*` tag (no tag, nothing to
  compare; a tag whose tree lacks the file fails). An added case, field or flag at the end of an enum, record, flags or variant
  is additive. A removed or changed item
  needs a breaking bump, an added one an additive bump: from 1.0 the major and the minor version, below 1.0 (as cargo
  reads it) the minor and the patch version. Comments and docs are not the API.
- The editor implements the generated `Api` trait once; both hosts call it.
- Supported WIT: bool, the integers, floats, string, enum, and `result<T, enum>` or `result<_, enum>` as a result.
  `mal-gen` checks every position and refuses anything else with the WIT name.

**Who is calling.** Every `Api` method gets the `Caller` first: the extension's id, and the origin of the request it is
serving (an agent that has an extension act stays the agent). The editor (`sattr::editor::Editor`) decides on it:
namespaced command ids, notice keys and ids owned per extension (and a cap of 20), settings through
`set_by_extension`, no reserved keys, `commands.run` through the extension's door. Both hosts hold an extension to the
same `Limits`: Luau a step budget and a memory limit; a component fuel, a memory limit (a `ResourceLimiter`) and an epoch
deadline (the `wasm::ticker`). A panic that poisoned the API's lock stops the extension: no call after it succeeds.
`settings.set` takes `scoped-level` (stream, language, document, pane) and a scope id; `ask.choose` returns a question id and
the answer comes to `entry.answered`.

**The Luau side** (one contract):

- Functions live in `drgnx.<interface>.<name>`, also under `drgnx.<package>_v<version>.<interface>.<name>`;
  `drgnx.api_version` is the package version. Every table is read-only to scripts.
- An integer must be whole and in range; a 64-bit one exact up to 2^53 (Luau numbers are doubles): anything else is
  raised as an error, never rounded. A result above 2^53 is an error too.
- An API failure (`result<_, E>`) is returned, never raised: `nil, "kind"`; success is the value (or `true`) alone. A
  misuse (wrong argument, a busy API) is raised. A script's function that breaks the contract (`true, "kind"`, a lone
  `nil`, an unknown kind) is refused, never read as success.
- A call from inside a call is refused with an error, never a deadlock; a panic in the API does not poison later calls.

**Enforced by:** `wit-check` in CI, and the scan rule `no-hand-luau-binding` (an `impl … UserData` anywhere but
`sattr`). Owner: `sattr`. Conformance: `crates/ext/sattr/tests/conformance.rs` (every function of the world is bound,
from an independent read of the WIT).

**Why.** Two hosts bound by hand drift apart, and an API without a version cannot be kept compatible.
