;;; chrome-tab-titles-test.el --- batch tests: special pages get readable tab titles (audit G3) -*- lexical-binding: t -*-
;; test-class: det

;; The 2026-11-16 audit (G3): special pages opened as tabs titled with Emacs buffer names: `*drgnx start*',
;; `*drgnx settings*', `*drgnx keyboard shortcuts*', `*Extensions*'.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-chrome)

(defmacro chrome-tab-titles-test--buffer (name &rest body)
  "BODY with `b' a fresh buffer called NAME."
  (declare (indent 1))
  `(let ((b (generate-new-buffer ,name)))
     (unwind-protect (progn ,@body) (kill-buffer b))))

(ert-deftest chrome-tab-titles/special-pages-read-as-names ()
  (pcase-dolist (`(,name ,title) '(("*drgnx settings*" "Settings")
                                   ("*drgnx keyboard shortcuts*" "Keyboard Shortcuts")
                                   ("*Extensions*" "Extensions")
                                   ("*drgnx start*" "Welcome")
                                   ("*Run and Debug*" "Run and Debug")))
    (chrome-tab-titles-test--buffer name
      (should (equal (drgnx-chrome-tab-title b) title)))))

(ert-deftest chrome-tab-titles/the-tab-shows-the-title ()
  "The tab's text is the title, with no star."
  (chrome-tab-titles-test--buffer "*drgnx settings*"
    (let ((s (substring-no-properties (drgnx-chrome--tab (selected-window) b nil nil nil))))
      (should (string-search "Settings" s))
      (should-not (string-search "*" s)))))

(ert-deftest chrome-tab-titles/files-and-own-titles ()
  "A file's tab keeps its file's name; a buffer may name its own title."
  (chrome-tab-titles-test--buffer "notes.txt"
    (with-current-buffer b (setq buffer-file-name "/tmp/x/notes.txt"))
    (should (equal (drgnx-chrome-tab-title b) "notes.txt"))
    (with-current-buffer b (setq buffer-file-name nil)))
  (chrome-tab-titles-test--buffer "*drgnx work: x*"
    (with-current-buffer b (setq-local drgnx-chrome-tab-title "Work"))
    (should (equal (drgnx-chrome-tab-title b) "Work"))))

(provide 'chrome-tab-titles-test)
;;; chrome-tab-titles-test.el ends here
