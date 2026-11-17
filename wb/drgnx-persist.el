;;; drgnx-persist.el --- The workbench survives a restart -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The layout you leave is the layout you find: each window's grid of tiles (`drgnx-grid-tree': the docks, the tool
;; tiles and their stacks, the editor tiles with their tabs and shown files, every size), what the grid remembers of
;; hidden tiles, the sizes you chose, the sidebar view and the Explorer's folders.  Saved when Emacs exits (only from a graphical session: a batch run
;; never writes your state) to $XDG_STATE_HOME/drgnx/workbench.eld; restored at the first
;; graphical frame, and again whenever a window opens after none (a daemon that keeps running after
;; its last window closed: the next `emacsclient -c' gets the layout back).  Files that no longer
;; exist are skipped; sizes are clamped to the frame; a tile whose kind is not defined waits as a placeholder until its
;; module is on (`drgnx-grid-tile-placeholder').  A format-2 file (the docks and groups of before the grid) is migrated
;; on read (`drgnx-persist--from-v2'); another format is ignored.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-state-intent)           ; the store: which frames, and the sizes you chose
(require 'drgnx-groups)
(require 'drgnx-grid)
(require 'drgnx-timer)
(require 'drgnx-notice)
(defvar drgnx-large-file-open)          ; core/drgnx-large-file.el: bound around the visits, read by editor/large-files
(defvar drgnx-persist--refit (make-hash-table :test #'eq :weakness 'key)
  "Frame → (WIDTH HEIGHT . TREE): its pixel size when last seen and the grid it was restored with, until the first
command after the restore.")

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
(defconst drgnx-persist-version 3
  "Format of the state file: 3, :frames, one per window, each with its grid (`:tree').  A format-2 file (each window's
docks and editor groups) is migrated when read.")
(defconst drgnx-persist--max-bytes 4194304
  "The largest state file drgnx writes or reads, in bytes (4 MiB: a layout with many tabs and windows is far less).")
(define-error 'drgnx-persist-newer "workbench.eld was written by a newer drgnx" 'file-error)
(declare-function drgnx-frame-role "drgnx-frames")
(defvar drgnx-persist--pending)
(declare-function drgnx-explorer-chosen-roots "drgnx-explorer")
(declare-function drgnx-explorer-set-roots "drgnx-explorer")

(defun drgnx-persist--file ()
  (or drgnx-persist-file (expand-file-name "workbench.eld" (drgnx-state-dir))))

(defun drgnx-persist--terminal-frame-p (&optional frame)
  "Non-nil if FRAME (default: the selected one) is a terminal window: the store's kind `tty' (a child frame counts
as its root frame), on a real terminal.  A daemon's first frame (`initial') is not one; batch Emacs's frame is
`tty' for the store but not a terminal window here: it may save and restore when asked (tests, scripts), and
`drgnx-persist--on-exit' still never writes from it (no graphical frame)."
  (let ((frame (or frame (selected-frame))))
    (while (and (frame-live-p frame) (frame-parent frame)) (setq frame (frame-parent frame)))
    (and (eq (drgnx-state-frame-kind frame) 'tty)
         (not (equal (terminal-name (frame-terminal frame)) "initial_terminal")))))

(defun drgnx-persist--gui-p (frame)
  "Non-nil if FRAME is a graphical window (the store's kind `gui'; a child frame is not)."
  (eq (drgnx-state-frame-kind frame) 'gui))

(defun drgnx-persist--save-skipped-p (frames)
  "Non-nil if `drgnx-persist-save' called with FRAMES writes nothing: no frames were given (it would save the
selected frame's workbench) and the selected frame is a terminal window.  Explicit FRAMES are graphical windows."
  (and (null frames) (drgnx-persist--terminal-frame-p)))

(defun drgnx-persist--graphical-only ()
  "Say that layouts belong to graphical windows (what Save / Restore Workbench Layout answer in a terminal)."
  (message "Layouts are saved and restored from graphical windows")
  nil)

(defun drgnx-persist-state (&optional frame)
  "FRAME's workbench as a plist (see the commentary).  A frame that rebuilds itself — its parameter
`drgnx-persist-restore' is (FUNCTION . ARGS), e.g. a job window — is saved as (:role custom :restore …).
It and the main window are saved with `drgnx-persist--frame-geometry' when graphical."
  (if-let* ((restore (frame-parameter frame 'drgnx-persist-restore)))
      (append (list :role 'custom :restore restore) (drgnx-persist--frame-geometry frame))
    (let ((state (drgnx-persist--workbench-state frame)))
      (if (eq (plist-get state :role) 'main) (append state (drgnx-persist--frame-geometry frame)) state))))

(defun drgnx-persist--frame-geometry (frame)
  "FRAME's `:geometry' (pixel left top, then the text area's width and height — what `set-frame-size' sets, so the
size does not grow at every restart) and, when it has one, `:fullscreen' (its `fullscreen' parameter: `maximized', …);
nil when FRAME is not graphical."
  (and (display-graphic-p frame)
       (let ((edges (frame-edges frame 'outer-edges)))
         (append (list :geometry (list (nth 0 edges) (nth 1 edges)
                                       (frame-text-width frame) (frame-text-height frame)))
                 (and (frame-parameter frame 'fullscreen)
                      (list :fullscreen (frame-parameter frame 'fullscreen)))))))

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

(defun drgnx-persist--shown-file (g)
  "The file editor group G shows, else the last file it showed (a start page or a Work map in front does not lose
the file you were in), else nil."
  (or (buffer-file-name (window-buffer g))
      (seq-some (lambda (e) (and (buffer-live-p (car e)) (buffer-file-name (car e)))) (window-prev-buffers g))))

(defconst drgnx-persist--size-keys '(left panel right)
  "The `:sizes' intents a state keeps, one per home: the docks' and the panel's (the home `bottom', a size you chose,
not the one a popup squeezed).")

(defun drgnx-persist--sizes (frame)
  "FRAME's chosen sizes, an alist KEY → pixels of the `:sizes' intents in `drgnx-persist--size-keys' that hold one."
  (delq nil (mapcar (lambda (k) (let ((px (plist-get (drgnx-state-intent frame :sizes k) :px)))
                                  (and (integerp px) (cons k px))))
                    drgnx-persist--size-keys)))

(defun drgnx-persist--tree (frame)
  "FRAME's grid to save (`drgnx-grid-tree'; while a tile shows full size, the tree it goes back to).  An editor tile
keeps its tabs as files, with those not visited yet after a restore, and the file it showed last when a page that is
no file (the start page, a Work map) is in front."
  (let ((tree (copy-tree (drgnx-grid--frame-snapshot-tree frame))))
    (dolist (leaf (drgnx-grid-tree-leaves tree))
      (when (eq (car leaf) 'editor)
        (let* ((p (cdr leaf)) (w (drgnx-grid--tile-by-id (plist-get p :id) frame))
               (pending (and w (nth 2 (assq w drgnx-persist--pending))))
               (file (and w (drgnx-persist--shown-file w))))
          (setf (plist-get p :tabs) (or pending (seq-filter #'file-name-absolute-p (plist-get p :tabs))))
          (unless (equal file (plist-get p :shown))
            (setf (plist-get p :shown) file (plist-get p :point) nil (plist-get p :start) nil))
          (setcdr leaf p))))
    tree))

(defun drgnx-persist--workbench-state (frame)
  (let ((frame (or frame (selected-frame))))
    (with-selected-frame frame
      (let ((mon (frame-parameter frame 'drgnx-monitor)))
        (list :role (if (fboundp 'drgnx-frame-role) (drgnx-frame-role) 'main)
              :monitor (and (consp mon) (drgnx-monitors--identity mon))
              :shell (copy-tree (frame-parameter frame 'drgnx-grid-shell))
              :tree (drgnx-persist--tree frame)
              :memory (list :docks (copy-tree (frame-parameter frame 'drgnx-grid-memory))
                            :sizes (drgnx-persist--sizes frame)
                            :view (drgnx-wb-sidebar-view frame))
              :roots (and (fboundp 'drgnx-explorer-chosen-roots) (drgnx-explorer-chosen-roots))
              :extra (drgnx-persist--extra))))))

(defvar drgnx-persist--extra-reported nil
  "The state functions already reported as failing or returning something unusable (said once each).")

(defun drgnx-persist--plain-p (x &optional depth)
  "Non-nil if X is plain data the state file can hold: symbols, numbers, strings (text properties are dropped by
`drgnx-persist--no-props'), conses and vectors, nested less than 32 deep and with no circular list."
  (setq depth (or depth 0))
  (cond ((or (symbolp x) (numberp x) (stringp x)) t)
        ((>= depth 32) nil)
        ((vectorp x) (seq-every-p (lambda (e) (drgnx-persist--plain-p e (1+ depth))) x))
        ((consp x) (let ((n 0))
                     (while (and (consp x) (< (setq n (1+ n)) 100000) (drgnx-persist--plain-p (car x) (1+ depth)))
                       (setq x (cdr x)))
                     (and (not (consp x)) (drgnx-persist--plain-p x (1+ depth)))))))

(defun drgnx-persist--no-props (x)
  "X (checked by `drgnx-persist--plain-p') as a copy whose strings have no text properties: the file layer refuses
a string with properties, which would fail the whole save."
  (cond ((stringp x) (substring-no-properties x))
        ((consp x) (let (acc)
                     (while (consp x) (push (drgnx-persist--no-props (car x)) acc) (setq x (cdr x)))
                     (nconc (nreverse acc) (drgnx-persist--no-props x))))
        ((vectorp x) (vconcat (mapcar #'drgnx-persist--no-props x)))
        (t x)))

(defun drgnx-persist--extra ()
  "The plist the functions of `drgnx-persist-state-functions' return, joined (the selected frame's).
A function's result counts only if it is a proper plist that can be read back (no buffer, marker or
other object); otherwise that function is skipped and said once, and the others' keys are kept."
  (let (extra)
    (run-hook-wrapped
     'drgnx-persist-state-functions
     (lambda (fn)
       (let ((r (condition-case err (funcall fn) (error (cons 'drgnx-persist-error (error-message-string err))))))
         (cond ((and (proper-list-p r) (cl-evenp (length r)) (drgnx-persist--plain-p r))
                (setq extra (append extra (drgnx-persist--no-props r))))
               ((memq fn drgnx-persist--extra-reported))
               (t (push fn drgnx-persist--extra-reported)
                  (drgnx-notify 'wb 'warn
                                (format "state function %S left out of the saved workbench: %s" fn
                                        (if (eq (car-safe r) 'drgnx-persist-error) (cdr r) "not a plist that can be read back"))
                                :id (cons 'state-function fn)))))
       nil))
    extra))

(defun drgnx-persist--frames ()
  "The windows to save: the store's visible graphical frames, the main one (the selected graphical one without a
main one) first, then the others, oldest first."
  (let* ((shown (seq-filter (lambda (f) (and (frame-live-p f) (frame-visible-p f))) (drgnx-state-frames 'gui)))
         (main (or (car (memq (drgnx-state-main-frame) shown)) (drgnx-persist--gui-frame) (selected-frame))))
    (cons main (remq main shown))))

(defun drgnx-persist-save (&optional file frames)
  "Write the workbench of FRAMES (default: every window, the main one first) to FILE (default:
`drgnx-persist-file').  Tabs not visited yet (restored at idle) are kept.  Called from a terminal window
\(and with no FRAMES) it writes nothing, whatever FILE is: a terminal frame has no layout to export, and a terminal
session never overwrites the desktop layout.  Run as a command, a save it refuses says so in the echo area."
  (interactive)
  (if (drgnx-persist--save-skipped-p frames)
      (drgnx-persist--graphical-only)
    (let ((say (called-interactively-p 'any))
          (file (or file (drgnx-persist--file)))
          (state (list :version drgnx-persist-version
                       :frames (mapcar (lambda (f) (drgnx-persist--no-props (drgnx-persist-state f)))
                                       (or frames (drgnx-persist--frames))))))
      (condition-case nil
          (progn (drgnx-file-update file (lambda (old)
                                           (when (drgnx-persist--newer-p old) (signal 'drgnx-persist-newer nil))
                                           state)
                                    :on-unreadable 'backup :max-bytes drgnx-persist--max-bytes)
                 file)
        (drgnx-persist-newer (when say (drgnx-notice-clear 'wb 'workbench-newer))   ; a command's reply: each time
                             (drgnx-notify 'wb 'warn "workbench.eld was written by a newer drgnx: not saved"
                                           :id 'workbench-newer :echo (and say t))
                             nil)))))

(defun drgnx-persist--newer-p (data)
  "Non-nil if DATA, the state file as read, has a `:version' above `drgnx-persist-version'."
  (let ((v (and (proper-list-p data) (plist-get data :version))))
    (and (integerp v) (> v drgnx-persist-version))))

(defun drgnx-persist--save-quietly (&optional frames-function)
  "`drgnx-persist-save' for hooks: nothing prompts, and an error (a busy lock, a full disk, a file that cannot be
written) is one message, never raised.  FRAMES-FUNCTION, when given, returns the frames to save."
  (let ((inhibit-interaction t))
    (condition-case err (drgnx-persist-save nil (and frames-function (funcall frames-function)))
      (error (drgnx-notify 'wb 'warn (format "workbench.eld not saved: %s" (error-message-string err))
                           :id 'workbench-save)
             nil))))

(defun drgnx-persist--read (file)
  "FILE's state, or nil when it is absent or empty.  An unreadable file (not plain data, too deep or too big) is
not restored: one message, and the next save keeps a backup of it."
  (let ((r (drgnx-file-read file :max-bytes drgnx-persist--max-bytes)))
    (if (eq (plist-get r :status) 'unreadable)
        (progn (drgnx-notify 'wb 'fail
                             (format "%s cannot be read (%s): the workbench is not restored; the next save keeps a backup of it"
                                     file (plist-get (plist-get r :problem) :text))
                             :id (cons 'workbench-read file))
               nil)
      (plist-get r :data))))

(defun drgnx-persist--clamp (px limit) (and (integerp px) (max 1 (min px (floor limit)))))

(defun drgnx-persist--visit (file)
  "FILE's buffer, visited without asking anything (this runs at start: nobody may be there to answer):
no remote files, only safe local variables, no large-file question (Emacs's off; a large file opens as
editor/large-files opens automatic ones); nil if it cannot be visited."
  (when (and (stringp file) (not (file-remote-p file)))
    (let ((non-essential t) (enable-local-variables :safe) (large-file-warning-threshold nil)
          (drgnx-large-file-open 'auto))
      (or (get-file-buffer file)
          (and (file-exists-p file) (ignore-errors (find-file-noselect file)))))))

(defvar drgnx-persist--pending nil "Tabs still to visit: list of (WINDOW FILES).")

(defun drgnx-persist--set-tabs (w files)
  "W's tabs: the visited ones among FILES, in FILES' order (plus what W shows)."
  (set-window-parameter w 'drgnx-tabs
                        (let ((bufs (delq nil (mapcar #'get-file-buffer (seq-filter (lambda (f) (and (stringp f) (not (file-remote-p f)))) files)))))
                          (if (or (memq (window-buffer w) bufs) (not (buffer-file-name (window-buffer w)))) bufs
                            (append bufs (list (window-buffer w)))))))

(defun drgnx-persist--visit-pending ()
  "Visit the next restored tab (the layer's idle steps call this: `persist-visit'); nil when none is left."
  (let ((entry (car drgnx-persist--pending)))
    (when entry
      (pcase-let ((`(,w ,todo ,files) entry))
        (if (or (null todo) (not (window-live-p w)))
            (pop drgnx-persist--pending)
          (drgnx-persist--visit (car todo))
          (setcar (cdr entry) (cdr todo))
          (drgnx-persist--set-tabs w files)
          (drgnx-chrome-apply (window-frame w))))
      t)))

(defun drgnx-persist--main-state (frames)
  "The state of FRAMES that goes into the selected frame: the one saved with `:role main', else the first that
is a workbench (not a window that rebuilds itself); nil when there are only such windows."
  (or (seq-find (lambda (st) (eq (plist-get st :role) 'main)) frames)
      (seq-find (lambda (st) (not (eq (plist-get st :role) 'custom))) frames)))

(defvar drgnx-persist-restoring nil
  "Non-nil while `drgnx-persist-restore' runs.  A window's function that rebuilds it (`:restore') then takes back
only its state and arranges nothing: the restored workbench keeps its panes, sizes and focus.")

(defun drgnx-persist-restore (&optional file)
  "Bring back the workbench saved in FILE — the selected frame gets the main window's layout (the state
saved with `:role main', wherever it stands in the file), every other window is made again; non-nil if a
state was restored.  A window that rebuilt itself is rebuilt by its function (with `drgnx-persist-restoring'
non-nil), on the graphical display, and, when it returns a frame and the display still has room, put back at its
saved pixel position and size.
Each group's shown file is visited now, its other tabs at idle (never a question at start).
From a terminal window, the workbench is restored into the graphical window when one is open (and the terminal
says so); with none, nothing is restored (a terminal window keeps the default layout for its size)."
  (interactive)
  (cond ((not (drgnx-persist--terminal-frame-p)) (drgnx-persist--restore file))
        ((drgnx-persist--gui-frame)
         ;; focus stays in the terminal: the user may be over SSH, or there on purpose
         (when (with-selected-frame (drgnx-persist--gui-frame) (drgnx-persist--restore file t))
           (message "Restored into the graphical window")
           t))
        (t (drgnx-persist--graphical-only))))

(defun drgnx-persist--restore (file &optional keep-focus)
  "`drgnx-persist-restore' in the selected frame, which is not a terminal window.  The selected frame gets the
input focus back after the other windows are made, unless KEEP-FOCUS (a restore asked for from a terminal)."
  (let* ((drgnx-persist-restoring t)
         (file (or file (drgnx-persist--file))) (state (drgnx-persist--read file))
         (frames (drgnx-persist--frames-of state)))
    (cond
     ((null state) nil)
     ((null frames)
      (drgnx-notify 'wb 'fail
                    (format "%s has format %S, not %d; not restored" file (plist-get state :version) drgnx-persist-version)
                    :id (cons 'workbench-format file))
      nil)
     (t
      (setq drgnx-persist--pending nil)
      ;; The selected frame gets the main window's layout — and is the main window (a file of only job windows
      ;; has none: the frame is left as it is).
      (when-let* ((main (drgnx-persist--main-state frames)))
        (dolist (f (frame-list))        ; the roles are parameters: the store sees them when told
          (when (eq (frame-parameter f 'drgnx-frame-role) 'main)
            (set-frame-parameter f 'drgnx-frame-role nil)
            (drgnx-state-sync f)))
        (set-frame-parameter nil 'drgnx-frame-role 'main)
        (drgnx-state-sync)
        ;; its size first: the docks are clamped to it
        (when-let* (((display-graphic-p)) (g (drgnx-persist--geometry main)))
          (drgnx-persist--place-frame (selected-frame) g)
          (drgnx-persist--keep-state (selected-frame) g (plist-get main :fullscreen)))
        (drgnx-persist--restore-frame main)
        (setq frames (remq main frames)))
      (let ((home (selected-frame)))
        (unwind-protect
            (dolist (st frames)            ; the window manager places them; one failing is skipped
              (if (eq (plist-get st :role) 'custom)    ; it rebuilds itself (a job window), if its code is here
                  (let ((restore (plist-get st :restore)))
                    (cond
                     ((and (consp restore) (fboundp (car restore)))
                      (if-let* ((host (drgnx-persist--gui-frame)))      ; its display, never a text frame
                          (condition-case err
                              (let ((frame (with-selected-frame host (apply (car restore) (cdr restore))))
                                    (g (drgnx-persist--geometry st)))
                                (when (and g (frame-live-p frame) (display-graphic-p frame))
                                  (drgnx-persist--place-frame frame g)
                                  (drgnx-persist--keep-state frame g (plist-get st :fullscreen))))
                            (error (drgnx-notify 'wb 'warn (format "a window was not restored: %s" (error-message-string err))
                                                 :id 'window-restore)))
                        (drgnx-notify 'wb 'warn "a window was not restored: no graphical display" :id 'window-restore)))
                     (t (drgnx-notify 'wb 'warn (format "a window was not restored: %S is not loaded" (car-safe restore))
                                      :id 'window-restore))))
                (when-let* ((f (ignore-errors (make-frame '((drgnx-frame-role . aux))))))
                  (condition-case err (with-selected-frame f (drgnx-persist--restore-frame st))
                    (error (drgnx-notify 'wb 'warn (format "a window's layout was not restored: %s" (error-message-string err))
                                         :id 'window-layout-restore))))))
          (when (and (not keep-focus) (frame-live-p home)) (select-frame-set-input-focus home))))
      t))))

(defun drgnx-persist--frames-of (state)
  "The window states of the state file STATE, in format 3 (a format-2 file migrated: `drgnx-persist--from-v2'), or
nil when STATE has another format."
  (let ((frames (plist-get state :frames)))
    (when (and (proper-list-p frames) (seq-every-p #'drgnx-grid-tree--plist-p frames))
      (pcase (plist-get state :version)
        (2 (mapcar #'drgnx-persist--from-v2 frames))
        (3 frames)))))

;;;; Format 2: the docks and editor groups of before the grid, migrated on read

(defun drgnx-persist--from-v2 (state)
  "A format-2 window STATE as format 3: its docks, panel and groups become a grid (`drgnx-persist--grid-from-v2'),
their chosen sizes and the sidebar view its `:memory'.  A window that rebuilds itself (`:role custom') is as it was."
  (if (eq (plist-get state :role) 'custom) state
    (let ((px (lambda (k) (let ((v (plist-get (plist-get state k) :px))) (and (integerp v) v)))))
      (append (list :role (plist-get state :role))
              (and (plist-get state :geometry) (list :geometry (plist-get state :geometry)))
              (and (plist-get state :fullscreen) (list :fullscreen (plist-get state :fullscreen)))
              (list :tree (drgnx-persist--grid-from-v2 state)
                    :memory (list :sizes (delq nil (list (and (funcall px :left) (cons 'left (funcall px :left)))
                                                         (and (funcall px :panel) (cons 'panel (funcall px :panel)))
                                                         (and (funcall px :right) (cons 'right (funcall px :right)))))
                                  :view (plist-get (plist-get state :left) :view))
                    :roots (plist-get state :roots)
                    :extra (plist-get state :extra))))))

(defun drgnx-persist--v2-stacked-p (main)
  "Non-nil when the format-2 groups' window state MAIN splits them top and bottom (its first split is vertical)."
  (let ((n 0) found)
    (while (and (consp main) (not found) (< (setq n (1+ n)) 10000))
      (when (memq (car main) '(vc hc)) (setq found (car main)))
      (setq main (cdr main)))
    (eq found 'vc)))

(defun drgnx-persist--grid-from-v2 (state)
  "The grid (a TREE, `drgnx-grid-tree') of format-2 window STATE, at the selected frame's size: the left dock (the side
bar with its view), the editor groups (side by side, or stacked as its window state had them) over the panel, and the
right dock, those shown in STATE at their saved pixel sizes, clamped as a restore clamps them (a dock to half the
frame's width, the panel to seven tenths of its height)."
  (let* ((fw (frame-pixel-width)) (fh (frame-pixel-height)) (scale (drgnx-pixels-scale)) (id 0)
         (next (lambda () (setq id (1+ id))))
         (dock (lambda (k limit) (let ((spec (plist-get state k)))
                                   (and (drgnx-grid-tree--plist-p spec) (plist-get spec :shown)
                                        (or (drgnx-persist--clamp (plist-get spec :px) limit) (floor limit 2))))))
         (tab (lambda (k) (let ((tab (plist-get (plist-get state k) :tab))) (and tab (symbolp tab) tab))))
         (left (funcall dock :left (* 0.5 fw))) (panel (funcall dock :panel (* 0.7 fh)))
         (right (funcall dock :right (* 0.5 fw)))
         (view (plist-get (plist-get state :left) :view))
         (specs (seq-filter #'drgnx-grid-tree--plist-p
                            (let ((g (plist-get state :groups))) (and (proper-list-p g) g))))
         (stacked (drgnx-persist--v2-stacked-p (plist-get state :main)))
         (editors (mapcar (lambda (g)
                            (list 'editor :px nil :share nil :id (funcall next)
                                  :tabs (let ((tabs (plist-get g :tabs)))
                                          (and (proper-list-p tabs) (seq-filter #'stringp tabs)))
                                  :shown (and (stringp (plist-get g :shown)) (plist-get g :shown))))
                          (or specs (list nil))))
         (side (- fw (or left 0) (or right 0)))
         (area (drgnx-grid-tree-join (if stacked 'col 'row) editors
                                     (mapcar (lambda (g) (and (not stacked) (integerp (plist-get g :px))
                                                              (plist-get g :px)))
                                             (or specs (list nil)))
                                     (if stacked (- fh (or panel 0)) side) scale))
         (area-tile (lambda (k dock px)
                      (and px (list 'tile :px nil :share nil :id (funcall next) :kinds (and (funcall tab k) (list (funcall tab k)))
                                    :shown (funcall tab k) :dock dock
                                    :state (list :area (pcase k (:panel 'panel) (:right 'right)))))))
         (center (if panel
                     (drgnx-grid-tree-join 'col (list area (funcall area-tile :panel 'bottom panel)) (list nil panel) fh scale)
                   area))
         ;; (NODE . PX) side by side: the left dock, the rest, the right dock
         (row (delq nil (list (and left (cons (list 'tile :px nil :share nil :id (funcall next) :kinds '(side-bar)
                                                    :shown 'side-bar :dock 'left
                                                    :state (and view (symbolp view) (list :view view)))
                                              left))
                              (cons center nil)
                              (and right (cons (funcall area-tile :right 'right right) right)))))
         (tree (drgnx-grid-tree-join 'row (mapcar #'car row) (mapcar #'cdr row) fw scale)))
    (and (drgnx-grid-valid-tree-p tree) tree)))

;;;; Restore a window

(defun drgnx-persist--restore-memory (memory)
  "Bring back MEMORY, a window state's `:memory': the sizes you chose and the sidebar view as intent `restore' (a size
missing from it clears the one chosen before; each is clamped to the frame), and what the grid remembers of hidden
tiles, when it is plain data."
  (let ((memory (and (drgnx-grid-tree--plist-p memory) memory)))
    (let ((view (plist-get memory :view)))
      (when (and view (symbolp view)) (drgnx-state-note-intent nil :view nil view :by 'restore)))
    (let ((sizes (let ((s (plist-get memory :sizes))) (and (proper-list-p s) s))))
      (dolist (k drgnx-persist--size-keys)
        (let ((px (cdr-safe (assq k (seq-filter #'consp sizes))))
              (limit (if (memq k '(left right)) (* 0.5 (frame-pixel-width)) (* 0.7 (frame-pixel-height)))))
          (drgnx-state-note-intent nil :sizes k (drgnx-persist--clamp px limit) :by 'restore))))
    (let ((docks (plist-get memory :docks)))
      (when (and (proper-list-p docks)
                 (seq-every-p (lambda (e) (and (consp e) (drgnx-grid-tree-entry-p (car e))
                                               (drgnx-grid-tree--plist-p (cdr e)) (drgnx-grid-tree--plain-p (cdr e) 4)))
                              docks))
        (set-frame-parameter nil 'drgnx-grid-memory (copy-tree docks))))))

(defun drgnx-persist--restore-frame (state)
  "Bring back one window's workbench STATE in the selected frame: its folders, its grid, then its memory.  A tree that
is not valid (`drgnx-grid-valid-tree-p') changes nothing in the grid and gives one notice.  Each editor tile's shown
file is visited now (missing files are skipped), its other tabs at idle."
  (let ((frame (selected-frame)) (tree (plist-get state :tree)))
    (when-let* ((roots (let ((r (plist-get state :roots)))
                         (and (proper-list-p r)
                              (seq-filter (lambda (d) (and (stringp d) (not (file-remote-p d)) (file-directory-p d))) r))))
                ((fboundp 'drgnx-explorer-set-roots)))
      (drgnx-explorer-set-roots roots))
    (set-frame-parameter nil 'drgnx-persist-extra (plist-get state :extra))
    (cond
     ((null tree))
     ((not (drgnx-grid-valid-tree-p tree))
      (drgnx-notify 'wb 'warn "A window's saved layout was not valid; it keeps the layout it has" :id 'workbench-tree))
     (t
      (let ((tree (copy-tree tree)) (editors nil))
        (dolist (leaf (drgnx-grid-tree-leaves tree))
          (when (eq (car leaf) 'editor)
            (let ((p (cdr leaf)))
              (drgnx-persist--visit (plist-get p :shown))
              (push (list (plist-get p :id) (seq-filter #'stringp (plist-get p :tabs)) (plist-get p :shown)) editors))))
        ;; every tile is made from TREE: no live tile keeps an id TREE holds
        (drgnx-grid-forget-full-size frame)
        (dolist (w (window-list frame 'nomini)) (set-window-parameter w 'drgnx-tile-id nil))
        (set-frame-parameter frame 'drgnx-grid-next-id
                             (apply #'max (or (frame-parameter frame 'drgnx-grid-next-id) 0)
                                    (drgnx-grid--tree-ids tree)))
        (drgnx-grid-apply-tree tree frame)
        (dolist (e (nreverse editors))
          (pcase-let ((`(,id ,files ,shown) e))
            (when-let* ((w (drgnx-grid--tile-by-id id frame)))
              (set-window-prev-buffers w nil)
              (drgnx-persist--set-tabs w files)
              (setq drgnx-persist--pending
                    (append drgnx-persist--pending (list (list w (remove shown files) files)))))))
        (when (and drgnx-persist--pending (not (drgnx-timer-active-p 'persist-visit)))
          ;; not :interruptible: a file visit aborted half-way is not safe to repeat
          (drgnx-timer-idle-steps 'persist-visit 0.2 #'drgnx-persist--visit-pending :owner :core))
        ;; and the sizes once more at the frame's next size change (below)
        (puthash frame (cons (frame-pixel-width) (cons (frame-pixel-height) tree)) drgnx-persist--refit)
        (add-hook 'window-size-change-functions #'drgnx-persist--refit)
        (add-hook 'pre-command-hook #'drgnx-persist--refit-done))))
    ;; after the grid: what its tiles noted while they were made is replaced by what was chosen
    (drgnx-persist--restore-memory (plist-get state :memory))
    (drgnx-chrome-apply))
  t)

(defun drgnx-persist--refit (frame)
  "A restored FRAME changed size: a new window is restored at the size it was made with, and the window manager's
answers (the sizes it gives the window, one or more) can come after, as they do for a client's window at scale 2.
Emacs shares each change out among the tiles by their sizes at the time, so the grid it was restored with is applied
again (`drgnx-grid-apply-tree': only the sizes change), while its tiles are still the ones it holds.  At every change
of the frame's size until the first command (`drgnx-persist--refit-done'): a change of its windows alone is passed
over."
  (when-let* ((at (gethash frame drgnx-persist--refit))
              ((not (and (= (car at) (frame-pixel-width frame)) (= (cadr at) (frame-pixel-height frame))))))
    (puthash frame (cons (frame-pixel-width frame) (cons (frame-pixel-height frame) (cddr at))) drgnx-persist--refit)
    (let ((tree (cddr at)))
      (when (equal (sort (copy-sequence (drgnx-grid--tree-ids tree)) #'<)
                   (sort (delq nil (mapcar (lambda (w) (window-parameter w 'drgnx-tile-id)) (drgnx-grid-tiles frame)))
                         #'<))
        (drgnx-grid-apply-tree tree frame)))))

(defvar drgnx-persist--unmaximize (make-hash-table :test #'eq :weakness 'key)
  "Restored window → (GEOMETRY . TRIES): its saved geometry, while the window manager may still maximize it unasked.")

(defun drgnx-persist--keep-state (frame geometry fullscreen)
  "A window restored at GEOMETRY with the saved `fullscreen' FULLSCREEN: a maximized or full-screen one is made so
again; one saved as neither is watched (`drgnx-persist--unmaximize'): mutter maximizes a new window whose size comes
close to the work area's, so a window you sized that big came back maximized, its size lost."
  (if (memq fullscreen '(maximized fullboth fullwidth fullheight))
      (set-frame-parameter frame 'fullscreen fullscreen)
    (puthash frame (cons geometry 0) drgnx-persist--unmaximize)
    (add-hook 'window-size-change-functions #'drgnx-persist--unmaximize)
    (add-hook 'pre-command-hook #'drgnx-persist--refit-done)))

(defun drgnx-persist--unmaximize (frame)
  "FRAME, restored as neither maximized nor full screen, was maximized by the window manager: it is given back its
`fullscreen' nil, then, once the window manager has unmaximized it (to a size of its own choosing, which can come
after ours), its saved geometry (`drgnx-persist--place-frame'), again whenever a later answer takes it away.  Until the
first command; three tries at most."
  (when-let* ((at (gethash frame drgnx-persist--unmaximize)))
    (let ((g (car at)) (tries (cdr at)))
      (cond ((frame-parameter frame 'fullscreen) (set-frame-parameter frame 'fullscreen nil))
            ((and (= (frame-text-width frame) (nth 2 g)) (= (frame-text-height frame) (nth 3 g))))
            ((>= tries 3) (remhash frame drgnx-persist--unmaximize))
            (t (puthash frame (cons g (1+ tries)) drgnx-persist--unmaximize)
               (drgnx-persist--place-frame frame g))))))

(defun drgnx-persist--refit-done ()
  "The first command after a restore: the window's sizes are yours from now on, nothing is put back any more."
  (clrhash drgnx-persist--refit)
  (clrhash drgnx-persist--unmaximize)
  (remove-hook 'window-size-change-functions #'drgnx-persist--unmaximize)
  (remove-hook 'window-size-change-functions #'drgnx-persist--refit)
  (remove-hook 'pre-command-hook #'drgnx-persist--refit-done))

(defun drgnx-persist--gui-frame ()
  "The graphical frame to restore into or save from (a daemon's F1 is not one, nor is a child frame)."
  (if (drgnx-persist--gui-p (selected-frame)) (selected-frame)
    (seq-find #'drgnx-persist--gui-p (frame-list))))

(defun drgnx-persist--on-exit ()
  "Save from a graphical frame only (a batch run must never write the user's state)."
  (when-let* ((f (drgnx-persist--gui-frame)))
    (with-selected-frame f (drgnx-persist--save-quietly))))

(defvar drgnx-persist--saved-at-exit nil
  "Non-nil when a closing client already saved every window (its frames are being deleted).")

(defun drgnx-persist--before-client-delete (proc &optional noframe)
  "Before `server-delete-client' deletes PROC's frames one by one: if they are all the graphical
windows left (\[save-buffers-kill-terminal] in the last client), save every one of them now.
A client that made no frame (`emacsclient -e', a file shown in a window already there; server.el records
a client's frame as its `frame' property) closes none: it is passed over at once, consing nothing, as every
request ends here and `frame-parameter' of `client' copies each frame's whole parameter list."
  (unless (or noframe (not (process-get proc 'frame)))
    (let ((gui (seq-filter #'drgnx-persist--gui-p (frame-list))))
      (when (and gui (seq-every-p (lambda (f) (eq (frame-parameter f 'client) proc)) gui))
        (drgnx-persist--save-quietly #'drgnx-persist--frames)   ; a terminal window may be the selected one
        (setq drgnx-persist--saved-at-exit t)))))

(defun drgnx-persist--on-delete-frame (frame)
  "Closing the last graphical frame (a daemon's client): save it — the daemon may never exit cleanly
— unless the closing client saved every window already."
  (when (and (drgnx-persist--gui-p frame)
             (not (frame-parameter frame 'drgnx-persist-restore))   ; a window that rebuilds itself is not the workbench
             (not (seq-some (lambda (f) (and (not (eq f frame)) (drgnx-persist--gui-p f)))
                            (frame-list))))       ; a child frame (a posframe) is no window of the workbench
    (if drgnx-persist--saved-at-exit
        (setq drgnx-persist--saved-at-exit nil)
      (drgnx-persist--save-quietly (lambda () (list frame))))))

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
                            (error (drgnx-notify 'wb 'warn (format "after-restore function %S failed: %s" fn (error-message-string err))
                                                 :id (cons 'after-restore fn))))
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
*scratch* (no file asked for) and before it shows a file asked for.  A frame already restored is left alone.
Known limits (accepted; reopen when seen): this hook does not run for a graphical frame made by
`make-frame-on-display' from a terminal client, nor while isearch or a minibuffer is active or when the
server's `server-execute' signals an error — that window gets no restore."
  (let ((frame (or frame (selected-frame))))
    (when (and drgnx-persist-restore-on-start (drgnx-persist--gui-p frame)
               (not (seq-some (lambda (f) (and (not (eq f frame)) (drgnx-persist--gui-p f)))
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
    (drgnx-persist--refit-done)
    (remove-hook 'drgnx-first-gui-frame-hook #'drgnx-persist--on-start)
    (drgnx-timer-cancel 'persist-visit)))

(provide 'drgnx-persist)
;;; drgnx-persist.el ends here
