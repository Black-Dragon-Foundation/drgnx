;;; runtime-settings-fixture.el --- for tests of the agents and AI settings (unified-settings Task 15) -*- lexical-binding: t -*-
;; Load with (load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t).
;; `drgnx-test-with-runtime-settings' runs BODY with the eight runtime settings bound to their defaults (what a
;; start without settings.el has), the applier's session state bound fresh and a temp config folder, and afterwards
;; takes whatever the applier put in theme `drgnx' for them away.  Tests set a value with `drgnx-test-set-runtime'
;; (a plain `setq' of the binding) or through settings.el with `drgnx-test-runtime-settings-put' (the applier reads it).
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-setting)
(require 'drgnx-settings-apply)
(require 'drgnx-settings-defaults)
(require 'drgnx-agents)                 ; the variables the fixture saves and sets
(require 'drgnx-ai)

(defconst drgnx-test-runtime-settings--vars
  '(drgnx-agents-profiles drgnx-agents-default drgnx-agents-mcp drgnx-agents-routes drgnx-agents-openrouter
                          drgnx-agents-allow-unsandboxed drgnx-ai-providers drgnx-ai-roles)
  "The agents and AI settings.")

;; The applier writes a setting's top-level value (`set-default-toplevel-value', as Customize does), so a test that
;; applies must not `let'-bind the variable: it snapshots the top-level values instead, and puts them back.
(defvar drgnx-test-runtime-settings--saved nil
  "A stack of snapshots: ((VARS-AND-VALUES) . (APPLIER-STATE)).")

(defun drgnx-test-runtime-settings--reset ()
  "Snapshot the runtime settings' top-level values and the applier's state; make both the defaults (a fresh start)."
  (push (list (mapcar (lambda (v) (cons v (default-toplevel-value v))) drgnx-test-runtime-settings--vars)
              drgnx-settings-apply--entries drgnx-settings-apply-problems drgnx-settings-apply-durations
              drgnx-settings-package-settings-off drgnx-settings-defaults--cache)
        drgnx-test-runtime-settings--saved)
  (dolist (v drgnx-test-runtime-settings--vars)
    (set-default-toplevel-value v (eval (car (get v 'standard-value)) t)))
  (setq drgnx-settings-apply--entries nil drgnx-settings-apply-problems nil drgnx-settings-apply-durations nil
        drgnx-settings-package-settings-off nil drgnx-settings-defaults--cache nil))

(defun drgnx-test-runtime-settings--forget ()
  "End what `drgnx-test-runtime-settings--reset' began: the applier's traces of the runtime settings go (their theme
values and saved values), and the snapshot comes back."
  (dolist (var drgnx-test-runtime-settings--vars)
    (dolist (p '(theme-value saved-value customized-value)) (put var p nil))
    (dolist (theme custom-known-themes)
      (put theme 'theme-settings (cl-remove-if (lambda (s) (eq (cadr s) var)) (get theme 'theme-settings)))))
  (when-let* ((snap (pop drgnx-test-runtime-settings--saved)))
    (pcase-dolist (`(,v . ,val) (nth 0 snap)) (set-default-toplevel-value v val))
    (setq drgnx-settings-apply--entries (nth 1 snap) drgnx-settings-apply-problems (nth 2 snap)
          drgnx-settings-apply-durations (nth 3 snap) drgnx-settings-package-settings-off (nth 4 snap)
          drgnx-settings-defaults--cache (nth 5 snap))))

(defmacro drgnx-test-with-runtime-bindings (&rest body)
  "BODY with the runtime settings at their defaults and the applier's state fresh; the applier's traces go after.
For a test that makes its own config folder (set DRGNX_CONFIG_DIR yourself)."
  (declare (indent 0) (debug t))
  `(progn (drgnx-test-runtime-settings--reset)
          (unwind-protect (progn ,@body)
            (drgnx-test-runtime-settings--forget))))

(defmacro drgnx-test-with-runtime-settings (&rest body)
  "BODY with the runtime settings at their defaults, the applier's state fresh and a temp config folder."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-runtime-bindings (drgnx-test-with-config ,@body)))

(defun drgnx-test-set-runtime (&rest var-values)
  "Set the runtime settings VAR VALUE… (plain `setq's of the current bindings)."
  (while var-values (set (pop var-values) (pop var-values))))

(defun drgnx-test-runtime-settings-put (&rest entries)
  "Make settings.el hold ENTRIES (each an entry's text) and apply it; the applier's results."
  (drgnx-test-config-put 'settings (concat "(drgnx-settings\n :version 1\n " (string-join entries "\n ") ")\n"))
  (drgnx-settings-apply-global))

(defun drgnx-test-write-settings (file &rest var-values)
  "Write settings FILE as (drgnx-settings :version 1 (VAR VALUE)…) from the pairs VAR-VALUES, making its folder.
For a child Emacs that reads its own settings.el (a hub, a mock agent's host); the running test sets the bindings
it needs itself."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (let ((print-length nil) (print-level nil) (coding-system-for-write 'utf-8-unix))
      (prin1 (append (list 'drgnx-settings :version 1)
                     (cl-loop for (var value) on var-values by #'cddr collect (list var value)))
             (current-buffer))
      (insert "\n"))))

(defun drgnx-test-settings-text ()
  "settings.el's text, or nil."
  (drgnx-test-config-text 'settings))

(provide 'runtime-settings-fixture)
;;; runtime-settings-fixture.el ends here
