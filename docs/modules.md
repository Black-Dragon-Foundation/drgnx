# Modules

Everything drgnx does beyond its core is a **module**: one file `modules/<category>/drgnx-<name>.el` with one
`drgnx-module-define`. Modules start in **stages**, each under its own error guard and timed, so one broken module
never stops Emacs from starting:

| Stage | When |
|---|---|
| `startup` | while drgnx starts |
| `idle` | the first time Emacs is idle (one second) |
| `first-frame` | when the first graphical window opens (a daemon's first `emacsclient -c`) |
| `first-file` | when the first file is visited |
| `first-input` | before the first command you give |

**Preferences: Modules** (palette, Options menu) lists every module with its status — `ok`, `failed: …`, `needs
<package>`, `needs <module>`, `disabled` — its stage, how long it took, and whether it runs at the next start; `RET`
turns the module on that row off (or back on) from the next start. `drgnx doctor` reports failed modules and modules
waiting for packages, from the last session.

## Packages

A module that needs a package says so (`:packages '(magit)`). Until the package is installed the module does not run
and is reported as waiting for it — Emacs never installs anything on its own (`drgnx sync` will, M5).

## modules.eld

Your choices live in `~/.config/drgnx/modules.eld` (`$DRGNX_CONFIG_DIR`):

```elisp
(:version 1
 :disabled (ui/zen lang/python)          ; modules that do not run
 :flags ((ui/popups +childframe)))       ; module flags
```

An older format is migrated when it is read; an unreadable file is reported in `*Messages*` and ignored (modules use
their defaults) — never an error at start.

## Writing a module

```elisp
(drgnx-module-define 'tools/example
  :doc "One line: what it gives you."
  :stage 'idle
  :requires '(core/workbench)            ; modules that must have run
  :packages '(example-mode)              ; features that must be loadable
  :flags '(+fancy)                       ; (drgnx-module-flag-p 'tools/example '+fancy)
  :doctor (lambda () (unless (executable-find "example") '("the example program is not installed")))
  :settings '((example-width . "Width of the example pane"))
  :setup
  (lambda ()
    (drgnx-command-define 'example-run :category "Example" :title "Run Example" :command #'example-run
      :doc "Run the example")))
```

Every command goes through the registry (`drgnx-command-define`) and gets a key — or `:none` with a reason — in each
key profile ([keys.md](keys.md)); faces inherit theme faces (no colours). See [core.md](core.md) for the registry.

## Shipped modules

| Module | Stage | What it gives you |
|---|---|---|
| `core/basics` | startup | quiet defaults (no bell, no dialogs, y/n, background compiler warnings only in the log), Open File, Save, line numbers |
| `core/workbench` | startup | the workbench: docks, panel, popups, chrome, groups, several windows, the layout across restarts ([workbench.md](workbench.md)) |
| `editor/editing` | startup | Fold / Unfold, Change Case (camelCase, snake_case, kebab-case, cycle), Expand / Shrink Selection (tree-sitter nodes when the buffer has a parser), Go to Line |
| `ui/look` | startup | Color Theme (remembered in modules.eld), Zen Mode (only the text; again to give the sidebar and panel back) |
