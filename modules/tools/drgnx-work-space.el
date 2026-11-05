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

(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-wb-place "drgnx-rules")
(declare-function drgnx-work-map-buffers "drgnx-work-map")
(declare-function drgnx-work-map-buffer "drgnx-work-map")
(declare-function drgnx-work-map-mode "drgnx-work-map")
(declare-function drgnx-work-map-toggle-outline "drgnx-work-map")
(declare-function drgnx-work-map--changed "drgnx-work-map")
(defvar drgnx-work-space--view)
(defvar drgnx-work-space--message)
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

;;;; Faces: stock faces until the look's semantic ones exist; its one table retargets them

(defface drgnx-work-dim '((t :inherit shadow)) "Items off the selection's chain." :group 'drgnx-work-space)
(defface drgnx-work-card '((t :inherit default)) "A card's text." :group 'drgnx-work-space)
(defface drgnx-work-selected '((t :inherit highlight)) "The selected item." :group 'drgnx-work-space)
(defface drgnx-work-chain '((t :inherit link :underline nil)) "Items on the selection's chain." :group 'drgnx-work-space)
(defface drgnx-work-overlap '((t :inherit warning)) "An overlap's flag and its edge." :group 'drgnx-work-space)
(defface drgnx-work-needs-you '((t :inherit error)) "A thing that needs you." :group 'drgnx-work-space)
(defface drgnx-work-edge '((t :inherit shadow)) "An edge." :group 'drgnx-work-space)
(defface drgnx-work-edge-strong '((t :inherit shadow :weight bold)) "An edge that edits." :group 'drgnx-work-space)
(defface drgnx-work-label '((t :inherit shadow)) "A layer's label." :group 'drgnx-work-space)
(defface drgnx-work-chip '((t :inherit secondary-selection)) "A chip." :group 'drgnx-work-space)
(defface drgnx-work-new '((t :inherit success)) "The mark of a new conclusion." :group 'drgnx-work-space)
(defface drgnx-work-agent-1 '((t :inherit ansi-color-blue)) "The first agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-2 '((t :inherit ansi-color-green)) "The second agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-3 '((t :inherit ansi-color-magenta)) "The third agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-4 '((t :inherit ansi-color-cyan)) "The fourth agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-5 '((t :inherit ansi-color-yellow)) "The fifth agent colour." :group 'drgnx-work-space)
(defface drgnx-work-agent-6 '((t :inherit ansi-color-red)) "The sixth agent colour." :group 'drgnx-work-space)

(defconst drgnx-work-space-command-ids '(work-view work-outline)
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
  (let ((buffer (drgnx-work-space--buffer (or workspace (drgnx-work-space-workspace)))))
    (unless no-display (pop-to-buffer buffer))
    buffer))

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

;;;; The module

(defun drgnx-work-space--setup ()
  "tools/work-space's setup: the hub client's events, connection and disconnection reach the map client; the map
follows the windows; the commands."
  (drgnx-module-hook 'drgnx-hub-event-functions event (event data) (drgnx-work-client-event event data))
  (drgnx-module-hook 'drgnx-hub-connected-functions connected () (drgnx-work-client-connected))
  (drgnx-module-hook 'drgnx-hub-disconnect-functions disconnected () (drgnx-work-client-disconnected))
  (drgnx-module-hook 'drgnx-work-client-change-functions changed (view marks) (drgnx-work-map--changed view marks))
  (drgnx-module-hook 'drgnx-work-client-status-functions status (view status) (drgnx-work-space--show-status view status))
  (drgnx-state-subscribe 'windows-changed #'drgnx-work-space--windows-changed)
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-work-map-mode 'editor))
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
  (when-let* ((b (get-buffer "*drgnx work: none*"))) (kill-buffer b)))

(drgnx-module-define 'tools/work-space
                     :doc "The Work space: one map of every live piece of agent work, in six layers, with the edges between them."
                     :stage 'startup :requires '(core/workbench)
                     :setup #'drgnx-work-space--setup :teardown #'drgnx-work-space--teardown)

(provide 'drgnx-work-space)
;;; drgnx-work-space.el ends here
