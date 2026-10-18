# drgnx in a terminal

drgnx runs in a text terminal too: `emacsclient -s drgnx -t`, `emacs -nw`, over SSH, inside tmux. How much of it
works depends on the terminal. A terminal has to send the shortcuts (`C-S-p`, `` C-` ``, `C-.` …), copy to your
computer's clipboard, show true colour and report the mouse. This page lists what each common terminal can do,
the shortcuts it keeps for itself, and the line that fixes what is missing.

**Works best:** kitty, foot, Ghostty, and WezTerm with one setting. They send `C-S-` chords and the other shortcuts,
and copy to the clipboard, over SSH as well. Each keeps some `C-S-` chords for itself; [the fixes](#the-fixes) free
them. In any terminal, **F1** opens the command palette (VS Code keys) and `M-x` works in every
profile, so every command can still be reached.

The table is `drgnx-tty-terminals` in `core/drgnx-tty.el`; onboarding and the doctor read the same data.

## What each terminal can do

Each row is **reported**: drgnx's builders have not run it yet. Each cell comes from official documentation: the
linked page, or another official page or source named in [The fixes](#the-fixes), such as the kitty keyboard
protocol's list of terminals, xterm's manual, tmux's manual, or the default shortcuts Ptyxis ships. A cell marked
**(unconfirmed)** rests on secondary sources or general knowledge only. "Yes" means the terminal does it with its
default settings.

| Terminal | kkp | modifyOtherKeys | OSC 52 copy | True colour | Mouse | Shortcuts it keeps | Row |
|---|---|---|---|---|---|---|---|
| [kitty](https://sw.kovidgoyal.net/kitty/conf/) | yes | no (unconfirmed) | yes | yes (unconfirmed) | yes (unconfirmed) | 62, all `C-S-`: `C-S-c` `C-S-v` `C-S-t` `C-S-p` `C-S-<return>` `C-S-<left>`/`<right>`/`<up>`/`<down>` … | reported |
| [WezTerm](https://wezterm.org/config/key-encoding.html) | no (opt-in) | yes | yes | yes (unconfirmed) | yes (unconfirmed) | 55: `C-S-c` `C-S-v` `C-S-t` `C-S-n` `C-S-w` `C-S-p` `C-S-f` `C-S-<arrows>` …, and `s-` keys | reported |
| [foot](https://codeberg.org/dnkl/foot/src/branch/master/doc/foot.ini.5.scd) | yes | no (unconfirmed) | yes | yes | yes | `C-S-c` `C-S-v` `C-S-r` `C-S-n` `C-S-o` `C-S-z` `C-S-x` `C-S-u` | reported |
| [Ghostty](https://ghostty.org/docs/config/reference) | yes | yes (unconfirmed) | yes | yes (unconfirmed) | yes | (unconfirmed) `C-S-c` `C-S-v` `C-S-t` `C-S-n` `C-S-w`, and more (`ghostty +list-keybinds --default`) | reported |
| [Alacritty](https://alacritty.org/config-alacritty.html) | yes | no (unconfirmed) | yes | yes (unconfirmed) | yes (unconfirmed) | `C-S-c` `C-S-v` `C-S-f` `C-S-b` `C-S-SPC` `C-S-o` | reported |
| [iTerm2](https://iterm2.com/documentation-preferences-profiles-keys.html) | no (unconfirmed; a setting) | no (unconfirmed) | no (unconfirmed) | yes (unconfirmed) | yes (unconfirmed) | (unconfirmed) Cmd keys (`s-c` `s-v` `s-t` …) | reported |
| [GNOME Terminal, Ptyxis (VTE)](https://gitlab.gnome.org/GNOME/vte/-/issues/2495) | no (unconfirmed) | no | no | yes (unconfirmed) | yes (unconfirmed) | `C-S-c` `C-S-v` `C-S-t` `C-S-n` `C-S-o` `C-S-f` `C-S-a` `C-S-w` `C-S-q` `C-S-<prior>` `C-S-<next>` `S-<f10>` `C-M-S-t` | reported |
| [Terminal.app](https://support.apple.com/guide/terminal/change-profiles-keyboard-settings-trmlkbrd/mac) | no (unconfirmed) | no (unconfirmed) | no (unconfirmed) | no (unconfirmed) | yes (unconfirmed) | (unconfirmed) Cmd keys (`s-c` `s-v` `s-t` …) | reported |
| [xterm](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) | no (unconfirmed) | yes | no | no (unconfirmed) | yes | (unconfirmed) `S-<prior>` `S-<next>` `S-<insert>` | reported |
| [Linux console](https://man7.org/linux/man-pages/man4/console_codes.4.html) | no (unconfirmed) | no (unconfirmed) | no | no (unconfirmed) | no (unconfirmed) | (unconfirmed) `M-<f1>`…`M-<f12>`, `C-M-<f1>`…`C-M-<f12>` (switch consoles) | reported |
| [tmux](https://man.openbsd.org/tmux) | no | no | no | no | yes (unconfirmed) | `C-b` (its prefix) | reported |

- **kkp** is the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/): every key and
  modifier arrives, `s-` (Super/Cmd) included. Its page lists the terminals that implement it.
- **modifyOtherKeys** is xterm's older way: `C-S-` chords, `C-.`, `` C-` ``, `C-<return>` and `C-<tab>` arrive,
  `s-` and `H-` keys do not.
- **Neither** (a "legacy" terminal): `C-<letter>`, `M-` keys, F keys and arrows arrive, but not `C-S-<letter>`,
  `C-<punctuation>` (other than `C-@ C-[ C-\ C-] C-^ C-_`), `C-<digit>`, `C-<return>`, `C-<tab>` or any `s-`/`H-`
  key. The terminal sends `C-S-p` as plain `C-p`. drgnx keeps one key set, with no separate set for terminals.
  Commands whose shortcut cannot arrive are still in the palette.
- **OSC 52** is the escape sequence that puts drgnx's copy on your computer's clipboard. It still works when drgnx
  runs on another machine over SSH.

## The fixes

What to change in each terminal, for what the table marks "no" and for the shortcuts it keeps. "None" means no setting
helps.

- **kitty:** it uses its own keyboard protocol (kkp) instead of modifyOtherKeys. Its shortcuts (`kitty_mod` is
  `ctrl+shift`) take `C-S-p` (the palette) among others. Add `clear_all_shortcuts yes` to `kitty.conf` before your
  own `map` lines. Or free one chord with a `map` that has no action, such as `map kitty_mod+t`. kitty then passes
  the chord to drgnx.
- **WezTerm:** `config.enable_kitty_keyboard = true` in `wezterm.lua` (off by default). Its default bindings take
  `C-S-p` (its own command palette) and more. `config.disable_default_key_bindings = true` frees them all.
- **foot:** no setting needed for modifyOtherKeys, since foot speaks kkp. To free a chord, set its action to `none`
  in `foot.ini` under `[key-bindings]`, for example `search-start=none`.
- **Ghostty:** `keybind = ctrl+shift+t=unbind` frees a chord. `ghostty +list-keybinds --default` lists the defaults.
- **Alacritty:** no setting needed for modifyOtherKeys, since Alacritty speaks kkp. To free a chord, add
  `[[keyboard.bindings]] key = "F", mods = "Control|Shift", action = "ReceiveChar"` to `alacritty.toml`. OSC 52 copy
  is on by default (`[terminal] osc52 = "OnlyCopy"`).
- **iTerm2:** Settings → General → Selection: turn on *Applications in terminal may access clipboard* (OSC 52).
  Settings → Profiles → Keys → General: *Apps can change how keys are reported* lets drgnx turn kkp on. Kitty's
  protocol page lists iTerm2, but whether this setting is on by default is unconfirmed, so the table says no. macOS
  keeps the Cmd chords.
- **GNOME Terminal, Ptyxis (VTE):** none for keys or copy. VTE has no kkp and no modifyOtherKeys (Emacs turns the
  latter off for VTE), and it does not take OSC 52 ([VTE issue 2495](https://gitlab.gnome.org/GNOME/vte/-/issues/2495)).
  Freeing a chord in Preferences → Shortcuts does not help: VTE then sends it without Shift. Use F1 or the palette;
  copies stay inside drgnx.
- **Terminal.app:** none for keys, copy or true colour. True colour was announced for macOS 26 (unconfirmed).
  Settings → Profiles → Keyboard: *Use Option as Meta key* makes `M-` keys work.
- **xterm:** it refuses OSC 52 by default, because its `disallowedWindowOps` resource defaults to
  `GetChecksum,GetIconTitle,GetSelection,GetWinTitle,SetSelection,SetXprop`
  ([xterm(1)](https://invisible-island.net/xterm/manpage/xterm.html)). Add the same list without `SetSelection` to
  `~/.Xresources`: `XTerm*disallowedWindowOps: GetChecksum,GetIconTitle,GetSelection,GetWinTitle,SetXprop`. For true
  colour, try `TERM=xterm-direct` (unconfirmed). Emacs turns on modifyOtherKeys in xterm by itself.
- **Linux console:** none for keys, copy or colour (16 colours). For the mouse, run the gpm service and
  `M-x gpm-mouse-mode` (in an Emacs built with gpm).
- **tmux:** see [below](#tmux).

## Keys

`C-S-p`, `` C-` ``, `C-.` and the other chords of your profile reach drgnx only through a key protocol: a plain
terminal sends `C-S-p` as `C-p`, and `C-.` not at all. drgnx turns on one protocol in each terminal window:

- **modifyOtherKeys**, wherever the terminal has it: xterm, WezTerm, Ghostty, and tmux with `extended-keys on`.
  drgnx asks the terminal for it when Emacs did not, and decodes every chord (Emacs alone decodes only a few, so
  `C-S-p` would type text). Under tmux drgnx reads `extended-keys` and asks tmux for it when it is `on` or
  `always`. When it is `off`, or tmux is too old to have the option (before 3.2), the window counts as plain.
  Every chord arrives except `s-` and `H-` keys. This needs no package.
- **The kitty keyboard protocol (kkp)**, only for terminals that have kkp but not modifyOtherKeys: kitty, foot,
  Alacritty, and iTerm2 with the setting in [The fixes](#the-fixes). The `ui/terminal-keys` module uses the `kkp`
  package from MELPA, pinned in drgnx's lock (`drgnx sync` installs it). When such a terminal window opens, kkp
  asks the terminal once whether it speaks the protocol (`CSI ? u`) and waits 0.2 s at most. A terminal that says
  no, or does not answer, keeps its plain keys. If the answer starts but does not finish in time (a slow SSH
  link), drgnx takes the half-made change back, the window keeps its plain keys, and drgnx records the
  problem. Under kkp every key arrives, `s-` keys included.
- **Neither** (GNOME Terminal, Ptyxis, Terminal.app, the Linux console): open the palette with **F1** (VS Code
  keys) or `M-x`; every command is there. `terminal-report.eld` lists the keys of your profile this terminal
  cannot send.

Each terminal window keeps its own keys: a kitty window and a Ptyxis window on the same drgnx each get what their
terminal can send.

**`C-g` in a kkp terminal (kitty).** modifyOtherKeys leaves `C-g` the plain byte it always was, so it stops
anything, busy Lisp included; that is why drgnx prefers it. Under kkp the terminal sends `C-g` as an escape
sequence, which Emacs reads only between commands. drgnx turns on kkp's `kkp-restore-legacy-keys-around-subprocesses`,
so while Emacs waits for a program (a `git` that hangs, say) the terminal sends plain keys and `C-g` stops the
program. But `C-g` cannot stop busy Lisp (a long computation, a loop) in a kkp terminal; `terminal-report.eld`
says so for that terminal (`:c-g waits`). To keep `C-g` working everywhere, set **`drgnx-tty-use-kkp`** to `nil`
(`M-x customize-variable`; it applies to terminal windows opened afterwards). kitty then sends plain keys: no
`C-S-` chords, so use F1 or the palette for those.

Ctrl+Shift+`` ` `` arrives from xterm and tmux as Ctrl+Shift+`~` (the character Shift makes on a US layout);
drgnx reads it as `` C-S-` `` (New Terminal). On other layouts, use the palette if the key does nothing.

Without the `kkp` package, `ui/terminal-keys` waits and the doctor's module check names it
(`ui/terminal-keys (kkp)`); modifyOtherKeys works as above.

## SSH

Run drgnx on the remote machine and attach from your terminal: `ssh box -t emacsclient -s drgnx -t`. Keys, mouse and
OSC 52 copy travel over SSH unchanged. The remote end can only see `TERM`, so drgnx may not know which terminal you
are in. A terminal-specific `TERM` (`xterm-kitty`, `xterm-ghostty`, `foot`) needs its terminfo entry on the remote
machine. Without it, Emacs falls back to 8 colours or refuses the terminal. To fix this, install the entry with
`infocmp -x | ssh box tic -x -`. Or use `kitten ssh` in kitty, or Ghostty's `ssh-terminfo` shell integration. Or
connect with `TERM=xterm-256color`.

## tmux

Inside tmux, drgnx talks to tmux, not to your terminal: tmux decides which keys and copies get through. Its defaults
block both. Add these lines to `~/.tmux.conf` (drgnx never writes it) and run `tmux source ~/.tmux.conf`:

```
set -s extended-keys on                      # C-S- chords, C-. … (modifyOtherKeys)
set -s set-clipboard on                      # copy reaches your clipboard (the default, external, refuses programs)
set -as terminal-features ',xterm-kitty:RGB' # true colour; use your terminal's TERM outside tmux
```

tmux keeps `C-b` as its prefix. Press `C-b` twice to send it to drgnx, or set another prefix with `set -g prefix`.
tmux does not pass the kitty keyboard protocol, so `s-` keys do not arrive inside tmux.

## EDITOR

Onboarding suggests `EDITOR='emacsclient -s drgnx -t'`: `git commit` and other programs that open an editor then
open it in drgnx, in the terminal you ran them from.

A client that opens a file this way (`emacsclient -t FILE`) gets the **editor only**: no sidebar, panel or right
dock, so the commit message has the whole terminal. It is never the main window. Close its tab (Close Tab, or
the tab's `×`) or press `C-x #`: the edit ends and the program that opened it goes on, as with `code --wait`. If
the file has unsaved changes, drgnx first asks whether to save it (answering no ends the edit without them, as
`C-x #` does). Moving the tab to another group or window does not end the edit. `emacsclient -t` without a file
(and `drgnx -t`) opens the whole workbench.

## What drgnx asks the terminal

When a terminal window opens, drgnx works out which terminal it is from that client's own environment (in a
daemon, never the daemon's) and asks the terminal its name and version once (XTVERSION), waiting 0.2 s at most;
a terminal that does not answer just stays unnamed (an answer that comes later is still used). A second window of
the same kind of terminal asks nothing. Which keys arrive, colours and the rest are read for each window. What it
found — how keys arrive (kitty keyboard protocol, modifyOtherKeys, or neither), OSC 52, colours, the mouse — and the
keys of your profile this terminal cannot send are written to `terminal-report.eld` in drgnx's state directory
(`~/.local/state/drgnx/`), one entry per terminal device, for the doctor and the key sheet. The file is written
whole and then renamed into place, so two Emacs processes never leave half of it, and nothing ever asks about it.
Like Emacs's own terminal setup, the question drops keys typed ahead while a new terminal window opens. In a terminal
without modifyOtherKeys, kkp asks its own question, once per terminal, waiting 0.2 s at most (see [Keys](#keys));
its answer is added to the report.

## Mouse

In a terminal window the mouse works as in a graphical one: a click puts the cursor there, a double click selects
a word, the wheel scrolls, a divider can be dragged (the sidebar's edge resizes it), and the Explorer, the tab line
(a click shows the tab, the `×` closes it), the status bar's items and the menu bar answer clicks. Ctrl-click in
the Explorer adds a row to the selection (Shift-click belongs to the terminal, see below). A click on the menu
bar opens a text menu: move with the arrow keys, `RET` takes an item, `C-g` closes it. drgnx turns this on for each terminal window when it opens, never for a
graphical window, with the SGR mouse protocol; the Linux console, which the table lists without mouse reporting,
keeps its mouse.

While the mouse is on, the terminal gives the mouse to drgnx, so **selecting text with the terminal's own selection
is Shift+drag** in most terminals: Option+drag in iTerm2, and in kitty whatever its `terminal_select_modifiers`
says. Pasting stays the terminal's paste key. To keep the terminal's behaviour instead, run **Toggle Mouse in
Terminal Windows** (palette: "mouse"); it saves the choice. The same is the setting
`drgnx-tty-mouse` (`M-x customize-variable`): `nil` leaves the mouse to the terminal. On Emacs 31 the
setting also overrides Emacs's own default of turning the mouse on in terminals.

## Small terminals

A terminal has the size it has, so drgnx lays the workbench out by it. A new terminal window shows the **sidebar**
when it is at least 120 columns wide and the **panel** when it has at least 30 lines; a smaller one starts with the
editor alone, and the right dock stays hidden as in a graphical window. The docks are fractions of the terminal, so
they follow it when it changes: the sidebar is a quarter of the columns (at least 20), the right dock 30% (at least
24), the panel 30% of the lines (at least 6). A dock you resize yourself keeps the size you gave it when the terminal changes. What counts as your resize is the mouse drag of a divider and the commands `enlarge-window` (`C-x ^`), `shrink-window`, `enlarge-window-horizontally` (`C-x }`) and `shrink-window-horizontally` (`C-x {`), as far as they changed that dock; the setting `drgnx-tty-layout-resize-commands` lists them, for a package that resizes windows. A popup that borrows the panel or Emacs squeezing a dock into a small window is no choice of yours.

When the terminal grows, a dock its size had kept away comes (an 80x24 window that becomes 120x40 shows the sidebar
and the panel), unless you opened or closed that dock yourself in the meantime. When it shrinks, a dock you opened
stays open, only smaller. Below 40 columns or 12 lines drgnx shows and resizes nothing — a split tmux pane, a window
dragged to a sliver — and the editor stays; the docks come back at the next size that has room. A window that cannot
fit a dock never shows an error. The two sizes are the settings `drgnx-tty-layout-columns` (120) and
`drgnx-tty-layout-lines` (30) (`M-x customize-variable`). A window opened for one file (`emacsclient -t FILE`) shows
the editor only and is left alone.

## Clipboard

Copying in drgnx puts the text on your computer's clipboard through OSC 52 when the terminal takes it (the table's
"OSC 52 copy"), over SSH as well: the sequence travels through the connection unchanged. Emacs turns this on by
itself only when the terminal's version answer is 203 or more. drgnx also turns it on in **tmux** (which then
needs `set -s set-clipboard on`, see above) and in a **kitty** whose answer was lower. A terminal that does not
take OSC 52 (GNOME Terminal, Ptyxis) keeps the copy inside drgnx.

- **Long copies:** a copy whose OSC 52 text passes `xterm-max-cut-length` (100000 characters once encoded, about
  75000 characters of text) is not sent. drgnx says so once per terminal in the echo area ("too long for the
  terminal's clipboard (N characters); kept in drgnx") and the text stays in drgnx's kill ring. Emacs's own method
  would stop for two seconds instead.
- **Paste:** the profile's paste key (`C-v` in the VS Code profile, `C-y` in the Emacs profile) pastes drgnx's
  last copy, from the kill ring. To bring text in from other programs, paste with the terminal's own paste key
  (`C-S-v`, or Cmd+V on macOS). Emacs receives it as one bracketed paste: it arrives as text and none of it runs
  as a key.
- **Reading the terminal's clipboard** is off. Most terminals refuse an OSC 52 read, kitty asks you every time, and
  a refused read makes the yank wait two seconds. `M-x customize-variable` `drgnx-tty-clipboard-read` turns it on
  (terminals already open follow at once); then `C-y` asks the terminal for its clipboard first. With it off,
  drgnx leaves alone a read you turned on through Emacs's own `xterm-extra-capabilities`.

## Colours

A terminal shows 8, 256 or 16 million (true colour) colours. The theme looks as in a graphical window on a true-colour
terminal; on 256 colours it is approximated, on 8 colours only the basic ones remain.

- **True colour from each window.** Emacs reads `COLORTERM` from the environment the Emacs daemon was started with,
  not from the terminal you attach from, so a daemon started without it shows 256 colours in every window. drgnx
  reads the `COLORTERM` your `emacsclient` sends: when it is `truecolor` or `24bit` and your `TERM` has no true
  colour of its own, drgnx opens that window with the `-direct` entry of the same terminal (`xterm-256color` gives
  `xterm-direct`, `tmux-256color` gives `tmux-direct`), if the machine running the daemon has that terminfo entry.
  Windows without `COLORTERM` keep what their `TERM` says, so two windows of one daemon can differ.
  Terminals whose `TERM` has no `-direct` entry (`screen-256color`, `xterm-kitty`) do not get this; there, start the
  daemon with `COLORTERM=truecolor` (every window of it then has true colour), or install a terminfo entry with
  `RGB`, or set `TERM=xterm-direct` where the terminal can take it. The `-direct` entries send colours in the
  standard colon form; if a terminal draws wrong colours with it, start the daemon with `COLORTERM=truecolor`, which
  uses the older semicolon form.
- **Over SSH** a terminal-specific `TERM` without its terminfo entry on the remote machine gives 8 colours. The
  fixes are in the SSH section above.
- **Nothing is told by colour alone.** On 8 colours drgnx still tells states apart: git status by its letter at the
  edge of an Explorer row (`M` changed, `A` added, `U` untracked, `D` deleted, `C` conflict), a review finding by its
  severity word, the shown tab by its weight or inverse video, and Work items by their glyph and words. Each of
  these faces is checked on 8, 256 and 24-bit terminals: none draws its text in its own background colour.
  `drgnx-tty-frames-state-faces` lists them with the cue each relies on.

## What a terminal window lacks

- **Images:** the commit graph, image previews and other pictures need a graphical window; in a terminal they say so.
- **One font size:** a terminal shows one font in one size; headings and zoom do not change it.
- **Popups on Emacs 30.2:** child frames need Emacs 31 in a terminal. On 30.2, completion shows at the bottom.
- **Super (`s-`) keys:** only through kkp, and never inside tmux.
