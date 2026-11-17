;;; quit-dialog-gui-test.el --- GUI test: quitting with changed files asks one Save / Don't Save / Cancel question -*- lexical-binding: t -*-
;; test-class: det
;; The audit's C2: Ctrl+Q (and the close button, and C-x C-c) with changed files showed Emacs' `save-some-buffers'
;; chain.  Real keys go through the command loop; `kill-emacs' is the only stub, so a quit that goes through shows as
;; KILLED.  Cancel keeps everything, Don't Save quits with the file as it was on disk, Save writes it first.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)
(defconst drgnx-ui-quit-dialog--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-ui-quit-dialog--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-ui-quit-dialog--repo))
(require 'drgnx)
(require 'drgnx-session)

;; a quit that asks Emacs' own chain (a prompt that wants other keys) must fail, not wait: the answer is typed or it is red
(defun drgnx-ui-quit-dialog--type (keys)
  (let ((answered (with-timeout (20 'timed-out) (drgnx-uitest-run (drgnx-uitest-key-events keys)) 'done)))
    (when (eq answered 'timed-out)
      (when (active-minibuffer-window) (abort-recursive-edit))
      (ert-fail (list "the quit's question did not end after the keys" keys)))))

(defun drgnx-ui-quit-dialog--disk (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest drgnx-ui-quit-dialog/one-question-with-three-answers ()
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (let* ((dir (file-name-as-directory (make-temp-file "quit-dialog" t)))
         (a (expand-file-name "a.txt" dir)) (b (expand-file-name "b.txt" dir))
         (drgnx-keep-running nil) (killed nil) (questions nil)
         (overriding-local-map (let ((m (make-sparse-keymap)))   ; what `drgnx-session-setup' remaps C-x C-c to, kept off global-map
                                 (define-key m (kbd "C-x C-c") #'drgnx-session-close-frame) m))
         ba bb)
    (write-region "a\n" nil a nil 'silent) (write-region "b\n" nil b nil 'silent)
    (setq ba (find-file-noselect a) bb (find-file-noselect b))
    (unwind-protect
        (cl-letf (((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t)))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) (push 'yes-or-no-p questions) nil))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) (push 'y-or-n-p questions) nil)))
          (set-window-buffer (selected-window) ba)
          (with-current-buffer ba (insert "changed a\n"))
          (with-current-buffer bb (insert "changed b\n"))
          ;; Cancel (c, and Escape): nothing happens, no Emacs question follows
          (drgnx-ui-quit-dialog--type "C-x C-c c")
          (should-not killed) (should-not (active-minibuffer-window))
          (should (buffer-modified-p ba)) (should (buffer-modified-p bb))
          (drgnx-ui-quit-dialog--type "C-x C-c ESC")
          (should-not killed) (should (buffer-modified-p ba))
          ;; Don't Save: quits, both files as they were on disk
          (drgnx-ui-quit-dialog--type "C-x C-c d")
          (should killed) (should-not (active-minibuffer-window))
          (should (equal "a\n" (drgnx-ui-quit-dialog--disk a)))
          (should (equal "b\n" (drgnx-ui-quit-dialog--disk b)))
          ;; Save All: both written, then it quits
          (setq killed nil)
          (drgnx-ui-quit-dialog--type "C-x C-c s")
          (should killed) (should-not (active-minibuffer-window))
          (should (equal "changed a\na\n" (drgnx-ui-quit-dialog--disk a)))
          (should (equal "changed b\nb\n" (drgnx-ui-quit-dialog--disk b)))
          (should-not (buffer-modified-p ba))
          (should-not questions))             ; Emacs' own question chain never ran
      (dolist (x (list ba bb)) (with-current-buffer x (set-buffer-modified-p nil)) (kill-buffer x))
      (delete-directory dir t))))

(provide 'quit-dialog-gui-test)
;;; quit-dialog-gui-test.el ends here
