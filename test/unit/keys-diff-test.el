;;; keys-diff-test.el --- batch tests: the key-sheet diff against gryphn -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-keys-diff)
(require 'drgnx-paths)

(ert-deftest drgnx-keys-diff/reads-gryphn-sheets-without-running-them ()
  (let ((dir (make-temp-file "drgnx-gryphn" t)))
    (unwind-protect
        (progn
          (write-region "(error \"never run\")\n(gryphn-command-define 'kx-a :title \"A\" :category \"X\" :command #'ignore :key \"<f5>\")\n(dolist (x '(1)) (gryphn-command-define 'kx-b :title \"B\" :category \"X\" :command #'ignore))\n`(gryphn-command-define ',id)\n"
                        nil (expand-file-name "gryphn-x.el" dir) nil 'silent)
          (should (equal (mapcar (lambda (r) (list (car r) (nth 2 r))) (drgnx-keys-diff-gryphn-sheet dir))
                         '((kx-a "<f5>") (kx-b nil)))))
      (delete-directory dir t))))

(ert-deftest drgnx-keys-diff/nothing-unexplained-against-the-real-gryphn ()
  ;; The M4 exit: every gryphn command is in drgnx with gryphn's key, or explained.
  (let ((dir (expand-file-name "~/workspace/gryphn/emacs")))
    (skip-unless (file-directory-p dir))
    ;; In its own Emacs: the diff runs every module and loads gryphn's files.
    (let ((out (with-temp-buffer
                 (list (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil t nil "keys" "diff" "--against" "gryphn" dir)
                       (buffer-string)))))
      (should (equal (list (car out) (car (last (split-string (cadr out) "\n" t))))
                     (list 0 (car (last (split-string (cadr out) "\n" t))))))
      (should (string-match-p " 0 unexplained" (cadr out))))))
