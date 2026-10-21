# dragonX (`drgnx`)

**A modern, workbench-first Emacs framework**, by the Black Dragon Foundation. VS Code / Zed / Cursor ergonomics — stable docks and
editor groups, a command palette, mouse-first discoverability, AI completion and agents with any model —
on top of everything that makes Emacs worth it: org, deep programmability, a persistent daemon and the
whole Emacs package ecosystem. Light on memory: the target is a daemon under 400 MB with all modules on.

> **Status: pre-release.** drgnx is being built in the open. You can install it to follow along, but there is no
> support, and contributions are not being accepted yet. Watch the repo for updates.

## What makes it different

- **Zero-jank layout, as a tested guarantee.** The workbench window manager (left/right/bottom docks,
  editor groups that never split on their own, popups that leave no trace) is verified by layout
  invariants that run in a headless test session on every change.
- **Agent-testable editor.** A headless harness lets AI agents start an isolated Emacs, click, type,
  take screenshots and measure layout jank and latency through MCP tools — so UI changes come with
  evidence, not hope.
- **Any model, local first.** One provider registry for OpenRouter and local runners (Ollama, LM Studio,
  llama.cpp, vLLM, LocalAI, Jan, …) feeds ghost-text completion, inline edits with per-hunk review, chat,
  agents and semantic search.
- **Semantic search built in**, shared by the editor and by agents, set up with one command.
- **Guided onboarding**: environment checks, keys and theme, importing your projects into an org board,
  AI providers, indexing, agents, the daemon — every step re-runnable and checked by `drgnx doctor`.

## Requirements

- GNU Emacs **31.1 or newer**, with native compilation. Emacs 30 and older are no longer supported.
- Linux (GNOME, KDE, XFCE, Cinnamon, tiling window managers) and macOS

**Coming next: Nidhogg**, dragonX's own Emacs build: GNU Emacs 31 with dragonX's patches
([Black-Dragon-Foundation/nidhogg](https://github.com/Black-Dragon-Foundation/nidhogg)). dragonX will run on it, and
the installer will build and install it for you. It is in progress and not released yet.

## Install

Pre-release: this installs the work in progress.

```sh
curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash
```

It prints a plan first, asks before every root step, and builds Nidhogg, drgnx's own Emacs (GNU Emacs 31.1 with drgnx's
patches, native compilation), on Fedora 44/45, Ubuntu 26.04 and macOS; elsewhere it stops (no Nidhogg recipe yet), and
the doctor fails on a stock GNU Emacs. On macOS, run it in Terminal: it installs Homebrew
(after asking) and builds Nidhogg with it, adds a **drgnx** app to `~/Applications` and opens it, and the Welcome sets up keys,
AI and Claude Code; afterwards open drgnx with Spotlight (⌘Space, type "drgnx") or Launchpad, or run `drgnx .` in a
project, like `code .`; to keep it in the Dock, drag `~/Applications/drgnx.app` there.
`--dry-run` shows the plan only. On a second machine, `bash -s -- --config URL` (after the `| bash`) also sets it up from
your configuration repository ([docs/guide/second-machine.md](docs/guide/second-machine.md)). Details,
manual install and uninstall: [docs/guide/install.md](docs/guide/install.md). Check a machine with `drgnx doctor`. Keep it current with `drgnx update` (`--restart` restarts drgnx afterwards; `--back` undoes the last update).

## Documentation

- [Guide](docs/index.md#guide): install, onboarding, the workbench, keys, modules, packages, agents, the work tracker
- [Develop](docs/index.md#develop): architecture, core, the test harness, performance, scenarios

## Roadmap

- **Done:** the test harness for agents, the installer and `drgnx doctor`, VS Code / Emacs / Vim key profiles,
  modal Vim editing on evil (states, the `SPC` leader, ex commands that keep the workbench's groups, panels and
  AI working with it), the workbench (Explorer, Buffers, docks, panel, editor groups, several windows, layout that
  survives restarts), modules, reproducible packages with rollback, onboarding, AI agents with queued input and edit
  review, the perf lab, the work tracker, AI completion and inline edits with any model (local runners first),
  built-in semantic search, terminal windows (`drgnx -t`, SSH, tmux: keys, mouse, clipboard, colours), several
  monitors under sway, i3, Hyprland, niri, KDE Plasma, X11 and macOS (move a window to another monitor, restore each
  window to its own; GNOME explains its key), your own shell in drgnx's terminal, and a second machine from one command
  (`drgnx bootstrap`).
- **Next:** **Nidhogg**, dragonX's own Emacs build (see Requirements); dragonX then runs on it.
- **Polish:** a compositor for rounded, shadowed, animated popups and panels. Linux Wayland first, then macOS.
- **Speed:** no freezes while Lisp works; parsing, process output and JSON move off the main thread; smooth scrolling.
- **Agents:** a panel that shows what agents do in detail (each step, diffs, permissions, context and cost), with
  collapse per step type that remembers your choice; an agent runtime written in Rust.
- **Extensions:** WebAssembly extensions, so tools can be written in any language (agent tools first). Community
  Emacs packages keep working.
- **Also planned:** a settings editor, a Meow modal module, then the public launch. (Language servers, a debugger,
  multiple cursors and the keyboard shortcuts editor are already modules: `lang/eglot`, `extra/debug`, `extra/mc`,
  `tools/shortcuts`.)

No dates and no promises: this is the direction, not a schedule.

## License

drgnx is free software under the **GNU General Public License v3.0 or later** (see `LICENSE`).
Code derived from [Emacs Bedrock](https://codeberg.org/ashton314/emacs-bedrock) keeps its MIT notice.
The Seatbelt base policy in `core/drgnx-sandbox-macos.el` is OpenAI Codex's, Copyright 2025 OpenAI, under the
Apache License 2.0 (`LICENSES/Apache-2.0.txt`).
A separate `drgnx-pro` add-on may follow later under a source-available license that stays free for
individuals, open-source developers and small businesses.
