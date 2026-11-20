# Components

One page per piece of chrome. Each says what it is for, its anatomy, the faces and tokens it uses, the rules that get
broken most, and a screenshot of drgnx drawing it, dark and light. Sizes are logical pixels (see [type and
density](../type.md)); every colour is a [token](../tokens.md).

| Component | What it is |
|---|---|
| [Cards](cards.md) | the islands the window is made of, on the gap |
| [Chips, keycaps and buttons](chips-and-keys.md) | the small things inside rows and bars, agent marks and progress among them |
| [Title row](title-row.md) | the top of the window: project, search, needs-you |
| [Status bar](status-bar.md) | the one quiet bar at the bottom |
| [Explorer](explorer.md) | the file tree, and the list pattern every list follows |
| [Palette](palette.md) | the floating command palette and Quick Open |
| [Popups](popups.md) | completion, docs, menus and notices over the code |
| [Lens bar](lens-bar.md) | the Work space's tab line of views |
| [Background list](background-list.md) | what a chat runs in the background, in the agent panel |
| [Detail island](detail-island.md) | the Work space's side card for the selected thing |
| [Research trail](trail.md) | an agent's steps, in order |
| [Notebook cell](notebook-cell.md) | a Jupyter cell as a card on Glitnir, a band elsewhere |
| [Empty states](empty-states.md) | what a list or view says when there is nothing in it |
| [Row (kit)](row.md) | a list, tree or map row, as the kit expands it (generated from `etc/ui/components.eld`) |
| [Button (kit)](button.md) | a label in a rounded box, four styles and two sizes, with its key hint |
| [Key hint (kit)](key-hint.md) | the keys of an action in the code font, in a small box |
| [Section header (kit)](section-header.md) | a section's title, with a twisty when it folds and an optional count |
| [Diff block (kit)](diff-block.md) | a file's head row (path, +N −M, buttons) over each hunk's rows in the code font, in the card's ring |
| [Empty state (kit)](empty-state.md) | what a list or console says while it holds nothing, with an optional quiet button |
| [Toast (kit)](toast.md) | a notice floating over the editor: a status dot, the text, up to two quiet buttons |
| [Tooltip (kit)](tooltip.md) | the overlay surface, 8 px of pad, the UI font; feeds the `tooltip` face |
| [Card (kit)](card.md) | the rows of one card: a ring inside the line, open where the card goes on |
| [Agent mark (kit)](agent-mark.md) | the agent mark's numbers (generated from `etc/ui/components.eld`) |
| [Progress (kit)](progress.md) | progress's numbers (generated from `etc/ui/components.eld`) |
| [Tab (kit)](tab.md) | an editor tab or a panel's tab, its icon, title and close mark |
| [Question card (kit)](question-card.md) | what an agent asks you: a permission, a question or a sign-off, on one needs-you card |
| [Segmented switch (kit)](segmented.md) | one ringed track of choices, the current one on the quiet selection |
| [Text input (kit)](text-input.md) | the field round a real buffer's text: one line or several, with context chips |
| [Rail item (kit)](rail-item.md) | a place of the rail: its icon in a 32 px square, the current place on the quiet selection, a warn dot when it changed |

## How to read a page

- **Anatomy** names the parts left to right or top to bottom, with the sizes that are fixed.
- **Faces and tokens** lists what the component draws with. A face is in [the face reference](../../guide/face.md); a
  token is in [tokens](../tokens.md), which also lists every face that uses it.
- **Rules** are the mistakes reviews keep finding. Each is a do or a don't, and each has been broken at least once.
- **Screenshot** is taken by drgnx itself (the look scenes), never drawn by hand, and regenerated with the look scenes
  (`bin/drgnx ui look-scenes`) when the look changes.
