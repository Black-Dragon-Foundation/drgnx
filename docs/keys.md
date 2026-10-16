# Keys

drgnx speaks **VS Code, Emacs and Vim** keys, and combinations of them: Vim or Emacs for editing with VS Code's
shortcuts for everything else. Commands are registered once, without keys; **key profiles** give them keys,
**layers** stack the profiles, and your **`keys.eld`** wins over everything. Every surface — menus, the command
palette, the key sheet, which-key, the markdown cheat sheet — shows the keys that are active right now.

## Choosing a profile

**Preferences: Keyboard Profile…** (in the command palette and the Options menu) switches at once, without a
restart, and remembers the choice in `keys.eld`:

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
| Keyboard Shortcuts (key sheet) | `C-k C-s` | `C-h C-k` | `SPC ?` |
| Keyboard Profile… | `C-k C-p` | — | `SPC h k` |
| Open File… | `C-o` | `C-x C-f` | `SPC f f` |
| Save | `C-s` | `C-x C-s` | `SPC f s` |
| Toggle Line Numbers | — | — | `SPC u l` |
| Module Report | — | — | `SPC h m` |
| Toggle Sidebar | `C-b` | `<f8>` | `SPC e` |
| Focus Explorer / Buffers | `C-S-e` / `C-k e` | `C-x M-e` / `C-x C-b` | `SPC E` / `SPC ,` |
| Toggle Panel / Right Dock | ``C-` `` / `C-M-b` | — / — | `SPC j` / `SPC R` |
| Close Tab / Next / Previous | `C-<f4>` / `C-<next>` / `C-<prior>` | — / Emacs' `C-x <right>` / `C-x <left>` | `SPC b d` / `SPC b n` / `SPC b p` |
| Split Editor Right / Down | ``C-\`` / ``C-k C-\`` | Emacs' `C-x 3` / `C-x 2` | `SPC w v` / `SPC w s` |
| Focus Group 1–3 / Move Editor to Next Group | `C-1`–`C-3` / `C-M-<right>` | `C-x o` / — | `SPC 1`–`SPC 3` / `SPC w m` |
| Open Editor in New Window | `C-k o` | Emacs' `C-x 5 2` | `SPC w o` |
| Fold / Unfold | `C-{` / `C-}` | — | `SPC z c` / `SPC z o` |
| Expand / Shrink Selection | `M-S-<right>` / `M-S-<left>` | — | `SPC v` / `SPC V` |
| Zen Mode | `C-k z` | — | `SPC u z` |
| Go to Line | Emacs' `M-g g` | `M-g g` | `SPC g l` |
| Go to Definition / References / Rename Symbol / Hover | `F12` / `S-F12` / `F2` / `C-S-SPC` | Emacs' `M-.` / `M-?` / — / `C-h .` | `SPC c d` / `SPC c r` / `SPC c R` / `SPC c h` |
| Source Control / Blame | `C-S-g` / — | Emacs' `C-x v d` / `C-x v g` | `SPC g s` / `SPC g b` |
| New Terminal | ``C-S-` `` | — | `SPC t n` |
| Quick Open / Search in Project / Go to Symbol | `C-p` / `C-S-f` / `C-S-o` | Emacs' `C-x p f` / `C-x p g` / `M-g i` | `SPC f p` / `SPC s p` / `SPC s s` |
| Org Capture / Agenda | `C-c c` / `C-c a` | `C-c c` / `C-c a` | `SPC n c` / `SPC n a` |

The Explorer's and the Buffers panel's own keys (rows, expand, open, close) are in [workbench.md](workbench.md).
A command that lives in a mode's keymap (like those) keeps its keymap in every profile: an entry's `:map` wins,
else the command's own, else the profile's.

"—" means the profile has no key for it; every command is always in the palette. Vim's keys are leader keys in
evil's normal state. On **macOS** the VS Code profile uses Cmd: `C-` becomes `s-` (`s-o`, `s-k s-s`, `s-S-p`).

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

- **same key** — two commands want one key in one keymap;
- **claim** — a layer binds a key another layer uses natively (e.g. VS Code's `C-o` Open File over Emacs'
  open-line, or over Vim's jump back);
- **prefix** — a key turns a prefix into a command or the other way round: against Emacs' own bindings (VS Code's
  `F1` replaces Emacs' `F1` help prefix — `C-h` still works — and its `C-k` chords replace `kill-line`), against a
  loaded mode keymap, or between two drgnx keys (`C-k` for one command, `C-k C-s` for another).

The later layer wins (your `keys.eld` wins over all). Conflicts and problems are listed at the end of the key sheet
(**Keyboard Shortcuts**), written to `~/.local/state/drgnx/keys-report.eld` on every start, and summarised by
`drgnx doctor` (`key-conflicts`: info for conflicts, a warning for problems such as an unknown command in
`keys.eld`).

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
- `:mac` gives a different key on macOS: `(palette "C-c p" :mac "s-p")`.
- A mistake never breaks startup: an unreadable file, an unknown command or an invalid key is a problem on the key
  sheet and in the doctor, and everything else still applies.
- Keyboard Profile… rewrites only `:layers` and keeps the rest of the file.

A graphical Keyboard Shortcuts editor (search, press-to-rebind, writes `keys.eld`) comes in M4.

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
Emacs' default bindings in; winning bindings, conflicts and problems out. `drgnx-keys-apply` binds the result and
remembers what each binding replaced, so the next switch restores Emacs' own bindings first (and leaves alone a
binding someone else changed since). The active keys of each command are in its `bound` slot, which every surface
reads. Tests: `test/unit/core-keys-test.el` (resolution, switching, keys.eld, surfaces) and
`test/live/drgnx-keys-test.el` (real key presses in a headless session).
