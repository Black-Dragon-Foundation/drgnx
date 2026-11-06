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

Verdict (the manager's): pending.
