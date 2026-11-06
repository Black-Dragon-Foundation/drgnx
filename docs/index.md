# drgnx documentation

## Guide

Using drgnx.

- [Install](guide/install.md): install.sh, per-platform guide (on a Mac: Homebrew, Emacs, the drgnx app, step by step), source build, `drgnx doctor`, uninstall.
- [Onboarding](guide/onboarding.md): `drgnx onboard` and Help → Welcome — new to Emacs, environment, keys and packages, projects onto the board, AI (Ollama, LM Studio, OpenRouter), Claude Code, keep running or quit.
- [Opening drgnx](guide/opening.md): `drgnx .`, `drgnx PATH`, `drgnx open` (like `code .`, one drgnx); the drgnx app on macOS (Finder, Spotlight, Dock, Open With); keep running in the background or quit when the last window closes.
- [Workbench](guide/workbench.md): the sidebar — Explorer and Buffers panel — the change bus, performance vs treemacs/ibuffer;
  several monitors: what each window manager allows (sway, i3, Hyprland, niri, KDE, X11, macOS; GNOME's key), floating rules.
- [Keys](guide/keys.md): VS Code, Emacs and Vim key profiles — Vim on evil with states, the `SPC` leader, ex commands and mixed stacks (M12d) — the Mac keys (⌘P, ⌘⇧P, …), layers, keys.eld, conflicts.
- [Command palette](guide/palette.md): `#` for a code question, and the floating, rounded, blurred palette under Glitnir (`drgnx-look-palette`).
- [Modules](guide/modules.md): stages, packages, flags, modules.eld, Preferences: Modules, writing a module.
- [Packages](guide/packages.md): `drgnx sync`, the lock, the cache, generations, rollback, upgrade, safe mode, bisect.
- [Agents](guide/agents.md): agents over ACP, input that queues and never cancels, the Agents tab, edit review, durable jobs, what a job's Claude ignores of your settings, agents outside drgnx that report to it, plans ↔ board.
- [AI](guide/ai.md): one provider registry (OpenRouter and local runners), roles with fallback, keys read from the environment or auth-source, stored only in your Keychain or keyring when you ask, agent profiles.
- [Runners](guide/runners.md): your other machines run jobs; how drgnx reaches them through your own ssh (the options it always sets, one connection per runner, a lost link never a result), logins it never answers, host keys it never accepts; adding, checking and removing a machine (`drgnx runner …`).
- [Jobs](guide/jobs.md): agents through a plan — proposal, approval, worktrees, a policy, review and merge (with an optional accept gate: every file accepted), budget, fallback; `drgnx job`.
- [Agent browser](guide/agent-browser.md): the browser a sandboxed agent session drives — which one drgnx finds, what it can reach and how to answer its cards, `drgnx browser install` (a pinned, checksum-verified download you run yourself), `drgnx browser list`, the doctor's line.
- [Semantic Search](guide/search.md): find code by meaning — `#` in the palette, the index, what is never indexed, `.drgnx/search.eld`, privacy.
- [Editing](guide/editing.md): language support (tree-sitter grammars), and the editor's amenities.
- [Large files](guide/large-files.md): above 50 MiB a file opens in chunks, lean or raw — a file you open asks once, `drgnx open` and everything automatic never ask; the header line and the status bar say which, and switch; long lines turn on so-long.
- [Git and review](guide/git.md): the diff view, inline blame, AI commit messages, Review Branch, Pull Requests.
- [The Work space](guide/work-space.md): opening the map (`work-view`), its faces, the machines the hub lists, `ratatoskr machines report`; the Board, the Timeline and the research trail, the review view, the second reviewer and the steering keys. It replaces the Work cockpit and the job window.
- [Work tracker](guide/work.md): specs › plans › tasks › TODOs › commits, branches and worktrees; `drgnx work`.
- [Search and replace](guide/replace.md): the Search view in the sidebar and the find bar — symbols and text in one interface, tick boxes, one Undo.
- [Layouts](guide/layouts.md): Agent, Editor, Zen and Browser, and your own; one key cycles them, and switching back restores what you left.
- [Browser pane](guide/browser.md): a web page beside the editor (WebKit), Test Report for Playwright, and an agent's page with its screenshot.
- [Live view](guide/live.md): the view of an agent's browser, waiting for a later update; the host-launched browser for agents is gone.
- [Remote editing](guide/remote.md): Open Remote… (ssh hosts, podman containers), the status-line segment, Reconnect, language servers on the host.
- [Keyboard Shortcuts editor](guide/shortcuts.md): every command with its keys; record new ones, see conflicts, filter, undo.
- [Agent settings](guide/agent-settings.md): one page per agent (Claude Code, Codex, Gemini, Kimi Code) — routes and billing, MCP servers, hooks and skills; add, edit, remove, Test.
- [The face](guide/face.md): no light menu bar or scroll bar, thin themed dividers, line numbers in code that never shift sideways, problems at the end of their line, a top line (project, branch, the three keys that open everything), a status bar built from segments you can reorder, drop or add to, a dark title bar that follows the theme, glyphs with an ASCII form, quick help in a card beside the symbol (a strip in terminals), a × and Esc/q that close every help pane, popup and side pane, a start page in an empty editor; every choice a setting.
- [Editor features vs VS Code, Zed and Cursor](guide/editor-matrix.md): what drgnx has, where it is described, its GUI test and perf workload.
- [Trusted folders](guide/security.md): Trust This Folder, the "Restricted Mode" mark, what files from untrusted folders cannot make Emacs do.
- [Plugins, rules and hooks](guide/plugins.md): installing and approving a plugin, choosing the plugins of one project, how your hook rules and plugins' hooks decide an agent's step (first deny wins, changes chain, the point's time, failures refuse); the rule format; rules are guardrails (being written).
- [In a terminal](guide/terminal.md): the graphical window, a capable terminal and a legacy one (Alt+Shift and F6); what each terminal can do (kitty, WezTerm, foot, Ghostty, Ptyxis, tmux …) and which rows a test ran, the lines that fix what is missing, SSH, tmux, `EDITOR`, the clipboard, the mouse, colours.
- [Settings](guide/settings.md): settings.el, the Settings page, and how your settings meet your Lisp, Customize and packages (being written).
- [Your files](guide/files.md): when a settings file has a mistake (the last good copy, Open and Reset), backups, locks and `config-good/`, two machines sharing one folder.
- [A second machine](guide/second-machine.md): what travels (the whole config dir), what stays on this machine (the data, state and cache dirs), paths written `~/…`, the doctor's `portable-config` check, provider keys in `secrets.age`, the one command `drgnx bootstrap`.
- [Notices](guide/notices.md): how drgnx tells you things; the two counts in the mode line and the Notices list; desktop notifications for everything waiting on you, once each, while no drgnx window has focus (D-Bus, `osascript` on macOS), and the off switch.
- [Speed: freezes, GC and the heap](guide/speed.md): the GC census (one line per collection, Help → GC Census) and the Heap Audit (Help → Heap Audit: what keeps the Lisp heap large, by owner, against budgets; it asks first, because Emacs stops for seconds).
- [Your shell](guide/shell.md): the one line for zsh, bash and fish — `drgnx` completion, eat's shell integration in the terminal, why an idle shell never blocks quit, `EDITOR`, your login shell's `PATH` in drgnx, prompt themes, fish's limits.

## Reference

- [Config files](reference/config.md): every file drgnx keeps, its folder, format, keys and what they mean (generated from the definitions).

Commands, options and the CLI, generated from the command registry — not written yet.

## Develop

How drgnx is built, tested and measured.

- [Architecture overview](develop/architecture.md)
- [Core](develop/core.md): paths, staged hooks, no-prompt guard, command registry, surfaces, palette, modules (every module turns off cleanly: the rule and its check).
- [Harness](develop/harness.md): headless GUI test sessions, test tiers (each unit test file in an Emacs of its
  own), CLI and MCP tools for agents.
- [Performance](develop/perf.md): the perf lab — input latency, frames, GC, startup, memory, budgets, the soak, tuning.
- [Scenarios](develop/scenarios.md): behaviour scenarios and the evidence behind the workbench design.
- [Formatting](develop/formatting.md): `bin/drgnx fmt` — the Emacs Lisp formatter, and where it is enforced.
- [bin/drgnx check](develop/check.md): build and every test tier in one parallel run; shards, GUI slots, phases, the leak census, the shuffled test order and the polluter bisect.
- [CI](develop/ci.md): the GitHub Actions workflows — Emacs 31.1 suite, shellcheck, leak scan, nightly GUI tier.
- [The runtime workspace](develop/runtime.md): `runtime/`, the Cargo workspace (MSRV, deny policy, locked builds), the crate names, and the conformance harness: scenario files run against a hub binary, one socket-path fixture for Lisp and Rust.
- [forseti](develop/forseti.md): the scheduler core the hub, its runners and jobq share — the job model, priority and the queue order, admission and grants, eviction and drains, two schedulers on one machine, the memory cap and ladder, kill classes, expected times, placement by finish time, the trust filter, fairness; pure.
- [sleipnir](develop/sleipnir.md): the runner — the machine probe and the runner contract, the reservation files two schedulers share, the one podman argv, the slice tree, job units, job-exec and `result.json`, the row parsers, jobq's shim; a job's inputs frozen at submit, the hardened git (no hook, fsmonitor or outside config ever runs), and checkout slots whose git dirs no job can reach.
- [Settings](develop/settings.md): the settings files' data subset and its two readers (Lisp and `huginn`), the start-up order, testing in a child Emacs.
- [The hub and the gateway](develop/hub.md): Ratatoskr, the one durable process behind agents (Ratatoskr phase 7 is done: no Lisp runtime, no backend, one writer), its socket protocol, the traffic gateway.
- [The store (Urdr)](develop/store.md): `work.db` schema 10 — one knowledge graph with history, written by Ratatoskr only.
- [The Work space](develop/work-space.md): how the map is built — the map core `vegvisir` (its events, model, chains, overlaps, effects and tests), its layout (plan blocks, lanes with a capacity, ports) and the 30-agent fixture; the hub's facts (worktree bases, live specs, machines, shell reads).
- [Records (saga)](develop/records.md): reading and writing a project's plan, ledger, deferred-list and board files without changing a byte.
- [Agent coordination](develop/coordination.md): jobs, tasks and leases, the decision log, messages, the MCP tools (and the identity and limits of agents outside drgnx), delivery.
- [The job sandbox](develop/sandbox.md): where the job sandbox's documentation is, and the VC guard (no git of yours runs in a task's folder).
- [Plugins](develop/plugins.md): the plugin host `brokkr` — the manifest, the approval hash, the install scan and the WIT world plugins implement; the hook engine (`norn::hooks`); the hub's plugins (install, approval, cards, the lists per project).
- [Gleipnir](develop/gleipnir.md): the Rust sandbox in `runtime/` that every agent session runs in — its spec and what it refuses, bwrap, the inner helper, Landlock, seccomp, Seatbelt, the relay and the proxy, the check, and the escape rows that prove it.

Docs are updated in the same commit as the code they describe.
