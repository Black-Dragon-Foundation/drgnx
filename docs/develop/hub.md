# The hub and the gateway

User docs: [Agents → The hub and the gateway](../guide/agents.md#the-hub-and-the-gateway).

## Processes

- **The hub** (`core/drgnx-hub.el`): a batch Emacs started as a durable job (`drgnx-jobs-start "drgnx-hub" …`), one
  per drgnx data directory. It gets the starting Emacs's drgnx and XDG directories and provider keys (when set) as
  its environment; under systemd only named variables pass (`--setenv=NAME`), so no value is ever in a command line.
  Its main loop is `accept-process-output` plus the event drain batch Emacs needs (queued events hold back
  sentinels). SIGTERM or `shutdown` removes its socket.
- **The gateway** (`core/drgnx-gateway.el`) runs inside the hub: never in the editing Emacs, so streaming cannot
  touch the keystroke budget.
- **curl**, one per forwarded request, reads its config on stdin (`-K -`): the URL, the provider's key header and the
  request body never appear in its argv.

## The control socket

`drgnx-hub-socket`: `$XDG_RUNTIME_DIR/drgnx/hub-HASH.sock` (HASH: the first 8 hex digits of the SHA-1 of the data
dir), else `<state>/hub/hub.sock`; its directory is mode 0700. One JSON object per line:

| Request (`{"id", "method", "params"}`) | Result |
|---|---|
| `ping` | `{pid}` |
| `status` | `{pid, socket, gateway_port, registrations, started}` |
| `subscribe` | `true`; then events `{"event", "data"}` on this connection |
| `gateway/register` `{job, task, agent, chain: [[provider, model-or-null]…], budget, keys: {provider: key}}` | `{token, url}` |
| `gateway/unregister` `{token}` | `true` |
| `spend` `{job?, task?, agent?}` | `{input, output, cost, requests}` |
| `shutdown` | `true`, then the hub exits |

Errors: `{"id", "error": {"message"}}`. Events (from the gateway): `request` (job, task, agent, provider, model, status,
input, output, cost), `fallback` (agent, from, to, why), `budget` (job, spent, budget).

A second hub on the same socket finds the first answering `ping` and exits with status 3; a socket file nobody
answers on is replaced. Client side: `drgnx-hub-ensure` (start if needed; commands and the CLI only — it waits),
`drgnx-hub-call` (asynchronous), `drgnx-hub-call-sync`, `drgnx-hub-connect` + `drgnx-hub-event-functions`. The unit
runner sets `DRGNX_NO_HUB_START=1`: a test never starts a hub that would outlive the suite unless it unsets it (the
hub's own tests do, and stop what they start).

## Registrations

`gateway/register` returns a token of 64 hex digits (32 bytes of `/dev/urandom`). The hub keeps
`<state>/hub/registrations.eld` (mode 0600): `((SHA256-OF-TOKEN . REGISTRATION)…)` — never a token, never a key — and
reads it back when it starts, so agents keep working across a hub restart. Keys sent in `keys` live in the hub's
memory only (`drgnx-gateway-set-key`); after a restart they come again from the environment, quiet auth-source files,
or the next command that registers.

## Forwarding

A provider can be carried when it has `:messages t` (it serves Anthropic's Messages API at its URL without `/v1`
plus the agent's path): the `openrouter`, `ollama` and `anthropic` presets. Its key goes as `Authorization: Bearer`,
or `x-api-key` with `:auth x-api-key`. The request's `content-type`, `accept`, `anthropic-version` and
`anthropic-beta` headers pass; the body's top-level `model` is replaced when the chain step names one. Nothing goes
to the agent until the upstream's head is whole: 1xx heads are skipped; 401, 402, 408, 409, 429, 5xx, or curl ending
first, try the next step (a `fallback` event). Once the head went out there is no fallback: the rest streams through
(`Connection: close`, no length) and the connection closes when curl ends. An agent that hangs up kills its curl.

Spend: `drgnx-http-usage-scanner` follows the answer — SSE `message_start`/`message_delta` usage, or one JSON body's
`usage` (Anthropic or OpenAI names, `cost` when given); without a cost, a provider's `:price (IN . OUT)` (USD per
million tokens) prices it. One `spend` row per request in `work.db` (schema 2). The budget is checked before
forwarding: a job whose spend reached its budget gets 429 `budget_exceeded` and a `budget` event.
