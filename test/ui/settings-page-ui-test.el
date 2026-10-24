;;; settings-page-ui-test.el --- GUI tests: the Settings page on a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; Preferences: Settings is opened on the root frame; the rows of the group in the window are drawn (the visible ones
;; first, then the rest in slices), a search narrows them, and the jank guard sees no window move by a timer.  A
;; screenshot of the page is taken (its path is printed).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-settings-page-ui-test--repo             ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-settings-page-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-settings-page)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-settings-page-ui-test--repo) nil t)

(defvar drgnx-jank-guard-log)

(ert-deftest drgnx-settings-page-ui/the-page-draws-and-searches-without-jank ()
  (let ((root (drgnx-uitest-root-frame)) (dir (make-temp-file "drgnx-settings-shot" t)))
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (let ((log-before (length drgnx-jank-guard-log)))
            (with-current-buffer (drgnx-settings-page 'look)
              (switch-to-buffer (current-buffer))
              (should (drgnx-test-wait (lambda () (and (not (drgnx-view-pending-p drgnx-view))
                                                       (> (drgnx-view-row-count drgnx-view) 0)))
                                       :secs 60 :what "the Settings page's rows"))
              (redisplay t)
              (should (string-search "Scope: " (buffer-string)))
              (let ((shot (plist-get (drgnx-uitest-capture dir) :root)))
                (should (file-exists-p shot))
                (copy-file shot (expand-file-name "settings-page.png" temporary-file-directory) t)
                (message "settings page screenshot: %s" (expand-file-name "settings-page.png" temporary-file-directory)))
              (drgnx-settings-page-search "fill-column")
              (should (drgnx-test-wait (lambda () (and (not (drgnx-view-pending-p drgnx-view))
                                                       (string-search "Fill Column" (buffer-string))))
                                       :secs 60 :what "the search result"))
              (redisplay t)
              (should (= (length drgnx-jank-guard-log) log-before)))))
      (delete-directory dir t))))

(provide 'settings-page-ui-test)
;;; settings-page-ui-test.el ends here
