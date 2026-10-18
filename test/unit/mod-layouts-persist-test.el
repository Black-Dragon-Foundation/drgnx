;;; mod-layouts-persist-test.el --- batch tests: the layout and the sidebar view survive a restart -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(require 'drgnx-persist)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-browser" drgnx-dir) nil t)

(defconst drgnx-layouts-persist-test--params
  '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px drgnx-persist-restored
                  drgnx-persist-extra drgnx-layouts-state drgnx-layouts-current drgnx-layouts-previous
                  drgnx-layouts-zen-return))

(defmacro drgnx-layouts-persist-test--with (&rest body)
  "BODY with a state file and config dir in a temp dir, an Explorer and a Search section, one editor
window, and the persist hooks as the layouts module wires them.  Prompts signal an error."
  (declare (indent 0))
  `(drgnx-test-with-state
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-layouts-persist" t)))
            (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
            (drgnx-persist-file (expand-file-name "state.eld" dir))
            (drgnx-persist-after-restore-functions nil) (drgnx-persist-state-functions nil)
            (drgnx-wb--sections nil)
            (drgnx-wb--areas (copy-tree drgnx-wb--areas))
            (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
            (size (cons (frame-width) (frame-height))))
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
         (dolist (b '("*drgnx-lp-explorer*" "*drgnx-lp-find*" "*drgnx-lp-code*" "*drgnx: no agent*" "*drgnx: browser*"))
           (when (get-buffer b) (kill-buffer b)))
         (delete-directory dir t)))))

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

(ert-deftest drgnx-layouts/agent-pane-after-restart ()
  "The chat pane is still the layout's pane after a restart: the next layout removes it."
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'agent)
    (drgnx-persist-save)
    (drgnx-layouts-persist-test--restart)
    (let ((groups (drgnx-groups-list)))
      (should (= 2 (length groups)))
      (should (eq (window-parameter (cadr groups) 'drgnx-layouts-pane) 'agent))
      (should (equal (buffer-name (window-buffer (cadr groups))) "*drgnx: no agent*")))
    (drgnx-layouts-apply 'editor)
    (should (= 1 (length (drgnx-groups-list))))))

(ert-deftest drgnx-layouts/browser-pane-after-restart ()
  "The browser pane is found again after a restart: Open URL does not split a third group."
  (drgnx-layouts-persist-test--with
    (let ((drgnx-layouts-shapes (copy-sequence drgnx-layouts-shapes))
          (drgnx-layouts-pane-fillers (copy-sequence drgnx-layouts-pane-fillers)))
      (drgnx-browser--register-shape)
      (drgnx-layouts-apply 'browser)
      (should (= 2 (length (drgnx-groups-list))))
      (drgnx-persist-save)
      (drgnx-layouts-persist-test--restart)
      (let ((pane (cadr (drgnx-groups-list))))
        (should (eq (window-parameter pane 'drgnx-layouts-pane) 'browser))
        (should (equal (buffer-name (window-buffer pane)) "*drgnx: browser*"))
        (should (eq (drgnx-browser--pane) pane))
        (should (= 2 (length (drgnx-groups-list)))))
      (drgnx-layouts-apply 'editor)
      (should (= 1 (length (drgnx-groups-list)))))))

(ert-deftest drgnx-layouts/browser-pane-before-its-module-sets-up ()
  "The browser module sets up after the layouts' restore: the pane is marked without it, and filled once it registers."
  (drgnx-layouts-persist-test--with
    (let ((drgnx-layouts-shapes (copy-sequence drgnx-layouts-shapes))
          (drgnx-layouts-pane-fillers (copy-sequence drgnx-layouts-pane-fillers)))
      (drgnx-browser--register-shape)
      (drgnx-layouts-apply 'browser)
      (drgnx-persist-save)
      (setq drgnx-layouts-pane-fillers (assq-delete-all 'browser drgnx-layouts-pane-fillers)) ; a fresh Emacs
      (drgnx-layouts-persist-test--restart)
      (let ((pane (cadr (drgnx-groups-list))))
        (should (eq (window-parameter pane 'drgnx-layouts-pane) 'browser))   ; marked, nothing to fill it with yet
        (drgnx-browser--register-shape)                                       ; the browser module's setup
        (should (equal (buffer-name (window-buffer pane)) "*drgnx: browser*"))
        (should (eq (drgnx-browser--pane) pane))
        (should (= 2 (length (drgnx-groups-list)))))
      (drgnx-layouts-apply 'editor)
      (should (= 1 (length (drgnx-groups-list)))))))

(ert-deftest drgnx-layouts/an-old-single-pane-is-still-read ()
  "A workbench saved with `:pane' (one spec, before `:panes') still brings its pane back."
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'agent)
    (drgnx-persist-save)
    (drgnx-layouts-persist-test--edit-state :panes nil)
    (drgnx-layouts-persist-test--edit-state :pane '(1 . agent))
    (drgnx-layouts-persist-test--restart)
    (should (eq (window-parameter (cadr (drgnx-groups-list)) 'drgnx-layouts-pane) 'agent))))

(ert-deftest drgnx-layouts/arrangement-keeps-groups-tabs-and-files-after-restart ()
  "A remembered arrangement comes back with each group's tabs and shown file, opening the files that are not open."
  (drgnx-layouts-persist-test--with
    (let* ((dir (file-name-as-directory (make-temp-file "drgnx-lp-files" t)))
           (files (mapcar (lambda (n) (expand-file-name n dir)) '("a.txt" "b.txt" "c.txt"))))
      (unwind-protect
          (progn
            (dolist (f files) (write-region "x\n" nil f nil 'silent))
            (drgnx-layouts-apply 'editor)
            (switch-to-buffer (find-file-noselect (nth 0 files)))
            (find-file-noselect (nth 1 files))
            (drgnx-persist--set-tabs (selected-window) (list (nth 0 files) (nth 1 files)))
            (drgnx-groups-split-right)
            (set-window-buffer (selected-window) (find-file-noselect (nth 2 files)))
            (select-window (car (drgnx-groups-list)))
            (drgnx-layouts-apply 'zen)
            (drgnx-layouts-apply 'agent)           ; Editor's arrangement is remembered
            (drgnx-persist-save)
            (dolist (f files) (when-let* ((b (get-file-buffer f))) (kill-buffer b)))
            (drgnx-layouts-persist-test--restart)
            (dolist (f files) (when-let* ((b (get-file-buffer f))) (kill-buffer b)))
            (should-not (get-file-buffer (nth 1 files)))
            (drgnx-layouts-apply 'editor)
            (let ((groups (drgnx-groups-list)))
              (should (= 2 (length groups)))
              (should (equal (buffer-file-name (window-buffer (car groups))) (nth 0 files)))
              (should (equal (buffer-file-name (window-buffer (cadr groups))) (nth 2 files)))
              (should (equal (mapcar #'buffer-file-name (drgnx-chrome-tabs (car groups))) (list (nth 0 files) (nth 1 files))))))
        (dolist (f files) (when-let* ((b (get-file-buffer f))) (kill-buffer b)))
        (delete-directory dir t)))))

(ert-deftest drgnx-layouts/arrangements-after-restart ()
  "Each layout's last arrangement survives a restart, not only the current layout's name."
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'agent)
    (drgnx-groups-split-right)                          ; the user's change: a third group …
    (drgnx-wb-area-show 'panel 'output (get-buffer-create "*drgnx-lp-code*")) ; … and the panel
    (drgnx-layouts-apply 'editor)
    (drgnx-persist-save)
    (drgnx-layouts-persist-test--restart)
    (should (eq (drgnx-layouts-current) 'editor))
    (drgnx-layouts-apply 'agent)
    (should (= 3 (length (drgnx-groups-list))))         ; as it was left (a fresh Agent has two)
    (should (drgnx-wb-area-window 'panel))
    (should (eq (drgnx-wb-area-tab 'panel) 'output))
    (should (eq (window-parameter (nth 2 (drgnx-groups-list)) 'drgnx-layouts-pane) 'agent)) ; the split came before it
    (drgnx-layouts-apply 'editor)
    (should (= 2 (length (drgnx-groups-list))))))       ; the pane is gone, the user's split stays

(ert-deftest drgnx-layouts/crafted-arrangements-are-ignored ()
  "Junk where the arrangements go is no error and gives no arrangement."
  (drgnx-layouts-persist-test--with
    (drgnx-layouts-apply 'editor)
    (drgnx-persist-save)
    (dolist (junk '(42 "x" (nope) ((agent . 3)) ((no-such-layout :main (leaf)))
                       ((agent :main ((parameters (foo . 1)) leaf (buffer "*scratch*"))))))
      (drgnx-layouts-persist-test--edit-state :arrangements junk)
      (drgnx-layouts-persist-test--edit-state :pane '(9 . agent))
      (drgnx-layouts-persist-test--restart)
      (should (eq (drgnx-layouts-current) 'editor))
      (should (= 1 (length (drgnx-groups-list))))
      (should-not (window-parameter (selected-window) 'foo)))
    ;; a damaged arrangement is no arrangement: the layout is built as if never left
    (drgnx-layouts-persist-test--edit-state :arrangements '((agent :main (leaf) :left 5 :pane (1 . agent))
                                                            (zen :main (leaf junk)) (browser :main (leaf) :left (:px 99999999))))
    (drgnx-layouts-persist-test--restart)
    (drgnx-layouts-apply 'zen)
    (drgnx-layouts-apply 'agent)
    (should (= 2 (length (drgnx-groups-list))))
    (should (eq (window-parameter (cadr (drgnx-groups-list)) 'drgnx-layouts-pane) 'agent))))

(provide 'mod-layouts-persist-test)
;;; mod-layouts-persist-test.el ends here

(ert-deftest drgnx-layouts/the-persist-fixture-keeps-the-frame-size ()
  ;; The fixture gives the frame back its size: a frame one line shorter after each test left later docks no room.
  (let ((size (cons (frame-width) (frame-height))))
    (drgnx-layouts-persist-test--with (ignore))
    (read-event nil nil 0.01)                           ; a terminal frame takes its new size at the next wait
    (should (equal (cons (frame-width) (frame-height)) size))))
