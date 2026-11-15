;;; frame-borders-gui-test.el --- GUI tests: drgnx's own child frames draw their borders at the pixel rule's widths (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Nidhogg's shells take `child-frame-border-width' and `internal-border-width' in logical pixels and draw them at the
;; display scale, as they take a face's `:box' widths.  Each of drgnx's own child frames (the palette's box, a lane's
;; modal frame, a toast, the debug toolbar's card, the echo box) is made from its parameters under the root frame with
;; a ring in its chrome, and the ring it draws (`frame-child-frame-border-width', device pixels) is the line rule's
;; width of the look's ring (`drgnx-px-line'), never that times the scale again.  Pattern D: the widths are read from
;; the made frame, nothing is timed.  Meaningful at a scale above 1 (`DRGNX_UI_SCALE=2'); the rows skip unless
;; Glitnir draws the frames (the native shell).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-frame-borders--repo        ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-frame-borders--repo)))
(require 'drgnx)
(require 'drgnx-pixels)
(require 'drgnx-palette-frame)
(require 'drgnx-popup)
(require 'drgnx-notice-toast)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-ui-frame-borders--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-echo" drgnx-ui-frame-borders--repo) nil t)

(declare-function drgnx-debug-toolbar--params "drgnx-debug-toolbar" (parent))
(declare-function drgnx-look-echo--params "drgnx-look-echo" ())
(declare-function drgnx-look-echo--place "drgnx-look-echo" (box))

(defmacro drgnx-ui-frame-borders--with-rings (&rest body)
  "BODY with the look's rings set: the palette's (modal) 2 logical px, the popup chrome's 1."
  (declare (indent 0))
  `(progn
     (skip-unless (drgnx-uitest-glitnir-p))
     (cl-letf (((symbol-function 'drgnx-palette-frame--look) (lambda () '((child-frame-border-width . 2))))
               ((symbol-function 'drgnx-look-chrome-current) (lambda (&optional _f) '((child-frame-border-width . 1)))))
       ,@body)))

(defun drgnx-ui-frame-borders--check (params ring)
  "A hidden child frame of the root made from PARAMS draws a ring of RING logical px by the line rule."
  (let* ((root (drgnx-uitest-root-frame))
         (f (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
              (make-frame (append `((parent-frame . ,root) (minibuffer . nil) (visibility . nil)) params)))))
    (unwind-protect
        (should (equal (list :ring (frame-child-frame-border-width f) :scale (frame-scale-factor root))
                       (list :ring (drgnx-px-line ring root) :scale (frame-scale-factor root))))
      (delete-frame f))))

(ert-deftest drgnx-ui-frame-borders/a-border-parameter-reads-back-what-was-set ()
  "A child frame given `child-frame-border-width' 2, and another given `internal-border-width' 3 (no ring), read
those back from `frame-parameter' (the logical px given), and draw them at the scale: the drawn widths are
`frame-child-frame-border-width''s and `frame-internal-border-width''s.  Compare-then-set code (the palette's box,
the cards' edge, posframe) relies on the parameter reading back what it set."
  (skip-unless (drgnx-uitest-glitnir-p))
  (let* ((root (drgnx-uitest-root-frame)) (s (frame-scale-factor root))
         (at (lambda (n) (max 1 (floor (+ (* n s) 0.5)))))
         (make (lambda (params)
                 (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                   (make-frame (append `((parent-frame . ,root) (minibuffer . nil) (visibility . nil)) params)))))
         (ring (funcall make '((child-frame-border-width . 2) (internal-border-width . 0))))
         (pad (funcall make '((internal-border-width . 3)))))
    (unwind-protect
        (should (equal (list :ring (frame-parameter ring 'child-frame-border-width)
                             (frame-child-frame-border-width ring)
                             :pad (frame-parameter pad 'internal-border-width) (frame-internal-border-width pad)
                             :scale s)
                       (list :ring 2 (funcall at 2) :pad 3 (funcall at 3) :scale s)))
      (delete-frame ring)
      (delete-frame pad))))

(ert-deftest drgnx-ui-frame-borders/the-palette-s-box ()
  "The palette's box (`drgnx-palette-frame--params', the modal chrome) draws the look's 2 px ring by the line rule,
and so does the box made and reused by `drgnx-palette-frame--ensure'."
  (drgnx-ui-frame-borders--with-rings
    (let ((root (drgnx-uitest-root-frame)))
      (drgnx-ui-frame-borders--check
       (seq-remove (lambda (p) (eq (car p) 'parent-frame)) (drgnx-palette-frame--params root)) 2)
      (let ((drgnx-palette-frame--frame nil))
        (unwind-protect
            (let ((f (drgnx-palette-frame--ensure root)))
              (should (= (frame-child-frame-border-width f) (drgnx-px-line 2 root)))
              ;; reused: the widths are given again only when they changed
              (should (eq (drgnx-palette-frame--ensure root) f))
              (should (= (frame-child-frame-border-width f) (drgnx-px-line 2 root))))
          (when (frame-live-p drgnx-palette-frame--frame) (delete-frame drgnx-palette-frame--frame)))))))

(ert-deftest drgnx-ui-frame-borders/a-lane-s-modal-frame ()
  "A popup lane's frame dressed modal (`drgnx-popup--float-dress') draws the palette's 2 px ring by the line rule."
  (drgnx-ui-frame-borders--with-rings
    (let* ((root (drgnx-uitest-root-frame))
           (f (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                (make-frame `((parent-frame . ,root) (minibuffer . nil) (visibility . nil)
                              (internal-border-width . 0) (child-frame-border-width . 0))))))
      (unwind-protect
          (progn
            (drgnx-popup--float-dress f t)
            (should (= (frame-child-frame-border-width f) (drgnx-px-line 2 root))))
        (delete-frame f)))))

(ert-deftest drgnx-ui-frame-borders/a-toast ()
  "A toast (`drgnx-notice-toast--params') draws the popup chrome's 1 px ring by the line rule."
  (drgnx-ui-frame-borders--with-rings
    (drgnx-ui-frame-borders--check
     (seq-remove (lambda (p) (eq (car p) 'parent-frame)) (drgnx-notice-toast--params (drgnx-uitest-root-frame))) 1)))

(ert-deftest drgnx-ui-frame-borders/the-debug-toolbar-s-card ()
  "The debug toolbar's card (`drgnx-debug-toolbar--params') draws the popup chrome's 1 px ring by the line rule."
  (drgnx-ui-frame-borders--with-rings
    (drgnx-ui-frame-borders--check
     (seq-remove (lambda (p) (eq (car p) 'parent-frame)) (drgnx-debug-toolbar--params (drgnx-uitest-root-frame))) 1)))

(ert-deftest drgnx-ui-frame-borders/the-echo-box ()
  "The echo box, placed (`drgnx-look-echo--place'), draws the palette's 2 px ring by the line rule, at its parent's
scale."
  (drgnx-ui-frame-borders--with-rings
    (let* ((root (drgnx-uitest-root-frame))
           (box (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                  (make-frame (append `((parent-frame . ,root) (minibuffer . nil)) (drgnx-look-echo--params))))))
      (unwind-protect
          (progn
            (drgnx-look-echo--place box)
            (should (= (frame-child-frame-border-width box) (drgnx-px-line 2 root)))
            ;; at its parent's scale (a box made before its window takes the scale's widths with the scale)
            (should (= (frame-scale-factor box) (frame-scale-factor root)))
            ;; placed again, the ring stays: what the box is given is compared with what it was given
            (drgnx-look-echo--place box)
            (should (= (frame-child-frame-border-width box) (drgnx-px-line 2 root))))
        (delete-frame box)))))

(provide 'frame-borders-gui-test)
;;; frame-borders-gui-test.el ends here
