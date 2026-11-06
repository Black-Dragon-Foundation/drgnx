# Agents in the editor: drawing developer notes

## Measurements: how agent ranges are drawn beside diff-hl

Measured in the GUI harness (`test/ui/agents-editor-gui-test.el`, mutter, Glitnir, dark and light themes, scale 1 and 2,
120-row window, 5 agents, 20 ranges of 40 lines).

- **Visible-rows rebuild** (one gutter overlay and one ring overlay per visible row, slots reused): p95 0.36 ms at
  scale 1, 0.56 ms at scale 2 (bar 2 ms).
- **Redisplay cost the overlays add** (60 scrolls, p95): bare 3.5 ms; gutter overlays alone 3.8 ms; ring as a card
  `:box` alone 8.9 ms; ring as a background tint alone 3.6 ms. The boxed ring is the costly part, not the gutter.
- **Fringe owner beside diff-hl:** an agent's `before-string` fringe overlay on a line diff-hl also marks shows the agent's
  bar when it is created after diff-hl's overlay, or has a higher `priority`; created before it at equal priority diff-hl
  wins. With `diff-hl-highlight-function` wrapped to skip agent lines, the agent always owns the line, through
  diff-hl's sync update, `diff-hl-update-async` and `diff-hl-flydiff`; the user's own changed lines keep diff-hl's mark.
- **Margin form** (terminal): a one-column left margin with a `(margin left-margin)` before-string draws on the marked row
  and not on its neighbour.

## Verdict

- **Ring rows use the background-tint form, with no `:box`.** The rebuild passes its 2 ms bar in both forms (0.36 ms at
  scale 1, 0.56 ms at scale 2), but the card `:box` form adds about 5 ms per redisplay over bare (8.9-9.4 ms against
  3.5-3.7 ms p95), which alone breaks the +1 ms budget against no agents. The tint form costs +0.1-0.9 ms.
- **Fringe owner beside diff-hl:** wrap `diff-hl-highlight-function` so it skips agent lines, and give the agent's
  `before-string` overlay priority 100. The wrapper alone won in every mode measured; the priority covers creation
  order. The user's own changed lines keep diff-hl's mark.
- **Terminal:** a one-column left margin with a `(margin left-margin)` before-string.

## The client

`modules/tools/drgnx-agents-editor.el` is the module. Its core, `drgnx-agents-editor--core-step (state event)`, is pure and
returns `(state . effects)`:

- events: `watch`, `unwatch`, `frame`, `delta`, `buffer-changed`, `restart`;
- a delta whose `version` is not newer than the state's is dropped; one whose `base` is not the state's version asks for
  a full frame (the effect `call-watch`); a frame or delta whose `doc_version` is older than the buffer's last change
  sent to the hub (`drgnx-agents-editor-note-change`) is dropped; after a restart no delta has a base;
- the shell watches a file buffer when a window shows it (`window-buffer-change-functions`,
  `window-size-change-functions`), unwatches it when none does, and asks again from `drgnx-hub-connected-functions`.

`drgnx-agents-editor-frame (buffer)` is the cached frame. Frames are applied at once, by calling
`drgnx-agents-editor-apply-functions` with (buffer frame); the hub already coalesces them to one per 50 ms. The module
sets `drgnx-agent-identity-watched-function` to the ordinals present in watched buffers and clears it when it goes.
`drgnx-agents-editor-probe` times N frame applies (the probe for `agents-cursor-tick`; the verdict waits for the gate).
The hub's `agents/buffer/watch` and `agents/buffer/unwatch` come with the hub's buffer view; until then a call finds
no method and the buffer simply has no frame.
