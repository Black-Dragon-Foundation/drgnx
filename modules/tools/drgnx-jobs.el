;;; drgnx-jobs.el --- Jobs as a source of what needs you (module tools/jobs; no view of its own) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What tells you a job needs you when you are not looking: the open cards and the messages to you of the jobs are the
;; `jobs' source of the notice model (`drgnx-notice-set'), so they count in the one "needs you" number and a new one
;; reaches the desktop through the notice routes.  The running jobs are the `jobs' segment of the status bar.  A job's
;; agents show in the Work space (the map, the Board's tasks and the review view).  See docs/guide/jobs.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-notice)
(require 'drgnx-notice-desktop)

;; `jobs' is a segment of the status bar, defined by this module's setup (the bar's library comes with `ui/face')
(declare-function drgnx-statusbar-define-segment "drgnx-statusbar")
(declare-function drgnx-statusbar-refresh "drgnx-statusbar")
(declare-function drgnx-statusbar-source-window "drgnx-statusbar")
(declare-function drgnx-face-glyph "drgnx-ui-kit")
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-work-space-open "drgnx-work-space")

(defvar drgnx-notice--sources)
(defvar drgnx-jobs-attention-mode)

(defun drgnx-jobs--hub ()
  "The hub's client, loaded when it is not yet."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub-client)))

(defun drgnx-jobs--v (x) (unless (memq x '(:null :false)) x))

;;;; What needs you, counted once: the notice model's `jobs' source and the Work space's needs-you strip

(defun drgnx-jobs--source-p ()
  "Non-nil while the `jobs' notice source is defined: the module `tools/jobs' is on."
  (and (gethash 'jobs drgnx-notice--sources) t))

(defun drgnx-jobs--line (text)
  "TEXT as one line of at most 100 characters."
  (truncate-string-to-width (string-join (split-string (format "%s" text) "[\n\r]+" t) " ") 100 nil nil "…"))

(defun drgnx-jobs--items (jobs)
  "The notice items for JOBS (`job/status' summaries): each open card, each message to the user not acted on."
  (let ((items nil))
    (dolist (j jobs)
      (when (member (plist-get j :status) '("proposed" "running" "paused"))
        (let ((job (plist-get j :id)))
          (dolist (c (drgnx-jobs--v (plist-get j :cards)))
            (push (nconc (list :id (cons 'card (plist-get c :id)) :text (format "%s — %s" job (plist-get c :title))
                               :command 'work-needs-you-next :scope job)
                         ;; an overlap card is advice: it counts, it never interrupts
                         (when (equal (plist-get c :kind) "overlap") (list :echo nil)))
                  items))
          (dolist (m (drgnx-jobs--v (plist-get j :messages)))
            (unless (equal (plist-get m :state) "acted")
              (push (list :id (cons 'message (plist-get m :id))
                          :text (drgnx-jobs--line (format "%s — %s: %s" job (plist-get m :sender) (plist-get m :text)))
                          :command 'work-needs-you-next :scope job)
                    items))))))
    (nreverse items)))

(defvar drgnx-jobs--running nil
  "How many jobs run, from the last `job/status' answer; nil when that is not known (no answer, or the hub went away).
The `jobs' segment of the status bar shows it.")

(defun drgnx-jobs--set-running (n)
  "N jobs run (nil: not known): the status bar is drawn again when that changed."
  (unless (eql n drgnx-jobs--running)
    (setq drgnx-jobs--running n)
    (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t))))

(defun drgnx-jobs--segment ()
  "The `jobs' segment: `◎ 2 jobs' while jobs run (what waits on you is the `needs-you' segment's).  Reads the cached count."
  (when-let* (((drgnx-jobs--source-p)) (n drgnx-jobs--running) ((> n 0)))
    ;; a pixel bar: the design's layers icon; a terminal: the busy glyph
    (format "%s %d job%s" (if (fboundp 'drgnx-statusbar--icon) (drgnx-statusbar--icon 'layers 'busy)
                            (or (drgnx-face-glyph 'busy (window-frame (drgnx-statusbar-source-window))) ""))
            n (if (= n 1) "" "s"))))

(defun drgnx-jobs-note-jobs (jobs)
  "Every job's summary (JOBS, as `job/status' lists them) was read: they are the `jobs' set of the notice model, the
one \"needs you\" count's, and the running ones the `jobs' segment's.  The recount calls it; nothing happens while
`tools/jobs' is off (no source)."
  (when (drgnx-jobs--source-p)
    (drgnx-notice-set 'jobs (drgnx-jobs--items jobs))
    (drgnx-jobs--set-running
     (cl-count-if (lambda (j) (equal (plist-get j :status) "running")) (append jobs nil)))
    (force-mode-line-update t)))

(defun drgnx-jobs--unknown (reason)
  "The jobs' count is not known (REASON says why): a count that cannot be read again must not stay as if current."
  (when (drgnx-jobs--source-p)
    (drgnx-notice-set 'jobs :unknown :reason reason)
    (drgnx-jobs--set-running nil)
    (force-mode-line-update t)))

(defun drgnx-jobs--unknown-gone ()
  "`drgnx-hub-disconnect-functions': the hub went away."
  (drgnx-jobs--unknown "Jobs: not known — the hub went away"))

(defun drgnx-jobs--recount ()
  "Count again what needs the user (asynchronously).  A hub that does not answer makes the count not known."
  (condition-case nil
      (progn (drgnx-jobs--hub)
             (drgnx-hub-call "job/status" nil
                             (lambda (r e)
                               (if e (drgnx-jobs--unknown "Jobs: not known — the hub did not answer")
                                 (drgnx-jobs-note-jobs (drgnx-jobs--v (plist-get r :jobs)))))))
    (error (drgnx-jobs--unknown "Jobs: not known — the hub did not answer"))))

(defun drgnx-jobs--schedule-recount ()
  "Count again within a second (once, however many events)."
  (drgnx-timer-soon 'jobs-recount 1 #'drgnx-jobs--recount :owner 'tools/jobs))

(defun drgnx-jobs--event (event _data)
  "`drgnx-hub-event-functions' (while the attention mode is on): a job or a card changed — count again.  A new card
reaches the desktop through the set's `:added' ids (the notice routes), not from here."
  (when (and (member event '("job" "card")) drgnx-jobs-attention-mode)
    (drgnx-jobs--schedule-recount)))

(define-minor-mode drgnx-jobs-attention-mode
  "Jobs as a source of what needs you: the hub's events recount their cards and messages; a lost hub makes
the count not known."
  :global t :group 'drgnx
  (if drgnx-jobs-attention-mode
      (progn (add-hook 'drgnx-hub-event-functions #'drgnx-jobs--event)
             (add-hook 'drgnx-hub-disconnect-functions #'drgnx-jobs--unknown-gone)
             (when (featurep 'drgnx-hub-client) (drgnx-jobs--schedule-recount)))   ; never loads the client by itself
    (remove-hook 'drgnx-hub-event-functions #'drgnx-jobs--event)
    (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-jobs--unknown-gone)))

(defun drgnx-jobs--idle-recount ()
  "Count again, once the hub's client is loaded: the 60 s idle timer's function."
  (when (featurep 'drgnx-hub-client) (drgnx-jobs--recount)))

(drgnx-module-define 'tools/jobs
                     :doc "Jobs: what the open cards and messages of jobs need of you, in the one needs-you count and the status bar; shown in the Work space."
                     :stage 'startup :requires '(tools/agents)
                     :setup
                     (lambda ()
                       ;; the source, its set and the mode's hub hooks go with the module's cleanup stack
                       (drgnx-notice-define-source 'jobs :title "Jobs" :command 'work-needs-you-next)
                       (when (fboundp 'drgnx-statusbar-define-segment)
                         (drgnx-statusbar-define-segment 'jobs :fn #'drgnx-jobs--segment :click 'drgnx-work-space-open
                                                         :help "Jobs; click for what they need of you"))
                       (drgnx-jobs-attention-mode 1)
                       ;; counted again now and then once the hub's client is here (the Agents mirror loads it)
                       (drgnx-timer-start 'jobs-recount-idle 60 #'drgnx-jobs--idle-recount :repeat t :idle t)))

(provide 'drgnx-jobs)
;;; drgnx-jobs.el ends here
