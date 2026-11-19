;;; drgnx-doc-agents.el --- Documents written with agents: the live paragraph and the comments (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A spec or plan an agent writes grows in its buffer (auto-revert for a worktree agent, pair writes for a paired chat).
;; `drgnx-doc-agents-mode' (on for record files) marks the paragraph under the writing agent's newest edit range with the
;; agent's mark in the margin and a quiet fill, one overlay that moves when presence says the agent is writing elsewhere
;; (no Lisp per keystroke).  A comment is a thread anchored to a paragraph: `doc-comment-add' sends `comments/add' with the
;; paragraph's text as the quote (the hub steers the writing agent, never cancelling its turn; with none the comment waits),
;; the margin shows "N comments" on an anchored paragraph, and the thread's card (the view `doc-comments/RECORD', hub rows,
;; runtime/crates/drgnx-ratatoskr/src/view/doc_comments.rs) shows the replies.  A thread whose paragraph is gone has no marker
;; here; the card keeps its quote.  Loaded by tools/work-space (drgnx-work-space.el); defines no module.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(defvar drgnx-hub--events)
(declare-function drgnx-ui-kit-agent-mark "drgnx-ui-kit")
(declare-function drgnx-review-request-open "drgnx-review-screen")

(defvar-local drgnx-doc-agents--record nil "The record this buffer's document is: `spec:ID', `plan:ID', `decision:N' or `task:ID'.")
(defvar-local drgnx-doc-agents--writer-ov nil "The overlay of the writing agent's paragraph.")
(defvar-local drgnx-doc-agents--threads nil "The threads last shown, as `comments/list' gives them.")
(defvar-local drgnx-doc-agents--pulse-timer nil "The key of the writer paragraph's pulse (a `drgnx-timer-poll'), or nil.")
(defvar drgnx-reduced-motion nil "Non-nil: no pulses (the user's reduced-motion setting).")
(declare-function drgnx-timer-poll "drgnx-timer")
(declare-function drgnx-timer-cancel "drgnx-timer")
(declare-function glitnir--reduced-motion-p "glitnir")

(defun drgnx-doc-agents--paragraph (pos)
  "(START . END) of the paragraph at POS: the lines around it up to a blank line."
  (save-excursion
    (goto-char pos)
    (let ((blank (lambda () (looking-at-p "[ \t]*$"))))
      (beginning-of-line)
      (while (and (not (bobp)) (not (funcall blank))
                  (progn (forward-line -1) (not (funcall blank)))))
      (when (funcall blank) (forward-line 1))
      (let ((start (point)))
        (while (and (not (eobp)) (not (funcall blank))) (forward-line 1))
        (cons start (if (and (not (eobp)) (> (point) start)) (1- (point)) (point)))))))

(defun drgnx-doc-agents--line-pos (line)
  (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)))

(defun drgnx-doc-agents-mark-writer (_start-line end-line slot handle)
  "Mark the paragraph of END-LINE (the end of the writing agent's newest edit range) as being written: the agent's mark
\(SLOT, HANDLE) in the margin and the quiet fill.  One overlay, moved here; the agent writing elsewhere moves it."
  (let* ((p (drgnx-doc-agents--paragraph (drgnx-doc-agents--line-pos end-line))))
    (unless (overlayp drgnx-doc-agents--writer-ov)
      (setq drgnx-doc-agents--writer-ov (make-overlay (car p) (cdr p) nil t))
      (overlay-put drgnx-doc-agents--writer-ov 'drgnx-doc-agents-writer t)
      (overlay-put drgnx-doc-agents--writer-ov 'evaporate t))
    (move-overlay drgnx-doc-agents--writer-ov (car p) (cdr p))
    (overlay-put drgnx-doc-agents--writer-ov 'face 'drgnx-selected-quiet)
    (overlay-put drgnx-doc-agents--writer-ov 'before-string
                 (propertize (concat (if (fboundp 'drgnx-ui-kit-agent-mark)
                                         (or (ignore-errors (drgnx-ui-kit-agent-mark slot handle 'text)) handle)
                                       handle)
                                     " ")
                             'help-echo (format "%s is writing this paragraph" handle)))
    ;; one repeating timer for the buffer unless motion is reduced; reduced motion stops a pulse that runs
    (drgnx-doc-agents--pulse (drgnx-doc-agents--motion-p))
    drgnx-doc-agents--writer-ov))

(defun drgnx-doc-agents--motion-p ()
  "Whether the writer's paragraph may pulse: motion is not reduced."
  (not (or drgnx-reduced-motion
           (eq (bound-and-true-p drgnx-look-motion) 'reduced)
           (and (fboundp 'glitnir--reduced-motion-p) (glitnir--reduced-motion-p)))))

(defun drgnx-doc-agents--pulse-tick (buffer)
  "One beat of the pulse in BUFFER: the writer paragraph's fill steps between the quiet and the full selection.
Ends (non-nil) when the paragraph or the buffer is gone."
  (if (and (buffer-live-p buffer)
           (overlayp (buffer-local-value 'drgnx-doc-agents--writer-ov buffer))
           (overlay-buffer (buffer-local-value 'drgnx-doc-agents--writer-ov buffer)))
      (let ((ov (buffer-local-value 'drgnx-doc-agents--writer-ov buffer)))
        (overlay-put ov 'face (if (eq (overlay-get ov 'face) 'drgnx-selected-quiet) 'drgnx-selected 'drgnx-selected-quiet))
        nil)
    t))

(defun drgnx-doc-agents--pulse (on)
  "Start the pulse when ON (and motion is allowed), else stop it: one timer for the buffer, owned by this library."
  (if (and on (drgnx-doc-agents--motion-p))
      (unless drgnx-doc-agents--pulse-timer
        (setq drgnx-doc-agents--pulse-timer
              (drgnx-timer-poll (cons 'drgnx-doc-agents-pulse (current-buffer)) 1.0 #'drgnx-doc-agents--pulse-tick
                                :deadline 3600 :args (list (current-buffer)) :owner 'drgnx-doc-agents)))
    (when drgnx-doc-agents--pulse-timer
      (drgnx-timer-cancel drgnx-doc-agents--pulse-timer)
      (setq drgnx-doc-agents--pulse-timer nil))))

(defun drgnx-doc-agents--clear-writer ()
  (drgnx-doc-agents--pulse nil)
  (when (overlayp drgnx-doc-agents--writer-ov) (delete-overlay drgnx-doc-agents--writer-ov))
  (setq drgnx-doc-agents--writer-ov nil))

;;;; Comments

(defun drgnx-doc-agents--view-call (method params)
  "Ask the hub METHOD on the events connection, where the comment-thread view lives."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (drgnx-hub--call-on drgnx-hub--events method params #'ignore)))

(defun drgnx-doc-agents--refresh ()
  "Ask the thread card to read the threads again."
  (when drgnx-doc-agents--record
    (drgnx-doc-agents--view-call "doc-comments/set" (list :view (concat "doc-comments/" drgnx-doc-agents--record) :refresh t))))

(defun drgnx-doc-agents-comment-add (text)
  "Comment on the paragraph at point: a new thread, steered to the agent writing the record (never cancelling its turn);
with none writing, it waits."
  (interactive (list (read-string "Comment on this paragraph: ")))
  (unless drgnx-doc-agents--record (user-error "This document is not a record"))
  (let* ((p (drgnx-doc-agents--paragraph (point)))
         (quote (string-trim (buffer-substring-no-properties (car p) (min (cdr p) (+ (car p) 200)))))
         (buffer (current-buffer)))
    (when (string-empty-p quote) (user-error "Point is not in a paragraph"))
    (drgnx-hub-call "comments/add"
                    (list :record drgnx-doc-agents--record :anchor (list :quote quote) :text text)
                    (lambda (_result err)
                      (if err (message "Comment: %s" err)
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer (drgnx-doc-agents--refresh))))))))

(defun drgnx-doc-agents-reply (comment text)
  "Reply TEXT in the thread of COMMENT (any comment of it), steered to the agent it was sent to."
  (interactive (list (or (get-text-property (pos-bol) 'drgnx-comment) (user-error "No comment on this line"))
                     (read-string "Reply: ")))
  (let ((buffer (current-buffer)))
    (drgnx-hub-call "comments/reply" (list :comment comment :text text)
                    (lambda (_result err)
                      (if err (message "Comment: %s" err)
                        (when (buffer-live-p buffer) (with-current-buffer buffer (drgnx-doc-agents--refresh))))))))

(defun drgnx-doc-agents--clear-markers ()
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'drgnx-doc-agents-comments) (delete-overlay ov))))

(defun drgnx-doc-agents--thread-count (th)
  (1+ (length (plist-get th :replies))))

(defun drgnx-doc-agents--find (quote)
  "The paragraph of the buffer that starts with QUOTE, as (START . END), or nil."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward (substring quote 0 (min 60 (length quote))) nil t)
      (drgnx-doc-agents--paragraph (match-beginning 0)))))

(defun drgnx-doc-agents--orphans ()
  "The threads shown whose paragraph is gone: their quote is kept for the card."
  (seq-filter (lambda (th) (equal (plist-get (plist-get th :anchor) :state) "removed")) drgnx-doc-agents--threads))

(defun drgnx-doc-agents--show-threads (threads)
  "Mark each anchored paragraph of THREADS (as `comments/list' gives them) with its comment count in the margin."
  (setq drgnx-doc-agents--threads threads)
  (drgnx-doc-agents--clear-markers)
  (let ((by-para nil))
    (dolist (th threads)
      (let* ((anchor (plist-get th :anchor)) (quote (plist-get anchor :quote)))
        (unless (equal (plist-get anchor :state) "removed")
          (when-let* ((p (and quote (drgnx-doc-agents--find quote))))
            (let ((cell (assoc p by-para)))
              (if cell (cl-incf (cdr cell) (drgnx-doc-agents--thread-count th))
                (push (cons p (drgnx-doc-agents--thread-count th)) by-para)))))))
    (dolist (c by-para)
      (let ((ov (make-overlay (caar c) (caar c))) (n (cdr c)))
        (overlay-put ov 'drgnx-doc-agents-comments n)
        (overlay-put ov 'before-string
                     (propertize (format "\N{SPEECH BALLOON} %d " n) 'help-echo (format "%d comment%s" n (if (= n 1) "" "s"))))))))

;;;; The mode

(define-minor-mode drgnx-doc-agents-mode
  "Mark the paragraph an agent is writing in this record's document and the paragraphs that carry comments."
  :lighter nil
  (unless drgnx-doc-agents-mode
    (drgnx-doc-agents--clear-writer)
    (drgnx-doc-agents--clear-markers)))

;;;; Record files, the thread card

(defun drgnx-doc-agents--record-of (file)
  "The record FILE is: a plan under docs/plans, a spec under docs/specs (their entity ids carry the file's path)."
  (cond ((string-match-p "/docs/plans/[^/]+\\.md\\'" file) (concat "plan:" file))
        ((string-match-p "/docs/specs/[^/]+\\.md\\'" file) (concat "spec:" file))))

(defun drgnx-doc-agents-maybe-enable ()
  "`find-file-hook': `drgnx-doc-agents-mode' on in a plan or spec file."
  (when-let* ((file buffer-file-name) (record (drgnx-doc-agents--record-of file)))
    (setq drgnx-doc-agents--record record)
    (drgnx-doc-agents-mode 1)))

(defvar drgnx-doc-agents-threads-mode-map (make-sparse-keymap)
  "Keys of the thread cards (the key profiles bind them: `r' replies to the thread at point).")

(define-derived-mode drgnx-doc-agents-threads-mode special-mode "Comments"
  "The comment threads of a record, a card each (the hub builds the rows)."
  (setq-local truncate-lines t cursor-type nil)
  (buffer-disable-undo))

(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-env-register "drgnx-view-env")

(defun drgnx-doc-agents-threads-open ()
  "The thread cards of this record, in a buffer of their own (the hub builds the rows)."
  (interactive)
  (let* ((record (or drgnx-doc-agents--record (user-error "This document is not a record")))
         (view (concat "doc-comments/" record))
         (buffer (get-buffer-create (format "*Comments: %s*" (file-name-nondirectory (string-remove-prefix "plan:" (string-remove-prefix "spec:" record)))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-doc-agents-threads-mode)
        (drgnx-doc-agents-threads-mode)
        (setq drgnx-doc-agents--record record)
        (if (not (fboundp 'nidhogg-view--call))
            (let ((inhibit-read-only t)) (insert "  The thread cards need drgnx's own Emacs (Nidhogg).\n"))
          (drgnx-view-patch-attach view "unshown" :sja t)
          (require 'drgnx-view-env)
          (drgnx-view-env-register view (current-buffer)
                                   (lambda (_v) (drgnx-doc-agents--view-call "doc-comments/subscribe" (list :view view :record record))))
          (drgnx-doc-agents--view-call "doc-comments/subscribe" (list :view view :record record)))))
    (pop-to-buffer buffer)))

(provide 'drgnx-doc-agents)
;;; drgnx-doc-agents.el ends here
