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

## The watchdog

When drgnx runs on a Nidhogg built with the stall watchdog, it turns the watchdog on at every start; there is
nothing to install and nothing to switch on. The watchdog times every busy span of Emacs and, when one lasts 100 ms or
more, notes what it was doing: the command, the Lisp function and file at the bottom of the stack and the package
that owns them. It writes one line per stall into the same `watchdog/` folder of drgnx's state folder as the census
(`YYYY-MM-DD.jsonl`, files older than 14 days are deleted), while the census stops writing. The typing commands
(`self-insert-command`, the delete commands, `newline`, and Evil's insert-state ones when Evil is loaded) are marked, so a
stall during typing is told apart from one while you were idle. A file's package is named by drgnx's own owner map
(your packages, drgnx's modules, Emacs itself).

It runs only in an interactive Emacs, never in a batch command. To turn it off, set `drgnx-speed-watchdog` to `nil`
([Settings](settings.md)); the change applies at once. In an Emacs without the watchdog the setting does nothing, and
`drgnx doctor` says so.

## The doctor's speed checks

`drgnx doctor` has two checks in the group Speed. Each says whether the day **meets** or **missed** its goal, beside
how serious it is.

- **freezes** judges today's stalls by the time Emacs was busy not counting garbage collection, against 100 ms. It is
  `ok` when there was none (and says how many of your typing commands took 16 ms or more). It is `info` when there were
  some but all under 250 ms and none you felt, with the counts and the three packages with most stalls. It is `warn`
  for a stall you felt of a second or more, a package with ten or more stalls, or a hang the watchdog had to kill, and
  the fix line names the package, the drgnx module that enables it, how often it stalled, how long in all and how many
  you felt: open **Help → Show Freezes**. In an Emacs without the watchdog it is `info` and says to update Nidhogg
  (`drgnx update`).
- **gc** judges the garbage collection row (a pause p95 of 50 ms or less over the last week and no collection of 250 ms
  or more) and the live heap against its budget. `ok` when met; `info` with the numbers when missed without a long
  collection; `warn` for a collection of 250 ms or more or a heap over its budget, with the fix **Help → Heap Audit**
  and the largest owner of the last audit.

`drgnx doctor` runs in an Emacs of its own, so it judges what your running drgnx wrote: the day files, and the live
heap recorded with the newest collection. The watchdog counts as running when the setting is on and a day file was
written in the last 15 minutes; with the setting on and nothing recent, `freezes` is `info` and says there is no recent
watchdog record (is drgnx running?).

The watchdog also posts a notice (source *Freezes*, a warning, not echoed) for a stall you felt of a second or more
or a killed hang, at most once per kind of stall per day, and one for the GC at most once a day. The GC look runs at idle every half hour and reads only the GC row (the heap
audit's snapshot only to word a warning), so the watchdog does not cause the stalls it reports. Each opens Show
Freezes (or the Heap Audit).

## Show Freezes

**Help → Show Freezes** (or the palette) lists what the watchdog found, worst first, over the days it keeps. At the top
is the **GC row**: how many collections, how many you felt, the longest and the total, whether the week meets its
target, and, once you have run a Heap Audit, its largest owner. Below it, one row per package: how many stalls, how many
you **felt** (the felt column: they came while you typed or waited on Emacs), the time in all and the longest, each kind of
stall (its signature) and the call tree, the busiest branches first.

Each package row has buttons: **Source** (the package's library, or its folder), **Homepage** (when the package
names one) and **Module** (the drgnx module that enables it; the modules list lets you turn it off). The header has
**Copy report**, which puts the names, durations, call stacks and the Nidhogg version on the clipboard, with no file
path, ready to paste into a bug report, and **Sample the next freeze in depth**, which makes the watchdog keep a
longer stack for the next stall; a notice tells you when that record is in. The GC row has **Run a heap audit** (it
asks first, see [Heap Audit](#heap-audit)) and **Show collections** (the GC census report). `g` draws the page again.
