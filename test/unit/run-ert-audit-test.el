;;; run-ert-audit-test.el --- the audit's pattern checks, each on a minimal bad test in a child runner -*- lexical-binding: t -*-
;; test-class: cond
;; The audit (DRGNX_TEST_AUDIT=1, failing with DRGNX_TEST_AUDIT_FAIL=1) holds a :gated test to the delivery gate and a
;; :handshake test to parked children.  Each row runs a real runner (`drgnx-run-ert-batch', one Emacs for the file) on
;; a generated file that stubs the two hub functions the audit advises, and reads the results.  The :det rule's rows
;; are in lint-test-classes-test.el.  docs/develop/harness.md, "The audit".
(require 'ert)
(require 'json)
(require 'drgnx-run-ert)

(defconst drgnx-run-ert-audit-test--stubs
  '((defvar drgnx-test-gate--active nil)
    (defvar drgnx-test-gate--releasing nil)
    (defun drgnx-hub--client-filter (_conn _chunk) nil)
    (defun drgnx-hub--open (_events) nil)
    (defun drgnx-test-child-parked-p (proc) (and (process-get proc :parked) t)))
  "What a generated file defines in place of the hub client and the handshake fixture.")

(defun drgnx-run-ert-audit-test--file (pattern &rest tests)
  "A temp file of class `cond' and PATTERN (a word) with the stubs and TESTS, a list of (NAME BODY…); its directory."
  (let* ((dir (make-temp-file "drgnx-audit" t)) (file (expand-file-name "x-test.el" dir)))
    (with-temp-file file
      (insert ";; test-class: cond\n;; test-pattern: " pattern "\n")
      (dolist (f drgnx-run-ert-audit-test--stubs) (prin1 f (current-buffer)) (insert "\n"))
      (dolist (tst tests)
        (prin1 `(ert-deftest ,(car tst) () ,@(cdr tst)) (current-buffer)) (insert "\n")))
    dir))

(defun drgnx-run-ert-audit-test--run (dir &rest env)
  "Run the runner on DIR with ENV (strings) added; the results as a plist, and the exit code as :exit."
  (let* ((results (expand-file-name "r.json" dir))
         (process-environment
          (append env (list (concat "DRGNX_TEST_RESULTS=" results)
                            "DRGNX_TEST_SELECTOR" "DRGNX_TEST_SHUFFLE" "DRGNX_TEST_RERUN" "DRGNX_TEST_LEAKS"
                            "DRGNX_TEST_AUDIT" "DRGNX_TEST_AUDIT_FAIL" "DRGNX_TEST_AUDIT_ALL")
                  process-environment))
         (code (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                             "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                             "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" dir)))
    (append (list :exit code)
            (json-parse-string (with-temp-buffer (insert-file-contents results) (buffer-string)) :object-type 'plist))))

(defun drgnx-run-ert-audit-test--failures (j)
  "The (NAME . CONDITION) pairs of J's failures."
  (mapcar (lambda (f) (cons (plist-get f :name) (plist-get f :condition))) (plist-get j :failures)))

(defconst drgnx-run-ert-audit-test--on '("DRGNX_TEST_AUDIT=1" "DRGNX_TEST_AUDIT_FAIL=1"))

(ert-deftest drgnx-run-ert-audit/a-gated-test-that-saw-an-unreleased-line-fails ()
  (let* ((dir (drgnx-run-ert-audit-test--file
               "gated"
               '(x/unreleased (let ((drgnx-test-gate--active t)) (drgnx-hub--client-filter nil "{}\n")) (should t))
               '(x/released (let ((drgnx-test-gate--active t) (drgnx-test-gate--releasing 'call-1))
                              (drgnx-hub--client-filter nil "{}\n"))
                            (should t))))
         (j (apply #'drgnx-run-ert-audit-test--run dir drgnx-run-ert-audit-test--on)))
    (should-not (eql 0 (plist-get j :exit)))
    (should (equal '(("x/unreleased" . "gated test saw a hub line the gate did not release"))
                   (drgnx-run-ert-audit-test--failures j)))
    ;; the audit alone reports, and without it nothing is checked
    (should (eql 0 (plist-get (drgnx-run-ert-audit-test--run dir "DRGNX_TEST_AUDIT=1") :exit)))
    (should (eql 0 (plist-get (drgnx-run-ert-audit-test--run dir) :exit)))))

(ert-deftest drgnx-run-ert-audit/a-gated-test-that-opened-a-connection-outside-the-gate-fails ()
  (let* ((dir (drgnx-run-ert-audit-test--file
               "gated"
               '(x/outside (let ((drgnx-test-gate--active t)) nil) (drgnx-hub--open nil) (should t))
               '(x/inside (let ((drgnx-test-gate--active t)) (drgnx-hub--open nil)) (should t))))
         (j (apply #'drgnx-run-ert-audit-test--run dir drgnx-run-ert-audit-test--on)))
    (should (equal '(("x/outside" . "gated test opened a hub connection outside the gate"))
                   (drgnx-run-ert-audit-test--failures j)))))

(ert-deftest drgnx-run-ert-audit/a-gated-files-test-that-skips-the-gate-is-held-to-it-unless-listed ()
  ;; a test that never enters `drgnx-test-gated' is audited as one that does, unless test/gate-exempt.eld lists it
  (let* ((dir (drgnx-run-ert-audit-test--file
               "gated"
               '(x/no-gate (drgnx-hub--open nil) (should t))
               '(x/no-gate-line (drgnx-hub--client-filter nil "{}\n") (should t))
               '(x/listed (drgnx-hub--open nil) (should t))
               '(x/pure (should t))))
         (exempt (expand-file-name "gate-exempt.eld" dir)))
    (with-temp-file exempt (insert "((x/listed :why \"a fake hub\"))\n"))
    ;; the checkout's own register lists no test of this file: every test that talks to the hub fails
    (let ((j (apply #'drgnx-run-ert-audit-test--run dir drgnx-run-ert-audit-test--on)))
      (should (equal '(("x/listed" . "gated test opened a hub connection outside the gate")
                       ("x/no-gate" . "gated test opened a hub connection outside the gate")
                       ("x/no-gate-line" . "gated test saw a hub line the gate did not release"))
                     (sort (drgnx-run-ert-audit-test--failures j) (lambda (a b) (string< (car a) (car b)))))))
    ;; a listed one passes
    (let ((j (apply #'drgnx-run-ert-audit-test--run dir (concat "DRGNX_TEST_GATE_EXEMPT=" exempt)
                    drgnx-run-ert-audit-test--on)))
      (should (equal '("x/no-gate" "x/no-gate-line")
                     (sort (mapcar #'car (drgnx-run-ert-audit-test--failures j)) #'string<))))))

(ert-deftest drgnx-run-ert-audit/a-handshake-test-that-signalled-an-unparked-child-fails ()
  (let* ((dir (drgnx-run-ert-audit-test--file
               "handshake"
               '(x/unparked
                 (let ((p (make-process :name "x-cat" :command '("cat") :noquery t)))
                   (unwind-protect (signal-process p 'CONT) (delete-process p)))
                 (should t))
               '(x/parked
                 (let ((p (make-process :name "x-cat" :command '("cat") :noquery t)))
                   (process-put p :parked t)
                   (unwind-protect (signal-process p 'CONT) (delete-process p)))
                 (should t))
               '(x/by-pid (signal-process (emacs-pid) 0) (should t))))
         (j (apply #'drgnx-run-ert-audit-test--run dir drgnx-run-ert-audit-test--on))
         (msg "handshake test signalled a child that was not parked"))
    (should (equal `(("x/by-pid" . ,msg) ("x/unparked" . ,msg))
                   (sort (drgnx-run-ert-audit-test--failures j)
                         (lambda (a b) (string< (car a) (car b))))))))

(provide 'run-ert-audit-test)
;;; run-ert-audit-test.el ends here
