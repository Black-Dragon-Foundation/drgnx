;;; editing-settings-test.el --- the Editor settings a VS Code user looks for first: font size, tab size, word wrap -*- lexical-binding: t -*-
;; test-class: det
;; Audit K1.  Font size reads as the code font's size layer; tab size sets the default tab width; word wrap steers
;; `drgnx-face-line-wrap'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-type-faces)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-editing" drgnx-dir) nil t)

(ert-deftest drgnx-editing-settings/declared-with-vs-code-defaults ()
  (should (drgnx-setting-own-p 'drgnx-editing-font-size))
  (should (drgnx-setting-own-p 'drgnx-editing-tab-size))
  (should (drgnx-setting-own-p 'drgnx-editing-word-wrap))
  (should (= 4 (default-value 'drgnx-editing-tab-size)))
  (should (eq 'on (default-value 'drgnx-editing-word-wrap))))

(ert-deftest drgnx-editing-settings/font-size-is-the-code-fonts-size ()
  (let ((drgnx-editing-font-size 16.2))
    (should (< (abs (- 1.2 (plist-get (drgnx-look-fonts-resolve 'code) :size))) 0.001)))
  (let ((drgnx-editing-font-size drgnx-type-code-px))
    (should (= 1.0 (plist-get (drgnx-look-fonts-resolve 'code) :size)))))

(ert-deftest drgnx-editing-settings/tab-size-sets-the-default-tab-width ()
  (let ((tab (default-value 'tab-width)) (indent (default-value 'standard-indent)) (saved drgnx-editing--tab-saved))
    (unwind-protect
        (let ((drgnx-editing-tab-size 3))
          (setq drgnx-editing--tab-saved nil)
          (drgnx-editing--apply-tab-size)
          (should (= 3 (default-value 'tab-width)))
          (should (= 3 (default-value 'standard-indent))))
      (setq-default tab-width tab standard-indent indent)
      (setq drgnx-editing--tab-saved saved))))

(ert-deftest drgnx-editing-settings/word-wrap-steers-the-line-wrap ()
  (require 'drgnx-face (expand-file-name "modules/ui/drgnx-face" drgnx-dir) t)
  (skip-unless (featurep 'drgnx-face))
  (let ((was drgnx-face-line-wrap))
    (unwind-protect
        (progn (let ((drgnx-editing-word-wrap 'off)) (drgnx-editing--apply-word-wrap))
               (should (eq 'truncate drgnx-face-line-wrap))
               (let ((drgnx-editing-word-wrap 'on)) (drgnx-editing--apply-word-wrap))
               (should (eq 'word drgnx-face-line-wrap)))
      (set-default 'drgnx-face-line-wrap was))))
