;;; perf-settings-test.el --- batch tests: the settings workloads of the perf lab -*- lexical-binding: t -*-
;; test-class: det

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The settings layer's timing gates are perf workloads (harness/drgnx-perf-settings.el).  These tests run each
;; workload's forms in this process with small fixtures: the setup, each, measure and teardown work, the numbers
;; come back, and nothing is left behind (environment, variables, buffers).  Race-proof pattern D: nothing here waits
;; for anything.  The budgets are in test/perf/budgets.eld.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf-run)

(defvar drgnx-perf-settings-n)

(defconst drgnx-perf-settings-test--small
  '((start . 8) (page . 60) (prov . 20) (sync . 3) (open . 6))
  "Fixture sizes for the tests.")

(defun drgnx-perf-settings-test--spec (name)
  (cdr (assq name (drgnx-perf-run--workloads))))

(defun drgnx-perf-settings-test--run (name)
  "Run workload NAME's forms here, small; the measure's plist.  The environment is checked to come back."
  (let* ((spec (drgnx-perf-settings-test--spec name))
         (drgnx-perf-settings-n drgnx-perf-settings-test--small)
         (process-environment (copy-sequence process-environment))
         (before (list (getenv "DRGNX_CONFIG_DIR") (getenv "XDG_STATE_HOME") (getenv "XDG_CACHE_HOME")))
         result)
    (unwind-protect
        (progn
          (eval (read (plist-get spec :setup)) t)
          (when (plist-get spec :each) (eval (read (plist-get spec :each)) t))
          (setq result (eval (read (plist-get spec :measure)) t)))
      (eval (read (plist-get spec :teardown)) t))
    (should (equal before (list (getenv "DRGNX_CONFIG_DIR") (getenv "XDG_STATE_HOME") (getenv "XDG_CACHE_HOME"))))
    result))

(ert-deftest drgnx-perf-settings/the-five-workloads-exist-and-read ()
  (dolist (name '(settings-start settings-page settings-prov settings-sync settings-open))
    (let ((spec (drgnx-perf-settings-test--spec name)))
      (should spec)
      (dolist (k '(:setup :measure :teardown))
        (should (consp (read (plist-get spec k))))))))

(ert-deftest drgnx-perf-settings/every-measured-number-has-a-budget ()
  (let ((budgets (drgnx-perf-run--budgets)))
    (dolist (row '((settings-start :read_ms 2) (settings-page :open_ms 100) (settings-page :key_max_ms 16)
                   (settings-prov :prov_pct 5) (settings-sync :index_ms 2000) (settings-open :delta_ms nil)))
      (let ((b (seq-find (lambda (b) (and (eq (car b) (car row)) (equal (cadr b) (list (cadr row))))) budgets)))
        (should b)
        (when (nth 2 row) (should (= (nth 2 b) (nth 2 row))))))))

(ert-deftest drgnx-perf-settings/start-applies-every-entry-and-leaves-nothing ()
  (let ((r (drgnx-perf-settings-test--run 'settings-start)))
    (should (numberp (plist-get r :read_ms)))
    (should-not (intern-soft "drgnx-perf-sv-0"))))

(ert-deftest drgnx-perf-settings/page-opens-and-searches ()
  (let ((r (drgnx-perf-settings-test--run 'settings-page)))
    (dolist (k '(:open_ms :key_p50_ms :key_max_ms)) (should (numberp (plist-get r k))))
    (should-not (get-buffer "*drgnx settings*"))
    (should-not (intern-soft "drgnx-edit-perf-0"))))

(ert-deftest drgnx-perf-settings/prov-compares-a-plain-load-with-a-recorded-one ()
  (let ((r (drgnx-perf-settings-test--run 'settings-prov)))
    (dolist (k '(:load_ms :prov_load_ms :prov_pct :cold_extra_ms)) (should (numberp (plist-get r k))))))

(ert-deftest drgnx-perf-settings/sync-indexes-every-package ()
  (should (numberp (plist-get (drgnx-perf-settings-test--run 'settings-sync) :index_ms))))

(ert-deftest drgnx-perf-settings/open-compares-the-layers-in-and-out ()
  (let ((r (drgnx-perf-settings-test--run 'settings-open)))
    (dolist (k '(:open_on_ms :open_off_ms :delta_ms)) (should (numberp (plist-get r k))))
    (should (memq 'drgnx-settings-mode--apply-mode-overrides change-major-mode-after-body-hook))
    (should (memq 'drgnx-settings-workspace--private-variables hack-dir-local-get-variables-functions))))

;;; perf-settings-test.el ends here
