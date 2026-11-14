;;; look-editor-test.el --- the editor's chrome: cursor, current line, blame hint, inlay hints -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the buffer settings are read from a file-visiting code buffer; the blame hint's faces and gap
;; from its overlay's string; the inlay hint face from its spec.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-pixels)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-blame" drgnx-dir) nil t)

(ert-deftest drgnx-look-editor/cursor-and-current-line ()
  "Pattern D: a code buffer that visits a file gets the two-pixel bar cursor and the current line across the full
width; a text buffer with no file keeps Emacs's own cursor and has no current line mark; a cursor a mode set (the
modal box) stays."
  (with-temp-buffer
    (setq buffer-file-name "/nonexistent/look-editor.el")
    (emacs-lisp-mode)
    (drgnx-face-editor-maybe)
    (unwind-protect
        (progn
          (should (equal '(bar . 2) cursor-type))
          (should hl-line-mode)
          (should (face-attribute 'hl-line :extend nil 'default)))
      (drgnx-face-editor-clear)
      (should (eq t cursor-type))
      (should-not hl-line-mode)))
  (with-temp-buffer
    (text-mode)
    (drgnx-face-editor-maybe)
    (should (eq t cursor-type))
    (should-not hl-line-mode))
  (with-temp-buffer
    (setq buffer-file-name "/nonexistent/look-editor.el")
    (emacs-lisp-mode)
    (setq-local cursor-type 'box)
    (drgnx-face-editor-maybe)
    (unwind-protect (should (eq 'box cursor-type)) (drgnx-face-editor-clear))))

(ert-deftest drgnx-look-editor/blame-hint-faces-and-gap ()
  "Pattern D: the blame hint is italic subtle text in the caption face, after a gap of 24 logical pixels drawn as a
space of that width."
  (should (eq 'italic (face-attribute 'drgnx-blame :slant nil t)))
  (let ((inherit (ensure-list (face-attribute 'drgnx-blame :inherit))))
    (should (memq 'drgnx-text-subtle inherit))
    (should (memq 'drgnx-ui-caption inherit)))
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (insert "x = 1")
    (drgnx-blame--show (list :sha (make-string 40 ?a) :author "Ada" :time nil :summary "Fix the thing"))
    (let* ((s (overlay-get drgnx-blame--overlay 'after-string))
           (gap (get-text-property 0 'display s)))
      (should (equal `(space :width (,(round (* 24 (drgnx-pixels-scale))))) gap))
      (should (string-search "Ada" s))
      (should (eq 'drgnx-blame (get-text-property (string-search "Ada" s) 'face s))))))

(ert-deftest drgnx-look-editor/inlay-hint-inherits ()
  "Pattern D: the inlay hint face inherits the caption face and the subtle text colour, on the quiet selection, and
`eglot-inlay-hint-face' takes it once eglot is loaded."
  (let* ((inherit (ensure-list (face-attribute 'drgnx-inlay-hint :inherit))))
    (should (memq 'drgnx-ui-caption inherit))
    (should (memq 'drgnx-text-subtle inherit))
    (should (memq 'drgnx-selected-quiet inherit))
    (should (< (seq-position inherit 'drgnx-text-subtle) (seq-position inherit 'drgnx-selected-quiet)))))

(provide 'look-editor-test)
;;; look-editor-test.el ends here
