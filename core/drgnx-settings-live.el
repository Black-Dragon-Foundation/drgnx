;;; drgnx-settings-live.el --- Settings: changes apply at once; the end-of-init pass -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 13 (docs/develop/settings.md, "Live changes and :apply").
;; - `drgnx-settings-live-start' watches the directory of settings.el (`file-notify') and checks the files' stamps on
;;   frame focus and from `drgnx-settings-live-check' (the Settings page calls it before it draws), so a hand edit,
;;   another process's write, a rename over the file or a pull applies at once.
;; - `drgnx-settings-live-sync' re-applies a changed file through `drgnx-settings-apply-global' (idempotent), lets
;;   go of what the file no longer names (`drgnx-settings-let-go'), and runs `drgnx-settings-changed-functions'.  Nothing prompts or signals.
;; - A change to an own setting's variable (from any layer) queues its `:apply'; the queue runs on an idle tick through
;;   `drgnx-timer' (key `settings-apply'), never inside the watcher.  `drgnx-settings-apply-pass' runs the `:apply'
;;   of every own setting whose value changed while Emacs started (a `setq' in config.el included).
;; - The workspace files drgnx has read (W1 and W2 of the open projects, Task 17) are watched too: a change re-hacks
;;   the open buffers of their roots (`drgnx-settings-workspace-sync').

;;; Code:
(require 'cl-lib)
(require 'filenotify)
(require 'drgnx-setting)
(require 'drgnx-timer)
(require 'drgnx-file)
(require 'drgnx-settings-file)
(require 'drgnx-settings-apply)
(require 'drgnx-settings-workspace)

(declare-function drgnx-settings-prov-watch "drgnx-settings-prov" (var))
(declare-function drgnx-config-file "drgnx-config" (name &optional root))

(defvar drgnx-settings-changed-functions nil
  "Abnormal hook run after a settings file was re-read and something changed: each function gets FILE and CHANGES,
a list of (SCOPE VAR OLD NEW).  SCOPE is a scope path (nil: top level); OLD or NEW is `:unset' when the entry was
added or removed.  A function that signals is skipped; nothing here prompts.")

(defvar drgnx-settings-live--stamps (make-hash-table :test 'equal) "File -> the `drgnx-file-stamp' last synced.")
(defvar drgnx-settings-live--watches nil "The file-notify descriptors, by directory: (DIR . DESCRIPTOR).")
(defvar drgnx-settings-live--watched (make-hash-table :test 'eq) "Own variables with the `:apply' watcher.")
(defvar drgnx-settings-live--queue nil "Variables whose `:apply' waits for an idle tick, newest first.")
(defvar drgnx-settings-live--applied (make-hash-table :test 'eq) "Variable -> the value its `:apply' last ran for.")

(defun drgnx-settings-live-files ()
  "The settings files watched: settings.el, then the workspace files drgnx has read (the open projects' W1 and W2,
`drgnx-settings-workspace-files')."
  (cons (drgnx-config-file 'settings) (drgnx-settings-workspace-files)))

(defun drgnx-settings-live--global-p (file)
  "Non-nil when FILE is settings.el."
  (equal (expand-file-name file) (expand-file-name (drgnx-config-file 'settings))))

;;;; :apply

(defun drgnx-settings-live--apply-fn (var)
  "VAR's `:apply' function, or nil."
  (plist-get (drgnx-setting-meta var) :apply))

(defun drgnx-settings-live--run-apply (var)
  "Run VAR's `:apply' (no arguments; it reads the variable) and remember the value it ran for.  Never signals."
  (when-let* ((fn (drgnx-settings-live--apply-fn var)))
    (puthash var (and (default-boundp var) (default-value var)) drgnx-settings-live--applied)
    (condition-case err (let ((inhibit-interaction t)) (funcall fn))
      (error (drgnx-settings-file--warn (format ":apply of %s failed: %s" var (error-message-string err)))))))

(defun drgnx-settings-live--run-queue ()
  "Run the queued `:apply's (the idle tick)."
  (let ((vars (nreverse drgnx-settings-live--queue)))
    (setq drgnx-settings-live--queue nil)
    (dolist (var vars)
      (drgnx-settings-live--run-apply var))))

(defun drgnx-settings-live--enqueue (var)
  "Queue VAR's `:apply' for the next idle tick (once)."
  (unless (memq var drgnx-settings-live--queue)
    (push var drgnx-settings-live--queue))
  (drgnx-timer-start 'settings-apply 0.2 #'drgnx-settings-live--run-queue :idle t :owner :core))

(defun drgnx-settings-live--watcher (symbol _newval operation _where)
  "Variable watcher of an own setting: queue SYMBOL's `:apply'.  Only queues."
  (unless (memq operation '(let unlet))
    (when (drgnx-settings-live--apply-fn symbol)
      (drgnx-settings-live--enqueue symbol))))

(defun drgnx-settings-live--watch-own ()
  "Watch every own setting that has an `:apply' (idempotent; settings declared later join at the next call)."
  (dolist (var (drgnx-setting-names))
    (when (and (not (gethash var drgnx-settings-live--watched)) (drgnx-settings-live--apply-fn var))
      (add-variable-watcher var #'drgnx-settings-live--watcher)
      (puthash var t drgnx-settings-live--watched))))

(defun drgnx-settings-apply-pass ()
  "Run `:apply' for every own setting whose value changed while Emacs started (the end-of-init pass).
That is a value not equal to its default that no `:apply' has run for yet: settings.el's, a `setq' in config.el.
Never signals, never prompts."
  (condition-case err
      (dolist (var (drgnx-setting-names))
        (when (and (drgnx-settings-live--apply-fn var) (default-boundp var))
          (let* ((val (default-value var))
                 (done (gethash var drgnx-settings-live--applied 'none)))
            (unless (if (eq done 'none) (custom--standard-value-p var val) (equal val done))
              (drgnx-settings-live--run-apply var)))))
    (error (drgnx-settings-file--warn (format "the :apply pass failed: %s" (error-message-string err))))))

;;;; Reading a changed file

(defun drgnx-settings-live--changes (old new)
  "The (SCOPE VAR OLD NEW) list between the applied entries OLD and NEW, both ((VAR . ENTRY)…)."
  (let (changes)
    (dolist (cell new)
      (let ((o (assq (car cell) old)))
        (unless (and o (equal (drgnx-settings-entry-value (cdr o)) (drgnx-settings-entry-value (cdr cell))))
          (push (list nil (car cell) (if o (drgnx-settings-entry-value (cdr o)) :unset)
                      (drgnx-settings-entry-value (cdr cell)))
                changes))))
    (dolist (cell old)
      (unless (assq (car cell) new)
        (push (list nil (car cell) (drgnx-settings-entry-value (cdr cell)) :unset) changes)))
    (nreverse changes)))

(defun drgnx-settings-live--run-changed (file changes)
  "Run `drgnx-settings-changed-functions' with FILE and CHANGES (when there are any); CHANGES."
  (when changes
    (run-hook-wrapped 'drgnx-settings-changed-functions
                      (lambda (fn)
                        (condition-case e (funcall fn file changes)
                          (error (drgnx-settings-file--warn (format "%s, run because %s changed, failed: %s" fn file
                                                                    (error-message-string e)))))
                        nil)))
  changes)

(defun drgnx-settings-live-sync (file)
  "Read FILE again and apply what changed; the changes, a list of (SCOPE VAR OLD NEW).
For settings.el: `drgnx-settings-apply-global' pushes every entry (idempotent), variables the file no longer names
are let go (`drgnx-settings-let-go': modules' claims on them stay), new ones are watched for provenance, and `drgnx-settings-changed-functions' runs with FILE and the
changes.  For a workspace file: `drgnx-settings-workspace-sync' re-hacks its roots' open buffers when it changed, and
the hook runs the same way.  Another file only has its stamp recorded.  Nothing prompts; a failure is one notice
and nil."
  (condition-case err
      (let ((inhibit-interaction t))
        (puthash file (drgnx-file-stamp file) drgnx-settings-live--stamps)
        (cond
         ((drgnx-settings-live--global-p file)
          (drgnx-settings-live--watch-own)
          (let ((old drgnx-settings-apply--entries))
            (drgnx-settings-apply-global)               ; nil for no entries as well as for a failure: the entries say
            (let ((new drgnx-settings-apply--entries))
              (dolist (cell old)
                (unless (assq (car cell) new) (drgnx-settings-let-go (car cell))))   ; claims stay
              (when (fboundp 'drgnx-settings-prov-watch)
                (dolist (cell new) (drgnx-settings-prov-watch (car cell))))
              (drgnx-settings-live--run-changed file (drgnx-settings-live--changes old new)))))
         ((drgnx-settings-workspace-file-p file)
          (drgnx-settings-live--run-changed file (drgnx-settings-workspace-sync file)))))
    (error (drgnx-settings-file--warn (format "applying %s failed: %s" file (error-message-string err))) nil)))

(defun drgnx-settings-live-check (&optional files)
  "Sync every file of FILES (default `drgnx-settings-live-files') whose stamp is not the one last synced.
Cheap when nothing changed: one `file-attributes' per file.  Returns the files synced.  Never signals."
  (let (synced)
    (condition-case err
        (dolist (file (or files (drgnx-settings-live-files)))
          (unless (equal (drgnx-file-stamp file) (gethash file drgnx-settings-live--stamps))
            (drgnx-settings-live-sync file)
            (push file synced)))
      (error (drgnx-settings-file--warn (format "the settings files' stamp check failed: %s"
                                                (error-message-string err)))))
    (nreverse synced)))

;;;; Watching

(defun drgnx-settings-live--event (event)
  "file-notify callback for EVENT: a change to a watched file is synced (the stamp says whether it really changed)."
  (condition-case nil
      (let ((files (drgnx-settings-live-files)))
        (when (cl-some (lambda (f) (member (expand-file-name f)
                                           (mapcar #'expand-file-name (delq nil (list (nth 2 event) (nth 3 event))))))
                       files)
          (drgnx-settings-live-check files)))
    (error nil)))

(defun drgnx-settings-live--focus ()
  "`after-focus-change-function': the stamp check when a frame got focus."
  (when (cl-some (lambda (f) (eq (frame-focus-state f) t)) (frame-list))
    (drgnx-settings-live-check)))

(defun drgnx-settings-live-stop ()
  "Take the watches, the focus hook, the queue and its timer away."
  (pcase-dolist (`(,_ . ,desc) drgnx-settings-live--watches)
    (ignore-errors (file-notify-rm-watch desc)))
  (setq drgnx-settings-live--watches nil drgnx-settings-live--queue nil)
  (remove-function after-focus-change-function #'drgnx-settings-live--focus)
  (drgnx-timer-cancel 'settings-apply))

(defun drgnx-settings-live--watch-file (file)
  "Record FILE's stamp and watch its directory (once per directory)."
  (puthash file (drgnx-file-stamp file) drgnx-settings-live--stamps)
  (let ((dir (file-name-directory file)))
    (when (and (file-directory-p dir) (not (assoc dir drgnx-settings-live--watches)))
      (when-let* ((desc (ignore-errors
                          (file-notify-add-watch dir '(change) #'drgnx-settings-live--event))))
        (push (cons dir desc) drgnx-settings-live--watches)))))

(defun drgnx-settings-live-watch (file)
  "Watch settings FILE too (a workspace file read for the first time), once live changes have started; else
nothing.  Never signals."
  (when (advice-function-member-p #'drgnx-settings-live--focus after-focus-change-function)
    (condition-case nil (drgnx-settings-live--watch-file (expand-file-name file))
      (error nil))))

(defun drgnx-settings-live-start ()
  "Start watching the settings files, so a change applies at once; idempotent.  Never signals."
  (condition-case err
      (progn
        (drgnx-settings-live-stop)
        (dolist (file (drgnx-settings-live-files))
          (drgnx-settings-live--watch-file file))
        (drgnx-settings-live--watch-own)
        (add-function :after after-focus-change-function #'drgnx-settings-live--focus))
    (error (drgnx-settings-file--warn (format "watching the settings files failed: %s" (error-message-string err))))))

(provide 'drgnx-settings-live)
;;; drgnx-settings-live.el ends here
