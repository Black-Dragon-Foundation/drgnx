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
  asks you first: a card in the Work space, and nothing is written until you answer.
- It never marks a task done, approves a record, pushes, merges, starts or steers agents, spends, or changes
  settings, whatever the matrix says for its role.
- It never runs drgnx jobs: you start those, and drgnx's own agents run them.
- Its decisions are always proposals, and each names where it comes from.
- Every change it makes is its own entry in the history, so `ratatoskr graph revert --tx N` undoes it.

When a bound tool is refused, the answer says why and what to do instead; an unbound agent is told the
`ratatoskr outside bind` command to ask you for.

## Known limits

- After you answer a card for an outside agent's change to a record it did not create, its retry asks again with a
  new card: such a change cannot go through yet.
- "Its own" records are those made by the same agent process; a new Claude Code session is a new process, so
  yesterday's plans count as another's.
- Two MCP connections from one agent process share one identity; the folder of the latest one counts.
