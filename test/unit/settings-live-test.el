;;; settings-live-test.el --- batch tests: hand edits and other writers apply at once; :apply; the end-of-init pass -*- lexical-binding: t -*-
;; The fixture setting `drgnx-slt--n' is declared with `drgnx-defsetting' and an `:apply' that counts.  settings.el
;; lives under `drgnx-test-with-config'; the file-notify callback is called directly (no real inotify), time is the
;; virtual clock.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(require 'drgnx-registry)
(require 'drgnx-settings-live)

(defvar drgnx-slt--calls 0 "How often the fixture's `:apply' ran.")
(defvar drgnx-slt--seen nil "Every FILE and CHANGES `drgnx-settings-changed-functions' got.")

(defun drgnx-slt--apply () (cl-incf drgnx-slt--calls))
(defun drgnx-slt--changed (file changes) (push (cons file changes) drgnx-slt--seen))

(defmacro drgnx-slt--with (&rest body)
  "BODY with the fixture setting declared fresh, the live state bound fresh, a temp config and a virtual clock."
  (declare (indent 0))
  `(let ((drgnx-settings-apply--entries nil) (drgnx-settings-apply-problems nil) (drgnx-settings-apply-durations nil)
         (drgnx-settings-package-settings-off nil) (drgnx-settings-live--stamps (make-hash-table :test 'equal))
         (drgnx-settings-live--watches nil) (drgnx-settings-live--watched (make-hash-table :test 'eq))
         (drgnx-settings-live--queue nil) (drgnx-settings-live--applied (make-hash-table :test 'eq))
         (drgnx-settings-changed-functions (list #'drgnx-slt--changed))
         (drgnx-slt--calls 0) (drgnx-slt--seen nil))
     (makunbound 'drgnx-slt--n)
     (dolist (p '(standard-value theme-value saved-value custom-type drgnx-setting))
       (put 'drgnx-slt--n p nil))
     (eval '(drgnx-defsetting drgnx-slt--n 1 "A test setting." :type 'integer :group 'drgnx-slt :apply #'drgnx-slt--apply)
           t)
     (unwind-protect (drgnx-test-with-config (drgnx-test-with-clock ()
                                               (unwind-protect (progn ,@body)
                                                 (drgnx-settings-live-stop))))
       (drgnx-settings-live-stop)
       (put 'drgnx 'theme-settings
            (cl-remove-if (lambda (s) (eq (cadr s) 'drgnx-slt--n)) (get 'drgnx 'theme-settings)))
       (remove-variable-watcher 'drgnx-slt--n #'drgnx-settings-live--watcher)
       (makunbound 'drgnx-slt--n)
       (dolist (p '(standard-value theme-value saved-value custom-type drgnx-setting)) (put 'drgnx-slt--n p nil))
       (setq drgnx-setting--names (delq 'drgnx-slt--n drgnx-setting--names)))))

(defun drgnx-slt--put (n)
  "settings.el with the fixture at N, written as an editor would (a new file renamed over it)."
  (drgnx-test-config-put 'settings (format "(drgnx-settings\n :version 1\n (drgnx-slt--n %d))\n" n)))

(defun drgnx-slt--file () (drgnx-config-file 'settings))

(ert-deftest drgnx-settings-live/a-hand-edit-applies ()
  (drgnx-slt--with
    (drgnx-slt--put 2)
    (drgnx-settings-live-start)
    (drgnx-slt--put 7)
    (let ((changes (drgnx-settings-live-sync (drgnx-slt--file))))
      (should (equal changes '((nil drgnx-slt--n :unset 7))))
      (should (= 7 drgnx-slt--n))
      (should (equal drgnx-slt--seen (list (cons (drgnx-slt--file) changes)))))
    (drgnx-slt--put 9)
    (should (equal (drgnx-settings-live-sync (drgnx-slt--file)) '((nil drgnx-slt--n 7 9))))
    (should (= 9 drgnx-slt--n))))

(ert-deftest drgnx-settings-live/another-process-write-applies ()
  (drgnx-slt--with
    (make-directory (file-name-directory (drgnx-slt--file)) t)
    (drgnx-settings-live-start)
    (should (= 1 drgnx-slt--n))
    (write-region "(drgnx-settings\n :version 1\n (drgnx-slt--n 5))\n" nil (drgnx-slt--file) nil 'silent)
    (drgnx-settings-live--event (list 1 'changed (drgnx-slt--file)))
    (should (= 5 drgnx-slt--n))))

(ert-deftest drgnx-settings-live/a-rename-over-applies ()
  (drgnx-slt--with
    (drgnx-settings-live-start)
    (drgnx-slt--put 3)
    (drgnx-settings-live--event (list 1 'renamed (concat (drgnx-slt--file) ".test-new") (drgnx-slt--file)))
    (should (= 3 drgnx-slt--n))))

(ert-deftest drgnx-settings-live/focus-stamp-check-without-notify ()
  (drgnx-slt--with
    (drgnx-settings-live-start)
    (drgnx-slt--put 4)
    (should (equal (drgnx-settings-live-check) (list (drgnx-slt--file))))
    (should (= 4 drgnx-slt--n))
    (should-not (drgnx-settings-live-check))))

(ert-deftest drgnx-settings-live/an-entry-taken-out-goes-back-to-the-default ()
  (drgnx-slt--with
    (drgnx-slt--put 6)
    (drgnx-settings-live-sync (drgnx-slt--file))
    (should (= 6 drgnx-slt--n))
    (drgnx-test-config-put 'settings "(drgnx-settings\n :version 1)\n")
    (should (equal (drgnx-settings-live-sync (drgnx-slt--file)) '((nil drgnx-slt--n 6 :unset))))
    (should (= 1 drgnx-slt--n))))

(ert-deftest drgnx-settings-live/apply-runs-on-idle-not-in-the-watcher ()
  (drgnx-slt--with
    (drgnx-settings-live-start)
    (setq drgnx-slt--n 8)
    (should (= 0 drgnx-slt--calls))
    (should (drgnx-timer-active-p 'settings-apply))
    (setq drgnx-slt--n 9)                                  ; two changes, one run
    (drgnx-test-idle 1)
    (should (= 1 drgnx-slt--calls))
    (should-not (drgnx-timer-active-p 'settings-apply))))

(ert-deftest drgnx-settings-live/a-file-change-queues-apply ()
  (drgnx-slt--with
    (drgnx-settings-live-start)
    (drgnx-slt--put 5)
    (drgnx-settings-live-sync (drgnx-slt--file))
    (should (= 0 drgnx-slt--calls))
    (drgnx-test-idle 1)
    (should (= 1 drgnx-slt--calls))))

(ert-deftest drgnx-settings-live/the-end-of-init-pass-applies-a-config-el-setq ()
  (drgnx-slt--with
    (drgnx-settings-apply-pass)
    (should (= 0 drgnx-slt--calls))                        ; still the default
    (setq drgnx-slt--n 12)                                 ; config.el, before the watches exist
    (drgnx-settings-apply-pass)
    (should (= 1 drgnx-slt--calls))
    (drgnx-settings-apply-pass)
    (should (= 1 drgnx-slt--calls))))

(ert-deftest drgnx-settings-live/nothing-happens-while-nothing-changes ()
  (drgnx-slt--with
    (drgnx-slt--put 2)
    (drgnx-settings-live-start)
    (drgnx-settings-live-sync (drgnx-slt--file))
    (drgnx-test-idle 1)
    (setq drgnx-slt--seen nil drgnx-slt--calls 0)
    (should-not (drgnx-settings-live-check))
    (should-not (drgnx-settings-live-sync (drgnx-slt--file)))
    (should-not drgnx-slt--seen)
    (drgnx-test-idle 5)
    (should (= 0 drgnx-slt--calls))))

(ert-deftest drgnx-settings-live/a-failing-hook-function-does-not-stop-the-rest ()
  (drgnx-slt--with
    (let ((drgnx-settings-changed-functions (list (lambda (&rest _) (error "Boom")) #'drgnx-slt--changed)))
      (drgnx-slt--put 3)
      (should (drgnx-settings-live-sync (drgnx-slt--file)))
      (should drgnx-slt--seen))))

(provide 'settings-live-test)
;;; settings-live-test.el ends here
