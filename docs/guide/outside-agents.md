# Agents outside drgnx

Claude Code, Codex, Zed's agent or any other agent that speaks MCP can join drgnx's work from its own terminal or
editor. It connects to the hub with

```sh
<checkout>/bin/drgnx coord mcp --kind KIND
```

in its MCP configuration (KIND is a short lower-case name: `claude`, `codex`, `zed`…). Started in a project folder, it
gets an identity of its own (`ext:KIND:…`) and the reporting tools: `hello`, `report_edit`, `report_test`,
`ask_user`, `note_add`, the messages and the read tools. Everything it reports shows up in the Work space.

## Letting it work on plans and records

Out of the box an outside agent reads, reports and asks; it does not change your plans, specs or decision records.
You let it by binding its kind to a role in one project:

```sh
ratatoskr outside bind --kind claude --root ~/src/myproject --role worker
ratatoskr outside list
ratatoskr outside unbind binding:claude-0123456789ab
```

- `--root` is any folder of the project; drgnx binds the project's top-level (for a linked worktree, its main
  repository), so the binding covers every worktree of it. Your home folder, `/` and a folder outside any git
  repository cannot be bound.
- `--role` is a column of the permissions matrix: `worker` (the usual choice), `manager` or `chat`. A chat never
  changes anything.
- A binding is yours alone: no agent can write one, and one an agent's change touched no longer counts.
- An unbind applies at the agent's next call; it does not need to restart.
- `--json` prints the answer as JSON.

A bound agent also gets `plan_read`, `plan_write`, `records_read`, `records_write`, and `record_decision` for
proposals. It works in its own project only, and it follows the matrix like drgnx's own agents, with limits of its own:

- Its own plans and records it changes as its role allows. Changing one it did not create (yours, or another agent's)
  asks you first: a card in the Work space ("ext:claude:… wants plans/write on plan:…"), and nothing is written until
  you answer. Your yes lets that exact call through once: the agent is told, makes the same call again within the
  card's window (10 minutes by default, `agents-browser-once-window`) and it lands. A call with other arguments is
  another change and asks again; so does the same call after the window or after it went through once. Your no
  refuses that call for the same window, so a no given by mistake is undone by waiting: after the window the
  agent's retry makes a new card you can answer again.
- It never marks a task done, approves a record, pushes, merges, starts or steers agents, spends, or changes
  settings, whatever the matrix says for its role.
- It never runs drgnx jobs: you start those, and drgnx's own agents run them.
- Its decisions are always proposals, and each names where it comes from.
- Every change it makes is its own entry in the history, so `ratatoskr graph revert --tx N` undoes it.

When a bound tool is refused, the answer says why and what to do instead; an unbound agent is told the
`ratatoskr outside bind` command to ask you for.

## Known limits

- The card names the tool and the record, not the whole change; read the record (or ask the agent) before you say
  yes. A yes is used up by the retry even when the write is then refused for another reason (marking a task done,
  say).
- The binding counts only for a bridge that runs in the folder it names: on Linux and macOS drgnx reads the bridge
  process's working directory and compares it with that folder (symlinks resolved), at the connection and at every
  call, so a bridge started elsewhere, or one that moved, gets no rights and is told both folders. On other systems
  the folder is taken as the bridge names it. The kind (`--kind`) is the bridge's word: drgnx cannot check it, so a
  program running as you could start a bridge as another kind in a bound folder.
- "Its own" records are those made by the same agent process; a new Claude Code session is a new process, so
  yesterday's plans count as another's.
- Two MCP connections from one agent process share one identity; the folder of the latest one counts.
