;;; watchdog-test.el --- batch tests: drgnx's side of the stall watchdog -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-watchdog)
(require 'drgnx-gc-census)

(defvar nidhogg-watchdog-mode)
(defvar nidhogg-watchdog-log-directory)
(defvar nidhogg-watchdog-typing-commands)
(defvar nidhogg-watchdog-package-functions)

(defmacro drgnx-watchdog-test--stubbed (&rest body)
  "BODY with a stand-in for Nidhogg's watchdog (the feature, its mode and variables), interactive, setting on.
`calls' collects the arguments the stand-in mode was called with."
  (declare (indent 0) (debug t))
  `(let ((nidhogg-watchdog-mode nil) (nidhogg-watchdog-log-directory nil) (nidhogg-watchdog-typing-commands nil)
         (nidhogg-watchdog-package-functions nil) (drgnx-watchdog-mode nil) (drgnx-speed-watchdog t)
         (noninteractive nil) (calls nil))
     (cl-letf (((symbol-function 'nidhogg-watchdog-mode)
                (lambda (&optional arg) (push arg calls) (setq nidhogg-watchdog-mode (and arg (> arg 0)))))
               ((symbol-function 'drgnx-watchdog-available-p) (lambda () t))
               ((symbol-function 'drgnx-watchdog--wanted-p) (lambda () drgnx-speed-watchdog)))
       (unwind-protect (progn ,@body)
         (drgnx-watchdog-mode -1)))))

(ert-deftest drgnx-watchdog/on-by-default ()
  (skip-unless (featurep 'nidhogg-watchdog))
  (let ((noninteractive nil) (drgnx-speed-watchdog t))
    (unwind-protect
        (progn (drgnx-watchdog-maybe-start)
               (should drgnx-watchdog-mode)
               (should nidhogg-watchdog-mode))
      (drgnx-watchdog-mode -1))))

(ert-deftest drgnx-watchdog/settings ()
  (drgnx-watchdog-test--stubbed
    (drgnx-watchdog-maybe-start)
    (should drgnx-watchdog-mode)
    (should (equal nidhogg-watchdog-log-directory (expand-file-name "watchdog/" (drgnx-state-dir))))
    (dolist (c '(self-insert-command delete-backward-char delete-char backward-delete-char-untabify newline))
      (should (memq c nidhogg-watchdog-typing-commands)))
    (should-not (memq 'evil-ret nidhogg-watchdog-typing-commands))
    (should (memq #'drgnx-watchdog-package-of nidhogg-watchdog-package-functions))
    (should (equal calls '(1)))
    (cl-letf (((symbol-function 'featurep) (lambda (f &rest _) (eq f 'evil))))
      (should (memq 'evil-ret (drgnx-watchdog-typing-commands))))))

(ert-deftest drgnx-watchdog/package-of-names-a-string ()
  (should (equal (drgnx-watchdog-package-of (expand-file-name "core/drgnx-watchdog.el" drgnx-dir)) "drgnx"))
  (should-not (drgnx-watchdog-package-of nil)))

(ert-deftest drgnx-watchdog/off-in-batch ()
  (drgnx-watchdog-test--stubbed
    (let ((noninteractive t))
      (drgnx-watchdog-maybe-start))
    (should-not drgnx-watchdog-mode)
    (should-not calls)))

(ert-deftest drgnx-watchdog/setting-off ()
  (drgnx-watchdog-test--stubbed
    (let ((drgnx-speed-watchdog nil))
      (drgnx-watchdog-maybe-start))
    (should-not drgnx-watchdog-mode)
    (should-not calls)))

(ert-deftest drgnx-watchdog/without-the-flag ()
  (let ((drgnx-watchdog-mode nil) (noninteractive nil))
    (cl-letf (((symbol-function 'drgnx-watchdog-available-p) #'ignore))
      (drgnx-watchdog-maybe-start)
      (should-not drgnx-watchdog-mode))))

(ert-deftest drgnx-watchdog/teardown-turns-off ()
  (drgnx-watchdog-test--stubbed
    (drgnx-watchdog-maybe-start)
    (should nidhogg-watchdog-mode)
    (drgnx-watchdog-mode -1)
    (should-not nidhogg-watchdog-mode)
    (should-not (memq #'drgnx-watchdog-package-of nidhogg-watchdog-package-functions))
    (should (equal calls '(-1 1)))))

(ert-deftest drgnx-watchdog/census-hands-over ()
  "While the watchdog's mode is on, the census records nothing."
  (let ((nidhogg-watchdog-mode t) (drgnx-gc-census--ring nil) (drgnx-gc-census--start 0) (drgnx-gc-census--count 0)
        (drgnx-gc-census--dropped 0))
    (drgnx-gc-census--reset)
    (drgnx-gc-census--note)
    (should (zerop drgnx-gc-census--count))
    (setq nidhogg-watchdog-mode nil)
    (drgnx-gc-census--note)
    (should (= 1 drgnx-gc-census--count))))
