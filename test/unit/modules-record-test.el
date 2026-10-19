;;; modules-record-test.el --- batch tests: the safety net records what a setup reaches -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-modules)
(require 'drgnx-timer)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below

(defvar drgnx-modules-record-test-hook nil "A hook the fake modules add to.")
(defvar drgnx-modules-record-test-list nil "A list the fake modules add to.")
(defvar drgnx-modules-record-test-ran nil "What deferred work ran, newest first.")

(defun drgnx-modules-record-test-fn () "A hook function." nil)
(defun drgnx-modules-record-test-other () "Another hook function." nil)
(defun drgnx-modules-record-test-target (x) "A function that gets advised." x)
(defun drgnx-modules-record-test-advice (orig x) "Advice: one more." (1+ (funcall orig x)))
(defun drgnx-modules-record-test-advice-2 (orig x) "Advice: ten more." (+ 10 (funcall orig x)))
(define-minor-mode drgnx-modules-record-test-a-mode "A global mode for these tests." :global t)
(define-minor-mode drgnx-modules-record-test-b-mode "Another global mode for these tests." :global t)
(define-minor-mode drgnx-modules-record-test-opt-mode "A global mode an option turns on and off." :global t)
(defcustom drgnx-modules-record-test-opt nil
  "An option whose setter turns `drgnx-modules-record-test-opt-mode' on or off (as `custom-set-minor-mode')."
  :type 'boolean :group 'drgnx
  :set (lambda (sym v) (set-default sym v) (drgnx-modules-record-test-opt-mode (if v 1 -1))))

(defmacro drgnx-modules-record-test--with (&rest body)
  "BODY with a fresh module table, report, state, stacks, runs and features, an empty config dir, and the
test hook, list and modes as they were after."
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
          (drgnx-modules-record-test-hook nil) (drgnx-modules-record-test-list nil)
          (drgnx-modules-record-test-ran nil)
          (drgnx-module--claims (make-hash-table :test 'equal))
          (drgnx-module--releasers (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body)
       (drgnx-modules-record-test-a-mode -1) (drgnx-modules-record-test-b-mode -1)
       (delete-directory cfg t))))

(defun drgnx-modules-record-test--run (name)
  "Run module NAME's setup now, as its stage would."
  (drgnx-modules--run-one name (alist-get name drgnx-modules--table) 'startup))

(defun drgnx-modules-record-test--labels (name) (mapcar #'car (alist-get name drgnx-modules--stacks)))
(defun drgnx-modules-record-test--status (name) (plist-get (alist-get name drgnx-modules--report) :status))

(defmacro drgnx-modules-record-test--with-file (var contents &rest body)
  "BODY with VAR a temporary .el file holding CONTENTS, deleted after (and its .elc)."
  (declare (indent 2))
  `(let ((,var (make-temp-file "drgnx-rec" nil ".el" ,contents)))
     (unwind-protect (progn ,@body)
       (delete-file ,var)
       (when (file-exists-p (concat ,var "c")) (delete-file (concat ,var "c"))))))

(defun drgnx-modules-record-test--timer-p (timer) (or (memq timer timer-list) (memq timer timer-idle-list)))

(ert-deftest drgnx-modules-record/global-hooks-are-recorded-local-are-not ()
  (drgnx-modules-record-test--with
   (with-temp-buffer
     (let ((buf (current-buffer)))
       (drgnx-module-define 'test/a :doc "a"
                            :setup (lambda ()
                                     (with-current-buffer buf
                                       (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-other nil t))
                                     (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-fn)))
       (drgnx-modules-record-test--run 'test/a)
       (should (eq (drgnx-modules-record-test--status 'test/a) 'ok))
       (should (equal (drgnx-modules-record-test--labels 'test/a)
                      '("hook drgnx-modules-record-test-hook drgnx-modules-record-test-fn")))
       (should-not (drgnx-module-teardown 'test/a))
       (should-not (memq #'drgnx-modules-record-test-fn (default-value 'drgnx-modules-record-test-hook)))
       (should (memq #'drgnx-modules-record-test-other (buffer-local-value 'drgnx-modules-record-test-hook buf)))))))

(ert-deftest drgnx-modules-record/a-library-top-level-is-not-recorded ()
  ;; The top level of a library the setup loads registers for itself (`drgnx-modules--recording-p').
  (drgnx-modules-record-test--with
   (drgnx-modules-record-test--with-file lib "(add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-other)\n"
     (drgnx-module-define 'test/a :doc "a" :setup (lambda () (load lib nil t)))
     (drgnx-modules-record-test--run 'test/a))
   (should-not (drgnx-modules-record-test--labels 'test/a))
   (drgnx-module-teardown 'test/a)
   (should (memq #'drgnx-modules-record-test-other drgnx-modules-record-test-hook))))

(ert-deftest drgnx-modules-record/a-helpers-own-calls-are-not-recorded ()
  ;; drgnx's paired helpers push their own undo (which respects other modules' claims) and bind
  ;; `drgnx-module--in-helper' while they call `add-hook' and `advice-add': the net records nothing then.
  (unwind-protect
      (drgnx-modules-record-test--with
       (drgnx-module-define 'test/a :doc "a"
                            :setup (lambda ()
                                     (let ((drgnx-module--in-helper t))
                                       (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-fn)
                                       (advice-add 'drgnx-modules-record-test-target :around
                                                   #'drgnx-modules-record-test-advice))))
       (drgnx-modules-record-test--run 'test/a)
       (should (eq (drgnx-modules-record-test--status 'test/a) 'ok))
       (should-not (drgnx-modules-record-test--labels 'test/a))
       (drgnx-module-teardown 'test/a)
       (should (memq #'drgnx-modules-record-test-fn drgnx-modules-record-test-hook)))
    (advice-remove 'drgnx-modules-record-test-target #'drgnx-modules-record-test-advice)))

(ert-deftest drgnx-modules-record/keeps-what-was-there ()
  (drgnx-modules-record-test--with
   (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-other)
   (setq drgnx-modules-record-test-list (list 'y))
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda ()
                                 (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-other)
                                 (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-fn)
                                 (add-to-list 'drgnx-modules-record-test-list 'y)
                                 (add-to-list 'drgnx-modules-record-test-list 'x)))
   (drgnx-modules-record-test--run 'test/a)
   (should (equal (length (drgnx-modules-record-test--labels 'test/a)) 2))
   (should-not (drgnx-module-teardown 'test/a))
   (should (equal drgnx-modules-record-test-hook (list #'drgnx-modules-record-test-other)))
   (should (equal drgnx-modules-record-test-list '(y)))))

(ert-deftest drgnx-modules-record/advice-is-recorded ()
  (unwind-protect
      (drgnx-modules-record-test--with
       (advice-add 'drgnx-modules-record-test-target :around #'drgnx-modules-record-test-advice-2)
       (drgnx-module-define 'test/a :doc "a"
                            :setup (lambda ()
                                     (advice-add 'drgnx-modules-record-test-target :around #'drgnx-modules-record-test-advice-2)
                                     (advice-add 'drgnx-modules-record-test-target :around #'drgnx-modules-record-test-advice)))
       (drgnx-modules-record-test--run 'test/a)
       (should (= (drgnx-modules-record-test-target 1) 12))
       (should (equal (drgnx-modules-record-test--labels 'test/a)
                      '("advice drgnx-modules-record-test-target drgnx-modules-record-test-advice")))
       (should-not (drgnx-module-teardown 'test/a))
       (should (= (drgnx-modules-record-test-target 1) 11))    ; the one that was there stays
       (should-not (advice-member-p #'drgnx-modules-record-test-advice 'drgnx-modules-record-test-target)))
    (advice-remove 'drgnx-modules-record-test-target #'drgnx-modules-record-test-advice)
    (advice-remove 'drgnx-modules-record-test-target #'drgnx-modules-record-test-advice-2)))

(ert-deftest drgnx-modules-record/add-to-list-is-recorded ()
  ;; Also from a byte-compiled caller: `add-to-list''s compiler macro leaves a call on a variable that is special
  ;; when the caller is compiled (it rewrites only lexical ones, and — the limit core.md states — a variable whose
  ;; `defvar' the compiling Emacs has not run yet, such as one defined in the caller's own file).
  (drgnx-modules-record-test--with
   (drgnx-modules-record-test--with-file
       lib (concat ";;; -*- lexical-binding: t -*-\n"
                   "(defvar drgnx-modules-record-test--own-list nil)\n"
                   "(defun drgnx-modules-record-test--compiled-add ()\n"
                   "  (add-to-list 'drgnx-modules-record-test-list 'z))\n"
                   "(defun drgnx-modules-record-test--compiled-own-add ()\n"
                   "  (add-to-list 'drgnx-modules-record-test--own-list 'z))\n")
     (let ((byte-compile-warnings nil)) (should (byte-compile-file lib)))
     (load (concat lib "c") nil t))
   (should (memq 'add-to-list (append (aref (symbol-function 'drgnx-modules-record-test--compiled-add) 2) nil)))
   (should-not (memq 'add-to-list (append (aref (symbol-function 'drgnx-modules-record-test--compiled-own-add) 2) nil)))
   (setq drgnx-modules-record-test-list (list 'y))
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda ()
                                 (add-to-list 'drgnx-modules-record-test-list 'x t)
                                 (drgnx-modules-record-test--compiled-add)
                                 (with-temp-buffer         ; a buffer-local value is not the global list
                                   (setq-local drgnx-modules-record-test-list nil)
                                   (add-to-list 'drgnx-modules-record-test-list 'w))))
   (drgnx-modules-record-test--run 'test/a)
   (should (equal drgnx-modules-record-test-list '(z y x)))
   (should (equal (drgnx-modules-record-test--labels 'test/a)
                  '("list drgnx-modules-record-test-list z" "list drgnx-modules-record-test-list x")))
   (push 'q drgnx-modules-record-test-list)                ; someone else's, added since
   (should-not (drgnx-module-teardown 'test/a))
   (should (equal drgnx-modules-record-test-list '(q y)))))

(ert-deftest drgnx-modules-record/a-drgnx-timer-is-cancelled ()
  (drgnx-modules-record-test--with
   (let ((before (run-with-timer 3600 nil #'ignore)) repeating pending)
     (unwind-protect
         (progn
           (drgnx-module-define 'test/a :doc "a"
                                :setup (lambda ()
                                         (setq repeating (run-with-timer 3600 60 #'drgnx-modules-record-test-fn)
                                               pending (run-with-idle-timer 3600 nil #'drgnx-modules-record-test-other))))
           (drgnx-modules-record-test--run 'test/a)
           (should (equal (sort (drgnx-modules-record-test--labels 'test/a) #'string<)
                          '("timer drgnx-modules-record-test-fn" "timer drgnx-modules-record-test-other")))
           (should-not (drgnx-module-teardown 'test/a))
           (should-not (drgnx-modules-record-test--timer-p repeating))
           (should-not (drgnx-modules-record-test--timer-p pending))
           (should (drgnx-modules-record-test--timer-p before)))
       (dolist (tm (list before repeating pending)) (when tm (cancel-timer tm)))))))

(defun drgnx-modules-record-test--left (name) (plist-get (alist-get name drgnx-modules--report) :left))

(defvar drgnx-modules-record-test--ends nil "What the run-end hook saw, newest first: (MODULE TOKEN INHIBIT).")
(defun drgnx-modules-record-test--end (module)
  (push (list module (alist-get module drgnx-modules--runs) inhibit-interaction) drgnx-modules-record-test--ends))
(defun drgnx-modules-record-test--end-fails (_module) (error "Boom"))

(ert-deftest drgnx-modules-record/the-run-end-hook-runs-on-teardown-rollback-and-rerun ()
  (drgnx-modules-record-test--with
   (let ((drgnx-modules-run-end-functions '(drgnx-modules-record-test--end)) (drgnx-modules-record-test--ends nil))
     (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
     (drgnx-module-define 'test/bad :doc "bad" :setup (lambda () (error "No")))
     (drgnx-module-define 'test/r :doc "r" :setup #'ignore :teardown 'restart)
     ;; teardown: the token is gone when the hook runs, and nothing can prompt
     (drgnx-modules-record-test--run 'test/a)
     (should-not drgnx-modules-record-test--ends)
     (should-not (drgnx-module-teardown 'test/a))
     (should (equal drgnx-modules-record-test--ends '((test/a nil t))))
     ;; rollback
     (drgnx-modules-record-test--run 'test/bad)
     (should (eq (drgnx-modules-record-test--status 'test/bad) 'failed))
     (should (equal (car drgnx-modules-record-test--ends) '(test/bad nil t)))
     (should (= 2 (length drgnx-modules-record-test--ends)))
     ;; a run again: a restart module keeps its token until the new run, which ends the old one first
     (drgnx-modules-record-test--run 'test/r)
     (should (= 2 (length drgnx-modules-record-test--ends)))
     (let ((old (alist-get 'test/r drgnx-modules--runs)))
       (drgnx-modules-record-test--run 'test/r)
       (should (= 3 (length drgnx-modules-record-test--ends)))
       (should (equal (car drgnx-modules-record-test--ends) '(test/r nil t)))
       (should (alist-get 'test/r drgnx-modules--runs))
       (should-not (eq old (alist-get 'test/r drgnx-modules--runs)))))))

(ert-deftest drgnx-modules-record/a-failing-run-end-function-is-a-problem-not-an-error ()
  (drgnx-modules-record-test--with
   (let ((drgnx-modules-run-end-functions '(drgnx-modules-record-test--end-fails drgnx-modules-record-test--end))
         (drgnx-modules-record-test--ends nil))
     (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
     (drgnx-modules-record-test--run 'test/a)
     (should (equal (drgnx-module-teardown 'test/a)
                    '("run end: drgnx-modules-record-test--end-fails: Boom")))
     (should (= 1 (length drgnx-modules-record-test--ends))))))   ; the next function still ran

(ert-deftest drgnx-modules-record/an-elpa-singleton-survives-and-is-left ()
  ;; A library outside drgnx-dir starts its singleton timer lazily from a function a setup calls.
  (drgnx-modules-record-test--with
   (let* ((dir (make-temp-file "drgnx-elpa" t)) (file (expand-file-name "fake-elpa.el" dir)))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "(defvar fake-elpa--timer nil)\n(defun fake-elpa--tick () nil)\n"
                     "(defun fake-elpa-start ()\n"
                     "  (unless fake-elpa--timer (setq fake-elpa--timer (run-with-timer 3600 nil #'fake-elpa--tick))))\n"))
           (load file nil t)
           (drgnx-module-define 'test/a :doc "a" :setup (lambda () (fake-elpa-start)))
           (drgnx-modules-record-test--run 'test/a)
           (should-not (drgnx-modules-record-test--labels 'test/a))
           (should-not (drgnx-module-teardown 'test/a))
           (should (drgnx-modules-record-test--timer-p fake-elpa--timer))
           (should (equal (drgnx-modules-record-test--left 'test/a)
                          (list (format "timer fake-elpa--tick (%s)" (symbol-file 'fake-elpa--tick 'defun)))))
           (should (string-suffix-p "fake-elpa.el)" (car (drgnx-modules-record-test--left 'test/a)))))
       (when (boundp 'fake-elpa--timer) (when (timerp fake-elpa--timer) (cancel-timer fake-elpa--timer)))
       (mapc #'unintern '("fake-elpa--timer" "fake-elpa--tick" "fake-elpa-start"))
       (setq load-history (cl-remove file load-history :key #'car :test #'equal))
       (delete-directory dir t)))))

(ert-deftest drgnx-modules-record/a-lambda-is-left-and-reported ()
  (drgnx-modules-record-test--with
   (let (tm)
     (unwind-protect
         (progn
           (drgnx-module-define 'test/a :doc "a" :setup (lambda () (setq tm (run-with-timer 3600 nil (lambda () nil)))))
           (drgnx-modules-record-test--run 'test/a)
           (should-not (drgnx-modules-record-test--labels 'test/a))
           (should-not (drgnx-module-teardown 'test/a))
           (should (drgnx-modules-record-test--timer-p tm))
           (should (equal (drgnx-modules-record-test--left 'test/a) '("timer a lambda")))
           ;; a new run starts the list again
           (cancel-timer tm)
           (drgnx-modules-record-test--run 'test/a)
           (should (equal (drgnx-modules-record-test--left 'test/a) '("timer a lambda"))))
       (when tm (cancel-timer tm))
       (drgnx-module-teardown 'test/a)))))

(ert-deftest drgnx-modules-record/a-layer-timer-gets-no-net-undo ()
  (drgnx-modules-record-test--with
   (unwind-protect
       (progn
         (drgnx-module-define 'test/a :doc "a"
                              :setup (lambda () (drgnx-timer-start 'rec-k 3600 #'drgnx-modules-record-test-fn)))
         (drgnx-modules-record-test--run 'test/a)
         (should-not (drgnx-modules-record-test--labels 'test/a))   ; the run token owns it
         (should-not (drgnx-modules-record-test--left 'test/a))     ; and it is not "left"
         (should (drgnx-timer-active-p 'rec-k))
         (should-not (drgnx-module-teardown 'test/a))
         (should-not (drgnx-timer-active-p 'rec-k)))
     (drgnx-timer-reset))))

(ert-deftest drgnx-modules-record/newly-on-global-modes-go-off ()
  (drgnx-modules-record-test--with
   (drgnx-modules-record-test-a-mode 1)
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda () (drgnx-modules-record-test-a-mode 1) (drgnx-modules-record-test-b-mode 1)))
   (drgnx-modules-record-test--run 'test/a)
   (should (equal (drgnx-modules-record-test--labels 'test/a) '("mode drgnx-modules-record-test-b-mode")))
   (should-not (drgnx-module-teardown 'test/a))
   (should-not drgnx-modules-record-test-b-mode)
   (should drgnx-modules-record-test-a-mode)))

(ert-deftest drgnx-modules-record/features-are-reported-not-unloaded ()
  (drgnx-modules-record-test--with
   (drgnx-modules-record-test--with-file lib "(provide 'drgnx-modules-record-test-feature)\n"
     (unwind-protect
         (progn
           (drgnx-module-define 'test/a :doc "a" :setup (lambda () (load lib nil t)))
           (drgnx-modules-record-test--run 'test/a)
           (should (equal (drgnx-modules-features-of 'test/a) '(drgnx-modules-record-test-feature)))
           (should-not (drgnx-module-teardown 'test/a))
           (should (featurep 'drgnx-modules-record-test-feature))
           (should (equal (drgnx-modules-features-of 'test/a) '(drgnx-modules-record-test-feature))))
       (setq features (delq 'drgnx-modules-record-test-feature features))))))

(ert-deftest drgnx-modules-record/after-load-forms-belong-to-nobody ()
  ;; Another library's `eval-after-load' forms that a setup's `require' triggers run once: recorded, they would be
  ;; undone and never come back when the module is turned on again.  So they record nothing.
  (drgnx-modules-record-test--with
   (drgnx-modules-record-test--with-file lib "(provide 'drgnx-modules-record-test-late)\n"
     (let ((timer nil))
       (unwind-protect
           (progn
             (with-eval-after-load 'drgnx-modules-record-test-late
               (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-other)
               (setq timer (run-with-timer 3600 nil #'drgnx-modules-record-test-other)))
             (drgnx-module-define 'test/a :doc "a"
                                  :setup (lambda ()
                                           (load lib nil t)
                                           (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-fn)))
             (drgnx-modules-record-test--run 'test/a)
             (should timer)
             (should (equal (drgnx-modules-record-test--labels 'test/a)
                            '("hook drgnx-modules-record-test-hook drgnx-modules-record-test-fn")))
             (should-not (drgnx-module-teardown 'test/a))
             (should (equal drgnx-modules-record-test-hook (list #'drgnx-modules-record-test-other)))
             (should (drgnx-modules-record-test--timer-p timer)))
         (when timer (cancel-timer timer))
         (setq after-load-alist (assq-delete-all 'drgnx-modules-record-test-late after-load-alist)
               features (delq 'drgnx-modules-record-test-late features)))))))

(ert-deftest drgnx-modules-record/a-nested-setup-keeps-its-own ()
  ;; A module whose setup runs inside another's: what it reaches is its own, not the outer module's too.
  (drgnx-modules-record-test--with
   (let (timer)
     (unwind-protect
         (progn
           (drgnx-module-define 'test/b :doc "b" :stage 'idle
                                :setup (lambda () (setq timer (run-with-timer 3600 nil #'drgnx-modules-record-test-fn))
                                         (drgnx-modules-record-test-b-mode 1)))
           (drgnx-module-define 'test/a :doc "a"
                                :setup (lambda () (drgnx-modules--run-one 'test/b (alist-get 'test/b drgnx-modules--table) 'idle)))
           (drgnx-modules-record-test--run 'test/a)
           (should-not (drgnx-modules-record-test--labels 'test/a))
           (should (equal (drgnx-modules-record-test--labels 'test/b)
                          '("mode drgnx-modules-record-test-b-mode" "timer drgnx-modules-record-test-fn"))))
       (when timer (cancel-timer timer))))))

(ert-deftest drgnx-modules-record/with-owner-records-deferred-work ()
  (drgnx-modules-record-test--with
   (drgnx-modules-record-test--with-file lib "(provide 'drgnx-modules-record-test-later)\n"
     (let (later timer)
       (unwind-protect
           (progn
             (drgnx-module-define 'test/a :doc "a"
                                  :setup (lambda ()
                                           (eval-after-load 'drgnx-modules-record-test-later
                                             (drgnx-modules-with-owner
                                               (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-fn)))
                                           (setq later (drgnx-modules-with-owner
                                                         (setq timer (run-with-timer 3600 nil #'drgnx-modules-record-test-other))
                                                         (drgnx-modules-record-test-b-mode 1)
                                                         'ran))))
             (drgnx-modules-record-test--run 'test/a)
             (should (equal (drgnx-modules-record-test--labels 'test/a) '("after-load drgnx-modules-record-test-later")))
             (load lib nil t)                                  ; later, outside any setup
             (should (eq (funcall later) 'ran))                ; a timer callback, say
             (should (equal (drgnx-modules-record-test--labels 'test/a)
                            '("mode drgnx-modules-record-test-b-mode" "timer drgnx-modules-record-test-other"
                              "hook drgnx-modules-record-test-hook drgnx-modules-record-test-fn"
                              "after-load drgnx-modules-record-test-later")))
             (should-not drgnx-modules--current)
             (should-not (drgnx-module-teardown 'test/a))
             (should-not drgnx-modules-record-test-hook)
             (should-not drgnx-modules-record-test-b-mode)
             (should-not (drgnx-modules-record-test--timer-p timer)))
         (when timer (cancel-timer timer))
         (setq after-load-alist (assq-delete-all 'drgnx-modules-record-test-later after-load-alist)
               features (delq 'drgnx-modules-record-test-later features)))))))

(ert-deftest drgnx-modules-record/with-owner-skips-a-module-turned-off ()
  (drgnx-modules-record-test--with
   (let (later)
     (drgnx-module-define 'test/a :doc "a"
                          :setup (lambda ()
                                   (push (drgnx-modules-with-owner (push 'ran drgnx-modules-record-test-ran)) later)))
     (drgnx-modules-record-test--run 'test/a)
     (drgnx-module-teardown 'test/a)
     (should-not (funcall (car later)))
     (should-not drgnx-modules-record-test-ran)
     ;; turned on again: only the new run's deferred work runs, once
     (drgnx-modules-record-test--run 'test/a)
     (mapc #'funcall later)
     (should (equal drgnx-modules-record-test-ran '(ran)))
     ;; outside a setup there is no owner: the work just runs
     (should (equal (funcall (drgnx-modules-with-owner 'plain)) 'plain)))))

(ert-deftest drgnx-modules-record/after-load-entries-go-with-the-module ()
  ;; The function a setup's `eval-after-load' adds goes at teardown, whether its feature is loaded or not; another's
  ;; form for the same feature stays.  On, off, on, then the feature loads: the deferred work runs once (a stale
  ;; entry would make `eval-after-load' drop the new run's function as `equal').
  (drgnx-modules-record-test--with
   (let ((theirs (lambda () nil)))
     (unwind-protect
         (progn
           (eval-after-load 'drgnx-modules-record-test-eal theirs)
           ;; for a feature Emacs stores a wrapper around the function: that object is theirs in the entry
           (setq theirs (car (last (assq 'drgnx-modules-record-test-eal after-load-alist))))
           (drgnx-module-define 'test/a :doc "a"
                                :setup (lambda ()
                                         (eval-after-load 'drgnx-modules-record-test-eal
                                           (drgnx-modules-with-owner (push 'ran drgnx-modules-record-test-ran)))
                                         (eval-after-load 'cl-lib (drgnx-modules-with-owner nil))))
           (let ((n (length (assq 'drgnx-modules-record-test-eal after-load-alist)))
                 (n-cl (length (cdr (assq 'cl-lib after-load-alist)))))   ; forms: an emptied entry stays
             (drgnx-modules-record-test--run 'test/a)
             (should (= (length (assq 'drgnx-modules-record-test-eal after-load-alist)) (1+ n)))
             (should-not (drgnx-module-teardown 'test/a))
             (should (= (length (assq 'drgnx-modules-record-test-eal after-load-alist)) n))
             (should (= (length (cdr (assq 'cl-lib after-load-alist))) n-cl))
             (drgnx-modules-record-test--run 'test/a)                    ; on again
             (let ((load-file-name nil)) (provide 'drgnx-modules-record-test-eal))
             (should (equal drgnx-modules-record-test-ran '(ran)))
             (should-not (drgnx-module-teardown 'test/a))
             (should (memq theirs (cdr (assq 'drgnx-modules-record-test-eal after-load-alist))))))
       (setq after-load-alist (assq-delete-all 'drgnx-modules-record-test-eal after-load-alist)
             features (delq 'drgnx-modules-record-test-eal features))))))

(defconst drgnx-modules-record-test--net '(add-hook advice-add add-to-list do-after-load-evaluation eval-after-load)
  "The functions the safety net advises while a setup runs.")

(ert-deftest drgnx-modules-record/the-advice-is-gone-after-setup ()
  (drgnx-modules-record-test--with
   (let ((before (mapcar #'symbol-function drgnx-modules-record-test--net)) during timer)
     (unwind-protect
         (progn
           (drgnx-module-define 'test/a :doc "a"
                                :setup (lambda () (setq during (mapcar #'symbol-function drgnx-modules-record-test--net))))
           (drgnx-module-define 'test/b :doc "b"
                                :setup (lambda ()
                                         (add-hook 'drgnx-modules-record-test-hook #'drgnx-modules-record-test-fn)
                                         (setq timer (run-with-timer 3600 nil #'drgnx-modules-record-test-other))
                                         (drgnx-modules-record-test-b-mode 1)
                                         (error "Boom")))
           (drgnx-modules-record-test--run 'test/a)
           (should-not (equal during before))                ; it was there while the setup ran
           (should (cl-every #'eq (mapcar #'symbol-function drgnx-modules-record-test--net) before))
           (drgnx-modules-record-test--run 'test/b)
           (should (eq (drgnx-modules-record-test--status 'test/b) 'failed))
           (should (cl-every #'eq (mapcar #'symbol-function drgnx-modules-record-test--net) before))
           ;; and the failed setup's hook, timer and mode were rolled back
           (should-not drgnx-modules-record-test-hook)
           (should-not (drgnx-modules-record-test--timer-p timer))
           (should-not drgnx-modules-record-test-b-mode)
           (catch 'out (drgnx-modules--run-setup 'test/c (lambda () (throw 'out nil))))
           (should (cl-every #'eq (mapcar #'symbol-function drgnx-modules-record-test--net) before)))
       (when timer (cancel-timer timer))))))

(defun drgnx-modules-record-test--startup (net)
  "In a fresh Emacs, run the shipped modules' startup stage; NET nil: without the recorder.
Returns (STATUSES COMMANDS STACKS), STACKS the number of modules with a cleanup stack."
  (with-temp-buffer
    (let ((form `(progn
                   (require 'drgnx)
                   ,@(unless net '((advice-add 'drgnx-modules--record-call :override (lambda (_m fn) (funcall fn)))))
                   (drgnx--core-commands)
                   (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
                   (drgnx-modules-run 'startup)
                   (let ((print-length nil) (print-level nil))
                     (prin1 (list (mapcar (lambda (m) (cons (car m) (plist-get (cdr m) :status))) (drgnx-modules-report))
                                  drgnx-commands--order (length drgnx-modules--stacks)))))))
      (should (eq 0 (call-process (expand-file-name invocation-name invocation-directory) nil '(t nil) nil
                                  "-Q" "--batch"
                                  "--eval" (format "(setq load-prefer-newer %S load-path '%S)" load-prefer-newer load-path)
                                  "--eval" (prin1-to-string form))))
      (goto-char (point-max))
      (backward-sexp)
      (read (current-buffer)))))

(ert-deftest drgnx-modules-record/startup-is-unchanged ()
  ;; The shipped modules' startup stage gives the same statuses and commands with the recorder as without it.
  (let ((with (drgnx-modules-record-test--startup t)) (without (drgnx-modules-record-test--startup nil)))
    (should (> (length (car with)) 5))
    (should (> (length (cadr with)) 20))
    (should (> (nth 2 with) 5))                         ; the recorder did run
    (should (equal (take 2 with) (take 2 without)))))

(ert-deftest drgnx-modules-record/emacs-own-timers-are-left-alone ()
  ;; Emacs's libraries keep singleton timers in variables and start them lazily from code a setup calls (an edit
  ;; starts undo's boundary timer, a buffer's jit-lock its context timer).  Cancelled, they would stay dead for the
  ;; session: undo boundaries for process output would stop.
  (require 'jit-lock)
  (drgnx-modules-record-test--with
   (dolist (var '(undo-auto-current-boundary-timer jit-lock-context-timer))
     (when (timerp (symbol-value var)) (cancel-timer (symbol-value var)))
     (set var nil))
   (let ((buf (generate-new-buffer " drgnx-undo")))
     (unwind-protect
         (progn
           (drgnx-module-define 'test/a :doc "a"
                                :setup (lambda ()
                                         (with-current-buffer buf (buffer-enable-undo) (insert "a"))
                                         (let ((jit-lock-contextually t)) (with-temp-buffer (jit-lock-mode 1)))))
           (drgnx-modules-record-test--run 'test/a)
           (should (timerp undo-auto-current-boundary-timer))
           (should (timerp jit-lock-context-timer))
           (should-not (drgnx-modules-record-test--labels 'test/a))
           (should-not (drgnx-module-teardown 'test/a))     ; torn down at once, well inside undo's 10 s
           (should (drgnx-modules-record-test--timer-p undo-auto-current-boundary-timer))
           (should (drgnx-modules-record-test--timer-p jit-lock-context-timer))
           (let ((left (drgnx-modules-record-test--left 'test/a)))   ; and said so
             (should (cl-some (lambda (l) (string-prefix-p "timer undo-auto--boundary-timer (" l)) left))
             (should (member "timer a lambda" left))))
       (kill-buffer buf)))))

(ert-deftest drgnx-modules-record/a-helpers-mode-stays-while-another-module-claims-it ()
  ;; Module a turns a mode on through an option's setter, b sets the same option: tearing a down leaves the mode
  ;; on (b's claim stands); tearing b down too turns it off.  The net records nothing of a helper's own change.
  (drgnx-modules-record-test--with
   (unwind-protect
       (progn
         (drgnx-module-define 'test/a :doc "a" :setup (lambda () (drgnx-module-set 'drgnx-modules-record-test-opt t)))
         (drgnx-module-define 'test/b :doc "b" :setup (lambda () (drgnx-module-set 'drgnx-modules-record-test-opt t)))
         (drgnx-modules-record-test--run 'test/a)
         (drgnx-modules-record-test--run 'test/b)
         (should drgnx-modules-record-test-opt-mode)
         (should (equal (drgnx-modules-record-test--labels 'test/a) '("option drgnx-modules-record-test-opt")))
         (should-not (drgnx-module-teardown 'test/a))
         (should drgnx-modules-record-test-opt-mode)
         (should-not (drgnx-module-teardown 'test/b))
         (should-not drgnx-modules-record-test-opt-mode)
         (should-not drgnx-modules-record-test-opt))
     (drgnx-modules-record-test-opt-mode -1)
     (set-default 'drgnx-modules-record-test-opt nil))))

(ert-deftest drgnx-modules-record/a-helpers-hook-is-recorded-once ()
  ;; Two modules add the same function through the paired helper: one entry each (the helper's), and either
  ;; teardown keeps the function while the other module still claims it.
  (drgnx-modules-record-test--with
   (dolist (m '(test/a test/b))
     (drgnx-module-define m :doc "m"
                          :setup (lambda () (drgnx-module--hook-add 'drgnx-modules-record-test-hook
                                                                    #'drgnx-modules-record-test-fn nil))))
   (drgnx-modules-record-test--run 'test/a)
   (drgnx-modules-record-test--run 'test/b)
   (should (= (length (drgnx-modules-record-test--labels 'test/a)) 1))
   (should (= (length (drgnx-modules-record-test--labels 'test/b)) 1))
   (should-not (drgnx-module-teardown 'test/a))
   (should (memq #'drgnx-modules-record-test-fn drgnx-modules-record-test-hook))
   (should-not (drgnx-module-teardown 'test/b))
   (should-not drgnx-modules-record-test-hook)))

(ert-deftest drgnx-modules-record/add-to-list-compares-as-add-to-list-does ()
  ;; `add-to-list' calls COMPARE with the new element first: "abc" is not a prefix of "ab", so it is added.
  (drgnx-modules-record-test--with
   (setq drgnx-modules-record-test-list (list "ab"))
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda () (add-to-list 'drgnx-modules-record-test-list "abc" nil #'string-prefix-p)))
   (drgnx-modules-record-test--run 'test/a)
   (should (equal drgnx-modules-record-test-list '("abc" "ab")))
   (should (= (length (drgnx-modules-record-test--labels 'test/a)) 1))
   (should-not (drgnx-module-teardown 'test/a))
   (should (equal drgnx-modules-record-test-list '("ab")))))

(ert-deftest drgnx-modules-record/labels-are-short ()
  (drgnx-modules-record-test--with
   (drgnx-module-define 'test/a :doc "a"
                        :setup (lambda () (add-to-list 'drgnx-modules-record-test-list (make-string 500 ?x))))
   (drgnx-modules-record-test--run 'test/a)
   (should (<= (length (car (drgnx-modules-record-test--labels 'test/a))) 120))))

;;; modules-record-test.el ends here
