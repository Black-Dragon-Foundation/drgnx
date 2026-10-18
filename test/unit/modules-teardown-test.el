;;; modules-teardown-test.el --- batch tests: the cleanup stack, :teardown, rollback -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-modules)

(defmacro drgnx-modules-teardown-test--with (&rest body)
  "BODY with a fresh module table, report, state and cleanup stacks, and an empty config dir."
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-modules--stacks nil) (drgnx-modules-teardown-test--log nil))
     (unwind-protect (progn ,@body) (delete-directory cfg t))))

(defvar drgnx-modules-teardown-test--log nil "What the fake undos did, newest first.")
(defvar drgnx-modules-teardown-test-hook nil "A hook the fake module adds to.")

(defun drgnx-modules-teardown-test--logger (what)
  "A function of no arguments that logs WHAT."
  (lambda () (push what drgnx-modules-teardown-test--log)))

(defun drgnx-modules-teardown-test--push (&rest labels)
  "Push one logging undo per label in LABELS."
  (dolist (l labels) (drgnx-modules-push-undo l (drgnx-modules-teardown-test--logger l))))

(defun drgnx-modules-teardown-test--status (name) (plist-get (alist-get name drgnx-modules--report) :status))

(defun drgnx-modules-teardown-test--run (name)
  "Run module NAME's setup now, as its stage would."
  (drgnx-modules--run-one name (alist-get name drgnx-modules--table) 'startup))

(ert-deftest drgnx-modules-teardown/push-undo-only-during-setup ()
  (drgnx-modules-teardown-test--with
   (should-not (drgnx-modules-push-undo "outside" #'ignore))
   (should-not drgnx-modules--stacks)
   (let (seen)
     (drgnx-module-define 'test/a :doc "a"
                          :setup (lambda () (setq seen drgnx-modules--current)
                                   (should-not (drgnx-modules-push-undo "inside" #'ignore))))
     (drgnx-modules-run 'startup)
     (should (eq seen 'test/a)))
   (should (equal (mapcar #'car (alist-get 'test/a drgnx-modules--stacks)) '("inside")))
   (should-not drgnx-modules--current)
   (drgnx-modules-push-undo "after" #'ignore)
   (should (equal (mapcar #'car (alist-get 'test/a drgnx-modules--stacks)) '("inside")))))

(defmacro drgnx-modules-teardown-test--with-file (var contents &rest body)
  "BODY with VAR a temporary .el file holding CONTENTS, deleted after."
  (declare (indent 2))
  `(let ((,var (make-temp-file "drgnx-td" nil ".el" ,contents)))
     (unwind-protect (progn ,@body) (delete-file ,var))))

(ert-deftest drgnx-modules-teardown/push-undo-ignores-load-time ()
  ;; A library the setup loads registers for itself at its top level: never undone.
  (drgnx-modules-teardown-test--with
   (drgnx-modules-teardown-test--with-file lib "(drgnx-modules-teardown-test--push \"library\")\n"
     (drgnx-module-define 'test/a :doc "a"
                          :setup (lambda ()
                                   (load lib nil t)
                                   (drgnx-modules-teardown-test--push "own")))
     (drgnx-modules-run 'startup))
   (should (equal drgnx-modules-teardown-test--log nil))
   (should (equal (mapcar #'car (alist-get 'test/a drgnx-modules--stacks)) '("own")))))

(ert-deftest drgnx-modules-teardown/a-stage-run-from-a-loaded-file-records ()
  ;; The real boot: init.el calls drgnx-init while Emacs still loads the init file, so the startup
  ;; stage runs inside a `load'.  The setups' own changes are recorded all the same.
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/a :doc "a" :setup (lambda () (drgnx-modules-teardown-test--push "own")))
   (drgnx-modules-teardown-test--with-file init "(drgnx-modules-run 'startup)\n"
     (load init nil t))
   (should (equal (mapcar #'car (alist-get 'test/a drgnx-modules--stacks)) '("own")))
   (should-not (drgnx-module-teardown 'test/a))
   (should (equal drgnx-modules-teardown-test--log '("own")))))

(ert-deftest drgnx-modules-teardown/nested-setups-push-onto-their-own-module ()
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/b :doc "b" :stage 'idle :setup (lambda () (drgnx-modules-teardown-test--push "b")))
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda ()
                                 (drgnx-modules-teardown-test--push "a1")
                                 (drgnx-modules--run-one 'test/b (alist-get 'test/b drgnx-modules--table) 'idle)
                                 (drgnx-modules-teardown-test--push "a2")))
   (drgnx-modules-run 'startup)
   (should (equal (mapcar #'car (alist-get 'test/a drgnx-modules--stacks)) '("a2" "a1")))
   (should (equal (mapcar #'car (alist-get 'test/b drgnx-modules--stacks)) '("b")))))

(ert-deftest drgnx-modules-teardown/teardown-runs-last-in-first-out ()
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/a :doc "a" :setup (lambda () (drgnx-modules-teardown-test--push "a" "b" "c")))
   (drgnx-modules-run 'startup)
   (should (eq (drgnx-modules-teardown-test--status 'test/a) 'ok))
   (should-not (drgnx-module-teardown 'test/a))
   (should (equal (reverse drgnx-modules-teardown-test--log) '("c" "b" "a")))
   (should-not (assq 'test/a drgnx-modules--stacks))
   (should (eq (drgnx-modules-teardown-test--status 'test/a) 'off))
   ;; Off already: nothing runs again.
   (setq drgnx-modules-teardown-test--log nil)
   (should-not (drgnx-module-teardown 'test/a))
   (should-not drgnx-modules-teardown-test--log)))

(ert-deftest drgnx-modules-teardown/teardown-runs-the-module-function-first ()
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda () (drgnx-modules-teardown-test--push "a" "b"))
                        :teardown (drgnx-modules-teardown-test--logger "module"))
   (drgnx-modules-run 'startup)
   (should-not (drgnx-module-teardown 'test/a))
   (should (equal (reverse drgnx-modules-teardown-test--log) '("module" "b" "a")))))

(ert-deftest drgnx-modules-teardown/restart-modules-are-not-torn-down ()
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/r :doc "r" :setup (lambda () (drgnx-modules-teardown-test--push "a")) :teardown 'restart)
   (drgnx-module-define 'test/never :doc "n" :packages '(drgnx-no-such-package)
                        :setup (lambda () (drgnx-modules-teardown-test--push "n"))
                        :teardown (drgnx-modules-teardown-test--logger "never"))
   (drgnx-modules-run 'startup)
   (should (equal (drgnx-module-teardown 'test/r) '("restart")))
   (should-not drgnx-modules-teardown-test--log)
   (should (eq (drgnx-modules-teardown-test--status 'test/r) 'ok))
   (should (equal (mapcar #'car (alist-get 'test/r drgnx-modules--stacks)) '("a")))
   ;; A module that did not run does nothing.
   (should-not (drgnx-module-teardown 'test/never))
   (should-not (drgnx-module-teardown 'test/not-defined))
   (should-not drgnx-modules-teardown-test--log)
   (should (eq (drgnx-modules-teardown-test--status 'test/never) 'missing-packages))))

(ert-deftest drgnx-modules-teardown/failed-setup-rolls-back ()
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda ()
                                 (drgnx-modules-teardown-test--push "a")
                                 (drgnx-modules-push-undo "bad" (lambda () (error "undo kaputt")))
                                 (drgnx-modules-teardown-test--push "b")
                                 (error "setup kaputt")))
   (drgnx-modules-run 'startup)
   (should (equal (reverse drgnx-modules-teardown-test--log) '("b" "a")))
   (let ((r (alist-get 'test/a drgnx-modules--report)))
     (should (eq (plist-get r :status) 'failed))
     (should (string-search "setup kaputt" (plist-get r :error)))
     (should (equal (plist-get r :problems) '("bad: undo kaputt"))))
   (should-not (assq 'test/a drgnx-modules--stacks))
   ;; A failed module did not run: teardown does nothing.
   (setq drgnx-modules-teardown-test--log nil)
   (should-not (drgnx-module-teardown 'test/a))
   (should-not drgnx-modules-teardown-test--log)))

(ert-deftest drgnx-modules-teardown/a-throw-rolls-back ()
  ;; A setup that did not finish is half-applied, whatever the cause.
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda () (drgnx-modules-teardown-test--push "a" "b") (throw 'drgnx-td-out 'thrown)))
   (should (eq (catch 'drgnx-td-out (drgnx-modules-run 'startup)) 'thrown))
   (should (equal (reverse drgnx-modules-teardown-test--log) '("b" "a")))
   (should-not (assq 'test/a drgnx-modules--stacks))))

(ert-deftest drgnx-modules-teardown/a-quit-rolls-back-and-goes-on ()
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda () (drgnx-modules-teardown-test--push "a" "b") (signal 'quit nil)))
   (should (eq (condition-case nil (progn (drgnx-modules-run 'startup) 'finished) (quit 'quit)) 'quit))
   (should (equal (reverse drgnx-modules-teardown-test--log) '("b" "a")))
   (should-not (assq 'test/a drgnx-modules--stacks))))

(ert-deftest drgnx-modules-teardown/rollback-keeps-what-was-there-before ()
  ;; A restart module is never torn down while Emacs runs: run again and failing, only the new
  ;; changes are rolled back.
  (drgnx-modules-teardown-test--with
   (let ((fail nil))
     (drgnx-module-define 'test/r :doc "r" :teardown 'restart
                          :setup (lambda () (drgnx-modules-teardown-test--push (if fail "second" "first"))
                                   (when fail (error "kaputt"))))
     (drgnx-modules-teardown-test--run 'test/r)
     (setq fail t)
     (drgnx-modules-teardown-test--run 'test/r)
     (should (equal drgnx-modules-teardown-test--log '("second")))
     (should (equal (mapcar #'car (alist-get 'test/r drgnx-modules--stacks)) '("first")))
     (should (eq (drgnx-modules-teardown-test--status 'test/r) 'failed)))))

(ert-deftest drgnx-modules-teardown/a-module-run-again-is-torn-down-first ()
  ;; No undo is orphaned: running a module that is on turns it off first, then on.
  (drgnx-modules-teardown-test--with
   (let ((fail nil))
     (drgnx-module-define 'test/a :doc "a"
                          :setup (lambda () (drgnx-modules-teardown-test--push "u") (when fail (error "kaputt")))
                          :teardown (drgnx-modules-teardown-test--logger "td"))
     (drgnx-modules-teardown-test--run 'test/a)
     (drgnx-modules-teardown-test--run 'test/a)
     (should (equal (reverse drgnx-modules-teardown-test--log) '("td" "u")))
     (should (equal (mapcar #'car (alist-get 'test/a drgnx-modules--stacks)) '("u")))
     (should (eq (drgnx-modules-teardown-test--status 'test/a) 'ok))
     ;; …and a re-run that fails leaves nothing behind.
     (setq fail t drgnx-modules-teardown-test--log nil)
     (drgnx-modules-teardown-test--run 'test/a)
     (should (equal (reverse drgnx-modules-teardown-test--log) '("td" "u" "u")))
     (should-not (assq 'test/a drgnx-modules--stacks))
     (should (eq (drgnx-modules-teardown-test--status 'test/a) 'failed)))))

(ert-deftest drgnx-modules-teardown/a-teardown-that-tears-itself-down-runs-once ()
  (drgnx-modules-teardown-test--with
   (let ((inner :unset))
     (drgnx-module-define 'test/a :doc "a"
                          :setup (lambda () (drgnx-modules-teardown-test--push "u"))
                          :teardown (lambda () (push "td" drgnx-modules-teardown-test--log)
                                      (setq inner (drgnx-module-teardown 'test/a))))
     (drgnx-modules-run 'startup)
     (should-not (drgnx-module-teardown 'test/a))
     (should-not inner)
     (should (equal (reverse drgnx-modules-teardown-test--log) '("td" "u")))
     (should (eq (drgnx-modules-teardown-test--status 'test/a) 'off)))))

(ert-deftest drgnx-modules-teardown/an-external-module-is-restart ()
  ;; Its code was required: nothing can be undone while Emacs runs.
  (drgnx-modules-teardown-test--with
   (drgnx-modules--record 'external/x/feat 'idle 1 'ok)
   (should (equal (drgnx-module-teardown 'external/x/feat) '("restart")))
   (should (eq (drgnx-modules-teardown-test--status 'external/x/feat) 'ok))))

(ert-deftest drgnx-modules-teardown/teardown-is-a-function-or-restart ()
  (drgnx-modules-teardown-test--with
   (should-error (drgnx-module-define 'test/typo :doc "t" :setup #'ignore :teardown 'restrat))
   (should-error (drgnx-module-define 'test/num :doc "t" :setup #'ignore :teardown 3))
   (should-not (assq 'test/typo drgnx-modules--table))
   (dolist (td (list nil 'restart #'ignore (lambda ())))
     (should (eq (drgnx-module-define 'test/ok :doc "t" :setup #'ignore :teardown td) 'test/ok)))))

(ert-deftest drgnx-modules-teardown/an-undo-error-is-reported-not-raised ()
  (drgnx-modules-teardown-test--with
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda ()
                                 (drgnx-modules-teardown-test--push "first")
                                 (drgnx-modules-push-undo "hook foo-hook bar" (lambda () (error "boom")))
                                 (drgnx-modules-teardown-test--push "last"))
                        :teardown (lambda () (error "module boom")))
   (drgnx-modules-run 'startup)
   (let ((problems (drgnx-module-teardown 'test/a)))
     (should (equal problems '("teardown: module boom" "hook foo-hook bar: boom"))))
   (should (equal (reverse drgnx-modules-teardown-test--log) '("last" "first")))
   (should-not (assq 'test/a drgnx-modules--stacks))
   (let ((r (alist-get 'test/a drgnx-modules--report)))
     (should (eq (plist-get r :status) 'off))
     (should (equal (plist-get r :problems) '("teardown: module boom" "hook foo-hook bar: boom"))))))

(defun drgnx-modules-teardown-test--tick () "The fake module's timer function.")
(defun drgnx-modules-teardown-test--hook-fn () "The fake module's hook function.")

(defun drgnx-modules-teardown-test--timers ()
  (seq-count (lambda (tm) (eq (timer--function tm) #'drgnx-modules-teardown-test--tick)) timer-list))

(ert-deftest drgnx-modules-teardown/off-on-three-times-is-identity ()
  (drgnx-modules-teardown-test--with
   (let ((drgnx-modules-teardown-test-hook nil))
     (drgnx-module-define
      'test/a :doc "a"
      :setup (lambda ()
               (add-hook 'drgnx-modules-teardown-test-hook #'drgnx-modules-teardown-test--hook-fn)
               (drgnx-modules-push-undo "hook" (lambda () (remove-hook 'drgnx-modules-teardown-test-hook
                                                                       #'drgnx-modules-teardown-test--hook-fn)))
               (let ((tm (run-at-time 3600 3600 #'drgnx-modules-teardown-test--tick)))
                 (drgnx-modules-push-undo "timer" (lambda () (cancel-timer tm))))))
     (unwind-protect
         (progn
           (drgnx-modules-run 'startup)
           (dotimes (_ 3)
             (should (equal drgnx-modules-teardown-test-hook '(drgnx-modules-teardown-test--hook-fn)))
             (should (= (drgnx-modules-teardown-test--timers) 1))
             (should-not (drgnx-module-teardown 'test/a))
             (should-not drgnx-modules-teardown-test-hook)
             (should (= (drgnx-modules-teardown-test--timers) 0))
             (should-not drgnx-modules--stacks)
             (should (eq (drgnx-modules-teardown-test--status 'test/a) 'off))
             (drgnx-modules-teardown-test--run 'test/a)
             (should (eq (drgnx-modules-teardown-test--status 'test/a) 'ok)))
           ;; its own two undos and the safety net's two for the same hook and timer (each undo checks first)
           (should (= (length (alist-get 'test/a drgnx-modules--stacks)) 4)))
       (drgnx-module-teardown 'test/a)
       (cancel-function-timers #'drgnx-modules-teardown-test--tick)))))

(ert-deftest drgnx-modules-teardown/teardown-never-prompts ()
  ;; Teardown and rollback run in automatic paths: nothing in them may ask.  A :teardown or an undo
  ;; that would ask fails at once (reported), instead of waiting for an answer.
  (drgnx-modules-teardown-test--with
   (let* ((asked nil)
          (stub (lambda (fn) (lambda (&rest _)
                               (when inhibit-interaction (signal 'inhibited-interaction nil))
                               (push fn asked) (error "%s asked" fn)))))
     (cl-letf (((symbol-function 'read-from-minibuffer) (funcall stub 'read-from-minibuffer))
               ((symbol-function 'y-or-n-p) (funcall stub 'y-or-n-p))
               ((symbol-function 'yes-or-no-p) (funcall stub 'yes-or-no-p)))
       (drgnx-module-define 'test/quiet :doc "q"
                            :setup (lambda () (drgnx-modules-teardown-test--push "a"))
                            :teardown (drgnx-modules-teardown-test--logger "module"))
       (drgnx-module-define 'test/asks :doc "a"
                            :setup (lambda () (drgnx-modules-push-undo "asks" (lambda () (yes-or-no-p "Undo? "))))
                            :teardown (lambda () (y-or-n-p "Really? ")))
       (drgnx-module-define 'test/fails :doc "f"
                            :setup (lambda () (drgnx-modules-push-undo "asks" (lambda () (read-from-minibuffer "? ")))
                                     (error "kaputt")))
       (drgnx-modules-run 'startup)
       (should-not (drgnx-module-teardown 'test/quiet))
       (let ((problems (drgnx-module-teardown 'test/asks)))
         (should (= (length problems) 2))
         (should (string-prefix-p "teardown: " (car problems)))
         (should (string-prefix-p "asks: " (cadr problems))))
       (should (= (length (plist-get (alist-get 'test/fails drgnx-modules--report) :problems)) 1))
       (should-not asked)))))
