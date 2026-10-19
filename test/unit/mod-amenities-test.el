;;; mod-amenities-test.el --- batch tests: M11a's package modules — they wait without their package, run with it -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defconst drgnx-amenities-test--modules
  '(("extra/drgnx-booster" extra/booster (eglot-booster) ())
    ("extra/drgnx-format" extra/format (apheleia) (format-on-save))
    ("extra/drgnx-debug" extra/debug (dape) (debug-start debug-breakpoint debug-step-over debug-step-in debug-step-out debug-stop))
    ("extra/drgnx-guides" extra/guides (indent-bars) (toggle-indent-guides))
    ("lang/drgnx-markdown" lang/markdown (markdown-mode) (markdown-preview)))
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
         (drgnx-modules-run 'startup) (drgnx-modules-run 'idle)
         (drgnx-modules-run 'first-frame)))
     (pcase-dolist (`(,_ ,mod ,_ ,cmds) drgnx-amenities-test--modules)
       (should (eq (plist-get (alist-get mod (drgnx-modules-report)) :status) 'missing-packages))
       (dolist (c cmds) (should-not (drgnx-commands-get c)))))))

(ert-deftest drgnx-amenities/with-their-package-they-run ()
  ;; each module whose package the user's ELPA has
  (skip-unless (file-directory-p drgnx-amenities-test--elpa))
  (let ((load-path (append load-path (drgnx-amenities-test--elpa-path))) (ran 0))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))   ; no booster binary, no formatters
      (drgnx-test-with-modules (mapcar #'cadr drgnx-amenities-test--modules) :strict t
                               (pcase-dolist (`(,_ ,mod ,pkgs ,cmds) drgnx-amenities-test--modules)
                                 (when (seq-every-p #'drgnx-amenities-test--installed-p pkgs)
                                   (setq ran (1+ ran))
                                   (should (equal (list mod (plist-get (alist-get mod (drgnx-modules-report)) :status)) (list mod 'ok)))
                                   (dolist (c cmds) (should (drgnx-commands-get c)))))))
    (should (> ran 0))))

(ert-deftest drgnx-booster/only-with-the-binary ()
  (skip-unless (drgnx-amenities-test--installed-p 'eglot-booster))
  (let ((load-path (append load-path (drgnx-amenities-test--elpa-path))))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (drgnx-test-with-modules '(extra/booster) :strict t
                               (should-not (and (boundp 'eglot-booster-mode) eglot-booster-mode))))       ; no binary: eglot as it was
    (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "emacs-lsp-booster") "/usr/bin/emacs-lsp-booster"))))
      (drgnx-test-with-modules '(extra/booster) :strict t
                               (should eglot-booster-mode)))))

(ert-deftest drgnx-format/a-missing-formatter-still-saves ()
  (skip-unless (drgnx-amenities-test--installed-p 'apheleia))
  (let* ((load-path (append load-path (drgnx-amenities-test--elpa-path)))
         (file (make-temp-file "drgnx-format" nil ".py" "x  =  1\n")) (exec-path nil))
    (require 'python)                   ; python.el's own load-time registrations are not the module's
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Prompted")))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Prompted"))))
          (drgnx-test-with-modules '(extra/format) :strict t
                                   (with-current-buffer (find-file-noselect file)
                                     (python-mode)
                                     (goto-char (point-max)) (insert "y  =  2\n")
                                     (save-buffer)
                                     (let ((deadline (+ (float-time) 2))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
                                     (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "x  =  1\ny  =  2\n"))
                                     (set-buffer-modified-p nil) (kill-buffer))))
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

(ert-deftest drgnx-guides/colour-comes-from-shadow-not-highlight ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "modules/extra/drgnx-guides.el" drgnx-dir))
    (should (search-forward "(drgnx-module-set 'indent-bars-color '(shadow" nil t))))

(ert-deftest drgnx-guides/only-on-graphical-frames ()
  (load (expand-file-name "modules/extra/drgnx-guides" drgnx-dir) nil t)
  (let ((on nil))
    (with-temp-buffer
      (emacs-lisp-mode)
      (cl-letf (((symbol-function 'indent-bars-mode) (lambda (&rest _) (setq on t)))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (drgnx-guides--maybe))
      (should-not on)
      (cl-letf (((symbol-function 'indent-bars-mode) (lambda (&rest _) (setq on t)))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (drgnx-guides--maybe))
      (should on))))

(ert-deftest drgnx-smooth/terminal-frames-get-nothing-and-ultra-scroll-wins ()
  (load (expand-file-name "modules/ui/drgnx-smooth" drgnx-dir) nil t)
  (let ((used nil))
    (cl-letf (((symbol-function 'pixel-scroll-precision-mode) (lambda (&rest _) (push 'pixel used)))
              ((symbol-function 'ultra-scroll-mode) (lambda (&rest _) (push 'ultra used))))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (drgnx-smooth--setup))
      (should-not used)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'drgnx-smooth--ultra-p) (lambda () nil)))
        (drgnx-smooth--setup))
      (should (equal used '(pixel)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'drgnx-smooth--ultra-p) (lambda () t)))
        (drgnx-smooth--setup))
      (should (equal used '(ultra pixel))))))

(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(ert-deftest drgnx-smooth/turning-the-module-off-turns-scrolling-off ()
  (let (on-inside)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (drgnx-test-with-modules '(ui/smooth) :strict t
                               (setq on-inside (or pixel-scroll-precision-mode (bound-and-true-p ultra-scroll-mode)))))
    (should on-inside)
    (should-not pixel-scroll-precision-mode)
    (should-not (bound-and-true-p ultra-scroll-mode))))

(ert-deftest drgnx-smooth/a-daemon-s-first-frame-gets-it ()
  ;; the first-frame stage runs before the new graphical frame is selected (a daemon's terminal frame still is)
  (load (expand-file-name "modules/ui/drgnx-smooth" drgnx-dir) nil t)
  (let ((used nil))
    (cl-letf (((symbol-function 'pixel-scroll-precision-mode) (lambda (&rest _) (push 'pixel used)))
              ((symbol-function 'drgnx-smooth--ultra-p) (lambda () nil))
              ((symbol-function 'display-graphic-p) (lambda (&optional f) (and f t))))   ; only a frame other than the selected one
      (drgnx-smooth--setup))
    (should (equal used '(pixel)))))

(ert-deftest drgnx-format/only-where-the-project-formats ()
  ;; prettier, black, clang-format…: only in a project that uses them (a config file); never Lisp re-indentation
  (skip-unless (drgnx-amenities-test--installed-p 'apheleia))
  (let* ((load-path (append load-path (drgnx-amenities-test--elpa-path)))
         (dir (file-name-as-directory (make-temp-file "drgnx-fmt" t))) (py (concat dir "a.py")))
    (unwind-protect
        (drgnx-test-with-modules '(extra/format) :strict t
                                 (should-not (rassq 'lisp-indent apheleia-mode-alist))
                                 (should-not (rassq 'bibtex apheleia-mode-alist))
                                 (write-region "x = 1\n" nil py nil 'silent)
                                 (with-current-buffer (find-file-noselect py)
                                   (python-mode)
                                   (should (drgnx-format--inhibit-p))                              ; no formatter configured here
                                   (kill-buffer))
                                 (write-region "[tool.black]\nline-length = 100\n" nil (concat dir "pyproject.toml") nil 'silent)
                                 (with-current-buffer (find-file-noselect py)
                                   (python-mode)
                                   (should-not (drgnx-format--inhibit-p))
                                   (kill-buffer)))
      (delete-directory dir t))))

(ert-deftest drgnx-booster/never-for-remote-servers ()
  (skip-unless (drgnx-amenities-test--installed-p 'eglot-booster))
  (let ((load-path (append load-path (drgnx-amenities-test--elpa-path))))
    (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "emacs-lsp-booster") "/usr/bin/emacs-lsp-booster"))))
      (drgnx-test-with-modules '(extra/booster) :strict t
                               (should eglot-booster-no-remote-boost)))))                         ; a remote host seldom has the program

;;; mod-amenities-test.el ends here
