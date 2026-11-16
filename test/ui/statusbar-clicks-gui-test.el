;;; statusbar-clicks-gui-test.el --- GUI tests: the bar across the frame, clicked and read with no file open (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Audit B3: a real click on a status bar segment (the shield) runs its command in the editor and leaves the focus in
;; the editor, not in the bar's own window.  Audit L4: with no file open (a page in front, in a git folder) the bar
;; still shows the branch.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-statusbar-clicks--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-statusbar-clicks--repo)))
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar"))
  (load (expand-file-name (concat "modules/" m) drgnx-ui-statusbar-clicks--repo) nil t))
(require 'drgnx-state)
(require 'drgnx-pixels)

(defun drgnx-ui-statusbar-clicks--forget-transient-clears ()
  "Take the `clear-transient-map' hooks a pointer's press leaves on `pre-command-hook'."
  (dolist (b (cons nil (buffer-list)))
    (with-current-buffer (or b (current-buffer))
      (dolist (f (copy-sequence (if b (and (local-variable-p 'pre-command-hook) pre-command-hook)
                                  (default-value 'pre-command-hook))))
        (when (and (symbolp f) (equal (symbol-name f) "clear-transient-map"))
          (remove-hook 'pre-command-hook f (and b t)))))))

(defvar drgnx-ui-statusbar-clicks--ran nil "The windows a segment's click ran in.")

(defmacro drgnx-ui-statusbar-clicks--with (&rest body)
  "BODY in the root frame with the bar across it, segments `shield' (text SHIELD, a click that records its window) and
`branch' as the module defines it, a page (no file) in the editor; everything put back after."
  (declare (indent 0))
  `(let* ((root (drgnx-uitest-root-frame))
          (config (with-selected-frame root (current-window-configuration)))
          (state-was (bound-and-true-p drgnx-state-mode)) (bar-was (bound-and-true-p drgnx-statusbar-mode))
          (drgnx-statusbar-place 'frame)
          (drgnx-statusbar--segments (make-hash-table :test #'eq)) (drgnx-statusbar--texts (make-hash-table :test #'eq))
          (drgnx-statusbar--errors nil)
          (drgnx-statusbar-left '(shield branch)) (drgnx-statusbar-right nil)
          ;; the page's bar: the default's items, and the shield
          (drgnx-statusbar-other (cons 'shield (default-value 'drgnx-statusbar-other)))
          (page (get-buffer-create "*sb-clicks page*")))
     (setq drgnx-ui-statusbar-clicks--ran nil)
     (unwind-protect
         (with-selected-frame root
           (delete-other-windows)
           (with-current-buffer page (special-mode))
           (switch-to-buffer page)
           (drgnx-statusbar-define-segment 'shield :fn (lambda () "SHIELD")
                                           :click (lambda () (interactive) (push (selected-window) drgnx-ui-statusbar-clicks--ran)))
           (drgnx-statusbar-define-segment 'branch :fn #'drgnx-statusbar--seg-branch)
           (drgnx-state-mode 1)
           (drgnx-state-define-role 'statusbar)
           (drgnx-statusbar-mode 1)
           (drgnx-statusbar--frame-ensure root)
           (drgnx-test-wait-presented)
           ,@body)
       (with-selected-frame root
         (drgnx-statusbar-mode (if bar-was 1 -1))
         (drgnx-state-mode (if state-was 1 -1))
         (dolist (w (window-list root 'nomini))
           (when (eq (window-parameter w 'drgnx-role) 'statusbar) (ignore-errors (delete-window w))))
         (dolist (w (window-list root 'nomini))
           (dolist (p '(tab-line-format header-line-format mode-line-format)) (set-window-parameter w p nil)))
         (setq overriding-terminal-local-map nil)
         (drgnx-ui-statusbar-clicks--forget-transient-clears)
         (set-window-configuration config))
       (kill-buffer page))))

(defun drgnx-ui-statusbar-clicks--bar ()
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-role) 'statusbar)) (window-list nil 'nomini)))

(ert-deftest drgnx-ui-statusbar-clicks/a-click-on-the-shield-leaves-focus-in-the-editor ()
  "A real pointer click on a segment of the frame's bar runs its command with the editor selected, and the editor is
still the selected window after it (the click selected the bar's own window; the audit saw the next command run there)."
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-ui-statusbar-clicks--with
    (let* ((bar (drgnx-ui-statusbar-clicks--bar)) (editor (drgnx-state-editor-window))
           (edges (window-pixel-edges bar))
           (x (+ (nth 0 edges) (drgnx-px 20)))
           (y (- (nth 3 edges) (max 1 (/ (window-mode-line-height bar) 2)))))
      (should (window-live-p bar))
      (should (window-live-p editor))
      (should (drgnx-uitest-pointer-click x y (lambda () drgnx-ui-statusbar-clicks--ran)))
      (should (eq editor (car drgnx-ui-statusbar-clicks--ran)))
      (drgnx-test-wait-presented)
      (should-not (drgnx-statusbar--frame-window-p (selected-window)))
      (should (eq editor (selected-window))))))

(ert-deftest drgnx-ui-statusbar-clicks/the-branch-shows-with-no-file-open ()
  "A page that is no file in front, in a git folder: the bar names the branch."
  (cl-letf (((symbol-function 'drgnx-statusbar--git-branch) (lambda () (list :head "audit-branch"))))
    (drgnx-ui-statusbar-clicks--with
      (let ((text (format-mode-line drgnx-statusbar--frame-host nil (drgnx-ui-statusbar-clicks--bar))))
        (should (string-match-p "audit-branch" (substring-no-properties text)))))))

(provide 'statusbar-clicks-gui-test)
;;; statusbar-clicks-gui-test.el ends here
