;;; core-palette-test.el --- batch tests: the command palette -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-palette)

(defvar drgnx-test--palette-ran nil)
(defun drgnx-test--palette-cmd () (interactive) (setq drgnx-test--palette-ran t))

(ert-deftest drgnx-palette/candidates-and-run ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-commands-problems nil) (drgnx-test--palette-ran nil))
    (drgnx-command-define 'p :title "Do It" :category "Test" :command #'drgnx-test--palette-cmd)
    (drgnx-command-define 'gone :title "Gone" :category "Test" :command 'drgnx-test--missing)
    (should (equal (mapcar #'car (drgnx-palette-candidates)) '("Test: Do It")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Test: Do It")))
      (drgnx-palette))
    (should drgnx-test--palette-ran)))
