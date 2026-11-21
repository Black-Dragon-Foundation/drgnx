;;; basic.el --- A sample for the chunker  -*- lexical-binding: t; -*-

;; Copyright is not claimed.

;;; Commentary:

;; Several kinds of forms, in two sections.

;;; Code:

(require 'cl-lib)

;;;; Variables

(defvar sample-count 0
  "How many samples were taken.
A second line.")

(defconst sample-table '((a . 1) (b . 2) (c . 3))
  "A lookup table.")

(defcustom sample-name "x" "The name." :type 'string)

;;;; Functions

;;;###autoload
(defun sample-run (n)
  "Run N samples.
More about it."
  (interactive "p")
  (dotimes (_ n) (cl-incf sample-count))
  (message "ran %d (%s)" n ?\())

(defmacro sample-with (x &rest body)
  "Bind X around BODY."
  `(let ((it ,x)) ,@body))

(cl-defstruct (sample-point (:constructor sample-point-new)) x y)

(define-minor-mode sample-mode
  "Toggle the sample mode."
  :global t)

(defalias 'sample-go #'sample-run)

'sample-quoted
#'sample-run
[1 2 3]
