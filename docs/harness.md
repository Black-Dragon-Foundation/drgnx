# The drgnx harness

The harness lets people and agents run drgnx (or any Emacs configuration) in an **isolated, invisible GUI
Emacs session**, see it, drive it and measure it — without ever touching the Emacs you are working in. It is
how every drgnx UI change is developed and verified (see [roadmap.md](roadmap.md), "Test & control harness",
and [ADR 0004](decisions/0004-headless-ui-harness.md)).

## Test tiers

| Command | What runs | Where |
|---|---|---|
| `bin/drgnx test` | ERT suites in `test/unit/` (batch Emacs) and Python unit tests in `test/py/` | the host |
| `bin/drgnx test --podman` | the same, in a `fedora:45` container (Emacs 31.1, drgnx's baseline) | podman |
| `bin/drgnx test --ui` | GUI ERT suites in `test/ui/*-test.el` inside a headless session, then live session tests `test/ui/test_*.py` | the host (needs mutter) |

`harness/run-ert.el` runs a suite and writes a JSON summary
(`{"total","passed","failed","failures":[{"name","condition"}]}`) to `$DRGNX_TEST_RESULTS` when set; the
summary is the source of truth for GUI runs, whose exit status is only pass/fail.

A GUI run's ERT suite executes inside the session (`DRGNX_UI_TEST` names the suite directory), writes its
summary to `DRGNX_UI_RESULTS` and exits. mutter turns any nonzero Emacs exit code into `1`, so the runner
trusts the summary, not the code. The run is killed (whole process group) after `DRGNX_UI_TEST_TIMEOUT`
seconds (default 110) and never leaves mutter, dbus or Emacs processes behind.

## Sessions

A session is GUI Emacs (pgtk) under `mutter --headless` inside its own `dbus-run-session`, with a virtual
monitor (default 1600×900) and a Wayland display named after the session. Nothing is shown on your screen
and nothing talks to your own Emacs.

**Run directory** (`$XDG_STATE_HOME/drgnx/ui/<name>/`, override with `DRGNX_UI_STATE`):

```
session.json   name, socket, size, config
init/          generated early-init.el + init.el (the session's user-emacs-directory)
sock/          the session's server socket (mode 0700, or server-start silently refuses)
out/           screenshots in progress
ready.json     written once the frame is mapped: pid, socket, emacs version, init_error
```

**Isolation**, set up by `harness/init/prelude.el` before any configuration runs:

- Everything the session writes lands in its run directory (`user-emacs-directory`, eln cache). An external
  configuration is only read: code directories (`lisp/`, `extras/`, `site-lisp/`, `tree-sitter/`, `snippets/`,
  `themes/`) are linked, `custom.el` is copied, packages load from its `elpa/`; history, recentf, places and
  other state files are not brought in.
- No network and no installs: `url-retrieve*`, `package-install`/`-refresh-contents`/`-vc-install`/`-upgrade*`
  and `treesit-install-language-grammar` signal an error.
- No secrets: the environment is rebuilt from an allowlist (`HOME USER LOGNAME LANG LC_ALL PATH
  XDG_RUNTIME_DIR GRYPHN_EMACS_DIR` + `DRGNX_UI_*`), `auth-sources` is nil.
- Deterministic look: no startup screen, no blinking cursor, no bell, no dialog boxes.
- Safety: treemacs drag-to-move is off.
- Its own server: `server-name` = the session name, `server-socket-dir` = `sock/`, set before the
  configuration runs so any `server-start` in it uses the session's socket.

**Configurations:** `minimal` (stock Emacs, menu/tool/scroll bars off — `harness/init/minimal.el`), `gryphn`
(the gryphn layer's config directory, `$DRGNX_GRYPHN_CONFIG` or `~/.config/emacs`), or any directory with an
`init.el`. Emacs is launched with `--init-directory` and without `-Q` (which would skip the init file).
The Emacs binary is `$DRGNX_EMACS`, else `emacs-pgtk`, else `emacs`.
