# Title row

The integrated top of the window, drawn by drgnx instead of the system's title bar: where you are, how to start, and
whether anything waits for you.

![The title row, dark](../img/title-row-dark.png)

![The title row, light](../img/title-row-light.png)

## Anatomy

Left to right, 38 px tall (34 compact, 42 roomy):

1. the **mark**;
2. the **☰ button** (all the menus as one list);
3. the **project switcher**: the folder's name in semibold and a chevron, a list of the recent folders and three actions;
4. in the middle, the **search box**: it opens Quick Open, and `>` typed first turns it into the command palette; its
   key is a keycap (`Ctrl P`);
5. at the right, the pills that appear only while they have something to say: `N need you` (it opens the inbox) and
   `N agents`;
6. the three **layout toggles** (primary side bar, panel, secondary side bar): the icon is filled while its part shows;
7. the window controls.

The branch is not here: the status bar has it.

A double click on the row's empty part maximises or restores the window.

## Faces and tokens

The row is on the gap (`drgnx-surface-gap`); text is the UI role (`drgnx-ui-text`), the search box a keycap-and-field
on the quiet selection, the chips the chip faces ([chips](chips-and-keys.md)), and the project's name and the keys are bold (`drgnx-topline-strong`). The needs-you chip is `drgnx-status-attention`.

## Rules

- Nothing on the row moves when a chip appears or goes: the search box keeps its centre.
- When the frame is too narrow, the search box shrinks first, then the project's name is cut with an ellipsis; the ☰
  button, the pills, the toggles and the controls never hide, and the row never wraps.
- `attention` appears once per place and never blinks.
- The row is the UI font, never the code font.
