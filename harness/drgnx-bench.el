;;; drgnx-bench.el --- The workbench benchmark: drgnx vs treemacs and ibuffer -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx test --bench' (batch controller): builds a large fixture, starts a GUI session of
;; config=drgnx, runs test/bench/workbench-bench.el in it — the same operations with drgnx's
;; Explorer and Buffers panel, treemacs and ibuffer, each timed with a full redisplay — and
;; prints the comparison.  treemacs is loaded only in that session, read-only, from
;; $DRGNX_BENCH_ELPA (default ~/.config/emacs/elpa when present); without it only drgnx and
;; ibuffer are measured.  Fails when drgnx misses a budget or is slower than the competitor.
;; See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-ui)
(require 'drgnx-build)

(defconst drgnx-bench-budgets
  '(:explorer-first 30 :explorer-expand 80 :explorer-reveal 20 :explorer-key-p95 8 :explorer-refresh 150
    :buffers-render 30 :buffers-update 15 :buffers-key-p95 8)
  "drgnx's budgets in ms (GUI session, median of 3; key metrics are the p95 of 300 presses).")

(defconst drgnx-bench-pairs
  '((:explorer-first . :treemacs) (:explorer-expand . :treemacs) (:explorer-reveal . :treemacs)
    (:explorer-key-p95 . :treemacs) (:explorer-refresh . :treemacs)
    (:explorer-first-git . :treemacs) (:explorer-expand-git . :treemacs) (:git-status . :treemacs)
    (:buffers-render . :ibuffer) (:buffers-update . :ibuffer) (:buffers-key-p95 . :ibuffer))
  "Each metric and the tool drgnx is compared with.")

(defconst drgnx-bench-noise-ms 0.5
  "Differences smaller than this are measurement noise: drgnx is not slower because of them.")

(defun drgnx-bench--get (results tool metric)
  (let ((v (plist-get (plist-get results tool) metric))) (and (numberp v) v)))

(defun drgnx-bench-verdict (results budgets pairs)
  "Failures (strings): drgnx over a budget, or slower than the competitor where it was measured."
  (let (fails)
    (pcase-dolist (`(,metric . ,other) pairs)
      (let ((mine (drgnx-bench--get results :drgnx metric)) (theirs (drgnx-bench--get results other metric))
            (budget (plist-get budgets metric)))
        (cond ((null mine) (push (format "%s: not measured for drgnx" metric) fails))
              (t (when (and budget (> mine budget))
                   (push (format "%s: %.1f ms over the budget %s ms" metric mine budget) fails))
                 (when (and theirs (> mine (+ theirs drgnx-bench-noise-ms)))
                   (push (format "%s: %.1f ms, slower than %s (%.1f ms)" metric mine (substring (symbol-name other) 1) theirs)
                         fails))))))
    (nreverse fails)))

(defun drgnx-bench-table (results pairs)
  "The results as an aligned text table."
  (concat (format "%-18s %8s %8s  %s\n" "metric (ms)" "drgnx" "other" "compared with")
          (mapconcat (lambda (p)
                       (let ((mine (drgnx-bench--get results :drgnx (car p)))
                             (theirs (drgnx-bench--get results (cdr p) (car p))))
                         (format "%-18s %8s %8s  %s" (substring (symbol-name (car p)) 1)
                                 (if mine (format "%.1f" mine) "-") (if theirs (format "%.1f" theirs) "-")
                                 (substring (symbol-name (cdr p)) 1))))
                     pairs "\n")))

(defun drgnx-bench-fixture ()
  "A project of ~25k files: 200 folders × 100 files, big/ with 5000, a depth-8 file."
  (let ((root (make-temp-file "drgnx-bench" t)))
    (dotimes (d 200)
      (let ((dir (expand-file-name (format "d%03d" d) root)))
        (make-directory dir)
        (dotimes (f 100) (write-region "" nil (expand-file-name (format "f%03d.txt" f) dir) nil 'silent))))
    (let ((big (expand-file-name "big" root)))
      (make-directory big)
      (dotimes (f 5000) (write-region "" nil (expand-file-name (format "b%04d.txt" f) big) nil 'silent)))
    (let ((leaf (expand-file-name "deep/a/b/c/d/e/f/leaf.txt" root)))
      (make-directory (file-name-directory leaf) t)
      (write-region "" nil leaf nil 'silent))
    ;; A real repository: everything committed, then 50 files changed (git decorations to compute).
    (let ((default-directory (file-name-as-directory root)))
      (if (executable-find "git")
          (progn
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "-c" "user.email=bench@drgnx" "-c" "user.name=bench" "commit" "-qm" "bench")
            (dotimes (i 50) (write-region "changed\n" nil (expand-file-name (format "d%03d/f000.txt" i) root) nil 'silent)))
        (make-directory (expand-file-name ".git" root))))   ; still a project for project.el
    root))

(defun drgnx-bench-run ()
  "Run the benchmark; print the table and failures; return the exit code."
  (let* ((elpa (or (getenv "DRGNX_BENCH_ELPA")
                   (let ((d (expand-file-name "~/.config/emacs/elpa"))) (and (file-directory-p d) d))))
         (bench (expand-file-name "../test/bench/workbench-bench.el" drgnx-ui-harness-dir))
         (built (drgnx-build (expand-file-name ".." drgnx-ui-harness-dir)))     ; compiled, like treemacs
         (root (progn (when (plist-get built :errors) (message "drgnx build: %S" (plist-get built :errors)))
                      (message "building the fixture (25k files)…") (drgnx-bench-fixture)))
         (s (drgnx-ui-start "drgnx" "1400x800" 60))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (let* ((results (progn (message "measuring…")
                               (drgnx-ui-call sess (format "(progn (load %S nil t) (drgnx-bench-session %S %S))"
                                                           bench root elpa)
                                              900)))
               (fails (drgnx-bench-verdict results drgnx-bench-budgets drgnx-bench-pairs))
               (out (expand-file-name "bench.json" (drgnx-ui-state-root))))
          (with-temp-file out (insert (drgnx-ui--json results)))
          (princ (concat (drgnx-bench-table results drgnx-bench-pairs) "\n"))
          (dolist (e (append (plist-get results :errors) nil)) (princ (format "note: %s\n" e)))
          (princ (format "results: %s\n" out))
          (if fails
              (progn (dolist (f fails) (princ (format "FAIL %s\n" f))) 1)
            (princ "bench: drgnx within every budget and not slower than treemacs/ibuffer\n")
            0))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(provide 'drgnx-bench)
;;; drgnx-bench.el ends here
