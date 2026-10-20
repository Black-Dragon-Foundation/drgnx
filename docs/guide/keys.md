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
| Vim | `vim` for everything; choosing it turns the evil module on (see Vim keys) |
| Emacs editing + VS Code app keys | `emacs` editing, then `vscode` app and window |
| Vim editing + VS Code app keys | `vscode` app and window, then `vim` editing |

The last preset puts Vim **last**: it is the later layer for editing, so Vim keeps its Ctrl keys (`C-o` jump back,
`C-w`, `C-b`, `C-p`, `C-n`, `C-t` …) in normal and visual state, as VSCodeVim does, while VS Code's keys work in
insert state, in panels and, on a Mac, as Cmd keys. `keys.eld` flips any single key. The `SPC` leader keys stay in
this stack for every command, next to VS Code's own keys (see Leader keys below).

Onboarding's Look and Keys step asks which one you want (VS Code preselected; [onboarding.md](onboarding.md)).

**A Vim stack needs its engine.** Vim keys run on evil, which the `editor/evil` module provides; it is off, and
nothing of it installed, until you choose a Vim stack. Keyboard Profile… switches to a Vim stack only once evil is
loaded, so there is never a session with Vim keys and no Vim editing:

- evil installed (by an earlier `drgnx sync`): `editor/evil` is turned on and runs at once, then the keys switch.
- evil not installed: it asks once, naming what it installs ("Vim keys need evil, evil-collection (module
  editor/evil), not installed yet. Run drgnx sync now (it installs every package your modules are missing)?"). Yes
  turns the module on and runs `drgnx sync` as a job (its progress in the echo area), then starts evil and switches.
  No changes nothing. A sync or start that fails, or `C-g` during the sync, keeps your keys and turns the module back
  off; a failure says why, with the log. In `drgnx safe` (no modules run) the keys stay as they are.
- Called from code instead of as a command (`emacsclient -e`, a daemon, `drgnx onboard --non-interactive`) when
  evil is not installed, nothing is asked: `editor/evil` is turned on and the stack is written to `keys.eld` as
  `:pending-layers`, your keys stay as they are, and the message says "Vim needs drgnx sync". After `drgnx sync`
  the next start switches to it (and takes `:pending-layers` out). With evil installed it switches at once.
- A Vim stack in `keys.eld` without evil (uninstalled, say) still starts: the palette keeps `C-S-p` and `F1`, Leader
  Menu `M-SPC`; `SPC` types a space, and `editor/evil` waits for its packages (Preferences: Modules).
- Choosing VS Code or Emacs again turns `editor/evil` off from the next start, and drops a pending Vim stack.

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
| Close Tab / Next / Previous | `C-<f4>` / `C-<next>` / `C-<prior>` | — / Emacs' `C-x <right>` / `C-x <left>` | `SPC b d` / `SPC b n` or `g t` / `SPC b p` or `g T` |
| Split Editor Right / Down | ``C-\`` / ``C-k C-\`` | Emacs' `C-x 3` / `C-x 2` | `SPC w v` / `SPC w s` |
| Focus Group 1–3 / Move Editor to Next Group | `C-1`–`C-3` / `C-M-<right>` | `C-x o` / — | `SPC 1`–`SPC 3` / `SPC w m` |
| Open Editor in New Window | `C-k o` | Emacs' `C-x 5 2` | `SPC w o` |
| Fold / Unfold | `C-{` / `C-}` | — | `SPC z c` / `SPC z o` |
| Expand / Shrink Selection | `M-S-<right>` / `M-S-<left>` | — | `SPC v` / `SPC V` |
| Zen Mode | `C-k z` | — | `SPC u z` |
| Next Layout / Layout… | `C-k C-l` / — | — / — | `SPC l n` / `SPC l l` |
| Go to Line | Emacs' `M-g g` | `M-g g` | `SPC g l` |
| Go to Definition / References / Rename Symbol / Hover | `F12` / `S-F12` / `F2` / `C-S-SPC` | Emacs' `M-.` / `M-?` / palette / `C-h .` | `SPC c d` or `g d` / `SPC c r` or `g r` / `SPC c R` / `SPC c h` or `K` |
| Next / Previous Problem | `F8` / `S-F8` | palette / palette | `] d` / `[ d` |
| Focus Left / Right / Above / Below | palette | palette | `C-w h` / `C-w l` / `C-w k` / `C-w j` |
| Source Control / Blame | `C-S-g` / — | Emacs' `C-x v d` / `C-x v g` | `SPC g s` / `SPC g b` |
| New Terminal | ``C-S-` `` | — | `SPC t n` |
| Quick Open / Search in Project / Go to Symbol | `C-p` / palette / `C-S-o` | Emacs' `C-x p f` / `C-x p g` / `M-g i` | `SPC f p` / `SPC s p` / `SPC s s` |
| Org Capture / Agenda | `C-c c` / `C-c a` | `C-c c` / `C-c a` | `SPC n c` / `SPC n a` |

The Explorer's and the Buffers panel's own keys (rows, expand, open, close) are in [workbench.md](workbench.md).
A command that lives in a mode's keymap (like those) keeps its keymap in every profile: an entry's `:map` wins,
else the command's own, else the profile's.

"—" means the profile has no key for it; every command is always in the palette. Vim's keys are leader keys in
drgnx's leader map (`SPC …`), which the Vim engine plugs into its normal, visual and motion states and the panels. On **macOS** the VS Code profile uses Cmd (`s-`) as VS Code does there — see below.

## Vim keys

Choosing a Vim key stack turns the `editor/evil` module on (it is off until then; nothing is installed or loaded for
VS Code or Emacs keys). It runs [evil](https://github.com/emacs-evil/evil) as the editing engine; the leader keys, the
state indicator and the panels' keys belong to drgnx's own engine-neutral modal core, so another engine can plug in
later (Meow is the candidate):

- **States.** Editors start in *normal* state; `i`, `a`, `o` … enter *insert*, `v`, `V`, `C-v` enter *visual*
  (characters, lines, a block), `R` *replace*, `C-z` *Emacs* state (Emacs' own keys, until `C-z` again). `Esc` goes
  back to normal; `C-g` works in every state.
- **Indicator.** The mode line starts with the state — ` NORMAL `, ` INSERT `, ` VISUAL `, ` V-LINE `, ` V-BLOCK `,
  ` REPLACE `, ` EMACS ` — in colours the theme gives (faces `drgnx-modal-normal`, `-insert`, `-visual`, `-emacs`).
- **Cursor.** A box in normal state, a bar in insert and Emacs state, a hollow box in visual, an underline in replace.
  Only the shape: the colour is the theme's `cursor` face. Panels (the Explorer, Buffers, lists, tables, transcripts)
  keep the cursor they set — mostly none. In a terminal, Emacs 31.1 draws the shape too: while Vim editing runs
  drgnx sets `xterm-update-cursor` to `type` (the shape only, never the colour) and sets up a terminal that was
  already running; it works in Xterm-compatible terminals, and the default shape returns when Vim editing stops.
- **Panels are in Emacs state.** They keep their own keys and get `SPC` leader and `j` / `k` for rows; forms (the
  Search/Replace view) take typed text and have no Vim keys.
- **Inputs are in insert state.** Shells (eshell, comint, term, eat) and commit messages start where you type.
  The minibuffer is never modal.
- **Leader Menu.** `M-SPC` from any state, and `SPC` in normal state, show the leader's keys in a which-key popup.
- **Toggle Modal Editing** (`SPC u m`, the palette) turns Vim editing off and on for this session; the key stack
  stays as it is. It stays off however often the keys are applied again, until you toggle it on, choose another
  key stack, or restart. With it off, `SPC` types a space again; `M-SPC u m` is the way back.
- **Third-party modes** (Magit and its commit messages, Dired, xref, compilation, Help, Info, vundo, Eglot, Ediff)
  get Vim keys from [evil-collection](https://github.com/emacs-evil/evil-collection), each when the mode's library
  loads, not before, so starting Vim editing stays cheap. The list is `drgnx-evil-collection-modes`; drgnx's own modes are never in it.
  `:flags ((editor/evil no-collection))` in `modules.eld` leaves them all out (they keep their own keys).
- **Insert-state keys.** In the pure Vim stack insert state has Vim's keys: `C-w` deletes a word, `C-r` pastes a
  register, `C-v` quotes, `C-a`, `C-e`, `C-y`, `C-t`, `C-d`, `C-n`, `C-p`, `C-o` … When another profile's layer is
  mixed in (VS Code's app and window keys with Vim's editing, say) those keys stay Emacs' own, so the other
  profile's keys keep working while you type; switching back to the pure stack restores them. Replace state (`R`)
  keeps Vim's keys in a mixed stack. A key you rebound in `evil-insert-state-map` is never touched.
- **Unimpaired keys.** evil-collection adds Vim unimpaired's bracket pairs in normal state: `[b` `]b` previous / next
  buffer, `[e` `]e` move the line (or selection) up / down, `[q` `]q` and `[l` `]l` previous / next error (`[Q` `]Q`
  first / last), `[n` `]n` previous / next conflict marker, `[p` `]p` paste above / below, `[ SPC` `] SPC` insert a
  blank line above / below, and in visual state `[u` `]u` URL encode / decode and `[6` `]6` base64 encode / decode.
  They are on while Vim editing runs and off when it stops. Setting `evil-collection-want-unimpaired-p` to nil in
  `config.el` turns them off for good.
- **Multiple cursors** (the `multiple-cursors` package) run in Emacs state, because Vim's keys would act on one cursor
  at a time; when they end the buffer returns to the state it was in (normal when it was a visual one).
- **Your settings win.** The module sets evil's defaults (`evil-undo-system` `undo-redo`, `evil-want-C-u-scroll`,
  `evil-search-module` `evil-search`, no evil in the minibuffer) before your `config.el`, so your `setopt` is last. A
  cursor variable you set (`evil-normal-state-cursor` …) is kept.
- **AI ghost text** shows in insert state (and Emacs state, where keys type too); one `Esc` drops a suggestion and
  leaves insert state, `Tab` takes it, and Edit with AI (`SPC a e`) rewrites the visual selection ([ai.md](ai.md)).
- **Caps Lock as Esc** is the operating system's job (a keyboard setting), not drgnx's.

### Leader keys

The Vim profile's commands are on the leader keys `SPC …` (and `C-w …` for windows). They live in drgnx's own
`drgnx-modal-leader-map`, not in evil's maps, so they are known to the key sheet, the palette and the conflict report
before evil is installed, and the engine only has to plug the map into its states. `C-w` is a leader prefix like `SPC`:
a `keys.eld` key starting with `C-w ` goes in the leader map, next to evil's own `C-w` window keys (`C-w v`, `C-w s`,
`C-w c` run drgnx's commands, see [Ex commands and Vim habits](#ex-commands-and-vim-habits); the other `C-w` keys stay
evil's). The palette is reachable in every state and panel: `SPC SPC` from normal, visual and motion state and
panels, `C-S-p` and `F1` (Cmd+Shift+P and `F1` on a Mac) everywhere, so insert state is never without a way in. As in
the VS Code profile, that `F1` replaces Emacs' `F1` help prefix (`C-h` still works). The leader keys of the shipped
profile:

| Key | Command |
|---|---|
| `C-w h` | Focus Left |
| `C-w j` | Focus Below |
| `C-w k` | Focus Above |
| `C-w l` | Focus Right |
| `SPC ,` | Focus Buffers |
| `SPC /` | View: Search |
| `SPC 1` | Focus First Editor Group |
| `SPC 2` | Focus Second Editor Group |
| `SPC 3` | Focus Third Editor Group |
| `SPC ?` | Keyboard Shortcuts |
| `SPC E` | Focus Explorer |
| `SPC R` | Toggle Right Dock |
| `SPC SPC` | Command Palette |
| `SPC V` | Shrink Selection |
| `SPC a e` | Edit with AI… |
| `SPC a m` | LLM Menu |
| `SPC a q` | Ask the Codebase… |
| `SPC a s` | Send to LLM |
| `SPC a v` | Show Agents |
| `SPC a w` | Show Work |
| `SPC b A` | Close All Editors |
| `SPC b a` | Buffers: Show All Windows |
| `SPC b b` | Recent Buffers |
| `SPC b d` | Close Tab |
| `SPC b i` | Full Buffer Manager |
| `SPC b n` | Next Tab |
| `SPC b p` | Previous Tab |
| `SPC b u` | Close Saved Editors |
| `SPC c R` | Rename Symbol |
| `SPC c a` | Quick Fix |
| `SPC c c` | Toggle Comment |
| `SPC c d` | Go to Definition |
| `SPC c f` | Format Document |
| `SPC c h` | Show Hover |
| `SPC c r` | Find References |
| `SPC c x` | Problems |
| `SPC c ~` | Change Case: Cycle |
| `SPC e` | Toggle Sidebar |
| `SPC f S` | Save All |
| `SPC f f` | Open File… |
| `SPC f n` | New Untitled |
| `SPC f o` | Open Folder… |
| `SPC f p` | Quick Open |
| `SPC f r` | Reopen Closed Tab |
| `SPC f s` | Save |
| `SPC f w` | Save As… |
| `SPC g B` | Diff: Branch vs Base |
| `SPC g R` | Review Branch |
| `SPC g S` | Stage Change |
| `SPC g b` | Blame |
| `SPC g c` | Blame: Show Commit of Line |
| `SPC g d` | Diff with File |
| `SPC g h` | Show Change |
| `SPC g i` | Diff: Staged |
| `SPC g l` | Go to Line… |
| `SPC g p` | Pull Requests |
| `SPC g r` | Revert Change |
| `SPC g s` | Source Control |
| `SPC g w` | Diff: Working Tree |
| `SPC h k` | Keyboard Profile… |
| `SPC h m` | Module Report |
| `SPC h s` | Keyboard Shortcuts |
| `SPC h t` | Color Theme |
| `SPC j` | Toggle Panel |
| `SPC l l` | Layout… |
| `SPC l n` | Next Layout |
| `SPC m` | Menu for This Mode |
| `SPC n a` | Agenda Menu |
| `SPC n c` | Capture |
| `SPC o` | Focus Outline |
| `SPC s i` | Semantic Search |
| `SPC s j` | Jump to Text |
| `SPC s p` | Search in Project |
| `SPC s r` | Replace in Files |
| `SPC s s` | Go to Symbol |
| `SPC s y` | Go to Symbol in Project |
| `SPC t n` | New Terminal |
| `SPC u k` | Show Keys As I Type |
| `SPC u l` | Toggle Line Numbers |
| `SPC u m` | Toggle Modal Editing |
| `SPC u p` | Next Panel Tab |
| `SPC u t` | Undo Tree… |
| `SPC u z` | Zen Mode |
| `SPC v` | Expand Selection |
| `SPC w c` | Close Editor Group |
| `SPC w g` | Move Editor Group into New Window |
| `SPC w m` | Move Editor into Next Group |
| `SPC w n` | Move Editor into New Window |
| `SPC w o` | Open Editor in New Window |
| `SPC w s` | Split Editor Down |
| `SPC w v` | Split Editor Right |
| `SPC w w` | Pick Window |
| `SPC z c` | Fold |
| `SPC z o` | Unfold |

**Mixed stacks.** In "Vim editing + VS Code app keys" the `vim` layer covers editing only, but its leader keys (and
its other keys that exist only in modal maps, like `j` / `k` for rows in panels) are kept for every command, next to
the key the command's own layer gives it: Open File is `C-o` and `SPC f f`. Nothing else of the Vim layer is added: its
keys in the Explorer's or another view's own keymap stay out, and the layer that covers a command keeps its keys.
Leader keys cannot clash with VS Code's because they exist only in the leader map.

**Your own leader keys.** A `keys.eld` key that starts with the leader (`(save-file "SPC x")`) goes in the leader map
in a Vim or mixed stack, never the global keymap (else `SPC` would stop typing a space in insert state); in a VS Code or
Emacs stack it is an ordinary global key. Any other `keys.eld` key keeps the keymap it had.

### Ex commands and Vim habits

While Vim editing runs, the ex commands and Vim's window keys that touch files, windows and groups run drgnx's
commands, so the workbench keeps its editor groups, tabs and layout (the key tip shows the command's own key):

| Vim | Runs |
|---|---|
| `:w` / `:w FILE` | Save / Save As… `FILE` (`%` and `#` as in Vim; `:w!`, `:w !cmd`, `:w >> FILE` and a range are evil's own) |
| `:wa` | Save All (`:wa!` is evil's own) |
| `:e FILE` | Open File… `FILE` (`:e` alone and `:e!` re-read the file, evil's own) |
| `:sp [FILE]`, `C-w s` | Split Editor Down (`FILE` opens in the new group) |
| `:vs [FILE]`, `C-w v` | Split Editor Right (`FILE` opens in the new group) |
| `C-w c`, `:clo` | Close Editor Group |
| `:q`, `ZQ` | Close Tab when the group has other tabs, else Close Editor Group when there is another group, else Close Window |
| `:wq`, `:x`, `ZZ` | Save when the buffer changed, then what `:q` does |
| `:wq`, `:x`, `ZZ` in a Magit commit or rebase message | Finish the edit: git goes on (`with-editor-finish`) |
| `:q`, `ZQ` in a Magit commit or rebase message | Cancel the edit (`with-editor-cancel`) |
| `:wq`, `:x`, `ZZ` in an `emacsclient` buffer | Save when the buffer changed, then Done (`C-x #`): the client returns |
| `:q`, `ZQ` / `:q!` in an `emacsclient` buffer | Done (it asks before saving changes) / Done without saving |
| `:qa`, `:cq` | Close Window |
| `:wqa`, `:xa` | Save All, then Close Window |
| `C-w h` `j` `k` `l` | Focus Left / Below / Above / Right (editor groups, the sidebar, the panel and the right dock: `C-w l` reaches Work and Agents, `C-w h` comes back) |
| `g d`, `g r`, `K` | Go to Definition, Find References, Show Hover |
| `g t`, `g T` | Next Tab, Previous Tab |
| `] d`, `[ d` | Next Problem, Previous Problem (the next error or warning in this file) |

`:q` never quits drgnx's Emacs by itself. In the last tab of the last group it is Close Window, which closes the
window and keeps a background drgnx running (`drgnx-keep-running`), and otherwise asks, after offering to save, before
quitting; `:cq` and `:wqa` never end Emacs either. In the sidebar or the panel (a window that is not an editor group)
`:q` and `C-w c` go back to the editor you used last and never close a group. The ex commands `:w`, `:wa` and `:e` are the
data `drgnx-evil-ex-routes`; evil's `:q`, `:wq`, `:x`, `:qa`, `:wqa`, `:cq`, `:sp`, `:vs` and `C-w s/v/c` are advised while the
engine runs (`drgnx-evil--advice-pairs`), and evil's own again when Vim editing stops (a command you defined meanwhile
is kept). With the `core/workbench` module off, all of them are evil's own. Vim's other ex commands are untouched, and so
are evil's other window keys and commands (`C-w o` `x` `r` `H` `J` `K` `L`, `:new`, `:bd`): they act on raw Emacs
windows, not on editor groups, and can leave the workbench's arrangement (`C-w h` `j` `k` `l` `s` `v` `c` are drgnx's, above). In a
VS Code or Emacs stack Focus Left/Right/Above/Below and the problem commands have no keys (VS Code's `F8` /
`Shift+F8` go to the next / previous problem); they are in the palette.

In a terminal window drgnx has the mouse, so the terminal's own selection is **Shift+drag** in most terminals
(Option+drag in iTerm2; other terminals may use their own modifier); see [terminal.md](terminal.md#mouse).

The same keys work in a terminal window when the terminal can send them: `C-S-p`, `` C-` ``, `C-.` and the other
chords need modifyOtherKeys (xterm, WezTerm; tmux with `extended-keys on`) or the kitty keyboard
protocol (kitty, foot, Alacritty, Ghostty). drgnx turns on one of them, modifyOtherKeys where the terminal has it, because
`C-g` then stops everything; no profile has a second, terminal-only set of keys. In a terminal that has neither, such as GNOME Terminal or Ptyxis, `C-S-p`
arrives as `C-p`: open the palette with **F1** instead (VS Code keys; `M-x` in every profile). drgnx writes down
which of your keys that terminal cannot send. See [terminal.md](terminal.md#keys); the page opens with the three ways to run
drgnx (a graphical window, a capable terminal, a legacy one with Alt+Shift and F6).

## Copy, cut and paste

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| Copy / Cut / Paste (in a file) | `C-c` / `C-x` / `C-v` | `M-w` / `C-w` / `C-y` | `y` / `d` in visual state, `p` |

In the VS Code profile `C-c` and `C-x` copy and cut **only while text is selected** (as Emacs's CUA mode does); with
no selection they are Emacs's prefixes, so `C-x C-s`, `C-c C-c` in a mode and the rest work as always. A selection
the mark leaves empty (`C-SPC` and no move) counts as none. `C-v` always pastes, replacing the selection if there is
one, in one undo step; it no longer scrolls (PageDown does). In a read-only buffer Cut copies, and Paste says the
buffer is read-only. The Explorer keeps its own `C-c` / `C-x` / `C-v` for files (see [workbench.md](workbench.md)):
they are in its own keymap, which beats the global `C-v`, and the Explorer never selects text, so the selection-only
`C-c` / `C-x` stay out of its way. On a Mac they are `s-c`, `s-x` and `s-v`.

The Emacs and Vim profiles keep their own keys, and so does "Emacs editing + VS Code app keys": only the VS Code
editing layer takes `C-c`, `C-x` and `C-v`.

**Prefix habits with a selection.** `C-c` and `C-x` are also the start of Emacs's own keys (`C-x b`, `C-x C-s`, a
mode's `C-c C-c`, the agent and comint buffers' `C-c C-c`). With a selection they wait `drgnx-editing-prefix-delay`
(0.3 seconds; `M-x customize-variable`; `nil` acts at once) for the next key, as CUA mode does: a key that arrives in
time drops the selection and goes on as the prefix, so nothing is cut or lost; none, and `C-c` copies and `C-x`
cuts. So `C-x C-s`, `C-x b` and `C-c C-c` work with a selection when typed at your normal speed, and a lone `C-c`
or `C-x` acts after a short pause; `C-g` in that moment just drops the selection. A keyboard macro that recorded a
pause and then a cut replays without the pause, so the key after it becomes a prefix. Cmd+C and Cmd+X on a Mac are no prefix and act at once.

**The face's commands** ([face.md](face.md)) are in the palette in every profile; few have keys. **Show Quick
Help** is `C-k C-i` (VS Code) and `SPC k` (Vim); the Emacs profile keeps Emacs' `C-h .` (local help). **Close
Pane** and **Close Quick Help** are `Esc` and `q` in all three profiles, only where they close something (a help or
side pane, a popup, the quick help card; a buffer you type into keeps both keys). `F10` runs **Open the Menu** (a
remap of Emacs' `menu-bar-open`: the menu as text while the menu bar is hidden). **Preferences: Look and Layout
Settings…**, **Toggle Menu Bar**, **Toggle Status Bar**, **Toggle Quick Help on Hover**, **Show Start Page** and
**Change Language Mode** (also a click on the language in the status bar) have no key.

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
they select. Cmd+H (hide), Cmd+M (minimise), Cmd+` (next window), Cmd+Space and Cmd+Tab stay macOS'; Cmd+Z is Emacs'
own Mac key (undo), and in the VS Code profile Cmd+C and Cmd+X copy and cut a selection and Cmd+V pastes (see
[Copy, cut and paste](#copy-cut-and-paste)). The Emacs and Vim profiles keep their own keys
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
keys the app and window commands. The one exception is a modal profile (Vim): its keys that exist only in its modal
maps, the `SPC` leader keys above all, are kept next to the other layer's key for a command outside its scopes.

Besides keying drgnx commands, a profile **claims** the keys its own editing model uses: the `emacs` layer claims
Emacs' default bindings (`C-s` isearch, `C-o` open-line, `C-k` kill-line, …), the `vim` layer claims Vim's own keys
(`C-o` jump back, `C-w` window commands, `C-v` visual block, …). When a later layer binds a claimed key, it wins —
and the clash is reported.

### Vim's claims are per state

Vim's keys exist only in some states: `C-o` is jump back in normal, visual and motion state, but in insert state
(of a mixed stack) and in panels nothing of Vim's is on it. So a key another layer binds where Vim has one is
**kept**, and the higher layer wins **in those states only**:

- In "Vim editing + VS Code app keys" (Vim is the later layer) VS Code's `C-o` Open File, `C-w` Close Tab, `C-b`,
  `C-p`, `C-n`, `C-t` … stay bound: Vim's key wins in normal, visual and motion state, VS Code's works in insert state
  and in panels. Vim's insert-state keys are off in a mixed stack, so there are no insert-state claims there.
- The leader and panel maps claim too: VS Code's `C-w` Close Tab meets the leader's `C-w …` keys in normal, visual and
  motion state and in panels; a panel's own `SPC` (the Explorer's Open, Keep Focus) meets the `SPC` leader in panels,
  where the leader always wins.
- Where evil's keys come from: once evil has loaded, drgnx reads them from a copy of evil's own state maps
  (`evil-normal-state-map`, `evil-visual-state-map`, `evil-motion-state-map`, `evil-insert-state-map`), taken
  before drgnx binds anything there — every key evil binds counts (`C-^`, `C-6`, …), not only a list. Before
  that (evil not installed yet) `keys/vim.eld`'s `:claims` stand in: `(editing "C-o" "Jump Back" (normal visual
  motion insert))`, each with the states evil binds it in. A claim without states holds in every state.
- A key that **beats** Vim's — a `keys.eld` key, or a layer above Vim — is bound in evil's map too, so it works in
  those states (`(:bind ((go-quick-open "C-p")))` in the Vim stack: `C-p` is Quick Open in normal and insert
  state, not evil's paste-pop). The next switch of the key stack puts evil's own key back. Only global keys beat
  evil's state maps this way (a key of a mode's keymap stays under evil's in normal state). Keys you bind yourself
  in evil's state maps, in `config.el`, are left alone: the sheet says `C-p my-command (your own binding, kept)
  over Quick Open (user)`.

The key sheet says who wins where: `C-o Jump Back (vim; normal, visual, motion state) over Open File… (vscode)
[claim]; Open File… in insert state and panels`.

## In the terminal

A terminal (New Terminal, `tools/terminal-eat`) is a program that wants most keys itself, so the active profile
decides which keys it gets, the way VS Code's terminal does:

- **App and window keys reach drgnx** when they are not control or Alt characters: the palette, panel and terminal
  keys of the VS Code profile (`Ctrl+Shift+P`, `F1`, ``Ctrl+` ``), function keys, `C-c` keys, whatever the profile uses.
- **Editing keys go to the shell**: a control or Alt key (`C-a`, `C-e`, `C-w`, `C-d`, `M-f`) means what readline or zle
  make of it, even when the profile gives it to a drgnx command outside the terminal (VS Code's `C-w` Close Tab, `C-s`
  Save, `C-n` New Untitled). Eat's own reserved keys (`C-x`, `C-c`, `C-g`, `C-h`, `C-u`, `C-q`, `M-x`, `M-:`, `M-!`,
  `M-&`) stay with Emacs.
- **VS Code's own exceptions, in the VS Code profile**: VS Code's terminal skips the shell for some control keys
  (`terminal.integrated.commandsToSkipShell`), so the VS Code profile gets them in the terminal too: `C-p` Quick Open
  (Go to File), `C-b` Toggle Sidebar, every `C-k` chord (Keyboard Shortcuts, Open Folder, ...), and `C-f` Find in File,
  which searches the text of the terminal. This is the option `drgnx-terminal-skip-shell-keys` (a list of first keys,
  default `("C-p" "C-b" "C-k" "C-f")`; drop a key from it and that key reaches the shell again). It only applies
  to keys the active profile binds: in the Emacs and Vim profiles nothing is bound to these keys, so `C-p` (previous
  history entry), `C-b`, `C-k` (kill to end of line) and `C-f` all reach the shell. In the VS Code profile `C-k` is a
  chord prefix, so it does not kill to the end of the line in a terminal.

On a Mac the profile's keys are `Cmd` keys, which no shell uses, so those reach drgnx; the Alt aliases the VS Code
profile also has there (such as `M-j` for the panel) are Alt keys and go to the shell.

The split is computed from the active stack of the registry, so it follows a profile switch at once. The key sheet
(**Keyboard Shortcuts**) ends with an **In the terminal** section: one line "Reach drgnx: …" and one line for every
key that goes to the shell instead, such as "C-w goes to the shell (Close Tab: outside the terminal, or the
palette)". Several chords of one key are shown once ("C-k chords").

**Copy and paste**: `Ctrl+Shift+C` copies the selected text of the terminal (nothing selected, nothing happens) and
`Ctrl+Shift+V` pastes, on a Mac `Cmd+C` / `Cmd+V`. They are the commands *Terminal: Copy* and *Terminal: Paste* and
work in terminal buffers only. The Emacs profile leaves eat's own keys: `C-y` pastes, and copying is `C-c C-e`
(Emacs mode) then `M-w`.

## Conflicts are reported, never hidden

A conflict is one of:

- **same key** — two commands want one key in one keymap (however it is written: `TAB` and `C-i` are one key);
- **claim** — a layer binds a key another layer uses natively (e.g. VS Code's `C-o` Open File over Emacs'
  open-line; with Vim, per state: see "Vim's claims are per state" above);
- **prefix** — a key turns a prefix into a command or the other way round: against Emacs' own bindings (VS Code's
  `F1` replaces Emacs' `F1` help prefix — `C-h` still works — and its `C-k` chords replace `kill-line`), against a
  loaded mode keymap, or between two drgnx keys (`C-k` for one command, `C-k C-s` for another).

The later layer wins (your `keys.eld` wins over all). Prefix conflicts over the same command in one keymap are one
line (`C-k … 12 keys over kill-line (C-k)`, then each key). Conflicts and problems are listed at the end of the key sheet
(**Keyboard Shortcuts**), written to `~/.local/state/drgnx/keys-report.eld` on every start, and summarised by
`drgnx doctor` (`key-conflicts`: info for conflicts, a warning for problems such as an unknown command in
`keys.eld`). A key in the keymap of a package that loads later is bound when it loads; what that finds (a key that
cannot be bound, a prefix it replaces) joins the list and the report then.

With Vim keys the sheet shows leader keys plain (`SPC f f`) and a key that works in one state with it (`g d (normal state)`); the Leader Menu on `M-SPC` over Emacs' `cycle-spacing` is listed with the conflicts; which-key labels the leader keys and their prefixes (`SPC f` is `+File`); `drgnx doctor` (`modal`) warns when the engine is missing.

## keys.eld

`~/.config/drgnx/keys.eld` (in your config folder: [where drgnx keeps its files](files.md#where-drgnx-keeps-its-files)) is one plist:

```elisp
(:layers ((emacs editing) (vscode app window))     ; the stack; omit for the default (VS Code)
 :bind ((palette "C-c p")                           ; command id → one or more keys
        (line-numbers "C-c l" "<f9>")
        (open-file "C-c f" :map (org . org-mode-map))) ; a key in a mode's keymap (bound once org loads)
 :unbind (keys-sheet))                              ; no key for these
```

- Command ids are the registry ids (the palette shows the commands; `drgnx-commands-all` lists them).
- `:map` is a keymap symbol or `(FEATURE . KEYMAP)` for a keymap that exists once FEATURE is loaded. In a Vim or
  mixed stack a key that starts with `SPC` (or `C-w`, the leader keys) always goes in the leader map, whatever `:map` says.
  A global key that evil binds in some state (`C-p`, `C-o` …) beats evil's there: drgnx binds it in evil's map too
  and puts evil's key back when the stack switches (see "Vim's claims are per state").
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
- A mistake never breaks startup. `keys.eld` is read and written through drgnx's config layer, which never applies
  a file in part: a file that does not read, or whose `:layers`, `:bind` entries, `:unbind` or `:mac-option` are not
  in the shape above (one bad `:bind` entry is enough), is not applied at all. The last good copy of `keys.eld`
  (kept per machine in the state folder) is applied instead, or the default stack if there never was one, and the
  problem, with its line, is on the key sheet and in the doctor. An unknown command or an invalid key is a smaller
  problem, listed the same way, and everything else in the file still applies.
- `keys.eld` is read when drgnx starts and each time keys are applied (a profile switch, the editor), not
  while you type in it. Change it by hand in Preferences: Open Config File… and save, and the file is read again
  and the keys apply at once (the mistake notice clears too). Saved some other way, it applies at the next profile
  switch, editor change or start.
- Keyboard Profile… rewrites only `:layers` and keeps the rest of the file (a new `keys.eld` also gets `:version 1`).
  It, the editor and Onboarding refuse a `keys.eld` with a mistake, naming the line, and change nothing.
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
  writes nothing. The editor writes the whole file under a lock and only if it is still the file it read: a change
  made by hand or by another session while an edit was being made is refused ("keys.eld changed since you opened
  it"), never overwritten. The keys apply at once after every change. Changes made inside `drgnx-keys-edit-one-step` are one
  step (the editor's Replace: the key taken from other commands and given to this one).

In a terminal that cannot send `C-S-` chords and the like (GNOME Terminal, Ptyxis, Terminal.app), each chord of the
profile is typed as Alt+Shift with the key where that is free (`C-S-f` as Alt+Shift+F), or as F6 then the key
(`C-S-p` as F6 p), always: see [Legacy terminals](terminal.md#legacy-terminals-altshift-and-f6). `:tty-fallback` in
`keys.eld` gives a chord another Alt key, `(:tty-fallback (("C-S-p" . "M-Z")))`, if that key is free.

In such a terminal every surface shows a key the way that terminal can send it: the command palette shows
`F6 p` for the palette itself and `M-F` (Alt+Shift+F) for Search in Project, the "next time" tips say the same, the
menus (which keep their text as you change buffers) always show the F6 form, `F6 f`, and the key sheet (`C-h C-k`, `C-k C-r` in VS Code keys) ends with a section, "Keys this terminal cannot send, and
what to press here", that lists each such key with both forms. In a graphical window, and in a terminal that sends the
key, nothing changes. The markdown cheat sheet (`drgnx-surfaces-export-markdown`) always has the profile's own keys.

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
binding someone else changed since); a prefix a binding made (`s-k` for the Cmd+K chords where Emacs binds no `s-k`,
as in a terminal) goes again once it is empty. The active keys of each command are in its `bound` slot, which every surface
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
