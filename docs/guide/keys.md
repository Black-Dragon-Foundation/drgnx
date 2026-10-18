# Keys

drgnx speaks **VS Code, Emacs and Vim** keys, and combinations of them: Vim or Emacs for editing with VS Code's
shortcuts for everything else. Commands are registered once, without keys; **key profiles** give them keys,
**layers** stack the profiles, and your **`keys.eld`** wins over everything. Every surface — menus, the command
palette, the key sheet, which-key, the markdown cheat sheet — shows the keys that are active right now.

## Choosing a profile

**Preferences: Keyboard Profile…** (in the command palette and the Options menu) switches at once, without a
restart, and remembers the choice in `keys.eld` (`RET` with nothing typed keeps the current profile):

| Preset | Stack (later layers win) |
|---|---|
| VS Code (default) | `vscode` for app, editing and window commands |
| Emacs | `emacs` for everything |
| Vim | `vim` for everything — its keys work once the evil module is installed (M4) |
| Emacs editing + VS Code app keys | `emacs` editing, then `vscode` app and window |
| Vim editing + VS Code app keys | `vim` editing, then `vscode` app and window |

The onboarding flow will ask which one you want (VS Code preselected).

## Keys of the core commands

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| Command Palette | `C-S-p`, `F1` | `C-S-p` | `SPC SPC` |
| Keyboard Shortcuts (key sheet) | `C-k C-r` | `C-h C-k` | `SPC ?` |
| Keyboard Profile… | `C-k C-p` | — | `SPC h k` |
| Leader Menu (the `SPC` keys from any state; in the Vim profile `M-SPC` replaces Emacs' `cycle-spacing`) | — | — | `M-SPC` |
| Next / Previous Row (in a panel: lists, tables, transcripts) | `<down>` / `<up>` | `<down>` / `<up>` | `j` / `k` |
| Preferences: Keyboard Shortcuts (the editor) | `C-k C-s` | — | `SPC h s` |
| Open File… | `C-o` | `C-x C-f` | `SPC f f` |
| Save | `C-s` | `C-x C-s` | `SPC f s` |
| Toggle Line Numbers | — | — | `SPC u l` |
| Module Report | — | — | `SPC h m` |
| Toggle Sidebar | `C-b` | `<f8>` | `SPC e` |
| Focus Explorer / Buffers | palette / `C-k e` | `C-x M-e` / `C-x C-b` | `SPC E` / `SPC ,` |
| View: Explorer / View: Search | `C-S-e` / `C-S-f` | palette / palette | palette / `SPC /` |
| Replace in Files | `C-S-h` | `C-c s r` | `SPC s r` |
| Toggle Panel / Right Dock | ``C-` ``, `C-j` / `C-M-b` | — / — | `SPC j` / `SPC R` |
| Close Tab / Next / Previous | `C-<f4>` / `C-<next>` / `C-<prior>` | — / Emacs' `C-x <right>` / `C-x <left>` | `SPC b d` / `SPC b n` / `SPC b p` |
| Split Editor Right / Down | ``C-\`` / ``C-k C-\`` | Emacs' `C-x 3` / `C-x 2` | `SPC w v` / `SPC w s` |
| Focus Group 1–3 / Move Editor to Next Group | `C-1`–`C-3` / `C-M-<right>` | `C-x o` / — | `SPC 1`–`SPC 3` / `SPC w m` |
| Open Editor in New Window | `C-k o` | Emacs' `C-x 5 2` | `SPC w o` |
| Fold / Unfold | `C-{` / `C-}` | — | `SPC z c` / `SPC z o` |
| Expand / Shrink Selection | `M-S-<right>` / `M-S-<left>` | — | `SPC v` / `SPC V` |
| Zen Mode | `C-k z` | — | `SPC u z` |
| Next Layout / Layout… | `C-k C-l` / — | — / — | `SPC l n` / `SPC l l` |
| Go to Line | Emacs' `M-g g` | `M-g g` | `SPC g l` |
| Go to Definition / References / Rename Symbol / Hover | `F12` / `S-F12` / `F2` / `C-S-SPC` | Emacs' `M-.` / `M-?` / palette / `C-h .` | `SPC c d` / `SPC c r` / `SPC c R` / `SPC c h` |
| Source Control / Blame | `C-S-g` / — | Emacs' `C-x v d` / `C-x v g` | `SPC g s` / `SPC g b` |
| New Terminal | ``C-S-` `` | — | `SPC t n` |
| Quick Open / Search in Project / Go to Symbol | `C-p` / palette / `C-S-o` | Emacs' `C-x p f` / `C-x p g` / `M-g i` | `SPC f p` / `SPC s p` / `SPC s s` |
| Org Capture / Agenda | `C-c c` / `C-c a` | `C-c c` / `C-c a` | `SPC n c` / `SPC n a` |

The Explorer's and the Buffers panel's own keys (rows, expand, open, close) are in [workbench.md](workbench.md).
A command that lives in a mode's keymap (like those) keeps its keymap in every profile: an entry's `:map` wins,
else the command's own, else the profile's.

"—" means the profile has no key for it; every command is always in the palette. Vim's keys are leader keys in
evil's normal state. On **macOS** the VS Code profile uses Cmd (`s-`) as VS Code does there — see below.

## On a Mac

Keys are written the Emacs way: `s-` is Cmd ⌘, `M-` Option ⌥, `C-` Ctrl ⌃, `S-` Shift ⇧; `s-k s-s` is ⌘K then ⌘S. The
everyday keys of the VS Code profile on a Mac, as in VS Code:

| Command | Mac |
|---|---|
| Command Palette / Quick Open (files) | ⌘⇧P (or F1) / ⌘P |
| View: Search / Replace in Files / Find in File | ⌘⇧F / ⌘⇧H / ⌘F |
| Save / Save All / New Untitled / Close Tab / Reopen Closed Tab | ⌘S / ⌥⌘S / ⌘N / ⌘W / ⌘⇧T |
| Toggle Sidebar / View: Explorer / Toggle Panel / New Terminal | ⌘B / ⌘⇧E / ⌃\` / ⌃⇧\` |
| Source Control | ⌃⇧G |
| Go to Definition / References / Rename Symbol / Quick Fix | F12 / ⇧F12 / F2 / ⌘. |
| Toggle Comment / Select Line / Delete Line / Undo / Redo | ⌘/ / ⌘L / ⌘⇧K / ⌘Z / ⌘⇧Z |
| Edit with AI / Show Agents / Semantic Search | ⌘K ⌘E / ⌘K A / ⌘K ⌘F |
| Keyboard Shortcuts / Settings (All Preferences) | ⌘K ⌘S / ⌘, |
| Close Window / Quit drgnx | ⌘⇧W / ⌘Q |
| Cancel (a question, a running step) | ⌃G or Escape |

The function keys (F1, F2, F12) need Fn on a Mac keyboard unless "Use F1, F2, etc. keys as standard function keys" is
on (System Settings → Keyboard → Keyboard Shortcuts → Function Keys). Every command, with its key, is in the palette
and on the key sheet (⌘K ⌘S). Two keys with Shift and punctuation, ⌃⇧\` (New Terminal) and
⇧⌘Space (Show Hover), depend on the keyboard layout and are not yet confirmed on a real Mac: if one does nothing, run
the command from the palette.

The VS Code profile on macOS has **VS Code's own Mac keys**: `C-` becomes Cmd (`s-o`, `s-k s-s`), except where VS
Code on a Mac uses another key — there it has that one (`:mac` in `keys/vscode.eld`). Cmd+Shift with a letter is
written as Emacs on a Mac receives it, the capital letter: Shift+Cmd+P is `s-P` (the key sheet shows `s-P`), Shift+Cmd+Z
`s-Z`; Shift stays with other keys (`S-s-<return>`, `C-S-s-<right>`). drgnx writes every macOS key that way, also
yours (`:mac "S-s-y"` in `keys.eld` binds `s-Y`).

| Command | Linux | Mac |
|---|---|---|
| Toggle Panel / New Terminal | ``C-` `` / ``C-S-` `` | Ctrl: ``C-` `` / ``C-S-` `` (Cmd+` is macOS' next window) |
| Go to Recent / Back / Forward | `C-<tab>` / `M-<left>` / `M-<right>` | Ctrl: `C-<tab>` / `C--` / `C-_` (Ctrl+Shift+-) |
| Next / Previous Tab | `C-<next>` / `C-<prior>` | `M-s-<right>` / `M-s-<left>` (Option+Cmd+→ / ←) |
| Close Tab / Close Window | `C-w` / `C-q` | `s-w` / `s-W` (Shift+Cmd+W) |
| Quit drgnx | — (File → Quit; `C-q` closes the window as in VS Code) | `s-q` (offers to save, then stops drgnx) |
| Move Editor to Next Group | `C-M-<right>` | `C-s-<right>` (Ctrl+Cmd+→) |
| Expand / Shrink Selection | `M-S-<right>` / `M-S-<left>` | `C-S-s-<right>` / `C-S-s-<left>` (Ctrl+Shift+Cmd+→ / ←) |
| Fold / Unfold | `C-{` / `C-}` | `M-s-[` / `M-s-]` (Option+Cmd+[ / ]) |
| Select All / Save All | `C-S-a` / `C-k s` | `s-a` / `M-s-s` (Option+Cmd+S) |
| Source Control | `C-S-g` | Ctrl: `C-S-g` |
| All Preferences… / Preferences: Modules | — / `C-,` | `s-,` (the palette on every Preferences command) / — |
| Explorer: Copy Path / Reveal in Finder | `M-S-c` / `M-S-r` | `M-s-c` / `M-s-r` (Option+Cmd+C / R) |
| Explorer: Delete / Delete Permanently | `<delete>` / `S-<delete>` | `s-<backspace>` / `M-s-<backspace>` (and the Linux keys) |
| Explorer: Select (mark) | `C-SPC` | `C-SPC` (Cmd+Space is Spotlight; with two input sources Ctrl+Space switches them — turn that shortcut off in System Settings → Keyboard → Keyboard Shortcuts → Input Sources) |
| Org Capture / Agenda, `C-c` keys of transcripts, reviews and grep | `C-c …` | the same `C-c …` (Cmd+C copies) |

And the Mac's text editing, as in every Mac app (Linux has VS Code's Linux keys for them):

| Command | Linux | Mac |
|---|---|---|
| Cursor to Line Start / End | `<home>` / `<end>` | `s-<left>` / `s-<right>` (and Home / End) |
| Cursor to File Start / End | `C-<home>` / `C-<end>` | `s-<up>` / `s-<down>` |
| Cursor Word Left / Right | `C-<left>` / `C-<right>` | `M-<left>` / `M-<right>` (Option+← / →) |
| Delete Word Left / Delete to Line Start | `C-<backspace>` / — | `M-<backspace>` / `s-<backspace>` |

Line Start goes to the first non-blank character, and from there to the very start, as VS Code's Home. With Shift
they select. Cmd+H (hide), Cmd+M (minimise), Cmd+` (next window), Cmd+Space and Cmd+Tab stay macOS'; Cmd+C, Cmd+V,
Cmd+X and Cmd+Z are Emacs' own Mac keys (copy, paste, cut, undo). The Emacs and Vim profiles keep their own keys
(`C-a`, `M-f`, `0`, `w`, …).

**Modifier keys.** With the VS Code profile (also as the app layer under Emacs or Vim editing) drgnx sets, on a Mac:
Cmd is `s-` (super), the **left Option is Meta** (`M-`: Option+← moves by word, Option+Cmd+→ is next tab), and the
**right Option types characters** (`@ # { [ €`). Other Mac apps type characters with either Option, which on German,
French and many other layouts is how you type `@ # { [`: so on a Mac, Look and Keys asks "Left Option key (types
characters: @ # { [ on German, French, … keyboards)", offering your saved answer on Return (Meta before you have
answered). **Types characters:** the left Option types characters too, for ordinary keys, and
stays Meta for the arrows and other function keys and the mouse — Option+← / → still move by word
(`ns-alternate-modifier` is `(:ordinary none :function meta :mouse meta)`); **Meta:** the left Option is Meta, as above.
The answer is saved in `keys.eld` as `:mac-option characters` or `:mac-option meta` (edit it there too); without
interaction (`drgnx onboard --non-interactive`) nothing changes. Switching to the Emacs or Vim profile puts back what
was there. (GNU Emacs' `ns-` variables and the Mac port's `mac-` ones are both handled.)

## Layers and scopes

Every command has a scope: **editing** (moving, selecting, changing text), **app** (files, palette, settings) or
**window** (splits, docks, panels). A layer is a profile plus the scopes it keys; a command takes its keys from the
last layer that covers its scope. In "Emacs editing + VS Code app keys", Emacs keeps the editing keys and VS Code
keys the app and window commands.

Besides keying drgnx commands, a profile **claims** the keys its own editing model uses: the `emacs` layer claims
Emacs' default bindings (`C-s` isearch, `C-o` open-line, `C-k` kill-line, …), the `vim` layer claims Vim's
normal-mode keys (`C-o` jump back, `C-w` window commands, `C-v` visual block, …). When a later layer binds a claimed
key, it wins — and the clash is reported.

## Conflicts are reported, never hidden

A conflict is one of:

- **same key** — two commands want one key in one keymap (however it is written: `TAB` and `C-i` are one key);
- **claim** — a layer binds a key another layer uses natively (e.g. VS Code's `C-o` Open File over Emacs'
  open-line, or over Vim's jump back);
- **prefix** — a key turns a prefix into a command or the other way round: against Emacs' own bindings (VS Code's
  `F1` replaces Emacs' `F1` help prefix — `C-h` still works — and its `C-k` chords replace `kill-line`), against a
  loaded mode keymap, or between two drgnx keys (`C-k` for one command, `C-k C-s` for another).

The later layer wins (your `keys.eld` wins over all). Prefix conflicts over the same command in one keymap are one
line (`C-k … 12 keys over kill-line (C-k)`, then each key). Conflicts and problems are listed at the end of the key sheet
(**Keyboard Shortcuts**), written to `~/.local/state/drgnx/keys-report.eld` on every start, and summarised by
`drgnx doctor` (`key-conflicts`: info for conflicts, a warning for problems such as an unknown command in
`keys.eld`). A key in the keymap of a package that loads later is bound when it loads; what that finds (a key that
cannot be bound, a prefix it replaces) joins the list and the report then.

## keys.eld

`~/.config/drgnx/keys.eld` (or `$DRGNX_CONFIG_DIR/keys.eld`) is one plist:

```elisp
(:layers ((emacs editing) (vscode app window))     ; the stack; omit for the default (VS Code)
 :bind ((palette "C-c p")                           ; command id → one or more keys
        (line-numbers "C-c l" "<f9>")
        (open-file "C-c f" :map (org . org-mode-map))) ; a key in a mode's keymap (bound once org loads)
 :unbind (keys-sheet))                              ; no key for these
```

- Command ids are the registry ids (the palette shows the commands; `drgnx-commands-all` lists them).
- `:map` is a keymap symbol or `(FEATURE . KEYMAP)` for a keymap that exists once FEATURE is loaded.
- `:mac` gives a different key on macOS: `(palette "C-c p" :mac "s-p")`; `:mac ()` is no key there, and
  `(quit :none "reason" :mac "s-q")` a key only there.
- `:everywhere` names keys that must work in every mode: ``(toggle-panel "C-`" :everywhere "C-j")`` binds `C-j`
  as usual and also in a keymap that comes before every major and minor mode map, so lisp-interaction or Org mode
  cannot take it. Use it for one-stroke keys of the global keymap only; the minibuffer keeps its own keys.
  Switching profiles or applying keys again removes the keymap. On macOS an entry with `:mac` has no `:everywhere`
  keys there; without `:mac` they become Cmd keys like the others. A binding of the same key in a mode's keymap
  from `keys.eld` (or a higher layer) wins in that mode, and the key sheet lists the conflict.
  With the VS Code keys `C-j` toggles the panel everywhere, which also replaces Org's `C-j`, lisp-interaction's
  `eval-print-last-sexp`, ielm's and term's; to keep a mode's `C-j`, write ``(toggle-panel "C-`" "M-j")`` in
  `keys.eld`. It applies only when the profile also owns the editing keys: with "Emacs editing + VS Code app keys"
  or Vim editing, `C-j` stays the editing layer's in modes and Toggle Panel has it only where Emacs' global key was.
- A mistake never breaks startup: an unreadable file, an unknown command or an invalid key is a problem on the key
  sheet and in the doctor, and everything else still applies.
- Keyboard Profile… rewrites only `:layers` and keeps the rest of the file.
- The Keyboard Shortcuts editor writes through `drgnx-keys-edit` (`core/drgnx-keys-edit.el`): `drgnx-keys-edit-bind`,
  `-add`, `-replace`, `-unbind`, `-reset`, `-reset-all` and `-undo`. Each changes one entry of `:bind` or `:unbind` and
  keeps your comments, `:layers` and the other entries as they are; an entry keeps its `:mac` keys and `:none` reason
  (on a Mac, edits go to the `:mac` keys of an entry that has them). A symlinked `keys.eld` stays a symlink, and the
  file keeps its permissions; it is written as UTF-8. A `keys.eld` that does not read is reported and never written, and
  so is one whose `:bind` or `:unbind` is not a plain list written out (`:bind ((palette "C-c p"))`, not
  `:bind '((palette "C-c p"))`): the error says to fix it by hand and nothing is changed. A missing file is created
  with a header comment. Taking the last
  key away puts the command in `:unbind`.
- Undo goes one step back, also after a restart: `keys.eld.undo` holds the text before and after the last change made
  by the editor. If `keys.eld` has been changed since (by you, another session, or Keyboard Profile…), undo refuses and
  writes nothing. The keys apply at once after every change. Changes made inside `drgnx-keys-edit-one-step` are one
  step (the editor's Replace: the key taken from other commands and given to this one).

The Keyboard Shortcuts editor (Preferences: Keyboard Shortcuts) changes these keys for you: [shortcuts.md](shortcuts.md).

## For module authors

Register commands without keys and give their keys in each profile:

```elisp
(drgnx-command-define 'git-status :category "Git" :title "Status" :command #'magit-status)
(drgnx-keys-define 'vscode '((git-status "C-S-g")))
(drgnx-keys-define 'emacs '((git-status "C-x g")))
(drgnx-keys-define 'vim '((git-status "SPC g g")))
```

Use `:scope 'editing` or `'window` on the command when it is not an app command, and `(ID :none "reason")` when a
profile has no natural key for it. Profiles ship as data in `keys/<profile>.eld`.

## How it works

`core/drgnx-keys.el`: `drgnx-keys-resolve` is a pure function — commands, profiles, layers, `keys.eld`, platform and
Emacs' default bindings in; winning bindings, conflicts and problems out (`drgnx-platform` names the platform:
`macos` or `linux`; on macOS Emacs' defaults include its Mac port's `s-` keys, so taking `s-k` for VS Code's
Cmd+K chords is a reported prefix conflict, as `C-k` over `kill-line` is on Linux). `drgnx-keys-apply` binds the result and
remembers what each binding replaced, so the next switch restores Emacs' own bindings first (and leaves alone a
binding someone else changed since). The active keys of each command are in its `bound` slot, which every surface
reads. Tests: `test/unit/core-keys-test.el` (resolution, switching, keys.eld, surfaces) and
`test/live/drgnx-keys-test.el` (real key presses in a headless session).

## Against gryphn

`bin/drgnx keys diff --against gryphn DIR` (or `$DRGNX_GRYPHN_DIR`; any other arguments print the usage and exit 2)
compares gryphn's key sheet — every
`gryphn-command-define`, the rows of its VS Code key table, its numbered window keys, read from gryphn's `emacs/`
directory DIR and never run — with drgnx's VS Code profile, with every module and gryphn's board, runs, agents,
search, LLM and IDE files as an external module ([modules.md](modules.md)). Every gryphn command is in drgnx with
gryphn's key among its keys — `C-s` saves, `C-w` closes the tab, `C-d` adds the next occurrence, `M-<up>` moves the
line, `C-.` is Quick Fix, `M-j` toggles the panel, `C-S-b` focuses the Buffers panel, `<f11>` is zen mode, next to
drgnx's own keys — or the line is explained. The Emacs keys gryphn leaves alone (`C-a`, `C-e`, `C-y`, `M-f`, `C-SPC`,
`M-x`, …) must stay Emacs' in drgnx too (outside panels with their own keys):

| gryphn | Why it is not in drgnx, or differs |
|---|---|
| `C-k` (kill line) | starts VS Code's chords in drgnx (`C-k C-r` key sheet, `C-k z` zen, `C-k s` save all, …); `C-S-k` deletes the line |
| `<f1>` key sheet | `<f1>` is the palette, as in VS Code; the key sheet is `C-k C-r` (VS Code's Keyboard Shortcuts Reference) |
| Window 4 … 9 (`M-4` … `M-9`) | drgnx numbers editor groups (`M-1` … `M-3`, `C-1` … `C-3`), not every window; `M-o` picks any window |

| gryphn | Why it is not in drgnx |
|---|---|
| Workspaces (next, previous, switch, save, restore, close) | deferred; several windows and editor groups cover their use, and the layout survives restarts |
| Toggle Minimap | minimap is not installed; a minimap module is deferred |
| Dashboard | a start dashboard competes with the restored workbench; deferred |
| Trust / Reload mise | gryphn's mise file needs its bundle loader; a drgnx mise module is planned with the editor amenities (M11) |

Unexplained lines make the command exit non-zero (a test runs it when `DRGNX_GRYPHN_DIR` names a gryphn checkout).
