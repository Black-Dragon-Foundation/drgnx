;;; view-fixture.el --- test helpers for views (wb/drgnx-view.el) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-view-test-with-type' defines a throwaway view type around a body.  `drgnx-view-test--text' is a view's
;; region as a string; `drgnx-view-test--expected' is every row rendered fresh, concatenated: a view is right when
;; the two are equal and `drgnx-view--check' is nil.  `drgnx-view-test--alloc' counts what a byte-compiled call
;; allocates (until the determinism suite's `drgnx-test-alloc' replaces it).

;;; Code:
(require 'cl-lib)
(require 'drgnx-view)

(defvar byte-compile-warnings)

(defmacro drgnx-view-test-with-type (spec &rest body)
  "BODY with the view type (car SPEC) defined by `drgnx-view-define' with the arguments (cdr SPEC), removed after.
SPEC: (NAME &rest ARGS), all evaluated."
  (declare (indent 1))
  `(progn (drgnx-view-define ,@spec)
          (unwind-protect (progn ,@body) (drgnx-view--undefine ,(car spec)))))

(defun drgnx-view-test--text (view)
  "VIEW's region, START to the end of its buffer, as a string without properties."
  (with-current-buffer (drgnx-view--buffer view)
    (save-restriction (widen) (buffer-substring-no-properties (drgnx-view--start view) (point-max)))))

(defun drgnx-view-test--expected (view)
  "VIEW's rows rendered fresh with its type's RENDER, in its order, concatenated (an error row for a RENDER that
signals)."
  (let ((render (drgnx-view-type-render (drgnx-view--type view))) (keys (drgnx-view--keys view)) parts)
    (dotimes (i (drgnx-view--n view))
      (let* ((key (aref keys i))
             (r (condition-case err (funcall render key)
                  (error (drgnx-view--error-text key (error-message-string err))))))
        (push (if (consp r) (concat (car r) (cdr r)) r) parts)))
    (apply #'concat (nreverse parts))))

(defun drgnx-view-test--compile-library ()
  "Byte-compile the view library's functions in place: the tests run on source, and an interpreted call conses."
  (mapatoms (lambda (s)
              (when (and (fboundp s) (string-prefix-p "drgnx-view-" (symbol-name s))
                         (not (string-prefix-p "drgnx-view-test" (symbol-name s)))
                         (functionp (symbol-function s)) (not (compiled-function-p (symbol-function s))))
                (let ((byte-compile-warnings nil)) (byte-compile s))))))

(defun drgnx-view-test--alloc (fn)
  "What calling the byte-compiled FN allocates (conses, floats, vector cells, symbols, string chars, intervals,
strings, summed): the smallest delta of `memory-use-counts' over three warm runs, minus an empty call's own."
  (drgnx-view-test--compile-library)
  (let* ((byte-compile-warnings nil)
         (fn (if (compiled-function-p fn) fn (byte-compile fn)))
         (empty (let ((e (lambda () nil))) (if (compiled-function-p e) e (byte-compile e)))) best)
    (cl-flet ((delta (f) (let* ((a (memory-use-counts)) (_ (funcall f)) (b (memory-use-counts)))
                           (apply #'+ (cl-mapcar #'- b a)))))
      (funcall fn) (funcall fn)
      (dotimes (_ 3)
        (let ((d (- (delta fn) (delta empty)))) (setq best (if best (min best d) d)))))
    best))

(provide 'view-fixture)
;;; view-fixture.el ends here
