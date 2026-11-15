;;; frame-borders-gui-test.el --- GUI tests: drgnx's own child frames draw their borders at the pixel rule's widths (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Nidhogg's shells take `child-frame-border-width' and `internal-border-width' in logical pixels and draw them at the
;; display scale, as they take a face's `:box' widths.  Each of drgnx's own child frames (the palette's box, a lane's
;; modal frame, a toast, the debug toolbar's card) is made from its parameters under the root frame with
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

(declare-function drgnx-debug-toolbar--params "drgnx-debug-toolbar" (parent))

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

(provide 'frame-borders-gui-test)
;;; frame-borders-gui-test.el ends here
