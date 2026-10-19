;;; test-order-test.el --- --shuffle and --find-polluter -*- lexical-binding: t -*-
;; The runner's test order (harness/run-ert.el, bin/drgnx test).  Every run here is on a tiny fixture suite of a few
;; files with a planted polluter; the real suite is never run.
(require 'ert)
(require 'cl-lib)
(require 'seq)

(defconst drgnx-test-order-test--bin
  (expand-file-name "../../bin/drgnx" (file-name-directory (or load-file-name buffer-file-name))))

(defconst drgnx-test-order-test--env-unset
  '("DRGNX_TEST_SELECTOR" "DRGNX_TEST_RESULTS" "DRGNX_TEST_LEAKS" "DRGNX_TEST_LEAKS_ALLOWED" "DRGNX_TEST_SHUFFLE"
    "DRGNX_TEST_ONE_PROCESS" "DRGNX_TEST_ORDER_IN" "DRGNX_TEST_ORDER_OUT" "DRGNX_TEST_DIR" "DRGNX_RUN_TMP" "DRGNX_EMACS")
  "The variables of an outer run that must not reach a run the test starts.")

(defconst drgnx-test-order-test--ordered
  '(("order-test.el" . "(ert-deftest iso-ord/t1 () (should t))
(ert-deftest iso-ord/t2 () (should t))
(ert-deftest iso-ord/t3 () (should t))
(ert-deftest iso-ord/t4 () (should t))
(ert-deftest iso-ord/t5 () (should t))
(ert-deftest iso-ord/t6 () (should t))
(ert-deftest iso-ord/t7 () (should t))
(ert-deftest iso-ord/t8 () (should t))"))
  "A suite of one file with eight passing tests.")

(defconst drgnx-test-order-test--polluted
  '(("pol-test.el" . "(defvar iso-pol--dirty nil)
(ert-deftest iso-pol/a-one () (should t))
(ert-deftest iso-pol/b-two () (should t))
(ert-deftest iso-pol/c-three () (should t))
(ert-deftest iso-pol/d-four () (should t))
(ert-deftest iso-pol/e-sets-it () (setq iso-pol--dirty t))
(ert-deftest iso-pol/f-six () (should t))
(ert-deftest iso-pol/g-seven () (should t))
(ert-deftest iso-pol/h-eight () (should t))
(ert-deftest iso-pol/z-needs-clean () (should-not iso-pol--dirty))"))
  "A suite whose test e sets a variable and whose last test fails when it is set.")

(defun drgnx-test-order-test--suite (dir files)
  "Write FILES, an alist NAME → contents, into the directory DIR (made)."
  (make-directory dir t)
  (pcase-dolist (`(,name . ,text) files)
    (with-temp-file (expand-file-name name dir) (insert "(require 'ert)\n" text "\n"))))

(defun drgnx-test-order-test--runner (suite results &rest env)
  "Run SUITE with the batch runner in a fresh Emacs with ENV; return (EXIT . OUTPUT).  The summary goes to RESULTS."
  (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results)) env
                                     drgnx-test-order-test--env-unset process-environment))
        (default-directory temporary-file-directory))
    (with-temp-buffer
      (cons (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                          "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                          "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" suite)
            (buffer-string)))))

(defun drgnx-test-order-test--bin (tmp suite &rest args)
  "Run bin/drgnx ARGS on the suite SUITE (DRGNX_TEST_DIR), HOME and TMPDIR below TMP; return (EXIT . OUTPUT)."
  (let ((process-environment (append (list (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory))
                                           (concat "DRGNX_TEST_DIR=" suite)
                                           (concat "HOME=" tmp) (concat "TMPDIR=" tmp))
                                     (cl-remove-if (lambda (v) (member v '("DRGNX_EMACS" "DRGNX_TEST_DIR")))
                                                   drgnx-test-order-test--env-unset)
                                     process-environment))
        (default-directory (file-name-as-directory tmp)))
    (with-temp-buffer
      (cons (apply #'call-process drgnx-test-order-test--bin nil t nil args) (buffer-string)))))

(defun drgnx-test-order-test--json (file)
  (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string)) :object-type 'plist))

(defun drgnx-test-order-test--names (results)
  "The names of the tests in the summary RESULTS, in the order they ran."
  (mapcar (lambda (tt) (plist-get tt :name)) (plist-get (drgnx-test-order-test--json results) :tests)))

(defmacro drgnx-test-order-test--with-suite (files &rest body)
  "Run BODY with TMP (a temp directory, removed afterwards), SUITE (FILES written in it) and RESULTS bound."
  (declare (indent 1))
  `(let* ((tmp (file-name-as-directory (make-temp-file "drgnx-ord" t)))
          (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
     (unwind-protect
         (progn (drgnx-test-order-test--suite suite ,files) ,@body)
       (delete-directory tmp t))))

(ert-deftest drgnx-test-order/same-seed-same-order ()
  (drgnx-test-order-test--with-suite drgnx-test-order-test--ordered
    (let (plain a b other one)
      (should (eql 0 (car (drgnx-test-order-test--runner suite results))))
      (setq plain (drgnx-test-order-test--names results))
      (should (eql 0 (car (drgnx-test-order-test--runner suite results "DRGNX_TEST_SHUFFLE=7"))))
      (setq a (drgnx-test-order-test--names results))
      (should (eql 0 (car (drgnx-test-order-test--runner suite results "DRGNX_TEST_SHUFFLE=7"))))
      (setq b (drgnx-test-order-test--names results))
      (should (eql 0 (car (drgnx-test-order-test--runner suite results "DRGNX_TEST_SHUFFLE=8"))))
      (setq other (drgnx-test-order-test--names results))
      ;; one Emacs for all the files gives the file the same order as its own Emacs does
      (should (eql 0 (car (drgnx-test-order-test--runner suite results "DRGNX_TEST_SHUFFLE=7" "DRGNX_TEST_ONE_PROCESS=1"))))
      (setq one (drgnx-test-order-test--names results))
      (should (equal (sort (copy-sequence plain) #'string<) (sort (copy-sequence a) #'string<))) ; the same tests
      (should (= 8 (length a)))
      (should (equal a b))
      (should (equal a one))
      (should-not (equal a plain))
      (should-not (equal a other)))))

(ert-deftest drgnx-test-order/seed-is-in-the-summary ()
  (drgnx-test-order-test--with-suite drgnx-test-order-test--ordered
    (dolist (env '(nil ("DRGNX_TEST_ONE_PROCESS=1")))
      ;; without the flag: no seed, no mention
      (let ((r (apply #'drgnx-test-order-test--runner suite results env)))
        (should-not (plist-member (drgnx-test-order-test--json results) :seed))
        (should-not (string-match-p "shuffle seed" (cdr r))))
      ;; with it: printed, and in the JSON as a string
      (let ((r (apply #'drgnx-test-order-test--runner suite results "DRGNX_TEST_SHUFFLE=1234" env)))
        (should (equal "1234" (plist-get (drgnx-test-order-test--json results) :seed)))
        (should (string-match-p "shuffle seed 1234" (cdr r)))))))

(ert-deftest drgnx-test-order/finds-the-polluter ()
  (drgnx-test-order-test--with-suite drgnx-test-order-test--polluted
    ;; the polluted run fails ...
    (should (eql 1 (car (drgnx-test-order-test--runner suite results "DRGNX_TEST_ONE_PROCESS=1"))))
    ;; ... and the bisect names the test that sets the variable, in log2 N + 2 runs at most (N = 8 tests before it)
    (let* ((r (drgnx-test-order-test--bin tmp suite "test" "--find-polluter" "iso-pol/z-needs-clean"))
           (runs (and (string-match "(\\([0-9]+\\) runs)" (cdr r)) (string-to-number (match-string 1 (cdr r))))))
      (should (eql 0 (car r)))
      (should (string-match-p "likely polluter (unconfirmed): iso-pol/e-sets-it" (cdr r)))
      (should-not (string-match-p "polluter[^\n]*: iso-pol/[^e]" (cdr r)))
      (should (and runs (<= runs (+ 2 (ceiling (log 8 2)))))))))

(ert-deftest drgnx-test-order/finds-the-polluter-across-files ()
  ;; the polluter in one file, the test it breaks in another: FILES name both
  (drgnx-test-order-test--with-suite '(("a-test.el" . "(defvar iso-pol--dirty nil)
(ert-deftest iso-pol/a-clean () (should t))
(ert-deftest iso-pol/b-sets-it () (setq iso-pol--dirty t))
(ert-deftest iso-pol/c-clean () (should t))")
                                       ("z-test.el" . "(ert-deftest iso-pol/z-needs-clean () (should-not (bound-and-true-p iso-pol--dirty)))"))
    (let ((r (drgnx-test-order-test--bin tmp suite "test" "--find-polluter" "iso-pol/z-needs-clean"
                                         (expand-file-name "a-test.el" suite) (expand-file-name "z-test.el" suite))))
      (should (eql 0 (car r)))
      (should (string-match-p "likely polluter (unconfirmed): iso-pol/b-sets-it" (cdr r))))
    ;; without FILES only TEST's own file is loaded: nothing before it pollutes it
    (let ((r (drgnx-test-order-test--bin tmp suite "test" "--find-polluter" "iso-pol/z-needs-clean")))
      (should (eql 1 (car r)))
      (should (string-match-p "iso-pol/z-needs-clean passes" (cdr r))))))

(ert-deftest drgnx-test-order/says-when-the-test-fails-alone ()
  (drgnx-test-order-test--with-suite '(("alone-test.el" . "(ert-deftest iso-alone/a-fine () (should t))
(ert-deftest iso-alone/b-broken () (should nil))")
                                       ("other-test.el" . "(ert-deftest iso-other/ok () (should t))"))
    (let ((r (drgnx-test-order-test--bin tmp suite "test" "--find-polluter" "iso-alone/b-broken")))
      (should (eql 0 (car r)))
      (should (string-match-p "iso-alone/b-broken fails alone" (cdr r)))
      (should-not (string-match-p "polluter" (cdr r)))
      (should (string-match-p "(1 run)" (cdr r))))
    ;; a name no test has is a usage error, not a pass
    (let ((r (drgnx-test-order-test--bin tmp suite "test" "--find-polluter" "iso-alone/nope")))
      (should (eql 2 (car r)))
      (should (string-match-p "iso-alone/nope" (cdr r))))))

(ert-deftest drgnx-test-order/the-shuffled-order-is-the-bisected-one ()
  ;; with a seed the tests before TEST are those the shuffled run puts before it: the bisect and the run agree.
  ;; Seeds are searched for, one that puts the polluter before the victim and one that puts it after, so the test
  ;; says nothing about which order a particular seed gives.
  (drgnx-test-order-test--with-suite drgnx-test-order-test--polluted
    (let (before after)
      (cl-loop for i from 1 to 40
               for seed = (number-to-string i)
               until (and before after)
               do (drgnx-test-order-test--runner suite results (concat "DRGNX_TEST_SHUFFLE=" seed) "DRGNX_TEST_ONE_PROCESS=1")
               (let ((ran (drgnx-test-order-test--names results)))
                 (if (< (cl-position "iso-pol/e-sets-it" ran :test #'equal) (cl-position "iso-pol/z-needs-clean" ran :test #'equal))
                     (unless before (setq before seed))
                   (unless after (setq after seed)))))
      (should before)
      (should after)
      (let ((r (drgnx-test-order-test--bin tmp suite "test" (concat "--shuffle=" before) "--find-polluter" "iso-pol/z-needs-clean")))
        (should (eql 0 (car r)))
        (should (string-match-p (format "shuffle seed %s" before) (cdr r)))
        (should (string-match-p "likely polluter (unconfirmed): iso-pol/e-sets-it" (cdr r))))
      (let ((r (drgnx-test-order-test--bin tmp suite "test" (concat "--shuffle=" after) "--find-polluter" "iso-pol/z-needs-clean")))
        (should (eql 1 (car r)))
        (should (string-match-p (format "shuffle seed %s" after) (cdr r)))
        (should (string-match-p "iso-pol/z-needs-clean passes" (cdr r)))))))

(ert-deftest drgnx-test-order/the-order-does-not-reseed-random ()
  ;; shuffling uses a generator of its own: the global `random' goes on as it would have
  (drgnx-test-order-test--with-suite drgnx-test-order-test--ordered
    (drgnx-test-order-test--suite
     suite `(("rand-test.el" . ,(format "(ert-deftest iso-rand/a () (with-temp-file %S (prin1 (list (random 1000000) (random 1000000)) (current-buffer))))" (expand-file-name "rand" tmp)))))
    (let (seen)
      (dolist (env '(nil ("DRGNX_TEST_SHUFFLE=7") ("DRGNX_TEST_SHUFFLE=7")))
        (apply #'drgnx-test-order-test--runner suite results "DRGNX_TEST_SELECTOR=\"iso-rand/\"" env)
        (push (with-temp-buffer (insert-file-contents (expand-file-name "rand" tmp)) (buffer-string)) seen))
      ;; an unshuffled run draws fresh numbers each time; a seeded generator would give the same pair every run
      (should-not (equal (nth 0 seen) (nth 1 seen)))
      (should-not (equal (nth 1 seen) (nth 2 seen))))))

(ert-deftest drgnx-test-order/tests-do-not-see-the-bisect-variables ()
  ;; The bisect's Emacsen get DRGNX_TEST_ORDER_IN.  A test of theirs that starts a runner must get a normal one:
  ;; the outer runner scrubs the variable for its tests (it read it first).  Here the outer is given ORDER_IN naming
  ;; one test, which starts a nested runner on a two-test suite and writes what it saw.
  (drgnx-test-order-test--with-suite nil
    (let ((seen (expand-file-name "seen" tmp)) (order (expand-file-name "order" tmp)))
      (drgnx-test-order-test--suite
       suite
       `(("env-test.el" . ,(format "(ert-deftest iso-env/nested ()
  (let* ((inner (make-temp-file \"inner\" t)) (json (expand-file-name \"r.json\" inner)))
    (with-temp-file (expand-file-name \"x-test.el\" inner)
      (insert \"(require 'ert) (ert-deftest iso-inner/a () (should t)) (ert-deftest iso-inner/b () (should t))\"))
    (let ((process-environment (cons (concat \"DRGNX_TEST_RESULTS=\" json) process-environment)))
      (call-process %S nil nil nil \"--batch\" \"-Q\" \"-L\" %S \"-l\" %S \"-f\" \"drgnx-run-ert-batch\" inner))
    (with-temp-file %S
      (prin1 (list (getenv \"DRGNX_TEST_ORDER_IN\")
                   (plist-get (json-parse-string (with-temp-buffer (insert-file-contents json) (buffer-string)) :object-type 'plist) :total))
             (current-buffer)))))
(ert-deftest iso-env/other () (should t))"
                                   (expand-file-name invocation-name invocation-directory)
                                   (file-name-directory (locate-library "run-ert.el")) (locate-library "run-ert.el") seen))))
      (with-temp-file order (insert "iso-env/nested\n"))
      (should (eql 0 (car (drgnx-test-order-test--runner suite results (concat "DRGNX_TEST_ORDER_IN=" order) "DRGNX_TEST_ONE_PROCESS=1"))))
      (should (= 1 (plist-get (drgnx-test-order-test--json results) :total)))   ; ORDER_IN picked the one test
      (should (equal nil (car (read (with-temp-buffer (insert-file-contents seen) (buffer-string))))))
      (should (= 2 (cadr (read (with-temp-buffer (insert-file-contents seen) (buffer-string)))))))))

(ert-deftest drgnx-test-order/a-missing-file-is-usage-not-a-backtrace ()
  (drgnx-test-order-test--with-suite drgnx-test-order-test--polluted
    (let ((r (drgnx-test-order-test--bin tmp suite "test" "--find-polluter" "iso-pol/z-needs-clean" (expand-file-name "nope-test.el" suite))))
      (should (eql 2 (car r)))
      (should (string-match-p "no such test file or directory: .*nope-test.el" (cdr r)))
      (should (string-match-p "usage: drgnx test" (cdr r)))
      (should-not (string-match-p "Debugger\\|Backtrace\\|  apply(" (cdr r))))))

(ert-deftest drgnx-test-order/the-flags-reach-the-runner ()
  ;; bin/drgnx test --shuffle[=SEED] / --find-polluter: what the runner's Emacs is given (a fake Emacs records it)
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-ord" t)))
         (seen (expand-file-name "seen" tmp))
         (fake (expand-file-name "fake-emacs" tmp))
         (default-directory tmp))
    (unwind-protect
        (progn
          (with-temp-file fake
            (insert (format "#!/bin/sh\necho \"${DRGNX_TEST_SHUFFLE-unset}|${DRGNX_TEST_LEAKS-unset}|$*\" >> %s\n" seen)))
          (set-file-modes fake #o755)
          (let ((process-environment (append (list (concat "DRGNX_EMACS=" fake) (concat "HOME=" tmp) (concat "TMPDIR=" tmp)
                                                   "DRGNX_TEST_DIR=/suite")
                                             (cl-remove-if (lambda (v) (member v '("DRGNX_EMACS" "DRGNX_TEST_DIR")))
                                                           drgnx-test-order-test--env-unset)
                                             process-environment)))
            (cl-flet ((bin (&rest args) (with-temp-buffer (cons (apply #'call-process drgnx-test-order-test--bin nil t nil args)
                                                                (buffer-string)))))
              (should (eql 0 (car (bin "test"))))
              (should (eql 0 (car (bin "test" "--shuffle=abc-1.2"))))
              (should (eql 0 (car (bin "test" "--leaks" "--shuffle" "--one-process"))))
              (should (eql 0 (car (bin "test" "--find-polluter" "iso/t" "/a-test.el" "/b-test.el"))))
              (should (eql 0 (car (bin "test" "--shuffle=5" "--find-polluter" "iso/t"))))
              ;; a seed with a space or a slash, an empty one, and --find-polluter with no test: usage, exit 2
              (dolist (args '(("test" "--shuffle=a b") ("test" "--shuffle=a/b") ("test" "--shuffle=") ("test" "--find-polluter")))
                (let ((r (apply #'bin args)))
                  (should (eql 2 (car r)))
                  (should (string-match-p "usage: drgnx test" (cdr r)))))))
          (let ((lines (split-string (with-temp-buffer (insert-file-contents seen) (buffer-string)) "\n" t)))
            (should (= 5 (length lines)))
            (should (string-match-p "\\`unset|unset|.* -f drgnx-run-ert-batch /suite\\'" (nth 0 lines))) ; no flag: no variable
            (should (string-match-p "\\`abc-1\\.2|unset|.* -f drgnx-run-ert-batch /suite\\'" (nth 1 lines)))
            (should (string-match-p "\\`[0-9]+|1|.* -f drgnx-run-ert-batch /suite\\'" (nth 2 lines))) ; a generated seed: a number
            (should (string-match-p " -f drgnx-run-ert-find-polluter-batch /suite iso/t /a-test.el /b-test.el\\'" (nth 3 lines)))
            (should (string-match-p "\\`5|unset|.* -f drgnx-run-ert-find-polluter-batch /suite iso/t\\'" (nth 4 lines)))))
      (delete-directory tmp t))))

(provide 'test-order-test)
;;; test-order-test.el ends here
