# Continuous integration

GitHub Actions runs the same commands you run locally; nothing in CI is CI-only.

| Workflow | When | What |
|---|---|---|
| `CI` (`.github/workflows/ci.yml`) | every push to `main`, every pull request, on demand | the unit suite on **Emacs 31.1** (Fedora 45, `bin/drgnx test --container`) and **Emacs 30.2** (Ubuntu 26.04, `bin/drgnx test`); `shellcheck --severity=warning` on `install.sh`, `bin/drgnx` and the pre-commit hook; the leak scan |
| `GUI tier` (`.github/workflows/gui.yml`) | nightly, on demand | `bin/drgnx test --container --ui`: real Emacs 31.1 (pgtk) sessions under headless mutter |
| `Terminal tier` (`.github/workflows/tty.yml`) | nightly, on demand | `bin/drgnx test --container --tty --fedora 44` and `45`: the terminal tests (Emacs in tmux) on Emacs 30.2 and 31.1 |
| `Bootstrap` (`.github/workflows/bootstrap.yml`) | weekly (Monday), on demand with a Fedora release (45 by default, 44 builds Emacs from source) | `bin/drgnx test --bootstrap --fedora N`: the exit test of a second machine — `install.sh --yes --config … --identity …` in a fresh Fedora container reaches a green doctor with the configuration, the locked packages and the provider keys back, and a second run changes nothing ([harness.md](harness.md)) |
| `macOS` (`.github/workflows/macos.yml`) | `unit`: every push to `main`, every pull request, on demand; `install`: weekly (Wednesday), on demand | on macOS 27 (`xcode-27`, Apple silicon: GitHub names macOS images after their Xcode now): `unit` installs Emacs and ripgrep with Homebrew, checks that `install.sh` parses under macOS's bash 3.2 (`/bin/bash -n`), prints its plan (`--dry-run`) and runs `bin/drgnx test`; `install` runs `install.sh --yes` for real on the checkout (Homebrew's emacs-plus), then `drgnx doctor`, `drgnx sync` (a first sync from the shipped lock), `drgnx macos-app` and `drgnx open --check`. A newer run cancels an older one of the same event and ref only, so a push to `main` never cancels the weekly install |
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
prompts pins `drgnx-platform`; only tools the system has are linked into a fake PATH (macOS has no `setsid`), and only
POSIX options are used (no `timeout`, `dd iflag=`, GNU grep's `--exclude`); a test puts back the mode tables it
changes (`major-mode-remap-alist`: Emacs 31 asks to install a missing grammar, which in batch reads stdin); native
compilation is optional (Homebrew's Emacs has none). On Linux, `TMPDIR` set to a symlinked or long directory shows
most of these before macOS CI does.

## Reproduce a job locally

```
bin/drgnx test --container          # the Emacs 31.1 job (podman, docker or nerdctl)
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
