# bin/drgnx check

Build, then every test tier, in one command — in parallel wherever that is safe — with one summary at the end.

```sh
bin/drgnx check                # everything
bin/drgnx check --no-perf      # skip the perf tier (the slowest, and it needs a quiet machine)
bin/drgnx check --no-gui       # build and the unit suite only
bin/drgnx check --jobs 6 --shards 4
bin/drgnx check --leaks        # the unit shards with the leak census on (see below)
```

It runs in phases:

1. **Build.** An error stops everything.
2. **In parallel:**
   - the unit suite in `--shards` shards (4), each running its test files one after another, every file in an
     Emacs of its own (as `bin/drgnx test` does — see [harness.md](harness.md#one-emacs-per-test-file)), with one
     merged summary per shard;
   - the test/ui session;
   - the terminal tier (`bin/drgnx test --tty`: Emacs sessions in private tmux servers, every file in an Emacs of its
     own), when tmux is installed; not with `--no-gui`;
   - the live tests in shards, each in the unit suite's sandbox (`drgnx-run-ert-batch`: a temp HOME and drgnx dirs,
     a dead session bus, no display, the provider keys unset), its files in one Emacs. The sessions they start run
     detached (no systemd user manager answers there), and `test/live/jobs-systemd-test.el` skips. A live test that
     needs the user's ELPA reads it from `DRGNX_USER_ELPA` (named before HOME is swapped), never from `~`.

   GUI jobs (each starts headless Emacs sessions; the terminal tier counts as one) run no more at a time than free memory allows: 1 GiB each beyond
   1.5 GiB kept free, at least one, at most four.
3. **The unit tests tagged `:timing`, alone.** They assert how long something takes (`:tags '(:timing)` on the
   `ert-deftest`); `bin/drgnx test` still runs them with the rest. This job keeps one Emacs for every file
   (`DRGNX_TEST_ONE_PROCESS=1`): its 16 tests would cost less than an Emacs for each of the ~140 files.
4. **The scenario tier, alone.** Its scenarios hold frame budgets; a frame from the daemon in under 500 ms failed
   at 514 ms next to the parallel phase.
5. **The bench, alone.**
6. **Perf, alone.** It measures input latency. When the machine stays too busy to measure, `--perf` exits 3: the
   summary says NOT JUDGED (busy). That is not a pass.

Every job runs with SIGPIPE ignored (`trap '' PIPE`), as `bin/drgnx test` and the hub do: a hub served inside a
test Emacs that does not ignore it is killed (exit 141) by a write to a client that left. A test that needs it
skips where it is not ignored (`drgnx-hub-test--sigpipe-ignored-p`). At most `--jobs` (8) jobs run at once; a value that is not a whole number above 0 is refused (exit 2). Each job writes
its log to `~/.local/state/drgnx/check/<time>/<job>.log`. Its stdin is empty, so a stray prompt reads end-of-file
instead of waiting.

**Ending early.** A job that overruns its time limit, or every running job when the run itself is interrupted
(SIGTERM, or C-c in a terminal), gets TERM on its whole process group. It then has 25 s (`drgnx-check-grace`) to clean up before KILL: a session's stop takes 18 s at the very most.
Jobs run with `DRGNX_UI_STOP_ON_EXIT=1`, and so do the `bin/drgnx test --ui/--scenario/--bench/--perf` tiers: a
test process ended that way stops the harness sessions it started on its way out. A session whose Emacs is slow to
exit is finished by systemd. `bin/drgnx ui start` sessions are meant to outlive the command and are never stopped
like this.

The summary lists every job — ok, FAILED (exit N), TIMED OUT, NOT JUDGED or skipped — with its time and log, then
the wall time against the time the same jobs take one after another. The exit status is 0 only when all passed.

Shards are balanced by how long each test file took last time (`check/durations.eld`, kept from the shards'
results). Sessions started at the same moment never share a name:
- within one state root, a name is claimed by creating its run directory;
- across roots, a unit name another session holds (systemd: "already loaded", "has a fragment file" or "already exists") is passed over for the next one.

The `ui` job runs with `DRGNX_UI_TEST_TIMEOUT=300` (the session test's own default is 110 s): next to the parallel
shards a session boots slower, and the test's own settle waits are not cut short by the shorter limit.

Tests that run in parallel must not depend on machine-wide state another test may share:
- A check of "no process like this one is left" uses a marker only this test's process has, such as a random sleep
  length.
- A test of name choice stubs `drgnx-ui-unit-active-p`, because real units belong to the live shards running
  alongside.

## Lints on the source

Some rules are kept by unit tests that read the source (`test/unit/lint-buffers-timers-test.el`): an internal
` *…*` buffer is made with `inhibit-buffer-hooks`; the workbench starts no wall-clock timer on a follow path; and
timers go through the layer.

**Timers go through the layer** (`drgnx-lint/timers-go-through-the-layer`). For every `.el` under `core/` (except the layer, `core/drgnx-timer.el`), `modules/` and
`wb/`, `(drgnx-lint-timers--violations FILE)` lists `(LINE . FORM)` for each lambda, closure or `apply-partially` as
the function of a timer start, and each raw `run-at-time`, `run-with-timer`, `run-with-idle-timer`, `timer-set-time`
or `timer-set-idle-time` unless its delay is the literal `0` and its repeat nil or absent. The number of violations
must equal the file's entry in `drgnx-lint-timers--not-yet` (`(FILE COUNT)`, 0 when absent):

- more: "above: a new raw timer, use `drgnx-timer-*`";
- fewer: "below: lower the count in `drgnx-lint-timers--not-yet`".

The counts can only fall: a batch that migrates a site lowers its file's count in the same commit, and the list ends
empty. A branch merged later that adds raw timers adds its files' counts in its merge commit. The rule itself is in
[core.md](core.md#timers).

**Process callbacks run inside the guard** (`test/unit/lint-guard-test.el`). For every `.el` under `core/`, `wb/` and
`modules/`, read with the Lisp reader, a site is a `make-process`, `make-network-process`, `make-pipe-process` or
`make-serial-process` form with a `:filter` or `:sentinel` value, or a `set-process-filter` or `set-process-sentinel`
call, whose callback is not `(drgnx-guard-wrap …)`, `nil`, `#'ignore` or `#'internal-default-process-sentinel`
(`drgnx-proc-start` wraps its own). Each site is `(FILE CALL DEFUN)`, DEFUN the definition holding it.

- `drgnx-lint/process-callbacks-are-guarded`: a site with no row in `test/lint-guard-allowed.eld` fails, naming the
  file, the definition and the call ("wrap it: `(drgnx-guard-wrap #'FN "LABEL")`", [core.md](core.md#no-prompts-in-automatic-paths-drgnx-guardel)).
- `drgnx-lint/no-stale-guard-allowlist-entries`: a row with no site left (or more rows than sites), or a malformed
  row, fails.
- `drgnx-lint/the-guard-lint-sees-each-form`: the scanner on a scratch checkout, one string per form.

A row is `(:file F :form CALL :near DEFUN :why WHY :until TASK)`, one per site (two sites of one call in one
definition are two equal rows). TASK is `18` (notices Task 18: core and `wb`), `"td-t15"` … `"td-t23"` (the
teardown batch whose rider wraps the module) or `"runner"` (the hub-protocol sweep moves the site to
`drgnx-proc-start`). The list only shrinks: the change that wraps a site deletes its row in the same commit; a branch
merged later that adds a site adds its row in its merge commit.

## The leak census (`--leaks`)

`bin/drgnx test --leaks` (and `bin/drgnx check --leaks`, for the unit shards and the timing job) turns on a census of
what the tests leave behind: `DRGNX_TEST_LEAKS=1`, read by the runner (`harness/run-ert.el`), which every per-file Emacs
and every shard inherits. It combines with `--one-process`. It is **report only**: the exit status is the tests'.

- **Around every test** the runner reads the cheap fingerprint (`drgnx-modules-fingerprint`: timers, processes,
  buffers, `features`, the hooks drgnx touches, `global-mode-string`, the alists a mode writes into, drgnx's
  registries; [harness.md](harness.md#the-fingerprint)) before and after; every difference is a leak of that test.
- **Around every test file** it reads the full fingerprint, which adds every hook variable and every advised function
  (about 10 ms), and compares the file's start with its end. What a test was already named for is not said twice. An
  advice or a hook outside the listed ones shows only here, so its line names the file, not the test (`(file)`).
- A **timer a test left pending is cancelled** after it (and reported), so it cannot fire inside the next test; a
  layer timer ([core.md](core.md#timers)) is cancelled by its key and reported by it, so the layer forgets it too
  (`drgnx-run-ert/layer-timers-are-reset-after-a-test`). `ert-kill-all-test-buffers` runs after each file.
- Each leak's **source** is the file that defined the function, advice or timer function (`symbol-file`), or that
  provided the feature; inside the checkout it is relative to it.

The runner prints the leaks at the end and puts them in the results JSON as `:leaks`, a vector of
`(:test :file :what :source)`; the per-file summaries are merged (see [harness.md](harness.md#one-emacs-per-test-file))
and `check --leaks` merges the shards' (each leak once) and prints the same block after its summary.

```
Leaks (2)
  drgnx-browser/opens  browser-test.el  hook window-buffer-change-functions +drgnx-browser--fill  [modules/tools/drgnx-browser.el]
  (file)  layouts-test.el  advice ignore +drgnx-layouts--probe  [modules/ui/drgnx-layouts.el]
```

A line reads: the test (`(file)` for the per-file scan), the test file, what changed (`+` appeared, `-` gone; the kind
first: `hook`, `timer`, `advice`, `feature`, `buffer`, `process`, `registry`, `auto-mode`, …), and in brackets the file
that defined it. No brackets: it could not be told (a lambda). A hook function that stays on a global hook is the
cheapest to find: its brackets name the module that forgot to remove it, its test names the test that set it up.

**The allowlist** `test/leaks-allowed.eld` holds what is not a leak: Emacs's own timers and hooks, and deliberate
fixtures. Each entry is `(:what REGEXP :source REGEXP :why STRING)`: a leak whose line matches `:what` and whose source
matches `:source` (leave `:source` out for any) is not reported. Always say why. `DRGNX_TEST_LEAKS_ALLOWED` names
another file (the runner's own tests use it). An error while the census reads a fingerprint is a line of the report (`census error: …`), never an error of the run.

With the census off (the default) the runner loads nothing, advises nothing, and the summary has no `:leaks`.

## The order of the tests (`--shuffle`, `--find-polluter`)

A test that passes only after another one — it relies on a hook, a variable or a feature the other left — is a leak
that the census can name only when it also shows in the fingerprint. Two flags of `bin/drgnx test` find the rest.

```sh
bin/drgnx test --shuffle             # a random order, from a seed made for this run
bin/drgnx test --shuffle=4711        # the same order again
bin/drgnx test --find-polluter drgnx-foo/fails-sometimes [FILE…]
```

**`--shuffle[=SEED]`** (`DRGNX_TEST_SHUFFLE=SEED`) runs each file's selected tests in a random order the seed fixes.
SEED is a word of letters, digits, `.`, `_` and `-`; without one the command makes a number. The runner prints the
seed when it starts and again after a failure (`drgnx: shuffle seed 4711 (the same order again: …)`), and writes it to
the results JSON as `:seed` (a string; only a shuffled run has it). The order of one file comes from the seed and the
file's base name, so it is the same whether the file runs in its own Emacs (the default) or with the others
(`--one-process`); the files themselves keep their (name) order. The shuffle has a small generator of its own (not Emacs's
`random`, whose sequences differ by C library, OS and Emacs version; the global `random` state is not touched), so a seed
gives the same order on any machine for the same test names; a test added or renamed changes the orders. It combines with `--leaks`, `--one-process` and a name selector.
Technically the runner turns the selected tests into a `(member …)` selector — ERT keeps the order of that.

**`--find-polluter TEST [FILE…]`** answers "which test before TEST makes it fail?". TEST is a test name; FILEs are test
files or directories (none: the file under `test/unit` that defines TEST). The tests before TEST are those a one-Emacs
run of the files would run first — name order, or the shuffled order when `--shuffle=SEED` comes first. It runs, each
time in a fresh Emacs with the runner's sandbox (one process, no census), the tests before TEST and then TEST:

1. TEST alone. If it fails, it prints `TEST fails alone` and stops: nothing before it matters.
2. TEST after all the tests before it. If it passes, `TEST passes after all N tests before it`, exit 1: this order does not
   break it (try `--shuffle`, or name more FILEs, since a polluter in another file is only seen when that file is loaded).
3. Otherwise it halves the list — first half, then TEST; the half that makes TEST fail is kept, else the other — until one
   test is left, and prints `likely polluter (unconfirmed): NAME` with the files it loaded and a command that checks the pair
   (`DRGNX_TEST_SELECTOR='(member NAME TEST)' bin/drgnx test --one-process`: that loads the default `test/unit` suite, so
   it needs NAME and TEST there).

That is at most ⌈log₂ N⌉ + 2 runs for N tests before TEST (listing the tests first is one more Emacs that runs none).
It assumes one polluter: two tests that must both run before TEST are not told apart, and the second half is not
re-run to confirm, so the answer is a lead, not a finding (a flaky TEST misleads it too): check the pair as printed. Exit status: 0 when it names a polluter or TEST fails alone, 1 when
TEST passes after all of them, 2 when it cannot run (no such test or FILE — it says so and prints the usage —, an Emacs that timed out; `DRGNX_TEST_FILE_TIMEOUT`
applies to each run). `--find-polluter` takes the rest of the command line, so flags go before it.

The runner's own side: `DRGNX_TEST_ORDER_IN=FILE` (the names to run, one a line, in that order — a whole suite's
names would not fit in the environment) and `DRGNX_TEST_ORDER_OUT=FILE` (write the names in run order, run none) are
what the bisect's Emacsen are given; they are not for people (the runner reads them first and removes them from the
environment of the tests, so a runner a test starts is a normal one).
