# The hub and the gateway

User docs: [Agents → The hub and the gateway](../guide/agents.md#the-hub-and-the-gateway).

## Processes

- **The client** (`core/drgnx-hub-client.el`, feature `drgnx-hub-client`): everything an editor, the CLI or the
  sandbox needs to talk to a hub, and nothing of the hub's runtime — the socket path and its trust check, the line
  protocol, `drgnx-hub-call` / `-call-sync`, the event subscription, `drgnx-hub-ensure` (which starts the hub),
  the write queue and `drgnx hub start|stop|status`. It requires only `cl-lib`, `subr-x`, `drgnx-paths`, `drgnx-jobs`
  and `drgnx-guard` (the AI provider list comes from `drgnx-ai`, which the caller has loaded). Editor files require
  this and never `drgnx-hub`; `drgnx-agents.el` calls the server's `drgnx-hub-serving-p` and `drgnx-hub-register` only
  when `(featurep 'drgnx-hub)`. The message prompt both the cockpit preview and the hub's delivery use is
  `drgnx-coord-message-prompt` (`core/drgnx-coord.el`). A `declare-function` of a client function names
  `"drgnx-hub-client"`.
- **The hub** (`core/drgnx-hub.el`, the server half; it requires the client): a batch Emacs started as a durable job (`drgnx-jobs-start "drgnx-hub" …`), one
  per drgnx data directory. Without a systemd user manager (always on macOS) the job is detached by
  `drgnx-jobs--detach`: `setsid -f`, or where there is no `setsid` (macOS) perl, which forks and calls setsid(2)
  itself — Emacs's child already leads its own process group, and setsid(2) refuses a group leader. Either way the
  hub leads its own session and process group and outlives the Emacs that started it. A job's pid is checked
  against the boot it was started in: Linux's `boot_id`, macOS's `sysctl -n kern.bootsessionuuid` (not
  `kern.boottime`, which moves when the clock is set). It gets the starting Emacs's drgnx and XDG directories as its
  environment (under systemd only named variables pass, `--setenv=NAME`, so no value is in a command line) and never
  a provider key: a systemd unit keeps its environment where `systemctl --user show` prints it, and the detached
  launcher passes the starting Emacs's environment on, so `drgnx-hub-ensure` unsets every provider's `:key-env` for
  it. Keys come over the socket instead (`gateway/keys`, below). Its `PATH` is the starting Emacs's, until an Emacs
  that read the user's login shell (`core/drgnx-shell-env.el`, at start and Shell: Reload Environment) finds `PATH`
  changed and sends `env/set`: the hub applies it to its own `process-environment` and `exec-path`, so the agents and
  jobs it starts next (`drgnx-jobs` passes `PATH` on to systemd-run) get it. It is never restarted for that: a
  restart would end its durable sessions.
  Its main loop is `accept-process-output` plus the event drain batch Emacs needs (queued events hold back
  sentinels). SIGTERM or `shutdown` removes its socket. It starts with SIGPIPE ignored (`trap '' PIPE`): the
  editing Emacs that launches it does not ignore it, and a write to a connection an agent closed must be an error,
  never the hub's end. The ACP agents it runs and their MCP servers (coordination, search) start the same way —
  `drgnx-command-ignoring-sigpipe`, `sh -c "trap '' PIPE; exec …"`, off Windows — because libuv resets SIGPIPE in an
  agent's children, and a write to a pipe whose reader left would otherwise end the server.
- **The gateway** (`core/drgnx-gateway.el`) runs inside the hub: never in the editing Emacs, so streaming cannot
  touch the keystroke budget.
  Besides the 127.0.0.1 port it can listen on **per-session Unix sockets** (`drgnx-gateway-listen-socket PATH`, for
  agents in a sandbox without the host's loopback; the caller picks PATH, `gateway.sock` in the session's private
  directory beside `mcp.sock` and `hub.sock`). Same filter, path allowlist and token check as the port; the socket
  is mode 0600 and a stale file at PATH is replaced. `drgnx-gateway-close-socket PATH` (and `drgnx-gateway-stop`)
  cuts the connections on it, with their upstream requests, and removes the file.
- **curl**, one per forwarded request, reads its config on stdin (`-K -`): the URL, the provider's key header and the
  request body never appear in its argv.
  The config has `suppress-connect-headers`: behind an HTTPS proxy curl's `include` would otherwise print the
  proxy's CONNECT head first, and the gateway would take it for the provider's answer.

## The control socket

`drgnx-hub-socket`: `$XDG_RUNTIME_DIR/drgnx/hub-HASH.sock` (HASH: the first 8 hex digits of the SHA-1 of the data
dir), else `<state>/hub/hub-HASH.sock`; a path over 103 bytes (macOS's limit, the closing NUL included in 104; Linux
allows 107) — a deep state dir — moves to `drgnx-hub-UID/` in the first of `$TMPDIR`, `$TMP`, `$TEMP`, else `/tmp`
(the environment's, never `temporary-file-directory`: the Rust side computes the same path, docs/develop/runtime.md). The bytes are counted as the
system sees the name, encoded (`file-name-coding-system`: macOS decomposes "é" into 3 bytes).
Its directory is mode 0700 (made so from the start, with any parents it needs) and must be the user's own directory
— never a link, which would be followed (`drgnx-hub--private-dir`). A client checks the same before it pings, connects or sends
anything (`drgnx-hub--untrusted`): the directory a real directory (not a link) of the user's with no access for
others, and the socket the user's; a directory that is missing is refused too (what is checked is then connected to
by path, and a missing one could be another user's by then). Otherwise it refuses ("Not connecting to the drgnx hub: … is open to other users")
and never hands over keys — on the `/tmp` fallback another local user could have made the directory first. The
coordination server's `coord/notify` checks the same. One JSON object per line:

| Request (`{"id", "method", "params"}`) | Result |
|---|---|
| `ping` | `{pid}` |
| `status` | `{pid, socket, gateway_port, registrations, started}` |
| `subscribe` | `true`; then events `{"event", "data"}` on this connection |
| `gateway/register` `{job, task, agent, chain: [[provider, model-or-null]…], budget, keys: {provider: key}, owner, openrouter}` | `{token, url, openrouter}` (the restrictions kept; absent when none; restrictions that do not read are an error) |
| `gateway/unregister` `{token}` | `true` |
| `gateway/keys` `{keys: {provider: key}}` | `true`: the keys go to the gateway's memory |
| `env/set` `{env: [{name, value}…]}` (at most 16, a value at most 32768 characters; the `{NAME: value}` object form is refused as `invalid params`) | `{applied: [NAME…]}`: the names `drgnx-shell-env-names` allows (never a key, `drgnx-shell-env-refused-p`) go into the hub's environment (`drgnx-shell-env-apply`: `PATH` merged, the sender's dirs first) |
| `spend` `{job?, task?, agent?}` | `{input, output, cost, requests}` |
| `shutdown` | `true`, then the hub exits |

| `agents/start` `{profile, cwd, task?, job?}` | `{id, name}`: a session held by the hub |
| `agents/list` | `{sessions: [Snapshot…]}` |
| `agents/get` `{id}` | `{session: Snapshot, entries: [Entry…], seq}` (the snapshot, the whole transcript, the change number) |
| `agents/send` `{id, text}`, `agents/stop` `{id}`, `agents/kill` `{id}` | `true` |
| `agents/permission` `{id, request, option}` | `true` — the user's answer: the only way a permission is answered |
| `agents/do` `{id, op, n?, text?, item?, reject?}` | `true`: `deliver-queue`, `unqueue`, `requeue`, `review` |
| `coord/notify` (a notification: no id, no answer) | delivery runs now ([coordination.md](coordination.md)), and the new events go out |
| `events/since` `{since?, limit?}` | `{since, last, events: [...]}`: the events after `since` (0), oldest first, at most `limit` (200; at most 1000) |
| `job/propose` `{plan, repo?, budget?, auto?, gate?}`, `job/approve` `{id, budget?}`, `job/stop` `{id}`, `job/resume` `{id, budget?}` | the job (`drgnx-job-summary`); `gate`: `review` or `review+accept`, kept with the job (default: the hub's `drgnx-job-merge-gate`) |
| `job/start-task` `{plan, n, auto?, gate?}` | the job: a proposal of task `n` and the tasks it needs (Start as Job); the plan is only read |
| `job/reassign` `{task, profile}`, `job/block` `{task, reason}`, `job/unblock` `{task}`, `job/order` `{task, delta}` | the job, after the user's change from the Work graph (job data `:profiles`, `:blocked`, `:order`); a done or dropped task is an error |
| `job/status` `{id?, decisions?}` | the job (with its decision log when `decisions` is true), or `{jobs: [...]}` |
| `job/card` `{card, action, arg?}` | the job, after the user's action on a card (once: a settled card is an error) |
| `job/reply` `{message, text}` | `true`: the user's answer to an agent's message, which reaches the agent as the user's answer to that question ([coordination.md](coordination.md#delivery-the-hub)) |
| `job/dismiss` `{message}` | `true`: the message is acted on without an answer (the badge stops counting it) |

Errors: `{"id", "error": {"message"}}`. A line that is not JSON is answered with an error too when its `"id"` can be
read (otherwise it is dropped); a line over 1 MiB closes its connection. A client that reads slowly is never dropped for it: once its
socket's buffer is full, `process-send-string` waits and runs timers and filters meanwhile, and what comes for that
client then is queued and written in order after the write (`drgnx-hub--enqueue`, `drgnx-hub--drain`; a broadcast
queues its event for every subscriber before it writes to any, so a newer event never reaches one before an older; never a write one level deeper, which
would nest until `excessive-lisp-nesting` lands anywhere in the hub). A client that stopped reading (a suspended
Emacs) is dropped (logged) when its queue passes `drgnx-hub-client-max-queued` (16 MiB), wherever its write is, or a
write to it makes no progress for longer than `drgnx-hub-client-stuck-after` (10 s; checked also on the hub's tick,
when nothing more comes for it). A line goes out 8 KB at a time (`drgnx-hub--piece`), each piece progress: a write that fills the client's
socket waits 20 ms before Emacs tries again, and macOS's local sockets hold 8 KB (Linux's ~200 KB), so a snapshot of a
few MB takes seconds there (the hub writes ~400 KB/s to a client on macOS) and must not count as a stopped client. Only
the innermost write in progress is judged by time (`drgnx-hub--writing`): one beneath it cannot go on meanwhile, so it gets
back the time each write above it took (only that: a stopped client beneath writes to others is still dropped); its Emacs
connects again (the Agents module's idle timer, the Work cockpit's What needs you refresh) — meanwhile it shows the hub's sessions as
ended.
Snapshots and transcript entries travel as **JSON objects** ("Records 2" below). Events: from the gateway `request` (job, task, agent, provider, model, status, input, output, cost), `fallback`
(agent, from, to, why), `budget` (job, spent, budget); from jobs `card` (id, job, task, kind, title), `job` (id: its status, tasks or open cards changed) and `fallback` (job, task,
agent, from, to, why); from sessions `agent` (id, seq, session — the snapshot) and
`agent-entries` (id, seq, entries: [[index, Entry]…], the entries new or changed since the last time — entries change
in place: chunks appended, tool calls updated), at most one of each per session per 50 ms; `lease-released` (task,
agent, job); `events` (below).

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
again before the hub answers — up to `drgnx-hub-subscribe-deadline`, 5 s, after which an unanswered one is given up
and the next call subscribes again; each new one hands over the keys this Emacs holds) + `drgnx-hub-event-functions`. The unit
runner sets `DRGNX_NO_HUB_START=1`: a test never starts a hub that would outlive the suite unless it unsets it (the
hub's own tests do, and stop what they start). It also sets `DRGNX_HUB_PARENT_PID` to its own pid, which a hub
inherits: a hub whose parent is gone exits (checked each second), so an interrupted run leaves none behind.

## Events

The hub's own timers are layer timers keyed `hub-tick`, `hub-deliver`, `(hub-flush . ID)`, `hub-events` and `hub-exit` ([core.md](core.md#the-acp-watchdog-and-the-hubs-timers)): a burst of session changes delivers once, and `events` go at most every `drgnx-hub-events-interval`.

The hub turns what happens into events in the store's event log ([coordination.md](coordination.md), `event`):

- **Native sessions** (`drgnx-hub--session-events`, on each change of a session):
  - **its life:** `start` when the hub first sees it (data `:head`, the commit its folder is at, read from the
    repository's files by `drgnx-job-git-head`, never a git process), `stop` when it exits;
  - **its turns:** `start` and `stop` with data `(:turn t …)` — `:turn` first, so readers tell them from a life's
    with a prefix test; the cockpit's life, `:stopped` and timeline leave them out;
  - **edits:** an edit tool call it completed (`edit`: kind edit, delete or move, with the paths of its diffs, at most
    100 then `:more N`), once per call, before the turn's `stop`. A write request is the edit when there is one — the
    user accepts it (`agents/do` `review`; a rejected one is none) or a job's policy writes it — and the tool call an
    adapter reports for the same write (claude-agent-acp's Write and Edit do) leaves out the paths this turn recorded
    already: one `edit` per write. The scan starts at the first tool call that may still change, so a streamed turn
    is not walked again on each chunk;
  - **permissions:** a permission it asks (`question`, `:permission ID`) and its answer (`answer`, `:question EVENT-ID
    :permission ID :by BY :option OPTION`): by `user` (the `agents/permission` request, a job's card:
    `drgnx-hub-note-permission-answer`; the event's agent is then `user`), else by `drgnx` with no option — cancelled
    (Stop) or dropped when the agent ended.
- **Jobs** (`core/drgnx-job.el`): a reviewer's verdict (`review`, `:verdict pass` or `fail`, the reasons in the
  summary; no data without a verdict); a merge into the job's branch (`status`, `:status "merged" :into job/ID`); a
  write a job agent's policy allows (`edit`). A task's agent is registered (`drgnx-coord-agent-register`, kind `job`)
  with its worktree, branch and `base`, the commit the worktree is at when it starts: the cockpit diffs its edits
  against it (an agent that retries a task after a failed review starts from the earlier attempt's commits, so its
  diff is the retry's own), and shows it as its job's agent only while the job is shown.
- **Retention:** the hub's housekeeping (every 30 ticks, a minute) calls `drgnx-coord-events-prune-daily`: by age once
  a day, and on every call the row cap (`drgnx-coord-event-max-rows`).

Subscribers get them as `events` (`:since ID :last ID :events [{id, at, agent, job, task, kind, summary, data}…]`,
`data` a JSON object parsed from the store's column, absent when there is none), at
most one every `drgnx-hub-events-interval` (0.25 s) and 200 a time. The hub's session events and `coord/notify`
schedule a broadcast at once; its tick (2 s) catches what other processes wrote and the job events above, which go out
within those 2 s. Event ids are never reused (`autoincrement`), so a pruned log never sends an id twice. A new hub
starts after the last event there is; a client catching up asks `events/since`. In an editor, the `test` events with
counts reach the status bar (`drgnx-statusbar-note-tests`, when it is loaded) through `drgnx-hub--note-tests`, which
`drgnx-hub-connect` adds to `drgnx-hub-event-functions` and `drgnx-hub-disconnect` removes.

## Sessions across a restart

On each change to a session the hub keeps `<state>/hub/sessions.eld` (mode 0600, written like registrations.eld,
only when it differs): `(:id :name :profile :cwd :acp-id :task)` of each live session the agent made, oldest first —
not a job's (a job frees the task of an agent the hub took with it and starts it again). A hub that starts, once it
serves, resumes each with `drgnx-agents-take-over` (ACP `session/load`) under its own id and name (messages and
spend follow them); a file that cannot be read, or is not a list of sessions, is copied aside
(`sessions.eld.bak-…`, `drgnx-file-backup`), logged in one line and resumes none (the next save replaces it, the
backup keeps the bytes): the agent replays the
history into the transcript and the session is idle; an editor that reconnects fetches it again (`agents/get`). A
session whose agent cannot load sessions (no `loadSession`, or an error) ends and says why, and so leaves the file.
What was in flight is gone: a turn that was running, the queue, a pending permission or edit.

## Records 2

What crosses the socket is JSON shaped by the record schemas of `core/drgnx-records.el` (docs/develop/core.md,
"Records"); the Lisp side never prints Lisp to a peer and never calls `read` on what a peer sent.

- A `Snapshot` is `drgnx-records-session` (`status`, `via`, `mode` are strings of closed lists), an `Entry` is
  `drgnx-records-entry` (its `text` joined by the hub, `drgnx-agents-join-text`).
- `agents/list` answers `{sessions: [Snapshot]}`, `agents/get` `{session, entries, seq}`; the events `agent`
  `{id, seq, session}` and `agent-entries` `{id, seq, entries: [[index, Entry]]}`.
- `events` and `events/since` rows carry `data` as an object (the store's column, parsed), or no `data`.
- The editor's mirror (`drgnx-agents-mirror`) decodes with `drgnx-records-from-json`: status and entry types become
  symbols, and a record that does not decode (an unknown type, a wrong shape) is skipped with one message.
- `env/set` takes `{env: [{name, value}]}` only (see the method table).

## Per-session sockets

A sandboxed session's agent reaches drgnx's MCP servers through a dir of its own, served by the hub
(`core/drgnx-sandbox-mcp.el`). The agent's side, the bridge, is in [sandbox.md](sandbox.md#mcp-through-a-socket).

- **Where.** `(drgnx-sandbox-mcp-dir SID)` is `s/SID` beside the hub's socket: `$XDG_RUNTIME_DIR/drgnx/s/SID`, or
  `s/SID` beside the hub socket's fallback place. These are the dirs of `drgnx-sandbox-sessions-dirs`, so the sandbox
  may bind it as its `:run` (`/run/drgnx` inside on Linux, its own path on macOS). Each level is made by
  `drgnx-hub--private-dir`: mode 0700, this user's, never a link. SID is a name (letters, digits, `-`, `_`), never a
  path. A socket's path there must fit 103 bytes, or there is no dir.
- **Sockets.** `(drgnx-sandbox-mcp-open S &optional SEARCH)` listens on `mcp.sock` (coordination) and, when SEARCH
  is given, on `search.sock`. SEARCH is the job's project root, given by name and spelled as its index is: a value
  that is not a string, a root that is S's folder or lies inside it, or a folder the VC guard lists
  (`drgnx-sandbox-vc-guarded-p`, or inside one), is an error, because the search server runs
  git in its root and nothing outside the sandbox runs git in a task folder. The search server is **pinned** to that
  root (`DRGNX_SEARCH_PINNED=1`): a `path` argument outside it is refused, and one inside it searches the root, so
  no git runs where the agent points and no other project's index is read (`drgnx-search-mcp--pinned-root`). It sets
  S's `mcp-dir` and returns the dir. `hub.sock` is kept in the same dir for the hub protocol's agent class, which is
  not served yet.
- **One server per connection, outside the sandbox.** The hub starts the server of `drgnx-coord-mcp-server-spec`
  (or `drgnx-search-mcp-server-spec`) as a child of its own. Its environment is the hub's, with `DRGNX_AGENT` = S's
  id, `DRGNX_JOB` and `DRGNX_TASK` = S's, and the data-dir variables set from the spec. The hub's own
  `DRGNX_AGENT`, `DRGNX_AGENT_KIND`, `DRGNX_JOB` and `DRGNX_TASK` are unset. The server works in the session's dir,
  never in the task folder: the coordination server runs git where it starts. Its stdio is spliced to the
  connection. **The socket a connection comes in on is the identity.**
- **Every byte from the socket is hostile.** Lines are split linearly (`drgnx-mcp-bridge--feed`). A line over
  `drgnx-mcp-bridge-max-line` (16 MiB), or one that is not a JSON object, closes the connection and ends its server,
  unforwarded. Writes either way go through the hub clients' queue (`drgnx-hub--enqueue`): a side that stops reading
  for `drgnx-hub-client-stuck-after` seconds, or past `drgnx-hub-client-max-queued` bytes, is dropped. A socket
  serves at most `drgnx-sandbox-mcp-max-connections` (4) connections at once; more are closed as they come.
- **Ends.** A connection that closes ends its server; a server that ends closes its connection. The session's end
  (its agent exits, or `drgnx-agents-kill`) calls `(drgnx-sandbox-mcp-close S)`: every server and connection, the
  listeners and the dir go.
- **What the agent gets.** `(drgnx-sandbox-mcp-server-specs S INSIDE-DIR)` gives the `mcpServers` entries `drgnx`
  and, when `search.sock` listens, `drgnx-search`. Each runs `drgnx-mcp-bridge-command` on its socket in INSIDE-DIR,
  with an empty `env`. `drgnx-agents--mcp-servers` gives them instead of the stdio servers when S's `mcp-dir` is set.
  Every other session, interactive agents included, keeps the stdio servers.

Tests: `test/unit/sandbox-mcp-test.el` (`drgnx-sandbox-mcp/`).

## Registrations

`gateway/register` returns a token of 64 hex digits (32 bytes of `/dev/urandom`). The hub keeps
`<state>/hub/registrations.eld` (mode 0600): `((SHA256-OF-TOKEN . REGISTRATION)…)` — never a token, never a key —
written by `drgnx-hub--write-private` = `drgnx-file-write` with `:private t` (a temporary file beside it, synced to
disk — the directory is not synced, which Emacs cannot do — and renamed over it, so a hub or a machine that dies
mid-write leaves the old one whole; an old file loses its group and other bits; content over 1 MiB or not plain data is
refused and the file untouched), and
reads it back with `drgnx-file-read` when it starts (a file it cannot read is copied aside as
`registrations.eld.bak-…` and logged in one line: those agents register again). Both files and the port file are
read and written by the hub only; the hub's pid file (`drgnx-hub--take-lock`) is its own lock protocol and stays
outside the layer. It also keeps the gateway's port (`<state>/hub/port`, written with `drgnx-file-write-text`) and binds it again, so agents
keep working across a hub restart (when the port is taken meanwhile, a new one is used and the log says so). A
session's token is unregistered when its agent exits or is killed. Tokens have no expiry; instead a registration
names its `owner`, the pid of the Emacs that registered it (`drgnx-agents--gateway` sends its own: the agent is its
child, and a hub's own sessions are the hub's), and the hub drops those whose owner is gone (`drgnx-hub--alive-p`: a
zombie counts as gone) when it starts and on each tick (2 s) — a crashed editor never unregisters its agents' tokens.
A registration without an owner (kept before owners were) or with one that is not a pid stays until it is unregistered. A pid the system has given to a new process since
keeps its registrations until that one ends too. The last key handed over for a provider wins: two editors with different keys for it (separate billing) swap
the hub's on each reconnect. Keys sent in `keys` live in the hub's
memory only (`drgnx-gateway-set-key`, and `drgnx-ai--keys` for the agents it starts), never in a file. `drgnx-hub-ensure` (a command, the CLI's `drgnx hub start`)
hands the hub the keys its Emacs already holds, asking no one (`drgnx-hub--held-keys`: a provider's environment
variable, else a key loaded this session), with `gateway/keys` after the hub answers, and `drgnx-hub-connect` does so again with each new subscription: a
restarted hub has no key a command gave its predecessor (a `.gpg` one) until an editor connects again — the Agents
module's idle timer looks every 30 s — and its requests until then fail over or answer "no key". The hub never looks a key up where that may ask
(a `.gpg` file, the Keychain, a keyring): an agent it starts (`agents/start`, a job's, a resumed one) uses the keys
editors handed over, its environment or quiet auth-source files (`drgnx-ai-key` without INTERACTIVE), and with none for
any provider of its chain it does not start: "No key for openrouter in the drgnx hub: an editor hands its keys over
when it connects (or run drgnx hub start where the key is set)".

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
