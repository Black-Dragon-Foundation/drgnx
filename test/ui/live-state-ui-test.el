;;; live-state-ui-test.el --- GUI tests: the Live view follows its window through the state store (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-live-ui-test--repo                           ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-live-ui-test--repo)))
(require 'drgnx-wb)
(require 'drgnx-state)
(load (expand-file-name "modules/tools/drgnx-live" drgnx-live-ui-test--repo) nil t)

(defun drgnx-live-ui-test--wait (pred &optional secs)
  "Wait until PRED, up to SECS (default 3) seconds; return its value."
  (let ((deadline (+ (float-time) (or secs 3))) (v nil))
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (sit-for 0.05))
    v))

(ert-deftest drgnx-live-ui/a-resize-reaches-the-view ()
  ;; The view's window made narrower (C-x {): the store sees the window change size, and the view asks the
  ;; browser for frames as wide as the window is now.
  (let* ((root (drgnx-uitest-root-frame))
         (config (with-selected-frame root (current-window-configuration)))
         (buf (generate-new-buffer " *live-ui*")) (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-live--send)
                   (lambda (method &optional params &rest _) (push (cons method params) sent))))
          (drgnx-state-mode 1)
          (drgnx-live--subscribe)
          (with-selected-frame root
            (delete-other-windows)
            (switch-to-buffer buf)
            (drgnx-live-mode)
            (set-window-buffer (split-window-right) (get-buffer-create "*scratch*"))
            (setq drgnx-live--session "S" drgnx-live--max-width (window-body-width (selected-window) t)))
          (drgnx-uitest-run nil)
          (let* ((win (get-buffer-window buf root)) (before (window-body-width win t)))
            (should (eq win (drgnx-state-editor-window root)))
            (select-frame-set-input-focus root)
            (select-window win)
            (drgnx-uitest-run (list ?\C-u ?2 ?0 ?\C-x ?{))      ; shrink-window-horizontally by 20 columns
            (should (< (window-body-width win t) before))
            (let ((now (window-body-width win t)))
              (unless (drgnx-live-ui-test--wait
                       (lambda () (equal now (plist-get (cdr (assoc "Page.startScreencast" sent)) :maxWidth))))
                (ert-fail (list "the screencast did not follow the window" now before sent (buffer-local-value 'drgnx-live--max-width buf)))))
            (should (assoc "Page.stopScreencast" sent))))
      (drgnx-state-unsubscribe 'windows-changed #'drgnx-live--shown-again)
      (drgnx-state-unsubscribe 'pane-resized #'drgnx-live--resized)
      (drgnx-state-mode -1)
      (when (buffer-live-p buf) (kill-buffer buf))
      (with-selected-frame root (set-window-configuration config)))))

;;; live-state-ui-test.el ends here
