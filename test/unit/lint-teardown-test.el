;;; lint-teardown-test.el --- every module turns off cleanly: the dynamic check and its lints -*- lexical-binding: t -*-
;; The rule (docs/develop/core.md, "Writing a module that can be turned off"): a module's setup changes global
;; state only through recorded doors, and its :teardown undoes the rest (or it is `:teardown 'restart').
;; - `drgnx-teardown/every-module-leaves-nothing' sets each shipped module up alone with `drgnx-test-with-modules'
;;   `:strict t' and turns it off: the state after equals the state before.
;; - `drgnx-teardown/off-on-off-is-off': turned off and on again, a module sets up what its first setup did and no
;;   more (no stacked timers), and its last teardown still leaves nothing.
;; - The lints read modules/ with the Lisp reader (comments never count): nothing registers at load, and the raw
;;   forms the recorder cannot see need a :teardown.
;; Modules not converted yet are on `drgnx-teardown--not-yet', each with the migration batch that converts it;
;; the list shrinks to empty.
(require 'ert)
(require 'ert-x)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defconst drgnx-teardown--not-yet
  '((core/basics :until 15) (core/workbench :until 15)
    (editor/editing :until 16) (editor/sticky :until 16) (ui/look :until 16) (ui/smooth :until 16) (org/org :until 16)
    (extra/blame :until 18) (extra/booster :until 18) (extra/completion :until 18) (extra/debug :until 18)
    (extra/format :until 18) (extra/guides :until 18) (extra/hunks :until 18) (extra/jump :until 18)
    (extra/keycast :until 18) (extra/llm :until 18) (extra/magit :until 18) (extra/mc :until 18)
    (extra/undo :until 18) (extra/wgrep :until 18) (extra/windows :until 18)
    (tools/agents :until 19) (tools/ai :until 19) (tools/jobs :until 19) (tools/live :until 19) (tools/work :until 19)
    (tools/layouts :until 20) (tools/browser :until 20) (tools/replace :until 20) (tools/search :until 20)
    (tools/shortcuts :until 20)
    (tools/diff :until 21) (tools/review :until 21) (tools/prs :until 21) (tools/vc :until 21)
    (tools/commit-message :until 21) (tools/terminal :until 21)
    (editor/clipboard :until 22) (tools/agent-settings :until 22) (tools/remote :until 22) (ui/terminal :until 22)
    (ui/terminal-keys :until 22) (ui/terminal-layout :until 22) (ui/terminal-popups :until 22))
  "Shipped modules not yet converted to turn off cleanly: (MODULE :until BATCH), BATCH the number of the
migration batch that converts it and takes it off.  The dynamic check and the raw-forms lint skip them.")

(defconst drgnx-teardown--load-registrations
  '(("modules/tools/drgnx-replace.el" advice-add :until 20)
    ("modules/tools/drgnx-replace.el" with-eval-after-load :until 20)
    ("modules/tools/drgnx-shortcuts.el" with-eval-after-load :until 20)
    ("modules/tools/drgnx-ai-ui.el" add-to-list :until 19))
  "Registrations at the top level of a module file that are known and wait for their batch: (FILE CALL :until
BATCH).  One that is gone fails the lint too, so the entry goes with it.")

(defconst drgnx-teardown--library-files
  '(("modules/ui/drgnx-tty-clipboard.el" . ui/terminal)
    ("modules/ui/drgnx-tty-fallback-layer.el" . ui/terminal))
  "Files under modules/ that define no module: (FILE . the MODULE whose setup uses them).")

;;;; Reading modules/

(defun drgnx-teardown--forms (file)
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun drgnx-teardown--files ()
  (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\.el\\'"))

(defun drgnx-teardown--rel (file) (file-relative-name file drgnx-dir))

(defun drgnx-teardown--defines (file)
  "((NAME . ARGS)…) of the `drgnx-module-define' forms of FILE, ARGS as written (nothing is evaluated)."
  (let (out)
    (dolist (form (drgnx-teardown--forms file))
      (pcase form (`(drgnx-module-define (quote ,name) . ,args) (push (cons name args) out))))
    (nreverse out)))

(defvar drgnx-teardown--modules-cache nil)

(defun drgnx-teardown--modules ()
  "((NAME FILE . ARGS)…) for every shipped module, read from modules/ once."
  (or drgnx-teardown--modules-cache
      (setq drgnx-teardown--modules-cache
            (seq-mapcat (lambda (f) (mapcar (lambda (d) (cons (car d) (cons (drgnx-teardown--rel f) (cdr d))))
                                            (drgnx-teardown--defines f)))
                        (drgnx-teardown--files)))))

(defun drgnx-teardown--restart-p (module)
  "MODULE (NAME FILE . ARGS) is written `:teardown \\='restart'."
  (equal (plist-get (cddr module) :teardown) ''restart))

;;;; The dynamic check

(defun drgnx-teardown--checked (modules not-yet)
  "The names of MODULES ((NAME FILE . ARGS)…) the dynamic check sets up: not on NOT-YET, not restart-only."
  (mapcar #'car (seq-remove (lambda (m) (or (assq (car m) not-yet) (drgnx-teardown--restart-p m))) modules)))

(defun drgnx-teardown--elpa-path ()
  "The package directories of the user's ELPA, used read-only when present (as `mod-amenities-test')."
  (let ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))))
    (and (file-directory-p elpa) (seq-filter #'file-directory-p (directory-files elpa t "\\`[^.]")))))

(defmacro drgnx-teardown--with-packages (&rest body)
  "BODY with the user's packages on `load-path' and no outside program found (none is started)."
  `(let ((load-path (append load-path (drgnx-teardown--elpa-path))))
     (cl-letf (((symbol-function 'executable-find) #'ignore))
       ,@body)))

(defun drgnx-teardown--again (name)
  "Turn module NAME off and on again through the product path; fail when the second setup adds something
other than the first did (something stacked, or a guard that outlived the teardown).  Compared by description
\(kind, key, function, repeat), not identity: a timer, buffer or closure made again is the same thing."
  (let* ((on (drgnx-modules-fingerprint))
         (_ (drgnx-module-teardown name))
         (off (drgnx-modules-fingerprint))
         (spec (cdr (assq name drgnx-modules--table))))
    (drgnx-modules--run-one name spec (plist-get spec :stage))
    (let ((first (sort (drgnx-test-modules--diff-lines off on) #'string<))
          (again (sort (drgnx-test-modules--diff-lines off (drgnx-modules-fingerprint)) #'string<)))
      (unless (equal first again)
        (ert-fail (list "on again, the module did not set up what it did the first time:"
                        :first first :again again))))))

(defun drgnx-teardown--leftovers (module &optional again)
  "Set MODULE (a name, or a fake module's file) up alone, strictly, and turn it off (with AGAIN: off and on
once in between).  Returns (STATUS . FAILURE): the status its setup reached, and nil or why it failed."
  (let ((status nil))
    (condition-case err
        (progn (drgnx-test-with-modules (list module) :strict t
                                        (let ((name (if (stringp module) (car (car (last drgnx-modules--table))) module)))
                                          (setq status (plist-get (alist-get name (drgnx-modules-report)) :status))
                                          (when (and again (eq status 'ok)) (drgnx-teardown--again name))))
               (cons status nil))
      (ert-test-failed (cons status (cdr err))))))

(defun drgnx-teardown--say (checked results)
  "Print what the check covered: the modules it checked, those whose setup did not run here, those pending."
  (let ((idle (delq nil (cl-mapcar (lambda (m r) (unless (eq (car r) 'ok) (cons m (car r)))) checked results))))
    (message "teardown check: %d module(s) checked, %d not set up here%s, %d pending a migration batch"
             (length checked) (length idle) (if idle (format " %S" idle) "") (length drgnx-teardown--not-yet))))

(ert-deftest drgnx-teardown/every-module-leaves-nothing ()
  (let ((checked (drgnx-teardown--checked (drgnx-teardown--modules) drgnx-teardown--not-yet)) (results nil))
    (drgnx-teardown--with-packages
     (dolist (m checked) (push (drgnx-teardown--leftovers m) results)))
    (setq results (nreverse results))
    (drgnx-teardown--say checked results)
    ;; every module checked, each failure named with its module
    (should (equal (delq nil (cl-mapcar (lambda (m r) (and (cdr r) (cons m (cdr r)))) checked results)) nil))))

(ert-deftest drgnx-teardown/off-on-off-is-off ()
  (let (failures)
    (drgnx-teardown--with-packages
     (dolist (m (drgnx-teardown--checked (drgnx-teardown--modules) drgnx-teardown--not-yet))
       (when-let* ((f (cdr (drgnx-teardown--leftovers m t)))) (push (cons m f) failures))))
    (should (equal (nreverse failures) nil))))

(ert-deftest drgnx-teardown/the-lists-name-shipped-modules ()
  ;; Every entry is a shipped module with its batch; every file under modules/ defines a module or is listed.
  (let ((names (mapcar #'car (drgnx-teardown--modules))))
    (should (equal (seq-remove (lambda (e) (and (memq (car e) names) (natnump (plist-get (cdr e) :until))))
                               drgnx-teardown--not-yet)
                   nil))
    (should (equal (seq-remove (lambda (f) (or (drgnx-teardown--defines f)
                                               (assoc (drgnx-teardown--rel f) drgnx-teardown--library-files)))
                               (drgnx-teardown--files))
                   nil))))

;;;; The check, on fake modules

(defun drgnx-teardown-test--fake (dir name contents)
  "Write the fake module file NAME.el under DIR holding CONTENTS; return its path."
  (let ((file (expand-file-name (concat name ".el") dir)))
    (with-temp-file file (insert ";;; " name ".el --- a fake module -*- lexical-binding: t -*-\n" contents))
    file))

(defvar drgnx-teardown-test--timer nil "The fake guarded module's timer.")

(defun drgnx-teardown-test--leaky () nil)
(defun drgnx-teardown-test--tick () nil)

(ert-deftest drgnx-teardown/the-check-sees-a-leak ()
  ;; A module off the not-yet list is checked; one whose setup reaches a hook outside every door fails, named.
  (ert-with-temp-directory dir
                           (let ((leaky (drgnx-teardown-test--fake dir "fake-leaky" "(drgnx-module-define 'fake/leaky :doc \"leaks\"
  :setup (lambda () (push #'drgnx-teardown-test--leaky (default-value 'find-file-hook))))"))
                                 (clean (drgnx-teardown-test--fake dir "fake-clean" "(drgnx-module-define 'fake/clean :doc \"clean\"
  :setup (lambda () (add-hook 'find-file-hook #'drgnx-teardown-test--leaky)))")))
                             (let ((modules (append (drgnx-teardown--defines leaky) (drgnx-teardown--defines clean))))
                               (should (equal (drgnx-teardown--checked (mapcar (lambda (d) (cons (car d) (cons "f" (cdr d)))) modules)
                                                                       '((fake/leaky :until 99)))
                                              '(fake/clean))))
                             (unwind-protect
                                 (let ((r (drgnx-teardown--leftovers leaky)))
                                   (should (eq (car r) 'ok))
                                   (should (string-match-p "hook find-file-hook \\+drgnx-teardown-test--leaky" (format "%S" (cdr r)))))
                               (remove-hook 'find-file-hook #'drgnx-teardown-test--leaky))
                             (should (equal (drgnx-teardown--leftovers clean) '(ok)))
                             (should-not (memq 'drgnx-teardown-test--leaky (default-value 'find-file-hook))))))

(ert-deftest drgnx-teardown/on-again-sees-a-guard-that-outlived-the-teardown ()
  ;; The timer is recorded and cancelled at teardown, but the variable still holds it: on again, the guard
  ;; starts nothing.  One teardown alone looks clean; off and on again does not.
  (ert-with-temp-directory dir
                           (let ((guarded (drgnx-teardown-test--fake dir "fake-guarded" "(drgnx-module-define 'fake/guarded :doc \"guarded\"
  :setup (lambda () (unless drgnx-teardown-test--timer
                      (setq drgnx-teardown-test--timer (run-with-timer 600 600 #'drgnx-teardown-test--tick)))))")))
                             (unwind-protect
                                 (progn
                                   (should (equal (drgnx-teardown--leftovers guarded) '(ok)))
                                   (setq drgnx-teardown-test--timer nil)
                                   (let ((r (drgnx-teardown--leftovers guarded t)))
                                     (should (eq (car r) 'ok))
                                     (should (string-match-p "on again.*timer" (format "%S" (cdr r))))))
                               (when (timerp drgnx-teardown-test--timer) (cancel-timer drgnx-teardown-test--timer))
                               (setq drgnx-teardown-test--timer nil)))))

(ert-deftest drgnx-teardown/on-again-passes-what-is-made-again ()
  ;; A timer the second setup starts again is a new object but the same thing; deferred work through
  ;; `eval-after-load' and `drgnx-modules-with-owner' (the documented pattern) leaves nothing either.
  (ert-with-temp-directory dir
                           (let ((timed (drgnx-teardown-test--fake dir "fake-timed" "(drgnx-module-define 'fake/timed :doc \"timed\"
  :setup (lambda () (run-with-timer 600 600 #'drgnx-teardown-test--tick)))"))
                                 (deferred (drgnx-teardown-test--fake dir "fake-deferred" "(drgnx-module-define 'fake/deferred :doc \"deferred\"
  :setup (lambda () (eval-after-load 'drgnx-teardown-test-never-loaded
                      (drgnx-modules-with-owner (add-hook 'find-file-hook #'drgnx-teardown-test--leaky)))))")))
                             (should (equal (drgnx-teardown--leftovers timed t) '(ok)))
                             (should (equal (drgnx-teardown--leftovers deferred) '(ok)))
                             (should (equal (drgnx-teardown--leftovers deferred t) '(ok))))))

;;;; Lints

(defconst drgnx-teardown--registrations
  '(add-hook advice-add add-function add-to-list define-advice run-with-timer run-at-time run-with-idle-timer
             eval-after-load with-eval-after-load
             drgnx-command-define drgnx-wb-define-section drgnx-wb-define-tab drgnx-wb-define-area drgnx-wb-place
             drgnx-wb-define-place drgnx-signal-subscribe drgnx-surfaces-define-context drgnx-layouts-define-pane
             drgnx-layouts-define-shape drgnx-statusbar-define-segment drgnx-pane-define-kind drgnx-modal-define-engine)
  "Calls that register something global: in a module file they belong in the setup, where they are recorded.")

(defun drgnx-teardown--deferred-p (head)
  "HEAD starts a form whose body does not run when the file loads (a definition, a function, quoted data)."
  (and (symbolp head)
       (or (memq head '(quote function lambda \` drgnx-module-define))
           (string-match-p "\\`\\(cl-\\)?def" (symbol-name head)))))

(defun drgnx-teardown--load-registrations (file)
  "The registration calls (their head symbols) that run when FILE loads."
  (let (out)
    (cl-labels ((walk (form)
                  (when (consp form)
                    (cond ((memq (car form) drgnx-teardown--registrations) (push (car form) out))
                          ((drgnx-teardown--deferred-p (car form)))
                          (t (let ((x form))
                               (while (consp x) (walk (car x)) (setq x (cdr x)))))))))
      (mapc #'walk (drgnx-teardown--forms file)))
    (nreverse out)))

(defun drgnx-teardown--load-violations (files allowed)
  "\"FILE: CALL at load\" for each load-time registration in FILES not in ALLOWED, and \"FILE: CALL no longer
at load\" for each ALLOWED entry of FILES that is gone."
  (let (out)
    (dolist (f files)
      (let* ((rel (drgnx-teardown--rel f))
             (calls (delete-dups (drgnx-teardown--load-registrations f)))
             (known (mapcar #'cadr (seq-filter (lambda (e) (equal (car e) rel)) allowed))))
        (dolist (c calls) (unless (memq c known) (push (format "%s: %s at load (put it in the setup)" rel c) out)))
        (dolist (k known) (unless (memq k calls) (push (format "%s: %s no longer at load (remove the entry)" rel k) out)))))
    (nreverse out)))

(ert-deftest drgnx-lint/modules-register-nothing-at-load ()
  ;; A registration at a module file's top level runs when the file loads, outside every setup: nothing records
  ;; it and a module turned off keeps it.
  (should (equal (drgnx-teardown--load-violations (drgnx-teardown--files) drgnx-teardown--load-registrations) nil)))

(ert-deftest drgnx-lint/the-load-check-reads-only-what-loads ()
  (ert-with-temp-directory dir
                           (let ((f (drgnx-teardown-test--fake dir "fake-load" "(defun a () (add-hook 'x #'a))
(advice-add 'b :before #'a)
(with-eval-after-load 'c (add-to-list 'd 1))
(drgnx-module-define 'fake/load :setup (lambda () (run-with-timer 1 nil #'a)))
'(drgnx-command-define 'q)")))
                             (should (equal (drgnx-teardown--load-registrations f) '(advice-add with-eval-after-load)))
                             (should (equal (mapcar (lambda (s) (replace-regexp-in-string "\\`[^:]*: " "" s))
                                                    (drgnx-teardown--load-violations (list f) `((,(drgnx-teardown--rel f) advice-add :until 1)
                                                                                                (,(drgnx-teardown--rel f) run-at-time :until 1))))
                                            '("with-eval-after-load at load (put it in the setup)"
                                              "run-at-time no longer at load (remove the entry)"))))))

(defvar drgnx-teardown--globals-cache nil)

(defun drgnx-teardown--global-p (var)
  "VAR is a global variable: bound here, or a `defvar'/`defcustom'/`defconst' of drgnx's core, wb or modules."
  (or (boundp var)
      (memq var (or drgnx-teardown--globals-cache
                    (setq drgnx-teardown--globals-cache
                          (let (out)
                            (dolist (d '("core" "wb" "modules"))
                              (dolist (f (directory-files-recursively (expand-file-name d drgnx-dir) "\\.el\\'"))
                                (dolist (form (drgnx-teardown--forms f))
                                  (when (and (memq (car-safe form) '(defvar defcustom defconst defvar-local))
                                             (symbolp (cadr form)))
                                    (push (cadr form) out)))))
                            (or out '(nil))))))))

(defun drgnx-teardown--lambda-p (x)
  (or (eq (car-safe x) 'lambda) (and (eq (car-safe x) 'function) (eq (car-safe (cadr x)) 'lambda))))

(defun drgnx-teardown--raw-form (form)
  "Why FORM changes global state the recorder cannot see: (ALWAYS . MESSAGE), or nil.
ALWAYS is non-nil when a :teardown does not make it right."
  (pcase form
    (`(with-eval-after-load ,_ . ,body)
     (if (seq-some (lambda (b) (eq (car-safe b) 'drgnx-modules-with-owner)) body)
         '(t . "drgnx-modules-with-owner inside with-eval-after-load never runs (use eval-after-load)")
       '(nil . "with-eval-after-load (use eval-after-load with drgnx-modules-with-owner)")))
    (`(eval-after-load ,_ ,fn)
     (unless (eq (car-safe fn) 'drgnx-modules-with-owner) '(nil . "eval-after-load without drgnx-modules-with-owner")))
    (`(setf (alist-get ,_ ,(and var (pred symbolp) (pred drgnx-teardown--global-p)) . ,_) . ,_)
     (cons nil (format "setf (alist-get … %s) (use drgnx-module-alist-put)" var)))
    (`(,(and f (or 'face-spec-set 'setopt 'setq-default 'modify-frame-parameters)) . ,_)
     (cons nil (format "%s" f)))
    (`(,(and f (pred symbolp) (guard (string-prefix-p "custom-set-" (symbol-name f)))) . ,_)
     (cons nil (format "%s" f)))
    (`(,(or 'define-key 'keymap-set) ,(or 'global-map '(current-global-map)) . ,_)
     (cons nil (format "%s global-map (use drgnx-module-define-key)" (car form))))
    (`(add-function ,_ ,(and place (or `(default-value ,_) (pred symbolp))) . ,_)
     (cons nil (format "add-function on %S (remove it in the module's :teardown)" place)))
    (`(add-hook ,hook ,(pred drgnx-teardown--lambda-p) . ,(or 'nil `(,_) `(,_ nil)))
     (cons t (format "a lambda on the global hook %S (name it)" hook)))))

(defun drgnx-teardown--walk (form fn)
  "Call FN on FORM and every list and symbol inside it."
  (funcall fn form)
  (when (consp form)
    (let ((x form))
      (while (consp x) (drgnx-teardown--walk (car x) fn) (setq x (cdr x))))))

(defun drgnx-teardown--raw-violations (file teardown)
  "\"FILE: what\" for each raw global form in FILE; with TEARDOWN (the module has one) only those it cannot fix."
  (let (out (rel (drgnx-teardown--rel file)))
    (dolist (top (drgnx-teardown--forms file))
      (drgnx-teardown--walk
       top (lambda (form)
             (let ((v (cond ((eq form 'default-frame-alist) '(nil . "default-frame-alist (use drgnx-module-alist-put)"))
                            ((consp form) (drgnx-teardown--raw-form form)))))
               (when (and v (or (car v) (not teardown)))
                 (push (format "%s: %s%s" rel (cdr v) (if (car v) "" ", without a :teardown")) out))))))
    (nreverse out)))

(defun drgnx-teardown--file-modules (file)
  "The names of the modules FILE belongs to."
  (or (mapcar #'car (drgnx-teardown--defines file))
      (let ((m (cdr (assoc (drgnx-teardown--rel file) drgnx-teardown--library-files)))) (and m (list m)))))

(defun drgnx-teardown--file-teardown-p (file)
  "A module FILE belongs to has a :teardown (a function or restart)."
  (seq-some (lambda (name) (plist-get (cddr (assq name (drgnx-teardown--modules))) :teardown))
            (drgnx-teardown--file-modules file)))

(ert-deftest drgnx-lint/raw-global-forms-need-a-teardown ()
  (let (bad)
    (dolist (f (drgnx-teardown--files))
      (unless (seq-some (lambda (name) (assq name drgnx-teardown--not-yet)) (drgnx-teardown--file-modules f))
        (setq bad (append bad (drgnx-teardown--raw-violations f (drgnx-teardown--file-teardown-p f))))))
    (should (equal bad nil))))

(ert-deftest drgnx-lint/the-raw-forms-check-sees-each-form ()
  (ert-with-temp-directory dir
                           (let ((f (drgnx-teardown-test--fake dir "fake-raw" "(defun a ()
  (with-eval-after-load 'x (foo))
  (with-eval-after-load 'x (drgnx-modules-with-owner (foo)))
  (eval-after-load 'x (drgnx-modules-with-owner (foo)))
  (eval-after-load 'x #'foo)
  (setf (alist-get 'k auto-mode-alist) 'v)
  (let ((l nil)) (setf (alist-get 'k l) 'v))
  (face-spec-set 'f nil) (custom-set-faces) (setopt x 1) (setq-default y 1)
  (define-key global-map [remap a] #'b) (define-key some-map [remap a] #'b)
  (push '(a . b) default-frame-alist) (modify-frame-parameters nil nil)
  (add-function :before (default-value 'x) #'a) (add-function :before (local 'x) #'a)
  (add-hook 'find-file-hook (lambda () 1))
  (add-hook 'find-file-hook #'a)
  (add-hook 'find-file-hook (lambda () 1) nil t))")))
                             (should (equal (mapcar (lambda (s) (replace-regexp-in-string "\\`[^:]*: " "" s))
                                                    (drgnx-teardown--raw-violations f nil))
                                            '("with-eval-after-load (use eval-after-load with drgnx-modules-with-owner), without a :teardown"
                                              "drgnx-modules-with-owner inside with-eval-after-load never runs (use eval-after-load)"
                                              "eval-after-load without drgnx-modules-with-owner, without a :teardown"
                                              "setf (alist-get … auto-mode-alist) (use drgnx-module-alist-put), without a :teardown"
                                              "face-spec-set, without a :teardown" "custom-set-faces, without a :teardown"
                                              "setopt, without a :teardown" "setq-default, without a :teardown"
                                              "define-key global-map (use drgnx-module-define-key), without a :teardown"
                                              "default-frame-alist (use drgnx-module-alist-put), without a :teardown"
                                              "modify-frame-parameters, without a :teardown"
                                              "add-function on (default-value 'x) (remove it in the module's :teardown), without a :teardown"
                                              "a lambda on the global hook 'find-file-hook (name it)")))
                             ;; with a :teardown, only what it cannot make right
                             (should (equal (mapcar (lambda (s) (replace-regexp-in-string "\\`[^:]*: " "" s))
                                                    (drgnx-teardown--raw-violations f t))
                                            '("drgnx-modules-with-owner inside with-eval-after-load never runs (use eval-after-load)"
                                              "a lambda on the global hook 'find-file-hook (name it)"))))))

(provide 'lint-teardown-test)
;;; lint-teardown-test.el ends here
