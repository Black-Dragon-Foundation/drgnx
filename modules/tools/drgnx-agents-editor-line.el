;;; drgnx-agents-editor-line.el --- The agent line: who is nearest your point, in the header's tail -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of module tools/agents-in-editor.  The header's tail takes one more provider (depth 30, after the large-file
;; header and sticky scroll): the agent line, for the agent nearest point in the window's buffer: its mark, handle and
;; mode, the symbol at its line, the step title or plan entry in quotes, "+N" for the others (a click opens who is
;; here) and a follow chip.  While it shows, the breadcrumb shortens to the file name.
;;
;; Everything is built when a frame arrives (`drgnx-agents-editor-line--apply'); the provider that redisplay calls
;; only picks the entry nearest the window's point from that cache, so a frame's strings are the same objects until the
;; next frame.  See docs/guide/agents-in-the-editor.md and docs/develop/agents-editor.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-agent-identity)

(declare-function drgnx-chrome-add-tail-provider "drgnx-chrome")
(declare-function drgnx-chrome-remove-tail-provider "drgnx-chrome")
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function drgnx-agents-editor-draw--line-pos "drgnx-agents-editor-draw")
(declare-function drgnx-work-who-is-here "drgnx-work-code")
(declare-function drgnx-agents-editor-draw--apply "drgnx-agents-editor-draw")
(declare-function drgnx-agents-editor-frame "drgnx-agents-editor")
(declare-function drgnx-agents-editor-watched-buffers "drgnx-agents-editor")
(defvar drgnx-chrome-mode)
(defvar drgnx-agents-editor-apply-functions)
(defvar drgnx-agents-editor-unwatch-functions)
(defvar drgnx-agents-editor-followed)
(defvar drgnx-chrome-short-breadcrumb-functions)
(defvar drgnx-agents-editor-draw--modes)

(defvar drgnx-agents-editor-line-symbol-function nil
  "A function of (BUFFER POS) returning the name of the symbol at POS, or nil; the default asks `add-log-current-defun'.")

(defvar-local drgnx-agents-editor-line--entries nil
  "This buffer's agent line entries from the last frame: ((POS ORDINAL SESSION STRING)...), in agent order.")

(defvar drgnx-agents-editor-line--map
  (let ((m (make-sparse-keymap)))
    (define-key m [header-line mouse-1] #'drgnx-agents-editor-line-click)
    m)
  "Clicks on the agent line's chips.")

;;;; Building the line (once per frame)

(defun drgnx-agents-editor-line--escape (s)
  "S safe for the mode line."
  (string-replace "%" "%%" s))

(defun drgnx-agents-editor-line--symbol (buffer pos)
  "The symbol at POS in BUFFER, or nil.  Asked once per frame, never in redisplay."
  (condition-case nil
      (if drgnx-agents-editor-line-symbol-function
          (funcall drgnx-agents-editor-line-symbol-function buffer pos)
        (and (< (buffer-size buffer) 2000000)
             (with-current-buffer buffer (save-excursion (goto-char pos) (add-log-current-defun)))))
    (error nil)))

(defun drgnx-agents-editor-line--chip (text kind help)
  (propertize text 'face 'drgnx-chrome-crumb 'mouse-face 'mode-line-highlight 'help-echo help
              'drgnx-agents-editor-line kind 'local-map drgnx-agents-editor-line--map))

(defun drgnx-agents-editor-line--string (agent pos buffer others)
  "The agent line for AGENT (at POS in BUFFER), OTHERS more agents in the buffer."
  (let* ((ord (plist-get agent :ordinal))
         (mode (or (cdr (assoc (plist-get agent :mode) drgnx-agents-editor-draw--modes)) (plist-get agent :mode) "here"))
         (where (plist-get (plist-get agent :projected) :worktree_label))
         (sym (and pos (not where) (drgnx-agents-editor-line--symbol buffer pos)))
         (title (or (plist-get agent :plan_entry) (plist-get agent :step_title)))
         (face (plist-get (drgnx-agent-identity ord) :face)))
    (concat
     " "
     (propertize (drgnx-agent-identity-text ord) 'face face) " "
     (drgnx-agents-editor-line--escape (or (plist-get agent :handle) "Agent")) " · " mode
     (if where (concat " in " (drgnx-agents-editor-line--escape where)) "")
     (if sym (concat " · " (drgnx-agents-editor-line--escape sym)) "")
     (if (and title (not (string-empty-p title)))
         (concat " \"" (drgnx-agents-editor-line--escape (truncate-string-to-width title 40 nil nil "…")) "\"")
       "")
     (if (> others 0)
         (concat " " (drgnx-agents-editor-line--chip (format "+%d" others) 'here "Who is here in this file"))
       "")
     " " (drgnx-agents-editor-line--chip "F follow" 'follow "Follow this agent: keep its name tag on"))))

(defun drgnx-agents-editor-line--apply (buffer frame)
  "Cache BUFFER's agent line entries from FRAME."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((agents (cl-remove-if-not (lambda (a) (plist-get a :line)) (plist-get frame :agents)))
             (n (length agents)) (had (and drgnx-agents-editor-line--entries t)) entries)
        (dolist (a agents)
          (let ((pos (drgnx-agents-editor-draw--line-pos (plist-get a :line) 0)))
            (push (list pos (plist-get a :ordinal) (plist-get a :session)
                        (drgnx-agents-editor-line--string a pos buffer (1- n)))
                  entries)))
        (setq drgnx-agents-editor-line--entries (nreverse entries))
        (force-mode-line-update)
        (unless (eq had (and entries t)) (drgnx-agents-editor-line--reapply buffer))))))

(defun drgnx-agents-editor-line--reapply (buffer)
  "The breadcrumb's length depends on the line showing: lay out the chrome of BUFFER's frames again."
  (when (and (bound-and-true-p drgnx-chrome-mode) (fboundp 'drgnx-chrome-apply))
    (dolist (w (get-buffer-window-list buffer nil t))
      (drgnx-chrome-apply (window-frame w)))))

(defun drgnx-agents-editor-line--nearest (entries pos)
  "The entry of ENTRIES whose position is nearest POS."
  (let (best (d most-positive-fixnum))
    (dolist (e entries)
      (let ((e-d (abs (- (car e) pos))))
        (when (< e-d d) (setq best e d e-d))))
    best))

;;;; The provider and the breadcrumb

(defun drgnx-agents-editor-line--provider (w)
  "The chrome's tail provider (depth 30): the line of the agent nearest window W's point.  Cached strings only."
  (when-let* ((entries (buffer-local-value 'drgnx-agents-editor-line--entries (window-buffer w)))
              (e (drgnx-agents-editor-line--nearest entries (window-point w))))
    (nth 3 e)))

(defun drgnx-agents-editor-line--short-breadcrumb (w)
  "Non-nil while window W's buffer shows an agent line: the breadcrumb is the file name alone."
  (and (buffer-local-value 'drgnx-agents-editor-line--entries (window-buffer w)) t))

;;;; Clicks and following

(defun drgnx-agents-editor-line-click (event)
  "A click on a chip of the agent line: \"+N\" opens who is here, \"F follow\" follows the agent."
  (interactive "e")
  (let* ((posn (event-start event)) (str (posn-string posn))
         (kind (and str (get-text-property (cdr str) 'drgnx-agents-editor-line (car str))))
         (w (posn-window posn)))
    (when (window-live-p w)
      (with-selected-window w
        (pcase kind
          ('here (when (fboundp 'drgnx-work-who-is-here) (call-interactively #'drgnx-work-who-is-here)))
          ('follow (drgnx-agents-editor-follow)))))))

(defun drgnx-agents-editor-follow ()
  "Follow the agent nearest point in this buffer (keeps its name tag on); again, or with none, stops following."
  (interactive)
  (let* ((e (drgnx-agents-editor-line--nearest drgnx-agents-editor-line--entries (point)))
         (session (and e (nth 2 e))))
    (setq drgnx-agents-editor-followed (and session (not (equal session drgnx-agents-editor-followed)) session))
    (dolist (b (drgnx-agents-editor-watched-buffers))
      (when-let* ((f (drgnx-agents-editor-frame b))) (drgnx-agents-editor-draw--apply b f)))
    (message (if drgnx-agents-editor-followed "Following %s" "Not following an agent")
             (or (and drgnx-agents-editor-followed (drgnx-agents-editor-line--handle e)) ""))))

(defun drgnx-agents-editor-line--handle (e)
  (and e (let ((s (nth 3 e))) (when (string-match "[^ ]+ \\([^·]+\\) ·" s) (string-trim (match-string 1 s))))))

;;;; Probe

(defun drgnx-agents-editor-line-probe (buffer frame n)
  "Time N builds of the agent line entries of FRAME in BUFFER and a provider call after each: milliseconds, a list."
  (let (ms)
    (dotimes (_ n)
      (push (* 1000 (car (benchmark-run 1
                           (drgnx-agents-editor-line--apply buffer frame)
                           (when-let* ((w (car (get-buffer-window-list buffer nil t)))) (drgnx-agents-editor-line--provider w)))))
            ms))
    ms))

;;;; Setup

(defun drgnx-agents-editor-line-setup ()
  "Show the agent line.  Called by the module's setup."
  (drgnx-module-hook 'drgnx-agents-editor-apply-functions line-apply (buffer frame)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-line--apply buffer frame))
  (drgnx-module-hook 'drgnx-agents-editor-unwatch-functions line-unwatch (buffer)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-line--clear buffer))
  (drgnx-module-hook 'drgnx-chrome-short-breadcrumb-functions line-crumb (w)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-line--short-breadcrumb w))
  (drgnx-command-define 'agents-follow :category "Agents" :title "Follow Agent"
                        :command #'drgnx-agents-editor-follow
                        :doc "Follow the agent nearest point in this file: its name tag stays on")
  (eval-after-load 'drgnx-chrome
    (drgnx-modules-with-owner (drgnx-chrome-add-tail-provider #'drgnx-agents-editor-line--provider 30))))

(defun drgnx-agents-editor-line--clear (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((had drgnx-agents-editor-line--entries))
        (setq drgnx-agents-editor-line--entries nil)
        (when had (force-mode-line-update) (drgnx-agents-editor-line--reapply buffer))))))

(defun drgnx-agents-editor-line-teardown ()
  "Take the agent line out of every buffer and its provider out of the chrome."
  (when (fboundp 'drgnx-chrome-remove-tail-provider)
    (drgnx-chrome-remove-tail-provider #'drgnx-agents-editor-line--provider))
  (setq drgnx-agents-editor-followed nil)
  (dolist (b (buffer-list)) (drgnx-agents-editor-line--clear b)))

(provide 'drgnx-agents-editor-line)
;;; drgnx-agents-editor-line.el ends here
