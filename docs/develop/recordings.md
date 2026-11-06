# Live recordings

A live run of the agent system against real providers and outside agents costs credits and subscription share. A
**recording** captures what the outside ends sent, so the run can be replayed as often as needed for nothing: drgnx
itself (the hub, the gateway, the editor) runs for real on replay, and only the outside ends come from the recording.
Providers and outside agent CLIs are outside services, so a recording of them is a mock; nothing of drgnx's is
recorded in place of running it.

This page covers what is built so far: the file format, the normalizers and the match key, the secret scrub and its
lint, the gateway's tap and the LLM replayer. The ACP side (outside agents, their MCP calls and worktree effects) and
the `bin/drgnx record` / `replay` commands come next; until then a run is recorded and replayed with the hub's
environment variables below.

## Turning it on

Recording and replay are a hub's start-up mode, never a setting: a setting left on would record every day, and a
recording is one run on a fresh state root.

| Variable | Meaning |
|---|---|
| `DRGNX_RECORD=DIR` | record this run into DIR (made; a DIR that holds a recording already is refused) |
| `DRGNX_RECORD_PROVENANCE` | `mock` (made from the scripted mocks) or `live` (the default) |
| `DRGNX_REPLAY=DIR` | replay the run in DIR |
| `DRGNX_REPLAY_SPEED` | the chunks' recorded gaps times this (default `0`: no waits; `1`: live pace) |
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
```

`manifest.json` is written at start: `{format: "drgnx-recording", version: 1, normalize: 1, scrub: 1, status:
"incomplete", provenance: "mock" | "live", started, ended, drgnx_commit, nidhogg_version, build: "release" | "test",
adapters, providers, profiles, worktree, connections, caps, spend, lint, roots}`. `roots` names the run's state, data,
home and temp directories (`{"$STATE": PATH, …}`), so a replay elsewhere can normalize the recorded bodies. The fields
`record stop` fills (`status`, `ended`, `spend`, `lint`, …) stay at their start values until that command exists. A
reader refuses an unknown `format` or a higher `version` (`runstav::recording::check_manifest`).

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
  provider's base becomes `http://127.0.0.1:PORT/p/ID` on the replayer, keyless).
- `runtime/conformance/src/bin/ratatoskr-mock.rs`: `llm --replay DIR [--speed N] [--misses FILE] [--parent PID]`.

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
  run), `record-and-replay-refused-together`.
