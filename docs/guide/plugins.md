# Plugins, rules and hooks

Plugins give agents tools of their own (abilities) and shape what agents do (hooks). This page covers installing and
approving a plugin, what a plugin can and cannot reach, abilities, how your rules and the plugins' hooks decide a step,
choosing the plugins of one project, the hooks at each point, and what each agent provider gets today. To write a
plugin, see [develop/plugins.md](../develop/plugins.md).

## Installing and approving

A plugin is a folder with two files, `plugin.json` (what it declares) and `plugin.wasm` (the code). Nothing runs until
you have approved exactly those files.

1. **Install it:** `drgnx plugins install PATH` copies the folder into drgnx's data folder (`plugins/NAME/`, readable by
   you alone) and prints the plugin's hash. A plugin of the same name is not overwritten: give `--replace` to put the
   new files in its place. `drgnx plugins list` shows what is installed, and `drgnx plugins remove NAME` deletes it
   and forgets its approval.
2. **Look at it and approve it,** on the Plugins page: the palette command `Plugins…` (Settings → Plugins). A card
   in the agent views waits for you too, and the notice "Plugin NAME waits for your approval" opens the page. When the
   Extensions view is built it hosts this same page as a second door; it is not in drgnx yet. You are shown what the plugin declares: its abilities, the hosts it may
   reach over HTTPS, and for each hook the point, the verdicts it may return and the tools or paths it looks at.
   Approving sends the hash you were shown; if the files changed in between, the approval is refused and you look
   again.
3. **Put it on your plugin list** (`drgnx-agents-plugins`, in Settings → User), in the order you want its hook to run
   (after your rules). A plugin runs only when it is approved *and* listed.

A plugin is in one of five states:

| State | Meaning | Runs? |
|---|---|---|
| `unapproved` | installed, never approved | no; a card waits for you |
| `approved` | you approved the files that are on disk now | yes, where the plugin list names it |
| `changed` | the files on disk are not the ones you approved | no; a card asks again |
| `disabled` | you switched it off | no |
| `broken` | the manifest does not read; the page says why | no |

**A changed plugin stops at once.** Whoever swaps `plugin.wasm` (or edits `plugin.json`) after you approved it turns
the plugin into `changed`; no call reaches the new code. The page shows what you approved beside what the plugin asks
for now, so you can see what grew. Approve again, with the new hash, or remove it.

**The page (Settings → Plugins, command `Plugins…`, module `tools/plugins`).** One section per plugin: its state and
hash, its abilities, each hook with its point, the verdicts it may return and what it looks at, and for a hook that may
`change` what it may rewrite (a tool's arguments, "the file contents of writes", the commit message or the review notes);
the hosts it may reach; what it sees (diffs and file contents in the projects where it is enabled, which it may send to
its hosts; its key-value store, shared across those projects); and "In this project": whether it runs in the project
the page was opened from, that project's rules and the rules switched off there. `a` approves the plugin at point (the
hash that section displayed, never one fetched again), `d` disables it, `p` turns it on or off for the project (written
to your private workspace file: only you can set it), `g` reads the list again. The notice "Plugin NAME waits for your
approval" opens the same page. With the Extensions view on, Settings → Plugins and the notice open the plugin in
that view instead (see [Plugins in the Extensions view](extensions.md#plugins)); there, Replace and Remove are buttons.
Without it, replacing and removing a plugin stay in the CLI, and the page says how.

**Only you approve.** Approving and switching a plugin off are the user's own calls: no agent, no manager and no tool an
agent can reach can do either. The approval lives in drgnx's own store (not in a settings file), so a settings file
copied to another machine approves nothing.

**A plugin reaches only the hosts it declared, through drgnx.** Its HTTPS goes out from drgnx itself, never from the
plugin: to a host its manifest names, and, unless the session's network is `open`, one you also put on the `plugin`
tier of `drgnx-agents-net-hosts`. drgnx looks the name up once and refuses it when it leads to this machine, your LAN
(unless you pinned the name in `drgnx-sandbox-proxy-pinned-addresses`), a link-local or a metadata address. A refused
request fails in the plugin and shows in the session's events as a denied host (once per host per session), just as
the agent's own proxy reports one. A plugin's key-value store holds at most the `kv_bytes` its manifest declares (1 MiB
at most).

## What a plugin can and cannot reach

A plugin is a WebAssembly component that drgnx runs inside its hub, with these limits.

| It can | It cannot |
|---|---|
| read its own arguments (an ability call) or the step it was asked about (a hook), and answer | read your files, run a process, open a socket, read the environment or a secret |
| call HTTPS on the hosts its approved manifest names, from drgnx, on the `plugin` tier | reach a host it did not declare, an address on this machine or your network, or follow a redirect |
| keep a key-value store (at most its declared `kv_bytes`, 1 MiB at most) | see another plugin's store |
| see the diffs and file contents of the steps it is asked about, in the projects where it is enabled | run before you approved its exact files, or after they changed |

Each call gets a fresh instance with 64 MiB of memory and a time limit (a hook's is its point's, an ability's is 30 s);
a plugin that spins or traps is stopped and the step it hooked is refused, and the hub stays responsive. Plugins have
no files because they have no folder: drgnx grants none. Put what a plugin needs to know in its arguments or its store.

**Hooks never widen.** A hook may only narrow what the permissions matrix allows: its `allow` means "no objection" and
never answers a card for you, never turns a `never` into an ask. A test pins this at every point
([security.md](security.md#hooks-never-widen)).

**Rules are guardrails, not a boundary.** See [Your rules](#your-rules). A plugin's hook is code, so it can look at
more than a regex does, but it is still a check on top of the matrix and the sandbox, not a replacement for them.

## Abilities

An ability is a tool a plugin gives to agents. A session whose plugin list has an ability when it **starts** gets a
second tool server, `drgnx-plugins`, next to drgnx's own: its tools are named `PLUGIN_ABILITY` (an agent shows them as
`mcp__drgnx-plugins__PLUGIN_ABILITY`), with the description and argument schema from the manifest. Every agent profile
gets them, whichever provider it runs on.

- **Fixed at start.** An agent learns its tool servers when it starts, so a plugin you enable later reaches new
  sessions only; a running session shows a note that its plugins changed. Turning a plugin off or changing the list
  takes the abilities out of the list a running session is offered at its next connection.
- **Only what you grant.** A plugin's abilities are offered only while the plugin is approved and on the project's
  list, and only if the session's `plugin.abilities` cell in the permissions matrix is not Never. By default managers
  and workers may use them and a chat is asked each time (Cautious asks everywhere). Every call is checked again: a
  plugin you switched off, or a cell you set to Never, refuses the call.
- **Ask makes a card.** With the cell on Ask, a call shows a card naming the tool and the arguments it will run with,
  and waits for you with no time limit. Cancelling the call, or its connection closing, withdraws the card. The 30 second limit covers the plugin's own run, never the wait for you.
- **Arguments are checked** against the manifest's schema before the plugin sees them. The schema may use `type`,
  `properties`, `required`, `enum`, `items`, `maxLength` and `additionalProperties`, plus the notes `description`,
  `title`, `default`, `examples`, `deprecated`, `readOnly`, `writeOnly`, `$schema` and `$comment`; a manifest with any
  other keyword is refused when it is read.
- **Network** is the plugin's declared hosts, as above, and nothing else.

## In one project

The plugin list and your hook rules are yours alone. A repository's `.drgnx/settings.el`, its `.dir-locals.el` and an
agent cannot set `drgnx-agents-plugins`, `drgnx-agents-hook-rules` or `drgnx-agents-hook-rules-off`: a rule you rely
on cannot be taken away by the code it guards against.

In one project you may keep different choices, on the Workspace tab of Settings (they are saved in your private
workspace file for the project, never in the repository):

- `drgnx-agents-plugins` there **replaces** your list for that project: it can enable a plugin only there or leave one
  out. A plugin must still be approved.
- `drgnx-agents-hook-rules` there **adds** rules to yours for that project.
- `drgnx-agents-hook-rules-off` lists the `id`s of your rules that are switched off in that project. Only a rule with
  an `id` can be switched off.

## Rules and hooks

At four points the hub asks your **rules** and the enabled plugins' **hooks** about a step:

| Point | When | Its time |
|---|---|---|
| `before-tool` | before an agent's tool call runs | 2 s |
| `after-edit` | after an edit, before the hub writes a file for an agent | 5 s |
| `before-commit` | before the hub merges a task's commit | 10 s |
| `at-review` | before a task goes to its reviewer | 30 s |

`before-tool` and `after-edit` run today. `before-commit` and `at-review` can be declared and are checked, but the hub
does not call them yet: they arrive with the checkpoint and review work.

Each answers **allow** (no objection), **deny** (with a reason), **annotate** (a note shown under the step) or, where
the hub itself performs the action, **change** (a tool's arguments for the hub's own tools, the content the hub
writes, the merge commit's message, the notes for the reviewer).

**Rules first, then plugins.** Your rules run in list order, then each plugin's hook in the order of your plugin
list. Only the rules and hooks that match the step run.

- **The first deny decides.** Nothing after it runs, and the step shows the rules and hooks that were not run.
- **Changes chain:** each hook sees the step as the hooks before it changed it, and the last change is what runs.
- **Notes add up:** at most 8 per step, 2 KiB each, then a "+N more" line.
- **The time is the point's,** shared by every rule and hook: each hook gets its own deadline or what is left,
  whichever is smaller. A hook left with no time is not run ("not run: the point's time ran out (2 s)").
- **Failures refuse.** A hook that times out, crashes, is busy, answers with a change of the wrong shape or a
  verdict its manifest does not declare refuses the step ("hook NAME failed: …"). A hook declared advisory, and
  every hook that may only annotate, turns its failure into a note instead.
- **Hooks never widen** what the permissions matrix allows ([security.md](security.md#hooks-never-widen)).

### Your rules

A rule matches a point, and optionally tool kinds, path globs and a command, then denies or adds a note:

```json
[{"id": "no-rm-root", "point": "before-tool", "tool_kinds": ["execute"], "command": "^rm\\s+-rf\\s+/",
  "verdict": "deny", "reason": "no rm -rf on absolute paths"},
 {"point": "after-edit", "paths": ["**/*.lock", "migrations/**"], "verdict": "annotate",
  "reason": "a lock file or a migration changed"}]
```

**Rules are guardrails, not a boundary.** A command regex is easy to step around: `rm -r -f /`, `find / -delete`
or a command piped through base64 all pass the rule above. What an agent can actually reach is decided by the
permissions matrix and the sandbox ([security.md](security.md#the-permissions-matrix)); rules catch the common
mistake and tell the agent why.

| Key | Meaning |
|---|---|
| `point` | `before-tool`, `after-edit`, `before-commit` or `at-review` (required) |
| `tool_kinds` | the step's kind: `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`, or `drgnx` for the hub's own tools |
| `paths` | globs over the step's paths, relative to the project (an absolute glob starts with `/`): `*` and `?` stay within one folder name, `**` spans folders |
| `command` | a regular expression searched in the step's command (linear-time; at most 1 MiB compiled) |
| `verdict` | `deny` or `annotate`; rules never change anything (required) |
| `reason` | what the agent and you are shown, 1 to 1000 characters (required) |
| `id` | optional, `^[a-z0-9-]{1,32}$` and unique; only a rule with an id can be switched off for one project |

The keys AND together, and a key left out matches everything. A rule that does not check out (an unknown key, a
bad regex, an id used twice) refuses the whole list, naming the place (`[2].id`). A rule's verdicts are shown as
`rule:ID`, or `rule:N` by its place in the list.

**Kinds are the agent protocol's.** A kind an agent reports that is not one of the list above counts as `other`, and
only the hub's own servers say `drgnx`, so an agent cannot pass its step off as one of the hub's tools. A notebook
edit, which the Claude adapter reports as `other`, counts as `edit`. Kimi Code's and DeepSeek Harness's own tools
count by their names (`FetchURL`, `web_fetch` and `web_search` are `fetch`; `read` and `read_image` are `read`;
`glob` and `grep` are `search`; `bash` is `execute`; `edit`, `write`, `apply_patch` and `str_replace_editor` are
`edit`), and a request that names no kind takes the kind the agent gave the same tool call before.

## Before a tool call

The `before-tool` point runs where the hub sees an agent's tool call:

- **At the permission seam,** when the agent asks before one of its own tools runs. Your rules and the hooks run
  after the agent's freshness check and before the permissions matrix answers. A cell of `never` refuses at once,
  with no hook run. On `allow` or `ask` the hooks run first: a deny refuses the step with no card made, and only when
  none denied does the matrix ask you (a card) or let it run. A hook's `allow` never answers a card for you.
- **At the hub's own tools** (the coordination tools, and the plugins' abilities): once, at the hub's server, with
  the kind `drgnx` and the tool's full name (`mcp__drgnx__record_decision`). This is the one place a hook may
  `change` a call, and only for the tools its manifest names: the tool checks the changed arguments against its
  schema again, and a tool whose matrix checks are in its body (the manager's `merge`) checks what will run. The
  seam does not run the hooks again for such a step, but it still checks the step against the matrix, as it always
  did (`code.edit`); its row says "hooked at the hub's server".
- **Steps an agent allows itself.** Most agents run some tools without asking. When a rule or a hook of the
  session's plugin set looks at a kind, each agent's lock makes it ask about that kind too, so those steps reach the
  seam: Claude through managed ask rules (read → `Read`, `NotebookRead`; search → `Grep`, `Glob`, `LS`; fetch →
  `WebFetch`, `WebSearch`; execute → `Bash`, `BashOutput`, `KillShell`; edit → `Edit`, `Write`, `MultiEdit`,
  `NotebookEdit`; think → `Task`, `TodoWrite`; switch_mode → `ExitPlanMode`; other → its MCP resource tools), Gemini
  through an admin policy, Kimi Code through ask rules in its config, DeepSeek Harness through drgnx's ask plugin.
  Codex's shell steps reach the hooks through its managed hook ("hooked by the adapter"; it fails open on a timeout,
  while Codex's own approvals still fail closed). What can never ask is withheld (Codex's hosted web search, Gemini's
  subagents). An agent that would still run a subscribed kind unseen is not started, and the refusal names the kinds
  ([the security guide](security.md), "What each provider obeys"). The session shows which kinds are hooked and how.
  That these locks make the real CLIs ask is expected, and checked against mocks of them only so far.

What the agent is told of a refusal comes from drgnx, with the rule's or hook's words quoted: "drgnx refused Bash;
the hook deny-rm-hook said: «no rm -rf»". It is steered into the agent's running turn, so it does not retry. A note
shows under the step in the transcript. Each point run on a step is one record of the hub's own, with every rule and
hook that looked, what each said and how long it took; it is the step's provenance in the timeline.

**The plugin set is the session's start.** The hub reads your plugin list and rules at every step, but the lock's
ask rules are made when the session starts (a fork keeps its parent's): a hook enabled since then sees the steps
that reach the seam, and the session's marks say what it started with.

**A hook that hangs** is stopped at the point's 2 s, and the step is refused ("hook NAME failed: timed out"). The
session goes on.

## After an edit

The `after-edit` point runs off the agent's turn, in its own task: it never holds up the editor or the agent's other
requests, and it shares one 5 s budget. What it can do depends on who made the edit.

- **An edit the hub writes** (the agent's `fs/write_text_file` request): a hook may **annotate**, **deny** or
  **change** the content before it reaches the disk.
  - *Deny* answers the agent's request with the error `drgnx refused the write: REASON` and writes nothing.
  - *Change* writes the changed content, and the agent is told: "drgnx's hook NAME changed your write to PATH; read
    the file before editing it again".
- **An edit the agent made itself** (its own tools wrote the file): the file is already on disk, so a hook may only
  **annotate** or **deny**. A change is a failure of that hook. A deny steers the refusal to the agent, marks the step
  "refused by hook" in the timeline, and leaves the edit on disk and in the history. You can still accept it.
- A note is shown under the step.

**Which agents are changed.** `change` reaches only agents that write through the client. With Claude's adapter,
Claude Code makes its edits itself (the adapter's `writeTextFile` is a pass-through its tools do not call), so for
Claude a hook can annotate or deny but never change.

## In the agent views

- **Hook verdicts with provenance.** A refused step shows the rule or hook that refused it, with each source's verdict
  and time, and the notes under the step. A step an agent made itself and a hook denied afterwards is marked refused by
  hook.
- **Context breakdown.** The palette command `Context Breakdown…` shows what fills an agent's context, for an agent
  that reports it (below). Where the agent can drop or pin an item, the entries say so; where it cannot, they are plain
  text.
- **Plugins page.** `Plugins…`, as above. The page's keys: `a` approve, `d` disable, `p` turn on or off in this
  project, `g` refresh. Replacing and removing a plugin are CLI commands (`drgnx plugins install --replace`,
  `drgnx plugins remove`); the page shows the hint.

## What each provider gets today

Hooks run where drgnx sees a step. How much of an agent's work drgnx sees depends on the agent.

| Provider | Today | Arrives with the adapter forks |
|---|---|---|
| Claude (the org's `claude-agent-acp` fork) | every kind your rules and hooks look at is made to ask, so it reaches the seam; the panel extension reports the context breakdown and asks drgnx before a tool runs | `drop`, `pin` and `compact-preview` are not offered: the SDK cannot edit messages |
| Codex (the stock `codex-acp` adapter) | a config lock in Codex's read-only mode: edits and MCP tools ask, so they reach the seam; the shell steps its policy runs unasked go through a managed hook that asks drgnx first (`hooked by the adapter`: Codex lets the step run if drgnx does not answer in time); hosted web search is off | nothing: Codex keeps the stock adapter, so there is no context breakdown |
| Gemini, Kimi Code, DeepSeek Harness | a config lock that makes what it can ask; the session names the kinds that are hooked and those that are not ("not hooked: …"), and a session whose subscribed kinds cannot be hooked at all is refused with the reason | the forks are in progress and not promised here: each is to add the same panel extension (context breakdown and, where the agent allows, a request before a tool runs) |
| Gateway profiles (OpenRouter and API keys) | the same as Claude: they run through the Claude adapter | nothing |

Until a fork lands for a provider, expect "not hooked" marks for kinds its config cannot make ask, and no context
breakdown; Codex has no fork coming, so it never shows one. Abilities do not depend on the adapter: every profile gets them.

The managed ask rules for Claude are expected to make read-only commands ask; that has not yet been checked against
the real Claude Code, and the same goes for the lock formats of Codex, Gemini and DeepSeek against their real CLIs.
