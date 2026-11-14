# The agent system and the hub client: what the hub computes

Lisp keeps commands, keymaps, settings and the final insert or draw call. These parts of the agent system and the hub
client used to compute per streamed event and no longer do.

## The panel's session lookup

`drgnx-agent-panel--panel-for` reads `drgnx-agent-panel--by-session`, a table from the hub's session id to the panel's
buffer (weak in its values, cleared by the panel's `kill-buffer-hook`). It does not walk the buffer list. A panel in
another display class (a twin) is never in the table.

## Replace's modified buffers

`drgnx-replace--send-buffers` sends the hub no buffer text for a buffer the edit history tracks: it hands the buffer's
changes over (`drgnx-history-drain-now`) and calls `search/buffer` with `mirror` and the version they reached; the hub
searches the text of its edit history's mirror. A buffer the history does not track goes as before, text up to 256 KiB
(`drgnx-replace-refresh-max-bytes`) and `large` above it; a buffer open as a large file is `large` too. Nothing above
256 KiB is sent or hashed by this path. When the hub answers `false` (its mirror was behind) the buffer goes once more
after the pause, then waits for its next change.

## What waits on you, and the agents at work

The hub derives both (`agents::attention`, from each session's snapshot as `agents-attention`, hub.md "Events"): the
pending permissions as the items of the one "needs you" count, and how many sessions are at work. The mirror
(`drgnx-agents--take-attention`) sets `drgnx-agents--at-work` and the notice model's `agents` set from the event. No
walk over the sessions is made per streamed chunk any more: `drgnx-agents--changed` only runs its hook. Answering a
permission here (`drgnx-agents-answer-permission`) takes its item out of the set at once, and the hub's next list
agrees. The hub being gone clears both. Edits to review (`reviews`) have no source in the hub (its snapshot lists none),
so the set holds permissions only.

## The hub's events go through a table

`drgnx-hub-event-functions` handlers name the events they take with the `hub-events-taken` property of their function (a
list of names; one ending in `*` is a prefix, as `term/*`); `drgnx-module-hook` takes `:events '(...)` for the
function it defines. `drgnx-hub--event-handlers` looks an event name up in `drgnx-hub--handler-table`, made once per name
from the hook's value and made again when a handler is added or removed, and the hook effect runs only those functions
(`drgnx-guard-run-functions`, each in its own guard, in the hook's order). A handler with no property takes every event
(`drgnx-exec--event`, which also refreshes a stale job list on any event). A new handler declares its events; one
that does not is called for each, as before.

## Every hub connection is framed

Nidhogg's reader splits and parses every hub connection's input (`drgnx-hub--frame`); `drgnx-hub--lines`,
`drgnx-hub--client-filter` and the `nidhogg-workers-framing` condition on the hub client are gone, and so is the
unframed `json-parse-string` on the main thread. The probe (`drgnx-hub--ping-socket`) is no client connection (one `ping`, two lines, a filter of its own). A framing the
reader refuses is an error. The delivery gate, which replaces a connection's filter, parses each held line itself in
the fixture and hands it to `drgnx-hub--client-batch`. `drgnx-hub--model-line` stays for the gate and the perf harness's
advice.
