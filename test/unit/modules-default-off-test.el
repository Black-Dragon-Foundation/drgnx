;;; modules-default-off-test.el --- batch tests: modules that are off until chosen -*- lexical-binding: t -*-
;; Everything in temp dirs: a temp configuration and state dir, a temp modules dir; never the user's.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
(require 'drgnx-modules)
(require 'drgnx-pkg)

(defvar drgnx-modules-default-off-test--ran nil "Modules whose setup ran.")

(defmacro drgnx-modules-default-off-test--with (root &rest body)
  "BODY with ROOT a temp dir holding config/, state/ and mods/ (two module files: test/off, test/on)."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-default-off" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "XDG_STATE_HOME=" ,root "state"))
                                       process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil)
          (drgnx-settings-apply--entries nil)
          (drgnx-modules-default-off-test--ran nil))
     (make-directory (concat ,root "config") t)
     (make-directory (concat ,root "mods/test") t)
     (write-region "(drgnx-module-define 'test/off :default 'off :packages '(pkg-off) :setup #'ignore)\n"
                   nil (concat ,root "mods/test/drgnx-off.el") nil 'silent)
     (write-region "(drgnx-module-define 'test/on :packages '(pkg-on) :setup #'ignore)\n"
                   nil (concat ,root "mods/test/drgnx-on.el") nil 'silent)
     (drgnx-test-areas-reset)
     (unwind-protect (progn ,@body)
       (drgnx-test-areas-reset)
       (delete-directory ,root t))))

(defun drgnx-modules-default-off-test--define ()
  "Define test/off (default off) and test/on, whose setups are recorded, in the table."
  (drgnx-module-define 'test/off :default 'off
                       :setup (lambda () (push 'test/off drgnx-modules-default-off-test--ran)))
  (drgnx-module-define 'test/on
                       :setup (lambda () (push 'test/on drgnx-modules-default-off-test--ran))))

(defun drgnx-modules-default-off-test--status (name)
  (plist-get (alist-get name (drgnx-modules-report)) :status))

(ert-deftest drgnx-modules-default-off/manifest-skips-it-until-enabled ()
  (drgnx-modules-default-off-test--with root
    (let ((dir (concat root "mods")))
      (drgnx-modules-load-directory dir)
      (should (eq (plist-get (alist-get 'test/off drgnx-modules--table) :default) 'off))
      (should (eq (plist-get (alist-get 'test/on drgnx-modules--table) :default) 'on))
      (should (equal (drgnx-pkg-manifest dir) '(pkg-on)))
      (drgnx-modules-set-enabled 'test/off t)
      (should (equal (drgnx-pkg-manifest dir) '(pkg-off pkg-on)))
      (drgnx-modules-set-enabled 'test/off nil)
      (should (equal (drgnx-pkg-manifest dir) '(pkg-on))))))

(ert-deftest drgnx-modules-default-off/specs-are-read-never-run ()
  (drgnx-modules-default-off-test--with root
    (should (equal (drgnx-pkg--module-specs (concat root "mods"))
                   '((test/off :packages (pkg-off) :default off) (test/on :packages (pkg-on) :default on))))
    (should (equal (drgnx-pkg--module-packages (concat root "mods"))
                   '((test/off pkg-off) (test/on pkg-on))))
    (should-not drgnx-modules--table)))

(ert-deftest drgnx-modules-default-off/it-does-not-run-until-enabled ()
  (drgnx-modules-default-off-test--with root
    (drgnx-modules-default-off-test--define)
    (should (drgnx-module-default-off-p 'test/off))
    (should-not (drgnx-module-default-off-p 'test/on))
    (should-not (drgnx-module-default-off-p 'test/unknown))
    (drgnx-modules-run 'startup)
    (should (eq (drgnx-modules-default-off-test--status 'test/off) 'disabled))
    (should (eq (drgnx-modules-default-off-test--status 'test/on) 'ok))
    (drgnx-modules-set-enabled 'test/off t)
    (setq drgnx-modules--report nil)
    (drgnx-modules-run 'startup)
    (should (eq (drgnx-modules-default-off-test--status 'test/off) 'ok))))

(ert-deftest drgnx-modules-default-off/disabled-wins-over-enabled ()
  (drgnx-modules-default-off-test--with root
    (drgnx-modules-default-off-test--define)
    (drgnx-modules-update-state (lambda (_) '(:disabled (test/off) :enabled (test/off))))
    (should (drgnx-module-disabled-p 'test/off))
    (drgnx-modules-run 'startup)
    (should (eq (drgnx-modules-default-off-test--status 'test/off) 'disabled))
    (should (equal (drgnx-pkg-manifest (concat root "mods")) '(pkg-on)))))

(ert-deftest drgnx-modules-default-off/an-explicit-default-argument-wins ()
  (drgnx-modules-default-off-test--with root
    (should-not (drgnx-module-disabled-p 'test/x))
    (should (drgnx-module-disabled-p 'test/x 'off))
    (should-not (drgnx-module-disabled-p 'test/x 'on))
    (drgnx-modules-update-state (lambda (_) '(:enabled (test/x))))
    (should-not (drgnx-module-disabled-p 'test/x 'off))))

(ert-deftest drgnx-modules-default-off/modules-list-says-off-until-chosen ()
  (drgnx-modules-default-off-test--with root
    (drgnx-modules-default-off-test--define)
    (cl-flet ((next-start (name) (aref (cadr (assq name (drgnx-modules--entries))) 4)))
      (should (equal (next-start 'test/off) "off (chosen by the key profile)"))
      (should (equal (next-start 'test/on) "on"))
      (drgnx-modules-toggle 'test/off)                       ; flips :enabled, not :disabled
      (should (memq 'test/off (plist-get (drgnx-modules-read-state) :enabled)))
      (should-not (plist-get (drgnx-modules-read-state) :disabled))
      (should (equal (next-start 'test/off) "on"))
      (drgnx-modules-toggle 'test/off)
      (should-not (plist-get (drgnx-modules-read-state) :enabled))
      (should-not (plist-get (drgnx-modules-read-state) :disabled))
      (should (equal (next-start 'test/off) "off (chosen by the key profile)"))
      ;; a default-on module still toggles :disabled
      (drgnx-modules-toggle 'test/on)
      (should (memq 'test/on (plist-get (drgnx-modules-read-state) :disabled)))
      (should (equal (next-start 'test/on) "off")))))           ; never ran: "off at next start" is for a running one

(ert-deftest drgnx-modules-default-off/set-enabled-returns-the-state ()
  (drgnx-modules-default-off-test--with root
    (drgnx-modules-default-off-test--define)
    (drgnx-modules-update-state (lambda (_) '(:disabled (test/off test/on))))
    (let ((s (drgnx-modules-set-enabled 'test/off t)))
      (should (equal (plist-get s :enabled) '(test/off)))
      (should (equal (plist-get s :disabled) '(test/on))))   ; removed from :disabled, the other kept
    ;; a default-on module: nil adds it to :disabled
    (let ((s (drgnx-modules-set-enabled 'test/on nil)))
      (should (memq 'test/on (plist-get s :disabled)))
      (should (equal (plist-get s :enabled) '(test/off))))
    (should (drgnx-module-disabled-p 'test/on))
    ;; and ON takes it out of :disabled without adding it to :enabled (it is on by default)
    (let ((s (drgnx-modules-set-enabled 'test/on t)))
      (should-not (memq 'test/on (plist-get s :disabled)))
      (should (equal (plist-get s :enabled) '(test/off))))
    (should-not (drgnx-module-disabled-p 'test/on))))

(ert-deftest drgnx-modules-default-off/ship-lock-still-wants-it ()
  (drgnx-modules-default-off-test--with root
    (write-region (prin1-to-string '(:version 1 :packages ((pkg-on :version "1.0"))))
                  nil (concat root "config/drgnx.lock.eld") nil 'silent)
    (let ((err (should-error (drgnx-pkg-ship-lock (concat root "mods")) :type 'drgnx-pkg-error)))
      (should (string-match-p "\\bpkg-off\\b" (cadr err))))))

;; With FAILS always true bisect tries every candidate on, then every candidate off, and stops: the
;; second try's :disabled list is the candidates.
(defun drgnx-modules-default-off-test--bisect-candidates (root)
  (let (seen)
    (drgnx-pkg-bisect (lambda (cfg)
                        (push (drgnx-test-areas-file-value (expand-file-name "settings.el" cfg) 'drgnx-modules-disabled)
                              seen)
                        t)
                      :modules-dir (concat root "mods"))
    (sort (copy-sequence (car seen)) #'string<)))

(ert-deftest drgnx-modules-default-off/bisect-leaves-it-out ()
  (drgnx-modules-default-off-test--with root
    (drgnx-modules-load-directory (concat root "mods"))      ; set-enabled needs the module defined
    (should (equal (drgnx-modules-default-off-test--bisect-candidates root) '(test/on)))
    (drgnx-modules-set-enabled 'test/off t)
    (should (equal (drgnx-modules-default-off-test--bisect-candidates root) '(test/off test/on)))))

(ert-deftest drgnx-modules-default-off/the-enabled-list-reads-and-a-write-leaves-it-absent ()
  (drgnx-modules-default-off-test--with root
    (drgnx-test-areas-put-entries '((drgnx-modules-disabled . (a/b))))
    (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(a/b)))
    (should-not (plist-get (drgnx-modules-read-state) :enabled))
    (drgnx-modules-toggle 'c/d)                            ; a write: no :enabled entry is made
    (should-not (drgnx-settings-area-has-entry-p 'drgnx-modules-enabled))
    ;; the enabled list reads, validates like the disabled one, and is written back unchanged
    (drgnx-test-areas-reset)                               ; a new process: nothing applied yet
    (setq drgnx-settings-apply--entries nil)
    (drgnx-test-areas-put-entries '((drgnx-modules-enabled . (test/off))))
    (should (equal (plist-get (drgnx-modules-read-state) :enabled) '(test/off)))
    (drgnx-test-areas-put-entries '((drgnx-modules-enabled . ("oops"))))
    (should-not (plist-get (drgnx-modules-read-state) :enabled))))

(provide 'modules-default-off-test)
;;; modules-default-off-test.el ends here
