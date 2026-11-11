;;; look-float-test.el --- popups and the palette: values per variant, motion -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the chrome and palette alists are functions of the variant and of the motion setting.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-popup)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)

(defvar glitnir-reduced-motion)

(defun drgnx-look-float-test--shadow (blur offset opacity)
  `(:blur ,blur :offset (0 . ,offset) :spread 0 :opacity ,opacity))

(ert-deftest drgnx-look-float/values-per-variant ()
  "Pattern D: the three variants' popup and palette values are the approved ones."
  (let ((drgnx-look-motion 'full))
    (should (equal (drgnx-look-chrome-for 'dark)
                   `((corner-radius . 8) (shadow . ,(drgnx-look-float-test--shadow 16 6 0.35)) (transition . pop))))
    (should (equal (drgnx-look-chrome-for 'light)
                   `((corner-radius . 8) (shadow . ,(drgnx-look-float-test--shadow 16 6 0.14)) (transition . pop))))
    (should (equal (drgnx-look-chrome-for 'hc)
                   '((corner-radius . 8) (child-frame-border-width . 1) (transition . pop))))
    (should (equal (drgnx-look-palette-for 'dark)
                   `((corner-radius . 12) (shadow . ,(drgnx-look-float-test--shadow 48 16 0.50))
                     (ring . (child-frame-shadow . 0.45))
                     (alpha-background . 0.90) (backdrop-blur . 16) (transition . pop))))
    (should (equal (drgnx-look-palette-for 'light)
                   `((corner-radius . 12) (shadow . ,(drgnx-look-float-test--shadow 48 16 0.22))
                     (ring . (child-frame-shadow . 0.08))
                     (alpha-background . 0.90) (backdrop-blur . 16) (transition . pop))))
    (should (equal (drgnx-look-palette-for 'hc)
                   '((corner-radius . 12) (alpha-background . 1.0) (child-frame-border-width . 2)
                     (transition . pop))))))

(ert-deftest drgnx-look-float/customised-value-wins ()
  "Pattern D: a value the user set stands over the table, in every variant; the standard value follows the table."
  (let ((drgnx-look-motion 'full))
    (should-not (drgnx-look--float-customised-p 'drgnx-look-chrome))
    (should (equal (drgnx-look-chrome-current) (drgnx-look-chrome-for (drgnx-look-variant))))
    (let ((drgnx-look-chrome '((corner-radius . 3))) (drgnx-look-palette '((corner-radius . 4))))
      (should (drgnx-look--float-customised-p 'drgnx-look-chrome))
      (should (equal (drgnx-look-chrome-current) '((corner-radius . 3))))
      (should (equal (drgnx-look-palette-current) '((corner-radius . 4)))))))

(ert-deftest drgnx-look-float/reduced-motion-drops-transitions ()
  "Pattern D: `reduced' leaves no transition in either alist, in every variant; `auto' and `full' keep it."
  (dolist (variant '(dark light hc))
    (let ((drgnx-look-motion 'reduced))
      (should-not (assq 'transition (drgnx-look-chrome-for variant)))
      (should-not (assq 'transition (drgnx-look-palette-for variant)))
      (should (assq 'corner-radius (drgnx-look-chrome-for variant))))
    (dolist (m '(auto full))
      (let ((drgnx-look-motion m))
        (should (assq 'transition (drgnx-look-chrome-for variant)))
        (should (assq 'transition (drgnx-look-palette-for variant)))))))

(ert-deftest drgnx-look-float/motion-sets-glitnir-reduced-motion ()
  "Pattern D: `auto' is Glitnir's `auto' (the desktop says), `full' is nil (never reduce), `reduced' t; outside ui/look
the option is left alone (ui/look sets it as the module: `drgnx-look/teardown-restores-reduced-motion')."
  (pcase-dolist (`(,m . ,want) '((auto . auto) (full . nil) (reduced . t)))
    (let ((drgnx-look-motion m)) (should (eq want (drgnx-look--motion-value)))))
  (let ((glitnir-reduced-motion 'unset) (drgnx-look-motion 'full))
    (drgnx-look--motion-apply)
    (should (eq glitnir-reduced-motion 'unset))))

(ert-deftest drgnx-look-float/lane-fonts ()
  "Pattern D: in a lane's buffer the descriptions take the UI face and the keys the code face."
  (with-temp-buffer
    (drgnx-popup--fonts (current-buffer))
    (should (memq 'drgnx-ui-text (alist-get 'default face-remapping-alist)))
    (dolist (f '(transient-key which-key-key-face))
      (should (memq 'fixed-pitch (alist-get f face-remapping-alist))))
    (let ((n (length face-remapping-alist)))
      (drgnx-popup--fonts (current-buffer))
      (should (= n (length face-remapping-alist))))))

(provide 'look-float-test)
;;; look-float-test.el ends here
