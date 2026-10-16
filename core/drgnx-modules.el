;;; drgnx-modules.el --- A minimal module system -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A module is one file `modules/<category>/drgnx-<name>.el' with one `drgnx-module-define'.
;; Modules run in stages (`startup' now, `idle' once Emacs is idle), each under its own error
;; guard and timed; `drgnx-modules-report' says what loaded, how long it took and what failed.
;; Flags, settings, doctor checks and more stages arrive with M4 (docs/roadmap.md).

;;; Code:
(require 'cl-lib)

(defvar drgnx-modules--table nil "Alist NAME → plist (:doc :stage :setup :file), in definition order.")
(defvar drgnx-modules--report nil "Alist NAME → plist (:stage :ms :error).")

(cl-defun drgnx-module-define (name &key doc stage setup)
  "Define module NAME (a symbol like core/basics): DOC, STAGE (startup or idle), SETUP (a function)."
  (let ((entry (list :doc doc :stage (or stage 'startup) :setup setup :file load-file-name)))
    (if (assq name drgnx-modules--table)
        (setf (alist-get name drgnx-modules--table) entry)
      (setq drgnx-modules--table (append drgnx-modules--table (list (cons name entry))))))
  name)

(defun drgnx-modules--record (name stage ms err)
  (setf (alist-get name drgnx-modules--report) (list :stage stage :ms ms :error err)))

(defun drgnx-modules-run (stage)
  "Run the setup of every module of STAGE, each isolated and timed."
  (dolist (m drgnx-modules--table)
    (when (eq (plist-get (cdr m) :stage) stage)
      (let* ((t0 (float-time))
             (err (condition-case e (progn (funcall (plist-get (cdr m) :setup)) nil)
                    (error (error-message-string e)))))
        (drgnx-modules--record (car m) stage (round (* 1000 (- (float-time) t0))) err)))))

(defun drgnx-modules-load-directory (dir)
  "Load every module file under DIR (modules/<category>/drgnx-*.el); a file that fails to
load is reported as module <category>/<file name>."
  (dolist (file (directory-files-recursively dir "\\`drgnx-.*\\.el\\'"))
    (let ((t0 (float-time)))
      (condition-case e
          (load file nil t)
        (error (drgnx-modules--record
                (intern (format "%s/%s" (file-name-nondirectory (directory-file-name (file-name-directory file)))
                                (file-name-base file)))
                'load (round (* 1000 (- (float-time) t0))) (error-message-string e)))))))

(defun drgnx-modules-report () drgnx-modules--report)

(defun drgnx-modules-start (dir)
  "Load the modules in DIR, run the startup stage now and the idle stage when Emacs is idle."
  (drgnx-modules-load-directory dir)
  (drgnx-modules-run 'startup)
  (run-with-idle-timer 1 nil #'drgnx-modules-run 'idle))

(defun drgnx-modules-show-report ()
  "Which modules ran, in which stage, how long they took, and what failed."
  (interactive)
  (with-help-window "*drgnx modules*"
    (with-current-buffer standard-output
      (insert "drgnx modules\n\n")
      (dolist (m (reverse drgnx-modules--report))
        (insert (format "  %-28s %-8s %5d ms  %s\n" (car m) (plist-get (cdr m) :stage) (plist-get (cdr m) :ms)
                        (or (plist-get (cdr m) :error) "ok")))))))

(provide 'drgnx-modules)
;;; drgnx-modules.el ends here
