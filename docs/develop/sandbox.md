# The job sandbox

## Git: snapshot mode

In snapshot mode, the default, each task of a job gets a `.git` of its own in its folder
`<repo>/.claude/worktrees/ID-N/`. `core/drgnx-job-snapshot.el` makes it. It is **never a copy of the user's
`.git`**. The user's `.git` holds what an agent must not read, and `git cat-file --batch-all-objects` or
`fsck --lost-found` lists all of it without knowing any object id:
- unreachable objects: a file staged and then unstaged, a dropped stash, a commit amended away;
- the other branches, tags, reflogs and the index;
- config that may carry tokens.

Git's own security guidance sets the second rule: a `.git` an agent can write is untrusted, and running git in it runs
that agent's config and hooks. So the hub runs git in a task's `.git` only **before** any agent has it. From then
on, git runs there only inside the sandbox.

### What the agent can see

In a task's `.git`, and nothing more:
- **The branch BASE** (`refs/heads/job/ID`) and every object reachable from it: the whole history of that branch,
  including anything ever committed to it. `HEAD` names BASE.
- **The objects of earlier BASE tips.** The job's store keeps them: BASE moves forward as tasks merge, and a
  force-moved BASE leaves its old tip's objects, which were the job's own.
- **A whitelist config** that the hub wrote (below).
- **A shared clone** (no copy-on-write) also has:
  - `refs/remotes/origin/job/ID`, at the same commit;
  - the clone's own reflog entry, which names the store's path;
  - read access to the store's objects, the same set as above.

Everything else stays out:
- the user's other branches, tags, stash, reflogs and index;
- unreachable objects;
- uncommitted changes and untracked files (`.env`, local keys);
- the user's hooks, remotes, credentials and other config;
- the user's linked worktrees.

The user's `.git` is never copied or mounted.

### The job's store

Once per job, the hub makes a **clean store** at `<repo>/.claude/worktrees/<BASE>.base.git`, where the `/` of BASE
becomes `~` (`job~ID.base.git`; `~` never appears in a branch name). It is made with:

```
git -c core.hooksPath=/dev/null -c core.fsmonitor=false clone -q --no-local --bare --single-branch --no-tags \
    --template= --branch BASE -- REPO STORE
```

- `--no-local` makes git transfer a pack through upload-pack, as from a server. Only objects reachable from BASE come
  through, so none of the user's unreachable objects, other branches or tags.
- `--template=` installs no hooks.
- The clone's config is then **replaced** with the whitelist.
- A bare clone writes no reflog.

The clone goes to `STORE.part`, which is renamed to `STORE` only once its config is written. A store that a stopped
job or a crash left half-made therefore never has the final name, and its `.part` leftover is removed before the next
build.

The store is hub-only. No agent mounts it writable, and nothing of an agent's reaches it. When BASE moves (a task
merged), the next task's snapshot first runs
`git --git-dir=STORE fetch -q --no-tags --no-write-fetch-head REPO +refs/heads/BASE:refs/heads/BASE`.
- The store is always named with `--git-dir` (or `config --file STORE/config`), never found by discovery.
  `safe.bareRepository=explicit`, git's hardening against embedded bare repositories, refuses discovery.
  Discovery from a wrong directory would also find the user's repository instead.
- The store's steps run one at a time: a fetch while a copy reads the store could give the copy a ref without its
  objects.
- Each turn is guarded. An error in any step, even a synchronous one (`.claude/worktrees` is not a directory), ends
  it with `(:error MSG)` and frees the store for the next turn.

### The task's copy

`drgnx-job-snapshot-make REPO FOLDER BASE DONE` makes the store, or fetches into it, and then the task's `.git`. It is
asynchronous, like every step here (separate processes with a deadline, so the hub never waits). DONE gets one of:

- `(:mode snapshot :read nil)`: a copy-on-write copy of the store. On Linux it uses `cp -a --reflink=always` (btrfs,
  XFS). On macOS it uses `cp -c -a` (clonefile, APFS). The store is inside the repository, so the copy is on the same
  filesystem.
- `(:mode clone :read DIRS)`: the fallback without copy-on-write (tmpfs, ext4, network filesystems, HFS+). It runs
  `git clone -q --shared --no-checkout --single-branch --no-tags --template= --branch BASE STORE FOLDER`. DIRS is the
  store's `objects`, which the sandbox mounts read-only. Never the user's.
- `(:error MSG)`: BASE is not a branch name, REPO is not a repository, FOLDER exists and is not empty, or the store
  failed twice.

In both modes, the task's config is the store's whitelist again, with `core.bare false`. Then
`cat-file -e refs/heads/BASE^{commit}` checks the copy. Nothing is checked out: the sandbox's first step checks out
`job/ID-N` at BASE in the empty folder.

The caller keeps DIRS with the task, in the hub's state, never in the folder. At bind time it checks them against
`drgnx-job-snapshot-read-dirs REPO BASE`, which is derived from the repository. Once an agent has had a folder, its
alternates file is the agent's, so nothing is ever derived from it.

**Copy-on-write is probed, not assumed.** `drgnx-job-snapshot-cow-p REPO` copies one small file under
`<repo>/.claude/worktrees/` (never in `.git`) with the copy command, and caches the answer per filesystem (the
device number). In the hub, the first probe on a filesystem is a process of its own. Setting
`drgnx-job-snapshot-copy-on-write` to nil always makes the clone.

**A `.git` the user's git is writing.** The store comes from git's own transfer, which reads refs and objects
consistently and ignores the user's lock files. When the clone or fetch fails, for example because BASE is not there
yet, a store made by that try is removed and the step runs once more.

### The config: a whitelist the hub writes

The hub writes the store's config itself, and each task's config is the same list. A key no one has thought of yet
stays out.

| From | Keys | Why |
|---|---|---|
| the store's fresh clone | `core.repositoryformatversion`, `core.filemode`, `core.ignorecase`, `core.symlinks`, `core.precomposeunicode`, `extensions.*` | What git needs to read the repository (the object format). |
| the user's repository (`--no-includes`) | `core.autocrlf`, `core.eol`, `core.safecrlf` | Line endings, as the user checks out. |
| the user's repository | `core.hooksPath`, only if relative and without `..` | The project's own hooks (drgnx's `.githooks`) run inside the sandbox, from the checkout. |
| the user's repository | `filter.lfs.clean`, `smudge`, `process`, `required` | Git LFS checkouts. |
| the hub | `core.bare` (true in the store, false in a task), `gc.auto 0` | A repack would un-share copied blocks, or drop objects a clone borrows. |

A carried value that holds a URL with credentials (`://user:secret@`) is dropped too.

Nothing else is carried:
- remotes, `credential.*`, `url.*`, `http.*` (including `http.<url>.*` subsections with credentials in the URL);
- `submodule.*.url`, `branch.*.remote` and `pushRemote`;
- `lfs.url` and `lfs.pushurl`;
- `include*`;
- `core.fsmonitor`, `core.worktree`, `core.sshCommand` and the other program keys.

**Overrides on every git the hub runs here:**

| Override | Why |
|---|---|
| `core.hooksPath=/dev/null`, `--template=` | No hook runs in the hub, and none is installed in the store or a clone. |
| `core.fsmonitor=false` | An fsmonitor is a program git runs whenever it reads the index. |
| env: `GIT_TERMINAL_PROMPT=0` | Never a prompt. |
| env: `GIT_ALLOW_PROTOCOL=file` | Only local transfers. |
| env: `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY` and `GIT_ALTERNATE_OBJECT_DIRECTORIES` unset | No inherited variable points git at another repository. |

The clone's local upload-pack reads the user's own repository config, which is trusted.

**Inside the sandbox**, git runs what the task's config and checkout name:
- checkout runs `filter.lfs.*` and the hooks under a relative `core.hooksPath` (`post-checkout`);
- `bundle create` runs none.

drgnx's own sandboxed steps should still pass `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.pager=cat
-c core.editor=false`, with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`. Then an agent's config only
ever runs with the agent's own power.

After DONE, nothing outside the sandbox runs git in the folder again (the VC guard enforces it).

**Limits:**
- **Git LFS repositories do not check out yet.** LFS content (`.git/lfs/objects`) is not in the store.
  - The task's config has the LFS filter (with `filter.lfs.required`) but no remote and no `lfs.url`, so
    `git-lfs smudge` has no endpoint even with network. The checkout likely aborts.
  - A checkout with `GIT_LFS_SKIP_SMUDGE=1` would leave pointer files instead.
- Submodules' git directories are not copied. A task gets empty submodule directories.
- On macOS, `cp -c` may fall back to a full copy without failing on a filesystem without clonefile. The probe then
  answers yes. For a store this costs little (it holds BASE alone).
- The store's time and disk grow with BASE's reachable history. A very large repository pays seconds once per job,
  not per task.

### Bounded

The store and each copy live under `.claude/worktrees/` and nowhere else. `drgnx-job-snapshot-remove DIR DONE`
removes them with `rm -rf`, which never follows a link an agent left. It takes only its own folders:
- a task folder `ID-N` (or `ID-N-review`) with a `.git` directory;
- a store `NAME.base.git`.

It refuses a path with a link anywhere from the repository down: `.claude`, `worktrees` or the folder itself. The
repository's own path is the user's, and may go through a link. Remove a store only after the last task that borrows
from it (shared clones).
`drgnx-job-snapshot-disk-usage DIR DONE` reports `(:bytes N :exclusive M)`:
- N comes from `du`, which counts shared blocks in full;
- M is what is not shared, from `btrfs filesystem du` on btrfs, and nil elsewhere.

Measured on drgnx's own repository on btrfs (base `main`, 7572 objects reachable; three runs each):

| What | Time | Disk |
|---|---|---|
| the job's store, made | 0.16–0.18 s | 2.4 MB |
| the job's store, fetched (BASE unchanged) | 11–12 ms | |
| a task's copy-on-write copy | 11 ms | 2.4 MB by `du`, exclusive 0 |
| a task's shared clone | 21–22 ms | 28 KB |
