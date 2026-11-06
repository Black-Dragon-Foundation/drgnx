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
no method and the buffer simply has no frame. The rows that need the hub's methods (`agents-editor-hub-test.el`, the
[B] row of the client) come with the hub's buffer view (the presence area); the [A] and [D] rows run on fed frames.

## Drawing: `drgnx-agents-editor-draw.el`

The draw file adds itself to `drgnx-agents-editor-apply-functions` and draws from the frame alone.

- **Bars:** an `editing` agent with a line gets one decor cursor at `(line_end, col)`. It is put once (with the
  colour string resolved from the identity face) and moved afterwards with `drgnx-decor-cursor-move-now`, which moves
  the same overlay at once instead of waiting for decor's 50 ms flush. `drgnx-agent-identity-cleared-hook` (run by
  `drgnx-agent-identity-clear`, so at every theme load) puts every bar again with the new colour and clears the tints.
- **Rings:** `reading` and `pending` agents with a line range. One overlay per visible row of each range, taken from a
  buffer-local pool and moved, rebuilt on `window-scroll-functions`, window size changes and each frame. Reading is a
  background tint (the agent's colour mixed into the default background with `drgnx-color-mix`); pending is a dashed
  underline in the colour. No `:box`: see the verdict above.
- **Projected** agents (another worktree) and file-only reads (no `:line`): no bar, no ring. A projected agent has one
  `after-string` tag overlay at the end of its mapped line.
- **Tags:** `drgnx-agents-tags` and `drgnx-decor-cursor-keep-label`: `always` keeps every tag on, `never` turns decor's
  tags off, `activity` leaves decor's 2 s after a move; a shared identity face or `drgnx-agents-editor-followed` keeps
  a tag on. Without Glitnir the tag text is the bar's `help-echo`.
- **Gutter strip:** the frame's `:gutter` ranges become a line table (`--lines`), one `before-string` overlay per visible
  row at priority 100 (the fringe spec in GUI frames, a `(margin left-margin)` display in terminals, where the buffer
  also gets `left-margin-width` 1 for as long as the table is not empty). The first row of a changed range uses the
  identity's gutter shape; pending and conflict rows keep the hollow and hatched shapes, so the kind stays readable.
  Hover text is the frame's `help` as the string's `help-echo`.
- **diff-hl:** `drgnx-agents-editor--diff-hl-highlight` is set as the default `diff-hl-highlight-function` through
  `drgnx-module-set` once diff-hl is loaded (undone with the module). It skips the lines in the table and gives the
  rest to the function that was set before; it reads the cached table, nothing else. When the table goes empty the
  buffer's diff-hl is redrawn so its marks come back, and on teardown every diff-hl buffer is redrawn. A range that
  changes shape while diff-hl is on leaves diff-hl's marks on lines the agent stopped owning until diff-hl's next update.
- **The agent line (`drgnx-agents-editor-line.el`):** `drgnx-chrome-add-tail-provider` (depth 30) registers
  `drgnx-agents-editor-line--provider`; the chrome's provider list (`drgnx-chrome-tail-providers`, depth order) is a
  `(:eval ...)` after the breadcrumb that joins the providers' strings, each a function of the window, run in
  redisplay, answering from cache. The large-file header (depth 10) and sticky scroll (depth 20) are providers too;
  `drgnx-chrome-header-tail` still works as a buffer-local construct after the providers. At each frame the line's
  strings are built once per agent (symbol at its line from `add-log-current-defun`, or
  `drgnx-agents-editor-line-symbol-function`; the plan entry, else the step title, truncated to 40 columns; `%`
  doubled); redisplay only picks the entry nearest the window's point, so the same string object comes back until the
  next frame. `drgnx-chrome-short-breadcrumb-functions` shortens the breadcrumb to the file name while the line shows.
  `drgnx-agents-editor-line-probe` times the build and a provider call (the probe for `agents-line-tick`; the verdict
  waits for the gate).
- **Badges, the status segment, who is here (`drgnx-agents-editor-here.el`):** the workspace presence
  (`agents/presence/subscribe`, then the `agent-presence` event, one `FilePresence` per file) is cached by file name.
  Each event rebuilds three things from the cache, none in redisplay: the badge string per user path
  (files: agents with a `pending`, `write` or `edit` entry, three marks with their initials then `+N`; folders: every
  ancestor up to the root, one mark per agent), the who-is-here rows (each session's newest entry) and the status
  string (eight marks, `+N`). A file in a linked worktree lands on the user's tree through the main checkout its
  `.git` file names plus the entry's `rel`; it is shown only when that checkout is a workspace root. The Explorer
  paints a badge through `drgnx-explorer-add-decorator` (an overlay at the row's end with `drgnx-git` set, so the next
  paint of the row removes it); the status bar through `drgnx-statusbar-define-segment` and `agents-here` set after
  `agents` in `drgnx-statusbar-left`. Ordinals are the hub's: the client keeps each session's `(ordinal .
  last_active)` from its `agent` snapshots (and `agents/list` at setup and on each new connection), forgets a session
  whose snapshot has no ordinal (it ended), and sets both `drgnx-agents-editor-here-ordinal-function` and
  `drgnx-agent-identity-sessions-function` (identity's reuse past capacity) from it; an agent the hub has not named yet
  has no mark and no who-is-here row until its snapshot comes, and a change of ordinals rebuilds the three;
  `drgnx-agents-editor-here-paired-function` (a ring on a paired agent's mark) is nil until the pair feature sets it.
  `work-who-is-here`, called interactively, ends in `drgnx-agents-editor-here-choose` (RET follows); its `o` (open the
  panel) comes with the panel.
- A buffer that stops being watched (`drgnx-agents-editor-unwatch-functions`) or is killed loses its bars, ring
  overlays and tags.

## Probes recorded for the gate

Recorded in the GUI harness (`agents-editor-gui/p3-drawn-frame`, mutter, Glitnir, dark and light, scale 1 and 2; five agents,
three gutter ranges, an 80 to 95 row window). These are readings; the verdicts wait for the gate.

- `agents-cursor-tick` (the frame apply: bar, rings, tag, strip, line table): p95 0.2-0.36 ms.
- `agents-gutter-tick` (a scroll's visible-rows rebuild): p95 0.07-0.11 ms.
- Pixels: the strip shows the agent's colour in the fringe of its lines and not elsewhere; the read range's rows hold none
  of the default background along their text, in both themes at both scales.
- `agents-line-tick` has its probe (`drgnx-agents-editor-line-probe`) and no GUI reading yet.

## Not yet in this branch

- The rows that need the hub (`agents-editor-hub-test.el`, the client's [B] row, and the Explorer's
  `badges-land-on-the-users-tree-for-a-worktree-agent`) come with the hub's buffer view and presence feed; the same
  mapping is tested here with a real git worktree.
- The who-is-here list's `o` (open the panel) comes once the panel is in `p3`.
