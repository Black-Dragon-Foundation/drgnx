# Pair mode: how each agent's edits reach the door

Pair mode lets a chat edit your own checkout live (user guide: `docs/guide/pair-mode.md`). The sandbox does not change
for it: Gleipnir binds the checkout **read-only** for every chat, so the only way a chat's edit reaches a file is the
hub's door, which sends it to the editor that has the file open. This page records, per agent, which of its edit
shapes reach the door, which of its own write tools exist and how each is turned off, and what a blocked native write
returns. The rows under `test/conformance/pair/` prove it with the mock agents; how often a real model reaches for its
native tools is measured once in the combined live proof, never against a subscription here.

## The door is per session

A call on a session's socket always speaks for the session that owns it, so one chat cannot write as another:

- **The socket is the session.** `mcp/session` mints `mcp.sock` in the session's own directory (`<socket
  dir>/s/SID/`); the tools on it act as `Row::identity()`, fixed when it was minted (`sessions.rs`). The agent
  socket `hub.sock` beside it is `Socket::Agent {sid}`, whose class and caller are fixed the same way (`hello.rs`).
- **The sandbox shows only its own directory.** The launch binds `s/SID/` read-only and nothing else of `s/`
  (`sandbox::session_spec`; Gleipnir refuses `s/` itself or another session's directory as a source,
  `sandbox::tests::an_agent_session_dir_reaches_nothing_else_beside_the_socket`).
- **No tool takes a session id.** The guard refuses `session` and `sid` arguments, with `agent`, `from`, `sender`,
  `as` and `identity`, before any tool runs (`norn::tools::guard::IDENTITY_ARGS`): `session: tools never take an
  identity`.

Proofs: `launch_sandboxed::hub_socket_identifies_its_session` (a real sandboxed child sees its own `mcp.sock` and not
another session's; `hello` through it names its own agent; a call naming the other session is refused) and the row
`pair/a-call-on-the-socket-is-the-owning-session` (two chats; one names the other's session id, refused).

## Per agent

| Agent | Edit shapes that reach the door | Its own write tools, and how each is off | A blocked native write returns |
|---|---|---|---|
| Claude (claude-agent-acp) | the drgnx MCP tools `edit_file {path, old, new}` and `write_file {path, content}`; reads through `read_file {path}` | `Edit`, `Write`, `MultiEdit`, `NotebookEdit`: in `_meta.claudeCode.options.disallowedTools` of every chat in a project, from its start (they take effect only when Claude's query process starts, so toggling them would rebuild the session; pair is gated at the hub instead). `Bash` stays: a shell write gets `EROFS` | `EROFS` (`Read-only file system`, os error 30) for a shell or process write; a disallowed tool is not offered to the model |
| Gemini (gemini-cli ACP) | ACP `fs/write_text_file` (its `write_file` and `edit` tools inside the root use the client's file system, `AcpFileSystemService`), `fs/read_text_file` for reads; the drgnx MCP tools too | none needed: inside the root its writes are ACP requests the hub answers. Its tools make missing parent folders natively first, which fails on the read-only bind, so the door makes them for an allowed write | `EROFS` for its shell tool or a native `mkdir` |
| Codex (codex-acp) | the drgnx MCP tools `edit_file`, `write_file`, `read_file` | `apply_patch` and shell writes: every Codex chat runs in the `read-only` mode its lock asks for (and the adapter must report), so a shell write gets `EROFS`; an `apply_patch` it asks permission for in a project chat is refused by the hub, never approved (an approved patch would run outside Codex's sandbox) | the refusal entry: "this chat edits your project through drgnx: use edit_file {path, old, new} or write_file {path, content}"; `EROFS` for a shell write |
| Kimi (kimi acp) | the drgnx MCP tools `edit_file`, `write_file`, `read_file` | `Write` and `Edit`: denied by user rules the hub adds to the lock's `config.toml` in every project chat. Kimi's plan mode is refused while the lock holds (its plan-file writes skip the hooks), so no write is left unseen | the tool is denied without asking; `EROFS` for a `Bash` write |
| DeepSeek | filled by its own task (its lock, the fork's ask plugin) | | |

Rows: `pair/native-edit-blocked-claude`, `pair/native-edit-blocked-gemini`, `pair/native-edit-blocked-codex`, `pair/native-edit-blocked-kimi` (a release hub, the real sandbox: a native
write of `README` in a project chat fails with `EROFS` and the file is unchanged). The routing rows of the door
itself (every edit shape reaching it with the native tools off) are `pair/proof-claude`, `pair/proof-gemini`, `pair/proof-codex` and `pair/proof-kimi`; `pair/kimi-plan-mode-refused-while-paired` covers Kimi's plan mode.

## What the result decides

- Every project chat, paired or not, starts with the drgnx edit tools and, for Claude, its native edit tools
  disallowed; Claude's native `Read` stays allowed, so a whole-file write is refused unless the hub served the read
  it is based on (the refusal names `read_file`).
- A chat's ACP `fs/*` calls with a path inside the checkout go to the door; every other role keeps the session fence
  and the inline write.
- Gemini's shapes need nothing turned off; Claude's need the four tools disallowed. Both proof rows cover the two.
