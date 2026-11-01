;;; preflight-test.el --- bin/drgnx test --preflight -*- lexical-binding: t -*-
;; test-class: det
;; The runner of each pre-flight step is a stub script (DRGNX_PREFLIGHT_RUNNER), so no container starts.
(require 'ert)
(require 'seq)
(require 'drgnx-paths)

(defun drgnx-preflight-test--run (stub-body &optional env args)
  "Run `bin/drgnx test --preflight' with a stub runner whose body is STUB-BODY (it first prints a run summary of
$PF_TESTS, default 3, tests); ENV (\"K=V\" strings) goes first, ARGS after the options; return (EXIT . STAMP-TEXT-OR-NIL)."
  (let* ((dir (make-temp-file "drgnx-preflight" t))
         (stub (expand-file-name "runner" dir))
         (out (expand-file-name "report" dir)))
    (unwind-protect
        (progn
          (with-temp-file stub (insert "#!/bin/sh\n"
                                       "echo \"drgnx: 1 test files, each in an Emacs of its own: ${PF_TESTS:-3} tests, ${PF_TESTS:-3} as expected, 0 unexpected (1 s)\"\n"
                                       stub-body "\n"))
          (set-file-modes stub #o755)
          (let* ((process-environment (append env
                                              (list (concat "DRGNX_PREFLIGHT_RUNNER=" stub)
                                                    "DRGNX_TEST_CHAOS_IMAGE=stub-image" "DRGNX_LEASE=off")
                                              process-environment))
                 (exit (apply #'call-process (expand-file-name "bin/drgnx" drgnx-dir) nil nil nil
                              "test" "--preflight" "--out" out "--seeds" "1" args)))
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

(ert-deftest drgnx-preflight/p1-runs-the-det-files-with-the-audit-failing-and-p2-does-not ()
  (let* ((log (make-temp-file "drgnx-pf-log"))
         (process-environment (cons (concat "PF_LOG=" log) process-environment)))
    (unwind-protect
        (progn
          (drgnx-preflight-test--run
           "echo \"$DRGNX_TEST_SELECTOR|$DRGNX_TEST_AUDIT|$DRGNX_TEST_AUDIT_FAIL|$DRGNX_TEST_PODMAN_ARGS\" >> \"$PF_LOG\"")
          (let ((lines (with-temp-buffer (insert-file-contents log) (split-string (buffer-string) "\n" t))))
            (should (equal (seq-filter (lambda (l) (string-prefix-p "(tag :det)|" l)) lines)
                           '("(tag :det)|1|1|" "(tag :det)|1|1|")))
            (dolist (l (seq-remove (lambda (l) (string-prefix-p "(tag :det)|" l)) lines))
              (should-not (string-match-p "|1|1|" l)))))
      (delete-file log))))

(ert-deftest drgnx-preflight/a-pass-that-ran-no-test-is-red-and-writes-no-stamp ()
  ;; every step ran zero tests (no class line yet, a selector that matches nothing)
  (let ((r (drgnx-preflight-test--run "exit 0" '("PF_TESTS=0"))))
    (should-not (eql 0 (car r)))
    (should-not (cdr r)))
  ;; only P3 ran zero tests
  (let ((r (drgnx-preflight-test--run
            "case \"$DRGNX_TEST_IMAGE\" in stub-image) echo 'drgnx: 1 test files, each in an Emacs of its own: 0 tests, 0 as expected, 0 unexpected (1 s)';; esac; exit 0")))
    (should-not (eql 0 (car r)))
    (should-not (cdr r))))

(ert-deftest drgnx-preflight/the-chaos-image-comes-from-det-image-sh-s-last-line ()
  ;; tooling/det-image.sh TARBALL NAME prints noise, then DRGNX_TEST_IMAGE=IMAGE; P3 runs on that image
  (let* ((dir (make-temp-file "drgnx-detimg" t))
         (script (expand-file-name "det-image.sh" dir))
         (log (expand-file-name "images" dir)))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "#!/bin/sh\necho \"no remote: building the base\"\n[ \"$2\" = preflight ] || exit 3\n"
                    "echo \"Nidhogg 31.0\"\necho \"DRGNX_TEST_IMAGE=localhost/drgnx-test-$2:run\"\n"))
          (set-file-modes script #o755)
          (let ((r (drgnx-preflight-test--run
                    (format "echo \"$DRGNX_TEST_IMAGE\" >> %s; exit 0" log)
                    (list "DRGNX_TEST_CHAOS_IMAGE=" (concat "DRGNX_DET_IMAGE=" script))
                    '("--nidhogg-tarball" "t.tar.xz"))))
            (should (eql 0 (car r)))
            (should (member "localhost/drgnx-test-preflight:run"
                            (with-temp-buffer (insert-file-contents log) (split-string (buffer-string) "\n" t))))))
      (delete-directory dir t))))

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
