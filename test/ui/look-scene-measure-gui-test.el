;;; look-scene-measure-gui-test.el --- GUI tests: the look scenes measure a row as drawn (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every width is read after `drgnx-test-wait-presented'.  The scenes' width check
;; (harness/drgnx-look-scenes-session.el) measures the hub's rows with `window-text-pixel-size' from a row's start.  A
;; row right after a hidden line (the Explorer's hidden root row: its text and newline invisible) starts mid screen
;; line, and `window-text-pixel-size' from there leaves out an image at the start: the window-dark scene at scale 2
;; counted the first folder's row 32 px short and called the hub's right cut of its name a needless one.

(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-scene-measure--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-scene-measure--repo)))
(require 'drgnx)
(require 'drgnx-view)
(load (expand-file-name "harness/drgnx-look-scenes-session" drgnx-ui-look-scene-measure--repo) nil t)

(declare-function drgnx-look-scene--row-parts "drgnx-look-scenes-session" (window bol eol))
(declare-function drgnx-look-scene--free-after "drgnx-look-scenes-session" (window bol pos eol))

(defconst drgnx-ui-look-scene-measure--svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\"/></svg>"
  "A 32 px image, made at the size it is drawn (`:scale' 1), as the hub's icons are.")

(ert-deftest drgnx-ui-look-scene-measure/a-row-after-a-hidden-line-is-measured-as-drawn ()
  "A row whose line follows a hidden one (text and newline invisible) and starts with an image: its parts and the px
free after it are measured with the image, as drawn."
  (skip-unless (image-type-available-p 'svg))
  (let ((buf (get-buffer-create " *look-scene-measure*")))
    (drgnx-uitest-bare-frame)
    (delete-other-windows)
    (unwind-protect
        (let (bol eol)
          (with-current-buffer buf
            (erase-buffer)
            (insert (propertize "root\n" 'invisible t))
            (setq bol (point))
            (insert (propertize " " 'display (create-image drgnx-ui-look-scene-measure--svg 'svg t :scale 1))
                    "name")
            (setq eol (point))
            (insert "\n")
            (setq-local cursor-type nil)
            (goto-char (point-min)))
          (set-window-buffer (selected-window) buf)
          (drgnx-test-wait-presented)
          (let* ((w (selected-window))
                 (image-px (car (image-size (get-text-property bol 'display buf) t)))
                 (name-px (with-current-buffer buf (car (window-text-pixel-size w (1+ bol) eol))))
                 (drawn (- (car (posn-x-y (posn-at-point eol w))) (car (posn-x-y (posn-at-point bol w))))))
            (should (= image-px 32))
            (should (= drawn (+ image-px name-px)))
            (with-current-buffer buf
              (should (equal (mapcar (lambda (p) (nth 2 p)) (drgnx-look-scene--row-parts w bol eol))
                             (list (+ image-px name-px))))
              (should (= (drgnx-look-scene--free-after w bol eol eol)
                         (- (window-body-width w t) drawn))))))
      (kill-buffer buf))))

;;; look-scene-measure-gui-test.el ends here
