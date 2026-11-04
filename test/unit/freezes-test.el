;;; freezes-test.el --- batch tests: Show Freezes -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-freezes)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defvar nidhogg-watchdog-record-functions nil)
(defvar nidhogg-watchdog-mode nil)
(defvar nidhogg-version)

(defconst drgnx-freezes-test--ranking
  (list (list :gc t :name "GC" :count 12 :felt 3 :total 480.0 :max 120.0 :detail (list :meets nil))
        (list :package "pkg-a" :name "pkg-a" :count 4 :felt 2 :total 1800.0 :max 900.0 :score 1400.0
              :signatures (list (list :name "sig-1 /opt/outside/pkg-a/a.el" :count 3 :felt 2)
                                (list :name "sig-2" :count 1 :felt 0))
              :tree '("root" 0 ("pkg-a-run" 4 ("pkg-a--slow /opt/outside/pkg-a/a.el" 4))))
        (list :package "pkg-b" :name "pkg-b" :count 2 :felt 0 :total 260.0 :max 150.0 :score 60.0
              :signatures (list (list :name "sig-3" :count 2 :felt 0)) :tree '("root" 0)))
  "A ranking in the shape `nidhogg-watchdog-ranking' documents.")

(ert-deftest drgnx-freezes/view-rows ()
  (let ((keys (drgnx-freezes--keys drgnx-freezes-test--ranking)))
    (should (equal keys '(head gc (package . "pkg-a") (package . "pkg-b"))))
    (let ((gc (drgnx-freezes--render 'gc)) (a (drgnx-freezes--render '(package . "pkg-a")))
          (b (drgnx-freezes--render '(package . "pkg-b"))))
      (should (string-match-p "GC .*12 collections · 3 felt" gc))
      (should (string-match-p "pkg-a.*4 stalls · felt 2 · 1.8 s in all · longest 900 ms" a))
      (should (string-match-p "pkg-a--slow" a))                 ; the call tree
      (should (string-match-p "sig-1" a))                       ; the signatures
      (should (string-match-p "pkg-b.*2 stalls · felt 0" b))
      (should (string-suffix-p "\n" a)))))

(ert-deftest drgnx-freezes/copy-report-has-no-outside-paths ()
  (let* ((nidhogg-version "31.1-nidhogg.9")
         (text (drgnx-freezes-report-text drgnx-freezes-test--ranking)))
    (should (string-match-p "Nidhogg 31.1-nidhogg.9" text))
    (should (string-match-p "pkg-a: 4 stalls, 2 felt" text))
    (should (string-match-p "pkg-a--slow" text))
    (should-not (string-match-p "/opt" text))
    (should-not (string-match-p "outside" text))))

(ert-deftest drgnx-freezes/deep-sample-action ()
  (drgnx-notice-test-with-model
    (drgnx-notice-define-source 'watchdog :title "Freezes" :command 'freezes)
    (let ((asked nil) (started 0) (nidhogg-watchdog-record-functions nil) (drgnx-freezes--deep-armed nil)
          (nidhogg-watchdog-mode nil))
      (cl-letf (((symbol-function 'nidhogg-watchdog--deep) (lambda (n) (push n asked)))
                ((symbol-function 'drgnx-watchdog-doctor-start) (lambda () (cl-incf started))))
        ;; with the watchdog off there is nothing to sample with, and the doctor is not started
        (should-error (drgnx-freezes-sample-deep) :type 'user-error)
        (should (null asked))
        (setq nidhogg-watchdog-mode t)
        (drgnx-freezes-sample-deep))
      (should (= started 0))
      (should (equal asked '(1)))
      (should (memq #'drgnx-freezes--deep-arrived nidhogg-watchdog-record-functions))
      (should (null (drgnx-notices)))
      ;; a stall that was not sampled in depth does not use the notice up
      (run-hook-with-args 'nidhogg-watchdog-record-functions '(:nongc-ms 300))
      (should (null (drgnx-notices)))
      (should drgnx-freezes--deep-armed)
      (run-hook-with-args 'nidhogg-watchdog-record-functions '(:nongc-ms 300 :deep t))
      (should (= 1 (length (drgnx-notices))))
      (should-not (memq (function drgnx-freezes--deep-arrived) nidhogg-watchdog-record-functions))
      (should-not drgnx-freezes--deep-armed))))

(ert-deftest drgnx-freezes/gc-row-actions ()
  (let (calls)
    (cl-letf (((symbol-function 'drgnx-heap-audit-command) (lambda (&rest _) (push 'audit calls)))
              ((symbol-function 'drgnx-gc-census-show) (lambda () (push 'collections calls))))
      (drgnx-freezes--keys drgnx-freezes-test--ranking)
      (let ((text (drgnx-freezes--render 'gc)))
        (should (string-match-p "Run a heap audit" text))
        (should (string-match-p "Show collections" text)))
      (drgnx-freezes-heap-audit)
      (drgnx-freezes-show-collections))
    (should (equal (nreverse calls) '(audit collections)))))

(ert-deftest drgnx-freezes/command-is-registered ()
  (require 'drgnx)
  (drgnx--core-commands)
  (should (drgnx-commands-get 'freezes)))
