;;; drgnx-keys-diff.el --- The key-sheet diff against gryphn -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx keys diff --against gryphn [DIR]': every command on gryphn's key sheet (its registry:
;; `gryphn-command-define' forms with a literal id, read — never run — from DIR) against drgnx's
;; VS Code key profile with every module stage run (the user's ELPA when present, gryphn's board,
;; runs, agents, search and LLM files as the external module).  A gryphn command must exist in
;; drgnx (under its id or its drgnx name, `drgnx-keys-diff-aliases') with gryphn's key among its
;; keys, or be explained (`drgnx-keys-diff-explained').  Unexplained lines make the exit non-zero.
;; See docs/guide/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)

(defconst drgnx-keys-diff-aliases
  '((view-explorer . toggle-sidebar) (view-explorer-focus . focus-explorer) (view-buffers-focus . focus-buffers)
    (view-panel . toggle-panel) (view-palette . palette) (view-line-numbers . line-numbers)
    (go-prev-tab . previous-tab) (go-next-tab . next-tab) (view-outline . focus-outline)
    (file-save . save-file) (file-open . open-file) (file-close-tab . close-tab) (go-symbol-file . go-symbol)
    (go-definition . code-definition) (go-references . code-references) (view-terminal . toggle-panel)
    (view-git . scm-view) (view-split . split-editor-right) (view-settings . preferences-modules)
    (view-keys . keys-sheet) (go-window-1 . focus-group-1) (go-window-2 . focus-group-2) (go-window-3 . focus-group-3))
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
    (dev-mise-reload . "gryphn-mise needs gryphn's bundle loader; mise integration is a drgnx module for M11 (DEFERRED M4)")
    (view-keys . "<f1> is the palette, as in VS Code; the key sheet is C-k C-s (VS Code's Keyboard Shortcuts)")
    (go-window-4 . "drgnx numbers editor groups (M-1…M-3, C-1…C-3), not every window; M-o picks any window")
    (go-window-5 . "drgnx numbers editor groups (M-1…M-3), not every window; M-o picks any window")
    (go-window-6 . "drgnx numbers editor groups (M-1…M-3), not every window; M-o picks any window")
    (go-window-7 . "drgnx numbers editor groups (M-1…M-3), not every window; M-o picks any window")
    (go-window-8 . "drgnx numbers editor groups (M-1…M-3), not every window; M-o picks any window")
    (go-window-9 . "drgnx numbers editor groups (M-1…M-3), not every window; M-o picks any window")
    (emacs-kill-line . "C-k starts VS Code's chords in drgnx (C-k C-s key sheet, C-k z zen, C-k s save all…); C-S-k deletes the line"))
  "gryphn id → why it is not in drgnx, or why its key differs (shown with the line).")

(defun drgnx-keys-diff-gryphn-sheet (dir)
  "gryphn's sheet from DIR: (ID TITLE KEY FILE KIND) for every literal `gryphn-command-define', every
row of a `gryphn--keys' table, the `go-window-N' commands of a `dotimes' and the Emacs keys gryphn
lists as :native (KIND `native': documented, never rebound).  Nothing is evaluated."
  (let (rows)
    (dolist (file (directory-files dir t "\\`gryphn.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (while t
              (let ((form (read (current-buffer))))
                (cl-labels ((row (id title key &optional kind)
                              (push (list id title (and (stringp key) key) (file-name-nondirectory file) kind) rows))
                            (lit (v n)                ; a string, or (format "…%d" VAR) for the dotimes number N
                              (pcase v
                                ((pred stringp) v)
                                (`(format ,(and (pred stringp) f) ,(pred symbolp)) (and n (format f n)))))
                            (walk (x count)
                              (pcase x
                                (`(gryphn--keys ,_ . ,entries)
                                 (dolist (e entries)
                                   (when (and (consp e) (symbolp (car e))) (row (car e) (nth 3 e) (nth 1 e)))))
                                (`(dotimes (,_ ,(and (pred integerp) n)) . ,body) (dolist (b body) (walk b n)))
                                (`(gryphn-command-define (quote ,(and (pred symbolp) id)) . ,args)
                                 (row id (plist-get args :title) (plist-get args :key)))
                                (`(gryphn-command-define (intern (format ,(and (pred stringp) f) ,_)) . ,args)
                                 (dotimes (i (or count 0))           ; dotimes (i N) … (1+ i)
                                   (let ((n (1+ i)))
                                     (row (intern (format f n)) (lit (plist-get args :title) n) (lit (plist-get args :key) n)))))
                                (`(dolist (,_ (quote ,(and (pred consp) entries))) . ,body)
                                 (if (memq :native (flatten-tree body))
                                     (dolist (e entries) (row (car e) (nth 3 e) (nth 1 e) 'native))
                                   (dolist (b body) (walk b count))))
                                ((pred consp) (let ((y x)) (while (consp y) (walk (car y) count) (setq y (cdr y))))))))
                  (walk form nil))))
          (end-of-file nil))))
    (nreverse rows)))

(defun drgnx-keys-diff--drgnx-bindings (gryphn-dir)
  "drgnx's VS Code bindings with every module run: (ALL IDS GLOBAL), ALL and GLOBAL alists ID → keys
(GLOBAL: only the keys of the global map), IDS every command id."
  (let ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))))
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
          all global)
      (dolist (b (plist-get r :bindings))
        (push (plist-get b :key) (alist-get (plist-get b :id) all))
        (unless (plist-get b :map) (push (plist-get b :key) (alist-get (plist-get b :id) global))))
      (list all (mapcar #'drgnx-cmd-id (drgnx-commands-all)) global))))

(defun drgnx-keys-diff (gryphn-dir)
  "Lines (KIND ID TEXT EXPLANATION) where drgnx differs from gryphn's key sheet."
  (pcase-let* ((sheet (drgnx-keys-diff-gryphn-sheet gryphn-dir))
               (`(,bindings ,ids ,global) (drgnx-keys-diff--drgnx-bindings gryphn-dir))
               (lines nil))
    (pcase-dolist (`(,id ,title ,key ,file ,kind) sheet)
      (let ((target (or (alist-get id drgnx-keys-diff-aliases) id))
            (why (alist-get id drgnx-keys-diff-explained)))
        (cond ((eq kind 'native)          ; gryphn leaves the key to Emacs: drgnx must not take it
               (when-let* ((taken (seq-some (lambda (b)
                                              (seq-some (lambda (k) (and (or (equal k key) (string-prefix-p (concat key " ") k))
                                                                         (format "%s (%s)" (car b) k)))
                                                        (cdr b)))
                                            global)))   ; a key in a mode's own map leaves Emacs' key alone
                 (push (list 'native id (format "%s: gryphn leaves %s to Emacs, drgnx binds %s" title key taken) why)
                       lines)))
              ((not (memq target ids))
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
         (dir (or (car (seq-remove (lambda (a) (member a '("--against" "gryphn" "--"))) args))
                  (getenv "DRGNX_GRYPHN_DIR")))
         (lines nil) (unexplained 0))
    (setq command-line-args-left nil)
    (unless (and dir (file-directory-p dir))
      (princ "usage: drgnx keys diff --against gryphn DIR   (or set DRGNX_GRYPHN_DIR to gryphn's emacs/ directory)\n")
      (kill-emacs 2))
    (setq lines (drgnx-keys-diff (expand-file-name dir)))
    (dolist (l lines)
      (unless (nth 3 l) (cl-incf unexplained))
      (princ (format "%-8s %-28s %s%s\n" (car l) (nth 1 l) (nth 2 l)
                     (if (nth 3 l) (concat "\n         explained: " (nth 3 l)) "   UNEXPLAINED"))))
    (princ (format "%d differences, %d unexplained\n" (length lines) unexplained))
    (kill-emacs (if (zerop unexplained) 0 1))))

(provide 'drgnx-keys-diff)
;;; drgnx-keys-diff.el ends here
