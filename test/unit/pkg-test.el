;;; pkg-test.el --- batch tests: drgnx-pkg — manifest, lock, sync, generations, upgrade -*- lexical-binding: t -*-
;; Everything runs offline against package archives that are local directories, in temp dirs:
;; never the network, the user's ELPA, ~/.local/share/drgnx or ~/.config/drgnx.
(require 'ert)
(require 'drgnx-file)
(require 'drgnx-paths)
(require 'drgnx-pkg)

(defun drgnx-pkg-test--package (dir name version &optional requires body)
  "Write the single-file package NAME-VERSION.el into archive DIR; return its archive-contents entry."
  (write-region (format ";;; %s.el --- fixture %s  -*- lexical-binding: t -*-\n;; Version: %s\n;; Package-Requires: %S\n;;; Code:\n%s\n(defun %s-hello () %S)\n(provide '%s)\n;;; %s.el ends here\n"
                        name name version (cons '(emacs "29.1") (mapcar (lambda (r) (list (car r) (cadr r))) requires))
                        (or body "") name version name name)
                nil (expand-file-name (format "%s-%s.el" name version) dir) nil 'silent)
  (cons name (vector (version-to-list version)
                     (cons '(emacs (29 1)) (mapcar (lambda (r) (list (car r) (version-to-list (cadr r)))) requires))
                     (format "fixture %s" name) 'single nil)))

(defun drgnx-pkg-test--archive (dir packages)
  "Make DIR a package archive holding PACKAGES: (NAME VERSION [REQUIRES [BODY]])…"
  (make-directory dir t)
  (dolist (f (directory-files dir t "\\.el\\'")) (delete-file f))
  (let ((entries (mapcar (lambda (p) (apply #'drgnx-pkg-test--package dir p)) packages)))
    (with-temp-file (expand-file-name "archive-contents" dir)
      (prin1 (cons 1 entries) (current-buffer))))
  (file-name-as-directory dir))

(defmacro drgnx-pkg-test--with (root &rest body)
  "BODY with ROOT a temp dir and every drgnx and package.el location inside it."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-pkg" t)))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "XDG_CACHE_HOME=" ,root "cache")
                                             (concat "XDG_STATE_HOME=" ,root "state"))
                                       process-environment))
          (drgnx-pkg-shipped-lock (concat ,root "shipped.lock.eld"))   ; never the checkout's etc/
          (drgnx-pkg-native-compile nil)
          (package-check-signature nil)
          (package-alist nil) (package-archive-contents nil) (package-activated-list nil)
          (package--initialized nil) (package-user-dir (expand-file-name "unused-elpa" ,root))
          (package-quickstart nil) (package-quickstart-file (expand-file-name "other-emacs/package-quickstart.el" ,root))
          (load-path load-path) (features features))
     (make-directory (concat ,root "config") t)
     (unwind-protect (progn ,@body)
       (delete-directory ,root t))))

(defun drgnx-pkg-test--write (file data)
  (make-directory (file-name-directory file) t)
  (with-temp-file file (prin1 data (current-buffer))))

(defun drgnx-pkg-test--want (root &rest names)
  "packages.eld in ROOT's config asking for NAMES; no modules (an empty modules dir)."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names)))

(defun drgnx-pkg-test--installed ()
  (sort (seq-filter (lambda (d) (not (string-prefix-p "." d)))
                    (seq-filter (lambda (d) (file-directory-p (expand-file-name d (drgnx-elpa-dir))))
                                (directory-files (drgnx-elpa-dir))))
        #'string<))

(defun drgnx-pkg-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-pkg-test--sync (root &rest args)
  "drgnx-pkg-sync with ROOT's (empty) modules dir and ARGS."
  (make-directory (concat root "mods") t)
  (apply #'drgnx-pkg-sync :modules-dir (concat root "mods") args))

;;;; Task 1: paths, manifest, lock

(ert-deftest drgnx-pkg/paths-follow-the-environment ()
  (drgnx-pkg-test--with root
    (should (equal (drgnx-data-dir) (concat root "data/")))
    (should (equal (drgnx-elpa-dir) (concat root "data/elpa/")))
    (should (equal (drgnx-generations-dir) (concat root "data/generations/")))
    (should (equal (drgnx-package-cache-dir) (concat root "cache/drgnx/packages/")))))

(ert-deftest drgnx-pkg/the-manifest-is-enabled-modules-packages-eld-and-ensures ()
  (drgnx-pkg-test--with root
    (let ((mods (concat root "mods/x/")))
      (make-directory mods t)
      ;; read, never run: the files would error if evaluated
      (write-region "(error \"never run\")\n(drgnx-module-define 'x/a :stage 'idle :packages '(pa pb) :setup #'ignore)\n(drgnx-module-define 'x/b :packages '(pz))\n(drgnx-module-define 'x/c :doc \"no packages\")\n"
                    nil (concat mods "drgnx-x.el") nil 'silent)
      (drgnx-pkg-test--write (concat root "config/modules.eld") '(:version 1 :disabled (x/b)))
      (drgnx-pkg-test--write (concat root "config/packages.eld") '(:packages (pc pa)))
      (drgnx-pkg-test--write (concat root "state/drgnx/packages-wanted.eld") '(pw))
      (should (equal (drgnx-pkg-manifest (concat root "mods")) '(pa pb pc pw))))))

(ert-deftest drgnx-pkg/lock-round-trip ()
  (drgnx-pkg-test--with root
    (should-not (drgnx-pkg-read-lock))
    (drgnx-pkg-write-lock '((zz :version "2.0" :sha256 "b") (aa :version "1.0" :sha256 "a")))
    (should (equal (drgnx-pkg-read-lock) '((aa :version "1.0" :sha256 "a") (zz :version "2.0" :sha256 "b"))))
    (should (string-match-p "\\`;; drgnx package lock" (with-temp-buffer (insert-file-contents (drgnx-pkg-lock-file)) (buffer-string))))))

(ert-deftest drgnx-pkg/an-unreadable-lock-is-an-error-and-is-never-overwritten ()
  (drgnx-pkg-test--with root
    (write-region "(:version 1 :packages ((aa :version" nil (drgnx-pkg-lock-file) nil 'silent)
    (let ((before (drgnx-pkg-test--bytes (drgnx-pkg-lock-file))))
      (should-error (drgnx-pkg-read-lock) :type 'drgnx-pkg-error)
      (drgnx-pkg-test--want root 'fa)
      (should-error (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))
                    :type 'drgnx-pkg-error)
      (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) before)))))

;;;; Task 2: sync, cache, offline, refusals

(ert-deftest drgnx-pkg/sync-installs-the-manifest-with-its-dependencies ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0")))))))
      (drgnx-pkg-test--want root 'fb)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should (plist-get r :ok))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0")))
        (should (file-exists-p (expand-file-name "fb-1.0/fb.elc" (drgnx-elpa-dir))))     ; byte-compiled
        (should (file-exists-p (expand-file-name "drgnx-quickstart.el" (drgnx-elpa-dir))))
        (let ((lock (drgnx-pkg-read-lock)))
          (should (equal (mapcar #'car lock) '(fa fb)))
          (should (equal (plist-get (alist-get 'fb lock) :version) "1.0"))
          (should (equal (plist-get (alist-get 'fb lock) :archive) "fx"))
          (should (equal (plist-get (alist-get 'fb lock) :sha256)
                         (secure-hash 'sha256 (drgnx-pkg-test--bytes (concat arch "fb-1.0.el"))))))
        (should (file-exists-p (expand-file-name "fb-1.0.el" (drgnx-package-cache-dir))))
        (should (equal (mapcar #'car (drgnx-pkg-generations)) '(1)))
        (should (eql (plist-get r :generation) 1))))))

(ert-deftest drgnx-pkg/offline-sync-from-the-lock-into-an-empty-dir ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0")))))))
      (drgnx-pkg-test--want root 'fb)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (delete-directory arch t)                                        ; no archive any more
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "data2") process-environment)))
        (let ((r (drgnx-pkg-test--sync root :offline t)))
          (should (plist-get r :ok))
          (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0"))))))))

(ert-deftest drgnx-pkg/a-wrong-hash-refuses-and-leaves-elpa-and-lock-alone ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0")))))))
      (drgnx-pkg-test--want root 'fb)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (write-region "(error \"tampered\")\n" nil (expand-file-name "fb-1.0.el" (drgnx-package-cache-dir)) nil 'silent)
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "data2") process-environment))
            (lock (drgnx-pkg-test--bytes (drgnx-pkg-lock-file))))
        (should-error (drgnx-pkg-test--sync root :offline t) :type 'drgnx-pkg-error)
        (should-not (file-exists-p (drgnx-elpa-dir)))                  ; nothing half-installed
        (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) lock))))))

(ert-deftest drgnx-pkg/a-locked-version-nobody-has-is-reported-and-the-rest-installed ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fc "1.0")))))
      (drgnx-pkg-test--want root 'fa 'fc)
      (drgnx-pkg-write-lock '((fc :version "0.9" :archive "fx" :kind single :file "fc-0.9.el" :sha256 "x")))
      (let ((lock (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)))
            (r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should-not (plist-get r :ok))
        (should (equal (mapcar #'car (plist-get r :missing)) '(fc)))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
        (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) lock))))))

(ert-deftest drgnx-pkg/a-second-sync-refuses-while-one-runs ()
  (drgnx-pkg-test--with root
    (make-directory (drgnx-data-dir) t)
    (drgnx-pkg-test--want root)
    (write-region (format "%d" (emacs-pid)) nil (expand-file-name "sync.lock" (drgnx-data-dir)) nil 'silent)
    (should-error (drgnx-pkg-test--sync root :archives nil) :type 'drgnx-pkg-error)
    ;; a lock left by a process that is gone is taken over
    (write-region "999999999" nil (expand-file-name "sync.lock" (drgnx-data-dir)) nil 'silent)
    (should (plist-get (drgnx-pkg-test--sync root :archives nil) :ok))
    (should-not (file-exists-p (expand-file-name "sync.lock" (drgnx-data-dir))))))

(ert-deftest drgnx-pkg/seeding-copies-an-existing-elpa ()
  ;; The cutover: the packages of today's Emacs, copied, then recorded in the lock.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))
          (old (concat root "old-elpa/")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (copy-directory (expand-file-name "fa-1.0" (drgnx-elpa-dir)) (expand-file-name "fa-1.0" old) nil t t)
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "data2") process-environment)))
        (let ((r (drgnx-pkg-test--sync root :offline t :seed old)))
          (should (plist-get r :ok))
          (should (equal (drgnx-pkg-test--installed) '("fa-1.0"))))))))

(ert-deftest drgnx-pkg/native-code-goes-to-drgnx-own-cache ()
  ;; Never into the user's other Emacs (~/.config/emacs/eln-cache): sync compiles into the data dir,
  ;; where sessions look first.
  (skip-unless (native-comp-available-p))                ; Homebrew's Emacs (macOS CI) has no native compilation
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0")))) (dirs nil)
          (drgnx-pkg-native-compile t))
      (drgnx-pkg-test--want root 'fa)
      (cl-letf (((symbol-function 'native-compile)
                 (lambda (f &rest _) (push (cons (car native-comp-eln-load-path) f) dirs))))
        (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))))
      (should dirs)
      (should (seq-every-p (lambda (d) (equal (file-name-as-directory (car d)) (concat root "data/eln-cache/"))) dirs))
      ;; .eln names hash the source's path: compile the files where sessions load them, not in staging
      (should (seq-every-p (lambda (d) (string-prefix-p (drgnx-elpa-dir) (cdr d))) dirs)))))

(ert-deftest drgnx-pkg/archives-in-packages-eld-even-none ()
  (drgnx-pkg-test--with root
    (should (equal (drgnx-pkg-archives) drgnx-pkg-default-archives))
    (drgnx-pkg-test--write (concat root "config/packages.eld") '(:archives ()))
    (should-not (drgnx-pkg-archives))
    (drgnx-pkg-test--write (concat root "config/packages.eld") '(:archives (("local" . "/srv/elpa/"))))
    (should (equal (drgnx-pkg-archives) '(("local" . "/srv/elpa/"))))))

;;;; Task 3: generations, rollback, upgrade

(ert-deftest drgnx-pkg/rollback-restores-the-files-byte-for-byte-at-the-same-path ()
  (drgnx-pkg-test--with root
    (let ((arch (concat root "arch")))
      (drgnx-pkg-test--archive arch '((fa "1.0")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (let ((v1 (drgnx-pkg-test--bytes (expand-file-name "fa-1.0/fa.elc" (drgnx-elpa-dir)))))
        (drgnx-pkg-test--archive arch '((fa "2.0")))
        (should (plist-get (drgnx-pkg-upgrade :archives `(("fx" . ,arch)) :modules-dir (concat root "mods") :smoke #'ignore) :ok))
        (should (equal (drgnx-pkg-test--installed) '("fa-2.0")))
        (should (equal (mapcar #'car (drgnx-pkg-generations)) '(3 2 1)))   ; 2: the snapshot before the upgrade
        (should (eql (drgnx-pkg-rollback) 2))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
        (should (equal (drgnx-pkg-test--bytes (expand-file-name "fa-1.0/fa.elc" (drgnx-elpa-dir))) v1))
        (should (equal (plist-get (alist-get 'fa (drgnx-pkg-read-lock)) :version) "1.0"))))))

(ert-deftest drgnx-pkg/a-broken-upgrade-restores-the-previous-generation ()
  (drgnx-pkg-test--with root
    (let ((arch (concat root "arch")))
      (drgnx-pkg-test--archive arch '((fa "1.0")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (drgnx-pkg-test--archive arch '((fa "2.0" nil "(error \"fa 2.0 is broken\")")))
      ;; the default smoke test: a fresh Emacs that activates the packages and loads every one
      (let ((r (drgnx-pkg-upgrade :archives `(("fx" . ,arch)) :modules-dir (concat root "mods"))))
        (should-not (plist-get r :ok))
        (should (string-match-p "fa 2.0 is broken" (plist-get r :smoke)))
        (should (eql (plist-get r :restored) 2))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
        (should (equal (plist-get (alist-get 'fa (drgnx-pkg-read-lock)) :version) "1.0"))
        (should (equal (mapcar #'car (drgnx-pkg-generations)) '(2 1)))))))

(ert-deftest drgnx-pkg/five-generations-are-kept ()
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root)
    (dotimes (_ 7) (drgnx-pkg-snapshot))
    (should (equal (mapcar #'car (drgnx-pkg-generations)) '(7 6 5 4 3)))))

;;;; Task 4: the guard, use-package :ensure, bisect, the CLI, the doctor, safe mode

(require 'drgnx-pkg-activate)
(require 'drgnx-doctor)

(ert-deftest drgnx-pkg/the-guard-refuses-installs-from-automatic-code ()
  (let ((orig (lambda (&rest _) 'installed)) (after-init-time (current-time)))
    (let ((this-command nil))                                      ; a timer, a hook at startup, …
      (should-error (drgnx-pkg--guard orig 'foo) :type 'drgnx-pkg-error))
    (let ((this-command 'package-install))                         ; the user asked
      (should (eq (drgnx-pkg--guard orig 'foo) 'installed)))
    (let ((this-command 'package-install) (after-init-time nil))   ; still starting up
      (should-error (drgnx-pkg--guard orig 'foo) :type 'drgnx-pkg-error)))
  (unwind-protect
      (progn (drgnx-pkg-guard-mode 1)
             (dolist (f '(package-install package-refresh-contents package-vc-install package-upgrade package-upgrade-all))
               (should (advice-member-p #'drgnx-pkg--guard f))))
    (drgnx-pkg-guard-mode -1))
  (should-not (advice-member-p #'drgnx-pkg--guard 'package-install)))

(defvar drgnx-pkg-test--hook nil)
(defvar drgnx-guard--automatic)

(ert-deftest drgnx-pkg/the-guard-refuses-installs-from-hooks-in-user-commands ()
  ;; M5-8: a hook running inside a user command (find-file, …) is not the user asking to install.
  (let ((orig (lambda (&rest _) 'installed)) (after-init-time (current-time)) (this-command 'find-file))
    (dolist (runner '(run-hooks run-hook-with-args run-hook-with-args-until-success run-hook-with-args-until-failure))
      (let ((drgnx-pkg-test--hook (list (lambda (&rest _) (drgnx-pkg--guard orig 'foo)))))
        (let ((err (should-error (funcall runner 'drgnx-pkg-test--hook) :type 'drgnx-pkg-error)))
          (should (string-match-p "hook" (cadr err)))
          (should-not (string-match-p "automatic code" (cadr err))))))
    (let ((drgnx-pkg-test--hook (list (lambda () (drgnx-pkg--guard orig 'foo)))))   ; a mode hook
      (should-error (run-mode-hooks 'drgnx-pkg-test--hook) :type 'drgnx-pkg-error))
    (let ((drgnx-guard--automatic t))                              ; inside drgnx-automatic
      (should-error (drgnx-pkg--guard orig 'foo) :type 'drgnx-pkg-error))))

(ert-deftest drgnx-pkg/the-guard-allows-installs-the-user-started ()
  ;; Review I1: M-x list-packages, describe-package's Install button (push-button), M-: and a third-party command
  ;; are the user's own: only hooks, timers, startup and automatic code are refused.
  (let ((orig (lambda (&rest _) 'installed)) (after-init-time (current-time)))
    (dolist (c '(list-packages push-button eval-expression package-install package-menu-execute auto-package-update-now))
      (let ((this-command c))
        (should (eq (drgnx-pkg--guard orig 'foo) 'installed))))))

(ert-deftest drgnx-pkg/use-package-ensure-only-records ()
  (drgnx-pkg-test--with root
    (should-not (drgnx-pkg-ensure 'drgnx-no-such-package-x '(t) nil))
    (should-not (drgnx-pkg-ensure 'seq '(t) nil))                 ; there already: nothing to record
    (should-not (drgnx-pkg-ensure 'drgnx-no-such-package-x '(t) nil))
    (should (equal (drgnx-pkg--read-file (drgnx-pkg-wanted-file)) '(drgnx-no-such-package-x)))
    (should (memq 'drgnx-no-such-package-x (drgnx-pkg-manifest (progn (make-directory (concat root "mods") t) (concat root "mods")))))))

(ert-deftest drgnx-pkg/sessions-activate-the-packages-directory ()
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root 'fa)
    (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))
    (setq package-alist nil package-activated-list nil)
    (drgnx-pkg-activate)
    (should (equal package-user-dir (drgnx-elpa-dir)))
    (should (string-prefix-p (drgnx-elpa-dir) (locate-library "fa")))
    (should (equal (progn (require 'fa) (fa-hello)) "1.0"))))

(ert-deftest drgnx-pkg/bisect-pins-the-failing-module ()
  (drgnx-pkg-test--with root
    (let ((mods (concat root "mods/x/")))
      (make-directory mods t)
      (dotimes (i 6)
        (write-region (format "(drgnx-module-define 'x/m%d :doc \"m\")\n" i) nil (format "%sdrgnx-m%d.el" mods i) nil 'silent))
      (drgnx-pkg-test--write (concat root "config/modules.eld") '(:version 1 :disabled (x/m0) :theme tango))
      (let* ((runs 0)
             (fails-with (lambda (culprit)
                           (lambda (config-dir)
                             (setq runs (1+ runs))
                             (let ((m (with-temp-buffer (insert-file-contents (expand-file-name "modules.eld" config-dir))
                                                        (read (current-buffer)))))
                               (should (eq (plist-get m :theme) 'tango))       ; the rest of the file is kept
                               (not (memq culprit (plist-get m :disabled))))))))
        (should (eq (drgnx-pkg-bisect (funcall fails-with 'x/m4) :modules-dir (concat root "mods")) 'x/m4))
        (should (<= runs 6))                                           ; halving, not one by one
        (should (eq (drgnx-pkg-bisect (lambda (_) t) :modules-dir (concat root "mods")) :not-a-module))
        (should-error (drgnx-pkg-bisect (lambda (_) nil) :modules-dir (concat root "mods")) :type 'drgnx-pkg-error)
        ;; the user's modules.eld is untouched
        (should (equal (drgnx-pkg--read-file (concat root "config/modules.eld")) '(:version 1 :disabled (x/m0) :theme tango)))))))

(ert-deftest drgnx-pkg/the-service-unit-is-written-never-installed ()
  (drgnx-pkg-test--with root
    (let ((unit (drgnx-pkg-service-unit)))
      (should (string-match-p "^Type=notify$" unit))
      (should (string-match-p (regexp-quote (concat "--fg-daemon=drgnx --init-directory=" (expand-file-name "init" drgnx-dir))) unit))
      (should-not (file-exists-p (expand-file-name "~/.config/systemd/user/drgnx.service.drgnx-test"))))
    (drgnx-pkg-service-unit (concat root "units"))
    (should (file-exists-p (concat root "units/drgnx.service")))))

(ert-deftest drgnx-pkg/the-service-unit-stops-restarting-when-another-drgnx-holds-the-name ()
  ;; M12a-30: Restart=on-failure looped when another drgnx held the server name.
  (drgnx-pkg-test--with root
    (let ((unit (drgnx-pkg-service-unit)))
      (should (string-match-p "^Restart=on-failure$" unit))
      (should (string-match-p "^RestartSec=2$" unit))
      (should (string-match-p "\\`\\[Unit\\]\n\\(.*\n\\)*StartLimitIntervalSec=60\n\\(.*\n\\)*StartLimitBurst=3\n\\(.*\n\\)*\\[Service\\]" unit)))))

(ert-deftest drgnx-pkg/the-cli-parses-its-commands ()
  (let (calls)
    (cl-letf (((symbol-function 'drgnx-pkg-sync) (lambda (&rest a) (push (cons 'sync a) calls) '(:ok t)))
              ((symbol-function 'drgnx-pkg-rollback) (lambda (&optional n) (push (list 'rollback n) calls) 1))
              ((symbol-function 'drgnx-pkg-upgrade) (lambda (&rest a) (push (cons 'upgrade a) calls) '(:ok nil :restored 2))))
      (should (eql (drgnx-pkg-cli-run '("sync" "--offline" "--seed" "/x")) 0))
      (should (equal (car calls) '(sync :offline t :seed "/x")))
      (should (eql (drgnx-pkg-cli-run '("rollback" "3")) 0))
      (should (equal (car calls) '(rollback 3)))
      (should (eql (drgnx-pkg-cli-run '("upgrade")) 1))
      (should (eql (drgnx-pkg-cli-run '("frobnicate")) 2)))))

(ert-deftest drgnx-pkg/the-doctor-reports-packages ()
  (let ((check (lambda (p) (drgnx-doctor-check 'packages (list :packages p)))))
    (should (eq (car (funcall check '(:manifest nil :installed nil :lock nil :generations 0))) 'ok))
    (let ((r (funcall check '(:manifest (fa fb) :installed (fa) :lock t :generations 1))))
      (should (eq (car r) 'warn))
      (should (string-search "fb" (nth 1 r)))
      (should (string-search "drgnx sync" (nth 2 r))))
    (should (eq (car (funcall check '(:manifest (fa) :installed (fa) :lock nil :generations 0))) 'warn))
    (should (eq (car (funcall check '(:manifest (fa) :installed (fa) :lock t :generations 2))) 'ok))
    (should (eq (car (funcall check '(:error "drgnx.lock.eld is unreadable"))) 'fail))))

(ert-deftest drgnx-pkg/the-doctor-fact-is-the-real-state ()
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root 'fa)
    (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))
    (let ((s (drgnx-pkg-status (concat root "mods"))))
      (should (equal (plist-get s :installed) '(fa)))
      (should (equal (plist-get s :manifest) '(fa)))
      (should (plist-get s :lock))
      (should (eql (plist-get s :generations) 1)))))

(ert-deftest drgnx-pkg/safe-mode-runs-no-modules-and-no-packages ()
  (require 'drgnx)
  (let (calls (process-environment (cons "DRGNX_SAFE=1" process-environment)))
    (cl-letf (((symbol-function 'drgnx-modules-start) (lambda (&rest _) (push 'modules calls)))
              ((symbol-function 'drgnx-pkg-activate) (lambda (&rest _) (push 'packages calls)))
              ((symbol-function 'drgnx-pkg-guard-mode) #'ignore)
              ((symbol-function 'drgnx-guard-mode) #'ignore) ((symbol-function 'drgnx-hooks-install) #'ignore)
              ((symbol-function 'drgnx--core-commands) #'ignore) ((symbol-function 'drgnx-keys-apply) #'ignore)
              ((symbol-function 'drgnx-surfaces-refresh) #'ignore))
      (unwind-protect
          (progn
            (drgnx-init)
            (should-not calls)
            (setenv "DRGNX_SAFE" nil)
            (drgnx-init)
            (should (equal (sort calls (lambda (a b) (string< a b))) '(modules packages))))
        (drgnx-timer-cancel 'gc-idle)))))

;;;; Review fixes (M5 final review)

(ert-deftest drgnx-pkg/a-failed-download-changes-nothing ()
  ;; C1: an archive that lists a file it cannot serve — elpa, lock and staging as before.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0")))))))
      (delete-file (concat arch "fa-1.0.el"))
      (drgnx-pkg-test--want root 'fb)
      (should-error (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :type 'drgnx-pkg-error)
      (should-not (file-exists-p (drgnx-elpa-dir)))
      (should-not (file-exists-p (drgnx-pkg-lock-file)))
      (should-not (file-exists-p (expand-file-name "elpa.staging" (drgnx-data-dir))))
      (should-not (file-exists-p (expand-file-name "sync.lock" (drgnx-data-dir)))))))

(ert-deftest drgnx-pkg/an-upgrade-whose-download-fails-leaves-the-packages-as-they-were ()
  (drgnx-pkg-test--with root
    (let ((arch (concat root "arch")))
      (drgnx-pkg-test--archive arch '((fa "1.0") (fb "1.0" ((fa "1.0")))))
      (drgnx-pkg-test--want root 'fb)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (drgnx-pkg-test--archive arch '((fa "2.0") (fb "2.0" ((fa "2.0")))))
      (delete-file (expand-file-name "fa-2.0.el" arch))
      (let ((r (drgnx-pkg-upgrade :archives `(("fx" . ,arch)) :modules-dir (concat root "mods") :smoke #'ignore)))
        (should-not (plist-get r :ok))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0")))
        (should (equal (plist-get (alist-get 'fb (drgnx-pkg-read-lock)) :version) "1.0"))))))

(ert-deftest drgnx-pkg/upgrade-never-touches-another-emacs-quickstart ()
  ;; I1: package-delete refreshes (or deletes) `package-quickstart-file' — another Emacs's.
  (drgnx-pkg-test--with root
    (let ((arch (concat root "arch")))
      (make-directory (file-name-directory package-quickstart-file) t)
      (write-region ";; theirs\n" nil package-quickstart-file nil 'silent)
      (drgnx-pkg-test--archive arch '((fa "1.0")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (drgnx-pkg-test--archive arch '((fa "2.0")))
      (should (plist-get (drgnx-pkg-upgrade :archives `(("fx" . ,arch)) :modules-dir (concat root "mods") :smoke #'ignore) :ok))
      (should (equal (drgnx-pkg-test--bytes package-quickstart-file) ";; theirs\n")))))

(ert-deftest drgnx-pkg/the-lock-decides-the-version ()
  ;; I3: an installed version the lock does not name is replaced by the locked one (online and offline).
  (dolist (offline '(nil t))
    (drgnx-pkg-test--with root
      (let ((arch (concat root "arch")))
        (drgnx-pkg-test--archive arch '((fa "1.0")))
        (drgnx-pkg-test--want root 'fa)
        (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
        (let ((lock1 (drgnx-pkg-test--bytes (drgnx-pkg-lock-file))))
          (drgnx-pkg-test--archive arch '((fa "2.0")))
          (drgnx-pkg-upgrade :archives `(("fx" . ,arch)) :modules-dir (concat root "mods") :smoke #'ignore)
          (write-region lock1 nil (drgnx-pkg-lock-file) nil 'silent)          ; the lock from git: fa 1.0
          (should (plist-get (if offline (drgnx-pkg-test--sync root :offline t)
                               (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))))
                             :ok))
          (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
          (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) lock1)))))))

(ert-deftest drgnx-pkg/a-pin-older-than-a-package-needs-is-a-conflict ()
  ;; I4: the lock pins fa 1.0; a new package needs fa 2.0 — reported, never "ok".
  (drgnx-pkg-test--with root
    (let ((arch (concat root "arch")))
      (drgnx-pkg-test--archive arch '((fa "1.0")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (drgnx-pkg-test--archive arch '((fa "2.0") (fb "1.0" ((fa "2.0")))))
      (drgnx-pkg-test--want root 'fa 'fb)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should-not (plist-get r :ok))
        (should (assq 'fa (plist-get r :missing)))
        (should (string-match-p "upgrade" (alist-get 'fa (plist-get r :missing))))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))))))

(ert-deftest drgnx-pkg/one-unknown-package-does-not-block-the-rest ()
  ;; I5
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root 'fa 'zz-not-anywhere)
    (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))))
      (should-not (plist-get r :ok))
      (should (equal (mapcar #'car (plist-get r :missing)) '(zz-not-anywhere)))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0"))))))

(ert-deftest drgnx-pkg/ensure-records-what-use-package-would-install ()
  ;; I5: the :ensure value decides — nil nothing, a symbol that package, (PKG :pin …) PKG.
  (drgnx-pkg-test--with root
    (drgnx-pkg-ensure 'mylib '(nil) nil)
    (drgnx-pkg-ensure 'thing '(other-pkg-x) nil)
    (drgnx-pkg-ensure 'thing2 '((pinned-pkg-x :pin "gnu")) nil)
    (drgnx-pkg-ensure 'plain-pkg-x '(t) nil)
    (should (equal (drgnx-pkg--read-file (drgnx-pkg-wanted-file)) '(other-pkg-x pinned-pkg-x plain-pkg-x)))))

(ert-deftest drgnx-pkg/installed-wants-are-kept ()
  ;; C1: the want outlives the sync that installed it (it is what keeps the package out of `sync --prune').
  (drgnx-pkg-test--with root
    (drgnx-pkg-ensure 'fa '(t) nil)
    (drgnx-pkg-test--want root)
    (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))
                       :ok))
    (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
    (should (equal (drgnx-pkg--read-file (drgnx-pkg-wanted-file)) '(fa)))))

(ert-deftest drgnx-pkg/rollback-waits-for-no-sync ()
  ;; I7: rollback takes the sync lock too.
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root)
    (drgnx-pkg-snapshot) (drgnx-pkg-snapshot)
    (write-region (format "%d" (emacs-pid)) nil (expand-file-name "sync.lock" (drgnx-data-dir)) nil 'silent)
    (should-error (drgnx-pkg-rollback 1) :type 'drgnx-pkg-error)))

(ert-deftest drgnx-pkg/a-file-that-does-not-install-leaves-the-cache ()
  ;; I8: a bad file is never kept to poison later (offline) syncs.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0")))))
      (drgnx-pkg-test--want root 'fa)
      (cl-letf (((symbol-function 'drgnx-pkg--unpack) (lambda (&rest _) (error "does not untar cleanly"))))
        (should-error (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :type 'drgnx-pkg-error))
      (should-not (file-exists-p (expand-file-name "fa-1.0.el" (drgnx-package-cache-dir))))
      (should-not (file-exists-p (drgnx-elpa-dir))))))

(ert-deftest drgnx-pkg/the-cli-reports-any-error-as-a-failure ()
  (cl-letf (((symbol-function 'drgnx-pkg-sync) (lambda (&rest _) (error "Something unexpected"))))
    (should (eql (drgnx-pkg-cli-run '("sync")) 1))))

(ert-deftest drgnx-pkg/the-cli-says-to-restart-after-a-change ()
  ;; I11: a running daemon keeps the packages it loaded.
  (cl-letf (((symbol-function 'drgnx-pkg-rollback) (lambda (&optional _) 1)))
    (should (string-match-p "restart" (with-output-to-string (drgnx-pkg-cli-run '("rollback")))))))

(ert-deftest drgnx-pkg/the-smoke-test-loads-only-real-features ()
  ;; I10: a package name is not always a feature of the package.
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root 'fa)
    (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))
    (should (equal (drgnx-pkg--smoke-features '(fa built-in-only-x)) '(fa)))
    (should-not (drgnx-pkg-smoke '(fa built-in-only-x)))))

(ert-deftest drgnx-pkg/an-interrupted-swap-is-recovered ()
  ;; M5: a crash between the two renames leaves elpa.old and no elpa.
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root 'fa)
    (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))
    (rename-file (directory-file-name (drgnx-elpa-dir)) (concat (directory-file-name (drgnx-elpa-dir)) ".old"))
    (should (plist-get (drgnx-pkg-test--sync root :offline t) :ok))
    (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))))

(ert-deftest drgnx-pkg/offline-reports-what-the-lock-does-not-have ()
  ;; M2, M3
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root 'fa)
    (drgnx-pkg-write-lock '((fc :version "1.0" :archive "fx" :kind single :file "fc-1.0.el" :sha256 "x")))
    (let ((r (drgnx-pkg-test--sync root :offline t)))
      (should-not (plist-get r :ok))
      (should (string-match-p "not in the lock" (alist-get 'fa (plist-get r :missing))))
      (should (string-match-p "not in the cache" (alist-get 'fc (plist-get r :missing)))))))

(ert-deftest drgnx-pkg/generations-and-rollback-track-the-current-one ()
  ;; M6 (a half-written snapshot is not a generation), M8 (rollback steps back from the current one)
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root)
    (dotimes (_ 3) (drgnx-pkg-snapshot))
    (make-directory (expand-file-name "4.tmp" (drgnx-generations-dir)) t)
    (should (equal (mapcar #'car (drgnx-pkg-generations)) '(3 2 1)))
    (should (eql (drgnx-pkg-rollback) 2))
    (should (eql (drgnx-pkg-rollback) 1))
    (should-error (drgnx-pkg-rollback) :type 'drgnx-pkg-error)))

(ert-deftest drgnx-pkg/sessions-keep-hand-installed-packages ()
  ;; M9: the quickstart file is the session's for good (package.el refreshes it after M-x package-install).
  (drgnx-pkg-test--with root
    (drgnx-pkg-activate)
    (should package-quickstart)
    (should (equal package-quickstart-file (expand-file-name "drgnx-quickstart.el" (drgnx-elpa-dir))))))

(ert-deftest drgnx-pkg/the-guard-covers-vc-upgrades ()
  ;; M10
  (unwind-protect
      (progn (drgnx-pkg-guard-mode 1)
             (should (advice-member-p #'drgnx-pkg--guard 'package-vc-upgrade))
             (should (advice-member-p #'drgnx-pkg--guard 'package-vc-upgrade-all)))
    (drgnx-pkg-guard-mode -1)))

;;;; Deferred review items

(ert-deftest drgnx-pkg/compile-failures-are-reported ()
  ;; M5-9: a package that does not byte-compile (or natively compile) still installs, and the sync says so.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch")
                                         '((fa "1.0") (fbad "1.0" nil "(eval-when-compile (error \"fixture fails to compile\"))"))))
          (drgnx-pkg-native-compile (native-comp-available-p)))   ; the native half needs native compilation
      (drgnx-pkg-test--want root 'fa 'fbad)
      (cl-letf (((symbol-function 'native-compile)
                 (lambda (f &rest _) (when (string-match-p "/fa\\.el\\'" f) (error "no libgccjit")))))
        (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
          (should (plist-get r :ok))
          (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fbad-1.0")))
          (should (seq-find (lambda (w) (string-match-p "fbad\\.el does not byte-compile" w)) (plist-get r :warnings)))
          (when (native-comp-available-p)
            (should (seq-find (lambda (w) (string-match-p "fa\\.el .*native.*no libgccjit" w)) (plist-get r :warnings))))
          (should-not (seq-find (lambda (w) (string-match-p "\\_<fa\\.el does not byte-compile" w)) (plist-get r :warnings)))
          (should (string-match-p "^WARNING .*fbad\\.el" (with-output-to-string (drgnx-pkg--report r)))))))))

(ert-deftest drgnx-pkg/every-package-compiles-when-bytecomp-was-not-loaded ()
  ;; macOS install: in an Emacs that had not loaded bytecomp, the first package compiled and every later one failed
  ;; ("symbolp, (autoload \"bytecomp\" …)"): the byte-compile-file wrapper put back the autoload it had found.  A fresh
  ;; Emacs, then: bytecomp unloaded where something loads it (package.el), two packages synced.
  (let* ((form `(progn
                  (when (featurep 'bytecomp) (unload-feature 'bytecomp t))
                  (unless (autoloadp (symbol-function 'byte-compile-file)) (error "Bytecomp still loaded"))
                  (drgnx-pkg-test--with root
                    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0")))))
                      (drgnx-pkg-test--write (concat root "config/packages.eld") '(:packages (fa fb)))
                      (let ((r (drgnx-pkg-test--sync root :archives (list (cons "fx" arch)))))
                        (princ (format "RESULT %S\n" (list (and (plist-get r :ok) t)
                                                           (file-exists-p (expand-file-name "fa-1.0/fa.elc" (drgnx-elpa-dir)))
                                                           (file-exists-p (expand-file-name "fb-1.0/fb.elc" (drgnx-elpa-dir)))))))))))
         (out (with-temp-buffer
                (call-process (expand-file-name invocation-name invocation-directory) nil t nil "--batch" "-Q"
                              "-L" (expand-file-name "core" drgnx-dir)
                              "-l" (expand-file-name "test/fixtures/pkg-fixture.el" drgnx-dir)
                              "--eval" (prin1-to-string form))
                (buffer-string))))
    (should (string-match "^RESULT \\(.*\\)$" out))
    (should (equal (car (read-from-string (match-string 1 out))) '(t t t)))))

(ert-deftest drgnx-pkg/the-sync-lock-knows-its-process-by-pid-and-start ()
  ;; M5-10: a pid reused (after a reboot) by another process is not the sync that wrote the lock.
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root)
    (make-directory (drgnx-data-dir) t)
    (let* ((file (expand-file-name "sync.lock" (drgnx-data-dir)))
           (attrs (symbol-function 'process-attributes))
           (stamp (drgnx-pkg--take-sync-lock)))
      (should (string-match-p (format "\\`%d [0-9.]+\\'" (emacs-pid)) stamp))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) stamp))
      (drgnx-pkg--release-sync-lock stamp)
      (should-not (file-exists-p file))
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid) (if (eql pid 4242) `((start . ,(seconds-to-time 5000))) (funcall attrs pid)))))
        (write-region "4242 5000.10" nil file nil 'silent)          ; alive, the same start: running
        (should-error (drgnx-pkg-test--sync root :archives nil) :type 'drgnx-pkg-error)
        (write-region "4242 1234.00" nil file nil 'silent)          ; alive, another start: a reused pid
        (should (plist-get (drgnx-pkg-test--sync root :archives nil) :ok))
        (should-not (file-exists-p file))))))

(ert-deftest drgnx-pkg/a-stale-lock-is-taken-over-once ()
  ;; M5-10: two processes taking over the same stale lock — the second finds the first's lock, not the
  ;; stale one it judged, and leaves it in place.
  (drgnx-pkg-test--with root
    (make-directory (drgnx-data-dir) t)
    (let ((file (expand-file-name "sync.lock" (drgnx-data-dir))))
      (write-region "999999999 1.00" nil file nil 'silent)
      (let ((seen "999999999 1.00"))
        (write-region "4242 77.00" nil file nil 'silent)             ; the other one got there first
        (should-error (drgnx-pkg--clear-stale-lock file seen) :type 'drgnx-pkg-error)
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "4242 77.00"))
        (should (equal (directory-files (drgnx-data-dir) nil "\\`[^.]") '("sync.lock")))
        (write-region seen nil file nil 'silent)
        (drgnx-pkg--clear-stale-lock file seen)
        (should-not (directory-files (drgnx-data-dir) nil "\\`[^.]"))
        (drgnx-pkg--release-sync-lock "4242 77.00")                 ; not ours: never deleted
        (write-region "4242 77.00" nil file nil 'silent)
        (drgnx-pkg--release-sync-lock (format "%d 1.00" (emacs-pid)))
        (should (file-exists-p file))))))

(ert-deftest drgnx-pkg/bisect-covers-external-modules ()
  ;; M5-11: an external module (modules.eld :external) can be the culprit too.
  (drgnx-pkg-test--with root
    (make-directory (concat root "mods/x/") t)
    (dotimes (i 3)
      (write-region (format "(drgnx-module-define 'x/m%d :doc \"m\")\n" i) nil (format "%smods/x/drgnx-m%d.el" root i) nil 'silent))
    (drgnx-pkg-test--write (concat root "config/modules.eld")
                           '(:version 1 :disabled (external/off)
                                      :external ((:name "gry" :path "/nowhere" :features (gry)) (:name "off" :path "/nowhere"))))
    (let ((fails (lambda (culprit)
                   (lambda (config-dir)
                     (not (memq culprit (plist-get (drgnx-pkg--read-file (expand-file-name "modules.eld" config-dir)) :disabled)))))))
      (should (eq (drgnx-pkg-bisect (funcall fails 'external/gry) :modules-dir (concat root "mods")) 'external/gry))
      (should (eq (drgnx-pkg-bisect (funcall fails 'x/m1) :modules-dir (concat root "mods")) 'x/m1))
      ;; an external module already off is no candidate: it stays off in every round
      (should (eq (drgnx-pkg-bisect (lambda (config-dir)
                                      (should (memq 'external/off (plist-get (drgnx-pkg--read-file (expand-file-name "modules.eld" config-dir))
                                                                             :disabled)))
                                      t)
                                    :modules-dir (concat root "mods"))
                  :not-a-module)))))

(ert-deftest drgnx-pkg/the-service-unit-quotes-its-paths ()
  ;; M5-13: systemd splits ExecStart at spaces and expands % and $.
  (let ((invocation-directory "/opt/my emacs/bin/") (invocation-name "emacs-pgtk")
        (drgnx-dir "/src/100% \"drgnx\"/"))
    (should (string-match-p (regexp-quote "\nExecStart=\"/opt/my emacs/bin/emacs-pgtk\" --fg-daemon=drgnx \"--init-directory=/src/100%% \\\"drgnx\\\"/init\"\n")
                            (drgnx-pkg-service-unit))))
  (let ((invocation-directory "/usr/bin/") (invocation-name "emacs") (drgnx-dir "/src/drgnx/"))
    (should (string-match-p "\nExecStart=/usr/bin/emacs --fg-daemon=drgnx --init-directory=/src/drgnx/init\n" (drgnx-pkg-service-unit)))))

(defmacro drgnx-pkg-test--with-unit (vars unit-text &rest body)
  "BODY with XDG_CONFIG_HOME a temp dir (VARS: ROOT UNIT RELOADS), UNIT-TEXT written as its drgnx.service
\(nil: no file), and the systemctl reload replaced by a counter: nothing reaches the real unit or systemd."
  (declare (indent 2))
  (pcase-let ((`(,root ,unit ,reloads) vars))
    `(drgnx-pkg-test--with ,root
       (let* ((process-environment (cons (concat "XDG_CONFIG_HOME=" ,root "xdg") process-environment))
              (,unit (expand-file-name "systemd/user/drgnx.service" (concat ,root "xdg")))
              (,reloads 0))
         (when ,unit-text
           (make-directory (file-name-directory ,unit) t)
           (write-region ,unit-text nil ,unit nil 'silent))
         (cl-letf (((symbol-function 'drgnx-pkg--systemctl-reload) (lambda () (cl-incf ,reloads) 'ok)))
           ,@body)))))

(defun drgnx-pkg-test--slurp (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-pkg-test--old-unit (exec)
  (format "[Unit]\nDescription=drgnx (Emacs daemon)\n\n[Service]\nType=notify\nExecStart=%s --fg-daemon=drgnx --init-directory=/x/init\nEnvironment=FOO=1\nRestart=on-failure\n" exec))

(ert-deftest drgnx-pkg/refresh-rewrites-only-execstart-emacs ()
  (drgnx-pkg-test--with-unit (root unit reload-calls) (drgnx-pkg-test--old-unit "/old/bin/emacs")
    (let ((r (drgnx-pkg-service-unit-refresh)))
      (should (eq (plist-get r :status) 'rewritten))
      (should (equal (plist-get r :old) "/old/bin/emacs"))
      (should (eq (plist-get r :reload) 'ok))
      (should (string-search "Environment=FOO=1\n" (drgnx-pkg-test--slurp unit)))
      (should (= 1 (with-temp-buffer (insert-file-contents unit) (how-many "^ExecStart=" (point-min) (point-max)))))
      (should (equal (nth 0 (drgnx-pkg--unit-exec-start (drgnx-pkg-test--slurp unit)))
                     (nth 0 (drgnx-pkg--unit-exec-start (drgnx-pkg-service-unit)))))
      (should (equal reload-calls 1)))))

(ert-deftest drgnx-pkg/refresh-shows-old-and-new-before-it-writes ()
  (drgnx-pkg-test--with-unit (root unit reload-calls) (drgnx-pkg-test--old-unit "/old/bin/emacs")
    (let (seen)
      (drgnx-pkg-service-unit-refresh
       nil (lambda (old new)
             ;; called with the file still as it was, nothing reloaded yet
             (setq seen (list old new (drgnx-pkg-test--slurp unit) reload-calls))))
      (should (equal (nth 0 seen) (car (drgnx-pkg--unit-exec-start (drgnx-pkg-test--old-unit "/old/bin/emacs")))))
      (should (equal (nth 1 seen) (car (drgnx-pkg--unit-exec-start (drgnx-pkg-service-unit)))))
      (should (equal (nth 2 seen) (drgnx-pkg-test--old-unit "/old/bin/emacs")))
      (should (= (nth 3 seen) 0))
      (should (string-search (nth 1 seen) (drgnx-pkg-test--slurp unit))))))

(ert-deftest drgnx-pkg/refresh-leaves-a-current-unit ()
  (drgnx-pkg-test--with-unit (root unit reload-calls) nil
    (make-directory (file-name-directory unit) t)
    (write-region (drgnx-pkg-service-unit) nil unit nil 'silent)
    (let ((before (drgnx-pkg-test--slurp unit)))
      (should (eq (plist-get (drgnx-pkg-service-unit-refresh) :status) 'current))
      (should (equal (drgnx-pkg-test--slurp unit) before))
      (should (= reload-calls 0)))))

(ert-deftest drgnx-pkg/refresh-current-through-a-symlink ()
  (drgnx-pkg-test--with-unit (root unit reload-calls) nil
    (let ((link (concat root "emacs-link")))
      (make-symbolic-link (expand-file-name invocation-name invocation-directory) link)
      (make-directory (file-name-directory unit) t)
      (write-region (drgnx-pkg-test--old-unit link) nil unit nil 'silent)
      (should (eq (plist-get (drgnx-pkg-service-unit-refresh) :status) 'current))
      (should (string-search link (drgnx-pkg-test--slurp unit)))
      (should (= reload-calls 0)))))

(ert-deftest drgnx-pkg/refresh-never-touches-a-foreign-unit ()
  (drgnx-pkg-test--with-unit (root unit reload-calls)
      "[Service]\nExecStart=/usr/bin/emacs --fg-daemon\n"
    (should (eq (plist-get (drgnx-pkg-service-unit-refresh) :status) 'foreign))
    (should (equal (drgnx-pkg-test--slurp unit) "[Service]\nExecStart=/usr/bin/emacs --fg-daemon\n"))
    (should (= reload-calls 0))))

(ert-deftest drgnx-pkg/refresh-without-a-unit ()
  (drgnx-pkg-test--with-unit (root unit reload-calls) nil
    (should (eq (plist-get (drgnx-pkg-service-unit-refresh) :status) 'none))
    (should-not (file-exists-p unit))))

(ert-deftest drgnx-pkg/unit-words-round-trip ()
  (dolist (s '("/a b/emacs" "/x/100%/emacs" "/x/$HOME/emacs" "/q\"x/emacs" "/plain/emacs"))
    (should (equal (drgnx-pkg--systemd-unword (drgnx-pkg--systemd-word s)) s))))

(ert-deftest drgnx-pkg/refresh-cli-lines ()
  (let ((new (expand-file-name invocation-name invocation-directory)))
    (drgnx-pkg-test--with-unit (root unit reload-calls) nil
      (should (equal (with-output-to-string (should (eql 0 (drgnx-pkg-cli-run '("service-unit" "--refresh")))))
                     (format "drgnx.service is not installed (%s): nothing to refresh\n" unit)))
      (make-directory (file-name-directory unit) t)
      (write-region (drgnx-pkg-test--old-unit "/old/bin/emacs") nil unit nil 'silent)
      (should (equal (with-output-to-string (should (eql 0 (drgnx-pkg-cli-run '("service-unit" "--refresh")))))
                     (format "drgnx.service ExecStart changes:\n- %s\n+ %s\ndrgnx.service ran /old/bin/emacs; now %s (systemd reloaded). Restart drgnx to use it: systemctl --user restart drgnx\n"
                             (car (drgnx-pkg--unit-exec-start (drgnx-pkg-test--old-unit "/old/bin/emacs")))
                             (car (drgnx-pkg--unit-exec-start (drgnx-pkg-service-unit))) new)))
      (should (equal (with-output-to-string (drgnx-pkg-cli-run '("service-unit" "--refresh")))
                     (format "drgnx.service runs %s: up to date\n" new)))
      (write-region "[Service]\nExecStart=/usr/bin/emacs --fg-daemon\n" nil unit nil 'silent)
      (should (equal (with-output-to-string (drgnx-pkg-cli-run '("service-unit" "--refresh")))
                     "drgnx.service's ExecStart is not drgnx's daemon line, left as it is: ExecStart=/usr/bin/emacs --fg-daemon\n"))
      (write-region (drgnx-pkg-test--old-unit "/old/bin/emacs") nil unit nil 'silent)
      (cl-letf (((symbol-function 'drgnx-pkg--systemctl-reload) (lambda () 'failed)))
        (should (string-search "(run: systemctl --user daemon-reload)"
                               (with-output-to-string (drgnx-pkg-cli-run '("service-unit" "--refresh")))))))))

(ert-deftest drgnx-pkg/no-temp-files-are-left-behind ()
  ;; M5-14: a write or a download that stops half way (an error, C-g) leaves no temp file; one left by a
  ;; killed run is removed by the next sync.
  (drgnx-pkg-test--with root
    (let ((user (drgnx-user-dir)) (cache (drgnx-package-cache-dir)))
      (cl-letf (((symbol-function 'pp-to-string) (lambda (&rest _) (error "Disk full"))))
        (should-error (drgnx-pkg-write-lock '((aa :version "1.0")))))
      (should-not (file-exists-p (drgnx-pkg-lock-file)))
      (should-not (directory-files user nil "tmp"))
      (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0")))))
        (let ((package-archives `(("fx" . ,arch)))
              (desc (package-desc-create :name 'fa :version '(1 0) :kind 'single :archive "fx")))
          (cl-letf (((symbol-function 'copy-file) (lambda (_from to &rest _) (write-region "half" nil to) (signal 'quit nil))))
            (should (eq (condition-case nil (drgnx-pkg--fetch desc nil) (quit 'quit)) 'quit))))
        (should-not (directory-files cache nil "\\.part\\'"))
        (write-region "half" nil (expand-file-name "fz-1.0.el.part" cache) nil 'silent)
        (write-region "half" nil (expand-file-name ".drgnx.lock.eld.tmp-x1Y2z3" user) nil 'silent)
        (write-region "keep" nil (expand-file-name ".tmp-not-drgnx" user) nil 'silent)
        (drgnx-pkg-test--want root 'fa)
        (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
        (should-not (directory-files cache nil "\\.part\\'"))
        (should (equal (directory-files user nil "tmp") '(".tmp-not-drgnx")))))))

(require 'url)

(defun drgnx-pkg-test--http-server (routes)
  "A loopback HTTP server: GET PATH answers (STATUS BODY) from the alist ROUTES (PATH STATUS BODY), else 404.
Returns the server process; its port is (process-contact SERVER :service)."
  (make-network-process
   :name "drgnx-pkg-test-http" :server t :host "127.0.0.1" :service t :family 'ipv4 :noquery t :coding 'binary
   :filter (lambda (proc string)
             (process-put proc :request (concat (process-get proc :request) string))
             (when (string-match "\\`GET \\([^ ]+\\) [^\r]*\r\n\\(?:.*\r\n\\)*?\r\n" (process-get proc :request))
               (pcase-let ((`(,status ,body) (or (cdr (assoc (match-string 1 (process-get proc :request)) routes))
                                                 '(404 "not here"))))
                 (process-send-string proc (format "HTTP/1.1 %d X\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                                                   status (string-bytes body)))
                 (process-send-string proc body))))))

(ert-deftest drgnx-pkg/http-downloads-keep-only-a-200 ()
  ;; M5-15: the status branch of drgnx-pkg--http-get against a real (loopback) server.
  (url-do-setup)
  (drgnx-pkg-test--with root
    (let* ((body (unibyte-string ?\( ?a 233 0 ?\) ?\n))      ; bytes, not text
           (server (drgnx-pkg-test--http-server `(("/fa-1.0.el" 200 ,body))))
           (base (format "http://127.0.0.1:%d/" (process-contact server :service)))
           (url-proxy-services nil) (url-show-status nil))
      (unwind-protect
          (progn
            (drgnx-pkg--http-get (concat base "fa-1.0.el") (concat root "ok"))
            (should (equal (drgnx-pkg-test--bytes (concat root "ok")) body))
            (should-error (drgnx-pkg--http-get (concat base "fb-1.0.el") (concat root "missing")))
            (should-not (file-exists-p (concat root "missing")))
            ;; through the download: an error, nothing in the cache, no .part
            (let ((package-archives `(("fx" . ,base))))
              (should-error (drgnx-pkg--fetch (package-desc-create :name 'fb :version '(1 0) :kind 'single :archive "fx") nil)
                            :type 'drgnx-pkg-error)
              (should (equal (drgnx-pkg--fetch (package-desc-create :name 'fa :version '(1 0) :kind 'single :archive "fx") nil)
                             (expand-file-name "fa-1.0.el" (drgnx-package-cache-dir))))
              (should (equal (directory-files (drgnx-package-cache-dir) nil "\\`[^.]") '("fa-1.0.el")))))
        (delete-process server)))))

;;;; M12a Task 12: the shipped lock (a new user's first sync)

(defun drgnx-pkg-test--entry (arch name version &optional requires)
  "The lock entry of the archive ARCH's file NAME-VERSION.el (REQUIRES: ((NAME VERSION)…))."
  (let ((file (format "%s-%s.el" name version)))
    (cons name (list :version version :archive "fx" :kind 'single :file file
                     :sha256 (secure-hash 'sha256 (drgnx-pkg-test--bytes (concat arch file)))
                     :requires requires :summary (format "fixture %s" name)))))

(defun drgnx-pkg-test--ship (entries)
  "ENTRIES as the shipped lock (the sandbox's, never the checkout's)."
  (drgnx-pkg-test--write (drgnx-pkg-shipped-lock-file) (list :version 1 :packages entries)))

(defun drgnx-pkg-test--versions ()
  (mapcar (lambda (e) (cons (car e) (plist-get (cdr e) :version))) (drgnx-pkg-read-lock)))

(defun drgnx-pkg-test--from-shipped-p ()
  "Does the user lock still carry the mark of the shipped lock it was copied from?"
  (plist-get (drgnx-pkg--read-file (drgnx-pkg-lock-file)) :from-shipped))

(ert-deftest drgnx-pkg/a-first-sync-uses-the-shipped-lock ()
  ;; The archive's newest fb needs the newest fa; the shipped lock pins the older pair, which installs as a pair.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch")
                                         '((fa "1.0") (fa "1.1") (fb "1.0" ((fa "1.0"))) (fb "1.1" ((fa "1.1")))))))
      (should (equal (drgnx-pkg-shipped-lock-file) (concat root "shipped.lock.eld")))
      (drgnx-pkg-test--ship (list (drgnx-pkg-test--entry arch 'fa "1.0")
                                  (drgnx-pkg-test--entry arch 'fb "1.0" '((fa "1.0")))))
      (drgnx-pkg-test--want root 'fb)
      (let ((shipped (drgnx-pkg-test--bytes (drgnx-pkg-shipped-lock-file)))
            (r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should (plist-get r :ok))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0")))
        (should (equal (drgnx-pkg-test--versions) '((fa . "1.0") (fb . "1.0"))))      ; the user lock, written
        (should (plist-get (alist-get 'fb (drgnx-pkg-read-lock)) :size))              ; the download's size
        (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-shipped-lock-file)) shipped))))))

(ert-deftest drgnx-pkg/archive-priorities-in-packages-eld ()
  ;; How the shipped lock prefers releases: a higher priority archive's version wins over a newer one elsewhere.
  (drgnx-pkg-test--with root
    (let ((rel (drgnx-pkg-test--archive (concat root "rel") '((fa "1.0"))))
          (snap (drgnx-pkg-test--archive (concat root "snap") '((fa "20261017.1200") (fz "20261017.1200")))))
      (drgnx-pkg-test--write (concat root "config/packages.eld")
                             `(:packages (fa fz) :archives (("rel" . ,rel) ("snap" . ,snap)) :archive-priorities (("rel" . 10))))
      (should (plist-get (drgnx-pkg-test--sync root) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fz-20261017.1200"))))))

(ert-deftest drgnx-pkg/a-user-lock-wins-over-the-shipped-one ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fa "1.1") (fa "1.2")))))
      (drgnx-pkg-test--ship (list (drgnx-pkg-test--entry arch 'fa "1.0")))
      (drgnx-pkg-write-lock (list (drgnx-pkg-test--entry arch 'fa "1.1")))
      (drgnx-pkg-test--want root 'fa)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.1")))
      (should (equal (drgnx-pkg-test--versions) '((fa . "1.1")))))))

(ert-deftest drgnx-pkg/lock-ship-covers-every-extra-module ()
  ;; Every module's packages, whatever is turned off (all presets); the maintainer's own packages stay out.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fd "1.0") (fa "1.0" ((fd "1.0"))) (fb "1.0") (pz "1.0"))))
          (mods (concat root "mods/extra/")))
      (make-directory mods t)
      (write-region "(drgnx-module-define 'extra/a :packages '(fa))\n(drgnx-module-define 'extra/b :packages '(fb))\n"
                    nil (concat mods "drgnx-x.el") nil 'silent)
      (drgnx-pkg-test--write (concat root "config/modules.eld") '(:version 1 :disabled (extra/b)))
      (drgnx-pkg-test--write (concat root "config/packages.eld") '(:packages (pz)))
      (should-error (drgnx-pkg-ship-lock (concat root "mods")) :type 'drgnx-pkg-error)   ; no lock yet
      (drgnx-pkg-sync :modules-dir (concat root "mods") :archives `(("fx" . ,arch)))       ; extra/b is off: no fb
      (let ((err (should-error (drgnx-pkg-ship-lock (concat root "mods")) :type 'drgnx-pkg-error)))
        (should (string-match-p "\\bfb\\b" (cadr err)))
        (should (string-match-p "full-ai" (cadr err))))
      (should-not (file-exists-p (drgnx-pkg-shipped-lock-file)))
      (drgnx-pkg-test--write (concat root "config/modules.eld") '(:version 1))
      (drgnx-config-reread 'modules)
      (drgnx-pkg-sync :modules-dir (concat root "mods") :archives `(("fx" . ,arch)))
      (drgnx-pkg-ship-lock (concat root "mods"))
      (let ((shipped (plist-get (drgnx-pkg--read-file (drgnx-pkg-shipped-lock-file)) :packages)))
        (should (equal (mapcar #'car shipped) '(fa fb fd)))                     ; the modules' and what they need
        (should (equal (cdr (assq 'fa shipped)) (cdr (assq 'fa (drgnx-pkg-read-lock))))))
      ;; the CLI checks drgnx's own modules, which this lock does not cover: refused, the shipped lock kept
      (let ((before (drgnx-pkg-test--bytes (drgnx-pkg-shipped-lock-file))))
        (should (eql (drgnx-pkg-cli-run '("lock" "--ship")) 1))
        (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-shipped-lock-file)) before))))))

(ert-deftest drgnx-pkg/an-interrupted-first-sync-leaves-no-half-state ()
  ;; The archive stops serving midway (fb's file): the packages directory as before; a re-run completes.
  (drgnx-pkg-test--with root
    (let* ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0"))))))
           (fb (drgnx-pkg-test--bytes (concat arch "fb-1.0.el"))))
      (drgnx-pkg-test--ship (list (drgnx-pkg-test--entry arch 'fa "1.0") (drgnx-pkg-test--entry arch 'fb "1.0" '((fa "1.0")))))
      (drgnx-pkg-test--want root 'fb)
      (delete-file (concat arch "fb-1.0.el"))
      (should-error (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :type 'drgnx-pkg-error)
      (should-not (file-exists-p (drgnx-elpa-dir)))
      (should-not (file-exists-p (expand-file-name "elpa.staging" (drgnx-data-dir))))
      (should-not (file-exists-p (expand-file-name "sync.lock" (drgnx-data-dir))))
      (should-not (drgnx-pkg-generations))
      (should (equal (drgnx-pkg-test--versions) '((fa . "1.0") (fb . "1.0"))))      ; the shipped lock, copied
      (should (drgnx-pkg-test--from-shipped-p))                                       ; still marked as the shipped one
      (let ((coding-system-for-write 'binary)) (write-region fb nil (concat arch "fb-1.0.el") nil 'silent))
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0"))))))

;;;; Task 12 review fixes: a soft first sync, --seed, requirements beyond the lock, an integral shipped lock

(defun drgnx-pkg-test--stale-fa (root)
  "The archive fx after fa 1.0 was replaced by 1.1 (fb 1.0, fc 1.0 and fd 1.0 need fa 1.0; fe needs nothing), and
fy with a newer fa 2.0.  Returns (FX FY FA-1.0-ENTRY)."
  (let* ((fx (drgnx-pkg-test--archive (concat root "fx") '((fa "1.0"))))
         (old (drgnx-pkg-test--entry fx 'fa "1.0")))
    (drgnx-pkg-test--archive fx '((fa "1.1") (fb "1.0" ((fa "1.0"))) (fc "1.0" ((fa "1.0"))) (fd "1.0" ((fa "1.0"))) (fe "1.0")))
    (list fx (drgnx-pkg-test--archive (concat root "fy") '((fa "2.0"))) old)))

(ert-deftest drgnx-pkg/a-shipped-pin-nobody-serves-falls-back-on-the-first-sync ()
  ;; The shipped fa 1.0 is gone: its archive's current fa (1.1, not fy's newer 2.0) installs, with a warning.
  (drgnx-pkg-test--with root
    (pcase-let ((`(,fx ,fy ,old) (drgnx-pkg-test--stale-fa root)))
      (drgnx-pkg-test--ship (list old (drgnx-pkg-test--entry fx 'fb "1.0" '((fa "1.0")))))
      (drgnx-pkg-test--want root 'fb)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx) ("fy" . ,fy)))))
        (should (plist-get r :ok))
        (should-not (plist-get r :missing))
        (should (member "fa: shipped 1.0 no longer served; installed 1.1" (plist-get r :warnings))))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.1" "fb-1.0")))
      (should (equal (drgnx-pkg-test--versions) '((fa . "1.1") (fb . "1.0"))))
      (should-not (drgnx-pkg-test--from-shipped-p))                                   ; the first write drops the mark
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx) ("fy" . ,fy)))))   ; and the next sync is a plain one
        (should (plist-get r :ok))
        (should-not (plist-get r :warnings))))))

(ert-deftest drgnx-pkg/a-stale-shared-dependency-does-not-take-its-dependents-along ()
  (drgnx-pkg-test--with root
    (pcase-let ((`(,fx ,_ ,old) (drgnx-pkg-test--stale-fa root)))
      (drgnx-pkg-test--ship (cons old (mapcar (lambda (n) (drgnx-pkg-test--entry fx n "1.0" '((fa "1.0")))) '(fb fc fd))))
      (drgnx-pkg-test--want root 'fb 'fc 'fd 'fe)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx)))))
        (should (plist-get r :ok))
        (should (equal (seq-filter (lambda (w) (string-prefix-p "fa:" w)) (plist-get r :warnings))
                       '("fa: shipped 1.0 no longer served; installed 1.1"))))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.1" "fb-1.0" "fc-1.0" "fd-1.0" "fe-1.0"))))))

(ert-deftest drgnx-pkg/a-users-own-lock-keeps-its-missing-pins ()
  ;; The same stale pin in a lock of the user's own (not the shipped one): reported, never replaced.
  (drgnx-pkg-test--with root
    (pcase-let ((`(,fx ,_ ,old) (drgnx-pkg-test--stale-fa root)))
      (drgnx-pkg-write-lock (list old (drgnx-pkg-test--entry fx 'fb "1.0" '((fa "1.0")))))
      (drgnx-pkg-test--want root 'fb)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx)))))
        (should-not (plist-get r :ok))
        (should (equal (sort (mapcar #'car (plist-get r :missing)) (lambda (a b) (string< a b))) '(fa fb))))
      (should (equal (drgnx-pkg-test--versions) '((fa . "1.0") (fb . "1.0")))))))

(ert-deftest drgnx-pkg/a-seeded-first-sync-keeps-the-seeded-versions ()
  ;; --seed brings another Emacs's packages: they are the user's choice, not the shipped lock's to replace.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.1")))))
      (drgnx-pkg-test--want root 'fa)
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "other") process-environment)))
        (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))))
      (delete-file (drgnx-pkg-lock-file))
      (drgnx-pkg-test--archive arch '((fa "1.0") (fa "1.1")))
      (drgnx-pkg-test--ship (list (drgnx-pkg-test--entry arch 'fa "1.0")))
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)) :seed (concat root "other/elpa")) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.1")))
      (should (equal (drgnx-pkg-test--versions) '((fa . "1.1")))))))

(ert-deftest drgnx-pkg/a-requirement-the-lock-lacks-is-installed ()
  ;; fb's entry requires fq, which the lock does not have: package.el resolves it (installed first).
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fq "1.0") (fb "1.0" ((fq "1.0")))))))
      (drgnx-pkg-test--ship (list (drgnx-pkg-test--entry arch 'fb "1.0" '((fq "1.0")))))
      (drgnx-pkg-test--want root 'fb)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fb-1.0" "fq-1.0"))))))

(ert-deftest drgnx-pkg/a-locked-package-a-built-in-satisfies-is-not-installed ()
  ;; fb needs seq 2.0, which this Emacs has built in: the lock's seq 99.0 is not forced on it.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((seq "99.0") (fb "1.0" ((seq "2.0")))))))
      (should (package-built-in-p 'seq '(2 0)))
      (drgnx-pkg-test--ship (list (drgnx-pkg-test--entry arch 'seq "99.0")
                                  (drgnx-pkg-test--entry arch 'fb "1.0" '((seq "2.0")))))
      (drgnx-pkg-test--want root 'fb)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fb-1.0"))))))

(ert-deftest drgnx-pkg/lock-ship-refuses-entries-without-a-hash-or-commit ()
  ;; A new user would install them unchecked.
  (drgnx-pkg-test--with root
    (let ((mods (concat root "mods/extra/")))
      (make-directory mods t)
      (write-region "(drgnx-module-define 'extra/a :packages '(fa gp fz))\n" nil (concat mods "drgnx-x.el") nil 'silent)
      (drgnx-pkg-write-lock '((fa :version "1.0" :archive nil :kind tar :file nil :sha256 nil)          ; seeded
                              (gp :kind git :url "https://example.invalid/gp" :version "0.1")         ; no commit
                              (fz :version "1.0" :archive "fx" :kind single :file "fz-1.0.el" :sha256 "ab")))
      (let ((err (should-error (drgnx-pkg-ship-lock (concat root "mods")) :type 'drgnx-pkg-error)))
        (should (string-match-p "\\bfa\\b" (cadr err)))
        (should (string-match-p "\\bgp\\b" (cadr err)))
        (should-not (string-match-p "\\bfz\\b" (cadr err))))
      (should-not (file-exists-p (drgnx-pkg-shipped-lock-file))))))

;;;; Deferred pass B: packages

(ert-deftest drgnx-pkg/compat-version-files-are-not-native-compiled ()
  ;; M10-13: compat-29.el etc. need their siblings at compile time and load only on an old Emacs: skipped
  ;; like -pkg/-autoloads, so a sync does not warn about them.
  (unless (and (fboundp 'native-comp-available-p) (native-comp-available-p))
    ;; the step binds `native-comp-eln-load-path', which an Emacs without it lacks (a sync never runs the step there)
    (ert-skip "needs an Emacs with native compilation (Homebrew's has none)"))
  (drgnx-pkg-test--with root
    (let ((dir (concat root "compat-1.0/")) (compiled nil) (drgnx-pkg-native-compile t) (drgnx-pkg--warnings nil))
      (make-directory dir t)
      ;; compat-27/29 are never loaded here (compat loads compat-NN only on an Emacs older than NN); compat-99 could be
      (dolist (f '("compat.el" "compat-27.el" "compat-29.el" "compat-99.el" "compat-macs.el"))
        (write-region "" nil (concat dir f) nil 'silent))
      (cl-letf (((symbol-function 'native-compile)
                 (lambda (f &rest _)
                   (push (file-name-nondirectory f) compiled)
                   (when (string-match-p "compat-2" f) (error "needs its siblings")))))
        (drgnx-pkg--native-compile (list dir)))
      (should (equal (sort compiled #'string<) '("compat-99.el" "compat-macs.el" "compat.el")))
      (should-not drgnx-pkg--warnings))))

(ert-deftest drgnx-pkg/soft-pin-fallback-keeps-newer-versions ()
  ;; M12a-55: the dropped pin's archive offers fa 1.0 only; fb needs fa 2.0, which another archive has.  The entry
  ;; archive's desc goes first, it does not replace the others: fb installs, it is not MISSING.
  (drgnx-pkg-test--with root
    (let* ((fx (drgnx-pkg-test--archive (concat root "fx") '((fa "1.0") (fb "1.0" ((fa "2.0"))))))
           (fy (drgnx-pkg-test--archive (concat root "fy") '((fa "2.0")))))
      (drgnx-pkg-test--ship (list (drgnx-pkg-test--entry fx 'fa "1.0") (drgnx-pkg-test--entry fx 'fb "1.0" '((fa "2.0")))))
      (drgnx-pkg-test--want root 'fb)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx) ("fy" . ,fy)))))
        (should (plist-get r :ok))
        (should-not (plist-get r :missing)))
      (should (equal (drgnx-pkg-test--installed) '("fa-2.0" "fb-1.0"))))))

(ert-deftest drgnx-pkg/two-dropped-pins-re-plan-twice ()
  ;; M12a-56: dropping fc's pin (gone; fc 1.1 needs fa 2.0) makes fa's pin 1.0 too old: a second round drops it too.
  (drgnx-pkg-test--with root
    (let* ((fx (drgnx-pkg-test--archive (concat root "fx") '((fa "1.0"))))
           (old-fa (drgnx-pkg-test--entry fx 'fa "1.0"))
           (fy (drgnx-pkg-test--archive (concat root "fy") '((fa "2.0")))))
      (drgnx-pkg-test--archive fx '((fa "1.0") (fc "1.0" ((fa "1.0")))))
      (let ((old-fc (drgnx-pkg-test--entry fx 'fc "1.0" '((fa "1.0")))))
        (drgnx-pkg-test--archive fx '((fa "1.0") (fc "1.1" ((fa "2.0")))))
        (drgnx-pkg-test--ship (list old-fa old-fc)))
      (drgnx-pkg-test--want root 'fc)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx) ("fy" . ,fy)))))
        (should (plist-get r :ok))
        (should-not (plist-get r :missing))
        (should (member "fc: shipped 1.0 no longer served; installed 1.1" (plist-get r :warnings)))
        (should (member "fa: shipped 1.0 is older than 2.0 needs; installed 2.0" (plist-get r :warnings))))
      (should (equal (drgnx-pkg-test--installed) '("fa-2.0" "fc-1.1"))))))

(ert-deftest drgnx-pkg/sync-prune-removes-what-left-the-manifest ()
  ;; M5-5: a plain sync keeps a package that left the manifest; `sync --prune' removes it (and only it, not what
  ;; the manifest still requires), says so, and the generation before keeps the rollback.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0"))) (fc "1.0")))))
      (drgnx-pkg-test--want root 'fb 'fc)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0" "fc-1.0")))
      (drgnx-pkg-test--want root 'fb)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))   ; plain: nothing removed
        (should (plist-get r :ok))
        (should-not (plist-get r :pruned)))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0" "fc-1.0")))
      ;; installed by hand after the last generation: only the "before prune" generation has it
      (let ((hand (expand-file-name "fh-1.0/" (drgnx-elpa-dir))))
        (make-directory hand t)
        (write-region "(define-package \"fh\" \"1.0\" \"by hand\" nil)\n" nil (concat hand "fh-pkg.el") nil 'silent)
        (write-region "(provide 'fh)\n" nil (concat hand "fh.el") nil 'silent))
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)) :prune t)))
        (should (plist-get r :ok))
        (should (equal (plist-get r :pruned) '(fc fh)))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0")))
        (should-not (assq 'fc (drgnx-pkg-read-lock)))
        (let ((out (with-output-to-string (drgnx-pkg--report r))))
          (should (string-match-p "^pruned: fc fh$" out))
          (should (string-match-p "restart drgnx" out))))                   ; a daemon still holds their autoloads
      (should (equal (plist-get (cdr (nth 1 (drgnx-pkg-generations))) :note) "before prune"))
      (drgnx-pkg-rollback)                                    ; no N: the generation before the current one
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0" "fc-1.0" "fh-1.0"))))))

(ert-deftest drgnx-pkg/sync-prune-dry-run-lists-and-removes-nothing ()
  ;; Review I3: `--prune --dry-run' says what would go.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0"))) (fc "1.0")))))
      (drgnx-pkg-test--want root 'fb 'fc)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (drgnx-pkg-test--want root 'fb)
      (make-directory (concat root "mods") t)
      (should (equal (drgnx-pkg-prune-candidates (concat root "mods")) '(fc)))
      (let ((gens (drgnx-pkg-generations)) (drgnx-dir (concat root "fake-checkout/")))   ; the CLI reads its modules/
        (make-directory (concat drgnx-dir "modules") t)
        (should (equal (with-output-to-string (should (eql (drgnx-pkg-cli-run '("sync" "--prune" "--dry-run")) 0)))
                       "would prune: fc\n"))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0" "fc-1.0")))
        (should (equal (drgnx-pkg-generations) gens))
        (with-output-to-string (should (eql (drgnx-pkg-cli-run '("sync" "--dry-run")) 1)))))))   ; --dry-run needs --prune

(ert-deftest drgnx-pkg/sync-prune-keeps-what-use-package-ensure-asked-for ()
  ;; C1: a want recorded by :ensure (or an external module) stays in the manifest after the sync that installed it,
  ;; so a later --prune does not remove it.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fz "1.0")))))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-ensure 'fz '(t))
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fz-1.0")))
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)) :prune t)))
        (should (plist-get r :ok))
        (should-not (plist-get r :pruned)))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fz-1.0"))))))

(ert-deftest drgnx-pkg/sync-prune-removes-nothing-while-something-is-missing ()
  ;; A sync that could not install everything prunes nothing.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fc "1.0")))))
      (drgnx-pkg-test--want root 'fa 'fc)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (drgnx-pkg-test--want root 'fa 'fnone)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)) :prune t)))
        (should-not (plist-get r :ok))
        (should-not (plist-get r :pruned)))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fc-1.0"))))))

(ert-deftest drgnx-pkg/the-cli-reads-sync-prune ()
  (let (calls)
    (cl-letf (((symbol-function 'drgnx-pkg-sync) (lambda (&rest a) (push a calls) '(:ok t))))
      (with-output-to-string (should (eql (drgnx-pkg-cli-run '("sync" "--prune")) 0)))
      (should (equal (car calls) '(:prune t))))))

(ert-deftest drgnx-pkg/the-service-unit-goes-through-the-file-layer ()
  (drgnx-pkg-test--with root
    (let* ((dir (concat root "units/more")) (file (concat dir "/drgnx.service"))
           (calls nil) (orig (symbol-function 'drgnx-file-write-text)))
      (cl-letf (((symbol-function 'drgnx-file-write-text)
                 (lambda (f text &rest args) (push f calls) (apply orig f text args))))
        (let ((unit (drgnx-pkg-service-unit dir)))
          (should (equal calls (list file)))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) unit))))
      (should (equal (directory-files dir nil "\\`[^.]\\|\\`\\.[^.]") '("drgnx.service"))))))


;;; pkg-test.el ends here
