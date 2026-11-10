;;; look-explorer-test.el --- the Explorer and Buffers rows: headings, git marks, selection, the hover-revealed ⋯ -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the rows are text and overlays; these tests read their properties with the frame's kind and the
;; git status stubbed (the batch frame is a terminal, where the controls are always shown).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/unit/wb-explorer-edge-test" drgnx-dir) nil t)   ; its fixtures: a root with files

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
        (should (memq 'drgnx-ui-heading (ensure-list (get-text-property i 'face header))))))))

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

(ert-deftest drgnx-look-explorer/selected-and-quiet ()
  "Pattern D: the row at point is `drgnx-selected' with the focus ring while the Explorer's window is the selected
one, and `drgnx-selected-quiet' when another window is."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui nil
      (let ((buf (drgnx-explorer--buffer)) (row (drgnx-look-explorer-test--row "README.md")))
        (set-window-buffer (selected-window) buf)
        (with-current-buffer buf (goto-char row) (drgnx-wb-selection-sync))
        (let ((o (with-current-buffer buf (car (seq-filter (lambda (o) (overlay-get o 'drgnx-row-selected))
                                                           (overlays-in (point-min) (point-max)))))))
          (should (equal '(drgnx-selected drgnx-focus) (overlay-get o 'face)))
          (should (= row (overlay-start o)))
          (let ((other (split-window)))
            (select-window other)
            (set-window-buffer other (get-buffer-create "*look-explorer-other*"))
            (with-current-buffer buf (drgnx-wb-selection-sync))
            (should (eq 'drgnx-selected-quiet (overlay-get o 'face)))))))))

(ert-deftest drgnx-look-explorer/ellipsis-hidden-shown-on-point-and-selected ()
  "Pattern D: on a graphical frame a row's ⋯ is drawn in the hidden face; the row at point shows it in its real
face; every row carries the one mouse face that lights the control."
  (drgnx-explorer-edge--with root
    (drgnx-look-explorer-test--as 'gui nil
      (let* ((buf (drgnx-explorer--buffer)) (a (drgnx-look-explorer-test--row "README.md"))
             (b (drgnx-look-explorer-test--row "docs"))
             (face-at (lambda (row) (let* ((tail (drgnx-look-explorer-test--tail row)) (i (string-search "⋯" tail)))
                                      (get-text-property i 'face tail)))))
        (set-window-buffer (selected-window) buf)
        (with-current-buffer buf (goto-char b) (drgnx-wb-selection-sync))
        (should (eq 'drgnx-control-hidden (funcall face-at a)))
        (should (eq 'drgnx-ui-close (funcall face-at b)))
        (with-current-buffer buf (goto-char a) (drgnx-wb-selection-sync))
        (should (eq 'drgnx-ui-close (funcall face-at a)))
        (should (eq 'drgnx-control-hidden (funcall face-at b)))
        (with-current-buffer buf
          (should (equal '(drgnx-hover-row) (ensure-list (get-text-property a 'mouse-face))))
          (should (eq (get-text-property (1+ a) 'mouse-face)
                      (get-text-property (1- (save-excursion (goto-char a) (pos-eol))) 'mouse-face))))))))

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
  "Pattern D, window-dark.html `.row' (gap 6px): where icons are images, a row's icon is followed by 6 logical
pixels of room before the name."
  (drgnx-explorer-edge--with root
    (cl-letf (((symbol-function 'drgnx-look-icon)
               (lambda (name &rest _) (propertize "i" 'display `(image :type svg :data "<svg/>" :name ,name)))))
      (drgnx-look-explorer-test--as 'gui nil
        (let ((row (drgnx-look-explorer-test--row "README.md")))
          (with-current-buffer (drgnx-explorer--buffer)
            (let* ((name (drgnx-look-explorer-test--at row "README"))
                   (icon (get-text-property (1- name) 'display)))
              (should (stringp icon))
              (should (eq 'image (car-safe (get-text-property 0 'display icon))))
              (should (equal `(space :width (,(drgnx-px 6))) (get-text-property 1 'display icon))))))))))

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
