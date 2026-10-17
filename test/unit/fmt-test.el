;;; fmt-test.el --- batch tests: drgnx fmt, the Emacs Lisp formatter -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-fmt)

(defmacro drgnx-fmt-test--with (dir &rest body)
  (declare (indent 1))
  `(let ((,dir (file-name-as-directory (make-temp-file "drgnx-fmt" t))))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(defun drgnx-fmt-test--write (file text) (with-temp-file file (insert text)) file)
(defun drgnx-fmt-test--read (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest drgnx-fmt/a-file-is-reindented-trimmed-and-left-alone-the-second-time ()
  (drgnx-fmt-test--with dir
    (let ((f (drgnx-fmt-test--write (concat dir "a.el")
                                    "(defun f (x)\n        (let ((y 1))   \n\t(+ x\n y)))\n\n\n")))
      (should (eq (car (drgnx-fmt-file f)) 'changed))
      (should (equal (drgnx-fmt-test--read f) "(defun f (x)\n  (let ((y 1))\n    (+ x\n       y)))\n"))
      (should (eq (car (drgnx-fmt-file f)) 'same))
      ;; deep enough for a tab: spaces only
      (drgnx-fmt-test--write f "(defun f ()\n(let ((a 1))\n(let ((b 2))\n(list a\nb))))\n")
      (drgnx-fmt-file f)
      (should (equal (drgnx-fmt-test--read f) "(defun f ()\n  (let ((a 1))\n    (let ((b 2))\n      (list a\n            b))))\n")))))

(ert-deftest drgnx-fmt/a-file-that-does-not-read-is-refused-and-untouched ()
  (drgnx-fmt-test--with dir
    (dolist (text '("(defun f ()\n  (list 1 2)\n" "(defun f ()\n \"open string)\n" "(defun f () 1))\n"))
      (let ((f (drgnx-fmt-test--write (concat dir "bad.el") text)))
        (let ((r (drgnx-fmt-file f)))
          (should (eq (car r) 'error))
          (should (string-match-p "bad.el:[0-9]+" (cadr r))))                    ; where
        (should (equal (drgnx-fmt-test--read f) text))))))

(ert-deftest drgnx-fmt/the-project-s-own-macros-indent-as-they-declare ()
  (drgnx-fmt-test--with dir
    (drgnx-fmt-test--write (concat dir "m.el") "(defmacro my-with (spec &rest body)\n  (declare (indent 1))\n  `(progn ,spec ,@body))\n")
    (let ((f (drgnx-fmt-test--write (concat dir "u.el") "(my-with x\n(foo)\n(bar))\n(ert-deftest t1 ()\n(should t))\n")))
      (drgnx-fmt-file f (list dir))
      (should (equal (drgnx-fmt-test--read f) "(my-with x\n  (foo)\n  (bar))\n(ert-deftest t1 ()\n  (should t))\n")))))

(ert-deftest drgnx-fmt/strings-and-comments-keep-their-text ()
  (drgnx-fmt-test--with dir
    (let ((f (drgnx-fmt-test--write (concat dir "s.el")
                                    "(defun f ()\n  \"Doc line one.\n  kept as written.\"\n  (g 1)       ; a trailing comment\n  ;; a comment line\n  (h))\n")))
      (drgnx-fmt-file f)
      (should (equal (drgnx-fmt-test--read f)
                     "(defun f ()\n  \"Doc line one.\n  kept as written.\"\n  (g 1)       ; a trailing comment\n  ;; a comment line\n  (h))\n")))))

(ert-deftest drgnx-fmt/check-mode-reports-without-writing-and-the-cli-exits-accordingly ()
  (drgnx-fmt-test--with dir
    (let* ((text "(defun f ()\n(g))\n") (f (drgnx-fmt-test--write (concat dir "c.el") text)))
      (should (eq (car (drgnx-fmt-file f nil t)) 'changed))
      (should (equal (drgnx-fmt-test--read f) text))                             ; --check writes nothing
      (should (eql (drgnx-fmt-cli-run (list "--check" f)) 1))
      (should (eql (drgnx-fmt-cli-run (list f)) 0))
      (should (eql (drgnx-fmt-cli-run (list "--check" f)) 0))
      (drgnx-fmt-test--write f "(defun f (\n")
      (should (eql (drgnx-fmt-cli-run (list f)) 2)))))                          ; does not read: its own code

;;; fmt-test.el ends here
