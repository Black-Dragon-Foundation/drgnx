;;; drgnx-problems.el --- The Problems view: every error and warning of the project, in the panel -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One Problems view, as VS Code's (audit D1: there were two, Flymake's raw list and the Notices page): the errors,
;; warnings and notes Flymake holds for the buffers of the project, grouped by file (the file's name, its folder and
;; its count), each row the severity's mark, the message, its source and `[Ln L, Col C]'.  Return or a click goes
;; there.  With nothing to show it says so.  It lives in the panel's Problems tab (wb/drgnx-area.el).  Flymake's own
;; listings are kept up to date by `flymake--update-diagnostics-listings'; the module that defines Problems (lang/eglot)
;; follows that function to redraw this view, debounced, only while a window shows it.  drgnx's own problems (a
;; module waiting for packages) are notices, in the Notices list, not here.  See docs/guide/modules.md (lang/eglot).

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-timer)
(require 'drgnx-faces)
(require 'drgnx-ui-kit)                 ; `drgnx-status-fail', `-warn', `-info'

(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-type "flymake" (diag))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function flymake-diagnostic-backend "flymake" (diag))
(declare-function flymake--lookup-type-property "flymake" (type prop &optional default))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(defvar flymake-mode)

(defconst drgnx-problems-buffer-name "*drgnx problems*" "The Problems view's buffer.")

(defconst drgnx-problems-empty "No problems have been detected in the workspace."
  "What the view says with nothing to show (VS Code's words).")

(defvar-local drgnx-problems--root nil "The folder whose problems the view lists, or nil (every file's).")

(defvar-keymap drgnx-problems-mode-map
  :doc "Keys of the Problems view: Return goes to the problem, `g' lists again."
  "RET" #'drgnx-problems-goto
  "<mouse-2>" #'drgnx-problems-goto-mouse
  "<mouse-1>" #'drgnx-problems-goto-mouse)

(define-derived-mode drgnx-problems-mode special-mode "Problems"
  "The errors and warnings of the project, by file.  RET goes to one; \\`g' lists them again."
  (setq-local revert-buffer-function #'drgnx-problems--revert)
  (setq-local truncate-lines t)
  (buffer-disable-undo))

(defun drgnx-problems--severity (diag)
  "DIAG's severity: `error', `warning' or `note'."
  (pcase (flymake--lookup-type-property (flymake-diagnostic-type diag) 'flymake-category)
    ('flymake-error 'error) ('flymake-warning 'warning) (_ 'note)))

(defun drgnx-problems--buffers (root)
  "The live buffers with Flymake on that visit a file under ROOT (every one with ROOT nil), by file name."
  (let (out)
    (dolist (b (buffer-list))
      (let ((file (buffer-file-name b)))
        (when (and file (buffer-local-value 'flymake-mode b)
                   (or (null root) (file-in-directory-p file root)))
          (push b out))))
    (sort out (lambda (a b) (string< (buffer-file-name a) (buffer-file-name b))))))

(defun drgnx-problems-collect (root)
  "The problems under ROOT: a list of (FILE . DIAGS), DIAGS as (SEVERITY TEXT SOURCE LINE COL BUFFER POS) sorted
errors first, then by place."
  (let (out)
    (dolist (b (drgnx-problems--buffers root))
      (with-current-buffer b
        (let (rows)
          (dolist (d (flymake-diagnostics))
            (let ((pos (flymake-diagnostic-beg d)))
              (save-excursion
                (save-restriction
                  (widen)
                  (goto-char pos)
                  (push (list (drgnx-problems--severity d) (flymake-diagnostic-text d)
                              (let ((be (flymake-diagnostic-backend d)))
                                (and (symbolp be) (string-remove-suffix "-flymake" (symbol-name be))))
                              (line-number-at-pos) (1+ (current-column)) b pos)
                        rows)))))
          (when rows
            (push (cons (buffer-file-name b)
                        (sort rows (lambda (x y)
                                     (let ((rx (cl-position (car x) '(error warning note)))
                                           (ry (cl-position (car y) '(error warning note))))
                                       (if (= rx ry) (< (nth 6 x) (nth 6 y)) (< rx ry))))))
                  out)))))
    (nreverse out)))

(defun drgnx-problems--mark (severity)
  (pcase severity
    ('error (propertize "✕" 'face 'drgnx-status-fail))
    ('warning (propertize "⚠" 'face 'drgnx-status-warn))
    (_ (propertize "ⓘ" 'face 'drgnx-status-info))))

(defun drgnx-problems--insert (groups)
  "Insert GROUPS (`drgnx-problems-collect') as the view's rows."
  (if (null groups)
      (insert "  " (propertize drgnx-problems-empty 'face 'drgnx-text-muted) "\n")
    (pcase-dolist (`(,file . ,rows) groups)
      (insert (propertize (file-name-nondirectory file) 'face 'bold) "  "
              (propertize (abbreviate-file-name (directory-file-name (file-name-directory file))) 'face 'drgnx-text-subtle)
              "  " (propertize (number-to-string (length rows)) 'face 'drgnx-text-muted) "\n")
      (pcase-dolist (`(,sev ,text ,source ,line ,col ,buffer ,pos) rows)
        (let ((start (point)))
          (insert "    " (drgnx-problems--mark sev) " " (car (split-string text "\n"))
                  (if source (propertize (format "  %s" source) 'face 'drgnx-text-subtle) "")
                  (propertize (format "  [Ln %d, Col %d]" line col) 'face 'drgnx-text-subtle) "\n")
          (put-text-property start (point) 'drgnx-problem (cons buffer pos))
          (put-text-property start (1- (point)) 'mouse-face 'highlight))))))

(defun drgnx-problems--revert (&rest _)
  "List the problems again, keeping point's line."
  (let ((inhibit-read-only t) (line (line-number-at-pos)))
    (erase-buffer)
    (drgnx-problems--insert (drgnx-problems-collect drgnx-problems--root))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun drgnx-problems--root-here ()
  (require 'project)
  (when-let* ((p (project-current nil))) (expand-file-name (project-root p))))

(defun drgnx-problems-buffer ()
  "The Problems view's buffer, made if need be and listing this project's problems now (the panel's Problems tab shows it)."
  (let ((root (drgnx-problems--root-here))
        (buffer (get-buffer-create drgnx-problems-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-problems-mode) (drgnx-problems-mode))
      (setq drgnx-problems--root root)
      (drgnx-problems--revert))
    buffer))

;;;###autoload
(defun drgnx-problems-show ()
  "Show the Problems view: the errors and warnings of this project, by file, in the panel."
  (interactive)
  (let ((buffer (drgnx-problems-buffer)))
    (pop-to-buffer buffer)
    buffer))

(defun drgnx-problems-goto ()
  "Go to the problem on this row."
  (interactive)
  (pcase (get-text-property (point) 'drgnx-problem)
    (`(,buffer . ,pos)
     (unless (buffer-live-p buffer) (user-error "That file is closed"))
     (pop-to-buffer buffer)
     (goto-char pos))
    (_ (user-error "No problem here"))))

(defun drgnx-problems-goto-mouse (event)
  "Go to the problem clicked (EVENT)."
  (interactive "e")
  (mouse-set-point event)
  (drgnx-problems-goto))

(defun drgnx-problems--redraw ()
  "The debounce: list the problems again when a window shows the view."
  (when-let* ((b (get-buffer drgnx-problems-buffer-name)) ((get-buffer-window b)))
    (with-current-buffer b (drgnx-problems--revert))))

(defun drgnx-problems-follow (&rest _)
  "After Flymake updated its listings: redraw the view soon (debounced; nothing while no window shows it)."
  (when-let* ((b (get-buffer drgnx-problems-buffer-name)) ((get-buffer-window b)))
    (drgnx-timer-start 'problems-view 0.2 #'drgnx-problems--redraw :owner b)))

(provide 'drgnx-problems)
;;; drgnx-problems.el ends here
