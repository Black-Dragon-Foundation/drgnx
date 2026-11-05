# Sleipnir, the runner

`runtime/crates/sleipnir` is the runner: what a machine that runs drgnx jobs for a hub needs. Its features:

| Feature | What | Dependencies |
|---|---|---|
| `proto` | the hub–runner protocol | pure |
| `sync` | a job's inputs, the hardened git, checkout slots | std, `rustix`, `sha2`; blocking, never tokio |
| `linux` | the machine probe and the executor | blocking, never tokio |
| `runner` (default) | the binary's modes | |

## Sync

`sleipnir::sync` gets a job's code to a runner without letting the job get code run outside its container.

### Inputs, frozen at submit (`sync::capture`)

`capture(repo, extra)` reads the user's worktree on the hub and returns `Inputs`:

- `commit` and `tree`: `HEAD` and its tree;
- `manifest`: the overlay, every uncommitted change against `HEAD` (staged, unstaged, untracked and not ignored,
  deletions), from `git diff --no-renames --raw -z HEAD` and `git ls-files -o -z --exclude-standard`;
- `extras`: the declared gitignored inputs (`inputs.extra`), a directory taken whole.

Each entry is a file `(path, mode, sha256, size)` or a deletion. A link is an entry with mode `120000`, hashed over
its target. Paths are raw bytes throughout: a name with a space, a newline or bytes that aren't UTF-8 arrives
exactly, or the capture is refused naming it.

The capture refuses, naming the path:

- every missing extra, all at once (`SyncError::Missing`);
- a submodule, or a nested repository (`ls-files` names only its directory);
- a path with a `.git` component, in any case;
- anything that is neither a file nor a link.

`input_key(&inputs)` is sha256 hex over the tree id, the manifest and the extras, so a rewrite with the same bytes
keeps the key and a change of content or mode doesn't.

Git runs here as everywhere in sleipnir: hardened, with no global config. The user's `core.excludesFile` is still
honoured: it is read as data from their global config files (and the repository's) with `git config --file`, and
passed to `ls-files`. Files the user ignores never enter the overlay. `capture::a_globally_ignored_file_never_enters_the_overlay`
(`tests/capture_home.rs`, alone in its binary since it sets `HOME`) checks this through the real `~/.gitconfig` lookup.

### The hardened git (`sync::git`)

`Git { git_dir, work_tree }.cmd(args)` is the only constructor for a git command in sleipnir. Every command gets:

- `GIT_DIR` and, unless the repository is bare, `--work-tree`;
- `-c core.hooksPath=/dev/null -c core.fsmonitor=false`;
- `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null`;
- `-c transfer.fsckObjects=true`;
- no inherited `GIT_*` variable, and `GIT_TERMINAL_PROMPT=0`.

So git never discovers a `.git` a job planted, never runs a hook or an fsmonitor program, and reads no config a job
or another program could have written. The test `git::every_command_is_hardened` puts a recording `git` first on
`PATH`, sets hostile `GIT_*` variables in the test process, and checks every command a capture and two slot updates
run.

### Slots (`sync::slot`)

A slot is one checkout per slot key (project, source worktree, trust, toolchain). Its three directories are
siblings under the runner folder, named by 32 hex digits of the key's hash:

| Path | What | Jobs see it |
|---|---|---|
| `slots/<id>/` | the checkout | read-only (a writer gets a private copy) |
| `slots-git/<id>/` | its git dir: index, config, `used`, the locks; objects come from the mirror (`objects/info/alternates`) | never |
| `slots-target/<id>/` | its `CARGO_TARGET_DIR` | read-write, one job at a time |

`update(paths, mirror, commit, overlay)`:

1. checks the commit id and every overlay path and mode before anything changes; git itself only warns and skips a
   path it won't store, so this check is ours;
2. deletes, never follows, every `.git` in the slot (a directory, a file or a link);
3. builds the wanted index in a temporary index: the commit (`read-tree`), the overlay's blobs (`hash-object -w`
   from the blob store) and its entries (`update-index -z --index-info`), then `write-tree`;
4. refreshes the slot's index, so a file whose stat changed but whose bytes didn't (a touch, an SELinux relabel) is
   not rewritten;
5. moves the checkout with `read-tree --reset -u` and detaches `HEAD` at the commit.

Git rewrites only the files whose content changed, with the current time, and removes deletions. Every other file
keeps its mtime, so cargo rebuilds exactly what changed. Git also replaces a link a job planted where a directory
belongs, rather than write through it. The git dir's `info/attributes` unsets `text`, `ident`, `filter` and
`working-tree-encoding` for every path, so the slot holds exactly the bytes captured.

`private_copy(paths, dest)` copies the slot for a job that declares `writes_tree`. It clones each file where the
filesystem can (`CopyKind::Reflink`) and copies it otherwise (`CopyKind::Plain`). Files keep their mode and mtime,
links are copied as links, and `dest` must not exist.

`Locks::of(paths)` takes `flock`s on files in the git dir, so they hold across processes and go with a process that
dies:

- `read` is shared and marks the slot used;
- `update` waits for every reader;
- `target` is exclusive, for a job that builds into the target dir.

`try_update` and `try_target` return `None` instead of waiting. A lock belongs to its open file description, which a
child forked by another thread shares until it execs: a `try_*` can see a lock held a moment after its holder let it
go. So the locks' test (`tests/slot_locks.rs`) runs alone in its own binary, where no other thread spawns git.

`gc(root, now, in_use)` removes slots unused for 7 days (by the `used` file), target dir first, then the checkout,
then the git dir. A slot in `in_use`, or one whose lock is held, is kept.

### The escape rows

Each row plants into the slot what a job could write, syncs a new commit and overlay, and checks that the marker the
planted program would write is absent and the planted `.git` is gone:

| Test | The plant |
|---|---|
| `slot::a_planted_post_checkout_hook_never_runs` | a repository at `slot/.git` with every hook git may run on a checkout |
| `slot::core_fsmonitor_in_a_planted_config_never_runs` | `core.fsmonitor` in `slot/.git/config` |
| `slot::a_planted_core_hookspath_never_runs` | `core.hooksPath` at hooks the job wrote |
| `slot::a_dot_git_file_in_the_slot_is_deleted_not_followed` | a `.git` file and a `.git` link naming a git dir outside the slot, which stays unchanged |
| `slot::a_planted_link_never_leads_a_write_outside` | links where a directory and a file belong |

All are `[D]`: temp repositories and real git, no clock, no waits.
