;;; capture-test.el --- GUI tests: screenshots with child frames -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defun drgnx-test--png-size (file)
  (image-size (create-image file 'png nil) t))

(ert-deftest drgnx-ui-capture/root-and-child-frame ()
  (let* ((dir (make-temp-file "drgnx-shot" t))
         (root (drgnx-uitest-root-frame))
         (child (make-frame `((parent-frame . ,root) (left . 200) (top . 150) (width . 30) (height . 5)
                              (minibuffer . nil) (undecorated . t) (visibility . t)))))
    (unwind-protect
        (progn
          (redisplay t) (sit-for 0.3)
          (let ((c (drgnx-uitest-capture dir)))
            (should (file-exists-p (plist-get c :root)))
            (should (equal (drgnx-test--png-size (plist-get c :root))
                           (cons (frame-pixel-width root) (frame-pixel-height root))))
            (should (= (length (plist-get c :children)) 1))
            (let ((k (aref (plist-get c :children) 0)))
              (should (equal (list (plist-get k :x) (plist-get k :y))
                             (seq-take (frame-edges child 'native-edges) 2)))
              (should (file-exists-p (plist-get k :path))))))
      (delete-frame child)
      (delete-directory dir t))))

(ert-deftest drgnx-ui-capture/no-echo-pollution ()
  (let ((dir (make-temp-file "drgnx-shot" t)))
    (message nil)
    (drgnx-uitest-capture dir)
    (should (null (current-message)))
    (delete-directory dir t)))
