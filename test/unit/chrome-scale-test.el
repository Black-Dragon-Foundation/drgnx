;;; chrome-scale-test.el --- the Flow chrome's per-scale sizes (Flow Task 29) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  Task 29's change: the rail, title row, tab lines and composer read their own frame's scale, and
;; what is sized from it is cached per scale (not per frame, not once for all): `drgnx-pixels-cached' KEY FRAME FN calls
;; FN with FRAME once for each scale seen under KEY; `drgnx-pixels-cache-reset' (a scale change) empties it, so every view
;; on the frame sizes itself again.  The frames here are stand-ins: only their scale matters.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-pixels)

(declare-function drgnx-pixels-cached "drgnx-pixels" (key frame fn))
(declare-function drgnx-pixels-cache-reset "drgnx-pixels" ())

(defmacro chrome-scale-test--with-frames (&rest body)
  "BODY with the frames `f1' and `f3' at scale 1, `f2' at scale 2, and an empty cache."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'drgnx-pixels-scale) (lambda (&optional f) (if (eq f 'f2) 2.0 1.0))))
     (drgnx-pixels-cache-reset)
     ,@body))

(ert-deftest drgnx-chrome-scale/a-size-is-cached-once-for-each-scale ()
  (chrome-scale-test--with-frames
    (let* ((calls 0) (fn (lambda (f) (cl-incf calls) (* 10 (drgnx-pixels-scale f)))))
      (should (= 10.0 (drgnx-pixels-cached 'rail 'f1 fn)))
      (should (= 10.0 (drgnx-pixels-cached 'rail 'f1 fn)))
      (should (= 1 calls))
      ;; a frame of another scale sizes itself at its own scale
      (should (= 20.0 (drgnx-pixels-cached 'rail 'f2 fn)))
      (should (= 2 calls))
      ;; a third frame at scale 1 shares the cache of the first: the cache is per scale, not per frame
      (should (= 10.0 (drgnx-pixels-cached 'rail 'f3 fn)))
      (should (= 2 calls))
      ;; another key is its own
      (drgnx-pixels-cached 'composer 'f1 fn)
      (should (= 3 calls)))))

(ert-deftest drgnx-chrome-scale/a-scale-change-sizes-every-view-again ()
  (chrome-scale-test--with-frames
    (let* ((calls 0) (fn (lambda (f) (cl-incf calls) (drgnx-pixels-scale f))))
      (drgnx-pixels-cached 'rail 'f1 fn)
      (drgnx-pixels-cache-reset)
      (drgnx-pixels-cached 'rail 'f1 fn)
      (should (= 2 calls)))))

(provide 'chrome-scale-test)
;;; chrome-scale-test.el ends here
