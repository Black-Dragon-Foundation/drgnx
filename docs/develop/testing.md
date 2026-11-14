# Testing a change: only what it can affect

A merge, a base branch or a pull request changes some files; most test groups cannot see most files.
`bin/drgnx test --affected` reads a git range, picks the groups its diff can affect, and (with `--run`) runs
them, skipping a group whose inputs have not changed since its last green run. The full runs stay what they are:
`bin/drgnx check`, and CI on every push ([ci.md](ci.md)).

```
bin/drgnx test --affected A..B                  # print the groups, why, and each group's command
bin/drgnx test --affected A..B --run            # run them; skip those already green on the same inputs
bin/drgnx test --affected A..B --run --no-cache # run them all
bin/drgnx test --affected A..B --json           # the groups as JSON (range, groups: id, dir, run; why): the hub's merge queue reads it
```

The range is any `git diff` range (`A..B`, `A...B`). `--run` exits 0 only when every group is green or skipped; every
group runs, whatever an earlier one said (no fail-fast).

## The map: `test/affected.eld`

One table, shaped like CI's path filter (`.github/ci/paths.txt`, [ci.md](ci.md#path-filter)): a row is a glob (`*`
matches across `/`) and the actions it asks for; **the first row that matches a changed path wins**. The file's
header lists the actions. A path no row matches runs **everything**, and the output says which path and why. The
table also holds how each kind of group runs (`:kinds`) and which files key its cache entry.

| Change | Groups |
|---|---|
| `docs/`, `README.md` only | the docs checks (`docs:test/unit/config-doc-test.el`, `…settings-doc-test.el`) and nothing else |
| `SECURITY.md`, `LICENSE*` | none |
| `test/affected.eld`, `core/drgnx-affected.el` | `lisp:test/unit/affected-test.el` (and `rules` for the Lisp): nothing else reads the table or the tool |
| `core/`, `modules/` Lisp | `lisp:<test file>` for each unit test file that names the file's feature, plus `rules` and `rust:drgnx-ratatoskr` with its dependents (the doctor and the launch rows read `core/` and `modules/`) |
| `wb/`, `themes/`, `keys/`, `init/`, `modules/ui/`, `etc/icons/` | the same Lisp groups, plus `ui` and `scenario` |
| `runtime/crates/<c>/` | `rust:<c>` and every crate that depends on it, `rust-rules`; `domr` when the hub or the harness is among them |
| `runtime/Cargo.*`, `runtime/protocol/` | `rust-workspace`, `domr`, `rust-rules` |
| `test/conformance/<g>/` | `domr:<g>` |
| `test/unit/X-test.el` | that file and `rules` (the lints read every test file) |
| `test/ui/`, `test/live/`, `test/scenario/`, `test/tty/`, `test/perf/` | that tier and `rules` |
| `bin/`, `harness/`, `settings/`, `install.sh`, `test/support/`, `test/fixtures/`, the lock | everything |
| `.github/`, `.githooks/` | the whole unit suite |

*Everything* is `unit`, `rust-workspace`, `domr`, `ui`, `scenario` and `tty`. It leaves out `perf`: the perf lab is
timing, judged on a quiet machine (`bin/drgnx test --perf`); a change under `test/perf/` asks for it. A wider group
replaces the narrower ones it contains (`unit` replaces every `lisp:` group, `rust-workspace` every `rust:`, `domr`
every `domr:`).

**The hub is built with `test-hooks` wherever a group builds it** (`rust-workspace`, `rust-rules`, `domr`), as CI's
Runtime job does. Cargo keeps one `target/debug/ratatoskr` whatever the features, so a plain `cargo test -p
drgnx-ratatoskr --test …` overwrites the binary that test binaries built before it then start, and their hub-backed
rows fail with "sandbox run exists only in a test-hooks build". Built with the hooks, the conformance rows also run
against the hub CI runs them against.

**Lisp tests map by what they name.** A source file's feature is its file name (`core/drgnx-registry.el` is
`drgnx-registry`). A unit test file is affected when its text names the feature: a `(require 'drgnx-registry)`, or the
feature as a prefix of a test name (`drgnx-registry/…`). Almost every test requires the umbrella `drgnx`, so following
`require`s would reach every file; the name is the cheap, over-approximate test. When no test names the file, the
whole unit suite runs and the output says so. A test that exercises a file without naming it is not found: name it, or
add a row.

**Rust dependents come from `cargo metadata`** (`--no-deps`, offline, the manifests only): a crate depends on another
when its manifest has a path dependency on it, of any kind (a dev-dependency counts: its tests link it).
`DRGNX_AFFECTED_METADATA` names a saved answer. Without `cargo` or an answer, a Rust change runs `rust-workspace` and
says why.

## Running, and where

A group's command is in `:kinds` of the table. Lisp groups are `DRGNX_TEST_ONLY=<file> bin/drgnx test --container`:
one test file in the container. Rust and `domr` groups run `cargo`, which never runs on the host: **set
`DRGNX_AFFECTED_WRAP`** to the words that put a command in a container or a slot (for example the build wrapper
`ratatoskr-cargo.sh`, or a slot script); without it `--run` refuses those groups (exit 2, nothing cached). The
wrapper's words come before every group's command.

## Live notebook kernels

`notebook::kernel::tests_live` (ignored rows) start a real ipykernel, over ipc and over loopback tcp: ready, `print`, an error,
`input()` through the stdin channel, interrupt, orderly shutdown. They read the kernel's python from `DRGNX_NB_KERNEL_PYTHON` and fail,
saying where the kernel is, when it is missing. The kernel is the hash-pinned set in `test/container/ipykernel-requirements.txt`
(every wheel checked, `--no-deps`, compiled for Python 3.15): the adapter image has it at `/opt/nb-kernel`, made with `python3.15`
(its `ENV` sets the variable), and the rows run there only (`ci.md`, "The debug adapters"). Run them in the image with
`cargo test -p drgnx-ratatoskr --features drgnx-ratatoskr/test-hooks --lib -- --ignored --test-threads 1 notebook::kernel::tests_live`.
**ipykernel aborts in its own teardown (SIGABRT) about one run in five**, after an orderly shutdown and after doing everything asked
of it, so the rows assert that the kernel ended by itself within the grace (not killed), not that its exit code is 0; they print the
exit status whenever it is not 0 (`--nocapture`, or the failing run's output), so a pattern shows. The unit tests of the kernel module run under nextest (a
process each: their virtual-clock rows share process-wide state under plain `cargo test`).

## The result cache

`--run` skips a group whose key is already recorded and says so (`skipped X: inputs unchanged since its last green
run`). The key is a hash of

- the group's id and command,
- the Emacs build (`emacs-version`) and the `rustc` and `cargo` versions,
- the name and contents of each of the group's input files (the table's `:lisp-inputs`, the group's own test file or
  crate directories with the crates they depend on, the tier's test directories).

A group is recorded only when it exited 0. A red run, a refusal or a killed run leaves the cache as it was, so the
next run runs the group again. `--no-cache` runs everything and records the green ones.

The cache is `$DRGNX_AFFECTED_CACHE`, else `$XDG_CACHE_HOME/drgnx/affected`, else `~/.cache/drgnx/affected`: one
empty-ish file per key, never inside a checkout, never committed. Deleting the directory only costs a rerun. A group's
inputs are coarse on purpose (any change under `core/` changes every Lisp group's key): a skip means *nothing it can
read changed*, never *probably fine*.

The tests (`test/unit/affected-test.el`) hold fixed fake diffs against the table and the cache's hit, miss and
red-is-never-cached cases.

## A real tree-sitter grammar in the unit tier

A test that needs a real parser (the notebook's, which gives each language one parser over its cells' ranges) cannot rely on
the image having a grammar. `bin/drgnx test --container` therefore runs `test/packs/ts-grammars.sh` inside the container before
the suite: the pack job (`ratatoskr packs sync --builtin`, from the hub binary at `runtime/target/debug/ratatoskr`) builds the
python grammar at the pack's pin into a host cache (`DRGNX_TEST_TS_CACHE`, default `test-ts-grammars` in drgnx's cache folder, keyed by the
pin) and the suite gets `DRGNX_TEST_TS_GRAMMARS`. Without the hub binary the test skips; CI sets `DRGNX_TEST_TS_REQUIRED=1`, which
fails the run when no grammar was built, and `test/no-skip.eld` lists the test. The container needs network, git and a C compiler,
which the test image has.
