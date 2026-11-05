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

## Reads through shell commands

When an agent reads files with shell commands (`cat`, `sed -n`, `rg`, a script) rather than its own read tool, the
Work space still shows them, in two ways:

- **From the command:** the files a command names (`cat a`, `sed -n 1,5p b > c`), read from its text. This works for
  every agent and every machine. What a command builds at run time (`$(…)`, variables, `xargs`) is never guessed.
- **Seen open** (Linux): the files the command's processes actually opened, seen by the sandbox as they open them. It
  only watches: it never blocks or changes anything, and the command's output is the same. Writes seen this way are
  shown as "written by a command".

What "seen open" keeps:

- only files in the agent's folder, by their real names (a link that leads elsewhere is dropped);
- never what git ignores (build output such as `target/`), toolchain files (`~/.cargo`, `~/.rustup`, the mise
  caches) or system files (`/usr`, `/etc`, `/proc`);
- a file the command looked for that does not exist is left out.

Some commands are not watched, and their step says why:

- **"opens not traced for this build"**: builds and test runs (`cargo`, `make`, `ninja`, `cmake`, `npm`, `pnpm`,
  `yarn`, `go build`, `go test`, `pytest`, `podman`, `emacs`, `nidhogg` and every `bin/drgnx` command), and any command
  that once made its step more than a little slower (more than 5 % or 50 ms, whichever is more, and never more than
  250 ms). Such a command is not watched again in that folder while the hub runs.
- **"opens not traced for Codex: turned off in settings"** (or Gemini): Codex and Gemini can only be watched as a whole
  (every command they run pays for it), so they are off unless you list them in `drgnx-agents-trace-opens`, for
  example `("claude" "codex")`. Claude Code is watched one shell command at a time and is on by default.
- **"opens are not traced on macOS"**: macOS has no way to watch opens without root, so there you see the files
  commands name only.
