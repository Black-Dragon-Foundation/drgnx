;;; wb-focus-test.el --- batch tests: Focus Left/Right/Above/Below across editor groups and docks -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-actions)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)

(defmacro drgnx-wb-focus-test--with (&rest body)
  "BODY with the sidebar (two dummy sections) on the left of one editor group, rules and chrome on."
  `(drgnx-test-with-state
     (let ((drgnx-wb--sections nil) (display-buffer-alist nil))
       (delete-other-windows)
       (set-window-parameter (selected-window) 'drgnx-tabs nil)
       (drgnx-rules-mode 1)
       (drgnx-chrome-mode 1)
       (drgnx-wb-define-section 'top :slot -1 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-focus-top*")))
       (drgnx-wb-define-section 'bottom :slot 0 :title "BOTTOM" :buffer (lambda () (get-buffer-create "*drgnx-focus-bottom*")))
       (unwind-protect
           (progn (switch-to-buffer (get-buffer-create "*drgnx-focus-a*"))
                  (drgnx-chrome-apply nil t)
                  (drgnx-wb-show-sidebar)
                  ,@body)
         (drgnx-wb-hide-sidebar)
         (drgnx-chrome-mode -1)
         (drgnx-rules-mode -1)
         (delete-other-windows)
         (dolist (b '("*drgnx-focus-top*" "*drgnx-focus-bottom*" "*drgnx-focus-a*"))
           (when (get-buffer b) (kill-buffer b)))))))

(ert-deftest drgnx-wb-focus/moves-between-groups-and-the-sidebar ()
  (drgnx-wb-focus-test--with
   (let ((g1 (selected-window)))
     (drgnx-groups-split-right)
     (let ((g2 (selected-window)) (dock (drgnx-wb-section-window 'top)))
       (should-not (eq g1 g2))
       (drgnx-wb-focus-left)
       (should (eq (selected-window) g1))
       (drgnx-wb-focus-left)
       (should (eq (selected-window) dock))        ; docks are `no-other-window', still reachable
       (drgnx-wb-focus-left)                       ; an edge: nothing changes, no error
       (should (eq (selected-window) dock))
       (drgnx-wb-focus-right)
       (should (eq (selected-window) g1))
       (drgnx-wb-focus-right)
       (should (eq (selected-window) g2))
       (drgnx-wb-focus-right)
       (should (eq (selected-window) g2))))))

(ert-deftest drgnx-wb-focus/up-and-down-between-groups-and-docks ()
  (drgnx-wb-focus-test--with
   (let ((top (drgnx-wb-section-window 'top)) (bottom (drgnx-wb-section-window 'bottom)))
     (select-window top)
     (drgnx-wb-focus-down)
     (should (eq (selected-window) bottom))
     (drgnx-wb-focus-down)
     (should (eq (selected-window) bottom))
     (drgnx-wb-focus-up)
     (should (eq (selected-window) top))
     (drgnx-wb-focus-up)
     (should (eq (selected-window) top))
     (should-error (drgnx-wb-focus-direction 'sideways)))))

(provide 'wb-focus-test)
;;; wb-focus-test.el ends here
