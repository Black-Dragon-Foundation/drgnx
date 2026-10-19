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

(defcustom drgnx-wb-dock-columns 32
  "Width of the left dock, in columns, the first time it shows (later: the width it had)."
  :type 'integer :group 'drgnx)

(defface drgnx-wb-close '((t :inherit shadow))
  "The close button (×) of a title, tab row or popup header." :group 'drgnx)

(defface drgnx-wb-bar '((t :inherit tab-line :height 1.0 :box nil))
  "The band of a header row (breadcrumb, a dock section's title, a panel's tab row): the theme's tab-line
background, not the header line's, so every row of chrome is one colour and follows the theme." :group 'drgnx)

(declare-function drgnx-face-glyph "drgnx-face")

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

;;;; The close button

(defun drgnx-wb-close-glyph ()
  "The close glyph: ×, its ASCII form on a terminal that is not UTF-8 (`drgnx-face-glyph')."
  (or (and (fboundp 'drgnx-face-glyph) (drgnx-face-glyph 'close)) "×"))

(defvar drgnx-wb--close-maps nil
  "Alist COMMAND → the keymap of a close button that runs it (one per command: there are three).")

(defun drgnx-wb-close-button (command help &rest props)
  "The close glyph as a button: clickable (`mouse-1' in a header line runs COMMAND, which takes the click event),
highlighted under the pointer, HELP as its `help-echo'.  PROPS are text properties the click handler reads.
Built once when a title or tab row is set, never while drawing."
  (let ((map (or (alist-get command drgnx-wb--close-maps)
                 (let ((m (make-sparse-keymap)))
                   (define-key m [header-line mouse-1] command)
                   (setf (alist-get command drgnx-wb--close-maps) m)))))
    (apply #'propertize (drgnx-wb-close-glyph)
           'face 'drgnx-wb-close 'mouse-face 'highlight 'local-map map 'help-echo help props)))

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
                        (if (string-prefix-p " " title) "" " ") title)))

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
  "Hide the left dock, remembering its pixel width for the next show."
  (when-let* ((windows (drgnx-wb--dock-windows)))
    (set-frame-parameter nil 'drgnx-wb-dock-px (window-pixel-width (car windows)))
    (when (memq (selected-window) windows) (drgnx-wb-focus-editor))
    (dolist (w windows) (when (window-live-p w) (delete-window w)))))

(defvar drgnx-wb-view-providers nil
  "Alist VIEW → function that defines VIEW's sections now.  A module that sets up at idle registers one when its file
loads, so the view's key works before then (`drgnx-wb-show-view' calls it when VIEW has no sections).")

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
        (set-frame-parameter nil 'drgnx-wb-dock-px (window-pixel-width (car windows)))
        (when in-dock (drgnx-wb-focus-editor))
        (dolist (w windows) (when (window-live-p w) (delete-window w))))
      (set-frame-parameter nil 'drgnx-wb-view view)
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
  "Show BUFFER in the most recently used editor window, never splitting; SELECT it if asked."
  (let ((w (drgnx-wb-editor-window)))
    (set-window-buffer w buffer)
    (setq drgnx-signal--editor-window w)
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
