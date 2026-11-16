;;; problems-view-test.el --- batch tests: one Problems view of the code's errors and warnings (audit D1) -*- lexical-binding: t -*-
;; test-class: det

;; The 2026-11-16 audit (D1): there were two "Problems": Ctrl+Shift+M showed Flymake's raw list (empty, no header, no
;; "No problems" text) and the status bar's count opened the Notices list.  Now one view lists the code's problems by
;; file, says when there are none, and the Problems command and the status bar's count open it.

(require 'ert)
(require 'cl-lib)
(require 'flymake)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(lang/eglot))

(defun problems-view-test--diagnostics ()
  "What Flymake holds for the current buffer here: one warning on line 1 and one error on line 2 (Flymake's own
backends and timers are not run: the view only reads `flymake-diagnostics')."
  (list (flymake-make-diagnostic (current-buffer) (point-min) (1+ (point-min)) :warning "unused variable")
        (flymake-make-diagnostic (current-buffer) (save-excursion (goto-char (point-min)) (forward-line 1) (point))
                                 (save-excursion (goto-char (point-min)) (forward-line 1) (line-end-position))
                                 :error "wrong type argument")))

(ert-deftest problems-view/lists-the-codes-problems-by-file ()
  "Errors first, then warnings, each with its place; the file's name heads them; Return goes there."
  (let* ((dir (file-name-as-directory (make-temp-file "problems" t)))
         (file (expand-file-name "a.el" dir)) buf view)
    (unwind-protect
        (progn
          (write-region "(a)\n(b)\n" nil file nil 'silent)
          (setq buf (find-file-noselect file))
          (with-current-buffer buf (setq-local flymake-mode t))   ; the flag the view reads, not the mode's timers
          (cl-letf (((symbol-function 'flymake-diagnostics) (lambda (&rest _) (problems-view-test--diagnostics))))
            (let ((groups (drgnx-problems-collect dir)))
              (should (equal (mapcar #'car groups) (list file)))
              (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r) (nth 3 r))) (cdar groups))
                             '((error "wrong type argument" 2) (warning "unused variable" 1)))))
            (cl-letf (((symbol-function 'pop-to-buffer) (lambda (b &rest _) (set-buffer b)))
                      ((symbol-function 'drgnx-problems--root-here) (lambda () dir)))
              (setq view (drgnx-problems-show))))
          (with-current-buffer view
            (should (derived-mode-p 'drgnx-problems-mode))
            (should (string-match-p "\\`a\\.el" (buffer-string)))
            (should (string-match-p "wrong type argument.*\\[Ln 2, Col 1\\]" (buffer-string)))
            (goto-char (point-min))
            (search-forward "wrong type")
            (cl-letf (((symbol-function 'pop-to-buffer) (lambda (b &rest _) (set-buffer b))))
              (drgnx-problems-goto)
              (should (eq (current-buffer) buf))
              (should (= (line-number-at-pos) 2)))))
      (when (buffer-live-p buf) (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf))
      (when-let* ((b (get-buffer "*drgnx problems*"))) (kill-buffer b))
      (delete-directory dir t))))

(ert-deftest problems-view/says-when-there-are-none ()
  "With nothing to show, the view says so in VS Code's words, never a blank buffer."
  (unwind-protect
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (b &rest _) (set-buffer b)))
                ((symbol-function 'drgnx-problems--root-here) (lambda () (make-temp-name "/nonexistent/"))))
        (with-current-buffer (drgnx-problems-show)
          (should (string-search "No problems have been detected in the workspace." (buffer-string)))))
    (when-let* ((b (get-buffer "*drgnx problems*"))) (kill-buffer b))))

(ert-deftest problems-view/the-problems-command-opens-it ()
  "Ctrl+Shift+M (`code-problems') runs the Problems view, not Flymake's raw list."
  (drgnx-test-with-modules '(lang/eglot)
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'code-problems)) 'drgnx-problems-show))))

(provide 'problems-view-test)
;;; problems-view-test.el ends here
