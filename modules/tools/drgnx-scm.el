;;; drgnx-scm.el --- Module tools/scm: the Source Control side bar -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Source Control view of the left side bar, as VS Code's: the repositories of the workspace, each one's branch
;; with Sync or Publish Branch, the commit message box with its Commit button, the staged, unstaged and conflicted
;; changes (stage, unstage, discard, open the diff) as a list or a tree, and the Source Control Graph.  The hub reads
;; the repositories and builds the rows (`scm/subscribe', runtime/crates/drgnx-ratatoskr/src/view/scm.rs) and runs
;; every git command on a thread of its own (`git/stage', `git/commit', `git/remote', …): this file draws nothing,
;; never runs git and never waits for it.  Untracked files a discard drops go to the trash, as the Explorer's
;; deletes do.  Magit stays for power use (Git: Open in Magit).  See docs/guide/git.md, "Source Control".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)

(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-view-patch-attach "drgnx-view" (view class &rest keys))
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe headless))
(declare-function drgnx-view-env-unregister "drgnx-view-env" (view))
(declare-function drgnx-wb-define-section "drgnx-wb" (name &rest spec))
(declare-function drgnx-wb-show-view "drgnx-wb" (view))
(declare-function drgnx-wb-focus-section "drgnx-wb" (name))
(declare-function drgnx-wb-editor-window "drgnx-wb" (&optional frame))
(declare-function drgnx-wb-rows-setup "drgnx-wb" ())
(declare-function drgnx-wb-selection-sync "drgnx-wb" ())
(declare-function drgnx-diff-show "drgnx-diff" (source &optional root file))
(declare-function project-root "project" (project))
(declare-function drgnx-explorer-roots "drgnx-explorer" ())
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest keys))
(declare-function magit-status "magit-status" (&optional directory cache))
(defvar drgnx-hub--events)
(defvar drgnx-wb-dock-map)
(defvar drgnx-wb--selected-overlay)

(defgroup drgnx-scm nil "The Source Control side bar." :group 'drgnx)

(defcustom drgnx-scm-smart-commit nil
  "Non-nil: Commit with nothing staged stages every change and commits, without asking (VS Code's
`git.enableSmartCommit'); the answer Always to its question sets it."
  :type 'boolean :group 'drgnx-scm)

(defcustom drgnx-scm-view-as 'list
  "How the Source Control view lists each section's changes: `list' (one row per file) or `tree' (in their folders)."
  :type '(choice (const list) (const tree)) :group 'drgnx-scm)

(defface drgnx-scm-section '((t :inherit bold)) "A Source Control section's title." :group 'drgnx-scm)
(defface drgnx-scm-deleted '((t :strike-through t)) "A deleted file's name." :group 'drgnx-scm)
(defface drgnx-scm-lane '((t :inherit drgnx-text-muted)) "The Source Control Graph's lanes." :group 'drgnx-scm)
(defface drgnx-scm-incoming '((t :inherit drgnx-accent)) "An incoming commit's mark (on the upstream only)." :group 'drgnx-scm)
(defface drgnx-scm-outgoing '((t :inherit drgnx-accent)) "An outgoing commit's mark (not pushed)." :group 'drgnx-scm)
(defface drgnx-scm-ref '((t :inherit drgnx-text-muted :box (:line-width -1)))
  "A branch or tag chip in the Source Control Graph." :group 'drgnx-scm)

(defconst drgnx-scm-view-id "scm" "The hub-fed view of the Source Control rows.")
(defconst drgnx-scm-buffer-name "*Source Control*" "The rows' buffer.")
(defconst drgnx-scm-message-buffer-name "*Source Control Message*" "The commit message box's buffer.")

(defvar drgnx-scm--target nil "The repository (its root) the commit box and the palette's commands act on, or nil.")
(defvar drgnx-scm--branches nil "Alist ROOT → its branch, as the rows last said.")
(defvar drgnx-scm--remotes nil "Alist ID → (ROOT . OP) of the remote commands running.")

;;;; Talking to the hub

(defun drgnx-scm--hub-p ()
  "Non-nil when the hub's event connection is up (the view lives on it)."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-scm--call (method params &optional then failed)
  "Ask the hub METHOD with PARAMS on the event connection; THEN gets the result on success.  A failure is a notice
with git's text, after FAILED (a function of no arguments) when given; without the hub, FAILED runs at once.  Nothing
waits."
  (if (not (drgnx-scm--hub-p))
      (progn (when failed (funcall failed)) (message "Source Control: the hub is not running"))
    (drgnx-hub--call-on drgnx-hub--events method params
                        (lambda (result error)
                          (if error
                              (progn (when failed (funcall failed)) (drgnx-scm--failed method error))
                            (when then (funcall then result)))))))

(defun drgnx-scm--failed (what error)
  "A git command WHAT failed with ERROR: a notice."
  (let ((text (if (stringp error) error (format "%s" (or (plist-get error :message) error)))))
    (if (fboundp 'drgnx-notify)
        (drgnx-notify 'core 'warn (format "Git: %s" (car (split-string text "\n")))
                      :detail text :id (list 'scm what))
      (message "Git: %s" text))))

(defun drgnx-scm--roots ()
  "The workspace's folders: the Explorer's roots, else the current project's, else `default-directory'."
  (mapcar (lambda (d) (directory-file-name (expand-file-name d)))
          (or (and (fboundp 'drgnx-explorer-roots) (drgnx-explorer-roots))
              (when-let* ((p (project-current))) (list (project-root p)))
              (list default-directory))))

(defun drgnx-scm--active-file ()
  "The file in the editor, or nil."
  (when-let* ((w (and (fboundp 'drgnx-wb-editor-window) (drgnx-wb-editor-window)))
              (f (buffer-file-name (window-buffer w))) ((not (file-remote-p f))))
    (expand-file-name f)))

(defun drgnx-scm--subscribe (&optional _view)
  "Tell the hub the view shows the workspace's repositories (at attach, and again on a reconnect)."
  (drgnx-scm--call "scm/subscribe"
                   (append (list :view drgnx-scm-view-id :roots (vconcat (drgnx-scm--roots))
                                 :view_as (symbol-name drgnx-scm-view-as))
                           (when-let* ((a (drgnx-scm--active-file))) (list :active a)))))

(defun drgnx-scm--set (&rest params)
  "A change to the view (`scm/set' with PARAMS)."
  (when (get-buffer drgnx-scm-buffer-name)
    (drgnx-scm--call "scm/set" (append (list :view drgnx-scm-view-id) params))))

;;;; The rows' buffer

(defvar drgnx-scm-mode-map
  (let ((m (make-sparse-keymap)))
    (when (boundp 'drgnx-wb-dock-map) (set-keymap-parent m drgnx-wb-dock-map))
    (define-key m [mouse-1] #'drgnx-scm-click)
    m)
  "Keys of the Source Control view (key profiles: `:map (drgnx-scm . drgnx-scm-mode-map)').")

(define-derived-mode drgnx-scm-mode special-mode "Source Control"
  "The Source Control view: the repositories, their changes and history (the hub builds the rows)."
  (setq-local truncate-lines t cursor-type nil mode-line-format nil)
  (buffer-disable-undo)
  (when (fboundp 'drgnx-wb-rows-setup) (drgnx-wb-rows-setup)))

(defun drgnx-scm--buffer ()
  "The view's buffer, attached as the hub-fed view the first time."
  (or (get-buffer drgnx-scm-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-scm-buffer-name)
        (drgnx-scm-mode)
        (if (not (fboundp 'nidhogg-view--call))
            (let ((inhibit-read-only t))
              (insert (propertize "  Source Control needs drgnx's own Emacs (Nidhogg).\n" 'face 'shadow)))
          (drgnx-view-patch-attach drgnx-scm-view-id "unshown" :sja t)
          (add-hook 'drgnx-view-patch-patched-functions #'drgnx-scm--patched nil t)
          (require 'drgnx-view-env)
          (drgnx-view-env-register drgnx-scm-view-id (current-buffer) #'drgnx-scm--subscribe)
          (drgnx-scm--subscribe))
        (current-buffer))))

(defun drgnx-scm--patched (&rest _)
  "The rows changed: keep each repository's branch (the commit box's placeholder names it), and put the selected row
back on point's row.  Sjá's edits move the selection overlay with the text (a row inserted at its start pushes it
on, an edit can leave it empty at a row's start), and only a command would sync it again: an empty overlay's stretch
to the right edge pushed the next row out of its window, drawn as a blank selected row (UX audit, Staged Changes
after a stage)."
  (let ((o drgnx-wb--selected-overlay))
    (when (and (overlayp o) (overlay-buffer o)
               (not (and (= (overlay-start o) (pos-bol)) (= (overlay-end o) (pos-eol)))))
      (drgnx-wb-selection-sync)))
  (let (branches)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((what (get-text-property (point) 'drgnx-scm)) ((equal (plist-get what :kind) "branch")))
          (push (cons (plist-get what :root) (plist-get what :branch)) branches))
        (forward-line 1)))
    (setq drgnx-scm--branches branches))
  (drgnx-scm--placeholder))

(defun drgnx-scm--what (&optional pos)
  "What the row at POS (default point) is: the hub's `drgnx-scm' plist, or nil."
  (get-text-property (or pos (point)) 'drgnx-scm))

(defun drgnx-scm--rows-in (root section &optional dir)
  "The (PATH . UNTRACKED) of every file row of ROOT's SECTION (under DIR when given)."
  (let (out)
    (with-current-buffer (drgnx-scm--buffer)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((w (drgnx-scm--what)) ((equal (plist-get w :kind) "file"))
                      ((equal (plist-get w :root) root)) ((equal (plist-get w :section) section))
                      ((or (null dir) (string-prefix-p (concat dir "/") (plist-get w :path)))))
            (push (cons (plist-get w :path) (eq (plist-get w :untracked) t)) out))
          (forward-line 1))))
    (nreverse out)))

;;;; Acting on a row

(defun drgnx-scm--stage (root paths)
  (when paths (drgnx-scm--call "git/stage" (list :root root :paths (vconcat paths)))))

(defun drgnx-scm--unstage (root paths)
  (when paths (drgnx-scm--call "git/unstage" (list :root root :paths (vconcat paths)))))

(defun drgnx-scm--discard (root files)
  "Discard FILES ((PATH . UNTRACKED)) of ROOT, asked first: tracked ones back to the index's text (`git/discard'),
untracked ones to the trash."
  (when files
    (let* ((n (length files)) (one (car files))
           (question (cond ((and (= n 1) (cdr one)) (format "Delete %s? It goes to the trash. " (car one)))
                           ((= n 1) (format "Discard changes in %s? This can't be undone. " (car one)))
                           (t (format "Discard changes in %d files? Untracked files go to the trash; the rest can't be undone. " n)))))
      (when (y-or-n-p question)
        (let ((tracked (mapcar #'car (cl-remove-if #'cdr files)))
              (untracked (mapcar #'car (cl-remove-if-not #'cdr files))))
          (when tracked (drgnx-scm--call "git/discard" (list :root root :paths (vconcat tracked))))
          (when untracked
            (let ((delete-by-moving-to-trash t))
              (dolist (p untracked)
                (let ((f (expand-file-name p root)))
                  (if (and (file-directory-p f) (not (file-symlink-p f)))
                      (delete-directory f t t)
                    (delete-file f t)))))
            (drgnx-scm--set :refresh t)))))))

(defun drgnx-scm--open-diff (root what)
  "Open WHAT's (a file row) change in the editor: the diff of its section, landing on it; an untracked file
itself."
  (let ((path (plist-get what :path)))
    (if (eq (plist-get what :untracked) t)
        (drgnx-scm--open-file root path)
      (require 'drgnx-diff)
      (drgnx-diff-show (if (equal (plist-get what :section) "staged") 'staged 'working) root path))))

(defun drgnx-scm--open-file (root path)
  "Show ROOT's file PATH in the editor."
  (let ((f (expand-file-name path root)) (w (and (fboundp 'drgnx-wb-editor-window) (drgnx-wb-editor-window))))
    (if (window-live-p w)
        (progn (set-window-buffer w (find-file-noselect f)) (select-window w))
      (find-file f))))

(defun drgnx-scm--act (action what)
  "Do ACTION (a button's `drgnx-scm-action', or the row's default when nil) on the row WHAT."
  (let* ((root (plist-get what :root)) (kind (plist-get what :kind)) (section (plist-get what :section))
         (path (plist-get what :path)) (dir (plist-get what :dir)))
    (when root (setq drgnx-scm--target root) (drgnx-scm--placeholder))
    (pcase (or action
               (pcase kind
                 ("file" "diff") ((or "section" "dir" "graph" "repos") "toggle") ("repo" "select")
                 ("commit-row" "show-commit") ("more" "more") ("commit" "commit") ("branch" "checkout")))
      ("diff" (drgnx-scm--open-diff root what))
      ("open" (drgnx-scm--open-file root path))
      ("stage" (drgnx-scm--stage root (list path)))
      ("unstage" (drgnx-scm--unstage root (list path)))
      ("discard" (drgnx-scm--discard root (list (cons path (eq (plist-get what :untracked) t)))))
      ("stage-all" (drgnx-scm--stage root (mapcar #'car (drgnx-scm--rows-in root section))))
      ("unstage-all" (drgnx-scm--unstage root (mapcar #'car (drgnx-scm--rows-in root section))))
      ("discard-all" (drgnx-scm--discard root (drgnx-scm--rows-in root section)))
      ("stage-dir" (drgnx-scm--stage root (list dir)))
      ("unstage-dir" (drgnx-scm--unstage root (list dir)))
      ("discard-dir" (drgnx-scm--discard root (drgnx-scm--rows-in root section dir)))
      ("toggle" (drgnx-scm--set :toggle (plist-get what :key)))
      ("select" (drgnx-scm--set :select (list :root root :on (if (eq (plist-get what :selected) t) :false t))))
      ("more" (drgnx-scm--set :more root))
      ("show-commit" (require 'drgnx-diff) (drgnx-diff-show (list 'commit (plist-get what :sha)) root))
      ("commit" (drgnx-scm-commit))
      ("refresh" (drgnx-scm-refresh))
      ("menu" (drgnx-scm-menu))
      ("checkout" (drgnx-scm-checkout))
      ("sync" (drgnx-scm--remote "sync"))
      ("publish" (drgnx-scm--remote "publish")))))

(defun drgnx-scm-click (event)
  "A click in the view: the button under it, else the row's default (a file's diff, a section's fold)."
  (interactive "e")
  (let* ((posn (event-start event)) (pos (posn-point posn)))
    (when (and pos (windowp (posn-window posn)))
      (with-selected-window (posn-window posn)
        (goto-char pos)
        (when-let* ((what (drgnx-scm--what pos)))
          (drgnx-scm--act (get-text-property pos 'drgnx-scm-action) what))))))

(defun drgnx-scm--here ()
  "The row at point, or a `user-error'."
  (or (and (derived-mode-p 'drgnx-scm-mode) (drgnx-scm--what (pos-bol)))
      (user-error "Not on a Source Control row")))

(defun drgnx-scm-open () "Open the change at point (a file's diff), or fold the section at point." (interactive)
       (drgnx-scm--act nil (drgnx-scm--here)))

(defun drgnx-scm-stage-at-point ()
  "Stage the file, folder or section at point."
  (interactive)
  (let ((w (drgnx-scm--here)))
    (drgnx-scm--act (pcase (plist-get w :kind) ("file" "stage") ("dir" "stage-dir") ("section" "stage-all")
                           (_ (user-error "Nothing to stage here")))
                    w)))

(defun drgnx-scm-unstage-at-point ()
  "Unstage the file, folder or section at point."
  (interactive)
  (let ((w (drgnx-scm--here)))
    (drgnx-scm--act (pcase (plist-get w :kind) ("file" "unstage") ("dir" "unstage-dir") ("section" "unstage-all")
                           (_ (user-error "Nothing to unstage here")))
                    w)))

(defun drgnx-scm-discard-at-point ()
  "Discard the changes of the file, folder or section at point (asked first)."
  (interactive)
  (let ((w (drgnx-scm--here)))
    (drgnx-scm--act (pcase (plist-get w :kind) ("file" "discard") ("dir" "discard-dir") ("section" "discard-all")
                           (_ (user-error "Nothing to discard here")))
                    w)))

(defun drgnx-scm-toggle-at-point ()
  "Fold or unfold the section, folder or graph at point."
  (interactive)
  (let ((w (drgnx-scm--here)))
    (unless (plist-get w :key) (user-error "Nothing folds here"))
    (drgnx-scm--act "toggle" w)))

;;;; The commit box

(defvar drgnx-scm-message-mode-map (make-sparse-keymap)
  "Keys of the commit message box (key profiles: `:map (drgnx-scm . drgnx-scm-message-mode-map)').")

(define-derived-mode drgnx-scm-message-mode text-mode "Commit Message"
  "The Source Control view's commit message: Ctrl+Enter commits."
  (setq-local mode-line-format nil)
  (add-hook 'post-command-hook #'drgnx-scm--placeholder nil t))

(defvar drgnx-scm--placeholder-overlay nil "The commit box's placeholder overlay.")

(defun drgnx-scm--repo ()
  "The repository the commit box acts on: the last one a row was used in, else the editor file's (the deepest
holding it), else the first the rows show; nil without rows."
  (let ((roots (mapcar #'car drgnx-scm--branches)) (file (drgnx-scm--active-file)))
    (or (and drgnx-scm--target (member drgnx-scm--target roots) drgnx-scm--target)
        (and file (car (sort (cl-remove-if-not (lambda (r) (string-prefix-p (file-name-as-directory r) file)) roots)
                             (lambda (a b) (> (length a) (length b))))))
        (car (last roots)))))

(defun drgnx-scm--placeholder ()
  "Show the commit box's placeholder while it is empty: \"Message (Ctrl+Enter to commit on \\='BRANCH\\=')\"."
  (when-let* ((buf (get-buffer drgnx-scm-message-buffer-name)))
    (with-current-buffer buf
      (unless (overlayp drgnx-scm--placeholder-overlay)
        (setq-local drgnx-scm--placeholder-overlay (make-overlay (point-min) (point-min) nil nil t)))
      (let* ((root (drgnx-scm--repo)) (branch (cdr (assoc root drgnx-scm--branches)))
             (text (if (> (buffer-size) 0) nil
                     (concat "Message (Ctrl+Enter to commit"
                             (if branch (format " on '%s'" branch) "")
                             (if (and root (cdr drgnx-scm--branches))
                                 (format " in %s" (file-name-nondirectory root)) "")
                             ")"))))
        ;; the placeholder keeps to the box's one line (cut at its edge); a message you type wraps
        (setq-local truncate-lines (and text t))
        (move-overlay drgnx-scm--placeholder-overlay (point-min) (point-min))
        (overlay-put drgnx-scm--placeholder-overlay 'after-string
                     (and text (propertize text 'face 'shadow 'cursor 0)))))))

(defun drgnx-scm--message-buffer ()
  "The commit message box's buffer."
  (or (get-buffer drgnx-scm-message-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-scm-message-buffer-name)
        (drgnx-scm-message-mode)
        (drgnx-scm--placeholder)
        (current-buffer))))

(defun drgnx-scm--message ()
  "The commit box's text, trimmed."
  (string-trim (with-current-buffer (drgnx-scm--message-buffer) (buffer-string))))

(defun drgnx-scm--staged-p (root)
  "Whether ROOT's rows show staged changes."
  (with-current-buffer (drgnx-scm--buffer)
    (save-excursion
      (goto-char (point-min))
      (let (found)
        (while (and (not found) (not (eobp)))
          (let ((w (drgnx-scm--what)))
            (setq found (and (equal (plist-get w :kind) "section") (equal (plist-get w :root) root)
                             (equal (plist-get w :section) "staged"))))
          (forward-line 1))
        found))))

(defun drgnx-scm--commit (root all)
  "Commit ROOT with the box's message (ALL: every change staged first); the box empties when it is done."
  (let ((message (drgnx-scm--message)))
    (when (string-empty-p message)
      (drgnx-wb-focus-section 'scm-message)
      (user-error "Type a commit message first"))
    ;; the box empties as the commit starts (VS Code's input does): the commit's reply waits on git; a failure puts
    ;; the message back while the box is still empty
    (with-current-buffer (drgnx-scm--message-buffer)
      (delete-region (point-min) (point-max))
      (drgnx-scm--placeholder))
    (drgnx-scm--call "git/commit" (list :root root :message message :all (if all t :false))
                     (lambda (result)
                       (let ((sha (plist-get result :sha)))
                         (message "Committed %s" (substring sha 0 (min 8 (length sha))))))
                     (lambda ()
                       (with-current-buffer (drgnx-scm--message-buffer)
                         (when (zerop (buffer-size)) (insert message))
                         (drgnx-scm--placeholder))))))

(defun drgnx-scm-commit ()
  "Commit what is staged with the commit box's message.  With nothing staged, asks once whether to stage every
change and commit (Always: from now on, `drgnx-scm-smart-commit')."
  (interactive)
  (let ((root (or (drgnx-scm--repo) (user-error "No repository"))))
    (if (or (drgnx-scm--staged-p root) (string-empty-p (drgnx-scm--message)))
        (drgnx-scm--commit root nil)
      (pcase (if drgnx-scm-smart-commit ?y
               (car (read-multiple-choice "There are no staged changes. Stage all your changes and commit them directly?"
                                          '((?y "yes" "Stage every change and commit") (?a "always" "Always, without asking")
                                            (?n "cancel" "Do not commit")))))
        (?y (drgnx-scm--commit root t))
        (?a (customize-save-variable 'drgnx-scm-smart-commit t) (drgnx-scm--commit root t))
        (_ nil)))))

(defun drgnx-scm-commit-staged () "Commit only what is staged." (interactive)
       (drgnx-scm--commit (or (drgnx-scm--repo) (user-error "No repository")) nil))

(defun drgnx-scm-commit-all () "Stage every change and commit." (interactive)
       (drgnx-scm--commit (or (drgnx-scm--repo) (user-error "No repository")) t))

(defun drgnx-scm-undo-commit ()
  "Undo the last commit, keeping its changes staged."
  (interactive)
  (let ((root (or (drgnx-scm--repo) (user-error "No repository"))))
    (when (y-or-n-p "Undo the last commit? Its changes stay staged. ")
      (drgnx-scm--call "git/undo-commit" (list :root root)))))

;;;; Remote, branches, stash

(defun drgnx-scm--remote (op)
  "Run the remote command OP (push, pull, fetch, sync, publish) in the commit box's repository; a notice says how it
ended."
  (let ((root (or (drgnx-scm--repo) (user-error "No repository"))))
    (drgnx-scm--call "git/remote" (list :root root :op op)
                     (lambda (result) (push (cons (plist-get result :id) (cons root op)) drgnx-scm--remotes)))
    (message "Git: %s…" (capitalize op))))

(put 'drgnx-scm--hub-event 'hub-events-taken '("scm-remote"))

(defun drgnx-scm--hub-event (event data)
  "`drgnx-hub-event-functions': a remote command ended (`scm-remote')."
  (when (equal event "scm-remote")
    (let ((op (capitalize (format "%s" (plist-get data :op)))) (state (plist-get data :state)))
      (unless (equal state "running")
        (setq drgnx-scm--remotes (assq-delete-all (plist-get data :id) drgnx-scm--remotes)))
      (pcase state
        ("done" (message "Git: %s done" op))
        ("stopped" (message "Git: %s stopped" op))
        ("failed" (drgnx-scm--failed op (or (plist-get data :error) "failed")))))))

(defun drgnx-scm-push () "Push the branch." (interactive) (drgnx-scm--remote "push"))
(defun drgnx-scm-pull () "Pull into the branch." (interactive) (drgnx-scm--remote "pull"))
(defun drgnx-scm-fetch () "Fetch from the remotes." (interactive) (drgnx-scm--remote "fetch"))
(defun drgnx-scm-sync () "Pull, then push." (interactive) (drgnx-scm--remote "sync"))
(defun drgnx-scm-publish () "Push a branch with no upstream and track it." (interactive) (drgnx-scm--remote "publish"))

(defun drgnx-scm-remote-stop ()
  "Stop the remote commands running."
  (interactive)
  (unless drgnx-scm--remotes (user-error "No push, pull or fetch is running"))
  (dolist (r drgnx-scm--remotes) (drgnx-scm--call "git/remote-stop" (list :id (car r)))))

(defun drgnx-scm-checkout ()
  "Pick a branch (local ones first, then remote ones) and switch to it; a new name creates it."
  (interactive)
  (let ((root (or (drgnx-scm--repo) (user-error "No repository"))))
    (drgnx-scm--call "git/branches" (list :root root)
                     (lambda (result)
                       (let* ((names (mapcar (lambda (b) (plist-get b :name)) (plist-get result :branches)))
                              (pick (completing-read "Checkout to: " names nil nil)))
                         (unless (string-empty-p pick)
                           (drgnx-scm--call "git/checkout"
                                            (list :root root :branch pick :create (if (member pick names) :false t)))))))))

(defun drgnx-scm-create-branch ()
  "Create a branch from HEAD and switch to it."
  (interactive)
  (let ((root (or (drgnx-scm--repo) (user-error "No repository")))
        (name (string-trim (read-string "New branch name: "))))
    (unless (string-empty-p name)
      (drgnx-scm--call "git/checkout" (list :root root :branch name :create t)))))

(defun drgnx-scm-delete-branch ()
  "Pick a local branch and delete it (a branch not merged is asked about again)."
  (interactive)
  (let ((root (or (drgnx-scm--repo) (user-error "No repository"))))
    (drgnx-scm--call "git/branches" (list :root root)
                     (lambda (result)
                       (let* ((names (delq nil (mapcar (lambda (b) (and (eq (plist-get b :remote) :false)
                                                                        (not (eq (plist-get b :current) t))
                                                                        (plist-get b :name)))
                                                       (plist-get result :branches))))
                              (pick (completing-read "Delete branch: " names nil t)))
                         (unless (string-empty-p pick)
                           (drgnx-scm--call "git/delete-branch" (list :root root :branch pick :force :false) nil)))))))

(defun drgnx-scm-stash () "Stash every change, untracked files too." (interactive)
       (drgnx-scm--call "git/stash" (list :root (or (drgnx-scm--repo) (user-error "No repository")) :op "push")))

(defun drgnx-scm-stash-pop () "Pop the last stash." (interactive)
       (drgnx-scm--call "git/stash" (list :root (or (drgnx-scm--repo) (user-error "No repository")) :op "pop")))

(defun drgnx-scm-open-magit () "Open the repository in Magit." (interactive)
       (unless (require 'magit nil t) (user-error "Magit is not installed"))
       (magit-status (or (drgnx-scm--repo) default-directory)))

(defvar drgnx-scm-menu-items
  '(("Pull" . drgnx-scm-pull) ("Push" . drgnx-scm-push) ("Sync" . drgnx-scm-sync) ("Fetch" . drgnx-scm-fetch)
    ("Checkout to…" . drgnx-scm-checkout) ("Create Branch…" . drgnx-scm-create-branch)
    ("Delete Branch…" . drgnx-scm-delete-branch) ("Stash" . drgnx-scm-stash) ("Pop Stash" . drgnx-scm-stash-pop)
    ("Undo Last Commit" . drgnx-scm-undo-commit) ("View as Tree / List" . drgnx-scm-toggle-view-as)
    ("Open in Magit" . drgnx-scm-open-magit))
  "The ⋯ button's menu: (LABEL . COMMAND).")

(defun drgnx-scm-menu ()
  "The ⋯ menu: pull, push, sync, fetch, branches, stash, the list or tree, Magit."
  (interactive)
  (let* ((pick (completing-read "Source Control: " (mapcar #'car drgnx-scm-menu-items) nil t)))
    (when-let* ((cmd (cdr (assoc pick drgnx-scm-menu-items)))) (call-interactively cmd))))

;;;; The palette's file commands

(defun drgnx-scm--file-root ()
  "The editor file and its repository's root, or a `user-error'."
  (let* ((file (or (buffer-file-name) (user-error "This buffer has no file")))
         (root (or (locate-dominating-file file ".git") (user-error "Not in a git repository")))
         (root (directory-file-name (expand-file-name root))))
    (cons (file-relative-name (expand-file-name file) root) root)))

(defun drgnx-scm-stage-file () "Stage this buffer's file." (interactive)
       (let ((fr (drgnx-scm--file-root))) (drgnx-scm--stage (cdr fr) (list (car fr)))))

(defun drgnx-scm-unstage-file () "Unstage this buffer's file." (interactive)
       (let ((fr (drgnx-scm--file-root))) (drgnx-scm--unstage (cdr fr) (list (car fr)))))

(defun drgnx-scm-discard-file () "Discard this buffer's file's unstaged changes (asked first)." (interactive)
       (let ((fr (drgnx-scm--file-root)))
         (when (y-or-n-p (format "Discard changes in %s? This can't be undone. " (car fr)))
           (drgnx-scm--call "git/discard" (list :root (cdr fr) :paths (vector (car fr)))
                            (lambda (_) (when (buffer-file-name) (revert-buffer t t t)))))))

(defun drgnx-scm-open-changes () "This buffer's file's changes against HEAD." (interactive)
       (require 'drgnx-diff)
       (let ((fr (drgnx-scm--file-root))) (drgnx-diff-show 'working (cdr fr) (car fr))))

(defun drgnx-scm-stage-all () "Stage every change of the repository." (interactive)
       (drgnx-scm--call "git/stage" (list :root (or (drgnx-scm--repo) (user-error "No repository")) :paths ["."])))

(defun drgnx-scm-unstage-all () "Unstage every staged change." (interactive)
       (drgnx-scm--call "git/unstage" (list :root (or (drgnx-scm--repo) (user-error "No repository")) :paths ["."])))

(defun drgnx-scm-discard-all () "Discard every change (asked first): untracked files go to the trash." (interactive)
       (let ((root (or (drgnx-scm--repo) (user-error "No repository"))))
         (drgnx-scm--discard root (drgnx-scm--rows-in root "changes"))))

;;;; The view

(defun drgnx-scm-show ()
  "Show the Source Control view in the side bar."
  (interactive)
  (drgnx-wb-show-view 'scm)
  (drgnx-wb-focus-section 'scm))

(defun drgnx-scm-refresh () "Read every shown repository again." (interactive) (drgnx-scm--set :refresh t))

(defun drgnx-scm-toggle-view-as ()
  "List each section's changes in their folders, or as a list."
  (interactive)
  (setq drgnx-scm-view-as (if (eq drgnx-scm-view-as 'tree) 'list 'tree))
  (drgnx-scm--set :view_as (symbol-name drgnx-scm-view-as)))

(defun drgnx-scm--saved ()
  "`after-save-hook': the saved file's repository is read again (while the view lives)."
  (when-let* ((f (buffer-file-name)) ((get-buffer drgnx-scm-buffer-name)) ((not (file-remote-p f))))
    (drgnx-scm--set :active (expand-file-name f))))

(defun drgnx-scm--focus-in ()
  "`after-focus-change-function' companion: a frame took the focus, so the view reads its repositories again."
  (when (and (get-buffer drgnx-scm-buffer-name) (frame-focus-state)) (drgnx-scm--set :refresh t)))

(defun drgnx-scm--teardown ()
  "Turning tools/scm off: the view's buffers go (the hub forgets the view with them)."
  (remove-hook 'after-save-hook #'drgnx-scm--saved)
  (remove-function after-focus-change-function #'drgnx-scm--focus-in)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-scm--hub-event)
  (when (get-buffer drgnx-scm-buffer-name)
    (when (drgnx-scm--hub-p) (drgnx-scm--call "scm/close" (list :view drgnx-scm-view-id)))
    (when (fboundp 'drgnx-view-env-unregister) (drgnx-view-env-unregister drgnx-scm-view-id))
    (kill-buffer drgnx-scm-buffer-name))
  (when (get-buffer drgnx-scm-message-buffer-name) (kill-buffer drgnx-scm-message-buffer-name))
  (setq drgnx-scm--target nil drgnx-scm--branches nil drgnx-scm--remotes nil))

(defconst drgnx-scm-commands
  '((scm-view "View: Show Source Control" drgnx-scm-show "Show the Source Control view")
    (git-commit "Git: Commit" drgnx-scm-commit "Commit what is staged (asks to stage all when nothing is)")
    (git-commit-staged "Git: Commit Staged" drgnx-scm-commit-staged "Commit only what is staged")
    (git-commit-all "Git: Commit All" drgnx-scm-commit-all "Stage every change and commit")
    (git-undo-commit "Git: Undo Last Commit" drgnx-scm-undo-commit "Undo the last commit, its changes staged")
    (git-stage-file "Git: Stage File" drgnx-scm-stage-file "Stage this buffer's file")
    (git-unstage-file "Git: Unstage File" drgnx-scm-unstage-file "Unstage this buffer's file")
    (git-stage-all "Git: Stage All Changes" drgnx-scm-stage-all "Stage every change of the repository")
    (git-unstage-all "Git: Unstage All Changes" drgnx-scm-unstage-all "Unstage every staged change")
    (git-discard-file "Git: Discard File Changes" drgnx-scm-discard-file "Discard this file's unstaged changes")
    (git-discard-all "Git: Discard All Changes" drgnx-scm-discard-all "Discard every change; untracked files to the trash")
    (git-push "Git: Push" drgnx-scm-push "Push the branch")
    (git-pull "Git: Pull" drgnx-scm-pull "Pull into the branch")
    (git-sync "Git: Sync" drgnx-scm-sync "Pull, then push")
    (git-fetch "Git: Fetch" drgnx-scm-fetch "Fetch from the remotes")
    (git-publish "Git: Publish Branch" drgnx-scm-publish "Push a new branch and track it")
    (git-remote-stop "Git: Stop Push or Pull" drgnx-scm-remote-stop "Stop the running push, pull or fetch")
    (git-checkout "Git: Checkout to…" drgnx-scm-checkout "Switch to a branch")
    (git-branch-create "Git: Create Branch…" drgnx-scm-create-branch "A new branch from HEAD")
    (git-branch-delete "Git: Delete Branch…" drgnx-scm-delete-branch "Delete a local branch")
    (git-stash "Git: Stash" drgnx-scm-stash "Stash every change")
    (git-stash-pop "Git: Pop Stash" drgnx-scm-stash-pop "Pop the last stash")
    (git-open-changes "Git: Open Changes" drgnx-scm-open-changes "This file's changes against HEAD")
    (git-open-magit "Git: Open in Magit" drgnx-scm-open-magit "The repository in Magit")
    (scm-refresh "Source Control: Refresh" drgnx-scm-refresh "Read the repositories again")
    (scm-view-as-tree "Source Control: Toggle Tree View" drgnx-scm-toggle-view-as "Changes in their folders, or a list"))
  "The palette's Source Control commands: (ID TITLE COMMAND DOC).")

(defconst drgnx-scm-view-commands
  '((scm-open "Source Control: Open Change" drgnx-scm-open "The change at point (a file's diff), or fold the section")
    (scm-stage "Source Control: Stage" drgnx-scm-stage-at-point "Stage the file, folder or section at point")
    (scm-unstage "Source Control: Unstage" drgnx-scm-unstage-at-point "Unstage the file, folder or section at point")
    (scm-discard "Source Control: Discard" drgnx-scm-discard-at-point "Discard the changes at point (asked first)")
    (scm-toggle "Source Control: Fold" drgnx-scm-toggle-at-point "Fold or unfold the section at point"))
  "The view's own commands, in its map: (ID TITLE COMMAND DOC).")

(defun drgnx-scm--define (id label fn doc &rest more)
  "Register command ID: LABEL is the palette's \"Category: Title\", FN its function, DOC its line, MORE the rest."
  (let ((at (string-search ": " label)))
    (apply #'drgnx-command-define id :category (substring label 0 at) :title (substring label (+ at 2))
           :command fn :doc doc more)))

(drgnx-module-define 'tools/scm
                     :doc "The Source Control side bar: changes, stage, commit, branches, push and pull, the graph."
                     :stage 'startup
                     :teardown #'drgnx-scm--teardown
                     :setup
                     (lambda ()
                       (pcase-dolist (`(,id ,label ,fn ,doc) drgnx-scm-commands)
                         (drgnx-scm--define id label fn doc))
                       (let ((in-view (lambda () (derived-mode-p 'drgnx-scm-mode))))
                         (pcase-dolist (`(,id ,label ,fn ,doc) drgnx-scm-view-commands)
                           (drgnx-scm--define id label fn doc :map 'drgnx-scm-mode-map :when in-view)))
                       (drgnx-scm--define 'scm-commit-message "Source Control: Commit from Message" #'drgnx-scm-commit
                                          "Commit with the message box's text" :map 'drgnx-scm-message-mode-map
                                          :when (lambda () (derived-mode-p 'drgnx-scm-message-mode)))
                       (when (fboundp 'drgnx-wb-define-section)
                         (drgnx-module-alist-put 'drgnx-wb-island-views 'scm '(:title "Source Control"))
                         (drgnx-wb-define-section 'scm-message :view 'scm :slot 0 :own-header t :fit 0.15 :min-rows 1
                                                  :buffer #'drgnx-scm--message-buffer)
                         (drgnx-wb-define-section 'scm :view 'scm :slot 1 :own-header t
                                                  :buffer #'drgnx-scm--buffer))
                       (add-hook 'drgnx-hub-event-functions #'drgnx-scm--hub-event)
                       (add-hook 'after-save-hook #'drgnx-scm--saved)
                       (add-function :after after-focus-change-function #'drgnx-scm--focus-in)))

(provide 'drgnx-scm)
;;; drgnx-scm.el ends here
