;;; frame-size-helpers-gui-test.el --- GUI tests: the frame size helpers wait for the compositor (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-test-frame-fullscreen' and `drgnx-test-frame-text-size' (test/fixtures/wait-fixture.el) are what every row that
;; resizes the session's root frame stands on.  A compositor can answer a state request after a paint, and a configure
;; can come after a resize took: these rows make both happen and check the helpers do not return on the old size.
;; The late answer is counted in presented frames, not in time: it comes after the Nth `drgnx-uitest-snapshot' (each a
;; trip through the compositor), the samples the helpers wait on.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defvar drgnx-frame-size-helpers-test--late nil
  "(N . FUNCTION) while a row holds back an answer: FUNCTION runs after the Nth presented frame from now.")

(defun drgnx-frame-size-helpers-test--after-sample (&rest _)
  "`drgnx-uitest-snapshot' advice: count a presented frame; run the held-back answer at its count."
  (when drgnx-frame-size-helpers-test--late
    (if (> (car drgnx-frame-size-helpers-test--late) 1)
        (cl-decf (car drgnx-frame-size-helpers-test--late))
      (let ((answer (cdr drgnx-frame-size-helpers-test--late)))
        (setq drgnx-frame-size-helpers-test--late nil)
        (funcall answer)))))

(defmacro drgnx-frame-size-helpers-test--out-of-fullscreen (root &rest body)
  "BODY with ROOT, the session's root frame, out of fullscreen and 100 px smaller each way, the presented-frame counter
on; everything put back after."
  (declare (indent 1))
  `(let* ((,root (drgnx-uitest-root-frame))
          (size (list (frame-text-width ,root) (frame-text-height ,root)))
          (full (frame-parameter ,root 'fullscreen)))
     (skip-unless (display-graphic-p ,root))
     (unwind-protect
         (progn
           (setq full (drgnx-test-frame-fullscreen ,root nil))
           (drgnx-test-frame-text-size ,root (- (car size) 100) (- (cadr size) 100))
           (advice-add 'drgnx-uitest-snapshot :after #'drgnx-frame-size-helpers-test--after-sample)
           ,@body)
       (advice-remove 'drgnx-uitest-snapshot #'drgnx-frame-size-helpers-test--after-sample)
       (setq drgnx-frame-size-helpers-test--late nil)
       (unless (eq full (frame-parameter ,root 'fullscreen))
         (set-frame-size ,root (car size) (cadr size) t)
         (drgnx-test-frame-fullscreen ,root full)))))

(ert-deftest drgnx-ui-frame-size-helpers/back-to-fullscreen-waits-for-a-late-answer ()
  "Going back to fullscreen, answered only after four presented frames: the helper returns with the frame at the size
it had in fullscreen, not on the paints of the old size before the answer (two equal ones end a presented wait)."
  (drgnx-frame-size-helpers-test--out-of-fullscreen root
    (let* ((full-size (gethash root drgnx-test--fullscreen-sizes))
           (drgnx-test-frame-fullscreen-request
            (lambda (frame state)
              (setq drgnx-frame-size-helpers-test--late
                    (cons 4 (lambda () (set-frame-parameter frame 'fullscreen state)))))))
      (should full-size)
      (should-not (equal full-size (list (frame-pixel-width root) (frame-pixel-height root))))   ; premise
      (drgnx-test-frame-fullscreen root 'fullboth)
      (should (equal full-size (list (frame-pixel-width root) (frame-pixel-height root)))))))

(ert-deftest drgnx-ui-frame-size-helpers/a-resize-undone-by-a-late-configure-fails ()
  "A resize that took and is then undone at the next presented frame (a configure answered after it): the helper
fails, naming the size that did not hold, instead of returning on the size it saw for a moment."
  (drgnx-frame-size-helpers-test--out-of-fullscreen root
    (let* ((ow (frame-text-width root)) (oh (frame-text-height root))
           (w (- ow (* 4 (frame-char-width root)))) (h (- oh (* 4 (frame-char-height root)))))
      (setq drgnx-frame-size-helpers-test--late (cons 1 (lambda () (set-frame-size root ow oh t))))
      (let ((err (should-error (drgnx-test-frame-text-size root w h) :type 'ert-test-failed)))
        (should (equal "the frame's text size did not hold" (car-safe (cadr err))))))))

(provide 'frame-size-helpers-gui-test)
;;; frame-size-helpers-gui-test.el ends here
