;;; drgnx-persist.el --- The workbench survives a restart -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The layout you leave is the layout you find: the left dock, the panel (and its tab), the right
;; dock — each with its pixel size — the editor groups with their sizes, tabs and shown files, and
;; the Explorer's folders.  Saved when Emacs exits (only from a graphical session: a batch run
;; never writes your state) to $XDG_STATE_HOME/drgnx/workbench.eld; restored at the first
;; graphical frame.  Files that no longer exist are skipped; sizes are clamped to the frame; a
;; state written by another format version is ignored.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-groups)

(defcustom drgnx-persist-restore-on-start t
  "Restore the last workbench layout at the first graphical frame."
  :type 'boolean :group 'drgnx)

(defvar drgnx-persist-file nil "The state file; nil means $XDG_STATE_HOME/drgnx/workbench.eld.")
(defconst drgnx-persist-version 2 "Format of the state file (1: one window; 2: :frames, one per window).")
(declare-function drgnx-frame-role "drgnx-frames")
(defvar drgnx-persist--pending)
(defvar drgnx-explorer--roots)
(declare-function drgnx-explorer-set-roots "drgnx-explorer")

(defun drgnx-persist--file ()
  (or drgnx-persist-file (expand-file-name "workbench.eld" (drgnx-state-dir))))

(defun drgnx-persist--area (area)
  (let ((w (drgnx-wb-area-window area)))
    (list :shown (and w t) :tab (drgnx-wb-area-tab area)
          :px (if w (if (eq area 'right) (window-pixel-width w) (window-pixel-height w))
                (frame-parameter nil (intern (format "drgnx-wb-%s-px" area)))))))

(defun drgnx-persist-state (&optional frame)
  "FRAME's workbench as a plist (see the commentary).  A frame that rebuilds itself — its parameter
`drgnx-persist-restore' is (FUNCTION . ARGS), e.g. a job window — is saved as (:role custom :restore …)."
  (if-let* ((restore (frame-parameter frame 'drgnx-persist-restore)))
      (list :role 'custom :restore restore)
    (drgnx-persist--workbench-state frame)))

(defun drgnx-persist--workbench-state (frame)
  (with-selected-frame (or frame (selected-frame))
    (let ((dock (car (drgnx-wb--dock-windows))))
      (list :role (if (fboundp 'drgnx-frame-role) (drgnx-frame-role) 'main)
            :left (list :shown (and dock t)
                        :px (if dock (window-pixel-width dock) (frame-parameter nil 'drgnx-wb-dock-px)))
            :panel (drgnx-persist--area 'panel)
            :right (drgnx-persist--area 'right)
            :roots (and (boundp 'drgnx-explorer--roots) drgnx-explorer--roots)
            :main (window-state-get (window-main-window) t)
            :groups (mapcar (lambda (g) (list :tabs (or (nth 2 (assq g drgnx-persist--pending))   ; still loading
                                                        (delq nil (mapcar #'buffer-file-name (drgnx-chrome-tabs g))))
                                              :shown (buffer-file-name (window-buffer g))))
                            (drgnx-groups-list))))))

(defun drgnx-persist--frames ()
  "The windows to save: the main (or selected graphical) one first, then the other graphical ones."
  (let* ((ok (lambda (f) (and (frame-live-p f) (frame-visible-p f) (not (frame-parent f)) (display-graphic-p f))))
         (main (or (seq-find (lambda (f) (and (funcall ok f) (eq (frame-parameter f 'drgnx-frame-role) 'main))) (frame-list))
                   (drgnx-persist--gui-frame) (selected-frame)))
         (others (seq-filter (lambda (f) (and (not (eq f main)) (funcall ok f))) (reverse (frame-list)))))
    (cons main others)))

(defun drgnx-persist-save (&optional file frames)
  "Write the workbench of FRAMES (default: every window, the main one first) to FILE (default:
`drgnx-persist-file').  Tabs not visited yet (restored at idle) are kept."
  (interactive)
  (let ((file (or file (drgnx-persist--file)))
        (state (list :version drgnx-persist-version
                     :frames (mapcar #'drgnx-persist-state (or frames (drgnx-persist--frames))))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil) (print-level nil)) (prin1 state (current-buffer))))
    file))

(defun drgnx-persist--read (file)
  (when (file-readable-p file)
    (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))

(defun drgnx-persist--strip (tree)
  "The window state TREE without its window parameters: a state file must not set any (drgnx saves
none — they would come from a crafted file)."
  (if (consp tree)
      (let ((rest (drgnx-persist--strip (cdr tree))))   ; dotted and improper lists too
        (if (eq (car-safe (car tree)) 'parameters) rest (cons (drgnx-persist--strip (car tree)) rest)))
    tree))

(defun drgnx-persist--clamp (px limit) (and (integerp px) (max 1 (min px (floor limit)))))

(defun drgnx-persist--visit (file)
  "FILE's buffer, visited without asking anything (this runs at start: nobody may be there to answer):
no remote files, only safe local variables, no large-file question; nil if it cannot be visited."
  (when (and (stringp file) (not (file-remote-p file)))
    (let ((non-essential t) (enable-local-variables :safe) (large-file-warning-threshold nil))
      (or (get-file-buffer file)
          (and (file-exists-p file) (ignore-errors (find-file-noselect file)))))))

(defvar drgnx-persist--pending nil "Tabs still to visit: list of (WINDOW FILES).")
(defvar drgnx-persist--timer nil)

(defun drgnx-persist--set-tabs (w files)
  "W's tabs: the visited ones among FILES, in FILES' order (plus what W shows)."
  (set-window-parameter w 'drgnx-tabs
                        (let ((bufs (delq nil (mapcar #'get-file-buffer (seq-filter (lambda (f) (and (stringp f) (not (file-remote-p f)))) files)))))
                          (if (or (memq (window-buffer w) bufs) (not (buffer-file-name (window-buffer w)))) bufs
                            (append bufs (list (window-buffer w)))))))

(defun drgnx-persist--visit-pending ()
  "Visit the next restored tab (one per idle tick); nil when none is left."
  (let ((entry (car drgnx-persist--pending)))
    (cond
     ((null entry)
      (when (timerp drgnx-persist--timer) (cancel-timer drgnx-persist--timer))
      (setq drgnx-persist--timer nil)
      nil)
     (t
      (pcase-let ((`(,w ,todo ,files) entry))
        (if (or (null todo) (not (window-live-p w)))
            (pop drgnx-persist--pending)
          (drgnx-persist--visit (car todo))
          (setcar (cdr entry) (cdr todo))
          (drgnx-persist--set-tabs w files)
          (drgnx-chrome-apply (window-frame w))))
      t))))

(defun drgnx-persist-restore (&optional file)
  "Bring back the workbench saved in FILE — the selected frame gets the main window's layout,
every other window is made again; non-nil if a state was restored.  Each group's shown file is
visited now, its other tabs at idle (never a question at start)."
  (interactive)
  (let* ((file (or file (drgnx-persist--file))) (state (drgnx-persist--read file))
         (frames (pcase (plist-get state :version)
                   (1 (list state))
                   (2 (plist-get state :frames)))))
    (cond
     ((null state) nil)
     ((null frames)
      (message "drgnx: %s has format %S, not %d; not restored" file (plist-get state :version) drgnx-persist-version)
      nil)
     (t
      (setq drgnx-persist--pending nil)
      ;; The selected frame gets the main window's layout — and is the main window.
      (dolist (f (frame-list)) (when (eq (frame-parameter f 'drgnx-frame-role) 'main) (set-frame-parameter f 'drgnx-frame-role nil)))
      (set-frame-parameter nil 'drgnx-frame-role 'main)
      (drgnx-persist--restore-frame (car frames))
      (let ((home (selected-frame)))
        (unwind-protect
            (dolist (st (cdr frames))            ; the window manager places them; one failing is skipped
              (if (eq (plist-get st :role) 'custom)    ; it rebuilds itself (a job window), if its code is here
                  (let ((restore (plist-get st :restore)))
                    (if (and (consp restore) (fboundp (car restore)))
                        (condition-case err (apply (car restore) (cdr restore))
                          (error (message "drgnx: a window was not restored: %s" (error-message-string err))))
                      (message "drgnx: a window was not restored: %S is not loaded" (car-safe restore))))
                (when-let* ((f (ignore-errors (make-frame '((drgnx-frame-role . aux))))))
                  (condition-case err (with-selected-frame f (drgnx-persist--restore-frame st))
                    (error (message "drgnx: a window's layout was not restored: %s" (error-message-string err)))))))
          (when (frame-live-p home) (select-frame-set-input-focus home))))
      t))))

(defun drgnx-persist--restore-frame (state)
  "Bring back one window's workbench STATE in the selected frame."
  (drgnx-wb-area-hide 'panel)
  (drgnx-wb-area-hide 'right)
  (drgnx-wb-hide-sidebar)
  (unwind-protect
      (progn
        (when-let* ((roots (seq-filter (lambda (d) (and (not (file-remote-p d)) (file-directory-p d)))
                                       (plist-get state :roots)))
                    ((fboundp 'drgnx-explorer-set-roots)))
          (drgnx-explorer-set-roots roots))
        ;; Editor groups: their tree and sizes (windows whose buffer is gone are kept — no file
        ;; is visited yet after a restart), then each one's shown file and tabs.
        (let ((groups (plist-get state :groups)))
          (when-let* ((main (plist-get state :main)))
            (let ((window-restore-killed-buffer-windows #'ignore))
              (ignore-errors (window-state-put (drgnx-persist--strip main) (window-main-window) 'safe))))
          (catch 'full                                    ; the tree did not fit: side by side, while it fits
            (while (< (length (drgnx-groups-list)) (length groups))
              (unless (ignore-errors (split-window (car (last (drgnx-groups-list))) nil 'right))
                (throw 'full nil))))
          (setq drgnx-persist--pending                    ; after earlier windows' entries, groups in order
                (append drgnx-persist--pending
                        (cl-loop for g in (drgnx-groups-list) for spec in groups
                                 collect (let* ((files (plist-get spec :tabs))
                                                (shown (drgnx-persist--visit (plist-get spec :shown))))
                                           (set-window-buffer g (or shown (get-scratch-buffer-create)))
                                           (set-window-prev-buffers g nil)
                                           (drgnx-persist--set-tabs g files)
                                           (list g (seq-remove (lambda (f) (equal f (plist-get spec :shown))) files) files)))))
          (when (and drgnx-persist--pending (not (timerp drgnx-persist--timer)))
            (setq drgnx-persist--timer (run-with-idle-timer 0.2 t #'drgnx-persist--visit-pending)))))
    ;; Docks and panel come back whatever happened above: sizes first (clamped), then shown.
    (let ((left (plist-get state :left)) (panel (plist-get state :panel)) (right (plist-get state :right)))
      (set-frame-parameter nil 'drgnx-wb-dock-px (drgnx-persist--clamp (plist-get left :px) (* 0.5 (frame-pixel-width))))
      (set-frame-parameter nil 'drgnx-wb-panel-px (drgnx-persist--clamp (plist-get panel :px) (* 0.7 (frame-pixel-height))))
      (set-frame-parameter nil 'drgnx-wb-right-px (drgnx-persist--clamp (plist-get right :px) (* 0.5 (frame-pixel-width))))
      (when (plist-get left :shown) (drgnx-wb-show-sidebar))
      (when (plist-get panel :shown) (drgnx-wb-area-show 'panel (plist-get panel :tab)))
      (when (plist-get right :shown) (drgnx-wb-area-show 'right (plist-get right :tab))))
    (drgnx-chrome-apply))
  t)

(defun drgnx-persist--gui-frame ()
  "The graphical frame to restore into or save from (a daemon's F1 is not one)."
  (if (display-graphic-p (selected-frame)) (selected-frame)
    (seq-find #'display-graphic-p (frame-list))))

(defun drgnx-persist--on-exit ()
  "Save from a graphical frame only (a batch run must never write the user's state)."
  (when-let* ((f (drgnx-persist--gui-frame)))
    (ignore-errors (with-selected-frame f (drgnx-persist-save)))))

(defvar drgnx-persist--saved-at-exit nil
  "Non-nil when a closing client already saved every window (its frames are being deleted).")

(defun drgnx-persist--before-client-delete (proc &optional noframe)
  "Before `server-delete-client' deletes PROC's frames one by one: if they are all the graphical
windows left (\[save-buffers-kill-terminal] in the last client), save every one of them now."
  (unless noframe
    (let ((gui (seq-filter (lambda (f) (and (frame-live-p f) (display-graphic-p f) (not (frame-parent f)))) (frame-list))))
      (when (and gui (seq-every-p (lambda (f) (eq (frame-parameter f 'client) proc)) gui))
        (ignore-errors (drgnx-persist-save))
        (setq drgnx-persist--saved-at-exit t)))))

(defun drgnx-persist--on-delete-frame (frame)
  "Closing the last graphical frame (a daemon's client): save it — the daemon may never exit cleanly
— unless the closing client saved every window already."
  (when (and (display-graphic-p frame)
             (not (seq-some (lambda (f) (and (not (eq f frame)) (display-graphic-p f))) (frame-list))))
    (if drgnx-persist--saved-at-exit
        (setq drgnx-persist--saved-at-exit nil)
      (ignore-errors (drgnx-persist-save nil (list frame))))))

(defun drgnx-persist--on-start ()
  "At the first graphical frame — which a daemon makes before selecting it.  An emacsclient's
window is left to `drgnx-persist--on-client-frame'."
  (when-let* (((and drgnx-persist-restore-on-start)) (f (drgnx-persist--gui-frame))
              ((not (frame-parameter f 'client))))
    (ignore-errors (with-selected-frame f (drgnx-persist-restore)))))

(defun drgnx-persist--on-client-frame ()
  "An emacsclient's new window, after the server showed its buffer in it: when it is the only
graphical window — the daemon's first, or the first after the last one closed — bring the
workbench back (a file the client asked for is shown next, on top of it)."
  (let ((f (selected-frame)))
    (when (and drgnx-persist-restore-on-start (display-graphic-p f)
               (not (seq-some (lambda (o) (and (not (eq o f)) (display-graphic-p o) (not (frame-parent o))))
                              (frame-list))))
      (ignore-errors (drgnx-persist-restore)))))

(define-minor-mode drgnx-persist-mode
  "Save the workbench when Emacs exits or its last graphical frame closes; restore it at the first
graphical frame, and at each emacsclient window that opens when no other one is open."
  :global t :group 'drgnx
  (if drgnx-persist-mode
      (progn (add-hook 'kill-emacs-hook #'drgnx-persist--on-exit)
             (add-hook 'delete-frame-functions #'drgnx-persist--on-delete-frame)
             (advice-add 'server-delete-client :before #'drgnx-persist--before-client-delete)
             (add-hook 'drgnx-first-gui-frame-hook #'drgnx-persist--on-start)
             (add-hook 'server-after-make-frame-hook #'drgnx-persist--on-client-frame))
    (remove-hook 'kill-emacs-hook #'drgnx-persist--on-exit)
    (remove-hook 'delete-frame-functions #'drgnx-persist--on-delete-frame)
    (advice-remove 'server-delete-client #'drgnx-persist--before-client-delete)
    (remove-hook 'drgnx-first-gui-frame-hook #'drgnx-persist--on-start)
    (remove-hook 'server-after-make-frame-hook #'drgnx-persist--on-client-frame)))

(provide 'drgnx-persist)
;;; drgnx-persist.el ends here
