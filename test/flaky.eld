;;; flaky.eld --- tests the CI tolerates as flaky  -*- mode: lisp-data -*-
;; (NAME :reason STRING :stress STRING): NAME a test that failed once and passed on the rerun
;; (DRGNX_TEST_RERUN=1, harness/run-ert.el) and is listed here; the run prints `flaky (listed: REASON)' and passes.
;; :reason is the cause, :stress the stress run (command and result) that the commit adding the entry quotes:
;; `DRGNX_TEST_SELECTOR=… bin/drgnx test --stress N --load K'.  A flake without a cause is fixed, not listed.
;; drgnx-lint/flaky-entries-have-a-reason-and-a-stress-run checks every entry.
((drgnx-sandbox-relay/many-connections
  :reason "the Lisp relay listens with Emacs's default queue of 5; twenty connects at once overflow it when the relay accepts late (on one CPU every run does), and macOS answers an overflow with a reset (Linux retries the SYN).  Gleipnir's Rust relay (queue 1024) replaces it"
  :stress "DRGNX_TEST_SELECTOR='\"^drgnx-sandbox-relay/many-connections$\"' bin/drgnx test --stress 50 --load 16 (Linux container): 50 passed")
 (drgnx-remote/a-second-file-of-the-project-joins-the-running-server
  :reason "TRAMP returns a pipe process before its remote shell has read the exec line; eglot's initialize follows at once, and a shell that reads late reads those bytes with the line (bash reads a -icanon terminal in chunks) and drops them at the exec, so the server never answers (30 s).  The fix is in Nidhogg's TRAMP: wait until the shell has read the line"
  :stress "DRGNX_TEST_SELECTOR='\"^drgnx-remote/a-second-file-of-the-project-joins-the-running-server$\"' bin/drgnx test --stress 30 --load 16 (Linux container): 30 passed; with a slow shell emulated (tramp-pipe-stty-settings \"-icanon min 255 time 5\") all 6 tests of the file that start a server fail this way"))
