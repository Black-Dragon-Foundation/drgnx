;;; notice-fixture.el --- for notice tests: a fresh notice model, restored by value; allocation counts -*- lexical-binding: t -*-

;;; Commentary:
;; `drgnx-notice-test-with-model' gives BODY an empty notice model and puts the one it found back afterwards, with
;; `set' (never `let' over a library that might not be loaded yet: kb tests-never-reach-home).  It requires the model
;; first, so every variable it names is defined.  `drgnx-notice-test--alloc' counts the conses a byte-compiled body
;; allocates (the shape of the timer plan's helper; determinism phase 3's `drgnx-test-alloc' replaces it).

;;; Code:
(require 'ert)
(require 'bytecomp)
(require 'drgnx-notice)

(defvar drgnx-notice-test--variables
  '((drgnx-notice--table . (make-hash-table :test #'equal))
    (drgnx-notice--events . nil)
    (drgnx-notice--conditions . (make-hash-table :test #'eq))
    (drgnx-notice--more . (make-hash-table :test #'eq))
    (drgnx-notice--sources . (make-hash-table :test #'eq))
    (drgnx-notice--rank . 0)
    (drgnx-notice--stale . nil)
    (drgnx-notice--sets . (make-hash-table :test #'eq))
    (drgnx-notice--index . (make-hash-table :test #'eq))
    (drgnx-notice--heard . (make-hash-table :test #'eq))
    (drgnx-notice--was . (make-hash-table :test #'eq))
    (drgnx-notice--union . (make-hash-table :test #'equal))
    (drgnx-notice--needs-you . 0)
    (drgnx-notice--scoped . (make-hash-table :test #'equal))
    (drgnx-notice--scoped-tick . -1)
    (drgnx-notice--problems . (cons 0 0))
    (drgnx-notice--dismissed . (make-hash-table :test #'equal))
    (drgnx-notice--tick . 0)
    (drgnx-notice-functions . nil)
    (drgnx-notice--hook-errors . nil)
    (drgnx-notice--queue . nil)
    (drgnx-notice--running . nil))
  "The notice model's variables, each with the form that makes its fresh value.")

(defmacro drgnx-notice-test-with-model (&rest body)
  "Run BODY with a fresh notice model; afterwards the model found before is set back, value by value."
  (declare (indent 0) (debug t))
  (let ((saved (make-symbol "saved")))
    `(let ((,saved (mapcar (lambda (v) (cons (car v) (symbol-value (car v)))) drgnx-notice-test--variables)))
       (unwind-protect
           (progn
             (dolist (v drgnx-notice-test--variables) (set (car v) (eval (cdr v) t)))
             ,@body)
         (dolist (s ,saved) (set (car s) (cdr s)))))))

(defun drgnx-notice-test--compile ()
  "Byte-compile every function of the notice model that is not: allocation is measured on compiled code."
  (let ((byte-compile-warnings nil) (inhibit-message t))
    (mapatoms
     (lambda (s)
       (when (and (fboundp s) (not (macrop s))
                  (let ((n (symbol-name s)))
                    (or (string-prefix-p "drgnx-notice" n) (string-prefix-p "drgnx-needs-you" n)
                        (member n '("drgnx-notify" "drgnx-problems-count" "drgnx-notices"))))
                  (not (string-prefix-p "drgnx-notice-test" (symbol-name s)))
                  (not (compiled-function-p (indirect-function s))))
         (byte-compile s))))))

(defun drgnx-notice-test--conses (fn)
  "Conses allocated while FN runs, plus the counter's own list."
  (let ((before (car (memory-use-counts))))
    (funcall fn)
    (- (car (memory-use-counts)) before)))

(defun drgnx-notice-test--alloc-1 (fn)
  "The fewest conses FN allocates in 3 warm runs, the counter's own list subtracted."
  (drgnx-notice-test--compile)
  (funcall fn)                                          ; warm
  (let ((base (min (drgnx-notice-test--conses #'ignore) (drgnx-notice-test--conses #'ignore)))
        (best most-positive-fixnum))
    (dotimes (_ 3) (setq best (min best (- (drgnx-notice-test--conses fn) base))))
    best))

(defmacro drgnx-notice-test--alloc (&rest body)
  "The fewest conses BODY, byte-compiled, allocates in 3 warm runs.  BODY reads its data from special variables: a
compiled lambda captures no lexical ones."
  `(drgnx-notice-test--alloc-1 (byte-compile '(lambda () ,@body))))

(provide 'notice-fixture)
;;; notice-fixture.el ends here
