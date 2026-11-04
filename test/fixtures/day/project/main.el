;;; main.el --- the synthetic day's project: a small Lisp library  -*- lexical-binding: t -*-

;;; Commentary:
;; A pinned fixture (test/fixtures/day/).  Nothing in it is run; the day opens it, starts eglot on it against the
;; replay server and asks the repository for its status and log.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defvar day-ledger nil "Entries of the ledger, newest first: (ID . AMOUNT).")

(defun day-add (id amount)
  "Add AMOUNT under ID to the ledger."
  (push (cons id amount) day-ledger)
  amount)

(defun day-total ()
  "The sum of the ledger."
  (cl-loop for (_ . a) in day-ledger sum a))

(defun day-by-id (id)
  "Every amount recorded under ID."
  (cl-loop for (i . a) in day-ledger when (equal i id) collect a))

(defun day-largest (&optional n)
  "The N (default 3) largest entries."
  (seq-take (sort (copy-sequence day-ledger) (lambda (a b) (> (cdr a) (cdr b)))) (or n 3)))

(defun day-report ()
  "The ledger as text, one line per entry."
  (mapconcat (lambda (e) (format "%-12s %10.2f" (car e) (cdr e))) (reverse day-ledger) "\n"))

(defun day-reset ()
  "Empty the ledger."
  (setq day-ledger nil))

(defun day-merge (other)
  "Add the entries of the ledger OTHER to this one."
  (dolist (e (reverse other)) (day-add (car e) (cdr e))))

(defun day-average ()
  "The mean entry, or nil for an empty ledger."
  (when day-ledger (/ (day-total) (length day-ledger))))

(defun day-split (id)
  "A cons of the entries under ID and the others."
  (cl-loop for e in day-ledger
           if (equal (car e) id) collect e into mine
           else collect e into rest
           finally return (cons mine rest)))

(defun day-round (x &optional digits)
  "X rounded to DIGITS (default 2) decimals."
  (let ((m (expt 10 (or digits 2)))) (/ (fround (* x m)) m)))

(provide 'main)
;;; main.el ends here
