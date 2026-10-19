;;; measure-fixture.el --- measuring in a unit test: allocation first, CPU when allocation cannot say it -*- lexical-binding: t -*-
;;
;; (drgnx-test-alloc BODY...)                 what BODY allocates: the least of 3 runs after an unmeasured one, the
;;                                            `memory-use-counts' delta summed over its seven kinds
;; (drgnx-test-cpu-ms (&key (n 50)) BODY...)  the median CPU time of N runs of BODY, in ms
;; (drgnx-test-compile PREFIX...)             byte-compile in place every interpreted function named PREFIX…
;;
;; Allocation is the same for the same code on the same Emacs, however loaded the machine is; CPU time moves a little
;; with load; wall clock moves with everything, so a wall-clock test is tagged `:timing'.  Docs: docs/develop/core.md
;; "Measuring in a unit test".
(require 'cl-lib)
(defvar byte-compile-warnings)

(defun drgnx-test--compile (symbol)
  "Byte-compile SYMBOL's function in place when it is an interpreted one."
  (let ((f (symbol-function symbol)))
    (when (and (functionp f) (not (compiled-function-p f)) (not (autoloadp f)))
      (let ((byte-compile-warnings nil)) (byte-compile symbol)))))

(defun drgnx-test-compile (&rest prefixes)
  "Byte-compile in place every interpreted function whose name starts with one of PREFIXES (strings).
Tests load the code from source when it is newer than its .elc, and interpreted code conses for its own bookkeeping:
compiled first, a measurement is what users run, and the same whichever test compiled what before."
  (mapatoms (lambda (s)
              (when (and (fboundp s) (let ((name (symbol-name s))) (cl-some (lambda (p) (string-prefix-p p name)) prefixes)))
                (drgnx-test--compile s)))))

(defun drgnx-test--alloc-once (thunk)
  "What one call of THUNK allocates: the summed `memory-use-counts' delta, less the 7 conses of the first reading's list."
  (let* ((a (memory-use-counts)) (_ (funcall thunk)) (b (memory-use-counts)) (sum 0))
    (while a (setq sum (+ sum (- (pop b) (pop a)))))
    (- sum 7)))

(defun drgnx-test--cpu-once (thunk)
  "The CPU time one call of THUNK takes, in ms."
  (let* ((a (current-cpu-time)) (_ (funcall thunk)) (b (current-cpu-time)))
    (unless (and a b) (error "No CPU clock here: `current-cpu-time' is nil"))
    (/ (* 1000.0 (- (car b) (car a))) (cdr a))))

;; This file is loaded from source: compiled, the readings above allocate nothing between them but the 7 conses
(mapc #'drgnx-test--compile '(drgnx-test--alloc-once drgnx-test--cpu-once))

(defun drgnx-test--alloc (thunk)
  "See `drgnx-test-alloc'."
  (funcall thunk)
  (min (drgnx-test--alloc-once thunk) (drgnx-test--alloc-once thunk) (drgnx-test--alloc-once thunk)))

(defun drgnx-test--cpu-ms (n thunk)
  "See `drgnx-test-cpu-ms'."
  (unless (and (integerp n) (> n 0)) (error "drgnx-test-cpu-ms: N must be a positive integer, not %S" n))
  (let ((runs (sort (cl-loop repeat n collect (drgnx-test--cpu-once thunk)) #'<)) (mid (/ n 2)))
    (if (cl-oddp n) (nth mid runs) (/ (+ (nth (1- mid) runs) (nth mid runs)) 2.0))))

(defmacro drgnx-test-alloc (&rest body)
  "What BODY allocates, an integer: one unmeasured run, then the least of three measured runs of the
`memory-use-counts' delta summed over its seven kinds (conses, floats, vector cells, symbols, string characters,
intervals, strings), less the 7 conses the reading itself makes; an empty BODY gives 0.  The same for the same code
and Emacs, whatever else the machine runs.  BODY runs as written: its own `let's count when the test file is loaded
from source, the functions it calls as they are loaded (`drgnx-test-compile' first for a bound in conses)."
  (declare (indent 0) (debug t))
  `(drgnx-test--alloc (lambda () ,@body)))

(cl-defmacro drgnx-test-cpu-ms ((&key (n 50)) &rest body)
  "The median CPU time (`current-cpu-time') of N runs of BODY, in ms, a float; with N even, the mean of the middle two.
CPU time moves less with load than wall clock does, but it moves: use it only where allocation cannot say what the
test guards, with headroom (3× the host's median).  Use: (drgnx-test-cpu-ms () BODY…) or
\(drgnx-test-cpu-ms (:n 20) BODY…)."
  (declare (indent 1) (debug ((&rest form) body)))
  `(drgnx-test--cpu-ms ,n (lambda () ,@body)))

(provide 'drgnx-measure-fixture)
;;; measure-fixture.el ends here
