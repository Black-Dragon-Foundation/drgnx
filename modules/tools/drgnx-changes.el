;;; drgnx-changes.el --- The Changes view: what the agents changed, by task (library of tools/scm) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub builds the rows (`changes/subscribe', runtime/crates/drgnx-ratatoskr/src/view/changes.rs): task, then file,
;; then hunk, the hunks no task owns last.  This library is the buffer they land in, its commands on the row at point
;; (open the file at the hunk, revert the hunk) and the grouping switch of the Changes place: "By task" is this view,
;; "By repo" is Source Control's own (`drgnx-scm').  Loaded by tools/scm (drgnx-scm.el); defines no module.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-registry)

(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-unregister "drgnx-view-env")
(declare-function drgnx-wb-rows-setup "drgnx-wb")
(declare-function drgnx-scm--buffer "drgnx-scm")
(declare-function drgnx-work-code--worktree "drgnx-work-code")
(defvar drgnx-hub--events)

(defconst drgnx-changes-view-id "changes" "The hub-fed view of the Changes rows.")
(defconst drgnx-changes-buffer-name "*Changes*" "The rows' buffer.")

(defvar drgnx-changes-by 'task "How the Changes place groups: `task' (this view) or `repo' (Source Control).")

(defun drgnx-changes--hub-p ()
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-changes--call (method params &optional then)
  "Ask the hub METHOD with PARAMS; THEN gets the result.  Nothing waits."
  (if (not (drgnx-changes--hub-p))
      (message "Changes: the hub is not running")
    (drgnx-hub--call-on drgnx-hub--events method params
                        (lambda (result error)
                          (if error (message "Changes: %s" (if (stringp error) error (plist-get error :message)))
                            (when then (funcall then result)))))))

(defun drgnx-changes--subscribe (&optional _view)
  "Tell the hub the view shows what the agents changed (at attach, and again on a reconnect)."
  (drgnx-changes--call "changes/subscribe" (list :view drgnx-changes-view-id)))

(defun drgnx-changes-refresh ()
  "Read the sessions' edits again."
  (interactive)
  (when (get-buffer drgnx-changes-buffer-name)
    (drgnx-changes--call "changes/set" (list :view drgnx-changes-view-id :refresh t))))

(defvar drgnx-changes-mode-map (make-sparse-keymap) "Keys of the Changes view (the key profiles bind them).")

(define-derived-mode drgnx-changes-mode special-mode "Changes"
  "The Changes view: what the agents changed, task by task (the hub builds the rows)."
  (setq-local truncate-lines t cursor-type nil mode-line-format nil)
  (buffer-disable-undo)
  (when (fboundp 'drgnx-wb-rows-setup) (drgnx-wb-rows-setup)))

(defun drgnx-changes--buffer ()
  "The view's buffer, attached as the hub-fed view the first time."
  (or (get-buffer drgnx-changes-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-changes-buffer-name)
        (drgnx-changes-mode)
        (if (not (fboundp 'nidhogg-view--call))
            (let ((inhibit-read-only t))
              (insert (propertize "  Changes needs drgnx's own Emacs (Nidhogg).\n" 'face 'shadow)))
          (drgnx-view-patch-attach drgnx-changes-view-id "unshown" :sja t)
          (require 'drgnx-view-env)
          (drgnx-view-env-register drgnx-changes-view-id (current-buffer) #'drgnx-changes--subscribe)
          (drgnx-changes--subscribe))
        (current-buffer))))

(defun drgnx-changes--action-at-point ()
  "The `drgnx-action' of the row at point, (\"open\" PATH LINE), or nil."
  (get-text-property (pos-bol) 'drgnx-action))

(defun drgnx-changes-open-hunk ()
  "Open the file at the hunk (or the file) on this row."
  (interactive)
  (pcase (drgnx-changes--action-at-point)
    (`("open" ,path ,line)
     (find-file (expand-file-name path (or (bound-and-true-p drgnx-work-space--root) default-directory)))
     (goto-char (point-min)) (forward-line (1- (max 1 line))))
    (_ (user-error "No file on this row"))))

(defun drgnx-changes-revert-hunk ()
  "Revert the hunk on this row in its agent's worktree, when the edit history named the operation."
  (interactive)
  (let ((h (get-text-property (pos-bol) 'drgnx-hunk)))
    (unless h (user-error "No hunk on this row"))
    (unless (plist-get h :op) (user-error "The edit history has not named the operation of this hunk yet"))
    (drgnx-changes--call "history/revert/hunk"
                         (list :worktree (or (and (fboundp 'drgnx-work-code--worktree)
                                                  (drgnx-work-code--worktree (plist-get h :session)))
                                             (user-error "The agent's worktree is not known here"))
                               :op (plist-get h :op)
                               :path (plist-get h :path) :hunk (plist-get h :index))
                         (lambda (r) (message "Changes: %s" (or (plist-get r :state) "reverted"))))))

(defun drgnx-changes-group-by (by)
  "Show the Changes place grouped BY `task' (this view) or `repo' (Source Control) in the selected window."
  (setq drgnx-changes-by by)
  (switch-to-buffer (if (eq by 'repo) (drgnx-scm--buffer) (drgnx-changes--buffer))))

(defun drgnx-changes-for-item (kind id)
  "Show the Changes place by task, filtered to the item KIND (\"task\" or \"agent\") ID: only that task's groups, or
only that agent's.  The hub keeps the filter for the view until another one (an empty id shows every group)."
  (setq drgnx-changes-by 'task)
  (switch-to-buffer (drgnx-changes--buffer))
  (drgnx-changes--call "changes/set" (list :view drgnx-changes-view-id :refresh t
                                           :filter (if (equal kind "task") (list :task id) (list :agent id)))))

(defun drgnx-changes-all ()
  "Show every task's changes again (the filter `e' in Work set goes)."
  (interactive)
  (drgnx-changes--call "changes/set" (list :view drgnx-changes-view-id :refresh t :filter (list :task ""))))

(defun drgnx-changes-by-task () "Show the changes by task." (interactive) (drgnx-changes-group-by 'task))
(defun drgnx-changes-by-repo () "Show the changes by repository (Source Control)." (interactive) (drgnx-changes-group-by 'repo))

(defun drgnx-changes-setup ()
  "tools/scm's setup: the Changes commands."
  (dolist (c '((changes-by-task "Changes: By Task" drgnx-changes-by-task "What the agents changed, task by task" nil)
               (changes-by-repo "Changes: By Repo" drgnx-changes-by-repo "The changes by repository (Source Control)" nil)
               (changes-refresh "Changes: Refresh" drgnx-changes-refresh "Read the sessions' edits again" nil)
               (changes-all "Changes: Show Every Task" drgnx-changes-all "Every task's changes again (no filter)" nil)
               (changes-open-hunk "Changes: Open Hunk" drgnx-changes-open-hunk "The file at the hunk on this row"
                                  drgnx-changes-mode-map)
               (changes-revert-hunk "Changes: Revert Hunk" drgnx-changes-revert-hunk
                                    "Revert the hunk on this row in its agent's worktree" drgnx-changes-mode-map)))
    (let ((at (string-search ": " (nth 0 (cdr c)))))
      (apply #'drgnx-command-define (car c) :category (substring (nth 0 (cdr c)) 0 at)
             :title (substring (nth 0 (cdr c)) (+ at 2)) :command (nth 1 (cdr c)) :doc (nth 2 (cdr c))
             (and (nth 3 (cdr c)) (list :map (nth 3 (cdr c))))))))

(defun drgnx-changes-teardown ()
  "Turning tools/scm off: the view's buffer goes (the hub forgets the view with it)."
  (when (get-buffer drgnx-changes-buffer-name)
    (when (drgnx-changes--hub-p) (drgnx-changes--call "changes/close" (list :view drgnx-changes-view-id)))
    (when (fboundp 'drgnx-view-env-unregister) (drgnx-view-env-unregister drgnx-changes-view-id))
    (kill-buffer drgnx-changes-buffer-name)))

(provide 'drgnx-changes)
;;; drgnx-changes.el ends here
