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

## Landlock (Task 5)

## seccomp

`gleipnir::seccomp` holds one fixed filter. It is on in both Linux tiers, and no spec can turn it off or change it.
The filter allows every call by default and refuses this list (`seccomp::rules()`):

| Refused | Result | Why |
|---|---|---|
| `ptrace` | EPERM | Without a pid namespace (the reduced tier), it would read and write other processes of the same user. |
| `keyctl`, `add_key`, `request_key` | EPERM | Kernel keyrings are not namespaced. The user's session and user keyrings hold credentials. |
| `perf_event_open` | EPERM | Watches other processes, and is a large kernel attack surface. |
| `bpf` | EPERM | Kernel attack surface. |
| `userfaultfd` | EPERM | A common primitive for exploiting kernel races. |
| `io_uring_setup`, `io_uring_enter`, `io_uring_register` | EPERM | io_uring operations are not system calls, so seccomp never sees them. It is also a frequent source of CVEs. |
| `unshare`, `setns` | EPERM | A new namespace gives a namespaced root, kernel attack surface, and a way around the mount layout. |
| `clone` with any `CLONE_NEW*` bit in its flags | EPERM | The same, through `clone`. These are seven rules, one per bit of `0x7E020000`, because seccompiler cannot express "masked value is not zero". |
| `mount`, `umount2`, `pivot_root` | EPERM | The sandbox's view of the file system stays as bwrap built it. |
| `open_tree`, `move_mount`, `fsopen`, `fsconfig`, `fsmount`, `fspick`, `mount_setattr` | EPERM | The same, for the new mount API. |
| `ioctl` with `TIOCSTI` (`0x5412`) or `TIOCLINUX` (`0x541C`) | EPERM | Both push input into a terminal (CVE-2017-5226), and `TIOCLINUX` also reads the console selection. |
| `socket(AF_VSOCK)` | EPERM | vsock reaches the host or the hypervisor, past the network namespace. |
| `clone3` | ENOSYS | Its flags sit in a struct that seccomp cannot read. On ENOSYS, libc falls back to `clone`, which the rules above check. EPERM would break thread creation instead. |

Argument checks compare only the **low 32 bits** of the argument. The kernel reads an `ioctl` request and a `socket`
domain as 32-bit ints, so `TIOCSTI | 1 << 32` is TIOCSTI to the kernel, and the filter must see it that way too. The
`CLONE_NEW*` bits all sit in the low half, and legacy `clone` ignores the high half.

`seccomp::compile(arch)` builds the BPF for `X86_64` or `Aarch64` on any Linux host. The call numbers come from a table
in the module, so neither filter depends on the host's libc. seccompiler `=0.5.0` compiles the EPERM rules. Its
architecture check kills a call that comes from any other audit arch. Before seccompiler's code there is a short
hand-written prologue. None of its jumps leave it, and none of seccompiler's jumps enter it:
- **x86_64:** `ld arch; jeq AUDIT_ARCH_X86_64 (else skip two); ld nr; jset 0x40000000 (else skip one); ret
  KILL_PROCESS`. A foreign arch and an **x32** call both land on the kill. x32 calls carry `AUDIT_ARCH_X86_64` with bit
  30 set in the number, so a list keyed on x86_64 numbers would miss them. Debian can turn x32 on at boot
  (`syscall.x32=y`). The filter sees the number before the kernel checks whether x32 is enabled, so the kill happens
  either way.
- **aarch64:** `ld arch; jeq AUDIT_ARCH_AARCH64 (then skip one); ret KILL_PROCESS; ld nr`.
- **Then, for both:** `jeq clone3; ret ERRNO(ENOSYS)`. seccompiler gives one errno to every rule in a filter, so a
  rule with a different errno goes here.

`seccomp::install(prog)` sets `PR_SET_NO_NEW_PRIVS`, then installs the filter on every thread
(`SECCOMP_FILTER_FLAG_TSYNC`). The inner helper (Task 8) compiles the filter for `seccomp::native()` and installs it
right after Landlock. A filter that does not compile or install stops the sandbox from starting (fail
closed). Off Linux, `compile` and `install` return `Unsupported`. That includes Android, which has no backend.

Tests (`seccomp::tests`):
- `bpf_golden_x86_64` and `bpf_golden_aarch64`: insta snapshots of each whole program in `src/snapshots/`, one line
  per instruction. A new seccompiler is checked against these.
- `bpf_interpreter_table`: a classic-BPF interpreter in the test runs both programs over synthetic `seccomp_data`
  (3232 cases):
  - every call number 0–1023;
  - each `CLONE_NEW*` bit alone, all seven together, and with thread flags, plus 0, fork and thread flags alone;
  - TIOCSTI and TIOCLINUX with and without high bits;
  - vsock and other socket domains;
  - every x32 number;
  - four foreign arches.

  This checks what the filter does, not just which bytes it has.
- `installed_filter_denies`: the real install. For each case, the test binary runs itself again in a child process.
  That child forks once without the filter (the control) and once with it. Only calls whose unfiltered result
  differs from the filtered one are used:
  - `unshare(CLONE_NEWUSER)`, `io_uring_setup`, `keyctl`, `add_key`, `socket(AF_VSOCK)`, and `ptrace` attach to the
    child's own child: EPERM;
  - `clone3(NULL, 0)`: EINVAL unfiltered, ENOSYS filtered;
  - `mount` on a missing target: ENOENT unfiltered, EPERM filtered;
  - `TIOCSTI | 1 << 32` on a pty the child makes its controlling terminal: EIO or success unfiltered, EPERM filtered;
  - x32 `getpid`: killed;
  - `getpid` and `socket(AF_UNIX)` still work.

  A case is skipped, with the reason printed, when its control does not give the unfiltered result. Inside a podman
  container, the container's own filter already refuses `io_uring_setup`, `add_key` and vsock, so those three skip
  there. They run wherever no container filter is in the way. The calls the kernel already refuses to an unprivileged process (`setns`, `pivot_root`,
  the new mount API, `bpf`, `userfaultfd`) are covered by the interpreter only.

## macOS: Seatbelt (Task 9)

## The relay (Task 11)

## The proxy (Task 10)

## The check (Task 12)

## Proving it (Tasks 14 and 15)

## What this does not claim yet (Task 19)
