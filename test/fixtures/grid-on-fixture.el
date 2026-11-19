;;; grid-on-fixture.el --- the grid on, for the batch tests of the docks and areas -*- lexical-binding: t -*-
;; Docks and areas are tiles of the grid (there are no side windows): a batch test that shows one runs with the grid on.
(require 'drgnx-grid)

(defmacro drgnx-test-with-grid-on (&rest body)
  "BODY with `drgnx-grid-mode' on, and as it was after."
  (declare (indent 0))
  `(let ((grid-was drgnx-grid-mode))
     ;; room for a dock beside an editor, as the grid fixture's frame has
     (when (and (not (display-graphic-p)) (< (frame-width) 120)) (set-frame-size nil 160 50))
     (unless grid-was (drgnx-grid-mode 1))
     (unwind-protect (progn ,@body)
       (unless grid-was
         (drgnx-grid-mode -1)
         (dolist (p '(drgnx-grid-next-id drgnx-grid-memory drgnx-grid--good drgnx-grid--docks))
           (set-frame-parameter nil p nil))))))

(provide 'grid-on-fixture)
;;; grid-on-fixture.el ends here
