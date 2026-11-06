# Plugins, rules and hooks

Plugins give agents tools of their own (abilities) and shape what agents do (hooks). This page is being written:
it grows as plugins reach the hub. Today it covers installing and approving a plugin, how your rules and the plugins'
hooks decide a step, and choosing the plugins of one project.

## Installing and approving

A plugin is a folder with two files, `plugin.json` (what it declares) and `plugin.wasm` (the code). Nothing runs until
you have approved exactly those files.

1. **Install it:** `drgnx plugins install PATH` copies the folder into drgnx's data folder (`plugins/NAME/`, readable by
   you alone) and prints the plugin's hash. A plugin of the same name is not overwritten: give `--replace` to put the
   new files in its place. `drgnx plugins list` shows what is installed, and `drgnx plugins remove NAME` deletes it
   and forgets its approval.
2. **Look at it and approve it,** in the Extensions view's Plugins section (`C-S-x`) or in Settings → Plugins. A card
   in the agent views waits for you too. You are shown what the plugin declares: its abilities, the hosts it may
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
edit, which the Claude adapter reports as `other`, counts as `edit`.

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