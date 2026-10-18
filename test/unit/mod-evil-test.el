;;; mod-evil-test.el --- batch tests: editor/evil, evil as drgnx's Vim engine (states, indicator, cursor, toggle) -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it those tests skip.
;; Everything runs in a temp configuration, state dir and HOME; the module table, the engine registry and the
;; mode line are put back after each test.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal)
(require 'drgnx-explorer)
(require 'drgnx-buffers)
(require 'drgnx-outline)
(require 'eshell)
(require 'log-edit)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar xterm-update-cursor)
(defvar which-key-mode)
(defvar which-key-show-transient-maps)
(defvar evil-state)
(defvar evil-local-mode)
(defvar evil-mode-map-alist)
(defvar evil-undo-system)
(defvar evil-want-C-u-scroll)
(defvar evil-search-module)
(defvar evil-want-minibuffer)
(defvar evil-mode-line-format)
(defvar evil-want-keybinding)
(defvar evil-normal-state-entry-hook)
(defvar evil-normal-state-cursor)
(defvar git-commit-setup-hook)
(defvar eshell-directory-name)
(defvar eshell-history-file-name)
(defvar eshell-last-dir-ring-file-name)
(defvar drgnx-work-mode-hook)
(defvar drgnx-evil-test--count 0)
(declare-function evil-mode "evil-core")
(declare-function evil-normal-state "evil-states")
(declare-function evil-insert-state "evil-states")
(declare-function evil-replace-state "evil-states")
(declare-function evil-emacs-state "evil-states")
(declare-function evil-visual-char "evil-states")
(declare-function evil-visual-line "evil-states")
(declare-function evil-visual-block "evil-states")
(declare-function evil-refresh-cursor "evil-common")
(declare-function evil-local-mode "evil-core")
(declare-function which-key-mode "which-key")
(declare-function drgnx-evil-stop "drgnx-evil")
(declare-function drgnx-evil-toggle "drgnx-evil")
(declare-function drgnx-evil-doctor "drgnx-evil")
(declare-function drgnx-terminal-new "drgnx-terminal")

(defconst drgnx-evil-test--module (expand-file-name "modules/editor/drgnx-evil.el" drgnx-dir))

(defun drgnx-evil-test--cmd ()
  "A command bound at SPC t t in the leader map by the tests."
  (interactive)
  (cl-incf drgnx-evil-test--count))

(defmacro drgnx-evil-test--config (layers enabled &rest body)
  "BODY in a temp configuration whose keys.eld has LAYERS, with the module loaded (not run) and, when
ENABLED, chosen in modules.eld.  Tables, the engine registry and the mode line are put back after; evil is
stopped.  Evil's packages are not on `load-path' here."
  (declare (indent 2))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-evil" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state")
                                             (concat "HOME=" root "home"))
                                       process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-modal-engines nil) (drgnx-modal-running nil)
          (drgnx-keys--session-layers nil) (drgnx-keys-last nil) (drgnx-keys-profiles nil)
          (drgnx-keys-problems nil)
          (emulation-mode-map-alists emulation-mode-map-alists)
          (drgnx-evil-test--count 0)
          (mode-line-saved (default-value 'mode-line-format)))
     (make-directory (concat root "config") t)
     (make-directory (concat root "home") t)
     (write-region (format "%S\n" (list :layers ,layers)) nil (concat root "config/keys.eld") nil 'silent)
     (when ,enabled
       (write-region "(:version 1 :enabled (editor/evil))\n" nil (concat root "config/modules.eld") nil 'silent))
     (unwind-protect
         (progn (load drgnx-evil-test--module nil t t)
                ,@body)
       (when (fboundp 'drgnx-evil-stop) (drgnx-evil-stop))
       (when (fboundp 'evil-mode) (evil-mode -1))
       (setq-default mode-line-format mode-line-saved)
       (delete-directory root t))))

(defmacro drgnx-evil-test--with (&rest body)
  "BODY with evil available, a Vim stack and `editor/evil' chosen; the module has not run yet."
  (declare (indent 0))
  `(drgnx-modal-test-with-evil
     (drgnx-evil-test--config '((vim app editing window)) t
       ,@body)))

(defun drgnx-evil-test--run ()
  "Run the module's setup the way the startup stage does; returns its status."
  (drgnx-modules--run-one 'editor/evil (alist-get 'editor/evil drgnx-modules--table) 'startup)
  (plist-get (alist-get 'editor/evil (drgnx-modules-report)) :status))

(defmacro drgnx-evil-test--running (&rest body)
  "BODY with the module run and evil on in the Vim stack."
  (declare (indent 0))
  `(drgnx-evil-test--with
     (should (eq (drgnx-evil-test--run) 'ok))
     ,@body))

(defmacro drgnx-evil-test--buffer (var mode &rest body)
  "BODY with VAR a new buffer in MODE, shown in the selected window (evil refreshes the cursor only there); killed after."
  (declare (indent 2))
  `(let ((,var (generate-new-buffer "evil-test")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer ,var)
           (with-current-buffer ,var (funcall ,mode) ,@body))
       (kill-buffer ,var))))

(defun drgnx-evil-test--line ()
  "The mode line's `:eval' segments as text (`format-mode-line' gives nothing in batch)."
  (mapconcat (lambda (seg)
               (let ((v (and (eq (car-safe seg) :eval) (eval (cadr seg) t))))
                 (if (stringp v) v "")))
             (default-value 'mode-line-format) ""))

;;;; Off until chosen

(ert-deftest drgnx-evil/off-by-default ()
  (drgnx-evil-test--config '((vim app editing window)) nil
    (let ((before (featurep 'evil)) (ran nil))
      (cl-letf (((symbol-function 'drgnx-evil-setup) (lambda () (setq ran t))))
        (should (drgnx-module-default-off-p 'editor/evil))
        (should (eq (drgnx-evil-test--run) 'disabled))
        (should-not ran)
        (should-not drgnx-modal-running)
        (should (eq before (featurep 'evil)))
        (should-not (assq 'evil drgnx-modal-engines))))))

(ert-deftest drgnx-evil/vim-stack-starts-evil ()
  (drgnx-evil-test--running
    (should (bound-and-true-p evil-mode))
    (should (eq drgnx-modal-running 'evil))
    (should (assq 'evil drgnx-modal-engines))
    (drgnx-evil-test--buffer b #'prog-mode
      (should (eq drgnx-modal-state 'normal))
      (should (string-search " NORMAL " (drgnx-evil-test--line))))))

(ert-deftest drgnx-evil/a-vscode-stack-never-starts-it ()
  (drgnx-modal-test-with-evil
    (drgnx-evil-test--config '((vscode app editing window)) t
      (should (eq (drgnx-evil-test--run) 'ok))
      (should-not drgnx-modal-running)
      (should-not (bound-and-true-p evil-mode)))))

(ert-deftest drgnx-evil/a-vscode-stack-stops-the-engine ()
  (drgnx-evil-test--running
    (drgnx-evil-test--buffer b #'prog-mode
      (should (eq drgnx-modal-state 'normal))
      (should (eq (drgnx-modal-sync-engine '((vscode app editing window))) nil))
      (should-not (bound-and-true-p evil-mode))
      (should-not drgnx-modal-running)
      (dolist (buf (buffer-list))
        (with-current-buffer buf (should-not drgnx-modal-state)))
      (should-not (string-search "NORMAL" (drgnx-evil-test--line)))
      (should-not (member '(:eval (drgnx-modal-mode-line)) (default-value 'mode-line-format))))))

;;;; Panels, forms, inputs

(ert-deftest drgnx-evil/panels-are-emacs-state-without-a-cursor ()
  (drgnx-evil-test--running
    (dolist (mode '(drgnx-explorer-mode drgnx-buffers-mode drgnx-outline-mode))
      (drgnx-evil-test--buffer b mode
        (should (eq drgnx-modal-state 'emacs))
        (should (eq drgnx-modal-state (drgnx-modal-initial-state)))
        (should-not cursor-type)
        (evil-normal-state)
        (evil-emacs-state)
        (evil-refresh-cursor)
        (should (eq drgnx-modal-state 'emacs))
        (should-not cursor-type)))))

(ert-deftest drgnx-evil/a-panel-that-sets-a-cursor-keeps-it ()
  (drgnx-evil-test--running
    (load (expand-file-name "modules/tools/drgnx-work-ui" drgnx-dir) nil t)
    (let ((drgnx-work-mode-hook (list (lambda () (setq cursor-type 'hollow)))))
      (drgnx-evil-test--buffer b #'drgnx-work-mode
        (should (eq drgnx-modal-state 'emacs))
        (should (eq cursor-type 'hollow))
        (evil-normal-state)
        (evil-emacs-state)
        (evil-refresh-cursor)
        (should (eq cursor-type 'hollow))))))

(ert-deftest drgnx-evil/forms-are-emacs-state ()
  (drgnx-evil-test--running
    (load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
    (drgnx-evil-test--buffer b #'drgnx-replace-mode
      (should (eq drgnx-modal-state 'emacs))
      (should-not drgnx-modal--leader-on)
      (should-not drgnx-modal--panel-on))))

(ert-deftest drgnx-evil/inputs-start-in-insert ()
  (drgnx-evil-test--running
    (let* ((dir (file-name-as-directory (concat root "home")))
           (eshell-directory-name dir) (eshell-history-file-name nil) (eshell-last-dir-ring-file-name nil))
      (load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)
      (let ((shell (drgnx-terminal-new dir)))
        (unwind-protect
            (with-current-buffer shell
              (should (derived-mode-p 'eshell-mode))
              (should (eq drgnx-modal-state 'insert))
              (should (eq drgnx-modal-state (drgnx-modal-initial-state))))
          (kill-buffer shell))))
    (drgnx-evil-test--buffer b #'log-edit-mode
      (should (eq drgnx-modal-state 'insert)))))

(ert-deftest drgnx-evil/the-minibuffer-is-never-modal ()
  (drgnx-evil-test--running
    ;; batch Emacs reads a minibuffer from stdin unless a keyboard macro runs: <f9> RET asks, RET answers
    (let* ((seen 'unset)
           (ask (lambda ()
                  (interactive)
                  (minibuffer-with-setup-hook
                      (lambda () (setq seen (list (bound-and-true-p evil-local-mode) drgnx-modal-state)))
                    (read-string "evil test: "))))
           (overriding-local-map (define-keymap "<f9>" ask)))
      (execute-kbd-macro (kbd "<f9> RET"))
      (should (equal seen '(nil nil))))))

(ert-deftest drgnx-evil/a-commit-message-starts-in-insert ()
  (drgnx-evil-test--running
    (drgnx-evil-test--buffer b #'text-mode
      (should (eq drgnx-modal-state 'normal))
      (run-hooks 'git-commit-setup-hook)
      (should (eq drgnx-modal-state 'insert)))))

(ert-deftest drgnx-evil/buffers-made-before-the-engine-get-their-state ()
  (drgnx-modal-test-with-evil
    (drgnx-evil-test--config '((vim app editing window)) t
      (let ((code (generate-new-buffer "evil-before-code"))
            (panel (generate-new-buffer "evil-before-panel"))
            (shell (generate-new-buffer "evil-before-shell"))
            (eshell-directory-name (concat root "home/")) (eshell-history-file-name nil)
            (eshell-last-dir-ring-file-name nil))
        (unwind-protect
            (progn
              (with-current-buffer code (prog-mode))
              (with-current-buffer panel (drgnx-explorer-mode))
              (with-current-buffer shell (let ((default-directory (concat root "home/"))) (eshell-mode)))
              (dolist (b (list code panel shell))
                (should-not (buffer-local-value 'drgnx-modal-state b)))
              (should (eq (drgnx-evil-test--run) 'ok))
              (should (eq (buffer-local-value 'drgnx-modal-state code) 'normal))
              (should (eq (buffer-local-value 'drgnx-modal-state panel) 'emacs))
              (should (eq (buffer-local-value 'drgnx-modal-state shell) 'insert))
              (save-window-excursion
                (switch-to-buffer code)
                (evil-refresh-cursor)
                (should (eq cursor-type 'box))
                (switch-to-buffer panel)
                (evil-refresh-cursor)
                (should-not cursor-type)))
          (mapc #'kill-buffer (list code panel shell)))))))

(ert-deftest drgnx-evil/a-mode-change-follows-the-new-mode ()
  (drgnx-evil-test--running
    (drgnx-evil-test--buffer b #'prog-mode
      (should (eq drgnx-modal-state 'normal))
      (drgnx-outline-mode)
      (should (eq drgnx-modal-state 'emacs))
      (should drgnx-modal--panel-on)
      (prog-mode)
      (should (eq drgnx-modal-state 'normal))
      (should-not drgnx-modal--panel-on))))

;;;; Leader, order

(ert-deftest drgnx-evil/leader-active-follows-state ()
  (drgnx-evil-test--running
    (let ((saved (copy-tree drgnx-modal-leader-map)))
      (unwind-protect
          (progn
            (keymap-set drgnx-modal-leader-map "SPC t t" #'drgnx-evil-test--cmd)
            (drgnx-evil-test--buffer b #'text-mode
              (save-window-excursion
                (switch-to-buffer b)
                (should (eq drgnx-modal-state 'normal))
                (execute-kbd-macro (kbd "SPC t t"))
                (should (= drgnx-evil-test--count 1))
                (should (equal (buffer-string) ""))
                (evil-insert-state)
                (execute-kbd-macro (kbd "SPC t t"))
                (should (= drgnx-evil-test--count 1))
                (should (equal (buffer-string) " tt")))))
        (setcdr drgnx-modal-leader-map (cdr saved))))))

(ert-deftest drgnx-evil/alists-stay-ordered ()
  (drgnx-evil-test--running
    (let ((pos (lambda (sym) (cl-position sym emulation-mode-map-alists))))
      (setq emulation-mode-map-alists
            (cons 'evil-mode-map-alist (delq 'evil-mode-map-alist emulation-mode-map-alists)))
      (should (< (funcall pos 'evil-mode-map-alist) (funcall pos 'drgnx-modal--leader-alist)))
      (drgnx-evil-test--buffer b #'text-mode
        (evil-local-mode -1)
        (evil-local-mode 1))
      (should (< (funcall pos 'drgnx-modal--leader-alist) (funcall pos 'evil-mode-map-alist))))))

;;;; States, cursor, indicator

(ert-deftest drgnx-evil/visual-types-reach-the-core ()
  (drgnx-evil-test--running
    (drgnx-evil-test--buffer b #'text-mode
      (insert "one two\nthree\n")
      (goto-char (point-min))
      (evil-visual-char)
      (should (eq drgnx-modal-state 'visual))
      (should (string-search " VISUAL " (drgnx-evil-test--line)))
      (evil-visual-line)
      (should (eq drgnx-modal-state 'visual-line))
      (should (string-search " V-LINE " (drgnx-evil-test--line)))
      (evil-visual-block)
      (should (eq drgnx-modal-state 'visual-block))
      (evil-normal-state)
      (should (eq drgnx-modal-state 'normal))
      (evil-visual-line)
      (should (eq drgnx-modal-state 'visual-line))
      (evil-normal-state))))

(ert-deftest drgnx-evil/cursor-shapes-per-state ()
  (drgnx-evil-test--running
    (drgnx-evil-test--buffer b #'text-mode
      (should (eq cursor-type 'box))
      (evil-insert-state)
      (should (eq drgnx-modal-state 'insert))
      (should (eq cursor-type 'bar))
      (evil-visual-char)
      (should (eq cursor-type 'hollow))
      (evil-normal-state)
      (evil-replace-state)
      (should (eq drgnx-modal-state 'replace))
      (should (eq cursor-type 'hbar))
      (evil-emacs-state)
      (should (eq drgnx-modal-state 'emacs))
      (should (eq cursor-type 'bar))
      (evil-normal-state)
      (should (eq cursor-type 'box)))))

(ert-deftest drgnx-evil/c-g-is-the-same-in-every-state ()
  (drgnx-evil-test--running
    (drgnx-evil-test--buffer b #'text-mode
      (let ((plain (with-temp-buffer (key-binding (kbd "C-g")))))
        (should (eq plain 'keyboard-quit))
        (dolist (enter '(evil-normal-state evil-insert-state evil-replace-state evil-emacs-state evil-visual-char
                                           evil-visual-line evil-visual-block evil-motion-state))
          (funcall enter)
          (should (eq (key-binding (kbd "C-g")) plain))))
      (evil-normal-state)
      (should (eq (key-binding (kbd "C-g")) 'keyboard-quit)))
    (drgnx-evil-test--buffer b #'drgnx-outline-mode
      (should (eq drgnx-modal-state 'emacs))
      (should (eq (key-binding (kbd "C-g")) 'keyboard-quit)))))

(ert-deftest drgnx-evil/stopping-puts-everything-back ()
  (drgnx-modal-test-with-evil
    (drgnx-evil-test--config '((vim app editing window)) t
      (require 'evil)
      (let ((code (generate-new-buffer "evil-stop-code"))
            (panel (generate-new-buffer "evil-stop-panel"))
            (cursor-before evil-normal-state-cursor))
        (unwind-protect
            (progn
              (with-current-buffer code (text-mode))
              (with-current-buffer panel (drgnx-outline-mode))
              (should (eq (drgnx-evil-test--run) 'ok))
              (save-window-excursion
                (switch-to-buffer code)
                (evil-refresh-cursor)
                (should (eq cursor-type 'box))
                (drgnx-evil-stop)
                (should (eq cursor-type t))
                (should-not drgnx-modal-state)
                (switch-to-buffer panel)
                (should-not cursor-type)
                (should-not drgnx-modal-state))
              (should (eq evil-normal-state-cursor cursor-before))
              (should-not (memq 'drgnx-evil--sync evil-normal-state-entry-hook))
              (should-not (memq 'drgnx-evil--init-buffer after-change-major-mode-hook))
              (dolist (fn drgnx-evil--selection-functions)
                (should-not (advice-member-p #'drgnx-evil--after-selection fn)))
              (should-not (bound-and-true-p evil-mode))
              (should-not (member '(:eval (drgnx-modal-mode-line)) (default-value 'mode-line-format))))
          (mapc #'kill-buffer (list code panel)))))))

(ert-deftest drgnx-evil/which-key-is-on-while-it-runs ()
  (drgnx-modal-test-with-evil
    (drgnx-evil-test--config '((vim app editing window)) t
      (require 'which-key)
      (let ((was-on (bound-and-true-p which-key-mode))
            (was-transient which-key-show-transient-maps))
        (when was-on (which-key-mode -1))
        (setq which-key-show-transient-maps nil)
        (unwind-protect
            (progn
              (should (eq (drgnx-evil-test--run) 'ok))
              (should which-key-mode)
              (should which-key-show-transient-maps)
              (drgnx-evil-stop)
              (should-not which-key-mode)
              (should-not which-key-show-transient-maps))
          (setq which-key-show-transient-maps was-transient)
          (which-key-mode (if was-on 1 -1)))))))

(ert-deftest drgnx-evil/the-terminal-follows-the-cursor-where-emacs-can ()
  (drgnx-evil-test--running
    ;; as on Emacs 31.1 with term/xterm loaded, where the option exists (30.2 has none: nothing to set)
    (cl-progv '(xterm-update-cursor) '(nil)
      (unwind-protect
          (progn
            (drgnx-evil-stop)
            (setq features (delq 'term/xterm features))
            (drgnx-evil-start)
            (should-not xterm-update-cursor)      ; the library loads later: set when it does
            (provide 'term/xterm)
            (should (eq xterm-update-cursor t))
            (drgnx-evil-stop)
            (should-not xterm-update-cursor)
            (drgnx-evil-start)                    ; the library is loaded already: set at once
            (should (eq xterm-update-cursor t))
            (drgnx-evil-stop)
            (should-not xterm-update-cursor))
        (setq features (delq 'term/xterm features))))))

;;;; Settings, toggle, doctor, rows

(ert-deftest drgnx-evil/settings-are-the-documented-ones ()
  (drgnx-modal-test-with-evil
    (drgnx-evil-test--config '((vim app editing window)) t
      (require 'evil)
      (setq evil-want-keybinding t evil-undo-system 'undo-tree evil-want-C-u-scroll nil
            evil-search-module 'isearch evil-want-minibuffer t evil-mode-line-format 'before)
      (should (eq (drgnx-evil-test--run) 'ok))
      (should-not evil-want-keybinding)
      (should (eq evil-undo-system 'undo-redo))
      (should (eq evil-want-C-u-scroll t))
      (should (eq evil-search-module 'evil-search))
      (should-not evil-want-minibuffer)
      (should-not evil-mode-line-format))))

(ert-deftest drgnx-evil/toggle-turns-the-engine-off-and-on ()
  (drgnx-evil-test--running
    (drgnx-evil-test--buffer b #'prog-mode
      (should (equal (drgnx-evil-doctor) nil))
      (drgnx-evil-toggle)
      (should-not drgnx-modal-running)
      (should-not (bound-and-true-p evil-mode))
      (should-not drgnx-modal-state)
      (should (= 1 (length (drgnx-evil-doctor))))    ; the stack still wants evil
      (drgnx-evil-toggle)
      (should (eq drgnx-modal-running 'evil))
      (should (eq drgnx-modal-state 'normal))
      (should-not (drgnx-evil-doctor)))))

(ert-deftest drgnx-evil/modal-toggle-is-a-command-while-the-engine-is-loaded ()
  (drgnx-evil-test--running
    (let ((cmd (drgnx-commands-get 'modal-toggle)))
      (should cmd)
      (should (equal (drgnx-cmd-title cmd) "Toggle Modal Editing"))
      (should (funcall (drgnx-cmd-when cmd))))
    (setq drgnx-modal-engines nil)
    (should-not (funcall (drgnx-cmd-when (drgnx-commands-get 'modal-toggle))))))

(ert-deftest drgnx-evil/modal-toggle-has-an-entry-in-every-profile ()
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (should (= 3 (length profiles)))
    (dolist (p profiles)
      (should (assq 'modal-toggle (plist-get (cdr p) :bind))))
    (should (equal (cadr (assq 'modal-toggle (plist-get (alist-get 'vim profiles) :bind))) "SPC u m"))
    (dolist (name '(vscode emacs))
      (should (eq (cadr (assq 'modal-toggle (plist-get (alist-get name profiles) :bind))) :none)))))

(provide 'mod-evil-test)
;;; mod-evil-test.el ends here
