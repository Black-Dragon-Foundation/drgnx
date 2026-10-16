;;; drgnx-modules.el --- The module system -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A module is one file `modules/<category>/drgnx-<name>.el' with one `drgnx-module-define'.  It
;; runs in a stage — `startup', `idle' (once Emacs is idle), `first-frame', `first-file',
;; `first-input' — under its own error guard, timed.  It may require other modules, need packages
;; (it waits, reported, until they are installed: Emacs never installs anything by itself), have
;; flags, doctor checks and settings.  The user's choices live in modules.eld in the user dir
;; (`drgnx-user-dir'): disabled modules, flags, external modules; older formats are migrated, an
;; unreadable file is reported and ignored.  Preferences: Modules lists every module with its
;; status and turns modules on and off.  See docs/modules.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)
(require 'drgnx-paths)
(require 'drgnx-hooks)

(defvar drgnx-modules--table nil "Alist NAME → plist (:doc :stage … :file), in definition order.")
(defvar drgnx-modules--report nil "Alist NAME → plist (:stage :ms :status :error :missing).")
(defvar drgnx-modules--state nil "The user's modules.eld, read once.")
(defconst drgnx-modules-stages '(startup idle first-frame first-file first-input))
(defconst drgnx-modules-state-version 1 "Format of modules.eld.")

(cl-defun drgnx-module-define (name &key doc stage setup requires packages flags doctor settings)
  "Define module NAME (a symbol like lang/python).
DOC: one line.  STAGE: one of `drgnx-modules-stages' (default startup).  SETUP: a function.
REQUIRES: modules that must have run.  PACKAGES: features that must be loadable (else the module
waits, reported as missing-packages).  FLAGS: the flags it understands (`drgnx-module-flag-p').
DOCTOR: a function returning problem strings.  SETTINGS: alist VARIABLE → doc."
  (let ((entry (list :doc doc :stage (or stage 'startup) :setup setup :requires requires :packages packages
                     :flags flags :doctor doctor :settings settings :file load-file-name)))
    (if (assq name drgnx-modules--table)
        (setf (alist-get name drgnx-modules--table) entry)
      (setq drgnx-modules--table (append drgnx-modules--table (list (cons name entry))))))
  name)

;;;; modules.eld

(defun drgnx-modules--state-file () (expand-file-name "modules.eld" (drgnx-user-dir)))

(defun drgnx-modules--migrate (data)
  "DATA from any format → the current one, or nil if it is not a modules.eld."
  (cond ((and (listp data) (keywordp (car data)) (eql (plist-get data :version) drgnx-modules-state-version)) data)
        ((and (listp data) (seq-every-p #'symbolp data))         ; version 0: the disabled modules
         (list :version drgnx-modules-state-version :disabled data))))

(defun drgnx-modules-read-state ()
  "The user's modules.eld (migrated), or defaults; never an error at start."
  (or drgnx-modules--state
      (setq drgnx-modules--state
            (let* ((file (drgnx-modules--state-file))
                   (data (and (file-readable-p file)
                              (condition-case err (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
                                (error (message "drgnx: %s is unreadable (%s); modules use their defaults"
                                                file (error-message-string err))
                                       :unreadable)))))
              (or (and data (not (eq data :unreadable))
                       (or (drgnx-modules--migrate data)
                           (progn (message "drgnx: %s is not a modules file; modules use their defaults" file) nil)))
                  (list :version drgnx-modules-state-version))))))

(defun drgnx-modules-write-state (state)
  "Write STATE as the user's modules.eld."
  (let ((file (drgnx-modules--state-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; drgnx modules: what you turned off, module flags, external modules (docs/modules.md).\n")
      (let ((print-length nil) (print-level nil)) (pp (plist-put state :version drgnx-modules-state-version) (current-buffer))))
    (setq drgnx-modules--state nil)
    state))

(defun drgnx-module-flag-p (module flag)
  "Non-nil if the user turned FLAG on for MODULE."
  (memq flag (alist-get module (plist-get (drgnx-modules-read-state) :flags))))

(defun drgnx-module-disabled-p (module) (memq module (plist-get (drgnx-modules-read-state) :disabled)))

;;;; Running

(defun drgnx-modules--record (name stage ms status &optional err missing)
  (setf (alist-get name drgnx-modules--report)
        (list :stage stage :ms ms :status status :error err :missing missing)))

(defun drgnx-modules--ok-p (name) (eq (plist-get (alist-get name drgnx-modules--report) :status) 'ok))

(defvar drgnx-modules-after-stage-functions nil
  "Called with the stage after its modules ran (core re-applies keys and menus after later stages).")

(defun drgnx-modules-run (stage)
  "Run the setup of every module of STAGE, each isolated and timed."
  (dolist (m drgnx-modules--table)
    (let ((name (car m)) (spec (cdr m)))
      (when (eq (plist-get spec :stage) stage)
        (let ((missing (seq-remove (lambda (p) (or (featurep p) (locate-library (symbol-name p))))
                                   (plist-get spec :packages)))
              (unmet (seq-remove #'drgnx-modules--ok-p (plist-get spec :requires))))
          (cond
           ((drgnx-module-disabled-p name) (drgnx-modules--record name stage 0 'disabled))
           (missing (drgnx-modules--record name stage 0 'missing-packages nil missing))
           (unmet (drgnx-modules--record name stage 0 'missing-requires nil unmet))
           (t (let* ((t0 (float-time))
                     (err (condition-case e (progn (funcall (plist-get spec :setup)) nil)
                            (error (error-message-string e)))))
                (drgnx-modules--record name stage (round (* 1000 (- (float-time) t0)))
                                       (if err 'failed 'ok) err))))))))
  (run-hook-with-args 'drgnx-modules-after-stage-functions stage))

(defun drgnx-modules-load-directory (dir)
  "Load every module file under DIR (modules/<category>/drgnx-*.el); a file that fails to
load is reported as module <category>/<file name>."
  (dolist (file (directory-files-recursively dir "\\`drgnx-.*\\.el\\'"))
    (let ((t0 (float-time)))
      (condition-case e
          (load (file-name-sans-extension file) nil t)   ; the .elc when `drgnx build' made one
        (error (drgnx-modules--record
                (intern (format "%s/%s" (file-name-nondirectory (directory-file-name (file-name-directory file)))
                                (file-name-base file)))
                'load (round (* 1000 (- (float-time) t0))) 'failed (error-message-string e)))))))

(defun drgnx-modules-report () drgnx-modules--report)

(defun drgnx-modules-write-report ()
  "Save the report for `drgnx doctor' (it runs in another process)."
  (ignore-errors
    (let ((file (expand-file-name "modules-report.eld" (drgnx-state-dir))))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (let ((print-length nil) (print-level nil))
          (prin1 (mapcar (lambda (m) (cons (car m) (list :status (plist-get (cdr m) :status)
                                                           :error (plist-get (cdr m) :error)
                                                           :missing (plist-get (cdr m) :missing))))
                         drgnx-modules--report)
                 (current-buffer)))))))

(defun drgnx-modules-start (dir)
  "Load the modules in DIR, run the startup stage now and the others when their moment comes."
  (drgnx-modules-load-directory dir)
  (drgnx-modules-run 'startup)
  (run-with-idle-timer 1 nil (lambda () (drgnx-modules-run 'idle) (drgnx-modules-write-report)))
  (pcase-dolist (`(,hook . ,stage) '((drgnx-first-gui-frame-hook . first-frame) (drgnx-first-file-hook . first-file)
                                     (drgnx-first-input-hook . first-input)))
    (add-hook hook (lambda () (drgnx-modules-run stage))))
  (drgnx-modules-write-report))

;;;; Preferences: Modules

(defvar drgnx-modules-list-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m tabulated-list-mode-map) m)
  "Keys come from the key profiles (command `modules-toggle').")

(define-derived-mode drgnx-modules-list-mode tabulated-list-mode "Modules"
  "Every module, its status, and whether it runs at the next start."
  (setq tabulated-list-format [("Module" 26 t) ("Status" 18 t) ("Stage" 12 t) ("ms" 5 t) ("Next start" 18 t) ("About" 0 nil)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun drgnx-modules--entries ()
  (mapcar (lambda (m)
            (let* ((name (car m)) (r (alist-get name drgnx-modules--report)) (st (plist-get r :status)))
              (list name (vector (symbol-name name)
                                 (pcase st ('missing-packages (format "needs %s" (mapconcat #'symbol-name (plist-get r :missing) " ")))
                                       ('missing-requires (format "needs %s" (mapconcat #'symbol-name (plist-get r :missing) " ")))
                                       ('failed (format "failed: %s" (plist-get r :error)))
                                       ('nil "not run yet") (_ (symbol-name st)))
                                 (symbol-name (plist-get (cdr m) :stage))
                                 (format "%s" (or (plist-get r :ms) ""))
                                 (if (drgnx-module-disabled-p name) "off at next start" "on")
                                 (or (plist-get (cdr m) :doc) "")))))
          drgnx-modules--table))

(defun drgnx-modules-list ()
  "Show every module, its status and whether it runs at the next start (\\[drgnx-modules-list-toggle] turns it on or off)."
  (interactive)
  (let ((b (get-buffer-create "*drgnx modules*")))
    (with-current-buffer b
      (drgnx-modules-list-mode)
      (setq tabulated-list-entries #'drgnx-modules--entries)
      (tabulated-list-print t))
    (when (called-interactively-p 'any) (pop-to-buffer b))
    b))

(defun drgnx-modules-toggle (module)
  "Turn MODULE off at the next start, or back on."
  (let* ((state (copy-sequence (drgnx-modules-read-state))) (off (plist-get state :disabled)))
    (drgnx-modules-write-state (plist-put state :disabled (if (memq module off) (remq module off) (append off (list module)))))
    (when-let* ((b (get-buffer "*drgnx modules*"))) (with-current-buffer b (tabulated-list-print t)))))

(defun drgnx-modules-list-toggle ()
  "Turn the module on this row off at the next start, or back on."
  (interactive)
  (when-let* ((m (tabulated-list-get-id))) (drgnx-modules-toggle m)))

(defalias 'drgnx-modules-show-report #'drgnx-modules-list)

(provide 'drgnx-modules)
;;; drgnx-modules.el ends here
