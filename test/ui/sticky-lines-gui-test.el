;;; sticky-lines-gui-test.el --- GUI test: sticky lines and a shown pin in a card over the window (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Design F6/X5: the card is a child frame over the window's top rows.  The text under it does not move (no reflow),
;; the card stays put through a scroll, and its window is left out of the ruler and the minimap.

(require 'ert)
(require 'cl-lib)
(require 'seq)

(defconst drgnx-ui-sticky--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb" "modules/editor"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-sticky--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-sticky--repo))
(require 'drgnx-sticky)

(defun drgnx-ui-sticky--line (n)
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))

(defun drgnx-ui-sticky--y (pos)
  "POS's row top in the selected window, pixels."
  (cdr (posn-x-y (posn-at-point pos))))

(ert-deftest drgnx-ui-sticky-lines/a-card-over-the-top-rows-never-moves-the-text ()
  (skip-unless (display-graphic-p))
  (let ((b (generate-new-buffer "sticky-lines-gui")) (w (selected-window)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer b)
          (insert "(defun drgnx-ui-sticky-fn ()\n  \"Doc.\"\n  (let ((x 1))\n")
          (dotimes (i 200) (insert (format "    (message \"line %d\")\n" i)))
          (insert "    x))\n")
          (emacs-lisp-mode)
          (set-window-start w (drgnx-ui-sticky--line 40))
          (goto-char (drgnx-ui-sticky--line 60))
          (redisplay t)
          (let ((start (window-start w)) (y (drgnx-ui-sticky--y (drgnx-ui-sticky--line 45))))
            ;; a shown pin keeps the card: the header's scopes do not replace it
            (setq drgnx-sticky--pin-shown (list (cons w 'test)))
            (drgnx-sticky--fill w (list (drgnx-ui-sticky--line 1) (drgnx-ui-sticky--line 3)))
            (redisplay t)
            (let* ((card (cdr (assq w drgnx-sticky--cards))) (frame (aref card 0)) (edges (window-inside-pixel-edges w)))
              (should (frame-visible-p frame))
              (should (eq (frame-parent frame) (window-frame w)))
              (should (window-parameter (frame-root-window frame) 'drgnx-minimap-exclude))
              (should (equal (frame-position frame) (cons (nth 0 edges) (nth 1 edges))))
              (should (= (frame-pixel-width frame) (- (nth 2 edges) (nth 0 edges))))
              (should (equal (with-current-buffer (aref card 1) (buffer-substring-no-properties (point-min) (point-max)))
                             "1 (defun drgnx-ui-sticky-fn ()\n3   (let ((x 1))"))
              ;; no reflow: the window's start, and a row's place under the card, are as before
              (should (= (window-start w) start))
              (should (= (drgnx-ui-sticky--y (drgnx-ui-sticky--line 45)) y))
              ;; a scroll: the card stays where it is, with the same lines
              (scroll-up 10)
              (redisplay t)
              (should (frame-visible-p frame))
              (should (equal (frame-position frame) (cons (nth 0 edges) (nth 1 edges))))
              (should (equal (aref card 2) (list (drgnx-ui-sticky--line 1) (drgnx-ui-sticky--line 3)))))))
      (drgnx-sticky--hide-all t)
      (kill-buffer b))))

(ert-deftest drgnx-ui-sticky-lines/the-card-leaves-the-minimap-in-sight ()
  (skip-unless (display-graphic-p))
  (let ((b (generate-new-buffer "sticky-lines-minimap")) (w (selected-window)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer b)
          (insert "(defun f ()\n  1)\n")
          (set-window-parameter w 'glitnir-minimap '(:width 100))
          (redisplay t)
          (drgnx-sticky--fill w (list (point-min)))
          (redisplay t)
          (let ((frame (aref (cdr (assq w drgnx-sticky--cards)) 0)) (edges (window-inside-pixel-edges w)))
            (should (frame-visible-p frame))
            (should (= (+ (car (frame-position frame)) (frame-pixel-width frame))
                       (- (nth 2 edges) (drgnx-px 100 (window-frame w)))))))
      (set-window-parameter w 'glitnir-minimap nil)
      (drgnx-sticky--hide-all t)
      (kill-buffer b))))

(ert-deftest drgnx-ui-sticky-lines/a-window-gets-its-hidden-card-in-the-lines-style-and-it-goes-with-the-window ()
  (skip-unless (display-graphic-p))
  (let ((b (generate-new-buffer "sticky-lines-premake")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((drgnx-sticky-style 'lines) (w (split-window)))
            (with-current-buffer b (insert "(defun f ()\n  1)\n") (emacs-lisp-mode) (drgnx-sticky-mode 1))
            (set-window-buffer w b)
            (drgnx-sticky--resized (window-frame w))             ; the window change's subscriber
            (let ((card (cdr (assq w drgnx-sticky--cards))))
              (should card)
              (should (frame-live-p (aref card 0)))
              (should-not (frame-visible-p (aref card 0)))
              (should-not (aref card 2))
              (delete-window w)
              (drgnx-sticky--resized (selected-frame))
              (should-not (assq w drgnx-sticky--cards))
              (should-not (frame-live-p (aref card 0)))
              (should-not (buffer-live-p (aref card 1))))))
      (drgnx-sticky--hide-all t)
      (kill-buffer b))))

;;; sticky-lines-gui-test.el ends here
