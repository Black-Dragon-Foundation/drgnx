;;; look-scale-test.el --- the UI scale: its steps, the zoom commands, the frames it reaches -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the setting's schema and the commands' arithmetic; the frame part through the frame parameter
;; `drgnx-pixels-ui-scale' reads, with Nidhogg's text zoom and the save stubbed.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-pixels)
(load (expand-file-name "modules/ui/drgnx-look-scale" drgnx-dir) nil t)

(defmacro drgnx-look-scale-test--isolated (&rest body)
  "BODY with the save and Nidhogg's text zoom stubbed (ZOOMS collects (FRAME . ZOOM)), then the frame as it was."
  (declare (indent 0))
  `(let ((drgnx-look-scale 100) (zooms nil) (was (frame-parameter nil 'drgnx-ui-scale)))
     (ignore zooms)
     (cl-letf (((symbol-function 'drgnx-settings-defaults-save) (lambda (var value) (set var value)))
               ((symbol-function 'nidhogg-set-frame-text-zoom) (lambda (f z) (push (cons f z) zooms)))
               ((symbol-function 'drgnx-look-scale--roots) (lambda () (list (selected-frame)))))
       (unwind-protect (progn ,@body)
         (set-frame-parameter nil 'drgnx-ui-scale was)))))

(ert-deftest drgnx-look-scale/steps-are-five-percent ()
  "Pattern D: the schema takes 100 to 200 in steps of 5 (103 is refused, 105 taken)."
  (should-not (drgnx-setting-check 'drgnx-look-scale 105))
  (should-not (drgnx-setting-check 'drgnx-look-scale 100))
  (should-not (drgnx-setting-check 'drgnx-look-scale 200))
  (should (drgnx-setting-check 'drgnx-look-scale 103))
  (should (drgnx-setting-check 'drgnx-look-scale 95))
  (should (drgnx-setting-check 'drgnx-look-scale 205))
  (should (drgnx-setting-check 'drgnx-look-scale 1.1)))

(ert-deftest drgnx-look-scale/zoom-in-clamps-at-200 ()
  "Pattern D: Zoom In adds 10 % and stops at 200; Zoom Out takes 10 % and stops at 100."
  (drgnx-look-scale-test--isolated
    (drgnx-look-scale-zoom-in)
    (should (= drgnx-look-scale 110))
    (setq drgnx-look-scale 195)
    (drgnx-look-scale-zoom-in)
    (should (= drgnx-look-scale 200))
    (drgnx-look-scale-zoom-in)
    (should (= drgnx-look-scale 200))
    (setq drgnx-look-scale 105)
    (drgnx-look-scale-zoom-out)
    (should (= drgnx-look-scale 100))
    (drgnx-look-scale-zoom-out)
    (should (= drgnx-look-scale 100))))

(ert-deftest drgnx-look-scale/reset-is-100 ()
  "Pattern D: Reset Zoom gives 100 %, and the frame its own sizes (no UI scale, text zoom 1)."
  (drgnx-look-scale-test--isolated
    (drgnx-look-scale-set 150)
    (should (= (drgnx-pixels-ui-scale) 1.5))
    (should (equal (car zooms) (cons (selected-frame) 1.5)))
    (drgnx-look-scale-zoom-reset)
    (should (= drgnx-look-scale 100))
    (should (= (drgnx-pixels-ui-scale) 1.0))
    (should (equal (car zooms) (cons (selected-frame) 1.0)))))

(ert-deftest drgnx-look-scale/ui-scale-multiplies-the-pixels ()
  "Pattern D: at 110 % a 26-pixel row is `drgnx-px' 26 at the display scale times 1.1 (36 at 1.25)."
  (drgnx-look-scale-test--isolated
    (drgnx-look-scale-set 110)
    (should (= (drgnx-pixels-ui-scale) 1.1))
    (cl-letf (((symbol-function 'drgnx-pixels-device-p) #'always)
              ((symbol-function 'frame-scale-factor) (lambda (&optional _) 1.25)))
      (should (= (drgnx-px 26) 36))
      (should (= (drgnx-px 16) 22)))))

(ert-deftest drgnx-look-scale/teardown-restores ()
  "Pattern D: teardown gives every frame text zoom 1 and no UI scale, and the zoom commands their stock behaviour."
  (drgnx-look-scale-test--isolated
    (drgnx-look-scale-set 130)
    (drgnx-look-scale-off)
    (should (= (drgnx-pixels-ui-scale) 1.0))
    (should (equal (car zooms) (cons (selected-frame) 1.0)))
    (should (= drgnx-look-scale 130))))   ; the setting stays: the next setup applies it again

(provide 'look-scale-test)
;;; look-scale-test.el ends here
