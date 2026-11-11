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
  mem_available_mib, on_ac}`, each optional) stands in for those figures: a fake runner shares its host's pressure
  files, memory, disk and power supplies, so the fleet rows set a quiet machine on mains power instead of admitting
  on the host's load (or refusing a `workstation` job because the host shows a battery). A file that doesn't
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
| a login other than root (uid 0) | add the runner as an ordinary user |
| a login not confined as SELinux `user_u` (`user_t`, read from `/proc/self/attr/current`: `linux::confined`) | map the login to another SELinux user (`semanage login -m -s staff_u LOGIN`), or a subuid range plus a local policy module letting `user_t` run `newuidmap` |
| a systemd user manager | log in, or `loginctl enable-linger` |
| rootless podman ≥ 5 | install or upgrade podman; connect as an ordinary user |
| cgroup v2 | the unified hierarchy (the default on current distributions) |
| podman on the systemd cgroup manager | `cgroup_manager = "systemd"`, with a user manager running |
| `memory pids cpu` delegated to the user | a `user@.service.d/delegate.conf` drop-in, then log in again |
| git | install git |

There is no reduced mode. A `user_u` runner that passed once (its login remapped later) is refused at each job's start
too: the attempt ends `infra: setup` with the same reason. Linger is a fact, not a refusal: without it, jobs end when the link drops, and the runner
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
  `/proc/<pid>/stat` field 22, so a reused pid doesn't count) and on the boot it was written in. On a Mac the start
  time is `proc_pidinfo`'s (microseconds since the epoch), and the directory is under the runner root.

## A Mac runner (`darwin`)

A Mac with Apple silicon, in a standard account of its own (`drgnx-runner`), runs host jobs under Seatbelt; no
containers, no keys. Its probe (`darwin::probe`) reads the machine once into a `Raw` (`read`, macOS only: `sw_vers`,
`sysctl`, `pmset -g batt`, `dseditgroup`, `xcode-select -p`, `/usr/bin/clang --version`, one `brew list --versions`,
`statvfs` of the runner root, and Gleipnir's check of `/usr/bin/sandbox-exec`); the rest is pure and tested on
fixtures on Linux.

**The Mac contract** (`contract`), refused with the whole list: macOS 15 or newer; Apple silicon
(`hw.optional.arm64`, so a Rosetta shell passes); a root-owned `sandbox-exec`; the standard (non-admin) account `drgnx-runner` (`id -un`, `dseditgroup`): another
account only with `--allow-own-account`, an administrator only with `--allow-admin` (each refusal names its flag and
what it exposes), root never; the
Command Line Tools answering, with a full Xcode's licence accepted (`clang`'s refusal names it, its own item); `mise`
from Homebrew; 40 GB free on the runner root's volume. **Facts**: `os` `macos 15.6`, `arch` `aarch64`, cores (`hw.ncpu`), memory, disk,
battery; the Linux-only fields false. **Features**: `arch:aarch64`, `host-jobs`, `xcode-clt`, and `brew:<name>@<major>.<minor>`
for each Homebrew package at its newest installed version (and `brew:<name>` alone), `tool:<name>@<version>` for
each toolchain record under the root, and `account:admin` / `account:own` for an account taken by an allowance (the
runner list shows what it exposes; a Linux runner's `account:admin` is a login in `wheel` or `sudo`). The boot id is `kern.bootsessionuuid`.

**Toolchains** (`darwin::tools`, `sleipnir tools --root DIR PIN...`). The hub runs it at `runner add` and
`runner check`, as the runner account and outside any job (mise downloads from hosts a job isn't granted). For each pin
(`rust@1.95`) the user's Homebrew `mise` runs `install` and then `env --json` in the root, with mise's data, state,
config and cache folders and Rust's `RUSTUP_HOME`/`CARGO_HOME` all under the root, so nothing lands in the account's
home; the record `<root>/tools/env/<pin>.json` keeps the folders mise put on `PATH` and its other variables (never
mise's own or the job's). It prints the outcomes and the features as JSON. A job placed with `tool:` features reads
`<root>/tools` (never writes it), gets each record's folders first on its `PATH` and its variables where the job sets
none; a feature without a record fails the launch with its name.

**Attempts** (`darwin::attempt`, `darwin::jobexec`, `darwin::sandbox`; `serve::platform::DarwinPlatform`). launchd
takes no job from an ssh login (its Background session refuses `launchctl bootstrap user/<uid>`), so `launch` starts
`sleipnir job-exec <dir>` with `setsid`, in a session of its own that outlives the link (on a workstation at nice 10,
which every process of the job inherits: Linux's CPU and IO weights of 20), and writes
`job-exec.pid` (`<pid> <start time>`, atomically); its own early errors go to `job-exec.log`. The attempt is active
while that pid has that start time (a reused pid is not), and `kill` is SIGKILL to its process group (job-exec and
whatever stayed in it); a process that left the group is the watchdog's to find, by session and marker. However a
job ends (by itself, its timeout, a kill reason), job-exec kills what is left of it once the result is written: the
session and the marked processes the watchdog's scan finds, then its own group. job-exec
runs the command only as `/usr/bin/sandbox-exec -f job.sb …` and refuses anything else (a keyed job, a helper other
than its proxy, a bare command) as `infra: setup`, so a job never runs unconfined. `job.sb` is Gleipnir's profile of the attempt's
spec (`darwin::sandbox::spec`): it reads the source and the runner's programs (`<root>/bin`), writes only `HOME` and
`TMPDIR`, both inside the attempt folder (and the source when the job writes its tree; never the attempt folder
itself, whose `job-exec.pid`, `kill_reason` and `result.json` are job-exec's), `PATH` the brew shim's folder,
then Homebrew's and the system's (after its toolchains'), the marker
`DRGNX_RUNNER_ATTEMPT`, Homebrew read-only (`HOMEBREW_NO_AUTO_UPDATE` and the like; `HOMEBREW_NO_INSTALL_FROM_API`, so formulae load from the
installed kegs instead of a JSON API fetch, which needs the network and a lock in Homebrew's var; its cache, logs and temporary
files in the attempt's tmp: a configure asks `brew` where a package is), and no network but its proxy's (below). Every job a Mac runner takes is a
build or a test, so its profile has Gleipnir's build addition (`darwin::sandbox::mac_context`: the developer dir and
the account's per-user folder, `getconf DARWIN_USER_DIR`'s parent, by true name; docs/develop/gleipnir.md, "The build
addition"); a per-user folder that can't be resolved refuses the launch. The timeout is read on `CLOCK_MONOTONIC`, `caffeinate -i -w` keeps the Mac
awake while the job runs, and the verdict comes from `forseti::classify` like Linux's. A Mac has no pause, live
resize, CPU weights or keys: those methods answer none or refuse.

**A Mac job's network** (`darwin::proxy`). A job the hub grants hosts (its `net_hosts`) gets Gleipnir's CONNECT proxy
with that allow-list (`crate::net`, shared with Linux's job helper: no metadata service, no address that isn't public,
connections only to public addresses), served by its own job-exec on a loopback port for the job's life; a Mac has no
network namespace and no relay sidecar. `launch` checks the list, writes it to the attempt's `net.allow`, binds
`127.0.0.1:0` and starts job-exec with that listener kept open (every other descriptor is close-on-exec), naming the
descriptor and port in `job.json`'s helper. The port is in the job's profile as its only network (outbound to
`localhost:<port>`) and in its `HTTP(S)_PROXY` variables, `NO_PROXY` the loopback names. job-exec takes the listener
only if it is on `127.0.0.1:<port>`, makes it close-on-exec again so the job never holds it, and serves it on a thread
of its own; a proxy that can't start fails the job `infra: setup`, and a refused request is logged in
`job-exec.log`. Binding in `serve` means no other process can take the port between the profile and the proxy. The
loopback is the whole Mac's: while the job runs, another local process could reach the job's allow-listed hosts
through the port, and nothing else.

**Homebrew in a job** (`darwin::brew`): offline and read-only, Homebrew can't name a package's prefix. `brew --prefix
--installed NAME`, which Emacs's configure asks for libgccjit, loads the formula from the JSON API (a download, under a
lock in Homebrew's var) or, with `HOMEBREW_NO_INSTALL_FROM_API`, from the homebrew/core tap (a `git clone` into
Homebrew). So a Mac job's `brew` is the runner's shim: `<root>/bin/brew-shim/brew`, a link to the runner's `sleipnir`
(the launch makes it, `brew::ensure_shim`), first on the job's `PATH`; `sleipnir` started as `brew` is the shim. It
answers the offline queries from the prefix's folders: `--prefix`, `--prefix [--installed] NAME…`
(`/opt/homebrew/opt/NAME`; with `--installed`, one that is missing fails) and `--cellar [NAME…]`. What needs the network
or writes Homebrew (`install`, `upgrade`, `update`, `tap`, `uninstall`, `fetch`, `link`, `cleanup` and the like) fails
at once with a message naming the shim. Everything else (`ls`, `list`, `--version`, `config`, a query with an option the
shim doesn't know) runs the real `/opt/homebrew/bin/brew` with the read-only environment above; if it fails, a line
naming the shim follows brew's own error, so no call fails silently.

**The memory cap** (`darwin::memwatch`): no kernel enforces a Mac job's grant, so job-exec's watchdog does. Every
500 ms it lists the processes and takes the job's: job-exec's session less job-exec (a job-exec that leads no session,
a test or a hand run, starts the command in a session of its own and takes that), plus processes of the runner's user
outside it born after the command that carry `DRGNX_RUNNER_ATTEMPT=<hub>/<job>/<attempt>` (`KERN_PROCARGS2`). It sums
their `ri_phys_footprint` (`proc_pid_rusage`; the resident set on Linux, where the rows run). Past the cap, the
grant less 192 MiB (the overshoot the spike measured at this tick, rounded up; never under half the grant), it
SIGKILLs every one: the verdict is `oom` (the kill counts as the job's own OOM, never `red` and never `infra`), and
`result.json`'s `mem_overshoot_mib` records the peak past the grant for every Mac job (none on Linux, where the kernel
caps it). A Mac has no job helper (no keys; job-exec serves the proxy), so job-exec also runs the disk watch (`linux::disk`,
every 10 s, `disk-start` written before the command): below the floor, the running job that grew most is stopped
`infra: disk`. **The sweep**: setsid loses launchd's group cleanup, so a Mac's `cleanup` (at start and after each job)
first SIGKILLs the runner user's processes whose marker names this hub and an attempt that no longer runs
(`memwatch::strays`); another hub's are left alone.

**Machine-wide pressure** (`darwin::pressure`): a Mac has no PSI, so `DarwinPlatform::pressure` answers the
kernel's own event instead (a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source, the level read once at start; no polling),
and `serve`'s ladder takes it in place of `forseti::ladder_level`: *warn* is `tight` (no offer admitted), *critical*
is `danger`, where a kill the ladder calls for becomes an eviction (requeued, no strike: the pressure is the user's
own load). Linux's platform answers none and keeps PSI (`the_platforms_pressure_event_sets_the_ladder`).

## The podman argv

`linux::podman::argv(req, caps, runner_args)` is the one builder of a `podman run` line, used by the hub's own container
jobs (`exec/container.rs` calls it with `RunnerArgs::local(owner_tag)`) and by the runners. It is pure and builds on every
target, so a hub on macOS uses it too. Fixed for every job: `--rm`, `--pull=never`, `--userns=keep-id`,
`--cap-drop=all`, `--security-opt=no-new-privileges`, `--read-only`, `--tmpfs /tmp`, the pids, memory and CPU limits,
`--memory-swap` equal to `--memory`, `--oom-score-adj=1000`, `--cgroup-conf=memory.oom.group=1`, `--network=none`, a
digest-pinned image from the allow-list, and the command after the image, where podman reads no options. Every job container
carries its owner's labels (`drgnx.owner=<tag>` on a hub, `drgnx.runner=<hub id>` on a runner, and `drgnx.job=<id>`), so
a sweep finds exactly its own; `RunnerArgs.job_labels` turns them off. A granted network (`Caps.proxy`, a `JobNet`
naming the job's sidecar) replaces `--network=none` with `--network=container:<sidecar>`: the job shares the relay
sidecar's loopback-only network namespace, and gets the proxy variables (`HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`,
`https_proxy` = `http://127.0.0.1:3128`; `NO_PROXY`, `no_proxy` = `localhost,127.0.0.1,::1`) and nothing else: no mount,
no `--dns`, no `--sysctl net.*` (crun refuses them in a joined namespace), no entrypoint. `argv` refuses a sidecar that
is not the one `net_names` gives this job.

`net_names(ra, job)` gives the sidecar's name, `drgnx-px-<tag>-<job>` on a hub and `<prefix>-px-<job>` on a runner (a
runner prefix that could reach the hub's `drgnx-job-` or `drgnx-px-` names, or another runner's `…-px-` sidecars, is
refused), and the labels. `sidecar_argv(names, ra, image, keys)` is the sidecar's line: `run -i --rm --pull=never
--log-driver=none --detach-keys= --user 65534:65534`, no capabilities, read-only, 32 pids, `128m` memory and swap, one
CPU, `--ulimit core=1` (no core: below), `--network=none`, never `-t` (a tty would rewrite the frames' bytes), and
`--listen 127.0.0.1:3128 --job-ip 127.0.0.1` after the image, plus `--keys drgnx-key` for a job with keys ("Keys").
A job with keys always gets a sidecar, with network or without (then its proxy's allow-list is empty). `--detach-keys=` stays: podman scans a piped stdin for its detach sequence, and a match
would close the channel. The sidecar runs in podman's default user namespace (no `keep-id`).

On a runner (`RunnerArgs::runner(prefix, hub_id, slice)`) the container is named `<prefix>-<id>`, labelled
`drgnx.runner=<hub id>` (the runner removes only containers with both), and placed with `--cgroup-parent=<job slice>`:
without it, podman puts a container started from a unit under `user.slice`, outside the job's slice. Its mounts are
exactly this set (`RunnerMounts`), nothing else:

| Mount | Inside | Mode |
|---|---|---|
| the source: the slot, or a writer's private copy | `/work` | `ro,z` (`rw,Z` for a `writes_tree` copy) |
| the slot's target dir | `/target` (`CARGO_TARGET_DIR`) | `rw,Z` |
| each cache the suite declares | its own absolute path, never under `/work`, `/target`, `/tmp` or `/run/drgnx` | `rw,Z` |
| `drgnx-key` | `/run/drgnx/key` | `ro,Z` |

A keyed job (`KeyMounts.vars`, each `(key name, variable)`) runs as `drgnx-key exec NAME=VAR… -- CMD`: `drgnx-key` is
the entrypoint, with or without network.
The argv names the keys and variables only; a name or variable that isn't plain is refused. The job's request has no
field to put anything around the command.

`check_limits(podman, env, limit)` asks `podman info` and refuses container jobs unless the caps hold (cgroup v2, the
systemd manager, `memory pids cpu` delegated); `limits_enforced(info)` is its pure half. It answers the parsed
`podman info`, which `linux::netcheck::net_ready(info)` reads for a networked job: podman 5.0 or newer and rootless
(on macOS, the machine's podman; its rootless connection is checked where the hub picks it), each refusal in the
design's words ("Networked container jobs need podman 5.0 or newer; this host has `4.9.4`.", "drgnx runs containers
rootless; this podman is rootful."). A job without network never runs it.

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
`infra: key not delivered`, never the job's own failure; a written kill reason still comes first. A scheduler that
pauses or evicts a job first leaves `disturbed` in its folder (`jobexec::disturbed(dir, why)`): the result says
`disturbed: true` (its time is no fair sample), and a red becomes `Suspect`, to be run again undisturbed.

### Live resizing (`linux::resize`)

The moves on a running job that never throttle it (the job scheduler's "grow and shrink while running"):

- **Grow.** When the container's `memory.current` passes 85 % of its cap and the machine has room, the cap grows by a
  quarter (at least 256 MiB), never past the job's `mem_mib.max` and never past the room: the budget now, and, on
  the machine where the backfill head has its reserved start, what the head still needs then (`Head::of` takes the
  reservation and `forseti::budget_at` at its start; the grow is taken from that budget). `grow(job, budget, head)`
  decides; `apply` carries it out.
- **Through the unit, never behind systemd.** `apply` sets the container's systemd scope (`set-property --runtime …
  MemoryMax=`) and the container (`podman update --memory M --memory-swap M`, so still no swap), in the order that
  keeps the scope at or above its container: scope first for a grow, container first for a shrink. No cgroup file is
  written by sleipnir.
- **A shrink below use is refused.** `shrink(job, to)` refuses a cap under the container's use, and `apply` reads the
  use again just before a shrink and refuses it then too, never forcing the kernel to reclaim or kill.
- **CPU weight.** `weights(running, waiting_p12)`: while P1–P2 jobs wait for CPU, the running P4–P5 job slices get
  `CPUWeight=20`; once they no longer wait, 100 again.
- **Pause.** At the ladder's pressure level a dedicated machine pauses its lowest-priority long builds (`podman
  pause`, the cgroup freezer) and lets them go on once the pressure is gone; a workstation never pauses.

In `serve`, a grow is judged under the admission lock (`admit::grow`) against the machine as it is, the others'
reservations counted; once applied, the job's reservation holds what it added, so no scheduler admits into it, and the
grown grant is written to the attempt's `attempt.json`. A grow that can't be applied leaves the reservation as it was.
The hub's head reservation reaches the runner it is on as a `head` frame (the head's start and need; `at` 0 once it
holds there no more; the queue sends it after a tick when it changed, and again after a hello,
`runners::queue::tests::the_heads_runner_hears_its_reservation`): a grow there also leaves what the machine will have
at the head's start (`forseti::budget_at`, from the running jobs' expected ends) minus the head's need
(`admit::HeadHere`, `a_grow_leaves_the_hubs_head_its_room`). CPU weights
follow the offers: a P1–P2 offer refused for CPU since the last `ready` makes the P4–P5 jobs yield at the next one.
Builds count as long builds for the ladder.

## The job helper (`helper`)

```
sleipnir job-helper --dir D [--hub-allow FILE]
```

One per attempt, owning what the job may use and must never keep. job-exec starts it inside the job's unit (so in
its slice, capped at no swap), and it reads job-exec's pipe: when job-exec ends, or the unit stops, the helper goes
with it. Nothing outlives the job, so no daemon is left behind, and `serve` may end with the link while it runs. It:

- sets `PR_SET_DUMPABLE=0` and `RLIMIT_CORE` 1 (soft and hard) first: no core dump (a piped `core_pattern`, as
  systemd-coredump's, ignores a limit of 0 but honours 1, and with `fs.suid_dumpable` 2 dumps a process that isn't
  dumpable), and no other process of the user can read its memory or `/proc` files. Its children inherit the limit
  (so the sidecar's `--ulimit core=1` is not a raise, which crun would be refused);
- takes the job's keys from `serve` on `D/helper.sock` (0600, this user only) and answers the job's requests for them
  through the job's relay sidecar ("Keys" below);
- with `--hub-allow`, or for a job with keys, starts the job's relay sidecar (`helper::net::Relay`: `podman` with the
  `job.json`'s `helper.sidecar_argv`, named `helper.net.sidecar`, `<prefix>-px-<id>`), waits for its `READY` before its
  own `ready` line, and runs Gleipnir's CONNECT proxy on the relay's proxy streams (`Listener::Streams`, `max_conns`
  128) with the hub's allow-list (empty for a job with keys and no network), and the key answers on its key streams
  (`owner::run_keyed` with `net::KeyServer`). A relay that ends before the job writes `kill_reason` `infra: proxy: <reason>` (the sidecar's exit code
  and its meaning, its last stderr line), removes the job's container, then stops the sidecar; at the job's end the
  helper removes the job's container before the sidecar. An
  entry naming `metadata.google.internal`, `169.254.169.254`, `fd00:ec2::254` or any address that isn't public is
  refused, no name is pinned, and the proxy connects only to public addresses, so a listed name that resolves to
  `169.254.x` gets `403` too. (The agent browser's `METADATA_NEVER` replaces this list once both are on one line.)
- watches the runner folder's disk every 10 s (`linux::disk`, which a Mac's job-exec runs itself). Below the floor (the larger of 20 GB and 10 % of its
  filesystem, `forseti`'s disk guard) the job that grew most since its start is stopped: its helper writes
  `kill_reason("infra: disk")` and kills its container. A job's growth is its attempt folder's size less its size
  when its helper started (`disk-start`); every helper sums the same running attempts, so only one acts per reading
  and they agree which. In a test build the floor reads the folder's `test-machine.json` too.

Its socket appears at once (bound under a temporary name, then renamed); then it writes `helper.pid` and prints
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
3. `drgnx-key` (std only, so its static build starts in any image) asks on the abstract socket `@drgnx-key`
   (`DRGNX_KEY_SOCK` names another: `@NAME` or a path):
   - `drgnx-key exec NAME=VAR… -- CMD` reads each key into VAR, in its own environment only, and execs CMD;
   - `drgnx-key get NAME` writes one key to stdout.
   The job's sidecar (`--keys drgnx-key`) binds that name in the network namespace it shares with the job, before its
   `READY` (a name already taken exits 2, so a job can never squat it first), and carries each connection to the
   helper as a key stream (docs/develop/drgnx-px.md, "Key streams"): one request of at most 512 bytes, one answer. An
   abstract name lives in its network namespace only, so no other job, no other namespace and nothing on the host
   reaches it, and no file, socket label or SELinux rule is involved: it works the same for an unconfined user and a
   confined `staff_u`. The helper builds each answer (`keys::answer`: `ok LEN` and the value) in a `Locked` buffer,
   sends it, and zeroes it; px zeroes every buffer a key stream's bytes pass through.
   A request waits for its key up to 60 s. When it doesn't come, the helper records the name in `D/key-timeout`
   first, then answers `timeout`, and `drgnx-key` exits 75; `result.json` reads the record as `infra: key not
   delivered`. A name the job doesn't list is refused at once (exit 64).
4. Each delivered read is a line in `D/key-use` (the name and the time); `serve` sends each line once as a `key-use`
   frame (`key-use.sent` counts them, across reconnects).
5. Podman's argv, its stored config and `podman inspect` show the names only. Neither `podman run --env` nor podman
   secrets are used: both end up in podman's stored config or in files.

`serve` gives every keyed job its own copy of the bundle's `drgnx-key` in its attempt folder, since each container
relabels what it mounts (`Z`). The job helper owns the channel of every job with keys: every keyed job is a runner job
(a keyed job never runs on the hub's machine); the hub's own exec jobs never carry keys, and their network goes through the
hub's `JobNetwork` (docs/develop/hub.md). A sidecar's image is imported from the bundle's
`drgnx-px-<arch>-linux-musl` (tagged by content) when `serve` launches it; under Q8 `serve` creates no network.

## The runner bundle

`bin/drgnx build runner-bundle [--arch x86_64|aarch64]` builds `sleipnir`, `drgnx-key` and the relay sidecar `drgnx-px` (kept in the bundle as `drgnx-px-<arch>-linux-musl`) static (Rust's
self-contained musl targets, release) into `runtime/target/bundle/<arch>/`, and checks each with `file`. The host's
architecture is the default; `install.sh` builds that one, and CI's container lane builds both. `tests/bundle_host.rs`
(`#[ignore = "bundle"]`, with `DRGNX_TEST_BUNDLE` and a musl image in `DRGNX_TEST_FOREIGN_IMAGE`) checks each binary
is static and runs `drgnx-key` in an image of another libc.

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
filesystem can (`CopyKind::Reflink`: `FICLONE` on Linux, APFS `fclonefileat` on a Mac) and copies it otherwise
(`CopyKind::Plain`). Files keep their mode and mtime,
links are copied as links, and `dest` must not exist.

`Locks::of(paths)` takes `flock`s on files in the git dir, so they hold across processes and go with a process that
dies:

- `read` is shared and marks the slot used;
- `try_update` (a move, `gc`, the disk guard's prune) is exclusive, `None` at once while anyone reads;
- `target` is exclusive, for a job that builds into the target dir (`try_target`: `None` instead of waiting).

`hold(paths, inputs, move_to)` is a job's read lock on its slot at its input key: the slot's git dir records the key
it holds (`inputs`, written under the update lock after `move_to`, removed before it); a slot at other inputs is
moved only when `try_update` gets it, so a slot any job reads (a job of another hub on the same root too) is never
moved under it, and the answer is `None`. A lock can't turn from exclusive to shared in one step on Linux, so after a
move the slot is read and checked again. `serve` holds its job's lock from the checkout until the result is there;
the job's job-exec takes its own at its start (`hold_for_job`, on the slot the attempt's `slot-hold` names:
`write_job_hold`), and refuses to run, `infra: setup`, when the slot moved meanwhile (its `serve` gone before
job-exec started). A job that writes the tree reads its own copy, so its hold ends after the copies.

Locks can't be handed to job-exec: a systemd-run unit inherits no file descriptor. A lock belongs to its open file description, which a
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
`Store::missing`, `Mirror::has_commit` and `Mirror::ref_tips` answer a `sync-have`, `Receiver::offset` and `append`
take a `bundle`, and `fetch_origin` serves an `origin-fetch` ("serve" below). `sleipnir sync-bundle` (`test-hooks`
only) takes one bundle on stdin and announces `at OFFSET` after every chunk, for the fleet row.

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
`returned`, `blob`, `bundle`) adds `"len": N` to its line, and the bytes follow the line as one chunk: a 4-byte big-endian length,
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
| `ready` | runner → hub | free memory and CPU, PSI, running attempts, slots and images present, `on_battery` |
| `offer` / `admit` / `refuse` | hub → runner / back | the job spec, its priority, the frozen input key, the grant hint and expected time; the grant; why not (text, and `forseti`'s `WaitReason`) |
| `head` | hub → runner | the queue's head is reserved here: its start (`at`, 0 when no longer) and its memory and CPU need, which a grow here leaves |
| `sync-have` / `sync-need` / `blob` / `bundle` / `origin-fetch` | both | the repository's mirror id, the commit, tree and overlay manifest (paths as raw bytes); the missing blobs and commit, and the mirror's ref tips; a blob's chunk at its offset of its total; a bundle chunk at its offset, each with the bundle's hash; a fetch from the project's origin (with `cred`: through the key of that name, sent before it) |
| `start` / `started` | hub → runner / back | the image, plain variables, the allowed hosts, the pinned names (`pins`, `[[name, address]]`, none from an older hub), the row parser; the unit |
| `log` | runner → hub | the offset, then the bytes, read from the attempt's log file, never from a pipe |
| `returned` | runner → hub | what the attempt gives back (`what`: `patch` or `outputs`), a chunk at its offset of its total, with the whole's sha256; the first chunk lists what was left out (`left`, `[[path, why]]`); `kept`: over its limit, no bytes, it stays on the runner |
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
sleipnir serve --root DIR --prefix P --hub-id H --profile dedicated|workstation [--watchdog DIR]
               [--allow-own-account] [--allow-admin]
```

The runner's end of the hub's control channel. On a cloud machine `--watchdog DIR` names the watchdog's folder ("The
watchdog"). `--allow-own-account` and `--allow-admin` are what the user allowed at `runner add` (kept in the runner's
record): the Mac contract reads them; Linux takes an administrator's login without them. It lives on stdin and stdout and exits at their end, at `bye`, or
after 45 s without a frame (the hub pings every 10 s, and so does `serve`). Nothing is installed or enabled: between
connections the runner has its folder and, with linger, the attempts still running in their own units. It is blocking
and threaded (one thread reads frames, the main loop handles them and ticks every 100 ms); no async runtime.

### Platforms (`serve::platform`)

`serve`'s protocol loop never calls the machine itself: everything it asks of it goes through a `Platform`, so one
loop serves every runner kind. `LinuxPlatform` is the one above (transient units in job slices, rootless podman,
cgroups and PSI); `DarwinPlatform` is a Mac's ("A Mac runner", above). What a platform answers:

| Area | Methods | Linux |
|---|---|---|
| probe and contract | `machine`, `limits`, `boot_id`, `contract`, `survives_link`, `job_runner` | `linux::probe`, linger, podman's caps check (`podman` feature), `Probe::devices` (`gpu`: a DRM render node of a real driver, not `vgem`/`vkms`, or NVIDIA's `nvidiactl` with a `nvidiaN`; `kvm`: `/dev/kvm`; each only when this user may open it read-write, by permissions alone: nothing is opened). Jobs don't get these devices yet: no `--device` goes into a job's container |
| reservations between schedulers | `reservations`, `start_time` | `linux::reserve` (`$XDG_RUNTIME_DIR`, `/proc` start times) |
| attempts | `launch`, `active`, `kill` | `job.json`, `sleipnir job-exec` in a transient unit; `podman kill` |
| caps | `current_mib`, `pause`, `unpause`, `grow_candidate`, `resize`, `weight_unit`, `set_weight` | the job slice's cgroup, `linux::resize` |
| cleanup | `cleanup` | containers, units, attempt folders, bundles (`serve::cleanup`) |

A platform that has no pause, grow or CPU weights says so (`grow_candidate` and `weight_unit` answer none), and the
loop skips them. The rows in `serve/platform_tests.rs` run the loop on a fake platform: hello and probe answer from
it, and an attempt goes from offer to `finished` through its `launch`, `active` and `kill`.

**The runner folder** (`--root`): `bin/<name>/` holds bundles (the `sleipnir` that serves names its own folder in
`hello-ok`, and runs every job-exec it starts); `jobs/<id>.<attempt>/` is an attempt's folder, its whole record:

| File | What |
|---|---|
| `attempt.json` | the hub id, the `JobRef` with its nonce, the spec, priority, grant and expected figures, the bundle its job-exec runs from, its unit |
| `job.json`, `log`, `result.json`, `kill_reason` | job-exec's (above) |
| `helper.sock`, `helper.pid`, `helper.log`, `disk-start`, `key-use`, `key-timeout` | the job helper's (above) |
| `drgnx-key`, `net-allow`, `key-use.sent` | the job's own copy of the bundle's `drgnx-key`, the hub's allow-list, the `key-use` lines sent |
| `src/`, `target/` | an attempt the hub synced nothing for: its (empty) source; the target dir |
| `tree/` | a synced job that writes its tree: its private copy of the slot |
| `base/`, `returned.patch`, `returned.tar` | a job that declares `writes`: the slot as it started from, which its changes are read against; what was sent back (below) |
| `cancelled`, `collected` | the hub cancelled it; the hub has its result (`done`), so the folder may go |

**`hello`** must come first; a hub id other than `--hub-id` gets `bye`. Each `hello` re-probes the runner contract
(`missing`) and linger (logind's live answer), and lists this hub's attempts from the folder: `finished` when
`result.json` is there, `running` while the unit is active, `lost` otherwise, each with its log's length. A `ready`
follows, then one every 2 s and at every job end: free memory and CPU from `forseti::budget` over the live machine
(this hub's running attempts counted, the others' through their reservations), PSI, the running attempts, the slots
present (the folders under `<root>/slots`, sorted: `sync::slot::present`) and the images the attempts this `serve`
started ran in. The hub counts a start warm where both are there.

**`offer`** is admitted by `forseti::admit` under the machine's admission lock (`linux::reserve::with_admit_lock`):
it reads the machine with the others' live reservations, decides, sizes the grant (`forseti::size`) and writes the
reservation (`drgnx-<hub id>`, job `<id>-<attempt>`) before it lets go, so two schedulers never fit into the same
memory. The answer is `admit {grant}` or `refuse {why, reason}`. An offer whose folder exists is answered again from
it when it is the same placement (hub and nonce), and refused otherwise. While the memory ladder is above normal, no
offer is admitted. `forseti`'s 10 s gap between starts counts from this hub's latest start in the folder, so it
holds across `serve` processes. An offer whose slot (`SlotKey` of its project, the hub's worktree and its trust) a
running job reads at another input key is refused: a slot moves only between jobs (a job that writes the tree reads
its own copy). This check sees this hub's jobs only; the slot's read locks (`slot::hold`, at `start`) are what keep a
slot still under every job.

**Sync.** Between `admit` and `start` the hub sends `sync-have`: the repository's mirror id, the commit and the overlay
the runner's trust may get. `serve` answers `sync-need` with the overlay's blobs the store lacks, whether the mirror
lacks the commit, and the mirror's ref tips (what a bundle may leave out). The hub sends blobs (chunks of at most
1 MiB at an offset of the total; one is kept only whole and hashing to its name), a bundle (`bundle::Receiver`: a
chunk past what is held is dropped, an overlap is skipped; at its total it is checked and fetched into the mirror) or
`origin-fetch` (`Mirror::fetch_origin` in a thread of its own, so pings go on; its end comes back to the loop), and
`serve` answers `sync-need` again after each. An `origin-fetch` with `cred` names the deploy key or token the hub sent
just before in a `key` frame of the attempt: a `key` frame for a syncing attempt that hasn't started is held in memory
for that fetch only (`Live::origin_cred`), never handed to the job, and goes to `fetch_origin` as `OriginCred::Https`
for an `http(s)://` origin or `OriginCred::SshKey` otherwise; a fetch naming a key that didn't come fails the sync. A sync that fails (a bad repository id, a bundle that doesn't check, a
fetch that fails) ends the attempt `infra: setup`, with why in its log.

**`start`** of a synced attempt first holds its slot at the inputs (`slot::hold`, moving it with `slot::update` under
the slot's update lock: the mirror's commit, then the overlay from the blob store; a slot another job reads at other
inputs ends the attempt `infra: setup`) and runs the job on the slot, or on `slot::private_copy` in
`tree/` when it writes the tree; it records the slot's id in `attempt.json`. Then it writes `job.json` (the shared
podman argv, `RunnerArgs::runner(prefix, hub id, slice)`, in the job's
slice `drgnx-runner-work-<id>.slice`) and starts the unit `<prefix>-<id>-<attempt>` running `sleipnir job-exec` with
`RuntimeMaxSec` = the timeout + 60 s (job-exec's own timeout writes the verdict first). The reservation passes to the
unit's main pid, so it outlives `serve`. Then `started`. Every attempt gets its job helper (the disk watch); a keyed
one also its key mounts and `drgnx-key exec` (its spec's key names, each into the variable of that name), and one
with `net_hosts` its proxy, the hosts written to `net-allow` and checked first ("The job helper", "Keys"). What can't
start (no image, a parser it doesn't know, an allow-list entry that is never reached, a bundle without `drgnx-key` or
`drgnx-px` for a networked job, and for now container variables) ends `infra: setup`, with the reason in the attempt's log; it is never
run another way. `key` frames go to the helper ("Keys"), and the helper's `key-use` lines come back as `key-use`
frames. The hub sends no pins (a pin names an address on the hub machine's network; a job that needs one stays there), and
the job helper's proxy pins nothing.

**Logs** are read from the attempt's log file by offset, never from a pipe: a new attempt streams from 0, and after a
reconnect the hub sends `attach {r, log_offset}` with where its own copy ends. When the attempt has its
`result.json` and its log is all sent, `serve` sends what comes back (below), its rows (`row`) and `finished` with
`result.json`, drops the reservation, cleans up and sends `ready`.

**What comes back** (`sync::returned`, `Serve::give_back`), for a job whose spec has `writes_tree` (the hub sets it
when the job declares `writes` or `outputs`): `changes` reads the private copy against `base/` and writes a git patch
(`--full-index` form: an `index` line with both blob ids and the mode, then the hunks) of the text files the `writes`
globs match that differ, were added or were removed; a binary file, a link and a name git would quote are left out,
each with its reason, and the copy's `.git` is never read. `outputs` makes a ustar archive of the regular files the
`outputs` globs match and of `reports/`, folders first. Each goes back in `returned` frames before `finished`; one
over its limit (16 MiB for the patch, 256 MiB for the outputs) is sent `kept`, without its bytes. Glob matching is
`returned::glob_ok`, which the hub's `patch_ok` calls too, so both sides pick the same files. A unit that ended without job-exec's result was killed from outside: its
result is written as `infra: killed`. `cancel` writes `cancelled` and the kill reason, then kills the container, so
job-exec writes the verdict, which `serve` reports as `Cancelled`.

**The ladder** runs at every `ready` on the runner's slice tree: `tight` stops admissions; at `pressure` and
`danger` the scheduler holding the most memory (`forseti::ladder_acts`: every scheduler, ours included, counted by
Σ `max(reserve, current)`) evicts (dedicated) or kills our newest (workstation), writing `evicted` or `infra: killed` before it kills the container. On a dedicated
runner it pauses the lowest-priority long builds at `pressure` and lets them go on below it; a paused or evicted job
is marked `disturbed` first. After the ladder, `ready` grows the jobs near their caps and sets the CPU weights (live
resizing, above).

**The cleanup**, at start, at every job end and at every `done`, removes only what is this hub's
(`serve::cleanup::plan`, pure):

- containers of its prefix labelled `drgnx.runner=<hub id>` whose `drgnx.job` attempt doesn't run, the job's
  container (`<prefix>-<id>`) before its relay sidecar (`<prefix>-px-<id>`): `linux::podman::leftovers`, the sweep the
  hub shares, over `podman ps -a --format json` (a running job's sidecar stays);
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

## The watchdog

```
sleipnir watchdog --provider aws|gcp --idle S --lifetime S --unattended S --root RUNNER_ROOT --dir DIR
```

A cloud machine's own end (design §6.7.6), a system unit in drgnx's image, so it works with the hub gone, asleep or
without credentials. In the image the unit (`drgnx-watchdog.service`) runs it with `--root
/var/lib/drgnx/runner` (the runner folder the image build makes, owned by the `runner` user) and `--dir
/var/lib/drgnx/watchdog` (its `StateDirectory`), so `serve` on that machine runs with the same root and
`--watchdog /var/lib/drgnx/watchdog`. Every 5 s (`watchdog::POLL`) it looks at three things:

- **the jobs:** the attempt folders under `RUNNER_ROOT/jobs/` without `collected`: running, or a result waiting for the
  hub. It reads the folder, so it needs no `serve`.
- **the hub:** `RUNNER_ROOT/heartbeat.json`, `{contact, offer}` in Unix seconds, which `serve --watchdog DIR` writes:
  `contact` at the hub's frames (at most every 5 s), `offer` at each offer (at once).
- **the provider's notice:** AWS IMDSv2 (`PUT /latest/api/token`, then `spot/instance-action` with the token; the
  instance's hop limit of 1 is enough on the machine itself), or GCE's `computeMetadata/v1/instance/preempted` with
  `Metadata-Flavor: Google`.

What it does is `watchdog::decide(provider, limits, look)`, pure (`Look {now, booted, last_job, jobs, heartbeat}`;
times before the boot count as the boot):

| | AWS | GCP |
|---|---|---|
| no job for the idle time, counted from the last job and the hub's last offer | `systemctl poweroff`, `Why::Idle` | writes `DIR/idle` (since when); `serve` sends `idle {since}` and the hub deletes the machine |
| the unattended lifetime since the hub's last contact (or the boot), whatever runs | `poweroff`, `Why::Unattended` | nothing: the provider's `terminationTime` |
| the lifetime since the boot, whatever runs | `poweroff`, `Why::Lifetime` | nothing: the provider's `terminationTime` |

Pings alone never keep an idle machine: the hub stops a machine it has no work for by sending it no offer, so "the
idle stop through the watchdog" needs no call. It never runs `halt` (that leaves an AWS instance running); a power-off
of an instance started with `InstanceInitiatedShutdownBehavior=terminate` ends it and its volumes. On GCP a guest stop
would leave a stopped VM with a billed disk and clear its deadline, so it never powers off. The boot time comes from
`/proc/uptime`, so a restarted watchdog keeps the lifetime; its idle time counts from its own start (it can't know when
the last job ended before it). A failed power-off is tried again at the next look; `DIR/poweroff` says why.

A notice is written once to `DIR/preempting` (the time the machine goes, Unix seconds; GCE gives none, so its time is
the moment it was seen). `serve --watchdog DIR` reads `DIR/preempting` and `DIR/idle` every 2 s and sends
`preempting {at}` once and `idle {since}` at each new value. The hub stops offering to that runner, and its attempts end
`infra: preempted` and requeue at once: neither a strike nor an eviction.

It writes only in `DIR`, its own folder (root's in the image), each file by a new temporary file and a rename, and reads
the runner's files with `O_NOFOLLOW | O_NONBLOCK`, regular files only, at most 64 KiB (`watchdog::read_small`), so a
job that plants a link or a FIFO there can't steer a root process. The metadata requests are plain HTTP with a 2 s
limit. A test build adds `--clock-file F` (the time is F's number, and the boot its first reading), `--poweroff-cmd PATH`
and `--metadata-url URL` (`ratatoskr-mock cloud`'s `/__metadata/<instance>`). Built with `runner` on Linux only; any
other build refuses the mode.

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
prefix and label only (`[D]`), the bench's readings, speed, result shape and capped argv (`[D]`), and the watchdog's
table on AWS and GCP, its notices, answers and options (`watchdog::`, `[D]`, a test clock). The bench's
runner-host row (`bench_runs_capped_and_under_2_minutes`, `[C]`) needs the default features: build `runner_host`
without `--no-default-features` for it.

`tests/fleet_serve.rs` plays the hub over real SSH to a real `serve` in the fake fleet (`#[ignore = "fleet"]`,
`test/runners/README.md`, "Fleet rows"), every row `[C]`: a new `serve` lists the running attempt after a cut
channel and reattaches it; `serve` ends at `bye` and at an EOF and leaves nothing enabled, loaded or written outside
its root; two hubs on one root and prefix never clean each other's; an update keeps the old bundle while its job runs;
the log after a reconnect comes from the file by offset, byte for byte; linger is reported at every `hello`. The
hub's `tests/fleet_runners.rs` `watchdog::a_spot_notice_requeues_at_once_with_no_strike` (`[C]`, `fleet.sh up
--runners 1 --cloud MOCK`) runs a real watchdog on a fake runner against the mock's metadata for a seeded instance:
the mock's spot notice reaches the hub as `preempting`, and the parked job's attempt requeues with no strike.

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
each `[C]`: the helper is not dumpable (its `/proc` files aren't its user's, unlike a plain child's); the helper
started by job-exec runs in the job's unit and slice and dies with the unit; and below the floor (the folder's
`test-machine.json`) the job that grew most is stopped `infra: disk` before any other. The keyed rows (`relay_keys::`,
`#[ignore = "keys"]`, with the relay's image from `DRGNX_TEST_PX_DIR`) run on the Fedora VM gate, once as an
unconfined user and once as a confined `staff_u` one: a keyed job's command has the variable in its own
`/proc/<pid>/environ` and only `lo`, while `podman inspect` and the stored config hold the names only (and the start
cost is printed); a key that never comes is 75 with the helper's record, an unlisted one is refused; no other
namespace (none, the host's, a second job's) reaches the name; the job can neither bind the name (px in the job exits
2) nor get a key from the proxy port; and the sidecar has `RLIMIT_CORE` 1, is not dumpable, refuses the test-hooks
flags, and leaves no core when it aborts. The unit rows `[D]`: a key frame's value held in a locked buffer that is all
zeros just before it is unmapped, only listed names taken or served, the allow-list's metadata and link-local refusals
and the proxy's `403` for a listed name that resolves link-local, the disk watch's pick, the key-timeout record's
verdict, and `drgnx-key exec` in the argv with names only.

`tests/fleet_sync.rs` holds sync's fleet rows (`#[ignore = "fleet"]`), run from the fleet's harness over real SSH
(`fleet.sh test 'sync::'`, with the `sleipnir` binary in `/fleet/share`). `sync::a_dropped_bundle_resumes_not_restarts`
sends a 10 MiB bundle, cuts the link at 40 % once the runner has announced that offset, reconnects, and checks that the
runner resumes there: at most 60 % plus 1 MiB is sent again, and the commit arrives in the mirror.
