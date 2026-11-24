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
