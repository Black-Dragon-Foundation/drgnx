;;; util.el --- helpers of the synthetic day's project  -*- lexical-binding: t -*-

;;; Code:
(require 'main)

(defun util-lines (text)
  "TEXT split into non-empty lines."
  (split-string text "\n" t))

(defun util-parse-line (line)
  "A LINE of the report back into (ID . AMOUNT), or nil."
  (when (string-match "\\`\\(\\S-+\\)\\s-+\\([0-9.]+\\)\\'" line)
    (cons (match-string 1 line) (string-to-number (match-string 2 line)))))

(defun util-load-report (text)
  "Fill the ledger from the report TEXT."
  (day-reset)
  (dolist (l (util-lines text))
    (when-let* ((e (util-parse-line l))) (day-add (car e) (cdr e)))))

(defun util-histogram (buckets)
  "The ledger's amounts counted into BUCKETS equal-width bins: a vector."
  (let* ((amounts (mapcar #'cdr day-ledger)) (hi (apply #'max 1 amounts))
         (v (make-vector buckets 0)))
    (dolist (a amounts)
      (cl-incf (aref v (min (1- buckets) (floor (* buckets (/ (float a) hi)))))))
    v))

(provide 'util)
;;; util.el ends here
