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
| `drgnx-face-menu-bar` | `nil` | Show Emacs's menu bar. Hidden, the commands are in the palette, and `M-x tmm-menubar` opens the whole menu in the minibuffer (`F10` does not help: on a toolkit window with the bar hidden it has no menu to open, and can freeze the window). **Toggle Menu Bar** (palette, View menu) flips it for this session only. |
| `drgnx-face-scroll-bars` | `none` | `none`, or `native` for the toolkit's scroll bar on the right. The position is in the status bar. |
| `drgnx-face-dividers` | `t` | A thin line between windows, in the theme's colours. In a terminal the border is the terminal's own, drawn in the same colour. Turning it off turns `window-divider-mode` off only if drgnx turned it on; yours stays. |
| `drgnx-face-divider-width` | `1` | The line's width in pixels (graphical frames). |
| `drgnx-face-line-spacing` | `nil` | Extra pixels between lines; `2` or `3` reads calmer. `nil` leaves Emacs's (or your own `line-spacing`) alone. |

The menu bar and the scroll bar are off from the very first moment (no light bar flashes up before the theme
loads): `init/early-init.el` starts the frame without them (on a Mac the menu bar is the system's and is left alone),
and the settings above put them back.

`drgnx-face-menu-bar` and `drgnx-face-scroll-bars` are the one source for new frames and open ones: a
`(menu-bar-mode 1)` in `config.el` is overridden on every frame made after it, so use `setopt` as above. With the
module off (Preferences: Modules), nothing of this runs after startup and `(menu-bar-mode 1)` brings the bar back.

## The buffers

| Setting | Default | What it does |
|---|---|---|
| `drgnx-face-line-numbers-modes` | `(prog-mode conf-mode yaml-mode yaml-ts-mode)` | Files in these modes (or modes derived from them) show line numbers. Prose, `*scratch*` and buffers without a file do not. |
| `drgnx-face-inline-problems` | `short` | Problems from the language server or flymake at the end of their line: `nil` (only underlined), `short` (the first problem, shortened) or `t` (all of them). Needs an Emacs whose flymake has `flymake-show-diagnostics-at-end-of-line` (30.1 and later). |

The number column is as wide as the file needs when it opens; it never narrows, and widens only when the file needs
another digit, so the text does not shift sideways while you type. **Toggle Line Numbers** (palette, View menu) still
turns them off in one buffer.

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

## The status bar

In place of Emacs's raw mode line (`-:@--- file All L5 Git-main (YAML)`) each editor window ends in a quiet bar:
what you need at a glance, nothing that shouts. It is built from **segments**. Turn it off and on with **Toggle
Status Bar** (View menu, palette); `drgnx-statusbar-mode` is the switch.

| Left | Shows | Click |
|---|---|---|
| `branch` | `⑂ main` (the branch, from the buffer's version control) | the repository status |
| `problems` | `✓` when flymake finds none, else `⚠ 1` (errors) and `⚠ 2` (warnings) | the problems list |
| `tests` | test results (arrives with the work tracker; nothing yet) | |
| `jobs` | the job badge when a job needs you | job status |
| `agents` | `◎ 1 busy`, and `◐ 1 waiting on you` when an agent needs an answer | the Agents tab |
| `modal` | the modal-editing state, when that module is loaded | |
| `misc` | other indicators (nothing yet) | |

| Right | Shows | Click |
|---|---|---|
| `lsp` | `LSP ●` (connected), `○` (starting), `✕` (exited) when eglot manages the buffer | the server's events |
| `position` | `Ln 12, Col 4` | go to a line |
| `indent` | `Spaces: 2` or `Tab Size: 8` | tabs or spaces |
| `encoding` | `UTF-8` | change it |
| `eol` | `LF`, `CRLF` or `CR` | change it |
| `language` | `YAML`, `Python`, `Emacs Lisp` | the mode's help |

The most recently used editor window shows the whole bar; the other editor groups show `drgnx-statusbar-compact`
(position and language). A buffer whose own `mode-line-format` is nil (a terminal, say) keeps no bar. In a narrow
window the bar never wraps: segments go in the order of `drgnx-statusbar-drop-order` (line endings first), and the
branch is cut with an ellipsis, never dropped. The glyphs come from `drgnx-face-glyphs`, so a terminal that is not
UTF-8 shows ASCII.

| Setting | Default | What it does |
|---|---|---|
| `drgnx-statusbar-left` | `(branch problems tests jobs agents modal misc)` | segments on the left, in order |
| `drgnx-statusbar-right` | `(lsp position indent encoding eol language)` | segments on the right, in order |
| `drgnx-statusbar-drop-order` | `(eol indent encoding lsp language misc tests jobs)` | dropped first to last when the window is narrow |
| `drgnx-statusbar-compact` | `(position language)` | what the other editor groups show |
| `drgnx-statusbar-place` | `editors` | `editors`; `frame` (one bar across the frame) arrives with the grid |
| `drgnx-statusbar-indent-vars` | the common indent offsets | the variables `indent` reads, first bound one wins |

Reorder or drop with `setopt`, and add your own in `config.el`:

```elisp
(setopt drgnx-statusbar-left '(branch problems agents))          ; fewer, in this order
(drgnx-statusbar-define-segment 'clock
  :fn (lambda () (format-time-string "%H:%M"))                   ; a string, or nil to show nothing
  :click #'calendar                                              ; a command or a function
  :help "The time; click for the calendar")
(setopt drgnx-statusbar-right (cons 'clock drgnx-statusbar-right))
```

A segment function runs on every redisplay of its window, so it must only read what is already known (a variable,
a buffer-local value): never call git, start a process, read a file or ask a language server. One that signals an
error shows nothing and the message is kept once in `drgnx-statusbar--errors` (no message per redisplay).

## Faces

drgnx draws with the theme's faces and none of its own colours: the dividers inherit `shadow`, so a theme that
styles `window-divider` itself keeps its choice, and every colour you see comes from the theme you picked
(Preferences: Color Theme).
