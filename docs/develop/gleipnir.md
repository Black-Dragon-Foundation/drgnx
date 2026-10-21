# Gleipnir: the sandbox

Gleipnir is the Rust sandbox in `runtime/crates/gleipnir` ([runtime.md](runtime.md#crate-names)). It runs a program
inside a boundary the kernel enforces: bubblewrap with Landlock and seccomp on Linux (the full tier), Landlock and
seccomp alone (the reduced tier), or Seatbelt on macOS. It is self-contained: the caller passes every path, name and
port, and nothing in gleipnir names a drgnx directory or reads a drgnx variable. Nothing in drgnx uses it yet; job
agents run as before until phase 6. The Lisp libraries on main are described in [sandbox.md](sandbox.md).

Each section below is written by the task named in it.

## Using it (Task 13)

## The spec (Task 2)

## What is refused (Task 2)

## Platforms (Task 2)

## Toolchain roots (Task 3)

## The bubblewrap argv (Task 7)

## The inner helper (Task 8)

## Landlock

`gleipnir::landlock` (Task 5). Landlock is the second layer, after the mount namespace (full tier) or in its place
(reduced tier). It works in three pure steps and one Linux-only one:

- `plan_for(spec, tier)` gives a `LandlockPlan`: the read roots, write roots, device files that may be written, the
  roots under which pathname Unix sockets may be connected to, and the TCP ports (or none). Its `min_abi` is the
  spec's `layers.landlock_min_abi`, raised to the tier's floor. The plan travels in the inner spec.
- `rules_for_abi(plan, abi)` gives the `RulesetDesc` for one ABI: what is handled (denied unless allowed) and what is
  allowed where. It asks only for rights that ABI has. An ABI above 9 gets the ABI-9 set.
- `gate(plan, kernel, cap)` is the floor. The effective ABI is `min(kernel_abi(), abi_cap, 9)`. It is refused when
  it is below the plan's `min_abi` or below the tier's floor, whatever the plan says.
- `restrict(plan, abi_cap)` runs the gate first, so a refusal restricts nothing. Then it applies the description in
  `CompatLevel::HardRequirement` mode, never `BestEffort`, and returns `Applied { abi }`. Because the description
  asks only for what the ABI has, the hard requirement decides nothing on a correct kernel; it is a backstop. A
  rule set that is not fully enforced is refused too. `abi_cap` exists for the escape rows (the `test-hooks`
  feature) and is `None` otherwise.

**The two tiers.**

| | Full (under bwrap) | Reduced (no namespaces) |
|---|---|---|
| Paths | inside paths (bind dests) | the host's own (sources) |
| Floor | ABI ≥ 1 | ABI ≥ 9, plus seccomp |
| Read and execute | `/` | `/usr /etc /opt /nix /gnu /bin /lib /lib64 /sbin /proc`, `/dev/{null,zero,full,random,urandom,tty}`, and the spec's read, write, bind, home, run and tmp sources |
| Write | `write` entries, rw binds, an rw home, `/tmp`, `/var/tmp`, `/dev/shm`, `/dev/pts` (bwrap's private mounts) | `write` entries, rw binds, an rw home, the spec's `tmp`. Never the host's `/tmp`, `/var/tmp` or `/dev/shm`: without a mount namespace they are the user's own |
| Device files written | `/dev/{null,zero,full,tty,ptmx}` | `/dev/{null,zero,full}` |
| Unix connect (ABI 9) | the `run` dest | the `run` source |
| TCP connect (ABI 4) | relay ports and `extra_tcp_ports` under `Net::Isolated`; not handled under `Net::Shared` | not handled: the network is open |

**Per ABI.**

| ABI | Adds | How it is used |
|---|---|---|
| 1 | the first fs rights | all handled. Read and execute on the read roots. Every write right on the write roots except `make_char` and `make_block`: those are handled and never granted, since an agent has no use for device nodes. `write_file` on the device files |
| 2 | `refer` | handled; granted on the write roots |
| 3 | `truncate` | the same. `O_TRUNC` on a device ignores it, so `> /dev/null` works |
| 4 | TCP bind and connect | `connect_tcp` handled only when the plan has ports; `bind_tcp` never, since servers inside must work |
| 5 | `ioctl_dev` | never handled: ioctls on ttys and pipes must work, and seccomp blocks TIOCSTI and TIOCLINUX |
| 6 | scopes | abstract Unix sockets and signals scoped: nothing made outside the sandbox can be reached or signalled |
| 7, 8 | logging, thread sync | nothing used here |
| 9 | `resolve_unix` | handled; granted only on the connect roots. A server the sandboxed program makes itself stays reachable (the kernel's same-domain rule) |
| 10, 11 | UDP rules, a restrict flag | the `landlock` crate stops at 9, so a newer kernel runs the ABI-9 set |

**Opening the rule paths.** Each path is opened `O_PATH` with `openat2(RESOLVE_NO_SYMLINKS)`, so no link anywhere
in it is followed. A missing path or a link is skipped. That only narrows what is allowed: `/bin` → `usr/bin` is
covered by `/usr`, and bwrap's `/dev/ptmx` → `pts/ptmx` by `/dev/pts`. Any other open error refuses. A path that is
not a directory gets only the rights that apply to files.

**What Landlock adds under bwrap.** Under bwrap it is defence in depth only. The mount namespace already decides
what exists. Landlock also holds if a bind turns out wider than meant, and its scopes stop abstract sockets and
signals that the namespaces do not cover.

**Landlock's TCP rule is never network isolation.** A TCP Fast Open `sendto(MSG_FASTOPEN)` bypassed `connect_tcp`
on every kernel with ABI ≥ 4. The fix (mainline 33cb713db016, 7.2-rc4) came with no ABI bump, so a process cannot
tell a fixed kernel from an unfixed one. Landlock has no UDP rules before ABI 10 either. Isolation is
`--unshare-net` plus the relay and the proxy; the TCP rule stays inside that namespace as a second layer.

**The reduced tier's floor is ABI 9.** This is the user's ruling on review B1, stricter than the design's 6. Only
ABI 9 controls connecting to pathname Unix sockets. Without a mount namespace, ABI 6–8 would leave the hub socket,
D-Bus, ssh-agent and the Emacs server reachable. Validation refuses a reduced spec with a lower `landlock_min_abi`,
`plan_for` raises it to 9, and `gate` refuses an effective ABI below 9 (for example a kernel at 8, or the test
hook's cap of 8).

**The reduced tier and `/proc`.** There is no pid namespace, so `/proc` shows the host's processes. Landlock's
ptrace scoping denies other processes' `environ`, `mem` and `fd` (EACCES). It does not deny their `cmdline` or
`stat`: a sandboxed program can read the command lines of the user's processes. The user accepted this gap
(2026-10-21). It is recorded by the test `reduced_proc_other_cmdline_is_the_gap` and the escape row
`reduced-proc-cmdline-the-gap`, and phase 6 names it in the reduced badge's text.

Tests: `landlock::tests`. The pure ones include the goldens `rules_per_abi_golden` (ABI 1–9 × full shared, full
isolated, reduced), the floor table, and the check that the handled set equals the crate's own set for each ABI. The
real ones each run in a re-exec'd child of the test binary, because a restriction cannot be undone. They skip with
the reason when the kernel's ABI is too low.

## seccomp (Task 4)

## macOS: Seatbelt (Task 9)

## The relay (Task 11)

## The proxy (Task 10)

## The check (Task 12)

## Proving it (Tasks 14 and 15)

## What this does not claim yet (Task 19)
