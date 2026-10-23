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

(defvar drgnx-evil-ex-test--modules "(:version 1 :enabled (editor/evil))\n"
  "The module choices of the temp configuration, written as the old modules.eld plist (they become settings.el's entries).")

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
       (load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
       (drgnx-test-areas-put-old 'modules drgnx-evil-ex-test--modules)       ; as settings.el's entries
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
                       ((symbol-function 'drgnx-wb-focus-editor)
                        (lambda () (interactive) (push '(focus-editor) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'revert-buffer)
                        (lambda (&rest _) (push '(revert) drgnx-evil-ex-test--calls)))
                       ((symbol-function 'shell-command-on-region)
                        (lambda (_b _e cmd &rest _) (push (list 'shell cmd) drgnx-evil-ex-test--calls)))
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
      (dolist (cell drgnx-evil--advice-pairs)
        (should-not (advice-member-p (cdr cell) (car cell))))
      (should (= (length drgnx-evil--advice-pairs) 9))
      (dolist (cell '(evil-save-and-quit evil-quit-all-with-error-code))
        (should (assq cell drgnx-evil--advice-pairs)))
      (should-not (advice-member-p #'drgnx-evil-ex-quit 'evil-quit))
      (dolist (cell '(("w" . evil-write) ("wa" . evil-write-all) ("e" . evil-edit)))
        (should (eq (alist-get (car cell) evil-ex-commands nil nil #'equal) (cdr cell)))))))

(ert-deftest drgnx-evil-ex/bang-shell-and-special-file-arguments-are-evils ()
  (drgnx-evil-ex-test--with
    (let* ((file (expand-file-name "visited.txt" (make-temp-file "drgnx-evil-ex-file" t))))
      (drgnx-evil-ex-test--buffer b #'text-mode
        (setq buffer-file-name file)
        (set-buffer-modified-p nil)
        ;; :w! is evil's: it writes the visited file, not a file named "!"
        (evil-ex-execute "w!")
        (should (equal (drgnx-evil-ex-test--calls) `((save-as ,file))))
        ;; :w !cmd pipes to the command
        (evil-ex-execute "w !cat")
        (should (equal (drgnx-evil-ex-test--calls) '((shell "cat"))))
        ;; :e! re-reads the file (never opens a file named "!")
        (evil-ex-execute "e!")
        (should (equal (drgnx-evil-ex-test--calls) '((revert))))
        ;; % is the visited file
        (evil-ex-execute "e %")
        (should (equal (drgnx-evil-ex-test--calls) `((find-file ,file))))
        (evil-ex-execute (concat "w " (file-name-directory file) "other.txt"))
        (should (equal (drgnx-evil-ex-test--calls) `((save-as ,(concat (file-name-directory file) "other.txt")))))
        (evil-ex-execute "w %")
        (should (equal (drgnx-evil-ex-test--calls) `((save-as ,file))))
        ;; arguments complete as evil's own: files for :e, files or shell commands for :w, the bang is parsed
        (dolist (row '(("e" file) ("w" file-or-shell) ("wa" nil)))
          (let ((fn (evil-ex-completed-binding (car row))))
            (should (eq (evil-get-command-property fn :ex-arg) (cadr row)))
            (should (evil-get-command-property fn :ex-bang))))
        (set-buffer-modified-p nil)
        (setq buffer-file-name nil)))))

(ert-deftest drgnx-evil-ex/sp-and-vs-open-the-file-in-the-new-group ()
  (drgnx-evil-ex-test--with
    (drgnx-evil-ex-test--buffer b #'text-mode
      (evil-ex-execute "sp /tmp/one.txt")
      (should (equal (drgnx-evil-ex-test--calls) '((split-down) (find-file "/tmp/one.txt"))))
      (evil-ex-execute "vs /tmp/two.txt")
      (should (equal (drgnx-evil-ex-test--calls) '((split-right) (find-file "/tmp/two.txt"))))
      (evil-ex-execute "sp")
      (should (equal (drgnx-evil-ex-test--calls) '((split-down)))))))

(ert-deftest drgnx-evil-ex/the-quit-all-variants-never-quit-emacs ()
  (drgnx-evil-ex-test--with
    (drgnx-evil-ex-test--buffer b #'text-mode
      (dolist (cmd '("qa" "quitall" "cq"))
        (evil-ex-execute cmd)
        (should (equal (drgnx-evil-ex-test--calls) '((close-frame)))))
      (dolist (cmd '("wqa" "wqall" "xa" "xall"))
        (evil-ex-execute cmd)
        (should (equal (drgnx-evil-ex-test--calls) '((save-all) (close-frame))))))))

(ert-deftest drgnx-evil-ex/q-and-close-group-in-a-dock-go-back-to-the-editor ()
  (drgnx-evil-ex-test--with
    (drgnx-evil-ex-test--buffer b #'text-mode
      ;; the selected window is not one of the groups: a dock
      (drgnx-evil-ex-test--layout (list b) (list 'a-group 'another-group)
        (evil-ex-execute "q")
        (should (equal (drgnx-evil-ex-test--calls) '((focus-editor))))
        (evil-ex-execute "clo")
        (should (equal (drgnx-evil-ex-test--calls) '((focus-editor))))
        (execute-kbd-macro (kbd "C-w c"))
        (should (equal (drgnx-evil-ex-test--calls) '((focus-editor))))
        (execute-kbd-macro (kbd "Z Q"))
        (should (equal (drgnx-evil-ex-test--calls) '((focus-editor))))))))

(ert-deftest drgnx-evil-ex/without-the-workbench-evils-own-commands-run ()
  (let ((drgnx-evil-ex-test--modules "(:version 1 :enabled (editor/evil) :disabled (core/workbench))\n"))
    (drgnx-evil-ex-test--with
      (should-not (drgnx-evil-ex--workbench-p))
      (drgnx-evil-ex-test--buffer b #'text-mode
        ;; every advice hands over to evil's own function
        (dolist (fn '(drgnx-evil-ex-quit drgnx-evil-ex-write-quit drgnx-evil-ex-split-down drgnx-evil-ex-split-right
                                         drgnx-evil-ex-close-group))
          (let ((seen nil))
            (funcall fn (lambda (&rest args) (push args seen)) 1 2)
            (should (equal seen '((1 2))))))
        (should-not (drgnx-evil-ex-test--calls))
        ;; the ex command and the key reach evil's split, not a missing registry command
        (save-window-excursion
          (let ((n (length (window-list))))
            (evil-ex-execute "sp")
            (should (= (length (window-list)) (1+ n)))
            (execute-kbd-macro (kbd "C-w v"))
            (should (= (length (window-list)) (+ n 2)))))
        (should-not (drgnx-evil-ex-test--calls))))))

(defvar with-editor-mode)
(defvar server-buffer-clients)

(ert-deftest drgnx-evil-ex/commit-and-client-buffers-finish-the-edit ()
  ;; magit's commit or rebase message (with-editor) and an emacsclient buffer: ZZ, :wq and :x end the edit, so git
  ;; or the client stops waiting; :q and ZQ cancel it (:q! in a client buffer drops it unsaved).  The workbench's
  ;; Close Tab or Close Window never runs there, and evil-collection gives with-editor its ZZ / ZQ.
  (drgnx-evil-ex-test--with
    (should (memq 'with-editor drgnx-evil-collection-modes))
    (cl-letf (((symbol-function 'with-editor-finish)
               (lambda (&rest _) (interactive) (push '(finish) drgnx-evil-ex-test--calls)))
              ((symbol-function 'with-editor-cancel)
               (lambda (&rest _) (interactive) (push '(cancel) drgnx-evil-ex-test--calls)))
              ((symbol-function 'server-edit)
               (lambda (&rest _) (interactive) (push '(server-edit) drgnx-evil-ex-test--calls)))
              ((symbol-function 'server-buffer-done)
               (lambda (&rest _) (push '(server-done) drgnx-evil-ex-test--calls))))
      (drgnx-evil-ex-test--buffer b #'text-mode
        (drgnx-evil-ex-test--layout (list b) (list (selected-window))
          (setq-local with-editor-mode t)
          (set-buffer-modified-p t)
          (dolist (cmd '("wq" "x"))
            (evil-ex-execute cmd)
            (should (equal (drgnx-evil-ex-test--calls) '((finish)))))
          (execute-kbd-macro (kbd "Z Z"))
          (should (equal (drgnx-evil-ex-test--calls) '((finish))))
          (evil-ex-execute "q")
          (should (equal (drgnx-evil-ex-test--calls) '((cancel))))
          (execute-kbd-macro (kbd "Z Q"))
          (should (equal (drgnx-evil-ex-test--calls) '((cancel))))
          (setq-local with-editor-mode nil)
          (setq-local server-buffer-clients (list 'a-client))
          (evil-ex-execute "wq")
          (should (equal (drgnx-evil-ex-test--calls) '((save) (server-edit))))
          (set-buffer-modified-p nil)
          (evil-ex-execute "x")
          (should (equal (drgnx-evil-ex-test--calls) '((server-edit))))
          (execute-kbd-macro (kbd "Z Z"))
          (should (equal (drgnx-evil-ex-test--calls) '((server-edit))))
          (evil-ex-execute "q")
          (should (equal (drgnx-evil-ex-test--calls) '((server-edit))))
          (evil-ex-execute "q!")
          (should (equal (drgnx-evil-ex-test--calls) '((server-done))))
          (setq-local server-buffer-clients nil)
          (evil-ex-execute "q")
          (should (equal (drgnx-evil-ex-test--calls) '((close-frame)))))))))

(ert-deftest drgnx-evil-ex/stop-keeps-what-the-user-defined-meanwhile ()
  (drgnx-evil-ex-test--with
    (evil-ex-define-cmd "w[rite]" 'ignore)         ; the user's own, after the engine started
    (drgnx-evil-stop)
    (should (eq (alist-get "w" evil-ex-commands nil nil #'equal) 'ignore))
    (should (eq (alist-get "wri" evil-ex-commands nil nil #'equal) 'ignore))
    (should (eq (alist-get "wa" evil-ex-commands nil nil #'equal) 'evil-write-all))
    (evil-ex-define-cmd "w[rite]" 'evil-write)))   ; evil's again for the tests after this one

(provide 'mod-evil-ex-isolated)
;;; mod-evil-ex-isolated.el ends here
