# drgnx in a terminal

drgnx runs three ways, from the full experience down. Start at the first and go down only as far as you must:

1. **A graphical window** (`drgnx`, the app, the desktop entry) is the full experience: every key, images, the
   commit graph, the browser and Live panes, several font sizes, popups as floating frames.
2. **A capable terminal** (`drgnx -t`, `emacsclient -s drgnx -t`, `emacs -nw`, also over SSH and inside tmux with a
   few lines of tmux settings) gives the same workbench, the mouse, true colour and the clipboard. A terminal that
   speaks a key protocol (WezTerm, Ghostty, foot, kitty, Alacritty, xterm) sends every shortcut, `C-S-p` and `` C-` ``
   included. See [Keys](#keys) and [Get the full keys](#get-the-full-keys).
3. **A legacy terminal** (GNOME Terminal, Ptyxis, Terminal.app, the Linux console, tmux without `extended-keys`)
   cannot send `C-S-p`, `C-.` and the like. It has the same commands, with two more ways to type each shortcut:
   **Alt+Shift** with the key, or **F6** then the key. **F1** opens the command palette (VS Code keys; `M-x` in every
   profile), so every command can still be reached. See [Legacy terminals](#legacy-terminals-altshift-and-f6): its table
   lists every shortcut of the VS Code profile and what to press instead, and a test checks the table against the profile.

How much works in a terminal depends on the terminal: it has to send the shortcuts, copy to your computer's
clipboard, show true colour and report the mouse. This page lists what each common terminal can do, the shortcuts it
keeps for itself, and the line that fixes what is missing. [What a terminal window lacks](#what-a-terminal-window-lacks)
lists what only a graphical window has. `drgnx doctor` run in a terminal tells you which way you are on and what would
move you up ([Check this terminal](#check-this-terminal)).

**Works best:** WezTerm, Ghostty, foot, kitty and Alacritty (WezTerm first: it has modifyOtherKeys, where `C-g` keeps
stopping busy Lisp; the others get the kitty keyboard protocol, where it cannot, see [Keys](#keys)). They send `C-S-`
chords and the other shortcuts,
and copy to the clipboard, over SSH as well. Each keeps some `C-S-` chords for itself; [the fixes](#the-fixes) free
them.

The table is `drgnx-tty-terminals` in `core/drgnx-tty.el`; onboarding and the doctor read the same data.

## What each terminal can do

Each row is **reported** (drgnx's builders have not run it) or **verified**: a test tier ran drgnx in it (the notes
under the table say what ran and what did not). A reported cell comes from official documentation: the linked page,
or another official page or source named in [The fixes](#the-fixes), such as the kitty keyboard protocol's list of
terminals, xterm's manual, tmux's manual, or the default shortcuts Ptyxis ships. A cell marked **(unconfirmed)** rests
on secondary sources or general knowledge only. "Yes" means the terminal does it with its default settings. A test
checks that this column says "verified" exactly for the rows the table's data marks verified.

| Terminal | kkp | modifyOtherKeys | OSC 52 copy | True colour | Mouse | Shortcuts it keeps | Row |
|---|---|---|---|---|---|---|---|
| [kitty](https://sw.kovidgoyal.net/kitty/conf/) | yes | no (unconfirmed) | yes | yes | yes (unconfirmed) | 62, all `C-S-`: `C-S-c` `C-S-v` `C-S-t` `C-S-p` `C-S-<return>` `C-S-<left>`/`<right>`/`<up>`/`<down>` … | verified in part (kkp, copy, colour) |
| [WezTerm](https://wezterm.org/config/key-encoding.html) | no (opt-in) | yes | yes | yes (unconfirmed) | yes (unconfirmed) | 55: `C-S-c` `C-S-v` `C-S-t` `C-S-n` `C-S-w` `C-S-p` `C-S-f` `C-S-<arrows>` …, and `s-` keys | reported |
| [foot](https://codeberg.org/dnkl/foot/src/branch/master/doc/foot.ini.5.scd) | yes | no (unconfirmed) | yes | yes | yes | `C-S-c` `C-S-v` `C-S-r` `C-S-n` `C-S-o` `C-S-z` `C-S-x` `C-S-u` | reported |
| [Ghostty](https://ghostty.org/docs/config/reference) | yes | yes (unconfirmed) | yes | yes (unconfirmed) | yes | (unconfirmed) `C-S-c` `C-S-v` `C-S-t` `C-S-n` `C-S-w`, and more (`ghostty +list-keybinds --default`) | reported |
| [Alacritty](https://alacritty.org/config-alacritty.html) | yes | no (unconfirmed) | yes | yes (unconfirmed) | yes (unconfirmed) | `C-S-c` `C-S-v` `C-S-f` `C-S-b` `C-S-SPC` `C-S-o` | reported |
| [iTerm2](https://iterm2.com/documentation-preferences-profiles-keys.html) | no (unconfirmed; a setting) | no (unconfirmed) | no (unconfirmed) | yes (unconfirmed) | yes (unconfirmed) | (unconfirmed) Cmd keys (`s-c` `s-v` `s-t` …) | reported |
| [GNOME Terminal, Ptyxis (VTE)](https://gitlab.gnome.org/GNOME/vte/-/issues/2495) | no (unconfirmed) | no | no | yes (unconfirmed) | yes (unconfirmed) | `C-S-c` `C-S-v` `C-S-t` `C-S-n` `C-S-o` `C-S-f` `C-S-a` `C-S-w` `C-S-q` `C-S-<prior>` `C-S-<next>` `S-<f10>` `C-M-S-t` | reported |
| [Terminal.app](https://support.apple.com/guide/terminal/change-profiles-keyboard-settings-trmlkbrd/mac) | no (unconfirmed) | no (unconfirmed) | no (unconfirmed) | no (unconfirmed) | yes (unconfirmed) | (unconfirmed) Cmd keys (`s-c` `s-v` `s-t` …) | reported |
| [xterm](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) | no (unconfirmed) | yes | no | no (unconfirmed) | yes | (unconfirmed) `S-<prior>` `S-<next>` `S-<insert>` | verified (xterm-like) |
| [Linux console](https://man7.org/linux/man-pages/man4/console_codes.4.html) | no (unconfirmed) | no (unconfirmed) | no | no (unconfirmed) | no (unconfirmed) | (unconfirmed) `M-<f1>`…`M-<f12>`, `C-M-<f1>`…`C-M-<f12>` (switch consoles) | reported |
| [tmux](https://man.openbsd.org/tmux) | no | no | no | no | yes (unconfirmed) | `C-b` (its prefix) | verified |

- **kitty, verified:** `emacsclient -t` in kitty 0.48 (Fedora 45, Emacs 31.1; `bin/drgnx test
  --container --tty`) gets kkp, with no Alt+Shift or F6 layer and no hint. `C-S-p`, `C-S-f`, `C-S-e`, `` C-` `` and
  `C-.` reach their commands through kitty's own key encoder. A copy (`S-<right>`, `C-c`) reaches the clipboard,
  there are 16777216 colours, and `C-g` stops a program Emacs waits for. Still unconfirmed: the mouse reports kitty
  itself sends (the test sends them as bytes, and Emacs handles them) and the shortcuts kitty keeps (the test's keys
  bypass them).
- **tmux, verified:** the tty tier (`bin/drgnx test --tty`, and in the Fedora 44 and 45 containers) runs drgnx inside
  a private tmux server, a new one for every test, with the tmux settings of [drgnx inside tmux](#drgnx-inside-tmux)
  off and on in turn. It checks that drgnx identifies tmux, asks it for modifyOtherKeys (level 1 and 2, and the `csi-u`
  format), sends a copy as OSC 52 through `set-clipboard on` or through `allow-passthrough on` and keeps it in drgnx
  when neither is set, sees focus events, gets true colour with an `RGB` feature, and reports missing settings without
  writing `~/.tmux.conf`. The keys are sent to the pane as the bytes a terminal sends, so tmux's own key parsing is
  not part of it.
- **xterm, verified as "xterm-like":** the same tier opens its terminal windows with `TERM=xterm-256color`, the way
  xterm (and any terminal that gives no name) looks to Emacs. With it drgnx's layout, mouse (as SGR reports), popups,
  256 colours and 24-bit colour from `COLORTERM` are tested, and C-S- chords through modifyOtherKeys. It is **not**
  a real xterm window: xterm's own defaults (the OSC 52 refusal, its shortcuts) rest on its manual.
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
- **WezTerm:** no setting needed for keys: it sends modifyOtherKeys, which drgnx turns on. Its default bindings take
  `C-S-p` (its own command palette) and more. `config.disable_default_key_bindings = true` in `wezterm.lua` frees them all.
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
- **tmux:** see [below](#drgnx-inside-tmux).

## Keys

`C-S-p`, `` C-` ``, `C-.` and the other chords of your profile reach drgnx only through a key protocol: a plain
terminal sends `C-S-p` as `C-p`, and `C-.` not at all. drgnx turns on one protocol in each terminal window:

- **modifyOtherKeys**, wherever the terminal has it: xterm, WezTerm, and tmux with `extended-keys on`.
  drgnx asks the terminal for it when Emacs did not, and decodes every chord (Emacs alone decodes only a few, so
  `C-S-p` would type text). Under tmux drgnx reads `extended-keys` and asks tmux for it when it is `on` or
  `always`. When it is `off`, or tmux is too old to have the option (before 3.2), the window counts as plain.
  Every chord arrives except `s-` and `H-` keys, and inside tmux the ones tmux folds into others (`C-S-p` as `C-p`,
  see [drgnx inside tmux](#drgnx-inside-tmux)). This needs no package.
- **The kitty keyboard protocol (kkp)**, for terminals that have kkp but no confirmed modifyOtherKeys: kitty, foot,
  Alacritty, Ghostty, and iTerm2 with the setting in [The fixes](#the-fixes). For a terminal drgnx knows, its row
  in the table decides, whatever Emacs's own start-up test did: Emacs asks Alacritty for modifyOtherKeys, which it
  does not have, and drgnx takes that request back. The `ui/terminal-keys` module uses the `kkp`
  package from MELPA, pinned in drgnx's lock (`drgnx sync` installs it). When such a terminal window opens, kkp
  asks the terminal once whether it speaks the protocol (`CSI ? u`) and waits 0.2 s at most. A terminal that says
  no, or does not answer, keeps its plain keys. If the answer starts but does not finish in time (a slow SSH
  link), drgnx takes the half-made change back, the window keeps its plain keys, and drgnx records the
  problem. Under kkp every key arrives, `s-` keys included.
- **Neither** (GNOME Terminal, Ptyxis, Terminal.app, the Linux console): Alt+Shift with the key, or F6 then the key
  (see [Legacy terminals](#legacy-terminals-altshift-and-f6)), or the palette with **F1** (VS Code keys) or `M-x`;
  every command is there. `terminal-report.eld` lists the keys of your profile this terminal cannot send.

Each terminal window keeps its own keys: a kitty window and a Ptyxis window on the same drgnx each get what their
terminal can send.

**`C-g` in a kkp terminal (kitty).** modifyOtherKeys leaves `C-g` the plain byte it always was, so it stops
anything, busy Lisp included; that is why drgnx prefers it. Under kkp the terminal sends `C-g` as an escape
sequence, which Emacs reads only between commands. drgnx turns on kkp's `kkp-restore-legacy-keys-around-subprocesses`,
so while Emacs waits for a program (a `git` that hangs, say) the terminal sends plain keys and `C-g` stops the
program. But `C-g` cannot stop busy Lisp (a long computation, a loop) in a kkp terminal; `terminal-report.eld`
says so for that terminal (`:c-g waits`). To keep `C-g` working everywhere, set **`drgnx-tty-use-kkp`** to `nil`
(`M-x customize-variable`; it applies to terminal windows opened afterwards). kitty, foot, Alacritty and Ghostty
are then legacy terminals: type a `C-S-` chord as Alt+Shift with the key, or F6 then the key (see
[Legacy terminals](#legacy-terminals-altshift-and-f6)).

Ctrl+Shift+`` ` `` arrives from xterm and tmux as Ctrl+Shift+`~` (the character Shift makes on a US layout);
drgnx reads it as `` C-S-` `` (New Terminal). On other layouts, use the palette if the key does nothing.

Without the `kkp` package, `ui/terminal-keys` waits and the doctor's module check names it
(`ui/terminal-keys (kkp)`); modifyOtherKeys works as above.

## Get the full keys

A terminal can send `C-S-` chords and the other shortcuts in three ways. They are listed best first, and drgnx uses
the best one the window has:

1. **A GUI frame** (`drgnx` opens one): every key, no protocol needed.
2. **A terminal with a key protocol.** modifyOtherKeys is preferred: **WezTerm** and **xterm** have it, and `C-g`
   keeps stopping busy Lisp there (WezTerm needs no setting for it). The kitty keyboard protocol is used where
   modifyOtherKeys is missing or unconfirmed: **Ghostty**, **foot**, **kitty** and **Alacritty**; it works, but `C-g`
   cannot stop busy Lisp there (see [Keys](#keys)). Ghostty's and foot's modifyOtherKeys support is unconfirmed, so
   they are counted with kitty.
3. **A legacy terminal** (GNOME Terminal, Ptyxis, Terminal.app, the Linux console, tmux without `extended-keys`):
   hold **Alt+Shift** with the key, or press **F6** and then the key (the fallback layer, see
   [Legacy terminals](#legacy-terminals-altshift-and-f6)), or use F1 and the palette.

When a window has only the third way, drgnx tells you which terminal would give it the second. It lists the ones
you already have first ("kitty is installed: run `drgnx -t` from kitty"). If none is installed, it prints the install
command for your system, for the first two. **drgnx never installs anything**: it reads your `PATH` (and, on macOS,
`/Applications`) and `/etc/os-release`, and prints.

| Terminal | Fedora | Debian, Ubuntu | Arch | macOS |
|---|---|---|---|---|
| WezTerm | [download](https://wezterm.org/installation.html) | [download](https://wezterm.org/installation.html) | `sudo pacman -S wezterm` | `brew install --cask wezterm` |
| xterm | `sudo dnf install xterm` | `sudo apt install xterm` | `sudo pacman -S xterm` | none |
| Ghostty | [download](https://ghostty.org/docs/install/binary) | [download](https://ghostty.org/docs/install/binary) | `sudo pacman -S ghostty` | `brew install --cask ghostty` |
| foot (Wayland) | `sudo dnf install foot` | `sudo apt install foot` | `sudo pacman -S foot` | none |
| kitty | `sudo dnf install kitty` | `sudo apt install kitty` | `sudo pacman -S kitty` | `brew install --cask kitty` |
| Alacritty | `sudo dnf install alacritty` | `sudo apt install alacritty` | `sudo pacman -S alacritty` | `brew install --cask alacritty` |

On an image-based Fedora (Silverblue, Kinoite, Bazzite; drgnx sees `/run/ostree-booted`) the Fedora packages are
`rpm-ostree install xterm`, `rpm-ostree install foot` and `rpm-ostree install kitty` (a restart finishes it); `dnf` is
never suggested there. WezTerm and foot have Flatpaks on Flathub, but a Flatpak terminal runs its shell inside the
sandbox, where drgnx is not, so drgnx does not suggest them.

xterm is the last resort for looks: no clipboard copy over SSH and 256 colours (drgnx says so wherever it names xterm),
but it has modifyOtherKeys, so it ranks right after WezTerm, and first among the packages Fedora and Debian have.
Ghostty, foot, kitty and Alacritty get the kitty keyboard protocol, so `C-g` cannot stop busy Lisp there.

Other systems, and the RHEL clones (Rocky, Alma: kitty is only in EPEL) and Amazon Linux, get each terminal's download
page. The commands were checked against the distributions' package indexes on 2026-10-18. A distribution derived from
one of these (Linux Mint, Nobara, EndeavourOS) gets its parent's commands. For two packages to install, drgnx prefers
the ones it has a package command for over download pages, in the order above.

**Open `drgnx -t` in one of them.** Off by default. Set **`drgnx-tty-open-in`** (`M-x customize-variable`) to `auto`
(the first installed terminal of the table that fits your display: foot needs Wayland, xterm X11) or to one terminal
(`wezterm`, `ghostty`, `xterm`, `foot`, `kitty`, `alacritty`), and `drgnx -t` starts it with drgnx inside. On macOS,
WezTerm, kitty and Alacritty are started through the command inside their application, and Ghostty with
`open -na Ghostty.app --args -e …` (its own command line cannot open a window on macOS), which returns at once. Over SSH, or with no
display, it does nothing and `drgnx -t` runs in the terminal you are in.

## Legacy terminals: Alt+Shift and F6

A terminal without a key protocol (GNOME Terminal, Ptyxis, Terminal.app, the Linux console) cannot send `C-S-p`,
`C-.` and the like, and tmux at modifyOtherKeys level 1 folds `C-S-<letter>` into `C-<letter>`. Such a terminal gets
the **fallback layer**: two more ways to type each chord it cannot send. A terminal with kkp or modifyOtherKeys, and a
graphical window, get none, and each terminal window on one drgnx has its own (kkp turned on later takes it away).

- **Alt+Shift with the key**, where it is free: **Alt+Shift+F** is Search in Project (`C-S-f`), Alt+Shift+E the
  Explorer. It is decided when you press it: in a buffer whose mode binds that Alt+Shift key (`M-F`) itself, the mode
  keeps it, and where the chord itself does nothing, Alt+Shift stays what Emacs makes of it. With VS Code keys this
  means Alt+Shift+F, B, E, A and the like no longer select by word in a legacy terminal (Emacs's shift selection of
  Alt+F, Alt+B…): select with Ctrl+Shift+← and →, which every terminal sends. Some chords have no Alt+Shift key,
  and drgnx guesses no other one for them: where Emacs uses it
  (Alt+Shift+. is the end of the buffer, Alt+Shift+\` is `not-modified`), and where a terminal starts its replies with it.
  **Alt+Shift+P** is `ESC P`, how a terminal begins its answer to "which terminal are you?"; an answer that arrives
  late would otherwise open the palette and type its text. So Ctrl+Shift+P is **F6 p**, or **F1** (VS Code keys).
- **F6 then the key**, always. F6 adds Ctrl, and Shift to a letter or Space (Ctrl with a letter needs no help):
  F6 p is `C-S-p`, F6 . is `C-.`, F6 Enter is `C-<return>`, F6 Tab is `C-<tab>`, F6 Shift+Tab is `C-S-<tab>`. A
  Shift+punctuation chord is typed with the character Shift makes (`` C-S-` `` is F6 ~); Enter and Backspace, which
  a terminal sends no Shift with, take Alt for it (`C-S-<return>` is F6 Alt+Enter); `C-SPC` is F6 Ctrl+Space. While
  F6 waits, the echo area says `Ctrl+Shift+…`; `C-g` quits, a key typed before F6 included (C-x F6 C-g); Esc
  cancels F6 alone; F6 twice is F6. A click, a paste or a focus change after F6 drops F6 and happens as usual.

The first time a kind of terminal with the layer connects, one message says so: "This terminal can't send Ctrl+Shift
keys: use Alt+Shift (or F6 then the key). drgnx doctor has details." It is never a question, and it is said once per
kind of terminal, ever (`terminal-report.eld` remembers it as `:hinted`). It comes half a second after the window
opens, and only if the layer is still on then: a kitty has no kitty keyboard protocol for the moment before its answer
arrives, and gets no message.

`terminal-report.eld` keeps the 16 terminals set up most recently (one entry per terminal device). It has, for each
terminal, `:fallback` (the layer is on) and `:fallbacks`: every chord of your
profile a plain terminal cannot send, as `(CHORD NATIVE-P ALT PREFIX)`, where NATIVE-P says this terminal sends it
itself. `drgnx-tty-sendable-key` gives any key as a terminal window can type it (`M-F`, `<f6> p`, or the key itself).
The command palette, the menus, the "next time" tips and the key sheet show keys that way, and the key sheet has a
section, "Keys this terminal cannot send, and what to press here"; in the Keyboard Shortcuts editor `†` names the
key to press and **Set the Terminal Fallback** (`t`) changes it ([shortcuts.md](shortcuts.md#terminal-mark)).

Settings (`M-x customize-variable`):

- **`drgnx-tty-fallback`** (`t`): `nil` takes the layer off every terminal.
- **`drgnx-tty-chord-prefix`** (`<f6>`). F6 because it is free in Emacs and in every drgnx profile, and every
  terminal sends it and keeps none of it (Terminal.app with fn on a Mac keyboard). The others are taken: F1 help and
  the palette, F2 rename and Emacs's two-column prefix, F3 and F4 keyboard macros, F5 and F9–F12 VS Code's debug and
  go-to keys, F8 the Emacs profile's sidebar, F10 the menu (VTE keeps F10 and F11).
- **`drgnx-tty-fallback-hint`** (`t`): `nil`, no message.
- **`keys.eld`'s `:tty-fallback`** gives a chord another Alt key: `(:tty-fallback (("C-S-p" . "M-Z")))`. The key must
  be Alt with a character key, unused by Emacs and your profile, not reserved, and not another chord's; otherwise it
  is not used and a notice says why (the doctor's `terminal-keys` row shows it), as it does for an entry that is not
  `(CHORD . KEY)` or names a chord your profile needs no fallback for.

With VS Code keys (the rows are what `drgnx-tty-fallback-table` computes from the profile; a test fails if this table and the profile differ):

| Chord | Command | Alt+Shift | F6 |
|---|---|---|---|
| `C-S-p` | Command Palette | — | `F6 p` |
| `C-,` | Settings | — | `F6 ,` |
| `C-S-s` | Save As… | `Alt+Shift+S` | `F6 s` |
| `C-S-t` | Reopen Closed Tab | `Alt+Shift+T` | `F6 t` |
| `C-S-n` | New Window | `Alt+Shift+N` | `F6 n` |
| `` C-` `` | Toggle Panel | — | `` F6 ` `` |
| `C-1` | Focus First Editor Group | — | `F6 1` |
| `C-2` | Focus Second Editor Group | — | `F6 2` |
| `C-3` | Focus Third Editor Group | `Alt+Shift+3` | `F6 3` |
| `C-'` | Menu for This Mode | `Alt+Shift+'` | `F6 '` |
| `C-S-e` | View: Explorer | `Alt+Shift+E` | `F6 e` |
| `C-SPC` | Mark | — | `F6 Ctrl+Space` |
| `C-M-S-c` | Copy Relative Path | — | `F6 Alt+C` |
| `C-S-b` | Focus Buffers | `Alt+Shift+B` | `F6 b` |
| `C-{` | Fold | — | `F6 {` |
| `C-}` | Unfold | — | `F6 }` |
| `C-S-a` | Select All | `Alt+Shift+A` | `F6 a` |
| `C-S-z` | Redo | `Alt+Shift+Z` | `F6 z` |
| `C-/` | Toggle Comment | — | `F6 /` |
| `C-S-k` | Delete Line | `Alt+Shift+K` | `F6 k` |
| `C-<return>` | New Line Below | — | `F6 Enter` |
| `C-S-<return>` | New Line Above | — | `F6 Alt+Enter` |
| `C-<backspace>` | Delete Word Left | — | `F6 Backspace` |
| `C-S-SPC` | Show Hover | — | `F6 Space` |
| `C-.` | Quick Fix | — | `F6 .` |
| `C-S-m` | Problems | `Alt+Shift+M` | `F6 m` |
| `C-S-f` | View: Search | `Alt+Shift+F` | `F6 f` |
| `C-S-o` | Go to Symbol | — | `F6 o` |
| `C-<tab>` | Recent Buffers | — | `F6 Tab` |
| `C-S-h` | Replace in Files | `Alt+Shift+H` | `F6 h` |
| `` C-S-` `` | New Terminal | — | `F6 ~` |
| `C-S-g` | Source Control | `Alt+Shift+G` | `F6 g` |
| `C-=` | Zoom In | `Alt+Shift+=` | `F6 =` |
| `C-+` | Zoom In | — | `F6 +` |
| `C--` | Zoom Out | — | `F6 -` |
| `C-0` | Reset Zoom | — | `F6 0` |
| `C-!` | Replace This Match (the Replace bar) | — | `F6 !` |

The Replace bar's `S-<return>` (Previous Match) and `C-M-<return>` (Replace All) have no F6 form, since F6 adds Ctrl and
Alt already stands for Shift on Enter: in a legacy terminal use their other keys, `S-<f4>` and `C-<return>` (F6 Enter).

## SSH

Run drgnx on the remote machine and attach from your terminal: `ssh box -t emacsclient -s drgnx -t`. Keys, mouse and
OSC 52 copy travel over SSH unchanged. The remote end can only see `TERM`, so drgnx may not know which terminal you
are in. A terminal-specific `TERM` (`xterm-kitty`, `xterm-ghostty`, `foot`) needs its terminfo entry on the remote
machine. Without it, Emacs falls back to 8 colours or refuses the terminal. To fix this, install the entry with
`infocmp -x | ssh box tic -x -`. Or use `kitten ssh` in kitty, or Ghostty's `ssh-terminfo` shell integration. Or
connect with `TERM=xterm-256color`.

## drgnx inside tmux

Inside tmux, drgnx talks to tmux, not to your terminal: tmux decides which keys, copies and focus changes get
through, and its defaults block most of them. drgnx reads tmux's settings when a terminal window opens (`tmux show`,
asked of the tmux the window runs in, 1 second at most), works with what tmux allows, and writes the lines you can
add for the rest into `terminal-report.eld`. **drgnx never writes `~/.tmux.conf`.** Add the
lines you want yourself, then run `tmux source ~/.tmux.conf` and open a new terminal window (settings are read when
one opens). The lines, in this order, each only if it is missing:

```
set -s set-clipboard on                       # copy reaches your clipboard (the default, external, refuses programs)
set -s extended-keys on                       # C-S- chords, C-. … (modifyOtherKeys)
set -g allow-passthrough on                   # tmux 3.3 and later, if set-clipboard stays off: copy goes around tmux
set -g focus-events on                        # drgnx sees when the window gains or loses focus
set -as terminal-features ',xterm-kitty:RGB'  # true colour; the TERM of the terminal around tmux
```

- **Copy** goes out as OSC 52 when `set-clipboard` is `on`. Otherwise, with `allow-passthrough on`, drgnx wraps the
  same sequence in tmux's passthrough (`ESC P tmux;` … `ESC \`, every `ESC` doubled) and tmux hands it to the
  terminal unchanged. With neither, the copy stays in drgnx and the terminal's capabilities say no OSC 52. The
  terminal around tmux must take OSC 52 as well (the table above), and over SSH or a second tmux each layer needs
  its own setting. drgnx builds the sequence itself, so it also works with `TERM=screen`, tmux's old default.
- **Keys:** with `extended-keys on` tmux sends chords as modifyOtherKeys, and drgnx asks for **level 1**, Emacs's
  own. Then `C-g` always works (it stays one byte and stops a runaway Lisp loop), but tmux folds some chords into
  others: `C-S-<letter>` (and `C-M-S-<letter>`) arrive as `C-<letter>`, `C-S-SPC` and `` C-` `` as `C-SPC`, `` C-S-` ``
  as `C-^` (tmux 3.7c). drgnx lists those in `terminal-report.eld` as keys this terminal cannot send (the key sheet
  lists them with what to press instead: Alt+Shift or F6 then the key), and the capabilities carry them as
  `:folded`. `M-x customize-variable` `drgnx-tty-tmux-mok-level` set to `2` asks for level 2 (it applies to the
  tmux windows already open too): C-S-letter chords work natively in tmux, but `C-g` can no longer stop a runaway
  Lisp loop (it reaches Emacs as an escape sequence; prompts and commands still take it, and the capabilities say
  `:c-g waits`, as for the kitty keyboard protocol). `extended-keys-format csi-u` (tmux 3.5 and
  later) works too, drgnx decodes it, but it gains nothing, so the lines above do not suggest it.
- **Focus:** with `focus-events on` the window's focus changes reach drgnx, which refreshes what depends on focus (the
  Explorer's git state).
- **True colour:** the `terminal-features` line tells tmux the terminal around it takes 24-bit colour; Emacs also
  needs `COLORTERM=truecolor` in the environment tmux starts it with. The line names that terminal's `TERM` (here
  `xterm-kitty`; drgnx fills it in).

tmux keeps `C-b` as its prefix. Press `C-b` twice to send it to drgnx, or set another prefix with `set -g prefix`.
tmux does not pass the kitty keyboard protocol, so `s-` keys do not arrive inside tmux. A tmux on the other side of
SSH (`TERM=tmux-*` without `TMUX` set) is known to be tmux, but drgnx cannot ask it: copy is sent as plain OSC 52 and
Emacs's own key choice stays.

## EDITOR

Onboarding suggests `EDITOR='emacsclient -s drgnx -t'`: `git commit` and other programs that open an editor then
open it in drgnx, in the terminal you ran them from.

A client that opens a file this way (`emacsclient -t FILE`) gets the **editor only**: no sidebar, panel or right
dock, so the commit message has the whole terminal. It is never the main window. Close its tab (Close Tab, or
the tab's `×`) or press `C-x #`: the edit ends and the program that opened it goes on, as with `code --wait`. If
the file has unsaved changes, drgnx first asks whether to save it (answering no ends the edit without them, as
`C-x #` does). Moving the tab to another group or window does not end the edit. `emacsclient -t` without a file
(and `drgnx -t`) opens the whole workbench.

## Popups

A transient menu, which-key's hints, `*Completions*`, help from the minibuffer and the calendar show in the popup
lane at the bottom of the terminal window ([workbench.md](workbench.md#popups)). Nothing is drawn over your text:
while a popup is open the editor above it is a little shorter and the line you are on stays on the screen; when it
ends, every window has its size back. A popup in one window never appears in another: with a graphical window and a
terminal window on one daemon, a transient in one leaves the other alone.

- **Completion** (corfu, when you have it) draws its popup (corfu, when you have it) as a floating child frame of the
  terminal window, as in a graphical window. A child frame with a border draws it with box-drawing characters
  (`┌ ─ ┐ │ └ ┘`) while every terminal on the daemon writes UTF-8, and with `+ - |` as soon as one does not. The border
  glyphs are one shared table, so the choice follows the terminals that are connected.
- **A terminal that does not write UTF-8** (a window started with `LANG=C`) cannot show `×`, `●`, `›`, `▾`, `▸` or
  `│`. drgnx draws ASCII marks in their place in that window only (`x`, `*`, `>`, `v`, `>`, `|`), in the tab line,
  the breadcrumb, the Explorer and the docks' headings, instead of Emacs's `\u00D7` escapes. A UTF-8 terminal is not
  touched. Set a UTF-8 locale in the terminal's profile to get the real glyphs. (Text that a header makes only when
  it is drawn stays as Emacs shows it.)

Other child-frame packages (posframe, eldoc-box) keep their own look and get no workbench chrome, as in a graphical
window. drgnx ships none of them; a child frame they make follows the same border glyphs.

## What drgnx asks the terminal

When a terminal window opens, drgnx works out which terminal it is from that client's own environment (in a
daemon, never the daemon's) and asks the terminal its name and version once (XTVERSION), waiting 0.2 s at most;
a terminal that does not answer just stays unnamed (an answer that comes later is still used). A second window of
the same kind of terminal asks nothing. Which keys arrive, colours and the rest are read for each window. What it
found — how keys arrive (kitty keyboard protocol, modifyOtherKeys, or neither), OSC 52, colours, the mouse — and the
keys of your profile this terminal cannot send are written to `terminal-report.eld` in drgnx's state directory
(`~/.local/state/drgnx/`), one entry per terminal device, for the doctor and the key sheet. The file is written
whole and then renamed into place, so two Emacs processes never leave half of it, and nothing ever asks about it.
If `terminal-report.eld` has a mistake (edited by hand, say), it is read as no report and the next terminal window
writes it anew.
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
needs `set-clipboard on` or `allow-passthrough on`, see [drgnx inside tmux](#drgnx-inside-tmux)) and in a
**kitty** whose answer was lower. A terminal that does not take OSC 52 (GNOME Terminal, Ptyxis) keeps the copy
inside drgnx.

- **Long copies:** a copy whose OSC 52 text passes `xterm-max-cut-length` (100000 characters once encoded, about
  75000 characters of text) is not sent. drgnx says so once per terminal in the echo area ("too long for the
  terminal's clipboard (N characters); kept in drgnx") and the text stays in drgnx's kill ring. Emacs's own method
  would stop for two seconds instead.
- **Paste:** the profile's paste key (`C-v` in the VS Code profile, `C-y` in the Emacs profile) pastes drgnx's
  last copy, from the kill ring; in the VS Code profile `C-c` and `C-x` copy and cut a selection (see
  [keys.md](keys.md#copy-cut-and-paste)), and the copy reaches the terminal's clipboard. To bring text in from other programs, paste with the terminal's own paste key
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
  reads the `COLORTERM` your `emacsclient` sends: when it is `truecolor` or `24bit`, your terminal is one the table
  above lists with true colour, and your `TERM` has no true colour of its own, drgnx opens that window with the
  `-direct` entry of the same terminal (`xterm-256color` gives `xterm-direct`, `tmux-256color` gives `tmux-direct`),
  if the machine running the daemon has that terminfo entry; if Emacs cannot load it, the window opens as before.
  The setting `drgnx-tty-true-colour` (`M-x customize-variable`) chooses which windows: `known` (the default)
  as above, `t` for any window whose `COLORTERM` says so (also terminals the table does not list, and tmux, whose
  outer terminal decides whether colours get through), `nil` for none. Windows without `COLORTERM` keep what their
  `TERM` says, so two windows of one daemon can differ.
  Terminals whose `TERM` has no `-direct` entry (`screen-256color`, `xterm-kitty`) do not get this; there, install
  a terminfo entry with `RGB`, or set `TERM=xterm-direct` where the terminal can take it, or start the daemon with
  `COLORTERM=truecolor`: that forces true colour on **every** window of that daemon, including those of terminals
  that have only 256 colours, which then draw wrong colours. The `-direct` entries send colours in the standard
  colon form; if a terminal draws wrong colours with it, the daemon's `COLORTERM=truecolor` uses the older
  semicolon form.
- **Over SSH** a terminal-specific `TERM` without its terminfo entry on the remote machine gives 8 colours. The
  fixes are in the SSH section above.
- **Nothing is told by colour alone.** On 8 colours drgnx still tells states apart: git status by its letter at the
  edge of an Explorer row (`M` changed, `A` added, `U` untracked, `D` deleted, `C` conflict; ignored files, which have
  no letter, are italic), a review finding by its
  severity word, the shown tab by its weight or inverse video, and Work items by their glyph and words. Each of
  these faces is checked on 8, 256 and 24-bit terminals: none draws its text in its own background colour.
  `drgnx-tty-frames-state-faces` lists them with the cue each relies on.

## Check this terminal

`drgnx doctor`, run in a terminal, has a Terminal group; **Check This Terminal** (Help, in the palette; no key) shows
the same group inside drgnx for the terminal window you are in, in `*drgnx terminal*`. In a graphical window it says to
run it in a terminal window, or `drgnx doctor` in a shell. Outside a terminal the doctor prints one line, `not run from a
terminal`. Nothing prompts, nothing is installed, and inside tmux the only process is `tmux show` (1 second at most).
This is what Ptyxis (GNOME's VTE terminal) gives:

```
OK    terminal             GNOME Terminal, Ptyxis (VTE) (TERM=xterm-256color), terminfo found
OK    terminal-mouse       mouse reports are on: clicks, the wheel and drags work
WARN  terminal-keys        neither the kitty keyboard protocol nor modifyOtherKeys: this terminal cannot send C-S- chords and the like
      chord  native  fallback     prefix
      C-S-p  no      Alt+Shift+P  F6 p
      C-.    no      —            F6 .
      fix: This terminal cannot send C-S- chords and the like. To get every key, install a terminal that sends them
           (drgnx never installs one for you): xterm: sudo dnf install xterm; foot: sudo dnf install foot. …
WARN  terminal-clipboard   copy stays in drgnx: nothing carries OSC 52 to your clipboard
      fix: none: VTE does not take OSC 52 (GNOME VTE issue 2495); copy stays in drgnx
```

- **`terminal`:** which terminal this is (from the environment; inside tmux, tmux and the terminal around it), its
  `TERM`, and whether a terminfo entry for it exists here. A terminal drgnx does not know is `INFO`: F1 and the palette
  reach every command.
- **`terminal-colours`:** true colour, or how many colours; a terminal that has true colour but runs at 256 is told
  to set `COLORTERM=truecolor`.
- **`terminal-mouse`**, **`terminal-clipboard`:** from the terminal's row in the table above; the fix is that row's
  line (`none: …` where no setting helps).
- **`terminal-keys`:** the kitty keyboard protocol, modifyOtherKeys or neither. For a terminal that sends neither, the
  table lists every shortcut of your key profile it cannot send: whether the terminal sends it itself (`native`), the
  Alt+Shift key that stands for it (`—` where that key is in use or reserved) and the F6 form (see [Legacy
  terminals](#legacy-terminals-altshift-and-f6)). The fix names the capable terminals you have installed, or else the
  install command for your system. With no window of this terminal opened in drgnx yet, the table says `open drgnx in
  this terminal once to list them`.
- **`terminal-tmux`** (inside tmux only): `OK`, or a warning naming what tmux lacks (copy, keys, focus, true colour) with
  the fix `add to ~/.tmux.conf: LINE; LINE…, then run tmux source ~/.tmux.conf` ([the lines](#drgnx-inside-tmux)). drgnx
  never edits `~/.tmux.conf`. For a tmux on the other side of SSH, which drgnx cannot ask, an `INFO` with the full list
  to check there.
- **`terminal-ssh`** (over SSH only): whether this machine has your terminal's terminfo entry; if not, the fixes from
  [SSH](#ssh).

The doctor describes the newest window of the same kind of terminal that drgnx has opened (the capabilities it measured
are in `terminal-report.eld`); Check This Terminal measures the window you are in.

## What a terminal window lacks

- **Images:** the commit graph, image previews and other pictures need a graphical window; in a terminal they say so.
- **One font size:** a terminal shows one font in one size; headings and zoom do not change it.
- **Super (`s-`) keys:** only through kkp, and never inside tmux.
