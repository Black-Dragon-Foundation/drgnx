;;; preflight-test.el --- bin/drgnx test --preflight -*- lexical-binding: t -*-
;; The runner of each pre-flight step is a stub script (DRGNX_PREFLIGHT_RUNNER), so no container starts.
(require 'ert)
(require 'drgnx-paths)

(defun drgnx-preflight-test--run (stub-body)
  "Run `bin/drgnx test --preflight' with a stub runner whose body is STUB-BODY; return (EXIT . STAMP-TEXT-OR-NIL)."
  (let* ((dir (make-temp-file "drgnx-preflight" t))
         (stub (expand-file-name "runner" dir))
         (out (expand-file-name "report" dir)))
    (unwind-protect
        (progn
          (with-temp-file stub (insert "#!/bin/sh\n" stub-body "\n"))
          (set-file-modes stub #o755)
          (let* ((process-environment (append (list (concat "DRGNX_PREFLIGHT_RUNNER=" stub)
                                                    "DRGNX_TEST_CHAOS_IMAGE=stub-image" "DRGNX_LEASE=off")
                                              process-environment))
                 (exit (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil nil nil
                                     "test" "--preflight" "--out" out "--seeds" "1")))
            (cons exit (when (file-exists-p (concat out ".stamp"))
                         (with-temp-buffer (insert-file-contents (concat out ".stamp")) (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest drgnx-preflight/no-stamp-on-failure ()
  ;; a stub failing P2 (two CPUs)
  (let ((r (drgnx-preflight-test--run
            "case \"$DRGNX_TEST_PODMAN_ARGS\" in *--cpus=2*) echo '   FAILED  x/y'; exit 1;; esac; exit 0")))
    (should-not (eql 0 (car r)))
    (should-not (cdr r)))
  ;; one killed mid-run: its parent, the pre-flight, dies at P2
  (let ((r (drgnx-preflight-test--run
            "case \"$DRGNX_TEST_PODMAN_ARGS\" in *--cpus=2*) kill -KILL $PPID; sleep 1;; esac; exit 0")))
    (should-not (eql 0 (car r)))
    (should-not (cdr r))))

(ert-deftest drgnx-preflight/a-full-success-writes-the-stamp ()
  (let ((r (drgnx-preflight-test--run "exit 0")))
    (should (eql 0 (car r)))
    (should (string-match-p "\\`[^ ]+ [0-9]+ [0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\n\\'" (cdr r)))))

(ert-deftest drgnx-preflight/a-difference-between-the-two-det-runs-is-red ()
  (let ((r (drgnx-preflight-test--run
            "case \"$DRGNX_TEST_SHUFFLE\" in *-b) echo '   FAILED  x/y'; exit 1;; esac; exit 0")))
    (should-not (eql 0 (car r)))
    (should-not (cdr r))))

;;; preflight-test.el ends here
