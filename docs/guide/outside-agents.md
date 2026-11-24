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
- It never marks a task done (unless you gave it a `status.done` write grant, below), approves a record, pushes,
  merges, starts or steers agents, spends, or changes settings, whatever the matrix says for its role.
- It never runs drgnx jobs: you start those, and drgnx's own agents run them.
- Its decisions are always proposals, and each names where it comes from.
- Every change it makes is its own entry in the history, so `ratatoskr graph revert --tx N` undoes it.

An agent can ask what the grants you made let it do: its tool `my_grants` lists the active grants that apply to it (its
kind's, any outside agent's, its project's) and no one else's; `ratatoskr graph grants show WHO` shows you the same set for
an agent (`--project P` and `--profile NAME` add the project and profile it works under).

Lists the agent reads (`task_read` find, ready and mine, `graph_read`) come back as a one-line header ("3 tasks (rows
in the structured result)") and the rows in the tool's structured result, so each row costs the agent's context once.
Resource links to the entities are sent only when the agent asks for them with `links: true`.

When a bound tool is refused, the answer says why and what to do instead; an unbound agent is told the
`ratatoskr outside bind` command to ask you for.

## Answering and closing from a terminal

What an agent asks, and the closing of work, is yours; these commands do it without the editor. Each one calls the
hub's own method, so the checks are the hub's. `--json` prints the answer as JSON; exit 0 means it did what you asked.

```sh
ratatoskr card list --open                 # what waits for you: questions, access requests, changes
ratatoskr card settle 12 yes               # answer card 12 (the choices are the card's own)
ratatoskr message send agent:s-3 "go on"   # write to an agent as yourself
ratatoskr message reply 41 "use the new API"   # answer a question message: it goes to the asker
ratatoskr task status task:aa-00001 done   # set a task's status (a status the tracker knows)
ratatoskr plan status plan:aa-00002 3 done # set a task of a plan; done also ticks its steps in the file
ratatoskr records status                   # the record view files and their conflicts
ratatoskr records conflict spec:aa-00004   # a conflicted record: the file's text and the graph's
ratatoskr records resolve spec:aa-00004 --keep file   # keep the file's text (or `graph`: write the graph's back)
ratatoskr graph settings only-user-closes on          # "only I close my tasks" (no argument shows it)
```

- Write grants: with none, an outside agent has exactly the rights above. You can give one more, as narrow as you like:
  who (`agent:ID`, `kind:claude`, `any-outside`), where (a project, `plan:ID` or `task:ID` and everything under it), what
  (`create`, `update.title|body|acceptance|priority|labels`, `status.<status>` with `status.done` its own right,
  `note`, `link`, `split`, `claim`) and until when. `parked` is yours alone and cannot be granted. Every change is a
  user entry in the history, and an outside agent can never make or edit one.

  ```sh
  ratatoskr graph grants grant --who kind:claude --where plan:aa-00002 --what note --what status.done --until 7d
  ratatoskr graph grants edit grant:xxxxxxxx --what note,claim --until none   # new operations; `none` removes the expiry
  ratatoskr graph grants list [--who W] [--json]      ratatoskr graph grants revoke grant:xxxxxxxx
  ratatoskr graph grants show ext:claude:4242-ab      # the active grants that apply to one agent
  ```

  A revoke or an expiry takes effect on the agent's next write. While "only I close my tasks" is on, `status.done`
  grants do nothing (the agent proposes the close, as before). Outside agents read their own grants.
- A card settles once; settling one that is not open says so and exits 1. An agent's change card (it wants to write a
  record that is not its own) is answered here too.
- A task that comes from a plan file (imported or scanned) changes only through `plan status`, which writes the file's
  ticks as well; `task status` tells you which file it comes from.
- A task changed by someone since `task status` read it is refused with a conflict: run it again.
- `graph forget` retires what files that moved or were deleted still hold in the store (see `docs/develop/records.md`).

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
