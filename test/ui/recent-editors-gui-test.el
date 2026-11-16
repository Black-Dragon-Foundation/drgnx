;;; recent-editors-gui-test.el --- GUI test: VS Code's Ctrl+Tab goes back to the editor used before (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; On a graphical frame, with `tab-bar-mode''s own C-<tab> (`tab-next', which the title row's tab bar binds in its map
;; when it turns on: audit G1/F14) in force, the VS Code profile's Ctrl+Tab opens the group's editors, most recently
;; used first: Return goes back to the one used before; Ctrl+Tab again moves down, Ctrl+Shift+Tab up.  Real keys go
;; through the command loop.  The tab bar's map is put in force as the mode does, without turning the mode on (which
;; would add the frame parameters it keeps).

(require 'ert)
(require 'drgnx-uitest)
(defconst drgnx-ui-recent-editors--repo           ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-ui-recent-editors--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-ui-recent-editors--repo))
(require 'drgnx)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-ui-recent-editors--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-ui-recent-editors--repo) nil t)
(mapc #'require (drgnx-test-modules--requires (expand-file-name "modules/core/drgnx-workbench.el"
                                                                drgnx-ui-recent-editors--repo)))

(ert-deftest drgnx-ui-recent-editors/ctrl-tab-goes-back-and-cycles ()
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-recent-editors" t)))
        (minor-mode-map-alist (cons (cons t (let ((m (make-sparse-keymap))) (keymap-set m "C-<tab>" #'tab-next) m))
                                    minor-mode-map-alist))
        bufs)
    (unwind-protect
        (drgnx-test-with-modules '(core/workbench)
          (drgnx-keys-use '((vscode app editing window)))
          (unwind-protect
              (progn
                (should (eq (key-binding (kbd "C-<tab>")) #'drgnx-chrome-recent-editor))
                (dolist (name '("a.txt" "b.txt" "c.txt"))
                  (let ((f (expand-file-name name dir)))
                    (write-region "x\n" nil f nil 'silent)
                    (switch-to-buffer (find-file-noselect f))
                    (drgnx-chrome-apply nil t)
                    (push (current-buffer) bufs)))
                (pcase-let ((`(,c ,b ,a) bufs))
                  (should (eq (window-buffer) c))
                  (drgnx-uitest-run (drgnx-uitest-key-events "C-<tab> RET"))       ; back to the one used before
                  (should-not (active-minibuffer-window))
                  (should (eq (window-buffer) b))
                  (drgnx-uitest-run (drgnx-uitest-key-events "C-<tab> C-<tab> RET")) ; Ctrl held, Tab twice: further back
                  (should (eq (window-buffer) a))
                  (drgnx-uitest-run (drgnx-uitest-key-events "C-<tab> C-<tab> C-S-<tab> RET"))
                  (should (eq (window-buffer) b))))
            (drgnx-keys--restore)))
      (dolist (b bufs) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
      (delete-directory dir t))))

(provide 'recent-editors-gui-test)
;;; recent-editors-gui-test.el ends here
