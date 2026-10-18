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
terminal sends `C-S-p` as `C-p`, and `C-.` not at all. The `ui/terminal-keys` module turns on whichever protocol
the terminal has, in each terminal window:

- **The kitty keyboard protocol (kkp)**: kitty, foot, Ghostty, Alacritty, and WezTerm or iTerm2 with the setting
  in [The fixes](#the-fixes). drgnx uses the `kkp` package from MELPA, pinned in drgnx's lock (`drgnx sync`
  installs it). When a terminal window opens, kkp asks the terminal once whether it speaks the protocol
  (`CSI ? u`) and waits 0.2 s at most. A terminal that says no, or does not answer, keeps its plain keys. Under
  kkp every key arrives, `s-` keys included.
- **modifyOtherKeys**: xterm (Emacs turns it on there by itself) and tmux with `extended-keys on`. drgnx reads
  tmux's `extended-keys` and asks tmux for modifyOtherKeys when it is `on` or `always`. When it is `off`, drgnx
  does not ask, and the window counts as plain. Every chord arrives except `s-` and `H-` keys.
- **Neither** (GNOME Terminal, Ptyxis, Terminal.app, the Linux console): open the palette with **F1** (VS Code
  keys) or `M-x`; every command is there. `terminal-report.eld` lists the keys of your profile this terminal
  cannot send.

Each terminal window keeps its own keys: a kitty window and a Ptyxis window on the same drgnx each get what their
terminal can send.

**`C-g` still interrupts.** Under kkp a terminal sends `C-g` as an escape sequence. While Emacs waits for a program
(a `git` that hangs, say), it reacts only to the plain `C-g` byte. drgnx turns on kkp's
`kkp-restore-legacy-keys-around-subprocesses`: while Emacs waits, the terminal sends plain keys, so `C-g` stops
the program.

Without the `kkp` package the module waits, and the doctor's module check names it (`ui/terminal-keys (kkp)`).
modifyOtherKeys then works only for the few chords Emacs decodes itself (`C-<tab>`, `C-.`, `C-,` …), not for
`C-S-` chords.

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
Like Emacs's own terminal setup, the question drops keys typed ahead while a new terminal window opens. kkp asks
its own question, once per terminal, waiting 0.2 s at most (see [Keys](#keys)); its answer is added to the report.

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
  (terminals already open follow at once); then `C-y` asks the terminal for its clipboard first.

## What a terminal window lacks

- **Images:** the commit graph, image previews and other pictures need a graphical window; in a terminal they say so.
- **One font size:** a terminal shows one font in one size; headings and zoom do not change it.
- **Popups on Emacs 30.2:** child frames need Emacs 31 in a terminal. On 30.2, completion shows at the bottom.
- **Super (`s-`) keys:** only through kkp, and never inside tmux.
