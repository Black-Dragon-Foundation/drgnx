;;; drgnx-wb.el --- The workbench: window roles and the left dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Each window has a role (window parameter `drgnx-role'): editor windows hold files, the left
;; dock holds sections (the Buffers panel above the Explorer).  The dock is made of side windows
;; with a fixed pixel width that survives hiding and showing; its titles live in the
;; `header-line-format' window parameter, so no mode can erase them.  Showing the dock never
;; focuses it, and files chosen in the dock go to the most recently used editor window without
;; splitting.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-signal)
(require 'drgnx-modules-helpers)
(require 'drgnx-state-intent)
(require 'drgnx-ui-kit)
(require 'drgnx-faces)                  ; `drgnx-look-hover-control', the selection faces
(require 'drgnx-pixels)                 ; `drgnx-look-pixel-width'
(require 'drgnx-icons)                  ; `drgnx-look-icon'
(require 'drgnx-type-faces)             ; `drgnx-ui-text', `drgnx-ui-heading'
(declare-function drgnx-look-ui-line-spacing "drgnx-look-density" (&optional line-px density scale))
(declare-function drgnx-look-density-value "drgnx-look-density" (key &optional density))

(defcustom drgnx-wb-dock-columns 32
  "Width of the left dock, in columns, the first time it shows (later: the width it had)."
  :type 'integer :group 'drgnx)

;; The close button's face is the kit's; the old name stays, so a saved customization of it still applies.
(put 'drgnx-wb-close 'face-alias 'drgnx-ui-close)

(defface drgnx-wb-bar '((t :inherit tab-line :height 1.0 :box nil))
  "The band of a header row (breadcrumb, a dock section's title, a panel's tab row): the theme's tab-line
background, not the header line's, so every row of chrome is one colour and follows the theme." :group 'drgnx)

(defvar drgnx-wb-dock-map (make-sparse-keymap)
  "Parent keymap of every dock section's mode (keys come from the key profiles).")

(defvar drgnx-wb--owned nil
  "Windows the running code owns (it shows its own buffer there): moving them from a timer or a
follower is not a jank-guard violation (invariant I9).")

(defmacro drgnx-wb-with-owned-windows (windows &rest body)
  "Run BODY with WINDOWS declared as the caller's own (see `drgnx-wb--owned')."
  (declare (indent 1))
  `(let ((drgnx-wb--owned (append ,windows drgnx-wb--owned))) ,@body))

(defvar drgnx-wb--sections nil "Alist NAME → plist (:slot :title :buffer :view), the left dock's sections.")

;;;; The close button (the UI kit's: `drgnx-ui-close-button')

(defun drgnx-wb-close-glyph () "The close glyph (`drgnx-face-glyph' `close')." (drgnx-face-glyph 'close))

(defun drgnx-wb-close-button (command help &rest props)
  "The kit's close button on a header line: `drgnx-ui-close-button' with COMMAND, HELP and PROPS."
  (drgnx-ui-close-button command help :props props))

(defun drgnx-wb-bar (string &optional filled)
  "STRING as a header row: `drgnx-wb-bar' behind it (under any face it has), and a filler to the window's right edge,
so the whole row is the bar's colour and not the header line's.  FILLED: STRING already reaches the edge."
  (let ((s (copy-sequence string)))
    (add-face-text-property 0 (length s) 'drgnx-wb-bar t s)
    (if filled s (concat s (propertize " " 'display '(space :align-to right) 'face 'drgnx-wb-bar)))))

(defun drgnx-wb-header-with-close (title command help &rest props)
  "TITLE, then the close button for COMMAND (see `drgnx-wb-close-button') at the right edge of the window."
  (let ((button (apply #'drgnx-wb-close-button command help props)))
    (drgnx-wb-bar (concat title (propertize " " 'display `(space :align-to (- right ,(1+ (string-width button))))) " " button) t)))

(defun drgnx-wb--close-dock-click (event)
  "A click on a dock section's ✕: hide the sidebar."
  (interactive "e")
  (ignore event)
  (drgnx-wb-hide-sidebar))

(defun drgnx-wb-section-header (title)
  "A dock section's header: the ✕ that hides the sidebar, then TITLE.
The ✕ comes first: a title with buttons (Buffers) fills the dock's width, so one at the end would be clipped.  A
space before it keeps it off the frame's edge."
  (drgnx-wb-bar (concat " " (drgnx-wb-close-button #'drgnx-wb--close-dock-click "Close sidebar")
                        " " (let ((chevron (drgnx-look-icon 'chevron-down 'drgnx-ui-heading)))
                              (if (string-empty-p chevron) "" (concat chevron " ")))
                        (drgnx-wb--heading (string-trim-left title)))))

(defun drgnx-wb--heading (title)
  "TITLE in the heading face, keeping the faces and properties it has (the buttons of a title with some)."
  (let ((s (copy-sequence title)))
    (add-face-text-property 0 (length s) 'drgnx-ui-heading t s)
    s))

;;;; Rows: the UI font, git marks at the right edge, the selected row, the hover-revealed ⋯

(defconst drgnx-wb--control "⋯" "A row's menu control; `drgnx-look-hover-control' hides it until the row is hovered.")

(defvar drgnx-wb--mark-measures 0 "How many times the tail's geometry was measured (tests read it).")
(defvar drgnx-wb--tail-memo (make-hash-table :test #'equal)
  "(GENERATION CHAR-WIDTH CHAR-HEIGHT SCALE) → the tail's geometry (DOTS-PX MARK-PX GAP-PX PAD-PX).  Bounded: cleared
beyond 16 entries (a zoom or a font change adds one).")

(defun drgnx-wb-mark-memo-clear ()
  "Forget the measured geometry of the rows' right edge (tests, and a theme change)."
  (clrhash drgnx-wb--tail-memo)
  (setq drgnx-wb--mark-measures 0))

(defun drgnx-wb--tail-geometry ()
  "(DOTS MARK GAP PAD): the widths in pixels of the ⋯, of a git mark in the small code face, of the gap between them
and of the padding at the edge.  Measured when the fonts, the character cell or the scale change, not per row."
  (let ((key (list drgnx-pixels-generation (frame-char-width) (frame-char-height) (drgnx-pixels-scale))))
    (or (gethash key drgnx-wb--tail-memo)
        (progn
          (cl-incf drgnx-wb--mark-measures)
          (when (> (hash-table-count drgnx-wb--tail-memo) 16) (clrhash drgnx-wb--tail-memo))
          (let ((scale (drgnx-pixels-scale)))
            (puthash key (list (drgnx-look-pixel-width drgnx-wb--control 'drgnx-ui-text)
                               (drgnx-look-pixel-width "M" 'drgnx-code-small)
                               (round (* 4 scale)) (round (* 8 scale)))
                     drgnx-wb--tail-memo))))))

(defun drgnx-wb-git-mark-face (status)
  "The status face of a git STATUS mark: modified and renamed warn, added and untracked ok, deleted and conflicts fail."
  (pcase status
    ((or 'modified 'renamed) 'drgnx-status-warn)
    ((or 'added 'untracked) 'drgnx-status-ok)
    ((or 'deleted 'conflict) 'drgnx-status-fail)
    (_ 'drgnx-status-info)))

(defun drgnx-wb-row-tail (mark face shown)
  "The string at a row's right edge: MARK (a string or nil) in FACE and the code face, then the ⋯ control, SHOWN in
its real face or hidden until the row is hovered.  Both are placed in pixels from the window's right edge, so
the marks of all rows line up; the whole string carries the row's mouse face."
  (pcase-let ((`(,dots ,mark-px ,gap ,pad) (drgnx-wb--tail-geometry)))
    (propertize (concat (propertize " " 'display `(space :align-to (- right (,(+ pad dots gap mark-px)))))
                        (if mark (propertize mark 'face (list face 'drgnx-code-small)) "")
                        (propertize " " 'display `(space :align-to (- right (,(+ pad dots)))))
                        (drgnx-look-hover-control drgnx-wb--control shown)
                        (propertize " " 'display `(space :width (,pad))))
                'mouse-face 'drgnx-hover-row)))

(defun drgnx-wb-row-tail-overlay (eol mark face shown)
  "Put the tail (see `drgnx-wb-row-tail') of the row ending at EOL in an overlay that remembers MARK and FACE."
  (let ((o (make-overlay eol eol)))
    (overlay-put o 'drgnx-git t)
    (overlay-put o 'drgnx-row-tail (cons mark face))
    (overlay-put o 'after-string (drgnx-wb-row-tail mark face shown))
    o))

(defvar-local drgnx-wb--selected-overlay nil "The overlay on the selected row (point's).")
(defvar-local drgnx-wb--tail-shown nil "The tail overlay whose ⋯ is drawn in its real face now.")

(defun drgnx-wb--set-tail-shown (o shown)
  "Redraw the tail overlay O with its ⋯ SHOWN or hidden."
  (when (overlayp o)
    (pcase-let ((`(,mark . ,face) (overlay-get o 'drgnx-row-tail)))
      (overlay-put o 'after-string (drgnx-wb-row-tail mark face shown)))))

(defun drgnx-wb-selection-sync ()
  "Mark point's row as the selected one: `drgnx-selected' with the focus ring while this buffer's window is the
selected window, `drgnx-selected-quiet' otherwise.  The row's ⋯ is shown in its real face, the previous row's hidden
again.  Cheap: two overlays are touched."
  (let* ((window (get-buffer-window (current-buffer))) (focused (and window (eq window (selected-window))))
         (beg (pos-bol)) (end (min (point-max) (1+ (pos-eol)))))
    (unless (overlayp drgnx-wb--selected-overlay)
      (setq drgnx-wb--selected-overlay (make-overlay beg end nil t))
      (overlay-put drgnx-wb--selected-overlay 'drgnx-row-selected t)
      (overlay-put drgnx-wb--selected-overlay 'priority 5))
    (move-overlay drgnx-wb--selected-overlay beg end)
    (overlay-put drgnx-wb--selected-overlay 'face (if focused '(drgnx-selected drgnx-focus) 'drgnx-selected-quiet))
    (let ((now nil))                    ; post-command: a primitive loop, no closure
      (dolist (o (overlays-in beg end)) (when (and (not now) (overlay-get o 'drgnx-row-tail)) (setq now o)))
      (unless (eq now drgnx-wb--tail-shown)
        (drgnx-wb--set-tail-shown drgnx-wb--tail-shown nil)
        (drgnx-wb--set-tail-shown now t)
        (setq drgnx-wb--tail-shown now)))))

(defun drgnx-wb--selected-changed (_data)
  "The store's `selected-changed': the dock buffers' selected rows follow the focus (ring or quiet)."
  (dolist (w (drgnx-wb--dock-windows))
    (with-current-buffer (window-buffer w)
      (when (local-variable-p 'drgnx-wb--selected-overlay) (drgnx-wb-selection-sync)))))

(defvar drgnx-wb--rows-buffers nil
  "The dock buffers whose rows are UI rows (`drgnx-wb-rows-setup'); killed ones are dropped as the list is walked.")

(defvar-local drgnx-wb--rows-key nil
  "What this dock buffer's row spacing was made for (`drgnx-wb--rows-fit'), an integer; nil: none made yet.")

(defun drgnx-wb--rows-face (beg end)
  "jit-lock, after the buffer's own painting (its hook depth puts it last): `drgnx-ui-text' under the faces of the
characters from BEG to END that lack it, the newlines too, so the rows (and the strings of their overlays, which take
the face of the text under them) are in the UI font.  A remap of `default' did it before, and merged the UI font into
every face lookup of the buffer at every redisplay."
  (let ((inhibit-read-only t) (p beg))
    (with-silent-modifications
      (while (< p end)
        (let ((next (next-single-property-change p 'face nil end)) (face (get-text-property p 'face)))
          (unless (or (eq face 'drgnx-ui-text) (and (consp face) (memq 'drgnx-ui-text face)))
            (add-face-text-property p next 'drgnx-ui-text t))
          (setq p next)))))
  nil)

(defun drgnx-wb-rows-setup ()
  "Make the current dock buffer's rows UI rows: the UI text face under the rows' own faces (`drgnx-wb--rows-face',
from jit-lock) and the row height of the density, on the graphical frame that shows it (or the selected one).  Call it
from the buffer's major mode; a density change, a scale change and the buffer's first showing on a graphical frame
fit the rows again (`drgnx-wb-rows-follow')."
  (add-hook 'jit-lock-functions #'drgnx-wb--rows-face 90 t)
  (jit-lock-mode t)
  ;; the hover face takes `default' for its foreground, and with it the code font: here the UI face comes first.  No
  ;; remap of `default', so the other faces' lookups only miss in the alist.
  (face-remap-add-relative 'drgnx-hover-row 'drgnx-ui-text)
  (setq-local drgnx-wb--selected-overlay nil drgnx-wb--tail-shown nil drgnx-wb--rows-key nil)
  (add-hook 'post-command-hook #'drgnx-wb-selection-sync nil t)
  (unless (memq (current-buffer) drgnx-wb--rows-buffers) (push (current-buffer) drgnx-wb--rows-buffers))
  (drgnx-wb--rows-fit (let ((w (get-buffer-window nil t))) (if w (window-frame w) (selected-frame)))))

(defun drgnx-wb--rows-fit (frame)
  "Give the current dock buffer the density's tree row on FRAME (its `line-spacing'), when FRAME is graphical and
what the spacing depends on moved since: the row at FRAME's scale, FRAME's line height, the fonts.  A terminal frame
leaves the spacing as it is."
  (when (and (fboundp 'drgnx-look-ui-line-spacing) (frame-live-p frame) (display-graphic-p frame))
    (let* ((scale (drgnx-pixels-scale frame))
           (key (+ (round (* scale (drgnx-look-density-value 'tree-row))) (* 1000 (frame-char-height frame))
                   (* 1000000 (mod drgnx-pixels-generation 1000)))))
      (unless (eql key drgnx-wb--rows-key)
        (setq-local drgnx-wb--rows-key key)
        (setq-local line-spacing (drgnx-look-ui-line-spacing (drgnx-wb--natural-row-height frame) nil scale))))))

(defun drgnx-wb-rows-refresh (&optional frame)
  "Fit the dock buffers' rows again (`drgnx-wb--rows-fit'): those shown on FRAME, or with no FRAME every one, on the
frame that shows it (else the selected frame).  On `drgnx-look-density-changed-hook'."
  (setq drgnx-wb--rows-buffers (seq-filter #'buffer-live-p drgnx-wb--rows-buffers))
  (dolist (b drgnx-wb--rows-buffers)
    (let ((w (get-buffer-window b (or frame t))))
      (when (or w (null frame))
        (with-current-buffer b (drgnx-wb--rows-fit (if w (window-frame w) (selected-frame))))))))

(defun drgnx-wb--rows-frame-changed (data)
  "The store's `windows-changed' and `frame-resized' (idle): the dock buffers FRAME shows fit its scale (a dock
buffer made before any graphical frame, in a daemon, gets its rows when one first shows it)."
  (when-let* ((frame (plist-get data :frame)) ((frame-live-p frame))) (drgnx-wb-rows-refresh frame)))

(defun drgnx-wb-rows-follow ()
  "The dock's rows follow the density, the scale and the frames that show them.  From a dock section's setup (the
subscriptions and the hook are recorded there, and go with the module)."
  (drgnx-state-subscribe 'windows-changed #'drgnx-wb--rows-frame-changed)
  (drgnx-state-subscribe 'frame-resized #'drgnx-wb--rows-frame-changed)
  (add-hook 'drgnx-look-density-changed-hook #'drgnx-wb-rows-refresh))

(defun drgnx-wb--natural-row-height (&optional frame)
  "The height in pixels of a dock row on FRAME (default: the selected one) before any line spacing: text in the UI
face with an icon, a git mark in the small code face and the ⋯ on it, measured in a scratch buffer (the tallest of
them sets the line)."
  (with-temp-buffer
    (face-remap-add-relative 'default 'drgnx-ui-text)
    (setq-local line-spacing 0)         ; the frame's own spacing (the code line) is not part of the row
    (insert "Xg " (drgnx-look-icon 'file) (propertize "M" 'face 'drgnx-code-small) (propertize drgnx-wb--control 'face 'drgnx-ui-text))
    (cl-progv drgnx-pixels--quiet-hooks (make-list (length drgnx-pixels--quiet-hooks) nil)
      (cdr (buffer-text-pixel-size (current-buffer) (and frame (frame-first-window frame)))))))

(defun drgnx-wb-display-name (name)
  "NAME as it can be shown on one row: control characters (a newline in a file name) as ^X."
  (if (string-match-p "[\0-\37\177]" name)
      (replace-regexp-in-string "[\0-\37\177]"
                                (lambda (c) (if (equal c "\177") "^?" (string ?^ (+ 64 (aref c 0)))))
                                name t t)
    name))

(defun drgnx-wb-define-section (name &rest spec)
  "Define dock section NAME: SPEC is (:slot N :title STRING-OR-FUNCTION-RETURNING-ONE
:buffer FUNCTION-RETURNING-A-BUFFER :height FRACTION-OF-THE-DOCK :on-show FUNCTION-OF-THE-WINDOW
:on-focus FUNCTION-OF-THE-WINDOW, run when `drgnx-wb-focus-section' focuses it,
:view SYMBOL, the sidebar view the section belongs to, default `explorer').
A function title is asked each time the dock shows (a panel's filter stays in its title).
Called from a module's setup, the definition claims the section and records its undo: the section
it replaced put back, or `drgnx-wb-undefine-section' — only while the section is still the one defined
here.  Two modules defining the same section may be torn down in either order (`drgnx-module--claim')."
  (let ((rec (drgnx-modules--recording-p)) (old (let ((cell (assq name drgnx-wb--sections))) (and cell (list (cdr cell))))))   ; (SPEC) or nil
    (setf (alist-get name drgnx-wb--sections) spec)
    (when rec
      (let* ((target (list 'section name)) (box (drgnx-module--claim target old)))
        (drgnx-modules-push-undo
         (format "section %s" name)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda () (eq (alist-get name drgnx-wb--sections) spec))
            (lambda (prev)
              (drgnx-wb-undefine-section name)
              (when prev (setf (alist-get name drgnx-wb--sections) (car prev)))))))))
    name))

(defun drgnx-wb-undefine-section (name)
  "Remove dock section NAME and close its window wherever a dock shows it (the dock keeps its
other sections).  Returns non-nil when NAME was defined."
  (let ((defined (assq name drgnx-wb--sections)))
    (setq drgnx-wb--sections (assq-delete-all name drgnx-wb--sections))
    (dolist (frame (frame-list))
      (when-let* ((w (drgnx-wb-section-window name frame)))
        (when (eq (selected-window) w) (drgnx-wb-focus-editor))
        (delete-window w)))
    (and defined t)))

(defun drgnx-wb-section-window (name &optional frame)
  "The window showing dock section NAME on FRAME, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-section) name)) (window-list frame 'nomini)))

(defun drgnx-wb--dock-windows (&optional frame)
  (seq-filter (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock)) (window-list frame 'nomini)))

(defun drgnx-wb-sidebar-showing-p (&optional frame)
  (and (drgnx-wb--dock-windows frame) t))

(defvar drgnx-rules--placing)           ; drgnx-rules.el: the dock's side windows are meant, not rerouted

(defun drgnx-wb--in-view-p (spec view)
  "Non-nil when the section SPEC belongs to VIEW (a section without :view is the Explorer's)."
  (eq (or (plist-get spec :view) 'explorer) view))

(defun drgnx-wb--view-defined-p (view)
  "Non-nil when at least one section belongs to VIEW."
  (seq-some (lambda (s) (drgnx-wb--in-view-p (cdr s) view)) drgnx-wb--sections))

(defun drgnx-wb-sidebar-view (&optional frame)
  "The view the sidebar shows (or shows next) on FRAME.
It is `explorer' unless another view with sections was chosen (a stale choice falls back)."
  (let ((view (frame-parameter frame 'drgnx-wb-view)))
    (if (and view (drgnx-wb--view-defined-p view)) view 'explorer)))

(defun drgnx-wb-show-sidebar ()
  "Show the left dock (the current view's sections) without selecting it; keep the width it had."
  (unless (drgnx-wb-sidebar-showing-p)
    (let ((selected (selected-window)) (view (drgnx-wb-sidebar-view)))
      (pcase-dolist (`(,name . ,spec) (sort (seq-filter (lambda (s) (drgnx-wb--in-view-p (cdr s) view)) drgnx-wb--sections)
                                            (lambda (a b) (< (plist-get (cdr a) :slot) (plist-get (cdr b) :slot)))))
        (let ((drgnx-rules--placing t))
          (display-buffer-in-side-window
           (funcall (plist-get spec :buffer))
           `((side . left) (slot . ,(plist-get spec :slot)) (window-width . ,drgnx-wb-dock-columns)
             ,@(when (plist-get spec :height) `((window-height . ,(plist-get spec :height))))
             (dedicated . t)
             (window-parameters . ((drgnx-role . dock) (drgnx-section . ,name) (no-delete-other-windows . t)
                                   (no-other-window . t)
                                   (header-line-format . ,(let ((title (plist-get spec :title)))
                                                            (drgnx-wb-section-header
                                                             (if (functionp title) (funcall title) title))))))))))
      (when-let* ((px (frame-parameter nil 'drgnx-wb-dock-px)) (w (car (drgnx-wb--dock-windows))))
        (let ((window-resize-pixelwise t))              ; or the width is rounded to whole columns
          (ignore-errors (window-resize w (- px (window-pixel-width w)) t nil t))))
      (dolist (w (drgnx-wb--dock-windows))
        (set-window-scroll-bars w nil nil nil nil t)        ; a clean sidebar, like VS Code's
        ;; After the scroll bars: Emacs keeps the width only while it equals the body width it recorded (I11)
        (window-preserve-size w t t))
      (unless (eq (selected-window) selected) (select-window selected 'norecord))
      (pcase-dolist (`(,name . ,spec) drgnx-wb--sections)
        (when-let* ((fn (plist-get spec :on-show)) (w (drgnx-wb-section-window name)))
          (funcall fn w))))))

(defun drgnx-wb-hide-sidebar ()
  "Hide the left dock, remembering its pixel width for the next show.
The width is noted `:by auto' (`drgnx-state-note-intent'): a width you chose is kept instead."
  (when-let* ((windows (drgnx-wb--dock-windows)))
    (drgnx-state-note-intent nil :sizes 'left (window-pixel-width (car windows)) :by 'auto)
    (when (memq (selected-window) windows) (drgnx-wb-focus-editor))
    (dolist (w windows) (when (window-live-p w) (delete-window w)))))

(defvar drgnx-wb-view-providers nil
  "Alist VIEW → function that defines VIEW's sections now.  A module that sets up late can register one in its setup,
so the view's key works before its sections exist (`drgnx-wb-show-view' calls it when VIEW has no sections).
None does today: the Search view's module sets up at startup.")

(defun drgnx-wb-show-view (view)
  "Show only VIEW's sections in the left dock, swapping them in place at the same width.
Focus stays where it was (a focus in the dock moves to the new view's first section); a hidden
sidebar is shown first.  A view with no sections is a `user-error' and changes nothing."
  (unless (drgnx-wb--view-defined-p view)
    (when-let* ((provide (alist-get view drgnx-wb-view-providers))) (funcall provide)))
  (unless (drgnx-wb--view-defined-p view) (user-error "No %s view" view))
  (let ((in-dock (memq (selected-window) (drgnx-wb--dock-windows))))
    (unless (and (eq view (drgnx-wb-sidebar-view)) (drgnx-wb-sidebar-showing-p))
      (when-let* ((windows (drgnx-wb--dock-windows)))
        (drgnx-state-note-intent nil :sizes 'left (window-pixel-width (car windows)) :by 'auto)
        (when in-dock (drgnx-wb-focus-editor))
        (dolist (w windows) (when (window-live-p w) (delete-window w))))
      (drgnx-state-note-intent nil :view nil view)            ; who asked: the running write's, or the default
      (drgnx-wb-show-sidebar)
      (when-let* ((_ in-dock) (w (car (drgnx-wb--dock-windows))))
        (select-window w)))))

(defun drgnx-wb-view-explorer ()
  "Show the Explorer view (the Buffers panel, the Explorer, the Outline) in the sidebar and focus the file tree.
Like VS Code's Ctrl+Shift+E;
`drgnx-wb-show-view' (a layout, or a program) swaps the view and keeps the focus where it was."
  (interactive)
  (drgnx-wb-show-view 'explorer)
  (drgnx-wb-focus-section 'explorer))

(defun drgnx-wb-view-search ()
  "Show the Search view in the sidebar and focus it.
Like VS Code's Ctrl+Shift+F;
`drgnx-wb-show-view' (a layout, or a program) swaps the view and keeps the focus where it was."
  (interactive)
  (drgnx-wb-show-view 'search)
  (drgnx-wb-focus-section 'search))

(defun drgnx-wb-toggle-sidebar ()
  "Show or hide the left dock (Buffers and Explorer)."
  (interactive)
  (if (drgnx-wb-sidebar-showing-p) (drgnx-wb-hide-sidebar) (drgnx-wb-show-sidebar)))

(defun drgnx-wb-editor-window () (drgnx-signal-editor-window))

(defun drgnx-wb-show-in-editor (buffer &optional select)
  "Show BUFFER in the most recently used editor window, never splitting; SELECT it if asked.
Nil, and nothing shown, when the frame has no editor window (the daemon's initial frame)."
  (when-let* ((w (drgnx-wb-editor-window)))
    (set-window-buffer w buffer)
    (drgnx-state-use-editor w)
    (when select (select-window w))
    w))

(defun drgnx-wb-focus-editor ()
  "Move focus to the most recently used editor window."
  (interactive)
  (select-window (drgnx-wb-editor-window)))

(defun drgnx-wb-focus-section (name)
  "Show the dock if needed, in the view section NAME belongs to, and focus NAME.
The section's :on-focus function then gets its window (the Search view puts point in its query field)."
  (let ((spec (alist-get name drgnx-wb--sections)))
    (if spec (drgnx-wb-show-view (or (plist-get spec :view) 'explorer)) (drgnx-wb-show-sidebar))
    (let ((w (drgnx-wb-section-window name)))
      (select-window w)
      (when-let* ((fn (plist-get spec :on-focus))) (funcall fn w)))))

(provide 'drgnx-wb)
;;; drgnx-wb.el ends here
