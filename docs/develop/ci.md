# Continuous integration

GitHub Actions runs the same commands you run locally; nothing in CI is CI-only.

| Workflow | When | What |
|---|---|---|
| `CI` (`.github/workflows/ci.yml`) | every push to `main`, every pull request, on demand | the unit suite on **Emacs 31.1** (Fedora 45, `bin/drgnx test --container`) and **Emacs 30.2** (Ubuntu 26.04, `bin/drgnx test`); `shellcheck --severity=warning` on `install.sh`, `bin/drgnx` and the pre-commit hook; the leak scan |
| `GUI tier` (`.github/workflows/gui.yml`) | nightly, on demand | `bin/drgnx test --container --ui`: real Emacs 31.1 (pgtk) sessions under headless mutter |
| `Test images` (`.github/workflows/images.yml`) | a push changing `test/container/`, weekly, on demand | builds the two Fedora test images and pushes them to `ghcr.io/black-dragon-foundation/drgnx-test` and `drgnx-test-gui`, tagged with the Containerfile's hash (and `f45`) |

The unit suite includes formatting (`bin/drgnx fmt`), the byte-compile with no warnings and the lints, so they
need no jobs of their own. Tests that need what an Emacs build lacks skip themselves (for example the Work
graph tests on an Emacs without SVG), so the two Emacs jobs skip different tests.

## Reproduce a job locally

```
bin/drgnx test --container          # the Emacs 31.1 job (podman, docker or nerdctl)
bin/drgnx test --container --ui     # the nightly GUI tier
.githooks/pre-commit --all          # the leak scan over every tracked file
```

`DRGNX_CONTAINER=podman` names the container runtime without asking a host Emacs (CI has none).

## Prebuilt images (the cache)

Installing Emacs and the GUI stack into Fedora took about a minute per job, so the images are built once by
`Test images` and pulled. A job pulls the image tagged with the hash of the Containerfile it checked out; when
there is none yet (the push that changes the Containerfile), it builds the image itself, so a job never runs on
an image from another Containerfile. `bin/drgnx test --container` uses `DRGNX_TEST_IMAGE` (and `--ui`
`DRGNX_TEST_GUI_IMAGE`) instead of building when set — locally too:

```
DRGNX_TEST_IMAGE=ghcr.io/black-dragon-foundation/drgnx-test:f45 bin/drgnx test --container
```

The weekly rebuild picks up Fedora's updates under the same tags. The Ubuntu job installs its three packages
directly (about 18 s — less than restoring a cache).

## Rules for workflows

- Actions are pinned by commit hash with the version in a comment; Dependabot (`.github/dependabot.yml`) proposes
  updates weekly.
- `permissions: contents: read` and `persist-credentials: false`: no workflow can write to the repository. Only
  `Test images` may write packages; the test jobs may read them. None uses a secret beyond the built-in token.
- Heavy tiers stay out of the per-push run: the GUI tier is nightly; `drgnx test --install` (source builds in
  fresh containers) and `--perf` (needs a quiet machine) run locally.
