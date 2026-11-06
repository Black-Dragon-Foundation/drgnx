;;; drgnx-work-space.el --- Module tools/work-space: the Work space, one map of every live piece of agent work -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Work space shows a workspace's agent work in six layers (you asked, specs, plans, agents, branches, files and
;; machines) and the edges between them.  The hub keeps the map and sends a frame and then deltas for each view; this
;; module owns the editor's side: the faces, the workspace of a frame, the map buffer (drgnx-work-map.el), the map
;; client's wiring to the hub client (core/drgnx-work-client.el) and the commands.  A map no window shows is told to
;; the hub as hidden and draws nothing.  Turned off, it closes its views and kills its buffers.
;; See docs/guide/work-space.md and docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-state)
(require 'drgnx-view)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-map)
  (load (expand-file-name "drgnx-work-map" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-work-detail)
  (load (expand-file-name "drgnx-work-detail" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-work-code)
  (load (expand-file-name "drgnx-work-code" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-work-code-files-command "drgnx-work-code")
(declare-function drgnx-work-who-is-here "drgnx-work-code")
(declare-function drgnx-work-code-diffs-command "drgnx-work-code")
(declare-function drgnx-work-diff-quit "drgnx-work-code")
(declare-function drgnx-work-diff-accept-hunk "drgnx-work-code")
(declare-function drgnx-work-diff-reject-hunk "drgnx-work-code")
(declare-function drgnx-work-code-teardown "drgnx-work-code")
(declare-function drgnx-work-code-local-dir "drgnx-work-code")
(declare-function drgnx-work-code-one-line "drgnx-work-code")
(defvar drgnx-work-diff-mode-map)
(unless (featurep 'drgnx-work-board)
  (load (expand-file-name "drgnx-work-board" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-work-trail)
  (load (expand-file-name "drgnx-work-trail" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-work-review)
  (load (expand-file-name "drgnx-work-review" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-work-review-buffers "drgnx-work-review")
(declare-function drgnx-work-review-show "drgnx-work-review")
(declare-function drgnx-work-review-second "drgnx-work-review")
(declare-function drgnx-work-review-accept "drgnx-work-review")
(declare-function drgnx-work-review-reject "drgnx-work-review")
(declare-function drgnx-work-trail-buffers "drgnx-work-trail")
(declare-function drgnx-work-timeline-buffers "drgnx-work-trail")
(declare-function drgnx-work-trail-event "drgnx-work-trail")
(declare-function drgnx-work-trail-show "drgnx-work-trail")
(declare-function drgnx-work-trail-steer "drgnx-work-trail")
(declare-function drgnx-work-trail-pause "drgnx-work-trail")
(declare-function drgnx-work-trail-resume "drgnx-work-trail")
(declare-function drgnx-work-trail-stop "drgnx-work-trail")
(declare-function drgnx-work-trail-show-steps "drgnx-work-trail")
(declare-function drgnx-work-trail-show-conclusions "drgnx-work-trail")
(declare-function drgnx-work-keys-sheet "drgnx-work-trail")
(declare-function drgnx-work-lens-show-timeline "drgnx-work-board")
(declare-function drgnx-work-board-buffers "drgnx-work-board")
(declare-function drgnx-work-board--changed "drgnx-work-board")
(declare-function drgnx-work-lens-show-map "drgnx-work-board")
(declare-function drgnx-work-lens-show-board "drgnx-work-board")
(declare-function drgnx-work-detail-buffer "drgnx-work-detail")
(declare-function drgnx-work-detail-update "drgnx-work-detail")
(declare-function drgnx-work-detail-buffers "drgnx-work-detail")
(declare-function drgnx-pane-define-kind "drgnx-panes")
(declare-function drgnx-pane-show "drgnx-panes")

(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-wb-place "drgnx-rules")
(declare-function drgnx-work-map-buffers "drgnx-work-map")
(declare-function drgnx-work-map-buffer "drgnx-work-map")
(declare-function drgnx-work-map-mode "drgnx-work-map")
(declare-function drgnx-work-map-toggle-outline "drgnx-work-map")
(declare-function drgnx-work-map-needs-you "drgnx-work-map")
(declare-function drgnx-work-map-needs-you-here-next "drgnx-work-map")
(declare-function drgnx-work-map-collapse-layer "drgnx-work-map")
(declare-function drgnx-work-map--changed "drgnx-work-map")
(declare-function drgnx-work-map--edges-update "drgnx-work-map")
(declare-function drgnx-work-map-theme-changed "drgnx-work-map")
(defvar drgnx-work-space--view)
(defvar drgnx-work-space--message)
(defvar drgnx-hub--events)
(declare-function drgnx-hub-running-p "drgnx-hub-client")
(declare-function drgnx-hub-connect "drgnx-hub-client")
(declare-function drgnx-hub-call "drgnx-hub-client")
(defvar drgnx-hub-event-functions)
(defvar drgnx-hub-connected-functions)
(defvar drgnx-hub-disconnect-functions)

(defgroup drgnx-work-space nil "The Work space: one map of every live piece of agent work." :group 'drgnx)

(defcustom drgnx-work-space-roots nil
  "The repositories and folders one workspace spans (the map shows work in all of them).  Unset (nil): the frame's
project root; when that lies inside another git repository, that repository and the git repositories directly inside
it (a notes repository with the code repositories inside it)."
  :type '(repeat directory) :group 'drgnx-work-space)

(defcustom drgnx-work-space-density 'comfortable
  "How roomy the map is: `compact', `comfortable' or `roomy' (card sizes, gaps and bands)."
  :type '(choice (const compact) (const comfortable) (const roomy)) :group 'drgnx-work-space)

;;;; Faces: they inherit the look's semantic faces (core/drgnx-faces.el)

(defface drgnx-work-dim '((t :inherit drgnx-text-muted)) "Items off the selection's chain." :group 'drgnx-work-space)
(defface drgnx-work-card '((t :inherit default)) "A card's text." :group 'drgnx-work-space)
(defface drgnx-work-selected '((t :inherit drgnx-selected)) "The selected item." :group 'drgnx-work-space)
(defface drgnx-work-chain '((t :inherit drgnx-accent)) "Items on the selection's chain." :group 'drgnx-work-space)
(defface drgnx-work-overlap '((t :inherit warning)) "An overlap's flag and its edge." :group 'drgnx-work-space)
(defface drgnx-work-needs-you '((t :inherit drgnx-status-attention)) "A thing that needs you." :group 'drgnx-work-space)
(defface drgnx-work-edge '((t :inherit drgnx-text-subtle)) "An edge." :group 'drgnx-work-space)
(defface drgnx-work-edge-strong '((t :inherit drgnx-text-muted :weight bold)) "An edge that edits." :group 'drgnx-work-space)
(defface drgnx-work-label '((t :inherit drgnx-text-muted)) "A layer's label." :group 'drgnx-work-space)
(defface drgnx-work-chip '((t :inherit drgnx-selected-quiet)) "A chip." :group 'drgnx-work-space)
(defface drgnx-work-new '((t :inherit success)) "The mark of a new conclusion." :group 'drgnx-work-space)
(defface drgnx-work-agent-1 '((t :inherit drgnx-agent-1)) "The first agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-2 '((t :inherit drgnx-agent-2)) "The second agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-3 '((t :inherit drgnx-agent-3)) "The third agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-4 '((t :inherit drgnx-agent-4)) "The fourth agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-5 '((t :inherit drgnx-agent-5)) "The fifth agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-6 '((t :inherit drgnx-agent-6)) "The sixth agent colour." :group 'drgnx-work-space)

(defconst drgnx-work-space-command-ids
  '(work-view work-outline work-left work-right work-why work-touches work-next-agent work-previous-agent work-open
              work-open-beside work-needs-you-next work-needs-you-here-next work-needs-you-here-previous
              work-needs-you-1 work-needs-you-2 work-needs-you-3 work-needs-you-4 work-needs-you-5 work-needs-you-6
              work-needs-you-7 work-needs-you-8 work-needs-you-9 work-view-map work-view-board work-view-timeline work-trail
              work-steer work-pause work-resume work-stop work-keys-sheet work-conclusion-steps work-step-conclusions
              work-review work-second-reviewer work-review-accept work-review-reject
              work-focus work-overlaps
              work-collapse-layer-1 work-collapse-layer-2 work-collapse-layer-3 work-collapse-layer-4
              work-collapse-layer-5 work-collapse-layer-6 work-expand-layers work-show-finished work-search
              work-escape work-take-wheel work-files work-who-is-here
              work-diffs work-diff-quit work-diff-accept-hunk work-diff-reject-hunk)
  "The commands of this module, each with a row in every key profile (keys/*.eld).")

;;;; The workspace of a frame

(defun drgnx-work-space--fnv12 (strings)
  "12 hex digits of the 64-bit FNV-1a hash of STRINGS (sorted, joined by newlines)."
  (let ((h #xcbf29ce484222325) (mask #xffffffffffffffff))
    (dolist (byte (append (encode-coding-string (mapconcat #'identity (sort (copy-sequence strings) #'string<) "\n")
                                                'utf-8 t)
                          nil))
      (setq h (logand (* (logxor h byte) #x100000001b3) mask)))
    (substring (format "%016x" h) 0 12)))

(defun drgnx-work-space--git-p (dir) (file-exists-p (expand-file-name ".git" dir)))

(defun drgnx-work-space--default-roots (root)
  "ROOT, and when it lies inside another git repository, that repository and the git repositories directly in it."
  (let* ((root (file-name-as-directory root))
         (up (locate-dominating-file (file-name-directory (directory-file-name root)) ".git")))
    (if (null up)
        (list root)
      (let ((up (file-name-as-directory up)))
        (cons up (cl-remove-duplicates
                  (cons root (seq-filter (lambda (d) (and (file-directory-p d) (drgnx-work-space--git-p d)))
                                         (directory-files up t "\\`[^.]" t)))
                  :test #'file-equal-p))))))

(defun drgnx-work-space--project-id (root)
  "A repository's id: its first root commit, else its path (the hub's Urdr project is `project:COMMIT')."
  (or (ignore-errors
        (with-temp-buffer
          (when (zerop (call-process "git" nil '(t nil) nil "-C" root "rev-list" "--max-parents=0" "HEAD"))
            (car (sort (split-string (buffer-string) "\n" t) #'string<)))))
      root))

(defun drgnx-work-space-workspace (&optional frame)
  "The workspace FRAME's selected window works in: (:id ID :roots ROOTS), or nil when it is in no project (a scratch
buffer, a folder outside git, a remote folder).  ROOTS: `drgnx-work-space-roots' or the default (see there); ID:
\"workspace:\" and 12 hex digits of the roots' project ids."
  (let* ((frame (or frame (selected-frame)))
         (dir (with-current-buffer (window-buffer (frame-selected-window frame)) default-directory))
         (root (and dir (not (file-remote-p dir))
                    (let ((default-directory dir)) (when-let* ((p (project-current))) (project-root p)))))
         (roots (cond (drgnx-work-space-roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r)))
                                                      drgnx-work-space-roots))
                      (root (drgnx-work-space--default-roots (file-truename root))))))
    (when roots
      (list :id (concat "workspace:" (drgnx-work-space--fnv12 (mapcar #'drgnx-work-space--project-id roots)))
            :roots roots))))

;;;; The map buffer

(defun drgnx-work-space--name (workspace)
  (format "*drgnx work: %s*"
          (if-let* ((root (car (plist-get workspace :roots))))
              (file-name-nondirectory (directory-file-name root))
            (plist-get workspace :id))))

(defun drgnx-work-space--width-units (&optional window)
  "The drawing width, in units of 4 px, WINDOW (or the selected one) gives the map: its pixel width less the layer
labels' margin (84 px) and 12 px of padding, in logical pixels.  A terminal frame has no pixels: 226 units."
  (if (not (display-graphic-p))
      226
    (let* ((scale (or (and (fboundp 'frame-scale-factor) (frame-scale-factor)) 1))
           (px (/ (window-body-width (or window (selected-window)) t) (float scale))))
      (max 0 (floor (- px 96) 4)))))

(defun drgnx-work-space--killed ()
  "`kill-buffer-hook' of a map buffer: its view closes."
  (when drgnx-work-space--view (drgnx-work-client-close drgnx-work-space--view)))

(defun drgnx-work-space--empty-buffer ()
  (with-current-buffer (get-buffer-create "*drgnx work: none*")
    (unless (derived-mode-p 'drgnx-work-map-mode)
      (drgnx-work-map-mode)
      (drgnx-view-attach 'work-map))
    (setq drgnx-work-space--message
          "No project: open a folder in a git repository to see its agents' work here.")
    (drgnx-view-touch drgnx-view)
    (current-buffer)))

(defun drgnx-work-space--buffer (workspace)
  "The map buffer of WORKSPACE (a plist :id :roots, or nil), made and subscribed when there is none."
  (if (null workspace)
      (drgnx-work-space--empty-buffer)
    (let ((buffer (get-buffer-create (drgnx-work-space--name workspace))))
      (with-current-buffer buffer
        (unless (equal drgnx-work-space--view (plist-get workspace :id))
          (drgnx-work-map-mode)
          (setq default-directory (car (plist-get workspace :roots))
                drgnx-work-space--view (plist-get workspace :id) drgnx-work-space--message nil)
          (add-hook 'kill-buffer-hook #'drgnx-work-space--killed nil t)
          (drgnx-view-attach 'work-map)
          (drgnx-view-touch drgnx-view)
          (drgnx-work-client-open (plist-get workspace :id) workspace
                                  :width (drgnx-work-space--width-units)
                                  :density (symbol-name drgnx-work-space-density))))
      buffer)))

;;;###autoload
(defun drgnx-work-space-open (&optional workspace no-display)
  "Open the Work space: the map of WORKSPACE (default: the selected frame's, `drgnx-work-space-workspace'), shown in
an editor window unless NO-DISPLAY.  Returns the map buffer.  Outside a project it opens an empty map that says so
and subscribes to nothing."
  (interactive)
  ;; the map's events come back on the subscribed connection: dial it when this Emacs has none and a hub is there
  (when (and (fboundp 'drgnx-hub-running-p) (not (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))
             (drgnx-hub-running-p))
    (ignore-errors (drgnx-hub-connect)))
  (let ((buffer (drgnx-work-space--buffer (or workspace (drgnx-work-space-workspace)))))
    (unless no-display
      (pop-to-buffer buffer)
      (when (and (display-graphic-p) (buffer-local-value 'drgnx-work-space--view buffer))
        (drgnx-work-space--show-detail buffer)))
    buffer))

(defun drgnx-work-space-needs-you-next ()
  "Select the next thing that needs you in the Work space: in the map a window shows, else the newest, else a map
opened now.  It selects; it never approves, pushes or answers."
  (interactive)
  (let ((buffer (or (seq-find (lambda (b) (get-buffer-window-list b nil t)) (drgnx-work-map-buffers))
                    (car (drgnx-work-map-buffers)) (drgnx-work-space-open))))
    (pop-to-buffer buffer)
    (with-current-buffer buffer (drgnx-work-map-needs-you-here-next))))

(defun drgnx-work-space--show-detail (map-buffer)
  "The side panel of MAP-BUFFER in a window of the right dock (pane kind `work-detail'), the map keeping focus."
  (condition-case err
      (let ((win (selected-window)))
        (drgnx-work-detail-buffer map-buffer)
        (drgnx-pane-show 'work-detail)
        (when (window-live-p win) (select-window win)))
    (error (message "Work: the side panel did not open: %s" (error-message-string err)))))

(defun drgnx-work-space--detail-buffer ()
  "The buffer pane kind `work-detail' shows: the side panel of the newest map."
  (if-let* ((map (car (drgnx-work-map-buffers)))) (drgnx-work-detail-buffer map) (get-buffer-create "*drgnx work detail*")))

(defun drgnx-work-space-sync-shown ()
  "Tell the hub which maps a window shows now: a hidden one gets no deltas, a shown one a full frame.  Runs on the
workbench state store's window events (and by hand in tests); only calls the hub when a map's shown state changed."
  (dolist (buffer (drgnx-work-map-buffers))
    (when-let* ((id (buffer-local-value 'drgnx-work-space--view buffer))
                (view (buffer-local-value 'drgnx-view buffer)))
      (let ((shown (and (drgnx-view-shown-p view) t)))
        (unless (eq shown (drgnx-work-client-shown-p id))
          (drgnx-work-client-set id :shown (if shown t :false)))))))

(defun drgnx-work-space--windows-changed (&optional _data)
  "The state store's `windows-changed': maps that were shown or hidden tell the hub."
  (drgnx-work-space-sync-shown))

(defun drgnx-work-space--show-status (view-id status)
  "`drgnx-work-client-status-functions': a view's status changed; the map says reconnecting in its mode line."
  (when-let* ((buffer (drgnx-work-map-buffer view-id)))
    (with-current-buffer buffer
      (setq-local mode-name (if (equal status "reconnecting") "Work map (reconnecting)" "Work map"))
      (force-mode-line-update))))

;;;; Saved state: what the selection, view and filters are, for the layout to keep

(defun drgnx-work-space-state (&optional buffer)
  "The state of BUFFER's map to keep across restarts: a plist (:version 1 :selection :lens :filters :collapsed)."
  (with-current-buffer (or buffer (current-buffer))
    (list :version 1 :selection nil :lens 'map :filters nil :collapsed nil)))

(defun drgnx-work-space-restore (state &optional buffer)
  "Put STATE (`drgnx-work-space-state') back on BUFFER's map."
  (ignore state buffer)
  nil)

;;;; Files an agent is still editing open read-only; take the wheel

(require 'drgnx-agents)

(defvar-local drgnx-work-live-file--agent nil "The mirrored session whose worktree holds this buffer's file.")
(defvar-local drgnx-work-live-file--lighter "" "The mode line chip of `drgnx-work-live-file-mode': live · NAME.")
(defvar-local drgnx-work-live-file--was-read-only nil "The buffer's read-only state before the mode.")

(defvar drgnx-work-live-file-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap read-only-mode] #'drgnx-work-take-wheel)
    (define-key m [remap View-exit] #'drgnx-work-take-wheel)
    (define-key m [remap View-exit-and-edit] #'drgnx-work-take-wheel)
    m)
  "Keys of a live agent's file.  The key profiles bind `work-take-wheel' (W) here.")

(defun drgnx-work-live-file--session (file)
  "The mirrored session that holds FILE: alive (not exited), and FILE is in its linked worktree.  A linked
worktree has a `.git' file; the user's own checkout has a `.git' directory, and an agent in it locks nothing.  A
session's folder is the hub's word: a remote one (or one a link leads out to a remote name) holds no file here, and
no file name handler runs on it (`drgnx-work-code-local-dir')."
  (seq-find (lambda (s)
              (let ((cwd (and (drgnx-agent-session-remote s) (not (eq (drgnx-agent-session-status s) 'exited))
                              (drgnx-work-code-local-dir (drgnx-agent-session-cwd s))))
                    (file-name-handler-alist nil))
                (and cwd
                     (file-in-directory-p file cwd)
                     (file-regular-p (expand-file-name ".git" cwd)))))
            drgnx-agents--sessions))

(define-minor-mode drgnx-work-live-file-mode
  "An agent is still editing in this file's worktree: it is read-only, and \\[drgnx-work-take-wheel] takes the wheel."
  :lighter drgnx-work-live-file--lighter :keymap drgnx-work-live-file-mode-map
  (if drgnx-work-live-file-mode
      (progn (setq drgnx-work-live-file--was-read-only buffer-read-only
                   drgnx-work-live-file--lighter
                   (format " live · %s" (if drgnx-work-live-file--agent (drgnx-agent-session-name drgnx-work-live-file--agent) "")))
             (view-mode 1))
    (view-mode -1)
    (remove-hook 'after-save-hook #'drgnx-work-live-file--saved t)
    (setq buffer-read-only drgnx-work-live-file--was-read-only)))

(defun drgnx-work-live-file--maybe ()
  "`find-file-hook': lock the file when an agent still holds its worktree."
  (when-let* ((file buffer-file-name) ((not (file-remote-p file))) (s (drgnx-work-live-file--session file)))
    (setq drgnx-work-live-file--agent s)
    (drgnx-work-live-file-mode 1)))

(defun drgnx-work-live-file--saved ()
  "`after-save-hook' of a file whose wheel was taken: the agent is told which file changed (queued; part 3's protocol
replaces this later)."
  (when-let* ((s drgnx-work-live-file--agent) (id (drgnx-agent-session-remote s)) (file buffer-file-name))
    (drgnx-hub-call "agents/send"
                    ;; the file's name is the agent's: it stays on the message's one line
                    (list :id id :text (format "I edited %s while you were paused. Read it again before you change it."
                                               (drgnx-work-code-one-line (file-name-nondirectory file))))
                    #'ignore)))

(defun drgnx-work-take-wheel ()
  "Take the wheel of the agent holding this file: it is paused after its current tool call, the buffer becomes editable,
and saving tells the agent which file you changed."
  (interactive)
  (let ((s (or drgnx-work-live-file--agent (user-error "No live agent holds this file"))))
    (when-let* ((id (drgnx-agent-session-remote s))) (drgnx-hub-call "agents/pause" (list :id id) #'ignore))
    (view-mode -1)
    (setq buffer-read-only nil)
    (add-hook 'after-save-hook #'drgnx-work-live-file--saved nil t)
    (message "Work: %s is paused and this file is yours; save to tell it" (drgnx-agent-session-name s))))

;;;; The module

(defun drgnx-work-space--setup ()
  "tools/work-space's setup: the hub client's events, connection and disconnection reach the map client; the map
follows the windows; the commands."
  (drgnx-module-hook 'drgnx-hub-event-functions event (event data) (drgnx-work-client-event event data))
  (drgnx-module-hook 'drgnx-hub-connected-functions connected () (drgnx-work-client-connected))
  (drgnx-module-hook 'drgnx-hub-disconnect-functions disconnected () (drgnx-work-client-disconnected))
  (drgnx-module-hook 'drgnx-work-client-change-functions changed (view marks) (drgnx-work-map--changed view marks))
  (drgnx-module-hook 'drgnx-work-client-change-functions board-changed (view marks) (drgnx-work-board--changed view marks))
  (drgnx-module-hook 'drgnx-hub-event-functions trail-event (event data) (drgnx-work-trail-event event data))
  (drgnx-module-hook 'drgnx-work-client-status-functions status (view status) (drgnx-work-space--show-status view status))
  (drgnx-module-hook 'drgnx-work-map-select-functions selected (buffer) (drgnx-work-detail-update buffer))
  (drgnx-module-hook 'drgnx-work-map-edges-functions edges (view selection) (drgnx-work-map--edges-update view selection))
  (drgnx-module-hook 'enable-theme-functions edge-colours (_theme) (drgnx-work-map-theme-changed))
  (drgnx-module-hook 'disable-theme-functions edge-colours-off (_theme) (drgnx-work-map-theme-changed))
  (drgnx-module-hook 'find-file-hook live-file () (drgnx-work-live-file--maybe))
  (drgnx-command-define 'work-take-wheel :category "Work" :title "Take the Wheel from the Agent"
                        :command #'drgnx-work-take-wheel :map 'drgnx-work-live-file-mode-map
                        :doc "Pause the agent that is editing here and make this file editable; saving tells the agent")
  (drgnx-state-subscribe 'windows-changed #'drgnx-work-space--windows-changed)
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-work-map-mode 'editor))
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-work-files-mode 'popup))
  (drgnx-command-define 'work-files :category "Work" :title "List the Agent's Files"
                        :command #'drgnx-work-code-files-command :map 'drgnx-work-map-mode-map
                        :doc "The files the selected agent edited, one key each; the key opens the file at the agent's line")
  (drgnx-command-define 'work-diffs :category "Work" :title "Show the Agent's Diffs Side by Side"
                        :command #'drgnx-work-code-diffs-command :map 'drgnx-work-map-mode-map
                        :doc "The files the selected agent edited, one window each (three at most), against their base; q puts the windows back")
  (drgnx-command-define 'work-diff-quit :category "Work" :title "Close the Diffs"
                        :command #'drgnx-work-diff-quit :map 'drgnx-work-diff-mode-map
                        :doc "Close the side-by-side diffs and restore the windows as they were")
  (drgnx-command-define 'work-diff-accept-hunk :category "Work" :title "Accept the Hunk"
                        :command #'drgnx-work-diff-accept-hunk :map 'drgnx-work-diff-mode-map
                        :doc "Accept the hunk at point; the review view decides hunks")
  (drgnx-command-define 'work-diff-reject-hunk :category "Work" :title "Reject the Hunk"
                        :command #'drgnx-work-diff-reject-hunk :map 'drgnx-work-diff-mode-map
                        :doc "Reject the hunk at point; the review view decides hunks")
  (drgnx-command-define 'work-who-is-here :category "Work" :title "Who Is in This File"
                        :command #'drgnx-work-who-is-here
                        :doc "Name the agents in the file you are visiting, with their lines, and select it on the map")
  (when (fboundp 'drgnx-pane-define-kind)
    (drgnx-pane-define-kind 'work-detail :title " WORK DETAIL" :home 'right :buffer #'drgnx-work-space--detail-buffer))
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((work-left "Select the Previous Item" drgnx-work-map-left "Along the layer, to the left")
                   (work-right "Select the Next Item" drgnx-work-map-right "Along the layer, to the right")
                   (work-why "Select What It Came From" drgnx-work-map-why "Follow why up, to the nearest by position")
                   (work-touches "Select What It Touches" drgnx-work-map-touches "Follow touches down")
                   (work-next-agent "Select the Next Agent" drgnx-work-map-next-agent "The next agent, in team order")
                   (work-previous-agent "Select the Previous Agent" drgnx-work-map-previous-agent
                                        "The previous agent, in team order")
                   (work-open "Open" drgnx-work-map-open-selection
                              "An agent's transcript, a branch's repository, a file or a document")
                   (work-open-beside "Open Beside" drgnx-work-map-open-beside "Open it without moving focus")))
    ;; the lens map: the Board and the Timeline share these keys and move in their own way
    (drgnx-command-define id :category "Work" :title title :command fn :map 'drgnx-work-lens-map :doc doc))
  (drgnx-command-define 'work-view-map :category "Work" :title "Show the Map" :command #'drgnx-work-lens-show-map
                        :map 'drgnx-work-lens-map :doc "The map, keeping the selection")
  (drgnx-command-define 'work-view-board :category "Work" :title "Show the Board" :command #'drgnx-work-lens-show-board
                        :map 'drgnx-work-lens-map :doc "The tracker's tasks by column, keeping the selection")
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((work-view-timeline "Show the Timeline" drgnx-work-lens-show-timeline "A lane for each agent over time, keeping the selection")
                   (work-trail "Open the Research Trail" drgnx-work-trail-show "The selected agent's steps in order, with its conclusions")
                   (work-steer "Steer the Agent" drgnx-work-trail-steer "Message the selected agent; queued or steering, never a cancel")
                   (work-pause "Pause the Agent" drgnx-work-trail-pause "Cancel after the current tool call; u resumes")
                   (work-resume "Resume the Agent" drgnx-work-trail-resume "A plain continue prompt, labelled in the trail")
                   (work-stop "Stop the Agent" drgnx-work-trail-stop "Stop it, after a confirmation line")
                   (work-keys-sheet "Show This View's Keys" drgnx-work-keys-sheet "The keyboard shortcuts sheet")
                   (work-review "Open the Review" drgnx-work-review-show
                                "The selected agent's decisions with what they computed to, then its work as hunks")
                   (work-second-reviewer "Start a Second Reviewer" drgnx-work-review-second
                                         "A reviewer that sees the code and not the author's conclusions, through job/propose")))
    (drgnx-command-define id :category "Work" :title title :command fn :map 'drgnx-work-lens-map :doc doc))
  (drgnx-command-define 'work-review-accept :category "Work" :title "Accept the Change Here"
                        :command #'drgnx-work-review-accept :map 'drgnx-work-review-mode-map
                        :doc "A review mark with the diff's hash, for the merge gate; nothing is merged")
  (drgnx-command-define 'work-review-reject :category "Work" :title "Reject the Hunk Here"
                        :command #'drgnx-work-review-reject :map 'drgnx-work-review-mode-map
                        :doc "The file goes back to pending and the agent is told, queued; the agent is not cancelled")
  (drgnx-command-define 'work-conclusion-steps :category "Work" :title "Light the Steps of a Conclusion"
                        :command #'drgnx-work-trail-show-steps :map 'drgnx-work-trail-mode-map
                        :doc "On a conclusion: light the steps it rests on and go through them")
  (drgnx-command-define 'work-step-conclusions :category "Work" :title "Go to the Conclusions of a Step"
                        :command #'drgnx-work-trail-show-conclusions :map 'drgnx-work-trail-mode-map
                        :doc "On a step: go to the first conclusion that rests on it")
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((work-needs-you-here-next "Select the Next Thing That Needs You" drgnx-work-map-needs-you-here-next
                                             "Cycle the strip's chips; it selects, it never approves")
                   (work-needs-you-here-previous "Select the Previous Thing That Needs You"
                                                 drgnx-work-map-needs-you-here-previous "Cycle the strip's chips backwards")
                   (work-focus "Focus on the Chain" drgnx-work-map-focus "Hide what is not on the selection's chain; again for all")
                   (work-overlaps "Show Overlaps Only" drgnx-work-map-overlaps "Only the agents and branches that overlap")
                   (work-expand-layers "Expand All Layers" drgnx-work-map-expand-layers "Every layer open again")
                   (work-show-finished "Show Finished Items" drgnx-work-map-show-finished "Finished items too; again to hide them")
                   (work-search "Narrow the Map" drgnx-work-map-search "Dim what does not match; Enter selects the first match")
                   (work-escape "Clear Search, Filters, then Close" drgnx-work-map-escape
                                "Esc: the search first, then the filters, then the pane")))
    (drgnx-command-define id :category "Work" :title title :command fn :map 'drgnx-work-map-mode-map :doc doc))
  (drgnx-command-define 'work-needs-you-next :category "Work" :title "Next Thing That Needs You"
                        :command #'drgnx-work-space-needs-you-next
                        :doc "Select the next thing that needs you in the Work space, opening the map")
  (dotimes (i 9)
    (let ((n (1+ i)))
      (drgnx-command-define (intern (format "work-needs-you-%d" n)) :category "Work"
                            :title (format "Select Thing %d That Needs You" n)
                            :command (lambda () (interactive) (drgnx-work-map-needs-you n))
                            :map 'drgnx-work-map-mode-map :doc "Jump to it; nothing is approved or answered")))
  (dotimes (i 6)
    (let ((n (1+ i)))
      (drgnx-command-define (intern (format "work-collapse-layer-%d" n)) :category "Work"
                            :title (format "Collapse or Expand Layer %d" n)
                            :command (lambda () (interactive) (drgnx-work-map-collapse-layer n))
                            :map 'drgnx-work-map-mode-map :doc "One thin row with its name and count; again to expand")))
  (drgnx-command-define 'work-view :category "Work" :title "Open the Work Space" :command #'drgnx-work-space-open
                        :doc "The map of every live piece of agent work: asks, specs, plans, agents, branches, files and machines")
  (drgnx-command-define 'work-outline :category "Work" :title "Show the Map as an Outline"
                        :command #'drgnx-work-map-toggle-outline :map 'drgnx-work-map-mode-map
                        :doc "One block per agent, with why it exists and what it touches; again for the map"))

(defun drgnx-work-space--teardown ()
  "tools/work-space's `:teardown': the views close (the hub forgets them) and the map buffers go."
  (drgnx-work-client-close-all)
  (dolist (b (drgnx-work-map-buffers))
    (with-current-buffer b (remove-hook 'kill-buffer-hook #'drgnx-work-space--killed t))
    (kill-buffer b))
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-work-live-file-mode b)
      (with-current-buffer b (drgnx-work-live-file-mode -1))))
  (dolist (b (append (drgnx-work-board-buffers) (drgnx-work-timeline-buffers) (drgnx-work-trail-buffers)
                     (drgnx-work-review-buffers)))
    (kill-buffer b))
  (dolist (b (drgnx-work-detail-buffers)) (kill-buffer b))
  (drgnx-work-code-teardown)
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-work-files-mode) (kill-buffer b)))
  (when-let* ((b (get-buffer "*drgnx work: none*"))) (kill-buffer b)))

(drgnx-module-define 'tools/work-space
                     :doc "The Work space: one map of every live piece of agent work, in six layers, with the edges between them."
                     :stage 'startup :requires '(core/workbench)
                     :setup #'drgnx-work-space--setup :teardown #'drgnx-work-space--teardown)

(provide 'drgnx-work-space)
;;; drgnx-work-space.el ends here
