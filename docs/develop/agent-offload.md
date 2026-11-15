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
the fixture and hands it to `drgnx-hub--client-batch`. `drgnx-hub--model-line` is gone: the gate hands a `view-model` line to `drgnx-view-model-line`, and the perf harness advises
where framed lines are handled (`drgnx-hub--model-pushed`, `drgnx-hub--client-batch`).

## Hook rows of a step

The `agent-step` event names the tool call its step ran (`call`, the tool entry's `id`); `drgnx-agents-mirror--step` files
the step's hook rows under it and no longer walks the transcript for the newest tool entry. `timeline/get` rows have no
`call` (the `step` table keeps none).

## Edits to review

The attention set holds permissions only because reviews have no source: the hub's snapshot has `reviews: []` always
(`agents/session.rs`), and the Lisp runtime that made them (held agent writes, `agents/do` op `review`) was deleted with
the Lisp agent runtime (87dab81fd); before the offload the mirror's `reviews` was filled only from that empty list.

## The panel's header and chips (F1, first slice)

Built in the hub (hub.md "The agent panel's rows"): the header's name, status text cut to the room, lens and buttons, and
the chips. No `string-pixel-width` runs per character any more (`drgnx-agent-panel--fit` and the Lisp header and chips
builders are gone). Lisp keeps `drgnx-agent-panel-act` and `drgnx-agent-panel-press` (one click dispatcher), the lens it
tells the hub, and the header menu. Of the Lisp chips only the ones the hub's snapshot feeds are built: context, cost and
mode (its snapshot has no model, sandbox, MCP, file or checkpoint count, so those chips were never fed in a real session).
The hover highlight a row cannot set (`mouse-face` takes a symbol, a row carries a string) is the one thing the header lost.

## The panel's strip (F1, second slice)

The disclosure strip ("Open:", a pill per step type, "make default") is the hub's rows too (`p:strip`, `p:strip:N` when it
wraps; `view/panel_top.rs`): the pills carry `drgnx-agent-panel-action` `type:NAME` and `default`, the open step types
come from the look the editor sent, and the width comes from the env, so a resize is the hub's rebuild and no Lisp
measures a pill. `drgnx-agent-panel--strip-row` is gone; the one click dispatcher (`drgnx-agent-panel-act`) flips a type
or makes the default.

## The panel's cards (F1, cards)

The pinned cards, the to-do list and the edits ledger are the hub's rows (hub.md "The agent panel's rows"). The state
split: pins, the ledger's open flag and its mark are per-(connection, view) user state in the hub (`Chosen`), told by
`agents/panel/look`; the plan, the finished edits, the edited files and a paired chat's hunks are read by the hub from the
session. Lisp keeps the commands (`drgnx-agent-panel-pin`, `-ledger`, the click dispatcher's `card:*` actions) and, for a
paired chat's ledger line, the revert; the Lisp row builders, the plan and hunk loads and the ledger mark are gone.

## The diff and permission cards (F1, cards)

Built in the hub too (hub.md "The agent panel's rows"). `drgnx-agent-panel-cards--diff-row`, `--perm-row`, `--box`,
the `:diff` and `:perm` row keys and the Lisp loads of `work/files` and `work/hunks` (`cards-load`, which ran after each
finished edit) are gone, and so is `drgnx-agent-panel--diffs`: the panel reads no diff until Accept or Reject asks for the
one file. Lisp keeps the commands (accept, reject, allow, always), which read the card at point
(`drgnx-agent-panel-card`), and the click dispatcher's `card:*` buttons. The editor puts a hub patch's rows in the hub's
order: `drgnx-agent-panel--insert-ops` and the `p:` placement rule are gone with the special case.

## The composer's queue (F1, queue)

The notes queued for the agent are the hub's rows (`c:q:N`, from the snapshot's `queue`); `drgnx-agent-panel-composer--queue-row`
and the `:q` row keys are gone. The composer's input row stays Lisp (the field is the editor's: the user types in it); it
is the only row the panel draws itself under the transcript. The edit and drop commands read the note's number from the row
at point.
