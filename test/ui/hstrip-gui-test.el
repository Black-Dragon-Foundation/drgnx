;;; hstrip-gui-test.el --- GUI test: the horizontal strip on an editor that cuts its lines (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Task 21f (design 2026-11-18 §3.1): with the minimap module on, an editor that cuts its lines gets Nidhogg's
;; horizontal strip along the bottom of the text while a line is wider than the window; one that wraps does not;
;; Shift-wheel scrolls it sideways through the module's own binding, and the strip's thumb follows.

(require 'ert)
(require 'cl-lib)

(defconst drgnx-ui-hstrip--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb" "modules/editor"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-hstrip--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-hstrip--repo))
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-ui-hstrip--repo) nil t)
(require 'drgnx-ruler)
(require 'drgnx-pkg)   ; the module's setup loads it: its hook default is loaded here, before the census

(defvar drgnx-minimap-hstrip)
(declare-function drgnx-minimap--hub-p "drgnx-minimap")

(defmacro drgnx-ui-hstrip--with (&rest body)
  "BODY with the minimap module set up (torn down after), in the selected window W showing BUF: a text buffer whose
line 1 is 400 characters, lines cut; no hub."
  (declare (indent 0))
  `(let ((w (selected-window)) (buf (generate-new-buffer "hstrip-gui")))
     (skip-unless (fboundp 'glitnir-hstrip-state))
     (unwind-protect
         (drgnx-test-with-modules '(editor/minimap)
           (cl-letf (((symbol-function 'drgnx-minimap--hub-p) (lambda () nil)))
             (save-window-excursion
               (delete-other-windows)
               (switch-to-buffer buf)
               (insert (make-string 400 ?x) "\n")
               (dotimes (i 30) (insert (format "line %d\n" i)))
               (text-mode)
               (setq truncate-lines t)
               (goto-char (point-min))
               (set-window-hscroll w 0)
               (drgnx-ruler--place w)
               (redisplay t)
               ,@body)))
       (kill-buffer buf))))

(defun drgnx-ui-hstrip--shows-p (w)
  "Whether W's last redisplay drew the strip: it stands for some pixels and has a height."
  (pcase-let ((`(,whole ,height . ,_) (glitnir-hstrip-state w)))
    (and (> whole 0) (> height 0))))

(defun drgnx-ui-hstrip--row (w)
  "The painted device pixels of the strip's middle row across the frame, a string (any pixel format)."
  (pcase-let* ((`(,_ ,height ,bytes) (glitnir-snapshot nil 'raw))
               (`(,_ ,_ ,_ ,bottom) (window-inside-pixel-edges w))
               (y (floor (* (- bottom 6) (frame-scale-factor))))
               (stride (/ (length bytes) height)))
    (substring bytes (* y stride) (* (1+ y) stride))))

(ert-deftest drgnx-ui-hstrip/a-cut-editor-shows-the-strip-and-a-wrapping-one-none ()
  "With `drgnx-minimap-hstrip' on, an editor that cuts a line wider than its window shows the strip; the same editor
wrapping its lines shows none, and neither does the setting off."
  (skip-unless (display-graphic-p))
  (drgnx-ui-hstrip--with
    (should (window-parameter w 'glitnir-hstrip))
    (should (drgnx-ui-hstrip--shows-p w))
    ;; wrapped: nothing is cut, no strip
    (setq truncate-lines nil)
    (drgnx-ruler--place w)
    (redisplay t)
    (should-not (drgnx-ui-hstrip--shows-p w))
    ;; cut again, the setting off: no spec, no strip
    (setq truncate-lines t)
    (let ((drgnx-minimap-hstrip nil))
      (drgnx-ruler--place w)
      (redisplay t)
      (should-not (window-parameter w 'glitnir-hstrip))
      (should-not (drgnx-ui-hstrip--shows-p w)))))

(ert-deftest drgnx-ui-hstrip/shift-wheel-scrolls-and-the-thumb-follows ()
  "Shift-wheel over a cut editor, through the module's global binding, scrolls it sideways (down and up) and the
strip's painted thumb moves with each scroll."
  (skip-unless (display-graphic-p))
  (drgnx-ui-hstrip--with
    (set-window-hscroll w 40)
    (redisplay t)
    (should (drgnx-ui-hstrip--shows-p w))
    (let ((before (drgnx-ui-hstrip--row w))
          (posn (posn-at-point (window-start w) w)))
      (dolist (key '(S-wheel-down S-wheel-up))
        (let ((hs (window-hscroll w)) (event (list key posn)) (cmd (key-binding (vector key))))
          (should (eq cmd 'drgnx-hscroll-wheel))
          (setq last-input-event event)
          (call-interactively cmd nil (vector event))
          (redisplay t)
          (should (/= (window-hscroll w) hs))
          (should (drgnx-ui-hstrip--shows-p w))
          (should-not (equal (drgnx-ui-hstrip--row w) before))
          (setq before (drgnx-ui-hstrip--row w)))))))

(provide 'hstrip-gui-test)
;;; hstrip-gui-test.el ends here
