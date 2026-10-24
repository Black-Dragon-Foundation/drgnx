# Performance

drgnx is measured, not guessed at: every interaction it cares about is timed in a real GUI session (the
[harness](harness.md)), judged against budgets, and kept in a history.

```
drgnx test --perf           every workload; fails when a gated budget (allocation, CPU, rows) breaks; wall clock is reported;
                            what got worse than the local history is printed
drgnx test --perf --audit   the workloads with every hook function timed: judged on the hook budget only
drgnx test --soak [MIN]     the input workloads in a loop for MIN minutes (30); fails when memory grows
DRGNX_STARTUP_TRACE=FILE    emacs --init-directory …/init: where startup time goes, written to FILE
DRGNX_PERF_WORKLOADS='A B'  only those workloads (space-separated names from the table below; unset: all; a typo is an error).
                            A partial run is judged against its own budgets and writes no history line
DRGNX_PERF_RESULTS=FILE     write the results as JSON: every metric (wall clock included), each workload's calibration,
                            the Emacs version and the commit
DRGNX_PERF_ONLY=REGEXP      run only the workloads whose name matches (an Emacs regexp: `\|` for alternation): judged
                            against their own budgets, the history is not written
DRGNX_UI_SIZE=WxH           the perf sessions' monitor size (default 1400x800); DRGNX_UI_SCALE=S their scale (a session
                            that cannot apply it fails to start: exit 1, nothing measured)
DRGNX_MODAL_ELPA=DIR        a package directory with evil (see below): adds the three evil workloads
```

## What is measured

| Workload | What it does | Measured |
|---|---|---|
| typing | 186 characters into the middle of a ~12k-line Emacs Lisp file | input latency (p50/p95/max), GC count, time and each pause |
| scrolling | 30 pages down and up in the same file | input latency |
| tabs | 20 next-tab switches among 20 open files | input latency |
| explorer | focus the Explorer, 10 rows down (each one moves), back | input latency |
| agent-typing | typing while an agent (the mock) streams a reply into the Agents tab (checked: still streaming at the end) | input latency |
| agent-stream | the typing workload's six strings while the editor's other window shows a transcript whose running answer starts 400 kB long (not done) and the mock streams 100-character chunks onto it, 50 a second (`stream 500`; checked: still streaming at the end): a chunk costs the chunk, and only the new text is drawn | input latency |
| cockpit-cards | typing while the Work cockpit is filtered to a job (Show Job in Work: the graph, and What needs you with four cards, three tasks and their agents; twenty decisions) and three mock agents stream, the panes following their changes (checked: still streaming at the end); until M12f `job-window`, the job's own frame | input latency |
| code-scrolling | `<next>`×30 then `<prior>`×30 through the 12k-line fixture with sticky scroll and indent guides (when installed) on — smooth scrolling is on but pixel scrolling is a wheel's, not `<next>`'s | input latency |
| diff-scrolling | `<next>`×30 then `<prior>`×30 through a 10k-line diff in the split layout | input latency |
| typing-with-ghost | the typing workload with ghost text on: a mock model answers every pause at once, the pause shortened to 10 ms so each key asks and the next cancels (checked: it asked) | input latency |
| replace-typing | 22 characters into the fixture while the Search view lists 10k matches in 100 files: the first key starts the search (checked: at least 5 keys typed while it streamed, all 10k listed) | input latency, and `:slice_ms`: the wall time of each view draw while the matches stream (budget: max 16 ms) |
| replace-retype | the same 10k matches listed and drawn, then the string `pi` typed 5 times into the Replace field: after the pause each match row is patched with its new preview, in slices, the visible rows first (checked: no full draw, the rows equal a fresh render of the view's keys) | input latency, and `:slice_ms`: the wall time of each view draw (`drgnx-view--draw-buffer`, timed by a harness-side advice; budget: max 6 ms) |
| live-view | the typing workload's 186 characters while the Live view, beside the file, shows a mock browser's JPEG frames as wide as the view asked for (as Chrome sends them), 30 a second, each sent once the last was acknowledged (the mock runs in the same Emacs, so its message and websocket frame are made once; without ImageMagick the frames are a few bytes no decoder takes, so drawing costs less) (checked: frames were drawn) | input latency |
| agent-settings-open | the Claude Code settings page opened and drawn (`redisplay`) against a fixture home: a 5 MB `.claude.json` (300 projects with history), 50 MCP servers and 200 skills; three runs | milliseconds until drawn (budget 150) and the processes started (budget 0: opening the page starts nothing) |
| remote-typing | the typing workload's 186 characters in a local file while the Explorer lists a mock-method root (test/fixtures/tramp-mock.el: a real TRAMP connection to a local `sh`) and its connection is dead, the segment showing it lost (checked: nothing was sent to the remote, the connection stayed dead) | input latency |
| typing-with-index | the typing workload's 186 characters with the search module on and the drgnx repo's semantic index loaded: the repo indexed into the session's own state dir by a stub embedder (384 numbers per chunk; no provider, no network), read into memory by one query before the keys (checked: the query cache still holds it); the index file is deleted after | input latency |
| typing-evil | the typing workload with Vim keys: `i`, the same six strings, `<escape>` (checked: typed, back in normal state) | input latency |
| motions-evil | a 5000-line copy of the fixture, normal state, from the middle: `j`×20, `w`×20, `}`×10, `C-d`×5, `C-u`×5 (checked: point moved) | input latency |
| explorer-evil | the explorer workload with Vim keys: `SPC E`, `j`×10, `<escape>` | input latency |
| window-switch | `C-x o` ×50 across three editor groups showing one file, with the left dock, the panel and the right dock shown (checked: the selected window changed 50 times) | input latency |
| terminal-typing | 6 × 20 characters (`echo hello world 123`) typed into an eat terminal in the panel running `cat` (no shell, so no shell configuration; the tty echoes every key and eat draws it) | input latency |
| terminal-output | the same 120 characters typed into the fixture while an eat terminal in the panel streams `seq 1 2000` in a loop (checked: the terminal's process is alive, its window is shown and its text changed while typing) | input latency |
| frames | 5 new frames until drawn | frame time |
| redisplay | 30 forced redisplays of the fixture | redisplay time |
| startup | a drgnx daemon (isolated: its own HOME and drgnx dirs, the harness's environment allowlist) until its server answers (a daemon that never answers fails), 4 starts, the first dropped | server-ready time, modules' time |
| memory | after the workloads and a GC | RSS |

**Input latency** is a command's start until the screen shows it: a 0 s timer set after the command redisplays
before it reads the clock (timers can run before the command loop's own redisplay, which would leave fontification
and mode-line work out). Keys arrive one at a time (the harness), so typed-ahead input — where Emacs skips
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
(`drgnx-perf-row-counters`: the Explorer's and the Buffers panel's renders, the cockpit's draws), `:gc_count`, `:gc_ms`
and `:gc_pause`. A perf session runs at drgnx's GC settings, as a user's does (HARNESS-GC-1): the run stops with an error
when its `gc-cons-threshold` is not `drgnx-gc-cons-threshold`.

Every workload runs three times (each with its own setup, its typing fixture reused, everything it opened closed
after it) and the median of each number is kept, so one noisy run never decides.

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
DRGNX_MODAL_ELPA=… DRGNX_PERF_ONLY='^\(typing\|typing-evil\)$' bin/drgnx test --perf
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
| `(:cpu_ms :p50)` (typing, typing-with-ghost, remote-typing) | a normal key: about 30 ms (the p90 sits on the 1-in-10 spike, PERF-KEYSPIKE-1) | the measured p50 with the same headroom |
| `(:cpu_ms :p90)` | CPU ms per command, times `DRGNX_PERF_CPU_FACTOR` (default 1; 2 on hosted runners) | the container's p90 x 2 |
| `(:rows)` | rows drawn during the run, exact | measured |
| `(:processes)`, `(:rss_kb)` | as before | the design |

**Reported** (every other path: `:input`, `:redisplay`, `:frame`, `:server_ms`, `:modules_ms`, `:draw_ms`,
`:slice_ms`, the GC numbers): wall clock. The run prints `report ...` lines with the value and the budget and does not
judge them; the paired A/B run at n >= 100 does. The numbers the design fixed - keystroke and scroll p95 < 16 ms, max
50 ms, a GC pause p95 < 50 ms, a new frame p95 < 500 ms, a daemon's server ready < 1 s, modules < 1.8 s, redisplay p95
16 ms - stay in the file as the targets those reports are read against; a p95 of fewer than 100 samples is shown as `-`.

**Seeding.** `:alloc` and `:rows` come from the Emacs 31.1 container (the GUI image; `bin/drgnx test --container`
has no `--perf` yet, so the tier runs by hand: `podman run --memory 4g --memory-swap 4g --security-opt
seccomp=unconfined --security-opt label=disable -v CHECKOUT:/src:ro -v OUT:/out -e DRGNX_PERF_RESULTS=/out/r.json -w
/src drgnx-test-gui:f45 bin/drgnx test --perf`, through the heavy slot), twice: allocation and rows must agree
between the runs. The checkout is not built there, so the figures are those of code loaded from source; compiled
code allocates less, so a built checkout stays under them. A workload that could not run in the container has no
gated rows yet and is named, with the reason, in `drgnx-perf-run-unseeded` (a test checks both ways).
In a container the lab names the workloads that error there (`drgnx-perf-run-container-skipped`: the two mock-agent ones, the Live view and the terminal ones, the last three for want of the websocket and eat packages in the image) and leaves them out, so the CI perf job does not fail on them; on a host they run.

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
laptop's number; the other allocation rows, whose commands do not wait on a stream, agree to a few percent between
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
`(:compose :draw-ms :p95)`; any of them `regressed` is exit 1, any `inconclusive` is exit 3. It also judges the judged
side's `:compose` budget rows (the median of the value over its rounds) at n >= 100, n being `(:compose :count)` summed
over its rounds.

**Fresh builds and the eln cache (PERF-ELN-1).** A tree that was just built has no native-compiled files yet: its
session compiles them in the background while it runs, and the first runs cost several times more. Both sessions
therefore wait until their native compilation has drained, and both run a discarded warm-up before the samples; the
report prints each side's warm-up p50 next to the measured one.

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

## In CI

The `perf` job of `gui.yml` runs `bin/drgnx test --container --perf` on every push to `main` with
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
  - **The idle collection** is the timer layer's key `gc-idle` (`drgnx-gc-idle-seconds`, 8 s; started again by a
    second setup, never doubled), owner `:core`, so it is covered by the timer lint like every other timer. It
    collects only when more than a quarter of the threshold was allocated since the last collection
    (`drgnx-gc--consed` minus `drgnx-gc--base`, which `drgnx-gc--note` on `post-gc-hook` sets): an idle Emacs that
    allocated nothing stays still. `drgnx-gc-mode` (on after `drgnx-gc-setup`) owns that hook function, so it is
    one function, removed when the mode turns off.
  - **A gap collection for producers:** `(drgnx-gc-gap)` collects, and returns t, when `drgnx-gc-gap-quiet` (0.02 s,
    nil: never) has passed without input, no input is pending and at least `drgnx-gc-gap-share` (85%) of the
    threshold was allocated since the last collection. A producer that finished a burst of work calls it instead
    of waiting for the threshold to be hit in the middle of the next keystroke.
  - **gcmh:** `drgnx-gc-mode` watches `gcmh-mode`. Turned on, gcmh does the threshold and the idle collection and
    `gc-idle` is cancelled; turned off, drgnx's threshold, `gc-cons-percentage` 0.1 and `gc-idle` are back
    (gcmh's own mode function sets its low threshold after the watcher ran, so `gcmh-mode-off-hook` restores
    them too). A `let` of `gcmh-mode` changes nothing.
  - **Batch Emacs** (the hub and workers): `drgnx-gc-batch-setup` sets 32 MB (`drgnx-gc-batch-threshold`) and
    `gc-cons-percentage` 0.2. It is the first form of `drgnx-hub-main`, `drgnx-search-index-cli`,
    `drgnx-search-mcp-main` and `drgnx-coord-mcp-main`; short CLI commands keep Emacs's defaults.
  - **Harness sessions** of the minimal configuration run at the same settings (`drgnx-ui-gc-early` and
    `drgnx-ui-gc-setup` in `harness/init/prelude.el`); a session of an external configuration brings its own.
- **The Outline** keeps no imenu markers: each refresh turns them into integer positions and releases them, since a
  marker in the source buffer costs every edit of that buffer until a collection frees it. Its rows are patched by key
  (an edit that moves definitions redraws none). Wall numbers: perf deferred.
- **Key resolution** at startup checked every pair of bindings for prefixes and re-parsed keys each time; it now
  caches parsed keys and compares only keys in one keymap with the same first event.
- **Harness sessions** share one native-code cache per state root, so advice trampolines (the no-prompt guard
  advises built-in functions) are compiled once, not on every session start (~150 ms each).

## Where startup time goes

`DRGNX_STARTUP_TRACE=/tmp/trace.eld emacs --init-directory <checkout>/init` (one Emacs per file: harness sessions
pass the variable on, so concurrent ones would overwrite each other) writes, at the first frame: how long
each `require` took, the functions most often on the stack (a CPU profile), and when init ended. In a harness
session most of the time is not drgnx's: the harness's own minimal configuration starts in about a second (the
compositor, the first frame, fonts); drgnx's own init is ~220 ms in batch and ~200 ms to a daemon's server.

## Slow frames in another configuration

A new frame under drgnx takes ~66 ms (in a session) and ~190 ms from a daemon (`emacsclient -c`). The 2.1 s
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

`test/unit/perf-modal-test.el` (the evil workloads, their budget rows, the 1 ms rule, `DRGNX_PERF_ONLY`), `test/unit/perf-test.el` (statistics, the probes, the audit — including that it never stops a function from removing
itself — budgets, history), `test/unit/core-gc-test.el`; the workloads run with `drgnx test --perf`.

### typing-with-index: provisional budget

Budget p95 22 ms, max 50 ms, **provisional**. The ruled target is `typing`'s 16 ms. The 22 is the worst of 3 runs, rounded up
(p95 12.2, 17.2, 21.1 ms; max 19.4, 24.0, 25.2 ms), taken on 2026-10-18 at a load average of 7 to 8, where the p95 rose with
the load. `typing` alone reads 3.5 ms on a quiet machine, so the loaded index is not shown to cost anything yet.
A quiet-machine `bin/drgnx test --perf` run pins the number: set the p95 to 16 if it holds, and drop this note.
