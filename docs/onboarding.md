# Onboarding

`drgnx onboard` takes a fresh machine to a working drgnx; in Emacs, **Help → Welcome** (palette: "Welcome") lists
the same steps with their status — `RET` runs one. Every step is a command of its own ("Onboarding: Import
Projects"…), can be run again at any time, and changes nothing the second time. Progress is kept in
`~/.local/state/drgnx/onboarding.eld`: a run that stopped resumes, and a step that fails is shown failed with how to
fix it — it never stops the others.

```
drgnx onboard                                   asks (in the terminal) where a step has a choice
drgnx onboard --non-interactive --preset ide    never asks: defaults and the options given
        [--keys "VS Code"|Emacs|…] [--theme THEME] [--roots DIR…] [--step ID]…
```

The exit code is 1 when a step failed. `drgnx doctor` reports onboarding too.

## The steps

| Step | What it does |
|---|---|
| Check the Environment | git (required), ripgrep, fd, podman, mise, a GPU tool, the Symbols Nerd Font — each found or missing, with how to get it |
| Look and Keys | the key profile (VS Code, Emacs, Vim, combinations), a colour theme, and the module preset: **minimal** (the workbench and built-in modules), **ide** (plus the package-backed editing modules — not AI), **full-ai** (everything). Your own module choices outside `extra/` stay. Change any of it later: Preferences: Keyboard Profile, Color Theme, Modules |
| Import Projects | finds git repositories under `~/workspace`, `~/code`, `~/src`, `~/projects`, `~/git` (or `--roots`) and in gryphn's `~/.config/gryphn/projects.tsv`; you pick (default: all). Each goes on the **board** with its open TODOs |
| AI Providers | lists local model runners found (Ollama, llama.cpp, LM Studio); providers, keys and models per role arrive with the AI milestone |
| Semantic Search | lists embedding servers found; indexing arrives with the search milestone |
| Agents | lists agent CLIs found (Claude, gryphn's `gry`); profiles and MCP servers arrive with the agents milestone |
| Daemon and Desktop | writes `~/.config/drgnx/systemd/drgnx.service` and `~/.config/drgnx/applications/drgnx.desktop` and prints how to install them (and `EDITOR`/`VISUAL`); run interactively, it installs them into `~/.config/systemd/user/` and `~/.local/share/applications/` if you say yes |
| Portability | lists chezmoi and age; setting up a second machine is documented with the platforms milestone |
| Finish | runs `drgnx doctor` and says what is left |

## The board

Projects go on an org file, `board.org` in your `org-directory` (`drgnx-projects-board-file` to change it), one
top-level heading per project — the format gryphn's board uses, so it keeps working on the same file:

```org
* alpha
:PROPERTIES:
:PROJECT_ROOT: /srv/code/alpha
:REPO_URL: https://github.com/you/alpha.git
:END:
** TODO write the parser
:PROPERTIES:
:ONBOARD_ID: 3f1c0a9e5b21
:END:
```

Open TODOs come from `TODO.md` (`- [ ] …`), `TODO.org` (`* TODO …`) and plan checklists in `docs/**/plans/*.md`.
A project already on the board (same root) is not added again; a TODO already imported (same `ONBOARD_ID`) is
not added again; nothing on the board is moved or rewritten. If the board is open in Emacs with unsaved changes,
the step stops and asks you to save first. Projects are also listed in `~/.config/drgnx/projects.eld` and
remembered by project.el (its list lives in `~/.local/state/drgnx/projects`).

The scan goes at most three levels below each root, never into a repository, a hidden or symlinked directory or
`node_modules`/`target`/`build`/`dist`, and stops after five seconds.

## Tests

`test/unit/onboard-test.el` (fixture repositories and boards in temp dirs: order and resume, failures, never
asking when non-interactive, presets, the scan's bounds, importing twice, an existing gryphn board, an unsaved
board, the daemon files, the whole flow twice, the CLI) and `test/live/drgnx-onboard-test.el` (a fresh GUI
session onboards non-interactively; the board has the projects and TODOs, no step or doctor check fails, Welcome
opens in the editor, a second run changes nothing).
