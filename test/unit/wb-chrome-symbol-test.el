;;; wb-chrome-symbol-test.el --- batch tests: the breadcrumb names the definition at point, from a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The definition comes from the hub (`outline/scopes', view/outline.rs: the Outline's parse of the file); a real hub
;; as its own process answers, inside the delivery gate (`drgnx-test-gated').  Needs Sjá and the hub's binary; skipped
;; without either.  The rest of the chrome: wb-chrome-test.el.
(require 'ert)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/gated-hub-fixture" drgnx-dir) nil t)
(require 'drgnx-chrome)
(require 'drgnx-view)                    ; Sjá (`nidhogg-views'): the gated hub needs it

(ert-deftest drgnx-chrome-symbol/the-breadcrumb-names-the-definition-at-point ()
  "window-dark.html `.crumbs': the breadcrumb ends with the definition point is in (`.cur', muted; the file then in
the crumbs' colour).  The name is asked for on idle (a command only arms the debounce), kept in the window when the
hub answers, and the breadcrumb only reads it.  A window showing another buffer shows no stale name."
  (drgnx-test-with-gated-hub
    (drgnx-test-with-state
      (let ((dir (file-name-as-directory (make-temp-file "drgnx-chrome" t))) (display-buffer-alist nil))
        (delete-other-windows)
        (set-window-parameter (selected-window) 'drgnx-tabs nil)
        (drgnx-rules-mode 1)
        (drgnx-chrome-mode 1)
        (unwind-protect
            (let* ((w (selected-window)) (f (expand-file-name "src/a.el" dir)) b)
              (make-directory (expand-file-name ".git" dir))
              (make-directory (file-name-directory f) t)
              (write-region "(defun drgnx-test-one ()\n  1)\n\n(defun drgnx-test-two ()\n  2)\n" nil f nil 'silent)
              (setq b (find-file-noselect f))
              (switch-to-buffer b)
              (drgnx-chrome-apply nil t)
              (with-current-buffer b (goto-char (point-min)) (search-forward "2)"))
              (set-window-point w (with-current-buffer b (point)))
              (drgnx-chrome--symbol-schedule)
              (should (drgnx-timer-active-p 'chrome-symbol))
              (drgnx-chrome--symbol-update)
              (drgnx-test-hub-settle (lambda () (string-search "drgnx-test-two" (drgnx-chrome-breadcrumb w)))
                                     "the definition in the breadcrumb")
              (let ((crumb (drgnx-chrome-breadcrumb w)))
                (should (equal "src › a.el › drgnx-test-two" (string-trim (substring-no-properties crumb))))
                (should (memq 'drgnx-text-muted (ensure-list (get-text-property (string-search "drgnx-test-two" crumb) 'face crumb))))
                (should (memq 'drgnx-chrome-crumb (ensure-list (get-text-property (string-search "a.el" crumb) 'face crumb)))))
              (should (string-search "drgnx-test-two" (format "%s" (window-parameter w 'header-line-format))))
              (write-region "x\n" nil (expand-file-name "b.txt" dir) nil 'silent)
              (switch-to-buffer (find-file-noselect (expand-file-name "b.txt" dir)))
              (drgnx-chrome-apply nil t)
              (should-not (string-search "drgnx-test" (drgnx-chrome-breadcrumb w)))
              (drgnx-timer-cancel 'chrome-symbol))
          (drgnx-chrome-mode -1)
          (drgnx-rules-mode -1)
          (delete-other-windows)
          (dolist (b (buffer-list))
            (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
              (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
          (delete-directory dir t))))))

;;; wb-chrome-symbol-test.el ends here
