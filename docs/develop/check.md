# bin/drgnx check

Build, then every test tier, in one command — in parallel wherever that is safe — with one summary at the end.

```sh
bin/drgnx check                # everything
bin/drgnx check --no-perf      # skip the perf tier (the slowest, and it needs a quiet machine)
bin/drgnx check --no-gui       # build and the unit suite only
bin/drgnx check --jobs 6 --shards 4
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
