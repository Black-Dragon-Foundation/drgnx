;;; wb-cover-test.el --- batch tests: a hovered row's cover is owned and removed -*- lexical-binding: t -*-
;; test-class: det
;; The cover (`drgnx-wb-cover-sense') draws a long name's control over its end while the pointer is on the row.  Its
;; overlay is one per window, detached when the pointer leaves the row, gone with its buffer or window, and removed
;; everywhere when a module that set the covers up is turned off.  (The drawing itself needs a display: the GUI row
;; drgnx-ui-look-explorer-cover/a-long-name-gets-its-dots-over-it-on-hover.)

(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-wb)

(defmacro drgnx-wb-cover-test--with-rows (&rest body)
  "BODY in a temp buffer of two rows, the first with a cover in the selected window; COVER is it."
  (declare (indent 0))
  `(with-temp-buffer
     (insert "a-long-name\nanother\n")
     (let ((cover (make-overlay 5 12 nil t)))
       (overlay-put cover 'drgnx-wb-cover t)
       (overlay-put cover 'drgnx-row-bol 1)
       (setq drgnx-wb--covers (list (cons (selected-window) cover)))
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(ert-deftest drgnx-wb-cover/leaving-its-row-detaches-the-cover ()
  "The pointer off another row keeps the cover; off its own row, the cover is detached (kept for the next row)."
  (drgnx-wb-cover-test--with-rows
    (drgnx-wb-cover-sense (selected-window) 14 'left)
    (should (overlay-buffer cover))
    (drgnx-wb-cover-sense (selected-window) 3 'left)
    (should-not (overlay-buffer cover))
    (should (eq cover (cdr (assq (selected-window) drgnx-wb--covers))))))

(ert-deftest drgnx-wb-cover/a-killed-buffer-leaves-no-cover ()
  (let (made)
    (drgnx-wb-cover-test--with-rows (setq made cover))
    (should (overlayp made))
    (should-not (overlay-buffer made))))

(ert-deftest drgnx-wb-cover/turning-the-module-off-removes-every-cover ()
  "A module that set the covers up (`drgnx-wb-covers-setup') removes every buffer's covers when it is off."
  (let ((drgnx-modules--stacks nil))
    (let ((drgnx-modules--current 'cover-test))
      (drgnx-wb-covers-setup "cover-test"))
    (drgnx-wb-cover-test--with-rows
      (dolist (u (alist-get 'cover-test drgnx-modules--stacks)) (funcall (cdr u)))
      (should-not (overlay-buffer cover))
      (should-not drgnx-wb--covers))))

(provide 'wb-cover-test)
;;; wb-cover-test.el ends here
