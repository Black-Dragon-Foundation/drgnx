;;; grid-on-fixture.el --- the grid on, for the batch tests of the docks and areas -*- lexical-binding: t -*-
;; Docks and areas are tiles of the grid (there are no side windows): a batch test that shows one runs with the grid on.
(defvar drgnx-grid-mode)

(defmacro drgnx-test-with-grid-on (&rest body)
  "BODY with `drgnx-grid-mode' on, and as it was after."
  (declare (indent 0))
  `(let ((grid-was (progn (require 'drgnx-grid) drgnx-grid-mode)))
     ;; room for a dock beside an editor, as the grid fixture's frame has
     (when (and (not (display-graphic-p)) (< (frame-width) 120)) (set-frame-size nil 160 50))
     (unless grid-was (drgnx-grid-mode 1))
     (unwind-protect (progn ,@body)
       (unless grid-was
         (drgnx-grid-mode -1)
         ;; a row that made or replaced frames meanwhile: every frame and window is as it was before the grid
         (dolist (f (frame-list))
           (dolist (p '(drgnx-grid-next-id drgnx-grid-memory drgnx-grid--good drgnx-grid--docks))
             (set-frame-parameter f p nil))
           (dolist (w (window-list f))
             (dolist (p '(drgnx-tile-id no-delete-other-windows delete-window))
               (set-window-parameter w p nil))))))))

;; The GUI rows of a file that shows docks and areas all run with the grid on: the file loads this and calls
;; `drgnx-test-grid-on-for-file'.
(defun drgnx-test-grid-on--run-test (orig test &rest args)
  "Around `ert-run-test': the row runs with the grid on."
  (drgnx-test-with-grid-on (apply orig test args)))

(defun drgnx-test-grid-on-for-file ()
  "Every row run from here on in this Emacs runs with the grid on (a file's rows: each file has its own Emacs)."
  ;; innermost (depth 100): the leak census wraps `ert-run-test' too and must see the session without the grid
  (advice-add 'ert-run-test :around #'drgnx-test-grid-on--run-test '((depth . 100))))

(provide 'grid-on-fixture)
;;; grid-on-fixture.el ends here
