# Runners

A runner is a machine that runs the hub's jobs: your desktop, a cloud machine, a Mac. You add one with
`drgnx runner add HOST --trust mine` and list them with `drgnx runner list`. Your own machine runs light jobs too.

## Disk

Every runner keeps its own disk in order. drgnx removes only what it made there and recorded, and never anything in
use: a running job's folder, its checkout and build folder, what a queued job will need, or what you pinned.

- **Below 80 GB free** the runner removes what has gone unused longest: finished job folders and outputs, then build
  folders unused for a day, then checkouts and caches unused for three days (recordings: 30 days), then images older
  than the newest two of each name.
- **Below 20 GB free** no new job starts there, and a running job that keeps filling the disk is stopped as
  `infra: disk`, never a red test. It runs again elsewhere or later.
- **Your quota.** To cap what drgnx keeps on a machine, put this in its `runner.conf` (in the runner's folder):

  ```toml
  [disk]
  quota_gb = 200
  ```

  Over the quota drgnx removes whatever isn't in use or pinned, oldest first, until it is under.
- **Removal is gentle.** While the disk is busy (IO pressure above 20 %) the runner waits, up to a minute, before
  each removal.
- **Your laptop** runs light jobs only and keeps 2 GB of memory for you. When your apps need memory, no job starts;
  when the machine runs short, drgnx stops its newest job and runs it again later.

See and steer it from a terminal:

| Command | What it does |
|---|---|
| `drgnx runner disk [NAME] [--json]` | each runner's free space, what drgnx keeps, your quota, btrfs's unallocated space, the use per kind (and how much may go now), and every item with its size and state: `active`, `idle`, `evictable`, `pinned` |
| `drgnx runner reclaim NAME [--dry-run]` | removes now what is past its age and not pinned or in use; `--dry-run` only lists it |
| `drgnx runner pin NAME ID on\|off` | keeps an item (its id from `runner disk`) whatever its age, or lets it go again |

A folder in the runner's folder that drgnx didn't make or record is listed and kept. On a btrfs disk `runner disk`
also shows the unallocated space, since the free space it reports may not all be usable.

## Projects

A runner takes only jobs of a **registered project**. You register a repository once, through the hub's methods:

| Method | Params | Does |
|---|---|---|
| `jobs/project-add` | `{path, name?}` | registers the repository `path` is in |
| `jobs/project-list` | `{}` | the registered projects: id, name, origin, root commits |
| `jobs/project-remove` | `{id}` | forgets a project and its clones |

The hub records the repository's root commits (every one: a repository may have several), its origin URL and the name
(default: the folder's), and gives the project an id. Every clone and worktree of that repository is that project: the
hub maps a clone (by its git folder, which all its worktrees share) to the project the first time it sees it, by the
same origin and a shared root commit, and afterwards checks the mapping with one object lookup, so a clone deleted and
replaced by another repository at the same path is looked up again. A fork with another origin is another project (its
caches are not the upstream's). Refused: a shallow clone (`git fetch --unshallow` first: its cut-off commit would look
like a root), the same repository a second time, and a name already taken. Only you register or remove projects; an
agent's connection is refused.

Feature opt-ins, and later allow-lists, budgets, caches and fairness, name a project by its id. A job's project comes
only from this registry, never from its folder's name or from what its job pack says (a pack whose `project` is not the
registered name is refused). A job whose tree is in no registered project still runs on this machine as before; it never
goes to a runner, and while it waits its row says so, with the command that registers it (or, for a shallow clone or a
clone that matches two projects, what to do).
