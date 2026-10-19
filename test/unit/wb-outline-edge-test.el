;;; wb-outline-edge-test.el --- batch tests: the Outline section, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-outline)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-outline-edge-test--with (src &rest body)
  "BODY with SRC an elisp buffer in the editor and the Outline shown in the dock."
  (declare (indent 1))
  `(drgnx-test-with-clock (:allow-pending t)
     (let ((drgnx-wb--sections nil) (drgnx-signal--subscribers nil) (drgnx-signal--editor-window nil)
           (,src (generate-new-buffer "outline-edge-src.el")))
       (delete-other-windows)
       (with-current-buffer ,src
         (insert "(defun alpha () 1)\n")
         (emacs-lisp-mode))
       (switch-to-buffer ,src)
       (setq drgnx-signal--editor-window (selected-window))
       (drgnx-outline-setup)
       (drgnx-wb-show-sidebar)
       (unwind-protect (progn (drgnx-outline-refresh) ,@body)
         (drgnx-timer-cancel 'outline-refresh)
         (drgnx-outline--watch nil)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (kill-buffer ,src)
         (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name))))))

(defun drgnx-outline-edge-test--watched-p (buffer)
  (memq #'drgnx-outline--changed (buffer-local-value 'after-change-functions buffer)))

(ert-deftest drgnx-outline-edge/a-hidden-outline-stops-watching-at-the-next-pause ()
  "M3d-6: hidden, the Outline lets go of the source's after-change hook."
  (drgnx-outline-edge-test--with src
    (should (drgnx-outline-edge-test--watched-p src))
    (drgnx-wb-hide-sidebar)
    (with-current-buffer src (goto-char (point-max)) (insert "(defun beta () 2)\n"))
    (drgnx-outline--idle)                          ; the pause
    (should-not (drgnx-outline-edge-test--watched-p src))
    (should-not drgnx-outline--source)
    (drgnx-wb-show-sidebar)                        ; :on-show watches again
    (should (drgnx-outline-edge-test--watched-p src))))

(ert-deftest drgnx-outline-edge/a-hidden-outline-stops-watching-when-the-editor-changes ()
  (drgnx-outline-edge-test--with src
    (drgnx-wb-hide-sidebar)
    (drgnx-outline-refresh)                        ; the bus's editor-changed edge
    (should-not (drgnx-outline-edge-test--watched-p src))))

(ert-deftest drgnx-outline-edge/a-remote-file-gets-a-notice-and-no-index ()
  (drgnx-outline-edge-test--with src
    (let ((n 0))
      (cl-letf* ((orig (symbol-function 'imenu--make-index-alist))
                 ((symbol-function 'imenu--make-index-alist) (lambda (&rest a) (setq n (1+ n)) (apply orig a)))
                 ((symbol-function 'file-remote-p) (lambda (f &rest _) (and (stringp f) (string-prefix-p "/ssh:" f)))))
        (with-current-buffer src (setq buffer-file-name "/ssh:nobody@example.invalid:/x.el"))
        (unwind-protect
            (progn
              (drgnx-outline-refresh)
              (with-current-buffer drgnx-outline-buffer-name (drgnx-view-draw-now drgnx-view))
              (should (= n 0))
              (should (equal (append drgnx-outline--rows nil) nil))
              (should (string-match-p "off for remote files"
                                      (with-current-buffer drgnx-outline-buffer-name (buffer-string)))))
          (with-current-buffer src (setq buffer-file-name nil)))))))

;;; wb-outline-edge-test.el ends here
