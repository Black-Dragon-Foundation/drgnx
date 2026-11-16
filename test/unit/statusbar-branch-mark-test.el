;;; statusbar-branch-mark-test.el --- the branch segment draws one mark whether or not the git cache has the repository -*- lexical-binding: t -*-
;; test-class: det
;; Audit S3: the status bar's branch mark was the ⑂ glyph at one scale and the Lucide icon at another, by whether the git
;; cache had read the repository yet.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)

(defvar vc-mode)

(ert-deftest drgnx-statusbar-branch/the-fallback-uses-the-same-mark-as-the-cache ()
  (let ((marks nil) (vc-mode " Git-main"))
    (cl-letf (((symbol-function 'drgnx-statusbar--icon) (lambda (icon _glyph &optional _f) (push icon marks) "I"))
              ((symbol-function 'drgnx-statusbar--glyph) (lambda (g) (push g marks) "G"))
              ((symbol-function 'drgnx-statusbar--git-branch) (lambda () nil)))
      (should (equal "I main" (drgnx-statusbar--seg-branch)))
      (should (equal '(git-branch) marks)))
    (setq marks nil)
    (cl-letf (((symbol-function 'drgnx-statusbar--icon) (lambda (icon _glyph &optional _f) (push icon marks) "I"))
              ((symbol-function 'drgnx-statusbar--git-branch) (lambda () (list :head "main"))))
      (should (equal "I main" (drgnx-statusbar--seg-branch)))
      (should (equal '(git-branch) marks)))))
