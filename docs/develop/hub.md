# The hub and the gateway

User docs: [Agents → The hub and the gateway](../guide/agents.md#the-hub-and-the-gateway).

## Processes

- **The hub** (`core/drgnx-hub.el`): a batch Emacs started as a durable job (`drgnx-jobs-start "drgnx-hub" …`), one
  per drgnx data directory. Without a systemd user manager (always on macOS) the job is detached by
  `drgnx-jobs--detach`: `setsid -f`, or where there is no `setsid` (macOS) perl, which forks and calls setsid(2)
  itself — Emacs's child already leads its own process group, and setsid(2) refuses a group leader. Either way the
  hub leads its own session and process group and outlives the Emacs that started it. A job's pid is checked
  against the boot it was started in: Linux's `boot_id`, macOS's `sysctl -n kern.bootsessionuuid` (not
  `kern.boottime`, which moves when the clock is set). It gets the starting Emacs's drgnx and XDG directories and
  provider keys (when set) as its environment; under systemd only named variables pass (`--setenv=NAME`), so no
  value is ever in a command line.
  Its main loop is `accept-process-output` plus the event drain batch Emacs needs (queued events hold back
  sentinels). SIGTERM or `shutdown` removes its socket. It starts with SIGPIPE ignored (`trap '' PIPE`): the
  editing Emacs that launches it does not ignore it, and a write to a connection an agent closed must be an error,
  never the hub's end. The ACP agents it runs and their MCP servers (coordination, search) start the same way —
  `drgnx-command-ignoring-sigpipe`, `sh -c "trap '' PIPE; exec …"`, off Windows — because libuv resets SIGPIPE in an
  agent's children, and a write to a pipe whose reader left would otherwise end the server.
- **The gateway** (`core/drgnx-gateway.el`) runs inside the hub: never in the editing Emacs, so streaming cannot
  touch the keystroke budget.
- **curl**, one per forwarded request, reads its config on stdin (`-K -`): the URL, the provider's key header and the
  request body never appear in its argv.
  The config has `suppress-connect-headers`: behind an HTTPS proxy curl's `include` would otherwise print the
  proxy's CONNECT head first, and the gateway would take it for the provider's answer.

## The control socket

`drgnx-hub-socket`: `$XDG_RUNTIME_DIR/drgnx/hub-HASH.sock` (HASH: the first 8 hex digits of the SHA-1 of the data
dir), else `<state>/hub/hub-HASH.sock`; a path over 103 bytes (macOS's limit, the closing NUL included in 104; Linux
allows 107) — a deep state dir — moves to `drgnx-hub-UID/` in the temporary directory. The bytes are counted as the
system sees the name, encoded (`file-name-coding-system`: macOS decomposes "é" into 3 bytes).
Its directory is mode 0700 and must be the user's own. One JSON object per line:

| Request (`{"id", "method", "params"}`) | Result |
|---|---|
| `ping` | `{pid}` |
| `status` | `{pid, socket, gateway_port, registrations, started}` |
| `subscribe` | `true`; then events `{"event", "data"}` on this connection |
| `gateway/register` `{job, task, agent, chain: [[provider, model-or-null]…], budget, keys: {provider: key}}` | `{token, url}` |
| `gateway/unregister` `{token}` | `true` |
| `spend` `{job?, task?, agent?}` | `{input, output, cost, requests}` |
| `shutdown` | `true`, then the hub exits |

| `agents/start` `{profile, cwd, task?, job?}` | `{id, name}`: a session held by the hub |
| `agents/list` | `{sessions: [LISP…]}` (snapshots) |
| `agents/get` `{id}` | `{lisp, entries, seq}` (snapshot, the whole transcript, the change number) |
| `agents/send` `{id, text}`, `agents/stop` `{id}`, `agents/kill` `{id}` | `true` |
| `agents/permission` `{id, request, option}` | `true` — the user's answer: the only way a permission is answered |
| `agents/do` `{id, op, n?, text?, item?, reject?}` | `true`: `deliver-queue`, `unqueue`, `requeue`, `review` |
| `coord/notify` (a notification: no id, no answer) | delivery runs now ([coordination.md](coordination.md)) |
| `job/propose` `{plan, repo?, budget?, auto?}`, `job/approve` `{id, budget?}`, `job/stop` `{id}`, `job/resume` `{id, budget?}` | the job (`drgnx-job-summary`) |
| `job/status` `{id?, decisions?}` | the job (with its decision log when `decisions` is true), or `{jobs: [...]}` |
| `job/card` `{card, action, arg?}` | the job, after the user's action on a card (once: a settled card is an error) |
| `job/reply` `{message, text}` | `true`: the user's answer to an agent's message |

Errors: `{"id", "error": {"message"}}`. A line that is not JSON is answered with an error too when its `"id"` can be
read (otherwise it is dropped); a line over 1 MiB closes its connection. A subscriber that stops reading stalls the
hub once its socket's buffer is full: Emacs has no non-blocking write (`process-send-string` waits until it can
write); subscribers are Emacs process filters, which read as long as their Emacs runs.
Snapshots and transcript entries travel as **printed Lisp** (`lisp`,
`entries`): JSON would lose the difference between a symbol and a string in an entry; both ends are Emacs. Events: from the gateway `request` (job, task, agent, provider, model, status, input, output, cost), `fallback`
(agent, from, to, why), `budget` (job, spent, budget); from jobs `card` (id, job, task, kind, title), `job` (id: its status, tasks or open cards changed) and `fallback` (job, task,
agent, from, to, why); from sessions `agent` (id, seq, lisp — the snapshot) and
`agent-entries` (id, seq, entries: [[index, lisp]…], the entries new or changed since the last time — entries change
in place: chunks appended, tool calls updated), at most one of each per session per 50 ms; `lease-released` (task,
agent, job).

**Mirrors** (`core/drgnx-agents-mirror.el`): the editing Emacs keeps a `drgnx-agent-session` per hub session (`remote`
= its id) filled from these events; an action on a mirror goes to the hub (`drgnx-agents--remote`, never waiting).
A new Emacs fetches each transcript once (`agents/get`, which answers the session's change number `seq`) and keeps
the events that arrive meanwhile, then applies only those numbered after it — events and answers come on different
connections, so their order is not given; a snapshot (`agent`) or entries numbered at or before what a mirror has are
skipped, so an older snapshot never overwrites a newer one. A record that cannot be read (a session snapshot, a
transcript entry), or that is not a list (a number, a string), is skipped with a message; it never stops the records
after it.

One hub per socket: a second finds the first answering `ping`, or holding the lock — `SOCKET.lock/`, a directory
made atomically with the hub's pid — and exits with status 3 (a hub too busy to answer a ping keeps its socket); a hub that cannot start for any other
reason exits with status 1. A
lock whose process is gone (or a zombie) is taken over. A hub removes its socket and lock when it stops, and only if
the lock is still its own. Client side: `drgnx-hub-ensure` (start if needed; commands and the CLI only — it waits),
`drgnx-hub-call` (asynchronous), `drgnx-hub-call-sync`, `drgnx-hub-connect` (one subscription, even when called
again before the hub answers) + `drgnx-hub-event-functions`. The unit
runner sets `DRGNX_NO_HUB_START=1`: a test never starts a hub that would outlive the suite unless it unsets it (the
hub's own tests do, and stop what they start). It also sets `DRGNX_HUB_PARENT_PID` to its own pid, which a hub
inherits: a hub whose parent is gone exits (checked each second), so an interrupted run leaves none behind.

## Registrations

`gateway/register` returns a token of 64 hex digits (32 bytes of `/dev/urandom`). The hub keeps
`<state>/hub/registrations.eld` (mode 0600): `((SHA256-OF-TOKEN . REGISTRATION)…)` — never a token, never a key —
written to a temporary file beside it and renamed over it (a hub that dies mid-write leaves the old one whole), and
reads it back when it starts (a file it cannot read is logged: those agents register again); it also keeps the gateway's port (`<state>/hub/port`) and binds it again, so agents
keep working across a hub restart (when the port is taken meanwhile, a new one is used and the log says so). A
session's token is unregistered when its agent exits or is killed. Keys sent in `keys` live in the hub's
memory only (`drgnx-gateway-set-key`); after a restart they come again from the environment, quiet auth-source files,
or the next command that registers.

## Forwarding

The token is checked as soon as the request's head is whole (`drgnx-http-parse-head`): one that is not a registration
gets 401 at once, before the body (up to 32 MB) is waited for; a good token's body is kept as a list of pieces and
joined when its last piece came.

Only Anthropic Messages paths are forwarded — `/v1/messages`, `/v1/messages/count_tokens`, `/v1/models[/ID]`, with
a query, never `..` — and the URL built must keep the provider's host: a path cannot send the key elsewhere (404
otherwise). A provider can be carried when it has `:messages t` (it serves Anthropic's Messages API at its URL without `/v1`
plus the agent's path): the `openrouter`, `ollama` and `anthropic` presets. Its key goes as `Authorization: Bearer`,
or `x-api-key` with `:auth x-api-key`. The request's `content-type`, `accept`, `anthropic-version` and
`anthropic-beta` headers pass, with control characters (CR, NUL, …) stripped from names and values: curl's config would turn a CR into a header break; the body's top-level `model` is replaced when the chain step names one. The body goes to curl as a file
(`<state>/hub/bodies/`, 0700, each 0600, deleted when the request ends): curl takes no config line over about 10 MB.
Any error on the way answers the agent 500 `api_error` and closes the connection; one before curl starts (no curl, a
file that cannot be written) moves to the next provider. Nothing goes
to the agent until the upstream's head is whole: 1xx heads are skipped; 401, 402, 408, 409, 429, 5xx, or curl ending
first, try the next step (a `fallback` event) — except at the last step, whose own refusal is the answer: its status, its
`Retry-After` and its body pass through. Once the head went out there is no fallback: the rest streams through
(`Connection: close`, no length) and the connection closes when curl ends. An agent that hangs up kills its curl.

Spend: `drgnx-http-usage-scanner` follows the answer — SSE `message_start`/`message_delta` usage, or one JSON body's
`usage` (Anthropic or OpenAI names, `cost` when given); Anthropic's cache tokens count as what they cost — written
1.25×, read 0.1× an input token; without a cost, a provider's `:price (IN . OUT)` (USD per
million tokens) prices it. One `spend` row per request in `work.db` (schema 2). The budget is checked before
forwarding: a job whose spend reached its budget gets 429 `budget_exceeded` and a `budget` event; the request whose
spend reaches the budget sends that event as soon as its spend is recorded, so the job pauses without waiting for the
next request.
