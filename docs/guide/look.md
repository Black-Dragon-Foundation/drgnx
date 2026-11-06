# The look

drgnx ships three themes, all generated from one table of colours: **drgnx Dark**, **drgnx Light** and **drgnx High
Contrast**. Load one like any Emacs theme (`M-x load-theme`, or Preferences: Color Theme); they are found without any
setup.

## What a theme paints

- **Surfaces.** The editor is `default`. Beside it are the gap behind the cards and the bars (`drgnx-surface-gap`), the
  side panels (`drgnx-surface-panel`), raised things such as chips and the current tab (`drgnx-surface-raised`) and
  popups (`drgnx-surface-overlay`). In the dark theme the gap is darker than the editor; in the light theme it is
  darker than the white editor, so the cards read as depth.
- **Text.** Body text is `default`; secondary, tertiary and unavailable text are `drgnx-text-muted`, `-subtle` and
  `-disabled`.
- **Syntax and the rest.** Every `font-lock-*` face, the mode and header lines, tabs, dividers, search, completion,
  diffs, version-control state, diagnostics and the language server's faces, `outline-1` to `outline-8` (colour only,
  no size change) and the terminal's sixteen `ansi-color-*` colours come from the same table, so a package that
  inherits standard faces looks right with no work of its own.
- **Native title strip.** `nidhogg-title-bar` and `nidhogg-title-bar-inactive` follow the theme.

## The three variants

| | Dark | Light | High Contrast |
|---|---|---|---|
| Selection | blue-grey | pale blue | deep blue, text on it is white |
| Tints (status chips, diff lines) | 11 to 15 % of the status colour | 8 to 14 % | none |

High Contrast has no tints and no shadow faces; every text pair is at least 7:1.

## Terminals

On a terminal with 256 colours or fewer, the gap, the editor and the panel are one colour: the cards are drawn by the
vertical border instead.

## For theme authors

A theme of your own can set any of the semantic faces listed in [The face](face.md) ("Faces for theme authors"). The
token table is `themes/drgnx-tokens.eld`; `(drgnx-look-token 'panel)` reads a token of the active variant, and
`(drgnx-look-variant)` says which variant is on (`dark`, `light` or `hc`).
