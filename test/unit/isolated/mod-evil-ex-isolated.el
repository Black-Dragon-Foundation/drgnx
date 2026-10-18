;;; mod-evil-ex-isolated.el --- batch tests (own Emacs, test/unit/mod-evil-ex-test.el): Vim's ex commands, ZZ, C-w keys and habits run drgnx's commands -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it those tests skip.
;; The full registry and the startup modules run in a temp configuration (editor/evil chosen, the Vim stack
;; applied), so the keys are the shipped ones; the commands that would close windows or quit are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal)
(require 'drgnx-explorer)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar evil-state)
(defvar evil-ex-commands)
(defvar evil-normal-state-map)
(declare-function evil-ex-execute "evil-ex")
(declare-function evil-normal-state "evil-states")
(declare-function drgnx-evil-stop "drgnx-evil")
(declare-function drgnx-chrome-tabs "drgnx-chrome")
(declare-function drgnx-groups-list "drgnx-groups")

(defvar drgnx-evil-ex-test--calls nil "What the recorded commands ran, newest first.")

(defmacro drgnx-evil-ex-test--with (&rest body)
  "BODY with evil running in the Vim stack, all startup modules run, in a temp configuration and state dir.
Window, tab and group commands are recorded in `drgnx-evil-ex-test--calls' (as (NAME ARG…)); `kill-emacs' fails."
  (declare (indent 0))
  `(drgnx-modal-test-with-evil
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-evil-ex" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config")
                                               (concat "DRGNX_DATA_DIR=" dir "data")
                                               (concat "XDG_STATE_HOME=" dir "state")
                                               (concat "HOME=" dir "home"))
                                         process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
            (drgnx-modules--state nil) (drgnx-modal-engines nil) (drgnx-modal-running nil)
            (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (drgnx-keys--session-layers nil)
            (emulation-mode-map-alists emulation-mode-map-alists)
            (mode-line-saved (default-value 'mode-line-format))
            (drgnx-evil-ex-test--calls nil))
       (make-directory (concat dir "config") t)
       (make-directory (concat dir "home") t)
       (write-region "(:version 1 :enabled (editor/evil))\n" nil (concat dir "config/modules.eld") nil 'silent)
       (unwind-protect
           (progn
             (drgnx--core-commands)
             (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
             (drgnx-modules-run 'startup)
             (drgnx-keys-use '((vim app editing window)))
             (should (eq drgnx-modal-running 'evil))
             (cl-letf (((symbol-function 'kill-emacs) (lambda (&rest _) (ert-fail "kill-emacs was called")))
                       ((symbol-function 'save-buffers-kill-terminal) (lambda (&rest _) (ert-fail "Emacs was quit")))
                       ((symbol-function 'drgnx-session-close-frame)
                        (lambda (&optional _) (interactive) (push '(close-frame) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'drgnx-groups-close)
                        (lambda () (interactive) (push '(close-group) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'drgnx-chrome-close-tab)
                        (lambda () (interactive) (push '(close-tab) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'drgnx-groups-split-right)
                        (lambda () (interactive) (push '(split-right) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'drgnx-groups-split-down)
                        (lambda () (interactive) (push '(split-down) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'drgnx-buffers-save-all)
                        (lambda () (interactive) (push '(save-all) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'save-buffer)
                        (lambda (&rest _) (interactive) (push '(save) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'write-file)
                        (lambda (file &rest _) (interactive "F") (push (list 'save-as file) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'find-file)
                        (lambda (file &rest _) (interactive "F") (push (list 'find-file file) drgnx-evil-ex-test--calls))))
               ,@body))

         (when (fboundp 'drgnx-evil-stop) (drgnx-evil-stop))
         (drgnx-keys--restore)
         (setq-default mode-line-format mode-line-saved)
         (delete-directory dir t)))))

(defmacro drgnx-evil-ex-test--buffer (var mode &rest body)
  "BODY with VAR a new buffer in MODE, shown in the selected window and in the state evil gives it; killed after."
  (declare (indent 2))
  `(let ((,var (generate-new-buffer "evil-ex-test")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer ,var)
           (with-current-buffer ,var (funcall ,mode) ,@body))
       (kill-buffer ,var))))

(defun drgnx-evil-ex-test--calls ()
  "What the recorded commands ran since the last call, oldest first."
  (prog1 (reverse drgnx-evil-ex-test--calls) (setq drgnx-evil-ex-test--calls nil)))

(defmacro drgnx-evil-ex-test--layout (tabs groups &rest body)
  "BODY with the shown group having TABS (a list) and the frame GROUPS (a list), as the chrome and groups report them."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'drgnx-chrome-tabs) (lambda (_w) ,tabs))
             ((symbol-function 'drgnx-groups-list) (lambda (&optional _f) ,groups)))
     ,@body))

;;;; Ex commands

(ert-deftest drgnx-evil-ex/each-ex-command-routes ()
  (drgnx-evil-ex-test--with
    (drgnx-evil-ex-test--buffer b #'text-mode
      (evil-ex-execute "w")
      (should (equal (drgnx-evil-ex-test--calls) '((save))))
      (evil-ex-execute "write /tmp/x.txt")
      (should (equal (drgnx-evil-ex-test--calls) '((save-as "/tmp/x.txt"))))
      (evil-ex-execute "wa")
      (should (equal (drgnx-evil-ex-test--calls) '((save-all))))
      (evil-ex-execute "sp")
      (should (equal (drgnx-evil-ex-test--calls) '((split-down))))
      (evil-ex-execute "vs")
      (should (equal (drgnx-evil-ex-test--calls) '((split-right))))
      (evil-ex-execute "e /tmp/x")
      (should (equal (drgnx-evil-ex-test--calls) '((find-file "/tmp/x"))))
      (drgnx-evil-ex-test--layout (list b) nil
        (evil-ex-execute "qa")
        (should (equal (drgnx-evil-ex-test--calls) '((close-frame))))))))

(ert-deftest drgnx-evil-ex/q-in-the-last-tab-never-kills-emacs ()
  (drgnx-evil-ex-test--with
    (drgnx-evil-ex-test--buffer b #'text-mode
      (drgnx-evil-ex-test--layout (list b) (list (selected-window))
        (evil-ex-execute "q")
        (should (equal (drgnx-evil-ex-test--calls) '((close-frame))))
        (should (eq evil-state 'normal))
        (execute-kbd-macro (kbd "Z Z"))
        (should (equal (drgnx-evil-ex-test--calls) '((close-frame))))
        (evil-ex-execute "wq")
        (should (equal (drgnx-evil-ex-test--calls) '((close-frame))))
        (set-buffer-modified-p t)
        (evil-ex-execute "x")
        (should (equal (drgnx-evil-ex-test--calls) '((save) (close-frame)))))
      ;; two tabs: Close Tab
      (drgnx-evil-ex-test--layout (list b (current-buffer)) (list (selected-window))
        (evil-ex-execute "q")
        (should (equal (drgnx-evil-ex-test--calls) '((close-tab)))))
      ;; one tab, another group: Close Editor Group
      (drgnx-evil-ex-test--layout (list b) (list (selected-window) (selected-window))
        (evil-ex-execute "q")
        (should (equal (drgnx-evil-ex-test--calls) '((close-group))))))))

(ert-deftest drgnx-evil-ex/evils-window-keys-route ()
  (drgnx-evil-ex-test--with
    (drgnx-evil-ex-test--buffer b #'text-mode
      (should (eq evil-state 'normal))
      (execute-kbd-macro (kbd "C-w v"))
      (execute-kbd-macro (kbd "C-w s"))
      (drgnx-evil-ex-test--layout (list b) (list (selected-window) (selected-window))
        (execute-kbd-macro (kbd "C-w c")))
      (should (equal (drgnx-evil-ex-test--calls) '((split-right) (split-down) (close-group)))))))

(ert-deftest drgnx-evil-ex/habits-run-registry-commands ()
  (drgnx-evil-ex-test--with
    (cl-flet ((fn (id) (drgnx-cmd-command (drgnx-commands-get id))))
      (drgnx-evil-ex-test--buffer b #'emacs-lisp-mode
        (should (eq evil-state 'normal))
        (dolist (row '(("g d" . code-definition) ("g r" . code-references) ("K" . code-hover)
                       ("g t" . next-tab) ("g T" . previous-tab) ("] d" . code-next-problem)
                       ("[ d" . code-previous-problem) ("C-w h" . focus-left) ("C-w j" . focus-down)
                       ("C-w k" . focus-up) ("C-w l" . focus-right)))
          (should (eq (key-binding (kbd (car row))) (fn (cdr row)))))
        (should (eq (fn 'code-next-problem) #'flymake-goto-next-error)))
      ;; the conflict report stays clean: none of these keys is reported, and nothing is a problem
      (should-not (plist-get drgnx-keys-last :problems))
      (dolist (c (plist-get drgnx-keys-last :conflicts))
        (should-not (member (plist-get c :key) '("g d" "g r" "K" "g t" "g T" "] d" "[ d"
                                                 "C-w h" "C-w j" "C-w k" "C-w l"))))
      ;; a panel (emacs state) has the window keys too
      (drgnx-evil-ex-test--buffer b #'drgnx-explorer-mode
        (should (eq evil-state 'emacs))
        (should (eq (key-binding (kbd "C-w h")) (fn 'focus-left)))
        (should (eq (key-binding (kbd "C-w l")) (fn 'focus-right)))))))

(ert-deftest drgnx-evil-ex/stop-removes-routes-and-advice ()
  (drgnx-evil-ex-test--with
    (let ((before (alist-get "w" evil-ex-commands nil nil #'equal)))
      (should (advice-member-p #'drgnx-evil-ex-quit 'evil-quit))
      (should-not (eq before 'evil-write))
      (drgnx-evil-stop)
      (dolist (cell '((evil-quit . drgnx-evil-ex-quit) (evil-save-and-close . drgnx-evil-ex-write-quit)
                      (evil-save-modified-and-close . drgnx-evil-ex-write-quit)
                      (evil-window-split . drgnx-evil-ex-split-down) (evil-window-vsplit . drgnx-evil-ex-split-right)
                      (evil-window-delete . drgnx-evil-ex-close-group) (evil-quit-all . drgnx-evil-ex-close-window)))
        (should-not (advice-member-p (cdr cell) (car cell))))
      (should-not (advice-member-p #'drgnx-evil-ex-quit 'evil-quit))
      (dolist (cell '(("w" . evil-write) ("wa" . evil-write-all) ("e" . evil-edit) ("sp" . evil-window-split)
                      ("vs" . evil-window-vsplit)))
        (should (eq (alist-get (car cell) evil-ex-commands nil nil #'equal) (cdr cell)))))))

(provide 'mod-evil-ex-isolated)
;;; mod-evil-ex-isolated.el ends here
