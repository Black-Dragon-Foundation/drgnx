;;; wb-rules-edge-test.el --- batch tests: where buffers go, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-rules)
(require 'drgnx-popup)
(require 'calendar)

(defmacro drgnx-rules-edge--with (&rest body)
  "BODY with the rules mode on, a two-section dock shown and one editor window."
  `(drgnx-test-with-state
     (let ((drgnx-wb--sections nil) (drgnx-wb-unrouted nil)
           (drgnx-rules--table drgnx-rules--table)
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
       (delete-other-windows)
       (set-frame-parameter nil 'drgnx-wb-areas nil)
       (drgnx-wb-define-section 'top :slot -1 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-edge-top*")))
       (drgnx-wb-define-section 'bottom :slot 0 :title "BOTTOM" :buffer (lambda () (get-buffer-create "*drgnx-edge-bottom*")))
       (drgnx-rules-mode 1)
       (unwind-protect (progn ,@body)
         (drgnx-rules-mode -1)
         (drgnx-wb-hide-sidebar)
         (drgnx-wb-area-hide 'panel)
         (set-frame-parameter nil 'window-state nil)
         (delete-other-windows)
         (dolist (b '("*drgnx-edge-top*" "*drgnx-edge-bottom*" "*Calendar*"))
           (when (get-buffer b) (kill-buffer b)))))))

(ert-deftest drgnx-rules/side-window-toggling-keeps-the-dock-roles ()
  ;; `window-toggle-side-windows' saves and restores the side windows with `window-state-get':
  ;; the dock comes back as the dock, each section as itself.
  (drgnx-rules-edge--with
   ;; A fresh editor window: restoring the state reuses window objects, and ERT puts the window it
   ;; started with back after the test — that one must not have become a dock window meanwhile.
   (delete-other-windows (split-window))
   (drgnx-wb-show-sidebar)
   (window-toggle-side-windows)
   (should-not (drgnx-wb-sidebar-showing-p))
   (window-toggle-side-windows)
   (should (eq (window-parameter (drgnx-wb-section-window 'top) 'drgnx-role) 'dock))
   (should (window-live-p (drgnx-wb-section-window 'bottom)))))

(ert-deftest drgnx-rules/the-file-rule-never-reads-the-current-buffer ()
  ;; A name that is no buffer is not "a file" because the current buffer visits one.
  (drgnx-rules-edge--with
   (with-temp-buffer
     (setq buffer-file-name "/nonexistent/drgnx-edge.txt")
     (unwind-protect (should-not (drgnx-wb-rule-for "*drgnx-edge-no-such-buffer*"))
       (setq buffer-file-name nil)))))

(ert-deftest drgnx-rules/the-dock-is-shown-where-it-says-whatever-the-rules ()
  ;; The dock's own side windows are meant: a rule matching a section's buffer does not move it.
  (drgnx-rules-edge--with
   (drgnx-wb-place "\\`\\*drgnx-edge-top\\*\\'" 'editor)
   (let ((editor (selected-window)))
     (drgnx-wb-show-sidebar)
     (should (window-live-p (drgnx-wb-section-window 'top)))
     (should (eq (window-parameter (get-buffer-window "*drgnx-edge-top*") 'drgnx-role) 'dock))
     (should-not (equal (buffer-name (window-buffer editor)) "*drgnx-edge-top*")))))

(ert-deftest drgnx-popup/the-calendar-shows-its-month-in-the-lane ()
  ;; Popup content beyond *Completions*: the calendar's grid is in the lane, from its first line.
  (drgnx-rules-edge--with
   (calendar)
   (let ((w (get-buffer-window "*Calendar*")))
     (should (window-live-p w))
     (should (window-parameter w 'drgnx-popup))
     (should (string-search (calendar-month-name (calendar-extract-month (calendar-current-date)))
                            (with-current-buffer "*Calendar*" (buffer-string))))
     (should (= (window-start w) 1))
     (calendar-exit)
     (should-not (drgnx-popup-active-p)))))

(provide 'wb-rules-edge-test)
;;; wb-rules-edge-test.el ends here
