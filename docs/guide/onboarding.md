# Onboarding

`drgnx onboard` takes a fresh machine to a working drgnx; in Emacs, **Help → Welcome** (palette: "Welcome") lists
the same steps with their status — `RET` runs one. Every step is a command of its own ("Onboarding: Import
Projects"…), can be run again at any time, and changes nothing the second time — with no option given, a step keeps
your current choices. Progress is kept in `~/.local/state/drgnx/onboarding.eld`: `drgnx onboard` resumes at the
first step not done (`--again` runs every step; `--step ID` runs that one), and a step that fails is shown failed
with how to fix it — it never stops the others.

```
drgnx onboard                                   asks (in the terminal) where a step has a choice
drgnx onboard --non-interactive --preset ide    never asks: the options given, else your current choices
        [--again] [--keys "VS Code"|Emacs|…] [--theme THEME] [--roots DIR…] [--todos] [--step ID]…
```

The exit code is 1 when a step failed. `drgnx doctor` reports onboarding too.

## The steps

| Step | What it does |
|---|---|
| Check the Environment | git (required), ripgrep, fd, podman, mise, a GPU tool, the Symbols Nerd Font — each found or missing, with how to get it |
| Look and Keys | the key profile (VS Code, Emacs, Vim, combinations), a colour theme, and the module preset: **minimal** (the workbench and built-in modules), **ide** (plus the package-backed editing modules — not AI), **full-ai** (everything). Your own module choices outside `extra/` stay. Change any of it later: Preferences: Keyboard Profile, Color Theme, Modules |
| Import Projects | finds git repositories under `~/workspace`, `~/code`, `~/src`, `~/projects`, `~/git` (or `--roots`) and in gryphn's `~/.config/gryphn/projects.tsv`; you pick (empty: all; `(none)`: none; several are separated by a comma, or by `;` or `|` when a path has a comma — the prompt says which). Each goes on the **board**; you choose which projects also bring their open TODOs (`--todos`: all of them; default: none) |
| AI Providers | finds the model runners running here (Ollama, llama.cpp, LM Studio, vLLM, … — [ai.md](ai.md)) and the providers you have a key for, picks a model for each role (Inline Completion prefers a code model; Edit and Chat prefer OpenRouter when it has a key), makes one test call per role and keeps the roles that answered — a role you chose that still answers stays. It writes no key: with none, it says how to add one (`OPENROUTER_API_KEY`, or `~/.authinfo`). It also reports the GPU's free memory. Change a role later: AI: Choose Provider/Model |
| Semantic Search | the same as **Set Up Semantic Search** ([search.md](search.md)). Run interactively (Help → Welcome) it finds an embedding model, tests it with one call and starts indexing the current project in the background — or, when that index is current, runs a test query. With `--non-interactive` it only reports: whether an embedding model is running (and how to start TEI or Ollama if not), and how many of the projects drgnx knows have an index; it starts nothing |
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

Open TODOs come from `TODO.md` (`- [ ] …`), `TODO.org` (`* TODO …`) and plan checklists in `docs/**/plans/*.md`
(checklist items remember their file, so Sync Plans and Board TODOs keeps them in step — [agents.md](agents.md))
(at most 200 per project and import; the step says when it stopped there). A project already on the board — the
same root, at any heading level, also through a symlink — is not added again; a TODO already imported is not added
again, even after you archived or deleted it (drgnx remembers what it imported); text that would read as org
syntax (tags, a property drawer, COMMENT) is quoted. The board is edited as text and written back with its
encoding, line endings, file modes and symlink; nothing on it is moved or rewritten. If the board has unsaved
changes in this Emacs, or another Emacs is editing it, the step stops and asks you to save first. Projects are also listed in `~/.config/drgnx/projects.eld` and
remembered by project.el (its list lives in `~/.local/state/drgnx/projects`).

The scan goes at most three levels below each root, never into a repository, a hidden or symlinked directory or
`node_modules`/`target`/`build`/`dist`, and stops after five seconds — then the step warns and says where it stopped
(name the directories with `--roots`).

## Tests

`test/unit/onboard-test.el` (fixture repositories and boards in temp dirs: order and resume, failures, never
asking when non-interactive, presets, the scan's bounds, importing twice, an existing gryphn board, an unsaved
board, the daemon files, the whole flow twice, the CLI), `test/unit/ai-onboard-test.el` (the AI step against a mock model server: roles set and tested, a working choice kept, nothing running) and `test/live/drgnx-onboard-test.el` (a fresh GUI
session onboards non-interactively; the board has the projects and TODOs, no step or doctor check fails, Welcome
opens in the editor, a second run changes nothing).
