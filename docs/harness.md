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
| `bin/drgnx test --ui` | GUI suites in a headless session (arrives with the session layer) | the host |

`harness/run-ert.el` runs a suite and writes a JSON summary
(`{"total","passed","failed","failures":[{"name","condition"}]}`) to `$DRGNX_TEST_RESULTS` when set; the
summary is the source of truth for GUI runs, whose exit status is only pass/fail.
