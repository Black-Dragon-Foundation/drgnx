# Architecture overview

drgnx is an Emacs Lisp framework with two core primitives that every module plugs into:

1. **The workbench** (`wb/`): each frame is a workbench with an editor area (editor groups that never split
   on their own) and three docks (left: Buffers / Explorer / Outline; right: agents, chat, board; bottom:
   terminal, problems, output, results, help). A change bus (`drgnx-signal`) is the only subscriber to raw
   Emacs window/buffer hooks and emits deduplicated events, which makes "the layout never jumps" a structural
   property. Layout invariants I1–I10 are tested in headless sessions.
2. **The command registry** (`core/`): one `drgnx-command-define` entry generates keys (per platform
   profile), menus, context menus, which-key labels, the palette, the F1 sheet, docs and the Settings page.

Around them: a module system (`drgnx-module-define`, staged loading, per-module error isolation, doctor
checks, settings), reproducible package management on package.el (lockfile, generations, rollback, network
access only in batch), the `drgnx` CLI, the headless UI harness with MCP tools for agents ([harness.md](harness.md); all tooling is batch Emacs Lisp), a provider
registry for AI features, and the semantic search module.

Layers, lowest to highest: Emacs built-ins → core → workbench → modules → external modules → user config
(`~/.config/drgnx`, never inside the checkout).

Details: [roadmap.md](roadmap.md).
