;;; editor-line-name-test.el --- the agent line's symbol name: from the outline, cached -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The hub's answer (`search/symbol-at') is stubbed: the ask function records what was asked and the
;; test answers by hand; `add-log-current-defun' is counted.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-chrome)
(load (expand-file-name "modules/editor/drgnx-sticky" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-large-files" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-agents-editor-line--symbol "drgnx-agents-editor-line")
(defvar drgnx-agents-editor-line-ask-function)
(defvar drgnx-view-old-path)

(defmacro editor-line-name-test--with (&rest body)
  "BODY with `buf' visiting a saved file of five lines, `asks' the outline questions asked as (FILE LINE CALLBACK),
and `defuns' the number of `add-log-current-defun' calls (each answers \"local\")."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "editor-line-name" t)) (file (expand-file-name "p.el" dir))
          (asks nil) (defuns 0) (drgnx-view-old-path nil))
     (with-temp-file file (insert "a\nb\nc\nd\ne\n"))
     (let ((buf (find-file-noselect file)))
       (unwind-protect
           (cl-letf (((symbol-function 'add-log-current-defun) (lambda () (cl-incf defuns) "local")))
             (let ((drgnx-agents-editor-line-ask-function
                    (lambda (_root file line cb) (push (list file line cb) asks) t)))
               ,@body))
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf)
         (delete-directory dir t)))))

(defun editor-line-name-test--pos (buf line)
  (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point))))

(ert-deftest drgnx-agents-editor-line/unmodified-asks-the-outline-once-per-line ()
  "A saved buffer asks the hub's outline once per line, never `add-log-current-defun'; the answer is kept."
  (editor-line-name-test--with
    (let ((l2 (editor-line-name-test--pos buf 2)) (l3 (editor-line-name-test--pos buf 3)))
      (dotimes (_ 3) (should-not (drgnx-agents-editor-line--symbol buf l2)))
      (drgnx-agents-editor-line--symbol buf l3)
      (should (equal (mapcar (lambda (a) (list (nth 0 a) (nth 1 a))) (reverse asks)) '(("p.el" 2) ("p.el" 3))))
      (funcall (nth 2 (car (last asks))) "f")
      (should (equal (drgnx-agents-editor-line--symbol buf l2) "f"))
      (should (= (length asks) 2))
      (should (= defuns 0)))))

(ert-deftest drgnx-agents-editor-line/modified-computes-once-per-tick-and-line ()
  "A modified buffer computes the name itself, once per (modification tick, line), and asks the hub nothing."
  (editor-line-name-test--with
    (with-current-buffer buf (goto-char (point-max)) (insert "f\n"))
    (let ((l2 (editor-line-name-test--pos buf 2)) (l3 (editor-line-name-test--pos buf 3)))
      (dotimes (_ 3) (should (equal (drgnx-agents-editor-line--symbol buf l2) "local")))
      (should (= defuns 1))
      (drgnx-agents-editor-line--symbol buf l3)
      (should (= defuns 2))
      (with-current-buffer buf (goto-char (point-max)) (insert "g\n"))
      (drgnx-agents-editor-line--symbol buf l2)
      (should (= defuns 3))
      (should-not asks))))

(ert-deftest drgnx-agents-editor-line/no-add-log-current-defun-per-frame ()
  "Twenty frames on a saved buffer's line call `add-log-current-defun' never; only the old path does, every frame."
  (editor-line-name-test--with
    (let ((drgnx-agents-editor-line-ask-function (lambda (_root _file _line cb) (funcall cb "h") t))
          (l2 (editor-line-name-test--pos buf 2)))
      (dotimes (_ 20) (should (equal (drgnx-agents-editor-line--symbol buf l2) "h")))
      (should (= defuns 0))
      (let ((drgnx-view-old-path t))
        (dotimes (_ 20) (drgnx-agents-editor-line--symbol buf l2)))
      (should (= defuns 20)))))

;;; editor-line-name-test.el ends here
