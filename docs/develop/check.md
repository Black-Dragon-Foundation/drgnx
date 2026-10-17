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
   - the unit suite in `--shards` batch Emacs (4);
   - the test/ui session;
   - the live tests in shards;
   - the scenario tier.

   GUI jobs (each starts headless Emacs sessions) run no more at a time than free memory allows: 1 GiB each beyond
   1.5 GiB kept free, at least one, at most four.
3. **The unit tests tagged `:timing`, alone.** They assert how long something takes (`:tags '(:timing)` on the
   `ert-deftest`); `bin/drgnx test` still runs them with the rest.
4. **The bench, alone.**
5. **Perf, alone.** It measures input latency.

At most `--jobs` (8) jobs run at once. Each job writes its log to `~/.local/state/drgnx/check/<time>/<job>.log`.
A job that overruns its time limit is ended with everything it started (its process group). The summary lists
every job — ok, FAILED (exit N), TIMED OUT or skipped — with its time and log, then the wall time against the time
the same jobs take one after another. The exit status is 0 only when all passed.

Shards are balanced by how long each test file took last time (`check/durations.eld`, kept from the shards'
results). Sessions started at the same moment from different shards never share a name: a name is claimed by
creating its run directory, and a taken one moves on to the next.

Tests that run in parallel must not depend on machine-wide state another test may share. A check of "no process
like this one is left" uses a marker only this test's process has, such as a random sleep length.
