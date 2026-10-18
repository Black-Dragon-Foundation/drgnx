;;; edit-clipboard-test.el --- batch tests: copy, cut and paste by key profile (M12b Task 14) -*- lexical-binding: t -*-
;; The keys are really applied (the module's commands, the real profiles) and the keys are pressed with a keyboard
;; macro, so the region-only map, Emacs' prefixes and the command loop's own deactivation are all in play.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/editor/drgnx-editing" drgnx-dir) nil t)

(defmacro drgnx-edit-clip-test--keys (layers &rest body)
  "BODY with the editing module's commands registered and the key LAYERS applied (undone after)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-edit-clip" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                       process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-keys--applied nil) (drgnx-keys--session-layers ,layers) (drgnx-keys-profiles nil)
          (drgnx-keys-problems nil) (drgnx-keys-last nil)
          (emulation-mode-map-alists emulation-mode-map-alists) (drgnx-editing-prefix-delay 0.05)
          (kill-ring nil) (kill-ring-yank-pointer nil) (interprogram-cut-function nil) (interprogram-paste-function nil))
     (unwind-protect
         (progn (funcall (plist-get (alist-get 'editor/editing drgnx-modules--table) :setup))
                (drgnx-keys-apply)
                ,@body)
       (drgnx-keys--restore)
       (delete-directory dir t))))

(defmacro drgnx-edit-clip-test--buffer (text &rest body)
  "BODY in the selected window showing a fresh buffer with TEXT (point at the start)."
  (declare (indent 1))
  `(save-window-excursion
     (let ((buf (generate-new-buffer " *edit-clip*")))
       (unwind-protect
           (progn (switch-to-buffer buf)
                  (insert ,text)
                  (goto-char (point-min))
                  (setq-local transient-mark-mode t)
                  ,@body)
         (kill-buffer buf)))))

(defun drgnx-edit-clip-test--select (beg end)
  "Select BEG to END, point at END, as a Shift-arrow selection leaves it."
  (set-mark beg)
  (goto-char end)
  (activate-mark))

(defvar drgnx-edit-clip-test--ran nil "Set by the test mode's `C-c C-c'.")

(defun drgnx-edit-clip-test--mode-command ()
  (interactive)
  (setq drgnx-edit-clip-test--ran t))

(defun drgnx-edit-clip-test--mode-keys ()
  "Give the current buffer a mode's `C-c C-c', as a major mode does."
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c C-c" #'drgnx-edit-clip-test--mode-command)
    (use-local-map map)))

(defun drgnx-edit-clip-test--press (keys)
  "Press KEYS (`kbd' syntax) in the selected window's buffer, through the command loop."
  (execute-kbd-macro (kbd keys)))

;;;; The VS Code profile

(ert-deftest drgnx-editing/vscode-c-c-copies-a-selection ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--select 1 6)
      (drgnx-edit-clip-test--press "C-c")
      (should (equal (car kill-ring) "hello"))
      (should (equal (buffer-string) "hello drgnx"))
      (should-not (region-active-p)))))

(ert-deftest drgnx-editing/vscode-c-c-without-a-selection-is-the-prefix ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--mode-keys)
      (should (keymapp (key-binding (kbd "C-c"))))
      (should (eq (key-binding (kbd "C-c C-c")) #'drgnx-edit-clip-test--mode-command))
      (setq drgnx-edit-clip-test--ran nil)
      (drgnx-edit-clip-test--press "C-c C-c")
      (should drgnx-edit-clip-test--ran)
      (should-not kill-ring)
      ;; With a selection, the same key copies instead.
      (drgnx-edit-clip-test--select 1 6)
      (should (eq (key-binding (kbd "C-c")) #'drgnx-editing-copy)))))

(ert-deftest drgnx-editing/vscode-an-empty-selection-keeps-the-prefix ()
  ;; C-SPC and no move leaves the mark active on nothing: C-c C-c and C-x C-s must still work.
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--mode-keys)
      (setq drgnx-edit-clip-test--ran nil)
      (drgnx-edit-clip-test--select 3 3)
      (drgnx-edit-clip-test--press "C-c C-c")
      (should drgnx-edit-clip-test--ran)
      (should-not kill-ring)
      (should-not mark-active)
      (drgnx-edit-clip-test--select 3 3)
      (should (eq (lookup-key (current-local-map) (kbd "C-c C-c")) #'drgnx-edit-clip-test--mode-command))
      (cl-letf (((symbol-function 'save-buffer) (lambda (&rest _) (interactive) (setq drgnx-edit-clip-test--ran 'saved))))
        (drgnx-edit-clip-test--press "C-x C-s"))
      (should (eq drgnx-edit-clip-test--ran 'saved))
      (should (equal (buffer-string) "hello drgnx")))))

(ert-deftest drgnx-editing/vscode-c-x-cuts-a-selection ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--select 1 7)
      (drgnx-edit-clip-test--press "C-x")
      (should (equal (car kill-ring) "hello "))
      (should (equal (buffer-string) "drgnx"))
      (should-not (region-active-p)))))

(ert-deftest drgnx-editing/vscode-c-x-cut-in-a-read-only-buffer-copies ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (setq buffer-read-only t)
      (drgnx-edit-clip-test--select 1 6)
      (drgnx-edit-clip-test--press "C-x")
      (should (equal (car kill-ring) "hello"))
      (should (equal (buffer-string) "hello drgnx")))))

(ert-deftest drgnx-editing/vscode-c-x-without-a-selection-is-the-prefix ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (should (keymapp (key-binding (kbd "C-x"))))
      (should (eq (key-binding (kbd "C-x C-s")) #'save-buffer))
      (drgnx-edit-clip-test--select 1 6)
      (should (eq (key-binding (kbd "C-x")) #'drgnx-editing-cut)))))

(ert-deftest drgnx-editing/vscode-c-v-pastes-and-replaces-a-selection ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (kill-new "X")
    (drgnx-edit-clip-test--buffer "hello world"
      (should (eq (key-binding (kbd "C-v")) #'drgnx-editing-paste))
      (goto-char 6)
      (drgnx-edit-clip-test--press "C-v")
      (should (equal (buffer-string) "helloX world"))
      (drgnx-edit-clip-test--select 1 7)           ; "helloX"
      (drgnx-edit-clip-test--press "C-v")
      (should (equal (buffer-string) "X world"))
      (should (= (point) 2))
      (should-not (region-active-p)))))

(ert-deftest drgnx-editing/vscode-paste-is-one-undo-step ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (kill-new "X")
    (drgnx-edit-clip-test--buffer "hello world"
      (buffer-enable-undo)
      (undo-boundary)
      (drgnx-edit-clip-test--select 1 6)
      (drgnx-edit-clip-test--press "C-v")
      (should (equal (buffer-string) "X world"))
      (primitive-undo 1 (if (null (car buffer-undo-list)) (cdr buffer-undo-list) buffer-undo-list))
      (should (equal (buffer-string) "hello world")))))

(ert-deftest drgnx-editing/commands-from-the-palette-without-a-selection-say-so ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello"
      (should-error (call-interactively #'drgnx-editing-copy) :type 'user-error)
      (should-error (call-interactively #'drgnx-editing-cut) :type 'user-error)
      (should (equal (buffer-string) "hello")))))

(ert-deftest drgnx-editing/the-explorer-keeps-its-own-copy-and-paste ()
  ;; The Explorer's C-c/C-x/C-v live in its mode map; the editor's C-v is a global key, which a local map beats.
  (require 'drgnx-explorer)
  (let ((drgnx-commands-problems nil) (drgnx-modules--table (copy-sequence drgnx-modules--table))
        (drgnx-modules--report nil))
    (drgnx-edit-clip-test--keys '((vscode app editing window))
      (drgnx--core-commands)
      (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
      (drgnx-modules-run 'startup)
      (drgnx-keys-apply)
      (drgnx-edit-clip-test--buffer "x"
        (use-local-map drgnx-explorer-mode-map)
        (should (eq (key-binding (kbd "C-v")) #'drgnx-explorer-paste))
        (should (eq (key-binding (kbd "C-c")) #'drgnx-explorer-copy))
        (should (eq (key-binding (kbd "C-x")) #'drgnx-explorer-cut))
        (use-local-map nil)
        (should (eq (key-binding (kbd "C-v")) #'drgnx-editing-paste))
        ;; Neither the keys nor the module resolution report a clash, in the real registry.
        (dolist (c (plist-get drgnx-keys-last :conflicts))
          (should-not (member (plist-get c :key) '("C-c" "C-x" "C-v"))))
        (should-not (seq-find (lambda (p) (string-match-p "\\`edit-\\(copy\\|cut\\|paste\\)" p))
                              (plist-get drgnx-keys-last :problems)))))))

;;;; The Emacs and Vim profiles

(ert-deftest drgnx-editing/emacs-profile-keeps-m-w-and-c-y ()
  (drgnx-edit-clip-test--keys '((emacs app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (should (eq (key-binding (kbd "M-w")) #'kill-ring-save))
      (should (eq (key-binding (kbd "C-y")) #'yank))
      (should (eq (key-binding (kbd "C-v")) #'scroll-up-command))
      (drgnx-edit-clip-test--select 1 6)
      (should (keymapp (key-binding (kbd "C-c"))))
      (should (keymapp (key-binding (kbd "C-x")))))))

(ert-deftest drgnx-editing/emacs-editing-with-vscode-app-keys-keeps-emacs-copy ()
  (drgnx-edit-clip-test--keys '((emacs editing) (vscode app window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (should (eq (key-binding (kbd "M-w")) #'kill-ring-save))
      (should (eq (key-binding (kbd "C-y")) #'yank))
      (should (eq (key-binding (kbd "C-v")) #'scroll-up-command))
      (drgnx-edit-clip-test--select 1 6)
      (should (keymapp (key-binding (kbd "C-c"))))
      (should (keymapp (key-binding (kbd "C-x")))))))

(ert-deftest drgnx-editing/vim-profile-unchanged ()
  ;; Evil is absent in the batch tests: the global keys stay Emacs' own.
  (drgnx-edit-clip-test--keys '((vim app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (should (eq (key-binding (kbd "C-v")) #'scroll-up-command))
      (drgnx-edit-clip-test--select 1 6)
      (should (keymapp (key-binding (kbd "C-c"))))
      (should (keymapp (key-binding (kbd "C-x")))))))

;;;; The prefix delay: a prefix key typed with a selection is still a prefix

(ert-deftest drgnx-editing/vscode-c-x-b-within-the-delay-keeps-the-text ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (setq drgnx-edit-clip-test--ran nil)
      (drgnx-edit-clip-test--select 1 6)
      (cl-letf (((symbol-function 'switch-to-buffer)
                 (lambda (&rest _) (interactive) (setq drgnx-edit-clip-test--ran 'switched))))
        (drgnx-edit-clip-test--press "C-x b"))
      (should (eq drgnx-edit-clip-test--ran 'switched))
      (should (equal (buffer-string) "hello drgnx"))
      (should-not kill-ring)
      (should-not (region-active-p)))))

(ert-deftest drgnx-editing/vscode-c-x-c-s-within-the-delay-saves-the-whole-text ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (setq drgnx-edit-clip-test--ran nil)
      (drgnx-edit-clip-test--select 1 6)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest _) (interactive) (setq drgnx-edit-clip-test--ran (buffer-string)))))
        (drgnx-edit-clip-test--press "C-x C-s"))
      (should (equal drgnx-edit-clip-test--ran "hello drgnx"))
      (should-not kill-ring))))

(ert-deftest drgnx-editing/vscode-c-c-c-c-with-a-selection-reaches-the-mode ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--mode-keys)
      (setq drgnx-edit-clip-test--ran nil)
      (drgnx-edit-clip-test--select 1 6)
      (drgnx-edit-clip-test--press "C-c C-c")
      (should drgnx-edit-clip-test--ran)
      (should-not kill-ring)
      (should (equal (buffer-string) "hello drgnx")))))

(ert-deftest drgnx-editing/vscode-c-x-alone-cuts-after-the-delay ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--select 1 6)
      (drgnx-edit-clip-test--press "C-x")
      (should (equal (car kill-ring) "hello"))
      (should (equal (buffer-string) " drgnx")))))

(ert-deftest drgnx-editing/a-nil-delay-acts-at-once ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (setq drgnx-editing-prefix-delay nil)
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--select 1 6)
      (drgnx-edit-clip-test--press "C-x b")           ; cuts, then b is typed
      (should (equal (car kill-ring) "hello"))
      (should (equal (buffer-string) "b drgnx")))))

(ert-deftest drgnx-editing/the-delay-waits-only-for-a-prefix-key ()
  (should (drgnx-editing--prefix-key-p [?\C-c]))
  (should (drgnx-editing--prefix-key-p [?\C-x]))
  (should-not (drgnx-editing--prefix-key-p [?\s-c]))
  (should-not (drgnx-editing--prefix-key-p [])))

(ert-deftest drgnx-editing/handed-back-keys-are-not-recorded-twice ()
  ;; (t . EVENT) is an event a keyboard macro already recorded.
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--select 1 6)
      (let ((unread-command-events nil) (this-command 'drgnx-editing-cut))
        (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () [24]))
                  ((symbol-function 'read-key) (lambda (&rest _) ?b)))
          (drgnx-editing-cut))
        (should (equal unread-command-events '((t . 24) (t . 98))))
        (should-not (region-active-p)))
      ;; and the empty selection's way back to the prefix
      (drgnx-edit-clip-test--select 3 3)
      (let ((unread-command-events nil) (this-command 'drgnx-editing-copy))
        (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () [3])))
          (drgnx-editing-copy))
        (should (equal unread-command-events '((t . 3))))))))

(ert-deftest drgnx-editing/c-g-within-the-delay-quits-and-cuts-nothing ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello drgnx"
      (drgnx-edit-clip-test--select 1 6)
      (let ((unread-command-events nil) (this-command 'drgnx-editing-cut) quit)
        (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () [24]))
                  ((symbol-function 'read-key) (lambda (&rest _) ?\C-g))
                  ((symbol-function 'keyboard-quit) (lambda () (setq quit t))))   ; a real quit would abort ert
          (drgnx-editing-cut))
        (should quit)
        (should-not unread-command-events))
      (should-not (region-active-p))
      (should-not kill-ring)
      (should (equal (buffer-string) "hello drgnx")))))

(ert-deftest drgnx-editing/paste-with-an-empty-kill-ring-changes-nothing ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (drgnx-edit-clip-test--buffer "hello world"
      (drgnx-edit-clip-test--select 1 6)
      (should-error (drgnx-editing-paste))
      (should (equal (buffer-string) "hello world")))))

;;;; The profiles

(ert-deftest drgnx-editing/copy-keys-add-no-conflict ()
  (drgnx-edit-clip-test--keys '((vscode app editing window))
    (let ((r drgnx-keys-last))
      (should-not (seq-find (lambda (c) (member (plist-get c :key) '("C-c" "C-x" "C-v"))) (plist-get r :conflicts)))
      (should-not (seq-find (lambda (p) (string-match-p "edit-\\(copy\\|cut\\|paste\\)" p)) (plist-get r :problems)))
      (should (equal (mapcar (lambda (id) (mapcar (lambda (b) (plist-get b :key))
                                                  (seq-filter (lambda (b) (eq (plist-get b :id) id)) (plist-get r :bindings))))
                             '(edit-copy edit-cut edit-paste))
                     '(("C-c") ("C-x") ("C-v")))))))

(ert-deftest drgnx-editing/copy-keys-on-a-mac-are-cmd ()
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (drgnx-edit-clip-test--keys '((vscode app editing window))
      (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles :layers '((vscode app editing window))
                                   :platform 'macos)))
        (should (equal (mapcar (lambda (b) (list (plist-get b :id) (plist-get b :key)))
                               (seq-filter (lambda (b) (memq (plist-get b :id) '(edit-copy edit-cut edit-paste))) (plist-get r :bindings)))
                       '((edit-copy "s-c") (edit-cut "s-x") (edit-paste "s-v"))))))))

(ert-deftest drgnx-editing/copy-keys-in-every-profile ()
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (should (equal (sort (mapcar #'car profiles) #'string<) '(emacs vim vscode)))
    (pcase-dolist (`(,name . ,spec) profiles)
      (dolist (id '(edit-copy edit-cut edit-paste))
        (should (equal (list name id t) (list name id (and (assq id (plist-get spec :bind)) t))))))
    (let ((vscode (plist-get (alist-get 'vscode profiles) :bind)))
      (should (equal (assq 'edit-copy vscode) '(edit-copy "C-c" :map drgnx-editing-region-map)))
      (should (equal (assq 'edit-cut vscode) '(edit-cut "C-x" :map drgnx-editing-region-map)))
      (should (equal (assq 'edit-paste vscode) '(edit-paste "C-v"))))
    (dolist (name '(emacs vim))
      (dolist (id '(edit-copy edit-cut edit-paste))
        (should (eq (cadr (assq id (plist-get (alist-get name profiles) :bind))) :none))))))

(ert-deftest drgnx-editing/the-region-map-is-active-only-with-a-mark ()
  (should (member 'drgnx-editing--region-alist (progn (drgnx-edit-clip-test--keys '((emacs app editing window))
                                                        emulation-mode-map-alists))))
  (should (equal (car drgnx-editing--region-alist) (cons 'mark-active drgnx-editing-region-map)))
  (should (keymapp drgnx-editing-region-map)))

;;; edit-clipboard-test.el ends here
