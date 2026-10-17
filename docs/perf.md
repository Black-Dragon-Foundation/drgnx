# Performance

drgnx is measured, not guessed at: every interaction it cares about is timed in a real GUI session (the
[harness](harness.md)), judged against budgets, and kept in a history.

```
drgnx test --perf           every workload; fails when a budget breaks; WORSE lines for what got worse
drgnx test --perf --audit   the same, with every hook function timed (printed, not judged: it adds its own cost)
drgnx test --soak [MIN]     the input workloads in a loop for MIN minutes (30); fails when memory grows
DRGNX_STARTUP_TRACE=FILE    emacs --init-directory …/init: where startup time goes, written to FILE
```

## What is measured

| Workload | What it does | Measured |
|---|---|---|
| typing | 186 characters into the middle of a 30k-line Emacs Lisp file | input latency (p50/p95/max), GC count and time |
| scrolling | 30 pages down and up in the same file | input latency |
| tabs | 20 next-tab switches among 20 open files | input latency |
| explorer | focus the Explorer, 30 rows down, back | input latency |
| agent-typing | typing while an agent (the mock) streams a reply into the Agents tab | input latency |
| frames | 5 new frames until drawn | frame time |
| redisplay | 30 forced redisplays | redisplay time |
| startup | a drgnx daemon (in temp dirs) until its server answers, 4 starts, the first dropped | server-ready time, modules' time |
| memory | after the workloads and a GC | RSS |

**Input latency** is a command's start to the next idle point, which comes after the redisplay that follows the
command — what you feel between a key and the screen. Input workloads run three times; the median of their p95
and max is kept, so one noisy run never decides.

## Budgets

`test/perf/budgets.eld`. From the design: a new frame p95 < 500 ms, a daemon's server ready < 1 s, modules < 1.8 s,
RSS < 400 MB. Input (set from the first measurements): p95 within one 60 Hz frame (16 ms), max 50 ms; redisplay
p95 16 ms; GC while typing 100 ms.

The history (`perf-history.jsonl` in the harness state root) gets one line per green-or-red run with its commit;
a metric more than 25% **and** 5 ms worse than the median of the last five runs is reported as WORSE (not failed).

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

- **GC.** Emacs' default threshold (800 kB) collected 28 times in 186 keystrokes. drgnx defers collection while
  starting (early-init), then uses 64 MB (`drgnx-gc-cons-threshold`) and collects after 8 s idle
  (`drgnx-gc-idle-seconds`), where nobody waits. The price is memory: +70 MB, within budget.
- **Key resolution** at startup checked every pair of bindings for prefixes and re-parsed keys each time; it now
  caches parsed keys and compares only keys in one keymap with the same first event.
- **Harness sessions** share one native-code cache per state root, so advice trampolines (the no-prompt guard
  advises built-in functions) are compiled once, not on every session start (~150 ms each).

## Where startup time goes

`DRGNX_STARTUP_TRACE=/tmp/trace.eld emacs --init-directory <checkout>/init` writes, at the first frame: how long
each `require` took, the functions most often on the stack (a CPU profile), and when init ended. In a harness
session most of the time is not drgnx's: the harness's own minimal configuration starts in about a second (the
compositor, the first frame, fonts); drgnx's own init is ~220 ms in batch and ~200 ms to a daemon's server.

## Slow frames in another configuration

A new frame under drgnx takes ~66 ms (in a session) and ~190 ms from a daemon (`emacsclient -c`). The 2.1 s
frames seen with the gryphn configuration do not reproduce in an isolated session ([scenarios.md](scenarios.md)):
they depend on live state — restored workspace layouts, many buffers, language servers. To see what a slow frame
spends in your own daemon (it only times and profiles, and undoes itself):

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
