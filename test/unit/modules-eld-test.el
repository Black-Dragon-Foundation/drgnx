;;; modules-eld-test.el --- batch tests: the module choices in settings.el, with the lock -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-areas' (config and state folders in a fresh temp root, settings.el not applied
;; in this process).  The concurrency tests start child `emacs --batch' processes (the runner's environment) and wait
;; for them under a 30 s bound.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
(require 'drgnx-modules)
(require 'drgnx-modal-choose)
(require 'drgnx-onboard)

(defmacro drgnx-modules-eld-test--with (&rest body)
  "BODY under `drgnx-test-with-areas', with fresh module tables."
  (declare (indent 0))
  `(drgnx-test-with-areas
     (let ((drgnx-modules--table nil) (drgnx-modules--report nil))
       ,@body)))

(defun drgnx-modules-eld-test--text () (drgnx-test-areas-text))

(defun drgnx-modules-eld-test--disabled ()
  "The disabled list settings.el holds, read fresh."
  (cdar (drgnx-settings-area-fresh '(drgnx-modules-disabled))))

(defconst drgnx-modules-eld-test--child-prefix "(setq drgnx-settings-file-lock-timeout 20)"
  "Run first in every child: the lock waits longer than the default second when two children write at once.")

(defun drgnx-modules-eld-test--children (forms)
  "Run each of FORMS (strings) in a child `emacs --batch' with this run's environment and load path; wait for all.
Fails the test unless every child exits 0."
  (let* ((at (+ (float-time) 2)) (bufs nil)
         (procs (mapcar
                 (lambda (form)
                   (let ((b (generate-new-buffer " *modules-eld-child*" t)))
                     (push b bufs)
                     (make-process
                      :name "modules-eld-child" :buffer b :noquery t
                      :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                     "--eval" (format "(setq load-path '%S load-prefer-newer t)" load-path)
                                     "--eval" "(require 'drgnx-modules)"
                                     "--eval" drgnx-modules-eld-test--child-prefix
                                     "--eval" (format "(progn (sleep-for (max 0 (- %f (float-time)))) %s)" at form)))))
                 forms)))
    (unwind-protect
        (progn
          (drgnx-test-wait (lambda () (not (cl-some #'process-live-p procs))) :secs 30 :what "the writer processes to end")
          (dolist (p procs) (should (not (process-live-p p))))
          (cl-loop for p in procs for b in (reverse bufs)
                   do (should (equal (list (process-exit-status p) (with-current-buffer b (buffer-string)))
                                     (list 0 (with-current-buffer b (buffer-string)))))))
      (mapc #'delete-process procs)
      (mapc #'kill-buffer bufs))))

;;;; The settings

(ert-deftest drgnx-modules-eld/the-settings-are-declared-for-the-modules-page ()
  (dolist (var '(drgnx-modules-disabled drgnx-modules-enabled drgnx-modules-flags drgnx-modules-external))
    (let ((meta (drgnx-setting-meta var)))
      (should (eq (plist-get meta :apply) 'drgnx-modules--settings-apply))
      (should (eq (plist-get meta :workspace) 'never))      ; a workspace never turns modules on or loads code
      (should (eq (plist-get meta :agents) 'never))
      (should (eq (plist-get meta :scope) 'global))
      (should-not (default-value var)))))

(ert-deftest drgnx-modules-eld/an-absent-file-gives-the-default-and-reading-writes-nothing ()
  (drgnx-modules-eld-test--with
    (should (equal (drgnx-modules-read-state) '(:disabled nil :enabled nil :flags nil :external nil)))
    (should-not (drgnx-modules-eld-test--text))))

(ert-deftest drgnx-modules-eld/the-old-file-is-still-defined-for-the-migration ()
  (let ((def (gethash 'modules drgnx-config--defs)))
    (should (equal (plist-get def :file) "modules.eld"))
    (should (eql (plist-get def :version) 2))))

;;;; Writers

(ert-deftest drgnx-modules-eld/two-emacsen-each-turn-off-100-modules-and-all-200-stay ()
  (drgnx-modules-eld-test--with
    (let ((form (lambda (tag)
                  (format "(dotimes (i 100) (drgnx-modules-toggle (intern (format \"%s/m%%d\" i))))" tag))))
      (drgnx-modules-eld-test--children (list (funcall form "a") (funcall form "b")))
      (let ((off (drgnx-modules-eld-test--disabled)))
        (should (= (length off) 200))
        (should (= (length (delete-dups (copy-sequence off))) 200))))))

(ert-deftest drgnx-modules-eld/enabled-survives-a-turn-off ()
  (drgnx-modules-eld-test--with
    (drgnx-module-define 'test/off :doc "off until chosen" :default 'off :setup #'ignore)
    (drgnx-module-define 'test/on :doc "on" :setup #'ignore)
    (drgnx-test-areas-put ";; mine\n(drgnx-settings\n :version 1\n (drgnx-modules-disabled nil)\n ;; chosen\n (drgnx-modules-enabled (test/off)))\n")
    (drgnx-modules-toggle 'test/on)
    (should (equal (drgnx-modules-eld-test--text)
                   ";; mine\n(drgnx-settings\n :version 1\n (drgnx-modules-disabled (test/on))\n ;; chosen\n (drgnx-modules-enabled (test/off)))\n"))
    (should (equal (plist-get (drgnx-modules-read-state) :enabled) '(test/off)))
    (should (drgnx-module-disabled-p 'test/on))
    (should-not (drgnx-module-disabled-p 'test/off))))

(ert-deftest drgnx-modules-eld/a-newer-settings-el-is-read-only-and-toggles-refuse ()
  (drgnx-modules-eld-test--with
    (drgnx-module-define 'test/off :doc "off until chosen" :default 'off :setup #'ignore)
    (let ((newer "(drgnx-settings :version 99 (drgnx-modules-disabled (a/b)))\n"))
      (drgnx-test-areas-put newer)
      (should-error (drgnx-modules-toggle 'c/d) :type 'drgnx-settings-refused)
      (should-error (drgnx-modules-toggle 'test/off) :type 'drgnx-settings-refused)
      (should-error (drgnx-modules-set-enabled 'test/off t) :type 'drgnx-settings-refused)
      (should (equal (drgnx-modules-eld-test--text) newer)))))

(ert-deftest drgnx-modules-eld/a-malformed-external-entry-is-a-failed-module-not-a-file-mistake ()
  (drgnx-modules-eld-test--with
    (drgnx-test-areas-put-entries '((drgnx-modules-external . ((:name nopath :features (a))))))
    (drgnx-modules-load-external)
    (should (eq (plist-get (alist-get 'external/nopath drgnx-modules--report) :status) 'failed))
    (drgnx-modules-toggle 'test/a)
    (should (equal (plist-get (drgnx-modules-read-state) :external) '((:name nopath :features (a)))))))

(ert-deftest drgnx-modules-eld/onboarding-preset-and-the-daemon-both-keep-their-change ()
  (drgnx-modules-eld-test--with
    (drgnx-test-areas-put-entries '((drgnx-modules-disabled . (ui/zen))))
    (drgnx-modules-eld-test--children '("(progn (require 'drgnx-onboard) (drgnx-onboard-apply-preset 'minimal))"))
    (drgnx-modules-toggle 'ui/look)                         ; its write starts from the file, not from its copy
    (let ((off (drgnx-modules-eld-test--disabled)))
      (should (memq 'ui/zen off))
      (should (memq 'ui/look off))
      (should (cl-some (lambda (m) (string-prefix-p "extra/" (symbol-name m))) off)))))

(ert-deftest drgnx-modules-eld/the-preset-and-a-toggling-daemon-at-once-lose-nothing ()
  (drgnx-modules-eld-test--with
    (drgnx-modules-eld-test--children
     (list "(progn (require 'drgnx-onboard) (dotimes (_ 5) (drgnx-onboard-apply-preset 'minimal)))"
           "(dotimes (i 40) (drgnx-modules-toggle (intern (format \"d/m%d\" i))))"))
    (let ((off (drgnx-modules-eld-test--disabled)))
      (should (= (length (seq-filter (lambda (m) (string-prefix-p "d/" (symbol-name m))) off)) 40))
      (should (cl-some (lambda (m) (string-prefix-p "extra/" (symbol-name m))) off)))))

(ert-deftest drgnx-modules-eld/the-theme-write-keeps-the-other-entries ()
  (drgnx-modules-eld-test--with
    (drgnx-test-areas-put "(drgnx-settings\n :version 1\n ;; mine\n (drgnx-modules-disabled (a/b)))\n")
    (drgnx-modules-update-state (lambda (s) (plist-put (copy-sequence s) :theme 'tango)))
    (should (eq (plist-get (drgnx-modules-read-state) :theme) 'tango))
    (should (string-search ";; mine\n (drgnx-modules-disabled (a/b))" (drgnx-modules-eld-test--text)))
    (should (string-search "(drgnx-look-theme tango)" (drgnx-modules-eld-test--text)))))

;;;; A file with a mistake keeps its bytes through every writer

(ert-deftest drgnx-modules-eld/a-file-with-a-mistake-keeps-its-bytes-through-every-writer ()
  (drgnx-modules-eld-test--with
    (drgnx-module-define 'test/off :doc "off until chosen" :default 'off :setup #'ignore)
    (dolist (bad '("(drgnx-settings :version 1 (drgnx-modules-disabled (a/b)\n ;; half typed\n"       ; unreadable
                   "(drgnx-settings :version 1 (drgnx-modules-disabled \"not a list\"))\n"            ; fails its schema
                   "(drgnx-settings :version 1 (drgnx-modules-flags ((ui/popups . 3))))\n"))
      (drgnx-test-areas-put bad)
      (dolist (writer (list (lambda () (drgnx-modules-toggle 'c/d))
                            (lambda () (drgnx-modules-toggle 'test/off))
                            (lambda () (drgnx-modules-set-enabled 'test/off t))
                            (lambda () (drgnx-modules-set-enabled 'c/d nil))
                            (lambda () (drgnx-modal--set-enabled 'undefined/engine t))
                            (lambda () (drgnx-onboard-apply-preset 'minimal))
                            (lambda () (drgnx-modules-update-state (lambda (s) (plist-put (copy-sequence s) :theme 'tango))))))
        (should-error (funcall writer) :type 'user-error)
        (should (equal (drgnx-modules-eld-test--text) bad))))))

(ert-deftest drgnx-modules-eld/the-onboarding-look-step-refuses-before-it-changes-anything ()
  (drgnx-modules-eld-test--with
    (let ((bad "(drgnx-settings :version 1 (drgnx-modules-disabled \"not a list\"))\n"))
      (drgnx-test-areas-put bad)
      (let ((r (drgnx-onboard-run :only '(look-and-keys) :non-interactive t :options '(:theme tango))))
        (should (eq (cadr (car r)) 'fail)))
      (should (equal (drgnx-modules-eld-test--text) bad)))))

(ert-deftest drgnx-modules-eld/the-color-theme-command-refuses-before-it-loads-a-theme ()
  (drgnx-modules-eld-test--with
    (load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)
    (let ((bad "(drgnx-settings :version 1 (drgnx-modules-disabled (a/b)\n") (themes custom-enabled-themes))
      (drgnx-test-areas-put bad)
      (should-error (drgnx-look-load-theme 'tango) :type 'drgnx-settings-refused)
      (should (equal custom-enabled-themes themes))
      (should (equal (drgnx-modules-eld-test--text) bad)))))

;;;; The list

(ert-deftest drgnx-modules-eld/the-list-shows-the-next-start-from-the-file ()
  (drgnx-modules-eld-test--with
    (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
    (drgnx-module-define 'test/b :doc "b" :default 'off :setup #'ignore)
    (let ((next (lambda (name) (aref (cadr (assq name (drgnx-modules--entries))) 4))))
      (should (equal (funcall next 'test/a) "on"))
      (should (equal (funcall next 'test/b) "off (chosen by the key profile)"))
      ;; another Emacs (or the user) wrote the file; this one has not looked again
      (drgnx-test-areas-put-entries '((drgnx-modules-disabled . (test/a)) (drgnx-modules-enabled . (test/b))))
      (should (equal (funcall next 'test/a) "off"))           ; never ran: "off at next start" is for a running one
      (should (equal (funcall next 'test/b) "on")))))

;;; modules-eld-test.el ends here
