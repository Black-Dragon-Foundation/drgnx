;;; modules-eld-test.el --- batch tests: modules.eld on the config layer, with the lock -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config' (config and state folders in a fresh temp root).  The concurrency
;; tests start child `emacs --batch' processes (the runner's environment) and wait for them under a 30 s bound.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-modules)
(require 'drgnx-modal-choose)
(require 'drgnx-onboard)

(defmacro drgnx-modules-eld-test--with (&rest body)
  "BODY under `drgnx-test-with-config', with fresh module tables."
  (declare (indent 0))
  `(drgnx-test-with-config
     (let ((drgnx-modules--table nil) (drgnx-modules--report nil))
       ,@body)))

(defun drgnx-modules-eld-test--text () (drgnx-test-config-text 'modules))

(defun drgnx-modules-eld-test--disabled ()
  "The :disabled list of modules.eld read fresh."
  (plist-get (plist-get (drgnx-config-read 'modules) :data) :disabled))

(defun drgnx-modules-eld-test--backups ()
  (directory-files (file-name-directory (drgnx-config-file 'modules)) t "\\`modules\\.eld\\.bak-"))

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
                                     "--eval" (format "(progn (sleep-for (max 0 (- %f (float-time)))) %s)" at form)))))
                 forms))
         (deadline (+ (float-time) 30)))
    (unwind-protect
        (progn
          (while (and (cl-some #'process-live-p procs) (< (float-time) deadline)) (accept-process-output nil 0.05))
          (dolist (p procs) (should (not (process-live-p p))))
          (cl-loop for p in procs for b in (reverse bufs)
                   do (should (equal (list (process-exit-status p) (with-current-buffer b (buffer-string)))
                                     (list 0 (with-current-buffer b (buffer-string)))))))
      (mapc #'delete-process procs)
      (mapc #'kill-buffer bufs))))

;;;; The definition

(ert-deftest drgnx-modules-eld/the-definition ()
  (let ((def (gethash 'modules drgnx-config--defs)))
    (should (equal (plist-get def :file) "modules.eld"))
    (should (eq (plist-get def :dir) 'config))
    (should (eql (plist-get def :version) 2))
    (should (eq (plist-get def :reload) 'start))
    (should (eq (plist-get def :last-good) t))
    (should (equal (plist-get def :default) '(:disabled nil)))
    (should (equal (mapcar #'car (plist-get def :migrate)) '(0 1)))))

(ert-deftest drgnx-modules-eld/an-absent-file-gives-the-default-and-reading-writes-nothing ()
  (drgnx-modules-eld-test--with
    (should (equal (drgnx-modules-read-state) '(:disabled nil)))
    (should-not (drgnx-modules-eld-test--text))))

;;;; Writers

(ert-deftest drgnx-modules-eld/two-emacsen-each-turn-off-100-modules-and-all-200-stay ()
  (drgnx-modules-eld-test--with
    (let ((form (lambda (tag)
                  (format "(dotimes (i 100) (drgnx-modules-toggle (intern (format \"%s/m%%d\" i))))" tag))))
      (drgnx-modules-eld-test--children (list (funcall form "a") (funcall form "b")))
      (let ((r (drgnx-config-read 'modules)))
        (should (eq (plist-get r :status) 'ok))
        (should (= (length (plist-get (plist-get r :data) :disabled)) 200))
        (should (= (length (delete-dups (copy-sequence (plist-get (plist-get r :data) :disabled)))) 200))))
    (should-not (drgnx-modules-eld-test--backups))))

(ert-deftest drgnx-modules-eld/enabled-survives-a-turn-off ()
  (drgnx-modules-eld-test--with
    (drgnx-module-define 'test/off :doc "off until chosen" :default 'off :setup #'ignore)
    (drgnx-module-define 'test/on :doc "on" :setup #'ignore)
    (drgnx-test-config-put 'modules ";; mine\n(:version 2\n :disabled nil\n :enabled (test/off)   ; chosen\n :mine 1)\n")
    (drgnx-modules-toggle 'test/on)
    (should (equal (drgnx-modules-eld-test--text)
                   ";; mine\n(:version 2\n :disabled (test/on)\n :enabled (test/off)   ; chosen\n :mine 1)\n"))
    (should (equal (plist-get (drgnx-modules-read-state) :enabled) '(test/off)))
    (should (drgnx-module-disabled-p 'test/on))
    (should-not (drgnx-module-disabled-p 'test/off))))

(ert-deftest drgnx-modules-eld/a-v1-file-is-migrated-in-memory-and-written-v2-by-a-toggle-with-a-backup ()
  (drgnx-modules-eld-test--with
    (let ((old "(:version 1\n :disabled (a/b)) ; mine\n"))
      (drgnx-test-config-put 'modules old)
      (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(a/b)))
      (should (eql (plist-get (drgnx-modules-read-state) :version) 2))
      (should (equal (drgnx-modules-eld-test--text) old))             ; reading wrote nothing
      (should-not (drgnx-modules-eld-test--backups))
      (drgnx-modules-toggle 'c/d)
      (should (string-search ":version 2" (drgnx-modules-eld-test--text)))
      (should (string-search "; mine" (drgnx-modules-eld-test--text)))
      (should (equal (drgnx-modules-eld-test--disabled) '(a/b c/d)))
      (let ((backups (drgnx-modules-eld-test--backups)))
        (should (= (length backups) 1))
        (should (equal (with-temp-buffer (insert-file-contents (car backups)) (buffer-string)) old))))))

(ert-deftest drgnx-modules-eld/a-v3-file-is-read-only-and-toggles-refuse ()
  (drgnx-modules-eld-test--with
    (drgnx-module-define 'test/off :doc "off until chosen" :default 'off :setup #'ignore)
    (let ((newer "(:version 3 :disabled (a/b) :future (1 2))\n"))
      (drgnx-test-config-put 'modules newer)
      (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(a/b)))    ; applied: it fits the schema
      (should (drgnx-module-disabled-p 'a/b))
      (should-error (drgnx-modules-toggle 'c/d) :type 'drgnx-config-refused)
      (should-error (drgnx-modules-toggle 'test/off) :type 'drgnx-config-refused)
      (should-error (drgnx-modules-set-enabled 'test/off t) :type 'drgnx-config-refused)
      (should (equal (drgnx-modules-eld-test--text) newer))
      (should-not (drgnx-modules-eld-test--backups)))))

(ert-deftest drgnx-modules-eld/a-v0-list-still-reads ()
  (drgnx-modules-eld-test--with
    (drgnx-test-config-put 'modules "(a/b c/d)\n")
    (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(a/b c/d)))
    (should (drgnx-module-disabled-p 'c/d))
    (should (equal (drgnx-modules-eld-test--text) "(a/b c/d)\n"))
    (drgnx-modules-toggle 'e/f)
    (should (string-search ":version 2" (drgnx-modules-eld-test--text)))
    (should (equal (drgnx-modules-eld-test--disabled) '(a/b c/d e/f)))
    (should (= (length (drgnx-modules-eld-test--backups)) 1))))

(ert-deftest drgnx-modules-eld/a-malformed-external-entry-is-a-failed-module-not-a-file-mistake ()
  (drgnx-modules-eld-test--with
    (drgnx-test-config-put 'modules "(:version 2 :external ((:name nopath :features (a))))\n")
    (should (eq (plist-get (drgnx-config-read 'modules) :status) 'ok))
    (drgnx-modules-load-external)
    (should (eq (plist-get (alist-get 'external/nopath drgnx-modules--report) :status) 'failed))
    (drgnx-modules-toggle 'test/a)
    (should (equal (plist-get (drgnx-modules-read-state) :external) '((:name nopath :features (a)))))))

(ert-deftest drgnx-modules-eld/onboarding-preset-and-the-daemon-both-keep-their-change ()
  (drgnx-modules-eld-test--with
    (drgnx-test-config-put 'modules "(:version 2 :disabled (ui/zen))\n")
    (drgnx-config-reread 'modules)                          ; the daemon read the file at its start
    (drgnx-modules-eld-test--children '("(progn (require 'drgnx-onboard) (drgnx-onboard-apply-preset 'minimal))"))
    (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(ui/zen)))    ; the daemon has not looked again
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

(ert-deftest drgnx-modules-eld/the-theme-write-keeps-the-other-keys ()
  (drgnx-modules-eld-test--with
    (drgnx-test-config-put 'modules "(:version 2\n :disabled (a/b) ; mine\n)\n")
    (drgnx-modules-update-state (lambda (s) (plist-put (copy-sequence s) :theme 'tango)))
    (should (eq (plist-get (drgnx-modules-read-state) :theme) 'tango))
    (should (string-search ":disabled (a/b) ; mine" (drgnx-modules-eld-test--text)))))

;;;; A file with a mistake keeps its bytes through every writer

(ert-deftest drgnx-modules-eld/a-file-with-a-mistake-keeps-its-bytes-through-every-writer ()
  (drgnx-modules-eld-test--with
    (drgnx-module-define 'test/off :doc "off until chosen" :default 'off :setup #'ignore)
    (dolist (bad '("(:version 2 :disabled (a/b)\n ;; half typed\n"               ; unreadable
                   "(:version 2 :disabled \"not a list\")\n"                      ; fails the schema
                   "(:version 2 :flags ((ui/popups . 3)))\n"))
      (drgnx-test-config-put 'modules bad)
      (drgnx-config-reread 'modules)
      (dolist (writer (list (lambda () (drgnx-modules-toggle 'c/d))
                            (lambda () (drgnx-modules-toggle 'test/off))
                            (lambda () (drgnx-modules-set-enabled 'test/off t))
                            (lambda () (drgnx-modules-set-enabled 'c/d nil))
                            (lambda () (drgnx-modal--set-enabled 'undefined/engine t))
                            (lambda () (drgnx-onboard-apply-preset 'minimal))
                            (lambda () (drgnx-modules-update-state (lambda (s) (plist-put (copy-sequence s) :theme 'tango))))))
        (should-error (funcall writer) :type 'drgnx-config-refused)
        (should (equal (drgnx-modules-eld-test--text) bad)))
      (should-not (drgnx-modules-eld-test--backups)))))

(ert-deftest drgnx-modules-eld/the-onboarding-look-step-refuses-before-it-changes-anything ()
  (drgnx-modules-eld-test--with
    (let ((bad "(:version 2 :disabled \"not a list\")\n"))
      (drgnx-test-config-put 'modules bad)
      (let ((r (drgnx-onboard-run :only '(look-and-keys) :non-interactive t :options '(:theme tango))))
        (should (eq (cadr (car r)) 'fail)))
      (should (equal (drgnx-modules-eld-test--text) bad))
      (should-not (file-exists-p (expand-file-name "keys.eld" (drgnx-user-dir)))))))

(ert-deftest drgnx-modules-eld/the-color-theme-command-refuses-before-it-loads-a-theme ()
  (drgnx-modules-eld-test--with
    (load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)
    (let ((bad "(:version 2 :disabled \"not a list\")\n") (themes custom-enabled-themes))
      (drgnx-test-config-put 'modules bad)
      (should-error (drgnx-look-load-theme 'tango) :type 'drgnx-config-refused)
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
      (drgnx-test-config-put 'modules "(:version 2 :disabled (test/a) :enabled (test/b))\n")
      (should (equal (funcall next 'test/a) "off"))           ; never ran: "off at next start" is for a running one
      (should (equal (funcall next 'test/b) "on")))))

;;; modules-eld-test.el ends here
