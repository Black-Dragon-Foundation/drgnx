;;; drgnx-agents-ask.el --- Ask an Agent About This: the command, its context and its keys (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; "Ask an Agent About This" (VS Code Ctrl+I, Emacs C-c w a, Vim SPC a a; the right-click menu on a buffer and on
;; Explorer rows) opens the Agents side with what the point is on as a removable context item in the composer: the
;; file, the lines of the region, or a Work or Explorer item.  With an agent working on the file (the hub's presence
;; model) its conversation opens; otherwise a new chat does.  Opening a file never switches the side by itself: nothing
;; here hooks `find-file'.  Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.
;;
;; Ctrl+I is the TAB character on a terminal and wherever the Tab key falls back to it, so the binding is made on the
;; graphic key `<C-i>' (`input-decode-map' splits it from TAB in a graphical frame); the Tab key keeps its own bindings,
;; and on a terminal the command is reached from the palette and the context menu.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-hub-client)

(defvar drgnx-agent-panel--context)
(defvar drgnx-work-map--selection)
(declare-function drgnx-agent-panel-new-chat "drgnx-agent-panel")
(declare-function drgnx-agent-panel-context-add "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer-redraw "drgnx-agent-panel-composer")
(declare-function drgnx-agents-side-open-conversation "drgnx-agent-panel-list" (session))
(declare-function drgnx-explorer-node-at "drgnx-explorer")

(defun drgnx-agents-ask-context ()
  "What the point is on, as a context item: (:file PATH :lines (A . B)) with an active region, (:file PATH) in a file's
buffer, (:item (KIND . ID)) on a Work row, the path of an Explorer row as (:file PATH); nil elsewhere."
  (cond ((derived-mode-p 'drgnx-work-map-mode)
         (and (consp (bound-and-true-p drgnx-work-map--selection))
              (list :item (cons (format "%s" (car drgnx-work-map--selection))
                                (cdr drgnx-work-map--selection)))))
        ((derived-mode-p 'drgnx-explorer-mode)
         (when-let* ((path (and (fboundp 'drgnx-explorer-node-at) (drgnx-explorer-node-at (point)))))
           (list :file path)))
        ((and buffer-file-name (use-region-p))
         (list :file buffer-file-name
               :lines (cons (line-number-at-pos (region-beginning))
                            (line-number-at-pos (max (region-beginning) (1- (region-end)))))))
        (buffer-file-name (list :file buffer-file-name))))

(defun drgnx-agents-ask--sessions-on (file callback)
  "Call CALLBACK with the ids of the sessions the hub's presence model has in FILE (none when it cannot say)."
  (condition-case nil
      (drgnx-hub-call "agents/presence/get" (list :file file)
                      (lambda (res _err)
                        (funcall callback
                                 (delete-dups
                                  (delq nil (mapcar (lambda (e) (plist-get e :session))
                                                    (append (plist-get res :entries) nil)))))))
    (error (funcall callback nil))))

(defun drgnx-agents-ask--show (context sessions)
  "Open the Agents side and put CONTEXT in its composer: SESSIONS' first conversation (compact, in the side), else a new
chat.  The item goes on the panel, whose composer draws it as a removable chip."
  (let ((buf (if sessions (drgnx-agents-side-open-conversation (car sessions)) (drgnx-agent-panel-new-chat))))
    (when (and context (buffer-live-p buf))
      (with-current-buffer buf
        (drgnx-agent-panel-context-add context)
        (when (fboundp 'drgnx-agent-panel-composer-redraw) (drgnx-agent-panel-composer-redraw))))
    buf))

;;;###autoload
(defun drgnx-agents-ask-about-this ()
  "Ask an agent about what the point is on: open its conversation when one works on this file, else a new chat, with
the file, the lines or the item as a context item you can remove.  Never sends anything."
  (interactive)
  (let ((context (drgnx-agents-ask-context)))
    (if-let* ((file (plist-get context :file)))
        (drgnx-agents-ask--sessions-on file (lambda (sessions) (drgnx-agents-ask--show context sessions)))
      (drgnx-agents-ask--show context nil))))

(defun drgnx-agents-ask--decode-c-i (&optional _frame)
  "In a graphical frame, split Ctrl+I from the Tab key: the first reads as `<C-i>', the second stays TAB."
  (when (display-graphic-p)
    (define-key input-decode-map [?\C-i] [C-i])))

(defun drgnx-agents-ask-setup ()
  "tools/agent-panel's setup: the command, and Ctrl+I as its own key in graphical frames."
  (drgnx-command-define 'ask-agent-about-this :category "Agents" :title "Ask an Agent About This"
                        :command #'drgnx-agents-ask-about-this :context '(region code org explorer)
                        :doc "Open the Agents side with the file, the lines or the item as context; you send")
  (add-hook 'after-make-frame-functions #'drgnx-agents-ask--decode-c-i)
  (drgnx-agents-ask--decode-c-i))

(defun drgnx-agents-ask-teardown ()
  "Undo `drgnx-agents-ask-setup''s hook."
  (remove-hook 'after-make-frame-functions #'drgnx-agents-ask--decode-c-i))

(provide 'drgnx-agents-ask)
;;; drgnx-agents-ask.el ends here
