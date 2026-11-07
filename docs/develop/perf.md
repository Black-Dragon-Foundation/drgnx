# Performance

drgnx is measured, not guessed at: every interaction it cares about is timed in a real GUI session (the
[harness](harness.md)), judged against budgets, and kept in a history.

```
drgnx test --perf           every workload; fails when a gated budget (allocation, CPU, rows) breaks; wall clock is reported;
                            what got worse than the local history is printed
drgnx test --perf --audit   the workloads with every hook function timed: judged on the hook budget only
drgnx test --soak [MIN]     the input workloads in a loop for MIN minutes (30); fails when memory grows
drgnx test --day [MIN]      the synthetic day (below): a pinned session of files, Org, eglot, vc-git and transcript replays
DRGNX_STARTUP_TRACE=FILE    emacs --init-directory …/init: where startup time goes, written to FILE
DRGNX_PERF_WORKLOADS='A B'  only those workloads (space-separated names from the table below; unset: all; a typo is an error).
                            A partial run is judged against its own budgets and writes no history line
DRGNX_PERF_RESULTS=FILE     write the results as JSON: every metric (wall clock included), each workload's calibration,
                            the Emacs version and the commit
DRGNX_UI_SIZE=WxH           the perf sessions' monitor size (default 1400x800); DRGNX_UI_SCALE=S their scale (a session
                            that cannot apply it fails to start: exit 1, nothing measured)
DRGNX_MODAL_ELPA=DIR        a package directory with evil (see below): adds the three evil workloads
```

## What is measured

| Workload | What it does | Measured |
|---|---|---|
| typing | 186 characters into the middle of a ~140k-line Emacs Lisp file | input latency (p50/p95/max), GC count, time and each pause |
| scrolling | 30 pages down and up in the same file | input latency |
| tabs | 20 next-tab switches among 20 open files | input latency |
| explorer | focus the Explorer, 10 rows down (each one moves), back | input latency |
| agent-typing | typing while an agent streams a reply (the Agents list is shown): a `ratatoskr-mock acp` in a Ratatoskr hub, the editor's session a mirror of the hub's (see "The agent workloads" below); the turn takes three seconds (checked: its `stop` entry is not in the mirror yet at the end) | input latency |
| code-scrolling | `<next>`×30 then `<prior>`×30 through the 12k-line fixture with sticky scroll and indent guides (when installed) on — smooth scrolling is on but pixel scrolling is a wheel's, not `<next>`'s | input latency |
| diff-scrolling | `<next>`×30 then `<prior>`×30 through a 10k-line diff in the split layout | input latency |
| typing-with-ghost | the typing workload with ghost text on: a mock model answers every pause at once, the pause shortened to 10 ms so each key asks and the next cancels (checked: it asked) | input latency |
| replace-typing | 22 characters into the fixture while the Search view lists 10k matches in 100 files: the first key starts the search (checked: at least 5 keys typed while it streamed, all 10k listed) | input latency, and `:slice_ms`: the wall time of each view draw while the matches stream (budget: max 16 ms) |
| replace-retype | the same 10k matches listed and drawn, then the string `pi` typed 5 times into the Replace field: after the pause each match row is patched with its new preview, in slices, the visible rows first (checked: no full draw, the rows equal a fresh render of the view's keys) | input latency, and `:slice_ms`: the wall time of each view draw (`drgnx-view--draw-buffer`, timed by a harness-side advice; budget: max 6 ms) |
| live-view | the typing workload's 186 characters while the Live view, beside the file, shows a mock browser's JPEG frames as wide as the view asked for (as Chrome sends them), 30 a second, each sent once the last was acknowledged (two frames that differ, chosen by the count of frames drawn so that each drawn frame differs from the last, as a page's frames differ, so the last frame can stay cached as the next one's stand-in; the mock runs in the same Emacs, so their messages and websocket frames are made once; without ImageMagick the frames are a few bytes no decoder takes, so drawing costs less) (checked: frames were drawn) | input latency; measured `:live :blank` (redisplays that drew a frame's space with no picture: a decode Nidhogg's image worker deferred, drawn without the last frame as its stand-in; 0 without the worker), `:frames`, `:deferred`, `:timing` (Nidhogg's `nidhogg-workers--test-image-timing`, when the build has it) |
| agent-settings-open | the Claude Code settings page opened and drawn (`redisplay`) against a fixture home: a 5 MB `.claude.json` (300 projects with history), 50 MCP servers and 200 skills; three runs | milliseconds until drawn (budget 150) and the processes started (budget 0: opening the page starts nothing) |
| settings-start | `settings.el` with 200 entries (100 of defined options, 100 of packages not loaded; no `:set` functions) read and applied as at a second start; three runs | milliseconds (`:read_ms`, budget 2) |
| settings-page | the Settings page opened and drawn with 5,000 customizable variables added to the session's own, then the name of one typed into the search a character at a time | `:open_ms` (budget 100), `:key_p50_ms` and `:key_max_ms` (a keystroke with its redisplay; the worst, budget 16), `:key_search_max_ms` (the search without the redisplay) |
| settings-prov | a 500-line `config.el` (a header, ten `load`s of small libraries, 97 blocks of a function, a managed variable's `setq` and an `add-hook`) loaded plain and with provenance, interleaved, nine rounds | `:prov_pct` (budget 5), `:load_ms`, `:prov_load_ms`, and `:cold_extra_ms` (what the first, uncached load adds) |
| settings-sync | the settings index written for 200 fixture packages of three files each | `:index_ms` (budget 2000) |
| settings-open | 30 files in a project with a shared and a private workspace file and a language override, opened with the workspace and language layers in and out, interleaved (the layers are checked to have applied) | `:open_on_ms`, `:open_off_ms` (medians per open) and `:delta_ms`, what the layers add (budget 1) |
| remote-typing | the typing workload's 186 characters in a local file while the Explorer lists a mock-method root (test/fixtures/tramp-mock.el: a real TRAMP connection to a local `sh`) and its connection is dead, the segment showing it lost (checked: nothing was sent to the remote, the connection stayed dead) | input latency |
| typing-with-index | the typing workload's 186 characters with the search module on and the drgnx repo indexed by the hub (Hrafn): tier 1 is finished before the keys, tier 2 runs while they are typed (checked: the hub still holds the chunks) | input latency |
| typing-evil | the typing workload with Vim keys: `i`, the same six strings, `<escape>` (checked: typed, back in normal state) | input latency |
| motions-evil | a 5000-line copy of the fixture, normal state, from the middle: `j`×20, `w`×20, `}`×10, `C-d`×5, `C-u`×5 (checked: point moved) | input latency |
| explorer-evil | the explorer workload with Vim keys: `SPC E`, `j`×10, `<escape>` | input latency |
| window-switch | `C-x o` ×50 across three editor groups showing one file, with the left dock, the panel and the right dock shown (checked: the selected window changed 50 times) | input latency |
| terminal-typing | 6 × 20 characters (`echo hello world 123`) typed into an eat terminal in the panel running `cat` (no shell, so no shell configuration; the tty echoes every key and eat draws it) | input latency |
| terminal-output | the same 120 characters typed into the fixture while an eat terminal in the panel streams `seq 1 2000` in a loop (checked: the terminal's process is alive, its window is shown and its text changed while typing) | input latency |
| frames | 5 new frames until drawn | frame time |
| redisplay | 30 forced redisplays of the fixture | redisplay time |
| startup | a drgnx daemon (isolated: its own HOME and drgnx dirs, the harness's environment allowlist) until its server answers (a daemon that never answers fails), 4 starts, the first dropped | server-ready time, modules' time |
| memory | after the workloads, a GC, then one key (`<down>`) and the pause after it, read once the idle collection's timer has given the freed heap back to the system (as it does for a user: `drgnx-gc--idle`) | RSS |

**The agent workload** (`agent-typing`) run a Ratatoskr hub in the session, as the
user's editor does: `$DRGNX_RATATOSKR_BIN` (a build with the `test-hooks` feature, `ratatoskr-mock` in the same folder;
without it the workloads fail and say so) is started with a settings file of its own whose profile `mock` is
`ratatoskr-mock acp --as claude --script FILE`. The script's n-th line is the program of the n-th prompt (`say TEXT`,
`silent SECONDS`: docs/develop/runtime.md), so a turn is the same whatever the prompt says. A prompt past the last
line runs its own words and ends at once, so a script needs a line for every run one mock serves. The session holds
mirrors (`drgnx-agents-mirror-start`). The hub tells of a session's state at most every 50 ms, so a short turn can go
by with no `busy` status: the workloads count the `stop` entries of the transcript to know that a turn has ended (the
check "typed while it streamed" is a turn that has not ended), never the status. The agents and their events are the hub's.

**Input latency** is a command's start until the screen shows it: `post-command-hook` redisplays
before it reads the clock (which leaves fontification and mode-line work in). The latency ends in the hook, not in a
0 s timer: under the harness a timer ran at the next paced input event, so input p95 sat at the tick (40.3 ms at the
0.04 s tick, 30.3 at 0.03; `DRGNX_UITEST_TICK` sets the tick for a probe). Keys arrive one at a time (the harness), so typed-ahead input — where Emacs skips
redisplay — is not covered; the harness's own recorder runs inside the measured span (small).

**Per command** (`drgnx-perf-begin` / `drgnx-perf-end`), from `pre-command-hook` to the redisplay after the command,
three numbers are recorded for each of the commands of a workload:

- `:input`, wall milliseconds, as above;
- `:alloc`, the objects allocated: the seven `memory-use-counts` added, less the 7 conses of the reading itself.
  The same code allocates the same on a quiet machine and a busy one (a timer or a process filter that happens to run
  inside the span adds its own, so two sessions agree to within a few per cent, not to the object);
- `:cpu_ms`, this process's CPU time (`current-cpu-time`).

Each is `(:n :p50 :p90 :p95 :p99 :max :mean)` (nearest rank); **`:p95` and `:p99` are null below n = 100**: the tail of
fewer samples is the maximum or next to it. A run also has `:rows`, the growth of the sum of the row counters
(`drgnx-perf-row-counters`: the Explorer's and the Buffers panel's renders), `:gc_count`, `:gc_ms`
and `:gc_pause`. A perf session runs at drgnx's GC settings, as a user's does (HARNESS-GC-1): the run stops with an error
when its `gc-cons-threshold` is not `drgnx-gc-cons-threshold`.

Every workload runs three times (each with its own setup, its typing fixture reused, everything it opened closed
after it) and the median of each number is kept, so one noisy run never decides.

The typing fixture is `core/` three times with one form of the lab's own between two files near its middle
(`drgnx-perf-run--fixture-spot`); the keys go into that form, six lists deep, the same text in every tree. They used to
go to the fixture's middle line, which moves whenever a core file is added: on a line with too few lists around it,
each `(let ((x` typed left a list open past its form, and Emacs Lisp's font-lock (`lisp--el-funcall-position-p`,
through `forward-sexp`) scanned the rest of the 4 MB file at every key, about one key in five costing 190 to 370 ms,
in every workload that types into the fixture.

## Vim keys (evil)

The three `-evil` workloads switch the session to the Vim key stack (`editor/evil` on, the engine started, `(vim app
editing window)`) and back to VS Code's keys afterwards. They need evil, which a checkout does not ship: set
`DRGNX_MODAL_ELPA` to the package directory the modal tests use ([harness.md](harness.md), "Modal tests"); without it
`--perf` prints `perf: evil workloads skipped — set DRGNX_MODAL_ELPA` and judges the rest. They run last, because evil
cannot be unloaded from a session and the other workloads (and the memory figure) stay what they were without it.
`drgnx test --perf` passes the variable on to the session.

Their budgets are those of the stack without evil, except the Explorer's keys (p95 8 ms, the Explorer key budget of
`harness/drgnx-bench.el`). One more rule is reported beside them: **`typing-evil` input p95 may exceed `typing` input
p95 by at most 1 ms in the same run** (`drgnx-perf-run--relative-fails`), so evil's cost shows even when both stay
under 16 ms.

First measurements (2026-10-18, a busy machine: load 3-5, so every number is high; the budgets above are PROVISIONAL
until a quiet-machine run pins them). Worst of 5 runs (each already the median of three): `typing-evil` p95 13.0 /
max 19.9 ms, `motions-evil` 9.6 / 11.5 ms, `explorer-evil` 6.4 / 6.4 ms. Next to them `typing` measured 12.6-14.1 ms p95
in the same runs, and `typing-evil` minus `typing` was between -1.1 and -0.1 ms: evil added nothing measurable.

To measure only some workloads (the run is GUI-heavy), name them:

```sh
DRGNX_MODAL_ELPA=… DRGNX_PERF_WORKLOADS='typing typing-evil' bin/drgnx test --perf
```

Only the budgets of the workloads that ran are judged, and such a run is not written to the history. Without the
filter every budget is judged: a budget whose workload did not run is reported as "not measured" (the one exception:
the three `-evil` rows when `DRGNX_MODAL_ELPA` is unset). Naming `typing-evil` without `typing` skips the 1 ms rule
and the run says so; a filter that is not a valid regexp, or matches no workload, stops the run with a message.

## Budgets

`test/perf/budgets.eld`: entries `(WORKLOAD PATH LIMIT &rest PLIST)`; `:emacs MAJOR` limits an entry to that Emacs
major version (for a budget that differs between versions; none exist now that 31.1 is the only target).

**Gated** (`drgnx-perf-gated-metrics`: `:alloc :cpu_ms :rows :processes :rss_kb`) - what the load on the machine does
not move. A broken one fails the run (`drgnx-perf-verdict`; `--perf` exits 1):

| Path | Limit | Seeded as |
|---|---|---|
| `(:alloc :p50)` | objects allocated per command | measured x 1.25, rounded up |
| `(:cpu_ms :p50)` (typing, typing-with-ghost, remote-typing) | a normal key: 8-12 ms. These rows and the p90 ones were 30 and 350-420 ms while one key in ten cost 100-200 ms (the fixture's open list and a Nidhogg redisplay, both fixed); seeded again 2026-11-05, so a key spike fails the run | the measured p50 with the same headroom |
| `(:cpu_ms :p90)` | CPU ms per command, times `DRGNX_PERF_CPU_FACTOR` (default 1; 2 on hosted runners) | the container's p90 x 2 |
| `(:rows)` | rows drawn during the run, exact | measured |
| `(:processes)`, `(:rss_kb)` | as before | the design |

**Reported** (every other path: `:input`, `:redisplay`, `:frame`, `:server_ms`, `:modules_ms`, `:draw_ms`,
`:slice_ms`, the GC numbers): wall clock. The run prints `report ...` lines with the value and the budget and does not
judge them; the paired A/B run at n >= 100 does. The numbers the design fixed - keystroke and scroll p95 < 16 ms, max
50 ms, a GC pause p95 < 50 ms, a new frame p95 < 500 ms, a daemon's server ready < 1 s, modules < 1.8 s, redisplay p95
16 ms - stay in the file as the targets those reports are read against; a p95 or p99 of fewer than 100 samples is shown
as `- (n=N, under 100: not judged)`.

**Seeding.** `:alloc` and `:rows` come from the Emacs 31.1 container (the GUI image; `bin/drgnx test --container`
has no `--perf` yet, so the tier runs by hand: `podman run --memory 4g --memory-swap 4g --security-opt
seccomp=unconfined --security-opt label=disable -v CHECKOUT:/src:ro -v OUT:/out -e DRGNX_PERF_RESULTS=/out/r.json -w
/src drgnx-test-gui:f45 bin/drgnx test --perf`), twice: allocation and rows must agree
between the runs. The checkout is not built there, so the figures are those of code loaded from source; compiled
code allocates less, so a built checkout stays under them. A workload that could not run in the container has no
gated rows yet and is named, with the reason, in `drgnx-perf-run-unseeded` (a test checks both ways).
In a container the lab names the workloads that error there (`drgnx-perf-run-container-skipped`: the Live view and the terminal ones, for want of the websocket and eat packages in the image) and leaves them out, so the CI perf job does not fail on them; on a host they run. With `DRGNX_USER_ELPA` naming a directory that holds an `eat-VERSION` package, `bin/drgnx test --container --perf` mounts it read-only and the terminal workloads run in the container too; with a `websocket-VERSION` package there the Live view runs too. `transcript-replay` (the synthetic day's stream, below) runs in the container too, with no agent or hub.

**Raising a budget** is a change of its own: edit `budgets.eld` in the same commit as the code that needs it, with the
reason in a comment on the row. A budget is raised for a measured, explained increase, never to make a run pass.

**History.** `perf-history.jsonl` (the harness state root) gets one line per run in which every workload ran, with its
commit. After a run, `drgnx-perf-regressions` prints the metrics whose `(:alloc :p50)` or `(:cpu_ms :p50)` is more than
15% worse than the median of the last five runs and worse by more than a floor: the larger of 8 conses (0.5 ms of CPU)
and twice the metric's spread (max - min) over those five runs. It is a local report (`regression (reported, local
history)`), never a failure: CI has no history and gates on the budgets. The new-frame path from a daemon
(`emacsclient -c`) is judged by the scenario `frame-from-daemon-fast` ([scenarios.md](scenarios.md)).

## Load, the wall clock and the calibration

A busy machine used to refuse the run (exit 3) because wall-clock numbers rose with the load: next to other test
runs, scrolling p95 went from 11.6 to 17.6 ms on the same commit. Nothing refuses now. `--perf` exits 0 or 1, and
what it can judge on any machine is what load does not move (allocation, CPU, rows). Wall clock is **reported**
with its sample count, and every workload carries a **calibration** (`drgnx-perf-calibrate`): a fixed byte-compiled
loop of 2,000,000 iterations timed on the wall clock and on the process's CPU clock. Alone on a core they agree;
`:loaded` is t when wall / CPU > 1.3, and the run prints `(loaded)` after that workload's wall numbers. The history
line still records the highest load average seen (`load`). A wall-clock judgement is made by the paired A/B run at
n >= 100, not by one run.

## Allocation that follows the wall clock (`replace-typing`)

`replace-typing` types while 10k matches stream into a view, and the view draws its rows in time-boxed slices that run
between the keys. A slower machine therefore runs more slices inside each of the 22 commands, and the per-command
allocation grows with the command's wall time: in the Emacs 31.1 GUI container on the same tree, input p50 19 / 37 ms gave
`:alloc :p50` 12732 / 15755, CI's slower runner (input p50 51 ms) gave 33072 against a seed run of 25252 (budget 31565).
An A/B run against the seed commit (047955be, host, n=176 per side) found 8074 against 8379 objects: no code change in
the allocation. So the budget follows the larger of the two CI-image measurements, 33072 x 1.25 = 41340, and not a
local machine's number; the other allocation rows, whose commands do not wait on a stream, agree to a few percent between
machines and keep their seeds. A row of this kind that moves again is judged by `--ab` first, not by re-seeding.

The keys also used to arrive in bursts. The harness types onto `unread-command-events`, and while the view's slices and
the search's parse ran as zero-delay timer chains, Emacs's wait for input ran them back to back and never returned to
read those keys (it leaves its timers for keyboard input only): up to ten keys queued, then ran with no redisplay
between them, and each key's 0 s probe timer ran inside the previous one's `redisplay`, so its latency counted every
redisplay after its own. With Glitnir (the compositor) on, 178 of 198 keys came in such bursts (input p50 58 ms, keys
alone 7.8 ms) against 101 of 198 off (21.6 / 16.2 ms): the A/B judged that "regressed" by +27.8 ms, an artefact of the
timing. Both chains now yield to pending input (`drgnx-timer-chain-delay`, core.md "A chain yields to input"): 192 of
198 keys alone on (a traced run), and the A/B judges the median improved, -19.6 ms [-26.8, -11.3] (input p50 7.3
on against 21.2 ms off, 2880x1800 at scale 2, n=176/172).

## Waiting for a view inside a workload (`replace-retype`)

A workload step that waits for a view to finish drawing (`drgnx-perf--replace-idle`: the arm, the measure and the
check of both replace workloads) polls with `(accept-process-output nil 0)` while a timer is due and 50 ms otherwise,
and signals an error if the view still has work after 100 s. One `accept-process-output` runs one link of a chain of
zero-delay timers however long it waits ([core.md](core.md), "Waits"), so a plain 50 ms poll gave the Search view one
4 ms slice per poll. The wait then gave up at its deadline with rows left, and the command loop finished them: it
runs a zero-delay chain link after link, with a redisplay between, and reads no socket until the chain ends. The
harness's next call (`drgnx-uitest-api-measure-begin`) got no answer in 20 s (CI run of 83e460be; locally at
`--cpus 2`: the arm's 30 s wait left 1,400 of 10,100 rows, the second repeat's left about 11,000 row changes). A view step
must not return while the view is busy, and `drgnx-ui-call`'s "no answer" error names the form it sent.

## Judging wall clock: `--perf --ab REF`

```sh
DRGNX_PERF_WORKLOADS=typing bin/drgnx test --perf --ab main [--n 100]
```

Wall clock is judged by interleaving two trees, so no quiet machine is needed. REF is exported with `git archive`
(a plain directory under `$DRGNX_RUN_TMP`, not a worktree), both trees are built (`bin/drgnx build`), and each gets a
session: the work tree's own, and one whose `init/`, `core/`, `wb/` and `modules/` come from REF
(`drgnx-ui-session-repo`; the harness and the probes are always the work tree's). Per workload: setup in both, one
discarded warm-up run per side, then runs A, B, A, B, ... until each side has at least N (default 100) per-command wall
samples and two runs. A calibration runs in both sessions before and after; one loaded calibration means the
workload is not judged. The command takes the host for itself (the exclusive lease); if it waits ten minutes without
getting it, it runs plain `--perf` on the work tree and prints `wall clock not judged: host busy`.

The verdict is a seeded bootstrap (2000 resamples, its own generator): the median of the work tree minus the median
of REF, with a 95% interval. The threshold is T = max(1 ms, 10% of REF's median). **regressed**: the whole
interval is above T. **no-regression**: all of it is at or below T. **inconclusive**: T is inside it. The
report also prints both sides' n, p50, p90, p95, allocation, CPU and rows, and judges the work tree's absolute wall
budgets (`(:input :p95)` and `:max`) at n >= 100. A workload that errors on REF (it did not exist there), or that
has no per-command samples (frames, startup, memory), is reported "not comparable".

Exit: 0 judged, no regression, budgets hold; 1 regressed or a wall budget fails; 3 not judged (a loaded calibration,
a busy host, an inconclusive interval). `DRGNX_PERF_RESULTS` gets the verdicts and both sides' stats.

**p95 and probe verdicts.** The median verdict above cannot see a tail that moves while the median stays, and the
gate is "at most +1 ms **p95**". `drgnx-perf-bootstrap-rounds` and `drgnx-perf-ab-verdict` therefore take
`:stat p95`: the same pairs of rounds are resampled with replacement, each side's samples of the drawn pairs are pooled
and the statistic is the nearest-rank p95 of the work tree minus that of REF (`:diff` is the same over all samples).
`:threshold` overrides T. A verdict `improved` (the whole interval below 0) also counts as no regression. The
`:compose` rows are wall clock too (reported by `--perf`, never gated), so a probe value gets its own verdict,
`drgnx-perf-ab-probe-verdict ROUNDS PATH`: each round carries both sides' run results, the statistic per round is the
value at PATH (e.g. `(:compose :draw-ms :p95)`) of the work tree minus REF's, pairs and bootstrap as for the median,
T = max(1 ms, 10 % of REF's median value); `not comparable` when a side lacks the number.

`--ab REF` still judges the median only and also prints the p95 verdict (T = 1 ms). `--ab-env` prints, per workload,
the median verdict, the p95 verdict at T = 1 ms and, when the runs carry it, the probe verdict on
`(:compose :draw-ms :p95)`; any of them `regressed` is exit 1, any `inconclusive` is exit 3, and an A/A that fails
(see "One A/A per A/B invocation") is exit 4. It also judges the judged
side's `:compose` budget rows (the median of the value over its rounds) at n >= 100, n being `(:compose :count)` summed
over its rounds.

**Fresh builds and the eln cache (PERF-ELN-1).** A tree that was just built has no native-compiled files yet: its
session compiles them in the background while it runs, and the first runs cost several times more. Both sessions
therefore wait until their native compilation has drained, and both run a discarded warm-up before the samples; the
report prints each side's warm-up p50 next to the measured one. A plain `--perf` run waits too, before its first
workload: on a built tree `typing`, which runs first, measured the compilation (its calibration loop ran at 59 ms
against 13 ms in every later workload of the same session, and the watchdog's stacks show the compilation's loads). A checkout
that is not built (CI's perf job) compiles nothing, and the wait ends at once.

## Glitnir (the compositor): popups, the `compose` probe, A/B by environment

**The `compose` probe.** When `glitnir-stats` is bound, `drgnx-perf-begin` resets it and `drgnx-perf-end` stores its
plist under `:compose` (`(:compose :compose-ms :p95)`, `(:compose :draw-ms :p95)`, `(:compose :painted-px)`,
`(:compose :count)`, ...), median-reduced over the three runs like every other number. On a build without Glitnir, or
when the stats are nil (an inactive root), there is no `:compose` row and nothing fails.

**Key to present.** `:input` ends at the redisplay after the command, but the picture reaches the compositor at the
frame clock's after-paint, which may come later, and when it comes differs between Glitnir on and off. On a build
whose `glitnir--last-paint` has `:present-ns` (that after-paint's time), each command also records the time from its
start to the first after-paint that sent a paint, waiting for it (100 ms at most) after the command's own numbers are
taken; a run stores them as `:present` (stats, as for `:input`), on both sides of an A/B. The A/B prints them as
`key to present (ms, REF/tree): p50 …/… p90 …/…` under each judged workload: reported, not judged.

`DRGNX_PERF_GLITNIR=on|off`
sets `glitnir-enable` in the session when recording begins (any other value leaves it alone); `drgnx test --perf`
passes it on to the session.

**The P1 workloads.** `popup-typing` (corfu open, 200+ characters), `popup-churn` (a posframe shown, moved and
hidden 200 times; the hides are measured), `scroll-under-popup` (an eldoc-box at point, 60 `<next>` then 60
`<prior>`: 120 samples, above the 100 that make p95 non-null) and `scroll-full-window` (one window filling the frame,
`<down>` 300 times (C-n is File > New)). The first three need the pinned child-frame packages: set `DRGNX_CHILDFRAME_ELPA`
([harness.md](harness.md), "Child-frame packages"); without it `--perf` prints `perf: popup workloads skipped` and
runs the rest (`scroll-full-window` needs no package).

**Glitnir A/B.**

```sh
DRGNX_PERF_WORKLOADS=popup-typing bin/drgnx test --perf --ab-env DRGNX_PERF_GLITNIR=on,off
```

`--ab-env VAR=JUDGED,REF` is the interleaved A/B of the section above on **one** tree: two sessions, no export and
one build. The first value is the **judged** side (the tool's "work tree" role), the second the **reference**, so
"regressed" means the judged value (Glitnir on) is slower. Without the comma it is a usage error (exit 2). Only
`DRGNX_PERF_GLITNIR` can be set this way. **Do not pass `--n`** in a gate run: the default (at least 100 per-command
samples a side) is what makes p95 non-null; `--n` only exists to shorten a trial run. Verdicts, exit codes and the
lease are those of `--ab`.

**The P1 budget rows** (spec §9.2, `test/perf/budgets.eld`). `popup-typing`, `popup-churn` and `scroll-under-popup`
each have `(:compose :compose-ms :p95)` 2 ms, `(:compose :compose-ms :max)` 8 ms and `(:input :p95)` 16 ms, judged on
the Glitnir-on side of the A/B above; `scroll-full-window` is measured only. A row may carry `:known ID :fails-above
CEILING`: a known failure whose value above the row's limit is printed as `KNOWN … (ID; fails above CEILING)` and
fails the run only above CEILING. The `popup-typing` and `popup-churn` compose p95 rows are known that way,
GL-POPUP-CHURN-FULL-1 (GTK repaints the whole root when a child frame maps or unmaps, until MP-3's widget-less child
frames), with spike (i)'s 4.42 ms as the ceiling. A row may instead carry `:known ID :fails-above-row (ROW PATH) :by
B`: its ceiling is ROW's value at PATH in the same A/B, on the judged side, plus B (ROW must run earlier in the run; a
ROW not measured in it fails the row). The `scroll-under-popup` compose p95 row is known that way, GL-SCROLL-PAGE-COPY-1,
failing only above `scrolling`'s compose p95 + 1 ms: each `<next>`/`<prior>` repaints about 93 % of the root (4.8 M
of 5.18 M device px at 2880×1800 scale 2), whose copy is 2.4–2.6 ms with or without the popup (per key 2.37 ms in
`scrolling`, 2.61 ms under the eldoc-box: the popup adds 0.24 ms). The presenting thread, where a scroll is a
layer-offset change (spec §9.2), removes it. The A/B's two sessions serve every workload, so it starts them with
`DRGNX_UI_MAX_RUNTIME` = `drgnx-perf-ab-session-runtime` (4 h) unless that is set: a full tier at 2880×1800 outlived
the default 30 min and lost both sessions mid-run ("can't find socket"). The run that judges them, on the Glitnir
build at 2880×1800 scale 2:

```sh
DRGNX_UI_SIZE=2880x1800 DRGNX_UI_SCALE=2 bin/drgnx test --perf --ab-env DRGNX_PERF_GLITNIR=on,off < /dev/null
```

## The audit's per-command hook time

`--audit` times every function on the busy hooks (`drgnx-perf-busy-hooks`, `window-state-change-functions` among
them). Besides the per-function rows (judged on `:p90`, 2 ms) it records, per command, the summed time of the audited
hook functions and of the timers that ran from that command's start to the next command's: `:hooks` per workload,
judged on its `:p90` against `drgnx-perf-run-hook-command-budget` (1.5 ms: twice the larger of the p90s measured on
2026-10-20, `typing` 0.46 and `explorer` 0.67 ms; the plan's starting value was 4). The probe's own timer, which holds the
redisplay, is left out. Process filters are not timed yet.

PERF-HOOKS-2: CI's perf job runs `--perf`, not `--audit`, so it does not enforce the `:hooks` budget; it is enforced
only in a local audit, and stays gated off in CI until it is measured on every seeded workload.

## A given Nidhogg, in a container

```sh
DRGNX_CONTAINER_NIDHOGG=/path/to/unpacked/nidhogg DRGNX_PERF_WORKLOADS=popup-typing \
  bin/drgnx test --container --perf --ab-env VAR=JUDGED,REF
DRGNX_CONTAINER_NIDHOGG=/path/to/unpacked/nidhogg bin/drgnx test --container --soak 30
```

The container runs the Nidhogg at `DRGNX_CONTAINER_NIDHOGG` (an unpacked build; see [harness.md](harness.md)) instead of
the image's, so a build under test is measured without touching the host. `--soak [MIN]` is the soak of the section above in
the GUI image, memory-capped like `--ui`; `--ab-env` is the interleaved A/B of the Glitnir section (it compiles the
tree first, so under podman the checkout is mounted as an overlay, `/src:O`: the `.elc` files go to a layer the run
throws away; other runtimes keep it read-only, where the A/B's build fails). Its two sessions run side by side, so
`--ab-env` gets two sessions' memory, `--memory 6g` (a plain `--perf` run 3g; `DRGNX_TEST_GUI_MEMORY` overrides both):
at 3g the OOM killer took one session in every `compile-flood` A/B (each peaks near 1.8 GB), and the run failed with
"Connection refused" or "End of file during parsing". Name the workloads
(`DRGNX_PERF_WORKLOADS`) for any A/B: the lab's other workloads need not suit the Nidhogg you mount.

## The synthetic day

```sh
DRGNX_CONTAINER_NIDHOGG=/path/to/unpacked/nidhogg bin/drgnx test --container --day 30
```

A long, mixed, deterministic session the container can run: for soaks and cost checks of a build (the stall
watchdog's gate) and for a rerun on a pinned release. Every input is pinned under `test/fixtures/day/`
(`drgnx-perf-day-composition` hashes them with the seed and the workload list into the 12-hex `:composition` that labels
every line, with the machine: `(:synthetic t :composition SHA :machine HOST)`).

- **Build-up**, once: the project's files and two Org trees open; eglot starts on the project against
  `test/fixtures/lsp-replay.el` (a batch Emacs on stdio that answers each request from the recorded exchange
  `lsp-exchange.eld`: no network, no language server; it reads its stdin through `/proc/PID/fd/0` on Linux, and on
  any POSIX system through the FIFO of `test/fixtures/mock-acp-stdin.sh` when started under it); `vc-git` reads the status and the log of the fixture repository
  (made in a temporary directory, two commits at fixed dates and an uncommitted change); two transcript replays
  (headless sessions fed from `transcript.eld`) start. Each step prints its time, RSS and live Lisp heap.
- **Steady**, until MIN minutes (default 30) have passed: rounds of `drgnx-perf-day-workloads` (`typing`, `scrolling`,
  `tabs`, `explorer`, `code-scrolling`, `diff-scrolling`, `replace-typing`, `replace-retype`, `window-switch`), their order shuffled per round from the fixed seed. After each round: RSS and the live heap
  (`drgnx-perf-heap-mb`, after a collection), and the number of collections. With the watchdog on, the day also reads its cumulative counters
  (never reset) at the start, after build-up and after each round, and prints per phase and per round: the monitor's CPU
  as a percent of the wall, the drain's p95 and largest bucket, missed against samples, and the stalls with felt and
  the most frequent signatures. The closing line says whether `drgnx-watchdog-mode` is on and whether the preloaded
  Lisp is natively compiled. Each workload's own stalls and `:watchdog` numbers are kept per round in the results
  JSON (`:workload_watchdog`), with the interval's numbers under `:watchdog`.
- **Rules** (`drgnx-perf-day-verdict`): RSS grows at most 20 % from the first steady round to the last, and no
  workload fails. There is **no 400 MB rule** (that is the soak's); a day is not compared with a user's numbers (a user's
  RSS is not the Lisp heap, the number of collections follows their consing, pauses differ by machine).
- **Not in it:** the workloads that need eat, websocket, evil, popups, a mock agent or the repository's own index; real
  language servers and agents; Magit (the built-in `vc-git` stands in).
- **Container memory:** `DRGNX_TEST_DAY_MEMORY` (default 6g, a desktop size; set 4g or less on a laptop), swap equal. The
  host name in the label is `DRGNX_PERF_MACHINE`, which `--container` sets to the host's.
- **Results:** `DRGNX_PERF_RESULTS` gets the composition, the phases' start and end times (to slice another log by
  phase), the build-up steps, the rounds and any errors as JSON.

## In CI

The `perf` job of `gui.yml` runs `bin/drgnx test --container --perf` on every push to `main` or `ci/*` with
`DRGNX_PERF_CPU_FACTOR=2` and writes `perf-results.json`, uploaded as the `perf-results` artifact (also when the run
fails). It gates on the budgets, not on history, and not on wall clock (the runner's clock is not the budgets' machine).

## Where things stood (2026-10-17, this machine)

| | before tuning | after |
|---|---|---|
| typing p95 / max | 2.2 / 22.8 ms | 3.5 / 20.5 ms |
| typing GC | 28 collections, 595 ms | 1 collection, 33 ms |
| scrolling p95 / max | 7.9 / 25.1 ms | 7.8 / 8.8 ms |
| frames p95 | 94 ms | 66 ms |
| redisplay p95 | 7.0 ms | 6.6 ms |
| daemon server ready | — | 206 ms (modules 24 ms) |
| RSS | 147 MB | 218 MB |
| key resolution (startup) | 82 ms | 20 ms |

## The terminal (eat), 2026-10-18

Measured on this machine at load 2.5–5 (other builds ran; each figure is the workload's median of three repeats, over
several runs, range shown):

| | input p50 | input p95 | input max | GC while typing |
|---|---|---|---|---|
| terminal-typing (`cat` echoing) | 1.3–1.8 ms | 3.5–4.9 ms | 4.0–12.5 ms | none |
| terminal-output (`seq 1 2000` in a loop, in the panel) | 1.8–2.7 ms | 4.1–6.0 ms | 23–68 ms | 9–10 collections, ~46 ms each, ~460 ms in all |

Budgets (`test/perf/budgets.eld`): terminal-typing p95 7 ms, max 13 ms; terminal-output p95 6 ms, max 50 ms (provisional, below). Typing into
a terminal costs about what typing into a file does.

**Where the output garbage comes from.** Eat's terminal emulation allocates about 470 bytes for every text segment it
writes (14 conses, 3 intervals, 10 vector cells and a string in `eat--t-write`) and 56 for each line feed, whatever the
segment's length: 110 bytes per output byte for `seq` lines, 7 for 80-column lines. A flood saturates Emacs (about 0.2 MB/s of
`seq`), so 20 to 30 MB of garbage a second and a collection every ~2 s. drgnx's own hooks do not appear in the memory
profile, `eat-minimum-latency`/`eat-maximum-latency` change nothing about the amount (larger values only make batches of
250 to 600 ms), and neither does the scrollback. Cutting the garbage means rewriting eat's writer (a fast path saved about
a quarter: not worth shadowing eat's internals).

**Where the pause lands.** A collection (45 to 55 ms: the live heap, not the garbage, sets it) is run by whichever code
allocates when the threshold is crossed. That is often the keystroke's own handling (the command, its redisplay, the
harness recorder) or the eat batch that runs before the latency timer; the pause then counts. So while a terminal prints,
`tools/terminal-eat` takes the collection itself, after an eat output batch, when no key was handled in the last 20 ms, no
input is waiting (`input-pending-p`) and 85% of `gc-cons-threshold` has been allocated: it calls the GC owner's `drgnx-gc-gap`
(below; `drgnx-gc-gap-quiet`, nil
turns it off; the module's old `drgnx-terminal-eat-gc-quiet` is an obsolete alias of it). The threshold is
unchanged (a higher one only trades the pause for a longer one: 95 ms at 256 MB, and 410 MB of memory), and the natural
collection stays as the backstop. The pause is not shortened, only kept out of a keystroke's handling; a key that arrives
during it still waits.

Measured on a machine at load 2.7 to 6.2, ten runs of terminal-output each (the workload's median of three repeats):

| | max, sorted | over 50 ms |
|---|---|---|
| without the early collection | 8.7 16.8 23.9 24.1 25.3 39.5 41.9 53.3 54.6 54.9 | 3 of 10 |
| with it | 5.3 5.6 5.9 5.9 22.3 24.0 30.7 36.3 40.7 49.4 | 0 of 10 |

A second comparison, five runs each on a busy machine (load 3.3 to 7.8), could not tell the two apart (with: 29 6 17 36
44; without: 26 5 38 32 35), so the evidence that the early collection helps is the mechanism (no collection overlapped a
slow keystroke with it) and the first ten-run comparison, not a large margin.

What remains is an eat output batch of 20 to 60 ms (under load) that a key waits for; slicing the batches (one chunk per
timer) made the p95 worse, because each slice redraws the terminal. **terminal-output's max budget is provisional**: 50 ms
is the ceiling, not a measurement (ten runs per arm, a busy machine, worst 49.4). The failures it can still give come from
the length of eat's output batches, not from GC (DEFERRED M12e-5-1: throttle or slice eat's output without the redraw cost).
terminal-typing's p95 is 7 ms: the worst of 16 runs with the module active (1.9 to 6.4, load 3 to 6), rounded up.

## Tuning (and why)

- **GC.** One owner, `core/drgnx-gc.el`. Emacs' default threshold (800 kB) collected 28 times in 186 keystrokes.
  drgnx raises it to 512 MB while starting (early-init; set back after startup even if drgnx fails to start), then
  uses 64 MB (`drgnx-gc-cons-threshold`). A threshold your own init set (no longer early-init's) is kept.
  - **The idle collection** is the timer layer's key `gc-idle` (`drgnx-gc-idle-seconds`, 1 s; started again by a
    second setup, never doubled), owner `:core`, so it is covered by the timer lint like every other timer. A
    collection at the threshold takes about 45 ms and lands on whatever key allocates past it, so the idle one takes
    it in a pause in typing instead: one second without input, when at least half the threshold
    (`drgnx-gc-idle-share`) was allocated since the last collection (`drgnx-gc--consed` minus `drgnx-gc--base`, which
    `drgnx-gc--note` on `post-gc-hook` sets): an idle Emacs that allocated nothing stays still. It collects at most
    once per pause (`drgnx-gc--idle-pause`), never with input pending, and never in a batch Emacs or a daemon no
    client is connected to (`drgnx-gc--someone-waits-p`). It was 8 s and a quarter, which a typist rarely gave it. `drgnx-gc-mode` (on after `drgnx-gc-setup`) owns that hook function, so it is
    one function, removed when the mode turns off.
  - **The heap goes back to the system at idle:** a collection hands what it frees back to malloc, which keeps it,
    so after the perf lab's `ts-open` (six 1 and 2 MB tree-sitter files) Emacs stayed at ~845 MB resident with a
    small live heap (`malloc-trim` gave back ~650 MB). The idle collection's timer therefore trims the heap
    (`malloc-trim`, glibc builds) once in the first pause after any collection, its own or an earlier one
    (`drgnx-gc--trimmed` holds `gcs-done` at the last trim), never with input pending.
  - **A gap collection for producers:** `(drgnx-gc-gap)` collects, and returns t, when `drgnx-gc-gap-quiet` (0.02 s,
    nil: never) has passed without input, no input is pending and at least `drgnx-gc-gap-share` (85%) of the
    threshold was allocated since the last collection. A producer that finished a burst of work calls it instead
    of waiting for the threshold to be hit in the middle of the next keystroke.
  - **gcmh:** `drgnx-gc-mode` watches `gcmh-mode`. Turned on, gcmh does the threshold and the idle collection and
    `gc-idle` is cancelled; turned off, drgnx's threshold, `gc-cons-percentage` 0.1 and `gc-idle` are back
    (gcmh's own mode function sets its low threshold after the watcher ran, so `gcmh-mode-off-hook` restores
    them too). A `let` of `gcmh-mode` changes nothing.
  - **Batch Emacs** (workers): `drgnx-gc-batch-setup` sets 32 MB (`drgnx-gc-batch-threshold`) and
    `gc-cons-percentage` 0.2. It is the first form of a worker's batch entry; short CLI
    commands keep Emacs's defaults.
  - **Harness sessions** of the minimal configuration run at the same settings (`drgnx-ui-gc-early` and
    `drgnx-ui-gc-setup` in `harness/init/prelude.el`); a session of an external configuration brings its own.
  - **The origin of a collection:** `drgnx-gc--idle` binds `nidhogg-watchdog-gc-origin` to `idle` around its
    `garbage-collect`, `drgnx-gc-gap` to `gap`, the heap audit to `audit`; nil reads as `auto`. The GC census
    (below) records it.
- **The Outline** keeps no imenu markers: each refresh turns them into integer positions and releases them, since a
  marker in the source buffer costs every edit of that buffer until a collection frees it. Its rows are patched by key
  (an edit that moves definitions redraws none). Wall numbers: perf deferred.
- **Key resolution** at startup checked every pair of bindings for prefixes and re-parsed keys each time; it now
  caches parsed keys and compares only keys in one keymap with the same first event.
- **Harness sessions** share one native-code cache per state root, so advice trampolines (the no-prompt guard
  advises built-in functions) are compiled once, not on every session start (~150 ms each).

## GC census

The first measure of the stall watchdog (V2 engine item A): what every garbage collection costs in a real session,
before anything is changed. `core/drgnx-gc-census.el`, off by default.

- **Turning it on:** `(:gc-census t)` in `speed.eld` (the config folder, read at every start; `drgnx-gc-setup` starts
  it), or `M-x drgnx-gc-census-mode` for this session. **Help → GC Census** (`gc-census`) shows the report, with a
  Copy button.
- **The hook records only.** `drgnx-gc-census--note`, called by the GC owner's `post-gc-hook` function
  (`drgnx-gc--note`; only `core/drgnx-gc.el` touches the hook), fills one slot of a 64-slot ring that was made
  when the mode started: the pause (the change in `gc-elapsed` since the last note; Emacs adds the collection's time
  before it runs the hook), the origin, `felt`, `gcs-done`, the time, `(garbage-collect-heapsize)` and the threshold.
  It does no file I/O, no `process-attributes` and no message, and never calls `input-pending-p` (on pgtk that can
  dispatch GLib events inside the collection's span). It allocates the heap-size list and two floats, nothing else
  (`drgnx-gc-census/hook-does-no-io` measures it with `memory-use-counts`). A full ring counts the collection as
  dropped (shown in the report).
- **`felt` is coarse here:** t when the collection ran inside a command or a timer, not at idle
  (`current-idle-time` is nil). The watchdog's C GC row replaces it with "input arrived in its span, or its span ran a
  command".
- **The writer** is the idle timer `gc-census` (1 s, once per pause, owner `:core`). It writes each entry as a
  collection line, the watchdog's log format, to `$XDG_STATE_HOME/drgnx/watchdog/YYYY-MM-DD.jsonl` through
  `drgnx-file-append-line`:
  `{"v":1,"type":"gc","at":"…","pid":…,"pause_ms":118.4,"origin":"auto","felt":false,"gcs_done":4711,"heap":{"live_mb":…,"free_mb":…,"conses_mb":…,"strings_mb":…,"string_bytes_mb":…,"vectors_mb":…,"symbols_mb":…,"intervals_mb":…,"floats_mb":…,"buffers_mb":…},"rss_mb":2410,"threshold_mb":74.2}`.
  The heap is SIZE × USED per type in MiB (vector slots count with vectors; malloc's own `heap` entry is not the
  Lisp heap and is left out), `free_mb` is SIZE × FREE. `rss_mb` is read when the writer runs, not at the
  collection. `threshold_mb` is the threshold in effect: `gc-cons-threshold`, or `gc-cons-percentage` of the live heap
  when that is more. The watchdog's own lines add `span_wall_ms` and `span_nongc_ms`, which only C can know.
- **Day files older than 14 days** are deleted when the mode starts (by the date in the name).
- **One writer:** while `nidhogg-watchdog-mode` is on, the hook and the writer do nothing; the watchdog's GC row writes
  the same lines.
- **The report** (`(drgnx-gc-census-report :days 7)`, the newest day files) gives per day the count, max, total
  seconds, the buckets `<4, <8, <16, <33, <50, <100, <250, <1000, ≥1000` ms with p50/p95/p99 estimated from them
  (linear inside a bucket, never above the max), the share by origin and the felt count; over all the days the same,
  the slope of pause against live heap (least squares, ms per 100 MB) with its point count, and the live heap by type
  after the last collection. The target it is read against: p95 ≤ 50 ms over 7 days with at least 20 collections, no
  collection ≥ 250 ms in a day.

## Where startup time goes

`DRGNX_STARTUP_TRACE=/tmp/trace.eld emacs --init-directory <checkout>/init` (one Emacs per file: harness sessions
pass the variable on, so concurrent ones would overwrite each other) writes, at the first frame: how long
each `require` took, the functions most often on the stack (a CPU profile), and when init ended. In a harness
session most of the time is not drgnx's: the harness's own minimal configuration starts in about a second (the
compositor, the first frame, fonts); drgnx's own init is ~220 ms in batch and ~200 ms to a daemon's server.

## The stalls probe (the stall watchdog)

On a Nidhogg with `nidhogg-watchdog` the perf lab reads the watchdog per workload. `drgnx-perf-begin` drains it
(`nidhogg-watchdog-drain-now`) and collects its records through `nidhogg-watchdog-record-functions`; `drgnx-perf-end`
drains again and reports `(:stalls N :stalls-lab N :stalls-felt N :stall-max-ms F :gc (:count N :max F :p95 F) :typing (:ge16 F :p95 F)
:watchdog (:missed N :spans N :samples N :monitor-cpu-ms F :drain-p95-ms F :drain-max-ms F))`. The watchdog's counters are
never reset: the probe snapshots them at the start and reports the difference (a reset would zero the totals the day reads
and the deltas of the watchdog's own summary lines). The difference comes from Nidhogg's `nidhogg-watchdog--stats-delta`
(which copes with a reset in between) and the drain p95 and largest bucket are read on Nidhogg's own drain edges
(1 2 4 8 16 33 50 100 ms; a forced `drain-now` is not in them); a build without these falls back to the C bucket edges. Each stall it keeps carries its wall time, felt, signature and culprit. `:stalls` is the counter's difference, not the number of records kept: the watchdog holds only its newest 32 records and the ring is not drained during a workload, so the records give `:stalls-felt`, `:stall-max-ms` and the stacks. `:stall-top` (in the results JSON) names the five
most frequent signatures with their count, longest wall time and culprit: where a workload's stalls come from, the
lab's own waits included. The lab's own waits are not the workload's stalls: a stall whose culprit is one of
`drgnx-perf-lab-waits` (a command's wait for its present, a workload's wait for its premise or for a draw), in its `process-wait`
phase, with less than the watchdog's threshold of its wall time anywhere else, goes to `:stalls-lab` and out of
`:stalls`, `:stalls-felt` and `:stall-max-ms` (so the `(:stalls) 0` rows judge the workload, never the lab). Only a
record can say a stall was the lab's: a stall the ring dropped stays in `:stalls`. `:typing :ge16` is the percent of
commands at 16 ms or more.
Without the feature the probe reports `:watchdog nil` and no stalls row is judged. The soak also prints `(:heap :live_mb
F)`, the live Lisp heap after its last collection (from `garbage-collect-heapsize`); reported, not gated.

**The switch.** `DRGNX_PERF_WATCHDOG` is applied when a recording starts (`drgnx-perf-begin`): unset or `default` runs
the watchdog at 100 ms (the shipped configuration), `on` at 1 ms (the stress case), a number at that many ms (`16`:
what the `stalls-ge16` rows mean), `off` leaves it off. A watchdog
already in that state is not restarted. On a system the watchdog does not run on (macOS: Nidhogg builds it but refuses
to start it) the switch does nothing, and nothing is put back. The switch is `drgnx-watchdog-mode`, so `off` also stops the doctor's record
hook and idle timer. `drgnx-perf-end` puts the watchdog back as it was before the recording (mode and threshold), so a
recording leaves nothing running; the synthetic day applies the switch itself as the session starts, before
build-up, and it stays for the whole day.

**Budgets.** `(W (:stalls) 0)`, `(W (:gc :max) 250)` and `(W (:gc :p95) 50)` for every input workload. They are
reported until seeded (`drgnx-perf-watchdog-gated`), as every new row is. The GC max is skipped when the workload
collected nothing, and the GC p95 is judged only over at least 20 collections; below that the tail is the maximum. A GC pause includes Lisp finalizers and the image-cache prune, so a
long pause is not always the collector's own marking.

**A/B.** Gated: `bin/drgnx test --perf --ab-env DRGNX_PERF_WATCHDOG=default,off` (the shipped watchdog against none).
Reported stress: `--ab-env DRGNX_PERF_WATCHDOG=on,off` (1 ms; not a gate).

Tests: `test/unit/perf-watchdog-test.el`.

## The workers probe (off-the-main-thread work)

On a Nidhogg with `nidhogg-workers` the lab measures the worker threads. Without the feature every row below reports
`:workers nil` and nothing fails.

**Advice on jsonrpc's reader keeps framing off.** Nidhogg's jsonrpc adoption stands back when `jsonrpc--process-filter`
or `jsonrpc--json-read` has advice, which includes drgnx's own. So the TRAMP timer guard (`lang/eglot`) is on
`nidhogg-workers-jsonrpc--batch` and on the filter of unframed connections only, the booster is not set up while
`nidhogg-workers-framing` is on, and eglot's events log is off (`eglot-events-buffer-config`, Show LSP Log turns it
on). A measurement of framing under drgnx's config compares the framed path only if none of these is undone
(`drgnx-lang/framing-engages-under-drgnx`).

**The switch.** `DRGNX_PERF_WORKERS` is read once per session, before any workload, and handed unchanged to
`(nidhogg-workers-apply SPEC)`: `default` (also unset), `on`, `off`, `inline`, or `+SW`/`-SW` items such as
`+nidhogg-workers-treesit+nidhogg-treesit-defer` (they have no commas, so `--ab-env` takes them). A step's gate is
`--ab-env DRGNX_PERF_WORKERS=+SW1+SW2,default`. Sessions and containers pass it on. The lab applies it with its
first call into a session, so a workload's `:setup` already runs under it: a connection is framed only if
`nidhogg-workers-framing` is on when it opens, and lsp-burst's servers open in its setup
(`drgnx-perf-workers/switch-applied-before-the-setup`). Each LSP row reports `:lsp :framed`, the connections Nidhogg
frames; a framing A/B whose framed arm shows 0 compared the unframed path twice.

**The probe.** `drgnx-perf-begin` resets `nidhogg-workers-stats`, `drgnx-perf-end` reports
`:workers (:phase-ms PLIST :wait-ms F :fallbacks N :deferrals PLIST)`: busy ms by phase (`worker-wait` as its total
and as `worker-wait-REASON` per reason; the A/B explains with them, see below; `treesit-with-waits` is `treesit`
(Nidhogg counts every synchronous parse there, the workers on or off) plus `treesit-wait`, the main thread's whole
tree-sitter time; `image-with-waits` is `image` plus the `display` and `image-pixels` waits, the main thread's whole
time for images, so a decode moved into a wait for `nh-img` does not count as gone; both are explain lines next to
input, cpu and stalls, not verdicts), the main thread's waits for a
worker (`treesit-wait` + `worker-wait`), jobs that ran inline, deferred work. The stalls probe adds `:stalls-ge16` and
`:stalls-ge100` (the watchdog resolves stalls at its threshold: 100 ms by default, so `-ge16` needs
`DRGNX_PERF_WATCHDOG=16`, the threshold the gates' A/Bs run with, or `on`).

**Workload keys.** `:complete-when FORM` is true once the work the actions started is done; the lab polls it every
10 ms while the session is idle (a repeating `drgnx-timer-*` timer, not an idle timer: that runs once per idle period,
and the lab's own calls do not end one) and records `:complete-ms`. Polling starts before the keys, so a form that is
already true then (an unedited buffer is coloured) must also count the work. The work can outlast the keys (a compile flood, the reparse after a
paste), so after the actions the lab waits for the form to hold (at most 60 s, `drgnx-perf-run-complete-wait`, the
session idle meanwhile) before it reads `:complete-ms`, the digest and the check; the input rows cover the keys only.
`:digest FORM` returns a string (buffer text plus the visible faces, filter-call arguments or the message sequence) kept
as `:digest`.

**Report-only rows.** A budget row `(W PATH LIMIT :report-only STEP)` never fails, and the report lists it as
`report`, until `DRGNX_PERF_LANDED` (comma separated) names STEP; the gate that lands a step adds it. From then on the
row is judged like any other, wall-clock paths included.

**The A/B verdict.** Besides the wall samples, p95 and the compose probe, each judged workload prints a verdict for
per-command input p50, p95, p99 and max, `:cpu_ms` p50 and p90, `:busy-ms` p50 and p95 (the main thread's busy time
per command: its latency plus the timers that ran after the screen showed it, up to the next command), `:timer-ms` p95
(the ms the timers took under each command; only the `:timers t` rows: `terminal-output`, `compile-flood`, `lsp-burst`,
`lsp-typing`), stalls of 16 and of 100 ms or more, `:complete-ms` and `lsp-burst`'s `:lsp :handler_ms :max` (the statistic over the rounds is the median of
the per-round differences; same rule: not worse unless the whole 95 % interval is above max (1 ms, 10 % of the REF
median)). A path a side does not report is left out. A workload whose `:digest` differs between the sides is
`regressed (digest)`. `--ab-env` counts all of these in the exit code (3 stays "inconclusive").

**Worker phases explain, they do not decide.** A phase's ms (`:workers :phase-ms`) gets no verdict: moving work to a
worker is meant to move time between phases, and the verdict is what the user feels (input, busy, timers, stalls). The
A/B prints an explain block under each workload with every phase's REF and tree value. What the lab does check is that
the phases add up in each arm (`drgnx-perf-ab-phase-sum`, printed on every A/B as `phase-sum ok` or `MISMATCH`): the
sum of the phases (`worker-wait-REASON` entries repeat `worker-wait` and are left out) must not exceed `(:busy-ms :sum)`
by more than 1 ms, else a phase counted time the main thread was not busy. The check works on the run's totals (the sum
of the per-command values). The change across the arms is only explained, never judged: every A/B prints
`explain busy changed by X ms, the phases' sum by Y ms` (`drgnx-perf-ab-phase-delta-line`). `:busy-ms` is a stand-in
(latency plus the timers after the screen showed the command), because Nidhogg reports no per-command main-thread busy
time, so run sums of it and of the phases are not comparable and a cross-arm rule failed by construction, even in an
A/A. No run carries a watchdog busy measure today; when one does, the explain line should prefer it, and a cross-arm
check can be judged again once Nidhogg reports a real per-command busy time.

**One A/A per A/B invocation.** With `--ab-env` the first selected workload runs against itself once, before any A/B
round (`--aa`, the default; `--no-aa` skips it, for debugging): the same session on the REF side, the same rounds, the
same verdicts, read both ways (REF minus REF, and the sides swapped). It runs once because it proves the lab is quiet at
that moment, which does not depend on the workload; one A/A per workload doubled the lab time of a gate arm. A deciding
verdict (median, p95, compose probe, every metric above) of `regressed` in either direction (the build reads worse than
itself, so the lab is broken), digests that differ, or a failing per-arm phase-sum check refuses the invocation: no
workload gets an A/B round, `A/A failed` is printed under the A/A's workload with the reasons, and the exit code is 4
(it comes before 1 and 3). Else every workload gets its A/B, and the results file records the A/A once (`aa`, with the
workload it ran on). An `inconclusive` verdict does not refuse: with about 13 deciding
metrics read two ways at n around 100, a tail metric is nearly always inconclusive against itself, so it prints a line
(`A/A (typing): p95 inconclusive (forward)`) and the A/B goes on; the A/B's own verdicts, budgets and exit codes are unchanged.
A probe that counts a phase twice shows up here, as a refused run, instead of as a verdict about the change. An A/A that
is not judged (a loaded calibration, an error, a workload without per-command samples) proves nothing about the lab and
refuses the invocation like a failed one: `A/A failed: the A/A was not-judged (loaded calibration)`, exit 4. Every
calibration (of an A/A or an A/B) is taken once both sessions are quiet: the wait lets a stream left running by the
last run end first, so a session's own background work does not mark it loaded. The A/A costs one workload's lab time
per invocation.

The results file carries `run_rounds` for every workload: per round and arm, the input p95, p99 and max and the counts of
stalls of 16 and of 100 ms or more, so a tail in the pooled samples can be traced to the rounds that carry it. The
`lsp-typing` digest hashes each server's first 100 messages of the session (not of the round, the flood goes on across
rounds); the `quick-open-large` digest names files by their path under the repository, not under the session's temporary
directory.

**The calibration rows** (report-only, never failing; printed as `report cal-ROW WORKLOAD: KEY value, …` by plain
`--perf`; a key the Nidhogg build does not report prints `n/a (Task 55/57)`): `cal-costs` (`:costs` and `:decisions`
against `(nidhogg-workers--policy)` for `ts-open`, `ts-typing`, `ts-paste` and `image-open`), `cal-pressure` (`:pressure`:
starts per second, mean and max frames, from `ts-typing` and `live-view`) and `cal-pty` (`terminal-output`'s `:ahead`
p50 and max, sampled per command from `nidhogg-workers--test-io-info`). They come from the probe's `:cal` record.

**Machine shape.** `DRGNX_PERF_CPUS=2|4` runs `bin/drgnx test --container` with `--cpuset-cpus` set to one thread of
each of the first 2 or 4 physical cores, read from `lscpu -p=CPU,CORE` (`drgnx-perf-cpuset-args`): `0,1` / `0,1,2,3`
on a machine that numbers its cores first, `0,2` / `0,2,4,6` on one that puts a core's two threads side by side, so
"2 cores" never means one core's two threads. The workers' A/B runs both shapes:

```sh
DRGNX_PERF_CPUS=2 bin/drgnx test --container --perf --ab-env DRGNX_PERF_WORKERS=+SW1+SW2,default
DRGNX_PERF_CPUS=4 bin/drgnx test --container --perf --ab-env DRGNX_PERF_WORKERS=+SW1+SW2,default
```

Tests: `test/unit/perf-workers-test.el`.

### The workers' workloads

Twelve workloads (`harness/drgnx-perf-workloads.el`, the session side in `test/fixtures/workers/perf-session.el`) measure
what the Nidhogg workers take off the main thread. Each types the same 6 commands into the editor while the work runs; the
first key starts it (from a timer, as it starts for a user), so the keys and the work overlap. Each has `:complete-when`
(`:complete-ms`, polled at idle) and `:digest` (equal on and off), and a budget row `(W PATH LIMIT :report-only STEP)` in
`test/perf/budgets.eld`: the limit is the design's table (V2 §1 or drgnx's existing row), never a first run. A row fails
only after `DRGNX_PERF_LANDED` names its step.

| Workload | What it does | Budget rows (step) |
|---|---|---|
| `lsp-burst` | three jsonrpc connections to `test/fixtures/lsp-replay.el`, replaying recorded rust-analyzer, clangd and tsserver traffic; each sends completion answers of 0.5, 1 and 3 MB, three rounds. `:lsp :handler_ms :max` is the slowest handler after the server wrote its answer's last byte (the server sends that time next, `LSP_REPLAY_STAMP`); the workload puts no advice on jsonrpc, which would keep Nidhogg's framing off. `:lsp :framed` counts the framed connections. Each request carries the runner's own completion deadline as its jsonrpc timeout (60 s); a request that times out is a handled failure, reported as `:lsp :timeouts` (count) and `:lsp :timeout_ids` (`CONNECTION/ID`), never a silent hang | input p95 16, no 16 ms stall, `:lsp :handler_ms :max` 50 (ot4; the A/B judges it too) |
| `lsp-typing` | the same servers flood 300 recorded diagnostics and progress messages a second (`:lsp :framed` as above) | input p95 16, max 50 (ot4) |
| `ts-open` | 1 and 2 MB files in `c-ts-mode`, `typescript-ts-mode`, `python-ts-mode`, opened one after the other in a second window | `:ts :draw_ms` 16 (first draw), `:ts :colored_ms` 500, no 100 ms stall (ot2) |
| `ts-paste` | `C-y` of 500 KB into a 1 MB C file, then typing (a p95 needs 100 commands over the repeats; every repeat starts from the file on disk) (electric-pair, show-paren, which-function on) | input p95 16, `:complete-ms` 300 (ot2) |
| `ts-typing`, `ts-typing-unclosed` | typing balanced / unclosed code in that file; complete (and the digest read) once every typed character's command has run and the colour has settled: no parse job or deferred region for the buffer, and jit-lock's contextual refontification after the last key done | input p95 16 (ot2) |
| `compile-flood` | `compile` (comint, a pty) of a generated 200k-line log; the digest is the count and md5 of the log lines that arrived, checked against the file | input p95 16, p99 50, max 50 (ot3) |
| `image-open` | a 4K PNG screenshot, then the 20-image Markdown preview through `drgnx-markdown--insert-html`; every repeat clears the image cache first (or only the warm-up decodes), and `:preview_drawn_ms` waits until no decode is pending on Nidhogg's image worker | no 16 ms stall, `:image :screenshot_ms` 16, `:image :preview_drawn_ms` 500 (ot6) |
| `explorer-expand` | `big/` of 5,000 files expanded, listing cache cleared (the bench's operation) | `:expand_ms` 80, no 16 ms stall (ot8) |
| `explorer-git` | the status of a 25k-file repository read in the background | input p95 16, no 16 ms stall (ot5) |
| `quick-open-large` | `project-files` of a 200,000-file git repository (Quick Open's listing) | `:complete-ms` 100, no 16 ms stall (ot5) |
| `autosave-typing` | a 50 MB buffer, the keyboard loop's auto-save at the first key (`nidhogg-workers--test-keyboard-auto-save`, `read_char`'s call: a `do-auto-save` from Lisp never leaves the main thread); the digest is the auto-save file's md5; each repeat kills the buffer the one before made (they once stayed, 100 MB that the `memory` row read) | input max 50, `:complete-ms` 1000 (ot8) |

`terminal-output` and `live-view` keep their rows. Their output depends on the clock (a paced stream, an
endless `seq` loop), so a digest that is equal on and off needs a fixed-length run; that is DEFERRED, not done here.

**Fixtures.** Generators, not big files: `test/fixtures/workers/generators.el` writes the sources (1 and 2 MB per language),
the compile log, the 5,000-file folder and the 25k- and 200k-file repositories when a workload sets up. The pictures are
`make-images.sh`'s output (ImageMagick; `screenshot-4k.png`, `images/`, `preview-20.md`). The language-server traffic is
recorded once from the real servers by `capture-lsp.sh` (run it in the container: `.claude/tmp/ctr.sh --image
localhost/drgnx-dev:f45 --memory 6g -- bash test/fixtures/workers/capture-lsp.sh`): a server the image lacks (clangd,
rust-analyzer, Node and typescript-language-server) is installed for that run only; the corpora are
`corpus-NAME.eld.gz` and `manifest.eld` gives the message count and byte total a replay must reproduce (a test checks it).
`lsp-replay.el` serves a corpus (`LSP_REPLAY_CORPUS`), with `LSP_REPLAY_COMPLETION_SIZES`, `LSP_REPLAY_FLOOD` and
`LSP_REPLAY_STAMP` (a `$/replaySent` notification with each answer's id and write time after the answer).

**A report-only run** (the baseline; a Nidhogg with workers, under the lease, no A/B):

```sh
DRGNX_PERF_WATCHDOG=on DRGNX_PERF_WORKLOADS="lsp-burst lsp-typing ts-open ts-paste ts-typing ts-typing-unclosed compile-flood image-open explorer-expand explorer-git quick-open-large autosave-typing" \
  .claude/tmp/perf-exclusive.sh bin/drgnx test --container --perf
```

### The Work space's workloads

`harness/drgnx-perf-work.el` (the session side: `test/fixtures/work-space-thirty-fixture.el`). Every workload but
`work-trail` runs against **30 mock agents streaming in a real hub**: `test/fixtures/work-space/thirty.json`
(`vegvisir`'s fixture too) built into three git repositories (`org`, `drgnx`, `nidhogg`) and a worktree per agent
under a temp directory. Each agent is a `ratatoskr-mock acp` of its own profile whose one turn edits the files the
description names (120 in all), reads one, records a decision where the description has a conclusion, starts a
subagent where it has a parent, then makes a chunk, a read step and a second of quiet for fifteen minutes. Each
gets the text of its ask. `$DRGNX_RATATOSKR_BIN` is needed as for the agent workloads. **Setup, `:each` and `:check`
call the fixture's premise**, which signals when fewer than 30 sessions are busy, when the map holds fewer than 30
agents, or when the map is not shown (hidden) to the hub and on screen as the workload says: a workload that did not
get its situation fails instead of measuring something else. Mock agents only; nothing reaches a subscription.

| Workload | What it does | Measured (budget row) |
|---|---|---|
| work-nav | 300 map keys (Tab, right, left, down and up, 60 each) with an agent selected | `:input :p95` 16 ms; `:frame_kb` 2048 (`memory-report-object-size` of the client's frame); `:stalls` 0 |
| work-raster | every band tile of the map's layout rasterised at scale 2 (`image-flush` and `image-size` of a fresh image), passes repeated to 100 tiles; then, for twelve agents, the tiles of the bands that carry that agent's chain, summed | `:raster_ms :p95` 1.5; `:chain_ms :max` 6 |
| work-relayout | 320 layout commands (`f`, `o`, `1` to `6`, 40 times; only about one in six makes the hub send a frame with a layout, and the lab's p95 needs 100 samples; each command first waits up to a second for the layout before it, which is why the lab's own input p90 reads about 1 s) | `:relayout :p95` 50 ms, from the command to the frame it asked for drawn (the view has nothing pending); `:stalls` 0 |
| work-live | 30 s with the map shown and the agents streaming (checked: the map got at least 30 deltas) | `:draw_ms_s` 40 (the view's `:draw-ms` per second); `:slice_ms :max` 4 (each draw of the map's view); `:stalls` 0 |
| work-typing-shown, work-typing-hidden | the typing workload's six strings with the map shown in the editor's other window, and with it open but shown nowhere (the hub told: no deltas) | `:input :p95` 16 ms each, `:stalls` 0; the rule between them (shown at most 1 ms over hidden) is `drgnx-perf-run--relative-fails`, judged when both are in the run |
| view-patch | no hub: a hub-fed view (`drgnx-view-patch-attach`) holding 30 agents' cards (150 rows, a run of faces, an item id, two stops and an image each), then 100 patches, each replacing one row of every agent (30 rows), parsed from JSON, applied and drawn | report-only until the render offload's combined pass: `:alloc` (objects for the parse, the apply and the draw), `:draw_kb` (kB the draw made), `:slices`, `:rows`. First smoke run (2026-11-07, GUI container): alloc p50 6052 objects, draw 6.7 kB |
| work-trail | a mock session whose one turn took 10,000 read steps (checked: its newest step is 10,000 or more); the trail opened until its first rows are drawn, then 20 steps appended (each with its draw) | `:draw_ms` 100; `:append_ms :max` 1 (from the merge to the end of the view's draw of it) |

Beside the budget rows the workloads report where their time goes (results JSON, not judged): work-relayout's
`:to_frame` (command to the frame's arrival), work-live's `:long` (each draw over 4 ms as `(MS TOUCHED ROWS GC-MS)`),
work-trail's `:settled_s` (seconds from the turn to its 10,000 steps readable) and, when the hub never holds them, a
trace of the newest step with the hub's and the session's CPU seconds in the premise's error. work-trail's append
splits as `:append_merge_ms` (the merge), `:append_draw_ms` (the view's draw) and `:append_poll_ms` (to the end of
the lab's wait, which the view's draw ends by throwing out of one bounded `accept-process-output`: no timer wakes it).
The relayout's wait for a draw is the same: a hook after each draw, no 1 ms timer; work-live waits its 30 s in one wait
that wakes only for process output.

The timing rows belong on the desktop's perf island (`perf-exclusive.sh` outermost; the relative rules need the shown
and hidden workloads in one run). Allocation, CPU and rows are not budgeted yet (`drgnx-perf-run-unseeded`). The Rust
rows (`vegvisir`'s layout and core step, the shell parse, the trace rows) are their crates' tests.

## Slow frames in another configuration

Start with Show Freezes (the watchdog's report) and the stalls probe above. A new frame under drgnx takes ~66 ms (in a session) and ~190 ms from a daemon (`emacsclient -c`). The 2.1 s
frames seen with an earlier reference configuration do not reproduce in an isolated session ([scenarios.md](scenarios.md)):
they depend on live state — restored workspace layouts, many buffers, language servers. To see what a slow frame
spends in your own daemon — this changes it while it runs (advice and wrapped hook entries, undone at the end:
only what the audit added is taken out), so do it only when you choose to:

```sh
emacsclient -s SERVER -e '(progn (load "<checkout>/harness/drgnx-perf.el") (drgnx-perf-audit-begin) (profiler-start (quote cpu)) t)'
emacsclient -s SERVER -c          # open the slow frame, then close it
emacsclient -s SERVER -e '(progn (profiler-stop) (format "%S" (seq-take (drgnx-perf-audit-end) 15)))'
```

The audit lists the hook functions that ran while the frame opened (`after-make-frame-functions`,
`server-after-make-frame-hook`, window hooks …), costliest first.

## Tests

`test/unit/perf-modal-test.el` (the evil workloads, their budget rows, the 1 ms rule, `DRGNX_PERF_WORKLOADS`), `test/unit/perf-test.el` (statistics, the probes, the audit — including that it never stops a function from removing
itself — budgets, history), `test/unit/core-gc-test.el`, `test/unit/gc-census-test.el` (the census); the workloads run
with `drgnx test --perf`.

### typing-with-index: provisional budget

Budget p95 22 ms, max 50 ms, **provisional**. The ruled target is `typing`'s 16 ms. The 22 is the worst of 3 runs, rounded up
(p95 12.2, 17.2, 21.1 ms; max 19.4, 24.0, 25.2 ms), taken on 2026-10-18 at a load average of 7 to 8, where the p95 rose with
the load. `typing` alone reads 3.5 ms on a quiet machine, so the loaded index is not shown to cost anything yet.
A quiet-machine `bin/drgnx test --perf` run pins the number: set the p95 to 16 if it holds, and drop this note.

The workload's setup starts a hub of its own (`$DRGNX_RATATOSKR_BIN`, a test-hooks build, as the agent workloads do),
makes a git project of the checkout's `core/` and `wb/` in a temporary folder (the container's `/src` is not a git
project) and waits for tier 1. It runs tier 1 only: tier 2 needs an embedder, and the container has no model, so the
real-model variant on the perf island is still to be added.

### Hrafn's rows

The Rust rows are `#[ignore]` tests that print their figures and assert the budget table's constants. They are not in
`budgets.eld`: a row there without a workload in a `--perf` run fails as "not measured". Each runs alone on the
desktop's pinned island (`perf-exclusive.sh` as the outer wrapper, `DRGNX_PERF_CPUS=4`).

| Row | Where | Budget |
|---|---|---|
| tier 1 of a drgnx checkout; one saved file searchable | `drgnx-ratatoskr/tests/timing.rs` (`tier1_of_a_checkout_and_one_saved_file`) | 60 s; 1 s |
| `search/query` p95, 50,000 and 100,000 synthetic chunks, vectors on | the same file (`query_p95_at_50k_chunks`, `…_100k_…`) | 100 ms |
| built-in embedding tokens/s (GPU), VRAM at 4,096 tokens | `hrafn-embed/tests/timing.rs` (`bench_tokens_per_s`) | 20,000; 800 MB |
| CPU fallback tokens/s on 4 cores | `bench_cpu` | 680 |
| one query embedding p95 | `query_p95` and `bench_cpu` | 50 ms |
| stall probe: no copy over 16.6 ms, worst 16 ms | `stall_probe` | a stand-in for the compositor (a second process copying 64 KB every 8 ms on the same card), not a real frame |

The GPU rows run through `hrafn-gpu.sh` on the Radeon; the RTX 2060's row (0.8 times its first AC figure) runs on the
laptop on AC. The synthetic stores are made of the fixture's chunk shapes, with every word common, so a keyword list
ranks nearly every chunk: a worst case for the full-text route.

## Settings (design §16)

The settings gates are the five `settings-*` workloads of the table above (`harness/drgnx-perf-settings.el`, which
builds each fixture in the session under a temp config, state and cache directory and puts the environment back).
They are wall clock, so they are reported against their budgets and judged in a pinned run:
`DRGNX_PERF_WORKLOADS='settings-start settings-page settings-prov settings-sync settings-open' bin/drgnx test --container --perf`.
The two gates that are not timings are tests: no provenance watcher sits on a variable that typing writes more than
1,000 times (`test/unit/settings-watch-test.el`), and applying settings adds only the custom loads of the variables it
names to `features` (`drgnx-settings-apply/applying-adds-only-the-named-custom-loads`).

Installing a variable watcher costs about 160 µs: `add-variable-watcher` walks the whole obarray. Provenance installs
one for each managed variable and each variable the static index finds your Lisp setting, once per start, so a
`settings.el` with 100 entries costs 16 ms of the start, and `settings-prov` shows it.

First measurements (2026-11-05, pinned island on the desktop, Emacs 31.1 in the GUI container; wall clock, so a
second run moves by up to 1.5×): `settings-start` 18.8 ms, then 5.7 after the applied-values file stopped being
rewritten at every start, the index file stopped being stat'ed for every setting and the last good copy stopped being
parsed again (budget 2: the rest is the bounded reader's token scan, about 1.8 ms for 200 entries, the per-entry
value check, about 1.7 ms, and the pushes, about 1.7 ms); `settings-page` open 90.6 then 49 ms (budget 100, met), a
search keystroke 209 then 70 ms at most (budget 16: the search itself is at most 32 ms for the first key, which looks
at every setting, then a few ms for the keys that narrow the last result; a forced redisplay of the page was the other
40 ms: the workload's `(redisplay t)' runs the ripe timers first, and the page's view drew every listed row again,
each worked out through provenance, because each search moved the rows' signature; a search now keeps the rows, and
on the island the keystroke went from p50 23.9 / 19.8, max 66.1 / 68.5 ms to p50 12.3 / 12.3, max 26.7 / 29.4 ms, the
worst key now the first key's own search, and the open from 31 to 19 ms); `settings-prov` 114 ms against a plain load of 0.8 ms before, 54 to 78 ms against 2 to 4 ms after provenance
stopped re-judging the file at every write and counting lines from the top for every form (budget 5 %: 97 watchers
installed at 160 µs and more each are most of it, so the gate cannot be met while every managed variable is watched
before the load); `settings-sync` 510 to 860 ms for 200 packages (budget 2 s, met); `settings-open` 3.1 then 2.4 ms per
open added by the workspace and language layers (budget 1: the trust resolution of the shared file's root, about
0.9 ms, and the private file's, about 0.5 ms, run at every open).

Third round (2026-11-05): `settings-start` resets the config layer's state of `settings.el` before each run, since a
start has none, and the file is then scanned and read once for both readers (`drgnx-file--read-share`): 5.2 ms. The
shared file's usable entries and the trust filter's classification are kept per read of the file and state of trust
(`settings-open` 1.3 ms). Opening the page starts the warming in 0.1 ms (`:warm_start_ms`) and builds no search text
(a test holds that); `:open_ms` of 57 ms is the page itself.

Second round: the trust root and state are kept per folder (`settings-open` 1.5 to 1.7 ms, from 2.4), the token scan
steps over plain atoms by regexp (`test/unit/file-scan-fast-test.el` holds it to the full scan's results), a type is
converted once for all the settings that share it, and the applied-values file is read once per start
(`settings-start` 5.1 to 5.5 ms from 5.8: still two reads of `settings.el` by the config layer and the settings
reader, and about 1.9 ms of pushes). Opening the page now builds every setting's search text in idle time (the
workload drains those steps, `:warm_ms` about 30 ms, outside `:open_ms`), so the search of the first key is at most
5 ms (`:key_search_max_ms`, from 32).

Ratatoskr's reader is timed by `runtime/crates/huginn/tests/timing.rs`: 64 KiB of settings-shaped data, median of 200
reads at most 1 ms. It is `#[ignore]`, run once and alone on a pinned host, optimized:
`perf-exclusive.sh env DRGNX_PERF_CPUS=2 … cargo test --release -p huginn --test timing -- --ignored --nocapture`
(2026-10-24, a pinned host, 2 CPUs: median 0.60 ms, max 4.2 ms for 65,677 bytes).

In CI the `huginn_read` fuzz target runs in `runtime.yml`'s fuzz job, and `ci.yml`'s Nidhogg job builds huginn's `dump`
example so the ERT differential (`drgnx-huginn/differential-fresh-seed`) compares it with Emacs's reader.

## Extensions

The Extensions view's rows are the workloads of `harness/drgnx-perf-extensions.el`, in the form of the settings rows: a
library evaluated in the session builds the fixture under temporary data, config, state and cache directories, times the
real functions against a hub stub that answers from memory, and puts everything back. The four archives are local
directories of `archive-contents` at their 2026-11-06 sizes (gnu 420, nongnu 480, melpa 5,500, melpa-stable 750: 7,150
rows), written by `drgnx-perf-extensions-write-archives`; no network. To write them for a look by hand:
`emacs --batch -l harness/drgnx-perf-extensions.el -f drgnx-perf-extensions-fixture-main [DIR]`
(default `test/fixtures/extensions/full`, written on demand and not committed).

| Workload | What it measures | Budget (`:report-only ext-pass`) |
|---|---|---|
| `extensions-open` | `Open Extensions` to the painted sections (`:rows_drawn`); `:processes` counts processes started | `:open_ms` 100, `:processes` 0 |
| `extensions-search` | each key of a search over 7,150 rows, to the painted results | `:key_p50_ms` 8, `:key_max_ms` 16 |
| `extensions-scroll` | scrolling the whole catalog by name (`@sort:name`, pages of 200), per key: the command, the list's own `post-command-hook` and the redisplay; the slices that draw a next page are timed apart (`:slice_max_ms`) | `:key_max_ms` 16 |
| `extensions-details` | opening a details page, to its painted rows | `:open_ms` 50 |
| `extensions-progress` | a running job's progress-file reads while it writes a step every key (each event names the file): the smallest gap between two reads (`:read_gap_min_ms`, `:reads`), how many gaps fall under 240 ms, whether the last write was read; and typing's p95 against idle | `:reads_too_close` 0, `:last_unread` 0, `:typing_delta_ms` 1 |
| `activate-live` | a job's plan step: repointing the 40 package directories of a running session into the generation that holds the old copies (one walk of `load-path`) | `:activate_ms` 20 |
| `activate-live-new` | a job's end that added a package, as the job layer passes it (`drgnx-extensions-live-after` of `(:status done)`): the new package activated from its own descriptor, the session holding 40 others | `:activate_ms` 20 |
| `install-overhead` | an install's cost beyond the package manager's own, both children run | `:overhead_ms` 3000 (reported on ext4; macOS has APFS clones) |
| `refresh-job` | the catalog refresh from the archives | none (reported) |
| `list-packages-compare` | `list-packages` on the same fixtures, offline: first render, a `package-menu-filter-by-name` keystroke, scrolling, memory | none; `:beats_*` flags say whether the view wins each |

The view draws from timers (`:delay 0`, then slices of at most `drgnx-view-slice`), so a timed form ends with the
harness's settle: it fires the draw timers the view armed through the timer layer's own wrapper until none is left,
draws what is still marked and redisplays. The clock stops on painted rows, never on armed timers.

The rows are provisional: they report and never fail until `DRGNX_PERF_LANDED` names `ext-pass`, the combined gate pass
that judges them. Run them pinned, alone on the perf island:
`DRGNX_PERF_WORKLOADS='extensions-open extensions-search extensions-scroll extensions-details extensions-progress activate-live activate-live-new install-overhead refresh-job list-packages-compare' perf-exclusive.sh env DRGNX_PERF_CPUS=4 bin/drgnx test --container --perf`.

The hub's side is a Rust bench, `runtime/crates/drgnx-ratatoskr/benches/extensions.rs`: `catalog-load` (parse and merge
7,150 rows) at most 100 ms and 15 MB, and `extensions/search` at most 3 ms at the 95th percentile. The 15 MB is what
the hub's cache keeps (the parsed file and the index): live bytes counted by the bench's own global allocator, not
resident memory, which a warm process's arenas hide. It is `#[ignore]`d;
run it once, optimized and alone on a pinned host:
`perf-exclusive.sh env DRGNX_PERF_CPUS=4 cargo test --release -p drgnx-ratatoskr --bench extensions -- --ignored --nocapture --test-threads 1`.

Tests: `test/unit/perf-extensions-test.el` (every row has a budget and a fixture, the comparison measures both sides).

## What typing rebuilds

The status bar is built again when the position or the text changes (every keystroke), but the segments that show
nothing of the text (branch, problems, language, encoding, `misc` ...: `drgnx-statusbar--steady`) are worked out once
per window while their key (epochs, notice tick, mode, encoding, narrowing, layout) holds; `position`, `indent` and
segments of your own run on every build. A window's tab line is kept while its tabs (names, files, modified flags),
width and drawing settings hold. The Buffers list works out its shown buffers once per render, and the palette ranks its
candidates from one read of the history (a hash, a sort of the few ranked, no comparison per candidate).
