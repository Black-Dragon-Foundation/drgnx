# Continuous integration

GitHub Actions runs the same commands you run locally; nothing in CI is CI-only.

| Workflow | When | What |
|---|---|---|
| `CI` (`.github/workflows/ci.yml`) | every push to `main`, every pull request, on demand | the `runtime` job (calls `runtime.yml`, below: a `needs:` cannot reach another workflow file); then the unit suite on **Nidhogg 31.1** (drgnx's own Emacs build, from its release tarball; Fedora 45, `bin/drgnx test --container`) against the `ratatoskr` artifact that call built in the same run (`DRGNX_RATATOSKR_BIN`; the tests that need it fail rather than skip, `test/no-skip.eld`; the job runs whatever the other runtime jobs say, `if: !cancelled()`, so a red macOS escape row never skips it, and a missing artifact fails its download), its files in parallel, a failed file rerun once, the `:timing` tests left out by name ([Parallel files](#parallel-files)); `shellcheck --severity=warning` on `install.sh`, `bin/drgnx` and the pre-commit hook; the leak scan |
| `GUI tier` (`.github/workflows/gui.yml`) | every push to `main`, nightly, on demand | real Emacs 31.1 (pgtk) sessions under headless mutter, three jobs: `ui` (`bin/drgnx test --container --ui`, `DRGNX_TEST_NO_TIMING=1`: the GUI and live tiers, the `:timing` tests left out), `scenario` (`--container --scenario`, `DRGNX_TEST_NO_TIMING=1`: the frame budget is reported, not judged) and `perf` (`--container --perf`, `DRGNX_PERF_CPU_FACTOR=2`, `DRGNX_PERF_RESULTS=perf-results.json` uploaded as the `perf-results` artifact, also when the run fails). A newer push cancels an older run of the same ref |
| `Terminal tier` (`.github/workflows/tty.yml`) | nightly, on demand | `bin/drgnx test --container --tty --fedora 45`: the terminal tests (Emacs in tmux) on Emacs 31.1 |
| `Bootstrap` (`.github/workflows/bootstrap.yml`) | weekly (Monday), on demand with a Fedora release (45 by default, or 44; the pinned Nidhogg release is unpacked first, so no build) | `bin/drgnx test --bootstrap --fedora N`: the exit test of a second machine — `install.sh --yes --config … --identity …` in a fresh Fedora container reaches a green doctor with the configuration, the locked packages and the provider keys back, and a second run changes nothing ([harness.md](harness.md)) |
| `Runtime` (`.github/workflows/runtime.yml`) | called by `ci.yml` (so on every push to `main` and every pull request); daily; on demand | the Rust workspace in `runtime/` ([runtime.md](runtime.md)). `linux` (Fedora 45, as root): `cargo fmt --check`, `clippy -D warnings`, `cargo test --locked --workspace` with `drgnx-ratatoskr/test-hooks`; it uploads that `ratatoskr` as the `ratatoskr` artifact; installs Nidhogg and runs the conformance suite with `--require-all` (the `v0` rows against the Lisp hub, then every row against Ratatoskr in front of the Lisp backend and the fake backend; as root the `sudo` rows run, so `security/another-uid-is-refused` is not skipped); a release build whose `version --json` must say `"test_hooks":false`; the perf baseline (`--perf`, artifact `ratatoskr-perf-linux`). `macos` (macOS 27, `brew install rust`): the same tests and conformance as the runner user, the `sudo` rows through passwordless `sudo -n -u nobody` (`--require-all` fails if that row is skipped), the perf baseline (`ratatoskr-perf-macos`), and last, whatever the steps before it said, `clippy --all-targets -D warnings` on the four pure-Rust crates (only clippy's test build shows code that is dead on macOS). The Gleipnir escape suite ([gleipnir.md](gleipnir.md), "Proving it") runs in three places. `linux` (the container, as root, `--init`): builds `gleipnir-probe` and `gleipnir-escape`, fails if `cargo tree -e features -i gleipnir -p drgnx-ratatoskr` shows `test-hooks` in a default build (under `bash` with `pipefail`, and the tree must name gleipnir, so a failed `cargo tree` never passes), and runs `--rows rows --rows rows/container` without `--require-all` (the full-tier rows skip there with "inside a container", and the reduced rows with "Landlock ABI N below 9" if the runner's kernel is older; what runs is that every row parses, the probes reach with no sandbox, `check-in-a-container`, and the floor and fail-closed rows); report `escape-report-container`. `macos`: the Seatbelt rows and `rows/any` (no row there needs Linux: a unit test holds it) for real with `/usr/bin/sandbox-exec`, `--require-all` (a skip fails the job), as the job's last step so a failing row never skips its conformance and perf steps, xcode-select pointed at the Command Line Tools when the runner has them (draugr refuses Xcode under `/Applications`); report `escape-report-macos`. `escape-host` (`ubuntu-24.04` and `ubuntu-24.04-arm`, no container): Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor, so the job runs `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (the runner user has passwordless sudo) and builds bubblewrap 0.12.0 (gleipnir's floor; apt has 0.9.0) from its checksummed release tarball; then `cargo test` for `gleipnir`, `draugr`, `eitri` and `gleipnir-escape` (the arm64 run is the first real one on arm64 Linux, for the seccomp call numbers) and `--rows rows/linux --rows rows/any` without `--require-all`, because the runner kernel's Landlock ABI is probably below 9 (the reduced rows skip with "Landlock ABI N below 9"; only listed reasons may skip). The job is `continue-on-error` until a first real run shows which rows that kernel holds; reports `escape-report-host-X64` and `-ARM64`. The 60-row full run with `--require-all` stays on the escape VM (`gleipnir-vm.sh run`). `android` type-checks `runstav`, `draugr`, `eitri`, `gleipnir` and `drgnx-ratatoskr` for `aarch64-linux-android` (a fake C compiler stands in for urdr's bundled SQLite; nothing links), then runs `clippy --all-targets -D warnings` there on the four pure-Rust crates (only clippy's test build shows code that is dead on Android). `msrv` (Rust 1.88.0, `cargo build --locked`). `deny` (cargo-deny 0.20.2, its checksum verified: advisories, licenses, bans, sources). `fuzz` (nightly-2026-10-15, cargo-fuzz 0.13.2, the runner's g++): 60 s a target on a push to `main`, 10 minutes a target daily, `fuzz_minutes` a target on demand, none on a pull request; a crash uploads its input as `fuzz-crashes`. The daily run is `deny` and `fuzz`: advisories land with no change on our side. The cargo registry and `target/` are cached with `actions/cache`, keyed on `Cargo.lock` and the job's OS and toolchain |
| `macOS` (`.github/workflows/macos.yml`) | `unit`: every push to `main`, every pull request, on demand; `install`: weekly (Wednesday), on demand | on macOS 27 (`xcode-27`, Apple silicon: GitHub names macOS images after their Xcode now): `unit` installs ripgrep and Rust with Homebrew, builds Ratatoskr with its test hooks (`DRGNX_RATATOSKR_BIN` for the client's tests; some need `--idle-tick-ms`) and installs Nidhogg from its release tarball (`test/container/nidhogg.sh macos`, which sets `DRGNX_EMACS`), checks that `install.sh` parses under macOS's bash 3.2 (`/bin/bash -n`), prints its plan (`--dry-run`) and runs `bin/drgnx test` the same way ([Parallel files](#parallel-files)), with no time factor (CI runs no `:timing` test); `install` (timeout 180 minutes: it builds Nidhogg) runs `install.sh --yes` for real on the checkout, then `drgnx doctor`, `drgnx sync` (a first sync from the shipped lock), `drgnx macos-app` and `drgnx open --check`. A newer run cancels an older one of the same event and ref only, so a push to `main` never cancels the weekly install |
| `Test images` (`.github/workflows/images.yml`) | a push changing `test/container/`, weekly, on demand | builds the three Fedora test images and pushes them to `ghcr.io/black-dragon-foundation/drgnx-test`, `drgnx-test-gui` and `drgnx-test-tty`, tagged with the Containerfile's hash (and `f45`) |

The unit suite includes formatting (`bin/drgnx fmt`), the byte-compile with no warnings and the lints, so they
need no jobs of their own. Tests that need what an Emacs build lacks skip themselves (for example the Work
graph tests on an Emacs without SVG), so the two Emacs jobs skip different tests.

The macOS workflow has no GUI tier: the GUI tests (`--ui`) stay Linux-only (they run under headless mutter), so the
Mac UI is checked by hand with the session checklist. The weekly `install` job is a real install on a fresh runner
(it installs Emacs with Homebrew); it stays out of the per-push run.

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

## Parallel files

Each unit-suite job (Emacs 31.1, macOS) runs the suite in one step: `DRGNX_TEST_JOBS` is the runner's cores
(`nproc` on Linux: 4 on `ubuntu-24.04`, 16 GB; `sysctl -n hw.ncpu` on macOS: 3, 7 GB), `DRGNX_TEST_RERUN=1` reruns a
failed file once (a file that fails and then passes is reported as a flake, not a failure) and `DRGNX_TEST_NO_TIMING=1`
leaves out the tests tagged `:timing` (wall-clock assertions) and lists them as skipped. That many test files run at
once, each in an Emacs of its own as always; a file's output is printed whole when it ends, after a `drgnx: FILE`
line, and the summary at the end lists every unexpected result.

No CI job runs a `:timing` test: a shared runner's clock judges nothing, so a budget in wall time lives where the
machine is quiet (`bin/drgnx check`'s `unit-timing` job, [check.md](check.md)) and, for the frame and the work in a
command, in the perf job (allocation, CPU time and counts; [perf.md](perf.md)). `bin/drgnx check` stays as the local
equivalent of the merge wave; no workflow runs it.

DEFERRED DET-CI-ENV-1: the step uses `DRGNX_TEST_NO_TIMING=1` rather than `(not (tag :timing))`, and
`test/no-skip.eld` has no darwin or Ubuntu rows until the first CI summaries list their skips.

The same locally (the Emacs 31.1 job's step, without the container):

```
DRGNX_TEST_JOBS=4 DRGNX_TEST_RERUN=1 DRGNX_TEST_NO_TIMING=1 bin/drgnx test
```

## Reproduce a job locally

```
bin/drgnx test --container          # the Emacs 31.1 job in one step (podman, docker or nerdctl; see "Parallel files")
bin/drgnx test --container --ui     # the GUI tier's ui job (--scenario, --perf: its other two)
bin/drgnx test --container --tty                # the nightly terminal tier (Fedora 45, Emacs 31.1)
bin/drgnx test --bootstrap          # the weekly second-machine exit test (fedora:45; --fedora 44 for the other release)
.githooks/pre-commit --all          # the leak scan over every tracked file
```

`bin/drgnx test --container` passes the run-control variables (`DRGNX_TEST_SELECTOR`, `_JOBS`, `_RERUN`, `_NO_TIMING`,
`DRGNX_PERF_RESULTS` through a mount, `_CPU_FACTOR`, `_WORKLOADS`, `DRGNX_UITEST_SETTLE_SCALE`) into the container and
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
(`drgnx-ci/nidhogg-pin-matches-install-sh`, `drgnx-ci/containerfiles-name-the-pinned-version`); the Containerfile
edit is what changes the image tag. `Containerfile.gui` keeps `emacs-lucid` for the X11/i3 sessions (Nidhogg has no X11
build; DEFERRED NIDHOGG-X11-1). A job pulls the image tagged with the hash of the Containerfile it checked out; when
there is none yet (the push that changes the Containerfile), it builds the image itself, so a job never runs on
an image from another Containerfile. `bin/drgnx test --container` uses `DRGNX_TEST_IMAGE` (and `--ui`
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

## What is cached

Measured on the runs of 2026-10-19/20 (`gh run view ID --json jobs`): the unit suite is 3.5–4 min on Linux and about
16 min on macOS, a GUI job 1.5–5.5 min, the image pull 18–28 s, `brew install emacs ripgrep` 8 s. Nothing in the unit
suite downloads: no ELPA package, no grammar, no `drgnx sync` (CI sets no `DRGNX_USER_ELPA` or `DRGNX_MODAL_ELPA`,
so the tests that need those packages skip). So the caches are few:

| What | Key | Saves | Bust it |
|---|---|---|---|
| the three test images (`Test images`, GHCR) | tag = first 16 hex of `sha256sum test/container/Containerfile{,.gui,.tty}` (and `f45`) | an install of Emacs and the GUI/terminal stack into Fedora per job: about 1.5–2 min (the tty tier now pulls instead of building every night) | edit the Containerfile, or run `Test images` by hand (the weekly run refreshes the tag with Fedora's updates) |

An image is addressed by the hash of the file it is built from, and a job whose hash has no image builds it itself, so
a job never runs on an image from another Containerfile; a cold cache (no image) gives the same result, only slower.

Deliberately not cached:

- **Byte-compile, native-compile (`.eln`) and test temp state.** The lints and the byte-compile test are tests: a cached
  `.elc` or `.eln` would let a stale file stand in for compiling the current source. The trampolines a run compiles
  (`DRGNX_TEST_ELN_DIR`) are per run and tiny.
- **ELPA packages, `drgnx sync`, tree-sitter grammars.** Not used by the CI suites (above). Where they are (`drgnx test
  --bootstrap` and the macOS `install` job, both weekly), the point is a fresh machine, and a `actions/cache` entry
  not read for 7 days is evicted, which a weekly job never beats ([GitHub's cache rules](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)). drgnx's own package cache
  (`cache/packages`) is checked against the lock's sha256 on every use, so it would be safe to add if a job ever needs it.
- **Homebrew and Nidhogg on macOS.** `brew install ripgrep` and Nidhogg's tarball (about 70 MB, plus its Homebrew
  dependencies) are a short step on the runner, less than restoring a cache.
- **Image layers of `Test images`.** It builds with `--pull=always` on purpose (the weekly run is the refresh).

A new `actions/cache` step needs a `key` with `hashFiles(...)` of its inputs and `restore-keys` only where a partial
match cannot change a result; `drgnx-ci/every-actions-cache-key-hashes-its-inputs` checks it, and
`drgnx-ci/prebuilt-images-are-addressed-by-their-containerfile-hash` checks the image tags.

## Rules for workflows

- Actions are pinned by commit hash with the version in a comment; Dependabot (`.github/dependabot.yml`) proposes
  updates weekly.
- `permissions: contents: read` and `persist-credentials: false`: no workflow can write to the repository. Only
  `Test images` may write packages; the test jobs may read them. None uses a secret beyond the built-in token.
- The GUI, scenario and perf jobs run on every push to `main` (not on pull requests); the terminal tier is nightly, the macOS real install and the second-machine exit test weekly; `drgnx test --install` (source
  builds in fresh containers) runs locally. The Emacs install step of each workflow is one step (the image pull, Homebrew's `brew install`), so one change swaps it.
