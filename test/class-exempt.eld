;;; class-exempt.eld --- test files that carry no class  -*- mode: lisp-data -*-
;; ((FILE [:off t] :why STRING) …): FILE is relative to the checkout.  A file here is never classified, linted for its
;; class, migrated or run by the pre-flight: the Lisp it tests is deleted or replaced by a plan (Ratatoskr P7 and P8),
;; frozen, or dead.  A row with `:off t' (the Lisp a plan deletes) is not run at all, CI included, unless
;; DRGNX_TEST_FROZEN=1 (harness/run-ert.el); the frozen UI's tests are tagged `:frozen' one by one (test/frozen.eld), and its keep-on guards run.
;; drgnx-lint/no-stale-exempt-rows fails a row whose file is gone (remove the row when the file goes);
;; drgnx-lint/every-test-has-a-class fails a file with neither a class line nor a row.
(
 ("test/unit/agents-ui-test.el" :why "frozen UI: the agent panel, cockpit, job window, review and Work UI are replaced")
 ("test/unit/job-ui-test.el" :why "frozen UI: the agent panel, cockpit, job window, review and Work UI are replaced")
 ("test/unit/mod-review-test.el" :why "frozen UI: the agent panel, cockpit, job window, review and Work UI are replaced")
 ("test/unit/work-ui-test.el" :why "frozen UI: the agent panel, cockpit, job window, review and Work UI are replaced")
 ("test/unit/compat-gryphn-test.el" :off t :why "gryphn is dead")
)
