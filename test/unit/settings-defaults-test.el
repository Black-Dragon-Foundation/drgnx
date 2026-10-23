;;; settings-defaults-test.el --- batch tests: settings/runtime-defaults.el, the shipped data -*- lexical-binding: t -*-
;; The file is data: the three constants of drgnx-ai.el and drgnx-agents.el take their values from it, and the strict
;; default of every `:on-error strict' setting is in it.  test/fixtures/settings/defconsts-before.eld is those three
;; constants as `main' had them, dumped by a batch Emacs.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-agents)
(require 'drgnx-ai)

(defun drgnx-settings-defaults-test--before ()
  "The old defconsts: ((NAME . VALUE)…)."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/settings/defconsts-before.eld" drgnx-dir))
    (read (current-buffer))))

(ert-deftest drgnx-settings-defaults/equal-the-old-defconsts ()
  (let ((before (drgnx-settings-defaults-test--before)))
    (should (= (length before) 3))
    (should (equal (cdr (assq 'drgnx-ai-presets before)) drgnx-ai-presets))
    (should (equal (cdr (assq 'drgnx-ai-default-roles before)) drgnx-ai-default-roles))
    (should (equal (cdr (assq 'drgnx-agents-builtin-profiles before)) drgnx-agents-builtin-profiles))
    ;; and the file says the same through the reader, without loading it
    (dolist (cell before)
      (should (equal (cdr cell) (drgnx-settings-defaults-value (car cell)))))))

(ert-deftest drgnx-settings-defaults/every-strict-setting-has-its-default-in-the-file ()
  (let ((strict (cl-remove-if-not (lambda (v) (eq (plist-get (drgnx-setting-meta v) :on-error) 'strict))
                                  (drgnx-setting-names))))
    (should (>= (length strict) 6))
    (dolist (var strict)
      (should (assq var (drgnx-settings-defaults-all)))
      (should (equal (drgnx-settings-defaults-value var) (eval (car (get var 'standard-value)) t))))))

(ert-deftest drgnx-settings-defaults/the-file-is-never-loaded ()
  ;; it is read as data: a form that would run does not
  (let ((ran nil))
    (cl-letf (((symbol-function 'load) (lambda (&rest _) (setq ran t))))
      (let ((drgnx-settings-defaults--cache nil)) (drgnx-settings-defaults-all)))
    (should-not ran)))

(ert-deftest drgnx-settings-defaults/a-missing-file-is-an-error ()
  (let ((drgnx-settings-defaults--cache nil)
        (drgnx-settings-defaults-file (expand-file-name "no-such-defaults.el" temporary-file-directory)))
    (should-error (drgnx-settings-defaults-all))))

;;; settings-defaults-test.el ends here
