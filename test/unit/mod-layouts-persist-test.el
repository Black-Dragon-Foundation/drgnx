;;; mod-layouts-persist-test.el --- batch tests: the layout and the sidebar view survive a restart -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(require 'drgnx-persist)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir) nil t)

(defconst drgnx-layouts-persist-test--params
  '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px drgnx-persist-restored
                  drgnx-persist-extra drgnx-layouts-state drgnx-layouts-current drgnx-layouts-previous
                  drgnx-layouts-zen-return))

(defmacro drgnx-layouts-persist-test--with (&rest body)
  "BODY with a state file and config dir in a temp dir, an Explorer and a Search section, one editor
window, and the persist hooks as the layouts module wires them.  Prompts signal an error."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-layouts-persist" t)))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
          (drgnx-persist-file (expand-file-name "state.eld" dir))
          (drgnx-persist-after-restore-functions nil) (drgnx-persist-state-functions nil)
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil)
          (drgnx-wb--areas (copy-tree drgnx-wb--areas))
          (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
          (size (cons (window-total-width (frame-root-window)) (window-total-height (frame-root-window)))))
     (set-frame-size nil 200 60)
     (delete-other-windows)
     (dolist (p drgnx-layouts-persist-test--params) (set-frame-parameter nil p nil))
     (drgnx-wb-define-section 'files :slot 0 :title "EXPLORER"
                              :buffer (lambda () (get-buffer-create "*drgnx-lp-explorer*")))
     (drgnx-wb-define-section 'find :slot 0 :view 'search :title "SEARCH"
                              :buffer (lambda () (get-buffer-create "*drgnx-lp-find*")))
     (drgnx-layouts--wire-persist)
     (drgnx-rules-mode 1)
     (drgnx-chrome-mode 1)
     (switch-to-buffer (get-buffer-create "*drgnx-lp-code*"))
     (set-window-parameter nil 'drgnx-tabs nil)
     (unwind-protect
         (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "prompted")))
                   ((symbol-function 'read-string) (lambda (&rest _) (error "prompted")))
                   ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted")))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "prompted"))))
           ,@body)
       (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize)
       (drgnx-chrome-mode -1)
       (drgnx-rules-mode -1)
       (drgnx-wb-hide-sidebar)
       (drgnx-wb-area-hide 'panel)
       (drgnx-wb-area-hide 'right)
       (delete-other-windows)
       (set-window-margins nil 0 0)
       (dolist (p drgnx-layouts-persist-test--params) (set-frame-parameter nil p nil))
       (set-frame-size nil (car size) (cdr size))
       (switch-to-buffer "*scratch*")
       (dolist (b '("*drgnx-lp-explorer*" "*drgnx-lp-find*" "*drgnx-lp-code*"))
         (when (get-buffer b) (kill-buffer b)))
       (delete-directory dir t))))

(defun drgnx-layouts-persist-test--restart ()
  "Forget the frame's runtime state, as a new Emacs would, and restore the saved workbench into it."
  (dolist (p drgnx-layouts-persist-test--params) (set-frame-parameter nil p nil))
  (drgnx-wb-hide-sidebar)
  (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize)
  (drgnx-persist--restore-into (selected-frame)))

(defun drgnx-layouts-persist-test--edit-state (key value)
  "Rewrite the saved state: KEY of the first frame's extras becomes VALUE (a layout that was deleted, junk)."
  (let* ((state (drgnx-persist--read drgnx-persist-file))
         (frame (car (plist-get state :frames))))
    (setq frame (plist-put frame :extra (plist-put (plist-get frame :extra) key value)))
    (setq state (plist-put state :frames (list frame)))
    (with-temp-file drgnx-persist-file (prin1 state (current-buffer)))))

(ert-deftest drgnx-layouts/remembered-after-restart ()
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'editor)
    (drgnx-persist-save)
    (should (eq (plist-get (plist-get (car (plist-get (drgnx-persist--read drgnx-persist-file) :frames)) :extra) :layout)
                'editor))
    (drgnx-layouts-persist-test--restart)
    (should (eq (drgnx-layouts-current) 'editor))))

(ert-deftest drgnx-layouts/zen-is-centred-again-after-restart ()
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'zen)
    (drgnx-persist-save)
    (set-window-margins nil 0 0)
    (drgnx-layouts-persist-test--restart)
    (should (eq (drgnx-layouts-current) 'zen))
    (should (memq #'drgnx-layouts--zen-resize window-size-change-functions))
    (should (> (or (car (window-margins (drgnx-wb-editor-window))) 0) 0))))

(ert-deftest drgnx-layouts/no-layout-saves-none ()
  (drgnx-layouts-persist-test--with
    (drgnx-persist-save)
    (drgnx-layouts-persist-test--restart)
    (should-not (drgnx-layouts-current))))

(ert-deftest drgnx-layouts/vanished-layout-is-ignored-after-restart ()
  (drgnx-layouts-persist-test--with
    (drgnx-persist-save)
    (dolist (junk '(no-such-layout "editor" 42))
      (drgnx-layouts-persist-test--edit-state :layout junk)
      (drgnx-layouts-persist-test--restart)
      (should-not (drgnx-layouts-current)))))

(ert-deftest drgnx-layouts/restoring-without-the-layouts-module-wired-is-harmless ()
  "A state written with a layout restores where the module is not loaded: nothing is applied."
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'editor)
    (drgnx-persist-save)
    (setq drgnx-persist-after-restore-functions nil)
    (drgnx-layouts-persist-test--restart)
    (should-not (drgnx-layouts-current))))

(ert-deftest drgnx-layouts/adopted-when-the-module-sets-up-after-the-restore ()
  "The layouts module sets up at idle, after the first frame was restored: it takes the saved layout then."
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'editor)
    (drgnx-persist-save)
    (setq drgnx-persist-after-restore-functions nil)
    (drgnx-layouts-persist-test--restart)
    (should-not (drgnx-layouts-current))
    (drgnx-layouts--wire-persist)
    (should (eq (drgnx-layouts-current) 'editor))))

(ert-deftest drgnx-wb-views/view-remembered-after-restart ()
  (drgnx-layouts-persist-test--with
    (drgnx-wb-show-view 'search)
    (drgnx-persist-save)
    (drgnx-layouts-persist-test--restart)
    (should (eq (drgnx-wb-sidebar-view) 'search))
    (should (drgnx-wb-sidebar-showing-p))
    (should (eq (window-parameter (car (drgnx-wb--dock-windows)) 'drgnx-section) 'find))))

(ert-deftest drgnx-wb-views/hidden-sidebar-keeps-its-view-after-restart ()
  (drgnx-layouts-persist-test--with
    (drgnx-wb-show-view 'search)
    (drgnx-wb-hide-sidebar)
    (drgnx-persist-save)
    (drgnx-layouts-persist-test--restart)
    (should-not (drgnx-wb-sidebar-showing-p))
    (should (eq (drgnx-wb-sidebar-view) 'search))))

(ert-deftest drgnx-wb-views/vanished-view-falls-back-to-the-explorer ()
  (drgnx-layouts-persist-test--with
    (drgnx-wb-show-view 'search)
    (drgnx-persist-save)
    (setq drgnx-wb--sections (seq-remove (lambda (s) (eq (plist-get (cdr s) :view) 'search)) drgnx-wb--sections))
    (drgnx-layouts-persist-test--restart)
    (should (eq (drgnx-wb-sidebar-view) 'explorer))
    (should (drgnx-wb-sidebar-showing-p))))

(provide 'mod-layouts-persist-test)
;;; mod-layouts-persist-test.el ends here
