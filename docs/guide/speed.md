# Speed: freezes, GC and the heap

Emacs does its work on one thread: while it runs Lisp, collects garbage or waits on a program, it does not answer
your keys. This page is about measuring those moments on your own machine and finding what causes them. It grows with
the stall watchdog; how the numbers are taken is in [Performance](../develop/perf.md).

Two things are counted apart:

- **Freezes**: any moment Emacs is busy for 100 ms or more, its garbage collection time taken out.
- **Garbage collection (GC)**: every collection, in its own row with its own target (a pause p95 of at most 50 ms, and
  none of 250 ms or more in a day). A collection stops everything; how long it takes grows with the **live Lisp heap**
  (what Emacs's Lisp still holds), not with the size of the process you see in a task manager. A smaller heap is how
  pauses come down, which is what the Heap Audit is for.

## GC census

The census writes one line per collection: how long it paused, why it ran (`auto`, drgnx's `idle` collection, a
`gap` a producer chose, the Heap Audit's own `audit`), whether it came while you were working or while Emacs was idle,
the live heap by type, and the process's size. It is off by default; `(:gc-census t)` in `speed.eld` (your config
folder, [Config files](../reference/config.md)) turns it on at every start, `M-x drgnx-gc-census-mode` for this
session. It only notes numbers during a collection and writes them when Emacs is idle, into one
file per day in `watchdog/` in drgnx's state folder (`~/.local/state/drgnx/watchdog/YYYY-MM-DD.jsonl`; files older
than 14 days are deleted). **Help → GC Census** sums up the days: collections per day, the longest, p50/p95/p99, the
share by origin, and how much each 100 MB of live heap adds to a pause on this machine. Once the stall watchdog runs,
its GC row takes over and the census stops writing.

## Heap Audit

**Help → Heap Audit** says what keeps the live Lisp heap large and who owns it.

It walks the whole heap and collects garbage once, so **Emacs does not respond while it runs**: seconds on a large
heap. It says so first, with the time the last audit took, and asks before it starts; then it asks whether to also
record allocation for two minutes of your normal use (see Allocation below). It never runs on its own, and nothing
else in drgnx starts it.

The view shows:

- **The Lisp heap**: live and free, by type (conses, strings, vectors, symbols …). This is what a collection walks.
- **Not the Lisp heap**: the process's resident size (RSS), buffer text and the image cache. They make the process
  large but do not make a collection longer, so they are shown apart: capping them would not shorten a pause.
- **By owner**: the heap each owner keeps — `drgnx`, `emacs` (Emacs's own libraries and its C core) or a package — and,
  for a package a drgnx module turns on, that module. Data two owners share is counted once, by the first in the order
  drgnx, Emacs, packages; so the totals add up instead of over-counting, as Emacs's own `memory-report` does.
- **Budgets**: each owner against its cap, `over`, `near` (90 % or more) or `under`, with the setting that fixes it.
  No caps are set yet: they come from the first audits' numbers.
- **Largest retainers**: the global variables, buffers (their text properties, overlays and local variables),
  processes, timers and symbol plists that keep the most, each with its owner. A buffer's undo list is its own row
  (kind `undo`). Well-known sinks are named: the kill ring, minibuffer histories, recent files, `*Messages*`, language
  server event logs and agent transcripts.
- **Allocation** (when recorded): which functions allocated the most while you worked. Allocation sets how *often*
  a collection runs, not how long it takes, so it is kept apart from what the heap keeps.

How an owner is found: a variable belongs to whoever defined it (the file of its `defvar`); a file in a package's
directory is that package's, a file under Emacs's `lisp/` directory is `emacs`, a file in drgnx is `drgnx` (the module
whose file it is). A buffer belongs to its major mode's package, or, for a mode of Emacs's own, to the package of its
process; a buffer-local variable to the variable's owner. What stays unattributed is `emacs` (Emacs's C variables) or
`unknown`. Closures are sized one level deep (a timer's or a hook's function and what it captured); a structure nobody
can size is counted as 0, and the view says how many there were.

Each audit also writes a snapshot, `heap-YYYY-MM-DD.json`, next to the census files (one per day, the last audit of
the day). It holds sizes and names only — variable, buffer and process names — never what a variable or a buffer
contains, and only you can read it (mode 0600). Audits on different days can be compared from these files.
