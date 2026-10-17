# drgnx documentation

## Guide

Using drgnx.

- [Install](guide/install.md): install.sh, per-platform guide, source build, `drgnx doctor`, uninstall.
- [Onboarding](guide/onboarding.md): `drgnx onboard` and Help → Welcome — environment, keys, projects onto the board, the daemon.
- [Workbench](guide/workbench.md): the sidebar — Explorer and Buffers panel — the change bus, performance vs treemacs/ibuffer.
- [Keys](guide/keys.md): VS Code, Emacs and Vim key profiles, layers, keys.eld, conflicts.
- [Modules](guide/modules.md): stages, packages, flags, modules.eld, Preferences: Modules, writing a module.
- [Packages](guide/packages.md): `drgnx sync`, the lock, the cache, generations, rollback, upgrade, safe mode, bisect.
- [Agents](guide/agents.md): agents over ACP, input that queues and never cancels, the Agents tab, edit review, durable jobs, plans ↔ board.
- [Work tracker](guide/work.md): specs › plans › tasks › TODOs › commits, branches and worktrees; `drgnx work`.

## Reference

Commands, options and the CLI, generated from the command registry — not written yet.

## Develop

How drgnx is built, tested and measured.

- [Architecture overview](develop/architecture.md)
- [Core](develop/core.md): paths, staged hooks, no-prompt guard, command registry, surfaces, palette, modules.
- [Harness](develop/harness.md): headless GUI test sessions, test tiers, CLI and MCP tools for agents.
- [Performance](develop/perf.md): the perf lab — input latency, frames, GC, startup, memory, budgets, the soak, tuning.
- [Scenarios](develop/scenarios.md): behaviour scenarios and the evidence behind the workbench design.

Docs are updated in the same commit as the code they describe.
