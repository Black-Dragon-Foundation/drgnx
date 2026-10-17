;;; mod-amenities-test.el --- batch tests: M11a's package modules — they wait without their package, run with it -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)

(defconst drgnx-amenities-test--modules
  '(("extra/drgnx-booster" extra/booster (eglot-booster) ())
    ("extra/drgnx-format" extra/format (apheleia) (format-on-save))
    ("extra/drgnx-debug" extra/debug (dape) (debug-start debug-breakpoint debug-step-over debug-step-in debug-step-out debug-stop)))
  "FILE MODULE PACKAGES COMMANDS.")

(defconst drgnx-amenities-test--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))
  "The user's ELPA, used read-only when present.")

(defun drgnx-amenities-test--installed-p (pkg)
  (and (file-directory-p drgnx-amenities-test--elpa)
       (directory-files drgnx-amenities-test--elpa nil (format "\\`%s\\(-[0-9]\\|\\'\\)" (regexp-quote (symbol-name pkg))))))

(defun drgnx-amenities-test--elpa-path ()
  (seq-filter #'file-directory-p (directory-files drgnx-amenities-test--elpa t "\\`[^.]")))

(defmacro drgnx-amenities-test--fresh (&rest body)
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
     (unwind-protect
         (progn (pcase-dolist (`(,file . ,_) drgnx-amenities-test--modules)
                  (load (expand-file-name (concat "modules/" file) drgnx-dir) nil t))
                ,@body)
       (delete-directory cfg t))))

(ert-deftest drgnx-amenities/without-packages-they-wait ()
  (let ((load-path (seq-remove (lambda (d) (string-prefix-p drgnx-amenities-test--elpa d)) load-path)))
    (drgnx-amenities-test--fresh
     (let ((pkgs (seq-mapcat (lambda (m) (nth 2 m)) drgnx-amenities-test--modules)) (orig (symbol-function 'featurep)))
       (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil))
                 ((symbol-function 'featurep) (lambda (f &rest r) (and (not (memq f pkgs)) (apply orig f r)))))
         (drgnx-modules-run 'idle)))
     (pcase-dolist (`(,_ ,mod ,_ ,cmds) drgnx-amenities-test--modules)
       (should (eq (plist-get (alist-get mod (drgnx-modules-report)) :status) 'missing-packages))
       (dolist (c cmds) (should-not (drgnx-commands-get c)))))))

(ert-deftest drgnx-amenities/with-their-package-they-run ()
  ;; each module whose package the user's ELPA has
  (skip-unless (file-directory-p drgnx-amenities-test--elpa))
  (let ((load-path (append load-path (drgnx-amenities-test--elpa-path))) (ran 0))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))   ; no booster binary, no formatters
      (drgnx-amenities-test--fresh
       (unwind-protect
           (progn
             (drgnx-modules-run 'idle)
             (pcase-dolist (`(,_ ,mod ,pkgs ,cmds) drgnx-amenities-test--modules)
               (when (seq-every-p #'drgnx-amenities-test--installed-p pkgs)
                 (setq ran (1+ ran))
                 (should (equal (list mod (plist-get (alist-get mod (drgnx-modules-report)) :status)) (list mod 'ok)))
                 (dolist (c cmds) (should (drgnx-commands-get c))))))
         (dolist (m '(apheleia-global-mode eglot-booster-mode))
           (when (and (fboundp m) (boundp m) (symbol-value m)) (funcall m -1))))))
    (should (> ran 0))))

(ert-deftest drgnx-booster/only-with-the-binary ()
  (skip-unless (drgnx-amenities-test--installed-p 'eglot-booster))
  (let ((load-path (append load-path (drgnx-amenities-test--elpa-path))))
    (load (expand-file-name "modules/extra/drgnx-booster" drgnx-dir) nil t)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
            (drgnx-booster--setup))
          (should-not (and (boundp 'eglot-booster-mode) eglot-booster-mode))       ; no binary: eglot as it was
          (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "emacs-lsp-booster") "/usr/bin/emacs-lsp-booster"))))
            (drgnx-booster--setup))
          (should eglot-booster-mode))
      (when (and (boundp 'eglot-booster-mode) eglot-booster-mode) (eglot-booster-mode -1)))))

(ert-deftest drgnx-format/a-missing-formatter-still-saves ()
  (skip-unless (drgnx-amenities-test--installed-p 'apheleia))
  (let* ((load-path (append load-path (drgnx-amenities-test--elpa-path)))
         (file (make-temp-file "drgnx-format" nil ".py" "x  =  1\n")) (exec-path nil))
    (require 'apheleia)
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Prompted")))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Prompted"))))
          (apheleia-global-mode 1)
          (with-current-buffer (find-file-noselect file)
            (python-mode)
            (goto-char (point-max)) (insert "y  =  2\n")
            (save-buffer)
            (let ((deadline (+ (float-time) 2))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "x  =  1\ny  =  2\n"))
            (set-buffer-modified-p nil) (kill-buffer)))
      (apheleia-global-mode -1)
      (delete-file file))))

(ert-deftest drgnx-debug/start-or-continue ()
  (load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)
  (let ((called nil))
    (cl-letf (((symbol-function 'call-interactively) (lambda (f &rest _) (push f called)))
              ((symbol-function 'dape--live-connection) (lambda (&rest _) nil)))
      (drgnx-debug-start-or-continue))
    (cl-letf (((symbol-function 'call-interactively) (lambda (f &rest _) (push f called)))
              ((symbol-function 'dape--live-connection) (lambda (&rest _) 'a-stopped-session)))
      (drgnx-debug-start-or-continue))
    (should (equal called '(dape-continue dape)))))

(defvar dape-active-mode)                               ; dape's: special, as in the module

(ert-deftest drgnx-debug/session-keys-only-while-debugging ()
  ;; F11 is Zen Mode in the VS Code profile, Step Into while a session runs (as in VS Code)
  (load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)
  (unwind-protect
      (let ((dape-active-mode t))
        (drgnx-debug--follow-session)
        (should drgnx-debug-session-mode)
        (setq dape-active-mode nil)
        (drgnx-debug--follow-session)
        (should-not drgnx-debug-session-mode))
    (drgnx-debug-session-mode -1)))

(ert-deftest drgnx-debug/keys-in-every-profile ()
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (dolist (c '(debug-start debug-breakpoint debug-step-over debug-step-in debug-step-out debug-stop))
        (should (string-search (format "(%s " c) text)))))
  (let ((vs (with-temp-buffer (insert-file-contents (expand-file-name "keys/vscode.eld" drgnx-dir)) (buffer-string))))
    (should (string-search "(debug-start \"<f5>\")" vs))
    (should (string-search "(debug-step-in \"<f11>\" :map drgnx-debug-session-map)" vs))))

;;; mod-amenities-test.el ends here
