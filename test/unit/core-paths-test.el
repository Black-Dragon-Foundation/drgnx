;;; core-paths-test.el --- batch tests: drgnx paths -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)

(ert-deftest drgnx-paths/user-and-state-dirs ()
  (let ((process-environment (append '("DRGNX_CONFIG_DIR=/tmp/drgnx-cfg" "XDG_STATE_HOME=/tmp/xs" "XDG_CACHE_HOME=/tmp/xc")
                                     process-environment)))
    (should (equal (drgnx-user-dir) "/tmp/drgnx-cfg/"))
    (should (equal (drgnx-state-dir) "/tmp/xs/drgnx/"))
    (should (equal (drgnx-cache-dir) "/tmp/xc/drgnx/"))))

(ert-deftest drgnx-paths/empty-or-relative-xdg-dirs-count-as-unset ()
  ;; The XDG spec: a relative path in these variables is invalid and ignored, as is an empty one — else both
  ;; resolve against the current directory (a daemon's cwd).
  (let ((default-directory (file-name-as-directory (make-temp-file "drgnx-cwd" t))))
    (unwind-protect
        (dolist (value '("" "rel" "~/x"))
          (let ((process-environment (append (list "HOME=/tmp/drgnx-home" "DRGNX_DATA_DIR" (concat "XDG_STATE_HOME=" value)
                                                   (concat "XDG_CACHE_HOME=" value) (concat "XDG_DATA_HOME=" value))
                                             process-environment)))
            (should (equal (drgnx-state-dir) "/tmp/drgnx-home/.local/state/drgnx/"))
            (should (equal (drgnx-cache-dir) "/tmp/drgnx-home/.cache/drgnx/"))
            (should (equal (drgnx-data-dir) "/tmp/drgnx-home/.local/share/drgnx/"))))
      (delete-directory default-directory t))))

(ert-deftest drgnx-paths/no-helper-ever-asks-tramp ()
  "REMOTE-PATHS-1: with a remote `default-directory' and no XDG variable set, expanding \"~\" must stay local."
  (let* ((asked nil)
         (home "/tmp/drgnx-remote-paths-home")
         (process-environment (append (list (concat "HOME=" home))
                                      (seq-remove (lambda (v) (string-match-p "\\`\\(HOME\\|XDG_[A-Z_]+\\|DRGNX_\\(CONFIG\\|DATA\\)_DIR\\)\\(=\\|\\'\\)" v))
                                                  process-environment)))
         (file-name-handler-alist
          (cons (cons "\\`/ssh:" (lambda (op &rest _) (push op asked) (error "Tramp was asked")))
                file-name-handler-alist))
         (default-directory "/ssh:nohost.invalid:/tmp/"))
    (dolist (fn '(drgnx-user-dir drgnx-state-dir drgnx-cache-dir drgnx-data-dir drgnx-elpa-dir
                                 drgnx-generations-dir drgnx-package-cache-dir))
      (let ((dir (funcall fn)))
        (should (stringp dir))
        (should (file-name-absolute-p dir))
        (should-not (file-remote-p dir))
        (should (string-prefix-p home dir))
        (should (string-suffix-p "/" dir))))
    (should-not asked)))

(defun drgnx-paths-test--sigpipe-ignored-p (command)
  "Does COMMAND (a list) run with SIGPIPE ignored?  Its /proc/self/status says (bit 12 of SigIgn)."
  (with-temp-buffer
    (apply #'call-process (car command) nil t nil (append (cdr command) '("-c" "grep SigIgn /proc/self/status")))
    (string-match "SigIgn:[ \t]*\\([0-9a-f]+\\)" (buffer-string))
    (/= 0 (logand #x1000 (string-to-number (match-string 1 (buffer-string)) 16)))))

(ert-deftest drgnx-paths/a-command-can-run-with-sigpipe-ignored ()
  (skip-unless (file-readable-p "/proc/self/status"))
  (should-not (drgnx-paths-test--sigpipe-ignored-p '("sh")))
  (let ((wrapped (drgnx-command-ignoring-sigpipe '("sh"))))
    (should (equal (car wrapped) "sh"))
    (should (drgnx-paths-test--sigpipe-ignored-p wrapped)))
  ;; no sh on Windows: the command as it was
  (let ((system-type 'windows-nt))
    (should (equal (drgnx-command-ignoring-sigpipe '("agent" "--x")) '("agent" "--x")))))

(ert-deftest drgnx-paths/checkout ()
  (should (file-exists-p (expand-file-name "core/drgnx-paths.el" drgnx-dir))))

(defun drgnx-paths-test--start (tmp &rest env)
  "Start a batch Emacs on TMP/init — an init directory whose early-init.el is drgnx's, whose init.el writes
a file where Emacs keeps its own state — with temp XDG dirs and ENV; what it says: (UED ELN AUTO-SAVE)."
  (let ((init (expand-file-name "init/" tmp)))
    (make-directory init t)
    (make-directory (expand-file-name "home" tmp) t)
    (write-region (format "(load %S nil t)\n" (expand-file-name "init/early-init.el" drgnx-dir)) nil (concat init "early-init.el") nil 'silent)
    (write-region "(write-region \"x\" nil (locate-user-emacs-file \"probe\") nil 'silent)
(princ (format \"%S\" (list user-emacs-directory (and (featurep 'native-compile) (car native-comp-eln-load-path)) auto-save-list-file-prefix)))\n"
                  nil (concat init "init.el") nil 'silent)
    (with-temp-buffer
      (let ((process-environment (append env (mapcar (lambda (v) (format "%s=%s%s" (car v) tmp (cdr v)))
                                                     '(("HOME" . "home") ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache")
                                                       ("DRGNX_CONFIG_DIR" . "config")))   ; early-init makes custom.el there
                                         process-environment)))
        ;; batch loads no init file; --user "" makes it load this init directory's
        (call-process (expand-file-name invocation-name invocation-directory) nil '(t nil) nil
                      "--batch" "--user" "" (concat "--init-directory=" init)))
      (car (read-from-string (buffer-string))))))

(ert-deftest drgnx-paths/emacs-keeps-its-state-and-native-code-out-of-the-checkout ()
  (let ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t))))
    (unwind-protect
        (pcase-let ((`(,ued ,eln ,saves) (drgnx-paths-test--start tmp "DRGNX_UI_RUN")))
          (should (equal ued (concat tmp "state/drgnx/emacs/")))
          (should (string-prefix-p (concat tmp "state/drgnx/emacs/") saves))
          (when eln (should (equal eln (concat tmp "cache/drgnx/eln-cache/"))))
          (should (file-exists-p (concat tmp "state/drgnx/emacs/probe")))
          (should (equal (directory-files (concat tmp "init") nil "\\`[^.]") '("early-init.el" "init.el"))))
      (delete-directory tmp t))))

(defconst drgnx-paths-test--drgnx-init
  "(add-to-list 'load-path %S) (add-to-list 'load-path %S) (require 'drgnx) (require 'cl-lib)
(cl-letf (((symbol-function 'drgnx-modules-start) #'ignore) ((symbol-function 'drgnx-keys-apply) #'ignore)
          ((symbol-function 'drgnx-surfaces-refresh) #'ignore) ((symbol-function 'drgnx-session-setup) #'ignore))
  (drgnx-init))\n"
  "init.el text that runs `drgnx-init' (packages activated, custom.el and config.el loaded; modules, keys, surfaces
and the session left out); format it with the core and wb directories.")

(defun drgnx-paths-test--start-custom (tmp init)
  "Start a batch Emacs on TMP/init as `drgnx-paths-test--start' does, with TMP/config and TMP/data as the drgnx config
and data dirs, whose init.el is INIT (text); what it prints, read."
  (let ((dir (expand-file-name "init/" tmp)))
    (make-directory dir t)
    (make-directory (expand-file-name "home" tmp) t)
    (write-region (format "(load %S nil t)\n" (expand-file-name "init/early-init.el" drgnx-dir)) nil (concat dir "early-init.el") nil 'silent)
    (write-region init nil (concat dir "init.el") nil 'silent)
    (with-temp-buffer
      (let ((process-environment (append (list "DRGNX_UI_RUN" "DRGNX_SAFE")
                                         (mapcar (lambda (v) (format "%s=%s%s" (car v) tmp (cdr v)))
                                                 '(("HOME" . "home") ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache")
                                                   ("DRGNX_CONFIG_DIR" . "config") ("DRGNX_DATA_DIR" . "data")))
                                         process-environment)))
        (call-process (expand-file-name invocation-name invocation-directory) nil '(t nil) nil
                      "--batch" "--user" "" (concat "--init-directory=" dir)))
      (car (read-from-string (buffer-string))))))

(defun drgnx-paths-test--after-init (form)
  "init.el text: `drgnx-init', then print FORM's value (text)."
  (concat (format drgnx-paths-test--drgnx-init (expand-file-name "core" drgnx-dir) (expand-file-name "wb" drgnx-dir))
          (format "(princ (format \"%%S\" %s))\n" form)))

(ert-deftest drgnx-paths/customize-saves-into-the-config-dir-never-the-checkout ()
  ;; Customize and `package-install' write `custom-set-variables' into `custom-file', else into the init file —
  ;; the checkout's tracked init/init.el (whose dirt then stops install.sh's updates).  custom.el in the config dir:
  ;; made when missing, loaded at start.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t)))
         (custom (concat tmp "config/custom.el"))
         (init (concat tmp "init/init.el")))
    (unwind-protect
        (progn
          (should (equal (drgnx-paths-test--start-custom
                          tmp "(princ (format \"%S\" custom-file))\n(customize-save-variable 'fill-column 72)\n")
                         custom))
          (should (string-search "(fill-column 72)" (with-temp-buffer (insert-file-contents custom) (buffer-string))))
          (should-not (string-search "custom-set-variables" (with-temp-buffer (insert-file-contents init) (buffer-string))))
          ;; the next start loads it
          (should (equal (drgnx-paths-test--start-custom tmp (drgnx-paths-test--after-init "fill-column")) 72)))
      (delete-directory tmp t))))

(ert-deftest drgnx-paths/a-package-mode-saved-with-customize-turns-on ()
  ;; custom.el loads in `drgnx-init' once the packages are active: a package's minor mode saved on through Customize
  ;; runs (loaded before them, its `require' fails quietly and the mode only looks on); an error in it is said, never
  ;; fatal, and `drgnx safe' skips it.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t)))
         (pkg (concat tmp "data/elpa/drgnx-test-foo-1.0/")))
    (unwind-protect
        (progn
          (make-directory pkg t)
          (make-directory (concat tmp "config") t)
          (write-region "(define-package \"drgnx-test-foo\" \"1.0\" \"A test package\" nil)\n" nil (concat pkg "drgnx-test-foo-pkg.el") nil 'silent)
          (write-region ";;;###autoload\n(define-minor-mode drgnx-test-foo-mode \"Test.\" :global t (setq drgnx-test-foo-ran drgnx-test-foo-mode))\n(defvar drgnx-test-foo-ran nil)\n(provide 'drgnx-test-foo)\n"
                        nil (concat pkg "drgnx-test-foo.el") nil 'silent)
          (write-region "(add-to-list 'load-path (directory-file-name (file-name-directory load-file-name)))\n(autoload 'drgnx-test-foo-mode \"drgnx-test-foo\" nil t)\n"
                        nil (concat pkg "drgnx-test-foo-autoloads.el") nil 'silent)
          (write-region "(custom-set-variables '(drgnx-test-foo-mode t nil (drgnx-test-foo)))\n" nil (concat tmp "config/custom.el") nil 'silent)
          (should (equal (drgnx-paths-test--start-custom
                          tmp (drgnx-paths-test--after-init "(list (bound-and-true-p drgnx-test-foo-mode) (bound-and-true-p drgnx-test-foo-ran))"))
                         '(t t)))
          ;; an error in it: said, and the start goes on
          (write-region "(error \"Broken custom\")\n" nil (concat tmp "config/custom.el") nil 'silent)
          (should (equal (drgnx-paths-test--start-custom tmp (drgnx-paths-test--after-init "(featurep 'drgnx)")) t))
          ;; drgnx safe: not loaded
          (write-region "(setq drgnx-test-custom-loaded t)\n" nil (concat tmp "config/custom.el") nil 'silent)
          (should (equal (drgnx-paths-test--start-custom tmp (drgnx-paths-test--after-init "(boundp 'drgnx-test-custom-loaded)")) t))
          (should (equal (drgnx-paths-test--start-custom     ; (the helper unsets DRGNX_SAFE: set in init.el)
                          tmp (concat "(setenv \"DRGNX_SAFE\" \"1\")\n" (drgnx-paths-test--after-init "(boundp 'drgnx-test-custom-loaded)")))
                         nil)))
      (delete-directory tmp t))))

(ert-deftest drgnx-paths/custom-el-loads-under-the-package-guard ()
  ;; custom.el runs once the packages are active and their guard is on, before config.el
  (require 'drgnx)
  (let ((calls nil) (custom-file "/nonexistent/custom.el") (drgnx-first-gui-frame-hook nil)
        (drgnx-modules-after-stage-functions nil) (process-environment (cons "DRGNX_SAFE" process-environment)))
    (cl-letf (((symbol-function 'drgnx-guard-mode) #'ignore) ((symbol-function 'drgnx-hooks-install) #'ignore)
              ((symbol-function 'drgnx-session-setup) #'ignore) ((symbol-function 'drgnx--core-commands) #'ignore)
              ((symbol-function 'drgnx-modules-start) #'ignore) ((symbol-function 'drgnx-keys-apply) #'ignore)
              ((symbol-function 'drgnx-surfaces-refresh) #'ignore) ((symbol-function 'drgnx-gc-setup) #'ignore)
              ((symbol-function 'drgnx-pkg-activate) (lambda () (push 'activate calls)))
              ((symbol-function 'drgnx-pkg-guard-mode) (lambda (&rest _) (push 'guard calls)))
              ((symbol-function 'drgnx--load-user-config) (lambda (&optional file) (push (if file 'custom 'config) calls))))
      (drgnx-init))
    (should (equal (nreverse calls) '(activate guard custom config)))))

(ert-deftest drgnx-paths/a-harness-session-keeps-its-state-in-its-run-directory ()
  (let ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t))))
    (unwind-protect
        (should (equal (car (drgnx-paths-test--start tmp (concat "DRGNX_UI_RUN=" tmp "run")))
                       (concat tmp "init/")))
      (delete-directory tmp t))))
