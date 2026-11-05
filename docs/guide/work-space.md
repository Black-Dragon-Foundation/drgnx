# The Work space

The Work space shows what your agents are doing in one place. This page grows with the feature; today it covers the
machines the hub knows about.

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
