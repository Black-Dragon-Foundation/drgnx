# The job sandbox

## Git: snapshot mode

In snapshot mode, the default, each task of a job gets a `.git` of its own in its folder
`<repo>/.claude/worktrees/ID-N/`. The agent owns that copy entirely and never touches the user's `.git`. Only `.git`
is copied, so **the agent never sees the user's uncommitted changes or untracked files** (`.env`, local keys).
`core/drgnx-job-snapshot.el` makes and prepares the copy. Git's own security guidance sets the rule: a `.git` an
agent can write is untrusted, and running git in it runs that agent's config and hooks. So the hub runs git in a copy
only **before** any agent has it. From then on, git runs there only inside the sandbox.

### The copy

`drgnx-job-snapshot-make REPO FOLDER BASE DONE` makes the copy. It is asynchronous, like every step here (separate
processes, so the hub never waits). DONE gets one of:

- `(:mode snapshot :read DIRS)`: a copy-on-write copy of REPO's common git directory (`drgnx-job-snapshot-common-dir`,
  so a linked worktree or a submodule is copied from its common dir). On Linux it uses `cp -a --reflink=always`
  (btrfs, XFS). On macOS it uses `cp -c -a` (clonefile, APFS). The folder is inside the repository, so the copy is
  on the same filesystem, and blocks are shared until one side rewrites them.
- `(:mode clone :read DIRS)`: the fallback where there is no copy-on-write (tmpfs, ext4, network filesystems,
  HFS+). It runs `git clone -q --shared --no-checkout --branch BASE REPO FOLDER`, so objects come through
  alternates and nothing is copied.
- `(:error MSG)`: BASE is not a branch name, REPO is not a repository, FOLDER exists and is not empty, or the copy
  failed twice.

DIRS are the object directories the sandbox must mount read-only. For a clone, that is the main repository's
`objects`. For a copy, it is nil, unless the repository itself borrows objects (its alternates are written into the
copy as absolute paths). The caller keeps DIRS with the task. `drgnx-job-snapshot-alternates FOLDER` reads the same
thing from the folder, but once an agent has had the folder, its alternates file is the agent's. Read from then on,
an agent could name any directory there and get it mounted, so later callers use DIRS.

Nothing is checked out. The sandbox's first step checks out `job/ID-N` at BASE in the empty folder.

**Copy-on-write is probed, not assumed.** `drgnx-job-snapshot-cow-p REPO` copies one small file under
`<repo>/.claude/worktrees/` (never in `.git`) with the copy command, and caches the answer per filesystem (the
device number). In the hub, the first probe on a filesystem is a process of its own. `drgnx-job-snapshot-copy-on-write`
set to nil always makes the clone.

**A `.git` the user's git is writing.** A copy taken while the user commits or fetches can hold that git's lock files
and miss a ref. The locks are removed (below). The base commit is then checked, and when it is missing, the copy is
removed and made once more.

### The preparation (trusted steps only)

The copy still holds only the user's content, so the hub prepares it outside the sandbox:

1. **Per-checkout state removed** (plain file operations, no git). Only `HEAD`, `config`, `description`, `hooks`,
   `info`, `objects`, `refs`, `packed-refs`, `shallow`, `reftable` and `lfs` stay. Everything else is the user's
   checkout's state, and removing it keeps the user's work in progress out:
   - `index` holds staged changes;
   - `logs/` is the reflogs, including the stash's list;
   - `worktrees/` holds the user's linked worktrees. They are still on disk, so `git worktree prune` alone would keep
     them;
   - `FETCH_HEAD`, `remotes/` and `branches/` hold remote URLs;
   - `MERGE_*`, `rebase-*`, `sequencer/`, `ORIG_HEAD` and `AUTO_MERGE` are merge, rebase and sequencer state;
   - `modules/` and `config.worktree`.

   Every `*.lock` left in the kept part is removed too (the loose object directories are not walked).
2. **Git steps**, each with `-c core.hooksPath=/dev/null -c core.fsmonitor=false`:
   - `cat-file -e BASE^{commit}`: the base is there.
   - `update-ref -d refs/stash`: the user's stashed changes.
   - `config --file .git/config --unset-all KEY` for each key below.
   - `remote remove -- NAME` for every remote. This removes its URL (which may hold a token) and its
     remote-tracking refs.
   - `config --file .git/config gc.auto 0`: a repack inside would un-share the copied blocks.
   - `worktree prune`.

The steps first list the copy's config names with `config --file … --no-includes --name-only --list --null`, so no
include is followed. The config edits use `--file`, so git does not even open the repository for them.

**Overridden for every git the hub runs on a copy, and why:**

| Override | Why |
|---|---|
| `core.hooksPath=/dev/null` | `remote remove` and `update-ref` delete refs, which runs the `reference-transaction` hook. No hook of the copy runs in the hub. |
| `core.fsmonitor=false` | An fsmonitor is a program git runs whenever it reads the index. None of these steps should, but none can start one. |
| env: `GIT_TERMINAL_PROMPT=0`; `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY` and `GIT_ALTERNATE_OBJECT_DIRECTORIES` unset | Never a prompt. No inherited variable points git at another repository. |

**Unset in the copy's config (`drgnx-job-snapshot--strip`), and why:**

| Keys | Why |
|---|---|
| `remote.*` (by `remote remove`), `remote.pushDefault` | URLs may hold a token. `uploadpack` and `receivepack` are commands. |
| `credential.*` | Helpers are programs. Usernames name accounts. |
| `url.*` | `insteadOf` rewrites may hold a token. |
| any `*.extraHeader`, `http.proxy`, `http.<url>.proxy` | `Authorization:` headers (CI checkouts write them). A proxy URL may hold a password. |
| any key ending in `token`, `pass`, `password` or `secret` (`sendemail.smtpPass`, `github.token`, …) | Named like a secret. |
| `include.*`, `includeIf.*` | Files outside the copy, which the sandbox does not mount. |
| `core.fsmonitor`, `core.sshCommand`, `core.askPass`, `core.gitProxy`, `core.alternateRefsCommand` | Programs on the user's machine. The copy starts with none, so any later one is the agent's. |
| `core.worktree` | It points to the user's checkout (submodules, separate git dirs). The agent's checkout is its folder. |

**Kept, on purpose:** the copy's `hooks/` and a relative `core.hooksPath` (a project's own pre-commit check still
runs, inside the sandbox), and `filter.*`, `diff.*` and `merge.*` drivers (Git LFS checkouts need them). They run only
inside the sandbox.

After DONE, nothing outside the sandbox runs git in the folder again (the VC guard enforces it).

**Limits:**
- Objects are copied whole. A blob the user staged, or a dropped stash, stays in the copy's object store as an
  unreachable object. It can be read by its id, but no ref, index or reflog names it. The shared clone reads the
  same store through alternates.
- Submodules' git directories (`modules/`) are not copied.
- On macOS, `cp -c` may fall back to a full copy without failing on a filesystem without clonefile. The probe then
  answers yes, and the copy costs the whole `.git`.

### Bounded

The copy lives in the task folder and nowhere else. `drgnx-job-snapshot-remove FOLDER DONE` removes the folder with
`rm -rf`, which never follows a link the agent left. It refuses anything that is not `.claude/worktrees/NAME/`.
`drgnx-job-snapshot-disk-usage FOLDER DONE` reports `(:bytes N :exclusive M)`:
- N comes from `du`, which counts shared blocks in full;
- M is what is not shared, from `btrfs filesystem du` on btrfs, and nil elsewhere.

Measured on drgnx's own `.git` on btrfs (38 MB, 4605 loose objects, three runs each, end to end through
`drgnx-job-snapshot-make`):

| What | Time | Disk |
|---|---|---|
| copy-on-write copy and preparation | 0.49–0.52 s (the `cp` alone: 0.37–0.41 s) | `du` 35 MB, exclusive 0 |
| shared clone and preparation | 42–43 ms | 92 KB |
