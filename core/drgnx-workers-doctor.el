;;; drgnx-workers-doctor.el --- The doctor's workers check -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One check in the group "Speed": is Nidhogg's work off the main thread on, running, and not falling back?  Its
;; facts (`:workers') come from `nidhogg-workers-stats' and the switches.  `drgnx doctor' is a batch Emacs of its own,
;; so it cannot see the editor's counters: there the check says only that the build has the feature and which switches
;; are on by default.  The counters and the live switch values are read only in an interactive Emacs.  Without the
;; feature the check says what to update.  Nothing here prompts.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-doctor)

(defvar nidhogg-workers--defaults)
(defvar nidhogg-workers--switches)
(declare-function nidhogg-workers-stats "nidhogg-workers")

(defconst drgnx-workers-doctor-update-fix
  "run `drgnx update': it builds the newest Nidhogg (docs/guide/speed.md, \"Workers\")"
  "What to do when this Emacs has no workers.")

(defconst drgnx-workers-doctor--workers
  '((:nh-io . nidhogg-workers-process-reader) (:nh-parse . nidhogg-workers-treesit)
    (:nh-img . nidhogg-workers-images) (:nh-blk . nidhogg-workers-dns) (:nh-save . nidhogg-workers-autosave))
  "Each worker (a key of `nidhogg-workers-stats') and the switch that turns its work off.")

(defconst drgnx-workers-doctor-fallback-share 0.1
  "A worker whose fallbacks are more than this share of its jobs is a warning.")

(defconst drgnx-workers-doctor--not-fallbacks '(boost-denied)
  "Reasons in `:fallbacks' that are no job taking today's path: `boost-denied' counts a wait that could not raise an
idle-priority thread (always, without privileges), while the job still ran on its worker.")

(defun drgnx-workers-doctor-facts ()
  "The `:workers' fact: nil without the feature, else (:live BOOL :switches ((SWITCH . VALUE)...) :stats STATS).
In a batch Emacs (`drgnx doctor') :live is nil, the switches are the build's defaults and there are no stats: they
would be this process's, not the editor's.  Never signals."
  (when (and (featurep 'nidhogg-workers) (fboundp 'nidhogg-workers-stats))
    (condition-case err
        (if noninteractive
            (list :live nil :switches (and (boundp 'nidhogg-workers--defaults) (copy-sequence nidhogg-workers--defaults)))
          (list :live t :stats (nidhogg-workers-stats)
                :switches (and (boundp 'nidhogg-workers--switches)
                               (mapcar (lambda (s) (cons s (and (boundp s) (symbol-value s))))
                                       nidhogg-workers--switches))))
      (error (list :live nil :error (error-message-string err))))))

(defun drgnx-workers-doctor--names (switches on)
  "The names of SWITCHES (an alist) whose value is ON (t or nil), comma-separated, or \"none\"."
  (let ((l (cl-loop for s in switches when (eq (and (cdr s) t) on) collect (symbol-name (car s)))))
    (if l (string-join l ", ") "none")))

(defun drgnx-workers-doctor--fallbacks (stats)
  "STATS' fallback reasons summed over the workers: an alist (REASON . COUNT), in order of first appearance."
  (let (sum)
    (dolist (w drgnx-workers-doctor--workers)
      (dolist (f (plist-get (plist-get stats (car w)) :fallbacks))
        (let ((cell (assq (car f) sum)))
          (if cell (cl-incf (cdr cell) (cdr f)) (setq sum (append sum (list (cons (car f) (cdr f)))))))))
    sum))

(defun drgnx-workers-doctor--worst (stats)
  "The worker of STATS whose fallbacks are most over the share of its jobs: (KEY JOBS FALLBACKS), or nil."
  (let (worst (worst-share 0))
    (dolist (w drgnx-workers-doctor--workers)
      (let* ((s (plist-get stats (car w)))
             (jobs (or (plist-get s :jobs) 0))
             (fb (cl-loop for f in (plist-get s :fallbacks)
                          unless (memq (car f) drgnx-workers-doctor--not-fallbacks) sum (cdr f))))
        (when (and (> jobs 0) (> (/ (float fb) jobs) drgnx-workers-doctor-fallback-share)
                   (> (/ (float fb) jobs) worst-share))
          (setq worst (list (car w) jobs fb) worst-share (/ (float fb) jobs)))))
    worst))

(defun drgnx-workers-doctor--check (facts)
  "The `workers' check on FACTS: (STATUS DETAIL FIX)."
  (let ((w (plist-get facts :workers)))
    (cond
     ((null w)
      (list 'info "work off the main thread needs Nidhogg 31.1-nidhogg.N or newer" drgnx-workers-doctor-update-fix))
     ((not (plist-get w :live))
      ;; a batch Emacs: the build and its defaults, never counters
      (let ((sw (plist-get w :switches)))
        (list 'info
              (format "this build has work off the main thread; on by default: %s; off by default: %s; \
the editor's counters are not visible from `drgnx doctor'"
                      (drgnx-workers-doctor--names sw t) (drgnx-workers-doctor--names sw nil))
              nil)))
     (t
      (let* ((sw (plist-get w :switches)) (stats (plist-get w :stats))
             (off (drgnx-workers-doctor--names sw nil))
             (fb (drgnx-workers-doctor--fallbacks stats))
             (running (cl-loop for k in drgnx-workers-doctor--workers
                               sum (or (plist-get (plist-get stats (car k)) :running) 0)))
             (worst (drgnx-workers-doctor--worst stats))
             (on (format "workers on: %s; running: %d" (drgnx-workers-doctor--names sw t) running)))
        (cond
         (worst
          (let ((key (car worst)))
            (list 'warn
                  (format "%s; %s took today's path for %d of %d jobs since start (%s)" on
                          (substring (symbol-name key) 1) (nth 2 worst) (nth 1 worst)
                          (mapconcat (lambda (f) (format "%s %d" (car f) (cdr f))) fb ", "))
                  (if (eq key :nh-blk)
                      ;; nh-blk also runs directory reads and file blocks, which their callers ask for: no switch
                      "set nidhogg-workers-dns to nil to take host-name lookups back to the main thread (nh-blk's \
directory reads and file blocks have no switch: their callers ask for them); the reasons are in `nidhogg-workers-stats'"
                    (format "set %s to nil to take that work back to the main thread; the reasons are in `nidhogg-workers-stats'"
                            (cdr (assq key drgnx-workers-doctor--workers)))))))
         ((or fb (not (equal off "none")))
          (list 'info
                (concat on "; off: " off
                        (and fb (format "; fallbacks: %s" (mapconcat (lambda (f) (format "%s %d" (car f) (cdr f))) fb ", "))))
                nil))
         (t (list 'ok on nil))))))))

(drgnx-doctor-define 'workers :group "Speed" :doc "Work off the main thread is on and not falling back"
                     :check #'drgnx-workers-doctor--check)

(provide 'drgnx-workers-doctor)
;;; drgnx-workers-doctor.el ends here
