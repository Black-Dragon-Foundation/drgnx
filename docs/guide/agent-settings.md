# Agent settings

**Agents: Settings** (module `tools/agent-settings`) shows one page per coding agent: Claude Code, Codex, Gemini and
Kimi Code. Each page has the routes to the models, then the agent's MCP servers, hooks and skills. You can add, edit,
remove and turn them on or off, and test them. The pages change the agents' own files. drgnx keeps no copy of these
settings.

Opening the page:

- From the Agents tab, `,` on a session's row opens the page of that session's agent, for its project (Agents:
  Settings of This Agent). Settings from a transcript does the same.
- Elsewhere, Agents: Settings (palette; `SPC a c` in the Vim profile) asks which agent, with Claude Code first. The
  page is for the project of the buffer you are in.

The page opens in the editor area as `*agent settings: Claude Code*` (or Codex, Gemini, Kimi Code). The agent names
at the top switch to another agent's page for the same project (also `TAB`, Other Agent…). The rules files
(`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`) come next, as links.

Opening the page and Refresh (`g`) only read files. They never start a server, run a hook or ask for a login. The
status is what the files tell: the file parses, the command is on `PATH`, the URL is set. Test does the rest, only
when you ask.

## Routes

One line per way to reach the models, with its base URL and model when it has them, where the key is kept, and how
it is billed:

| Billing | Meaning |
|---|---|
| flat: your subscription | the agent's own login (Claude, ChatGPT, Google, Kimi) |
| per token, billed by VENDOR | a direct API key of that vendor |
| per token through OpenRouter, plus its fee | an OpenRouter key |
| local: no cost | a model on this machine (Ollama, LM Studio) |

drgnx never reads, shows or copies a key. The line says where the key is: the agent's own login, an environment
variable, or your Keychain or keyring. A route whose key drgnx can keep has **[Store key…]**. It asks for the key with
the input hidden and stores it in the macOS Keychain or the Linux keyring ([ai.md](ai.md)).

A setting that overrides a route is shown in the warning colour. Examples: a Claude Code settings file whose `env`
sets `ANTHROPIC_BASE_URL`, or a Codex `model_provider` that replaces the ChatGPT login.

## MCP Servers, Hooks, Skills

One row per item:

- **name**, then **from**: `user`, `project`, `local` (Claude Code's private per-project scope), `plugin`,
  `extension`, `system` (managed settings) or `legacy` (the old kimi-cli files);
- **status**: `off` when it is turned off, `read-only` when the page cannot edit it (plugins, extensions, managed
  settings, a Gemini file with comments), `inactive` (a Codex project file of a project Codex does not trust), the
  file's own status (`ok`, `command not found`, `no URL`, `unreadable`), then the last Test with its age;
- **detail** under it: the command line or the URL, and the names of the environment variables and headers. Their
  values are never shown: an environment variable shows as `NAME=••••`, a header as `Name: ••••`.

A file that does not parse is listed under **Problems** with its line. drgnx never writes to it.

## Keys and buttons

The same keys in every key profile (VS Code, Emacs, Vim):

| Key | Command | What it does |
|---|---|---|
| `g` | Refresh | read the files again |
| `t` | Test | an MCP server: start it in a separate process and list its tools; a hook: run its command for real |
| `T` | Test All | test every MCP server on the page |
| `a` | Add… | add an MCP server, a hook or a skill (the section you are in) |
| `RET`, `e` | Edit… | change the MCP server or hook on this line (a skill: open its `SKILL.md`) |
| `d` | Remove… | remove the MCP server or hook on this line, after you confirm |
| `SPC` | Turn On or Off | an MCP server (Codex, Kimi Code) or a skill (Claude Code, Codex, Gemini) |
| `n` | New Skill… | a new `SKILL.md` with its name and description |
| `o` | Open Its File | the file this line comes from, at its line |
| `TAB` | Other Agent… | another agent's page, for the same project |

Every row has buttons for the same commands, and every section has **[Add…]** (Skills: **[New Skill…]**; MCP
Servers: **[Test All]** too).

## Adding and editing

Add asks, in the minibuffer:

1. where: the scope and its file (for Claude Code's MCP servers: User, Local or Project `.mcp.json`);
2. an MCP server: its name, the transport (`stdio`, `http`, `sse`), the command line (split as a shell would) or the
   URL, then the names of its environment variables (or headers) and each value. Values are read with the input
   hidden;
3. a hook: the event (from the agent's list), the matcher, the command and the timeout (seconds; milliseconds for
   Gemini).

Edit asks the same questions about the item on the line and writes to the file it is in. An empty answer keeps
what is there: the command line, the URL and, above all, each value ("empty: keep the current value"). The current
command line is shown with its secrets masked.

How each agent's files are written (one backup next to the file, key order kept, a file that changed meanwhile read
again) is in [develop/core.md](../develop/core.md). Claude Code's user and local servers go through `claude mcp`,
except when that would put a secret on a command line. Running agent sessions pick a change up when they start
again; the message after a write says so.

## Test

- **MCP server** (`t`, **[Test]**): drgnx starts a separate Emacs, which starts the server (or connects to its URL),
  asks for its tools and ends it. The editor never waits. The row shows "testing…", then `ok, N tools`, `failed: …`,
  `needs a login` (with the agent's way to log in) or `no answer (timed out)` after 20 seconds. Anything the server
  prints is masked before it is shown or kept.
- **Hook** (**[Test (runs the command)]**): this runs the hook's command for real, in the project, with a sample
  event on its input. It asks "Run COMMAND for real?" first. The row shows its exit status.

The last result of each item is kept, masked, in `agent-checks.eld` in drgnx's state directory, so the page shows it
again with its age.
