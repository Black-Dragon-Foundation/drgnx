;;; ui-launcher-stub.el --- a stand-in session launcher for the per-file GUI runner's own tests -*- lexical-binding: t -*-
;; DRGNX_UI_LAUNCHER=this file: `drgnx-ui-run-ui-file-session' loads it and starts "sessions" through it instead of a
;; compositor and an Emacs.  Each takes a second, notes its start and end in $STUB_LOG, and reports 2 rows passed; a file
;; whose name matches $STUB_FAIL fails one.  It fails the file when the leak check is not asked for.
(require 'cl-lib)
(declare-function drgnx-ui--read-json "drgnx-ui")

(defun drgnx-ui-launcher-stub (_tests-dir _timeout _config extra-env)
  (let* ((file (cl-some (lambda (e) (and (string-prefix-p "DRGNX_UI_TEST_FILE=" e) (substring e (length "DRGNX_UI_TEST_FILE="))))
                        extra-env))
         (leaks (member "DRGNX_TEST_FILE_LEAKS=1" extra-env))
         (bad (or (not leaks) (and (getenv "STUB_FAIL") (string-match-p (getenv "STUB_FAIL") file))))
         (run (make-temp-file "stub-run" t))
         (results (expand-file-name "results.json" run))
         (t0 (float-time)))
    (sleep-for 1)
    (when (getenv "STUB_LOG")
      (let ((create-lockfiles nil)) (write-region (format "%s %.3f %.3f\n" (file-name-nondirectory file) t0 (float-time)) nil (getenv "STUB_LOG") t 'silent)))
    (with-temp-file results
      (insert (format "{\"total\":2,\"passed\":%d,\"failed\":%d,\"failures\":[%s],\"skipped\":[]}"
                      (if bad 1 2) (if bad 1 0)
                      (if bad (format "{\"name\":\"stub/row\",\"condition\":%S}" (if leaks "stub failure" "no leak check asked")) ""))))
    (list 0 (drgnx-ui--read-json results) run)))

(setq drgnx-ui-test-session-function #'drgnx-ui-launcher-stub)
(provide 'ui-launcher-stub)
