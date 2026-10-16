;;; core-modules-test.el --- batch tests: the module system -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-modules)

(defmacro drgnx-test--fresh-modules (&rest body)
  `(let ((drgnx-modules--table nil) (drgnx-modules--report nil)) ,@body))

(ert-deftest drgnx-modules/define-and-run-by-stage ()
  (drgnx-test--fresh-modules
   (let (ran)
     (drgnx-module-define 'test/early :doc "early" :stage 'startup :setup (lambda () (push 'early ran)))
     (drgnx-module-define 'test/late :doc "late" :stage 'idle :setup (lambda () (push 'late ran)))
     (drgnx-modules-run 'startup)
     (should (equal ran '(early)))
     (drgnx-modules-run 'idle)
     (should (equal ran '(late early))))))

(ert-deftest drgnx-modules/errors-are-isolated-and-reported ()
  (drgnx-test--fresh-modules
   (let (ran)
     (drgnx-module-define 'test/broken :doc "b" :stage 'startup :setup (lambda () (error "kaputt")))
     (drgnx-module-define 'test/fine :doc "f" :stage 'startup :setup (lambda () (setq ran t)))
     (drgnx-modules-run 'startup)
     (should ran)
     (let ((broken (alist-get 'test/broken (drgnx-modules-report))))
       (should (string-search "kaputt" (plist-get broken :error)))
       (should (integerp (plist-get broken :ms))))
     (should (eq (plist-get (alist-get 'test/fine (drgnx-modules-report)) :error) nil)))))

(ert-deftest drgnx-modules/load-directory ()
  (drgnx-test--fresh-modules
   (let ((dir (make-temp-file "drgnx-mods" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "test" dir))
           (write-region "(drgnx-module-define 'test/from-file :doc \"x\" :stage 'startup :setup #'ignore)\n"
                         nil (expand-file-name "test/drgnx-from-file.el" dir))
           (write-region "(error \"does not load\")\n" nil (expand-file-name "test/drgnx-bad.el" dir))
           (drgnx-modules-load-directory dir)
           (should (assq 'test/from-file drgnx-modules--table))
           (should (string-search "does not load"
                                  (plist-get (alist-get 'test/drgnx-bad (drgnx-modules-report)) :error))))
       (delete-directory dir t)))))

(ert-deftest drgnx-modules/a-built-module-runs-compiled ()
  (let ((dir (make-temp-file "drgnx-modules" t)) (drgnx-modules--table nil) (drgnx-modules--report nil))
    (unwind-protect
        (let ((f (expand-file-name "drgnx-test-compiled.el" dir)))
          (with-temp-file f
            (insert ";;; -*- lexical-binding: t -*-\n(defun drgnx-test-compiled-fn () 1)\n"))
          (byte-compile-file f)
          (let ((load-prefer-newer t)) (drgnx-modules-load-directory dir))
          (should (byte-code-function-p (symbol-function 'drgnx-test-compiled-fn))))
      (delete-directory dir t))))

;;;; M4: the full module system

(defmacro drgnx-modules-test--with-config (&rest body)
  "BODY with an empty user config dir and state dir (never the user's)."
  `(let* ((cfg (make-temp-file "drgnx-cfg" t)) (st (make-temp-file "drgnx-st" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" cfg) (concat "XDG_STATE_HOME=" st))
                                       process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil))
     (unwind-protect (progn ,@body) (delete-directory cfg t) (delete-directory st t))))

(defun drgnx-modules-test--status (name) (plist-get (alist-get name (drgnx-modules-report)) :status))

(ert-deftest drgnx-modules/statuses ()
  (drgnx-modules-test--with-config
   (drgnx-module-define 'test/ok :doc "ok" :setup #'ignore)
   (drgnx-module-define 'test/needs-pkg :doc "p" :packages '(drgnx-no-such-package) :setup (lambda () (error "ran")))
   (drgnx-module-define 'test/needs-mod :doc "r" :requires '(test/needs-pkg) :setup (lambda () (error "ran")))
   (drgnx-module-define 'test/off :doc "d" :setup (lambda () (error "ran")))
   (drgnx-modules-write-state '(:version 1 :disabled (test/off)))
   (drgnx-modules-run 'startup)
   (should (eq (drgnx-modules-test--status 'test/ok) 'ok))
   (should (eq (drgnx-modules-test--status 'test/needs-pkg) 'missing-packages))
   (should (equal (plist-get (alist-get 'test/needs-pkg (drgnx-modules-report)) :missing) '(drgnx-no-such-package)))
   (should (eq (drgnx-modules-test--status 'test/needs-mod) 'missing-requires))
   (should (eq (drgnx-modules-test--status 'test/off) 'disabled))))

(ert-deftest drgnx-modules/the-new-stages-run-on-their-hooks ()
  (drgnx-modules-test--with-config
   (let (ran (drgnx-first-gui-frame-hook nil) (drgnx-first-file-hook nil) (drgnx-first-input-hook nil))
     (dolist (stage '(first-frame first-file first-input))
       (drgnx-module-define (intern (format "test/%s" stage)) :doc "s" :stage stage
                            :setup (let ((s stage)) (lambda () (push s ran)))))
     (drgnx-modules-start (make-temp-file "drgnx-empty" t))
     (run-hooks 'drgnx-first-file-hook)
     (should (equal ran '(first-file)))
     (run-hooks 'drgnx-first-gui-frame-hook 'drgnx-first-input-hook)
     (should (equal (sort ran #'string<) '(first-file first-frame first-input))))))

(ert-deftest drgnx-modules/flags-come-from-the-state ()
  (drgnx-modules-test--with-config
   (drgnx-modules-write-state '(:version 1 :flags ((ui/popups +childframe))))
   (should (drgnx-module-flag-p 'ui/popups '+childframe))
   (should-not (drgnx-module-flag-p 'ui/popups '+other))))

(ert-deftest drgnx-modules/old-and-broken-state-files ()
  (drgnx-modules-test--with-config
   ;; Version 0 was a bare list of disabled modules: migrated.
   (with-temp-file (expand-file-name "modules.eld" (drgnx-user-dir)) (prin1 '(lang/python ui/zen) (current-buffer)))
   (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(lang/python ui/zen)))
   (should (eql (plist-get (drgnx-modules-read-state) :version) 1))
   ;; Unreadable: defaults, a message, no error.
   (with-temp-file (expand-file-name "modules.eld" (drgnx-user-dir)) (insert "(:version 1 :disabled (oops"))
   (setq drgnx-modules--state nil)
   (should (equal (plist-get (drgnx-modules-read-state) :disabled) nil))))

(ert-deftest drgnx-modules/preferences-toggle-a-module ()
  (drgnx-modules-test--with-config
   (drgnx-module-define 'test/a :doc "A module" :setup #'ignore)
   (drgnx-modules-run 'startup)
   (drgnx-modules-toggle 'test/a)
   (should (memq 'test/a (plist-get (drgnx-modules-read-state) :disabled)))
   (with-current-buffer (drgnx-modules-list)
     (should (string-search "test/a" (buffer-string)))
     (should (string-search "off at next start" (buffer-string))))
   (drgnx-modules-toggle 'test/a)
   (should-not (memq 'test/a (plist-get (drgnx-modules-read-state) :disabled)))))

(ert-deftest drgnx-modules/the-doctor-reads-the-last-session ()
  (drgnx-modules-test--with-config
   (drgnx-module-define 'test/broken :doc "b" :setup (lambda () (error "kaputt")))
   (drgnx-module-define 'test/needs-pkg :doc "p" :packages '(drgnx-no-such-package) :setup #'ignore)
   (drgnx-modules-run 'startup)
   (drgnx-modules-write-report)
   (require 'drgnx-doctor)
   (let ((r (drgnx-doctor-check 'modules (drgnx-doctor-facts))))
     (should (eq (car r) 'fail))
     (should (string-search "test/broken" (nth 1 r))))))
