# forseti: the scheduler core

`runtime/crates/forseti` decides which job runs where, when and with how much. It is pure: no I/O, no clock and no
threads. Time (`u64` seconds since the epoch) and machine state are parameters, and sizes are MiB. Its shells read
the machine and carry out what it returns:

- the hub's queue, for this machine and the user's runners;
- `sleipnir`, the runner, for its local admission;
- jobq, the org folder's scheduler, which pins a tag (`forseti-v0.N`) on `main`.

It depends on `serde` only (`cargo tree -p forseti -e normal`), so it builds for every target, Android's included,
and brings no runtime into jobq. Its tests are pure ([D]) or run every order of a pure core with `skuld` ([A]).

## The words

- **Priority** is 1–5 (`Priority::P1` … `P5`). `Ord` puts P1 highest, so `Priority::P1 > Priority::P5` and `max`
  picks the more urgent; `number()` gives 1–5.
- **Job trust** is `JobTrust::{Public, Private, PrivateKeys}`; **runner trust** `RunnerTrust::{Mine, MyCloud,
  Shared}`.
- **Profile** is `Profile::{Workstation, Dedicated}`: someone's daily machine, or one nobody sits at.

"Class" names none of these.

## The model (`model`)

`JobSpec` is what a job is and needs. It carries jobq's spec (kind, weight, suite, tree, command, rows selected,
needs, inputs, features, core and memory ranges, disk, timeout, restartable, `writes_tree`, gate, expect, outputs,
state locks, pin, lane) plus the runners' fields: `project`, `trust`, `keys` (names only), `local_only` and
`writes`. A job is heavy only when it is marked so: `weight: Weight::Heavy`, read by `JobSpec::heavy()`.

`Job` adds the scheduler's view: its id, its own priority, when it was submitted, its state, attempt, whether it was
evicted once, disturbed, or has a blocked caller.

`MachineState` is one machine as its probe read it: profile, boot id, memory total and available, PSI, disk free and
total, power, the last start, the running jobs, features, and `others`, the other schedulers' reservations.

`Limits` are the machine's thresholds, never constants in the code:

| | `Limits::for_profile(Dedicated, …)` | `Limits::for_profile(Workstation, …)` |
|---|---|---|
| floor | 2 GiB | 1.5 GiB |
| the user's reserve | none | 4 GiB and 4 threads (out of `cores_usable`) |
| PSI limits (`avg10`) | memory `some` 10 %, CPU 40 %, IO `full` 10 % | memory 2 %, the user's apps 1 %, CPU 20 %, IO 5 % |
| CPU overcommit | up to 1.5 × while the jobs are mostly idle | none |
| on battery | runs | no jobs |
| disk kept free | 20 GB and 10 % of the filesystem | the same |

`Limits::fixed_slots(n)` admits by count only, for a hub with no Linux probe (macOS). jobq fills `Limits` from its
own configuration.

`Verdict` is how a job ended; `Verdict::Infra` carries a named reason without its `infra: ` prefix (the `Display`
adds it). `WaitReason` is why a job waits; the runners added `Trust`, `Pinned`, `NeedsLogin`, `NeedsKeys`,
`CloudCap`, `Benched`, `Mode`, `Features`, `Matrix`, `AwaitingConfirm` and `NoRunner` to jobq's.

## Priority (`priority`)

- **`effective_priorities(jobs, locks, waits_on_lock)`**: a job's effective priority is the highest of its own and of
  everything that waits on it. The waiters are the jobs that need it, the jobs waiting for a state lock it holds
  (`locks` are `(path, holder)`, `waits_on_lock` `(waiter, path)`), the user (P1, when `for_user` is set) and a blocked
  caller (P3). A user who bumps a gate's chunk lifts the prefix build it needs to P1, and a P1 job waiting for a build
  dir lifts the P5 job holding it.
- **`check_no_cycle(jobs, new)`** refuses, at submit, a job whose needs reach a cycle, and names the cycle.
- **`promote(own, waited_s)`**: one step up per 3600 s waited, never into P1.
- **`queue_order(jobs, eff, expected, now)`** sorts by priority: the effective one or the job's own promoted by its
  wait, whichever is higher. Within P1–P4 the shortest expected job goes first, with aging: the key is
  `expected minutes − waited minutes`. P5 goes oldest first, and shortest first only within the same minute.

The properties in `tests/props.rs`: `inheritance_is_monotone` (no job falls below its own priority or below a
waiter's, and raising one job never lowers another) and `no_starvation` (a job a minute arrives and one starts, so
higher work never stops; every job still starts within three promotions, its expected time and the backlog).
