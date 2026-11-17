;;; agent-cursors-test.el --- batch tests: agent cursors (modules/ui/drgnx-agent-cursors.el) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-agent-cursors" drgnx-dir) nil t)

(defmacro agent-cursors-test--glitnir (on &rest body)
  "BODY with Glitnir reported present (ON non-nil) or absent."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'drgnx-agent-cursors--glitnir-p) (lambda () ,on))) ,@body))

(defmacro agent-cursors-test--cursors (&rest body)
  "BODY in a temp buffer of 20 characters, on the virtual clock, with no cursors left over."
  (declare (indent 0))
  `(let ((drgnx-agent-cursors--cursors (make-hash-table :test #'equal)))
     (drgnx-test-with-clock ()
       (with-temp-buffer
         (insert (make-string 20 ?x))
         (unwind-protect (progn ,@body)
           (dolist (k (hash-table-keys drgnx-agent-cursors--cursors))
             (drgnx-agent-cursor-remove (car k) (cdr k))))))))

(ert-deftest drgnx-agent-cursors/face-bar-when-unboxed ()
  (agent-cursors-test--glitnir t
    (agent-cursors-test--cursors
      (let* ((ov (drgnx-agent-cursor-put (current-buffer) 'claude 5 "#123456" "Claude"))
             (face (overlay-get ov 'face)) (box (plist-get face :box)))
        (should (equal '(top right bottom) (plist-get box :open)))
        (should (equal '(-2 . -1) (plist-get box :line-width)))
        (should (equal "#123456" (plist-get face :background)))
        (should (equal "Claude" (plist-get box :label)))        ; the tag shows after a put
        (should (equal '(5 . 6) (cons (overlay-start ov) (overlay-end ov))))
        (drgnx-test-advance 2.1)
        (should-not (plist-get (plist-get (overlay-get ov 'face) :box) :label))))))

(ert-deftest drgnx-agent-cursors/face-restates-neighbour-box ()
  (agent-cursors-test--glitnir t
    (agent-cursors-test--cursors
      (put-text-property 3 9 'face '(:box (:line-width 1 :corner-radius 8 :open (top bottom))))
      (let* ((ov (drgnx-agent-cursor-put (current-buffer) 'claude 5 "#123456" "Claude"))
             (box (plist-get (overlay-get ov 'face) :box)))
        (should (equal '(top bottom) (plist-get box :open)))   ; the card's own sides, not the bar's
        (should (equal 8 (plist-get box :corner-radius)))
        (should (equal "Claude" (plist-get box :label)))
        (should (equal "#123456" (plist-get (overlay-get ov 'face) :background)))
        ;; touching the card (pos 9 is just past it) counts too
        (let ((box2 (plist-get (overlay-get (drgnx-agent-cursor-put (current-buffer) 'b 9 "#654321" "B") 'face) :box)))
          (should (equal 8 (plist-get box2 :corner-radius))))))))

(ert-deftest drgnx-agent-cursors/moves-batch-to-50ms ()
  (agent-cursors-test--glitnir t
    (agent-cursors-test--cursors
      (let* ((ov (drgnx-agent-cursor-put (current-buffer) 'claude 1 "#123456" "Claude")) (moves 0))
        (advice-add 'move-overlay :before (lambda (&rest _) (cl-incf moves)) '((name . cursor-count)))
        (unwind-protect
            (progn
              (dotimes (i 19) (drgnx-agent-cursor-move (current-buffer) 'claude (+ 2 i)))
              (drgnx-test-advance 0.01)
              (should (= 0 moves))
              (drgnx-test-advance 0.05)
              (should (= 1 moves))
              (should (= 20 (overlay-start ov))))
          (advice-remove 'move-overlay 'cursor-count))))))

(ert-deftest drgnx-agent-cursors/label-drops-after-2s ()
  (agent-cursors-test--glitnir t
    (agent-cursors-test--cursors
      (let ((ov (drgnx-agent-cursor-put (current-buffer) 'claude 1 "#123456" "Claude")))
        (drgnx-test-advance 2.5)
        (should-not (plist-get (plist-get (overlay-get ov 'face) :box) :label))
        (drgnx-agent-cursor-move (current-buffer) 'claude 7)
        (drgnx-test-advance 0.06)
        (should (equal "Claude" (plist-get (plist-get (overlay-get ov 'face) :box) :label)))
        (should (equal "Claude" (plist-get (plist-get (overlay-get ov 'mouse-face) :box) :label)))
        (drgnx-test-advance 1.5)
        (should (equal "Claude" (plist-get (plist-get (overlay-get ov 'face) :box) :label)))
        (drgnx-test-advance 0.6)
        (should-not (plist-get (plist-get (overlay-get ov 'face) :box) :label))))))

(ert-deftest drgnx-agent-cursors/move-now-moves-without-the-flush ()
  (agent-cursors-test--glitnir t
    (agent-cursors-test--cursors
      (let* ((ov (drgnx-agent-cursor-put (current-buffer) 'claude 1 "#123456" "Claude")) (moves 0))
        (advice-add 'move-overlay :before (lambda (&rest _) (cl-incf moves)) '((name . cursor-count)))
        (unwind-protect
            (progn
              (drgnx-agent-cursor-move-now (current-buffer) 'claude 9)
              ;; at once, with no timer: the same overlay, one move, and the tag shows for 2 s
              (should (= 9 (overlay-start ov)))
              (should (= 1 moves))
              (should (eq ov (drgnx-agent-cursor-overlay (current-buffer) 'claude)))
              (should (numberp (drgnx-agent-cursor-label-state (current-buffer) 'claude)))
              (drgnx-test-advance 0.1)
              (should (= 1 moves))
              (drgnx-test-advance 2.5)
              (should-not (drgnx-agent-cursor-label-state (current-buffer) 'claude)))
          (advice-remove 'move-overlay 'cursor-count))))))

(ert-deftest drgnx-agent-cursors/plain-without-glitnir ()
  (agent-cursors-test--glitnir nil
    (agent-cursors-test--cursors
      (let ((ov (drgnx-agent-cursor-put (current-buffer) 'claude 5 "#123456" "Claude")))
        (should-not (plist-member (overlay-get ov 'face) :box))))))

;;; agent-cursors-test.el ends here
