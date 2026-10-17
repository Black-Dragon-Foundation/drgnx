;;; drgnx-scenario.el --- Scenario tests: known reds, traces, fixtures, drivers -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Scenarios are ERT tests (named drgnx-scenario/…) that state how the UI should behave and
;; run inside a harness session of some configuration (`drgnx test --scenario --config C').
;; A scenario known to fail on a configuration is listed in the suite's known-red.eld; it is
;; then an expected failure — but only if it fails an assertion made with
;; `drgnx-scenario-check', which carries the jank report's trace, so every known red explains
;; itself.  Configuration specifics (how to open the Explorer, …) live in drivers/<config>.el.
;; See docs/develop/scenarios.md.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)

(defun drgnx-scenario-config ()
  "Name of the configuration the scenarios run against (a symbol)."
  (intern (or (getenv "DRGNX_SCENARIO_CONFIG") "minimal")))

(defun drgnx-scenario-suite-dir ()
  (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory)))

(defun drgnx-scenario--known-red-table ()
  (let ((file (expand-file-name "known-red.eld" (drgnx-scenario-suite-dir))))
    (and (file-exists-p file)
         (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))

(defun drgnx-scenario-known-red-p (test &optional config)
  "Non-nil if TEST (a symbol) is listed as known red for CONFIG (default: the current one)."
  (memq test (cdr (assq (or config (drgnx-scenario-config)) (drgnx-scenario--known-red-table)))))

(defun drgnx-scenario-expected (test)
  "The ERT expected result for TEST on the current configuration: `:failed' if known red."
  (if (drgnx-scenario-known-red-p test) :failed :passed))

;;;; Assertions with traces

(defun drgnx-scenario--value (v)
  (if (vectorp v) (mapconcat (lambda (x) (format "%s" x)) v ",") (format "%s" v)))

(defun drgnx-scenario-trace-lines (report)
  "REPORT's trace as readable lines: \"+196 ms  timer:follow  w3 point 17 → 36\"."
  (vconcat
   (mapcar (lambda (step)
             (let ((from (plist-get step :from)) (to (plist-get step :to)))
               (format "+%d ms  %s  %s %s" (plist-get step :t_ms) (plist-get step :cause) (plist-get step :window)
                       (if from
                           (mapconcat (lambda (f)
                                        (let ((k (intern (concat ":" f))))
                                          (format "%s %s → %s" f (drgnx-scenario--value (plist-get from k))
                                                  (drgnx-scenario--value (plist-get to k)))))
                                      (append (plist-get step :fields) nil) ", ")
                         (mapconcat #'identity (append (plist-get step :fields) nil) ",")))))
           (append (plist-get report :trace) nil))))

(defun drgnx-scenario-check (ok explanation report)
  "Unless OK, fail the scenario with EXPLANATION and REPORT's trace.  Returns t.
A REPORT whose measurement did not settle is an error, never a (known) red: the scenario
could not observe what it claims."
  (when (eq (plist-get report :settled) :false)
    (error "scenario did not settle within its timeout — cannot judge: %s; last changes: %s"
           explanation (mapconcat #'identity (last (append (drgnx-scenario-trace-lines report) nil) 6) " | ")))
  (or (and ok t)
      (signal 'ert-test-failed
              (list (list :scenario explanation :trace (drgnx-scenario-trace-lines report))))))

(defun drgnx-scenario-require (ok what)
  "Unless OK, stop the scenario with an error: its setup did not produce WHAT.
Setup failures are never (known) reds.  Returns t."
  (or (and ok t) (error "scenario setup failed: expected %s" what)))

;;;; Fixtures

(defun drgnx-scenario--write (root file text)
  (let ((path (expand-file-name file root)))
    (make-directory (file-name-directory path) t)
    (write-region text nil path nil 'silent)))

(defun drgnx-scenario-fixture (&optional kind)
  "A fresh git repository in a temp directory; return its root (no trailing slash).
KIND `basic' (default): README.md, docs/guide.md, src/app/{main,util}.py, tests/test_main.py.
KIND `second': another small project, for cross-project scenarios."
  (drgnx-scenario--delete-stale-fixtures)
  (let ((root (make-temp-file (format "drgnx-fixture-%s-" (or kind 'basic)) t)))
    (pcase (or kind 'basic)
      ('basic
       (drgnx-scenario--write root "README.md" "# Fixture\n")
       (drgnx-scenario--write root "docs/guide.md" "notes\n")
       (drgnx-scenario--write root "src/app/main.py" "print(\"hi\")\n")
       (drgnx-scenario--write root "src/app/util.py" "x = 1\n")
       (drgnx-scenario--write root "tests/test_main.py" "def test(): pass\n"))
      ('second
       (drgnx-scenario--write root "README.md" "# Second\n")
       (drgnx-scenario--write root "lib/other.py" "y = 2\n")))
    (let ((default-directory (file-name-as-directory root)))
      (call-process "git" nil nil nil "init" "-q")
      (call-process "git" nil nil nil "add" "-A")
      (call-process "git" nil nil nil "-c" "user.email=fixture@drgnx" "-c" "user.name=fixture"
                    "commit" "-qm" "fixture"))
    root))

(defun drgnx-scenario--delete-stale-fixtures ()
  "Delete this user's fixtures older than a day: left behind by runs killed at their timeout."
  (dolist (d (directory-files temporary-file-directory t "\\`drgnx-fixture-"))
    (let ((a (file-attributes d)))
      (when (and (eq t (file-attribute-type a)) (eql (file-attribute-user-id a) (user-uid))
                 (> (float-time (time-since (file-attribute-modification-time a))) 86400))
        (ignore-errors (delete-directory d t))))))

(declare-function drgnx-explorer-roots "drgnx-explorer")
(declare-function drgnx-explorer-set-roots "drgnx-explorer")

(defun drgnx-scenario--fixture-done (root)
  "Leave nothing of the fixture ROOT for the next scenario: its buffers (files and dired; never asking —
the configuration's own panels stay, whatever their directory), the Explorer roots in it, ROOT itself."
  (let ((in (lambda (d) (and d (string-prefix-p (file-name-as-directory root) (file-name-as-directory (expand-file-name d))))))
        (kill-buffer-query-functions nil))
    (dolist (b (buffer-list))
      (when (or (funcall in (buffer-file-name b))
                (and (provided-mode-derived-p (buffer-local-value 'major-mode b) 'dired-mode)
                     (funcall in (buffer-local-value 'default-directory b))))
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b)))
    (when (fboundp 'drgnx-explorer-roots)
      (let ((keep (seq-remove in (drgnx-explorer-roots))))
        (unless (equal keep (drgnx-explorer-roots)) (drgnx-explorer-set-roots keep))))
    (delete-directory root t)))

(defmacro drgnx-scenario-with-fixture (spec &rest body)
  "SPEC is (VAR [KIND]): bind VAR to a fresh fixture repo for BODY, then delete it and everything that
showed it (`drgnx-scenario--fixture-done')."
  (declare (indent 1))
  `(let ((,(car spec) (drgnx-scenario-fixture ,(cadr spec))))
     (unwind-protect (progn ,@body)
       (drgnx-scenario--fixture-done ,(car spec)))))

;;;; Timing and evidence

(defvar drgnx-scenario-quiet 1.0
  "Quiet period (s) before a scenario counts as settled.  Longer than `drgnx-uitest-quiet':
configurations under test may follow up to ~600 ms later (idle timers, re-armed debounces),
and a scenario must not end before they do.")

(defmacro drgnx-scenario-settling (&rest body)
  "Run BODY with the scenario quiet period."
  `(let ((drgnx-uitest-quiet drgnx-scenario-quiet)) ,@body))

(defun drgnx-scenario-callers (&optional n)
  "The N (default 5) innermost named Lisp functions on the stack, outside the harness."
  (let (names)
    (dolist (frame (backtrace-frames))
      (let ((f (cadr frame)))
        (when (and (symbolp f) (fboundp f) (not (special-form-p f))
                   (not (string-match-p "\\`\\(drgnx-\\|ert-\\|backtrace\\|apply\\|funcall\\|eval\\|run-hook\\|timer-event-handler\\|command-execute\\|call-interactively\\)" (symbol-name f))))
          (push f names))))
    (seq-take (nreverse names) (or n 5))))

(defmacro drgnx-scenario-watch-nil (var pred log &rest body)
  "Run BODY recording, into the list LOG (a symbol), who sets VAR to nil in buffers satisfying PRED."
  (declare (indent 3))
  (let ((watcher (make-symbol "watcher")))
    `(let ((,watcher (lambda (_sym new op where)
                       (when (and (null new) (eq op 'set) (buffer-live-p where) (funcall ,pred where))
                         (push (drgnx-scenario-callers) ,log)))))
       (add-variable-watcher ',var ,watcher)
       (unwind-protect (progn ,@body) (remove-variable-watcher ',var ,watcher)))))

;;;; Drivers

(defun drgnx-scenario-load-driver ()
  "Load drivers/<config>.el of the suite; skip the scenario if the configuration has none."
  (let ((file (expand-file-name (format "drivers/%s.el" (drgnx-scenario-config)) (drgnx-scenario-suite-dir))))
    (if (file-exists-p file)
        (load file nil t)
      (ert-skip (format "no scenario driver for configuration %s" (drgnx-scenario-config))))))

(provide 'drgnx-scenario)
;;; drgnx-scenario.el ends here
