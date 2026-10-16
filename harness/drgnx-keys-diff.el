;;; drgnx-keys-diff.el --- The key-sheet diff against gryphn -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx keys diff --against gryphn [DIR]': every command on gryphn's key sheet (its registry:
;; `gryphn-command-define' forms with a literal id, read — never run — from DIR) against drgnx's
;; VS Code key profile with every module stage run (the user's ELPA when present, gryphn's board,
;; runs, agents, search and LLM files as the external module).  A gryphn command must exist in
;; drgnx (under its id or its drgnx name, `drgnx-keys-diff-aliases') with gryphn's key among its
;; keys, or be explained (`drgnx-keys-diff-explained').  Unexplained lines make the exit non-zero.
;; See docs/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)

(defconst drgnx-keys-diff-aliases
  '((view-explorer . toggle-sidebar) (view-explorer-focus . focus-explorer) (view-buffers-focus . focus-buffers)
    (view-panel . toggle-panel) (view-palette . palette) (view-line-numbers . line-numbers)
    (go-prev-tab . previous-tab) (go-next-tab . next-tab) (view-outline . focus-outline))
  "gryphn id → the drgnx command that does the same.")

(defconst drgnx-keys-diff-explained
  '((workspace-next . "workspaces are deferred (DEFERRED M3e-1); windows (frames) and editor groups cover their use")
    (workspace-prev . "workspaces are deferred (DEFERRED M3e-1)")
    (workspace-switch . "workspaces are deferred (DEFERRED M3e-1)")
    (workspace-save . "workspaces are deferred (DEFERRED M3e-1); the layout itself survives restarts (persist)")
    (workspace-restore . "workspaces are deferred (DEFERRED M3e-1); Restore Workbench Layout covers the layout")
    (workspace-close . "workspaces are deferred (DEFERRED M3e-1)")
    (view-minimap . "minimap is not installed; a minimap module is deferred (DEFERRED M4)")
    (view-dashboard . "a start dashboard competes with the restored workbench; deferred (DEFERRED M4)")
    (dev-mise-trust . "gryphn-mise needs gryphn's bundle loader; mise integration is a drgnx module for M11 (DEFERRED M4)")
    (dev-mise-reload . "gryphn-mise needs gryphn's bundle loader; mise integration is a drgnx module for M11 (DEFERRED M4)"))
  "gryphn id → why it is not in drgnx, or why its key differs (shown with the line).")

(defun drgnx-keys-diff-gryphn-sheet (dir)
  "gryphn's sheet from DIR: (ID TITLE KEY FILE) for every literal `gryphn-command-define'."
  (let (rows)
    (dolist (file (directory-files dir t "\\`gryphn.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (while t
              (let ((form (read (current-buffer))))
                (cl-labels ((walk (x)
                              (when (consp x)
                                (if (and (eq (car x) 'gryphn-command-define) (eq (car-safe (nth 1 x)) 'quote)
                                         (symbolp (cadr (nth 1 x))))          ; not a backquote template
                                    (let ((args (nthcdr 2 x)))
                                      (push (list (cadr (nth 1 x)) (plist-get args :title)
                                                  (and (stringp (plist-get args :key)) (plist-get args :key))
                                                  (file-name-nondirectory file))
                                            rows))
                                  (let ((y x)) (while (consp y) (walk (car y)) (setq y (cdr y))))))))
                  (walk form))))
          (end-of-file nil))))
    (nreverse rows)))

(defun drgnx-keys-diff--drgnx-bindings (gryphn-dir)
  "drgnx's VS Code bindings with every module run: alist ID → keys."
  (let ((elpa (expand-file-name "~/.config/emacs/elpa")))
    (when (file-directory-p elpa)
      (dolist (d (directory-files elpa t "\\`[^.]")) (when (file-directory-p d) (add-to-list 'load-path d t)))))
  (require 'drgnx)
  (let* ((cfg (make-temp-file "drgnx-keys-diff" t))
         (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment)))
    (drgnx--core-commands)
    (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
    (dolist (stage drgnx-modules-stages) (ignore-errors (drgnx-modules-run stage)))
    (drgnx-modules-write-state
     `(:version 1 :external ((:name gryphn :path ,gryphn-dir
                              :features (gryphn-org gryphn-run gryphn-board gryphn-board-ui gryphn-org-ui gryphn-agents
                                         gryphn-search gryphn-llm gryphn-acp gryphn-ide)))))
    (drgnx-modules-load-external)
    (delete-directory cfg t)
    (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-profiles
                                 :layers '((vscode app editing window)) :platform 'linux))
          out)
      (dolist (b (plist-get r :bindings)) (push (plist-get b :key) (alist-get (plist-get b :id) out)))
      (cons out (mapcar #'drgnx-cmd-id (drgnx-commands-all))))))

(defun drgnx-keys-diff (gryphn-dir)
  "Lines (KIND ID TEXT EXPLANATION) where drgnx differs from gryphn's key sheet."
  (pcase-let* ((sheet (drgnx-keys-diff-gryphn-sheet gryphn-dir))
               (`(,bindings . ,ids) (drgnx-keys-diff--drgnx-bindings gryphn-dir))
               (lines nil))
    (pcase-dolist (`(,id ,title ,key ,file) sheet)
      (let ((target (or (alist-get id drgnx-keys-diff-aliases) id))
            (why (alist-get id drgnx-keys-diff-explained)))
        (cond ((not (memq target ids))
               (push (list 'missing id (format "%s (%s, %s)%s" title file (or key "no key") "") why) lines))
              ((and key (not (member key (alist-get target bindings))))
               (push (list 'key id (format "%s: gryphn %s, drgnx %s" title key
                                           (or (string-join (alist-get target bindings) " ") "none"))
                           why)
                     lines)))))
    (nreverse lines)))

(defun drgnx-keys-diff-cli ()
  "bin/drgnx keys diff --against gryphn [DIR]."
  (let* ((args command-line-args-left)
         (dir (expand-file-name (or (car (seq-remove (lambda (a) (member a '("--against" "gryphn" "--"))) args))
                                    "~/workspace/gryphn/emacs")))
         (lines (drgnx-keys-diff dir)) (unexplained 0))
    (setq command-line-args-left nil)
    (dolist (l lines)
      (unless (nth 3 l) (cl-incf unexplained))
      (princ (format "%-8s %-28s %s%s\n" (car l) (nth 1 l) (nth 2 l)
                     (if (nth 3 l) (concat "\n         explained: " (nth 3 l)) "   UNEXPLAINED"))))
    (princ (format "%d differences, %d unexplained\n" (length lines) unexplained))
    (kill-emacs (if (zerop unexplained) 0 1))))

(provide 'drgnx-keys-diff)
;;; drgnx-keys-diff.el ends here
