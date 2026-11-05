# Fake runners and the fleet harness

Tests that need machines to talk to over SSH run against containers that act as runners: Fedora 45 with `sshd`,
systemd as PID 1, the user `runner` (lingering, with the `memory pids cpu` controllers delegated to its user manager)
and rootless podman inside. A fleet is N of them plus one harness container on one podman network.

```
fleet.sh up --runners N [--max-sessions K] [--no-linger | --no-linger-on I] [--sshd-opt OPT]...
fleet.sh exec I -- CMD...      # in runner I (1-based), as `runner`, with its user manager's environment
fleet.sh check I               # runner I's controllers are delegated as the caps need (`up` checks every runner)
fleet.sh put FILE...           # copy files to /fleet/share in every runner (read-only there)
fleet.sh test FILTER           # $DRGNX_FLEET_TEST_BIN --ignored FILTER, in the harness
fleet.sh host BIN [FILTER]...  # a runner-host test binary in every runner, as `runner`, with --ignored
fleet.sh s1                    # build sleipnir's runner-host tests and run the fake runner's own checks
fleet.sh check-linger          # ssh in, start a unit, ssh in again: the unit is still active
fleet.sh status | down
```

`fleet.sh` starts podman itself, so a slot script must not wrap it in the dev container. Put `--container` first (the
slot scripts read it as "this command handles its own containers"; `fleet.sh` drops it):

```
DRGNX_FLEET_PREFIX=bld-fleet $HEAVY test/runners/fleet.sh --container up --runners 2
```

Containers are named `$DRGNX_FLEET_PREFIX-<run>-r<i>` and `...-hub` (`<run>` is the worktree's name, or
`DRGNX_FLEET_RUN`); `down` removes only those and the network `fleet-<run>`. The keys, the ssh config and the
harness's HOME live under `.claude/tmp/fleet/<run>/`.

## What the runner container needs

Found by the spike (rootless podman as the outer engine):

| Flag | Why |
|---|---|
| `--systemd=always` | systemd runs as PID 1 and gives `runner` a user manager |
| `--cap-add SYS_ADMIN` | without it the inner `newuidmap` gets EPERM writing a uid_map (rootless podman inside cannot start) |
| `--security-opt unmask=ALL` | without it the inner crun cannot mount `/proc` ("mount `proc` to `proc`: Operation not permitted") |
| `--security-opt label=disable` | as `ctr.sh` |
| `--device /dev/fuse`, `--device /dev/net/tun` | fuse-overlayfs storage; slirp4netns |
| `--memory` = `--memory-swap` | runners 3g, harness 2g |

The image also needs `newuidmap` and `newgidmap` made setuid (a rootless image build drops their file capabilities), a
subuid range for `runner` inside the 65536 ids the outer container maps (`20000:30000`), and the
`/etc/systemd/system/user@.service.d` drop-in `Delegate=memory pids cpu cpuset io`.

A container started by `podman run` inside a unit lands under `user.slice`, not under the unit's slice, unless it is
given `--cgroup-parent=<slice>`; `a_capped_container_runs_in_a_transient_slice` pins that.

## When `up` returns

`up` waits on announced states, never on time: the runner's system has booted (`systemctl is-system-running
--wait`; the base image is loaded by then), and `runner`'s own user manager says it is running (`systemctl --user
is-system-running --wait`). Then `check I` must pass for every runner, or `up` fails naming it:

- `runner`'s user manager is `running` (or `degraded`);
- `user@1000.service`'s `cgroup.subtree_control` hands `memory pids cpu` to its units;
- rootless podman, as `runner`, is on the systemd cgroup manager and sees `memory pids cpu`.

On a failure it prints where the controllers stop: the runner's root `cgroup.controllers` and
`cgroup.subtree_control`, and the user manager's `cgroup.subtree_control`. Runners have been seen (about 1 boot in
70) that booted with the user manager running and the base image loaded, yet with no controller delegated to the user
manager (its `cgroup.subtree_control` empty, and no `pids` for system services), for their whole boot: waiting never
changes that state, so `up` refuses such a runner instead of handing it to tests whose caps would then fail.

## Runner-host tests

`sleipnir`'s `tests/runner_host.rs` holds the rows that need a real user manager, cgroups and podman
(`#[ignore = "runner-host"]`): the fake runner's own checks (what `fleet.sh s1` runs), the slice tree, job-exec, OOM
and the reservation files. They run only inside a runner:

```
cargo test -p sleipnir --no-default-features --features linux --test runner_host --no-run   # in the dev container
fleet.sh host runtime/target/debug/deps/runner_host-HASH [FILTER]...
```

`host` copies the binary (and the `sleipnir` and `drgnx-key` binaries beside its `deps/`, which the job-exec and key rows start) into
`/fleet/share` and runs it in every runner with `--ignored --test-threads=1`.

## Fleet rows

Rows that play the hub (`#[ignore = "fleet"]`, `sleipnir`'s `tests/fleet_serve.rs`) run in the harness and reach
the runners over real SSH:

```
cargo test -p sleipnir --features test-hooks --test fleet_serve --no-run   # in the dev container
fleet.sh up --runners 2 --no-linger-on 2
DRGNX_FLEET_TEST_BIN=runtime/target/debug/deps/fleet_serve-HASH fleet.sh test --test-threads=1 serve::
```

`test` copies the `sleipnir` binary beside the test's `deps/` into the share and tells the rows where the share is
(`DRGNX_FLEET_SHARE`); each row installs it into its own runner root as a bundle (`<root>/bin/<name>/sleipnir`).
A runner's `/proc/pressure`, `/proc/meminfo` and disk are the host's, so each row also writes `test-machine.json`
into its root: a quiet machine with room, whose figures the `test-hooks` build admits on (`sleipnir.md`, "The machine
probe"). A busy or nearly full host never refuses a row's job.
Runner 1 lingers and runner 2 (`--no-linger-on 2`) doesn't. The rows can't be root in a runner, so a row that turns
linger on writes `enable-linger` into the share: the image's `fleet-linger.path` sees it and runs
`loginctl enable-linger runner`.
