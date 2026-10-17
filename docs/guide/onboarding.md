# Onboarding

`drgnx onboard` takes a fresh machine to a working drgnx; in Emacs, **Help → Welcome** (palette: "Welcome") lists
the same steps with their status — `RET` runs one. Every step is a command of its own ("Onboarding: Import
Projects"…), can be run again at any time, and changes nothing the second time — with no option given, a step keeps
your current choices. Progress is kept in `~/.local/state/drgnx/onboarding.eld`: `drgnx onboard` resumes at the
first step not done (`--again` runs every step; `--step ID` runs that one), and a step that fails is shown failed
with how to fix it — it never stops the others.

**The first start opens the Welcome by itself.** When drgnx's first window shows and onboarding has never run on
this machine (no `onboarding.eld`), the Welcome opens a moment later — from a timer, after your layout is back; it
asks nothing until you run a step. It does this once: opening it leaves `onboarding.eld` behind (with no step done),
so later starts open as you left them. Help → Welcome brings it back at any time.

```
drgnx onboard                                   asks (in the terminal) where a step has a choice
drgnx onboard --non-interactive --preset ide    never asks: the options given, else your current choices
        [--again] [--keys "VS Code"|Emacs|…] [--theme THEME] [--roots DIR…] [--todos] [--step ID]…
```

The exit code is 1 when a step failed. `drgnx doctor` reports onboarding too.

## The steps

| Step | What it does |
|---|---|
| Check the Environment | git (required), ripgrep, fd, podman, mise, a GPU tool, the Symbols Nerd Font — each found or missing, with how to get it for your system. **On a Mac** the fixes are Homebrew commands (`brew install ripgrep`, `brew install fd`, `brew install podman` and then `podman machine init`, `brew install mise`, `brew install --cask font-symbols-only-nerd-font`); git comes with the Xcode Command Line Tools (`xcode-select --install`), which get a row of their own — they also bring the C compiler that builds tree-sitter grammars; the GPU row is always fine (Apple silicon: models use the shared memory). The font is looked up in Emacs itself when drgnx has a window, else with `fc-list`; when neither can tell (a Mac has no `fc-list`), the font shows as "could not check", not as missing |
| Look and Keys | the key profile (VS Code, Emacs, Vim, combinations), a colour theme, and the module preset: **minimal** (the workbench and built-in modules), **ide** (plus the package-backed editing modules — not AI), **full-ai** (everything). Your own module choices outside `extra/` stay. Change any of it later: Preferences: Keyboard Profile, Color Theme, Modules |
| Import Projects | finds git repositories under `~/workspace`, `~/code`, `~/src`, `~/projects`, `~/git` (or `--roots`) and in gryphn's `~/.config/gryphn/projects.tsv`; you pick (empty: all; `(none)`: none; several are separated by a comma, or by `;` or `|` when a path has a comma — the prompt says which). Each goes on the **board**; you choose which projects also bring their open TODOs (`--todos`: all of them; default: none) |
| AI Providers | finds the model runners running here (Ollama, llama.cpp, LM Studio, vLLM, … — [ai.md](ai.md)) and the providers you have a key for, picks a model for each role (Inline Completion prefers a code model; Edit and Chat prefer OpenRouter when it has a key), makes one test call per role and keeps the roles that answered — a role you chose that still answers stays. It also reports the GPU's free memory (on a Mac: two thirds of the RAM, which Apple silicon shares with the GPU). **When nothing answers, it sets AI up** ([below](#setting-ai-up)); run again, it asks whether to keep what works or change it. With `--non-interactive` it installs, downloads and asks nothing: it reports what it found and the commands that would set AI up. Change a role later: AI: Choose Provider/Model |
| Semantic Search | the same as **Set Up Semantic Search** ([search.md](search.md)). Run interactively (Help → Welcome) it finds an embedding model, tests it with one call and starts indexing the current project in the background — or, when that index is current, runs a test query. With `--non-interactive` it only reports: whether an embedding model is running (and how to start TEI or Ollama if not), and how many of the projects drgnx knows have an index; it starts nothing |
| Agents | lists agent CLIs found (Claude, gryphn's `gry`); profiles and MCP servers arrive with the agents milestone |
| Daemon and Desktop | first asks once: "Keep drgnx running in the background when you close its last window? (recommended, like VS Code)" — yes keeps it running (reopening is instant), no quits it with its last window ([opening.md](opening.md#keep-running-or-quit)); saved in `~/.config/drgnx/session.eld`, changed later with Preferences: Keep drgnx Running in the Background. With `--non-interactive` nothing is asked: the choice made before stays, else drgnx keeps running. Then, **on macOS:** the drgnx app — if `~/Applications/drgnx.app` is missing, it offers to install it ([opening.md](opening.md#on-macos-the-drgnx-app)); with `--non-interactive` it installs nothing and says how (`drgnx macos-app`). No systemd, no desktop entry, nothing starts at login. **On Linux:** writes `~/.config/drgnx/systemd/drgnx.service` and `~/.config/drgnx/applications/drgnx.desktop` and prints how to install them (and `EDITOR`/`VISUAL`); run interactively, it installs them into `~/.config/systemd/user/` and `~/.local/share/applications/` if you say yes. The result says the choice and where to change it |
| Portability | lists chezmoi and age; setting up a second machine is documented with the platforms milestone |
| Finish | runs `drgnx doctor` and says what is left |

## Setting AI up

When no role has a provider that answers (or you run the step again and choose **Change**), the AI step asks:
**Set up AI with: Ollama (local) / LM Studio (local) / OpenRouter (cloud key) / Skip**. Whatever you choose, it ends
by testing every AI feature against what it just set up — one call each for Inline Completion (`complete`), Edit with
AI (`edit`) and Chat (`chat`), one embedding when it set the `embed` role, and Ask the Codebase over a small temporary
project (its own retrievers, then the chat model) — and says which answered.

**Ollama or LM Studio (local).** First it says, in one question, everything it would run and about how much it would
download; nothing happens until you say yes.

| | macOS | Linux |
|---|---|---|
| Ollama — install (if missing) | `brew install ollama` | Ollama's official installer, `curl -fsSL https://ollama.com/install.sh \| sh`: it uses `sudo`, so drgnx copies the command for you to run in a terminal and waits for Ollama to answer (up to ten minutes; `C-g` stops) |
| Ollama — start | `ollama serve`, as a drgnx job (not `brew services`: nothing starts at login) | the same, unless the installer's service already answers |
| LM Studio — install (if missing) | `brew install --cask lm-studio`, then `open -a "LM Studio"` once: the app's first start puts its `lms` command in `~/.lmstudio/bin` | opens the download page; install it, open it, and drgnx goes on once its server or `lms` is there |
| LM Studio — start | `lms server start` | the same |

Then it downloads (`ollama pull` / `lms get -y`) the models for the memory this machine has — Inline Completion
always gets `qwen2.5-coder:1.5b`; Edit and Chat get `qwen2.5-coder:7b` when both fit (about 7 GB of room), else
`:3b` (about 4 GB), else the 1.5B as well — the room being the GPU's free memory, or on a Mac two thirds of its RAM
(16 GB: the 7B; 8 GB: the 3B). It also downloads an embedding model (`nomic-embed-text`; LM Studio:
`nomic-embed-text-v1.5`) and puts it first in the `embed` role, so the next step, Semantic Search, can index. LM Studio
gets the same models as GGUF files from Hugging Face (`lmstudio-community/Qwen2.5-Coder-…-Instruct-GGUF`). Each model
goes first in its role in `~/.config/drgnx/ai.eld`; what the role had stays behind it as a fallback.

Every command runs as a drgnx job with its own log; the Welcome shows its last line while it runs, and `C-g` stops
it. A download that fails says which model, why (the log's last line), where the log is, and to run the step again —
a new run starts from the top, skips what is installed and running, and `ollama pull` / `lms get` skip what is
already downloaded. The server keeps running as a drgnx job; after a restart of the machine, run the step again to
start it (or `brew services start ollama` to have Ollama start at login).

**OpenRouter (cloud key).** In the drgnx app it asks for your key (`read-passwd`: never shown, never written to a file
or log) and keeps it in the macOS Keychain or your Linux keyring ([ai.md](ai.md#keys)); then Inline Completion gets
`qwen/qwen-2.5-coder-32b-instruct` and Edit and Chat `openrouter/auto`. OpenRouter has no embeddings here: semantic
search needs a local model or TEI, and the Semantic Search step says how. `drgnx onboard` runs in batch Emacs and
never reads the Keychain or keyring, so there it asks for no key: set `OPENROUTER_API_KEY` for the CLI, or run the
step in the drgnx app.

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
board, the daemon files, step 7 on macOS and on Linux with its question, the first window's Welcome, the whole flow
twice, the CLI), `test/unit/macos-test.el` (the applet's quoting, the document types, the app built with fake
`osacompile`/`plutil`/`codesign`/`lsregister`), `test/unit/ai-onboard-test.el` (the AI step against a mock model server: roles set and tested, a working choice kept, nothing running; setting AI up on a pretend Mac with fake `brew`, `ollama`, `lms`, `open`, `sysctl` and `security`, the fake servers being the mock: the room and the models for it, Ollama and LM Studio installed, started, downloaded, every feature tested, LM Studio without `lms`, the OpenRouter key into the Keychain and none asked in the CLI, a failed download and the run after it, nothing installed without interaction) and `test/live/drgnx-onboard-test.el` (a fresh GUI
session onboards non-interactively; the board has the projects and TODOs, no step or doctor check fails, Welcome
opens in the editor, a second run changes nothing).
