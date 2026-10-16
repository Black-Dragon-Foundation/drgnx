# drgnx

**A modern, workbench-first Emacs framework.** VS Code / Zed / Cursor ergonomics — stable docks and
editor groups, a command palette, mouse-first discoverability, AI completion and agents with any model —
on top of everything that makes Emacs worth it: org, deep programmability, a persistent daemon and the
whole Emacs package ecosystem. Light on memory: the target is a daemon under 400 MB with all modules on.

> **Status: pre-release.** drgnx is being built in the open. You can install it to follow along, but there is no
> support, and contributions are not being accepted yet. Watch the repo or read the roadmap.

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

- GNU Emacs **31.1+** with native compilation (30.2 still works); pgtk on Wayland, X11 and macOS builds
- Linux (GNOME, KDE, XFCE, Cinnamon, tiling window managers) and macOS

## Install

Pre-release: this installs the work in progress.

```sh
curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash
```

It prints a plan first, asks before every root step, and gets Emacs 31.1 from your distribution where it
is good or builds the signed GNU release with native compilation. `--dry-run` shows the plan only. Details,
manual install and uninstall: [docs/install.md](docs/install.md). Check a machine with `drgnx doctor`.

## Documentation

- [Install](docs/install.md)
- [Roadmap and design](docs/roadmap.md)
- [Architecture](docs/architecture.md)

## License

drgnx is free software under the **GNU General Public License v3.0 or later** (see `LICENSE`).
Code derived from [Emacs Bedrock](https://codeberg.org/ashton314/emacs-bedrock) keeps its MIT notice.
A separate `drgnx-pro` add-on may follow later under a source-available license that stays free for
individuals, open-source developers and small businesses.
