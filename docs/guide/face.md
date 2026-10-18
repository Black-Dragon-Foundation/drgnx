# The face

How drgnx looks. The aim is a calm editor like Zed that is as informed as VS Code: nothing on screen that you did
not ask for, everything you need one glance away. Every choice below is a setting of the module `ui/face`
(Preferences: Modules turns the module off; the settings are in Customize, group `drgnx-face`), every one applies
at once when you change it, and every one works in a terminal as well as in a window.

Put your choices in `config.el` ([modules.md](modules.md#your-own-code-configel)) with `setopt`, for example:

```elisp
(setopt drgnx-face-menu-bar t)          ; bring the menu bar back
(setopt drgnx-face-line-spacing 3)      ; airier lines
```

## The frame

| Setting | Default | What it does |
|---|---|---|
| `drgnx-face-menu-bar` | `nil` | Show Emacs's menu bar. Hidden, the commands are in the palette and `F10` still opens the menu. **Toggle Menu Bar** (View menu, palette) flips it for this session only. |
| `drgnx-face-scroll-bars` | `none` | `none`, or `native` for the toolkit's scroll bar on the right. The position is in the status bar. |
| `drgnx-face-dividers` | `t` | A thin line (1 pixel) between windows, in the theme's colours. In a terminal the border is the terminal's own, drawn in the same colour. |
| `drgnx-face-line-spacing` | `nil` | Extra pixels between lines; `2` or `3` reads calmer. `nil` leaves Emacs's (or your own `line-spacing`) alone. |

The menu bar and the scroll bar are off from the very first moment (no light bar flashes up before the theme
loads): `init/early-init.el` starts the frame without them, and the settings above put them back.

## The buffers

| Setting | Default | What it does |
|---|---|---|
| `drgnx-face-line-numbers-modes` | `(prog-mode conf-mode yaml-mode yaml-ts-mode)` | Files in these modes (or modes derived from them) show line numbers. Prose, `*scratch*` and buffers without a file do not. |
| `drgnx-face-inline-problems` | `short` | Problems from the language server or flymake at the end of their line: `nil` (only underlined), `short` (the first problem, shortened) or `t` (all of them). Needs an Emacs whose flymake has `flymake-show-diagnostics-at-end-of-line` (30.1 and later). |

The line-number column is as wide as the file needs when it opens and never gets narrower or wider while you type,
so the text does not shift sideways. **Toggle Line Numbers** (View menu) still turns them off in one buffer.

## Glyphs

drgnx draws a few symbols (a drag handle, a close mark, a branch sign, warnings, checks, busy and waiting marks,
ahead and behind arrows). They all come from one table, `drgnx-face-glyphs`: NAME → (UNICODE . ASCII). In a terminal
whose encoding is not UTF-8 (a bare Linux console, an old `LANG=C` session), the ASCII form is used so nothing shows
as a box. Change one for your font:

```elisp
(setopt drgnx-face-glyphs (cons '(close "×" . "x") drgnx-face-glyphs))   ; yours first
```

| Name | Unicode | ASCII | Name | Unicode | ASCII |
|---|---|---|---|---|---|
| `handle` | ⠿ | `::` | `paused` | ⏸ | `\|\|` |
| `close` | ✕ | `x` | `ahead` | ↑ | `^` |
| `branch` | ⑂ | `Y` | `behind` | ↓ | `v` |
| `warning` | ⚠ | `!` | `dot` | ● | `*` |
| `ok` | ✓ | `+` | `circle` | ○ | `o` |
| `busy` | ◎ | `@` | `waiting` | ◐ | `?` |

For code: `(drgnx-face-glyph 'close)` is the string for the selected frame, `(drgnx-face-glyph 'close FRAME)` for another.

## Faces

drgnx draws with the theme's faces and none of its own colours: the dividers inherit `shadow`, so a theme that
styles `window-divider` itself keeps its choice, and every colour you see comes from the theme you picked
(Preferences: Color Theme).
