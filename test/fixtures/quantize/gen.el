;;; gen.el --- Regenerate cases.json from the Lisp quantizer -*- lexical-binding: t -*-

;; Run in batch Emacs from the checkout root:
;;   emacs -Q --batch -L core -l test/fixtures/quantize/gen.el
;; and compare with cases.json (the Rust test `quantize_matches_the_lisp_fixtures` reads it).
;; Inputs avoid exact halves after scaling, where rounding modes could differ.

(require 'drgnx-search-store)
(require 'json)

(dolist (input '([1.0 -1.0 0.25 -0.25 0.0 0.75 0.125 -0.875 0.375]
                 [0.0 0.0 0.0]
                 [-0.5 -0.5 -0.5 -0.5 -0.5 -0.5 -0.5 -0.5]
                 [0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5]))
  (pcase-let ((`(,bits ,int8 ,scale) (drgnx-search-quantize input)))
    (princ (json-encode
            `((input . ,input)
              (bits . ,(vconcat (append bits nil)))
              (int8 . ,(vconcat (mapcar (lambda (b) (if (> b 127) (- b 256) b)) (append int8 nil))))
              (scale . ,scale))))
    (terpri)))
;;; gen.el ends here
