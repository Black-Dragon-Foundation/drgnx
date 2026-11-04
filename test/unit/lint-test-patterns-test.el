;;; lint-test-patterns-test.el --- every cond file names its pattern, and a lint for each pattern -*- lexical-binding: t -*-
;; test-class: cond
;; A `cond' test file names its patterns on a `;; test-pattern: P…' line (P: `orders', `gated' or `handshake'), an exact
;; line within its first 15 lines, beside its class line.  The files in test/pattern-pending.eld are the `cond' files
;; that have none yet; the register only shrinks.  Each pattern's lint reads the files that name it (never loads them),
;; with the class lints' reader: the test-defining macros are expanded, the file's own helpers are followed, and a
;; fixture macro (`drgnx-test-with-ratatoskr', `drgnx-test-gated') is a plain form.  See docs/develop/harness.md,
;; "Test patterns".
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-run-ert)

;; The class lints' reader lives in lint-test-classes-test.el.  Its definitions are evaluated here without its tests,
;; so that this file and that one stay independent files of the suite.
(let ((src (expand-file-name "test/unit/lint-test-classes-test.el" drgnx-dir)))
  (with-temp-buffer
    (insert-file-contents src)
    (condition-case nil
        (while t
          (let ((form (read (current-buffer))))
            (when (and (memq (car-safe form) '(defun defconst defvar defmacro cl-defun))
                       (string-prefix-p "drgnx-lint-classes--" (symbol-name (cadr form))))
              (eval form t))))
      (end-of-file nil))))

(declare-function drgnx-lint-classes--files "lint-test-classes-test")
(declare-function drgnx-lint-classes--forms "lint-test-classes-test")
(declare-function drgnx-lint-classes--parse "lint-test-classes-test")
(declare-function drgnx-lint-classes--read-test "lint-test-classes-test")
(declare-function drgnx-lint-classes--reaches "lint-test-classes-test")
(declare-function drgnx-lint-classes--walk "lint-test-classes-test")

(defconst drgnx-lint-patterns--handshake-banned
  '(signal-process interrupt-process kill-process quit-process stop-process continue-process process-live-p
                   sleep-for sit-for-positive run-at-time run-with-timer run-with-idle-timer accept-process-output-timed)
  "What a handshake test never calls: a raw signal (the fixture signals only a parked child), a liveness poll, or a
time as a marker.  A timed `accept-process-output' stays inside `drgnx-test-wait'.")

(defconst drgnx-lint-patterns--hub-calls '(drgnx-hub-call drgnx-hub-call-sync drgnx-hub-connect drgnx-hub-disconnect)
  "The hub client calls that a gated test makes inside `drgnx-test-gated', where the gate sees their lines.")

(defconst drgnx-lint-patterns--asserts '(should should-not should-error))

(defconst drgnx-lint-patterns--deliveries '(drgnx-test-deliver-all drgnx-test-hub-advance)
  "The calls after which every held line has been released and read.")

(defconst drgnx-lint-patterns--branching
  '(lambda if when unless cond and or while dolist dotimes cl-loop condition-case ignore-errors ignore-error
     defun cl-defun cl-flet cl-labels)
  "Forms in which a delivery does not count for what follows the form: it may not run.")

;;;; Reading

(defun drgnx-lint-patterns--pending ()
  "The files of test/pattern-pending.eld: a list of FILE (relative to the checkout) or (FILE :why STRING)."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/pattern-pending.eld" drgnx-dir))
    (mapcar (lambda (row) (if (consp row) (car row) row)) (read (current-buffer)))))

(defun drgnx-lint-patterns--files (pattern)
  "The live test files whose pattern line names PATTERN (a symbol), relative to the checkout."
  (seq-filter (lambda (rel) (memq pattern (drgnx-run-ert--file-patterns (expand-file-name rel drgnx-dir))))
              (drgnx-lint-classes--files)))

(defun drgnx-lint-patterns--without (heads form)
  "FORM with every sub-form whose head is one of HEADS replaced by nil (quoted data is left alone)."
  (cond ((atom form) form)
        ((eq (car form) 'quote) form)
        ((memq (car form) heads) nil)
        (t (let (out)
             (while (consp form)
               (push (drgnx-lint-patterns--without heads (car form)) out)
               (setq form (cdr form)))
             (nconc (nreverse out) form)))))

(defun drgnx-lint-patterns--mentions (head form)
  "Whether FORM has a call of HEAD anywhere in it."
  (let (hit)
    (drgnx-lint-classes--walk form (lambda (f) (when (eq (car-safe f) head) (setq hit t)) hit))
    hit))

(defun drgnx-lint-patterns--helpers-without (heads helpers)
  (mapcar (lambda (h) (cons (car h) (drgnx-lint-patterns--without heads (cdr h)))) helpers))

(defun drgnx-lint-patterns--violations (pattern rule)
  "Violations of RULE (a function of an `ert-deftest' form and the file's helpers: a list of strings) in the tests of
the files that name PATTERN, as \"file: test: what\" strings."
  (let (out)
    (dolist (rel (drgnx-lint-patterns--files pattern))
      (let ((parsed (drgnx-lint-classes--parse (drgnx-lint-classes--forms (expand-file-name rel drgnx-dir)))))
        (dolist (u drgnx-lint-classes--unexpanded)
          (push (format "%s: %s: did not expand: %s" rel (car u) (cdr u)) out))
        (dolist (test (cdr parsed))
          (dolist (m (funcall rule test (car parsed)))
            (push (format "%s: %s: %s" rel (cadr test) m) out)))))
    (nreverse out)))

(defun drgnx-lint-patterns--check (rule string)
  "The violations of RULE in the first test of the forms in STRING."
  (let ((p (drgnx-lint-classes--read-test string)))
    (funcall rule (cadr p) (car p))))

;;;; The rules, over one `ert-deftest' form

(defun drgnx-lint-patterns--rule-handshake (test helpers)
  (drgnx-lint-classes--reaches
   (drgnx-lint-patterns--without '(drgnx-test-wait) test)
   (drgnx-lint-patterns--helpers-without '(drgnx-test-wait) helpers)
   drgnx-lint-patterns--handshake-banned))

(defun drgnx-lint-patterns--ordered-calls (form helpers)
  "The calls of FORM in the order they run, a file-local helper's own calls where it is called; arguments come before
their call."
  (let (out active)
    (cl-labels ((visit (f)
                  (cond ((atom f))
                        ((eq (car f) 'quote))
                        (t (let ((head (and (symbolp (car f)) (car f))) (x (if (symbolp (car f)) (cdr f) f)))
                             (while (consp x) (visit (car x)) (setq x (cdr x)))
                             (when head
                               (push head out)
                               (when (and (assq head helpers) (not (memq head active)))
                                 (push head active)
                                 (dolist (b (nthcdr 3 (cdr (assq head helpers)))) (visit b))
                                 (pop active))))))))
      (visit form))
    (nreverse out)))

(defun drgnx-lint-patterns--rule-handshake-order (test helpers)
  "A `drgnx-test-child-signal' before any `drgnx-test-child-await' signals a child that has not announced."
  (let ((awaited nil) out)
    (dolist (c (drgnx-lint-patterns--ordered-calls test helpers))
      (cond ((eq c 'drgnx-test-child-await) (setq awaited t))
            ((and (eq c 'drgnx-test-child-signal) (not awaited))
             (cl-pushnew "drgnx-test-child-signal before any drgnx-test-child-await" out :test #'equal))))
    (nreverse out)))

(defun drgnx-lint-patterns--rule-gated-calls (test helpers)
  "In a test that calls `drgnx-test-gated', a hub call outside its body: its lines would not pass the gate."
  (when (drgnx-lint-patterns--mentions 'drgnx-test-gated test)
    (drgnx-lint-classes--reaches
     (drgnx-lint-patterns--without '(drgnx-test-gated) test)
     (drgnx-lint-patterns--helpers-without '(drgnx-test-gated) helpers)
     drgnx-lint-patterns--hub-calls)))

(defun drgnx-lint-patterns--scan-asserts (f delivered bad)
  "Walk F in evaluation order with DELIVERED (whether a delivery has run); push each assertion that runs before one
onto the cell BAD; return the new DELIVERED.  A delivery counts for what follows it at its own level and in the
levels that enclose it (a `let' binding, a call's argument); inside a branching form it counts only inside."
  (cond ((atom f) delivered)
        ((eq (car f) 'quote) delivered)
        ((eq (car f) 'function)
         (when (consp (cadr f)) (drgnx-lint-patterns--scan-asserts (cadr f) delivered bad))
         delivered)
        (t (let* ((head (and (symbolp (car f)) (car f))) (x (if head (cdr f) f)) (out delivered))
             (while (consp x)
               (setq out (drgnx-lint-patterns--scan-asserts (car x) out bad))
               (setq x (cdr x)))
             (when (and (memq head drgnx-lint-patterns--asserts) (not out))
               (push (format "%S" f) (car bad)))
             (cond ((memq head drgnx-lint-patterns--deliveries) t)
                   ((memq head drgnx-lint-patterns--branching) delivered)
                   (t out))))))

(defun drgnx-lint-patterns--rule-gated-asserts (test _helpers)
  "Inside `drgnx-test-gated', an assertion before the first delivery sees whatever the gate has released so far."
  (let ((bad (list nil)))
    (drgnx-lint-classes--walk
     test (lambda (f)
            (when (eq (car-safe f) 'drgnx-test-gated)
              (let ((d nil))
                (dolist (b (cddr f)) (setq d (drgnx-lint-patterns--scan-asserts b d bad))))
              t)))
    (mapcar (lambda (s) (format "assertion before drgnx-test-deliver-all or drgnx-test-hub-advance: %s"
                                (truncate-string-to-width s 70 nil nil "…")))
            (nreverse (car bad)))))

(defun drgnx-lint-patterns--kinds-ok-p (arg)
  "ARG, the form after `:kinds', is a non-empty quoted list, a `list' of something, or a named constant."
  (or (and (eq (car-safe arg) 'quote) (consp (cadr arg)))
      (and (eq (car-safe arg) 'list) (cdr arg))
      (and arg (symbolp arg) (not (keywordp arg)) (not (eq arg t)))))

(defun drgnx-lint-patterns--helper-forms (test helpers)
  "TEST and the file-local helpers it reaches, as forms."
  (let ((forms (list test)) seen (todo (list test)))
    (while todo
      (drgnx-lint-classes--walk
       (pop todo) (lambda (f)
                    (let ((name (cond ((and (consp f) (symbolp (car f))) (car f))
                                      ((and (eq (car-safe f) 'function) (symbolp (cadr f))) (cadr f)))))
                      (when (and name (assq name helpers) (not (memq name seen)))
                        (push name seen)
                        (push (cdr (assq name helpers)) forms)
                        (push (cdr (assq name helpers)) todo)))
                    nil)))
    forms))

(defun drgnx-lint-patterns--rule-orders (test helpers)
  "A `drgnx-test-every-order' call (in the test or a helper) with no non-empty `:kinds'."
  (let (out)
    (dolist (form (drgnx-lint-patterns--helper-forms test helpers))
      (drgnx-lint-classes--walk
       form (lambda (f)
              (when (eq (car-safe f) 'drgnx-test-every-order)
                (let ((kinds (memq :kinds (cdr f))))
                  (unless (and kinds (drgnx-lint-patterns--kinds-ok-p (cadr kinds)))
                    (cl-pushnew "drgnx-test-every-order without a non-empty :kinds" out :test #'equal))))
              nil)))
    (nreverse out)))

;;;; Tests

(ert-deftest drgnx-lint/every-cond-file-has-a-pattern-or-is-pending ()
  (let ((pending (drgnx-lint-patterns--pending)) bare)
    (dolist (rel (drgnx-lint-classes--files))
      (let ((file (expand-file-name rel drgnx-dir)))
        (when (and (eq (drgnx-run-ert--file-class file) :cond)
                   (not (drgnx-run-ert--file-patterns file))
                   (not (member rel pending)))
          (push rel bare))))
    (should-not (nreverse bare))))

(ert-deftest drgnx-lint/pending-rows-only-shrink ()
  ;; a listed file that has a line, or is gone, fails: remove its row
  (let (stale named)
    (dolist (rel (drgnx-lint-patterns--pending))
      (let ((file (expand-file-name rel drgnx-dir)))
        (cond ((not (file-exists-p file)) (push rel stale))
              ((drgnx-run-ert--file-patterns file) (push rel named)))))
    (should-not (nreverse stale))
    (should-not (nreverse named))))

(ert-deftest drgnx-lint/handshake-tests-signal-through-the-fixture ()
  (should-not (drgnx-lint-patterns--violations 'handshake #'drgnx-lint-patterns--rule-handshake))
  (should-not (drgnx-lint-patterns--violations 'handshake #'drgnx-lint-patterns--rule-handshake-order)))

(ert-deftest drgnx-lint/gated-tests-call-the-hub-inside-the-gate ()
  (should-not (drgnx-lint-patterns--violations 'gated #'drgnx-lint-patterns--rule-gated-calls)))

(ert-deftest drgnx-lint/gated-asserts-follow-deliver-all ()
  (should-not (drgnx-lint-patterns--violations 'gated #'drgnx-lint-patterns--rule-gated-asserts)))

(ert-deftest drgnx-lint/orders-tests-declare-their-kinds ()
  (should-not (drgnx-lint-patterns--violations 'orders #'drgnx-lint-patterns--rule-orders)))

;;;; The lints bite

(ert-deftest drgnx-lint/handshake-lint-bites ()
  (let ((rule #'drgnx-lint-patterns--rule-handshake))
    (dolist (bad '("(signal-process p 'INT)" "(interrupt-process p)" "(kill-process p)" "(quit-process p)"
                   "(stop-process p)" "(continue-process p)" "(process-live-p p)" "(sleep-for 0.1)" "(sit-for 0.1)"
                   "(run-at-time 1 nil #'ignore)" "(run-with-timer 1 nil #'ignore)" "(run-with-idle-timer 1 nil #'ignore)"
                   "(accept-process-output p 0.5)"))
      (should (drgnx-lint-patterns--check rule (format "(ert-deftest a/b () %s)" bad))))
    ;; through a helper of the file
    (should (equal (drgnx-lint-patterns--check rule "(defun h (p) (kill-process p)) (ert-deftest a/b () (h 1))")
                   '("kill-process (through h)")))
    (dolist (ok '("(drgnx-test-child-signal p 'INT)" "(sit-for 0)" "(accept-process-output p)"
                  "(drgnx-test-wait (lambda () (accept-process-output p 0.2)) :what \"x\")"
                  "(drgnx-test-wait (lambda () (process-live-p p)))"
                  "(ignore '(kill-process sleep-for))"))
      (should-not (drgnx-lint-patterns--check rule (format "(ert-deftest a/b () %s)" ok)))))
  (let ((rule #'drgnx-lint-patterns--rule-handshake-order))
    (should (drgnx-lint-patterns--check rule "(ert-deftest a/b () (drgnx-test-child-signal p 'INT) (drgnx-test-child-await p \"x\"))"))
    ;; an argument runs before its call
    (should-not (drgnx-lint-patterns--check rule "(ert-deftest a/b () (drgnx-test-child-signal p (drgnx-test-child-await p \"x\")))"))
    (should-not (drgnx-lint-patterns--check
                 rule "(ert-deftest a/b () (drgnx-test-child-await p \"x\") (drgnx-test-child-signal p 'INT))"))
    ;; the await in a helper, called first
    (should-not (drgnx-lint-patterns--check
                 rule "(defun h (p) (drgnx-test-child-await p \"x\")) (ert-deftest a/b () (h p) (drgnx-test-child-signal p 1))"))
    (should (drgnx-lint-patterns--check
             rule "(defun h (p) (drgnx-test-child-await p \"x\")) (ert-deftest a/b () (drgnx-test-child-signal p 1) (h p))"))))

(ert-deftest drgnx-lint/gated-calls-lint-bites ()
  (let ((rule #'drgnx-lint-patterns--rule-gated-calls))
    (dolist (call '("(drgnx-hub-call 'm nil #'ignore)" "(drgnx-hub-call-sync 'm nil)" "(drgnx-hub-connect)"
                    "(drgnx-hub-disconnect)"))
      (should (drgnx-lint-patterns--check
               rule (format "(ert-deftest a/b () %s (drgnx-test-gated nil (should t)))" call)))
      (should (drgnx-lint-patterns--check
               rule (format "(ert-deftest a/b () (drgnx-test-gated nil (should t)) %s)" call)))
      (should-not (drgnx-lint-patterns--check
                   rule (format "(ert-deftest a/b () (drgnx-test-gated nil %s (drgnx-test-deliver-all) (should t)))" call))))
    ;; a helper called outside the body
    (should (drgnx-lint-patterns--check
             rule "(defun h () (drgnx-hub-connect)) (ert-deftest a/b () (h) (drgnx-test-gated nil (should t)))"))
    (should-not (drgnx-lint-patterns--check
                 rule "(defun h () (drgnx-hub-connect)) (ert-deftest a/b () (drgnx-test-gated nil (h) (should t)))"))
    ;; a test with no gate is not this lint's
    (should-not (drgnx-lint-patterns--check rule "(ert-deftest a/b () (drgnx-hub-connect))"))))

(ert-deftest drgnx-lint/gated-asserts-lint-bites ()
  (let ((rule #'drgnx-lint-patterns--rule-gated-asserts))
    (dolist (bad '("(drgnx-test-gated nil (should x) (drgnx-test-deliver-all))"
                   "(drgnx-test-gated nil (should-not x))"
                   "(drgnx-test-gated nil (should-error (f)) (drgnx-test-hub-advance 5))"
                   ;; a delivery in a branch is not a delivery for what follows
                   "(drgnx-test-gated nil (when c (drgnx-test-deliver-all)) (should x))"
                   ;; a delivery inside a lambda
                   "(drgnx-test-gated nil (funcall (lambda () (drgnx-test-deliver-all))) (should x))"
                   ;; in another form's body the assertion is first
                   "(drgnx-test-gated nil (let ((m 1)) (should m)) (drgnx-test-deliver-all))"))
      (should (drgnx-lint-patterns--check rule (format "(ert-deftest a/b () %s)" bad))))
    (dolist (ok '("(drgnx-test-gated nil (drgnx-test-deliver-all) (should x) (should-not y))"
                  "(drgnx-test-gated nil (drgnx-test-hub-advance 5) (should-error (f)))"
                  ;; the delivery at the outer level, the assertion in an inner one
                  "(drgnx-test-gated nil (drgnx-test-deliver-all) (let ((a 1)) (when a (should a))))"
                  ;; a delivery in a binding, the assertion in the body
                  "(drgnx-test-gated nil (let ((m (drgnx-test-deliver-all))) (should m)))"
                  ;; a delivery in an argument
                  "(drgnx-test-gated nil (should (equal (drgnx-test-deliver-all) 1)))"
                  ;; no gate, no rule
                  "(progn (should x))"))
      (should-not (drgnx-lint-patterns--check rule (format "(ert-deftest a/b () %s)" ok))))))

(ert-deftest drgnx-lint/orders-lint-bites ()
  (let ((rule #'drgnx-lint-patterns--rule-orders))
    (dolist (bad '("(drgnx-test-every-order :sources s)" "(drgnx-test-every-order :kinds nil :sources s)"
                   "(drgnx-test-every-order :kinds '() :sources s)" "(drgnx-test-every-order :kinds (list) :sources s)"
                   "(drgnx-test-every-order :kinds (some-fn) :sources s)"))
      (should (drgnx-lint-patterns--check rule (format "(ert-deftest a/b () %s)" bad))))
    (dolist (ok '("(drgnx-test-every-order :kinds '(a b) :sources s)" "(drgnx-test-every-order :sources s :kinds (list 'a))"
                  "(drgnx-test-every-order :sources s :kinds my-kinds)"))
      (should-not (drgnx-lint-patterns--check rule (format "(ert-deftest a/b () %s)" ok))))
    ;; in a helper of the file
    (should (drgnx-lint-patterns--check
             rule "(defun h () (drgnx-test-every-order :sources s)) (ert-deftest a/b () (h))"))))

(ert-deftest drgnx-lint/the-register-lints-bite ()
  ;; a file that holds a cond class and no line is found by the same test as the lint uses
  (let* ((dir (make-temp-file "drgnx-pattern" t))
         (bare (expand-file-name "bare-test.el" dir)) (named (expand-file-name "named-test.el" dir)))
    (with-temp-file bare (insert ";; test-class: cond\n"))
    (with-temp-file named (insert ";; test-class: cond\n;; test-pattern: gated\n"))
    (should-not (drgnx-run-ert--file-patterns bare))
    (should (equal '(gated) (drgnx-run-ert--file-patterns named)))))

;;; lint-test-patterns-test.el ends here
