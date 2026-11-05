# sleipnir: the runner

`runtime/crates/sleipnir` is what runs jobs on a machine: the hub's own (local) machine, the user's other machines
over SSH, and jobq's. It is a library, shared by the hub, the runners and jobq, and the `sleipnir` binary (its modes: `serve`, `job-exec`, `job-helper`, `bench`, `git-receive`, `credential-helper`), with `drgnx-key` beside it.
The scheduling decisions are [`forseti`](forseti.md)'s; sleipnir reads the machine for them and carries them out.

## Features

| Feature | What | Dependencies |
|---|---|---|
| `linux` | the machine probe, the reservation files, the executor | std, rustix, libc, serde, `forseti`; blocking, never tokio |
| `sync` | a job's inputs, the hardened git, checkout slots, mirrors, bundles, blobs, caches, the disk guard | std, rustix, `sha2`, `secrecy`, `forseti`; blocking, never tokio |
| `proto` | the hub–runner protocol: the frames and their wire | pure: serde, serde_json, `forseti`'s types, `secrecy` and `zeroize` for a key's value |
| `runner` (default) | the binary's modes, the job helper's proxy | all of the above, `gleipnir` and tokio (the proxy only) |
| `test-hooks` | test-only entry points | compiled away otherwise |

`linux` turns on `proto`: the probe's `Facts` and `Missing` are the protocol's types, since `hello-ok` and
`probe-result` carry them.

jobq depends with `default-features = false, features = ["linux", "sync"]`, so no async runtime reaches it. The
Android check builds `--no-default-features --features proto,sync`, and CI builds jobq's shape static too
(`x86_64-unknown-linux-musl`, in `runtime.yml`'s `agent-containers` job; [ci.md](ci.md)).

**Platforms.** systemd and the cgroup files are a desktop-distro fact: `linux::probe`, `linux::reserve` and the
executor's systemd parts are `target_os = "linux"` only. Android (`target_os = "android"`) has no user manager to run
jobs under, so it gets none of them, and a runner there refuses every job rather than run one unconfined.

## The machine probe (`linux::probe`)

`Probe` holds where it reads (`/proc`, `/sys`, the user manager's cgroup, `$XDG_RUNTIME_DIR`, the runner folder), so
tests point it at fixture trees; `Probe::system(name, scheduler, slice_root, folder, profile)` is the real machine.

- **`machine(now, limits) -> MachineState`**: `MemTotal` and `MemAvailable`; PSI `avg10` of system memory and CPU
  `some` and IO `full`, and the user's apps' memory `some` (`app.slice/memory.pressure`) when the limits read it
  (the workstation profile); disk free and size of the runner folder's filesystem (`statvfs`); mains power; the boot
  id; and the other schedulers' live reservations (below). What runs is the scheduler's to fill in. In a
  `test-hooks` build only, a `test-machine.json` in the runner folder (`{psi, disk_free_gb, disk_total_gb,
  mem_available_mib}`, each optional) stands in for those figures: a fake runner shares its host's pressure files,
  memory and disk, so the fleet rows set a quiet machine instead of admitting on the host's load. A file that doesn't
  parse is an error, never the host's figures; the limits judging the figures are the profile's, unchanged.
- **`cgroup(slice) -> CgroupStat`**: `memory.current`, `memory.stat`'s `file`, `memory.peak`, `memory.events`'
  `oom_kill` and `oom_group_kill`, `cpu.stat`'s `usage_usec` and `memory.pressure`. A slice's cgroup is found the way
  systemd nests it: each `-` opens a level, so `drgnx-runner-work-a3f.slice` is
  `drgnx.slice/drgnx-runner.slice/drgnx-runner-work.slice/drgnx-runner-work-a3f.slice` under the user manager.
- **`psi_trigger(path, "some 150000 1000000")`** arms a kernel PSI trigger; `wait(timeout)` wakes when it fires.

### The runner contract

`contract(probe, podman) -> Result<Facts, Vec<Missing>>` is what `drgnx runner add` and every `hello` check. A host
that lacks any item is refused with the whole list, each with its fix:

| Item | Fix shown |
|---|---|
| a systemd user manager | log in, or `loginctl enable-linger` |
| rootless podman ≥ 5 | install or upgrade podman; connect as an ordinary user |
| cgroup v2 | the unified hierarchy (the default on current distributions) |
| podman on the systemd cgroup manager | `cgroup_manager = "systemd"`, with a user manager running |
| `memory pids cpu` delegated to the user | a `user@.service.d/delegate.conf` drop-in, then log in again |
| git | install git |

There is no reduced mode. Linger is a fact, not a refusal: without it, jobs end when the link drops, and the runner
list says so. The facts: architecture, OS (`ID VERSION_ID`), cores, memory, disk free, podman's version, linger, the
Landlock ABI, a graphical session, a battery, whether `memory.swap.max` can be set, whether systemd writes cpusets,
and the other schedulers present.

**cpusets.** A user manager started before `cpuset` was delegated accepts `AllowedCPUs=` and never writes the
slice's `cpuset.cpus`, while `user@.service`'s `cgroup.subtree_control` still lists `cpuset`. So the probe judges by
doing it: it sets `AllowedCPUs` on its own `<root>-probe.slice`, reads `cpuset.cpus` back, and stops the slice. When
the read-back fails, the executor writes the delegated files itself (below). `systemctl --user daemon-reexec` on the
host (the user's call) makes systemd do it again.

## Two schedulers on one machine (`linux::reserve`)

jobq and a runner, or two hubs, can share a machine. Each running job of each scheduler is one file in
`$XDG_RUNTIME_DIR/forseti/reservations/<scheduler>.<job>.json` (a `forseti::reserve::Reservation`: pid, boot id,
start time, job, reserve, current, expiry), written by rename, mode 0600 in a 0700 directory.

- **Admission** runs under `flock` on `forseti/admit.lock` (`Reservations::with_admit_lock`): read the others, decide,
  write the own reservation, let go. Two admissions in one second can't both fit.
- **Counting** is `forseti::count_others`: another scheduler's job counts as `max(reserve, current)`, once.
- **Liveness**: a file counts only while its process is the one that wrote it (`alive(pid, start_time)`, by
  `/proc/<pid>/stat` field 22, so a reused pid doesn't count) and on the boot it was written in.

## The podman argv

`linux::podman::argv(req, caps, runner_args)` is the one builder of a `podman run` line, used by the hub's own container
jobs (`exec/container.rs` calls it with `RunnerArgs::local()`) and by the runners. It is pure and builds on every
target, so a hub on macOS uses it too. Fixed for every job: `--rm`, `--pull=never`, `--userns=keep-id`,
`--cap-drop=all`, `--security-opt=no-new-privileges`, `--read-only`, `--tmpfs /tmp`, the pids, memory and CPU limits,
`--memory-swap` equal to `--memory`, `--oom-score-adj=1000`, `--cgroup-conf=memory.oom.group=1`, `--network=none`, a
digest-pinned image from the allow-list, and the command after the image, where podman reads no options. A granted
network is the proxy socket and `drgnx-fwd`, mounted read-only, as the entrypoint ([gleipnir.md](gleipnir.md)).

On a runner (`RunnerArgs::runner(prefix, hub_id, slice)`) the container is named `<prefix>-<id>`, labelled
`drgnx.runner=<hub id>` (the runner removes only containers with both), and placed with `--cgroup-parent=<job slice>`:
without it, podman puts a container started from a unit under `user.slice`, outside the job's slice. Its mounts are
exactly this set (`RunnerMounts`), nothing else:

| Mount | Inside | Mode |
|---|---|---|
| the source: the slot, or a writer's private copy | `/work` | `ro,z` (`rw,Z` for a `writes_tree` copy) |
| the slot's target dir | `/target` (`CARGO_TARGET_DIR`) | `rw,Z` |
| each cache the suite declares | its own absolute path, never under `/work`, `/target`, `/tmp` or `/run/drgnx` | `rw,Z` |
| the key socket and `drgnx-key` | `/run/drgnx/key.sock`, `/run/drgnx/key` | `ro,Z` |
| the proxy socket and `drgnx-fwd` (a granted network) | `/run/drgnx/proxy.sock`, `/run/drgnx/fwd` | `ro,Z` |

A keyed job (`KeyMounts.vars`, each `(key name, variable)`) runs as `drgnx-key exec NAME=VAR… -- CMD`: `drgnx-key` is
the entrypoint, or, with network, the forwarder's command (`drgnx-fwd PORT SOCKET -- /run/drgnx/key exec … -- CMD`).
The argv names the keys and variables only; a name or variable that isn't plain is refused. The job's request has no
field to put anything around the command.

`check_limits(podman, env, limit)` asks `podman info` and refuses container jobs unless the caps hold (cgroup v2, the
systemd manager, `memory pids cpu` delegated); `limits_enforced(info)` is its pure half.

## The executor

### The slice tree (`linux::slices`)

```text
<root>.slice                 MemoryHigh / MemoryMax (the cap); workstation: CPUWeight=20 IOWeight=20
  <root>-work.slice          AllowedCPUs
    <root>-work-<id>.slice   one job: accounting, stop, kill
      <unit>.service         job-exec (OOM score 900), with the podman client and conmon
      libpod-<ctr>.scope     its containers (OOM score 1000, memory.oom.group=1)
```

`ensure_tree(root, profile)` starts the tree (`drgnx-runner` on runners; jobq uses its own root);
`set(unit, props)` changes properties with `set-property --runtime` only, so nothing outlives a reboot;
`job_slice(root, id)` names a job's slice; `stop(slice)` stops a job with everything in it.

`set_cpus(manager, slice, cpus, by_systemd)` pins a slice's CPUs; every running and new container under it follows at
once. Where the probe found that systemd doesn't write cpusets, it also writes the delegated files directly: `+cpuset`
into each ancestor's `cgroup.subtree_control` from the user manager down, then the slice's `cpuset.cpus`
(`direct_cpus`). systemd keeps that write when it realizes the tree again.

### A job's unit (`linux::unit`)

Each attempt is a transient user service in its job slice: `unit::start(UnitReq)` runs `systemd-run --user --collect`
with `OOMScoreAdjust=900`, `OOMPolicy=kill`, `MemorySwapMax=0`, `RuntimeMaxSec` and `StandardOutput=append:` /
`StandardError=append:` the attempt's log, optionally `BindsTo=` another unit. The unit outlives its starter (the
runner's `serve`, jobq's daemon, a dropped link), and nothing passes through a pipe that could break. Its environment
(`--setenv`) is visible in `systemctl show`, so no secret ever goes there. `stop`, `active` and `list(prefix)` read and
end units.

### job-exec (`linux::jobexec`)

The unit runs `sleipnir job-exec <attempt folder>`, which reads the folder's `job.json` (`JobExec`) and runs the job's
command **inside its own service**, so the podman client and conmon land there too, at job-exec's OOM score. The
containers sit beside it in the job slice at 1000.

- **Why 900 and not 1000.** The job slice holds the service and the containers side by side, and systemd has no slice
  property for `memory.oom.group`, so the job is not one OOM group. At equal scores the kernel picks by size, and it
  has killed job-exec first, which then never writes a verdict. At 900 job-exec is still above every process of the
  user's, and a container goes first.
- **An OOM takes the whole job.** job-exec watches the job slice's `memory.events`; when `oom_kill` (or
  `oom_group_kill`) grows, it writes the verdict `oom` and then stops the whole job slice, with the job's other
  containers and itself in it. The timeout does the same with `timeout`. conmon goes with the slice, so podman's
  `--rm` never runs for those containers: they stay exited, labelled, for the runner's cleanup at the job's end.
- **Keyed jobs.** Before a keyed job's command starts (and so before its first key), job-exec reads its own service's
  `memory.swap.max`; anything but `0` refuses the job as `infra: setup`, and the command never runs.
- **The folder.** `offsets.json` records where each state dir's `check.log` stood at the start (only this attempt's
  part is read). A scheduler that kills a job writes the reason first (`kill_reason(dir, reason)`; `evicted` for an
  eviction), and the reason names the verdict. `result.json` is written by rename.
- **A kill reason stops the job.** When a reason appears while the command runs (the scheduler's ladder, a cancel,
  the helper's disk watch), job-exec ends the command, writes the verdict the reason names and stops the job slice.
- **The helper.** A spec with `helper` (`HelperSpec { root, keys, hub_allow, container }`; every runner job has one)
  gets `sleipnir job-helper` started after the swap check and before the command, inside job-exec's own service, and
  waited for by its `ready` line. It ends when job-exec closes its stdin, and with the unit in any case (below).

The verdict is `forseti::classify` over what job-exec saw: the kill reason, `oom_kill`, the exit code or signal, the
timeout and the row parser's judgement. The helper's `key-timeout` record (a key request that got no key) makes it
`infra: key not delivered`, never the job's own failure; a written kill reason still comes first.

## The job helper (`helper`)

```
sleipnir job-helper --dir D [--hub-allow FILE]
```

One per attempt, owning what the job may use and must never keep. job-exec starts it inside the job's unit (so in
its slice, capped at no swap), and it reads job-exec's pipe: when job-exec ends, or the unit stops, the helper goes
with it. Nothing outlives the job, so no daemon is left behind, and `serve` may end with the link while it runs. It:

- sets `PR_SET_DUMPABLE=0` and `RLIMIT_CORE` 0 first: no core dump (a piped `core_pattern` ignores `RLIMIT_CORE`),
  and no other process of the user can read its memory or `/proc` files;
- serves the job's keys on `D/key.sock` and takes them from `serve` on `D/helper.sock` (both 0600, this user only;
  "Keys" below);
- with `--hub-allow`, runs Gleipnir's CONNECT proxy on `D/proxy.sock` with the hub's allow-list (`helper::net`). An
  entry naming `metadata.google.internal`, `169.254.169.254`, `fd00:ec2::254` or any address that isn't public is
  refused, no name is pinned, and the proxy connects only to public addresses, so a listed name that resolves to
  `169.254.x` gets `403` too. (The agent browser's `METADATA_NEVER` replaces this list once both are on one line.)
- watches the runner folder's disk every 10 s (`helper::disk`). Below the floor (the larger of 20 GB and 10 % of its
  filesystem, `forseti`'s disk guard) the job that grew most since its start is stopped: its helper writes
  `kill_reason("infra: disk")` and kills its container. A job's growth is its attempt folder's size less its size
  when its helper started (`disk-start`); every helper sums the same running attempts, so only one acts per reading
  and they agree which. In a test build the floor reads the folder's `test-machine.json` too.

Its sockets appear at once (bound under a temporary name, then renamed); then it writes `helper.pid` and prints
`ready <pid>`. Its own messages go to `D/helper.log`, never a key's value.

## Keys

A key reaches a job without touching disk (design 6.6):

1. The hub sends one `key` frame per key after `started`. `serve` hands each to the attempt's helper over
   `helper.sock` (`helper::keys::hand`: `key NAME LEN` and the bytes), now or, while the helper is still coming up, at
   its next tick; until then it is only in `serve`'s memory. A key for an attempt that hasn't started here is dropped
   and only its name is said.
2. The helper takes only the names the job's spec lists, and holds each value in a `Locked` buffer: an anonymous
   mapping, `mlock`ed and `MADV_DONTDUMP`, zeroed and unmapped when it goes (at the job's end, or when the store is
   cleared). A test build's probe (`keys::probe::last_zeroed`) reads the buffer just before it is unmapped.
3. `drgnx-key` (std only, so its static build starts in any image) asks on `/run/drgnx/key.sock` (`DRGNX_KEY_SOCK`
   names another socket, as for a job that stays on the hub's machine):
   - `drgnx-key exec NAME=VAR… -- CMD` reads each key into VAR, in its own environment only, and execs CMD;
   - `drgnx-key get NAME` writes one key to stdout.
   A request waits for its key up to 60 s. When it doesn't come, the helper records the name in `D/key-timeout`
   first, then answers `timeout`, and `drgnx-key` exits 75; `result.json` reads the record as `infra: key not
   delivered`. A name the job doesn't list is refused at once (exit 64).
4. Each delivered read is a line in `D/key-use` (the name and the time); `serve` sends each line once as a `key-use`
   frame (`key-use.sent` counts them, across reconnects).
5. Podman's argv, its stored config and `podman inspect` show the names only. Neither `podman run --env` nor podman
   secrets are used: both end up in podman's stored config or in files.

`serve` gives every keyed job its own copy of the bundle's `drgnx-key` (and a networked one its own `drgnx-fwd`) in
its attempt folder, since each container relabels what it mounts (`Z`).

## The runner bundle

`bin/drgnx build runner-bundle [--arch x86_64|aarch64]` builds `sleipnir`, `drgnx-key` and `drgnx-fwd` static (Rust's
self-contained musl targets, release) into `runtime/target/bundle/<arch>/`, and checks each with `file`. The host's
architecture is the default; `install.sh` builds that one, and CI's container lane builds both. `tests/bundle_host.rs`
(`#[ignore = "bundle"]`, with `DRGNX_TEST_BUNDLE` and a musl image in `DRGNX_TEST_FOREIGN_IMAGE`) runs the bundle's
forwarder and `drgnx-key` in an image of another libc.

### `result.json` (`linux::result`)

`ResultJson { verdict, infra, counts { ran, passed, failed, skipped, crashed }, rows [{ name, verdict, attempt,
machine }], failing, machine, grant, wall_s, cpu_s, mem_peak_mib, disturbed, log }`. The CPU time and the memory peak
are the job slice's (`cpu.stat`, `memory.peak`).

### Row parsers (`linux::parse`)

| Parser | Reads |
|---|---|
| `ert` | ERT's batch lines (`passed`, `FAILED`, `skipped`, `failed` for an expected failure, with `N/M`) and `Ran N tests`; `Running N tests` with no `Ran` line is one crash |
| `cargo-test` | libtest's `test NAME ... ok / FAILED / ignored`; a test binary that died on a signal is a crash |
| `plist` | one row per line, `(:name "NAME" :verdict pass\|fail\|skip\|crash …)` |
| `exit` | no rows: the exit code decides |

`judge(parsed, expect)`: a failed row is red, a crashed one a crash; fewer rows than `expect.min_ran`, or more skips
than `expect.max_skipped`, is `suspect` (a set that silently ran nothing never passes), and the `exit` parser can't
claim `min_ran` at all.

### jobq's shim (`linux::shim`)

jobq's binary answers to `argv[0] == "podman"` and calls `shim::rewrite(argv, env)`: on the first `run` or `create`
(also `container run|create`; global options before it, with their values, are skipped) it inserts
`--cgroup-parent=<the job's slice> --oom-score-adj=1000 --cgroup-conf=memory.oom.group=1 --label <k>=<v>` right
after the subcommand, and `--memory-swap` equal to `--memory` when only the latter is given (it reads podman's run
options up to the image, so the image's own `-m` is never taken for podman's). Without a slice in the environment it
changes nothing. A score given on the command line stays after ours and wins; ours is the highest, so the shim never
lowers one.

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

A slot is one checkout per slot key (project, source worktree, trust, toolchain); the trust is
`forseti::JobTrust`, hashed as its word (`public`, `private`, `private+keys`). Its three directories are
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

### Mirrors (`sync::mirror`)

`Mirror::ensure(root, repo_id)` is the runner's bare mirror of one repository, `<root>/git/<id>/`. It is made with no
template (so it has no sample hooks) and its config gets `core.hooksPath=/dev/null` every time, besides the hardened
git's own `-c`. A repository id is letters, digits, `.`, `_` and `-`, at most 64, and never starts with `.` or `-`.
Jobs never see a mirror; slots borrow its objects through `objects/info/alternates`. Refs land under `refs/origin/`
(the origin's branches and tags) and `refs/hub/` (what the hub sent).

A mirror gets its objects three ways (design 6.2):

- **`fetch_origin(url, cred)`**, at the runner's own bandwidth. The URL is `https://` with no user or password in it,
  `ssh://`, or `user@host:path`; never a local path, `file://`, a remote helper (`ext::`) or anything starting with
  `-`. Git is told the same (`protocol.allow=never`, then `https` and `ssh` only; plain `http` only under
  `test-hooks`), and any configured credential helper is reset. The fetch writes no `FETCH_HEAD`.
- **A bundle** (below).
- **The hub's `git push`.** Its `--receive-pack` is `sleipnir git-receive --root ROOT REPO`, which execs `git
  receive-pack` on the mirror REPO names (its id, or its path under `ROOT/git/`, never anything else), through the
  hardened git. No hook runs, whatever the mirror's config says, and every object received is checked.

`has_commit(commit)` answers whether the mirror holds a commit, for the hub's choice between these.

**The origin's credential** (`sync::cred`) is a token or deploy key the user named for the project. It is held only in
`serve`'s memory and never written to a file:

- `OriginCred::Https(token)`: for one fetch, a socket in `<root>/run/` (mode 0700, the socket 0600) hands the token
  to `sleipnir credential-helper SOCKET get`, which git runs as its only helper and which prints it to git's pipe.
  The socket and its thread end with the fetch.
- `OriginCred::SshKey(key)`: a per-fetch `ssh-agent` (with a 600 s key lifetime besides) gets the key on stdin from
  `ssh-add -`; git's ssh is pointed at it with `IdentityAgent`, and the agent is killed after the fetch, whether it
  went through or failed, and when the key couldn't be loaded.

### Bundles and blobs (`sync::bundle`, `sync::blobs`)

When the mirror lacks more than 8 MiB, the hub sends one git bundle in 1 MiB chunks. `bundle::Receiver::open(root,
repo, BundleRef { sha256, size })` appends them to `<root>/bundles/<repo>.<sha256>.part`, under an exclusive lock, so a
leftover process from a dropped link and the reconnect's receiver never write at once. The file survives a drop, and
`offset()` (its size) is where the hub resumes. A partial of another bundle of the same repository is stale and goes.
`append` refuses bytes past the declared size. `finish()` checks the size and the sha256, then fetches the bundle's
refs into `refs/hub/` with every object checked. A bundle that fails either check never reaches the mirror, and its
file is removed.

`blobs::Store` is the overlay's content-addressed store, `<root>/blobs/<sha256 hex>`. `missing(hashes)` names the
blobs the hub must send (each once); `put(sha, bytes)` keeps a blob only when its bytes hash to its name, written
aside and renamed. It is the `Blobs` a slot update reads.

**The frames** (`sync-have`, `sync-need`, `blob`, `bundle {offset}`, `origin-fetch`) map onto these calls:
`Store::missing` and `Mirror::has_commit` answer a `sync-have`, `Receiver::offset` and `append` take a `bundle`, and
`fetch_origin` serves an `origin-fetch`. Until `serve` handles them, `sleipnir sync-bundle` (`test-hooks` only) takes
one bundle on stdin and announces `at OFFSET` after every chunk, for the fleet row.

## Disk and caches

### Caches by trust (`sync::cache`)

Every writable cache a job's suite declares is a folder `<root>/cache/<project>/<trust>/<name>/`, the trust being the
job's (`public`, `private`, `private+keys`). So a job never reads a cache that a job of another trust wrote. Each word
of the path is one component: letters, digits, `_`, `-` and `.` (not first) stay, and every other byte is `%XX`. So
no two words share a folder, and none leaves its parent.

`mounts_for(job, suite_caches)` gives the job's mounts, all read-write. The target dir comes first, at `/target`
inside:

- `public` and `private` jobs build into the slot's target dir;
- a `private+keys` job gets a fresh one in its own job folder (`jobs/<id>/target`). A keyed release job never runs
  what an unkeyed job's `build.rs` left.

Then comes one mount per declared cache. A `CacheKind::Shared` cache (cargo home, ccache, the Lisp cache) is shared by
the project's jobs of that trust. A `CacheKind::PerJob` cache (dnf and other package caches) is
`<name>@<job id>`, one per running job, since two runs on one dnf cache fail. Each cache's budget is 10 GiB
(`cache::BUDGET`, a setting).

### The disk guard (`sync::guard`)

The floor is 20 GB and 10 % of the runner folder's filesystem, whichever is more. Free space comes from `statvfs`
(`guard::df`), never from adding up sizes. The guard has four parts:

- **`scan(root, now, budget)`** lists what may go:
  - job folders, collected (the `collected` marker) or older than 24 h;
  - artifacts, by job;
  - slots, with how long each has been unused;
  - caches, each with its size (a walk that never follows a link, used only against its budget) and its last use.

  A link where one of these folders belongs is never followed and never listed.
- **`images(root)`** lists the podman store's images, each with the references we pulled it by. `<root>/images`
  records those, one `<id> <reference>` line per `pull`.
- **`plan(df, items, needs)`** is pure. Below the floor, it prunes in the design's order:
  1. collected job folders;
  2. artifacts no queued job needs;
  3. slots unused for 7 days, target dir first;
  4. caches over their budget, then the others, lowest trust first and least recently used first;
  5. images we pulled that no queued job names. An image we didn't pull is never pruned.

  Above the floor, only caches over their budget are pruned (between jobs).
- **`apply(root, plan, df)`** re-reads `df` before every prune for the floor and skips those once the floor is
  reached. Every path is opened component by component under the root with `O_NOFOLLOW`, so a link on the way fails
  that prune. Below it nothing is followed, and a link is removed as a link. A slot goes under its update lock, so a
  slot in use is kept. An image goes with `podman image rm`, never forced.

`pull(root, reference, allow)` pulls only `<repository>@sha256:<digest>` with the repository on the project's
allow-list (`check_pull`), and records it as ours. Jobs run `--pull=never`.

## The protocol (`proto`)

The hub and a runner talk over the hub's SSH sessions to the runner: the control channel (`sleipnir serve`'s stdin
and stdout) carries every job's frames, its logs and its keys; the bulk channels carry `blob` and `bundle` frames in
the same format. `PROTO_VERSION` is checked at `hello`: a runner of another version answers with its own, and the
hub copies its bundle before it sends work.

**The wire** (`FrameReader`, `FrameWriter`). One JSON line per frame, tagged by `t`. A frame with bytes (`log`,
`blob`, `bundle`) adds `"len": N` to its line, and the bytes follow the line as one chunk: a 4-byte big-endian length,
then the bytes, at most 1 MiB (`MAX_CHUNK`). A writer refuses a bigger chunk before it sends anything, and a reader
refuses one before it reads it. Any frame may carry a chunk, so a side skips the bytes of a frame it doesn't know and
stays in step. A line is at most 16 MiB (`MAX_LINE`, a `finished` frame's `result.json`). An error ends the channel.

**Changes between versions.** Fields a side doesn't know are ignored, fields a side misses take their defaults, and a
`t` it doesn't know reads as `Frame::Unknown`. A `refuse` frame's structured reason that this side can't read is
`None`; its `why` text still arrives. So a new hub talks to the runner it just updated while the old bundle's
attempts run to their end.

**Every job frame carries a `JobRef`**: job, attempt and nonce. The nonce is 16 random bytes the hub makes when it
places the attempt, written as 32 hex digits; `Debug` shows only the first 8. A job frame without its whole `JobRef`
does not parse.

| Frame | Direction | Fields |
|---|---|---|
| `hello` / `hello-ok` | hub → runner / back | the version, the hub id; the bundle version, the runner id, the boot id, linger, the attempts in the runner's folder (`{r, state, log_offset}`, state `running`, `finished` or `lost`), what the contract finds missing (re-probed at every hello) |
| `probe` / `probe-result` | hub → runner / back | the facts (`linux::probe::Facts`), what is missing, why container caps don't hold (`check_limits`), the features |
| `ready` | runner → hub | free memory and CPU, PSI, running attempts, slots and images present |
| `offer` / `admit` / `refuse` | hub → runner / back | the job spec, its priority, the frozen input key, the grant hint and expected time; the grant; why not (text, and `forseti`'s `WaitReason`) |
| `sync-have` / `sync-need` / `blob` / `bundle` / `origin-fetch` | both | the commit, tree and overlay manifest (paths as raw bytes); the missing blobs and commit; a blob; a bundle chunk at its offset (the last with the bundle's hash); a fetch from the project's origin |
| `start` / `started` | hub → runner / back | the image, plain variables, the allowed hosts, the pinned names (`pins`, `[[name, address]]`, none from an older hub), the row parser; the unit |
| `log` | runner → hub | the offset, then the bytes, read from the attempt's log file, never from a pipe |
| `row` | runner → hub | a test row's name and verdict |
| `key` | hub → runner | a key's name and value (below) |
| `key-use` | runner → hub | the key a job asked for, and when |
| `finished` | runner → hub | the attempt's `result.json`: the only source of a verdict |
| `cancel`, `fetch`, `attach`, `done` | hub → runner | stop the attempt; send a file of it; after a reconnect, stream its log from the hub's offset and its end; the hub has the result, so the attempt's folder may go |
| `preempting`, `draining`, `idle` | runner → hub | when, since when |
| `ping` / `pong` | both | every 10 s |
| `bye` | both | a clean end: an EOF without it is `link-lost` |

**A key's value** (`KeyValue`, a `secrecy::SecretString`) has no `Clone`, and its `Debug` shows `<redacted>`.
`Frame::loggable()`, the only form of a frame a log line takes, is `None` for a `key` frame. The value serializes only
while the codec writes a frame (a thread-local flag the writer sets); anywhere else serde fails on it, so it can't
reach a log or a file by way of `serde_json`. The writer's and the reader's line buffers are zeroed after a key frame,
and the value is zeroed when the frame drops.

## serve

```
sleipnir serve --root DIR --prefix P --hub-id H --profile dedicated|workstation
```

The runner's end of the hub's control channel. It lives on stdin and stdout and exits at their end, at `bye`, or
after 45 s without a frame (the hub pings every 10 s, and so does `serve`). Nothing is installed or enabled: between
connections the runner has its folder and, with linger, the attempts still running in their own units. It is blocking
and threaded (one thread reads frames, the main loop handles them and ticks every 100 ms); no async runtime.

**The runner folder** (`--root`): `bin/<name>/` holds bundles (the `sleipnir` that serves names its own folder in
`hello-ok`, and runs every job-exec it starts); `jobs/<id>.<attempt>/` is an attempt's folder, its whole record:

| File | What |
|---|---|
| `attempt.json` | the hub id, the `JobRef` with its nonce, the spec, priority, grant and expected figures, the bundle its job-exec runs from, its unit |
| `job.json`, `log`, `result.json`, `kill_reason` | job-exec's (above) |
| `helper.sock`, `key.sock`, `proxy.sock`, `helper.pid`, `helper.log`, `disk-start`, `key-use`, `key-timeout` | the job helper's (above) |
| `drgnx-key`, `drgnx-fwd`, `net-allow`, `key-use.sent` | the job's own copies of the bundle's binaries, the hub's allow-list, the `key-use` lines sent |
| `src/`, `target/` | the job's source (mounted `ro,z`) and target dir, until slots come from sync |
| `cancelled`, `collected` | the hub cancelled it; the hub has its result (`done`), so the folder may go |

**`hello`** must come first; a hub id other than `--hub-id` gets `bye`. Each `hello` re-probes the runner contract
(`missing`) and linger (logind's live answer), and lists this hub's attempts from the folder: `finished` when
`result.json` is there, `running` while the unit is active, `lost` otherwise, each with its log's length. A `ready`
follows, then one every 2 s and at every job end: free memory and CPU from `forseti::budget` over the live machine
(this hub's running attempts counted, the others' through their reservations), PSI and the running attempts.

**`offer`** is admitted by `forseti::admit` under the machine's admission lock (`linux::reserve::with_admit_lock`):
it reads the machine with the others' live reservations, decides, sizes the grant (`forseti::size`) and writes the
reservation (`drgnx-<hub id>`, job `<id>-<attempt>`) before it lets go, so two schedulers never fit into the same
memory. The answer is `admit {grant}` or `refuse {why, reason}`. An offer whose folder exists is answered again from
it when it is the same placement (hub and nonce), and refused otherwise. While the memory ladder is above normal, no
offer is admitted. `forseti`'s 10 s gap between starts counts from this hub's latest start in the folder, so it
holds across `serve` processes.

**`start`** writes `job.json` (the shared podman argv, `RunnerArgs::runner(prefix, hub id, slice)`, in the job's
slice `drgnx-runner-work-<id>.slice`) and starts the unit `<prefix>-<id>-<attempt>` running `sleipnir job-exec` with
`RuntimeMaxSec` = the timeout + 60 s (job-exec's own timeout writes the verdict first). The reservation passes to the
unit's main pid, so it outlives `serve`. Then `started`. Every attempt gets its job helper (the disk watch); a keyed
one also its key mounts and `drgnx-key exec` (its spec's key names, each into the variable of that name), and one
with `net_hosts` its proxy, the hosts written to `net-allow` and checked first ("The job helper", "Keys"). What can't
start (no image, a parser it doesn't know, an allow-list entry that is never reached, a bundle without `drgnx-key` or
`drgnx-fwd`, and for now container variables) ends `infra: setup`, with the reason in the attempt's log; it is never
run another way. `key` frames go to the helper ("Keys"), and the helper's `key-use` lines come back as `key-use`
frames. The pins go into the job's caps (`Caps.pins`, as a local container job's come from
`drgnx-sandbox-proxy-pinned-addresses`); the job helper's proxy doesn't pin by them yet.

**Logs** are read from the attempt's log file by offset, never from a pipe: a new attempt streams from 0, and after a
reconnect the hub sends `attach {r, log_offset}` with where its own copy ends. When the attempt has its
`result.json` and its log is all sent, `serve` sends its rows (`row`) and `finished` with `result.json`, drops the
reservation, cleans up and sends `ready`. A unit that ended without job-exec's result was killed from outside: its
result is written as `infra: killed`. `cancel` writes `cancelled` and the kill reason, then kills the container, so
job-exec writes the verdict, which `serve` reports as `Cancelled`.

**The ladder** runs at every `ready` on the runner's slice tree: `tight` stops admissions; at `pressure` and
`danger` the scheduler holding the most memory (`forseti::ladder_actor`, over the reservations) evicts (dedicated) or
kills our newest (workstation), writing `evicted` or `infra: killed` before it kills the container. Pausing a long
build waits for live resizing.

**The cleanup**, at start, at every job end and at every `done`, removes only what is this hub's
(`serve::cleanup::plan`, pure):

- containers named `<prefix>-<id>` labelled `drgnx.runner=<hub id>` whose attempt doesn't run;
- this hub's ended units (named in its own attempt records) still loaded;
- this hub's job folders, collected or older than 24 h, whose attempt doesn't run;
- bundles put there before its own that no process runs from and no running attempt (of any hub) started from (a
  newer one is a hub's update, about to serve).

So two hubs on one runner, with one root and one prefix, never remove each other's containers, units or folders,
and an update keeps the old bundle while its attempts run.

## bench

```
sleipnir bench --root DIR --image DIGEST
```

How fast the runner is, for placement's finish-time estimates; the hub records the result in the runner's registry
record. A fixed workload runs in one capped container (1 core, 512 MiB, no network, the shared argv, in its own job
slice `drgnx-runner-work-bench.slice`, named `drgnx-bench-bench`): sha256 over 256 MiB, then 128 MiB written and
synced into `<root>/bench/target`. The container times both parts itself (podman's start-up isn't counted) and prints
them with its own `memory.max` and `cpu.max`. The result, as JSON on stdout:

| Field | What |
|---|---|
| `speed` | `REFERENCE_S` (2.0 s, a current desktop core with an NVMe disk) over the measured seconds: higher is faster |
| `cores`, `mem_mib` | the cores jobs may use and the machine's memory, from the probe |
| `link_hint` | the default route's interface speed in Mbit/s when the kernel knows it; the hub measures the link itself |

The run is bounded at 120 s, start-up included: past it the bench fails and removes its container. The caps it ran
under go to stderr.

## Tests

`cargo test -p sleipnir --no-default-features --features linux` runs the pure rows: the contract's refusals from
`podman info` fixtures, the kernel's file formats, the reservation round trip and the presence of another scheduler,
the argv's fixed flags and the runner mount set, the shim, the unit's properties, the parsers, `result.json` and the
kill reason's precedence. `--features proto,sync` (the Android shape) runs sync's rows: the capture, the hardened
git, the slots and their escape rows, each with temp repositories and real git. `--features proto` alone runs the
protocol's rows `[D]`: every frame round-trips, unknown fields and frames are ignored, a key frame is never loggable
or printed, chunks over 1 MiB are refused, a job frame without its nonce doesn't parse, and a property that the reader
never panics on any bytes. The default features add `serve`'s rows: admission waits for the admission lock and
writes the reservation another scheduler then counts (`[B]`, the lock as the gate), the cleanup's plan matches
prefix and label only (`[D]`), and the bench's readings, speed, result shape and capped argv (`[D]`). The bench's
runner-host row (`bench_runs_capped_and_under_2_minutes`, `[C]`) needs the default features: build `runner_host`
without `--no-default-features` for it.

`tests/fleet_serve.rs` plays the hub over real SSH to a real `serve` in the fake fleet (`#[ignore = "fleet"]`,
`test/runners/README.md`, "Fleet rows"), every row `[C]`: a new `serve` lists the running attempt after a cut
channel and reattaches it; `serve` ends at `bye` and at an EOF and leaves nothing enabled, loaded or written outside
its root; two hubs on one root and prefix never clean each other's; an update keeps the old bundle while its job runs;
the log after a reconnect comes from the file by offset, byte for byte; linger is reported at every `hello`.

`tests/runner_host.rs` holds the rows that need a real user manager, cgroups and podman. They are
`#[ignore = "runner-host"]` and run only inside a fake runner (`test/runners/README.md`), never on a developer's
machine: build the test binary, then `fleet.sh host <binary> [FILTER]` runs it with `--ignored` in every runner (and
takes the `sleipnir` binary along for the job-exec rows). A child process such a test needs is the test binary again,
running one of the file's `child_*` entries. The rows: the fake runner's own checks (`fleet.sh s1`), two admissions
against one budget, a dead pid's reservation, the slice tree taking a container (cgroup path, cpusets both ways, the
cap, OOM scores), the cap's step ending in a kernel OOM below oomd's limit, a job in its own slice, an OOM as `oom`, a
keyed job without `memory.swap.max` 0, and a job outliving its starter.

`tests/runner_host_sync.rs` holds sync's runner-host rows, built with `--features test-hooks` and run the same way:

- `origin_fetch_with_a_token_leaves_no_file`: a fetch from a smart-HTTP origin (git's `http-backend` behind a small
  server in the test) that answers only with the token; afterwards no file under the runner folder, `/tmp` or the
  runner's home holds the token or its Authorization header;
- `push_into_the_mirror_runs_no_hook`: a push through `sleipnir git-receive` into a mirror with every receive hook
  planted, and a planted `core.hooksPath`, runs none of them; a path outside the mirrors is refused;
- `guard::a_symlink_planted_in_a_cache_is_never_followed`: links in a cache to a sentinel outside the root, and links
  where a cache or project folder belongs; after a scan, plan and apply below the floor the cache is gone, the
  sentinel is untouched, and a prune through a planted link is refused;
- `guard::never_removes_an_image_we_did_not_pull`: the fake runner's base image (not ours) and an imported image
  recorded as ours; only ours goes, and not while a queued job names it;
- `origin_fetch_with_a_deploy_key_leaves_no_file_and_no_agent`: real `sleipnir sync-fetch` children (a test-hooks
  mode taking the deploy key on stdin) fetch over `ssh://` through a fake `ssh` first on PATH, which records what the
  per-fetch agent holds, parks on a FIFO while the test scans the runner folder, `/tmp` and the home for the key, then
  runs `git-upload-pack` on a local origin. The agent holds the key, no file does, and after the fetch the agent's
  socket and process are gone; the same after a fetch the origin fails and after a key the agent can't load.

`tests/runner_host_helper.rs` holds the job helper's runner-host rows (`--features test-hooks`, default features),
each `[C]`: the helper is not dumpable (its `/proc` files aren't its user's, unlike a plain child's); `drgnx-key`
waits for a key, exits 75 having printed nothing and finds the helper's record there, then gets the key once it is
handed over; a keyed container's command has the variable in its own `/proc/<pid>/environ` while `podman inspect`, the
container's stored config and runtime state hold the names only; the helper started by job-exec runs in the job's
unit and slice and dies with the unit; and below the floor (the folder's `test-machine.json`) the job that grew most is
stopped `infra: disk` before any other. The unit rows `[D]`: a key frame's value held in a locked buffer that is all
zeros just before it is unmapped, only listed names taken or served, the allow-list's metadata and link-local refusals
and the proxy's `403` for a listed name that resolves link-local, the disk watch's pick, the key-timeout record's
verdict, and `drgnx-key exec` in the argv with names only.

`tests/fleet_sync.rs` holds sync's fleet rows (`#[ignore = "fleet"]`), run from the fleet's harness over real SSH
(`fleet.sh test 'sync::'`, with the `sleipnir` binary in `/fleet/share`). `sync::a_dropped_bundle_resumes_not_restarts`
sends a 10 MiB bundle, cuts the link at 40 % once the runner has announced that offset, reconnects, and checks that the
runner resumes there: at most 60 % plus 1 MiB is sent again, and the commit arrives in the mirror.
