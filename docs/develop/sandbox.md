# The job sandbox

## Git: worktree mode

Snapshot mode is the default. Worktree mode is opt-in: a profile's `:git worktree`, `drgnx job propose --git
worktree`, or the plan's `**Git:** worktree` line. One job uses one mode for all its tasks. `core/drgnx-job-worktree.el`
builds it. It makes the worktree and returns the binds as data; the sandbox applies them.

Each task gets a classic linked worktree that shares the repository's `.git`:

```
git worktree add -q -b job/ID-N/work <repo>/.claude/worktrees/ID-N refs/heads/job/ID
```

Why someone picks it:
- The task's branch is in the main repository the moment the agent commits. There is no bundle step.
- `git worktree list` shows every task.
- The user's own tools work in the folder: magit, `git log`, a shell prompt.
- There is no copy, even on ext4.

Git's security guidance is the rule here too: a `.git` an agent can write is untrusted, and git run in it runs that
agent's config and hooks. So the sandbox mounts the main `.git` **read-only**, except for what one worktree's commits
must write.

### The binds

`(drgnx-job-worktree-binds REPO FOLDER NAME ID N)` returns them in the order bubblewrap applies them. A later bind
covers an earlier one, so each pin comes after the writable directory it sits in. `GIT` is the repository's common
git directory; NAME is the worktree's directory in it (git names it after the folder, `ID-N`).

| # | Mode | Path | Why |
|---|---|---|---|
| 1 | ro | `GIT` | config, `hooks/`, `info/`, `packed-refs`, other refs, other worktrees |
| 2 | rw | `GIT/objects` | new objects: commits need it |
| 3 | rw | `GIT/refs/heads/job/ID-N` | its own branch `job/ID-N/work`, and no other ref |
| 4 | rw | `GIT/logs/refs/heads/job/ID-N` | that branch's reflog |
| 5 | rw | `GIT/worktrees/NAME` | its `HEAD`, `index`, `logs/HEAD` |
| 6 | ro | `GIT/worktrees/NAME/commondir` | pinned: where its repository is |
| 7 | ro | `GIT/worktrees/NAME/gitdir` | pinned |
| 8 | ro | `GIT/worktrees/NAME/config.worktree` | pinned; the hub makes it empty first |
| 9 | rw | `FOLDER` | the working tree |
| 10 | ro | `FOLDER/.git` | pinned: the `gitdir:` pointer |

- The branch is `job/ID-N/work`, so it is a file inside its own directory `refs/heads/job/ID-N/`. That directory is
  the only writable one among the refs. Every other branch, `job/ID` and `main` stay read-only. That includes the
  trick of writing a loose `refs/heads/main` that shadows a packed one.
- A bind mount point cannot be renamed or removed (EBUSY), so the pinned files stay.
- The main checkout is not mounted. Its untracked and uncommitted files (a `.env`) are not inside.
- The paths are true names. ID, N and NAME are checked first: an id like `../x` would widen the ref directory, so it is
  an error.
- `(drgnx-job-worktree-binds … t)` is the reviewer's: the same binds, every one read-only. The reviewer runs in the
  task's worktree.

The tests in `test/unit/job-worktree-test.el` assert this data: the order, which paths end up writable, and the
reviewer's. The escape tests prove under the real bwrap that each pinned path gives EROFS or EBUSY.

### Making the worktree

`(drgnx-job-worktree-add REPO FOLDER ID N BASE DONE)` runs `git worktree add` as a process of its own: the hub never
waits. Git runs in the main repository, with `core.hooksPath=/dev/null` and `core.fsmonitor=false`, as snapshot mode
does. Then, before any agent:
- it reads the worktree's NAME from `FOLDER/.git`, and keeps it only when that worktree's `gitdir` leads back;
- it makes `GIT/worktrees/NAME/config.worktree`, empty, so that it can be pinned. A file git copied there from the
  user's own `config.worktree` is kept;
- it makes the two ref directories (`drgnx-job-worktree-prepare`).

DONE gets `(:name NAME)` or `(:error MSG)`. A bad id or base, a folder that is there already, and a reftable
repository are refused before git runs.

Call `(drgnx-job-worktree-prepare REPO ID N)` before each start of the task's agent. `git pack-refs`, which `git gc`
runs, packs the branch and removes its now empty `refs/heads/job/` directories, and bubblewrap cannot bind a
directory that is not there.

### A reftable repository is refused

A repository on the reftable backend keeps every ref in one `reftable/` directory. It cannot be split into the
task's own branch and the rest. `(drgnx-job-worktree-refusal REPO)` returns the reason, from `git rev-parse
--show-ref-format` (git 2.45 or later) or else `extensions.refStorage`:

> this repository keeps its refs in reftable: worktree mode cannot limit the agent to its own branch; use snapshot mode

`drgnx-job-worktree-add` asks it before git runs.

### After each turn

`(drgnx-job-worktree-check REPO ID N BASE)` is t when `job/ID-N/work` still descends from BASE. It runs `git
merge-base --is-ancestor` in the main repository, whose config the agent cannot write. The loose ref file is the
agent's. So `(drgnx-job-worktree-tip REPO ID N)` reads it as a value: a regular file, not a link, holding 40 or 64
hex digits. A symbolic ref, a link or junk is nil. Without a loose file, it reads the line of `packed-refs`, which only
the user's git writes. Merge that commit, not the branch's name.

The check catches a rewound or replaced branch. It is not a guard against a hostile agent: the objects it reads are
writable.

### What it protects

- The main `.git/config`, `hooks/` and `info/` are read-only. Nothing the agent writes runs later outside the sandbox.
- Every ref but its own branch.
- The hub's socket, `~`, the user's sockets, `work.db` and the environment, as in snapshot mode.
- The main checkout's untracked and uncommitted files: they are not mounted.

### What it cannot protect

- **The repository's objects.** `objects/` must be writable for commits. A writable directory lets the agent delete or
  overwrite existing object files and packs. That means **data loss for anything not pushed elsewhere**, or a corrupt
  repository. The agent can also add `objects/info/alternates` entries, or a `commit-graph`. They inject objects or
  ancestry, but run no code.
- **Reading the whole repository.** The agent sees all history, all branches, unreachable objects (a file staged then
  unstaged, a dropped stash) and the main `config`, including remote URLs. A token in a remote URL is visible to the
  model.
- **Per-worktree state** (its index, HEAD, reflog, and a rebase, cherry-pick or `am` in progress) is the agent's. Git
  reads it only in that worktree, through the pinned pointers. **Neither continue nor abort an operation an agent left
  in progress in a task folder.** A rebase's todo list is the agent's, and its `exec` lines would run as you.
  `--abort` resets the branch its state names, which the agent may have set to `main`. Remove the worktree instead.
- **A nested `.git`** the agent creates in a subdirectory of the folder is a repository with the agent's config. The
  hub checks for one after each turn, as in snapshot mode.
- `git gc` of the user's while an agent runs can remove the branch's ref directory under it. The agent's next commit
  then fails to update its branch. The next start makes the directory again.
- Objects of an `objects/info/alternates` outside `.git` are not mounted. Git inside cannot read them.

### Risks, row by row

Snapshot mode against worktree mode (spec §4b):

| Risk | Snapshot (default) | Worktree (opt-in) |
|---|---|---|
| Agent-written config or hooks run outside the sandbox | no: git never runs in the copy outside the sandbox | no: main config and hooks read-only, pointers pinned |
| Other branches, `job/ID`, `main` moved | no | no: only its own `job/ID-N/` ref directory is writable |
| Repository objects deleted or corrupted | no: its own copy | **yes**: data loss for anything unpushed |
| User's uncommitted or untracked files (`.env`) seen | no | no |
| Remote URLs and their tokens seen | no: not in the store | yes: the main config is readable |
| The reviewer influenced by the implementer's git config | no: a fresh snapshot | no: the shared config is read-only |
| User's own tools (magit, `git` in a shell) in the folder | unsafe: the folder's `.git` is the agent's; drgnx keeps VC out | safe at the folder's root; never continue or abort an operation the agent left |
| Nested `.git` in a subdirectory | hub check and a card | hub check and a card |
| Branch visible in the main repository | after the bundle fetch | at once |
| `git worktree list` shows the task | no | yes |
| Disk and time to start | ≈ 0 extra disk with copy-on-write | ≈ 0: today's `worktree add` |
| Works on | btrfs, XFS, APFS (a shared clone elsewhere) | any filesystem; not reftable repositories |
