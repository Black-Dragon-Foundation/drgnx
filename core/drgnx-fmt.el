;;; drgnx-fmt.el --- drgnx fmt: the Emacs Lisp formatter -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx fmt [--check] [FILE…]' formats drgnx's Emacs Lisp the way Emacs indents it: it first learns how
;; drgnx's own macros indent (their `(declare (indent N))'), refuses a file that does not read (an unbalanced
;; parenthesis, an open string) and leaves it untouched, then reindents with spaces, trims trailing whitespace
;; and ends the file with one newline.  Text inside strings and comments is kept.  The pre-commit hook and a
;; unit test hold the whole tree to it.  See docs/develop/formatting.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
;; the libraries drgnx's code uses: their macros carry their own indentation
(dolist (lib '(pcase ert svg dom sqlite map rx project)) (require lib nil t))

(defconst drgnx-fmt-dirs '("core" "wb" "modules" "harness" "test" "init")
  "Where drgnx's Emacs Lisp lives (relative to `drgnx-dir').")

(defconst drgnx-fmt-data-dirs '("test/fixtures/huginn/corpus/")
  "Folders of .el files that are data, not code (huginn's corpus: cases the reader reads or refuses), never formatted.")

(defun drgnx-fmt-files ()
  "Every Emacs Lisp file of drgnx, except the data in `drgnx-fmt-data-dirs'."
  (let ((data (mapcar (lambda (d) (expand-file-name d drgnx-dir)) drgnx-fmt-data-dirs)))
    (seq-remove (lambda (f) (seq-some (lambda (d) (string-prefix-p d f)) data))
                (seq-mapcat (lambda (d) (let ((dir (expand-file-name d drgnx-dir)))
                                          (and (file-directory-p dir) (directory-files-recursively dir "\\.el\\'"))))
                            drgnx-fmt-dirs))))

;;;; How macros indent

(defun drgnx-fmt--learn-form (form)
  "Note how FORM's macros and functions want to be indented."
  (pcase form
    (`(,(or 'defmacro 'cl-defmacro 'defun 'cl-defun 'defsubst) ,(and name (pred symbolp)) ,_ . ,body)
     (dolist (b (seq-take body 2))                       ; (declare …) comes first, or after the docstring
       (when-let* (((eq (car-safe b) 'declare)) (i (assq 'indent (cdr b))))
         (put name 'lisp-indent-function (cadr i)))))
    (`(,(or 'put 'function-put) (quote ,(and name (pred symbolp))) (quote lisp-indent-function) ,n)
     (put name 'lisp-indent-function n))
    (`(,(or 'progn 'eval-and-compile 'eval-when-compile) . ,forms) (mapc #'drgnx-fmt--learn-form forms))))

(defvar drgnx-fmt--learned nil "The directories whose macros are known already.")

(defun drgnx-fmt--learn (dirs)
  "Learn how the macros defined under DIRS indent (once per directory)."
  (dolist (dir dirs)
    (unless (member dir drgnx-fmt--learned)
      (push dir drgnx-fmt--learned)
      (dolist (f (if (file-directory-p dir) (directory-files-recursively dir "\\.el\\'") (list dir)))
        (with-temp-buffer
          (insert-file-contents f)
          (condition-case nil
              (while t (drgnx-fmt--learn-form (read (current-buffer))))
            (error nil)))))))

;;;; Formatting

(defun drgnx-fmt--readable (file)
  "nil when the current buffer reads as Lisp, else where it does not (FILE:LINE: why)."
  (save-excursion
    (condition-case nil (let ((inhibit-message t) (message-log-max nil)) (check-parens) nil)   ; no "Mark set"
      (error (format "%s:%d: does not read (an unbalanced parenthesis or an open string)"
                     (file-name-nondirectory file) (line-number-at-pos))))))

(defun drgnx-fmt-buffer ()
  "Format the current buffer (Emacs Lisp that reads)."
  (let ((indent-tabs-mode nil) (inhibit-message t) (message-log-max nil))
    (indent-region (point-min) (point-max))
    (delete-trailing-whitespace)
    (goto-char (point-max))
    (skip-chars-backward "\n")
    (delete-region (point) (point-max))
    (insert "\n")))

(defun drgnx-fmt-file (file &optional dirs check)
  "Format FILE: (same), (changed), or (error WHERE) when it does not read (it is left as it was).  DIRS: where
to learn macro indentation (default: drgnx's code and FILE's directory).  CHECK: report, do not write."
  (drgnx-fmt--learn (or dirs (cons (file-name-directory (expand-file-name file))
                                   (mapcar (lambda (d) (expand-file-name d drgnx-dir)) drgnx-fmt-dirs))))
  (with-temp-buffer
    (insert-file-contents file)
    (delay-mode-hooks (emacs-lisp-mode))
    (if-let* ((err (drgnx-fmt--readable file)))
        (list 'error err)
      (let ((before (buffer-string)))
        (drgnx-fmt-buffer)
        (cond ((equal before (buffer-string)) (list 'same))
              (check (list 'changed))
              (t (let ((coding-system-for-write 'utf-8-unix)) (write-region nil nil file nil 'silent))
                 (list 'changed)))))))

;;;; Command line

(defun drgnx-fmt-cli-run (args)
  "`drgnx fmt [--check] [FILE…]' (no FILE: all of drgnx).  Exit code: 0 formatted (or nothing to do), 1 with
--check when a file would change, 2 when a file does not read."
  (let* ((check (member "--check" args)) (files (or (remove "--check" args) (drgnx-fmt-files))) (code 0))
    (dolist (f files)
      (pcase (drgnx-fmt-file f nil check)
        (`(error ,why) (princ (concat why "\n")) (setq code 2))
        (`(changed) (princ (format "%s %s\n" (if check "would format" "formatted") (file-relative-name f)))
         (when (and check (< code 1)) (setq code 1)))))
    code))

(defun drgnx-fmt-cli ()
  "bin/drgnx fmt: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-fmt-cli-run args))))

(provide 'drgnx-fmt)
;;; drgnx-fmt.el ends here
