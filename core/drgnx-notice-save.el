;;; drgnx-notice-save.el --- Each Emacs writes its own notice session file; the doctor reads it -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The session route of the notice model (drgnx-notice.el).  While `drgnx-notice-save-mode' is on, a change of the
;; model schedules one write, 2 s into idleness, of `<state>/notices/<PID>.eld': the conditions and the last 50
;; warn/fail events, as readable data.  At exit the file is renamed to `last.eld' (the last session).  Every Emacs
;; has its own file, so two running Emacsen never overwrite each other, and `drgnx doctor' (a separate process)
;; can say what the live ones tell, with their ages.  The first write of a session also deletes the files of dead
;; processes older than 7 days.  Files go through `drgnx-file-write'; the timer through `drgnx-timer-start'.
;; Never a prompt.  Core: it requires nothing in wb/ or modules/.  See docs/develop/core.md, "Notices".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-notice)
(require 'drgnx-timer)

(defconst drgnx-notice-save-event-limit 50 "How many warn/fail events a session file holds (the newest).")

(defconst drgnx-notice-save-keep-days 7 "How long the file of a dead process stays: days.")

(defvar drgnx-notice--save-pruned nil "Non-nil once this session has pruned the old files.")

;;;; Where

(defun drgnx-notice-save-dir ()
  "The folder of the session files: `notices' in the state dir."
  (expand-file-name "notices" (drgnx-state-dir)))

(defun drgnx-notice-save-file (&optional pid)
  "The session file of process PID (default this Emacs): `<state>/notices/<PID>.eld'."
  (expand-file-name (format "%d.eld" (or pid (emacs-pid))) (drgnx-notice-save-dir)))

(defun drgnx-notice-save-last-file ()
  "The file the last session left at exit: `<state>/notices/last.eld'."
  (expand-file-name "last.eld" (drgnx-notice-save-dir)))

(defun drgnx-notice-save-pid-live-p (pid)
  "Non-nil when PID is an Emacs (its process name starts with \"emacs\" or \"nidhogg\") that is running."
  (let ((comm (alist-get 'comm (process-attributes pid))))
    (and (stringp comm) (string-match-p "\\`\\(emacs\\|nidhogg\\)" comm))))

;;;; What

(defun drgnx-notice--save-notice (notice)
  "NOTICE as data for the file: no text properties, and only what reads back (an unreadable `:command' goes; an
unreadable id becomes its printed form)."
  (let ((out nil))
    (cl-loop for (k v) on notice by #'cddr
             do (cond ((stringp v) (setq out (cons (substring-no-properties v) (cons k out))))
                      ((drgnx-notice--readable-p v) (setq out (cons v (cons k out))))
                      ((eq k :id) (setq out (cons (format "%S" v) (cons k out))))))
    (nreverse out)))

(defun drgnx-notice--save-notices ()
  "The conditions, then the newest warn/fail events (newest first), as data."
  (let ((conditions nil) (events nil) (n 0))
    (maphash (lambda (_key notice) (when (eq (plist-get notice :life) 'condition) (push notice conditions)))
             drgnx-notice--table)
    (dolist (key drgnx-notice--events)
      (let ((notice (gethash key drgnx-notice--table)))
        (when (and notice (< n drgnx-notice-save-event-limit) (memq (plist-get notice :severity) '(warn fail)))
          (setq n (1+ n))
          (push notice events))))
    (mapcar #'drgnx-notice--save-notice
            (append (sort conditions (lambda (a b) (< (or (plist-get a :at) 0) (or (plist-get b :at) 0))))
                    (nreverse events)))))

(defun drgnx-notice--save-prune ()
  "Delete the session files of dead processes older than `drgnx-notice-save-keep-days' days."
  (let ((limit (time-subtract nil (* drgnx-notice-save-keep-days 86400))))
    (dolist (file (directory-files (drgnx-notice-save-dir) t "\\`[0-9]+\\.eld\\'"))
      (let ((mtime (file-attribute-modification-time (file-attributes file))))
        (when (and mtime (time-less-p mtime limit)
                   (not (drgnx-notice-save-pid-live-p (string-to-number (file-name-base file)))))
          (ignore-errors (delete-file file)))))))

(defun drgnx-notice--save ()
  "Write this Emacs's session file now."
  (let ((file (drgnx-notice-save-file)))
    (drgnx-file-write file
                      (list :version 1 :pid (emacs-pid) :emacs emacs-version :daemon (and (daemonp) t)
                            :started (float-time before-init-time) :written (float-time)
                            :notices (drgnx-notice--save-notices))
                      :fsync nil)
    (unless drgnx-notice--save-pruned
      (setq drgnx-notice--save-pruned t)
      (drgnx-notice--save-prune))
    file))

;;;; When

(defun drgnx-notice--save-soon (&optional _change)
  "Write the file once Emacs has been idle for 2 s (a change meanwhile is in that write)."
  (unless (drgnx-timer-active-p 'notices-save)
    (drgnx-timer-start 'notices-save 2 #'drgnx-notice--save :idle t :owner :core)))

(defun drgnx-notice--save-at-exit ()
  "On `kill-emacs-hook': write the file and rename it to `last.eld'; a failure is a message, never a stop."
  (drgnx-timer-cancel 'notices-save)
  (condition-case err
      (rename-file (drgnx-notice--save) (drgnx-notice-save-last-file) t)
    (error (message "drgnx: the notice session file was not written: %s" (error-message-string err)))))

(define-minor-mode drgnx-notice-save-mode
  "Keep this Emacs's notices in its session file, for the doctor and the next session.
A change writes the file when Emacs has been idle for 2 s; exit leaves it as `last.eld'."
  :global t :group 'drgnx
  (if drgnx-notice-save-mode
      (progn (add-hook 'drgnx-notice-functions #'drgnx-notice--save-soon)
             (add-hook 'kill-emacs-hook #'drgnx-notice--save-at-exit)
             (drgnx-notice--save-soon))
    (remove-hook 'drgnx-notice-functions #'drgnx-notice--save-soon)
    (remove-hook 'kill-emacs-hook #'drgnx-notice--save-at-exit)
    (drgnx-timer-cancel 'notices-save)))

(provide 'drgnx-notice-save)
;;; drgnx-notice-save.el ends here
