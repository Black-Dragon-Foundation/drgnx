;;; look-echo-test.el --- the echo area's box: which frames get it, on and off -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): what `drgnx-look-echo-on' and `-off' change in the frame alists and the message functions.
;; The prompts, the box's place and the swap are GUI rows (test/ui/look-echo-gui-test.el).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)

(ert-deftest drgnx-look-echo/only-graphical-frames-get-the-box ()
  "On: each graphical window system's entry asks for a child-frame minibuffer; `default-frame-alist' (which a terminal
frame reads) does not.  Off: both as they were."
  (let ((window-system-default-frame-alist (copy-tree '((x (alpha . 0.9)))))
        (default-frame-alist '((width . 80)))
        (minibuffer-frame-alist (list (cons 'width 80)))
        (resize-mini-frames 'grow-only)
        (drgnx-look-echo--on nil))
    (drgnx-look-echo-on)
    (unwind-protect
        (progn
          (dolist (sys '(x pgtk ns w32))
            (should (eq (alist-get 'minibuffer (alist-get sys window-system-default-frame-alist)) 'child-frame)))
          (should (eql (alist-get 'alpha (alist-get 'x window-system-default-frame-alist)) 0.9))
          (should-not (assq 'minibuffer default-frame-alist))
          (should (eq (alist-get 'visibility minibuffer-frame-alist 'none) nil))
          (should (memq #'drgnx-look-echo--route set-message-functions)))
      (drgnx-look-echo-off))
    (should (equal window-system-default-frame-alist '((x (alpha . 0.9)))))
    (should (equal minibuffer-frame-alist '((width . 80))))
    (should (eq resize-mini-frames 'grow-only))
    (should-not (memq #'drgnx-look-echo--route set-message-functions))
    (should-not (advice-member-p #'drgnx-look-echo--wait 'read-char))))

(ert-deftest drgnx-look-echo/classic-leaves-the-parameter-out ()
  "`classic': applying it turns the box off, so no frame alist asks for it."
  (let ((window-system-default-frame-alist nil) (minibuffer-frame-alist nil) (resize-mini-frames nil)
        (drgnx-look-echo--on nil) (drgnx-look-echo-row 'float))
    (drgnx-look-echo-on)
    (setq drgnx-look-echo-row 'classic)
    (cl-letf (((symbol-function 'drgnx-look-echo-apply-frames) #'ignore))
      (drgnx-look-echo-apply))
    (should-not drgnx-look-echo--on)
    (should-not window-system-default-frame-alist)))

(ert-deftest drgnx-look-echo/a-frame-with-its-own-row-routes-nothing ()
  "A frame with its own minibuffer (a terminal's, or classic): messages are left to Emacs."
  (cl-letf (((symbol-function 'drgnx-look-echo-box) #'ignore))
    (should-not (drgnx-look-echo--route "hello"))))

(provide 'look-echo-test)
;;; look-echo-test.el ends here
