# sleipnir: the runner

`runtime/crates/sleipnir` is what runs jobs on a machine: the hub's own (local) machine, the user's other machines
over SSH, and jobq's. It is a library, shared by the hub, the runners and jobq, and the `sleipnir` binary (its `job-exec` mode so far).
The scheduling decisions are [`forseti`](forseti.md)'s; sleipnir reads the machine for them and carries them out.

## Features

| Feature | What | Dependencies |
|---|---|---|
| `linux` | the machine probe, the reservation files, the executor | std, rustix, libc, serde, `forseti`; blocking, never tokio |
| `sync` | a job's inputs, the hardened git, checkout slots | std, rustix, `sha2`; blocking, never tokio |
| `proto` | the wire protocol | pure |
| `runner` (default) | the binary's modes | all of the above |
| `test-hooks` | test-only entry points | compiled away otherwise |

jobq depends with `default-features = false, features = ["linux", "sync"]`, so no async runtime reaches it. The
Android check builds `--no-default-features --features proto,sync`.

**Platforms.** systemd and the cgroup files are a desktop-distro fact: `linux::probe`, `linux::reserve` and the
executor's systemd parts are `target_os = "linux"` only. Android (`target_os = "android"`) has no user manager to run
jobs under, so it gets none of them, and a runner there refuses every job rather than run one unconfined.

## The machine probe (`linux::probe`)

`Probe` holds where it reads (`/proc`, `/sys`, the user manager's cgroup, `$XDG_RUNTIME_DIR`, the runner folder), so
tests point it at fixture trees; `Probe::system(name, scheduler, slice_root, folder, profile)` is the real machine.

- **`machine(now, limits) -> MachineState`**: `MemTotal` and `MemAvailable`; PSI `avg10` of system memory and CPU
  `some` and IO `full`, and the user's apps' memory `some` (`app.slice/memory.pressure`) when the limits read it
  (the workstation profile); disk free and size of the runner folder's filesystem (`statvfs`); mains power; the boot
  id; and the other schedulers' live reservations (below). What runs is the scheduler's to fill in.
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

The verdict is `forseti::classify` over what job-exec saw: the kill reason, `oom_kill`, the exit code or signal, the
timeout and the row parser's judgement.

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

## Tests

`cargo test -p sleipnir --no-default-features --features linux` runs the pure rows: the contract's refusals from
`podman info` fixtures, the kernel's file formats, the reservation round trip and the presence of another scheduler,
the argv's fixed flags and the runner mount set, the shim, the unit's properties, the parsers, `result.json` and the
kill reason's precedence. `--features proto,sync` (the Android shape) runs sync's rows: the capture, the hardened
git, the slots and their escape rows, each with temp repositories and real git.

`tests/runner_host.rs` holds the rows that need a real user manager, cgroups and podman. They are
`#[ignore = "runner-host"]` and run only inside a fake runner (`test/runners/README.md`), never on a developer's
machine: build the test binary, then `fleet.sh host <binary> [FILTER]` runs it with `--ignored` in every runner (and
takes the `sleipnir` binary along for the job-exec rows). A child process such a test needs is the test binary again,
running one of the file's `child_*` entries. The rows: the fake runner's own checks (`fleet.sh s1`), two admissions
against one budget, a dead pid's reservation, the slice tree taking a container (cgroup path, cpusets both ways, the
cap, OOM scores), the cap's step ending in a kernel OOM below oomd's limit, a job in its own slice, an OOM as `oom`, a
keyed job without `memory.swap.max` 0, and a job outliving its starter.
