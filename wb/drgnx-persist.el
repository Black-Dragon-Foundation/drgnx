;;; drgnx-persist.el --- The workbench survives a restart -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The layout you leave is the layout you find: the left dock, the panel (and its tab), the right
;; dock — each with its pixel size — the sidebar view, the editor groups with their sizes, tabs and shown files, and
;; the Explorer's folders.  Saved when Emacs exits (only from a graphical session: a batch run
;; never writes your state) to $XDG_STATE_HOME/drgnx/workbench.eld; restored at the first
;; graphical frame, and again whenever a window opens after none (a daemon that keeps running after
;; its last window closed: the next `emacsclient -c' gets the layout back).  Files that no longer
;; exist are skipped; sizes are clamped to the frame; a state written by another format version is ignored.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-groups)

(defcustom drgnx-persist-restore-on-start t
  "Restore the last workbench layout at the first graphical frame."
  :type 'boolean :group 'drgnx)

(defcustom drgnx-persist-after-restore-functions nil
  "Functions called with the frame after the saved workbench was restored into it — at the first
graphical frame, and whenever a window opens after none (a daemon that kept running).  Use it to show
what a client asked for in front.  Only that one frame: the other windows of a saved workbench (aux
frames) are made again without calling it, though their extras are in `drgnx-persist-extra' too.
Nothing here may prompt or block; an error is reported, not raised."
  :type 'hook :group 'drgnx)

(defcustom drgnx-persist-state-functions nil
  "Functions called with no argument, in the frame being saved, that each return a plist of extra
keys to keep in that frame's state (the layouts module keeps `:layout', `:pane', `:arrangements',
`:previous' and `:zen-return').  Keys share one plist, so namespace yours (`:mymodule-thing').  What a
function returns must be a plist that can be read back (symbols, numbers, strings, lists — no buffers,
markers or windows); otherwise that function is left out, said once, and the others' keys are kept.
After the restore the keys are in the frame parameter `drgnx-persist-extra', readable by
`drgnx-persist-after-restore-functions'.  Nothing here may prompt; an error leaves that function's keys out."
  :type 'hook :group 'drgnx)

(defvar drgnx-persist-file nil "The state file; nil means $XDG_STATE_HOME/drgnx/workbench.eld.")
(defconst drgnx-persist-version 2 "Format of the state file (1: one window; 2: :frames, one per window).")
(declare-function drgnx-frame-role "drgnx-frames")
(defvar drgnx-persist--pending)
(defvar drgnx-explorer--roots)
(declare-function drgnx-explorer-set-roots "drgnx-explorer")

(defun drgnx-persist--file ()
  (or drgnx-persist-file (expand-file-name "workbench.eld" (drgnx-state-dir))))

(defun drgnx-persist--terminal-frame-p (&optional frame)
  "Non-nil if FRAME (default: the selected one) is a terminal window: text, on a real terminal.  Batch Emacs's
frame and a daemon's first one are on the initial terminal and are not."
  (and (not (display-graphic-p frame))
       (not (equal (terminal-name (frame-terminal frame)) "initial_terminal"))))

(defun drgnx-persist--graphical-only ()
  "Say that layouts belong to graphical windows (what Save / Restore Workbench Layout answer in a terminal)."
  (message "Layouts are saved and restored from graphical windows")
  nil)

(defun drgnx-persist--area (area)
  (let ((w (drgnx-wb-area-window area)))
    (list :shown (and w t) :tab (drgnx-wb-area-tab area)
          :px (if w (if (eq area 'right) (window-pixel-width w) (window-pixel-height w))
                (frame-parameter nil (intern (format "drgnx-wb-%s-px" area)))))))

(defun drgnx-persist-state (&optional frame)
  "FRAME's workbench as a plist (see the commentary).  A frame that rebuilds itself — its parameter
`drgnx-persist-restore' is (FUNCTION . ARGS), e.g. a job window — is saved as (:role custom :restore …),
with `:geometry' (pixel left top, then the text area's width and height — what `set-frame-size' sets, so the
size does not grow at every restart) when it is graphical."
  (if-let* ((restore (frame-parameter frame 'drgnx-persist-restore)))
      (append (list :role 'custom :restore restore)
              (and (display-graphic-p frame)
                   (let ((edges (frame-edges frame 'outer-edges)))
                     (list :geometry (list (nth 0 edges) (nth 1 edges)
                                           (frame-text-width frame) (frame-text-height frame))))))
    (drgnx-persist--workbench-state frame)))

(defun drgnx-persist--place-frame (frame geometry)
  "Put FRAME at GEOMETRY (pixel left top width height, as `drgnx-persist--geometry' checked it).  The position
is used only where it falls inside a monitor's work area (an unplugged monitor leaves one nobody can reach: the
window manager places the window then); the size is cut to the work area, from that position on."
  (pcase-let* ((`(,left ,top ,w ,h) geometry)
               (areas (delq nil (mapcar (lambda (m) (alist-get 'workarea m)) (display-monitor-attributes-list frame))))
               (area (seq-find (lambda (a) (and (<= (nth 0 a) left) (< left (+ (nth 0 a) (nth 2 a)))
                                                (<= (nth 1 a) top) (< top (+ (nth 1 a) (nth 3 a)))))
                               areas)))
    (cond (area (set-frame-position frame left top)
                (set-frame-size frame (min w (- (+ (nth 0 area) (nth 2 area)) left))
                                (min h (- (+ (nth 1 area) (nth 3 area)) top)) t))
          (areas (set-frame-size frame (min w (nth 2 (car areas))) (min h (nth 3 (car areas))) t)))))

(defun drgnx-persist--geometry (state)
  "STATE's `:geometry' (pixel left top width height) if it is four integers of a sane size, else nil
\(a state file can hold anything)."
  (let ((g (plist-get state :geometry)))
    (and (proper-list-p g) (= (length g) 4) (seq-every-p #'integerp g)
         (seq-every-p (lambda (n) (<= (abs n) 20000)) g) (> (nth 2 g) 0) (> (nth 3 g) 0) g)))

(defun drgnx-persist--workbench-state (frame)
  (with-selected-frame (or frame (selected-frame))
    (let ((dock (car (drgnx-wb--dock-windows))))
      (list :role (if (fboundp 'drgnx-frame-role) (drgnx-frame-role) 'main)
            :left (list :shown (and dock t) :view (drgnx-wb-sidebar-view)
                        :px (if dock (window-pixel-width dock) (frame-parameter nil 'drgnx-wb-dock-px)))
            :panel (drgnx-persist--area 'panel)
            :right (drgnx-persist--area 'right)
            :roots (and (boundp 'drgnx-explorer--roots) drgnx-explorer--roots)
            :main (window-state-get (window-main-window) t)
            :groups (mapcar (lambda (g) (list :tabs (or (nth 2 (assq g drgnx-persist--pending))   ; still loading
                                                        (delq nil (mapcar #'buffer-file-name (drgnx-chrome-tabs g))))
                                              :shown (buffer-file-name (window-buffer g))
                                              :px (window-pixel-width g)))
                            (drgnx-groups-list))
            :extra (drgnx-persist--extra)))))

(defvar drgnx-persist--extra-reported nil
  "The state functions already reported as failing or returning something unusable (said once each).")

(defun drgnx-persist--extra ()
  "The plist the functions of `drgnx-persist-state-functions' return, joined (the selected frame's).
A function's result counts only if it is a proper plist that can be read back (no buffer, marker or
other object); otherwise that function is skipped and said once, and the others' keys are kept."
  (let (extra)
    (run-hook-wrapped
     'drgnx-persist-state-functions
     (lambda (fn)
       (let ((r (condition-case err (funcall fn) (error (cons 'drgnx-persist-error (error-message-string err))))))
         (cond ((and (proper-list-p r) (cl-evenp (length r))
                     (let ((print-length nil) (print-level nil) (print-circle nil)) (readablep r))) ; the user's print settings cut a list short
                (setq extra (append extra r)))
               ((memq fn drgnx-persist--extra-reported))
               (t (push fn drgnx-persist--extra-reported)
                  (message "drgnx: state function %S left out of the saved workbench: %s" fn
                           (if (eq (car-safe r) 'drgnx-persist-error) (cdr r) "not a plist that can be read back")))))
       nil))
    extra))

(defun drgnx-persist--frames ()
  "The windows to save: the main (or selected graphical) one first, then the other graphical ones."
  (let* ((ok (lambda (f) (and (frame-live-p f) (frame-visible-p f) (not (frame-parent f)) (display-graphic-p f))))
         (main (or (seq-find (lambda (f) (and (funcall ok f) (eq (frame-parameter f 'drgnx-frame-role) 'main))) (frame-list))
                   (drgnx-persist--gui-frame) (selected-frame)))
         (others (seq-filter (lambda (f) (and (not (eq f main)) (funcall ok f))) (reverse (frame-list)))))
    (cons main others)))

(defun drgnx-persist-save (&optional file frames)
  "Write the workbench of FRAMES (default: every window, the main one first) to FILE (default:
`drgnx-persist-file').  Tabs not visited yet (restored at idle) are kept.  Called from a terminal window
\(and with no FRAMES) it writes nothing: a terminal session never overwrites the desktop layout."
  (interactive)
  (if (and (null frames) (drgnx-persist--terminal-frame-p))
      (drgnx-persist--graphical-only)
    (let ((file (or file (drgnx-persist--file)))
          (state (list :version drgnx-persist-version
                       :frames (mapcar #'drgnx-persist-state (or frames (drgnx-persist--frames))))))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (let ((print-length nil) (print-level nil)) (prin1 state (current-buffer))))
      file)))

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

(defun drgnx-persist--main-state (frames)
  "The state of FRAMES that goes into the selected frame: the one saved with `:role main', else the first that
is a workbench (not a window that rebuilds itself); nil when there are only such windows."
  (or (seq-find (lambda (st) (eq (plist-get st :role) 'main)) frames)
      (seq-find (lambda (st) (not (eq (plist-get st :role) 'custom))) frames)))

(defun drgnx-persist-restore (&optional file)
  "Bring back the workbench saved in FILE — the selected frame gets the main window's layout (the state
saved with `:role main', wherever it stands in the file), every other window is made again; non-nil if a
state was restored.  A window that rebuilds itself (a job window) is rebuilt by its function, on the
graphical display, and, when the display still has room, put back at its saved pixel position and size.
Each group's shown file is visited now, its other tabs at idle (never a question at start).
From a terminal window the layout goes into the first graphical frame; with none, nothing is restored."
  (interactive)
  (if (not (drgnx-persist--terminal-frame-p))
      (drgnx-persist--restore file)
    (if-let* ((gui (drgnx-persist--gui-frame)))
        (with-selected-frame gui (drgnx-persist--restore file))
      (drgnx-persist--graphical-only))))

(defun drgnx-persist--restore (file)
  "`drgnx-persist-restore' in the selected frame, which is not a terminal window."
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
      ;; The selected frame gets the main window's layout — and is the main window (a file of only job windows
      ;; has none: the frame is left as it is).
      (when-let* ((main (drgnx-persist--main-state frames)))
        (dolist (f (frame-list)) (when (eq (frame-parameter f 'drgnx-frame-role) 'main) (set-frame-parameter f 'drgnx-frame-role nil)))
        (set-frame-parameter nil 'drgnx-frame-role 'main)
        (drgnx-persist--restore-frame main)
        (setq frames (remq main frames)))
      (let ((home (selected-frame)))
        (unwind-protect
            (dolist (st frames)            ; the window manager places them; one failing is skipped
              (if (eq (plist-get st :role) 'custom)    ; it rebuilds itself (a job window), if its code is here
                  (let ((restore (plist-get st :restore)))
                    (cond
                     ((and (consp restore) (fboundp (car restore)))
                      (condition-case err
                          (let ((frame (with-selected-frame (or (drgnx-persist--gui-frame) (selected-frame)) ; its display, never a text frame
                                         (apply (car restore) (cdr restore))))
                                (g (drgnx-persist--geometry st)))
                            (when (and g (frame-live-p frame) (display-graphic-p frame))
                              (drgnx-persist--place-frame frame g)))
                        (error (message "drgnx: a window was not restored: %s" (error-message-string err)))))
                     (t (message "drgnx: a window was not restored: %S is not loaded" (car-safe restore)))))
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
      (set-frame-parameter nil 'drgnx-persist-extra (plist-get state :extra))
      (when (symbolp (plist-get left :view))          ; an unknown view falls back to the Explorer when shown
        (set-frame-parameter nil 'drgnx-wb-view (plist-get left :view)))
      (set-frame-parameter nil 'drgnx-wb-dock-px (drgnx-persist--clamp (plist-get left :px) (* 0.5 (frame-pixel-width))))
      (set-frame-parameter nil 'drgnx-wb-panel-px (drgnx-persist--clamp (plist-get panel :px) (* 0.7 (frame-pixel-height))))
      (set-frame-parameter nil 'drgnx-wb-right-px (drgnx-persist--clamp (plist-get right :px) (* 0.5 (frame-pixel-width))))
      (when (plist-get left :shown) (drgnx-wb-show-sidebar))
      (when (plist-get panel :shown) (drgnx-wb-area-show 'panel (plist-get panel :tab)))
      (when (plist-get right :shown) (drgnx-wb-area-show 'right (plist-get right :tab))))
    (drgnx-persist--fit-groups (plist-get state :groups))
    (drgnx-chrome-apply))
  t)

(defun drgnx-persist--fit-groups (specs)
  "Put the editor groups back to the pixel widths SPECS (the groups' states) hold.  `window-state-put' works in
columns, so two halves of a split can come back 4 px apart or swapped (230/234 -> 234/230); the docks are in place
by now, so what is left is exact.  Every group but the last (it takes the rest).  Only a correction of rounding:
in a frame of another size the saved widths are wrong (two 20-column halves would come back 20 and 60), so a
group more than two characters away from its saved width, a width that cannot be had, or a state that holds
none, leaves that group as it is."
  (cl-loop for (g . more) on (drgnx-groups-list) for spec in specs
           for px = (plist-get spec :px)
           when (and more (integerp px) (window-live-p g) (/= px (window-pixel-width g))
                     (<= (abs (- px (window-pixel-width g))) (* 2 (frame-char-width (window-frame g)))))
           do (let ((window-resize-pixelwise t))     ; else a 4 px change is rounded to whole columns and lost
                (ignore-errors (window-resize g (- px (window-pixel-width g)) t nil t)))))

(defun drgnx-persist--gui-frame ()
  "The graphical frame to restore into or save from (a daemon's F1 is not one, nor is a child frame)."
  (if (display-graphic-p (selected-frame)) (selected-frame)
    (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))))

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
        (ignore-errors (drgnx-persist-save nil (drgnx-persist--frames)))   ; a terminal window may be the selected one
        (setq drgnx-persist--saved-at-exit t)))))

(defun drgnx-persist--on-delete-frame (frame)
  "Closing the last graphical frame (a daemon's client): save it — the daemon may never exit cleanly
— unless the closing client saved every window already."
  (when (and (display-graphic-p frame)
             (not (frame-parameter frame 'drgnx-persist-restore))   ; a window that rebuilds itself is not the workbench
             (not (seq-some (lambda (f) (and (not (eq f frame)) (not (frame-parent f)) (display-graphic-p f)))
                            (frame-list))))       ; a child frame (a posframe) is no window of the workbench
    (if drgnx-persist--saved-at-exit
        (setq drgnx-persist--saved-at-exit nil)
      (ignore-errors (drgnx-persist-save nil (list frame))))))

(defun drgnx-persist--restore-into (frame)
  "Restore the saved workbench into FRAME, once per frame, then run
`drgnx-persist-after-restore-functions' with it (only when a state was restored).  The frame is marked
first, so a restore that fails is not tried again in that frame (not at the next window or hook either).
Nothing here asks anything or signals: it runs from hooks."
  (unless (frame-parameter frame 'drgnx-persist-restored)
    (set-frame-parameter frame 'drgnx-persist-restored t)
    (when (ignore-errors (with-selected-frame frame (drgnx-persist-restore)))
      (run-hook-wrapped 'drgnx-persist-after-restore-functions
                        (lambda (fn frame)
                          (condition-case err (funcall fn frame)
                            (error (message "drgnx: after-restore function %S failed: %s" fn (error-message-string err))))
                          nil)                          ; nil: go on with the next function
                        frame))))

(defun drgnx-persist--on-start ()
  "At the first graphical frame — which a daemon makes before selecting it.  An emacsclient's window
is left to `drgnx-persist--on-new-frame': this runs inside `make-frame', before the server shows *scratch*
in a window that asked for no file, which would replace one restored file."
  (when-let* (((and drgnx-persist-restore-on-start)) (f (drgnx-persist--gui-frame))
              ((not (frame-parameter f 'client))))
    (drgnx-persist--restore-into f)))

(defun drgnx-persist--on-new-frame (&optional frame)
  "A client's new window (`server-after-make-frame-hook', which passes no argument: the selected frame):
if it is graphical and no other graphical window exists — a daemon's first, or one that kept running
after its last window closed — bring the saved workbench back into it.  It runs after the server showed
*scratch* (no file asked for) and before it shows a file asked for.  A frame already restored is left alone."
  (let ((frame (or frame (selected-frame))))
    (when (and drgnx-persist-restore-on-start (frame-live-p frame) (display-graphic-p frame)
               (not (seq-some (lambda (f) (and (not (eq f frame)) (not (frame-parent f)) (display-graphic-p f)))
                              (frame-list))))
      (drgnx-persist--restore-into frame))))

(define-minor-mode drgnx-persist-mode
  "Save the workbench when Emacs exits or its last graphical frame closes; restore it at the first
graphical frame, and at each emacsclient window that opens when no other one is open."
  :global t :group 'drgnx
  (if drgnx-persist-mode
      (progn (add-hook 'kill-emacs-hook #'drgnx-persist--on-exit)
             (add-hook 'delete-frame-functions #'drgnx-persist--on-delete-frame)
             (advice-add 'server-delete-client :before #'drgnx-persist--before-client-delete)
             (add-hook 'drgnx-first-gui-frame-hook #'drgnx-persist--on-start)
             (add-hook 'server-after-make-frame-hook #'drgnx-persist--on-new-frame))
    (remove-hook 'server-after-make-frame-hook #'drgnx-persist--on-new-frame)
    (remove-hook 'kill-emacs-hook #'drgnx-persist--on-exit)
    (remove-hook 'delete-frame-functions #'drgnx-persist--on-delete-frame)
    (advice-remove 'server-delete-client #'drgnx-persist--before-client-delete)
    (remove-hook 'drgnx-first-gui-frame-hook #'drgnx-persist--on-start)))

(provide 'drgnx-persist)
;;; drgnx-persist.el ends here
