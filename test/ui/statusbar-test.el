;;; statusbar-test.el --- GUI tests: the status bar follows point and the text on a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defconst drgnx-statusbar-ui-test--repo                     ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-statusbar-ui-test--repo)))
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar"))
  (load (expand-file-name (concat "modules/" m) drgnx-statusbar-ui-test--repo) nil t))
(load (expand-file-name "test/fixtures/state-fixture" drgnx-statusbar-ui-test--repo) nil t)
(require 'drgnx-state)

(defvar drgnx-statusbar-ui-test--seen nil "Window points at which redisplay evaluated the probe segment, newest first.")

(ert-deftest drgnx-ui-statusbar/the-bar-follows-point-and-edits ()
  (let ((buf (get-buffer-create "*drgnx-statusbar-lines*"))
        (state-was (bound-and-true-p drgnx-state-mode))
        (drgnx-statusbar--segments (make-hash-table :test #'eq))
        (drgnx-statusbar--errors nil)
        (drgnx-statusbar-left '(pct))
        (drgnx-statusbar-right '(probe position))
        (drgnx-statusbar-ui-test--seen nil))
    (with-current-buffer buf
      (emacs-lisp-mode)
      (erase-buffer)
      (dotimes (i 40) (insert (format "line %02d\n" i)))
      (goto-char (point-min)))
    (with-selected-frame (drgnx-uitest-root-frame)
      (delete-other-windows)
      (switch-to-buffer buf)
      (let ((w (selected-window)))
        (unwind-protect
            (progn
              (drgnx-state-mode 1)             ; the full bar is the store's editor window's
              (drgnx-statusbar--define-defaults)
              ;; evaluated only when redisplay draws the mode line: what a keypress did not redraw stays stale
              (drgnx-statusbar-define-segment
               'probe :fn (lambda () (push (window-point (drgnx-statusbar-source-window)) drgnx-statusbar-ui-test--seen) "."))
              (drgnx-statusbar-define-segment 'pct :fn (lambda () "feat-100%b-x"))
              (set-window-parameter w 'mode-line-format drgnx-statusbar--host)
              (add-hook 'post-command-hook #'drgnx-statusbar--post-command)
              (redisplay t)
              (should (= (car drgnx-statusbar-ui-test--seen) (window-point w)))
              ;; moving point: a redraw, and the bar says the new line
              (should (eq (plist-get (drgnx-uitest-run (drgnx-uitest-key-events "C-n C-n C-n C-f")) :settled) t))
              (should (= (car drgnx-statusbar-ui-test--seen) (window-point w)))
              (should (string-match-p "Ln 4, Col 2" (format-mode-line drgnx-statusbar--host nil w)))
              ;; typing: a redraw at every character, and the column moves
              (should (eq (plist-get (drgnx-uitest-run (drgnx-uitest-type-events "xyz")) :settled) t))
              (should (= (car drgnx-statusbar-ui-test--seen) (window-point w)))
              (should (string-match-p "Ln 4, Col 5" (format-mode-line drgnx-statusbar--host nil w)))
              ;; a % in a segment is text: the bar shows it, not the buffer name
              (let ((bar (format-mode-line drgnx-statusbar--host nil w)))
                (should (string-match-p "feat-100%b-x" bar))
                (should-not (string-match-p (regexp-quote (buffer-name buf)) bar))))
          (remove-hook 'post-command-hook #'drgnx-statusbar--post-command)
          (drgnx-state-mode (if state-was 1 -1))
          (set-window-parameter w 'mode-line-format nil)
          (set-buffer-modified-p nil)
          (kill-buffer buf))))))

(ert-deftest drgnx-ui-statusbar/only-the-window-you-are-in-shows-the-selection ()
  "One buffer in two windows, a region in the selected one: redisplay draws `(N selected)' in that window's bar only
\(while a mode line is drawn its window is the selected one; the bar asks `mode-line-window-selected-p')."
  (let ((buf (get-buffer-create "*drgnx-statusbar-selection*"))
        (drgnx-statusbar--segments (make-hash-table :test #'eq))
        (drgnx-statusbar--errors nil)
        (drgnx-statusbar-left nil) (drgnx-statusbar-right '(probe)) (drgnx-statusbar-compact '(probe))
        (transient-mark-mode t)
        (seen nil))
    (with-current-buffer buf
      (emacs-lisp-mode)
      (erase-buffer)
      (insert "one two three four\n"))
    (with-selected-frame (drgnx-uitest-root-frame)
      (delete-other-windows)
      (switch-to-buffer buf)
      (let* ((w (selected-window)) (other (split-window-right)))
        (unwind-protect
            (progn
              (drgnx-statusbar--define-defaults)
              ;; evaluated by redisplay for each window's bar: what that bar's position segment says
              (drgnx-statusbar-define-segment
               'probe :fn (lambda () (push (cons (drgnx-statusbar-source-window) (drgnx-statusbar--seg-position)) seen) "."))
              (dolist (x (list w other)) (set-window-parameter x 'mode-line-format drgnx-statusbar--host))
              (set-window-point other 3)
              (goto-char 9)
              (push-mark 1 t t)
              (setq seen nil)
              (force-mode-line-update t)
              (redisplay t)
              (should (string-match-p "(8 selected)" (or (cdr (assq w seen)) "")))
              (should (assq other seen))
              (should-not (string-match-p "selected" (cdr (assq other seen)))))
          (deactivate-mark)
          (dolist (x (list w other)) (when (window-live-p x) (set-window-parameter x 'mode-line-format nil)))
          (when (window-live-p other) (delete-window other))
          (kill-buffer buf))))))

;;; statusbar-test.el ends here
