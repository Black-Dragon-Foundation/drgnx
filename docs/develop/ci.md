# Continuous integration

GitHub Actions runs the same commands you run locally; nothing in CI is CI-only.

| Workflow | When | What |
|---|---|---|
| `CI` (`.github/workflows/ci.yml`) | every push to `main`, every pull request, on demand | the unit suite on **Emacs 31.1** (Fedora 45, `bin/drgnx test --container`) and **Emacs 30.2** (Ubuntu 26.04, `bin/drgnx test`), its files in parallel and then the `:timing` tests alone ([Parallel files](#parallel-files)); `shellcheck --severity=warning` on `install.sh`, `bin/drgnx` and the pre-commit hook; the leak scan |
| `GUI tier` (`.github/workflows/gui.yml`) | nightly, on demand | `bin/drgnx test --container --ui`: real Emacs 31.1 (pgtk) sessions under headless mutter |
| `Terminal tier` (`.github/workflows/tty.yml`) | nightly, on demand | `bin/drgnx test --container --tty --fedora 44` and `45`: the terminal tests (Emacs in tmux) on Emacs 30.2 and 31.1 |
| `Bootstrap` (`.github/workflows/bootstrap.yml`) | weekly (Monday), on demand with a Fedora release (45 by default, 44 builds Emacs from source) | `bin/drgnx test --bootstrap --fedora N`: the exit test of a second machine — `install.sh --yes --config … --identity …` in a fresh Fedora container reaches a green doctor with the configuration, the locked packages and the provider keys back, and a second run changes nothing ([harness.md](harness.md)) |
| `macOS` (`.github/workflows/macos.yml`) | `unit`: every push to `main`, every pull request, on demand; `install`: weekly (Wednesday), on demand | on macOS 27 (`xcode-27`, Apple silicon: GitHub names macOS images after their Xcode now): `unit` installs Emacs and ripgrep with Homebrew, checks that `install.sh` parses under macOS's bash 3.2 (`/bin/bash -n`), prints its plan (`--dry-run`) and runs `bin/drgnx test` the same way ([Parallel files](#parallel-files)); `install` runs `install.sh --yes` for real on the checkout (Homebrew's emacs-plus), then `drgnx doctor`, `drgnx sync` (a first sync from the shipped lock), `drgnx macos-app` and `drgnx open --check`. A newer run cancels an older one of the same event and ref only, so a push to `main` never cancels the weekly install |
| `Test images` (`.github/workflows/images.yml`) | a push changing `test/container/`, weekly, on demand | builds the two Fedora test images and pushes them to `ghcr.io/black-dragon-foundation/drgnx-test` and `drgnx-test-gui`, tagged with the Containerfile's hash (and `f45`) |

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
compilation is optional (Homebrew's Emacs has none). A test of a Linux-only branch pins the system too: `system-type`
in Lisp, a fake `uname` on the fake PATH or `DRGNX_UPDATE_PLATFORM` for `bin/drgnx`. Shell scripts and the snippets
tests run run under macOS's `/bin/bash` 3.2: no `source <(…)` (it sources nothing; `eval "$(…)"` works), and a
variable before a non-ASCII character takes braces (`${name}…`: macOS's bash reads `$name…` as an unknown variable;
`drgnx-bin/no-shell-variable-runs-into-a-non-ascii-character` checks it).

The two Emacs versions differ too. Emacs 31's ERT no longer loads bytecomp, so code that let-binds
`byte-compile-warnings` (or any variable of a library not loaded yet) requires the library first: bound before, the
variable is lexical and loading the library fails. Emacs 31 rejects a wall timer's `:repeat t` (30 ran it once):
a repeat is a number of seconds. Ubuntu's `emacs-nox` has no image functions (`image-flush` is declared, not
assumed), and without a UTF-8 locale Emacs quotes messages `like this', so a test matches either quote. On Linux,
`TMPDIR` set to a symlinked or long directory shows most of these before macOS CI does; `LC_ALL=en_US.iso88591` shows
the `$name…` one.

Nor does a test assume a desktop's environment. The Ubuntu job runs as root, in the C locale, with uutils' coreutils
and no tree-sitter grammars: a test that looks at glyphs pins the ASCII predicate it means (`drgnx-face--ascii-frame-p`,
`drgnx-cockpit-graph--ascii-p`) or reads Emacs's own `truncate-string-ellipsis` (`...` in the C locale); a test of a
read-only file skips as root; a tree-sitter mode without its grammar is not checked; a lock never rests on `mkdir`
alone (uutils' lets two racing commands both make the directory); and a test's flymake backend runs with
`trusted-content` bound to `:all` (Emacs 31 runs backends only in trusted buffers). `LANG=C bin/drgnx test` shows the
locale's share locally.

## Parallel files

Each unit-suite job (Emacs 31.1, Emacs 30.2, macOS) runs the suite in two steps:

1. Every test but the `:timing` ones (`DRGNX_TEST_SELECTOR='(not (tag :timing))'`) with `DRGNX_TEST_JOBS` set to
   the runner's cores (`nproc` on Linux: 4 on `ubuntu-24.04`, 16 GB; `sysctl -n hw.ncpu` on macOS: 3, 7 GB; three
   files at once, the slowest among them, peaked at about 1 GB together). That many test files run at once, each in
   an Emacs of its own as always; a file's output is printed whole when it ends, after a `drgnx: FILE` line, and the
   summary at the end lists every unexpected result. One file at a time, the Emacs 31.1 job took 785 s, 733 of them
   inside tests; three at a time, 30 of the slowest files took 160 s instead of 427.
2. Then the `:timing` tests (`DRGNX_TEST_SELECTOR='(tag :timing)'`), which hold wall-clock budgets, with nothing
   else running, a file at a time: the selector `bin/drgnx check` uses for its `unit-timing` job
   ([check.md](check.md)).

The two selectors take every test exactly once. The second step runs even when the first failed (`if:
${{ !cancelled() }}`), so one run shows both; either failing fails the job. `bin/drgnx test --container` passes
`DRGNX_TEST_JOBS` and the selector into the container. `DRGNX_TEST_TIME_FACTOR` (macOS) is set for the second step
only: only `:timing` tests read it.

Unlike `check`'s `unit-timing` job, the second step does not load every file into one Emacs
(`DRGNX_TEST_ONE_PROCESS=1`): there a timing test that scans drgnx's symbols
(`drgnx-fingerprint/the-first-scan-of-drgnx-symbols-costs-under-20-ms`) scans every test file's too and misses its
budget. A file at a time, each timing test sees what it sees in a plain `bin/drgnx test`; the price is an Emacs start
for every file, most of which then run no test.

The same locally (the Emacs 30.2 job's steps):

```
DRGNX_TEST_JOBS=4 DRGNX_TEST_SELECTOR='(not (tag :timing))' bin/drgnx test
DRGNX_TEST_SELECTOR='(tag :timing)' bin/drgnx test
```

## Reproduce a job locally

```
bin/drgnx test --container          # the Emacs 31.1 job in one step (podman, docker or nerdctl; see "Parallel files")
bin/drgnx test --container --ui     # the nightly GUI tier
bin/drgnx test --container --tty --fedora 44   # the nightly terminal tier (44: Emacs 30.2, 45: Emacs 31.1)
bin/drgnx test --bootstrap          # the weekly second-machine exit test (fedora:45; --fedora 44 for the source build)
.githooks/pre-commit --all          # the leak scan over every tracked file
```

`DRGNX_CONTAINER=podman` names the container runtime without asking a host Emacs (CI has none).

## Prebuilt images (the cache)

Installing Emacs and the GUI stack into Fedora took about a minute per job, so the images are built once by
`Test images` and pulled. A job pulls the image tagged with the hash of the Containerfile it checked out; when
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

## Rules for workflows

- Actions are pinned by commit hash with the version in a comment; Dependabot (`.github/dependabot.yml`) proposes
  updates weekly.
- `permissions: contents: read` and `persist-credentials: false`: no workflow can write to the repository. Only
  `Test images` may write packages; the test jobs may read them. None uses a secret beyond the built-in token.
- Heavy tiers stay out of the per-push run: the GUI tier is nightly, the macOS real install and the second-machine exit test weekly; `drgnx test --install` (source
  builds in fresh containers) and `--perf` (needs a quiet machine) run locally.
