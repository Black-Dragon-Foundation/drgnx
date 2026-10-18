;;; modules-off-test.el --- batch tests: Turn Off and Turn On in Preferences, now -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-modules)

(defvar drgnx-modules-off-test--log nil "What the fake setups and undos did, newest first.")
(defvar drgnx-modules-off-test--prompts nil "The prompts asked, newest first.")

(defmacro drgnx-modules-off-test--with (&rest body)
  "BODY with a fresh module table, report, state, cleanup stacks and an empty config dir; any prompt is recorded
and answered yes."
  `(let* ((cfg (make-temp-file "drgnx-cfg" t)) (st (make-temp-file "drgnx-st" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" cfg) (concat "XDG_STATE_HOME=" st))
                                       process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
          (drgnx-modules-after-teardown-functions nil) (drgnx-modules-after-stage-functions nil)
          (drgnx-modules-off-test--log nil) (drgnx-modules-off-test--prompts nil))
     (unwind-protect
         (cl-letf (((symbol-function 'y-or-n-p)
                    (lambda (p) (push p drgnx-modules-off-test--prompts) t)))
           ,@body)
       (delete-directory cfg t) (delete-directory st t))))

(defun drgnx-modules-off-test--define (name &rest args)
  "Define module NAME whose setup logs `NAME+' and pushes an undo that logs `NAME-'."
  (apply #'drgnx-module-define name :doc (symbol-name name)
         :setup (lambda ()
                  (push (list name '+) drgnx-modules-off-test--log)
                  (drgnx-modules-push-undo (symbol-name name)
                                           (lambda () (push (list name '-) drgnx-modules-off-test--log))))
         args))

(defun drgnx-modules-off-test--status (name) (plist-get (alist-get name drgnx-modules--report) :status))
(defun drgnx-modules-off-test--disabled () (plist-get (drgnx-modules-read-state) :disabled))

(ert-deftest drgnx-modules-off/turn-off-tears-down-and-remembers ()
  (drgnx-modules-off-test--with
   (let ((after 0))
     (add-hook 'drgnx-modules-after-teardown-functions (lambda () (cl-incf after)))
     (drgnx-modules-off-test--define 'test/a)
     (drgnx-modules-run 'startup)
     (should (eq (drgnx-modules-off-test--status 'test/a) 'ok))
     (should-not (drgnx-modules-turn-off 'test/a))
     (should (equal drgnx-modules-off-test--log '((test/a -) (test/a +))))
     (should (eq (drgnx-modules-off-test--status 'test/a) 'off))
     (should (drgnx-module-disabled-p 'test/a))
     (should (equal (drgnx-modules-off-test--disabled) '(test/a)))
     (should (= after 1))
     (should-not drgnx-modules-off-test--prompts))))

(ert-deftest drgnx-modules-off/turn-on-runs-a-passed-stage-now ()
  (drgnx-modules-off-test--with
   (drgnx-modules-write-state '(:version 1 :disabled (test/a)))
   (drgnx-modules-off-test--define 'test/a)
   (drgnx-modules-run 'startup)
   (should (eq (drgnx-modules-off-test--status 'test/a) 'disabled))
   (should-not drgnx-modules-off-test--log)
   (let (staged)
     (add-hook 'drgnx-modules-after-stage-functions (lambda (s) (push s staged)))
     (drgnx-modules-turn-on 'test/a)
     (should (equal staged '(startup))))   ; keys and menus follow, as after a stage
   (should (equal drgnx-modules-off-test--log '((test/a +))))
   (should (eq (drgnx-modules-off-test--status 'test/a) 'ok))
   (should-not (drgnx-module-disabled-p 'test/a))
   (should-not (drgnx-modules-off-test--disabled))
   ;; Off and on again: the setup runs once more, the undo once.
   (drgnx-modules-turn-off 'test/a)
   (drgnx-modules-turn-on 'test/a)
   (should (equal drgnx-modules-off-test--log '((test/a +) (test/a -) (test/a +))))))

(ert-deftest drgnx-modules-off/turn-on-waits-for-a-later-stage ()
  (drgnx-modules-off-test--with
   (drgnx-modules-write-state '(:version 1 :disabled (test/late test/needs)))
   (drgnx-modules-off-test--define 'test/late :stage 'idle)
   (drgnx-modules-off-test--define 'test/needs :packages '(drgnx-no-such-package-xyz))
   (drgnx-modules-run 'startup)
   (drgnx-modules-turn-on 'test/late)               ; the idle stage has not come
   (should-not drgnx-modules-off-test--log)
   (should-not (alist-get 'test/late drgnx-modules--report))
   (should-not (drgnx-module-disabled-p 'test/late))
   (drgnx-modules-run 'idle)                        ; and then it runs
   (should (equal drgnx-modules-off-test--log '((test/late +))))
   ;; Its stage has passed but its package is absent: it waits, reported.
   (drgnx-modules-turn-on 'test/needs)
   (should (equal drgnx-modules-off-test--log '((test/late +))))
   (should (eq (drgnx-modules-off-test--status 'test/needs) 'missing-packages))
   (should-not (drgnx-module-disabled-p 'test/needs))))

(ert-deftest drgnx-modules-off/dependents-are-listed-not-torn-down ()
  (drgnx-modules-off-test--with
   (drgnx-modules-off-test--define 'test/b)
   (drgnx-modules-off-test--define 'test/a :requires '(test/b))
   (drgnx-modules-off-test--define 'test/c :requires '(test/a))
   (drgnx-modules-run 'startup)
   (let ((deps (drgnx-modules-turn-off 'test/b)))
     (should (equal (sort (copy-sequence deps) #'string<) '(test/a test/c))))
   (should (equal (length drgnx-modules-off-test--log) 3))   ; three setups, no undo
   (should (eq (drgnx-modules-off-test--status 'test/b) 'ok))
   (should-not (drgnx-modules-off-test--disabled))
   (should-not drgnx-modules-off-test--prompts)
   ;; A module nobody needs has none.
   (should-not (drgnx-modules-turn-off 'test/c))))

(ert-deftest drgnx-modules-off/dependents-go-first-when-asked ()
  (drgnx-modules-off-test--with
   (drgnx-modules-off-test--define 'test/b)
   (drgnx-modules-off-test--define 'test/a :requires '(test/b))
   (drgnx-modules-off-test--define 'test/c :requires '(test/a))
   (drgnx-modules-run 'startup)
   (should-not (drgnx-modules-turn-off 'test/b :dependents t))
   (should (equal (seq-take drgnx-modules-off-test--log 3) '((test/b -) (test/a -) (test/c -))))
   (dolist (m '(test/a test/b test/c)) (should (eq (drgnx-modules-off-test--status m) 'off)))
   (should (equal (drgnx-modules-off-test--disabled) '(test/b)))   ; only the module asked for is remembered
   (should-not drgnx-modules-off-test--prompts)))

(ert-deftest drgnx-modules-off/restart-modules-wait-for-the-next-start ()
  (drgnx-modules-off-test--with
   (drgnx-modules-off-test--define 'test/r :teardown 'restart)
   (drgnx-modules-run 'startup)
   (should-not (drgnx-modules-turn-off 'test/r))
   (should (equal drgnx-modules-off-test--log '((test/r +))))      ; nothing undone
   (should (eq (drgnx-modules-off-test--status 'test/r) 'ok))
   (should (equal (drgnx-modules-off-test--disabled) '(test/r)))   ; but remembered
   (should (equal (aref (cadr (assq 'test/r (drgnx-modules--entries))) 4) "off at next start"))
   ;; Turning it back on only forgets the choice; the setup is not run twice.
   (drgnx-modules-turn-on 'test/r)
   (should (equal drgnx-modules-off-test--log '((test/r +))))
   (should-not (drgnx-modules-off-test--disabled))))

(ert-deftest drgnx-modules-off/the-list-says-what-is-off-now-and-next ()
  (drgnx-modules-off-test--with
   (drgnx-modules-off-test--define 'test/a)
   (drgnx-modules-run 'startup)
   (cl-flet ((row (m) (cadr (assq m (drgnx-modules--entries)))))
     (should (equal (aref (row 'test/a) 4) "on"))
     (drgnx-modules-turn-off 'test/a)
     (should (equal (aref (row 'test/a) 1) "off"))
     (should (equal (aref (row 'test/a) 4) "off"))
     (should (string-search "code stays loaded until restart" (aref (row 'test/a) 5)))
     (drgnx-modules-turn-on 'test/a)
     (should-not (string-search "stays loaded" (aref (row 'test/a) 5))))))

(defun drgnx-modules-off-test--press (module)
  "Put point on MODULE's row in the Modules list and run the command bound to RET there."
  (with-current-buffer (drgnx-modules-list)
    (goto-char (point-min))
    (while (and (not (eobp)) (not (eq (tabulated-list-get-id) module))) (forward-line 1))
    (should (eq (tabulated-list-get-id) module))
    (drgnx-modules-list-toggle)))

(ert-deftest drgnx-modules-off/the-command-asks-once ()
  (drgnx-modules-off-test--with
   (drgnx-modules-off-test--define 'test/b)
   (drgnx-modules-off-test--define 'test/a :requires '(test/b))
   (drgnx-modules-off-test--define 'test/c :requires '(test/b))
   (drgnx-modules-run 'startup)
   (unwind-protect
       (progn
         ;; No: nothing happens.
         (cl-letf (((symbol-function 'y-or-n-p) (lambda (p) (push p drgnx-modules-off-test--prompts) nil)))
           (drgnx-modules-off-test--press 'test/b))
         (should (equal (length drgnx-modules-off-test--prompts) 1))
         (should (eq (drgnx-modules-off-test--status 'test/b) 'ok))
         (should-not (drgnx-modules-off-test--disabled))
         ;; Yes: once, naming the dependents; they and the module go.
         (setq drgnx-modules-off-test--prompts nil)
         (drgnx-modules-off-test--press 'test/b)
         (should (equal (length drgnx-modules-off-test--prompts) 1))
         (should (string-match-p "\\`Also turn off test/[ac], test/[ac]\\? \\'" (car drgnx-modules-off-test--prompts)))
         (dolist (m '(test/a test/b test/c)) (should (eq (drgnx-modules-off-test--status m) 'off)))
         ;; The same row again turns it on, without a question.
         (setq drgnx-modules-off-test--prompts nil)
         (drgnx-modules-off-test--press 'test/b)
         (should-not drgnx-modules-off-test--prompts)
         (should (eq (drgnx-modules-off-test--status 'test/b) 'ok))
         ;; A dependent that went with it is turned on by the same key, then off again without asking.
         (drgnx-modules-off-test--press 'test/c)
         (should (eq (drgnx-modules-off-test--status 'test/c) 'ok))
         (drgnx-modules-off-test--press 'test/c)
         (should-not drgnx-modules-off-test--prompts)
         (should (drgnx-module-disabled-p 'test/c)))
     (kill-buffer "*drgnx modules*"))))

(ert-deftest drgnx-modules-off/onboarding-toggle-still-means-next-start ()
  (drgnx-modules-off-test--with
   (drgnx-modules-off-test--define 'test/a)
   (drgnx-modules-run 'startup)
   (drgnx-modules-toggle 'test/a)
   (should (equal (drgnx-modules-off-test--disabled) '(test/a)))
   (should (eq (drgnx-modules-off-test--status 'test/a) 'ok))      ; still running
   (should (equal drgnx-modules-off-test--log '((test/a +))))      ; nothing undone
   (drgnx-modules-toggle 'test/a)
   (should-not (drgnx-modules-off-test--disabled))
   (should (equal drgnx-modules-off-test--log '((test/a +))))))     ; nothing run twice
