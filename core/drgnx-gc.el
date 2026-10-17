;;; drgnx-gc.el --- Garbage collection: rare while starting, steady after, at idle -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; early-init.el defers collection while Emacs starts (startup allocates a lot and keeps most of
;; it).  After startup the threshold is `drgnx-gc-cons-threshold' — measured in the perf lab: Emacs'
;; default (800 kB) collected 28 times in 186 keystrokes (595 ms) — and Emacs collects when it has
;; been idle `drgnx-gc-idle-seconds', so the pauses fall where nobody waits.  See docs/perf.md.

;;; Code:
(require 'seq)

(defvar drgnx-gc-cons-threshold (* 64 1024 1024) "Bytes allocated between collections once started.")
(defvar drgnx-gc-idle-seconds 8 "Collect after this long without input.")

(defun drgnx-gc--idle () (garbage-collect))

(defun drgnx-gc-setup ()
  "The steady threshold and the idle collection (once)."
  (setq gc-cons-threshold drgnx-gc-cons-threshold gc-cons-percentage 0.1)
  (unless (seq-find (lambda (tm) (eq (timer--function tm) #'drgnx-gc--idle)) timer-idle-list)
    (run-with-idle-timer drgnx-gc-idle-seconds t #'drgnx-gc--idle)))

(provide 'drgnx-gc)
;;; drgnx-gc.el ends here
