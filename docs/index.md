# drgnx documentation

## Guide

Using drgnx.

- [Install](guide/install.md): install.sh, per-platform guide (on a Mac: Homebrew, Emacs, the drgnx app, step by step), source build, `drgnx doctor`, uninstall.
- [Onboarding](guide/onboarding.md): `drgnx onboard` and Help → Welcome — new to Emacs, environment, keys and packages, projects onto the board, AI (Ollama, LM Studio, OpenRouter), Claude Code, keep running or quit.
- [Opening drgnx](guide/opening.md): `drgnx .`, `drgnx PATH`, `drgnx open` (like `code .`, one drgnx); the drgnx app on macOS (Finder, Spotlight, Dock, Open With); keep running in the background or quit when the last window closes.
- [Workbench](guide/workbench.md): the sidebar — Explorer and Buffers panel — the change bus, performance vs treemacs/ibuffer;
  several monitors: what each window manager allows (sway, i3, Hyprland, niri, KDE, X11, macOS; GNOME's key), floating rules.
- [Keys](guide/keys.md): VS Code, Emacs and Vim key profiles — Vim on evil with states, the `SPC` leader, ex commands and mixed stacks (M12d) — the Mac keys (⌘P, ⌘⇧P, …), layers, keys.eld, conflicts.
- [Modules](guide/modules.md): stages, packages, flags, modules.eld, Preferences: Modules, writing a module.
- [Packages](guide/packages.md): `drgnx sync`, the lock, the cache, generations, rollback, upgrade, safe mode, bisect.
- [Agents](guide/agents.md): agents over ACP, input that queues and never cancels, the Agents tab, edit review, durable jobs, what a job's Claude ignores of your settings, agents outside drgnx that report to it, plans ↔ board.
- [AI](guide/ai.md): one provider registry (OpenRouter and local runners), roles with fallback, keys read from the environment or auth-source, stored only in your Keychain or keyring when you ask, agent profiles.
- [Jobs](guide/jobs.md): agents through a plan — proposal, approval, worktrees, a policy, review and merge (with an optional accept gate: every file accepted), budget, fallback; `drgnx job`.
- [Semantic Search](guide/search.md): find code by meaning — `#` in the palette, the index, what is never indexed, `.drgnx/search.eld`, privacy.
- [Editing](guide/editing.md): language support (tree-sitter grammars), and the editor's amenities.
- [Git and review](guide/git.md): the diff view, inline blame, AI commit messages, Review Branch, Pull Requests.
- [Work tracker](guide/work.md): specs › plans › tasks › TODOs › commits, branches and worktrees; `drgnx work`.
- [Work cockpit](guide/cockpit.md): the Work graph — specs, plans, tasks, agents, jobs and reviews, who is on what, needs and blocks, what waits on you; drawn in a wide window, an outline in terminals; worktrees that do not report; filters; TAB selects, RET or a click opens. Each agent's edits as a live diff: accept a file (a review mark, never a merge), ask the agent to undo it, comment on a line. What happened, one line per event; the timeline, chips per agent; questions in the graph and the timeline (the status bar's count: pending), answered with A (queued, never interrupting). What needs you and Decisions: every job's cards and messages, a job's log; Show Job in Work filters the cockpit to a job. From the graph: reassign a job's task, mark it blocked, run it earlier or later, Start as Job (a plan task and what it needs, proposed).
- [Search and replace](guide/replace.md): the Search view in the sidebar and the find bar — symbols and text in one interface, tick boxes, one Undo.
- [Layouts](guide/layouts.md): Agent, Editor, Zen and Browser, and your own; one key cycles them, and switching back restores what you left.
- [Browser pane](guide/browser.md): a web page beside the editor (WebKit), Test Report for Playwright, and an agent's page with its screenshot.
- [Live view](guide/live.md): watch the browser your agents drive, live, and take it over.
- [Remote editing](guide/remote.md): Open Remote… (ssh hosts, podman containers), the status-line segment, Reconnect, language servers on the host.
- [Keyboard Shortcuts editor](guide/shortcuts.md): every command with its keys; record new ones, see conflicts, filter, undo.
- [Agent settings](guide/agent-settings.md): one page per agent (Claude Code, Codex, Gemini, Kimi Code) — routes and billing, MCP servers, hooks and skills; add, edit, remove, Test.
- [The face](guide/face.md): no light menu bar or scroll bar, thin themed dividers, line numbers in code that never shift sideways, problems at the end of their line, a top line (project, branch, the three keys that open everything), a status bar built from segments you can reorder, drop or add to, a dark title bar that follows the theme, glyphs with an ASCII form, quick help in a card beside the symbol (a strip in terminals), a × and Esc/q that close every help pane, popup and side pane, a start page in an empty editor; every choice a setting.
- [Editor features vs VS Code, Zed and Cursor](guide/editor-matrix.md): what drgnx has, where it is described, its GUI test and perf workload.
- [Trusted folders](guide/security.md): Trust This Folder, the "Restricted Mode" mark, what files from untrusted folders cannot make Emacs do.
- [In a terminal](guide/terminal.md): the graphical window, a capable terminal and a legacy one (Alt+Shift and F6); what each terminal can do (kitty, WezTerm, foot, Ghostty, Ptyxis, tmux …) and which rows a test ran, the lines that fix what is missing, SSH, tmux, `EDITOR`, the clipboard, the mouse, colours.
- [Your files](guide/files.md): when a settings file has a mistake (the last good copy, Open and Reset), backups, locks and `config-good/`, two machines sharing one folder.
- [A second machine](guide/second-machine.md): what travels (the whole config dir), what stays on this machine (the data, state and cache dirs), paths written `~/…`, the doctor's `portable-config` check, provider keys in `secrets.age`, the one command `drgnx bootstrap`.
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
- [CI](develop/ci.md): the GitHub Actions workflows — Emacs 31.1 and 30.2 suites, shellcheck, leak scan, nightly GUI tier.
- [The hub and the gateway](develop/hub.md): the durable process behind agents, its socket protocol, the traffic gateway.
- [Agent coordination](develop/coordination.md): jobs, tasks and leases, the decision log, messages, the MCP tools (and the identity and limits of agents outside drgnx), delivery.
- [The Work cockpit's model](develop/cockpit.md): one model of specs, plans, tasks, agents, jobs and reviews from the live store; what happened, the timeline; each agent's edits (async git, regular files only); the Work graph's redraws, cost and tests; an agent's edits pane: live patches, accept, revert, comment; what happened, the timeline and answers: appends, routes, cost and tests; what needs you and the decisions: the job window's parts, the job filter, its saved state.
- [The job sandbox](develop/sandbox.md): what a job agent can see — the spec, what it refuses, the bubblewrap argv
  and why each flag, the MCP bridge into the sandbox, the Seatbelt profile on macOS, phase 2's network relay, proxy and gateway socket.

Docs are updated in the same commit as the code they describe.
