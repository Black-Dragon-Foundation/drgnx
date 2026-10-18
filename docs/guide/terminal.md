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

## Clipboard

Copying in drgnx puts the text on your computer's clipboard through OSC 52 when the terminal takes it (the table's
"OSC 52 copy"). In other terminals the copy stays inside drgnx. To bring text in from other programs, paste with the
terminal's own paste key (`C-S-v`, or Cmd+V on macOS). Emacs receives it as one bracketed paste.

## What a terminal window lacks

- **Images:** the commit graph, image previews and other pictures need a graphical window; in a terminal they say so.
- **One font size:** a terminal shows one font in one size; headings and zoom do not change it.
- **Popups on Emacs 30.2:** child frames need Emacs 31 in a terminal. On 30.2, completion shows at the bottom.
- **Super (`s-`) keys:** only through kkp, and never inside tmux.
