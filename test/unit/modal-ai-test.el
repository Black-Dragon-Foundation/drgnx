;;; modal-ai-test.el --- batch tests: AI ghost text and the selection with and without Vim keys -*- lexical-binding: t -*-
;; The tests that load evil are test/unit/isolated/modal-ai-isolated.el, run in a fresh batch Emacs
;; (docs/develop/harness.md, "Modal tests"); this file starts them.  The VS Code (and Emacs) stack has no engine:
;; that test runs here, where evil is never loaded.
(require 'ert)
(require 'drgnx)
(require 'drgnx-modal)
(load (expand-file-name "modules/tools/drgnx-ai-ui" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-modal-ai/own-process ()
  (should (null (drgnx-test-run-isolated "test/unit/isolated/modal-ai-isolated.el" "^drgnx-modal-ai/"))))

(ert-deftest drgnx-modal-ai/vscode-stack-unchanged ()
  ;; no engine: nothing inhibits ghost text, a pause asks in any code buffer, and the selection is the region
  (should-not (featurep 'evil))
  (should-not drgnx-modal-running)
  (should-not drgnx-ai-ghost-inhibit-functions)
  (should-not drgnx-modal-selection-function)
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-modal-ai" t)))
         (port nil) (script (concat root "llm.eld"))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config")) process-environment))
         (drgnx-ai-detected '((o :up t))) (drgnx-ai-ghost--said-unavailable nil)
         (drgnx-ai-providers nil) (drgnx-ai-roles nil)
         (mock nil))
    (unwind-protect
        (progn
          (make-directory (concat root "config") t)
          (with-temp-file script (prin1 '((:path "/api/generate" :body "{\"response\":\"(message name)\"}")) (current-buffer)))
          (setq mock (drgnx-ai-test-mock-llm nil script)
                port (process-get mock :port))
          (setq drgnx-ai-providers `((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim)))
                drgnx-ai-roles '((complete (o . "coder"))))
          (with-temp-buffer
            (emacs-lisp-mode)
            (drgnx-ai-ghost-mode 1)
            (insert "(defun greet (name)\n  ")
            (save-excursion (insert "\n  name)\n"))
            (drgnx-ai-ghost--trigger)
            (let ((deadline (+ (float-time) 5)))
              (while (and (not (drgnx-ai-ghost-text)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
            (should (equal (drgnx-ai-ghost-text) "(message name)"))
            (drgnx-ai-ghost--clear)
            ;; Edit with AI: the active region, else the defun at point
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "shorter")))
              (let ((spec (cadr (interactive-form 'drgnx-ai-edit))))
                (should (equal (advice-eval-interactive-spec spec) (list "shorter" (point-min) (point-max))))
                (let ((transient-mark-mode t))
                  (set-mark 2) (goto-char 7) (activate-mark)
                  (should (equal (advice-eval-interactive-spec spec) '("shorter" 2 7))))))))
      (when mock (delete-process mock))
      (delete-directory root t))))

(provide 'modal-ai-test)
;;; modal-ai-test.el ends here
