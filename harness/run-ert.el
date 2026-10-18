;;; run-ert.el --- Run drgnx ERT suites and write a JSON summary -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Used by `drgnx test' (batch) and by harness sessions in test mode (GUI).  The JSON
;; summary carries the details, because a GUI session's exit status is only pass/fail.

;;; Code:
(require 'cl-lib)
(require 'ert)

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

(defun drgnx-run-ert (dir &optional results-file)
  "Load every *-test.el under DIR (or the files of the list DIR: a shard), run all tests, write a JSON
summary to RESULTS-FILE.  Return t if every test passed."
  (advice-add 'ert-run-test :after (lambda (&rest _) (drgnx-run-ert-drain-events)) '((name . drgnx-run-ert-drain)))
  (let* ((selector (let ((s (getenv "DRGNX_TEST_SELECTOR"))) (and s (not (string-empty-p s)) (car (read-from-string s)))))
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
         ;; which tests: all, or DRGNX_TEST_SELECTOR (an ERT selector; bin/drgnx check runs :timing ones alone)
         (stats (ert-run-tests-batch (if selector selector t)))
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
    (when results-file
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region
         (decode-coding-string
          (json-serialize
           (list :total (+ (ert-stats-total stats) (length load-failures))
                 :passed (ert-stats-completed-expected stats)
                 :failed (length failures)
                 :failures (vconcat failures)
                 :known_red (vconcat (nreverse known-red))
                 :tests (vconcat (nreverse tests))))
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

(defun drgnx-run-ert--start-file (file tmp json buffer)
  "Start an Emacs that runs the test FILE alone (`drgnx-run-ert-batch', this Emacs's `load-path' and environment),
in the temp directory TMP (its DRGNX_RUN_TMP: used, never deleted, by it), its summary to JSON.  Its output goes
to BUFFER, or to this Emacs's standard error when BUFFER is nil."
  (let* ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" json) "DRGNX_TEST_ONE_PROCESS=1"
                                            (concat "DRGNX_RUN_TMP=" tmp))
                                      process-environment))
         (p (make-process
             :name (concat "drgnx-test-file " (file-name-nondirectory file)) :noquery t :connection-type 'pipe
             :coding 'utf-8
             :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                            "--eval" (format "(setq load-prefer-newer %S load-path '%S)" load-prefer-newer load-path)
                            "-l" drgnx-run-ert--self "-f" "drgnx-run-ert-batch" file)
             :filter (lambda (_ s) (if buffer
                                       (with-current-buffer buffer (goto-char (point-max)) (insert s))
                                     (princ s #'external-debugging-output)))
             :sentinel #'ignore)))
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
  (let ((total 0) (passed 0) failures known-red tests files)
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
                tests (append tests (plist-get s :tests) nil)))
        (when why
          (cl-incf total)
          (setq failures (append failures (list (list :name (concat "file " (file-name-nondirectory (plist-get f :file)))
                                                      :condition why)))))
        (push (list :file (plist-get f :file) :exit exit :seconds (plist-get f :seconds)) files)))
    (list :total total :passed passed :failed (length failures) :failures (vconcat failures)
          :known_red (vconcat known-red) :tests (vconcat tests) :files (vconcat (nreverse files)))))

(defun drgnx-run-ert--file-selected-p (file selector)
  "Whether the test FILE can hold a test SELECTOR picks: with a string selector (a regexp on test names), only a
file that defines such a test by name; any other selector, every file.  A narrow run then starts an Emacs only for
the files it needs."
  (or (not (stringp selector))
      (with-temp-buffer
        (insert-file-contents file)
        (let ((found nil))
          (while (and (not found) (re-search-forward "(ert-deftest[ \t\n]+\\([^][ \t\n()\"';]+\\)" nil t))
            (setq found (string-match-p selector (match-string 1))))
          found))))

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
         (count (length queue)) (running nil) (done nil) (t0 (float-time)))
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
                (unless (process-live-p p)
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
      (message "\ndrgnx: %d test files, each in an Emacs of its own: %d tests, %d as expected, %d unexpected (%.0f s)"
               count (plist-get summary :total) (plist-get summary :passed) (plist-get summary :failed) (- (float-time) t0))
      (cl-loop for f across (plist-get summary :failures) do (message "   FAILED  %s" (plist-get f :name)))
      (when results-file
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (decode-coding-string (json-serialize summary) 'utf-8) nil results-file nil 'silent)))
      (zerop (plist-get summary :failed)))))

(defvar project-list-file)

(defconst drgnx-run-ert--dead-bus "unix:path=/nonexistent/drgnx-unit-test"
  "The session bus address a unit test sees: no listener, so nothing reaches the user's desktop.")

(defconst drgnx-run-ert--desktop-variables
  '("DISPLAY" "WAYLAND_DISPLAY" "SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET")
  "Variables that point a program at the user's display or compositor; unset for the unit tier.")

(defun drgnx-run-ert--private-dir (dir)
  "Make DIR (mode 700) and return it."
  (make-directory dir t)
  (set-file-modes dir #o700)
  dir)

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
          (append (mapcar (lambda (v) (format "%s=%s" (car v) (expand-file-name (cdr v) tmp)))
                          '(("DRGNX_CONFIG_DIR" . "config") ("DRGNX_DATA_DIR" . "data")
                            ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache") ("HOME" . "home")
                            ("TMPDIR" . ".")))
                  (list "DRGNX_TEST_ISOLATED=1")
                  ;; …every Emacs this run starts compiles its trampolines into the same directory, once
                  (and eln (list (concat "DRGNX_TEST_ELN_DIR=" eln)))
                  ;; …a test that runs the runner gets one Emacs per file unless it says otherwise
                  (list "DRGNX_TEST_ONE_PROCESS")
                  ;; …a test that runs the runner or bin/drgnx again must not reuse (and delete) this directory
                  (list "DRGNX_RUN_TMP")
                  ;; …nor start a durable hub that would outlive it (the hub's own tests unset this)
                  (list "DRGNX_NO_HUB_START=1")
                  ;; …and a hub one starts anyway ends with this Emacs (an interrupted run leaves none)
                  (list (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
                  ;; …nor the user's provider keys: no test may reach a paid model (bare names unset them) — and
                  ;; not the agents' home directories, which would point a test at the user's real settings
                  (list "OPENROUTER_API_KEY" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "OPENAI_API_KEY"
                        "MOONSHOT_API_KEY" "DEEPSEEK_API_KEY" "GEMINI_API_KEY" "GOOGLE_API_KEY" "OPENAI_BASE_URL"
                        "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL" "ANTHROPIC_SMALL_FAST_MODEL"
                        "ANTHROPIC_DEFAULT_HAIKU_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL"
                        "ANTHROPIC_DEFAULT_FABLE_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL" "CLAUDE_CODE_OAUTH_TOKEN"
                        "CLAUDE_CODE_USE_BEDROCK" "CLAUDE_CODE_USE_VERTEX"
                        "CLAUDE_CONFIG_DIR" "CODEX_HOME" "KIMI_CODE_HOME")
                  ;; …nor the user's desktop: no display, no compositor socket, no session bus, a private
                  ;; runtime directory (bin/drgnx and `drgnx check' do the same for the process itself: dbus.el
                  ;; connects with the C environment, which this binding does not reach)
                  (list (concat "DBUS_SESSION_BUS_ADDRESS=" drgnx-run-ert--dead-bus)
                        (concat "XDG_RUNTIME_DIR=" (drgnx-run-ert--private-dir (expand-file-name "run" tmp))))
                  drgnx-run-ert--desktop-variables
                  (and (getenv "DRGNX_USER_ELPA") (list (concat "DRGNX_USER_ELPA=" (getenv "DRGNX_USER_ELPA"))))
                  (and (not (getenv "DRGNX_USER_ELPA")) (file-directory-p elpa) (list (concat "DRGNX_USER_ELPA=" elpa)))
                  process-environment))
         (_ (make-directory (expand-file-name "home" tmp) t))
         (abbreviated-home-dir nil)                     ; recomputed for the temp home
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
