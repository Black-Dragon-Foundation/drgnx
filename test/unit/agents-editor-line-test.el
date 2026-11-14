;;; agents-editor-line-test.el --- the agent line in the header's tail -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  Frames are fed to the module as the hub's events would be; the hub's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-chrome)
(load (expand-file-name "modules/editor/drgnx-sticky" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-large-files" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-agents-editor-sync-windows "drgnx-agents-editor")
(declare-function drgnx-agents-editor-line--provider "drgnx-agents-editor-line")
(defvar drgnx-agents-editor-line--entries)
(defvar drgnx-agents-editor-line-symbol-function)
(defvar drgnx-chrome-short-breadcrumb-functions)

(defvar drgnx-agents-editor-line-test--version 0)

(defmacro drgnx-agents-editor-line-test--with (lines &rest body)
  "BODY in a window showing a file buffer of LINES lines (`buf'), the module on and the large-file header and sticky
scroll's providers registered beside it."
  (declare (indent 1))
  `(let ((dir (make-temp-file "agents-line" t)) (drgnx-agents-editor-line-test--version 0)
         (drgnx-chrome-tail-providers nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
           (drgnx-test-with-modules '(tools/agents-in-editor)
             (save-window-excursion
               (delete-other-windows)
               (let ((buf (find-file-noselect (expand-file-name "a.el" dir))))
                 (unwind-protect
                     (let ((drgnx-agents-editor-line-symbol-function (lambda (_b pos) (format "sym-%d" (line-number-at-pos pos)))))
                       (with-current-buffer buf
                         (insert (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 ,lines) "\n"))
                         (set-buffer-modified-p nil))
                       (set-window-buffer (selected-window) buf)
                       (drgnx-agents-editor-sync-windows)
                       ,@body)
                   (kill-buffer buf))))))
       (dolist (p (copy-sequence drgnx-chrome-tail-providers)) (drgnx-chrome-remove-tail-provider p))
       (delete-directory dir t))))

(defun drgnx-agents-editor-line-test--frame (buf agents)
  (drgnx-agents-editor--event
   "agent-buffer" (list :view (buffer-local-value 'drgnx-agents-editor--view buf) :full t
                        :version (cl-incf drgnx-agents-editor-line-test--version) :agents agents)))

(defun drgnx-agents-editor-line-test--agent (ord line &rest more)
  (append (list :ordinal ord :session (format "s%d" ord) :handle (format "Agent%d" ord) :mode "editing" :line line
                :line_end line :col 0)
          more))

(ert-deftest drgnx-agents-editor/agent-line-is-memoised-per-line ()
  (drgnx-agents-editor-line-test--with 60
    (drgnx-agents-editor-line-test--frame
     buf (list (drgnx-agents-editor-line-test--agent 1 5) (drgnx-agents-editor-line-test--agent 2 50)))
    (let ((w (selected-window)))
      (set-window-point w (with-current-buffer buf (goto-char (point-min)) (forward-line 6) (point)))
      (let ((near-1 (drgnx-agents-editor-line--provider w)))
        (should (string-search "Agent1" near-1))
        (should (string-search "+1" near-1))
        (should (eq near-1 (drgnx-agents-editor-line--provider w)))          ; the same string until the next frame
        (set-window-point w (with-current-buffer buf (goto-char (point-min)) (forward-line 48) (point)))
        (let ((near-2 (drgnx-agents-editor-line--provider w)))
          (should (string-search "Agent2" near-2))
          (should-not (eq near-1 near-2)))
        ;; a new frame rebuilds the strings
        (drgnx-agents-editor-line-test--frame
         buf (list (drgnx-agents-editor-line-test--agent 1 5) (drgnx-agents-editor-line-test--agent 2 50)))
        (set-window-point w (with-current-buffer buf (goto-char (point-min)) (forward-line 6) (point)))
        (let ((again (drgnx-agents-editor-line--provider w)))
          (should (equal near-1 again))
          (should-not (eq near-1 again)))))))

(ert-deftest drgnx-agents-editor/agent-line-names-the-plan-entry ()
  (drgnx-agents-editor-line-test--with 60
    (drgnx-agents-editor-line-test--frame
     buf (list (drgnx-agents-editor-line-test--agent 1 5 :plan_entry "Rename the 100% case" :step_title "ignored")))
    (let ((s (drgnx-agents-editor-line--provider (selected-window))))
      (should (string-search "\"Rename the 100%% case\"" s))                  ; the mode line's % is doubled
      (should (string-search "sym-5" s))
      (should (string-search "editing" s))
      (should (string-search "F follow" s)))
    ;; without a plan entry, the step title
    (drgnx-agents-editor-line-test--frame buf (list (drgnx-agents-editor-line-test--agent 1 5 :step_title "Step 14")))
    (should (string-search "\"Step 14\"" (drgnx-agents-editor-line--provider (selected-window))))))

(ert-deftest drgnx-agents-editor/breadcrumbs-shorten-while-the-agent-line-shows ()
  (drgnx-agents-editor-line-test--with 60
    (should-not (run-hook-with-args-until-success 'drgnx-chrome-short-breadcrumb-functions (selected-window)))
    (drgnx-agents-editor-line-test--frame buf (list (drgnx-agents-editor-line-test--agent 1 5)))
    (should (run-hook-with-args-until-success 'drgnx-chrome-short-breadcrumb-functions (selected-window)))
    (drgnx-agents-editor-line-test--frame buf nil)
    (should-not (run-hook-with-args-until-success 'drgnx-chrome-short-breadcrumb-functions (selected-window)))))

(ert-deftest drgnx-chrome/sticky-scroll-still-shows-as-a-provider ()
  (let ((drgnx-chrome-tail-providers nil) (b (generate-new-buffer "sticky-provider")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer b)
          (insert "(defun drgnx-sticky-test-fn ()\n  \"Doc.\"\n"
                  (mapconcat (lambda (i) (format "  (message \"line %d\")" i)) (number-sequence 1 40) "\n") ")\n")
          (emacs-lisp-mode)
          (drgnx-sticky-mode 1)
          (goto-char (point-min))
          (set-window-start (selected-window) (save-excursion (forward-line 19) (point)))
          (drgnx-chrome-add-tail-provider #'drgnx-sticky--tail 20)
          (should (equal " › drgnx-sticky-test-fn" (substring-no-properties (drgnx-chrome--tail-string (selected-window)))))
          (drgnx-sticky-mode -1)
          (should (equal "" (drgnx-chrome--tail-string (selected-window)))))
      (drgnx-chrome-remove-tail-provider #'drgnx-sticky--tail)
      (kill-buffer b))))

(ert-deftest drgnx-chrome/large-files-header-still-shows ()
  ;; the large-file header is first (depth 10), before the sticky part and the agent line
  (let ((drgnx-chrome-tail-providers nil) (drgnx-chrome-mode t) (b (generate-new-buffer "large-provider")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer b)
          (setq-local drgnx-large-files--header " 412 MB, lean: [Open Raw]")
          (drgnx-chrome-add-tail-provider #'drgnx-sticky--tail 20)
          (drgnx-chrome-add-tail-provider #'drgnx-large-files--tail 10)
          (drgnx-chrome-add-tail-provider #'drgnx-agents-editor-line--provider 30)
          (should (equal '(drgnx-large-files--tail drgnx-sticky--tail drgnx-agents-editor-line--provider)
                         drgnx-chrome-tail-providers))
          (should (string-prefix-p " 412 MB" (drgnx-chrome--tail-string (selected-window)))))
      (dolist (p (copy-sequence drgnx-chrome-tail-providers)) (drgnx-chrome-remove-tail-provider p))
      (kill-buffer b))))

(provide 'agents-editor-line-test)
;;; agents-editor-line-test.el ends here
