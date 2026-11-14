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
