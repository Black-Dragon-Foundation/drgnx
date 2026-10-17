;;; mod-sticky-test.el --- batch tests: sticky scroll — the scopes scrolled past, in the header after the breadcrumb -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/editor/drgnx-sticky" drgnx-dir) nil t)

(defun drgnx-sticky-test--elisp (n)
  "A buffer text: a defun of N body lines."
  (concat "(defun drgnx-sticky-test-fn ()\n  \"Doc.\"\n"
          (mapconcat (lambda (i) (format "  (message \"line %d\")" i)) (number-sequence 1 n) "\n")
          ")\n"))

(defmacro drgnx-sticky-test--in (text mode &rest body)
  "BODY in a buffer with TEXT in MODE, shown in the selected window."
  (declare (indent 2))
  `(let ((b (generate-new-buffer "sticky-test")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer b)
           (insert ,text)
           (funcall ,mode)
           (goto-char (point-min))
           ,@body)
       (kill-buffer b))))

(defun drgnx-sticky-test--start-at-line (n)
  (set-window-start (selected-window) (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point))))

(ert-deftest drgnx-sticky/the-enclosing-function-sticks ()
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
    (drgnx-sticky-test--start-at-line 20)
    (should (string-search "(defun drgnx-sticky-test-fn" (drgnx-sticky--segment (selected-window))))))

(ert-deftest drgnx-sticky/no-header-at-the-top ()
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
    (drgnx-sticky-test--start-at-line 1)                     ; the defun's own first line is on screen
    (should (equal (drgnx-sticky--segment (selected-window)) ""))))

(ert-deftest drgnx-sticky/indentation-scopes-outermost-first ()
  ;; Python without tree-sitter: a class, a method, a nested function, by indentation
  (drgnx-sticky-test--in (concat "class Shape:\n    \"\"\"A shape.\"\"\"\n\n    def area(self):\n        def inner(x):\n"
                                 (mapconcat (lambda (i) (format "            y%d = x + %d" i i)) (number-sequence 1 30) "\n")
                                 "\n            return x\n        return inner(1)\n")
      #'python-mode
    (drgnx-sticky-test--start-at-line 15)
    (let ((s (drgnx-sticky--segment (selected-window))))
      (should (string-match-p "class Shape:.*def area(self):.*def inner(x):" s)))))

(ert-deftest drgnx-sticky/at-most-three-and-one-line ()
  (drgnx-sticky-test--in (concat "a:\n  b:\n    c:\n      d:\n        e:\n"
                                 (mapconcat (lambda (i) (format "          k%d: v\n" i)) (number-sequence 1 30) ""))
      #'prog-mode
    (drgnx-sticky-test--start-at-line 20)
    (let ((s (drgnx-sticky--segment (selected-window))))
      (should-not (string-search "\n" s))
      (should (= 3 (length (split-string s " › " t "[ ]+")))))))

(ert-deftest drgnx-sticky/the-header-follows-the-mode ()
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
    (drgnx-sticky-mode 1)
    (should (local-variable-p 'drgnx-chrome-header-tail))
    (drgnx-sticky-mode -1)
    (should-not (local-variable-p 'drgnx-chrome-header-tail))))

(ert-deftest drgnx-sticky/a-scroll-step-is-cheap ()
  ;; a 10k-line file: each new window start costs < 2 ms on average
  (drgnx-sticky-test--in (mapconcat (lambda (i) (drgnx-sticky-test--elisp 48)) (number-sequence 1 200) "") #'emacs-lisp-mode
    (let ((t0 (float-time)))
      (dotimes (i 200)
        (drgnx-sticky-test--start-at-line (+ 10 (* i 50)))
        (drgnx-sticky--segment (selected-window)))
      (should (< (/ (- (float-time) t0) 200) 0.002)))))

(ert-deftest drgnx-sticky/string-lines-are-no-scopes ()
  ;; a docstring's second line starts at column 0: not a scope (the GUI test found it)
  (drgnx-sticky-test--in (concat "(defun drgnx-sticky-test-doc (id)\n  \"Move job ID on: tasks are free again.\nThe job is done when every task is.\"\n"
                                 "  (when id\n    (let ((x 1))\n"
                                 (mapconcat (lambda (i) (format "      (message \"%d\")" i)) (number-sequence 1 30) "\n")
                                 ")))\n")
      #'emacs-lisp-mode
    (drgnx-sticky-test--start-at-line 20)
    (let ((s (drgnx-sticky--segment (selected-window))))
      (should (string-search "(defun drgnx-sticky-test-doc" s))
      (should-not (string-search "The job is done" s)))))

;;; mod-sticky-test.el ends here
