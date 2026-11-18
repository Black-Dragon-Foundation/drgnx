;;; editing-settings-test.el --- the Editor settings a VS Code user looks for first: font size, tab size, word wrap -*- lexical-binding: t -*-
;; test-class: det
;; Audit K1.  Font size reads as the code font's size layer; tab size sets the default tab width; word wrap is resolved
;; per buffer (the wrap addendum §3.3: off, on, column, bounded, and `auto' by the major mode).
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
  (should (eq 'auto (default-value 'drgnx-editing-word-wrap)))
  (should (= 80 (default-value 'drgnx-editing-word-wrap-column))))

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

;;;; Word wrap

(defvar nidhogg-wrap-column)

(defmacro drgnx-editing-settings--in (mode &rest body)
  "BODY in a temp buffer in MODE (a tree-sitter mode without its grammar still sets its major mode)."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((inhibit-message t) (warning-minimum-log-level :emergency)) (ignore-errors (funcall ,mode)))
     ,@body))

(ert-deftest drgnx-editing-settings/each-wrap-value-sets-the-buffers-wrap ()
  (drgnx-editing-settings--in #'emacs-lisp-mode
    (let ((drgnx-editing-word-wrap 'off)) (drgnx-editing--wrap-buffer))
    (should truncate-lines)
    (should-not word-wrap)
    (should-not nidhogg-wrap-column)
    (let ((drgnx-editing-word-wrap 'on)) (drgnx-editing--wrap-buffer))
    (should-not truncate-lines)
    (should word-wrap)
    (should-not truncate-partial-width-windows)            ; narrow windows wrap too
    (should (equal (assq 'continuation fringe-indicator-alist) '(continuation nil nil)))   ; no arrows (audit G4)
    (should-not nidhogg-wrap-column)
    (dolist (v '(column bounded))
      (let ((drgnx-editing-word-wrap v) (drgnx-editing-word-wrap-column 72)) (drgnx-editing--wrap-buffer))
      (should-not truncate-lines)
      (should (eql nidhogg-wrap-column 72)))
    (let ((drgnx-editing-word-wrap 'auto)) (drgnx-editing--wrap-buffer))   ; code: cut
    (should truncate-lines)
    (should-not nidhogg-wrap-column)))

(ert-deftest drgnx-editing-settings/auto-cuts-data-and-code-and-wraps-prose ()
  (pcase-dolist (`(,mode ,want) '((yaml-ts-mode off) (html-mode off) (mhtml-mode off) (css-mode off)
                                  (conf-toml-mode off) (python-mode off) (emacs-lisp-mode off)
                                  (org-mode on) (markdown-ts-mode on) (text-mode on)))
    (when (fboundp mode)
      (drgnx-editing-settings--in mode
        (should (eq major-mode mode))
        (should (equal (list mode (drgnx-editing-wrap-resolve 'auto)) (list mode want))))))
  ;; a special buffer is left alone
  (drgnx-editing-settings--in #'special-mode
    (should-not (drgnx-editing-wrap-resolve 'auto))
    (should-not (drgnx-editing-wrap-resolve 'on))))

(ert-deftest drgnx-editing-settings/a-mode-entry-wins-over-auto ()
  ;; a `(:mode python-mode (drgnx-editing-word-wrap on))' entry is a buffer-local value set before the mode hooks
  (drgnx-editing-settings--in #'python-mode
    (setq-local drgnx-editing-word-wrap 'on)
    (drgnx-editing--wrap-buffer)
    (should-not truncate-lines)
    (should word-wrap)))

(ert-deftest drgnx-editing-settings/a-files-own-truncate-lines-wins ()
  (drgnx-editing-settings--in #'text-mode
    (setq-local file-local-variables-alist '((truncate-lines . t)))
    (setq-local truncate-lines t)
    (let ((drgnx-editing-word-wrap 'auto)) (drgnx-editing--wrap-buffer))
    (should truncate-lines)
    (should-not drgnx-editing--wrap-shown)))

(ert-deftest drgnx-editing-settings/toggle-word-wrap-flips-one-buffer-and-back ()
  (let ((drgnx-editing-word-wrap 'auto) (other (generate-new-buffer " other")))
    (unwind-protect
        (drgnx-editing-settings--in #'python-mode
          (drgnx-editing--wrap-buffer)
          (should truncate-lines)
          (drgnx-editing-toggle-word-wrap)
          (should-not truncate-lines)
          (should word-wrap)
          (drgnx-editing--apply-word-wrap)                  ; a setting change keeps the toggle
          (should-not truncate-lines)
          (drgnx-editing-toggle-word-wrap)
          (should truncate-lines)
          (with-current-buffer other
            (python-mode)
            (drgnx-editing--wrap-buffer)
            (should truncate-lines)
            (should-not drgnx-editing--wrap-toggled)))
      (kill-buffer other))
    ;; the toggle is the buffer's own: a new buffer of the file (what a restart opens) resolves again
    (drgnx-editing-settings--in #'python-mode
      (drgnx-editing--wrap-buffer)
      (should truncate-lines)
      (should-not drgnx-editing--wrap-toggled))))

(ert-deftest drgnx-editing-settings/the-old-wrap-setting-is-gone ()
  (load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
  (should-not (boundp 'drgnx-face-line-wrap))
  (should-not (fboundp 'drgnx-face-toggle-wrap))
  (should (memq 'column (cdr (plist-get (get 'drgnx-editing-word-wrap 'drgnx-setting) :schema)))))
