;;; run-ert-test.el --- batch tier sanity -*- lexical-binding: t -*-
(require 'ert)
(ert-deftest drgnx-run-ert/loaded ()
  (should (fboundp 'drgnx-run-ert)))

(defconst drgnx-run-ert-test--fixtures
  (expand-file-name "../fixtures/" (file-name-directory (or load-file-name buffer-file-name))))

(defconst drgnx-run-ert-test--file-dir-re "/drgnx-t-[A-Za-z0-9]\\{6\\}/drgnx-run\\.[A-Za-z0-9]\\{6\\}/\\'"
  "A file's temp dir in the runner's short root (`drgnx-run-ert--short-root': in /tmp, else in TMPDIR).")

(defun drgnx-run-ert-test--batch (dir results &rest env)
  "Run the suite in DIR in a fresh batch Emacs (harness on the load path); return its exit code."
  (let ((process-environment (append (cons (concat "DRGNX_TEST_RESULTS=" results) env)
                                     (list "DRGNX_TEST_SELECTOR" "DRGNX_TEST_LEAKS" "DRGNX_TEST_LEAKS_ALLOWED" "DRGNX_TEST_SHUFFLE") ; not this run's selector, census or order
                                     process-environment))
        ;; never a buffer's deleted directory, which call-process refuses
        (default-directory (if (file-directory-p default-directory) default-directory temporary-file-directory)))
    (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                  "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                  "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" dir)))

(defun drgnx-run-ert-test--json (file)
  (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string)) :object-type 'plist))

(ert-deftest drgnx-run-ert/mixed-suite-writes-results-and-fails ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (fixture (expand-file-name "ert-mixed" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (progn
          (should (= (drgnx-run-ert-test--batch fixture results) 1))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (equal (list (plist-get r :total) (plist-get r :passed) (plist-get r :failed)) '(2 1 1)))
            (should (equal (plist-get (aref (plist-get r :failures) 0) :name) "drgnx-fixture/fails"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/suite-that-fails-to-load-is-a-failure ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp)))
    (unwind-protect
        (progn
          (write-region "(error \"boom\")\n" nil (expand-file-name "broken-test.el" tmp))
          (should (= (drgnx-run-ert-test--batch tmp results) 1))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (= (plist-get r :failed) 1))
            (should (string-prefix-p "load " (plist-get (aref (plist-get r :failures) 0) :name)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-test-file-that-does-not-read-fails-the-run-and-is-named ()
  ;; An unbalanced paren makes a whole file unreadable: its tests would be missing from the count and the run
  ;; could look green.  The run fails and prints the file and the error.
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp)))
    (unwind-protect
        (progn
          (write-region "(require 'ert)\n(ert-deftest bad/unbalanced () (should t)\n" nil (expand-file-name "unbalanced-test.el" tmp) nil 'silent)
          (write-region "(require 'ert)\n(ert-deftest fine/ok () (should t))\n" nil (expand-file-name "fine-test.el" tmp) nil 'silent)
          (let* ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_SELECTOR") process-environment))
                 (code nil)
                 (out (with-temp-buffer
                        (setq code (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                                                 "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                                 "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" tmp))
                        (buffer-string))))
            (should (= code 1))
            (should (string-match-p "unbalanced-test\\.el" out))                  ; the file is named …
            (should (string-match-p "end-of-file\\|Premature\\|EOF" out))          ; … with the error
            (should (= (plist-get (drgnx-run-ert-test--json results) :failed) 1))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/relative-suite-dir ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (default-directory drgnx-run-ert-test--fixtures))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--batch "ert-mixed" results)
          (should (= (plist-get (drgnx-run-ert-test--json results) :total) 2)))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/known-red-assertion-is-expected-with-its-trace ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (dir (expand-file-name "scenario-ok" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (progn
          (should (= (drgnx-run-ert-test--batch dir results "DRGNX_SCENARIO_CONFIG=minimal"
                                                (concat "DRGNX_UI_TEST=" dir))
                     0))
          (let* ((r (drgnx-run-ert-test--json results))
                 (red (aref (plist-get r :known_red) 0)))
            (should (= (plist-get r :failed) 0))
            (should (equal (plist-get red :name) "drgnx-fixture/known-red-assertion"))
            (should (equal (plist-get red :summary) "the Explorer snapped back"))
            (should (equal (aref (plist-get red :trace) 0) "+196 ms  timer:follow  w3 point 17 → 36"))
            (should (= (length (plist-get r :tests)) 2))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/known-red-error-is-unexpected ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (dir (expand-file-name "scenario-error" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (progn
          (should (= (drgnx-run-ert-test--batch dir results "DRGNX_SCENARIO_CONFIG=minimal"
                                                (concat "DRGNX_UI_TEST=" dir))
                     1))
          (should (= (plist-get (drgnx-run-ert-test--json results) :failed) 1)))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/known-red-needs-a-scenario-check ()
  (let* ((tmp (make-temp-file "drgnx-ert" t)) (results (expand-file-name "results.json" tmp))
         (dir (expand-file-name "scenario-bare" drgnx-run-ert-test--fixtures)))
    (unwind-protect
        (should (= (drgnx-run-ert-test--batch dir results "DRGNX_SCENARIO_CONFIG=minimal"
                                              (concat "DRGNX_UI_TEST=" dir))
                   1))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/unit-tests-never-see-the-users-drgnx-dirs ()
  ;; M5 review I9: the batch runner gives the whole suite temp config, data, state and cache dirs.
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (dolist (v '("DRGNX_CONFIG_DIR" "DRGNX_DATA_DIR" "XDG_STATE_HOME" "XDG_CACHE_HOME" "HOME"))
    (should (string-prefix-p (file-truename temporary-file-directory) (file-truename (getenv v)))))
  (should (string-prefix-p (file-truename temporary-file-directory) (file-truename project-list-file))))

(ert-deftest drgnx-run-ert/no-test-sees-the-users-xdg-dirs ()
  ;; XDG_CONFIG_HOME and XDG_DATA_HOME count for drgnx's config and data dirs: a test that unsets DRGNX_CONFIG_DIR or
  ;; DRGNX_DATA_DIR must still land under the run, never in the user's ~/.config or ~/.local/share.
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (dolist (v '("XDG_CONFIG_HOME" "XDG_DATA_HOME"))
    (should (getenv v))
    (should (string-prefix-p (file-truename temporary-file-directory) (file-truename (getenv v))))))

(ert-deftest drgnx-run-ert/unit-tests-never-see-the-users-desktop ()
  ;; A test that loads dbus.el, opens a frame or talks to a compositor must not reach the user's session.
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (dolist (v '("DISPLAY" "WAYLAND_DISPLAY" "SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET"))
    (should-not (getenv v)))
  (should (equal (getenv "DBUS_SESSION_BUS_ADDRESS") "unix:path=/nonexistent/drgnx-unit-test"))
  (let ((run (getenv "XDG_RUNTIME_DIR")))
    (should (string-prefix-p (file-truename temporary-file-directory) (file-truename run)))
    (should (= #o700 (file-modes run)))))

(ert-deftest drgnx-run-ert/a-file-watch-event-does-not-stop-later-sentinels ()
  ;; Batch Emacs has no command loop: a file-notify event waits in the input queue for ever, and while input
  ;; waits Emacs runs no process sentinel (timers still run).  The runner drains the queue after each test.
  (require 'filenotify)
  (let* ((dir (make-temp-file "drgnx-watch" t))
         (default-directory (file-name-as-directory dir))   ; the process below needs an existing directory
         (w (file-notify-add-watch dir '(change) #'ignore)))
    (unwind-protect
        (progn
          (write-region "x" nil (expand-file-name "a" dir) nil 'silent)
          (accept-process-output nil 0.3)                                     ; the event arrives
          (drgnx-run-ert-drain-events)
          (let* ((got nil) (p (make-process :name "after-watch" :command '("true") :sentinel (lambda (&rest _) (setq got t))))
                 (deadline (+ (float-time) 3)))
            (while (and (not got) (< (float-time) deadline)) (accept-process-output nil 0.05))
            (should got)
            (ignore p)))
      (file-notify-rm-watch w)
      (drgnx-run-ert-drain-events)
      (delete-directory dir t))))

(ert-deftest drgnx-run-ert/a-shard-runs-only-its-files-and-results-say-file-and-time ()
  ;; bin/drgnx check runs the unit suite in shards: the runner takes files as well as a directory
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-shard" t))) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (with-temp-file (concat tmp "one-test.el") (insert "(require 'ert)\n(ert-deftest shard-one () (should t))\n"))
          (with-temp-file (concat tmp "two-test.el") (insert "(require 'ert)\n(ert-deftest shard-two () (should t))\n"))
          (should (eql 0 (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_SELECTOR")
                                                            process-environment))
                               (default-directory tmp))
                           (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                         "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                         "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch"
                                         (concat tmp "one-test.el")))))
          (let ((tests (plist-get (drgnx-run-ert-test--json results) :tests)))
            (should (equal (mapcar (lambda (te) (plist-get te :name)) tests) '("shard-one")))
            (should (equal (file-name-nondirectory (plist-get (aref tests 0) :file)) "one-test.el"))
            (should (numberp (plist-get (aref tests 0) :seconds)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-selector-picks-the-tests-a-run-takes ()
  ;; bin/drgnx check runs the :timing tests alone, after the parallel phase: DRGNX_TEST_SELECTOR
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-sel" t))) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (with-temp-file (concat tmp "sel-test.el")
            (insert "(require 'ert)\n(ert-deftest sel-fast () :tags '(:timing) (should t))\n(ert-deftest sel-plain () (should t))\n"))
          (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_SELECTOR=(tag :timing)")
                                             process-environment))
                (default-directory tmp))
            (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                          "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                          "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" (concat tmp "sel-test.el")))
          (should (equal (mapcar (lambda (te) (plist-get te :name)) (plist-get (drgnx-run-ert-test--json results) :tests))
                         '("sel-fast"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/unit-tests-never-see-the-users-provider-keys ()
  ;; a test that runs the onboarding's AI step (a live test call) must never reach a paid provider
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (dolist (v '("OPENROUTER_API_KEY" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "OPENAI_API_KEY"))
    (should-not (getenv v))))

(ert-deftest drgnx-run-ert/unit-tests-start-no-hub-unless-they-say-so ()
  ;; an agent on an :ai profile in any test would start a durable hub that outlives the suite
  (skip-unless (getenv "DRGNX_TEST_ISOLATED"))
  (should (equal (getenv "DRGNX_NO_HUB_START") "1"))
  ;; …and a hub one starts anyway ends with the run (an interrupted run leaves none)
  (should (equal (getenv "DRGNX_HUB_PARENT_PID") (number-to-string (emacs-pid)))))

(ert-deftest drgnx-run-ert/a-run-that-dies-leaves-no-temp-dir-and-tests-write-below-the-run-dir ()
  ;; TMP-1: a test's temp files land in the run's own dir; when the run ends through `kill-emacs' (a test
  ;; that quits, a signal handled as quit) the dir is gone from the parent TMPDIR as well.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-die" t)))
         (parent (expand-file-name "parent" tmp)) (suite (expand-file-name "suite" tmp))
         (probe (expand-file-name "probe" tmp)))
    (unwind-protect
        (progn
          (make-directory parent) (make-directory suite)
          (with-temp-file (expand-file-name "die-test.el" suite)
            (insert (format "(require 'ert)\n(ert-deftest die-quits ()\n  (make-temp-file \"leaked\" t)\n  (write-region temporary-file-directory nil %S)\n  (kill-emacs 3))\n" probe)))
          ;; one Emacs: the runner itself dies; per file: the file's Emacs dies, the run goes on and fails
          (pcase-dolist (`(,mode . ,exit) '(("DRGNX_TEST_ONE_PROCESS=1" . 3) ("DRGNX_TEST_ONE_PROCESS" . 1)))
            (let ((process-environment (append (list (concat "TMPDIR=" parent) "DRGNX_TEST_SELECTOR" "DRGNX_TEST_RESULTS" mode)
                                               process-environment)))
              (should (eql exit (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                              "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                              "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" suite))))
            (let ((seen (with-temp-buffer (insert-file-contents probe) (buffer-string))))
              (if (equal mode "DRGNX_TEST_ONE_PROCESS=1")
                  (should (string-prefix-p (file-name-as-directory parent) seen))
                ;; per file: in the runner's short root (…/a-files-temp-dir-is-short-whatever-the-tmpdir), gone with the run as well
                (should (string-match-p drgnx-run-ert-test--file-dir-re seen))
                (should-not (file-exists-p (file-name-directory (directory-file-name seen))))))
            (should-not (directory-files parent nil directory-files-no-dot-files-regexp))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-given-run-dir-is-never-deleted-and-a-wrong-one-is-ignored ()
  ;; TMP-1 review C1: DRGNX_RUN_TMP names the dir bin/drgnx made (and removes).  The runner only uses a real
  ;; directory of that name; empty (= the current directory), someone's directory and a symlink are ignored
  ;; and survive; none is ever deleted by the runner.  Everything happens below a fresh temp parent.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-given" t)))
         (parent (expand-file-name "parent" tmp)) (suite (expand-file-name "suite" tmp))
         (victim (file-name-as-directory (expand-file-name "victim" tmp)))
         (link (expand-file-name "drgnx-run.abcdef" parent))
         (real (expand-file-name "drgnx-run.ghijkl" parent))
         (runner (lambda (given cwd)
                   (let ((process-environment (append (list (concat "TMPDIR=" parent) (concat "DRGNX_RUN_TMP=" given)
                                                            "DRGNX_TEST_SELECTOR" "DRGNX_TEST_RESULTS")
                                                      process-environment))
                         (default-directory cwd))
                     (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                   "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                   "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" suite)))))
    (unwind-protect
        (progn
          (make-directory parent) (make-directory suite) (make-directory victim)
          (write-region "keep" nil (concat victim "file") nil 'silent)
          (with-temp-file (expand-file-name "ok-test.el" suite) (insert "(require 'ert)\n(ert-deftest given-ok () (should t))\n"))
          (make-symbolic-link (directory-file-name victim) link)
          (make-directory real)
          ;; set but empty, with the victim as the current directory
          (should (eql 0 (funcall runner "" victim)))
          (should (file-exists-p (concat victim "file")))
          ;; someone's existing directory
          (should (eql 0 (funcall runner (directory-file-name victim) tmp)))
          (should (file-exists-p (concat victim "file")))
          ;; a symlink, even with the right name
          (should (eql 0 (funcall runner link tmp)))
          (should (file-exists-p (concat victim "file")))
          (should-not (directory-files victim nil "\\`[^f.]"))      ; nothing was put in it either
          ;; a real one of the right name: used, kept for bin/drgnx to remove
          (should (eql 0 (funcall runner real tmp)))
          (should (file-directory-p real))
          (should (file-directory-p (expand-file-name "home" real)))
          ;; the runner's own dirs (the three ignored cases) are gone
          (should-not (seq-remove (lambda (f) (member f '("drgnx-run.abcdef" "drgnx-run.ghijkl")))
                                  (directory-files parent nil directory-files-no-dot-files-regexp))))
      (delete-directory tmp t))))

(defun drgnx-run-ert-test--eln-probe (suite probe)
  "Write into SUITE a test file that `cl-letf's `buffer-list' (a native trampoline) and writes to PROBE what the
runner gave it: DRGNX_TEST_ELN_DIR and the first effective directory of `native-comp-eln-load-path'."
  (with-temp-file (expand-file-name "eln-test.el" suite)
    (insert (format "(require 'ert)\n(require 'cl-lib)\n(ert-deftest eln-probe ()\n  (cl-letf (((symbol-function 'buffer-list) (lambda (&rest _) nil))) (buffer-list))\n  (with-temp-file %S (prin1 (list (getenv \"DRGNX_TEST_ELN_DIR\") (car native-comp-eln-load-path)) (current-buffer))))\n"
                    probe))))

(defun drgnx-run-ert-test--run-suite (suite &rest env)
  "Run SUITE with the batch runner in a fresh Emacs with ENV; return its exit code."
  (let ((process-environment (append env (list "DRGNX_TEST_SELECTOR" "DRGNX_TEST_RESULTS" "DRGNX_TEST_LEAKS" "DRGNX_TEST_LEAKS_ALLOWED" "DRGNX_TEST_SHUFFLE")
                                     process-environment)))
    (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                  "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                  "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" suite)))

(ert-deftest drgnx-run-ert/trampolines-stay-in-the-run ()
  ;; A test that `cl-letf's a primitive compiles a native trampoline.  Emacs writes it to the first writable
  ;; directory of `native-comp-eln-load-path' — the user's ~/.config/emacs/eln-cache, which the runner's own
  ;; HOME swap comes too late to change.  The runner puts drgnx's directory first: nothing lands in the home
  ;; the Emacs started with.
  (skip-unless (and (fboundp 'native-comp-available-p) (native-comp-available-p)))
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-eln" t)))
         (home (expand-file-name "home" tmp)) (suite (expand-file-name "suite" tmp))
         (eln (expand-file-name "eln/" tmp)) (probe (expand-file-name "probe" tmp)))
    (unwind-protect
        (progn
          (make-directory home) (make-directory suite)
          (drgnx-run-ert-test--eln-probe suite probe)
          (should (eql 0 (drgnx-run-ert-test--run-suite suite (concat "HOME=" home) "XDG_CONFIG_HOME"
                                                        (concat "DRGNX_TEST_ELN_DIR=" eln))))
          (should (equal (file-name-as-directory (cadr (car (read-from-string (with-temp-buffer (insert-file-contents probe) (buffer-string))))))
                         eln))
          (should (directory-files-recursively eln "\\`subr--trampoline-.*_buffer_list_"))
          (should-not (directory-files-recursively home "\\`subr--trampoline-")))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/children-share-the-eln-dir ()
  ;; Every Emacs of a run (per-file processes, check shards, a test that runs the runner) uses one directory, so
  ;; a trampoline is compiled once: the runner exports it as DRGNX_TEST_ELN_DIR, and a runner given one uses it.
  (skip-unless (and (fboundp 'native-comp-available-p) (native-comp-available-p)))
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-eln" t)))
         (suite (expand-file-name "suite" tmp)) (probe (expand-file-name "probe" tmp))
         (given (expand-file-name "given-eln/" tmp))
         (read-probe (lambda () (car (read-from-string (with-temp-buffer (insert-file-contents probe) (buffer-string)))))))
    (unwind-protect
        (progn
          (make-directory suite)
          (drgnx-run-ert-test--eln-probe suite probe)
          ;; given: passed through as it is, and first in the child's load path
          (should (eql 0 (drgnx-run-ert-test--run-suite suite (concat "DRGNX_TEST_ELN_DIR=" given))))
          (should (equal (mapcar #'file-name-as-directory (funcall read-probe)) (list given given)))
          ;; not given: the runner picks one, exports it and puts it first
          (should (eql 0 (drgnx-run-ert-test--run-suite suite "DRGNX_TEST_ELN_DIR" (concat "XDG_CACHE_HOME=" tmp "cache"))))
          (pcase-let ((`(,exported ,first) (funcall read-probe)))
            (should (stringp exported))
            (should (equal (file-name-as-directory exported) (file-name-as-directory first)))))
      (delete-directory tmp t)))
  ;; this run too
  (when (getenv "DRGNX_TEST_ISOLATED")
    (should (equal (file-name-as-directory (getenv "DRGNX_TEST_ELN_DIR"))
                   (file-name-as-directory (car native-comp-eln-load-path))))))

(defun drgnx-run-ert-test--suite (dir files)
  "Write FILES, an alist NAME → contents, into the directory DIR (made)."
  (make-directory dir t)
  (pcase-dolist (`(,name . ,text) files)
    (with-temp-file (expand-file-name name dir) (insert "(require 'ert)\n" text "\n"))))

(ert-deftest drgnx-run-ert/files-do-not-share-an-emacs ()
  ;; Each test file runs in an Emacs of its own, as Emacs's own `make check' does: a hook a test leaves and a
  ;; feature it loads are gone for the next file.  ERT runs tests in name order, so in one Emacs the leak comes first.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite
           '(("a-leaks-test.el" . "(defun iso-test--leaked () nil)
(ert-deftest iso-a/leaks () (add-hook 'kill-buffer-hook #'iso-test--leaked) (provide 'iso-test--fake-feature))")
             ("b-clean-test.el" . "(ert-deftest iso-b/sees-nothing ()
  (should-not (featurep 'iso-test--fake-feature))
  (should-not (memq 'iso-test--leaked (default-value 'kill-buffer-hook))))")))
          (should (eql 0 (drgnx-run-ert-test--batch suite results)))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (equal (list (plist-get r :total) (plist-get r :passed) (plist-get r :failed)) '(2 2 0)))
            (should (= 2 (length (plist-get r :files)))))
          ;; --one-process: one Emacs, the leak reaches the second file
          (should (eql 1 (drgnx-run-ert-test--batch suite results "DRGNX_TEST_ONE_PROCESS=1")))
          (should (equal (plist-get (aref (plist-get (drgnx-run-ert-test--json results) :failures) 0) :name)
                         "iso-b/sees-nothing")))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-file-s-emacs-ignores-sigpipe-as-the-run-does ()
  ;; bin/drgnx runs the tests with SIGPIPE ignored, as the hub runs: a write to a reader that left is an error in the
  ;; test, never the end of its Emacs.  Emacs starts its children with the default action, so each file's Emacs
  ;; died of the signal (exit 13, no summary) — the gateway's tests, answering an agent that had hung up.
  (skip-unless (and (not (eq system-type 'windows-nt)) (executable-find "sh")))
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite '(("pipe-test.el" . "(ert-deftest iso-pipe/a-reader-that-left ()
  (let* ((ready nil)
         (p (make-process :name \"iso-pipe\" :command '(\"sh\" \"-c\" \"exec 0<&-; echo closed; exec sleep 30\")
                          :connection-type 'pipe :noquery t :filter (lambda (_p _s) (setq ready t)))))
    (while (not ready) (accept-process-output p 5))
    (should (condition-case nil (progn (process-send-string p (make-string 100000 ?x)) nil) (error t)))
    (delete-process p)))")))
          (should (eql 0 (drgnx-run-ert-test--batch suite results "DRGNX_TEST_FILE_TIMEOUT=60")))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (equal (list (plist-get r :total) (plist-get r :passed) (plist-get r :failed)) '(1 1 0)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-file-s-output-is-whole-when-files-run-at-once ()
  ;; DRGNX_TEST_JOBS > 1 keeps each file's output in a buffer until the file ends.  A file is over when its sentinel
  ;; has run — Emacs reads what is left in the pipe first — not once `process-live-p' is nil: the buffer went while
  ;; output was still coming, and the next chunk's filter ("Selecting deleted buffer") ended the whole run.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)) (out nil) (code nil))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite (mapcar (lambda (n) (cons (format "loud%d-test.el" n)
                                           (format "(ert-deftest iso-loud/a%d () (dotimes (i 3000) (message \"line %%d %s\" i)) (message \"loud%d done\"))"
                                                   n (make-string 200 ?x) n)))
                         '(1 2 3 4)))
          (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_JOBS=4"
                                                   "DRGNX_TEST_SELECTOR")
                                             process-environment)))
            (setq out (with-temp-buffer
                        (setq code (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                                                 "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                                 "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" suite))
                        (buffer-string))))
          (should-not (string-search "deleted buffer" out))
          (should (eql 0 code))
          (dolist (n '(1 2 3 4)) (should (string-search (format "loud%d done" n) out))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-crashing-file-is-named ()
  ;; A file whose Emacs dies (a test calls `kill-emacs') or hangs past DRGNX_TEST_FILE_TIMEOUT is a failure that
  ;; names the file; the other files still run and count.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)) (out nil) (code nil))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite suite '(("crash-test.el" . "(ert-deftest iso-crash/dies () (kill-emacs 7))")
                                             ("fine-test.el" . "(ert-deftest iso-fine/ok () (should t))")
                                             ("hang-test.el" . "(ert-deftest iso-hang/waits () (sleep-for 60))")))
          (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_FILE_TIMEOUT=3"
                                                   "DRGNX_TEST_SELECTOR")
                                             process-environment)))
            (setq out (with-temp-buffer
                        (setq code (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                                                 "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                                 "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" suite))
                        (buffer-string))))
          (should (eql 1 code))
          (let* ((r (drgnx-run-ert-test--json results))
                 (names (mapcar (lambda (f) (plist-get f :name)) (plist-get r :failures))))
            (should (equal (plist-get r :passed) 1))
            (should (equal (plist-get r :failed) 2))
            (should (seq-find (lambda (n) (string-match-p "crash-test\\.el" n)) names))
            (should (seq-find (lambda (n) (string-match-p "hang-test\\.el" n)) names))
            (should (string-match-p "timed out" (plist-get (seq-find (lambda (f) (string-match-p "hang-test" (plist-get f :name)))
                                                                     (plist-get r :failures))
                                                           :condition))))
          (should (string-match-p "crash-test\\.el" out)))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/summaries-are-merged ()
  ;; One summary of the same shape as a one-Emacs run (bin/drgnx check reads it), plus each file's exit and time.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite '(("one-test.el" . "(ert-deftest iso-one/passes () (should t))\n(ert-deftest iso-one/fails () (should nil))")
                   ("two-test.el" . "(ert-deftest iso-two/passes () (should t))\n(ert-deftest iso-two/skips () (skip-unless nil))")))
          (should (eql 1 (drgnx-run-ert-test--batch suite results)))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (equal (list (plist-get r :total) (plist-get r :passed) (plist-get r :failed)) '(4 2 1)))     ; a skip is neither
            (should (equal (mapcar (lambda (f) (plist-get f :name)) (plist-get r :failures)) '("iso-one/fails")))
            (should (equal (plist-get r :known_red) []))
            (should (equal (sort (mapcar (lambda (te) (plist-get te :name)) (plist-get r :tests)) #'string<)
                           '("iso-one/fails" "iso-one/passes" "iso-two/passes" "iso-two/skips")))
            (should (seq-every-p (lambda (te) (and (stringp (plist-get te :file)) (numberp (plist-get te :seconds))))
                                 (plist-get r :tests)))
            (let ((files (plist-get r :files)))
              (should (equal (mapcar (lambda (f) (file-name-nondirectory (plist-get f :file))) files) '("one-test.el" "two-test.el")))
              (should (equal (mapcar (lambda (f) (plist-get f :exit)) files) '(1 0)))
              (should (seq-every-p (lambda (f) (numberp (plist-get f :seconds))) files)))))
      (delete-directory tmp t))))

(defun drgnx-run-ert-test--long-dir (tmp)
  "A directory below TMP whose path is at least 100 bytes: as deep as a TMPDIR that leaves no room for a socket."
  (let ((dir (file-name-as-directory (expand-file-name (make-string (max 1 (- 100 (string-bytes tmp))) ?l) tmp))))
    (make-directory dir t)
    dir))

(ert-deftest drgnx-run-ert/the-time-factor-is-a-number-of-at-least-one ()
  ;; DRGNX_TEST_TIME_FACTOR scales :timing budgets on a slower machine: never below 1 (a budget is never tightened),
  ;; and anything that is not a plain number is 1
  (pcase-dolist (`(,value . ,factor) '((nil . 1) ("" . 1) ("2" . 2) ("1.5" . 1.5) ("1" . 1) ("0.5" . 1) ("0" . 1)
                                       ("-2" . 1) ("2x" . 1) ("x" . 1) (" 2" . 1) ("1e3" . 1)))
    (let ((process-environment (cons (if value (concat "DRGNX_TEST_TIME_FACTOR=" value) "DRGNX_TEST_TIME_FACTOR")
                                     process-environment)))
      (should (equal (cons value (drgnx-run-ert-time-factor)) (cons value factor))))))

(ert-deftest drgnx-run-ert/a-files-temp-dir-is-short-whatever-the-tmpdir ()
  ;; A Unix socket's path has at most 103 bytes on macOS (107 on Linux), and the hub's tests make one three levels
  ;; below a file's temp dir: a file's Emacs gets a directory of its own in a short root of the run's, right in
  ;; /tmp (mode 0700), however deep TMPDIR or bin/drgnx's DRGNX_RUN_TMP is (macOS's /var/folders/…/T/ is 49
  ;; bytes); both are gone afterwards, and nothing is left beside the given directory.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (parent (drgnx-run-ert-test--long-dir tmp)) (given (expand-file-name "drgnx-run.abcdef/" parent))
         (suite (expand-file-name "suite" tmp)) (probe (expand-file-name "probe" tmp)))
    (unwind-protect
        (progn
          (make-directory given t)
          (drgnx-run-ert-test--suite
           suite `(("where-test.el" . ,(format "(ert-deftest iso-where/tmp ()
  (write-region (prin1-to-string (list temporary-file-directory (file-modes (file-name-directory (directory-file-name temporary-file-directory))))) nil %S))"
                                               probe))))
          (dolist (run-tmp (list "DRGNX_RUN_TMP" (concat "DRGNX_RUN_TMP=" given)))
            (should (eql 0 (drgnx-run-ert-test--run-suite suite (concat "TMPDIR=" parent) run-tmp)))
            (pcase-let ((`(,seen ,modes) (car (read-from-string (with-temp-buffer (insert-file-contents probe) (buffer-string))))))
              (should (string-match-p drgnx-run-ert-test--file-dir-re seen))
              (should (equal seen (file-name-as-directory (file-truename seen))))   ; macOS: /private/tmp, not /tmp
              (should (eql modes #o700))
              (should-not (file-exists-p seen))
              (should-not (file-exists-p (file-name-directory (directory-file-name seen))))))
          (should (equal (directory-files parent nil directory-files-no-dot-files-regexp) '("drgnx-run.abcdef"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-long-tmpdir-leaves-the-hub-socket-short ()
  ;; macOS CI: under /var/folders/…/T/ each file's hub socket passed 104 bytes and every hub test failed with
  ;; "Service name too long".  A TMPDIR of 100+ bytes on Linux: the hub's socket stays within 103 bytes and a hub
  ;; test (its own file, in an Emacs of its own) passes.  Without a writable /tmp the root is made in TMPDIR, which
  ;; is then as long as it is: nothing to test.
  (skip-unless (file-writable-p "/tmp/"))
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (parent (drgnx-run-ert-test--long-dir tmp))
         (suite (expand-file-name "suite" tmp)) (probe (expand-file-name "socket" tmp)) (results (expand-file-name "r.json" tmp))
         (core (file-name-directory (locate-library "drgnx-hub")))
         (root (file-name-directory (directory-file-name core))))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite `(("socket-test.el" . ,(format "(require 'drgnx-hub)\n(ert-deftest iso-socket/where () (write-region (drgnx-hub-socket) nil %S))"
                                                probe))))
          (should (>= (string-bytes parent) 100))
          (let ((process-environment (append (list (concat "TMPDIR=" parent) "DRGNX_RUN_TMP" (concat "DRGNX_TEST_RESULTS=" results)
                                                   "DRGNX_TEST_SELECTOR=\"\\\\`\\\\(iso-socket/where\\\\|drgnx-hub/ping-status-and-register-over-the-socket\\\\)\\\\'\"")
                                             process-environment)))
            (should (eql 0 (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                         "--batch" "-Q" "-L" core "-L" (expand-file-name "harness" root) "-L" (expand-file-name "wb" root)
                                         "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch"
                                         (expand-file-name "socket-test.el" suite) (expand-file-name "test/unit/hub-test.el" root)))))
          (let ((socket (with-temp-buffer (insert-file-contents probe) (buffer-string))))
            (should (<= (string-bytes socket) 103))
            (should (string-match-p "/drgnx-t-[A-Za-z0-9]\\{6\\}/drgnx-run\\.[A-Za-z0-9]\\{6\\}/" socket)))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (equal (list (plist-get r :total) (plist-get r :passed) (plist-get r :failed)) '(2 2 0)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-narrow-run-starts-an-emacs-only-for-its-files ()
  ;; A name selector (a regexp) starts an Emacs only for the files that define a test it names; any other selector
  ;; (a tag can come from anywhere) runs every file.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-iso" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp))
         (files (lambda (selector)
                  (drgnx-run-ert-test--batch suite results (concat "DRGNX_TEST_SELECTOR=" selector))
                  (mapcar (lambda (f) (file-name-nondirectory (plist-get f :file)))
                          (plist-get (drgnx-run-ert-test--json results) :files)))))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite '(("one-test.el" . "(ert-deftest iso-one/a () (should t))")
                   ("two-test.el" . "(ert-deftest\n    iso-two/b () :tags '(:timing) (should t))")))
          (should (equal (funcall files "\"^iso-two/\"") '("two-test.el")))
          (should (equal (funcall files "\"iso-\\\\(one\\\\|nothing\\\\)\"") '("one-test.el")))
          (should (equal (funcall files "(tag :timing)") '("one-test.el" "two-test.el"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-session-run-loads-only-the-selected-files ()
  ;; M12f-A3-1: `drgnx-run-ert' (one Emacs: a session, --one-process) took no part in the prefilter, so a narrowed
  ;; `test --ui' loaded and ran the whole tier.  A file no selected test is named in is never loaded.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-one" t))) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (with-temp-file (concat tmp "keep-test.el") (insert "(require 'ert)\n(ert-deftest keep/ok () (should t))\n"))
          (with-temp-file (concat tmp "skip-test.el") (insert "(error \"an unselected file was loaded\")\n(ert-deftest skip/never () (should t))\n"))
          (should (eql 0 (let ((process-environment (append (list "DRGNX_TEST_SELECTOR=\"^keep/\"") process-environment))
                               (default-directory tmp))
                           (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                         "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                                         "-l" (locate-library "run-ert.el")
                                         "--eval" (format "(kill-emacs (if (drgnx-run-ert %S %S) 0 1))" tmp results)))))
          (let ((r (drgnx-run-ert-test--json results)))
            (should (equal (mapcar (lambda (te) (plist-get te :name)) (plist-get r :tests)) '("keep/ok")))
            (should (eql (plist-get r :failed) 0))))
      (delete-directory tmp t))))

;;;; The leak census

(defconst drgnx-run-ert-test--leaky
  '(("leaky-test.el" . "(defconst iso-leak--dir (file-name-directory (or load-file-name buffer-file-name)))
(defun iso-leak--hook-fn () nil)
(defun iso-leak--timer-fn () nil)
(defun iso-leak--advice (&rest _) nil)
(ert-deftest iso-leak/hook () (add-hook 'kill-buffer-hook #'iso-leak--hook-fn))
(ert-deftest iso-leak/timer () (run-with-timer 3600 3600 #'iso-leak--timer-fn))
(ert-deftest iso-leak/advice () (advice-add 'ignore :before #'iso-leak--advice))
(ert-deftest iso-leak/feature () (load (expand-file-name \"iso-leak-fake.el\" iso-leak--dir) nil t))")
    ("iso-leak-fake.el" . "(provide 'iso-leak-fake)"))
  "A suite file whose four tests each leave something: a hook, a repeating timer, an advice, a feature.")

(defun drgnx-run-ert-test--census (suite results &rest env)
  "Run SUITE with the census on; return (EXIT . OUTPUT).  The summary goes to RESULTS."
  (let ((process-environment (append (list (concat "DRGNX_TEST_RESULTS=" results) "DRGNX_TEST_LEAKS=1"
                                           "DRGNX_TEST_SELECTOR" "DRGNX_TEST_SHUFFLE")
                                     env process-environment))
        (default-directory temporary-file-directory))
    (with-temp-buffer
      (cons (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                          "--batch" "-Q" "-L" (file-name-directory (locate-library "run-ert.el"))
                          "-l" (locate-library "run-ert.el") "-f" "drgnx-run-ert-batch" suite)
            (buffer-string)))))

(defun drgnx-run-ert-test--leak (leaks what)
  "The entry of LEAKS (a vector) whose :what matches the regexp WHAT, or nil."
  (seq-find (lambda (l) (string-match-p what (plist-get l :what))) leaks))

(defun drgnx-run-ert-test--allow-file (dir &optional text)
  "A leaks-allowed file in DIR holding TEXT (default: nothing allowed)."
  (let ((f (expand-file-name "allowed.eld" dir))) (with-temp-file f (insert (or text "()"))) f))

(ert-deftest drgnx-run-ert/leaks-name-the-test-and-the-source ()
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-leak" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite suite drgnx-run-ert-test--leaky)
          (let* ((r (drgnx-run-ert-test--census suite results (concat "DRGNX_TEST_LEAKS_ALLOWED="
                                                                      (drgnx-run-ert-test--allow-file tmp))))
                 (leaks (plist-get (drgnx-run-ert-test--json results) :leaks))
                 (src (expand-file-name "leaky-test.el" suite))
                 (hook (drgnx-run-ert-test--leak leaks "kill-buffer-hook \\+iso-leak--hook-fn"))
                 (timer (drgnx-run-ert-test--leak leaks "\\`timer .*iso-leak--timer-fn"))
                 (advice (drgnx-run-ert-test--leak leaks "iso-leak--advice"))
                 (feature (drgnx-run-ert-test--leak leaks "\\`feature \\+iso-leak-fake")))
            (should (eql 0 (car r)))                   ; report-only: the exit status is the tests'
            (should (string-match-p "^Leaks (" (cdr r)))
            ;; the per-test scan names the test, the file, and the file that defined the function
            (should (equal (plist-get hook :test) "iso-leak/hook"))
            (should (equal (plist-get hook :file) src))
            (should (equal (plist-get hook :source) src))
            (should (equal (plist-get timer :test) "iso-leak/timer"))
            (should (equal (plist-get timer :source) src))
            (should (equal (plist-get feature :test) "iso-leak/feature"))
            (should (equal (plist-get feature :source) (expand-file-name "iso-leak-fake.el" suite)))
            ;; an advice shows only in the per-file scan: the file and the source, not the test
            (should (equal (plist-get advice :test) :null))
            (should (equal (plist-get advice :file) src))
            (should (equal (plist-get advice :source) src))
            ;; each once: the per-file scan does not repeat what the per-test scan said
            (should (= 4 (seq-count (lambda (l) (string-match-p "iso-leak" (plist-get l :what))) leaks)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/no-leaks-no-report ()
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-leak" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite suite '(("clean-test.el" . "(ert-deftest iso-clean/ok () (should (= 2 (+ 1 1))))")))
          (let ((r (drgnx-run-ert-test--census suite results)))
            (should (eql 0 (car r)))
            (should-not (string-match-p "Leaks" (cdr r)))
            (should (equal (plist-get (drgnx-run-ert-test--json results) :leaks) []))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/allowed-leaks-are-left-out ()
  ;; (:what REGEXP :source REGEXP :why STRING): a leak matching both is not reported; :source may be left out.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-leak" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite suite drgnx-run-ert-test--leaky)
          (drgnx-run-ert-test--census
           suite results
           (concat "DRGNX_TEST_LEAKS_ALLOWED="
                   (drgnx-run-ert-test--allow-file
                    tmp "((:what \"kill-buffer-hook\" :source \"leaky-test\\\\.el\\\\'\" :why \"fixture\")
 (:what \"iso-leak--timer-fn\" :why \"fixture\")
 (:what \"iso-leak--advice\" :source \"nothing-like-this\" :why \"does not match the source\"))")))
          (let ((leaks (plist-get (drgnx-run-ert-test--json results) :leaks)))
            (should-not (drgnx-run-ert-test--leak leaks "iso-leak--hook-fn"))
            (should-not (drgnx-run-ert-test--leak leaks "iso-leak--timer-fn"))
            (should (drgnx-run-ert-test--leak leaks "iso-leak--advice"))      ; the source differs: still reported
            (should (drgnx-run-ert-test--leak leaks "iso-leak-fake"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/a-pending-timer-is-cancelled-after-its-test ()
  ;; The timer test A starts must not fire inside test B: with the census on it is cancelled (and reported) at A's
  ;; end; without, it fires during B's wait.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-leak" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite '(("timer-test.el" . "(defvar iso-timer--fired nil)
(defun iso-timer--fire () (setq iso-timer--fired t))
(ert-deftest iso-timer/a-starts () (run-with-timer 0.05 nil #'iso-timer--fire))
(ert-deftest iso-timer/b-waits () (sleep-for 0.4) (should-not iso-timer--fired))")))
          (let ((r (drgnx-run-ert-test--census suite results (concat "DRGNX_TEST_LEAKS_ALLOWED=" (drgnx-run-ert-test--allow-file tmp)))))
            (should (eql 0 (car r)))
            (should (equal (plist-get (drgnx-run-ert-test--leak (plist-get (drgnx-run-ert-test--json results) :leaks)
                                                                "iso-timer--fire")
                                      :test)
                           "iso-timer/a-starts")))
          ;; the control: without the census the timer fires inside B
          (should (eql 1 (drgnx-run-ert-test--batch suite results))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/layer-timers-are-reset-after-a-test ()
  ;; A layer timer test A leaves pending is cancelled by its key (and reported by its key): the layer forgets it,
  ;; so test B sees no key whose timer a plain `cancel-timer' killed behind the layer's back.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-leak" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite `(("layer-test.el" . ,(format "(add-to-list 'load-path %S)
(require 'drgnx-timer)
(defun iso-layer--fire () nil)
(ert-deftest iso-layer/a-starts () (drgnx-timer-start 'iso-layer 600 #'iso-layer--fire :owner :core))
(ert-deftest iso-layer/b-sees-none () (should-not (drgnx-timer-active-p 'iso-layer)))"
                                               (file-name-directory (locate-library "drgnx-timer"))))))
          (let ((r (drgnx-run-ert-test--census suite results (concat "DRGNX_TEST_LEAKS_ALLOWED=" (drgnx-run-ert-test--allow-file tmp)))))
            (should (eql 0 (car r)))
            (should (equal (plist-get (drgnx-run-ert-test--leak (plist-get (drgnx-run-ert-test--json results) :leaks) "iso-layer")
                                      :test)
                           "iso-layer/a-starts"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/census-off-costs-nothing ()
  ;; Off (the default): no advice, no fingerprint library, no :leaks in the summary.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-leak" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)) (probe (expand-file-name "probe" tmp))
         (read-probe (lambda () (car (read-from-string (with-temp-buffer (insert-file-contents probe) (buffer-string)))))))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite `(("probe-test.el" . ,(format "(ert-deftest iso-probe/state ()
  (with-temp-file %S (prin1 (list (and (advice-member-p 'drgnx-run-ert-census 'ert-run-test) t)
                                  (featurep 'drgnx-modules-fingerprint)) (current-buffer))))" probe))))
          (should (eql 0 (drgnx-run-ert-test--batch suite results)))
          (should (equal (funcall read-probe) '(nil nil)))
          (should-not (plist-member (drgnx-run-ert-test--json results) :leaks))
          ;; on, the same test sees both
          (should (eql 0 (car (drgnx-run-ert-test--census suite results))))
          (should (equal (funcall read-probe) '(t t))))
      (delete-directory tmp t))))

(ert-deftest drgnx-run-ert/an-error-in-the-census-is-a-line-never-an-escape ()
  ;; A fingerprint that cannot be read (here `global-mode-string' is not a list while the test ends) is recorded as a
  ;; census line; it never ends the run, and the tests keep their own verdicts.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-leak" t)))
         (suite (expand-file-name "suite" tmp)) (results (expand-file-name "r.json" tmp)))
    (unwind-protect
        (progn
          (drgnx-run-ert-test--suite
           suite '(("broken-test.el" . "(ert-deftest iso-broken/a-breaks-it () (setq global-mode-string 5))
(ert-deftest iso-broken/b-mends-it () (setq global-mode-string nil))
(ert-deftest iso-broken/c-passes () (should t))")))
          (let* ((r (drgnx-run-ert-test--census suite results (concat "DRGNX_TEST_LEAKS_ALLOWED=" (drgnx-run-ert-test--allow-file tmp))))
                 (json (drgnx-run-ert-test--json results))
                 (line (drgnx-run-ert-test--leak (plist-get json :leaks) "census error")))
            (should (eql 0 (car r)))
            (should (equal (list (plist-get json :total) (plist-get json :passed) (plist-get json :failed)) '(3 3 0)))
            (should line)
            (should (string-match-p "listp" (plist-get line :what)))))
      (delete-directory tmp t))))
