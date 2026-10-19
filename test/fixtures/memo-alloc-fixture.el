;;; memo-alloc-fixture.el --- allocation of a byte-compiled call, for the memo clients' 0-allocation tests -*- lexical-binding: t -*-
;;
;; (drgnx-memo-fixture-alloc FN &rest SYMBOLS)  the conses, floats, vector cells, symbols, string chars, intervals and
;;                                              strings one call of FN allocates (the smallest of three warm runs)
;;
;; The tests run on source, and an interpreted call conses: FN, the memo library (`drgnx-memo', `drgnx-epoch' and
;; `drgnx-cache' functions) and each of SYMBOLS (the client's functions FN calls) are byte-compiled in place first.
(require 'cl-lib)
(defvar byte-compile-warnings)

(defun drgnx-memo-fixture--compile (symbol)
  "Byte-compile SYMBOL's function in place unless it is compiled already."
  (when (and (fboundp symbol) (functionp (symbol-function symbol)) (not (compiled-function-p (symbol-function symbol))))
    (let ((byte-compile-warnings nil)) (byte-compile symbol))))

(defun drgnx-memo-fixture-alloc (fn &rest symbols)
  "What one call of FN allocates, with the library and SYMBOLS byte-compiled (see the file's header)."
  (mapatoms (lambda (s) (when (string-match-p "\\`drgnx-\\(memo\\|epoch\\|cache\\)" (symbol-name s)) (drgnx-memo-fixture--compile s))))
  (mapc #'drgnx-memo-fixture--compile symbols)
  (let* ((byte-compile-warnings nil)
         (fn (if (compiled-function-p fn) fn (byte-compile fn)))
         (empty (byte-compile (lambda () nil))) best)
    (cl-flet ((delta (f) (let* ((a (memory-use-counts)) (_ (funcall f)) (b (memory-use-counts)))
                           (apply #'+ (cl-mapcar #'- b a)))))
      (funcall fn) (funcall fn)
      (dotimes (_ 3)
        (let ((d (- (delta fn) (delta empty)))) (setq best (if best (min best d) d)))))
    best))

(provide 'memo-alloc-fixture)
;;; memo-alloc-fixture.el ends here
