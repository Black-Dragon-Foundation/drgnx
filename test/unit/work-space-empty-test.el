;;; work-space-empty-test.el --- the Work space outside a project: an empty map that says so -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the hub client's call is stubbed to record what would have been asked.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(declare-function drgnx-work-space-open "drgnx-work-space")

(ert-deftest drgnx-work-space/no-workspace-opens-an-empty-map ()
  ;; a scratch buffer, a folder outside git: an empty map that says so, and no subscription
  (let ((calls nil) (dir (make-temp-file "work-space-none" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-work-client--call) (lambda (method &rest _) (push method calls) t)))
          (drgnx-test-with-modules '(tools/work-space)
            (with-temp-buffer
              (setq default-directory (file-name-as-directory dir))
              (save-window-excursion
                (set-window-buffer (selected-window) (current-buffer))
                (let ((buf (drgnx-work-space-open)))
                  (with-current-buffer buf (drgnx-view-draw-now drgnx-view))
                  (should (string-search "No project" (with-current-buffer buf (buffer-string))))
                  (should-not calls)
                  (should-not (drgnx-work-client-views)))))))
      (delete-directory dir t))))

(provide 'work-space-empty-test)
;;; work-space-empty-test.el ends here
