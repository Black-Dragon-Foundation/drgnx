# Live recordings

A live run of the agent system against real providers and outside agents costs credits and subscription share. A
**recording** captures what the outside ends sent, so the run can be replayed as often as needed for nothing: drgnx
itself (the hub, the gateway, the editor) runs for real on replay, and only the outside ends come from the recording.
Providers and outside agent CLIs are outside services, so a recording of them is a mock; nothing of drgnx's is
recorded in place of running it.

This page covers what is built so far: the file format, the normalizers and the match key, the secret scrub and its
lint, the gateway's tap and the LLM replayer, and the ACP side: the outside agents' pipe, their MCP calls, their
worktree effects and the ACP replayer. The `bin/drgnx record` / `replay` commands come next; until then a run is
recorded and replayed with the hub's environment variables below.

## Turning it on

Recording and replay are a hub's start-up mode, never a setting: a setting left on would record every day, and a
recording is one run on a fresh state root.

| Variable | Meaning |
|---|---|
| `DRGNX_RECORD=DIR` | record this run into DIR (made; a DIR that holds a recording already is refused) |
| `DRGNX_RECORD_PROVENANCE` | `mock` (made from the scripted mocks) or `live` (the default) |
| `DRGNX_REPLAY=DIR` | replay the run in DIR |
| `DRGNX_REPLAY_SPEED` | the chunks' and the agents' recorded gaps times this (default `0`: no waits; `1`: live pace) |
| `DRGNX_REPLAY_STRICT` | `1`: an agent replay that leaves recorded lines unused when it ends is a miss |
| `RATATOSKR_MOCK` | the `ratatoskr-mock` to replay with (default: the one beside the `ratatoskr` binary) |

Both `DRGNX_RECORD` and `DRGNX_REPLAY` at once is refused at start (exit 1, said in the hub log), and so is a replay
of a directory that is not a recording, or one with a newer format version. `status` gains `recording: {mode: "record"
| "replay", dir}`, and the hub log says the mode once at start. Recording works in release builds: a live run must
exercise the real sandbox, proxy and gateway relay.

## The files

One directory per run, append-only while recording: each line is flushed as it is written, so a killed run leaves a
usable prefix.

```
<run>/manifest.json      format, version, status, provenance, roots, connections, caps, spend
<run>/llm.jsonl          gateway exchanges, one line per attempt
<run>/acp/<n>.jsonl      one per agent process, n in spawn order
<run>/effects/<n>-<seq>/ worktree changes: files/…, deleted.txt, commits.bundle
```

`manifest.json` is written at start: `{format: "drgnx-recording", version: 1, normalize: 1, scrub: 1, status:
"incomplete", provenance: "mock" | "live", started, ended, drgnx_commit, nidhogg_version, build: "release" | "test",
adapters, providers, profiles, worktree, connections, caps, spend, lint, roots}`. `roots` names the run's state, data,
home and temp directories (`{"$STATE": PATH, …}`), so a replay elsewhere can normalize the recorded bodies. The fields
`record stop` fills (`status`, `ended`, `spend`, `lint`, …) stay at their start values until that command exists. A
reader refuses an unknown `format` or a higher `version` (`runstav::recording::check_manifest`).

While the run goes on, the hub rewrites the manifest (whole, through a temporary file) as agents start: each
connection is `{n, profile, argv (scrubbed), spawned_ms, sid, job, opens_with, forked_from?}`, where `sid` and `job`
are the hub session it serves (its gateway exchanges carry one of them as `session`), `opens_with` its first session
request (`session/new`, `session/fork`, `session/load`, `session/resume`; none for a probe) and `forked_from` `{n,
session}` the connection that opened a fork's source. `adapters` lists each `initialize` answer's `agentInfo` `{name,
version}` once.

Every line of every stream has `seq` (one counter for the whole run, taken when the exchange begins) and `t_ms`
(milliseconds since the run started), so streams interleave in their true order.

`llm.jsonl`, one line per attempt the gateway sent, written when the attempt ends:

```
{seq, t_ms, id: "x1", session?, provider, model, path, attempt, of, key,
 request: {headers, body}, client: {body}?,
 response: {status, headers, head_ms, chunks: [[dt_ms, text]…], end, at_chunk?}}
```

- `path` is the client's: an agent's target (`/v1/messages?beta=true`) or the editor's REST (`/chat/completions`).
- `attempt` of `of`: the chain step (the editor's route is 1 of 1). A fallback's 429 is its own line, with its head
  and no chunks (its body is never read).
- `request.body` is what went upstream (after the gateway's rewrite); `client.body` is the client's own body, only
  when the rewrite changed it.
- `response.status` is 0 when the provider gave no head. `chunks` are the bytes as read from upstream, text when UTF-8,
  else `{b64}`; `dt_ms` is the gap since the head or the chunk before. `end` is `complete`, `dropped` (upstream broke
  off, or no head), `client-left` (with `at_chunk`, the chunks passed on before the client hung up) or absent (the hub
  stopped with the attempt open).
- Bodies are stored scrubbed but not normalized. `key` is the match key at record time, for reading; a replay
  recomputes every key with the current normalizers, so a normalizer fix never needs a re-record.
- `session` is the hub session the request is for: the one whose socket it came in on, else the job its loopback
  registration is booked under (a session's own id when it has no job); none for the editor.

`acp/<n>.jsonl`, one per agent process (probes too), `{seq, t_ms, dir, msg}`:

| `dir` | `msg` |
|---|---|
| `in` | a line the hub sent the agent (scrubbed JSON-RPC) |
| `out` | a line the agent sent the hub |
| `mcp` | `{tool, args, result: {text, structured} \| {error}}`: the agent's call of the hub's MCP tool, at the session's socket, written when it ends |
| `effect` | `{path: "effects/<n>-<seq>", head?}`: the worktree's changes, written before the line that completes the tool call or the turn |
| `exit` | `{code, signal, stderr}` (the tail, scrubbed), once, last |

- **The pipe.** hermod's line tap (`ConnOpts::tap`, [runtime.md](runtime.md#hermod-the-acp-client)) sees each line
  before it is written or handled; a connection's lines take their `seq` one at a time, in the order they passed.
- **MCP calls.** An outside agent calls drgnx's tools through the stdio server in `mcpServers`, which reaches the
  session's MCP socket: those calls never cross the ACP pipe, so the socket's tools note each call into the session's
  latest connection's stream (`sessions.rs`'s `AfterTool`).
- **Effects.** An outside agent's own tools (Bash, the adapter's writes) change the worktree inside its process. At
  each `tool_call_update` that completes (or fails) a tool call, and at the answer that ends a turn, the tap looks at
  the session's cwd: its files (a repository's tracked and unignored ones, else every file but `.git`'s, at most
  20 000) by size and modification time, and its head commit, against the last look (the first at spawn). Changed
  files go to `files/` (text through the scrub), removed ones to `deleted.txt`, new commits to `commits.bundle`
  (`git bundle create … HEAD ^OLD`) with the new `head` in the line. Nothing changed: no line. The look runs on the
  connection's reader, before the line that completes the call is noted, so the effect's `seq` is lower. Only the
  session's own worktree is covered.

## Matching

**The key** of an LLM request (`runstav::recording::key`) is SHA-256 of the canonical, normalized, pattern-scrubbed
object `{route: "PROVIDER PATH", model, system, messages, tools, tool_choice, stream, max_tokens, temperature,
thinking, prompt, suffix, input, inputs, input_prefix, input_suffix, input_extra}` (the fields the request has; a body
that is not a JSON object keys on its text). `metadata` (Claude's `user_id`) and every other field are recorded but
not keyed. The n-th live occurrence of a key answers the n-th replayed one; one more is a miss.

**The normalizers (version 1)**, applied to both sides, in this order, over every string:

1. the run's roots → `$STATE`, `$DATA`, `$HOME`, `$TMP` (longest first, at a path boundary); other `/tmp/` paths whose
   first part has a digit → `$TMP/…`;
2. the hub's own ids → `$SID1`, `$JOB1`… (a session `a` + 12 hex, a job `x` + 11 or more hex, whole words);
3. UUIDs → `$UUID1`…;
4. RFC 3339 times and plain dates, and any value under `ts`, `created`, `timestamp` or `resetsAt` → `$TIME`;
5. `127.0.0.1:PORT` and `localhost:PORT` → `$PORT`;
6. keys sorted, whitespace dropped (`canonical`). Git object ids are not touched.

Ids and UUIDs are numbered by first appearance within one normalizer's input. For the LLM key that is one request:
requests can interleave differently on replay, so numbering across them would let one late request change every
later key.

## A miss

`ratatoskr-mock llm --replay DIR` answers a request it has no unused exchange for with 500, the header
`x-drgnx-replay: miss` (the gateway passes on only the status, `Content-Type` and `Retry-After`) and

```json
{"type":"error","error":{"type":"replay_miss","message":"not in the recording RUN: MODEL, N messages; nearest x12 differs at messages[3].content[0].text; re-record"}}
```

The nearest exchange is the one on the same route whose keyed object differs in the fewest places; the path is the
first place it differs. The request (scrubbed) and that path are appended to `misses.jsonl` in the replay's scratch
directory (`$DRGNX_RUN_TMP/replay/`, else `$TMPDIR/replay/`), never into the recording. It never improvises an
answer.

**Partial streams.** The replayer answers chunked, so a drop is visible: `dropped` and an exchange with no `end` send
their chunks and then drop the connection; `client-left` sends the chunks up to where the client left and waits for it
to leave again (still there after 30 s is a miss line). A recorded status 0 drops the connection with no head.

## The ACP replayer

On replay every agent profile's command becomes `ratatoskr-mock acp --replay DIR --as KIND --misses FILE --roots JSON
--speed N [--strict]` (KIND from the profile's provider, which is kept, so the lock and version-gated behaviour are
live's; the adapter's name and version come from the recorded `initialize` answer). The hub, its MCP socket and the
gateway run for real; only the agent's process is the recording. The scratch directory is `$DRGNX_RUN_TMP/replay/`
(the misses file and `claims/`, which the hub empties at start).

- **Streams.** Each `acp/<n>.jsonl` is one connection; the session's first-attempt gateway exchanges from `llm.jsonl`
  (`session` its `sid` or `job`, within the connection's lines) join it at their `seq`. `in` lines are expectations,
  every other line an action.
- **The causal rule.** An action is taken once every expectation before it (by `seq`) has arrived and matched, after
  its recorded gap times `--speed`. Expectations are matched in order within an ACP session and freely across sessions
  (an answer to the agent's own request belongs to that request's session). A message matches on its method and
  params, an answer on its result or error, both normalized (the recorded side with the manifest's roots, the received
  side with `--roots` after the scrub; on each side `$WT` is the cwd its session opened in). JSON-RPC ids are mapped:
  an answer goes out with the hub's id for the request; the agent's own requests go as recorded.
- **Claims.** A new process answers from every unclaimed connection that has matched so far (the lowest's actions;
  they agree up to the session request) and claims the lowest at its first session request, by creating
  `claims/<n>`. A fork into a new process and a resume after a hub restart are the same case: the next process takes
  the next connection that opens like that.
- **Actions.** `out` is written. `mcp` calls the tool through the session's first `mcpServers` entry, as the hub gave
  it on replay. `effect` writes the files into the session's cwd, removes the deleted ones, unbundles the commits and
  moves `HEAD` to the recorded head (`update-ref`, then `read-tree HEAD`), so a later `fs/read_text_file` answer, the
  hub's snapshot of the step, the diff and the commit hashes are live's; a head that cannot be restored (the worktree
  did not start where live did) is a miss. `llm` POSTs the client's recorded body to the agent's own
  `$ANTHROPIC_BASE_URL` with `$ANTHROPIC_AUTH_TOKEN`, so the real gateway forwards it to the LLM replayer and writes
  its spend rows; an outside agent's prompts are re-sent as recorded, never rebuilt. `exit` with a code other than 0
  ends the process with that code and stderr; a clean exit waits for stdin to close.
- **A miss** answers the unmatched request with JSON-RPC error -32099 (`replay miss: WHAT differs from the recorded
  line at PATH; re-record`), appends `{connection, code, why, path, expected, received}` to the misses file and exits
  3, which the hub shows as the agent ending. A message no unclaimed connection expects, a session request no
  unclaimed connection opens with, and (with `--strict`) recorded lines left unused when stdin closes are misses too.

## The scrub

At write time, in the recorder; nothing is written and removed later.

1. **Headers by allowlist** (`HEADERS`): `content-type`, `accept`, `anthropic-version`, `anthropic-beta`,
   `retry-after`, `x-request-id`, `x-generation-id`. No `authorization`, `x-api-key`, cookie or proxy header is ever
   stored, and the gateway hands the tap no sensitive header at all.
2. **Environment values by name** (`ENV_NAMES`: `PATH`, `HOME`, `LANG`, `TERM`, `NO_PROXY`, the `XDG_*` dirs, …)
   wherever an `env` appears (an object of names, or ACP's list of `{name, value}`), and `NAME=VALUE` words of an argv
   (`Scrub::argv`). Other values → `$SECRET`.
3. **Exact values:** each provider key, inside bifrost (`Keys::scrub`, so a key never leaves the keys module), over the
   bodies and each chunk; each gateway token the hub issues, told to the recorder at issue
   (`recording::secret`; the registry holds only hashes).
4. **Patterns** (`find_secrets`): `sk-or-v1-…`, `sk-ant-…`, `sk-…` (with a digit or a capital), `ghp_`/`gho_`/`ghu_`/
   `ghs_`/`ghr_`/`github_pat_`, `AKIA…`, `xoxb-`/`xoxp-`, the token after `Bearer `, JWTs, `-----BEGIN … PRIVATE
   KEY-----` blocks, the value of `CLAUDE_CODE_OAUTH_TOKEN=` → `$SECRET`.

## The lint

`runstav::recording::lint_run(DIR)` scans every file of a run, binary ones too, for rules 1 (a stored header name of
the never list), 2 (an `env` value kept that is not allowlisted) and 4, plus secret-looking values (16 or more key
characters, two classes, 3 bits a character) under key-, token-, secret- or password-named fields; a stream line's own
`key` is the match key and exempt. A finding names the file and byte offset, the kind and the first four characters,
never the value:

```
llm.jsonl:1234: key-prefix (sk-o…)
```

It also fails a run over 25 MB, and **a recording under a repository's `test/fixtures/recordings/` whose manifest is
not `provenance: "mock"`** (`not-mock`): repository fixtures are made only from the scripted mocks; live recordings stay
in the developer's own folder and never enter a public repository. Screenshots cannot be linted: a smoke run never
shows a key on screen.

## Code

- `runtime/crates/runstav/src/recording.rs`: the format's constants and manifest, the normalizers, the key, the scrub,
  the lint. Std, serde_json and sha2 only, so the std-only replayer shares it.
- `runtime/crates/bifrost/src/engine.rs`: the `Tap` trait (`Gateway::set_tap`): `begin(Sent)` per sent attempt (the
  body and the client's body key-scrubbed, the headers without the sensitive ones), then `head`, each `chunk` and
  `end(End::{Complete, Dropped, ClientLeft { chunk }})`. The exchange is ended before the upstream body is dropped.
- `runtime/crates/drgnx-ratatoskr/src/recording.rs`: `DRGNX_RECORD` / `DRGNX_REPLAY` at start, the `Recorder` (the
  run's clock, `seq`, one writer thread, the scrubber), the replayer's start and the provider substitution (every
  provider's base becomes `http://127.0.0.1:PORT/p/ID` on the replayer, keyless); the ACP tap (`acp_tap`: the
  connection's number, the manifest's entry, the lines, the exit and the effects), `mcp` and the profile
  substitution (`replayed_profile`).
- `runtime/crates/hermod/src/types.rs`, `conn.rs`: `LineTap`, `Dir`, `ConnOpts::tap`.
- `runtime/crates/drgnx-ratatoskr/src/agents/session.rs` (`launch` gives every connection its tap; `prepare` takes
  the replayed profile), `agents/probe.rs` (a probe's connection is tapped too), `sessions.rs` (`AfterTool` notes
  each MCP call).
- `runtime/conformance/src/bin/ratatoskr-mock.rs`: `llm --replay DIR [--speed N] [--misses FILE] [--parent PID]`;
  `runtime/conformance/src/mock_acp/replay.rs`: `acp --replay DIR --as KIND [--speed N] [--misses FILE] [--roots
  JSON] [--strict]`.

## Tests

- `cargo test -p runstav --lib recording::` (pattern D, pure): `normalize_is_stable_over_ids_paths_and_times`,
  `key_ignores_metadata_user_id`, `scrub_removes_keys_tokens_and_header_values`, `lint_names_file_and_kind_not_value`,
  `manifest_refuses_a_newer_version`. Their fake keys are built from two parts, so the repository's leak hook never sees
  a whole one.
- `cargo test -p bifrost --test engine` (pattern C): `a_tap_sees_every_attempt_with_its_chunks` (a 429 then a streamed
  200: two lines, no auth header, the key scrubbed, instants in order) and `a_hang_up_is_recorded_as_client_left`.
- domr rows `test/conformance/recording/` (pattern B): `llm-round-trip` (an editor stream recorded against the mock,
  replayed with no mock: the same body, a second equal spend row), `llm-miss-fails-loudly` (one changed message: 500
  `replay_miss`, the nearest path, a misses line), `no-key-on-disk` (neither the key nor the token in any file of the
  run), `record-and-replay-refused-together`. The agent rows (`requires` `test-hooks`: an unsandboxed launch) record
  a mock agent, put the worktree and `work.db` back where the run started, and replay on a second hub:
  `acp-round-trip` (an edit, a permission the user allows, a decision through the MCP tool, a commit: the same
  transcript, decision row, file and commit hash), `acp-miss-fails-loudly` (another prompt text: -32099, exit 3, a
  misses line with the path), `acp-gateway-resend` (a gateway profile with `--llm env`, the llm mock killed: the
  replay writes the same spend row through the real gateway), `effects-land-before-the-tool-call-completes` (the
  replayed edit step has the live snapshot, checked while the replayer waits for the permission answer after it).
  `acp-fork-in-a-second-process` (pattern C) replays a two-process recording made from the mocks with the row as the
  hub: the first process claims connection 1, a second one skips it and claims the fork's connection 2, a third
  finds nothing unclaimed (-32099, exit 3).
- `cargo test -p hermod --test conn` (pattern C): `a_tap_sees_both_directions_in_order`.
