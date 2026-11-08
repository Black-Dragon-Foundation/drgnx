;;; drgnx-decor-test.el --- batch tests: decoration faces, chips, card rows, agent cursors -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-decor" drgnx-dir) nil t)

(defmacro drgnx-decor-test--glitnir (on &rest body)
  "BODY with Glitnir reported present (ON non-nil) or absent."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'drgnx-decor--glitnir-p) (lambda () ,on))) ,@body))

(defmacro drgnx-decor-test--cursors (&rest body)
  "BODY in a temp buffer of 20 characters, on the virtual clock, with no cursors left over."
  (declare (indent 0))
  `(let ((drgnx-decor--cursors (make-hash-table :test #'equal)))
     (drgnx-test-with-clock ()
       (with-temp-buffer
         (insert (make-string 20 ?x))
         (unwind-protect (progn ,@body)
           (dolist (k (hash-table-keys drgnx-decor--cursors))
             (drgnx-decor-cursor-remove (car k) (cdr k))))))))

(ert-deftest drgnx-decor/card-rows-end-each-row-unboxed ()
  (let ((s (drgnx-decor-card-rows '("a" "b" "c") 10)))
    (should (= 3 (cl-count ?\n s)))
    (dotimes (i (length s))
      (when (eq (aref s i) ?\n)
        (should-not (get-text-property i 'face s))
        (should (get-text-property (1- i) 'face s))))
    (should (eq 'drgnx-card-top (get-text-property 0 'face s)))
    (should (eq 'drgnx-card-mid (get-text-property (string-search "b" s) 'face s)))
    (should (eq 'drgnx-card-bottom (get-text-property (string-search "c" s) 'face s)))
    (should (eq 'drgnx-card-single (get-text-property 0 'face (drgnx-decor-card-rows '("a") 4))))))

(ert-deftest drgnx-decor/card-rows-fill-to-width ()
  (dolist (row (split-string (drgnx-decor-card-rows '("a" "a much longer line than the width") 8) "\n" t))
    (should (= 8 (string-width (substring row 0 -1))))              ; the text, without the stretch
    (should (equal '(space :align-to 9) (get-text-property (1- (length row)) 'display row)))))

(ert-deftest drgnx-decor/chip-has-unboxed-gap ()
  (let ((c (drgnx-decor-chip "ok")))
    (should (equal " " (substring c 0 1)))
    (should-not (get-text-property 0 'face c))
    (should (eq 'drgnx-chip (get-text-property 1 'face c)))
    (should (eq 'drgnx-badge (get-text-property 1 'face (drgnx-decor-chip "ok" 'drgnx-badge))))))

(ert-deftest drgnx-decor/chip-icon-gets-boxed-space ()
  "`.chip': the icon comes first inside the chip's room, 5 px before the text, all in the chip's face."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
    (let* ((icon '(image :type xpm :data "x")) (c (drgnx-decor-chip "ok" nil icon)))
      (should (equal '(space :width (6)) (get-text-property 1 'display c)))
      (should (eq icon (get-text-property 2 'display c)))
      (should (equal '(space :width (5)) (get-text-property 3 'display c)))
      (should (seq-every-p (lambda (i) (eq 'drgnx-chip (get-text-property i 'face c))) (number-sequence 1 (1- (length c)))))
      (should-not (get-text-property 0 'face c)))))

(ert-deftest drgnx-decor/chips-and-buttons-are-the-looks-components ()
  "Design §3.5: a chip is the quiet chip's tint with room inside it (a flat box in its own background: no ring in
the text colour), in the caption role; a button is the look's control (`drgnx-control': its fill and hairline), in
the UI text role, and keeps them under the pointer and pressed (only the fill changes)."
  (let ((box (face-attribute 'drgnx-chip :box nil nil)))
    (should (eq 'flat-button (plist-get box :style)))
    (should-not (plist-get box :color)))
  (should (equal '(drgnx-ui-caption drgnx-chip-quiet) (face-attribute 'drgnx-chip :inherit nil nil)))
  (dolist (face '(drgnx-button drgnx-button-hover drgnx-button-pressed))
    (should (memq 'drgnx-control (ensure-list (face-attribute face :inherit nil nil))))
    (should (eq 'unspecified (face-attribute face :box nil nil)))))

(ert-deftest drgnx-decor/high-contrast-chips-keep-their-ring ()
  "look.css `.t-hc .chip': in high contrast a chip is ringed in its text colour (1 px), in the other variants it is
not; the room inside it is the same in both (6 px stretches either side on a graphical frame, plain spaces on a
terminal, plus the box's 1 px).  Pattern D (the frame's kind is stubbed)."
  (unwind-protect
      (progn
        (load-theme 'drgnx-high-contrast t)
        (dolist (face '(drgnx-chip drgnx-badge))
          (let ((box (face-attribute face :box nil t)))
            (should (equal (list face '(1 . 1)) (list face (plist-get box :line-width))))
            (should-not (plist-get box :style))
            (should-not (plist-get box :color))))
        (disable-theme 'drgnx-high-contrast)
        (load-theme 'drgnx-dark t)
        (should (eq 'flat-button (plist-get (face-attribute 'drgnx-chip :box nil t) :style))))
    (mapc #'disable-theme '(drgnx-high-contrast drgnx-dark)))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
    (let ((chip (drgnx-decor-chip "sandboxed")))
      (should (equal " sandboxed " (substring-no-properties chip 1)))
      (should (equal '(space :width (6)) (get-text-property 1 'display chip)))
      (should (equal '(space :width (6)) (get-text-property (1- (length chip)) 'display chip)))
      (should (eq 'drgnx-chip (get-text-property 1 'face chip)))))
  (let ((chip (drgnx-decor-chip "sandboxed")))
    (should (equal " sandboxed " (substring-no-properties chip 1)))
    (should-not (get-text-property 1 'display chip))))

(ert-deftest drgnx-decor/button-has-hover-face-and-keymap ()
  (let ((b (drgnx-decor-button "Go" #'ignore)))
    (should (eq 'drgnx-button (get-text-property 0 'face b)))
    (should (eq 'drgnx-button-hover (get-text-property 0 'mouse-face b)))
    (should (eq #'drgnx-decor--press (lookup-key (get-text-property 0 'keymap b) [down-mouse-1])))
    (should-not (lookup-key (get-text-property 0 'keymap b) (kbd "RET")))))   ; keys come from the profiles

(ert-deftest drgnx-decor/enter-activates-a-button-in-a-read-only-buffer-under-every-profile ()
  (dolist (profile '(vscode emacs vim))
    (drgnx-test-with-modules '(ui/look)
      (let* ((spec (with-temp-buffer
                     (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                     (goto-char (point-min)) (read (current-buffer))))
             (row (assq 'decor-activate (plist-get spec :bind)))
             (drgnx-keys--applied nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
             (drgnx-keys--session-layers `((,profile app)))
             (drgnx-keys-profiles `((,profile :name "Test" :bind (,row))))
             (ran 0))
        (should row)
        (unwind-protect
            (progn
              (drgnx-keys-apply)
              (with-temp-buffer
                (insert (drgnx-decor-button "Go" (lambda () (cl-incf ran))) " tail")
                (setq buffer-read-only t)
                (goto-char 2)
                (let ((cmd (lookup-key (get-text-property (point) 'keymap) (kbd "RET"))))
                  (should cmd)
                  (call-interactively cmd))
                (should (= 1 ran))
                (goto-char (point-max))
                (call-interactively #'drgnx-decor-activate)   ; off a button: nothing runs
                (should (= 1 ran))))
          (drgnx-keys--restore))))))

(ert-deftest drgnx-decor/cursor-face-bar-when-unboxed ()
  (drgnx-decor-test--glitnir t
    (drgnx-decor-test--cursors
      (let* ((ov (drgnx-decor-cursor-put (current-buffer) 'claude 5 "#123456" "Claude"))
             (face (overlay-get ov 'face)) (box (plist-get face :box)))
        (should (equal '(top right bottom) (plist-get box :open)))
        (should (equal '(-2 . -1) (plist-get box :line-width)))
        (should (equal "#123456" (plist-get face :background)))
        (should (equal "Claude" (plist-get box :label)))        ; the tag shows after a put
        (should (equal '(5 . 6) (cons (overlay-start ov) (overlay-end ov))))
        (drgnx-test-advance 2.1)
        (should-not (plist-get (plist-get (overlay-get ov 'face) :box) :label))))))

(ert-deftest drgnx-decor/cursor-face-restates-neighbour-box ()
  (drgnx-decor-test--glitnir t
    (drgnx-decor-test--cursors
      (put-text-property 3 9 'face '(:box (:line-width 1 :corner-radius 8 :open (top bottom))))
      (let* ((ov (drgnx-decor-cursor-put (current-buffer) 'claude 5 "#123456" "Claude"))
             (box (plist-get (overlay-get ov 'face) :box)))
        (should (equal '(top bottom) (plist-get box :open)))   ; the card's own sides, not the bar's
        (should (equal 8 (plist-get box :corner-radius)))
        (should (equal "Claude" (plist-get box :label)))
        (should (equal "#123456" (plist-get (overlay-get ov 'face) :background)))
        ;; touching the card (pos 9 is just past it) counts too
        (let ((box2 (plist-get (overlay-get (drgnx-decor-cursor-put (current-buffer) 'b 9 "#654321" "B") 'face) :box)))
          (should (equal 8 (plist-get box2 :corner-radius))))))))

(ert-deftest drgnx-decor/cursor-moves-batch-to-50ms ()
  (drgnx-decor-test--glitnir t
    (drgnx-decor-test--cursors
      (let* ((ov (drgnx-decor-cursor-put (current-buffer) 'claude 1 "#123456" "Claude")) (moves 0))
        (advice-add 'move-overlay :before (lambda (&rest _) (cl-incf moves)) '((name . decor-count)))
        (unwind-protect
            (progn
              (dotimes (i 19) (drgnx-decor-cursor-move (current-buffer) 'claude (+ 2 i)))
              (drgnx-test-advance 0.01)
              (should (= 0 moves))
              (drgnx-test-advance 0.05)
              (should (= 1 moves))
              (should (= 20 (overlay-start ov))))
          (advice-remove 'move-overlay 'decor-count))))))

(ert-deftest drgnx-decor/cursor-label-drops-after-2s ()
  (drgnx-decor-test--glitnir t
    (drgnx-decor-test--cursors
      (let ((ov (drgnx-decor-cursor-put (current-buffer) 'claude 1 "#123456" "Claude")))
        (drgnx-test-advance 2.5)
        (should-not (plist-get (plist-get (overlay-get ov 'face) :box) :label))
        (drgnx-decor-cursor-move (current-buffer) 'claude 7)
        (drgnx-test-advance 0.06)
        (should (equal "Claude" (plist-get (plist-get (overlay-get ov 'face) :box) :label)))
        (should (equal "Claude" (plist-get (plist-get (overlay-get ov 'mouse-face) :box) :label)))
        (drgnx-test-advance 1.5)
        (should (equal "Claude" (plist-get (plist-get (overlay-get ov 'face) :box) :label)))
        (drgnx-test-advance 0.6)
        (should-not (plist-get (plist-get (overlay-get ov 'face) :box) :label))))))

(ert-deftest drgnx-decor/faces-plain-without-glitnir ()
  (drgnx-decor-test--glitnir nil
    (dolist (entry drgnx-decor--boxes)
      (let ((box (drgnx-decor-box (car entry))))
        (should-not (plist-member box :corner-radius))
        (should-not (plist-member box :open))
        (should-not (plist-member box :label))))
    (drgnx-decor-test--cursors
      (let ((ov (drgnx-decor-cursor-put (current-buffer) 'claude 5 "#123456" "Claude")))
        (should-not (plist-member (overlay-get ov 'face) :box)))))
  (drgnx-decor-test--glitnir t
    (should (equal 99 (plist-get (drgnx-decor-box 'drgnx-badge) :corner-radius)))
    (should (equal '(bottom) (plist-get (drgnx-decor-box 'drgnx-card-top) :open))))
  ;; the loaded faces carry no Glitnir key on stock Emacs
  (dolist (entry drgnx-decor--boxes)
    (should-not (plist-member (face-attribute (car entry) :box nil t) :corner-radius))))

(ert-deftest drgnx-decor/cursor-move-now-moves-without-the-flush ()
  (drgnx-decor-test--glitnir t
    (drgnx-decor-test--cursors
      (let* ((ov (drgnx-decor-cursor-put (current-buffer) 'claude 1 "#123456" "Claude")) (moves 0))
        (advice-add 'move-overlay :before (lambda (&rest _) (cl-incf moves)) '((name . decor-count)))
        (unwind-protect
            (progn
              (drgnx-decor-cursor-move-now (current-buffer) 'claude 9)
              ;; at once, with no timer: the same overlay, one move, and the tag shows for 2 s
              (should (= 9 (overlay-start ov)))
              (should (= 1 moves))
              (should (eq ov (drgnx-decor-cursor-overlay (current-buffer) 'claude)))
              (should (numberp (drgnx-decor-cursor-label-state (current-buffer) 'claude)))
              (drgnx-test-advance 0.1)
              (should (= 1 moves))
              (drgnx-test-advance 2.5)
              (should-not (drgnx-decor-cursor-label-state (current-buffer) 'claude)))
          (advice-remove 'move-overlay 'decor-count))))))
