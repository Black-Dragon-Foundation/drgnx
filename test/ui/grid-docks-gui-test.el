;;; grid-docks-gui-test.el --- GUI test: a dock the user resizes stays as resized (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-grid-keep-dock-sizes' gives the docks their logical px back when the grid root's size or the scale changes.
;; A dock edge dragged (a plain `window-resize') is the user's choice: it stays after redisplay and the size-change
;; hooks, and is the size the dock keeps from then on.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-grid-docks--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-grid-docks--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-grid-docks--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-grid-docks--repo) nil t)
(require 'drgnx-grid-frames)
(require 'drgnx-grid-ops)

(defun drgnx-ui-grid-docks--width (dock)
  "DOCK's tile width in pixels."
  (window-size (drgnx-grid--tile-root (drgnx-grid-dock dock)) t t))

(defun drgnx-ui-grid-docks--resize (dock delta)
  "Drag DOCK's edge DELTA pixels (a plain `window-resize' of its tile), then let redisplay and the hooks run."
  (let ((window-resize-pixelwise t))
    (window-resize (drgnx-grid--tile-root (drgnx-grid-dock dock)) delta t nil t))
  (dotimes (_ 3) (redisplay t) (run-hook-with-args 'window-size-change-functions (selected-frame))))

(ert-deftest drgnx-ui-grid-docks/a-dock-the-user-resized-stays ()
  "The side bar dragged 40 px narrower and then 60 px wider stays at each size after redisplay and the size-change
hooks; the width it wants is the new one, so a later hook run keeps it."
  (drgnx-grid-test--with
    (let ((was drgnx-grid-mode))
      (unless was (drgnx-grid-mode 1))
      (unwind-protect
          (progn
            (drgnx-grid-show 'g-tree)
            (drgnx-grid-show 'g-term)
            (drgnx-test-wait-presented)
            (drgnx-grid-keep-dock-sizes (selected-frame))
            (let ((start (drgnx-ui-grid-docks--width 'left)))
              (drgnx-ui-grid-docks--resize 'left -40)
              (drgnx-test-wait-presented)
              (should (= (drgnx-ui-grid-docks--width 'left) (- start 40)))
              (drgnx-ui-grid-docks--resize 'left 60)
              (drgnx-test-wait-presented)
              (should (= (drgnx-ui-grid-docks--width 'left) (+ start 20)))
              (drgnx-grid-keep-dock-sizes (selected-frame))
              (should (= (drgnx-ui-grid-docks--width 'left) (+ start 20)))))
        (unless was (drgnx-grid-mode -1))
        (set-frame-parameter nil 'drgnx-grid--docks nil)))))

(ert-deftest drgnx-ui-grid-docks/resize-tiles-draws-a-2-px-accent-line-on-the-gap-in-use ()
  "Resize Tiles puts tiling.html's `.gaphint' on the gap its next step moves: a 2 px frame in the accent colour on the
gap between the editor and the side bar (the editor has no tile to its right), and takes it away when the mode ends."
  (skip-unless (display-graphic-p))
  (drgnx-grid-test--with
    (drgnx-grid-show 'g-tree)
    (drgnx-test-wait-presented)
    (let ((editor (drgnx-wb-editor-window)))
      (select-window editor)
      (let ((exit (drgnx-grid-resize-mode)))
        (unwind-protect
            (let* ((line drgnx-grid--resize-line) (e (window-pixel-edges editor)))
              (should (frame-live-p line))
              (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p line)) :secs 10 :what "the line shown")
              (should (= (frame-pixel-width line) (drgnx-px-line 2)))
              (should (<= (abs (- (frame-pixel-height line) (- (nth 3 e) (nth 1 e)))) 2))
              (should (<= (- (nth 0 e) (frame-right-divider-width) (drgnx-px-line 2)) (car (frame-position line)) (nth 0 e)))
              (let ((accent (face-foreground 'drgnx-accent nil t)))
                (when (stringp accent) (should (equal (frame-parameter line 'background-color) accent)))))
          (funcall exit)
          (drgnx-grid--resize-end)
          (dolist (w (window-list nil 'nomini))
            (dolist (p '(header-line-format mode-line-format tab-line-format drgnx-grid-mode-note))
              (set-window-parameter w p nil))))
        (should-not (frame-live-p drgnx-grid--resize-line))))))

(ert-deftest drgnx-ui-grid-docks/a-kind-comes-back-on-its-text-after-text-came-above-it ()
  "A kind switched away and back in its tile comes back on the line it was on, though text was inserted above that
line meanwhile: the remembered start and point follow the text (a hub view's patches arrive while it is hidden; a
start kept as a number came back rows earlier, the agent panel's tab switch at scale 2, 2026-11-20)."
  (skip-unless (display-graphic-p))
  (drgnx-grid-test--with
    (let ((term (get-buffer-create "*g-term-text*")))
      (with-current-buffer term
        (dotimes (i 200) (insert (format "line %d\n" i))))
      (let ((w (drgnx-pane-show 'g-term :buffer term)))
        (with-selected-window w
          (goto-char (point-min)) (forward-line 100)
          (set-window-start w (point)) (set-window-point w (point)))
        (redisplay t)
        (drgnx-pane-show 'g-problems)
        (redisplay t)
        (with-current-buffer term
          (goto-char (point-min))
          (dotimes (i 50) (insert (format "new %d\n" i))))
        (let ((w2 (drgnx-pane-show 'g-term)))
          (redisplay t)
          (should (eq term (window-buffer w2)))
          (with-current-buffer term
            (should (equal "line 100" (save-excursion (goto-char (window-start w2))
                                                      (buffer-substring (line-beginning-position) (line-end-position)))))
            (should (equal "line 100" (save-excursion (goto-char (window-point w2))
                                                      (buffer-substring (line-beginning-position) (line-end-position)))))))))))

(provide 'grid-docks-gui-test)
;;; grid-docks-gui-test.el ends here
