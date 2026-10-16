;;; input-test.el --- GUI tests: paced clicks, keys, typing, targets -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defun drgnx-test--lines-buffer ()
  "Show a fresh buffer with 60 numbered lines in a single window; return it."
  (let ((buf (get-buffer-create "*drgnx-lines*")))
    (with-current-buffer buf
      (erase-buffer)
      (dotimes (i 60) (insert (format "line %02d\n" i)))
      (goto-char (point-min)))
    (delete-other-windows)
    (switch-to-buffer buf)
    (redisplay t)
    buf))

(ert-deftest drgnx-ui-input/click-by-pixel-moves-point ()
  (drgnx-test--lines-buffer)
  (let* ((w (selected-window))
         (body (window-body-pixel-edges w))
         (lh (default-line-height))
         (x (+ (nth 0 body) 10))
         (y (+ (nth 1 body) (* 10 lh) (/ lh 2))))
    (should (eq (plist-get (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn x y))) :settled) t))
    (should (equal (buffer-substring (pos-bol) (pos-eol)) "line 10"))))

(ert-deftest drgnx-ui-input/click-by-target ()
  (drgnx-test--lines-buffer)
  (let ((xy (drgnx-uitest-target-xy "*drgnx-lines*" "line 25")))
    (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy))))
    (should (equal (buffer-substring (pos-bol) (pos-eol)) "line 25"))))

(ert-deftest drgnx-ui-input/target-by-major-mode ()
  (drgnx-test--lines-buffer)
  (should (eq (drgnx-uitest-find-window "fundamental-mode") (selected-window))))

(ert-deftest drgnx-ui-input/target-not-visible-errors ()
  (drgnx-test--lines-buffer)
  (should-error (drgnx-uitest-target-xy "*drgnx-lines*" "line 99"))
  (should-error (drgnx-uitest-target-xy "*no-such-buffer*" "x")))

(ert-deftest drgnx-ui-input/keys-and-typing ()
  (with-current-buffer (get-buffer-create "*drgnx-type*") (erase-buffer))
  (delete-other-windows)
  (switch-to-buffer "*drgnx-type*")
  (drgnx-uitest-run (append (drgnx-uitest-type-events "he said \"hi\" ✓")
                            (drgnx-uitest-key-events "C-a C-k")))
  (should (equal (buffer-string) ""))
  (should (equal (current-kill 0) "he said \"hi\" ✓")))
