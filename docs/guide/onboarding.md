# Onboarding

`drgnx onboard` takes a fresh machine to a working drgnx; in Emacs, **Help → Welcome** (palette: "Welcome") lists
the same steps with their status — Return (`RET`) on a step runs it. Every step is a command of its own ("Onboarding: Import
Projects"…), can be run again at any time, and changes nothing the second time — with no option given, a step keeps
your current choices. Progress is kept in `~/.local/state/drgnx/onboarding.eld`: `drgnx onboard` resumes at the
first step not done (`--again` runs every step; `--step ID` runs that one), and a step that fails is shown failed
with how to fix it — it never stops the others.

**The first start opens the Welcome by itself.** When drgnx's first window shows and onboarding has never run on
this machine (no `onboarding.eld`), the Welcome opens a moment later — from a timer, after your layout is back; it
asks nothing until you run a step. It does this once: opening it leaves `onboarding.eld` behind (with no step done),
so later starts open as you left them. Help → Welcome brings it back at any time.

**New to Emacs? (coming from VS Code)**

- **Run the steps from the top** (the Welcome's header line says so): the cursor starts on the first step; press
  **Return** to run the step under it, and when it is done the cursor moves to the next one. Each step's status and
  result show on its row.
- **Questions appear on the line at the bottom of the window** (Emacs calls it the *minibuffer*): `y` or `n` for
  yes/no; a choice lists its answers and its default in the question itself — e.g. `Set up AI with (ollama,
  lmstudio, openrouter, skip) (default ollama):` — type one (Tab completes it) and press Return; Return alone takes
  the default. An answer that is not one of them is refused, never taken for one.
- **Ctrl+G** (written `C-g`) is Emacs' cancel: it closes a question, or stops what a step is doing. Escape closes a
  question too.
- **When the steps are done, restart drgnx:** the modules and packages a step turned on or installed load at the
  next start (a running drgnx keeps what it loaded). The Finish step offers it — "Restart drgnx now? Your windows
  come back." — or quit drgnx (⌘Q on a Mac, or File → Quit drgnx) and open it again.
- Words you will meet: a *buffer* is the contents of a tab (a file, a terminal, a list like this one), a *frame* is a
  window of the app, and a *window* is a pane inside it (a split). Keys are written the Emacs way: `C-` Ctrl, `M-`
  Option (Alt on Linux), `s-` Cmd, `S-` Shift — so `s-P` is ⌘⇧P, and `M-x` (Option+X) runs a command by name, as the
  palette does. The Mac keys: [keys.md](keys.md#on-a-mac).

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
| Look and Keys | the key profile (VS Code, Emacs, Vim, combinations), a colour theme, and the module preset: **minimal** (the workbench and built-in modules), **ide** (plus the package-backed editing modules — not AI), **full-ai** (everything; a fresh install is full-ai, the default answer — a mix of your own is kept unless you pick a preset). Your own module choices outside `extra/` stay. **On a Mac with VS Code's keys** it also asks "Left Option key (types characters: @ # { [ on German, French, … keyboards) (types characters, Meta)" — **types characters** makes the left Option type them (Option+←/→ still move by word), **Meta** keeps it Meta ([keys.md](keys.md#on-a-mac)); Return alone gives the answer saved in `keys.eld` (Meta before you have answered), so running the step again shows your current choice; never asked with `--non-interactive`. Change any of it later: Preferences: Keyboard Profile, Color Theme, Modules. **Then the packages:** when the modules now on need packages that are not installed, run interactively it asks "Install the packages for full-ai now (about N MB)?" — the size is the sum of the downloads your lock (or, before your first sync, the [lock drgnx ships](packages.md#the-lock-drgnx-ships-your-first-sync)) records, left out when it does not know one; Git clones are not counted. Yes runs `drgnx sync` as a drgnx job with its own log, its row showing the package it is at ("installing magit-4.7.1… — C-g stops"); a sync that fails makes the step warn with why, the log, and to run `drgnx sync` again; `WARNING … no longer served; installed …` lines in its log are not failures (a shipped version the archives dropped, replaced by the current one — [packages.md](packages.md#the-lock-drgnx-ships-your-first-sync)). The modules and packages load at drgnx's next start: when it installed packages or changed the preset, the result says "restart drgnx to load the new modules", and the Finish step offers the restart. With `--non-interactive`, or when you say no, nothing is installed and the result says to run `drgnx sync` |
| Import Projects | finds git repositories under `~/workspace`, `~/code`, `~/src`, `~/projects`, `~/git` (or `--roots`) and in gryphn's `~/.config/gryphn/projects.tsv`; you pick (empty: all; `(none)`: none; several are separated by a comma, or by `;` or `|` when a path has a comma — the prompt says which). Each goes on the **board**; you choose which projects also bring their open TODOs (`--todos`: all of them; default: none) |
| AI Providers | finds the model runners running here (Ollama, llama.cpp, LM Studio, vLLM, … — [ai.md](ai.md)) and the providers you have a key for, picks a model for each role (Inline Completion prefers a code model; Edit and Chat prefer OpenRouter when it has a key), makes one test call per role and sets only the roles that answered — a role you chose that still answers stays; a provider that does not answer changes nothing in `ai.eld`, and the look-around and the three calls share eight seconds: the three calls start together and are waited for once, so a model that is slow to load gets the whole of what is left, not a third. A role whose call has not answered by then reads "not tested (out of time)" — it is neither counted as asked nor as failed, the step warns, and the interactive step does not offer "Set up AI with" because of it (run it again once the model is loaded). It also reports the GPU's free memory (on a Mac: two thirds of the RAM, which Apple silicon shares with the GPU). **When nothing answers, it sets AI up** ([below](#setting-ai-up)); run again, it asks whether to keep what works or change it. With `--non-interactive` it installs, downloads and asks nothing: it reports what it found and the commands that would set AI up. Change a role later: AI: Choose Provider/Model |
| Semantic Search | the same as **Set Up Semantic Search** ([search.md](search.md)). Run interactively (Help → Welcome) it finds an embedding model, tests it with one call and starts indexing the current project in the background — or, when that index is current, runs a test query. With `--non-interactive` it only reports: whether an embedding model is running (and how to start TEI or Ollama if not), and how many of the projects drgnx knows have an index; it starts nothing |
| Agents | sets up **Claude Code** for the agent panel ([below](#setting-claude-code-up)): `claude`, Node and the `claude-agent-acp` adapter installed if missing (asked first), your own login in a terminal, the `claude` agent profile started and checked. With `--non-interactive` it installs nothing and lists the commands that would set it up |
| Daemon and Desktop | first asks once: "Keep drgnx running in the background when you close its last window? (recommended, like VS Code)" — yes keeps it running (reopening is instant), no quits it with its last window ([opening.md](opening.md#keep-running-or-quit)); saved in `~/.config/drgnx/session.eld`, changed later with Preferences: Keep drgnx Running in the Background. With `--non-interactive` nothing is asked: the choice made before stays, else drgnx keeps running. Then, **on macOS:** the drgnx app — if `~/Applications/drgnx.app` is missing, it offers to install it ([opening.md](opening.md#on-macos-the-drgnx-app)); with `--non-interactive` it installs nothing and says how (`drgnx macos-app`). No systemd, no desktop entry, nothing starts at login. **On Linux:** writes `~/.config/drgnx/systemd/drgnx.service` and `~/.config/drgnx/applications/drgnx.desktop` and prints how to install them (and `EDITOR`/`VISUAL`); run interactively, it installs them into `~/.config/systemd/user/` and `~/.local/share/applications/` if you say yes. The result says the choice and where to change it, then names the terminals drgnx works best in ([terminal.md](terminal.md)). Run from a terminal window it adds that terminal's row (what works, what it keeps, the lines that fix it); in a terminal that cannot send every key (GNOME Terminal, Ptyxis, Terminal.app) it ends with what to install for this system (for example `sudo dnf install foot` on Fedora) and the Alt+Shift and F6 keys that work meanwhile. It only says; drgnx never installs a terminal and the step asks nothing about it |
| Portability | lists chezmoi and age; setting up a second machine is documented with the platforms milestone |
| Finish | runs `drgnx doctor` and says what is left; on a Mac with the drgnx app in `~/Applications` it adds how to open drgnx next time (Spotlight, Launchpad, the Dock) — without the app that sentence is left out. When a step turned modules on or installed packages in this drgnx, it asks (in the drgnx app) "Restart drgnx now? Your windows come back." — yes first asks what quitting asks (save changed files, losing unsaved changes, stopping programs still running — a no or `C-g` there keeps drgnx running and starts nothing), then starts `drgnx open` in the background, to run once this drgnx has ended, and quits (when drgnx runs as the `drgnx` systemd service, that waiter runs as its own short-lived user unit, `drgnx-restart-<pid>`, so stopping the service does not stop it); no: the result says "Quit drgnx (⌘Q on a Mac) and open it again to load your modules". From `drgnx onboard` nothing is asked |

## Setting AI up

When no role has a provider that answers (or you run the step again and choose **Change**), the AI step asks:
**Set up AI with (ollama, lmstudio, openrouter, skip)** — Ollama or LM Studio run models on this machine, OpenRouter
in the cloud with a key. Return alone takes the default: `ollama` when models get at least 10 GB of room here (the
GPU's memory; on a Mac two thirds of the RAM), else `openrouter`; never `skip`. Whatever you choose, it ends
by testing every AI feature against what it just set up — one call each for Inline Completion (`complete`), Edit with
AI (`edit`) and Chat (`chat`), one embedding when it set the `embed` role, and Ask the Codebase over a small temporary
project (its own retrievers, then the chat model) — and says which answered.

**Ollama or LM Studio (local).** First it says, in one question, everything it would run and about how much it would
download (on a re-run, only the models the server does not list yet count); nothing happens until you say yes.

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

Every command runs as a drgnx job with its own log. While the step works, its row in the Welcome says what it is
doing — "Starting Ollama…", the download's last log line (without colour codes or progress redraws), "Testing every feature…" — always with "— C-g stops", and
Ctrl+G (`C-g`) stops it. A model download, like the package sync, has no time limit (other commands give up after an
hour): `C-g` is how you stop a slow one, and in `drgnx onboard` Ctrl-C stops the job it waits on. A download that fails says which model, why (the log's last line), where the log is, and to run the
step again — a new run starts from the top, skips what is installed and running, and `ollama pull` / `lms get` skip
what is already downloaded.

**It keeps running.** The server is a drgnx job, and drgnx remembers the runner it set up (`ai-local.eld` in the
state directory). After a restart, a moment after drgnx's first window opens, drgnx asks that runner's address in
the background; if nothing answers and no drgnx job runs it, it starts it again (`ollama serve`, or `lms server
start` — without `lms` it says to open LM Studio) and says so once: "Starting Ollama…". A request that finds nothing
listening there (a crashed server) does the same, at most once a minute. Nothing starts at login or when the drgnx
daemon starts — only once you open a window — and nothing is ever asked.

**Chat needs its module.** Chat is gptel, module `extra/llm`, which the `minimal` and `ide` presets leave off. The
step checks it: run interactively it asks "Turn on Chat (module extra/llm)?", turns it on and, when gptel is not in
drgnx's packages yet, installs it (`drgnx sync` as a job, as Look and Keys does); Chat then works from the next start
(the result says so, and in the app the Finish step offers the restart; in `drgnx onboard` it says "loads at drgnx's
next start", since Finish offers nothing there). A module that is already on with gptel installed but not loaded yet
says the same, and asks for no restart. A module that is on with gptel not installed yet is reported with "run drgnx
sync"; with `--non-interactive` an off module is reported as "Chat needs module extra/llm
(Preferences: Modules)" and the step warns.

**OpenRouter (cloud key).** In the drgnx app it asks for your key (`read-passwd`: never shown, never written to a file
or log; the string you type is cleared once it is stored, but drgnx keeps one copy of the key in memory for the session) and keeps it in the macOS Keychain or your Linux keyring
([ai.md](ai.md#keys)); when `OPENROUTER_API_KEY` is set in the environment, that key wins over the stored one, and the
result says so; then Inline Completion gets
`qwen/qwen-2.5-coder-32b-instruct` and Edit and Chat `openrouter/auto`. OpenRouter has no embeddings here: semantic
search needs a local model or TEI, and the Semantic Search step says how. `drgnx onboard` runs in batch Emacs and
never reads the Keychain or keyring, so there it asks for no key: set `OPENROUTER_API_KEY` for the CLI, or run the
step in the drgnx app.

## Setting Claude Code up

The Agents step makes the built-in `claude` agent profile work: Claude Code through `claude-agent-acp`, signed in
with **your own Claude login** (subscription or API key) — drgnx never reads Claude's tokens or credentials files.
Only a `claude` on your `PATH` (or in `~/.local/bin`) counts: the copy bundled in a VS Code extension is not used.
When something is missing it asks once, listing every command, and runs nothing until you say yes (when `claude`
itself is missing the question also says that a `claude` inside a VS Code extension does not count):

| | macOS | Linux |
|---|---|---|
| Claude Code (`claude`) | `brew install --cask claude-code` | Claude's official installer, `curl -fsSL https://claude.ai/install.sh \| bash` (into `~/.local/bin`, no `sudo`) |
| Node.js, for the adapter (only when `claude-agent-acp` is missing too) | `brew install node` | your distro's package — `sudo dnf install nodejs npm`, `sudo apt-get install nodejs npm` or `sudo pacman -S nodejs npm` — which needs `sudo`: drgnx copies the command for you to run in a terminal and waits for `npm` to show up (up to ten minutes; `C-g` stops) |
| The adapter (`claude-agent-acp`) | `npm install -g @zed-industries/claude-agent-acp` (with Homebrew's Node; any other Node, which has a global directory that is not yours, gets `--prefix ~/.local` as on Linux) | `npm install -g --prefix ~/.local @zed-industries/claude-agent-acp` (no `sudo`: a system Node's global directory is not yours) |

The commands that need no password run as drgnx jobs with a log and progress in the Welcome (`C-g` stops them). If
one fails, the result says why (the log's last line), where the log is, and how to retry — run the step again, or
the command in a terminal (for Claude's installer on Linux and the adapter the result names that command); a new
run skips what is installed. `C-g` while the login is being checked ends the check and stops the step. Where the adapter or Node ends up outside your
`PATH` (`~/.local/bin`, or beside Homebrew), drgnx adds that directory to the end of the `PATH` of the running Emacs (a program you chose earlier on the
`PATH` keeps winning) and says so; put it in your shell's `PATH` too for the next start. The agent panel's sessions run in drgnx itself and see it at
once; the **hub** (durable sessions, [agents.md](agents.md#the-hub-and-the-gateway)) keeps the `PATH` it started with:
when the step added a directory and a hub runs, its result says so; run `drgnx hub stop` — it ends the hub's durable sessions — and the
next durable session starts a hub that finds the new programs.

**The login.** The step asks `claude auth status` (exit status and its `loggedIn` answer only). When Claude Code is
not logged in — or this `claude` has no `auth status`, in which case drgnx cannot tell and offers the login anyway —
it asks to open a terminal running `claude`. The terminal's header line says **Type /login, finish in the browser,
then press Return on the Agents row in the Welcome (Done)**. The step does not wait for you: it ends as "info", and when you are logged in, press
Return on its row in the Welcome (that is Done — it runs the step again) and it goes on. Declining the offer when
drgnx could not tell still checks the agent; the result says the login was not verified. It never fails the step on
that alone.

**The check.** With Claude Code logged in, it starts the `claude` profile's program (`claude-agent-acp`, or what
your `agents.eld` says), sends the ACP `initialize` request, waits up to ten seconds for the answer and stops it
again — `ok` when it answers; otherwise the step fails, saying whether the program ended at once (with the end of
its error output) or did not answer. Then Agents: New Agent Session… starts it in the agent panel
([agents.md](agents.md)).

**The defaults for your agents.** Once the check is `ok`, run interactively, the step asks three more things and
saves the answers in `agents.eld` ([agents.md](agents.md#what-agents-get)): the **default agent profile** (what Agents:
New Agent Session… offers on Return; Return alone keeps the one you have), whether the agents drgnx starts get its
**coordination tools** (tasks, messages, the decision log; on until you say otherwise) and whether they get its
**search tool** too (off: it lets an agent read the indexed code of all your projects). The result names the answers.
Running the step again shows your current answers. An `agents.eld` that cannot be read is left alone and the result says
so. `drgnx onboard --non-interactive` asks nothing and changes nothing.

With `--non-interactive` nothing is installed, no terminal opens, no question is asked: the step is "info" and lists
exactly the commands that would set it up; when everything is installed it only checks the login and the agent.

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
twice, the CLI; the Agents step on a pretend Mac and a pretend Linux with fake `brew`, `npm`, `curl`, `claude` and the
mock ACP agent as `claude-agent-acp`, on a PATH of fakes only: the commands in order and asked once, nothing run
without interaction or a yes, Linux's installer and the `sudo` Node left to you, a VS Code extension's `claude` not
counting, the login terminal and its header, a `claude` with no `auth status`, the profile answering, dying and
silent, an npm failure and its retry), `test/unit/tty-onboard-test.el` (the daemon step's terminal paragraph: no terminal frame, a kitty's row, a VTE on a pretend Fedora 45 with the recommendation and no installer run), `test/unit/macos-test.el` (the applet's quoting, the document types, the app built with fake
`osacompile`/`plutil`/`codesign`/`lsregister`), `test/unit/ai-onboard-test.el` (the AI step against a mock model server: roles set and tested, a working choice kept, nothing running; setting AI up on a pretend Mac with fake `brew`, `ollama`, `lms`, `open`, `sysctl` and `security`, the fake servers being the mock: the room and the models for it, Ollama and LM Studio installed, started, downloaded, every feature tested, LM Studio without `lms`, the OpenRouter key into the Keychain and none asked in the CLI, a failed download and the run after it, nothing installed without interaction, the progress row, Chat's module asked for or reported, the runner started again when it is down or refuses — not when it answers or a job runs it, at most once a minute, never in batch) and `test/live/drgnx-onboard-test.el` (a fresh GUI
session onboards non-interactively; the board has the projects and TODOs, no step or doctor check fails, Welcome
opens in the editor, a second run changes nothing).
