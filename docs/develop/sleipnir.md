# sleipnir: the runner

`runtime/crates/sleipnir` is what runs jobs on a machine: the hub's own (local) machine, the user's other machines
over SSH, and jobq's. It is a library, shared by the hub, the runners and jobq, and (later) the `sleipnir` binary.
The scheduling decisions are [`forseti`](forseti.md)'s; sleipnir reads the machine for them and carries them out.

## Features

| Feature | What | Dependencies |
|---|---|---|
| `linux` | the machine probe, the reservation files, the executor | std, rustix, libc, serde, `forseti`; blocking, never tokio |
| `sync` | input capture, the hardened git, slots | blocking, never tokio |
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

## Tests

`cargo test -p sleipnir --no-default-features --features linux` runs the pure rows: the contract's refusals from
`podman info` fixtures, the kernel's file formats, the reservation round trip and the presence of another scheduler.

`tests/runner_host.rs` holds the rows that need a real user manager, cgroups and podman. They are
`#[ignore = "runner-host"]` and run only inside a fake runner (`test/runners/README.md`), never on a developer's
machine: build the test binary, then `fleet.sh host <binary> [FILTER]` runs it with `--ignored` in every runner. A
child process such a test needs is the test binary again, running one of the file's `child_*` entries.
