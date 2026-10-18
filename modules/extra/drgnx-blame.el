;;; drgnx-blame.el --- Module extra/blame: inline blame — who changed this line, when, and why -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like VS Code's inline blame: after a short pause, the end of the line point is on says who last changed it, how
;; long ago and the commit's subject ("Ada, 3 days ago · Fix the parser"); a line you changed and have not committed
;; says "You · Uncommitted changes".  git runs in the background for that one line, on the buffer's text (so
;; unsaved edits line up); answers are kept until the buffer changes.  Only local files git tracks; a file git
;; refuses is not asked again.  Blame: Show Commit of Line opens that commit in the diff view.  See docs/guide/git.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)

(declare-function drgnx-diff-show "drgnx-diff")

(defface drgnx-blame '((t :inherit font-lock-comment-face)) "Inline blame at the end of the line." :group 'drgnx)

(defvar drgnx-blame-delay 0.6 "Seconds of idle time before the line's blame is asked for.")
(defvar drgnx-blame-cache-seconds 30 "How long a line's answer is kept (commits made elsewhere show after this).")

(defvar-local drgnx-blame--overlay nil "The overlay showing the blame.")
(defvar-local drgnx-blame--bol nil "Where the line the overlay belongs to starts.")
(defvar-local drgnx-blame--cache nil "Line → (TIME . INFO).")
(defvar-local drgnx-blame--proc nil "The git process asking for a line.")
(defvar-local drgnx-blame--off nil "git refused this file: not asked again.")
(defvar drgnx-blame--timer nil "The idle timer (one for every buffer).")
(defvar drgnx-blame-mode)

(defun drgnx-blame--parse (porcelain)
  "PORCELAIN (git blame --porcelain for one line) as (:sha :author :time :summary), or nil."
  (when (string-match "\\`\\([0-9a-f]\\{40\\}\\) " porcelain)
    (let ((sha (match-string 1 porcelain))
          (field (lambda (k) (and (string-match (format "^%s \\(.*\\)$" k) porcelain) (match-string 1 porcelain)))))
      (if (string-match-p "\\`0+\\'" sha)
          (list :sha sha :author "You" :time nil :summary "Uncommitted changes")
        (list :sha sha :author (funcall field "author")
              :time (let ((s (funcall field "author-time"))) (and s (string-to-number s)))
              :summary (funcall field "summary"))))))

(defun drgnx-blame--ago (seconds now)
  "How long before NOW the time SECONDS was, in words."
  (let* ((d (max 0 (- now seconds)))
         (say (lambda (n unit) (format "%d %s%s ago" n unit (if (= n 1) "" "s")))))
    (cond ((< d 60) "just now")
          ((< d 3600) (funcall say (/ d 60) "minute"))
          ((< d 86400) (funcall say (/ d 3600) "hour"))
          ((< d (* 30 86400)) (funcall say (/ d 86400) "day"))
          ((< d (* 365 86400)) (funcall say (/ d (* 30 86400)) "month"))
          (t (funcall say (/ d (* 365 86400)) "year")))))

(defun drgnx-blame--text (info now)
  "INFO (see `drgnx-blame--parse') as one line of at most 80 columns, in the face `drgnx-blame'."
  (let ((s (if (plist-get info :time)
               (format "%s, %s · %s" (plist-get info :author) (drgnx-blame--ago (plist-get info :time) now) (plist-get info :summary))
             (format "%s · %s" (plist-get info :author) (plist-get info :summary)))))
    (propertize (truncate-string-to-width (replace-regexp-in-string "[\n\r]" " " s) 80 nil nil "…") 'face 'drgnx-blame)))

(defun drgnx-blame--hide ()
  (when drgnx-blame--overlay (delete-overlay drgnx-blame--overlay))
  (setq drgnx-blame--bol nil))

(defun drgnx-blame--show (info)
  "Show INFO at the end of the current line."
  (unless drgnx-blame--overlay (setq drgnx-blame--overlay (make-overlay 1 1 nil t nil)))
  (move-overlay drgnx-blame--overlay (line-end-position) (line-end-position))
  (overlay-put drgnx-blame--overlay 'after-string
               (concat (propertize "   " 'cursor t) (drgnx-blame--text info (float-time))))
  (setq drgnx-blame--bol (line-beginning-position)))

(defun drgnx-blame--follow ()
  "`post-command-hook': the blame goes when point leaves its line or a region is active."
  (when (and drgnx-blame--bol (or (/= (line-beginning-position) drgnx-blame--bol) (region-active-p)))
    (drgnx-blame--hide)))

(defun drgnx-blame--forget (&rest _) (when drgnx-blame--cache (clrhash drgnx-blame--cache)))

(defun drgnx-blame--cached (line)
  (let ((e (and drgnx-blame--cache (gethash line drgnx-blame--cache))))
    (and e (< (- (float-time) (car e)) drgnx-blame-cache-seconds) (cdr e))))

(defun drgnx-blame--command (line contents)
  "git blame of LINE; CONTENTS: the buffer's text comes on stdin (it has unsaved changes)."
  (append (list "git" "blame" "--porcelain" "-L" (format "%d,%d" line line))
          (and contents '("--contents" "-"))
          (list "--" (file-name-nondirectory buffer-file-name))))

(defun drgnx-blame--refused-p (stderr)
  "Does git's STDERR say it will never blame this file (untracked, not a repository)?"
  (string-match-p "no such path\\|not a git repository\\|does not exist\\|no such ref" stderr))

(defun drgnx-blame--stop ()
  "Stop the request still running, so its end is not taken for an answer."
  (let ((p drgnx-blame--proc))
    (setq drgnx-blame--proc nil)
    (when (process-live-p p) (delete-process p))))

(defun drgnx-blame--update ()
  "Show the blame of the current line: from the cache, else from git in the background (replacing a request that
has not answered).  The empty line after the last newline has none."
  (unless (or drgnx-blame--off (not buffer-file-name) (region-active-p) (and (eobp) (bolp)))
    (let ((line (line-number-at-pos)) (buf (current-buffer)) (bol (line-beginning-position)) (modified (buffer-modified-p)))
      (if-let* ((info (drgnx-blame--cached line)))
          (drgnx-blame--show info)
        (drgnx-blame--stop)
        (let* ((out (generate-new-buffer " *drgnx-blame*" t)) (err (generate-new-buffer " *drgnx-blame err*" t))
               (default-directory (file-name-directory buffer-file-name))
               (p (make-process
                   :name "drgnx-blame" :buffer out :stderr err :noquery t :connection-type 'pipe :coding 'utf-8-unix
                   :command (drgnx-blame--command line modified)
                   :sentinel
                   (lambda (proc _event)
                     (unless (process-live-p proc)
                       (when (and (buffer-live-p buf) (eq proc (buffer-local-value 'drgnx-blame--proc buf)))
                         (with-current-buffer buf
                           (setq drgnx-blame--proc nil)
                           (if (not (eql (process-exit-status proc) 0))
                               ;; untracked, outside a repository: never again; anything else may pass
                               (when (drgnx-blame--refused-p (with-current-buffer err (buffer-string)))
                                 (setq drgnx-blame--off t))
                             (when-let* ((info (drgnx-blame--parse (with-current-buffer out (buffer-string)))))
                               (unless drgnx-blame--cache (setq drgnx-blame--cache (make-hash-table)))
                               (puthash line (cons (float-time) info) drgnx-blame--cache)
                               (when (= (line-beginning-position) bol) (drgnx-blame--show info))))))
                       (when-let* ((ep (get-buffer-process err))) (delete-process ep))
                       (kill-buffer out) (kill-buffer err))))))
          (setq drgnx-blame--proc p)
          (when modified                                     ; the text as the file has it: its coding, its line ends
            (set-process-coding-system p 'utf-8-unix (or buffer-file-coding-system 'utf-8-unix))
            (process-send-region p (point-min) (point-max)))
          (process-send-eof p))))))

(defun drgnx-blame--tick ()
  "The idle timer: the selected window's buffer, if it has inline blame."
  (with-current-buffer (window-buffer (selected-window))
    (when (and drgnx-blame-mode (not (eql drgnx-blame--bol (line-beginning-position))))
      (with-demoted-errors "drgnx blame: %S" (drgnx-blame--update)))))

(defun drgnx-blame--release-timer ()
  "Cancel the idle timer when no buffer but this one has inline blame (this one is going: off or killed)."
  (unless (seq-some (lambda (b) (and (not (eq b (current-buffer))) (buffer-local-value 'drgnx-blame-mode b))) (buffer-list))
    (when (timerp drgnx-blame--timer) (cancel-timer drgnx-blame--timer))
    (setq drgnx-blame--timer nil)))

(define-minor-mode drgnx-blame-mode
  "Inline blame: who last changed the current line, when, and the commit's subject, at its end."
  :lighter nil
  (if drgnx-blame-mode
      (progn
        (setq drgnx-blame--off nil)                          ; turned on again: asked again
        (add-hook 'post-command-hook #'drgnx-blame--follow nil t)
        (add-hook 'after-change-functions #'drgnx-blame--forget nil t)
        (add-hook 'after-save-hook #'drgnx-blame--forget nil t)
        (add-hook 'after-revert-hook #'drgnx-blame--forget nil t)
        (add-hook 'kill-buffer-hook #'drgnx-blame--release-timer nil t)
        (unless (timerp drgnx-blame--timer)
          (setq drgnx-blame--timer (run-with-idle-timer drgnx-blame-delay t #'drgnx-blame--tick))))
    (remove-hook 'post-command-hook #'drgnx-blame--follow t)
    (remove-hook 'after-change-functions #'drgnx-blame--forget t)
    (remove-hook 'after-save-hook #'drgnx-blame--forget t)
    (remove-hook 'after-revert-hook #'drgnx-blame--forget t)
    (remove-hook 'kill-buffer-hook #'drgnx-blame--release-timer t)
    (drgnx-blame--release-timer)
    (drgnx-blame--stop)
    (drgnx-blame--hide)))

(defun drgnx-blame--maybe ()
  "`find-file-hook': inline blame in a local file git tracks."
  (when (and buffer-file-name (not (file-remote-p buffer-file-name)) (eq (vc-backend buffer-file-name) 'Git))
    (drgnx-blame-mode 1)))

(defun drgnx-blame-show-commit ()
  "Blame: Show Commit of Line — the commit that last changed this line, in the diff view."
  (interactive)
  (unless buffer-file-name (user-error "Not a file"))
  (let* ((line (line-number-at-pos))
         (info (or (drgnx-blame--cached line)
                   (let ((text (buffer-substring-no-properties (point-min) (point-max)))
                         (default-directory (file-name-directory buffer-file-name))
                         (coding-system-for-write (or buffer-file-coding-system 'utf-8-unix))
                         (coding-system-for-read 'utf-8-unix)
                         (cmd (drgnx-blame--command line t)))
                     (with-temp-buffer
                       (insert text)
                       (and (eql 0 (apply #'call-process-region (point-min) (point-max) (car cmd) t '(t nil) nil (cdr cmd)))
                            (drgnx-blame--parse (buffer-string))))))))
    (cond ((null info) (user-error "git has no history for this line"))
          ((null (plist-get info :time)) (user-error "This line is not committed yet"))
          ((not (fboundp 'drgnx-diff-show)) (user-error "The diff view (module tools/diff) is off"))
          (t (drgnx-diff-show (list 'commit (plist-get info :sha)))))))

(drgnx-module-define 'extra/blame
                     :doc "Inline blame: the current line's author, age and commit subject at its end."
                     :stage 'idle
                     :setup
                     (lambda ()
                       (add-hook 'find-file-hook #'drgnx-blame--maybe)
                       (dolist (b (buffer-list)) (with-current-buffer b (drgnx-blame--maybe)))
                       (drgnx-command-define 'toggle-inline-blame :category "Source Control" :title "Toggle Inline Blame"
                                             :command #'drgnx-blame-mode :doc "Who changed the current line, at its end; off or on")
                       (drgnx-command-define 'blame-show-commit :category "Source Control" :title "Blame: Show Commit of Line"
                                             :command #'drgnx-blame-show-commit :doc "The commit that last changed this line")))

(provide 'drgnx-blame)
;;; drgnx-blame.el ends here
