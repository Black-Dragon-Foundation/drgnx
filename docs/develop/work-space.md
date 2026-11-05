# The Work space: the hub's side

The hub's code for the Work space lives in `runtime/crates/drgnx-ratatoskr/src/work/`. The pure parts take no clock and
no I/O, so tests run them in every order or directly.

## Machines

`work::machines` keeps the list `machines/list` and the event `machines-changed` carry (types in
`runstav/src/methods/work.rs`).

- `Registry` is pure: `report(r, now)`, `expire(now) -> names`, `set_local(slots)`, `list()`; `local` is always first
  and never expires. `Machines` holds one behind a lock in `Core`.
- `machines/report` takes user connections only (`classes: [User]`, in `test/conformance/class-matrix.json`); a report
  for `local`, a ttl outside 0..86400, more than 256 slots or a slot without id and kind is `invalid-params`.
- The local pool is read from the job runner (`exec::Runner::slot_counts`): one `local-N` slot per agent-job slot, the
  busy ones held by `job` (the pool does not say which job). The hub refreshes it, and drops expired reports, on every
  `machines/report` and `machines/list`, and every 2 s (`work::machines::run`, which waits on the clock only, a task named
  `machines:run` on the hub's clock, so `__test_advance` moves it). `machines-changed` carries the whole list, and only
  when it changed.
- The CLI is `ratatoskr machines report --machine M --ttl S [--json FILE|-]` (`machines_cli`): exit 0, 1 on a hub
  error, 2 on bad arguments. jobq calls it; its side is jobq's plan.
- Tests: `registry::*` (pattern D), `machines_cli::parses_and_reports` (D), conformance
  `work/machines-report-from-a-user`, `work/machines-report-from-an-agent-is-refused`,
  `work/machines-expire-after-ttl` (virtual clock) and `cli/machines-report` (the CLI as a child, exit read).

## Shell reads

Layer 1 of "reads through shell commands" (the files a command names; labelled "from the command") is
`work::shell_read`.

- `parse(cmd) -> Parsed` reads the text of a shell step and sorts the words that name files into `reads`, `writes`,
  `listed` (a directory listing or a recursive search without a path: `ls`, `find`, `fd`, `tree`, `rg foo`), `scripts`
  (`./x.sh`, `python y.py`, `source z`) and `cds`. It is table-driven over the heads `cat head tail less more wc cut
  sort diff jq grep rg ag ack sed awk find fd ls tree tee` and the interpreters and shells. It understands pipes,
  `&& || ; &`, redirections (`< f` read, `> f` `>> f` `&> f` write, `2>&1` nothing), quotes, `cd X &&` prefixes,
  leading `VAR=x`, `env`, `time`, `timeout`, `nice` and a `bash -c '…'` string parsed once.
- What it cannot know is left out and named in `skipped`, never guessed: `$(…)`, backticks, variables, `xargs` and
  `find -exec` input, a `bash -c` inside a `bash -c`, a heredoc, a subshell, `for`/`case`, a `cd` to an unknown place.
- `resolve(parsed, cwd, roots, glob_cap) -> Resolved` places the words: `~`, the `cd`s in order, simple globs (`*` `?`
  `[…]`, at most `glob_cap` matches per step, 200 in the hub; a glob over the cap, with no match, or with braces or
  `**` goes to `patterns`). Paths are made canonical (symlinks followed, `..` applied, also for a file that does not
  exist yet) and **only paths under the roots are kept**: a `..`, a symlink or a `cd` that leaves the workspace is
  dropped. A read of something missing is not a read, and a read of a directory is a listing.
- Tests: `work::shell_read::tests` (class `det`, pattern D, with a property test over the corpus and random words),
  the corpus in `src/work/shell_read/corpus.txt`, and the timing row `shell_parse_within_200_us`
  (`tests/work_timing.rs`, listed in `test/timing-rust.txt`, 200 µs at p95).
