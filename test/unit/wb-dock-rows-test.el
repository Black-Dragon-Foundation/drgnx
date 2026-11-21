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

(defvar drgnx-wb--sections)

(defun drgnx-wb-test--fit-delta (pixel body &optional spec rows chrome)
  "The edge move `drgnx-wb--fit-window' asks of a section window PIXEL pixels tall whose body Emacs reports as BODY: an
island header (tab line) of 26 and a header line of 22 (CHROME nil: none of either), 3 rows of 22 (or ROWS), the
section's SPEC (default a cap of 0.3) of a 900-pixel frame."
  (let ((drgnx-wb--sections (list (cons 'open (or spec '(:fit 0.3))))) (chrome (or chrome '(26 22))) moved)
    (cl-letf (((symbol-function 'window-live-p) (lambda (_) t))
              ((symbol-function 'window-parameter) (lambda (_w p) (and (eq p 'drgnx-section) 'open)))
              ((symbol-function 'window-frame) (lambda (&optional _) 'frame))
              ((symbol-function 'drgnx-wb--row-px) (lambda (_) 22))
              ((symbol-function 'window-in-direction) (lambda (&rest _) t))
              ((symbol-function 'window-buffer) (lambda (&optional _) (current-buffer)))
              ((symbol-function 'drgnx-wb--section-rows) (lambda (_) (or rows 3)))
              ((symbol-function 'frame-inner-height) (lambda (&optional _) 900))
              ((symbol-function 'window-pixel-height) (lambda (&optional _) pixel))
              ((symbol-function 'window-body-height) (lambda (&rest _) body))
              ((symbol-function 'window-tab-line-height) (lambda (&optional _) (car chrome)))
              ((symbol-function 'window-header-line-height) (lambda (&optional _) (cadr chrome)))
              ((symbol-function 'window-mode-line-height) (lambda (&optional _) 0))
              ((symbol-function 'window-scroll-bar-height) (lambda (&optional _) 0))
              ((symbol-function 'window-bottom-divider-width) (lambda (&optional _) 0))
              ((symbol-function 'adjust-window-trailing-edge) (lambda (_w delta &rest _) (setq moved delta))))
      (drgnx-wb--fit-window 'window))
    moved))

(ert-deftest drgnx-wb/a-section-squeezed-below-its-header-grows-to-its-rows-in-one-fit ()
  "A section fitted before its island header was measured is shorter than its tab and header lines once the header
grows (30 pixels, the body Emacs reports 0): one fit makes it hold them and its rows (48 + 66 = 114 pixels).  Its
chrome read as its height less its body (30) left it 18 pixels short, its header line past its bottom."
  (should (= 84 (drgnx-wb-test--fit-delta 30 0)))
  ;; fitted already: a second call changes nothing
  (should-not (drgnx-wb-test--fit-delta 114 66)))

(ert-deftest drgnx-wb/an-empty-section-with-min-rows-keeps-its-line ()
  "The Source Control message box: its own header, no lines yet.  Fitted to its rows it would be 0 pixels tall and
gone from the side bar; `:min-rows' 1 keeps one row (22 pixels)."
  (should (= -40 (drgnx-wb-test--fit-delta 40 40 '(:fit 0.15) 0 '(0 0))))
  (should (= -18 (drgnx-wb-test--fit-delta 40 40 '(:fit 0.15 :min-rows 1) 0 '(0 0))))
  ;; with lines, the rows count as before
  (should (= 26 (drgnx-wb-test--fit-delta 40 40 '(:fit 0.15 :min-rows 1) 3 '(0 0)))))

(provide 'wb-dock-rows-test)
;;; wb-dock-rows-test.el ends here
