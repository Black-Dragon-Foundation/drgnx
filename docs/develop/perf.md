# Performance

drgnx is measured, not guessed at: every interaction it cares about is timed in a real GUI session (the
[harness](harness.md)), judged against budgets, and kept in a history.

```
drgnx test --perf           every workload; fails when a budget breaks; WORSE lines for what got worse
drgnx test --perf --audit   the workloads with every hook function timed: judged on the hook budget only
drgnx test --soak [MIN]     the input workloads in a loop for MIN minutes (30); fails when memory grows
DRGNX_STARTUP_TRACE=FILE    emacs --init-directory …/init: where startup time goes, written to FILE
DRGNX_PERF_MAX_LOAD=N       the load average above which --perf does not judge (default: CPUs / 4, at least 3)
DRGNX_PERF_WAIT=S           how long --perf waits for a quiet machine before giving up (180 s)
```

## What is measured

| Workload | What it does | Measured |
|---|---|---|
| typing | 186 characters into the middle of a ~12k-line Emacs Lisp file | input latency (p50/p95/max), GC count, time and each pause |
| scrolling | 30 pages down and up in the same file | input latency |
| tabs | 20 next-tab switches among 20 open files | input latency |
| explorer | focus the Explorer, 10 rows down (each one moves), back | input latency |
| agent-typing | typing while an agent (the mock) streams a reply into the Agents tab (checked: still streaming at the end) | input latency |
| cockpit-cards | typing while the Work cockpit is filtered to a job (Show Job in Work: the graph, and What needs you with four cards, three tasks and their agents; twenty decisions) and three mock agents stream, the panes following their changes (checked: still streaming at the end); until M12f `job-window`, the job's own frame | input latency |
| code-scrolling | `<next>`×30 then `<prior>`×30 through the 12k-line fixture with sticky scroll and indent guides (when installed) on — smooth scrolling is on but pixel scrolling is a wheel's, not `<next>`'s | input latency |
| diff-scrolling | `<next>`×30 then `<prior>`×30 through a 10k-line diff in the split layout | input latency |
| typing-with-ghost | the typing workload with ghost text on: a mock model answers every pause at once, the pause shortened to 10 ms so each key asks and the next cancels (checked: it asked) | input latency |
| replace-typing | 22 characters into the fixture while the Search view lists 10k matches in 100 files: the first key starts the search (checked: at least 5 keys typed while it streamed, all 10k listed) | input latency |
| live-view | the typing workload's 186 characters while the Live view, beside the file, shows a mock browser's JPEG frames as wide as the view asked for (as Chrome sends them), 30 a second, each sent once the last was acknowledged (the mock runs in the same Emacs, so its message and websocket frame are made once; without ImageMagick the frames are a few bytes no decoder takes, so drawing costs less) (checked: frames were drawn) | input latency |
| agent-settings-open | the Claude Code settings page opened and drawn (`redisplay`) against a fixture home: a 5 MB `.claude.json` (300 projects with history), 50 MCP servers and 200 skills; three runs | milliseconds until drawn (budget 150) and the processes started (budget 0: opening the page starts nothing) |
| remote-typing | the typing workload's 186 characters in a local file while the Explorer lists a mock-method root (test/fixtures/tramp-mock.el: a real TRAMP connection to a local `sh`) and its connection is dead, the segment showing it lost (checked: nothing was sent to the remote, the connection stayed dead) | input latency |
| typing-with-index | the typing workload's 186 characters with the search module on and the drgnx repo's semantic index loaded: the repo indexed into the session's own state dir by a stub embedder (384 numbers per chunk; no provider, no network), read into memory by one query before the keys (checked: the query cache still holds it); the index file is deleted after | input latency |
| frames | 5 new frames until drawn | frame time |
| redisplay | 30 forced redisplays of the fixture | redisplay time |
| startup | a drgnx daemon (isolated: its own HOME and drgnx dirs, the harness's environment allowlist) until its server answers (a daemon that never answers fails), 4 starts, the first dropped | server-ready time, modules' time |
| memory | after the workloads and a GC | RSS |

**Input latency** is a command's start until the screen shows it: a 0 s timer set after the command redisplays
before it reads the clock (timers can run before the command loop's own redisplay, which would leave fontification
and mode-line work out). Keys arrive one at a time (the harness), so typed-ahead input — where Emacs skips
redisplay — is not covered; the harness's own recorder runs inside the measured span (small).

Every workload runs three times (each with its own setup, its typing fixture reused, everything it opened closed
after it) and the median of each number is kept, so one noisy run never decides.

## Budgets

`test/perf/budgets.eld`. From the design: keystroke and scroll p95 < 16 ms, a GC pause p95 < 50 ms, any hook
function p95 < 2 ms (judged in the `--audit` pass), a new frame p95 < 500 ms, a daemon's server ready < 1 s,
modules < 1.8 s, RSS < 400 MB (and after the 30-minute soak). Also: input max 50 ms, redisplay p95 16 ms, GC while
typing 100 ms.

The history (`perf-history.jsonl` in the harness state root) gets one line per run in which every workload ran,
with its commit. A p95 more than 15% **and** 5 ms worse than the median of the last five runs **fails** the run
(the 5 ms keeps noise in tiny numbers from failing it). The new-frame path from a daemon (`emacsclient -c`) is
judged by the scenario `frame-from-daemon-fast` ([scenarios.md](scenarios.md)).

## A quiet machine

Timings only mean something when nothing else takes the CPU: next to other test runs, scrolling p95 went from
11.6 to 17.6 ms on the same commit, and every other number rose with it (with ten busy loops: 24.5 ms). So
`--perf` reads the 1-minute load average before the run and after every workload:

- before the run, it waits (up to `DRGNX_PERF_WAIT`) for the load to fall to `DRGNX_PERF_MAX_LOAD`; if it never
  does, nothing is measured;
- if the load passed the limit during the run, the numbers are printed but **not judged** and not written to the
  history;
- both end with exit code **3** (0: every budget holds, 1: a failure), so a busy machine never reads as a pass or
  a regression. A judged run records its highest load in its history line (`load`).

Run `--perf` on its own: no other test tiers, agents or builds at the same time.

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

## Tuning (and why)

- **GC.** Emacs' default threshold (800 kB) collected 28 times in 186 keystrokes. drgnx raises it to 512 MB while
  starting (early-init; set back after startup even if drgnx fails to start), then uses 64 MB (`drgnx-gc-cons-threshold`) and collects after 8 s idle
  (`drgnx-gc-idle-seconds`), where nobody waits. The price is memory: +70 MB, within budget. A threshold your own
  init set (no longer early-init's) is kept, and with `gcmh-mode` on drgnx sets neither (gcmh does both).
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

`test/unit/perf-test.el` (statistics, the probes, the audit — including that it never stops a function from removing
itself — budgets, history), `test/unit/core-gc-test.el`; the workloads run with `drgnx test --perf`.

### typing-with-index: provisional budget

Budget p95 22 ms, max 50 ms, **provisional**. The ruled target is `typing`'s 16 ms. The 22 is the worst of 3 runs, rounded up
(p95 12.2, 17.2, 21.1 ms; max 19.4, 24.0, 25.2 ms), taken on 2026-10-18 at a load average of 7 to 8, where the p95 rose with
the load. `typing` alone reads 3.5 ms on a quiet machine, so the loaded index is not shown to cost anything yet.
A quiet-machine `bin/drgnx test --perf` run pins the number: set the p95 to 16 if it holds, and drop this note.
