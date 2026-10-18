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
| `drgnx-face-menu-bar` | `nil` | Show Emacs's menu bar. Hidden, the commands are in the palette, and `F10` opens the whole menu as text in the minibuffer (**Open the Menu**, `tmm-menubar`; the toolkit's own `F10` has no menu to open while the bar is hidden, and can freeze the window). With the bar shown, `F10` opens it as usual. **Toggle Menu Bar** (palette, View menu) flips it for this session only. |
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
| `sep` | ` · ` | ` \| ` | `flag` | ⚑ | `#` |
| `diamond` | ◆ | `<>` | `search` | ⌕ | `/` |
| `minimize` | – | `-` | `maximize` | ▢ | `[]` |

For code: `(drgnx-face-glyph 'close)` is the string for the selected frame, `(drgnx-face-glyph 'close FRAME)` for another.

## The status bar

In place of Emacs's raw mode line (`-:@--- file All L5 Git-main (YAML)`) each editor window ends in a quiet bar:
what you need at a glance, nothing that shouts. It is built from **segments**. Turn it off and on with **Toggle
Status Bar** (View menu, palette); `drgnx-statusbar-mode` is the switch.

| Left | Shows | Click |
|---|---|---|
| `branch` | `⑂ main` (the branch, from the buffer's version control) | the repository status |
| `problems` | `✓` when flymake finds none, `◐` while a checker has not reported yet, else `⚠ 1` (errors) and `⚠ 2` (warnings) | the problems list |
| `tests` | `✓ tests 41/41` or `✕ tests 2 failed`: the last test run | its output |
| `jobs` | `◎ 2 jobs` while jobs run, and `⚑1` when cards of jobs wait on you | job status |
| `agents` | `◎ 1 busy`, and `◐ 1 waiting on you` (in the error colour) when something waits for your answer | the Agents tab |
| `modal` | the modal-editing state (`NORMAL`, `INSERT` …), when that module is loaded | |
| `misc` | what stock Emacs shows beside the file: the buffer's process (`:run`), a keyboard macro being recorded (`● Rec`), `Narrowed`, `Remote: host`, and the entries of `global-mode-string` (the clock, a battery, other modules' marks) without the job badge | |

| Right | Shows | Click |
|---|---|---|
| `lsp` | `LSP ●` (connected), `○` (starting), `✕` (exited) when eglot manages the buffer | the server's events |
| `position` | `Ln 12, Col 4` | go to a line |
| `indent` | `Spaces: 2` or `Tab Size: 8` | tabs or spaces |
| `encoding` | `UTF-8` | change it |
| `eol` | `LF`, `CRLF` or `CR` | change it |
| `language` | `YAML`, `Python`, `Emacs Lisp` | the mode's help |

The most recently used editor window shows the whole bar; the other editor groups show `drgnx-statusbar-compact`
(position and language). The bar is for the buffers you edit: a buffer that visits a file, or is code, text or
configuration (`drgnx-statusbar-modes`: `prog-mode`, `text-mode`, `conf-mode` and what derives from them). Every other
buffer (Magit, Dired, help, Info, a shell, compilation, drgnx's own panes) keeps its own mode line, and a buffer whose
own `mode-line-format` is nil keeps none. In a narrow window the bar never wraps: segments go in the order of
`drgnx-statusbar-drop-order` (line endings first), and the branch is cut with an ellipsis, never dropped. The glyphs
come from `drgnx-face-glyphs`, so a terminal that is not UTF-8 shows ASCII (` | ` between segments instead of ` · `).

**Tests.** A compilation (`M-x compile`, `project-compile`) whose command matches
`drgnx-statusbar-test-command-regexp` (the word `test`: `bin/drgnx test`, `make test`, `cargo test`) is a test run.
When it finishes, the bar reads its last summary line once — ERT's `Ran 41 tests, 41 results as expected, 0
unexpected`, or `bin/drgnx test --ui`'s `ui ERT: 27/27 passed` (`drgnx-statusbar-test-count-regexps`) — and shows
`✓ tests 41/41`, or `✕ tests 2 failed`; a click shows that compilation. Only the last 64 KB of the output are
searched. Other code reports a run with `(drgnx-statusbar-note-tests PASSED FAILED SOURCE)`.

**Branch.** The branch is the one Emacs's version control put in `vc-mode`: a checkout made outside Emacs shows at
the next VC refresh of the buffer (saving it, or `M-x vc-refresh-state`).

**Jobs.** `◎ 2 jobs` counts the jobs the hub says are running (asked when the mode starts or the first hub event
arrives, then when a job or a card changes — one question at a time, never on redisplay; nothing while there is no
hub). `⚑1` is the job badge's count of cards and messages waiting on you.

**Waiting on you.** The number in `◐ 1 waiting on you` is the sum of `drgnx-statusbar-waiting-functions`: each
returns how many things wait for you. drgnx counts the agents' permission requests and edits to review; a module of
your own can add a function and call `drgnx-statusbar-refresh` when its count changes.

**Other modules' marks.** Anything a package puts on `global-mode-string` shows in `misc`, with no change to the bar.

The bar is redrawn after every command that moved point, changed the text or selected another window (both windows
trade the full and the compact bar a moment later, when the most recently used editor window is settled), and when
agents, the hub or git report a change (`drgnx-statusbar-refresh`: at most one redraw every 0.2 seconds, however many
changes come in, and only when a count changed; git always redraws). Each window keeps the bar it last drew, with
what it was drawn from (the buffer, point, the text's change count, the width, full or compact, the counts above and
the buffer's version-control, encoding, indentation width, mode, narrowing, checker and language-server state): a
redisplay that changes none of these reuses it, so a window you do not type in costs almost nothing however often
Emacs redraws the screen. Shown up to one keystroke late, because nothing announces them: a failed segment's retry
after 10 seconds, a change inside the buffer's process indicator (`mode-line-process`) that keeps the same construct,
and a segment of your own that has not called `(drgnx-statusbar-refresh t)`.

| Setting | Default | What it does |
|---|---|---|
| `drgnx-statusbar-left` | `(branch problems tests jobs agents modal misc)` | segments on the left, in order |
| `drgnx-statusbar-right` | `(lsp position indent encoding eol language)` | segments on the right, in order |
| `drgnx-statusbar-drop-order` | `(eol indent encoding lsp language misc tests jobs)` | dropped first to last when the window is narrow |
| `drgnx-statusbar-compact` | `(position language)` | what the other editor groups show |
| `drgnx-statusbar-place` | `editors` | `editors`; `frame` (one bar across the frame) arrives with the grid |
| `drgnx-statusbar-indent-vars` | the common indent offsets | the variables `indent` reads, first bound one wins |
| `drgnx-statusbar-modes` | `(prog-mode text-mode conf-mode)` | the modes (besides file buffers) that get the bar |
| `drgnx-statusbar-misc-exclude` | the job badge | entries of `global-mode-string` that `misc` leaves out |
| `drgnx-statusbar-test-command-regexp` | `\_<test\_>` | a compilation whose command matches is a test run |
| `drgnx-statusbar-test-count-regexps` | ERT's and `bin/drgnx test --ui`'s summary lines | where the counts come from |
| `drgnx-statusbar-waiting` (face) | inherits `error` | the colour of the waiting count |

Reorder or drop with `setopt`, and add your own in `config.el`:

```elisp
(setopt drgnx-statusbar-left '(branch problems agents))          ; fewer, in this order
(drgnx-statusbar-define-segment 'clock
  :fn (lambda () (format-time-string "%H:%M"))                   ; a string, or nil to show nothing
  :click #'calendar                                              ; a command or a function
  :help "The time; click for the calendar")
(setopt drgnx-statusbar-right (cons 'clock drgnx-statusbar-right))
```

A segment function runs whenever its window's bar is drawn again, so it must only read what is already known (a
variable, a buffer-local value): never call git, start a process, read a file or ask a language server. A segment
that shows something point, the text and the settings above do not cover is drawn again when you next move or type,
or within 0.2 seconds when your code calls `(drgnx-statusbar-refresh t)` after the change. Its text is plain text
with faces: a `%` is a percent sign (not a mode-line construct) and `display` properties are removed, so the bar can
count its columns. One that signals an error shows nothing, is skipped for 10 seconds and then tried again (when it
works, it comes back; when it fails again, it is skipped for another 10 seconds), and the message is kept in
`drgnx-statusbar--errors` (no message per redisplay). Defining it again gives it a new chance at once.

## The top line

A quiet line along the top of the frame says where you are and where to start:

```
 ◆ drgnx · main                 ⌕ C-p files · C-S-p commands · C-k C-r all keys
```

On the left, the project and branch of the editor you used last (the folder of the project's root, and the branch
git put in the file's version-control text; with no project it says `drgnx`, with no git it leaves the branch out).
In the middle, the three keys that open everything, as the profile you chose has them: **Quick Open** (files),
the **Command Palette** (commands) and **Keyboard Shortcuts** (all keys). Each one is a button: click `C-S-p
commands` and the palette opens. A command with no key of its own in your profile shows the key Emacs gives it
(`C-x p f` for files in the Emacs profile), and one with none at all is left out. In a terminal a chord the terminal
cannot send is shown the way it can be typed (the same form the palette and the key sheet show). When the frame is
too narrow for the hint, the hint goes first and the place is cut with an ellipsis last: the line never wraps.

When drgnx draws the window's title itself (a frame without its own title bar, a setting of the face that arrives
with window titles) the right end has `– ▢ ✕` (minimise, maximise, close) and the empty part of the line moves the
window when you drag it. With your window manager's own title bar those buttons would be a second set, so they are
not there; until that setting exists they never are.

The line is Emacs's tab bar with no tabs, since drgnx has no workspaces. It only reads what is already known (the
branch from the file's version-control text, never by running git; the project from the same cache the breadcrumb
keeps, filled when you switch editor, so a directory it has not met yet shows `drgnx` for a moment), so it costs
nothing when you type. If something in it fails it shows the mark alone for ten seconds rather than disappearing. A
`tab-bar-format` of your own is never replaced, and a tab bar that was already on is yours: then the top line stays
off. Turning the setting off puts back what it changed (the tab bar's format, its mode and its face). A terminal with fewer than 20 lines shows no line at all (it needs the room).

| Setting | Default | What it does |
|---|---|---|
| `drgnx-topline` | `t` | Show the top line. Set it to `nil` in `config.el` (or Customize) to take it away. |
| `drgnx-topline-min-lines` | `20` | A terminal frame with fewer lines than this shows none; windows always show it. |

Its faces are `drgnx-topline` (the quiet text, inherits `shadow` over `header-line`) and `drgnx-topline-strong`
(the project and the keys, inherits `bold` over `header-line`); the line itself takes the theme's `header-line`
look. The glyphs `diamond`, `search`, `minimize` and `maximize` are in the table above.

## Quick help

Rest the mouse on a symbol, or press **Show Quick Help** (`C-k C-i` in the VS Code profile, `SPC k` in Vim, the
palette in the Emacs profile, where `C-h .` keeps showing the local help at point), and a small card shows what the
mode or the language server knows about it: its signature and docs, with three buttons — **Open Help** (the full
documentation in the panel's Help tab: `describe-symbol` in Lisp, eldoc's documentation buffer elsewhere), **Go to
Definition** and **Find References**. Pressing the key again while its card shows (point not moved) opens the
Help tab; pressed while a card from hovering shows, it shows the card for point instead (point never jumps to the
mouse). A button used on a hovered symbol moves point there first and leaves the mark where point was (`C-u C-SPC`
goes back).

The card never covers the line you are editing. In a window it sits just below the symbol's line, inside the window
(above the line when there is no room below), and it never covers any row of that line (a long line wrapped over
several rows counts whole) or of the line point is on — hovering a symbol just above point puts the card under
point's line, or above the symbol's. It never leaves the window either: when not even one line of docs fits beside
the line, a hover shows nothing and the key puts the first line in the echo area. It moves out of the way as soon as
you type, and goes when the window scrolls or changes size under it. In a terminal, which has no pop-up frames in
Emacs 30, it is a strip of a few lines at the bottom of the editor (`…` while the docs are on their way): the editor
gives up those rows while it shows and gets them back, at the same size, when it goes. Point always stays visible.
In a terminal, `C-g` or `q` close the strip (`Esc` is the Meta prefix there), as does typing anything else.

It goes away when you type, run any other command, switch window or buffer, press `C-g`, `Esc` or `q` (**Close
Quick Help**, in every profile), or click its `✕`. A card that came from hovering never eats a key: `q` or `Esc`
put it away and then do what they always do (`q` types a q). It also goes when the mouse leaves the symbol and the
card. Only scrolling the card itself and its buttons keep it.

Hovering waits for the mouse to move: after you type, a pointer resting on the text brings no card back at your next
pause until you move it (as in VS Code). The mouse is only looked at while Emacs is idle and one of its windows has
the focus.

The docs come from Emacs's eldoc (`eldoc-documentation-functions`, which eglot feeds from the language server),
asked with point at the symbol. Every answer is asynchronous and the card waits at most one second for a slow server,
then shows what came; nothing you type ever waits for it. A variable's value is printed short (20 elements, 3
levels deep), so a huge list costs nothing. In Lisp, eldoc describes the function call around the
symbol (so hovering a function's name in a `defun` shows `defun`'s signature) and a variable's docstring with its
value; Open Help has the full story.

| Setting | Default | What it does |
|---|---|---|
| `drgnx-quickhelp-hover` | `t` | Show quick help when the mouse rests on a symbol (windows only; a terminal has the key). **Toggle Quick Help on Hover** (palette) flips it for this session. |
| `drgnx-quickhelp-delay` | `0.6` | Seconds the mouse rests on a symbol before the card shows. |
| `drgnx-quickhelp-max-lines` | `12` | The most lines of docs the card shows (it is also kept short enough to fit beside the line). |
| `drgnx-quickhelp-strip-lines` | `4` | Height of the strip in a terminal; a window too small to give up that many rows gets the first line in the echo area instead. |

## The start page

An empty editor tells you nothing, so drgnx fills it. **`*drgnx start*`** says what drgnx is in two lines, shows the
three keys that open everything (the files, the commands, all keys — the same ones the top line shows, from the
active profile: `C-p`, `C-S-p` and `C-k C-r` in VS Code's) and has four buttons: **Open a Folder…**, **Open the Work
Graph**, **All Keys** and **Don't show this again**. `Tab` and `Shift-Tab` move between the buttons, `Return` presses
one. A button whose command is not there (its module is off) is left out.

It shows itself only where nothing is lost: in the editor window you used last, and only when that window shows
`*scratch*` — never over a file, and never by splitting a window, moving focus to another window or asking you
anything. It looks at that when drgnx's first window opens (a moment after, once the files you asked for and your saved
layout are there), when a new window opens on a running drgnx (`emacsclient -c`), and when the last
file tab of the editor closes. Going to `*scratch*` yourself, with files still open, leaves it alone. In a terminal it
is the same page in the same place.

**Don't show this again** keeps your choice in `face.eld` in drgnx's state directory (`:start-dismissed`) and puts
the page away; it stays away on every later start and window. **Show Start Page** (palette, Help; no key of its own)
brings it back whenever you want it. The page is a tab only while it is shown, like `*scratch*`
(`drgnx-chrome-transient-tabs`), so it never lingers among your files.

## Faces

drgnx draws with the theme's faces and none of its own colours: the dividers inherit `shadow`, so a theme that
styles `window-divider` itself keeps its choice, and every colour you see comes from the theme you picked
(Preferences: Color Theme). The quick help card is `drgnx-quickhelp` (inherits `tooltip`) with the symbol's name in
`drgnx-quickhelp-title` (inherits `bold`); its border is Emacs's `child-frame-border` face. The start page uses
`drgnx-start-title` (inherits `bold`), `drgnx-start-key` (inherits `bold`) and `drgnx-start-quiet` (inherits `shadow`).
