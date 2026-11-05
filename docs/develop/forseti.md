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

## Admission (`admit`)

The model is a partitionable slot (jobq §5.4): each machine is one pool of cores, memory and disk, and each job
carves its share at start.

- **`budget(m, limits)`**:
  - `mem = MemAvailable − floor − reserve_user − Σ ours − others`. One of our running jobs counts its whole
    reservation for its first 300 s (a container grows after its setup), then `(reserve − current)⁺`, since what it
    uses is already gone from `MemAvailable`. `others` is `count_others` over `m.others` on `m.boot_id`; the probe has
    already dropped the reservations whose process is gone. Another scheduler's job counts `max(reserve, current)`
    whole, its use included: careful, since its `current` is that scheduler's last write.
  - `cpu = cores_usable − Σ expected CPU`: a job's mean from history, or its grant's cores when it has none
    (`Expected::known()` is false).
- **`admit(job, eff, exp, m, budget, limits)`** checks, in this order, and answers the first `WaitReason` that holds
  it back:
  1. with `fixed_slots(n)`: the count alone (`Threads` at `n` running), and nothing else;
  2. power: `OnBattery` when the limits say no jobs on battery;
  3. 10 s since the last start (`Gap`);
  4. memory: `budget ≥ mem_min` (`NoRoom`);
  5. CPU: `budget ≥` the job's expected CPU (its `cores.min` with no history), plus `(overcommit − 1) × cores_usable`
     while the running jobs use less than half their grants on average (`Threads`);
  6. the PSI limits, each reading strictly below its limit (`Pressure` naming `memory`, `app memory`, `cpu` or `io`);
  7. the disk: free space after the job's `disk_gib` stays at the guard, `max(disk_guard_gb, disk_guard_pct % of the
     filesystem)` (`DiskLow`).

  `eff` is the job's effective priority; none of F1's checks reads it.
- **`size(job, exp, budget, waiting_fit)`**, the grant:
  - `cores = clamp(cpu_budget / waiting_fit, cores_min, cores_max)`: a quiet machine gives a large run its maximum,
    a long queue shrinks shares toward the minimum;
  - `mem_cap = clamp(max(p95 × 1.3, mem_min), mem_min, min(mem_max, mem_budget))`;
  - `reserve = max(p95 × 1.1, mem_min)`, never above the cap (a job can't use more than its cap, and so admitted
    reservations never pass the budget);
  - with no history the cap is `min(mem_max, mem_budget)` and the reserve `mem_min`.
- **`oom_rerun(mem)`**: the one re-run after an `oom` verdict asks `mem_min × 1.5`.
- **`head_protection(order, waiting_since, now, fits)`**: when the first job of the order has waited 600 s without
  fitting anywhere, it names its best machine, and the shell admits nothing smaller there
  (`WaitReason::HeadProtection`) until it starts. Backfill replaces this in F2.

## Eviction and drains (`evict`, `drain`)

- **`may_evict(victim, claimant, now)`**: a P1 or P2 claimant may evict a job at least two priorities below it, and
  only one that is restartable, has run less than half its expected time, and was never evicted before. A job is
  evicted at most once.
- **`preempt_victims(claimant, m, need_mib, now, misses_2min_goal)`**: newest first, until what they free (their use
  plus what the budget held for them) covers the need; nothing when the claimant wouldn't miss its 2-minute start
  goal, or when evicting every candidate still wouldn't free enough.
- **Drains** for whole-machine runs: one starts only with no P1–P2 work pending (`drain_may_start`), pauses while P1
  work is there (`drain_paused`), is given up after 1800 s (`drain_abandon`), and may evict running P5 jobs after
  900 s (`drain_may_evict_p5`). A timing run that has started is never stopped.

## Two schedulers on one machine (`reserve`)

A hub and jobq share the laptop; a runner and jobq the desktop; two hubs may share a runner. Each writes a
`Reservation { scheduler, pid, boot_id, start_time, job, reserve_mib, current_mib, expires }` per running job
(`sleipnir::linux::reserve` keeps them as files under `$XDG_RUNTIME_DIR/forseti/` and takes `admit.lock` around
each admission).

- **`count_others(rs, boot_id, alive, own_scheduler, now)`**: Σ `max(reserve, current)` over the reservations of
  other schedulers that are on this boot, whose process is alive (pid and start time, so a reused pid isn't taken
  for it) and that haven't expired. A job written twice counts once.
- **`ladder_actor(own, own_slice_mib, others)`**: at ladder level 2 or higher only the scheduler whose slice holds
  the most memory acts; a tie goes to the name first in order.

`admitted_reservations_never_exceed_the_budget` (a property) and `admissions_in_every_order_stay_in_the_budget` ([A],
every interleaving of two schedulers' admissions under the lock) check that what both reserve stays within one
machine's budget; `a_job_is_evicted_at_most_once` checks the eviction limit over repeated rounds.

## Memory safety (`safety`)

The pure half of jobq §5.5's four layers; the shell writes the top slice's `MemoryHigh` and `MemoryMax` every 2 s
and reads the PSI files every second.

- **The cap.** `static_ceiling(profile, mem_total)` bounds it while no scheduler runs (dedicated `MemTotal − 3 GiB`,
  workstation `MemTotal − 8 GiB`). `cap_target(ours_used, MemAvailable, reserve_user, floor, ceiling)` is
  `ours_used + MemAvailable − reserve_user − floor`, never above the ceiling. `cap_step(high, max, target, step)`:
  raising writes `MemoryMax = target + 512 MiB` first, then `MemoryHigh = target`; lowering writes `MemoryHigh =
  target` at once, then brings `MemoryMax` down by at most one step toward `target + 512 MiB`. The step is
  `STEP_MIB`, 1 GiB per tick: the oomd spike found nothing against it (lowering `MemoryMax` past use gives a kernel
  OOM within the tick, which classifies cleanly).
- **The ladder.** `ladder_level(m, limits)`:

  | Level | Dedicated | Workstation |
  |---|---|---|
  | tight: stop admitting | `MemAvailable < floor + 2 GiB`, or memory PSI above the admission limit | `< reserve_user + floor + 2 GiB`, PSI above its limit, or the user's apps above theirs |
  | pressure | `< floor + 1 GiB`, or PSI above 20 % | (none) |
  | danger | `< floor`, or PSI above 40 % | `< reserve_user + floor`, or the apps above 5 % |

  `ladder_actions(level, profile, running, since_level2_s, last_kill)`: a dedicated machine at pressure pauses the
  lowest-priority long builds and evicts the lowest-priority short jobs (under 5 minutes), and after 10 s without
  relief acts as at danger, which evicts one job per tick, lowest priority first, newest first. A workstation stops
  admitting until danger, then kills our newest job, again every 5 s while it holds; it never pauses. At level 2 or
  higher only the `ladder_actor` acts.
- **The throttle rules** (both profiles; the oomd spike). Without swap a job over `MemoryHigh` freezes, and it reaches
  oomd's 80 % `full` in 18–25 s; the user's pressure never shows it. So `throttle_actions(over_high_s, ours_full_s,
  running)` evicts the newest job over its reservation (else the newest) once our slice has been over `MemoryHigh`
  for 10 s, or its memory `full avg10` above 50 % for 10 s: the throttle is resolved within 20 s.

`cap_never_exceeds_the_static_ceiling` (a property) runs the cap tick after tick from the ceiling: `MemoryHigh`
never passes it, `MemoryMax` never by more than 512 MiB, and `MemoryMax` never comes down more than a step.

## Kill classes (`classify`)

`classify(&ExitEvidence)` tells kills apart, so a kill never reads as red. First match wins:

1. we evicted it: `Evicted`;
2. a reason written before our kill (`kill_reason`: the disk guard, the ladder, a setup refusal, a key not
   delivered): `Infra(reason)`;
3. the job slice's `oom_kill` grew: `Oom` (re-run once at × 1.5);
4. an oomd line that killed or marked it (`oomd_line_matches`: systemd 259 logs "Killed …", 262 "Marked … for
   killing" and may leave the job frozen until its timeout), or a SIGKILL (exit 137) with no `oom_kill`:
   `Infra("oomd/killed")`;
5. SIGSEGV or SIGABRT (exit 139 or 134): `Crash`, the only verdict the crash splitter takes;
6. the timeout: `Timeout`;
7. the row parser's verdict, else the exit code; a parser's pass without exit 0 is `Red`.

The named reasons are in `classify::infra`: `runner lost`, `preempted`, `disk`, `key not delivered`, `setup`,
`killed` and `oomd/killed`. The hub records `runner lost` and `preempted` itself; they leave no exit evidence.

## History (`history`)

Every finished run leaves a `HistRow { key, machine, grant, wall_s, cpu_s, mem_peak_mib, verdict, disturbed, at,
warm }`.

- **`history_key(spec)`**: the kind, then the suite and the rows selected, or else the command with paths
  normalised (the job's tree and any `.claude/worktrees/<name>` path become `{tree}`, a `.claude/tmp` path `{tmp}`),
  so one command run from two worktrees has one history.
- **`expected(rows, other, speed_ratio, suite_default)`**: the median time of the last 5 undisturbed runs on this
  machine, with their mean CPU and the p95 of their peak memory; else the same from other machines' rows, the time ×
  the static speed ratio; else the suite's default; else 10 minutes. The last two know no CPU or memory.

## Placement (`place`)

Each runner decides how much it can take (its own `admit`); the hub decides which job goes where. For each queued
job, in queue order, the hub builds a `Candidate` per machine (the local one with `local: true`) and calls `pick`.

- **`trust_ok(job, keys, runner, keys_allowed)`**, the trust table (runners design §6.6). A job that names keys is
  `private+keys` whatever its trust says.

  | Job trust | `mine` | `my-cloud` | `shared` |
  |---|---|---|---|
  | `public` | yes | yes | yes |
  | `private` | yes | yes | no |
  | `private+keys` | yes | if every key is on that runner's list | no |

- **`filter(job, c, send, machines_cell_allows)`**, the hard filters in this order: trust and the pin (`local_only`,
  or `on` naming another machine), features, the runner's state (benched, needs login, needs keys, awaiting the
  user's confirm, unreachable, draining or preempting), the project's send mode and the runner's accept mode (a job
  leaves only if the project sends it and the runner accepts it), and the starter's `machines` matrix cell. The local
  machine passes trust, the modes and the cell always.
- **`finish(job, c, now)`**: `wait + start + transfer + expected`. The transfer is `missing_bytes / link_bps` (bytes
  per second; 0 on the local machine, and 0 until the rate is measured). The expected time comes from `c.history`
  (the job's rows from every machine): this machine's, else another machine's × `c.speed`, the static speed ratio,
  else 10 minutes.
- **`cloud_counts(eff, gates_allowed, is_gate, best_own_s, cloud_s, after_s, projection_ok)`**: a cloud machine
  counts only for work someone waits on (priority 1–3, or a gate's when the project allows cloud for gates), only if
  it finishes at least `runners-cloud-after` before the best own machine, and only if starting it fits the spend
  projection.
- **`pick(job, cands, ctx)`**: the smallest finish among the candidates that pass; ties go to the local machine,
  then `mine`, `my-cloud`, `shared`. With none, `Pick::Wait` carries the reason of the candidate that came closest
  (the latest check it failed: a job pinned to a benched runner waits as `Benched`); with no candidates at all,
  `NoRunner`.
- **`why_here(job, cands, ctx)`**: when trust alone keeps a job here, the hub says why, in the design's words:
  "runs here: needs key `K`, which no runner may get", "runs here: N commits not on origin" (a public project's job
  whose commits the origin lacks), "runs here: project P is private; the only free runner is shared".

Properties: `a_job_never_goes_to_a_runner_its_trust_forbids` over generated jobs, runners and modes.

## Fairness (`fair`)

Within a priority, projects share by deficit round robin on machine-seconds over the last hour. `Drr::order(order,
eff, project_of, usage_last_hour_s, weights)` reorders each run of one priority in the queue order (never across
runs, and P1 not at all): a project starts with its use ÷ its weight (default 1), the project with the least goes
next (on a tie, the one whose next job comes first), and each job charges it `quantum_s` (600 s) ÷ its weight. A
project that used less goes first, shares follow the weights, and one project's 400-chunk gate can't starve another
project's priority-4 work. `nothing_starves_under_fairness` bounds when each project's first job comes by the use
gaps and weights alone, however many jobs the others queue.
