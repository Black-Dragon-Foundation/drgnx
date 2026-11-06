;;; look-tabs-test.el --- tabs: the close mark appears on hover, the whole tab lights, state shows in the name -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): a window's tab line is a string built from its tabs; these tests read its text properties, with
;; the frame's kind stubbed (the batch frame is a terminal, where the close mark is always shown).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-chrome)
(load (expand-file-name "test/unit/wb-chrome-test" drgnx-dir) nil t)    ; its fixtures: a window with chrome on, files

(defmacro drgnx-look-tabs-test--as (kind &rest body)
  "BODY with the selected frame's kind stubbed to KIND (`gui' or `tty')."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (&optional _f) ,kind)))
     ,@body))

(defun drgnx-look-tabs-test--positions (tabs buffer)
  "The positions of TABS (the tab-line string) whose text belongs to BUFFER's tab."
  (let (out)
    (dotimes (i (length tabs))
      (when (eq (get-text-property i 'drgnx-buffer tabs) buffer) (push i out)))
    (nreverse out)))

(defun drgnx-look-tabs-test--close-face (tabs buffer)
  "The face of the close mark in BUFFER's tab: the character with the help text \"Close this tab\"."
  (seq-some (lambda (i) (and (equal (get-text-property i 'help-echo tabs) "Close this tab")
                             (let ((f (get-text-property i 'face tabs))) (if (listp f) (car f) f))))
            (drgnx-look-tabs-test--positions tabs buffer)))

(ert-deftest drgnx-look-tabs/inactive-close-is-hidden-active-is-real ()
  "Pattern D: on a graphical frame the close mark of a tab that is not shown is drawn in the hidden face, and the
shown tab's in its real one."
  (drgnx-chrome-test--with dir
    (drgnx-look-tabs-test--as 'gui
      (let* ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
             (tabs (window-parameter (selected-window) 'tab-line-format)))
        (should (eq 'drgnx-control-hidden (drgnx-look-tabs-test--close-face tabs a)))
        (should (eq 'drgnx-ui-close (drgnx-look-tabs-test--close-face tabs b)))))))

(ert-deftest drgnx-look-tabs/whole-tab-has-the-mouse-face ()
  "Pattern D: every character of a tab that is not shown, its close mark included, has the mouse face
`drgnx-hover-row', one value for the tab (Emacs lights the run of text whose value is `eq'), another for the next
tab; the shown tab has none."
  (drgnx-chrome-test--with dir
    (drgnx-look-tabs-test--as 'gui
      (let* ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
             (c (drgnx-chrome-test--open dir "c.txt"))
             (tabs (window-parameter (selected-window) 'tab-line-format))
             (faces (lambda (buf) (mapcar (lambda (i) (get-text-property i 'mouse-face tabs))
                                          (drgnx-look-tabs-test--positions tabs buf)))))
        (dolist (buf (list a b))
          (let ((fs (funcall faces buf)))
            (should (equal (car fs) '(drgnx-hover-row)))
            (should (seq-every-p (lambda (f) (eq f (car fs))) fs))))
        (should-not (eq (car (funcall faces a)) (car (funcall faces b))))
        (should (seq-every-p #'null (funcall faces c)))))))

(ert-deftest drgnx-look-tabs/modified-dot-and-preview-italic ()
  "Pattern D: a modified file's tab shows a dot in the muted text face; a tab that is only there while shown (a
preview: the scratch buffer) is in italics."
  (drgnx-chrome-test--with dir
    (drgnx-look-tabs-test--as 'gui
      (let* ((a (drgnx-chrome-test--open dir "a.txt")) (tabs nil))
        (with-current-buffer a (insert "more") )
        (drgnx-chrome-apply nil t)
        (setq tabs (window-parameter (selected-window) 'tab-line-format))
        (let* ((dot (string-search "●" tabs)) (face (get-text-property dot 'face tabs)))
          (should dot)
          (should (memq 'drgnx-text-muted (ensure-list face))))
        (with-current-buffer a (set-buffer-modified-p nil))
        (switch-to-buffer (get-scratch-buffer-create))
        (drgnx-chrome-apply nil t)
        (setq tabs (window-parameter (selected-window) 'tab-line-format))
        (let ((face (get-text-property (string-search "scratch" tabs) 'face tabs)))
          (should (memq 'drgnx-chrome-tab-preview (ensure-list face)))
          (should (eq 'italic (face-attribute 'drgnx-chrome-tab-preview :slant nil nil))))))))

(ert-deftest drgnx-look-tabs/terminal-shows-the-close-on-the-selected ()
  "Pattern D: on a terminal there is no hover, so every tab shows its close mark in its real face, the shown one
included."
  (drgnx-chrome-test--with dir
    (drgnx-look-tabs-test--as 'tty
      (let* ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
             (tabs (window-parameter (selected-window) 'tab-line-format)))
        (should (eq 'drgnx-ui-close (drgnx-look-tabs-test--close-face tabs a)))
        (should (eq 'drgnx-ui-close (drgnx-look-tabs-test--close-face tabs b)))))))

(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir) nil t)

(defun drgnx-look-tabs-test--row-height (tabs)
  "The height in pixels the tab line TABS asks for: its first character's spacer."
  (car (plist-get (cdr (get-text-property 0 'display tabs)) :height)))

(ert-deftest drgnx-look-tabs/the-tab-row-follows-a-density-change ()
  "Pattern D: a density change reaches every editor's tab row at once: the row is the new `tab-row' (34 → 38 at
roomy), although no tab and no buffer changed."
  (drgnx-chrome-test--with dir
    (drgnx-look-tabs-test--as 'gui
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _d) t))
                ((symbol-function 'drgnx-pixels-font-extent) (lambda (&rest _) '(13 . 4))))
        (let ((drgnx-look-density 'comfortable) (s (drgnx-pixels-scale)))
          (drgnx-chrome-test--open dir "a.txt")
          (drgnx-chrome-apply nil t)
          (should (equal (round (* 34 s))
                         (drgnx-look-tabs-test--row-height (window-parameter (selected-window) 'tab-line-format))))
          (setq drgnx-look-density 'roomy)
          (run-hooks 'drgnx-look-density-changed-hook)
          (should (equal (round (* 38 s))
                         (drgnx-look-tabs-test--row-height (window-parameter (selected-window) 'tab-line-format)))))))))

(provide 'look-tabs-test)
;;; look-tabs-test.el ends here
