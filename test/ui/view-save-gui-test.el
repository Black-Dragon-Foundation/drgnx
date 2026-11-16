;;; view-save-gui-test.el --- GUI test: Ctrl+X Ctrl+S with focus in a side view saves the editor, with no prompt -*- lexical-binding: t -*-
;; test-class: det
;; The user's 2026-11-16 bug: a click on an Explorer file left focus in the Explorer, Ctrl+S asked for a file name for
;; " *drgnx explorer*" and Return wrote the Explorer's rows to it.  Real keys go through the command loop; a prompt would
;; leave a minibuffer active, and the view would visit a file.
(require 'ert)
(require 'drgnx-uitest)
(defconst drgnx-ui-view-save--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-ui-view-save--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-ui-view-save--repo))
(require 'drgnx)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-ui-view-save--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-ui-view-save--repo) nil t)
(mapc #'require (drgnx-test-modules--requires (expand-file-name "modules/core/drgnx-basics.el" drgnx-ui-view-save--repo)))

(ert-deftest drgnx-ui-view-save/a-key-in-a-side-view-saves-the-editor-without-a-prompt ()
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (drgnx-test-with-modules '(core/basics)
    (let* ((dir (file-name-as-directory (make-temp-file "view-save" t)))
           (file (expand-file-name "a.txt" dir))
           (view (get-buffer-create " *drgnx explorer*"))
           (ed (progn (write-region "a\n" nil file nil 'silent) (find-file-noselect file)))
           (default-directory dir))
      (unwind-protect
          (progn
            (should (advice-member-p 'drgnx-core/basics--save-from-view 'save-buffer))   ; the module's wiring
            (with-current-buffer view (let ((inhibit-read-only t)) (special-mode) (insert "a.txt\n")))
            (set-window-buffer (selected-window) ed)
            (drgnx-test-use-editor (selected-window))
            (with-current-buffer ed (insert "changed\n"))
            (let ((side (split-window-right)))
              (set-window-buffer side view)
              (select-window side)
              (should (eq (current-buffer) view))
              (drgnx-uitest-run (drgnx-uitest-key-events "C-x C-s"))
              (should-not (active-minibuffer-window))
              (should-not (buffer-modified-p ed))
              (should (equal "changed\na\n" (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (should-not (buffer-local-value 'buffer-file-name view))
              (should-not (file-exists-p (expand-file-name " *drgnx explorer*" dir)))))
        (kill-buffer view) (kill-buffer ed)
        (delete-directory dir t)))))
