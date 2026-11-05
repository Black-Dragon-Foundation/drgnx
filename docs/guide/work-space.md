# The Work space

The Work space shows what your agents are doing in one place. This page grows with the feature; today it covers
opening the map, and the machines and files the hub knows about.

## Opening the map

**Open the Work Space** (`work-view`; VS Code `C-k t`, Emacs `C-c w w`, Vim `SPC a w`) opens the map of the project
of the frame you are in. A *workspace* is the project's repository and, when it lies inside another repository (a
notes repository with the code repositories inside it), that repository and the repositories directly inside it. To name
the repositories yourself, set `drgnx-work-space-roots`.

The map is a read-only buffer, `*drgnx work: NAME*`, in six layers: you asked, specs, plans, agents, branches, and
files and machines. The hub keeps what the map shows and sends changes as they happen; the map never asks again until
the hub restarts. If the hub goes away the map keeps what it showed and says "reconnecting" in its mode line, and it
subscribes again by itself when the hub is back. A map no window shows costs nothing: the hub sends it no changes, and
it is drawn again when you show it.

Outside a project (a scratch buffer, a folder that is not in git) the map is empty and says so.

The colours are the theme's: the map's faces (`drgnx-work-dim`, `drgnx-work-card`, `drgnx-work-selected`,
`drgnx-work-chain`, `drgnx-work-overlap`, `drgnx-work-needs-you`, `drgnx-work-edge`, `drgnx-work-edge-strong`,
`drgnx-work-label`, `drgnx-work-chip`, `drgnx-work-new` and `drgnx-work-agent-1` to `-6`) inherit stock faces and carry
no colour of their own. The Work tab that used to sit in the right dock (`work-view` as "Show Work") is gone; the Work
graph (`work-graph`) stays until the cockpit retires.

## Machines

The hub lists the machines agent work can run on:

- **`local`** is the machine the hub runs on. It is always listed. Its slots are the places an agent's job can run
  at once; a slot a job holds shows as held by "job".
- **Other machines** appear when something reports them, and stay for the time the report says (its `ttl`). A machine
  that stops reporting leaves the list after that time. The job queue (`jobq`) reports its desktop and laptop slots.

Report a machine from a terminal:

```sh
ratatoskr machines report --machine desktop --ttl 60 --json slots.json
```

`slots.json` is a list of `{"id": "d1", "kind": "agent-job", "holder": "job-7"}` (`holder` is left out for a free
slot), or an object with that list under `slots`; `-` reads it from standard input, and without `--json` the machine
has no slots. The command exits 0 when the hub took the report, 1 when the hub refused it (the machine name `local` is
the hub's own), and 2 when the arguments or the slots do not parse.

Only you can report machines: an agent's connection to the hub is refused (`not-allowed`).

## What an agent changed

For a session the hub is running, the Work space can list the files it edited, with the lines added and removed, show
one file's changes, and show a file as it was after an earlier step. Every number is measured against the folder as it
was when the session started (or when the hub made its worktree). A file the agent created is listed as new. Nothing is
asked of the agent's own folder: the hub compares its own snapshots of it. Before the agent's first edit the list is
empty.
