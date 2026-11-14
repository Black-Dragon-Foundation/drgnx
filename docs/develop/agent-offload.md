# The agent system and the hub client: what the hub computes

Lisp keeps commands, keymaps, settings and the final insert or draw call. These parts of the agent system and the hub
client used to compute per streamed event and no longer do.

## The panel's session lookup

`drgnx-agent-panel--panel-for` reads `drgnx-agent-panel--by-session`, a table from the hub's session id to the panel's
buffer (weak in its values, cleared by the panel's `kill-buffer-hook`). It does not walk the buffer list. A panel in
another display class (a twin) is never in the table.
