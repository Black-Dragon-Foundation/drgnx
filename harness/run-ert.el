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
  (let* ((load-failures
          (cl-loop for file in (drgnx-run-ert--files dir)
                   ;; a file that does not read or load costs its tests: the run fails and says which file
                   for err = (condition-case err (progn (load file nil t) nil) (error err) (quit err))
                   when err collect (progn (message "drgnx: test file %s did not load: %S" file err)
                                           (list :name (concat "load " (file-name-nondirectory file))
                                                 :condition (format "%S" err)))))
         ;; which tests: all, or DRGNX_TEST_SELECTOR (an ERT selector; bin/drgnx check runs :timing ones alone)
         (stats (ert-run-tests-batch (let ((s (getenv "DRGNX_TEST_SELECTOR")))
                                       (if (and s (not (string-empty-p s))) (car (read-from-string s)) t))))
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
                  ;; …a test that runs the runner or bin/drgnx again must not reuse (and delete) this directory
                  (list "DRGNX_RUN_TMP")
                  ;; …nor start a durable hub that would outlive it (the hub's own tests unset this)
                  (list "DRGNX_NO_HUB_START=1")
                  ;; …and a hub one starts anyway ends with this Emacs (an interrupted run leaves none)
                  (list (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
                  ;; …nor the user's provider keys: no test may reach a paid model (bare names unset them)
                  (list "OPENROUTER_API_KEY" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "OPENAI_API_KEY")
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
         (ok (drgnx-run-ert dir (getenv "DRGNX_TEST_RESULTS"))))
    (when own (delete-directory own t))
    (kill-emacs (if ok 0 1))))

(provide 'drgnx-run-ert)
;;; run-ert.el ends here
