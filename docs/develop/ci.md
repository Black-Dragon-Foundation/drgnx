# Continuous integration

GitHub Actions runs the same commands you run locally; nothing in CI is CI-only.

## The flow: `ci/*` before `main`

A candidate never goes straight to `main`. Push it to a branch named `ci/<name>`: every workflow that runs on a push
to `main` runs there too, macOS included. Read the **whole** run (every workflow, every job: nothing stops at the first
failure, see below), fix everything it shows, and push once more (a newer push to the same `ci/*` branch cancels the
older run). `main` moves only to a commit whose gates are green, by fast-forward to that exact commit; branch
protection requires the three gate checks. A run on `main` is never cancelled by a newer one. A `ci/*` push runs only
the jobs its change can affect against `main` ([Path filter](#path-filter)); `main` itself always runs everything.

```
git push origin HEAD:ci/my-change          # CI, macOS and the GUI tier run on the candidate
gh run list --branch ci/my-change          # wait for all of them, then read every failed job
git push origin <green sha>:main           # only when CI gate, macOS gate and GUI tier gate are green on it
```

A pull request to `main` works the same way: `main` fast-forwards to the pull request's head, so every job a pull
request runs checks out the head (`github.event.pull_request.head.sha`), never GitHub's merge commit
(`refs/pull/N/merge`), and the path filter diffs the head. CI's `changes` job fails, and with it the gate, unless the
head descends from `main`'s tip: merge or rebase onto it first.

## Gates

Each workflow that gates `main` ends in a job `gate`, which runs always (`if: always()`), `needs:` every job that runs
on a push, and fails unless each of them succeeded: a failed, cancelled or **skipped** job fails it. Its check name
is what branch protection requires (the names differ, so each is one check):

| Check | Workflow | Needs |
|---|---|---|
| `CI gate` | `CI` | `changes`, `runtime` (all of `runtime.yml`), `tiers` (`drgnx-tiers.yml`'s `unit`, `no-lisp-writes` and `hub-chaos`; skipped on a joint round's branch, [Joint rounds](#joint-rounds)), `scripts` |
| `macOS gate` | `macOS` | `changes`, `tiers` (`drgnx-tiers.yml`'s `macos`; the weekly `install` never runs on a push; the weekly run has no gate) |
| `GUI tier gate` | `GUI tier` | `changes`, `tiers` (`drgnx-tiers.yml`'s `ui`, `scenario`, `perf`) |

The gate step is one local action, `.github/actions/gate` (the `needs` as JSON; `allow-skipped` names the jobs that may
be skipped: a job the path filter found the change cannot affect ([Path filter](#path-filter)), and in `CI gate` the
`tiers` on `ci/joint/*`). A called workflow's job (`tiers`, `runtime`) succeeds when each of its jobs succeeded or was
not asked for. A narrowed manual run's CI gate is named `CI gate (partial)` ([Narrowed runs](#narrowed-runs)): no rule
requires that check, so it never stands for the full one.

No other job has a `needs:` but the path filter's (`needs: changes`, whose outputs it takes): a job waits only on what
it takes data from, and the unit suites build the Ratatoskr they test against, so a red runtime test never skips them. Nothing stops early: every `cargo test` runs with
`--no-fail-fast`, every matrix with `fail-fast: false`, no job is `continue-on-error`, and each independent step runs
whatever the steps before it said (`if: ${{ !cancelled() }}`; a step that uses a build waits only for that build's
outcome, `steps.<id>.outcome == 'success'`). The fuzz step runs every target and fails at the end naming each that
failed. `drgnx-ci/each-push-workflow-ends-in-one-gate-over-its-push-jobs` and `drgnx-ci/nothing-stops-early` check it.

Not gates: `Terminal tier` and `Bootstrap` run no push (nightly, weekly), and the terminal tier is red until its owner
makes it green (a tier gates only once it is green). `Test images` has no gate of its own: it runs as the `images`
job of `CI` and `GUI tier`, inside their gates (skipped only on a fork's pull request), and a job that finds no image
builds it.

| Workflow | When | What |
|---|---|---|
| `CI` (`.github/workflows/ci.yml`) | every push to `main` or `ci/*`, every pull request, on demand | the `runtime` job (calls `runtime.yml`, below: a `needs:` cannot reach another workflow file, so the call puts its jobs in `CI gate`); the `tiers` job, which calls `drgnx-tiers.yml` ([The tiers workflow](#the-tiers-workflow)) with `unit no-lisp-writes hub-chaos`: the unit suite on **Nidhogg 31.1** (drgnx's own Emacs build, from its release tarball; Fedora 45, `bin/drgnx test --container`) against a test-hooks `ratatoskr` built once on the runner (`bins-linux`), with `ratatoskr-mock` beside it (the gateway tests' provider) (`DRGNX_RATATOSKR_BIN`; the runner's glibc is older than Fedora 45's, so it runs in the container; the tests that need it fail rather than skip, `test/no-skip.eld`), and huginn's `dump` example (`DRGNX_HUGINN_DUMP`: the editor's differential test, `drgnx-huginn/differential-fresh-seed`, reads a fresh seed with it and with Emacs's reader; on `test/no-skip.eld`), its files in parallel, a failed file rerun once, the `:timing` tests left out by name ([Parallel files](#parallel-files)); `no-lisp-writes`, the same suite once with `DRGNX_WORK_DB_GATE=1` (it fetches the same `ratatoskr`, `ratatoskr-mock` and huginn `dump`, so `test/no-skip.eld` holds there too) (opening `work.db` read-write signals; only the tests tagged `:work-db-writer` are left out; docs/develop/store.md, "The one-writer gate"); `hub-chaos`, the `hub-client` and `ai-gateway` files once per seed (1 to 3) under seeded hub answer delays, with no rerun ([Hub chaos](#hub-chaos)); `shellcheck --severity=warning` on `install.sh`, `bin/drgnx`, the pre-commit hook, `test/container/nidhogg.sh` and `.github/ci/`'s scripts; the path filter's self-test; the leak scan; `CI gate` |
| `GUI tier` (`.github/workflows/gui.yml`) | every push to `main` or `ci/*` (not `ci/joint/*`), every pull request, nightly, on demand (a dispatched run's `GUI tier gate` does not count for `main`'s protection, so a pull request runs it itself) | `drgnx-tiers.yml` with `ui scenario perf`: real Nidhogg sessions under headless mutter, three jobs: `ui` (`bin/drgnx test --container --ui`, `DRGNX_TEST_NO_TIMING=1`: the GUI and live tiers, the `:timing` tests left out; it fetches the run's test-hooks `ratatoskr` for the live tests that start a hub, `DRGNX_RATATOSKR_BIN`), `scenario` (`--container --scenario`, `DRGNX_TEST_NO_TIMING=1`: the frame budget is reported, not judged) and `perf` (`--container --perf`, `DRGNX_PERF_CPU_FACTOR=2`, `DRGNX_PERF_RESULTS=perf-results.json` uploaded as the `perf-results` artifact, also when the run fails); `GUI tier gate`. A newer push to a `ci/*` branch cancels an older run of the same branch |
| `Terminal tier` (`.github/workflows/tty.yml`) | nightly, on demand | a `tiers` job calling `drgnx-tiers.yml` with `tty`: `bin/drgnx test --container --tty --fedora 45`, the terminal tests (Emacs in tmux) on Emacs 31.1, after fetching the pinned kkp. No gate: it is not a push workflow |
| `Bootstrap` (`.github/workflows/bootstrap.yml`) | weekly (Monday), on demand with a Fedora release (45 by default, or 44; the pinned Nidhogg release is unpacked first, so no build) | `bin/drgnx test --bootstrap --fedora N`: the exit test of a second machine — `install.sh --yes --config … --identity …` in a fresh Fedora container reaches a green doctor with the configuration, the locked packages and the provider keys back, and a second run changes nothing ([harness.md](harness.md)) |
| `Runtime` (`.github/workflows/runtime.yml`) | called by `ci.yml` (so on every push to `main` or `ci/*` and every pull request, inside `CI gate`); daily; on demand | the Rust workspace in `runtime/` ([runtime.md](runtime.md)). The `linux` job also fails if `cargo tree -i h2` or `-i aws-lc-sys` (all targets, all dependency kinds) prints anything: the gateway is HTTP/1.1 over rustls with ring. `linux` and `macos` run the workspace tests with the pinned model files (`DRGNX_TEST_MODELS`, from `.github/ci/models.sh`; What is cached); `linux` runs the GPU tests on llvmpipe (`DRGNX_TEST_ADAPTER=llvmpipe`, Mesa's software Vulkan driver from `rust-packages.sh`), and macOS, with no GPU on the runner, ignores them. `linux` (Fedora 45, as root, util-linux installed for `setpriv`: the image has only util-linux-core, and draugr's pdeathsig test and the `sudo` rows run it): `cargo fmt --check`, `clippy -D warnings`, `cargo test --locked --no-fail-fast --workspace` with `drgnx-ratatoskr/test-hooks`; installs Nidhogg and runs the conformance suite with `--require-all` (every row against Ratatoskr; as root the `sudo` rows run, so `security/another-uid-is-refused` is not skipped); a release build whose `version --json` must say `"test_hooks":false`; the perf baseline (`--perf`, artifact `ratatoskr-perf-linux`). `macos` (macOS 27, the image's `rustup` with clippy, not Homebrew's rust: no formula to fetch per run; before the tests `sudo xcode-select -s` points at the Command Line Tools the image installs, because draugr runs only the git of the selected developer dir and refuses Xcode under the admin-writable `/Applications`, whose git is the runner user's there): the same tests and conformance as the runner user, the `sudo` rows through passwordless `sudo -n -u nobody` (`--require-all` fails if that row is skipped), the perf baseline (`ratatoskr-perf-macos`), and last, whatever the steps before it said, `clippy --all-targets -D warnings` on the seven pure-Rust crates (runstav, draugr, eitri, gleipnir, mimir, bifrost and huginn, as on Android; only clippy's test build shows code that is dead on macOS). The Gleipnir escape suite ([gleipnir.md](gleipnir.md), "Proving it") runs in three places. `linux` (the container, as root, `--init`): builds `gleipnir-probe` and `gleipnir-escape`, fails if `cargo tree -e features -i gleipnir -p drgnx-ratatoskr` shows `test-hooks` in a default build (under `bash` with `pipefail`, and the tree must name gleipnir, so a failed `cargo tree` never passes), and runs `--rows rows --rows rows/container` without `--require-all` (the full-tier rows skip there with "inside a container", and the reduced rows with "Landlock ABI N below 9" if the runner's kernel is older; what runs is that every row parses, the probes reach with no sandbox, `check-in-a-container`, and the floor and fail-closed rows); report `escape-report-container`. `macos`: the Seatbelt rows and `rows/any` (no row there needs Linux: a unit test holds it) for real with `/usr/bin/sandbox-exec`, `--require-all` (a skip fails the job), whatever its conformance and perf steps said (and they whatever it says); report `escape-report-macos`. `escape-host` (`ubuntu-24.04` and `ubuntu-24.04-arm`, no container): Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor, so the job runs `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (the runner user has passwordless sudo) and builds bubblewrap 0.12.0 (gleipnir's floor; apt has 0.9.0) from its checksummed release tarball; then `cargo test` for `gleipnir`, `draugr`, `eitri` and `gleipnir-escape` (the arm64 run is the first real one on arm64 Linux, for the seccomp call numbers) and `--rows rows/linux --rows rows/any` without `--require-all`, because the runner kernel's Landlock ABI is probably below 9 (the reduced rows skip with "Landlock ABI N below 9"; only listed reasons may skip). The job gates (green on both runners since 74be75cf; it was `continue-on-error` until then); reports `escape-report-host-X64` and `-ARM64`. The 60-row full run with `--require-all` stays on the escape VM (`gleipnir-vm.sh run`). `escape-host` also runs the agent core's `#[ignore]`d sandbox tests (`cargo test -p drgnx-ratatoskr --features test-hooks -- --ignored`) with the bubblewrap it built, skipping the crate's timing rows (`test/timing-rust.txt`: they are the timing lane's, judged on a release build); `agent-containers` (podman, preinstalled on the runner) builds the static forwarder `drgnx-fwd` beside the hub (its own target dir, as `drgnx runtime build` does) and, in that target dir, `sleipnir` static in jobq's shape (its `linux` and `sync` features for `x86_64-unknown-linux-musl`, [sleipnir.md](sleipnir.md)), gives the runner's user a systemd user session (`loginctl enable-linger`, then `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` for the steps after: without one rootless podman falls back to cgroupfs and the hub refuses container jobs, whose caps it could not enforce) and runs the `container*/*` rows with `--require-all`; both restore the cargo cache before the build and save it right after (`actions/cache/restore` and `/save`). `android` type-checks `runstav`, `draugr`, `eitri`, `gleipnir`, `huginn`, `drgnx-ratatoskr` and `forseti` for `aarch64-linux-android` (a fake C compiler stands in for urdr's bundled SQLite; nothing links), and `sleipnir` with only its `proto` and `sync` features (the shape jobq and the Android door take), then runs `clippy --all-targets -D warnings` there on the eight pure-Rust crates (runstav, draugr, eitri, gleipnir, mimir, bifrost, huginn and forseti; not norn, whose urdr needs a C cross toolchain; only clippy's test build shows code that is dead on Android) and on `sleipnir` in that `proto,sync` shape. `msrv` (Rust 1.95.0, `cargo build --locked`). `deny` (cargo-deny 0.20.2, its checksum verified: advisories, licenses, bans, sources; the whole workspace, so every crate under `runtime/crates/`, for the targets `deny.toml` lists: Linux glibc and musl, macOS, Android). `fuzz` (nightly-2026-10-15, cargo-fuzz 0.13.2, the runner's g++; four parallel shards of `cargo fuzz list`'s targets): 60 s a target on a push (`main` or `ci/*`; every target runs, whatever an earlier one found), 10 minutes a target daily, `fuzz_minutes` a target on demand, none on a pull request; a crash uploads its input as `fuzz-crashes-N`. The daily run is `deny` and `fuzz`: advisories land with no change on our side. Each job with a build has a cargo cache ([What is cached](#what-is-cached)); `only` (from `ci.yml`'s path filter, or by hand) names the jobs to run |
| `macOS` (`.github/workflows/macos.yml`) | `tiers` (`drgnx-tiers.yml`'s `macos` job, below `unit`) and `macOS gate`: every push to `main` or `ci/*` (not `ci/joint/*`), every pull request, on demand; `install`: weekly (Wednesday), on demand | on macOS 27 (`xcode-27`, Apple silicon: GitHub names macOS images after their Xcode now; `.github/actionlint.yaml` declares the label for `actionlint`, whose runner list predates it): `unit` installs ripgrep with Homebrew and Rust with the image's `rustup`, builds Ratatoskr with its test hooks and `ratatoskr-mock` beside it (`.github/actions/build-test-bins`; `DRGNX_RATATOSKR_BIN` for the client's tests; some need `--idle-tick-ms`) and installs Nidhogg from its release tarball (`test/container/nidhogg.sh macos`, which sets `DRGNX_EMACS`), checks that `install.sh` parses under macOS's bash 3.2 (`/bin/bash -n`), prints its plan (`--dry-run`) and runs `bin/drgnx test` the same way ([Parallel files](#parallel-files)), with no time factor (CI runs no `:timing` test); `install` (timeout 180 minutes: it builds Nidhogg) runs `install.sh --yes` for real on the checkout, then `drgnx doctor`, `drgnx sync` (a first sync from the shipped lock), `drgnx macos-app` and `drgnx open --check`. A newer push to a `ci/*` branch cancels an older run of the same event and branch only, so a push never cancels the weekly install, and nothing cancels a run on `main` |
| `Test images` (`.github/workflows/images.yml`) | called first by `CI` and `GUI tier` (their `images` job) on every push and every pull request of this repository (never a fork's), weekly, on demand | builds the prebuilt CI images and pushes them to `ghcr.io/black-dragon-foundation/`: the three Fedora test images `drgnx-test`, `drgnx-test-gui` and `drgnx-test-tty` (and `f45` on `main`), the Rust job's `drgnx-test-rust`, and `drgnx-bwrap` per architecture, each tagged with `test/container/image-tag.sh` ([Prebuilt images](#prebuilt-images-the-cache)); a push or a manual run builds only the tags GHCR lacks, the weekly run rebuilds them all |

The unit suite includes formatting (`bin/drgnx fmt`), the byte-compile with no warnings and the lints, so they
need no jobs of their own. Tests that need what an Emacs build lacks skip themselves (for example the Work
graph tests on an Emacs without SVG), so the two Emacs jobs skip different tests.

The macOS workflow has no GUI tier: the GUI tests (`--ui`) stay Linux-only (they run under headless mutter), so the
Mac UI is checked by hand with the session checklist. The weekly `install` job is a real install on a fresh runner
(it installs Emacs with Homebrew); it stays out of the per-push run. Homebrew neither updates itself nor cleans up
after an install in either job (`HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_NO_INSTALL_CLEANUP`): the image's formulae are
what the run gets, and no step spends minutes on either.

The unit suite runs on both systems, so a test never assumes Linux: no `/proc` (the mock ACP agent is started through
`test/fixtures/mock-acp-stdin.sh`, which hands it its stdin through a FIFO; a process's command line or memory comes
from `process-attributes`); temp paths compared with git's go through `file-truename` (macOS's `/var` is
`/private/var`); sockets live under a short directory (macOS's temp dir is long); a test that expects Linux keys or
prompts pins `drgnx-platform`, one that expects Linux frame parameters (the menu bar) binds `system-type`; a variable
of an optional C feature is bound with `dlet` (Homebrew's Emacs has no D-Bus, so `dbus-registered-objects-table` is
not special there and a `let` binds it lexically); only tools the system has are linked into a fake PATH (macOS has no `setsid`), and only
POSIX options are used (no `timeout`, `dd iflag=`, GNU grep's `--exclude`); a test puts back the mode tables it
changes (`major-mode-remap-alist`: Emacs 31 asks to install a missing grammar, which in batch reads stdin); native
compilation is optional (Homebrew's Emacs has none: a test that counts allocations calls compiled functions of fixed
arity, since a byte-compiled `&rest` function such as `ignore` conses its argument list where the native one does
not). A socket's whole path stays under 104 bytes: a session's socket goes under a short runtime directory of its own
(`/tmp/drgnx-xdg…`), never under the run's temp directory (`/private/tmp/drgnx-t-…/drgnx-run.…/`, 45 bytes on
macOS). Module teardown re-applies the keys on the host's platform (`drgnx--after-teardown`), so on macOS it sets the
Mac modifiers and binds Cmd chords; `drgnx-test-with-modules` puts both back. A test of a poll counts reads, not
seconds: on a loaded runner one call to a tool can outlast the poll times. A test of a Linux-only branch pins the system too: `system-type`
in Lisp, a fake `uname` on the fake PATH or `DRGNX_UPDATE_PLATFORM` for `bin/drgnx`. Shell scripts and the snippets
tests run run under macOS's `/bin/bash` 3.2: no `source <(…)` (it sources nothing; `eval "$(…)"` works), no `read -N` (`dd bs=1 count=N` reads N bytes), and a
variable before a non-ASCII character takes braces (`${name}…`: macOS's bash reads `$name…` as an unknown variable;
`drgnx-bin/no-shell-variable-runs-into-a-non-ascii-character` checks it). A test that types into an interactive shell
(the zpty fixture `test/fixtures/zsh-complete.zsh`) types only once the shell's prompt is on the screen: text typed
before meets the terminal's own line editing (^U erases the line in the kernel), which macOS's slower runners show.

Emacs 31's ERT no longer loads bytecomp, so code that let-binds
`byte-compile-warnings` (or any variable of a library not loaded yet) requires the library first: bound before, the
variable is lexical and loading the library fails. Emacs rejects a wall timer's `:repeat t`:
a repeat is a number of seconds. Ubuntu's `emacs-nox` has no image functions (`image-flush` is declared, not
assumed), and without a UTF-8 locale Emacs quotes messages `like this', so a test matches either quote. On Linux,
`TMPDIR` set to a symlinked or long directory shows most of these before macOS CI does; `LC_ALL=en_US.iso88591` shows
the `$name…` one.

Nor does a test assume a desktop's environment. The Ubuntu job runs as root, in the C locale, with uutils' coreutils
and no tree-sitter grammars: a test that looks at glyphs pins the UI kit's one ASCII predicate,
`drgnx-ui-ascii-frame-p` (`drgnx-face-glyph`, the cockpit's and the tty popups' tests all follow it), or reads Emacs's own `truncate-string-ellipsis` (`...` in the C locale); a test of a
read-only file skips as root; a tree-sitter mode without its grammar is not checked; a lock never rests on `mkdir`
alone (uutils' lets two racing commands both make the directory); and a test's flymake backend runs with
`trusted-content` bound to `:all` (Emacs 31 runs backends only in trusted buffers). `LANG=C bin/drgnx test` shows the
locale's share locally.

## Path filter

A pull request and a push to a `ci/*` branch (not `ci/joint/*`) run only the jobs their change can affect. Each push
workflow (`CI`, `macOS`, `GUI tier`) starts with a `changes` job that runs `.github/ci/changes.sh` over one table,
`.github/ci/paths.txt`: rows of a glob and the jobs a change there can affect (`rt-*`: `runtime.yml`'s jobs; the
others: the tiers), the first matching row wins. The workflows pass on what it decided (`runtime.yml`'s `only`,
`drgnx-tiers.yml`'s `tiers`), and the gate allows exactly the jobs it skipped. Never fewer than the change needs:

- The diff is against `main`'s tip, and only when that tip is an ancestor of the commit and every finished run of
  the workflow's gate check on it passed (a pull request: its base, the same way). The jobs a change cannot affect
  then have their result on that tip: `main` moves only to commits whose gates passed.
- Everything runs on a push to `main`, a schedule, a manual run that names nothing, a joint round, a path no row
  names, 300 or more changed files, and on any error working out the diff (no tip, an API error, a red gate on the
  tip). A failed `changes` job runs everything too (and fails the gate).
- The workflows, `.github/ci/`, `bin/`, `install.sh`, the harness, `settings/`, the lock, `test/container/` (the
  Nidhogg pin and the images), `test/support/`, `test/fixtures/`, `core/` (the Lisp hub and the Rust tests read it),
  `runtime/` and `docs/develop/hub.md` (a Rust test reads its method table) run everything. Other Lisp runs the tiers
  (`modules/` the runtime's test jobs too); docs and the README run the tiers but `hub-chaos` (tests read them); a
  tier's own test directory runs that tier and the unit suite (its lints read every test file), and the `hub-client`
  and `ai-gateway` test files `hub-chaos` too; `SECURITY.md` and the licences run
  nothing but the always-run `scripts` job (shellcheck, the leak scan, the filter's self-test).

`bash .github/ci/changes.sh .github/ci/paths.txt --self-test` checks the mechanism and every `test` line of the table
(the bite cases: a `wb/` change skips Rust, a `runtime/` change runs everything, a workflow or an unknown path runs
everything, `SECURITY.md` runs nothing, a narrowed run is partial); `scripts` and `drgnx-ci/the-path-filter-bites`
run it. A new top-level path runs everything until it gets a row.

## Narrowed runs

A manual run of `CI` can name jobs and a test selector, to test one thing on GitHub instead of the desktop:

```
gh workflow run ci.yml --ref ci/my-lane -f jobs='unit' -f selector='"drgnx-registry/"'
gh workflow run ci.yml --ref ci/my-lane -f jobs='rt-linux' -f fuzz_minutes=1
```

`jobs` takes the table's ids (`rt-linux rt-msrv rt-escape rt-containers rt-android rt-deny rt-fuzz rt-macos unit
no-lisp-writes hub-chaos ui scenario perf macos tty timing`; the GUI tiers and `macos` run in `CI`'s own `tiers` job then),
`selector` is `DRGNX_TEST_SELECTOR` (an ERT selector, read as Lisp: a string is a regexp, `\|` not `|`; `hub-chaos`
keeps its own). When the run
leaves out a job the change needs, or narrows the tests, its gate is `CI gate (partial)`: green when what it ran
passed, never the check `main`'s protection requires. A narrowed run goes through the same path filter, so it never
runs less than it asks for; it saves caches like any `ci/*` run.

`runtime.yml` has one job outside the table, `fleet` (the fake SSH runners of `test/runners/`), which runs only on a
manual dispatch of `runtime.yml` that names it, never on a push or in a gate:

```
gh workflow run runtime.yml --ref ci/my-lane -f only=rt-fleet
```

## The tiers workflow

`.github/workflows/drgnx-tiers.yml` is the one definition of drgnx's Emacs-side jobs (`workflow_call`). drgnx's
`ci.yml`, `gui.yml`, `tty.yml` and `macos.yml` call it on the pinned release; **Nidhogg's CI calls it too**, at a pinned drgnx
commit, on the tarballs its own run just built, so a Nidhogg change is tested with drgnx's real tiers (the GUI tier
included) and the steps live in one place. Inputs:

| Input | Values | Meaning |
|---|---|---|
| `drgnx_ref` | commit, branch or tag; empty | the drgnx commit to test; empty: the caller's own commit |
| `nidhogg` | `release`, `artifact` | `release`: the images as built (the pinned release, `test/container/nidhogg.sh`); `artifact`: the run's `tarball-fedora-45` and `tarball-macos` |
| `tiers` | any of `unit no-lisp-writes hub-chaos ui scenario perf tty macos` | the jobs that run; the others are skipped |
| `selector` | an ERT selector; empty | `DRGNX_TEST_SELECTOR` of the test jobs (not `hub-chaos`, `perf` or `timing`): a narrowed run |

Every job checks drgnx out into `drgnx/` (in Nidhogg's run the workspace is Nidhogg's checkout) and takes the local
actions from there (`uses: ./drgnx/.github/actions/…`), so they come from the drgnx commit under test. A `drgnx_ref`
is checked right after the checkout, before any of its actions runs: it must be a commit on one of drgnx's own
branches (only a writer can push one). A pull request's ref (`refs/pull/…`) or a fork's commit, which GitHub also
serves from this repository, fails the job. The actions save a cache only for drgnx's own run of the workflow's own
commit (`github.sha`), never for a `drgnx_ref` another repository's run names:

- `build-test-bins`: Ratatoskr with the test hooks, `ratatoskr-mock` and huginn's `dump`, with a cargo cache
  (`cargo-OS-drgnx-test-bins-TOOLCHAIN-HASH`, [What is cached](#what-is-cached)) saved by a push or manual run of `main`
  or a pull request from a branch of this repository, never by a `ci/*` branch or a fork's (Nidhogg's run restores
  it and never writes). `bins-linux` runs it once, for `unit`, `no-lisp-writes`, `hub-chaos`, `ui` and `perf` (whose agent workloads start a hub with
  `ratatoskr-mock` beside it), and uploads the binaries (`drgnx-test-bins-linux`, kept a day); `macos` runs it itself (one macOS job, so no second macOS runner for it: GitHub's free plan runs 5 at once).
- `fetch-test-bins`: puts them back under the checkout's `runtime/target/debug` (so `bin/drgnx test --container` sees
  them at `/src`, `ratatoskr-mock` beside Ratatoskr) and sets `DRGNX_RATATOSKR_BIN` and `DRGNX_HUGINN_DUMP`.
- `test-image`: pulls the prebuilt image for its Containerfile ([Prebuilt images](#prebuilt-images-the-cache)); with
  `nidhogg-artifact` it then installs the run's tarball on top — a thin image `FROM` it that runs
  `test/container/nidhogg.sh fedora-45 TARBALL`, the same install the images make of the release — and names that image
  in `DRGNX_TEST_IMAGE` / `DRGNX_TEST_GUI_IMAGE`. It fails when the artifact holds no tarball; it never falls back to
  the release. On macOS the `macos` job passes the tarball to `nidhogg.sh macos TARBALL` the same way.
- `gate`: see [Gates](#gates).

Called workflows run in the caller's context: the caller's runners, token and caches (in Nidhogg's run the cargo cache
is Nidhogg's), and `actions/checkout` without `repository` checks out the caller
([GitHub: reusing workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)).

## Joint rounds

When drgnx and Nidhogg change together (a Nidhogg release that drgnx's next commit needs), each pair of commits is
tested once:

1. drgnx goes to a branch `ci/joint/<name>`: `CI` runs `runtime` and `scripts` and skips `tiers`, which `CI gate`
   allows there and nowhere else; `GUI tier` and `macOS` do not run (`branches: [main, "ci/**", "!ci/joint/**"]`).
2. Nidhogg's CI runs by hand with `drgnx_ref=ci/joint/<name>`: it builds Nidhogg and calls `drgnx-tiers.yml` with
   `nidhogg: artifact` and `unit no-lisp-writes ui macos` on that build.
3. After the Nidhogg release, drgnx's pin moves to it (`nidhogg.sh`, `install.sh`, the Containerfiles) on a plain
   `ci/<name>` branch: the full run there, on the published release, is `main`'s gate (scenario and perf run there).

## Hub chaos

The `hub-chaos` job of the tiers workflow (in `CI gate` through `ci.yml`'s `tiers` job, on every push) runs the
`hub-client` and `ai-gateway` files three times, with `DRGNX_TEST_HUB_CHAOS` set to 1, 2 and 3, against the run's
test-hooks `ratatoskr` (`bins-linux`): under a seed, what each real hub connection reads reaches the client after that
connection's own delay (none, or 10 to 200 ms, `test/fixtures/hub-chaos-fixture.el`; the pre-flight's P3-hub step,
below). It finds a test body that starts before its event connection is subscribed, which no CPU limit shows (a limit
slows every connection alike). No rerun: a red under chaos is a race, not a flake, so the job sets no
`DRGNX_TEST_RERUN`. A red is an error annotation naming the seed with the command that replays it; a seed that ran no
test is red too. The same locally:

```
DRGNX_TEST_HUB_CHAOS=2 DRGNX_TEST_SELECTOR='"^drgnx-\\(hub-client\\|ai-gateway\\)/"' bin/drgnx test --container
```

A seed is the two files at once, 62 tests in about 20 s on a desktop (the `:timing` ones left out), so the job is a
few minutes after `bins-linux`, the image pull and the binaries' download.

After the seeds the job's last step runs `bin/drgnx test --orders --container`, whatever the seeds said and with no
rerun (the files at the same time, one per CPU: in sequence, 82 runs of 9 files took 19 minutes, with 2 files to go,
past the job's 20): every file whose `;; test-pattern:` line names `gated` once per swapped pair of lines across connections
([Orders](check.md#orders-bindrgnx-test---orders)). A red names the file and its K, and
`DRGNX_TEST_GATE_SWAP=K DRGNX_TEST_ONLY=FILE bin/drgnx test --container` replays it.

## The timing lane and the pre-flight

Every tier sets `DRGNX_TEST_NO_TIMING=1`, so the tests tagged `:timing` (wall-clock assertions) run in one place only:
the `timing` job of the tiers workflow (`tiers: timing`), which runs `test/timing-lane.sh`. It is report-only
(the script reports and exits 0, so a red verdict never reddens the run; `CI gate` does not need it). The lane takes 20 samples of each row of `test/timing-rows.txt`
(one row for each area's test-name prefix, so an area is judged on its own time; `drgnx-lint/every-timing-test-is-in-a-row`
fails a `:timing` test no row holds), measures a fixed workload before and after (the calibration: a batch Emacs in the
image the tests run in, `DRGNX_TEST_IMAGE`, never a host Emacs, which a CI runner does not have),
and passes `DRGNX_TEST_TIME_FACTOR` = calibration / the budgets' reference calibration (`# island-calibration` in the rows
file) to the tests. A row is `void` when the two calibrations differ by over 25 % (retried once), `red` when its median
time exceeds the ratio times the calibration or over half the samples fail (rerun once; a pass on the rerun is `flaky`).
`test/timing-lane.sh --self-test` checks the verdicts and where the calibration runs (`drgnx-ci/the-timing-lane-judges-and-calibrates-in-the-image`
runs it with the unit suite).

The same job then runs the Rust timing tests (`#[ignore = "timing: …"]` under `runtime/`, which no other Rust job runs) with
`test/timing-rust.sh`: each test listed in `test/timing-rust.txt` alone, from a Fedora 45 container, one `pass`/`red` line each,
also report-only (artifact `drgnx-timing-rust-report`). `drgnx-ci/every-rust-timing-test-is-in-the-timing-list` fails a timing
test the list lacks.

**Runner images.** Every job names its image (`ubuntu-24.04`, never `ubuntu-latest`, which moves to 26.04 between
2026-10-19 and 2026-11-19), so the move changes nothing until a job is moved on purpose. `runtime.yml`'s `escape-host`
also runs on `ubuntu-26.04` and `ubuntu-26.04-arm`, gating like the others: bubblewrap 0.12.0 as `/usr/bin/bwrap` and no global sysctl
(26.04 keeps `apparmor_restrict_unprivileged_userns=1` and confirms `/usr/bin/bwrap` by its own profile), the setup
[gleipnir.md](gleipnir.md) recommends. The 24.04 legs lift the restriction with the sysctl.

`bin/drgnx test --preflight --out REPORT [--seeds N] [--nidhogg-tarball FILE]` hunts ordering bugs: the `det` files twice
in two shuffle orders with the runtime audit failing (`DRGNX_TEST_AUDIT_FAIL=1`: a `det` test that really sleeps, waits
on a process or starts one is red; any red, or a difference between the runs, is red), the `cond` files at 1 CPU, 2 CPUs and half a
core (`DRGNX_TEST_PODMAN_ARGS=--cpus=…`) N times each, and the `cond` tests of the process, socket and ordering files
(`hub-client`, `test-proc`, `remote`, `shell-env`, `shell-completion`, `session`; `DRGNX_PREFLIGHT_P3_SELECTOR`
overrides) on a chaos Nidhogg image: `DRGNX_TEST_CHAOS_IMAGE`, or the image `$DRGNX_DET_IMAGE TARBALL preflight` prints
as its last `DRGNX_TEST_IMAGE=` line (`DRGNX_DET_IMAGE` is the org folder's `tooling/det-image.sh`); without an image P3 is
skipped. P3-hub needs no image: the `hub-client` and `ai-gateway` files N times, seeds 1 to N, with
`DRGNX_TEST_HUB_CHAOS=SEED`, under which what each hub connection reads reaches the client after that connection's own
delay (its end runs at once, as Emacs runs it, or after output still queued) (none, or 10 to 200 ms, `test/fixtures/hub-chaos-fixture.el`; not on the
virtual clock of `drgnx-test-with-clock`, where the test orders time itself): a CPU limit
slows every connection alike, this changes which one is answered first (a test body that starts before its event connection is subscribed). A red prints its seed; the same
variable replays it. The files are chosen by class tag, so exempt and unclassified files are never run, and a step that ran no test
is red (a vacuous pass proves nothing). `REPORT.stamp` (`COMMIT PASSES DATE`) is written only when every step ran, ran
tests and passed; a failed, skipped-P3, zero-test or killed run leaves none.

## Parallel files

Each unit-suite job (Emacs 31.1, macOS) runs the suite in one step: `DRGNX_TEST_JOBS` is the runner's cores
(`nproc` on Linux: 4 on `ubuntu-24.04`, 16 GB; `sysctl -n hw.ncpu` on macOS: 3, 7 GB), `DRGNX_TEST_RERUN=1` reruns a
failed file once (a file that fails and then passes is reported as a flake, not a failure) and `DRGNX_TEST_NO_TIMING=1`
leaves out the tests tagged `:timing` (wall-clock assertions) and lists them as skipped. That many test files run at
once, each in an Emacs of its own as always; a file's output is printed whole when it ends, after a `drgnx: FILE`
line, and the summary at the end lists every unexpected result.

The `unit` job (Linux, Fedora 45) also sets `DRGNX_TEST_LOCALE=C.UTF-8`, which `bin/drgnx test --container` turns into
`LC_ALL` in the container; the other jobs run with no locale, so both are covered.

The `unit` and `no-lisp-writes` jobs run the runtime audit and fail on it (`DRGNX_TEST_AUDIT=1`,
`DRGNX_TEST_AUDIT_FAIL=1`; [harness.md](harness.md), "The audit"): a `det` test that really sleeps, waits with a timeout,
or starts a process or a socket is red there, as it is in the pre-flight. The primitives are advised only around `det`
tests, so the other tests run as before.

No CI job runs a `:timing` test: a shared runner's clock judges nothing, so a budget in wall time lives where the
machine is quiet (`bin/drgnx check`'s `unit-timing` job, [check.md](check.md)) and, for the frame and the work in a
command, in the perf job (allocation, CPU time and counts; [perf.md](perf.md)). `bin/drgnx check` stays as the local
equivalent of the merge wave; no workflow runs it.

Tests tagged `:frozen` (tests of Lisp that a plan replaces with Rust, run against the in-Emacs Lisp hub) are left out of
every run, CI included; `DRGNX_TEST_FROZEN=1` runs them (`harness/run-ert.el`). The same holds for whole files: a row
of `test/class-exempt.eld` with `:off t` (the Lisp runtime Ratatoskr P7 deletes, the Lisp search P8 deletes, gryphn)
leaves its file out of every run, a shard's list included. The frozen UI's rows have no `:off`: it is still in use.

DEFERRED DET-CI-ENV-1: the step uses `DRGNX_TEST_NO_TIMING=1` rather than `(not (tag :timing))`, and
`test/no-skip.eld` has no darwin or Ubuntu rows until the first CI summaries list their skips.

The same locally (the Emacs 31.1 job's step, without the container):

```
DRGNX_TEST_JOBS=4 DRGNX_TEST_RERUN=1 DRGNX_TEST_NO_TIMING=1 DRGNX_TEST_AUDIT=1 DRGNX_TEST_AUDIT_FAIL=1 bin/drgnx test
```

## Reproduce a job locally

```
bin/drgnx test --container          # the Emacs 31.1 job in one step (podman, docker or nerdctl; see "Parallel files")
bin/drgnx test --container --ui     # the GUI tier's ui job (--scenario, --perf: its other two)
bin/drgnx test --container --tty                # the nightly terminal tier (Fedora 45, Emacs 31.1)
bin/drgnx test --bootstrap          # the weekly second-machine exit test (fedora:45)
.githooks/pre-commit --all          # the leak scan over every tracked file
```

`bin/drgnx test --container` passes the run-control variables (`DRGNX_TEST_SELECTOR`, `_JOBS`, `_RERUN`, `_NO_TIMING`,
`DRGNX_PERF_RESULTS` through a mount, `_CPU_FACTOR`, `_WORKLOADS`, `DRGNX_UITEST_SETTLE_SCALE`, and the sessions'
`DRGNX_UI_SIZE`, `DRGNX_UI_MONITORS`, `DRGNX_UI_SCALE` and `DRGNX_UI_SCALES`) into the container and
always sets `DRGNX_LEASE=off`. Run from a git worktree (where `.git` is a file naming a host path), it also mounts the
repository's common git dir (`git rev-parse --git-common-dir`) read-only at the same absolute path, so git inside the
container works; the tests only read it.

`DRGNX_CONTAINER=podman` names the container runtime without asking a host Emacs (CI has none).

## Prebuilt images (the cache)

Installing Emacs and the GUI stack into Fedora took about a minute per job, so the images are built once by
`Test images` and pulled. Every image's Emacs is Nidhogg: `test/container/nidhogg.sh DISTRO` downloads the release
tarball, checks its pinned sha256, unpacks it to `/opt/nidhogg/VERSION`, installs its `deps.runtime` and links
`nidhogg`, `nidhoggclient`, `emacs` and `emacsclient` into `/usr/local/bin`; each Containerfile sets
`DRGNX_EMACS` to the same path. The script is the one place the version and the checksums (one per distro) are
bumped, together with `NIDHOGG_VERSION` in `install.sh` and the `ENV DRGNX_EMACS` line of each Containerfile
(`drgnx-ci/nidhogg-pin-matches-install-sh`, `drgnx-ci/containerfiles-name-the-pinned-version`).
`Containerfile.gui` keeps `emacs-lucid` for the X11/i3 sessions (Nidhogg has no X11 build; DEFERRED NIDHOGG-X11-1).

An image's tag is `test/container/image-tag.sh FILE`: the first 16 hex digits of a sha256 over the Containerfile and
every file its `COPY`/`ADD` lines take from the build context (a copied directory counts each file), so a change to
`nidhogg.sh`, the child-frame pins or a build script is a new tag, and nothing else is. A job looks the tag of its
own checkout up on GHCR (`.github/ci/ghcr.sh ref NAME TAG`, the registry API through curl) and pulls the digest it got
(`NAME@sha256:…`), so one job never mixes two builds of a tag (the weekly run rebuilds them). `ci.yml` and `gui.yml`
call `Test images` first, as their `images` job, on every push and pull request of this repository, and the jobs that
pull an image (`runtime`, `tiers`) wait for it: a round whose inputs changed builds each missing tag once and every
job of it pulls the same one (round 3 of `.6` built them in every job, about 3 minutes each, seven times a run). The
call builds only the tags GHCR lacks; `Test images`' own weekly run rebuilds every one (a caller's nightly does not),
and on `main` it moves `f45` to the tag an earlier round built. The waiting jobs run whatever the images job did
(`!cancelled()`), and a job that still finds no image (a fork's pull request: its token cannot push, so the call is
skipped there, which its gate allows) builds the image itself and pushes nothing, so a job never runs on an image of
other inputs. Only this repository's runs publish. The calls of `ci.yml` and `gui.yml` are separate concurrency groups
(`images-WORKFLOW-REF`): one shared group would cancel the call that waits. The prebuilt images:

- `drgnx-test`, `drgnx-test-gui`, `drgnx-test-tty`: the tiers (the `test-image` action; `bin/drgnx test --container`
  builds one itself when the action set none). Each is built on a base: `drgnx-base-test`, `drgnx-base-gui`,
  `drgnx-base-tty` (`test/container/base/Containerfile*`: only the Fedora packages), published first by the `bases` job
  of `Test images`. The tier's Containerfile is `ARG BASE` / `FROM ${BASE}` plus `nidhogg.sh` and its few copied
  files, and its `# base: NAME FILE` line names the base; `image-tag.sh` puts the base's tag into the image's, so a
  base change re-tags every image on it and a Nidhogg bump re-tags none of the bases. `image.sh` resolves a base as it
  does an image (local, GHCR, build), so a local run after a Nidhogg bump builds only the thin top.
- `drgnx-test-rust` (`Containerfile.rust`: Fedora 45 with `test/container/rust-packages.sh` and Nidhogg): the container
  of `runtime.yml`'s `linux` job, by digest, from that workflow's own `images` lookup job before it; without one the job runs plain
  `fedora:45`, and its steps run `rust-packages.sh` and `nidhogg.sh` themselves. The job's `container` is one
  expression with both cases: GitHub refuses a job whose `credentials` come out empty before any step runs, so only
  the prebuilt image gets them (`drgnx-ci/a-job-container-names-credentials-only-with-its-image`). The timing lane's Rust step
  (`test/timing-rust.sh`, `DRGNX_TEST_RUST_IMAGE`) runs in it too.
- `drgnx-bwrap` (`.github/ci/bwrap/`, `-x64` and `-arm64` tags, built on Ubuntu 24.04 of that architecture): one file,
  bubblewrap 0.12.0 built from its checksummed source, in a `FROM scratch` image, so the escape suite's runner jobs
  read its one layer with curl (`ghcr.sh file`, the manifest and the layer checked against their digests) and need
  no podman; without one they run the same `build.sh` on the runner.

A local `bin/drgnx test --container` uses the same tags: the local store first, then a pull of
`ghcr.io/black-dragon-foundation/NAME:TAG` (public, anonymous), a build only when both miss
(`test/container/image.sh`; `DRGNX_TEST_IMAGE_PULL=0` for offline). A local run therefore builds an image only for
inputs `Test images` has not published yet.

`bin/drgnx test --container` uses `DRGNX_TEST_IMAGE` (and `--ui`
`DRGNX_TEST_GUI_IMAGE`; `--ui --compositor kwin|niri` `DRGNX_TEST_WM_IMAGE`, from `Containerfile.wm`, which no CI job
builds or runs yet) instead of building when set — locally too:

```
DRGNX_TEST_IMAGE=ghcr.io/black-dragon-foundation/drgnx-test:f45 bin/drgnx test --container
```

The weekly rebuild picks up Fedora's updates under the same tags. The Ubuntu job installs its packages directly
(about 18 s — less than restoring a cache), zsh among them: the shell-file and completion tests need zsh and bash
(fish is optional; its parts skip). It runs as root on a workspace the runner's user owns, so it marks the checkout
as a git `safe.directory` system-wide (the tests run git with a temporary `HOME`); without that, every git command
on the checkout fails with "dubious ownership" (`drgnx test --bootstrap`'s snapshot did).

## The browser rows in a VM

The agent browser's layer needs Landlock ABI 9 (Linux 7.1) on both sandbox tiers, and GitHub's Ubuntu runners, 24.04
and 26.04 alike, boot Linux 7.0 (ABI 8). So each leg of `runtime.yml`'s `escape-host` runs the browser rows
(`tests/browser_sandboxed.rs`) in a Fedora 45 VM, whose kernel has ABI 9 or later as the Fedora hosts drgnx supports
do, right after its own sandbox lane, which leaves out exactly those rows (the names the test binary lists with
`--list --ignored`). `.github/ci/browser-vm.sh`:

- `up DIR` installs QEMU and cloud-image-utils from apt, fetches the pinned Fedora Cloud image of the runner's
  architecture and checks its sha256, and boots an overlay of it: KVM where the runner gives it (`/dev/kvm` is
  opened to the runner's user), emulation otherwise. cloud-init makes a user `runner` with passwordless sudo and a key
  made for the run; the script waits for ssh on a forwarded loopback port, at most 20 minutes.
- `put DIR PATH...` copies the job's `/usr/bin/bwrap` (bubblewrap 0.12.0; root's, as Gleipnir requires), `ratatoskr`,
  `gleipnir-probe`, `ratatoskr-mock`, the crate's `tests/data` and the test binary to the same paths in the VM:
  the binary names its data and its hub by absolute path. glibc builds of the runner run on Fedora's newer glibc.
- `run DIR CMD` runs the rows (`--ignored --test-threads 1`) as `runner`; their exit is the step's.

To bump the image, change its name and sha256 for both architectures (the `CHECKSUM` file beside the image, signed by
Fedora's key); `drgnx-ci/the-escape-legs-run-the-browser-rows-in-a-vm` holds the pins and the step order.

## What is cached

Measured on the runs of 2026-10-19/20 (`gh run view ID --json jobs`): the unit suite is 3.5–4 min on Linux and about
16 min on macOS, a GUI job 1.5–5.5 min, the image pull 18–28 s, `brew install emacs ripgrep` 8 s. Nothing in the unit
suite downloads: no grammar, no `drgnx sync`. The unit, GUI and terminal jobs use the `test-elpa` action
(`.github/actions/test-elpa`): `test/container/modal-elpa.sh` fetches the lock's pinned evil, goto-chg, evil-collection,
kkp, vertico, compat and orderless (vertico needs compat; Quick Open's tests drive real vertico), checks each sha256 against `etc/drgnx.lock.eld`, unpacks them into one directory (cached by the lock's hash,
saved only by a push to or the daily run of `main`, on its own commit), and the action sets `DRGNX_MODAL_ELPA` and `DRGNX_USER_ELPA` to it. So the evil and real-kkp teardown tests, the modal
isolation test and kitty's kkp tests run instead of skipping. So the caches are few:

| What | Key | Saves | Bust it |
|---|---|---|---|
| the prebuilt images (`Test images`, GHCR; the GUI one also holds the pinned child-frame packages, checked out at pinned upstream commits at build, so the tier fetches none) | tag = `test/container/image-tag.sh`: the Containerfile and every file it copies (and `f45` for the test images); pulled by digest | an install of Emacs and the GUI/terminal stack into Fedora per job: about 1.5–2 min; the Rust job's dnf installs and Nidhogg; the escape legs' bubblewrap build | change an input, or run `Test images` by hand (the weekly run refreshes every tag with Fedora's and Ubuntu's updates) |
| cargo: `target/` of every Rust job (`runtime.yml`'s `linux`, `msrv`, `escape-host` per architecture, `agent-containers`, `android`, `fuzz-build`, `macos`; `build-test-bins` per OS), and the registry's index and `.crate` files once per OS and lock for all of them (`fuzz` keeps its own, with its own lock) | target: `cargo-OS-JOB-mt1-TOOLCHAIN-HASH` (TOOLCHAIN: `rustc -V`, the pinned nightly or 1.88.0; HASH: `Cargo.lock` and every `Cargo.toml`), restored from the newest `cargo-OS-JOB-mt1-TOOLCHAIN-` entry when the hash moved; registry: `cargo-registry-OS-HASH(Cargo.lock)`, else the newest `cargo-registry-OS-` | the dependencies' compile (the unpruned `linux` cache was 3.5 GB, and every `Cargo.lock` change, a workspace version bump included, missed it whole) | a toolchain or dependency change makes a new key; delete the entries in the repository's Actions caches |
| Nidhogg's pinned release tarball on macOS (`runtime.yml`'s and the tiers' `macos` jobs share one entry, about 90 MB) | `nidhogg-release-OS-ARCH-HASH(test/container/nidhogg.sh)`, exact; `NIDHOGG_DOWNLOADS` points `nidhogg.sh` at it, which checks it against the pinned sha256 on every use and downloads instead when it fails | the download (the tarball never changes for a pin) | a pin bump makes a new key; saved by `main` only, never in Nidhogg's run (its own tarball) |
| the pinned model files the Rust tests run the built-in model from (`runtime.yml`'s `linux` and `macos` share one entry, `../test-models` beside the checkout, about 950 MB: hrafn-embed's `MODELS` table, listed in `.github/ci/models.txt`, which a test of hrafn-embed keeps equal to it) | `models-HASH(.github/ci/models.txt)`, exact, across OSes; `.github/ci/models.sh` checks each restored file's sha256, fetches what is missing or wrong from Hugging Face at its pinned revision, and sets `DRGNX_TEST_MODELS` | the download | a table change makes a new key; saved by `main` and a same-repository pull request |
| the fuzz corpora the fuzzers grew (`runtime/fuzz/corpus`, per shard) | `fuzz-corpus-SHARD-HASH-RUN`, restored from the newest of its shard | a run starts where the last stopped | delete the entries |

An image is addressed by the hash of the files it is built from, and a job whose hash has no image builds it itself,
so a job never runs on an image of other inputs; a cold cache (no image) gives the same result, only slower.

A cargo entry is safe to restore when older than the checkout: cargo checks every output against its inputs and
rebuilds what is stale, and the key names the toolchain, whose change would rebuild everything (a new key, so the
stale entry is never saved again under the same name). Cargo rebuilds a local crate when one of its sources is newer
than its last build, and a fresh checkout gives every file the checkout's time. So each entry carries the commit it
was built from (`runtime/target/.drgnx-built-from`, written before the save, and only when every step of the job
before it passed: after a failed step some outputs may be older than their sources, so the commit the job restored
stays, or none, and the next run rebuilds all that changed since), and after the restore
`.github/ci/commit-times.sh` gives each tracked file its last commit's time. A file that differs from that commit keeps
the checkout's time: its last commit can be older than the cached build (a branch committed before `main`'s run), and
it must still rebuild. Untracked files keep theirs too. The checkouts fetch the whole history for it (`fetch-depth: 0`,
`filter: blob:none`, so no old file contents: about 1 MB and 5 s). Only the crates that changed since the cache's
commit, and the crates above them, rebuild: with one integration test of `drgnx-ratatoskr` changed, only
`drgnx-ratatoskr` compiles, against all 13 local crates without it. An entry is saved once per key, so its commit ages
until the lock or the toolchain moves, and more crates rebuild as `main` moves on. Before a save,
`.github/ci/cargo-prune.sh` drops the top-level copies of the binaries (but `build-test-bins` keeps them for the upload;
cargo copies them out of `deps/` again), incremental data (CI builds with `CARGO_INCREMENTAL=0`) and the registry's
unpacked sources. It never fails a job: what it cannot work out it leaves, with a warning. A job saves at its
end when its build passed, whatever its tests said (a red test keeps the build), and only when its key was not
already there. Who saves (`CACHE_SAVE` and `CACHE_SAVE_PR` in `runtime.yml`, and the actions' own conditions): `main`
first, with every family (its pushes, manual runs and the daily run); a pull request from a branch of this repository
only the families that pay off: `runtime.yml`'s `linux` and `macos` (the slowest Rust jobs), `build-test-bins` (the
tiers wait for it) and the test ELPA. Its other jobs restore `main`'s and rebuild only what changed. `ci/*` branches
and a fork's pull requests only restore, so an untrusted change never writes what a trusted run reads, and neither does
a `drgnx_ref` another repository's run names. GitHub scopes a pull request's entries to its merge ref (it reads its own
and `main`'s, and `main` never reads them), and the fuzz corpora are grown by the daily run and `main` only. A pull
request whose lock matches `main`'s restores `main`'s entry under the exact key and saves nothing. CI builds
with line tables only (`CARGO_PROFILE_DEV_DEBUG=line-tables-only`: backtraces keep file and line), which halves the
kept build: the `linux` job's test build is 2.6 GB on disk and 0.6 GB compressed, against 5.3 GB and 1.1 GB with full
debug info. The registry is one entry per OS and lock, not a copy in each job's entry, and a pull request whose lock
is `main`'s finds `main`'s and saves none. The expected sizes (compressed, from that measurement and the entries of
2026-11-05): `main` about 4.5–5 GB (`linux` ~0.9, `macos` ~0.8, the four escape legs ~1.4, `agent-containers`, `msrv`,
`android` ~0.7 together, the test binaries ~0.55, `fuzz` ~0.45, the registries ~0.3); a pull request about 2.3 GB
(`linux`, `macos` and the test binaries; 0.3 GB more when it changes the lock). `main` plus one pull request is then
about 7–7.5 GB, inside the repository's 10 GB. More inputs
in a corpus only reach further: no corpus turns a crash into a pass. GitHub evicts the least recently used entries
first, so a finished pull request's go before `main`'s, which every run reads.

Deliberately not cached:

- **Byte-compile, native-compile (`.eln`) and test temp state.** The lints and the byte-compile test are tests: a cached
  `.elc` or `.eln` would let a stale file stand in for compiling the current source. The trampolines a run compiles
  (`DRGNX_TEST_ELN_DIR`) are per run and tiny.
- **ELPA packages, `drgnx sync`, tree-sitter grammars.** Not used by the CI suites (above). Where they are (`drgnx test
  --bootstrap` and the macOS `install` job, both weekly), the point is a fresh machine, and a `actions/cache` entry
  not read for 7 days is evicted, which a weekly job never beats ([GitHub's cache rules](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)). drgnx's own package cache
  (`cache/packages`) is checked against the lock's sha256 on every use, so it would be safe to add if a job ever needs it.
- **Homebrew on macOS.** `brew install ripgrep` and Nidhogg's Homebrew dependencies are a short step on the runner,
  and a download cache of them (Nidhogg's, 775 MB) saved under a minute: not worth its share of the 10 GB. Rust
  comes from the image's `rustup`.
- **Image layers of `Test images`.** It builds with `--pull=always` on purpose (the weekly run is the refresh).

A new `actions/cache` step needs a `key` with `hashFiles(...)` of its inputs (a save takes its restore's
`cache-primary-key`) and `restore-keys` only where a partial match cannot change a result (cargo's, with the toolchain
in it; the corpora); `drgnx-ci/every-actions-cache-key-hashes-its-inputs` checks it,
`drgnx-ci/no-fork-pull-request-writes-a-cache` the saves' conditions,
`drgnx-ci/a-restored-target-sees-unchanged-files-as-old` the commit times, and
`drgnx-ci/prebuilt-images-are-addressed-by-their-containerfile-hash` and `drgnx-ci/an-image-tag-hashes-every-file-it-copies`
check the image tags, `drgnx-ci/images-are-published-only-by-main-and-manual-runs` who publishes them.

## Rules for workflows

- Actions are pinned by commit hash with the version in a comment; Dependabot (`.github/dependabot.yml`) proposes
  updates weekly.
- `permissions: contents: read` and `persist-credentials: false`: no workflow can write to the repository. Only
  `Test images` may write packages (and the `images` job that calls it, never on a fork's pull request); the test jobs
  may read them. None uses a secret beyond the built-in token.
- The GUI, scenario and perf jobs run on every push to `main` or `ci/*` (not on pull requests); the terminal tier is nightly, the macOS real install and the second-machine exit test weekly; `drgnx test --install` (source
  builds in fresh containers) runs locally. The Emacs install step of each workflow is one step (the image pull, Homebrew's `brew install`), so one change swaps it.
