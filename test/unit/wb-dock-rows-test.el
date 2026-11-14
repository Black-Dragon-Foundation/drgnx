;;; wb-dock-rows-test.el --- batch tests: the rows a dock section fits itself to -*- lexical-binding: t -*-
;; test-class: det
;; A dock section is as tall as its rows (`drgnx-wb--fit-window'): the count is the view's own (the rows Sjá holds, or
;; the inserter's), not the lines of the buffer, which a draw that keeps only the window's slice does not have all of.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-view)
(require 'drgnx-view-sja)

(ert-deftest drgnx-wb/a-plain-buffers-rows-are-its-lines ()
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (should (= 3 (drgnx-wb--section-rows (current-buffer))))))

(ert-deftest drgnx-wb/a-view-held-in-sja-fits-to-the-rows-sja-holds-and-counts-no-lines ()
  (with-temp-buffer
    (insert "just the slice drawn\n")
    (cl-letf (((symbol-function 'drgnx-view-sja-p) (lambda (&optional _) t))
              ((symbol-function 'drgnx-view-row-count) (lambda (view) (should-not view) 500))
              ((symbol-function 'count-lines) (lambda (&rest _) (error "counted the buffer's lines"))))
      (should (= 500 (drgnx-wb--section-rows (current-buffer)))))))

(ert-deftest drgnx-wb/an-inserter-view-fits-to-its-own-row-count ()
  (with-temp-buffer
    (insert "a\n")
    (let ((view (make-symbol "view")))
      (setq-local drgnx-view view)
      (cl-letf (((symbol-function 'drgnx-view-sja-p) (lambda (&optional _) nil))
                ((symbol-function 'drgnx-view-p) (lambda (v) (eq v view)))
                ((symbol-function 'drgnx-view-row-count) (lambda (v) (should (eq v view)) 40))
                ((symbol-function 'count-lines) (lambda (&rest _) (error "counted the buffer's lines"))))
        (should (= 40 (drgnx-wb--section-rows (current-buffer))))))))

(provide 'wb-dock-rows-test)
;;; wb-dock-rows-test.el ends here
