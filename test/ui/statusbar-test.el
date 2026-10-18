;;; statusbar-test.el --- GUI tests: the status bar follows point and the text on a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defconst drgnx-statusbar-ui-test--repo                     ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-statusbar-ui-test--repo)))
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar"))
  (load (expand-file-name (concat "modules/" m) drgnx-statusbar-ui-test--repo) nil t))

(defvar drgnx-statusbar-ui-test--seen nil "Window points at which redisplay evaluated the probe segment, newest first.")

(ert-deftest drgnx-ui-statusbar/the-bar-follows-point-and-edits ()
  (let ((buf (get-buffer-create "*drgnx-statusbar-lines*"))
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
          (set-window-parameter w 'mode-line-format nil)
          (set-buffer-modified-p nil)
          (kill-buffer buf))))))

;;; statusbar-test.el ends here
