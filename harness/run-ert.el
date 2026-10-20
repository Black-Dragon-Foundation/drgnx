;;; run-ert.el --- Run drgnx ERT suites and write a JSON summary -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Used by `drgnx test' (batch) and by harness sessions in test mode (GUI).  The JSON
;; summary carries the details, because a GUI session's exit status is only pass/fail.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ert)
(require 'drgnx-test-env (expand-file-name "drgnx-test-env" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-run-ert-drain-events ()
  "Handle the events queued for a command loop batch Emacs does not have (file-notify events from a test's
watches): while one waits in the input queue, Emacs runs no process sentinel — later tests would never hear
their processes end.  The runner calls this after every test."
  (dotimes (_ 2) (read-event nil nil 0.002)))     ; 0 reads nothing: the event must be fetched first

(defun drgnx-run-ert--files (where)
  "The test files WHERE names: every *-test.el under a directory, or a list of files (a shard)."
  (if (and (stringp where) (file-directory-p where))
      (directory-files-recursively (expand-file-name where) "-test\\.el\\'")
    (mapcar #'expand-file-name (if (listp where) where (list where)))))

;;;; The leak census

;; With DRGNX_TEST_LEAKS set (`bin/drgnx test --leaks'), the cheap fingerprint (core/drgnx-modules-fingerprint.el) is
;; read around every test, the full one around every test file; each difference is a leak, recorded with the test, its
;; file and the file that defined the function concerned.  Report only: the exit status is the tests'.

(defvar drgnx-run-ert--self)

(defvar drgnx-run-ert--leaks nil "The leaks recorded so far, newest first: plists (:test :file :what :source).")

(defvar drgnx-run-ert--leaks-allowed nil "The entries of the allowlist: plists (:what REGEXP :source REGEXP :why STRING).")

(defvar drgnx-run-ert--census-file nil "The test file the census is in (its tests are running), or nil.")

(defvar drgnx-run-ert--census-start nil "The full fingerprint taken when the census entered `drgnx-run-ert--census-file'.")

(defvar drgnx-run-ert--census-seen nil "The :what lines recorded for the current file's tests: the per-file scan skips them.")

(defvar drgnx-run-ert--leaks-quiet nil
  "Non-nil in the Emacs of a test file that a run started (DRGNX_TEST_LEAKS_QUIET): the run prints one report.")

(defvar drgnx-run-ert--census-busy nil "Non-nil inside a test the census runs: a test that runs `ert-run-test' itself is not counted.")

(defun drgnx-run-ert--leaks-on-p ()
  "Whether DRGNX_TEST_LEAKS asks for the census."
  (let ((s (getenv "DRGNX_TEST_LEAKS"))) (and s (not (string-empty-p s)))))

(defun drgnx-run-ert--leaks-allowed-file ()
  "The allowlist: DRGNX_TEST_LEAKS_ALLOWED (a file), else test/leaks-allowed.eld of this checkout."
  (let ((given (getenv "DRGNX_TEST_LEAKS_ALLOWED")))
    (if (and given (not (string-empty-p given)))
        (expand-file-name given)
      (expand-file-name "../test/leaks-allowed.eld" (file-name-directory drgnx-run-ert--self)))))

(defun drgnx-run-ert--read-allowed (file)
  "The allowlist entries in FILE; a missing file allows nothing, an unreadable one is said and allows nothing."
  (when (file-readable-p file)
    (condition-case err
        (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
      (error (message "drgnx: leak allowlist %s does not read: %S" file err) nil))))

(defun drgnx-run-ert--leak-allowed-p (what source)
  "Whether the allowlist has an entry for the leak WHAT (a line) from SOURCE (a file, or nil): its :what matches,
and so does its :source when it has one."
  (cl-some (lambda (a)
             (and (string-match-p (plist-get a :what) what)
                  (or (null (plist-get a :source)) (string-match-p (plist-get a :source) (or source "")))))
           drgnx-run-ert--leaks-allowed))

(defun drgnx-run-ert--relative-source (source)
  "SOURCE, a file, relative to this checkout when it is inside it (so a report reads the same in every worktree)."
  (let ((root (file-name-directory (directory-file-name (file-name-directory drgnx-run-ert--self)))))
    (cond ((not (stringp source)) nil)
          ((string-prefix-p root source) (file-relative-name source root))
          ((string-prefix-p (file-truename root) source) (file-relative-name source (file-truename root)))
          (t source))))

(defun drgnx-run-ert--census-note (test file diff)
  "Record the entries of DIFF (`drgnx-modules-fingerprint-diff') as leaks of TEST (a name; :null for the per-file
scan) in FILE, but those on the allowlist and, for the per-file scan, those a test of the file was already named for."
  (dolist (d diff)
    (let ((what (plist-get d :what)) (source (drgnx-run-ert--relative-source (plist-get d :source))))
      (unless (or (drgnx-run-ert--leak-allowed-p what source)
                  (and (eq test :null) (member what drgnx-run-ert--census-seen)))
        (unless (eq test :null) (push what drgnx-run-ert--census-seen))
        (push (list :test test :file (or file :null) :what what :source (or source :null)) drgnx-run-ert--leaks)))))

(defun drgnx-run-ert--census-guard (test file thunk)
  "Call THUNK; an error in it is recorded as a census line of TEST in FILE and nil returned: the census reports,
it never ends a run."
  (condition-case err (funcall thunk)
    (error (push (list :test test :file (or file :null) :what (format "census error: %S" err) :source :null)
                 drgnx-run-ert--leaks)
           nil)))

(defun drgnx-run-ert--census-leave-file ()
  "End the current file: the full fingerprint against the one at its start, then its test buffers go."
  (when drgnx-run-ert--census-start
    (drgnx-run-ert--census-guard
     :null drgnx-run-ert--census-file
     (lambda ()
       (drgnx-run-ert--census-note :null drgnx-run-ert--census-file
                                   (drgnx-modules-fingerprint-diff drgnx-run-ert--census-start (drgnx-modules-fingerprint t)))))
    (let ((inhibit-message t)) (ignore-errors (ert-kill-all-test-buffers)))
    (setq drgnx-run-ert--census-file nil drgnx-run-ert--census-start nil drgnx-run-ert--census-seen nil)))

(defun drgnx-run-ert--census-enter-file (file)
  "A test of FILE is about to run: when it is not the file the census is in, end that one and start this."
  (unless (and drgnx-run-ert--census-start (equal file drgnx-run-ert--census-file))
    (drgnx-run-ert--census-leave-file)
    (setq drgnx-run-ert--census-file file
          drgnx-run-ert--census-seen nil
          drgnx-run-ert--census-start (drgnx-run-ert--census-guard :null file (lambda () (drgnx-modules-fingerprint t))))))

(defun drgnx-run-ert--census-timers (fingerprint)
  "The timers FINGERPRINT holds."
  (mapcar #'cdr (plist-get fingerprint :timers)))

(defun drgnx-run-ert-census (run test &rest args)
  "Around `ert-run-test': the cheap fingerprint before and after TEST; each difference is a leak of TEST.  A timer
the test left pending is cancelled, so it cannot fire inside the next test; a layer timer (core/drgnx-timer.el) by
its key, so the layer forgets it too.  An error in the census is a line of the report
\(`drgnx-run-ert--census-guard'), never an error of the test run."
  (if drgnx-run-ert--census-busy
      (apply run test args)
    (let* ((file (ert-test-file-name test)) (name (symbol-name (ert-test-name test)))
           (drgnx-run-ert--census-busy t) before)
      (drgnx-run-ert--census-guard name file (lambda () (drgnx-run-ert--census-enter-file file)))
      (setq before (drgnx-run-ert--census-guard name file #'drgnx-modules-fingerprint))
      (prog1 (apply run test args)
        (drgnx-run-ert--census-guard
         name file
         (lambda ()
           (let ((after (drgnx-modules-fingerprint)))
             (when before
               (drgnx-run-ert--census-note name file (drgnx-modules-fingerprint-diff before after))
               (let ((old (drgnx-run-ert--census-timers before)))
                 (dolist (tm (drgnx-run-ert--census-timers after))
                   (unless (memq tm old)
                     (let ((layer (and (fboundp 'drgnx-timer-describe) (drgnx-timer-describe tm))))
                       (if layer (drgnx-timer-cancel (plist-get layer :key)) (cancel-timer tm))))))))))))))

(defun drgnx-run-ert--census-start ()
  "Turn the census on: load the fingerprint, read the allowlist, advise `ert-run-test'."
  (let ((load-path (cons (expand-file-name "../core" (file-name-directory drgnx-run-ert--self)) load-path)))
    (require 'drgnx-modules-fingerprint))
  (setq drgnx-run-ert--leaks nil
        drgnx-run-ert--census-file nil drgnx-run-ert--census-start nil drgnx-run-ert--census-seen nil
        drgnx-run-ert--leaks-allowed (drgnx-run-ert--read-allowed (drgnx-run-ert--leaks-allowed-file)))
  (advice-add 'ert-run-test :around #'drgnx-run-ert-census '((name . drgnx-run-ert-census))))

(defun drgnx-run-ert--census-finish ()
  "End the last file, turn the census off, and return the leaks in the order they appeared (a list of plists)."
  (drgnx-run-ert--census-leave-file)
  (advice-remove 'ert-run-test #'drgnx-run-ert-census)
  (nreverse (prog1 drgnx-run-ert--leaks (setq drgnx-run-ert--leaks nil))))

(defun drgnx-run-ert-leaks-report (leaks)
  "LEAKS (plists, or the vector of them) as text: \"Leaks (N)\" and a line each (test, file, what, source); \"\" for none."
  (let ((leaks (append leaks nil)))
    (if (null leaks)
        ""
      (concat (format "Leaks (%d)\n" (length leaks))
              (mapconcat (lambda (l)
                           (let ((test (plist-get l :test)) (file (plist-get l :file)) (source (plist-get l :source)))
                             (format "  %s  %s  %s%s" (if (stringp test) test "(file)")
                                     (if (stringp file) (file-name-nondirectory file) "?")
                                     (plist-get l :what) (if (stringp source) (format "  [%s]" source) ""))))
                         leaks "\n")
              "\n"))))

;;;; The order of the tests

;; With DRGNX_TEST_SHUFFLE=SEED (`bin/drgnx test --shuffle[=SEED]') the tests of each file run in a random order that
;; SEED fixes, so a test that passes only after another one (a leaked hook, a variable left set) fails; the seed is
;; printed and written to the summary.  `bin/drgnx test --find-polluter TEST' bisects such a failure (below).
;; ERT keeps the order of a `(member …)' selector, which is how both give the tests their order.

(defun drgnx-run-ert--shuffle-seed ()
  "The seed of this run's shuffle (DRGNX_TEST_SHUFFLE, a string), or nil: tests run in ERT's order."
  (drgnx-run-ert--env "DRGNX_TEST_SHUFFLE"))

(defun drgnx-run-ert--shuffle (items seed)
  "ITEMS (a list) in an order SEED (a string) fixes: Fisher-Yates over a generator of this function's own (FNV-1a of
SEED, then the Park-Miller one, x -> 48271 x mod 2^31-1), so the order is the same on every OS and Emacs, and the
global `random' state, which tests and `make-temp-file' use, is not touched."
  (let* ((h 2166136261) (state nil) (v (vconcat items)) (i (length v)))
    (dolist (c (append seed nil)) (setq h (logand (* (logxor h c) 16777619) #xFFFFFFFF)))
    (setq state (1+ (mod h 2147483646)))
    (while (> i 1)
      (setq state (mod (* state 48271) 2147483647))
      (let ((j (mod state i)) (tmp nil))
        (cl-decf i)
        (setq tmp (aref v i)) (aset v i (aref v j)) (aset v j tmp)))
    (append v nil)))

(defun drgnx-run-ert--order (tests seed)
  "The ert-test objects TESTS in the order of a run shuffled by SEED: files by name, and each file's tests (by name
first, so the list's own order does not matter) shuffled from SEED and the file's base name, so a file has the same
order whether it runs alone or with the others."
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (test tests) (push test (gethash (or (ert-test-file-name test) "") groups)))
    (mapcan (lambda (file)
              (drgnx-run-ert--shuffle
               (sort (gethash file groups) (lambda (a b) (string< (format "%s" (ert-test-name a)) (format "%s" (ert-test-name b)))))
               (format "%s:%s" seed (file-name-nondirectory file))))
            (sort (hash-table-keys groups) #'string<))))

(defvar drgnx-run-ert--order-in nil
  "DRGNX_TEST_ORDER_IN as `drgnx-run-ert-batch' read it before it scrubbed the environment for the tests, or nil.")

(defvar drgnx-run-ert--order-out nil
  "DRGNX_TEST_ORDER_OUT as `drgnx-run-ert-batch' read it before it scrubbed the environment for the tests, or nil.")

(defvar drgnx-run-ert--file-child nil
  "Non-nil in the Emacs of one test file (DRGNX_TEST_FILE_CHILD as `drgnx-run-ert-batch' read it): its parent counts
the run's tests.")

(defun drgnx-run-ert--env (var)
  "The value of the environment variable VAR, or nil when it is unset or empty."
  (let ((s (getenv var))) (and s (not (string-empty-p s)) s)))

(defun drgnx-run-ert--selector ()
  "The ERT selector of this run: DRGNX_TEST_SELECTOR (an ERT selector; `bin/drgnx check' runs :timing ones alone),
else every test; with a shuffle seed, the selected tests as a `(member …)' in the shuffled order.  The Emacsen of
--find-polluter (one process) also read DRGNX_TEST_ORDER_IN=FILE, the names of the tests to run in that order, one a
line (a file: a whole suite's names would not fit in the environment), and DRGNX_TEST_ORDER_OUT=FILE, which writes the
names the run would run, in that order, to FILE and runs none."
  (let* ((s (drgnx-run-ert--env "DRGNX_TEST_SELECTOR"))
         (selector (if s (car (read-from-string s)) t))
         (seed (drgnx-run-ert--shuffle-seed))
         (in drgnx-run-ert--order-in)
         (out drgnx-run-ert--order-out))
    (cond
     (in `(member ,@(mapcar #'intern (split-string (with-temp-buffer (insert-file-contents in) (buffer-string)) "\n" t))))
     ((not (or seed out)) selector)
     (t (let ((tests (ert-select-tests selector t)))
          (when seed (setq tests (drgnx-run-ert--order tests seed)))
          (if out
              (progn (write-region (mapconcat (lambda (tt) (format "%s\n" (ert-test-name tt))) tests "") nil out nil 'silent)
                     '(member))                 ; not nil: `ert-run-tests-batch' takes that for every test
            `(member ,@tests)))))))

(defun drgnx-run-ert--say-seed (seed)
  "Say SEED, the shuffle seed of this run, and how to run again with it."
  (message "drgnx: shuffle seed %s (the same order again: bin/drgnx test --shuffle=%s)" seed seed))

(defun drgnx-run-ert (dir &optional results-file)
  "Load every *-test.el under DIR (or the files of the list DIR: a shard), run all tests, write a JSON
summary to RESULTS-FILE.  Return t if every test passed."
  (advice-add 'ert-run-test :after (lambda (&rest _) (drgnx-run-ert-drain-events)) '((name . drgnx-run-ert-drain)))
  (let* ((census (and (drgnx-run-ert--leaks-on-p) (progn (drgnx-run-ert--census-start) t)))
         ;; the RAW selector, for the file filter: `drgnx-run-ert--selector' needs the files loaded, and with a
         ;; shuffle it is a `(member …)', not a string (which would load every file)
         (selector (let ((s (getenv "DRGNX_TEST_SELECTOR"))) (and s (not (string-empty-p s)) (car (read-from-string s)))))
         (load-failures
          ;; only the files that can hold a selected test: a narrowed run of one Emacs (a session, --one-process)
          ;; loads nothing else (M12f-A3-1, as `drgnx-run-ert-files' does)
          (cl-loop for file in (cl-remove-if-not (lambda (f) (drgnx-run-ert--file-selected-p f selector))
                                                 (drgnx-run-ert--files dir))
                   ;; a file that does not read or load costs its tests: the run fails and says which file
                   for err = (condition-case err (progn (load file nil t) nil) (error err) (quit err))
                   when err collect (progn (message "drgnx: test file %s did not load: %S" file err)
                                           (list :name (concat "load " (file-name-nondirectory file))
                                                 :condition (format "%S" err)))))
         ;; which tests, in which order: DRGNX_TEST_SELECTOR, DRGNX_TEST_SHUFFLE (see `drgnx-run-ert--selector')
         (seed (drgnx-run-ert--shuffle-seed))
         (_ (when (and seed (not drgnx-run-ert--leaks-quiet)) (drgnx-run-ert--say-seed seed)))
         (stats (ert-run-tests-batch (drgnx-run-ert--selector)))
         ;; a test the prefilter could not see (a full run), a name selector that picked nothing (not in a file's own
         ;; Emacs: its parent counts)
         (load-failures
          (append load-failures
                  (and (null selector) (not drgnx-run-ert--order-in) (drgnx-run-ert--unindexed stats dir))
                  (and (stringp selector) (not drgnx-run-ert--file-child)
                       (zerop (+ (ert-stats-total stats) (length load-failures)))
                       (list (drgnx-run-ert--matched-nothing selector)))))
         (leaks (and census (drgnx-run-ert--census-finish)))
         (tests nil) (known-red nil) (failures nil))
    (cl-loop
     for test across (ert--stats-tests stats)
     for name = (symbol-name (ert-test-name test))
     for result = (ert-test-most-recent-result test)
     for expected = (ert-test-result-expected-p test result)
     for condition = (and (ert-test-result-with-condition-p result)
                          (ert-test-result-with-condition-condition result))
     do
     (push (list :name name
                 :result (cond ((ert-test-passed-p result) "passed")
                               ((ert-test-skipped-p result) "skipped")
                               (t "failed"))
                 :expected (if expected t :false)
                 ;; where and how long: bin/drgnx check balances its shards with them
                 :file (or (ert-test-file-name test) :null)
                 :seconds (or (ignore-errors (ert-test-result-duration result)) 0))
           tests)
     (cond
      ((not expected)
       (push (list :name name :condition (if condition (format "%S" condition) "unexpected result")) failures))
      ((ert-test-failed-p result)
       ;; An expected failure (a known red) counts only if it failed an assertion; an error
       ;; (missing fixture, broken driver, timeout) is never acceptable.
       ;; It must also be a `drgnx-scenario-check' failure (carrying its explanation and
       ;; trace), not a bare `should' that could fail for any reason.
       (let* ((data (and (eq (car condition) 'ert-test-failed) (cadr condition)))
              (summary (ignore-errors (plist-get data :scenario))))
         (cond
          (summary (push (list :name name :summary summary
                               :trace (or (ignore-errors (plist-get data :trace)) []))
                         known-red))
          (data (push (list :name name :condition
                            (format "known red, but it failed outside drgnx-scenario-check: %S" condition))
                      failures))
          (t (push (list :name name :condition (format "known red, but it errored: %S" condition))
                   failures)))))))
    (setq failures (append load-failures (nreverse failures)))
    (when (and seed failures (not drgnx-run-ert--leaks-quiet)) (drgnx-run-ert--say-seed seed)) ; again, where the failures are
    ;; the per-file Emacsen of a run say nothing: the run that started them prints one report from their summaries
    (when (and leaks (not drgnx-run-ert--leaks-quiet))
      (message "\n%s" (drgnx-run-ert-leaks-report leaks)))
    (when results-file
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region
         (decode-coding-string
          (json-serialize
           (append (list :total (+ (ert-stats-total stats) (length load-failures))
                         :passed (ert-stats-completed-expected stats)
                         :failed (length failures)
                         :failures (vconcat failures)
                         :known_red (vconcat (nreverse known-red))
                         :tests (vconcat (nreverse tests)))
                   ;; only a run with the census on says anything about leaks
                   (and census (list :leaks (vconcat leaks)))
                   ;; a shuffled run says which seed it used
                   (and seed (list :seed seed))))
          'utf-8)
         nil results-file nil 'silent)))
    (null failures)))

;;;; One Emacs per test file

(defconst drgnx-run-ert--self (or load-file-name buffer-file-name) "This file: every per-file Emacs loads it.")

(defvar drgnx-run-ert--file-processes nil "The per-file Emacsen running now; they end with the run.")

(defvar drgnx-run-ert--file-dirs nil "The temp directories of the per-file Emacsen running now.")

(defvar drgnx-run-ert--file-root nil "The short directory the per-file Emacsen's temp directories are made in.")

(defun drgnx-run-ert--short-root ()
  "A new directory of this user's (mode 0700) right in /tmp (`temporary-file-directory' where /tmp cannot be
written), for the per-file Emacsen's temp directories.  A Unix socket's path has at most 103 bytes on macOS (104
with its closing NUL; 107 on Linux), and the hub's tests make one three levels below a file's temp directory
\(run/drgnx/hub-HASH.sock): macOS's TMPDIR (/var/folders/xx/…/T/, 49 bytes) or any deep one leaves no room for
that, /tmp/drgnx-t-XXXXXX/drgnx-run.XXXXXX/ (37 bytes) does.  Its true name, as bin/drgnx's own directory
\(macOS's /tmp is a link to /private/tmp: 45 bytes): a test that compares paths sees one spelling."
  (let ((temporary-file-directory (if (file-writable-p "/tmp/") "/tmp/" temporary-file-directory)))
    (file-truename (with-file-modes #o700 (make-temp-file "drgnx-t-" t)))))

(defun drgnx-run-ert--env-number (var default)
  "The whole number above 0 in the environment variable VAR, else DEFAULT."
  (let ((s (getenv var)))
    (if (and s (string-match-p "\\`[1-9][0-9]*\\'" s)) (string-to-number s) default)))

(defun drgnx-run-ert-time-factor ()
  "What a `:timing' test multiplies its wall-clock budgets by: DRGNX_TEST_TIME_FACTOR, a number of at least 1 for
a machine slower than the one the budgets were set on (the macOS CI runner: 2), else 1.  The budgets themselves
stay as measured; a factor below 1 or not a number is ignored."
  (let* ((s (getenv "DRGNX_TEST_TIME_FACTOR"))
         (n (and s (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" s) (string-to-number s))))
    (if (and n (>= n 1)) n 1)))

(defun drgnx-run-ert--end-process (p &optional grace)
  "End P and what it started (its process group, as Emacs starts each process): TERM, GRACE seconds (default 5)
to clean up, then KILL."
  (ignore-errors (signal-process (- (process-id p)) 'TERM))
  (let ((deadline (+ (float-time) (or grace 5))))
    (while (and (process-live-p p) (< (float-time) deadline)) (accept-process-output p 0.05)))
  (ignore-errors (signal-process (- (process-id p)) 'KILL))
  (while (process-live-p p) (accept-process-output p 0.05)))

(defun drgnx-run-ert--end-files ()
  "`kill-emacs-hook' of a per-file run (C-c, TERM): end the files' Emacsen, which run in process groups of their own,
and remove their temp directories and the root they are in.  The Emacsen get up to 2 s to end first, so none
writes into a directory being removed; a root that cannot be removed is reported."
  (dolist (p drgnx-run-ert--file-processes)
    (when (process-live-p p) (ignore-errors (signal-process (- (process-id p)) 'TERM))))
  (let ((deadline (+ (float-time) 2)))
    (while (and (cl-some #'process-live-p drgnx-run-ert--file-processes) (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (dolist (d drgnx-run-ert--file-dirs) (ignore-errors (delete-directory d t)))
  (when drgnx-run-ert--file-root
    (condition-case err
        (delete-directory drgnx-run-ert--file-root t)
      (error (message "drgnx: could not remove %s: %s" drgnx-run-ert--file-root (error-message-string err))))
    (setq drgnx-run-ert--file-root nil)))

(defun drgnx-run-ert--file-ended (p _event)
  "Sentinel of a file's Emacs P: the file is over once this has run, as Emacs reads what is left in the pipe before
it runs a sentinel.  `process-live-p' is nil earlier: a buffer killed then, with output still coming, made the next
chunk's filter fail, which ends a batch Emacs (the whole run)."
  (unless (process-live-p p) (process-put p :ended t)))

(defun drgnx-run-ert--start-file (file tmp json buffer)
  "Start an Emacs that runs the test FILE alone (`drgnx-run-ert-batch', this Emacs's `load-path' and environment),
in the temp directory TMP (its DRGNX_RUN_TMP: used, never deleted, by it), its summary to JSON.  Its output goes
to BUFFER, or to this Emacs's standard error when BUFFER is nil."
  (let* ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" json) "DRGNX_TEST_ONE_PROCESS=1" "DRGNX_TEST_LEAKS_QUIET=1" "DRGNX_TEST_FILE_CHILD=1"
                                            (concat "DRGNX_RUN_TMP=" tmp)
                                            ;; the run's own: a test that runs the runner again runs its files
                                            ;; one at a time, as in a serial run
                                            "DRGNX_TEST_JOBS")
                                      process-environment))
         (p (make-process
             :name (concat "drgnx-test-file " (file-name-nondirectory file)) :noquery t :connection-type 'pipe
             :coding 'utf-8
             ;; SIGPIPE ignored, as bin/drgnx runs this Emacs: Emacs starts its children with the default action,
             ;; and a write to a reader that left (the gateway answering an agent that hung up) would end the file's
             ;; Emacs with no summary (`drgnx-command-ignoring-sigpipe', which the harness cannot load)
             :command (append (and (not (eq system-type 'windows-nt)) (list "sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\""))
                              (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                    "--eval" (format "(setq load-prefer-newer %S load-path '%S)" load-prefer-newer load-path)
                                    "-l" drgnx-run-ert--self "-f" "drgnx-run-ert-batch" file))
             :filter (lambda (_ s) (if buffer
                                       (with-current-buffer buffer (goto-char (point-max)) (insert s))
                                     (princ s #'external-debugging-output)))
             :sentinel #'drgnx-run-ert--file-ended)))
    (process-send-eof p)                ; stdin at its end: a stray prompt in a test fails, never waits
    (push p drgnx-run-ert--file-processes)
    p))

(defun drgnx-run-ert--read-summary (json)
  "The summary in the file JSON, or nil (missing or unreadable)."
  (ignore-errors (json-parse-string (with-temp-buffer (insert-file-contents json) (buffer-string)) :object-type 'plist)))

(defun drgnx-run-ert--merge (done timeout)
  "One summary of the ended files DONE (each :file :exit :seconds :timed-out :summary), in the shape of a
one-Emacs run plus :files.  A file whose Emacs timed out (after TIMEOUT s), died or exited non-zero without a
failed test is a failure named after the file."
  (let ((total 0) (passed 0) failures known-red tests files leaks (census nil))
    (dolist (f done)
      (let* ((s (plist-get f :summary)) (exit (plist-get f :exit))
             (why (cond ((plist-get f :timed-out) (format "its Emacs timed out after %d s (DRGNX_TEST_FILE_TIMEOUT)" timeout))
                        ((null s) (format "its Emacs ended (exit %s) without a summary" exit))
                        ((and (not (eql exit 0)) (eql 0 (plist-get s :failed))) (format "its Emacs exited %s" exit)))))
        (when s
          (cl-incf total (plist-get s :total))
          (cl-incf passed (plist-get s :passed))
          (setq failures (append failures (plist-get s :failures) nil)
                known-red (append known-red (plist-get s :known_red) nil)
                tests (append tests (plist-get s :tests) nil))
          (when (plist-member s :leaks)
            (setq census t leaks (append leaks (plist-get s :leaks) nil))))
        (when why
          (cl-incf total)
          (setq failures (append failures (list (list :name (concat "file " (file-name-nondirectory (plist-get f :file)))
                                                      :condition why)))))
        (push (list :file (plist-get f :file) :exit exit :seconds (plist-get f :seconds)) files)))
    (append (list :total total :passed passed :failed (length failures) :failures (vconcat failures)
                  :known_red (vconcat known-red) :tests (vconcat tests) :files (vconcat (nreverse files)))
            (and census (list :leaks (vconcat leaks))))))

(defun drgnx-run-ert--index (file)
  "What the selector prefilter knows of the test FILE: (NAMES . OPEN).  NAMES: the first argument of every top-level
form whose head symbol's name ends in `deftest' (`ert-deftest', a file's own `…--deftest' macro), as strings.  OPEN: t
when such a form's first argument is not a plain symbol (a computed name), or the file does not read: the file may
hold any test."
  (let ((names nil) (open nil) (obarray (obarray-make)))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (when (and (consp form) (symbolp (car form)) (string-suffix-p "deftest" (symbol-name (car form))))
                    (if (and (cdr form) (symbolp (cadr form)))
                        (push (symbol-name (cadr form)) names)
                      (setq open t)))))
            (end-of-file nil)))
      (error (setq open t)))
    (cons (nreverse names) open)))

(defun drgnx-run-ert--file-selected-p (file selector)
  "Whether the test FILE can hold a test SELECTOR picks: with a string selector (a regexp on test names), only a
file that defines such a test (`drgnx-run-ert--index') or may (a computed name); any other selector, every file.  A
narrow run then starts an Emacs only for the files it needs."
  (or (not (stringp selector))
      (let ((index (drgnx-run-ert--index file)))
        (or (cdr index) (cl-some (lambda (n) (string-match-p selector n)) (car index))))))

(defun drgnx-run-ert--unindexed (stats dir)
  "Failures (:name :condition), one for each test of STATS in a test file of DIR that its file's index does not
name: a name selector could not see it.  A file with a computed name (OPEN) is not checked."
  (let ((files (mapcar #'file-truename (drgnx-run-ert--files dir))) (indexes nil) failures)
    (cl-loop
     for test across (ert--stats-tests stats)
     for file = (ignore-errors (ert-test-file-name test))
     for truename = (and file (ignore-errors (file-truename file)))
     for el = (and truename (cl-find-if (lambda (f) (string= (file-name-sans-extension f) (file-name-sans-extension truename))) files))
     when el
     do (let ((index (or (alist-get el indexes nil nil #'equal)
                         (setf (alist-get el indexes nil nil #'equal) (drgnx-run-ert--index el))))
              (name (symbol-name (ert-test-name test))))
          (unless (or (cdr index) (member name (car index)))
            (push (list :name name
                        :condition (format "unindexed test %s in %s: the selector prefilter cannot see it"
                                           name (file-name-nondirectory el)))
                  failures))))
    (nreverse failures)))

(defun drgnx-run-ert--matched-nothing (selector)
  "The failure (:name :condition) of a run whose string SELECTOR matched no test."
  (list :name "selector"
        :condition (format "DRGNX_TEST_SELECTOR %S matched 0 tests (an Emacs regexp: \\| for alternation, not |)" selector)))

(defun drgnx-run-ert-files (files results-file)
  "Run each test file of FILES in an Emacs of its own, as Emacs's own `make check' does: a hook, timer, feature or
variable one file leaves never reaches the next.  Each gets this Emacs's `load-path' and environment (selector,
eln directory, no desktop), a temp directory of its own (its TMPDIR, runtime and state directories: short, so its
sockets fit, see `drgnx-run-ert--short-root') removed when it ends, and writes its own summary; one merged summary
goes to RESULTS-FILE.  The root of those directories goes when the run ends, or is stopped.  DRGNX_TEST_JOBS files
run at once (default 1); one that runs DRGNX_TEST_FILE_TIMEOUT seconds (default 300) is ended.  Return t when every
file passed."
  (let* ((selector (let ((s (getenv "DRGNX_TEST_SELECTOR"))) (and s (not (string-empty-p s)) (car (read-from-string s)))))
         (files (cl-remove-if-not (lambda (f) (drgnx-run-ert--file-selected-p f selector)) files))
         (jobs (drgnx-run-ert--env-number "DRGNX_TEST_JOBS" 1))
         (timeout (drgnx-run-ert--env-number "DRGNX_TEST_FILE_TIMEOUT" 300))
         (out-dir (make-temp-file "drgnx-files" t))
         (queue (cl-loop for file in files for i from 1
                         collect (list :file file :json (expand-file-name (format "%d.json" i) out-dir))))
         (count (length queue)) (running nil) (done nil) (t0 (float-time))
         (seed (drgnx-run-ert--shuffle-seed)))     ; the files' Emacsen inherit it; this one says it once
    (when seed (drgnx-run-ert--say-seed seed))
    (add-hook 'kill-emacs-hook #'drgnx-run-ert--end-files)
    (unwind-protect
        (progn
          (setq drgnx-run-ert--file-root (file-name-as-directory (drgnx-run-ert--short-root)))
          (while (or queue running)
            (while (and queue (< (length running) jobs))
              (let* ((f (pop queue)) (buffer (and (> jobs 1) (generate-new-buffer " *drgnx-test-file*")))
                     ;; named as bin/drgnx names a run's directory, so the file's runner takes it as given
                     (tmp (let ((temporary-file-directory drgnx-run-ert--file-root))
                            (make-temp-file "drgnx-run." t))))
                (unless buffer (message "drgnx: %s (%d/%d)" (plist-get f :file) (- count (length queue)) count))
                (push tmp drgnx-run-ert--file-dirs)
                (push (append f (list :buffer buffer :start (float-time) :tmp tmp
                                      :process (drgnx-run-ert--start-file (plist-get f :file) tmp (plist-get f :json) buffer)))
                      running)))
            (accept-process-output nil 0.05)
            (dolist (f (copy-sequence running))
              (let ((p (plist-get f :process)))
                (when (and (process-live-p p) (> (- (float-time) (plist-get f :start)) timeout))
                  (message "drgnx: %s ran %d s: ending it" (plist-get f :file) timeout)
                  (plist-put f :timed-out t)
                  (drgnx-run-ert--end-process p))
                (when (process-get p :ended)    ; its output is whole (`drgnx-run-ert--file-ended')
                  (setq running (delq f running)
                        drgnx-run-ert--file-processes (delq p drgnx-run-ert--file-processes)
                        drgnx-run-ert--file-dirs (delete (plist-get f :tmp) drgnx-run-ert--file-dirs))
                  (ignore-errors (delete-directory (plist-get f :tmp) t))
                  (when-let* ((buffer (plist-get f :buffer)))
                    (message "drgnx: %s" (plist-get f :file))
                    (princ (with-current-buffer buffer (buffer-string)) #'external-debugging-output)
                    (kill-buffer buffer))
                  (push (append f (list :exit (process-exit-status p) :seconds (- (float-time) (plist-get f :start))
                                        :summary (drgnx-run-ert--read-summary (plist-get f :json))))
                        done))))))
      (drgnx-run-ert--end-files)
      (delete-directory out-dir t))
    (let ((summary (drgnx-run-ert--merge (sort done (lambda (a b) (< (cl-position (plist-get a :file) files :test #'equal)
                                                                     (cl-position (plist-get b :file) files :test #'equal))))
                                         timeout)))
      (when (and (stringp selector) (zerop (plist-get summary :total)))
        (let ((f (drgnx-run-ert--matched-nothing selector)))
          (setq summary (plist-put (plist-put (plist-put (plist-put summary :total 1) :failed 1)
                                              :failures (vector f))
                                   :passed 0))))
      (when seed (setq summary (append summary (list :seed seed))))
      (message "\ndrgnx: %d test files, each in an Emacs of its own: %d tests, %d as expected, %d unexpected (%.0f s)"
               count (plist-get summary :total) (plist-get summary :passed) (plist-get summary :failed) (- (float-time) t0))
      (cl-loop for f across (plist-get summary :failures) do (message "   FAILED  %s" (plist-get f :name)))
      (when (and seed (> (plist-get summary :failed) 0)) (drgnx-run-ert--say-seed seed))
      (when (and (plist-get summary :leaks) (> (length (plist-get summary :leaks)) 0))
        (message "\n%s" (drgnx-run-ert-leaks-report (plist-get summary :leaks))))
      (when results-file
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (decode-coding-string (json-serialize summary) 'utf-8) nil results-file nil 'silent)))
      (zerop (plist-get summary :failed)))))

;;;; Finding the test that breaks another

;; `bin/drgnx test --find-polluter TEST [FILE…]': TEST passes alone but fails after some test before it.  The tests
;; before TEST (in TEST's file, or in FILES, in the order a one-Emacs run gives them) are run in a fresh Emacs with
;; TEST at the end, and the list is halved until one test is left.  Every run is an Emacs of its own with the
;; runner's sandbox, so the bisect itself leaves nothing behind; `drgnx-run-ert--file-root' and the kill hook of the
;; per-file runs clean up when it is interrupted.

(defvar drgnx-run-ert--polluter-runs 0 "The Emacsen with tests that the bisect has run so far.")

(defun drgnx-run-ert--child (files env)
  "Run the test FILES in one fresh batch Emacs (this one's `load-path', one process, no census) with ENV, a list of
\"VAR=VALUE\" strings and bare names to unset, ahead of this Emacs's environment.  Return (:exit N :timed-out BOOL
:output STRING).  One that runs DRGNX_TEST_FILE_TIMEOUT seconds (default 300) is ended."
  (let* ((tmp (let ((temporary-file-directory drgnx-run-ert--file-root)) (make-temp-file "drgnx-run." t)))
         (out (generate-new-buffer " *drgnx-polluter*"))
         (timeout (drgnx-run-ert--env-number "DRGNX_TEST_FILE_TIMEOUT" 300))
         (process-environment (append env (list (concat "DRGNX_RUN_TMP=" tmp) "DRGNX_TEST_ONE_PROCESS=1"
                                                "DRGNX_TEST_LEAKS" "DRGNX_TEST_LEAKS_QUIET")
                                      process-environment))
         (timed-out nil))
    (unwind-protect
        (let* ((p (make-process
                   :name "drgnx-polluter" :noquery t :connection-type 'pipe :coding 'utf-8 :buffer out
                   :command (append (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                          "--eval" (format "(setq load-prefer-newer %S load-path '%S)" load-prefer-newer load-path)
                                          "-l" drgnx-run-ert--self "-f" "drgnx-run-ert-batch")
                                    files)
                   :sentinel #'ignore))
               (deadline (+ (float-time) timeout)))
          (process-send-eof p)
          (push p drgnx-run-ert--file-processes)
          (while (process-live-p p)
            (accept-process-output p 0.05)
            (when (> (float-time) deadline)
              (setq timed-out t)
              (drgnx-run-ert--end-process p)))
          (setq drgnx-run-ert--file-processes (delq p drgnx-run-ert--file-processes))
          (list :exit (process-exit-status p) :timed-out timed-out :output (with-current-buffer out (buffer-string))))
      (kill-buffer out)
      (ignore-errors (delete-directory tmp t)))))

(defun drgnx-run-ert--child-error (what child)
  "Signal a `user-error' that WHAT (a string) failed, with the tail of the output of CHILD (see `drgnx-run-ert--child')."
  (let ((out (string-trim (plist-get child :output))))
    (user-error "%s%s\n%s" what (if (plist-get child :timed-out) " (timed out: DRGNX_TEST_FILE_TIMEOUT)" "")
                (if (> (length out) 1500) (concat "…" (substring out -1500)) out))))

(defun drgnx-run-ert--tests-in-order (files)
  "The names of the tests of FILES in the order a one-Emacs run runs them (shuffled by DRGNX_TEST_SHUFFLE, if set)."
  (let ((list-file (make-temp-file (expand-file-name "order" drgnx-run-ert--file-root))))
    (let ((child (drgnx-run-ert--child files (list (concat "DRGNX_TEST_ORDER_OUT=" list-file)
                                                   "DRGNX_TEST_ORDER_IN" "DRGNX_TEST_SELECTOR" "DRGNX_TEST_RESULTS"))))
      (unless (eql 0 (plist-get child :exit)) (drgnx-run-ert--child-error "listing the tests failed" child))
      (split-string (with-temp-buffer (insert-file-contents list-file) (buffer-string)) "\n" t))))

(defun drgnx-run-ert--fails-after-p (files names test)
  "Whether TEST fails when the tests NAMES (a list of strings) run before it, all in one fresh Emacs that loads FILES."
  (let* ((order (make-temp-file (expand-file-name "run-order" drgnx-run-ert--file-root)))
         (json (make-temp-file (expand-file-name "run-result" drgnx-run-ert--file-root) nil ".json")))
    (with-temp-file order (dolist (n (append names (list test))) (insert n "\n")))
    (cl-incf drgnx-run-ert--polluter-runs)
    (let* ((child (drgnx-run-ert--child files (list (concat "DRGNX_TEST_ORDER_IN=" order) (concat "DRGNX_TEST_RESULTS=" json)
                                                    "DRGNX_TEST_SHUFFLE" "DRGNX_TEST_SELECTOR" "DRGNX_TEST_ORDER_OUT")))
           (summary (drgnx-run-ert--read-summary json))
           (entry (and summary (seq-find (lambda (e) (equal (plist-get e :name) test)) (plist-get summary :tests))))
           (fails (and entry (equal (plist-get entry :result) "failed"))))
      (unless entry (drgnx-run-ert--child-error (format "%s did not run (its Emacs exited %s)" test (plist-get child :exit)) child))
      (message "drgnx: run %d: %d test%s before %s -> %s" drgnx-run-ert--polluter-runs (length names)
               (if (= 1 (length names)) "" "s") test (if fails "it fails" "it passes"))
      fails)))

(defun drgnx-run-ert--defining-file (dir test)
  "The test file under DIR that has `(ert-deftest TEST', or nil."
  (let ((re (concat "(ert-deftest[ \t\n]+" (regexp-quote test) "[ \t\n()]")))
    (seq-find (lambda (f) (with-temp-buffer (insert-file-contents f) (re-search-forward re nil t)))
              (drgnx-run-ert--files dir))))

(defun drgnx-run-ert-find-polluter (dir test files)
  "Find, among the tests that run before the test named TEST (a string), the one after which TEST fails.  FILES (test
files or directories) are loaded; none: the file under DIR that defines TEST.  The tests before TEST are those a
one-Emacs run of FILES runs first (DRGNX_TEST_SHUFFLE shuffles them).  It runs TEST alone, then after all of them,
then halves the list: at most ⌈log2 N⌉+2 runs for N tests before TEST.  It assumes one polluter.
Return (:polluter NAME), (:alone t) when TEST fails alone, or (:clean t) when it passes after all the tests before
it; each with :runs."
  (let* ((_ (dolist (f files) (unless (file-exists-p f) (user-error "no such test file or directory: %s" f))))
         (files (or (mapcan #'drgnx-run-ert--files files)
                    (list (or (drgnx-run-ert--defining-file dir test)
                              (user-error "no test named %s under %s (name the FILE that defines it)" test dir)))))
         (drgnx-run-ert--file-root (file-name-as-directory (drgnx-run-ert--short-root)))
         (drgnx-run-ert--polluter-runs 0)
         (seed (drgnx-run-ert--shuffle-seed)))
    (add-hook 'kill-emacs-hook #'drgnx-run-ert--end-files)
    (when seed (drgnx-run-ert--say-seed seed))
    (unwind-protect
        (let* ((order (drgnx-run-ert--tests-in-order files))
               (before (progn (unless (member test order) (user-error "%s is not among the tests of %s" test (mapconcat #'file-name-nondirectory files ", ")))
                              (seq-take-while (lambda (n) (not (equal n test))) order)))
               (result
                (cond
                 ((drgnx-run-ert--fails-after-p files nil test) (list :alone t))
                 ((null before) (list :clean t))
                 ((not (drgnx-run-ert--fails-after-p files before test)) (list :clean t))
                 (t (let ((candidates before))
                      (while (cdr candidates)
                        (let ((first (seq-take candidates (/ (length candidates) 2))))
                          (setq candidates (if (drgnx-run-ert--fails-after-p files first test)
                                               first
                                             (seq-drop candidates (length first))))))
                      (list :polluter (car candidates)))))))
          (append result (list :runs drgnx-run-ert--polluter-runs :before (length before) :files files)))
      (drgnx-run-ert--end-files)
      (remove-hook 'kill-emacs-hook #'drgnx-run-ert--end-files))))

(defun drgnx-run-ert-find-polluter-batch ()
  "Batch entry point of `bin/drgnx test --find-polluter': the remaining arguments are the directory of the suite, the
test's name and the files (maybe none).  Exit 0 when it names the polluter or the test fails alone, 1 when the test
passes after all the tests before it, 2 when it cannot run."
  (setq default-directory (expand-file-name default-directory)
        load-path (mapcar (lambda (d) (if (stringp d) (expand-file-name d) d)) load-path))
  (let* ((dir (expand-file-name (pop command-line-args-left)))
         (test (pop command-line-args-left))
         (files (prog1 (mapcar #'expand-file-name command-line-args-left) (setq command-line-args-left nil)))
         (code (condition-case err
                   (let* ((r (drgnx-run-ert-find-polluter dir test files))
                          (runs (plist-get r :runs))
                          (n (format "(%d run%s)" runs (if (= runs 1) "" "s"))))
                     (cond
                      ((plist-get r :alone)
                       (message "\n%s fails alone %s: it does not depend on any test before it" test n) 0)
                      ((plist-get r :clean)
                       (message "\n%s passes %s %s: no pollution in this order (try --shuffle, or name more FILES)"
                                test (if (zerop (plist-get r :before)) "alone, and no test runs before it"
                                       (format "after all %d test%s before it" (plist-get r :before)
                                               (if (= 1 (plist-get r :before)) "" "s")))
                                n)
                       1)
                      (t (message "\nlikely polluter (unconfirmed): %s\n  bisected from the tests before %s %s, assuming one polluter; the pair was not re-run\n  check the pair, with %s loaded: %s"
                                  (plist-get r :polluter) test n
                                  (mapconcat #'identity (plist-get r :files) " ")
                                  (format "DRGNX_TEST_SELECTOR='(member %s %s)' bin/drgnx test --one-process" (plist-get r :polluter) test))
                         0)))
                 (error (message "drgnx: %s\nusage: drgnx test [--shuffle=SEED] --find-polluter TEST [FILE…]" (error-message-string err)) 2))))
    (kill-emacs code)))

(defvar project-list-file)

(defun drgnx-run-ert--given-tmp ()
  "The directory bin/drgnx made for this run (DRGNX_RUN_TMP), or nil: it must be absolute, named
drgnx-run.XXXXXX, a real directory (no symlink) of the user's."
  (let ((given (getenv "DRGNX_RUN_TMP")))
    (and given (string-prefix-p "/" given)
         (string-match-p "/drgnx-run\\.[A-Za-z0-9]\\{6\\}/?\\'" given)
         (not (file-symlink-p (directory-file-name given)))
         (file-directory-p given)
         (eql (file-attribute-user-id (file-attributes given 'integer)) (user-uid))
         (expand-file-name given))))

(defun drgnx-run-ert--eln-dir ()
  "Where this run's native trampolines go: DRGNX_TEST_ELN_DIR when the run that started this one gave it (so every
Emacs of a run shares one), else drgnx's own cache for this Emacs version under the user's XDG cache — kept between
runs, because a unit run `cl-letf's ~60 primitives at ~0.2 s of compiling each.  Read before HOME is swapped."
  (let ((given (getenv "DRGNX_TEST_ELN_DIR")) (cache (getenv "XDG_CACHE_HOME")))
    (file-name-as-directory
     (if (and given (file-name-absolute-p given))
         (expand-file-name given)
       (expand-file-name (format "drgnx/test-eln/%s/" emacs-version)
                         (if (and cache (file-name-absolute-p cache)) cache "~/.cache"))))))

(defvar native-comp-eln-load-path)

(defun drgnx-run-ert--use-eln-dir (dir fallback user-cache)
  "Compile native trampolines into DIR (FALLBACK when DIR cannot be made or written): first in
`native-comp-eln-load-path', which loses USER-CACHE, the user's own eln-cache, so a test neither writes nor reads
there.  Emacs writes a trampoline (a `cl-letf' of a primitive) to the first writable directory of that list, and
looks for one only along it (`native-comp-enable-subr-trampolines' set to a directory would not be searched).
Return the directory, or nil without native compilation."
  (when (and (fboundp 'native-comp-available-p) (native-comp-available-p))
    (let ((dir (if (ignore-errors (make-directory dir t) (file-writable-p dir))
                   dir
                 (make-directory fallback t)
                 fallback)))
      (setq native-comp-eln-load-path
            (cons dir (cl-remove-if (lambda (d) (equal (file-name-as-directory (expand-file-name d invocation-directory))
                                                       user-cache))
                                    native-comp-eln-load-path)))
      dir)))

(defun drgnx-run-ert-batch ()
  "Batch entry point: run the suite in the remaining arguments — a directory, or test files (a shard) —
exit 0 or 1."
  ;; Absolute paths before HOME changes: "~/…" would then mean the temp home.
  (setq default-directory (expand-file-name default-directory)
        load-path (mapcar (lambda (d) (if (stringp d) (expand-file-name d) d)) load-path))
  (let* ((args (prog1 (mapcar #'expand-file-name command-line-args-left) (setq command-line-args-left nil)))
         (dir (if (and (= (length args) 1) (file-directory-p (car args))) (car args) args))
         ;; each test file in an Emacs of its own, unless DRGNX_TEST_ONE_PROCESS=1 (`bin/drgnx test --one-process')
         (one-process (equal (getenv "DRGNX_TEST_ONE_PROCESS") "1"))
         (drgnx-run-ert--leaks-quiet (equal (getenv "DRGNX_TEST_LEAKS_QUIET") "1"))
         (drgnx-run-ert--file-child (equal (getenv "DRGNX_TEST_FILE_CHILD") "1"))
         ;; …the bisect's variables are the runner's alone, like the one above: no test (or runner it starts) sees them
         (drgnx-run-ert--order-in (drgnx-run-ert--env "DRGNX_TEST_ORDER_IN"))
         (drgnx-run-ert--order-out (drgnx-run-ert--env "DRGNX_TEST_ORDER_OUT"))
         ;; native trampolines: drgnx's directory, never the user's ~/.config/emacs/eln-cache (both before HOME changes)
         (eln (drgnx-run-ert--eln-dir))
         (user-eln (file-name-as-directory (expand-file-name "eln-cache/" user-emacs-directory)))
         ;; The suite never sees the user's drgnx config, packages, state or cache.
         ;; `bin/drgnx test' makes a directory of its own, DRGNX_RUN_TMP, and removes it: used as it is (so
         ;; paths stay short), never deleted here.  Anything else the variable holds — empty (the current
         ;; directory), a symlink, a directory of another name or owner — is ignored.  A user-owned one of the right
         ;; name is used but, like the given one, never deleted.  Else the runner makes a directory and
         ;; deletes exactly that one.
         (given (drgnx-run-ert--given-tmp))
         (own (unless given (make-temp-file "drgnx-unit" t)))
         (tmp (or given own))
         ;; Everything a test makes with `make-temp-file' (and every child process) lands in TMP too, so
         ;; removing OWN below, or from `kill-emacs-hook' when the run dies, leaves nothing in /tmp.
         (temporary-file-directory (file-name-as-directory tmp))
         (_ (when own (add-hook 'kill-emacs-hook (lambda () (ignore-errors (delete-directory own t))))))
         (eln (drgnx-run-ert--use-eln-dir eln (expand-file-name "eln/" tmp) user-eln))
         ;; …nor anything else under ~ (HOME is a temp dir; the user's ELPA stays readable for the
         ;; tests that load packages from it, read-only, through DRGNX_USER_ELPA)
         (elpa (expand-file-name "~/.config/emacs/elpa"))
         (process-environment
          (append (drgnx-test-env 'unit tmp)      ; HOME, XDG, the hub, provider keys, bus, desktop: one list for every tier
                  ;; …every Emacs this run starts compiles its trampolines into the same directory, once
                  (and eln (list (concat "DRGNX_TEST_ELN_DIR=" eln)))
                  ;; …a test that runs the runner gets one Emacs per file unless it says otherwise
                  (list "DRGNX_TEST_ONE_PROCESS" "DRGNX_TEST_FILE_CHILD" "DRGNX_TEST_LEAKS_QUIET" "DRGNX_TEST_ORDER_IN" "DRGNX_TEST_ORDER_OUT")
                  ;; …a test that runs the runner or bin/drgnx again must not reuse (and delete) this directory
                  (list "DRGNX_RUN_TMP")
                  (and (getenv "DRGNX_USER_ELPA") (list (concat "DRGNX_USER_ELPA=" (getenv "DRGNX_USER_ELPA"))))
                  (and (not (getenv "DRGNX_USER_ELPA")) (file-directory-p elpa) (list (concat "DRGNX_USER_ELPA=" elpa)))
                  process-environment))
         (_ (make-directory (expand-file-name "home" tmp) t))
         (abbreviated-home-dir nil)                     ; recomputed for the temp home
         ;; Emacs computed this at startup from the real HOME (~/.emacs.d or ~/.config/emacs): a test that writes under it
         ;; (the custom file, eln-cache, auto-save lists …) lands in the run
         (user-emacs-directory (file-name-as-directory (expand-file-name "emacs" tmp)))
         ;; project.el remembers projects it sees: never in the user's own Emacs's list
         (project-list-file (expand-file-name "projects" tmp))
         (ok (if one-process
                 (drgnx-run-ert dir (getenv "DRGNX_TEST_RESULTS"))
               ;; each file's directory in a short root of its own (a socket path has at most 103 bytes on macOS)
               (drgnx-run-ert-files (drgnx-run-ert--files dir) (getenv "DRGNX_TEST_RESULTS")))))
    (when own (delete-directory own t))
    (kill-emacs (if ok 0 1))))

(provide 'drgnx-run-ert)
;;; run-ert.el ends here
