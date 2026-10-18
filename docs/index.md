# drgnx documentation

## Guide

Using drgnx.

- [Install](guide/install.md): install.sh, per-platform guide (on a Mac: Homebrew, Emacs, the drgnx app, step by step), source build, `drgnx doctor`, uninstall.
- [Onboarding](guide/onboarding.md): `drgnx onboard` and Help → Welcome — new to Emacs, environment, keys and packages, projects onto the board, AI (Ollama, LM Studio, OpenRouter), Claude Code, keep running or quit.
- [Opening drgnx](guide/opening.md): `drgnx .`, `drgnx PATH`, `drgnx open` (like `code .`, one drgnx); the drgnx app on macOS (Finder, Spotlight, Dock, Open With); keep running in the background or quit when the last window closes.
- [Workbench](guide/workbench.md): the sidebar — Explorer and Buffers panel — the change bus, performance vs treemacs/ibuffer.
- [Keys](guide/keys.md): VS Code, Emacs and Vim key profiles, the Mac keys (⌘P, ⌘⇧P, …), layers, keys.eld, conflicts.
- [Modules](guide/modules.md): stages, packages, flags, modules.eld, Preferences: Modules, writing a module.
- [Packages](guide/packages.md): `drgnx sync`, the lock, the cache, generations, rollback, upgrade, safe mode, bisect.
- [Agents](guide/agents.md): agents over ACP, input that queues and never cancels, the Agents tab, edit review, durable jobs, plans ↔ board.
- [AI](guide/ai.md): one provider registry (OpenRouter and local runners), roles with fallback, keys read from the environment or auth-source, stored only in your Keychain or keyring when you ask, agent profiles.
- [Jobs](guide/jobs.md): agents through a plan — proposal, approval, worktrees, a policy, review and merge, budget, fallback; `drgnx job`.
- [Semantic Search](guide/search.md): find code by meaning — `#` in the palette, the index, what is never indexed, `.drgnx/search.eld`, privacy.
- [Editing](guide/editing.md): language support (tree-sitter grammars), and the editor's amenities.
- [Git and review](guide/git.md): the diff view, inline blame, AI commit messages, Review Branch, Pull Requests.
- [Work tracker](guide/work.md): specs › plans › tasks › TODOs › commits, branches and worktrees; `drgnx work`.
- [Search and replace](guide/replace.md): the Search view in the sidebar and the find bar — symbols and text in one interface, tick boxes, one Undo.
- [Layouts](guide/layouts.md): Agent, Editor, Zen and Browser, and your own; one key cycles them, and switching back restores what you left.
- [Browser pane](guide/browser.md): a web page beside the editor (WebKit), Test Report for Playwright, and an agent's page with its screenshot.

## Reference

Commands, options and the CLI, generated from the command registry — not written yet.

## Develop

How drgnx is built, tested and measured.

- [Architecture overview](develop/architecture.md)
- [Core](develop/core.md): paths, staged hooks, no-prompt guard, command registry, surfaces, palette, modules.
- [Harness](develop/harness.md): headless GUI test sessions, test tiers, CLI and MCP tools for agents.
- [Performance](develop/perf.md): the perf lab — input latency, frames, GC, startup, memory, budgets, the soak, tuning.
- [Scenarios](develop/scenarios.md): behaviour scenarios and the evidence behind the workbench design.
- [Formatting](develop/formatting.md): `bin/drgnx fmt` — the Emacs Lisp formatter, and where it is enforced.
- [bin/drgnx check](develop/check.md): build and every test tier in one parallel run; shards, GUI slots, phases.
- [CI](develop/ci.md): the GitHub Actions workflows — Emacs 31.1 and 30.2 suites, shellcheck, leak scan, nightly GUI tier.
- [The hub and the gateway](develop/hub.md): the durable process behind agents, its socket protocol, the traffic gateway.
- [Agent coordination](develop/coordination.md): jobs, tasks and leases, the decision log, messages, the MCP tools, delivery.

Docs are updated in the same commit as the code they describe.
