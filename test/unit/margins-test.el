;;; margins-test.el --- batch tests: one owner of the window margins -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-margins)

(defmacro margins-test--with (&rest body)
  "BODY in a fresh buffer shown in the selected window (wide enough to centre), everything taken back after."
  (declare (indent 0))
  `(let ((b (generate-new-buffer " margins")) (w (selected-window)) (was (window-buffer (selected-window))))
     (unwind-protect
         (progn (set-window-buffer w b) (with-current-buffer b ,@body))
       (drgnx-margins-centre w nil)
       (set-window-buffer w was)
       (kill-buffer b)
       (drgnx-margins--watch))))

(ert-deftest drgnx-margins/claims-sum-in-order ()
  (margins-test--with
    (drgnx-margins-claim 'hunks 1 :order 2)
    (drgnx-margins-claim 'debug 2 :order 0)
    (drgnx-margins-claim 'agents 1 :order 1)
    (should (equal (window-margins w) '(4)))
    (should (equal (mapcar (lambda (o) (drgnx-margins-offset o)) '(debug agents hunks)) '(0 2 3)))
    (should (equal (drgnx-margins-pad 'hunks) "   "))
    (should (= left-margin-width 4))
    (drgnx-margins-claim 'agents nil)
    (should (equal (window-margins w) '(3)))
    (should (= (drgnx-margins-offset 'hunks) 2))
    (should-not (drgnx-margins-offset 'agents))
    (drgnx-margins-claim 'debug 0)
    (drgnx-margins-claim 'hunks nil)
    (should (equal (window-margins w) '(nil)))
    (should-not (local-variable-p 'left-margin-width))))

(ert-deftest drgnx-margins/centring-adds-to-the-claims ()
  (margins-test--with
    (drgnx-margins-claim 'hunks 1)
    (drgnx-margins-centre w 10)
    (should (equal (window-margins w) '(11 . 10)))
    (should (= (drgnx-margins-offset 'hunks) 10))
    ;; zen off keeps the claim
    (drgnx-margins-centre w nil)
    (should (equal (window-margins w) '(1)))
    ;; zen in a window narrower than its width: no centring, the claim stays
    (drgnx-margins-centre w 0)
    (should (equal (window-margins w) '(1)))))

(ert-deftest drgnx-margins/a-window-takes-its-new-buffers-claims ()
  (margins-test--with
    (drgnx-margins-claim 'hunks 1)
    (drgnx-margins-centre w 5)
    (let ((other (generate-new-buffer " other")))
      (unwind-protect
          (progn
            (set-window-buffer w other)
            (drgnx-margins--window-buffer-changed w)
            (should (equal (window-margins w) '(5 . 5)))
            (set-window-buffer w b)
            (drgnx-margins--window-buffer-changed (window-frame w))
            (should (equal (window-margins w) '(6 . 5))))
        (kill-buffer other)))))

(ert-deftest drgnx-margins/owners-are-told-when-places-move ()
  (let* ((told nil) (drgnx-margins-changed-functions (list (lambda (b) (push b told)))))
    (margins-test--with
      (drgnx-margins-claim 'hunks 1)
      (drgnx-margins-centre w 3)
      (should (equal told (list b b))))))

(ert-deftest drgnx-margins/hooks-only-while-needed ()
  (margins-test--with
    (drgnx-margins--watch)
    (should-not (memq #'drgnx-margins--window-buffer-changed window-size-change-functions))
    (drgnx-margins-claim 'hunks 1)
    (should (memq #'drgnx-margins--window-buffer-changed window-size-change-functions))
    (drgnx-margins-claim 'hunks nil)
    (should-not (memq #'drgnx-margins--window-buffer-changed window-buffer-change-functions))))

(ert-deftest drgnx-margins/zen-hunks-and-the-strip-share-the-margin ()
  "The owners on the helper: zen's centring keeps the terminal's marks and the strip, side by side."
  (load (expand-file-name "modules/extra/drgnx-hunks" drgnx-dir) nil t)
  (load (expand-file-name "modules/tools/drgnx-agents-editor-draw" drgnx-dir) nil t)
  (load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)
  (margins-test--with
    (cl-letf (((symbol-function 'drgnx-signal-editor-window-p) (lambda (x) (eq x w)))
              ((symbol-function 'window-total-width) (lambda (&rest _) 120)))
      (let ((drgnx-look-zen-width 100))
        (drgnx-hunks--margin t)
        (drgnx-agents-editor-draw--margin b t)
        (should (equal (window-margins w) '(2)))
        (should (< (drgnx-margins-offset 'agents) (drgnx-margins-offset 'hunks)))
        (drgnx-look--margins t)
        (should (equal (window-margins w) '(12 . 10)))
        (drgnx-look--margins nil)
        (should (equal (window-margins w) '(2)))
        (drgnx-hunks--margin nil)
        (drgnx-agents-editor-draw--margin b nil)
        (should (equal (window-margins w) '(nil)))))))

;;; margins-test.el ends here
