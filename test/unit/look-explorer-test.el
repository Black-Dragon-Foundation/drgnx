;;; look-explorer-test.el --- the Explorer and Buffers rows: headings, git marks, selection, the hover-revealed ⋯ -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the rows are text and overlays; these tests read their properties with the frame's kind and the
;; git status stubbed (the batch frame is a terminal, where the controls are always shown).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/unit/wb-explorer-edge-test" drgnx-dir) nil t)   ; its fixtures: a root with files
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-dir) nil t)

(defmacro drgnx-look-explorer-test--as (kind status &rest body)
  "BODY with the selected frame's kind stubbed to KIND (`gui' or `tty') and every file's git status STATUS."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (&optional _f) ,kind))
             ((symbol-function 'drgnx-git-unread-p) (lambda (&rest _) nil))
             ((symbol-function 'drgnx-git-status) (lambda (&rest _) ,status)))
     ,@body))

(defun drgnx-look-explorer-test--row (name)
  "The start of the Explorer row named NAME, painted."
  (with-current-buffer (drgnx-explorer--buffer)
    (drgnx-explorer--fontify (point-min) (point-max))
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (concat " " (regexp-quote name) "$"))
      (pos-bol))))

(defun drgnx-look-explorer-test--tail (row)
  "The after-string of the right-edge overlay on the row at ROW."
  (with-current-buffer (drgnx-explorer--buffer)
    (seq-some (lambda (o) (and (overlay-get o 'drgnx-row-tail) (overlay-get o 'after-string)))
              (overlays-in row (1+ (save-excursion (goto-char row) (pos-eol)))))))

(ert-deftest drgnx-look-explorer/sections-in-sentence-case ()
  "Pattern D: the three sections are called Files, Open and Outline, with no capitals but the first letter, and a
section header shows its title in the heading face."
  (drgnx-explorer-edge--with root
    (let ((title (plist-get (alist-get 'explorer drgnx-wb--sections) :title)))
      (should (equal "Files" (funcall title)))
      (should (equal "Open" (substring (drgnx-buffers--current-title) 0 4)))
      (should (equal "Outline" drgnx-outline-title))
      (dolist (s (list (funcall title) drgnx-outline-title (drgnx-buffers--current-title)))
        (should-not (let ((case-fold-search nil)) (string-match-p "[A-Z][A-Z]" s))))
      (let* ((header (drgnx-wb-section-header "Files")) (i (string-search "Files" header)))
        (should i)
        (should (memq 'drgnx-wb-section (ensure-list (get-text-property i 'face header))))))))

(ert-deftest drgnx-look-explorer/a-section-header-is-a-chevron-and-its-title ()
  "Pattern D: window-dark.html `.sec': a section's header is its chevron and its title, nothing else: no close button
\(Close Sidebar is on the island's ⋯) and no text buttons."
  (dolist (title (list "Files" (drgnx-buffers--current-title)))
    (let ((header (drgnx-wb-section-header title)))
      (should (string-search (drgnx-face-glyph 'chevron-down) header))
      (should-not (string-search (drgnx-face-glyph 'close) header))
      (should (equal (list (drgnx-face-glyph 'chevron-down) title)
                     (split-string (substring-no-properties header) " " t))))))

(ert-deftest drgnx-look-explorer/the-island-header-names-the-folder ()
  "Pattern D: window-dark.html `.ph': the sidebar is one island whose top window carries the header in its tab line:
the first root's name, then New File, Find and ⋯; no other dock window has one.  ⋯'s menu holds Close Sidebar."
  (drgnx-explorer-edge--with root
    (drgnx-buffers-setup)
    (drgnx-wb-show-sidebar)
    (let* ((windows (drgnx-wb--dock-windows)) (head (window-parameter (car windows) 'tab-line-format))
           (actions nil))
      (should (stringp head))
      (should (string-search (file-name-nondirectory (directory-file-name root)) head))
      (dotimes (i (length head))
        (when-let* ((a (get-text-property i 'drgnx-island-action head))) (cl-pushnew a actions :test #'equal)))
      (should (equal '((explorer . explorer-new-file) (explorer . explorer-find) menu) (nreverse actions)))
      (dolist (w (cdr windows)) (should-not (stringp (window-parameter w 'tab-line-format))))
      (should (rassq 'toggle-sidebar drgnx-wb-island-menu))
      (should (equal "Close Sidebar" (car (rassq 'toggle-sidebar drgnx-wb-island-menu))))
      ;; a new root renames it
      (let ((other (file-name-as-directory (make-temp-file "drgnx-island" t))))
        (unwind-protect
            (progn (drgnx-explorer-set-roots (list other))
                   (should (string-search (file-name-nondirectory (directory-file-name other))
                                          (window-parameter (car (drgnx-wb--dock-windows)) 'tab-line-format))))
          (delete-directory other t))))))

(ert-deftest drgnx-look-explorer/the-dock-is-on-the-panel-surface ()
  "Pattern D: window-dark.html `.card.ex' is `--panel', not the editor's colour: the dock's buffers draw `default' on
`drgnx-surface-panel'."
  (drgnx-explorer-edge--with root
    (drgnx-buffers-setup)
    (dolist (buf (list (drgnx-explorer--buffer) (drgnx-buffers--buffer)))
      (should (memq 'drgnx-surface-panel (flatten-tree (buffer-local-value 'face-remapping-alist buf)))))))

(ert-deftest drgnx-look-explorer/marks-coloured-and-pixel-aligned ()
  "Pattern D: a modified file's mark is `M' in the warning status face, behind a spacer placed in columns worked out
from measured pixels (a column is each frame's own cell, so a terminal showing the rows reads it right); the measure is
made once and not again for another redraw of the same rows."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui 'modified
      (drgnx-wb-mark-memo-clear)
      (let* ((row (drgnx-look-explorer-test--row "README.md")) (tail (drgnx-look-explorer-test--tail row))
             (spacer (get-text-property 0 'display tail)) (i (string-search "M" tail)))
        (should (eq 'space (car spacer)))
        (let ((align (plist-get (cdr spacer) :align-to)))
          (should (eq '- (car align)))
          (should (eq 'right (nth 1 align)))
          (should (floatp (nth 2 align))))                   ; N: columns, not (N) pixels
        (should i)
        (should (memq 'drgnx-status-warn (ensure-list (get-text-property i 'face tail))))
        (should (= 1 drgnx-wb--mark-measures))
        (with-current-buffer drgnx-explorer-buffer-name (jit-lock-refontify))
        (drgnx-look-explorer-test--row "README.md")
        (should (= 1 drgnx-wb--mark-measures))))))

(ert-deftest drgnx-look-explorer/status-faces ()
  "Pattern D: the mark faces: modified warn, untracked and added ok, deleted fail."
  (should (eq 'drgnx-status-warn (drgnx-wb-git-mark-face 'modified)))
  (should (eq 'drgnx-status-ok (drgnx-wb-git-mark-face 'untracked)))
  (should (eq 'drgnx-status-ok (drgnx-wb-git-mark-face 'added)))
  (should (eq 'drgnx-status-fail (drgnx-wb-git-mark-face 'deleted))))

(defun drgnx-look-explorer-test--faces (v)
  "The faces of a `face' property value V, as a list (a lone anonymous face is a plist, not a list of faces)."
  (if (keywordp (car-safe v)) (list v) (ensure-list v)))

(defun drgnx-look-explorer-test--selected (buf)
  "The selection overlay of BUF."
  (with-current-buffer buf
    (car (seq-filter (lambda (o) (overlay-get o 'drgnx-row-selected)) (overlays-in (point-min) (point-max))))))

(ert-deftest drgnx-look-explorer/selected-and-quiet ()
  "Pattern D, window-dark.html `.row.sel.focus' and `.row.sel': the row at point is the selection while the
Explorer's window is the selected one, and the inactive selection when another window is (as VS Code's inactive
selection).  Both are an inside box: no width changes when a row is selected.  The focused one is ringed in the
focus colour (`drgnx-focus''s ring); the inactive one's box is its fill's own colour.  The row's newline carries the
selection's face too, so its text and its tail are one box run (one ring, no seam between them).  Under the dark
theme (the ring's colour is a theme's), with Glitnir drawing (the ring needs it)."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui nil
      (cl-letf* (((symbol-function 'glitnir-active-p) #'always)
                 (buf (drgnx-explorer--buffer)) (row (drgnx-look-explorer-test--row "README.md"))
                 (was custom-enabled-themes))
        (mapc #'disable-theme custom-enabled-themes)
        (load-theme 'drgnx-dark t)
        (drgnx-wb--row-faces-clear)
        (set-window-buffer (selected-window) buf)
        (with-current-buffer buf (goto-char row) (drgnx-wb-selection-sync))
        (let* ((o (drgnx-look-explorer-test--selected buf)) (face (overlay-get o 'face))
               (box (plist-get face :box)))
          (should (eq 'drgnx-selected (plist-get face :inherit)))
          (should (equal (list nil (plist-get (face-attribute 'drgnx-focus :box nil t) :color))
                         (list (plist-get box :style) (plist-get box :color))))
          (should (stringp (plist-get box :color)))
          (should (< (car (plist-get box :line-width)) 0))
          (should (= row (overlay-start o)))
          (with-current-buffer buf
            (let ((eol (save-excursion (goto-char row) (pos-eol))))
              (should (eq face (get-char-property eol 'face)))))
          (let ((other (split-window)))
            (select-window other)
            (set-window-buffer other (get-buffer-create "*look-explorer-other*"))
            (with-current-buffer buf (drgnx-wb-selection-sync))
            (should (eq 'drgnx-selected-inactive (plist-get (overlay-get o 'face) :inherit)))
            (should (eq 'flat-button (plist-get (plist-get (overlay-get o 'face) :box) :style)))))
        (mapc #'disable-theme custom-enabled-themes)
        (mapc (lambda (th) (enable-theme th)) (reverse was))
        (drgnx-wb--row-faces-clear)))))

(ert-deftest drgnx-look-explorer/ellipsis-hidden-shown-on-point-and-selected ()
  "Pattern D, window-dark.html: on a graphical frame a row's ⋯ is hidden, drawn in its row's colour: the hidden face
on a row, the selection's colour on the selected row (it shows on hover only); a terminal shows it on every row; every
row's text carries the one mouse face that lights the control."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui nil
      (let* ((buf (drgnx-explorer--buffer)) (a (drgnx-look-explorer-test--row "README.md"))
             (b (drgnx-look-explorer-test--row "docs"))
             (face-at (lambda (row) (let* ((tail (drgnx-look-explorer-test--tail row)) (i (string-search "⋯" tail)))
                                      (car (drgnx-look-explorer-test--faces (get-text-property i 'face tail)))))))
        (set-window-buffer (selected-window) buf)
        (with-current-buffer buf (goto-char b) (drgnx-wb-selection-sync))
        (should (eq 'drgnx-control-hidden (funcall face-at a)))
        (should (equal (list :foreground (face-background 'drgnx-selected nil t)) (funcall face-at b)))
        (with-current-buffer buf (goto-char a) (drgnx-wb-selection-sync))
        (should (equal (list :foreground (face-background 'drgnx-selected nil t)) (funcall face-at a)))
        (should (eq 'drgnx-control-hidden (funcall face-at b)))
        (with-current-buffer buf
          (should (equal '(drgnx-hover-row) (ensure-list (get-text-property a 'mouse-face))))
          (should (eq (get-text-property (1+ a) 'mouse-face)
                      (get-text-property (1- (save-excursion (goto-char a) (pos-eol))) 'mouse-face))))))))

(ert-deftest drgnx-look-explorer/the-selected-row-is-one-run ()
  "Pattern D, window-dark.html `.row.sel': the selection is one fill from the row's start to its right edge: the
overlay on the row's text (not its newline: no fill past the row) and the same face on the tail at the right edge
(an overlay string takes no face from the overlays around it), so no gap opens under the tail.  Moving the selection
gives the old row's tail back its plain face."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui 'modified
      (let* ((buf (drgnx-explorer--buffer)) (a (drgnx-look-explorer-test--row "README.md"))
             (b (drgnx-look-explorer-test--row "docs"))
             (covered (lambda (row face)
                        (let ((tail (drgnx-look-explorer-test--tail row)))
                          (cl-loop for i below (length tail)
                                   always (member face (drgnx-look-explorer-test--faces
                                                        (get-text-property i 'face tail))))))))
        (set-window-buffer (selected-window) buf)
        (with-current-buffer buf (goto-char a) (drgnx-wb-selection-sync))
        (let* ((o (drgnx-look-explorer-test--selected buf)) (face (overlay-get o 'face)))
          (should (= (overlay-end o) (with-current-buffer buf (save-excursion (goto-char a) (pos-eol)))))
          (should (funcall covered a face))
          (should-not (funcall covered b face))
          (with-current-buffer buf (goto-char b) (drgnx-wb-selection-sync))
          (should (funcall covered b (overlay-get o 'face)))
          (should-not (funcall covered a (overlay-get o 'face)))
          ;; a repaint while point is on another row (no sync yet) follows the selection, not point
          (with-current-buffer buf
            (goto-char a)
            (drgnx-explorer--fontify (point-min) (point-max)))
          (should (funcall covered b (overlay-get o 'face)))
          (should-not (funcall covered a (overlay-get o 'face))))))))

(ert-deftest drgnx-look-explorer/a-row-reaches-the-right-edge ()
  "Pattern D, window-dark.html `.row': on a graphical frame a row's fill, hover and ring end at the card's inset, not
two columns short of it: the tail's last character stretches to the text area's right edge there, and is invisible
on a terminal, whose last columns stay free."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui nil
      (let* ((tail (drgnx-look-explorer-test--tail (drgnx-look-explorer-test--row "README.md")))
             (i (1- (length tail))))
        (should (equal '(when (display-graphic-p) space :align-to right) (get-text-property i 'display tail)))
        (should (get-text-property i 'invisible tail))))))

(ert-deftest drgnx-look-explorer/hover-lights-the-whole-row ()
  "Pattern D, window-dark.html `.row:hover': the hover is one rounded run over the row and its tail: the tail's
overlay spans the row's text and carries the mouse face, so Emacs lights its string with the text; the box is inside
the row (negative widths: nothing moves when it lights)."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui nil
      (let* ((row (drgnx-look-explorer-test--row "README.md"))
             (o (with-current-buffer (drgnx-explorer--buffer)
                  (seq-find (lambda (o) (overlay-get o 'drgnx-row-tail))
                            (overlays-in row (1+ (save-excursion (goto-char row) (pos-eol)))))))
             (mouse (overlay-get o 'mouse-face)))
        (should (= row (overlay-start o)))
        (should (eq 'drgnx-hover-row (plist-get mouse :inherit)))
        (should (< (car (plist-get (plist-get mouse :box) :line-width)) 0))))))

(ert-deftest drgnx-look-explorer/no-current-line-under-the-rows ()
  "Pattern D: the dock's sections draw the selection, not `hl-line' (the current line's colour sat under the
selection's tail and past its end, and below the hover); their fringes are the panel, not the editor's colour."
  (drgnx-explorer-edge--with root
    (drgnx-buffers-setup)
    (dolist (make (list #'drgnx-explorer--buffer #'drgnx-buffers--buffer #'drgnx-outline--buffer))
      (with-current-buffer (funcall make)
        (should-not (bound-and-true-p hl-line-mode))
        (should (member '(fringe drgnx-surface-panel fringe) face-remapping-alist))))))

(ert-deftest drgnx-look-explorer/the-outline-current-is-the-inactive-selection ()
  "Pattern D: the Outline's current definition is drawn as a selection in a list without the focus (bold), not the
hover's colour (which ranked it with a hovered row)."
  (should (eq 'drgnx-selected-inactive (face-attribute 'drgnx-outline-current :inherit))))

(ert-deftest drgnx-look-explorer/a-row-has-one-end ()
  "A row that ends its own way (the Outline's current definition: `drgnx-row-end') and is selected draws one stretch
to the right edge, the selection's: two would overflow the line (a truncation arrow in the fringe).  The row's own
end comes back when the selection leaves."
  (with-temp-buffer
    (insert "current\nother\n")
    (setq-local drgnx-wb-selection-unfocused t)   ; a buffer in no window: its selection shows anyway
    (let ((o (make-overlay 1 8)) (own (drgnx-wb--row-end 'drgnx-outline-current)))
      (overlay-put o 'drgnx-row-end own)
      (overlay-put o 'after-string own)
      (goto-char 1) (drgnx-wb-selection-sync)
      (should-not (overlay-get drgnx-wb--selected-overlay 'after-string))
      (should (eq (get-text-property 0 'face (overlay-get o 'after-string))
                  (overlay-get drgnx-wb--selected-overlay 'face)))
      (forward-line 1) (drgnx-wb-selection-sync)
      (should (eq own (overlay-get o 'after-string)))
      (should (overlay-get drgnx-wb--selected-overlay 'after-string)))))

(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir) nil t)

(ert-deftest drgnx-look-explorer/rows-follow-a-density-change ()
  "Pattern D: a density change reaches the dock's rows at once: the Explorer's and the Buffers panel's line spacing
makes the tree row of the new density (26 → 30 at roomy), with no new buffer or restart."
  (drgnx-explorer-edge--with root
    (let ((drgnx-look-density 'comfortable) (s (drgnx-pixels-scale)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _d) t))
                ((symbol-function 'drgnx-wb--natural-row-height) (lambda (&rest _) 18)))
        (dolist (buf (list (drgnx-explorer--buffer) (drgnx-buffers--buffer)))
          (with-current-buffer buf (drgnx-wb-rows-setup))
          (should (equal (drgnx-look-ui-line-spacing 18 'comfortable s) (buffer-local-value 'line-spacing buf))))
        (setq drgnx-look-density 'roomy)
        (run-hooks 'drgnx-look-density-changed-hook)
        (dolist (buf (list (drgnx-explorer--buffer) (drgnx-buffers--buffer)))
          (should (equal (drgnx-look-ui-line-spacing 18 'roomy s) (buffer-local-value 'line-spacing buf))))))))

(ert-deftest drgnx-look-explorer/rows-made-before-a-graphical-frame ()
  "Pattern D: a dock buffer made while no frame is graphical (a daemon before its first frame) has no row spacing;
once a graphical frame shows it, it gets the tree row in that frame's scale (×2 here)."
  (drgnx-explorer-edge--with root
    (let ((drgnx-look-density 'comfortable) (gui nil) (buf (drgnx-explorer--buffer)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _d) gui))
                ((symbol-function 'drgnx-wb--natural-row-height) (lambda (&rest _) 18))
                ((symbol-function 'drgnx-pixels-scale) (lambda (&optional _f) 2.0)))
        (with-current-buffer buf (kill-local-variable 'line-spacing) (drgnx-wb-rows-setup))
        (should-not (buffer-local-value 'line-spacing buf))
        (setq gui t)
        (set-window-buffer (selected-window) buf)
        (drgnx-wb-rows-refresh (selected-frame))
        (should (equal (drgnx-look-ui-line-spacing 18 'comfortable 2.0) (buffer-local-value 'line-spacing buf)))))))

(ert-deftest drgnx-look-explorer/rows-in-the-ui-font ()
  "Pattern D: the Explorer's and the Buffers panel's rows are drawn with `default' remapped to the UI text face."
  (drgnx-explorer-edge--with root
    (dolist (buf (list (drgnx-explorer--buffer) (drgnx-buffers--buffer)))
      (with-current-buffer buf
        (should (memq 'drgnx-ui-text (ensure-list (cadr (assq 'default face-remapping-alist)))))))))

(defun drgnx-look-explorer-test--at (row text)
  "Where TEXT starts in the row at ROW of the current buffer."
  (+ row (string-search text (buffer-substring row (save-excursion (goto-char row) (pos-eol))))))

(ert-deftest drgnx-look-explorer/a-changed-name-keeps-the-text-colour ()
  "Pattern D, window-dark.html `.row': a modified file's name is in the row's text colour, its state only the mark at
the right edge; an ignored file is the one whose name changes (dimmed, `.row.dim')."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui 'modified
      (let ((row (drgnx-look-explorer-test--row "README.md")))
        (with-current-buffer (drgnx-explorer--buffer)
          (should-not (memq 'drgnx-git-modified
                            (ensure-list (get-text-property (drgnx-look-explorer-test--at row "R")
                                                            'face)))))
        (should (string-search "M" (drgnx-look-explorer-test--tail row)))))
    (drgnx-look-explorer-test--as 'gui 'ignored
      (let ((row (drgnx-look-explorer-test--row "README.md")))
        (with-current-buffer (drgnx-explorer--buffer)
          (should (memq 'drgnx-git-ignored
                        (ensure-list (get-text-property (drgnx-look-explorer-test--at row "R")
                                                        'face)))))))))

(ert-deftest drgnx-look-explorer/the-icon-stands-off-its-name ()
  "Pattern D, window-dark.html `.row' (gap 6px): where icons are images, a row's icon has 6 logical pixels of room
either side (the image's own margin: an image inside a display string is not drawn)."
  (drgnx-explorer-edge--with root
    (cl-letf (((symbol-function 'drgnx-look-icon)
               (lambda (name &rest _) (propertize "i" 'display `(image :type svg :data "<svg/>" :name ,name)))))
      (drgnx-look-explorer-test--as 'gui nil
        (let ((row (drgnx-look-explorer-test--row "README.md")))
          (with-current-buffer (drgnx-explorer--buffer)
            (let* ((name (drgnx-look-explorer-test--at row "README"))
                   (icon (get-text-property (1- name) 'display)))
              (should (eq 'image (car-safe icon)))
              (should (equal (cons (drgnx-px 6) 0) (plist-get (cdr icon) :margin))))))))))

(ert-deftest drgnx-look-explorer/the-hidden-root-row-draws-no-icon ()
  "Pattern D: the one root's row is invisible, and Emacs draws a `display' image even on invisible text, so the row
gets no chevron or icon (they showed before the first folder's own)."
  (drgnx-explorer-edge--with root
    (cl-letf (((symbol-function 'drgnx-look-icon)
               (lambda (name &rest _) (propertize "i" 'display `(image :type svg :data "<svg/>" :name ,name)))))
      (drgnx-look-explorer-test--as 'gui nil
        (with-current-buffer (drgnx-explorer--buffer)
          (drgnx-explorer--fontify (point-min) (point-max))
          (should (invisible-p (point-min)))
          (should-not (text-property-not-all (point-min) (pos-eol 1) 'display nil)))))))

(ert-deftest drgnx-look-explorer/one-root-has-no-root-row ()
  "Pattern D, window-dark.html: with one root the tree starts at its entries (the island's header names the
project); the root's row is there but not shown.  With several roots each has a row, its name as it is."
  (drgnx-explorer-edge--with root
    (with-current-buffer (drgnx-explorer--buffer)
      (goto-char (point-min))
      (should (invisible-p (point)))
      (should-not (string-search (upcase (file-name-nondirectory (directory-file-name root)))
                                 (buffer-substring-no-properties (point-min) (point-max)))))
    (let ((other (file-name-as-directory (make-temp-file "drgnx-explorer-b" t))))
      (unwind-protect
          (progn
            (drgnx-explorer-set-roots (list root other))
            (with-current-buffer (drgnx-explorer--buffer)
              (goto-char (point-min))
              (should-not (invisible-p (point)))
              (should (string-search (file-name-nondirectory (directory-file-name root))
                                     (buffer-substring-no-properties (point) (pos-eol))))))
        (drgnx-explorer-set-roots (list root))
        (delete-directory other t)))))

(provide 'look-explorer-test)
;;; look-explorer-test.el ends here
