;;; drgnx-ai-ui.el --- Module tools/ai: ghost-text completion and the Tab arbiter -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Ghost text: a pause in a code buffer asks the `complete' role to fill in the middle (the text before and after
;; point); the answer shows after point, dimmed, only if nothing moved or changed meanwhile, and any other command
;; clears it.  Accept it whole (Tab), a word (C-<right>, bound only while it shows) or a line; Escape dismisses it.
;; Tab is one arbiter: a suggestion → accept; a completion popup → its own Tab; a snippet field → the next field;
;; an org/outline heading → cycle; otherwise indent.  See docs/guide/ai.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-ai)
(require 'drgnx-ai-client)
(require 'drgnx-ai-probe)

(defface drgnx-ai-ghost '((t :inherit shadow)) "A suggestion not yet accepted." :group 'drgnx)

(defvar drgnx-ai-ghost-delay 0.3 "Seconds of pause before a suggestion is asked for.")
(defvar drgnx-ai-ghost-before 2000 "Characters before point the model sees.")
(defvar drgnx-ai-ghost-after 1000 "Characters after point the model sees.")
(defvar drgnx-ai-ghost-max-tokens 64 "How long a suggestion may be.")

(defvar-local drgnx-ai-ghost--text nil "The suggestion still to accept.")
(defvar-local drgnx-ai-ghost--overlay nil)
(defvar-local drgnx-ai-ghost--request nil "The request in flight.")
(defvar-local drgnx-ai-ghost--showing nil "Non-nil while a suggestion shows: its keys are active.")
(defvar drgnx-ai-ghost--timer nil)
(defvar drgnx-ai-ghost-mode)                            ; the minor mode, defined below
(defvar drgnx-ai-ghost--said-unavailable nil "Told once this session that no provider completes.")

(defvar drgnx-ai-ghost-showing-map (make-sparse-keymap) "Keys active only while a suggestion shows.")
(defvar drgnx-ai-ghost--emulation (list (cons 'drgnx-ai-ghost--showing drgnx-ai-ghost-showing-map)))
(add-to-list 'emulation-mode-map-alists 'drgnx-ai-ghost--emulation)

(defvar drgnx-ai-ghost-mode-map (make-sparse-keymap) "Keys of buffers with ghost text (Tab: `drgnx-ai-tab').")

;;;; Showing

(defun drgnx-ai-ghost-text () "The suggestion showing, or nil." drgnx-ai-ghost--text)

(defun drgnx-ai-ghost-text-shown ()
  "The suggestion as it shows (with its face), or nil."
  (and drgnx-ai-ghost--overlay (overlay-get drgnx-ai-ghost--overlay 'after-string)))

(defun drgnx-ai-ghost--clear ()
  (when drgnx-ai-ghost--overlay (delete-overlay drgnx-ai-ghost--overlay))
  (setq drgnx-ai-ghost--overlay nil drgnx-ai-ghost--text nil drgnx-ai-ghost--showing nil))

(defun drgnx-ai-ghost--show (text)
  "Show TEXT as a suggestion at point."
  (drgnx-ai-ghost--clear)
  (unless (string-empty-p text)
    (setq drgnx-ai-ghost--text text drgnx-ai-ghost--showing t
          drgnx-ai-ghost--overlay (make-overlay (point) (point) nil nil t))
    (overlay-put drgnx-ai-ghost--overlay 'after-string
                 (concat (propertize (substring text 0 1) 'cursor 1 'face 'drgnx-ai-ghost)
                         (propertize (substring text 1) 'face 'drgnx-ai-ghost)))))

;;;; Asking

(defun drgnx-ai-ghost--available-p ()
  "Some provider of the `complete' role can be asked: found running here, or remote with its key."
  (seq-some (lambda (step)
              (let ((p (drgnx-ai-provider (car step))))
                (and p (memq 'fim (plist-get p :caps))
                     (if (plist-get p :key-env) (drgnx-ai-key (car step))
                       (plist-get (alist-get (car step) drgnx-ai-detected) :up)))))
            (drgnx-ai-role 'complete)))

(defun drgnx-ai-ghost--trigger ()
  "Ask for a suggestion at point (the pause has come).  Says once when no provider completes."
  (when (and drgnx-ai-ghost-mode (not buffer-read-only))
    (if (not (drgnx-ai-ghost--available-p))
        (unless drgnx-ai-ghost--said-unavailable
          (setq drgnx-ai-ghost--said-unavailable t)
          (message "AI completion: no provider for `complete' is running (AI: Choose Provider/Model)"))
      (when drgnx-ai-ghost--request (drgnx-ai-cancel drgnx-ai-ghost--request))
      (let ((buf (current-buffer)) (tick (buffer-chars-modified-tick)) (pt (point)))
        (setq drgnx-ai-ghost--request
              (drgnx-ai-request 'complete 'fim
                                (list :prefix (buffer-substring-no-properties (max (point-min) (- pt drgnx-ai-ghost-before)) pt)
                                      :suffix (buffer-substring-no-properties pt (min (point-max) (+ pt drgnx-ai-ghost-after)))
                                      :max-tokens drgnx-ai-ghost-max-tokens)
                                (lambda (text _info)
                                  (when (and text (buffer-live-p buf))
                                    (with-current-buffer buf
                                      (setq drgnx-ai-ghost--request nil)
                                      ;; only if nothing changed or moved since the question
                                      (when (and drgnx-ai-ghost-mode (= tick (buffer-chars-modified-tick)) (= pt (point)))
                                        (drgnx-ai-ghost--show (string-trim-right text))))))
                                :timeout 5))))))

(defconst drgnx-ai-ghost--keep-commands
  '(drgnx-ai-accept drgnx-ai-accept-word drgnx-ai-accept-line drgnx-ai-tab)
  "Commands that work with a suggestion rather than clear it.")

(defun drgnx-ai-ghost--post-command ()
  "After a command: anything but accepting clears the suggestion and the question in flight; a new pause asks."
  (unless (memq this-command drgnx-ai-ghost--keep-commands)
    (drgnx-ai-ghost--clear)
    (when drgnx-ai-ghost--request (drgnx-ai-cancel drgnx-ai-ghost--request) (setq drgnx-ai-ghost--request nil)))
  (when (timerp drgnx-ai-ghost--timer) (cancel-timer drgnx-ai-ghost--timer))
  (when (and drgnx-ai-ghost-mode (not drgnx-ai-ghost--text))
    (let ((buf (current-buffer)))
      (setq drgnx-ai-ghost--timer
            (run-with-idle-timer drgnx-ai-ghost-delay nil
                                 (lambda () (when (and (buffer-live-p buf) (eq buf (current-buffer)))
                                              (drgnx-ai-ghost--trigger))))))))

(define-minor-mode drgnx-ai-ghost-mode
  "Ghost-text completion from the `complete' role; Tab is `drgnx-ai-tab'."
  :lighter nil :keymap drgnx-ai-ghost-mode-map
  (if drgnx-ai-ghost-mode
      (add-hook 'post-command-hook #'drgnx-ai-ghost--post-command nil t)
    (remove-hook 'post-command-hook #'drgnx-ai-ghost--post-command t)
    (drgnx-ai-ghost--clear)))

(defvar drgnx-ai-complete-enabled t "Non-nil: ghost text in code buffers (AI: Toggle Completion).")

(defun drgnx-ai-ghost--maybe-enable ()
  (when drgnx-ai-complete-enabled (drgnx-ai-ghost-mode 1)))

;;;; Accepting

(defun drgnx-ai--accept-part (n)
  "Insert the first N characters of the suggestion; the rest keeps showing."
  (let ((text drgnx-ai-ghost--text))
    (when text
      (drgnx-ai-ghost--clear)
      (insert (substring text 0 n))
      (drgnx-ai-ghost--show (substring text n)))))

(defun drgnx-ai-accept ()
  "Insert the whole suggestion."
  (interactive)
  (when drgnx-ai-ghost--text (drgnx-ai--accept-part (length drgnx-ai-ghost--text))))

(defun drgnx-ai-accept-word ()
  "Insert the suggestion's next word."
  (interactive)
  (when-let* ((text drgnx-ai-ghost--text))
    (drgnx-ai--accept-part (if (string-match "\\`\\W*\\w+" text) (match-end 0) (length text)))))

(defun drgnx-ai-accept-line ()
  "Insert the suggestion up to its line's end."
  (interactive)
  (when-let* ((text drgnx-ai-ghost--text))
    (drgnx-ai--accept-part (if (string-match "\\`\n?[^\n]*" text) (match-end 0) (length text)))))

(defun drgnx-ai-dismiss ()
  "Drop the suggestion."
  (interactive)
  (drgnx-ai-ghost--clear))

(defun drgnx-ai-complete-toggle ()
  "Turn ghost-text completion on or off (code buffers)."
  (interactive)
  (setq drgnx-ai-complete-enabled (not drgnx-ai-complete-enabled))
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (derived-mode-p 'prog-mode) (drgnx-ai-ghost-mode (if drgnx-ai-complete-enabled 1 -1)))))
  (message "AI completion %s" (if drgnx-ai-complete-enabled "on" "off")))

;;;; The Tab arbiter

(declare-function org-at-heading-p "org")
(declare-function outline-on-heading-p "outline")

(defun drgnx-ai-tab-command ()
  "What Tab does here: the first of — accept the suggestion; the completion popup's Tab; the next snippet
field; cycle the heading; indent."
  (cond (drgnx-ai-ghost--text 'drgnx-ai-accept)
        ((and (bound-and-true-p corfu--frame) (frame-live-p corfu--frame) (frame-visible-p corfu--frame)) 'corfu-complete)
        ((bound-and-true-p company-candidates) 'company-complete-common)
        ((bound-and-true-p completion-in-region-mode) 'completion-at-point)
        ((and (fboundp 'yas-active-snippets) (yas-active-snippets)) 'yas-next-field-or-maybe-expand)
        ((bound-and-true-p tempel--active) 'tempel-next)
        ((and (derived-mode-p 'org-mode) (org-at-heading-p)) 'org-cycle)
        ((and (bound-and-true-p outline-minor-mode) (outline-on-heading-p)) 'outline-cycle)
        (t 'indent-for-tab-command)))

(defun drgnx-ai-tab ()
  "Tab: accept a suggestion, else the popup's, the snippet's, the heading's or the indent Tab."
  (interactive)
  (let ((cmd (drgnx-ai-tab-command)))
    (setq this-command cmd)
    (call-interactively cmd)))

;;;; The module

(drgnx-module-define 'tools/ai
                     :doc "AI: ghost-text completion in code buffers (the `complete' role) and one Tab for everything."
                     :stage 'startup :requires '(core/workbench)
                     :setup
                     (lambda ()
                       (add-hook 'prog-mode-hook #'drgnx-ai-ghost--maybe-enable)
                       ;; which providers run here: asked once Emacs is idle, never while it works
                       (run-with-idle-timer 2 nil (lambda () (drgnx-ai-probe nil)))
                       (pcase-dolist (`(,id ,title ,fn ,doc ,map)
                                      '((ai-accept "Accept Suggestion" drgnx-ai-accept "Insert the whole suggestion" nil)
                                        (ai-accept-word "Accept Suggestion Word" drgnx-ai-accept-word "Insert its next word"
                                                        drgnx-ai-ghost-showing-map)
                                        (ai-accept-line "Accept Suggestion Line" drgnx-ai-accept-line "Insert it to the line's end" nil)
                                        (ai-dismiss "Dismiss Suggestion" drgnx-ai-dismiss "Drop the suggestion" drgnx-ai-ghost-showing-map)
                                        (ai-tab "Tab (Suggestion, Completion, Snippet, Heading, Indent)" drgnx-ai-tab
                                                "Accept a suggestion, else the popup's, snippet's, heading's or indent Tab" drgnx-ai-ghost-mode-map)
                                        (ai-complete-toggle "Toggle AI Completion" drgnx-ai-complete-toggle "Ghost text on or off" nil)))
                         (apply #'drgnx-command-define id :category "AI" :title title :command fn :doc doc (and map (list :map map))))))

(provide 'drgnx-ai-ui)
;;; drgnx-ai-ui.el ends here
