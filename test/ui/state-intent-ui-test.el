;;; state-intent-ui-test.el --- GUI tests: a size you set by hand is intent and docks keep it (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-intent-test--repo                         ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-ui-intent-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-ui-intent-test--repo))
(require 'drgnx-wb)
(require 'drgnx-state)

(defvar drgnx-ui-intent-test--seen nil "The `pane-resized' events seen, newest first: (CAUSE BY ROLE COMMAND).")

(defun drgnx-ui-intent-test--see (data)
  (push (list (plist-get data :cause) (plist-get data :by) (drgnx-state-window-role (plist-get data :window))
              this-command drgnx-state--in-command)
        drgnx-ui-intent-test--seen))

(defun drgnx-ui-intent-test--wait (pred &optional secs)
  "Wait until PRED, up to SECS (default 3) seconds; return its value."
  (let ((deadline (+ (float-time) (or secs 3))) (v nil))
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (sit-for 0.05))
    v))

(ert-deftest drgnx-state-intent-ui/a-dragged-dock-keeps-its-width-when-the-frame-resizes ()
  ;; The left dock dragged wider on its divider, then the frame made narrower the way a window manager does it:
  ;; the dock keeps the width you gave it, and the width is your intent.
  (let* ((root (drgnx-uitest-root-frame))
         (config (with-selected-frame root (current-window-configuration)))
         (size (list (frame-pixel-width root) (frame-pixel-height root)))
         (saved (mapcar (lambda (p) (cons p (frame-parameter root p))) '(drgnx-wb-dock-px drgnx-intent-by))))
    (unwind-protect
        (progn
          (drgnx-state-mode 1)
          (setq drgnx-ui-intent-test--seen nil)
          (drgnx-state-subscribe 'pane-resized #'drgnx-ui-intent-test--see :lane 'now)
          (drgnx-state-subscribe 'pane-resized #'drgnx-state-intent--user-resized)
          (drgnx-wb-define-section 'st-intent-ui :slot 0 :title " DOCK"
                                   :buffer (lambda () (get-buffer-create " *st-intent-ui*")))
          (with-selected-frame root
            (set-frame-parameter root 'drgnx-wb-dock-px nil)
            (delete-other-windows)
            (drgnx-wb-show-sidebar))
          (let* ((dock (car (drgnx-wb--dock-windows root)))
                 (before (window-pixel-width dock))
                 (x (1- (nth 2 (window-pixel-edges dock)))) (y (/ (frame-pixel-height root) 2))
                 (from (posn-at-x-y x y root)) (to (posn-at-x-y (+ x 80) y root)))
            (should (eq 'vertical-line (posn-area from)))
            (let ((r (drgnx-uitest-run (drgnx-uitest-drag-events from to :lazy t))))
              (should (eq t (plist-get r :settled))))
            (let ((dragged (window-pixel-width dock)))
              (should (> dragged (+ before 40)))
              ;; the drag is noted once Emacs is idle
              (unless (drgnx-ui-intent-test--wait
                       (lambda () (equal (frame-parameter root 'drgnx-wb-dock-px) dragged)))
                (ert-fail (list "the drag was not noted" drgnx-ui-intent-test--seen
                                (frame-parameter root 'drgnx-wb-dock-px))))
              (should (eq 'user (plist-get (drgnx-state-intent root :sizes 'left) :by)))
              ;; the window manager makes the frame narrower
              (set-frame-size root (- (car size) 200) (cadr size) t)
              (drgnx-uitest-run nil)
              (should (<= (abs (- dragged (window-pixel-width dock))) 1)))))
      (ignore-errors (drgnx-wb-hide-sidebar))
      (drgnx-wb-undefine-section 'st-intent-ui)
      (drgnx-state-unsubscribe 'pane-resized #'drgnx-state-intent--user-resized)
      (drgnx-state-unsubscribe 'pane-resized #'drgnx-ui-intent-test--see)
      (drgnx-state-mode -1)
      (pcase-dolist (`(,p . ,v) saved) (set-frame-parameter root p v))
      (set-frame-size root (car size) (cadr size) t)
      (with-selected-frame root (set-window-configuration config))
      (when (get-buffer " *st-intent-ui*") (kill-buffer " *st-intent-ui*")))))

;;; state-intent-ui-test.el ends here
