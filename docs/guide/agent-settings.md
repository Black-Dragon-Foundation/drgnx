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

An OpenRouter route also shows the **OpenRouter restrictions** (which providers it may use, whether they may keep data;
[ai.md](ai.md#openrouter-restrictions)) with **[Change…]**, the command **OpenRouter Restrictions…** (`r`). It asks for
the providers to use only, the providers to avoid (slugs, comma separated, empty for none), whether providers may keep
your data, and whether to use only zero-data-retention endpoints, and saves the answers as `:openrouter` in
`agents.eld`: one setting for every OpenRouter route. The restrictions apply through drgnx's gateway. When the hub
cannot be had, an agent with restrictions does not start rather than go direct without them. A value that is not a
restriction, or an `agents.eld` that does not read, shows *OpenRouter restrictions: unreadable* with the reason, and
OpenRouter agents do not start until it is fixed (**[Change…]** replaces a wrong value; a file that does not read is
fixed in the file itself). With the gateway turned off (`drgnx-agents-use-gateway`) and restrictions set, a Claude
Code route shows them followed by *the gateway is turned off, so OpenRouter agents do not start: turn it on
(drgnx-agents-use-gateway) or remove the restrictions*, with **[Change…]**. A route that goes direct (Codex, or the
gateway turned off with no restrictions) says *applies through drgnx's gateway only; without it, your OpenRouter
account settings apply* and links to `https://openrouter.ai/settings/privacy`.

A setting that overrides a route is shown in the warning colour. Examples: a Claude Code settings file whose `env`
sets `ANTHROPIC_BASE_URL`, or a Codex `model_provider` that replaces the ChatGPT login.

## MCP Servers, Hooks, Skills

One row per item:

- **name**, then **from**: `user`, `project`, `local` (Claude Code's private per-project scope), `plugin`,
  `extension`, `system` (managed settings) or `legacy` (the old kimi-cli files);
- **status**: `off` when it is turned off, `read-only` when the page cannot edit it (plugins, extensions, managed
  settings, a Gemini file with comments), `inactive` (a Codex project file of a project Codex does not trust), the
  file's own status (`ok`, `command not found`, `no URL`, `unreadable`; a relative command such as `./bin/server` is
  looked for in the server's `cwd`, else the project, else your home directory), then the last Test with its age;
- **detail** under it: the command line or the URL, and the names of the environment variables and headers. Their
  values are never shown: an environment variable shows as `NAME=••••`, a header as `Name: ••••`.

A file that does not parse is listed under **Problems** with its line. drgnx never writes to it.

## Keys and buttons

The same keys in every key profile (VS Code, Emacs, Vim):

| Key | Command | What it does |
|---|---|---|
| `g` | Refresh | read the files again |
| `t` | Test | an MCP server: start it in a separate process and list its tools; a hook: run its command for real |
| `T` | Test All | test the MCP servers the agent would start (see Test, below) |
| `a` | Add… | add an MCP server, a hook or a skill (the section you are in) |
| `RET`, `e` | Edit… | change the MCP server or hook on this line (a skill: open its `SKILL.md`) |
| `d` | Remove… | remove the MCP server or hook on this line, after you confirm |
| `SPC` | Turn On or Off | an MCP server (Codex, Kimi Code) or a skill (Claude Code, Codex, Gemini) |
| `n` | New Skill… | a new `SKILL.md` with its name and description |
| `o` | Open Its File | the file this line comes from, at its line |
| `r` | OpenRouter Restrictions… | which providers OpenRouter may use, and whether they may keep data |
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
   Gemini; `none` or `0` for no timeout).

Edit asks the same questions about the item on the line and writes to the file it is in. An empty answer keeps
what is there: the command line, the URL and, above all, each value ("empty: keep the current value"). The current
command line is shown with its secrets masked. To drop an environment variable or a header, take its name out of
the list of names.

The page itself never holds a value: it keeps only the names, and Edit and Test read the item from its file when
you run them. Text copied from the page (`M-w`, then yank) is plain text.

How each agent's files are written (one backup next to the file, key order kept, a file that changed meanwhile read
again) is in [develop/core.md](../develop/core.md). Claude Code's user and local servers go through `claude mcp`,
except when that would put a secret on a command line. Running agent sessions pick a change up when they start
again; the message after a write says so.

## Test

- **MCP server** (`t`, **[Test]**): drgnx starts a separate Emacs, which starts the server (or connects to its URL),
  asks for its tools and ends it. The editor never waits. The row shows "testing…", then `ok, N tools`, `failed: …`,
  `needs a login` (with the agent's way to log in) or `no answer (timed out)` after 20 seconds. Anything the server
  prints is masked before it is shown or kept. A server from the project's files, or an `inactive` one (for example
  from a Codex project you have not trusted), starts only after you confirm, with its command or URL shown.
- **Test All** (`T`, **[Test All]**): every MCP server the agent would start. Inactive and off servers are skipped
  (the message says how many). The project's own servers (from files in the project) start only after one question
  that lists their commands. Hooks are never run by Test All.
- **Hook** (**[Test (runs the command)]**): this runs the hook's command for real, in the project, with a sample
  event on its input. It asks "Run COMMAND for real?" first. The row shows its exit status.

A tested server or hook gets Emacs's environment without the model vendors' keys and switches, the same list agents
never inherit (`drgnx-agents-scrubbed-env`: `ANTHROPIC_*`, `OPENAI_*`, `OPENROUTER_API_KEY`, `MOONSHOT_API_KEY`,
`DEEPSEEK_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, …), so a project's server never receives your provider keys.
What the item sets itself (its `env`, `${VAR}` values, a bearer token from a variable) it gets; a hook also gets its
project directory variables.

What runs is what you confirmed: Test, Edit and Remove read the item from its file again, and if it is no longer
what the page shows (someone changed the file), they stop with "changed on disk: Refresh (g)". Test All skips such
a server and says so.

The last result of each item is kept, masked, in `agent-checks.eld` in drgnx's state directory, so the page shows it
again with its age. The file keeps the newest 300 results and drops those of settings files that no longer exist.

The page keeps no undo (it is drawn again whole), works in the project's directory (or your home directory when it
shows only your own settings) whatever buffer it was opened from, and Test All draws it once after starting the
servers, then again as each result comes.

## Tests

The GUI test `test/ui/editor-m11c2-test.el` (`drgnx test --ui`) shows the Claude Code page with every section (an
environment value masked, a note that a settings file overrides the routes), an MCP Test that passes against a mock
server and one that times out, and the Codex page, with screenshots. The perf workload `agent-settings-open` opens
the page on a 5 MB `.claude.json` with 50 servers and 200 skills: it must draw in under 150 ms and start no process
([perf.md](../develop/perf.md)).
