;;; perf-extensions-test.el --- batch tests: the Extensions workloads of the perf lab -*- lexical-binding: t -*-
;; test-class: det

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Extensions view's timing rows are perf workloads (harness/drgnx-perf-extensions.el).  These tests load each
;; workload's forms in this process with small fixtures: every row has a budget and a fixture, the workloads setup,
;; measure and tear down, the numbers come back, and nothing is left behind (environment, advice, buffers).  The
;; numbers are not judged here: the combined gate pass runs them on the desktop.  Race-proof pattern D: nothing waits
;; for anything.  The budgets are in test/perf/budgets.eld.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-perf-run)

(defvar drgnx-perf-extensions-n)

(defconst drgnx-perf-extensions-test--small
  '((gnu . 6) (nongnu . 6) (melpa . 40) (melpa-stable . 8) (installed . 6) (updates . 3) (builtin . 4) (plugins . 2)
    (progress . 0.3) (live . 6) (scroll . 2))
  "Fixture sizes for the tests.")

(defun drgnx-perf-extensions-test--spec (name)
  (cdr (assq name (drgnx-perf-run--workloads))))

(defun drgnx-perf-extensions-test--run (name)
  "Run workload NAME's forms here, small; the measure's plist.  The environment is checked to come back."
  (let* ((spec (drgnx-perf-extensions-test--spec name))
         (drgnx-perf-extensions-n drgnx-perf-extensions-test--small)
         (process-environment (copy-sequence process-environment))
         (load-path load-path)
         (before (mapcar #'getenv '("DRGNX_DATA_DIR" "DRGNX_CONFIG_DIR" "XDG_STATE_HOME" "XDG_CACHE_HOME")))
         result)
    (unwind-protect
        (progn
          (eval (read (plist-get spec :setup)) t)
          (when (plist-get spec :each) (eval (read (plist-get spec :each)) t))
          (setq result (eval (read (plist-get spec :measure)) t)))
      (eval (read (plist-get spec :teardown)) t))
    (should (equal before (mapcar #'getenv '("DRGNX_DATA_DIR" "DRGNX_CONFIG_DIR" "XDG_STATE_HOME" "XDG_CACHE_HOME"))))
    (should-not (advice-member-p #'drgnx-perf-extensions--hub 'drgnx-hub-call))
    (should-not (get-buffer "*Extensions*"))
    result))

(defconst drgnx-perf-extensions-test--rows
  '((extensions-open :open_ms 100) (extensions-open :processes 0)
    (extensions-search :key_p50_ms 8) (extensions-search :key_max_ms 16)
    (extensions-scroll :key_max_ms 16)
    (extensions-details :open_ms 50)
    (extensions-progress :reads_too_close 0) (extensions-progress :last_unread 0)
    (extensions-progress :typing_delta_ms 1)
    (activate-live :activate_ms 20) (activate-live-new :activate_ms 20)
    (install-overhead :overhead_ms 3000))
  "The budgeted numbers: (WORKLOAD KEY LIMIT).  refresh-job and list-packages-compare report, with no budget.")

(ert-deftest drgnx-perf-extensions/every-row-has-a-budget-and-a-fixture ()
  (let ((budgets (drgnx-perf-run--budgets)))
    (dolist (name '(extensions-open extensions-search extensions-scroll extensions-details extensions-progress
                                    activate-live activate-live-new install-overhead refresh-job list-packages-compare))
      (let ((spec (drgnx-perf-extensions-test--spec name)))
        (should spec)
        (dolist (k '(:setup :measure :teardown))
          (should (consp (read (plist-get spec k)))))))
    (dolist (row drgnx-perf-extensions-test--rows)
      (let ((b (seq-find (lambda (b) (and (eq (car b) (car row)) (equal (cadr b) (list (cadr row))))) budgets)))
        (should b)
        (should (= (nth 2 b) (nth 2 row)))))))

(ert-deftest drgnx-perf-extensions/the-default-sizes-are-the-archives-at-their-full-size ()
  (eval drgnx-perf-extensions--lib t)
  (should (= 7150 (apply #'+ (mapcar #'cdr (drgnx-perf-extensions--archives))))))

(ert-deftest drgnx-perf-extensions/the-archives-are-local-directories-of-contents ()
  (eval drgnx-perf-extensions--lib t)
  (let ((drgnx-perf-extensions-n drgnx-perf-extensions-test--small)
        (dir (make-temp-file "drgnx-perf-ext-arch" t)))
    (unwind-protect
        (let ((archives (drgnx-perf-extensions-write-archives dir)))
          (should (equal (mapcar #'car archives) '("gnu" "nongnu" "melpa" "melpa-stable")))
          (dolist (a archives)
            (let ((contents (with-temp-buffer (insert-file-contents (concat (cdr a) "archive-contents")) (read (current-buffer)))))
              (should (eql (car contents) 1))
              (should (> (length (cdr contents)) 5)))))
      (delete-directory dir t))))

(ert-deftest drgnx-perf-extensions/open-draws-the-sections-and-starts-nothing ()
  (let ((r (drgnx-perf-extensions-test--run 'extensions-open)))
    (should (numberp (plist-get r :open_ms)))
    (should (eql (plist-get r :processes) 0))
    (should (> (plist-get r :rows) 10))
    ;; the timed open includes the draw: the rows are in the buffer when the clock stops
    (should (> (plist-get r :rows_drawn) 10))))

(ert-deftest drgnx-perf-extensions/search-and-scroll-time-every-key ()
  (let ((s (drgnx-perf-extensions-test--run 'extensions-search)))
    (dolist (k '(:key_p50_ms :key_max_ms)) (should (numberp (plist-get s k))))
    (should (> (plist-get s :keys) 3))
    (should (> (plist-get s :rows_drawn) 0)))
  (let ((s (drgnx-perf-extensions-test--run 'extensions-scroll)))
    (should (numberp (plist-get s :key_max_ms)))
    (should (numberp (plist-get s :slice_max_ms)))
    (should (eql (plist-get s :keys) 4))
    ;; the whole catalog by name, as the design's row says, drawn before the first scroll
    (should (eql (plist-get s :rows) 60))
    (should (> (plist-get s :rows_drawn) 40))))

(ert-deftest drgnx-perf-extensions/details-opens-five-pages ()
  (let ((r (drgnx-perf-extensions-test--run 'extensions-details)))
    (dolist (k '(:open_ms :open_max_ms)) (should (numberp (plist-get r k))))
    (should (eql (plist-get r :rows_drawn) 4))))

(ert-deftest drgnx-perf-extensions/progress-checks-the-gap-between-reads-and-compares-typing ()
  (let ((r (drgnx-perf-extensions-test--run 'extensions-progress)))
    (dolist (k '(:read_gap_min_ms :reads :typing_p95_ms :typing_p95_idle_ms :typing_delta_ms))
      (should (numberp (plist-get r k))))
    (should (eql (plist-get r :reads_too_close) 0))
    (should (eql (plist-get r :last_unread) 0))))

(ert-deftest drgnx-perf-extensions/activation-repoints-every-fixture-package ()
  (let ((r (drgnx-perf-extensions-test--run 'activate-live)))
    (should (numberp (plist-get r :activate_ms)))
    (should (eql (plist-get r :packages) 6))))

(ert-deftest drgnx-perf-extensions/activation-of-a-new-package-is-timed ()
  (let ((r (drgnx-perf-extensions-test--run 'activate-live-new)))
    (should (numberp (plist-get r :activate_ms)))
    (should (eql (plist-get r :activated) 1))))

(ert-deftest drgnx-perf-extensions/refresh-writes-the-catalog-from-the-archives ()
  (let ((r (drgnx-perf-extensions-test--run 'refresh-job)))
    (should (numberp (plist-get r :refresh_ms)))
    (should (> (plist-get r :packages) 30))))

(ert-deftest drgnx-perf-extensions/the-comparison-measures-both-sides ()
  (let ((r (drgnx-perf-extensions-test--run 'list-packages-compare)))
    (dolist (k '(:menu_first_ms :view_first_ms :menu_key_p50_ms :view_key_p50_ms :menu_scroll_max_ms :view_scroll_max_ms
                                :menu_heap_kb :view_heap_kb))
      (should (numberp (plist-get r k))))
    (should-not (get-buffer "*Packages*"))))

(ert-deftest drgnx-perf-extensions/install-overhead-runs-both-children ()
  ;; two real batch children, run to their end (pattern D: the test only waits for call-process)
  (let ((r (drgnx-perf-extensions-test--run 'install-overhead)))
    (dolist (k '(:sync_ms :plain_ms :overhead_ms)) (should (numberp (plist-get r k))))))

;;; perf-extensions-test.el ends here
