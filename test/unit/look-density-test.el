;;; look-density-test.el --- density: the table, line heights, who owns them -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the density table, the code line's owners and the UI rows' spacing are functions of settings
;; and of a frame's line height and scale.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-type-faces)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir) nil t)

(defmacro drgnx-look-density-test--frame-clean (&rest body)
  "BODY, then the selected frame's line spacing as it was."
  (declare (indent 0))
  `(let ((was (frame-parameter nil 'line-spacing)))
     (unwind-protect (progn ,@body)
       (drgnx-look-density-off)
       (set-frame-parameter nil 'line-spacing was))))

(ert-deftest drgnx-look-density/table ()
  "Pattern D: every key at every density is the design's number, in logical pixels."
  (pcase-dolist (`(,key ,compact ,comfortable ,roomy)
                 '((code-line 19 21 23) (tree-row 22 26 30) (tab-row 30 34 38) (status-bar 22 24 28)
                   (title-row 34 38 42) (gap 4 6 8) (panel-padding 8 12 16) (tree-indent 12 12 14)))
    (should (= compact (drgnx-look-density-value key 'compact)))
    (should (= comfortable (drgnx-look-density-value key 'comfortable)))
    (should (= roomy (drgnx-look-density-value key 'roomy)))
    (should (= comfortable (drgnx-look-density-value key))))
  (let ((drgnx-look-density 'roomy))
    (should (= 23 (drgnx-look-density-value 'code-line))))
  (should-error (drgnx-look-density-value 'nonsense)))

(ert-deftest drgnx-look-density/role-beats-density-beats-old-setting ()
  "Pattern D: the code role's `:line-height', when the user set it, is the target; else the density's; the frame
gets the target less the frame's own line height."
  (drgnx-look-density-test--frame-clean
    (let ((h (frame-char-height)))
      (should (= 21 (drgnx-look-density-code-line)))
      (let ((drgnx-look-density 'roomy)) (should (= 23 (drgnx-look-density-code-line))))
      (let ((drgnx-look-density 'compact)
            (drgnx-look-font-code '(:family "JetBrains Mono" :line-height 25)))
        (should (= 25 (drgnx-look-density-code-line))))
      ;; a role left at its default does not hide the density
      (let ((drgnx-look-density 'compact)
            (drgnx-look-font-code '(:family "JetBrains Mono" :line-height 21)))
        (should (= 19 (drgnx-look-density-code-line))))
      ;; the frame gets the target less its own line height (a terminal frame has no such parameter: the GUI row
      ;; measures the lines)
      (should (= (max 0 (- (drgnx-px 21 (selected-frame)) h))
                 (drgnx-look-density--extra (selected-frame))))
      (let ((drgnx-look-density 'roomy))
        (should (= (max 0 (- (drgnx-px 23 (selected-frame)) h))
                   (drgnx-look-density--extra (selected-frame))))))))

(ert-deftest drgnx-look-density/user-line-spacing-stays ()
  "Pattern D: a `line-spacing' the user set as the default is left alone: the frame needs nothing written."
  (drgnx-look-density-test--frame-clean
    (let ((old (default-value 'line-spacing)))
      (unwind-protect
          (progn
            (setq-default line-spacing 4)
            (should-not (drgnx-look-density--extra (selected-frame)))
            (setq-default line-spacing nil)
            (should (drgnx-look-density--extra (selected-frame))))
        (setq-default line-spacing old)))))

(ert-deftest drgnx-look-density/ui-cons-centres ()
  "Pattern D: the cons brings a UI row to the tree row's height and puts the extra pixels half above, half below
\(the odd one below); a row already tall enough gets none."
  (let ((row (drgnx-px 26)))
    (should (equal (cons (/ (- row 18) 2) (- (- row 18) (/ (- row 18) 2)))
                   (drgnx-look-ui-line-spacing 18)))
    (should (equal '(4 . 4) (drgnx-look-ui-line-spacing 18 'comfortable 1.0)))
    (should (equal '(4 . 5) (drgnx-look-ui-line-spacing 17 'comfortable 1.0)))
    (should (equal '(2 . 2) (drgnx-look-ui-line-spacing 18 'compact 1.0)))
    (should (equal '(6 . 6) (drgnx-look-ui-line-spacing 18 'roomy 1.0)))
    (should (equal '(0 . 0) (drgnx-look-ui-line-spacing 40 'comfortable 1.0)))
    (should (equal '(11 . 11) (drgnx-look-ui-line-spacing 30 'comfortable 2.0)))))

(ert-deftest drgnx-look-density/ui-line-spacing-rounds-half-up ()
  "The tree row at 1.25 is 33 device pixels (26 × 1.25 = 32.5, half up): 7 more than a 26 px line, 3 above and 4
below; at 4/3 it is 35, at 2 it is 52."
  (should (equal (drgnx-look-ui-line-spacing 26 'comfortable 1.25) '(3 . 4)))
  (should (equal (drgnx-look-ui-line-spacing 26 'comfortable (/ 160 120.0)) '(4 . 5)))
  (should (equal (drgnx-look-ui-line-spacing 26 'comfortable 2.0) '(13 . 13))))

(ert-deftest drgnx-look-density/code-line-goes-through-the-pixel-rule ()
  "The code line's extra spacing is the line in frame pixels less the character height: 21 at 1.25 is 26 (half up),
so the extra is 26 less the frame's line height."
  (cl-letf (((symbol-function 'frame-scale-factor) (lambda (&optional _f) 1.25))
            ((symbol-function 'drgnx-pixels-device-p) (lambda () t)))
    (let ((drgnx-look-density 'comfortable) (line-spacing nil))
      (should (= (drgnx-look-density--extra (selected-frame)) (max 0 (- 26 (frame-char-height))))))
    (let ((drgnx-look-density 'compact) (line-spacing nil))
      ;; 19 × 1.25 = 23.75 → 24
      (should (= (drgnx-look-density--extra (selected-frame)) (max 0 (- 24 (frame-char-height)))))))
  ;; a frame that counts logical pixels takes the line unscaled
  (cl-letf (((symbol-function 'frame-scale-factor) (lambda (&optional _f) 1.25))
            ((symbol-function 'drgnx-pixels-device-p) (lambda () nil)))
    (let ((drgnx-look-density 'comfortable) (line-spacing nil))
      (should (= (drgnx-look-density--extra (selected-frame)) (max 0 (- 21 (frame-char-height))))))))

(provide 'look-density-test)
;;; look-density-test.el ends here
