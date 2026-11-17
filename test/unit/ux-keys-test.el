;;; ux-keys-test.el --- batch tests: the VS Code profile's Ctrl+A/Q/O, Ctrl+Shift+U/W, Ctrl+K Ctrl+T; Open File's folder -*- lexical-binding: t -*-
;; test-class: det
;; The audit's K3, K4 and T1's shared helper.  The three profiles' own files are read as data (command id -> keys); the
;; keys go through the command loop in test/ui/vscode-keys-gui-test.el.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-session)
(require 'drgnx-paths)

(defun ux-keys-test--bind (profile)
  "PROFILE's (`vscode', `emacs' or `vim') :bind alist, read from keys/PROFILE.eld."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
    (plist-get (read (current-buffer)) :bind)))

(defun ux-keys-test--entry (profile id) (assq id (ux-keys-test--bind profile)))

(ert-deftest drgnx-keys/the-vscode-profile-has-its-k3-keys ()
  (should (equal (ux-keys-test--entry 'vscode 'edit-select-all) '(edit-select-all "C-a" :mac "s-a")))
  (should (equal (ux-keys-test--entry 'vscode 'view-output) '(view-output "C-S-u")))
  (should (equal (ux-keys-test--entry 'vscode 'file-close-window) '(file-close-window "C-S-w" :mac "s-W")))
  (should (equal (ux-keys-test--entry 'vscode 'preferences-theme) '(preferences-theme "C-k C-t")))
  (should (equal (ux-keys-test--entry 'vscode 'quit) '(quit "C-q" :mac "s-q")))
  (should (equal (ux-keys-test--entry 'vscode 'open-file) '(open-file "C-o"))))

(ert-deftest drgnx-keys/the-other-profiles-keep-their-own-keys-for-them ()
  "Emacs and Vim give Select All, Close Window and View: Output no VS Code key: C-a stays beginning-of-line."
  (dolist (profile '(emacs vim))
    (dolist (id '(edit-select-all file-close-window view-output))
      (let ((e (ux-keys-test--entry profile id)))
        (should e)
        (should (eq (cadr e) :none))))
    (should-not (equal (cadr (ux-keys-test--entry profile 'quit)) "C-q"))))

(ert-deftest drgnx-session/the-workspace-folder-is-the-explorers-innermost-folder-holding-it ()
  (let* ((a (file-name-as-directory (make-temp-file "ux-keys-a" t)))
         (b (file-name-as-directory (expand-file-name "inner" a))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "x/y" b) t)
          (cl-letf (((symbol-function 'drgnx-explorer-roots) (lambda () (list a b))))
            (should (equal (drgnx-session-workspace-folder (expand-file-name "x/y/" b)) b))   ; the innermost
            (should (equal (drgnx-session-workspace-folder a) a))
            (should (equal (drgnx-session-workspace-folder "/ssh:host:/some/dir/") "/ssh:host:/some/dir/")))
          (cl-letf (((symbol-function 'drgnx-explorer-roots) (lambda () nil)))   ; no folder: the dir itself
            (should (equal (drgnx-session-workspace-folder a) a))))
      (delete-directory a t))))

(ert-deftest drgnx-basics/open-file-asks-from-the-workspace-folder ()
  (load (expand-file-name "modules/core/drgnx-basics" drgnx-dir) nil t)
  (let* ((root (file-name-as-directory (make-temp-file "ux-keys-open" t)))
         (sub (file-name-as-directory (expand-file-name "sub" root)))
         asked opened)
    (unwind-protect
        (progn
          (make-directory sub t)
          (cl-letf (((symbol-function 'drgnx-explorer-roots) (lambda () (list root)))
                    ((symbol-function 'read-file-name) (lambda (_p &optional dir &rest _) (setq asked dir) "picked.txt"))
                    ((symbol-function 'find-file) (lambda (f &optional wildcards) (setq opened (list f wildcards)))))
            (let ((default-directory sub))
              (call-interactively #'drgnx-basics-open-file)))
          (should (equal asked root))
          (should (equal opened '("picked.txt" t))))
      (delete-directory root t))))

(provide 'ux-keys-test)
;;; ux-keys-test.el ends here
