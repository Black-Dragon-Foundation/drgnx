;;; drgnx-gc.el --- Garbage collection: rare while starting, steady after, at idle -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; early-init.el defers collection while Emacs starts (startup allocates a lot and keeps most of
;; it).  After startup the threshold is `drgnx-gc-cons-threshold' — measured in the perf lab: Emacs'
;; default (800 kB) collected 28 times in 186 keystrokes (595 ms) — and Emacs collects when it has
;; been idle `drgnx-gc-idle-seconds', so the pauses fall where nobody waits.  This file is the one
;; owner: the idle collection only after real allocation, `drgnx-gc-gap' for producers that know
;; they are in a quiet gap, `drgnx-gc-batch-setup' for batch Emacs, and gcmh-mode handed over to
;; and taken back from.  See docs/develop/perf.md.

;;; Code:
(require 'drgnx-timer)

(defvar drgnx-gc-cons-threshold (* 64 1024 1024) "Bytes allocated between collections once started.")
(defvar drgnx-gc-idle-seconds 1
  "Collect after this long without input: a pause in typing, so the collection (about 45 ms at drgnx's threshold)
lands there and not on a key.")
(defconst drgnx-gc-idle-share 0.5
  "The idle collection runs once this share of `gc-cons-threshold' was consed since the last collection.")
(defvar drgnx-gc-batch-threshold (* 32 1024 1024) "Bytes allocated between collections in a batch Emacs.")

(defcustom drgnx-gc-gap-quiet 0.02
  "Seconds without input before `drgnx-gc-gap' may collect; nil: never."
  :type '(choice (const :tag "Never" nil) number)
  :group 'drgnx)

(defconst drgnx-gc-gap-share 0.85
  "`drgnx-gc-gap' collects once this share of `gc-cons-threshold' was consed since the last collection.")

(defvar nidhogg-watchdog-gc-origin nil
  "Why the collection running now was started: `idle' (`drgnx-gc--idle'), `gap' (`drgnx-gc-gap'), `audit' (the heap
audit); nil reads as `auto'.  Callers bind it around `garbage-collect'; the GC census (core/drgnx-gc-census.el) reads
it on `post-gc-hook'.  Nidhogg's watchdog defines the same variable.")

(defvar drgnx-gc--base 0 "`drgnx-gc--consed' at the last collection.")

(defun drgnx-gc--consed ()
  "Bytes allocated so far: `memory-use-counts' weighted by object size."
  (let ((c (memory-use-counts)))
    (+ (* 16 (nth 0 c)) (* 8 (nth 1 c)) (* 8 (nth 2 c)) (* 48 (nth 3 c)) (nth 4 c) (* 56 (nth 5 c))
       (* 32 (nth 6 c)))))

(defvar drgnx-gc-census-mode)
(declare-function drgnx-gc-census--note "drgnx-gc-census")

(defun drgnx-gc--note ()
  "On `post-gc-hook': the GC census's record of this collection when the census is on (first, before this
function allocates), then how much was allocated at it."
  (when (bound-and-true-p drgnx-gc-census-mode) (drgnx-gc-census--note))
  (setq drgnx-gc--base (drgnx-gc--consed)))

(defvar drgnx-gc--idle-pause nil
  "When the pause the idle collection last collected in began (`float-time'), or nil: one collection per pause.")

(defvar server-clients)

(defun drgnx-gc--someone-waits-p ()
  "Non-nil when someone may be typing: not a batch Emacs, and not a daemon no client is connected to."
  (and (not noninteractive)
       (or (not (daemonp)) (and (boundp 'server-clients) server-clients t))))

(declare-function malloc-trim "alloc.c")      ; glibc builds only, hence the `fboundp'

(defvar drgnx-gc--trimmed nil "`gcs-done' when the idle collection last trimmed the heap, or nil before the first.")

(defun drgnx-gc--idle ()
  "The idle collection, `drgnx-gc-idle-seconds' into a pause: once per pause, when `drgnx-gc-idle-share' of the
threshold was consed since the last collection, no input is pending and someone may be typing
\(`drgnx-gc--someone-waits-p').  The pause's collection then lands there instead of on the next keys.
A collection gives the memory it frees back to malloc, not to the system (a big file's parse trees left hundreds of
megabytes resident): the first pause after any collection, this one's or an earlier one, trims the heap once
\(`malloc-trim').  The first trim after the workloads cost 53 ms (900 MB resident down to 190 MB), the later ones
under 1 ms: hence once per collection, in a pause, never after every collection."
  (let* ((idle (current-idle-time))
         (pause (and idle (- (float-time) (float-time idle)))))
    (when (and pause
               (not (and drgnx-gc--idle-pause (< (abs (- pause drgnx-gc--idle-pause)) 0.001)))
               (not (input-pending-p))
               (>= (- (drgnx-gc--consed) drgnx-gc--base) (* drgnx-gc-idle-share gc-cons-threshold))
               (drgnx-gc--someone-waits-p))
      (setq drgnx-gc--idle-pause pause)
      (let ((inhibit-interaction t) (nidhogg-watchdog-gc-origin 'idle)) (garbage-collect)))
    (when (and pause (fboundp 'malloc-trim) (not (eql gcs-done drgnx-gc--trimmed)) (not (input-pending-p)))
      (setq drgnx-gc--trimmed gcs-done)
      (malloc-trim))))

(defun drgnx-gc-gap ()
  "Collect now if this is a quiet gap and memory is nearly full; t when it collected.
For producers that finish a burst of work: no input pending, idle for `drgnx-gc-gap-quiet', and at least
`drgnx-gc-gap-share' of `gc-cons-threshold' consed since the last collection."
  (when (and (numberp drgnx-gc-gap-quiet)
             (let ((idle (current-idle-time))) (and idle (>= (float-time idle) drgnx-gc-gap-quiet)))
             (not (input-pending-p))
             (>= (- (drgnx-gc--consed) drgnx-gc--base) (* drgnx-gc-gap-share gc-cons-threshold)))
    (let ((inhibit-interaction t) (nidhogg-watchdog-gc-origin 'gap)) (garbage-collect))
    t))

(defun drgnx-gc--start-idle ()
  (drgnx-timer-start 'gc-idle drgnx-gc-idle-seconds #'drgnx-gc--idle :repeat t :idle t :owner :core))

(defun drgnx-gc--gcmh-off ()
  "gcmh is off: drgnx's threshold and idle collection are back."
  (setq gc-cons-threshold drgnx-gc-cons-threshold gc-cons-percentage 0.1)
  (drgnx-gc--start-idle))

(defun drgnx-gc--gcmh-changed (symbol newval operation _where)
  "Variable watcher of `gcmh-mode': gcmh does the idle collection while it is on, drgnx while it is off.
Acts only on a real change: loading gcmh.el sets the variable to nil, which must not overwrite the user's threshold."
  (when (and (eq operation 'set)
             (not (eq (and newval t) (and (default-boundp symbol) (default-value symbol) t))))
    (if newval (drgnx-timer-cancel 'gc-idle) (drgnx-gc--gcmh-off))))

(define-minor-mode drgnx-gc-mode
  "The GC owner's hooks: the note after each collection and the watch on `gcmh-mode'."
  :global t :group 'drgnx
  (cond (drgnx-gc-mode
         (add-hook 'post-gc-hook #'drgnx-gc--note)
         (add-hook 'gcmh-mode-off-hook #'drgnx-gc--gcmh-off)     ; gcmh sets its own threshold after the watcher ran
         (add-variable-watcher 'gcmh-mode #'drgnx-gc--gcmh-changed))
        (t (remove-hook 'post-gc-hook #'drgnx-gc--note)
           (remove-hook 'gcmh-mode-off-hook #'drgnx-gc--gcmh-off)
           (remove-variable-watcher 'gcmh-mode #'drgnx-gc--gcmh-changed))))

(defconst drgnx-gc--starting-above (* 256 1024 1024)
  "early-init.el's startup threshold is above this (its emacs-startup-hook tests the same).")

(declare-function drgnx-gc-census-maybe-start "drgnx-gc-census")
(declare-function drgnx-watchdog-maybe-start "drgnx-watchdog")

(defun drgnx-gc-setup ()
  "The owner on, the steady threshold and the idle collection (once) — unless gcmh-mode does both, and the
threshold only while it is early-init's startup value (a user's own is kept).  The GC census when its setting is on."
  (drgnx-gc-mode 1)
  (unless (bound-and-true-p gcmh-mode)
    (when (> gc-cons-threshold drgnx-gc--starting-above)
      (setq gc-cons-threshold drgnx-gc-cons-threshold gc-cons-percentage 0.1))
    (drgnx-gc--start-idle))
  (when (require 'drgnx-gc-census nil t)               ; absent where only this file is on the load path (a harness)
    (drgnx-gc-census-maybe-start))
  (when (require 'drgnx-watchdog nil t)
    (drgnx-watchdog-maybe-start)))

(defun drgnx-gc-batch-setup ()
  "The settings of a long-lived batch Emacs (hub, workers): a modest threshold, a low percentage."
  (setq gc-cons-threshold drgnx-gc-batch-threshold gc-cons-percentage 0.2))

(defun drgnx-gc-collect (origin)
  "Collect now on a caller's request, with `nidhogg-watchdog-gc-origin' bound to ORIGIN (e.g. `audit', the heap
audit's own collection), so the census and the watchdog's GC row say why; `garbage-collect''s value."
  (let ((nidhogg-watchdog-gc-origin origin) (inhibit-interaction t))
    (garbage-collect)))

(provide 'drgnx-gc)
;;; drgnx-gc.el ends here
