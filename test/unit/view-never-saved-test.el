;;; view-never-saved-test.el --- batch tests: a view is never saved, never visits a file (audit, the user's 2026-11-16 bug) -*- lexical-binding: t -*-
;; test-class: det
;; Ctrl+S with focus in the Explorer asked for a file name for " *drgnx explorer*" and wrote its rows to a file.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(mapc #'require (drgnx-test-modules--requires (expand-file-name "modules/core/drgnx-basics.el" drgnx-dir)))
(load (expand-file-name "modules/core/drgnx-basics" drgnx-dir) nil t)

(ert-deftest drgnx-basics/a-view-buffer-is-known-by-what-it-is ()
  (with-temp-buffer (rename-buffer " *drgnx explorer*" t) (should (drgnx-basics-view-buffer-p)))
  (with-temp-buffer (special-mode) (should (drgnx-basics-view-buffer-p)))
  (with-temp-buffer (should-not (drgnx-basics-view-buffer-p)))                      ; a plain buffer: not a view
  (with-temp-buffer (setq buffer-file-name "/tmp/x.el") (should-not (drgnx-basics-view-buffer-p)))
  (with-temp-buffer (setq-local drgnx-untitled-p t) (rename-buffer "*drgnx x*" t) (should-not (drgnx-basics-view-buffer-p))))

(ert-deftest drgnx-basics/save-in-a-view-saves-the-editor-and-never-asks ()
  (let* ((file (make-temp-file "view-save")) (ed (find-file-noselect file)) (asked nil) saved)
    (unwind-protect
        (with-current-buffer (get-buffer-create " *drgnx explorer*")
          (cl-letf (((symbol-function 'drgnx-state-editor-window) (lambda (&optional _f) (selected-window)))
                    ((symbol-function 'window-buffer) (lambda (&optional _w) ed))
                    ((symbol-function 'read-file-name) (lambda (&rest _) (setq asked t) "/tmp/nope"))
                    ((symbol-function 'read-string) (lambda (&rest _) (setq asked t) "")))
            (drgnx-basics--save-from-view (lambda (&rest _) (setq saved (current-buffer))))
            (should (eq saved ed))
            (should-not asked)
            ;; no editor: nothing is saved, nothing is asked, it says so
            (setq saved nil)
            (cl-letf (((symbol-function 'drgnx-state-editor-window) (lambda (&optional _f) nil)))
              (let (said)
                (cl-letf (((symbol-function 'message) (lambda (f &rest a) (setq said (apply #'format f a)))))
                  (drgnx-basics--save-from-view (lambda (&rest _) (setq saved t))))
                (should-not saved)
                (should (string-match-p "Nothing to save" said))))))
      (kill-buffer ed) (when (get-buffer " *drgnx explorer*") (kill-buffer " *drgnx explorer*"))
      (delete-file file))))

(ert-deftest drgnx-basics/the-module-wires-save-and-the-file-name-guard ()
  (drgnx-test-with-modules '(core/basics) :strict t
                           (should (advice-member-p 'drgnx-core/basics--save-from-view 'save-buffer))
                           (should (advice-member-p 'drgnx-core/basics--no-file-for-view 'set-visited-file-name))
                           (with-temp-buffer
                             (rename-buffer " *drgnx explorer*" t)
                             (should-error (set-visited-file-name "/tmp/drgnx-view-nofile") :type 'user-error)
                             (should-not buffer-file-name))
                           (with-temp-buffer (should-not (drgnx-basics--no-file-for-view "/tmp/x")))))   ; an editor is let through

(provide 'view-never-saved-test)
;;; view-never-saved-test.el ends here
