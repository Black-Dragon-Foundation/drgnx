;;; lint-test-classes-test.el --- every test file has a class, and a lint for each class -*- lexical-binding: t -*-
;; test-class: cond
;; A test file's class is the comment line `;; test-class: det' (or `cond', `timing'), an exact line within its first
;; 15 lines; a test's own `:det', `:cond' or `:timing' tag wins over its file's class.  The files are read with the
;; Lisp reader, never loaded.  A lint applies to a file as soon as it has a class line.  Files in
;; test/class-exempt.eld are never classified (their Lisp is deleted or replaced by a plan).
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-run-ert)

(defvar drgnx-lint-classes--all-classified t
  "Non-nil once every live test file has a class: `drgnx-lint/every-test-has-a-class' then fails on a file without one
(until then it only reports the count).")

(defconst drgnx-lint-classes--dirs '("test/unit" "test/ui" "test/tty" "test/live" "test/scenario"))

(defconst drgnx-lint-classes--det-banned
  '(sleep-for sit-for-positive make-process start-process run-at-time run-with-timer run-with-idle-timer
              accept-process-output-timed clock-loop drgnx-test-pause drgnx-test-proc-await-exit)
  "What a deterministic test never calls outside `drgnx-test-with-clock' (nor through a helper of its file).  A
synchronous `call-process' (git and the like) is allowed; `drgnx-test-pause' and `drgnx-test-proc-await-exit' are real
waits; the `drgnx-timer-*' layer only fills timer lists.")

(defconst drgnx-lint-classes--cond-banned '(sleep-for sit-for-positive)
  "What a conditional test never calls: a fixed pause.  `drgnx-test-pause' stays allowed (the \"did not happen\" window);
in test/ui it says what may not happen (`drgnx-lint-classes--gui-pauses').")

(defconst drgnx-lint-classes--clock-reads '(float-time-bare current-time time-since drgnx-test-real-time)
  "Calls that read the wall clock; `float-time' of an argument only converts a time.")

(defconst drgnx-lint-classes--comparisons '(< > <= >= = /= time-less-p time-equal-p))

;;;; Reading

(defun drgnx-lint-classes--exempt ()
  "The files of test/class-exempt.eld, relative to the checkout."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/class-exempt.eld" drgnx-dir))
    (mapcar #'car (read (current-buffer)))))

(defun drgnx-lint-classes--files ()
  "Every live test file (relative names): the test tiers' `*-test.el' files that are not exempt."
  (let ((exempt (drgnx-lint-classes--exempt)))
    (seq-remove (lambda (f) (member f exempt))
                (mapcar (lambda (f) (file-relative-name f drgnx-dir))
                        (seq-mapcat (lambda (d)
                                      (directory-files-recursively (expand-file-name d drgnx-dir) "-test\\.el\\'"))
                                    drgnx-lint-classes--dirs)))))

(defun drgnx-lint-classes--forms (file)
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun drgnx-lint-classes--own-class (test)
  "The class tag (:det, :cond or :timing) in the quoted `:tags' of the `ert-deftest' form TEST, or nil."
  (let ((tags (cadr (memq :tags (nthcdr 3 test)))))
    (when (eq (car-safe tags) 'quote)
      (seq-some (lambda (x) (car (memq x '(:det :cond :timing)))) (cadr tags)))))

(defvar drgnx-lint-classes--clock-macros nil
  "Names of the file-local macros whose body mentions `drgnx-test-with-clock', set by the last parse: they wrap the
clock fixture, so what they wrap is on virtual time like the fixture's own body.")

(defun drgnx-lint-classes--clock-form-p (f)
  "F is `drgnx-test-with-clock', or a file-local macro that wraps it."
  (and (consp f) (or (eq (car f) 'drgnx-test-with-clock) (memq (car f) drgnx-lint-classes--clock-macros))))

(defun drgnx-lint-classes--parse (forms)
  "FORMS (a file's top-level forms) as (HELPERS . TESTS): HELPERS an alist of file-local function name to its form,
TESTS the `ert-deftest' forms."
  (let (helpers tests)
    (setq drgnx-lint-classes--clock-macros nil)
    (dolist (f forms)
      (when (consp f)
        (when (and (memq (car f) '(defmacro cl-defmacro))
                   (let (hit)
                     (drgnx-lint-classes--walk f (lambda (x) (when (eq x 'drgnx-test-with-clock) (setq hit t)) hit))
                     hit))
          (push (cadr f) drgnx-lint-classes--clock-macros))
        (cond ((memq (car f) '(defun cl-defun defsubst cl-defsubst defmacro cl-defmacro))
               (push (cons (cadr f) f) helpers))
              ((eq (car f) 'ert-deftest) (push f tests)))))
    (cons helpers (nreverse tests))))

;;;; Walking

(defun drgnx-lint-classes--walk (form fn)
  "Call FN on FORM and every sub-form; FN returning non-nil prunes that form's sub-forms."
  (unless (funcall fn form)
    (when (consp form)
      (let ((x form))
        (while (consp x) (drgnx-lint-classes--walk (car x) fn) (setq x (cdr x)))))))

(defun drgnx-lint-classes--calls (form)
  "The calls in FORM, as symbols; the keys `sit-for-positive', `accept-process-output-timed' and `float-time-bare'
stand for the forms that wait on a time or read the wall clock, and `pause-without-a-reason' for a `drgnx-test-pause'
with no reason string.  What `drgnx-test-with-clock' wraps is not walked: the fixture moves time there."
  (let (out)
    (drgnx-lint-classes--walk
     form
     (lambda (f)
       (cond ((drgnx-lint-classes--clock-form-p f) t)
             ((eq (car-safe f) 'quote) t)    ; a quoted symbol is data (stubs, lists), not a call
             ((and (consp f) (symbolp (car f)))
              (push (car f) out)
              (pcase (car f)
                ;; a clock read that decides a loop is a deadline; one that only sets a stamp is not
                ((or 'while 'cl-loop 'cl-do 'dotimes)
                 (when (seq-some (lambda (k) (memq k drgnx-lint-classes--clock-reads))
                                 (drgnx-lint-classes--calls (if (eq (car f) 'while) (cadr f) (cdr f))))
                   (push 'clock-loop out)))
                ('sit-for (unless (eql (cadr f) 0) (push 'sit-for-positive out)))
                ('drgnx-test-pause (unless (stringp (nth 2 f)) (push 'pause-without-a-reason out)))
                ('accept-process-output (when (and (nth 2 f) (not (eql (nth 2 f) 0)))
                                          (push 'accept-process-output-timed out)))
                ('float-time (unless (cdr f) (push 'float-time-bare out))))
              nil))))
    out))

(defun drgnx-lint-classes--reaches (form helpers banned)
  "The banned calls FORM makes, directly or through the file-local HELPERS (an alist), as strings."
  (let (out seen)
    (cl-labels ((visit (f via)
                  (dolist (k (drgnx-lint-classes--calls f))
                    (cond ((memq k banned)
                           (cl-pushnew (if via (format "%s (through %s)" k via) (symbol-name k)) out :test #'equal))
                          ((and (assq k helpers) (not (memq k seen)))
                           (push k seen)
                           (visit (cdr (assq k helpers)) (or via k)))))))
      (visit form nil))
    (nreverse out)))

(defconst drgnx-lint-classes--time-arithmetic
  (append '(+ - * / min max abs floor ceiling round truncate float time-subtract time-add time-since float-time
              time-convert time-to-seconds)
          drgnx-lint-classes--comparisons)
  "Calls through which a value stays a clock reading; any other call (a function of a seed, say) ends the taint.")

(defun drgnx-lint-classes--clock-read-p (f)
  (and (consp f) (or (memq (car f) '(current-time time-since drgnx-test-real-time))
                     (and (eq (car f) 'float-time) (null (cdr f))))))

(defun drgnx-lint-classes--virtual (f &optional in)
  "F with the clock reads inside `drgnx-test-with-clock' (and its wrappers) replaced by 0: the fixture makes them
virtual, so they are no wall-clock reads.  `drgnx-test-real-time' stays: it reads the true clock."
  (cond ((atom f) f)
        ((eq (car f) 'quote) f)
        ((and in (drgnx-lint-classes--clock-read-p f) (not (eq (car f) 'drgnx-test-real-time))) 0)
        (t (let ((in (or in (drgnx-lint-classes--clock-form-p f))) out)
             (while (consp f)
               (push (drgnx-lint-classes--virtual (car f) in) out)
               (setq f (cdr f)))
             (nconc (nreverse out) f)))))

(defun drgnx-lint-classes--clock-asserts (form)
  "The `should' forms of FORM that compare a wall-clock read, or a variable bound from one, as strings.  A read inside
the clock fixture is virtual (except `drgnx-test-real-time'); a value stays a reading only through time arithmetic."
  (let ((form (drgnx-lint-classes--virtual form)) (tainted nil) (out nil) (bindings nil))
    (cl-labels ((reads-clock (f)
                  (cond ((symbolp f) (memq f tainted))
                        ((atom f) nil)
                        ((eq (car f) 'quote) nil)
                        ((drgnx-lint-classes--clock-read-p f) t)
                        ((memq (car f) drgnx-lint-classes--time-arithmetic) (seq-some #'reads-clock (cdr f))))))
      (drgnx-lint-classes--walk
       form (lambda (x)
              (when (and (memq (car-safe x) '(let let*)) (listp (cadr x)))
                (dolist (b (cadr x)) (when (consp b) (push (cons (car b) (cadr b)) bindings))))
              nil))
      (let ((changed t))
        (while changed
          (setq changed nil)
          (dolist (b bindings)
            (when (and (not (memq (car b) tainted)) (reads-clock (cdr b)))
              (push (car b) tainted) (setq changed t)))))
      (drgnx-lint-classes--walk
       form (lambda (x)
              (when (memq (car-safe x) '(should should-not))
                (drgnx-lint-classes--walk
                 (cadr x) (lambda (y)
                            (when (and (memq (car-safe y) drgnx-lint-classes--comparisons) (reads-clock y))
                              (push (format "%S" y) out) t)))
                t))))
    (nreverse out)))

;;;; The rules, over one `ert-deftest' form

(defun drgnx-lint-classes--rule-det (test helpers)
  (drgnx-lint-classes--reaches test helpers drgnx-lint-classes--det-banned))

(defun drgnx-lint-classes--rule-cond (test helpers)
  (drgnx-lint-classes--reaches test helpers drgnx-lint-classes--cond-banned))

(defun drgnx-lint-classes--rule-asserts (test _helpers)
  (drgnx-lint-classes--clock-asserts test))

(defun drgnx-lint-classes--violations (class rule)
  "Violations of RULE (a function of an `ert-deftest' form and the file's helpers) in the tests of class CLASS
(:det, :cond; nil: all but :timing) of the classified files, as \"file: test: what\" strings."
  (let (out)
    (dolist (rel (drgnx-lint-classes--files))
      (let* ((file (expand-file-name rel drgnx-dir)) (file-class (drgnx-run-ert--file-class file)))
        (when file-class
          (let ((parsed (drgnx-lint-classes--parse (drgnx-lint-classes--forms file))))
            (dolist (test (cdr parsed))
              (let ((c (or (drgnx-lint-classes--own-class test) file-class)))
                (when (if class (eq c class) (not (eq c :timing)))
                  (dolist (m (funcall rule test (car parsed)))
                    (push (format "%s: %s: %s" rel (cadr test) m) out)))))))))
    (nreverse out)))

(defun drgnx-lint-classes--gui-pauses ()
  "The live test/ui files with a `drgnx-test-pause' that gives no reason.  Every top-level form counts, not only what
a test reaches by a call: a command a test binds to a key is named by `function'.  A settle is a wait for a frame
(`drgnx-test-wait-presented'), and a window of the GUI tier says what may not happen in it."
  (seq-filter (lambda (rel)
                (and (string-prefix-p "test/ui/" rel)
                     (seq-some (lambda (form) (memq 'pause-without-a-reason (drgnx-lint-classes--calls form)))
                               (drgnx-lint-classes--forms (expand-file-name rel drgnx-dir)))))
              (drgnx-lint-classes--files)))

(defun drgnx-lint-classes--read-test (string)
  "STRING, a file's forms, as (HELPERS . TESTS)."
  (drgnx-lint-classes--parse (car (read-from-string (concat "(" string ")")))))

(defun drgnx-lint-classes--check (class rule string)
  "The violations of RULE in the first test of the forms in STRING, treated as class CLASS."
  (ignore class)
  (let ((p (drgnx-lint-classes--read-test string)))
    (funcall rule (car (cdr p)) (car p))))

;;;; Tests

(ert-deftest drgnx-lint/det-tests-use-no-real-time ()
  (should-not (drgnx-lint-classes--violations :det #'drgnx-lint-classes--rule-det)))

(ert-deftest drgnx-lint/cond-tests-have-no-fixed-pause ()
  (should-not (drgnx-lint-classes--violations :cond #'drgnx-lint-classes--rule-cond))
  (should-not (drgnx-lint-classes--gui-pauses)))

(ert-deftest drgnx-lint/only-timing-asserts-the-clock ()
  (should-not (drgnx-lint-classes--violations nil #'drgnx-lint-classes--rule-asserts)))

(ert-deftest drgnx-lint/class-lints-see-a-local-helper ()
  (let ((src "(defun h () (sleep-for 1)) (defun h2 () (h)) (ert-deftest a/b () (h2))"))
    (should (equal (drgnx-lint-classes--check :det #'drgnx-lint-classes--rule-det src)
                   '("sleep-for (through h2)")))
    (should (equal (drgnx-lint-classes--check :cond #'drgnx-lint-classes--rule-cond src)
                   '("sleep-for (through h2)")))))

(ert-deftest drgnx-lint/class-lints-bite ()
  (dolist (bad '("(ert-deftest a/b () (sleep-for 0.1))" "(ert-deftest a/b () (sit-for 0.1))"
                 "(ert-deftest a/b () (make-process :name \"x\"))" "(ert-deftest a/b () (run-at-time 1 nil #'ignore))"
                 "(ert-deftest a/b () (accept-process-output p 0.5))" "(ert-deftest a/b () (drgnx-test-pause 0.2))"
                 "(ert-deftest a/b () (drgnx-test-proc-await-exit p))"
                 "(ert-deftest a/b () (let ((end (+ (float-time) 3))) (while (< (float-time) end) (ignore))))"))
    (should (drgnx-lint-classes--check :det #'drgnx-lint-classes--rule-det bad)))
  (dolist (ok '(;; a quoted symbol is not a use: stubs and lists name primitives
                "(ert-deftest a/b () (cl-letf (((symbol-function 'call-process) #'ignore) ((symbol-function 'make-process) #'ignore)) (ignore '(run-at-time sleep-for))))"
                ;; a stamp or a backdated mtime is not a deadline
                "(ert-deftest a/b () (set-file-times f (time-subtract (current-time) 100)) (let ((stamp (float-time))) (setq s stamp)))"
                ;; a :time key is data
                "(ert-deftest a/b () (should (equal (plist-get x :time) 3)) (should (equal x (list :time 3 :other 4))))"
                "(ert-deftest a/b () (accept-process-output p))" "(ert-deftest a/b () (sit-for 0))"
                "(ert-deftest a/b () (drgnx-test-with-clock () (sleep-for 1) (float-time)))"
                "(ert-deftest a/b () (call-process \"git\" nil nil nil \"status\") (float-time (current-time)))"
                "(ert-deftest a/b () (drgnx-timer-debounce 'k 1 #'ignore))"
                ;; a file-local macro that wraps the clock fixture is the fixture
                "(defmacro w (&rest b) `(drgnx-test-with-clock () ,@b)) (ert-deftest a/b () (w (sleep-for 1) (run-at-time 1 nil #'ignore)))"))
    (should-not (drgnx-lint-classes--check :det #'drgnx-lint-classes--rule-det ok)))
  (should (drgnx-lint-classes--check :det #'drgnx-lint-classes--rule-det
                                     "(defmacro w (&rest b) `(progn ,@b)) (ert-deftest a/b () (w (sleep-for 1)))"))
  ;; a real-time bound inside the fixture is still a timing assertion; a seed taken from the clock is not a reading
  (should (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                     "(ert-deftest a/b () (drgnx-test-with-clock () (let ((began (drgnx-test-real-time))) (should (< (- (drgnx-test-real-time) began) 1)))))"))
  (should-not (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                         "(ert-deftest a/b () (let* ((seed (floor (float-time))) (rows (gen seed))) (should (= (length rows) 2))))"))
  (should-not (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                         "(defmacro w (&rest b) `(drgnx-test-with-clock () ,@b)) (ert-deftest a/b () (w (should (< (float-time) 5))))"))
  (should (drgnx-lint-classes--check :cond #'drgnx-lint-classes--rule-cond "(ert-deftest a/b () (sleep-for 0.1))"))
  (should (drgnx-lint-classes--check :cond #'drgnx-lint-classes--rule-cond "(ert-deftest a/b () (sit-for 1))"))
  (should-not (drgnx-lint-classes--check :cond #'drgnx-lint-classes--rule-cond
                                         "(ert-deftest a/b () (sit-for 0) (drgnx-test-pause 0.2) (run-at-time 1 nil #'ignore))"))
  ;; a window in the GUI tier says what may not happen; the rest of the suite's windows are the plain call
  (should (memq 'pause-without-a-reason (drgnx-lint-classes--calls '(progn (drgnx-test-pause 0.3)))))
  (should-not (memq 'pause-without-a-reason (drgnx-lint-classes--calls '(drgnx-test-pause 0.3 "no second answer"))))
  (should (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                     "(ert-deftest a/b () (should (< (- (float-time) 1) 2)))"))
  (should (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                     "(ert-deftest a/b () (let* ((t0 (float-time)) (dt (- (float-time) t0))) (should (< dt 1))))"))
  (should-not (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                         "(ert-deftest a/b () (let ((n 3)) (should (< n 4)) (should (= (length x) 2))))"))
  (should-not (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                         "(ert-deftest a/b () (let ((stamp (float-time))) (set-file-times f stamp)) (should (< (plist-get x :time) 4)))"))
  (should-not (drgnx-lint-classes--check nil #'drgnx-lint-classes--rule-asserts
                                         "(ert-deftest a/b () (drgnx-test-with-clock () (should (< (float-time) 5))))")))

(ert-deftest drgnx-lint/a-test-tag-wins-over-the-file-class ()
  (should (eq :cond (drgnx-lint-classes--own-class
                     '(ert-deftest a/b () :tags '(:cond :x) (ignore)))))
  (should-not (drgnx-lint-classes--own-class '(ert-deftest a/b () (ignore)))))

(ert-deftest drgnx-lint/every-test-has-a-class ()
  ;; fails while `drgnx-lint-classes--all-classified' is t (else reports): a test has a class by its file's line or its own tag
  (let (without (n 0))
    (dolist (rel (drgnx-lint-classes--files))
      (let ((file (expand-file-name rel drgnx-dir)))
        (unless (drgnx-run-ert--file-class file)
          (let ((tests (cdr (drgnx-lint-classes--parse (drgnx-lint-classes--forms file)))))
            (when (seq-remove #'drgnx-lint-classes--own-class tests)
              (push rel without)
              (cl-incf n (length (seq-remove #'drgnx-lint-classes--own-class tests))))))))
    (message "drgnx: %d test files (%d tests) have no class yet" (length without) n)
    (when drgnx-lint-classes--all-classified
      (should-not without))))

(ert-deftest drgnx-lint/no-stale-exempt-rows ()
  ;; always on, in either merge order: a row whose file is gone, or a file that has both a row and a class line
  (let (stale classed)
    (dolist (rel (drgnx-lint-classes--exempt))
      (let ((file (expand-file-name rel drgnx-dir)))
        (cond ((not (file-exists-p file)) (push rel stale))
              ((drgnx-run-ert--file-class file) (push rel classed)))))
    (should-not stale)
    (should-not classed)))

(ert-deftest drgnx-lint/exempt-rows-have-a-reason ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/class-exempt.eld" drgnx-dir))
    (dolist (row (read (current-buffer)))
      (should (stringp (car row)))
      (should (stringp (plist-get (cdr row) :why))))))

(ert-deftest drgnx-run-ert/an-off-row-s-file-is-not-run ()
  ;; A row with `:off t' (Lisp a plan deletes) leaves its file out of every run, a shard's list included, unless
  ;; DRGNX_TEST_FROZEN=1; an exempt row without it still runs (the frozen UI).
  (let* ((rows (with-temp-buffer
                 (insert-file-contents (expand-file-name "test/class-exempt.eld" drgnx-dir))
                 (read (current-buffer))))
         (path (lambda (row) (file-truename (expand-file-name (car row) drgnx-dir))))
         (off (funcall path (seq-find (lambda (r) (plist-get (cdr r) :off)) rows)))
         (on (funcall path (seq-find (lambda (r) (not (plist-get (cdr r) :off))) rows)))
         (dir (file-name-directory off)))
    (let ((process-environment (cons "DRGNX_TEST_FROZEN" process-environment)))   ; unset
      (let ((files (mapcar #'file-truename (drgnx-run-ert--files dir))))
        (should files)
        (should-not (member off files)))
      (should (member on (mapcar #'file-truename (drgnx-run-ert--files (list on)))))
      (should-not (drgnx-run-ert--files (list off))))
    (let ((process-environment (cons "DRGNX_TEST_FROZEN=1" process-environment)))
      (should (member off (mapcar #'file-truename (drgnx-run-ert--files dir)))))))

(defun drgnx-lint-classes-test--tmp (class-line &rest forms)
  "A temp file `x-test.el' with CLASS-LINE (or nil) and FORMS in a new directory; return its name."
  (let ((file (expand-file-name "x-test.el" (make-temp-file "drgnx-class" t))))
    (with-temp-file file
      (when class-line (insert class-line "\n"))
      (dolist (f forms) (prin1 f (current-buffer)) (insert "\n")))
    file))

(ert-deftest drgnx-run-ert/a-file-class-becomes-a-tag ()
  (should (eq :det (drgnx-run-ert--file-class (drgnx-lint-classes-test--tmp ";; test-class: det"))))
  (should-not (drgnx-run-ert--file-class (drgnx-lint-classes-test--tmp ";; test-class: det and more")))
  (should-not (drgnx-run-ert--file-class (drgnx-lint-classes-test--tmp nil)))
  (let* ((file (drgnx-lint-classes-test--tmp ";; test-class: cond"
                                             '(ert-deftest x/plain () (should t))
                                             '(ert-deftest x/own () :tags '(:det) (should t))))
         (dir (file-name-directory file)) (results (expand-file-name "r.json" dir)))
    (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results)
                                             "DRGNX_TEST_SELECTOR=(and (tag :cond) \"^x/\")")
                                       (list "DRGNX_TEST_SHUFFLE" "DRGNX_TEST_LEAKS" "DRGNX_TEST_RERUN")
                                       process-environment)))
      (should (eql 0 (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                   "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                   "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" dir))))
    (let ((json (json-parse-string (with-temp-buffer (insert-file-contents results) (buffer-string)) :object-type 'plist)))
      ;; only the file's tests that carry the file's class: the test with its own tag is :det, not :cond
      (should (equal 1 (plist-get json :total)))
      (should (equal "x/plain" (plist-get (aref (plist-get json :tests) 0) :name))))))

(ert-deftest drgnx-run-ert/a-det-flake-fails-even-when-listed ()
  (let* ((det (drgnx-lint-classes-test--tmp ";; test-class: det" '(ert-deftest x/flaky () (should t))))
         (con (drgnx-lint-classes-test--tmp ";; test-class: cond" '(ert-deftest x/flaky () (should t))))
         (list-file (make-temp-file "drgnx-flaky"))
         (summary (lambda (file)
                    (list :total 1 :passed 1 :failed 0 :failures [] :known_red [] :tests [] :skipped []
                          :flaky (vector (list :name "x/flaky" :file file :condition "boom")))))
         (process-environment (cons (concat "DRGNX_TEST_FLAKY=" list-file) process-environment)))
    (with-temp-file list-file (insert "((x/flaky :reason \"a cause\" :stress \"a run\"))\n"))
    (let ((inhibit-message t))
      (should (equal 0 (plist-get (drgnx-run-ert--judge-flaky (funcall summary con)) :failed)))
      (should (equal 1 (plist-get (drgnx-run-ert--judge-flaky (funcall summary det)) :failed))))))

(ert-deftest drgnx-run-ert/the-audit-records-a-real-sleep-and-ignores-the-clock ()
  (load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
  (let ((drgnx-run-ert--audit-seen nil) (drgnx-run-ert--audit-file nil) (inhibit-message t))
    (unwind-protect
        (progn
          (drgnx-run-ert--audit-advise)
          (let ((drgnx-run-ert--audit-current "x/det"))
            (accept-process-output nil 0.01)
            (should (equal drgnx-run-ert--audit-seen '(("x/det" . accept-process-output))))
            (setq drgnx-run-ert--audit-seen nil)
            (accept-process-output nil 0)  ; no wait: not a use of real time
            (let ((pipe (make-pipe-process :name "drgnx-audit-pipe" :noquery t)))
              (setq drgnx-run-ert--audit-seen nil)
              (unwind-protect (accept-process-output pipe 0) ; a timeout of 0 on a live process is a look too
                (delete-process pipe)))
            (drgnx-test-with-clock () (sleep-for 5) (sit-for 1) (accept-process-output nil 1))
            (should-not drgnx-run-ert--audit-seen)
            ;; a process or a socket under the fixture is real work: recorded
            (drgnx-test-with-clock () (drgnx-run-ert--audit-record 'make-process))
            (should (equal drgnx-run-ert--audit-seen '(("x/det" . make-process))))))
      (drgnx-run-ert--audit-unadvise))))

(ert-deftest drgnx-run-ert/the-audit-leaves-the-environment-and-the-primitives-alone ()
  (skip-unless (not (advice-member-p 'drgnx-run-ert-audit 'ert-run-test))) ; not inside an audited run
  (let ((process-environment (append '("DRGNX_TEST_AUDIT=1" "DRGNX_TEST_AUDIT_ALL=1" "DRGNX_TEST_AUDIT_FAIL=1")
                                     process-environment))
        (drgnx-run-ert--audit-all nil) (drgnx-run-ert--audit-fail nil))
    (unwind-protect
        (progn
          (drgnx-run-ert--audit-install)
          ;; read once, then gone: a test about the environment never sees the runner's switches
          (should drgnx-run-ert--audit-all)
          (should drgnx-run-ert--audit-fail)
          (dolist (v '("DRGNX_TEST_AUDIT" "DRGNX_TEST_AUDIT_ALL" "DRGNX_TEST_AUDIT_FAIL")) (should-not (getenv v)))
          ;; the primitives carry no advice outside an audited test
          (dolist (p drgnx-run-ert--audit-primitives)
            (should-not (advice-member-p 'drgnx-run-ert-audit p))))
      (drgnx-run-ert--audit-uninstall))))

(ert-deftest drgnx-run-ert/an-audited-run-fails-a-det-test-that-sleeps ()
  ;; a real runner (drgnx-run-ert-batch, one Emacs per file) on a real det file: the sleeping test is red with
  ;; DRGNX_TEST_AUDIT_FAIL=1, and the same run without it is green
  (let* ((file (drgnx-lint-classes-test--tmp ";; test-class: det"
                                             '(ert-deftest x/sleeps () (sleep-for 0.01) (should t))
                                             '(ert-deftest x/quiet () (should t))
                                             '(ert-deftest x/own-tag-is-cond () :tags '(:cond) (sleep-for 0.01) (should t))))
         (dir (file-name-directory file)) (results (expand-file-name "r.json" dir))
         (run (lambda (&rest env)
                (let ((process-environment (append env (list (concat "DRGNX_TEST_RESULTS=" results)
                                                             "DRGNX_TEST_SELECTOR" "DRGNX_TEST_SHUFFLE" "DRGNX_TEST_RERUN"
                                                             "DRGNX_TEST_LEAKS" "DRGNX_TEST_AUDIT" "DRGNX_TEST_AUDIT_FAIL"
                                                             "DRGNX_TEST_AUDIT_ALL")
                                                   process-environment)))
                  (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" dir))))
         (json (lambda () (json-parse-string (with-temp-buffer (insert-file-contents results) (buffer-string))
                                             :object-type 'plist))))
    (should-not (eql 0 (funcall run "DRGNX_TEST_AUDIT=1" "DRGNX_TEST_AUDIT_FAIL=1")))
    (let ((j (funcall json)))
      (should (equal 1 (plist-get j :failed)))
      (should (equal "x/sleeps" (plist-get (aref (plist-get j :failures) 0) :name))))
    (should (eql 0 (funcall run "DRGNX_TEST_AUDIT=1")))
    (should (eql 0 (funcall run)))))

;;; lint-test-classes-test.el ends here
