;;; vscode-keys-gui-test.el --- GUI test: the VS Code profile's Ctrl+A, Ctrl+C/X, Ctrl+O, Ctrl+Q, Ctrl+Shift+U (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; The audit's K3 and K4.  Real keys go through the command loop in a session whose keys are the VS Code profile's
;; (`drgnx-keys-use').  Copy and Cut with a selection act at once (they waited 300 ms for a prefix key), Ctrl+A selects
;; the buffer, Ctrl+O asks from the workspace folder, Ctrl+Shift+U shows and selects the panel's Output tab, and
;; Ctrl+Q asks the one Save / Don't Save / Cancel question.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)
(defconst drgnx-ui-vscode-keys--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-ui-vscode-keys--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-ui-vscode-keys--repo))
(require 'drgnx)
(require 'drgnx-session)
(require 'drgnx-explorer)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-ui-vscode-keys--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-ui-vscode-keys--repo) nil t)
(mapc #'require (drgnx-test-modules--requires (expand-file-name "modules/core/drgnx-basics.el" drgnx-ui-vscode-keys--repo)))
(mapc #'require (drgnx-test-modules--requires (expand-file-name "modules/core/drgnx-workbench.el" drgnx-ui-vscode-keys--repo)))
(mapc #'require (drgnx-test-modules--requires (expand-file-name "modules/editor/drgnx-editing.el" drgnx-ui-vscode-keys--repo)))
(mapc #'require (drgnx-test-modules--requires (expand-file-name "modules/tools/drgnx-terminal.el" drgnx-ui-vscode-keys--repo)))
(load (expand-file-name "modules/tools/drgnx-term" drgnx-ui-vscode-keys--repo) nil t)   ; Start in the workspace folder

(defconst drgnx-ui-vscode-keys--instant 0.2
  "Seconds a Copy or Cut may take from the key to the copy.  The Editing Prefix Delay made it 0.3 plus the key; at
once is a key event's dispatch, a few milliseconds.")

(defun drgnx-ui-vscode-keys--type (keys)
  "Type KEYS (kbd syntax) through the command loop; fail rather than wait when a question is left open."
  (let ((answered (with-timeout (20 'timed-out) (drgnx-uitest-run (drgnx-uitest-key-events keys)) 'done)))
    (when (eq answered 'timed-out)
      (when (active-minibuffer-window) (abort-recursive-edit))
      (ert-fail (list "the keys did not end" keys)))))

(defun drgnx-ui-vscode-keys--seconds-to (fn keys)
  "Seconds from typing KEYS until the function FN (advised for it) is called, or nil when it was not."
  (let* ((t0 nil) (at nil)
         (probe (lambda (&rest _) (unless at (setq at (float-time))))))
    (advice-add fn :before probe)
    (unwind-protect (progn (setq t0 (float-time)) (drgnx-ui-vscode-keys--type keys))
      (advice-remove fn probe))
    (and at (- at t0))))

(ert-deftest drgnx-ui-vscode-keys/copy-and-cut-are-instant-and-select-all-is-ctrl-a ()
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (drgnx-test-with-modules '(core/basics editor/editing)
    (drgnx-keys-use '((vscode app editing window)))
    (unwind-protect
        (let ((b (get-buffer-create "*vscode-keys*")) (kill-ring nil))
          (switch-to-buffer b)
          (erase-buffer) (insert "alpha beta gamma\n") (goto-char (point-min))
          (should (null (default-value 'drgnx-editing-prefix-delay)))
          (should (eq (key-binding (kbd "C-a")) 'mark-whole-buffer))
          ;; Ctrl+A: the whole buffer, point at its end
          (drgnx-ui-vscode-keys--type "C-a")
          (should (use-region-p))
          (should (equal (buffer-substring-no-properties (region-beginning) (region-end)) "alpha beta gamma\n"))
          ;; Ctrl+C with that selection: copied at once, the selection kept
          (let ((s (drgnx-ui-vscode-keys--seconds-to 'kill-ring-save "C-c")))
            (should s)
            (should (< s drgnx-ui-vscode-keys--instant)))
          (should (equal (car kill-ring) "alpha beta gamma\n"))
          ;; Ctrl+X with a selection: cut at once
          (goto-char (point-min)) (set-mark (point)) (forward-char 5) (activate-mark)
          (let ((s (drgnx-ui-vscode-keys--seconds-to 'kill-region "C-x")))
            (should s)
            (should (< s drgnx-ui-vscode-keys--instant)))
          (should (equal (car kill-ring) "alpha"))
          (should (equal (buffer-string) " beta gamma\n"))
          ;; no selection: C-x is still Emacs' prefix (C-x C-s would save; a prefix wait is no cut)
          (deactivate-mark)
          (should (keymapp (key-binding (kbd "C-x")))))
      (drgnx-keys--restore)
      (when (get-buffer "*vscode-keys*") (kill-buffer "*vscode-keys*")))))

(ert-deftest drgnx-ui-vscode-keys/ctrl-o-asks-from-the-workspace-folder ()
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (drgnx-test-with-modules '(core/basics)
    (drgnx-keys-use '((vscode app editing window)))
    (unwind-protect
        (let* ((root (file-name-as-directory (make-temp-file "vscode-keys-root" t)))
               (sub (file-name-as-directory (expand-file-name "sub/deep" root)))
               (target (expand-file-name "opened.txt" root))
               (drgnx-explorer--roots (list root))
               asked-in opened)
          (make-directory sub t)
          (write-region "x\n" nil target nil 'silent)
          (should (eq (key-binding (kbd "C-o")) 'drgnx-basics-open-file))
          (switch-to-buffer (get-buffer-create "*vscode-keys-open*"))
          (setq default-directory sub)                     ; this buffer's folder, which a raw find-file would offer
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (_prompt &optional dir &rest _) (setq asked-in dir) target)))
            (drgnx-ui-vscode-keys--type "C-o"))
          (setq opened (find-buffer-visiting target))
          (should opened)
          (should (equal (file-name-as-directory asked-in) root))      ; not sub/deep/, the buffer's folder
          (kill-buffer opened)
          (kill-buffer "*vscode-keys-open*")
          (delete-directory root t))
      (drgnx-keys--restore))))

(ert-deftest drgnx-ui-vscode-keys/ctrl-shift-u-shows-the-output-tab-and-ctrl-q-asks-once ()
  (drgnx-uitest-bare-frame)
  (drgnx-test-with-modules '(core/basics core/workbench)
    (drgnx-session-register-commands)
    (drgnx-keys-use '((vscode app editing window)))
    (unwind-protect
        (let* ((drgnx-keep-running nil) killed
               (frame (make-frame '((name . "vscode-keys"))))   ; the panel's grid marks its frame: a frame of its own, deleted after
               (b (generate-new-buffer "vscode-keys-quit.txt")))
          (select-frame frame)
          (delete-other-windows)
          (should (eq (key-binding (kbd "C-S-u")) 'drgnx-wb-view-output))
          (drgnx-ui-vscode-keys--type "C-S-u")
          (should (drgnx-wb-area-window 'panel))
          (should (eq (drgnx-wb-area-tab 'panel) 'output))
          (should (eq (selected-window) (drgnx-wb-area-window 'panel)))
          (should (eq (key-binding (kbd "C-q")) 'drgnx-session-quit))
          (should (eq (key-binding (kbd "C-S-w")) 'drgnx-session-close-frame))
          ;; a changed file: Ctrl+Q asks once; Cancel keeps drgnx, Don't Save quits
          (with-current-buffer b (setq buffer-file-name (expand-file-name "vscode-keys-quit.txt" temporary-file-directory))
                               (insert "unsaved"))
          (cl-letf (((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t)))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Emacs' own question was asked")))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "Emacs' own question was asked"))))
            (drgnx-ui-vscode-keys--type "C-q c")
            (should-not killed)
            (should (buffer-modified-p b))
            (drgnx-ui-vscode-keys--type "C-q d")
            (should killed))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)
          (delete-frame frame))
      (drgnx-keys--restore))))

(ert-deftest drgnx-ui-vscode-keys/ctrl-backtick-opens-the-terminal-in-the-workspace-root ()
  "The audit's T1: Ctrl+` from a file in a sub-folder starts the terminal in the Explorer's folder (the workspace
root), as VS Code does, not in the file's folder.  No hub in this row: the terminal is the eshell fallback
\(`drgnx-terminal-new'), which starts where the terminal would."
  (drgnx-uitest-bare-frame)
  (drgnx-test-with-modules '(core/basics core/workbench tools/terminal)
    (drgnx-keys-use '((vscode app editing window)))
    (unwind-protect
        (let* ((root (file-name-as-directory (make-temp-file "vscode-keys-term" t)))
               (sub (file-name-as-directory (expand-file-name "core/deep" root)))
               (file (expand-file-name "a.el" sub))
               (drgnx-explorer--roots (list root))
               (frame (make-frame '((name . "vscode-keys-term"))))
               (eshells nil))
          (select-frame frame)
          (delete-other-windows)
          (make-directory sub t)
          (write-region "x\n" nil file nil 'silent)
          (should (eq (key-binding (kbd "C-`")) 'drgnx-terminal-toggle))
          (switch-to-buffer (find-file-noselect file))
          (should (equal default-directory sub))
          (drgnx-ui-vscode-keys--type "C-`")
          (dolist (b (buffer-list))
            (with-current-buffer b (when (derived-mode-p 'eshell-mode) (push b eshells))))
          (should (= 1 (length eshells)))
          (should (equal (file-name-as-directory (buffer-local-value 'default-directory (car eshells))) root))
          (dolist (b eshells) (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
          (when (boundp 'eshell-hist-unload-hook) (set 'eshell-hist-unload-hook nil))   ; the hook eshell's first load adds
          (kill-buffer (find-buffer-visiting file))
          (delete-frame frame)
          (delete-directory root t))
      (drgnx-keys--restore))))

(provide 'vscode-keys-gui-test)
;;; vscode-keys-gui-test.el ends here
