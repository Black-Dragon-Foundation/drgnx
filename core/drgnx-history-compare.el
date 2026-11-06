;;; drgnx-history-compare.el --- compare two histories' hunks, and who wrote the text at point -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-history-compare' shows what branch B of the edit history has that branch A does not, file by file, each hunk
;; with who wrote it and in which step (`history/compare').  A fork opens it against its source.
;; `drgnx-history-who-wrote-this' says in the echo area who wrote the text at point or in the region, and in which step
;; (`history/blame'): its answer is the history's, not git's.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-registry)

(declare-function drgnx-hub-call-sync "drgnx-hub-client" (method params &optional timeout))
(declare-function drgnx-history-tracked-p "drgnx-history" (&optional buffer))

(defface drgnx-history-compare-heading '((t :inherit bold)) "A file's name in a comparison." :group 'drgnx)
(defface drgnx-history-compare-by '((t :inherit shadow)) "Who wrote a hunk, and in which step." :group 'drgnx)

(defun drgnx-history-compare--author (hunk)
  "A line saying who wrote HUNK's text in B and in which step."
  (let ((author (plist-get hunk :author)) (session (plist-get hunk :session)) (step (plist-get hunk :step)))
    (concat "by " (if author (format "%s" (if (listp author) (or (plist-get author :name) (plist-get author :id) author) author))
                    "no one recorded")
            (and session (format ", session %s" session))
            (and step (format ", step %s" step)))))

(defun drgnx-history-compare--insert (files)
  "Insert the compared FILES (the hub's) into the current buffer."
  (if (null files)
      (insert (propertize "The two histories hold the same text.\n" 'face 'drgnx-history-compare-by))
    (dolist (f files)
      (insert (propertize (plist-get f :path) 'face 'drgnx-history-compare-heading) "\n")
      (dolist (h (plist-get f :hunks))
        (insert "  " (propertize (drgnx-history-compare--author h) 'face 'drgnx-history-compare-by) "\n")
        (unless (string-empty-p (plist-get h :ours_text))
          (insert (propertize (concat "- " (string-replace "\n" "\n- " (plist-get h :ours_text)) "\n") 'face 'diff-removed)))
        (unless (string-empty-p (plist-get h :theirs_text))
          (insert (propertize (concat "+ " (string-replace "\n" "\n+ " (plist-get h :theirs_text)) "\n") 'face 'diff-added))))
      (insert "\n"))))

(defvar drgnx-history-compare-mode-map (make-sparse-keymap) "Keys of a comparison.")

(define-derived-mode drgnx-history-compare-mode special-mode "Compare"
  "A comparison of two edit histories' text."
  (buffer-disable-undo))

;;;###autoload
(defun drgnx-history-compare (a b)
  "Show what branch B of the edit history has that branch A does not.  Interactively, asks for both."
  (interactive (list (read-string "From branch: ") (read-string "To branch: ")))
  (require 'diff-mode)
  (let ((files (plist-get (drgnx-hub-call-sync "history/compare" (list :a a :b b) 15) :files))
        (buffer (get-buffer-create (format "*drgnx compare: %s..%s*" a b))))
    (with-current-buffer buffer
      (drgnx-history-compare-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s  ->  %s\n\n" a b) 'face 'drgnx-history-compare-heading))
        (drgnx-history-compare--insert files)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun drgnx-history-who-wrote-this--say (spans)
  "One line for SPANS (the hub's `history/blame' spans): who wrote them, in which steps."
  (if (null spans)
      "No one is recorded for this text"
    (string-join
     (delete-dups
      (mapcar (lambda (s) (format "%s%s" (or (plist-get s :author) "unknown")
                                  (if (plist-get s :step) (format " (step %s)" (plist-get s :step)) "")))
              spans))
     ", ")))

;;;###autoload
(defun drgnx-history-who-wrote-this (&optional start end)
  "Say who wrote the text between START and END (point, or the region) of this buffer, and in which step."
  (interactive (if (use-region-p) (list (region-beginning) (region-end)) (list (point) (min (1+ (point)) (point-max)))))
  (unless (and buffer-file-name (drgnx-history-tracked-p))
    (user-error "This buffer is not tracked by the edit history"))
  (let* ((root (locate-dominating-file buffer-file-name ".git"))
         (answer (drgnx-hub-call-sync
                  "history/blame" (list :path (file-relative-name buffer-file-name root)
                                        :worktree_root (directory-file-name (expand-file-name root))
                                        :start (1- (or start (point))) :end (1- (or end (1+ (point)))))
                  10)))
    (message "%s" (drgnx-history-who-wrote-this--say (plist-get answer :spans)))))

(defun drgnx-history-compare-register-commands ()
  "The comparison commands."
  (drgnx-command-define 'history-compare :category "Agents" :title "History: Compare Branches"
                        :command #'drgnx-history-compare
                        :doc "What one branch of the edit history has that another does not, by author and step")
  (drgnx-command-define 'history-who-wrote-this :category "Agents" :title "History: Who Wrote This"
                        :command #'drgnx-history-who-wrote-this
                        :doc "Who wrote the text at point, and in which step"))

(provide 'drgnx-history-compare)
;;; drgnx-history-compare.el ends here
