;;; bin-lease-test.el --- the host lease: bin/drgnx lease light|heavy|exclusive -*- lexical-binding: t -*-
;; Every test uses a temp DRGNX_LEASE_DIR, a short poll, no systemd cap, and unsets DRGNX_LEASE_HELD and CI for the
;; bin/drgnx it starts (the suite itself may run inside a lease, in CI).  Holders are real processes; each test kills
;; the ones it started.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-lease-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-lease-test--root) nil t)

(defconst drgnx-lease-test--bin (expand-file-name "bin/drgnx" drgnx-lease-test--root))

(defvar drgnx-lease-test--dir nil "The temp directory of the running test.")
(defvar drgnx-lease-test--procs nil "Holders the running test started.")

(defun drgnx-lease-test--env (&rest extra)
  "The environment of a bin/drgnx lease: a temp lease dir, 2 light and 1 heavy slot, EXTRA on top."
  (append extra
          (list (concat "DRGNX_LEASE_DIR=" drgnx-lease-test--dir "/lease") "DRGNX_LEASE_LIGHT=2"
                "DRGNX_LEASE_HEAVY=1" "DRGNX_LEASE_POLL=0.2" "DRGNX_LEASE_CAP=off" "CI=false"
                (concat "HOME=" drgnx-lease-test--dir) "DRGNX_LEASE_HELD" "DRGNX_LEASE")
          process-environment))

(defmacro drgnx-lease-test--with (&rest body)
  "Run BODY with a temp directory; kill the holders it started, then delete the directory."
  (declare (indent 0))
  `(let ((drgnx-lease-test--dir (make-temp-file "drgnx-lease-test" t))
         (drgnx-lease-test--procs nil))
     (unwind-protect (progn ,@body)
       (dolist (p drgnx-lease-test--procs)
         (when (process-live-p p) (signal-process p 'KILL)))
       (call-process "pkill" nil nil nil "-KILL" "-f" (concat "drgnx-lease-test-marker " drgnx-lease-test--dir))
       (delete-directory drgnx-lease-test--dir t))))

(defun drgnx-lease-test--file (name) (expand-file-name name drgnx-lease-test--dir))

(defun drgnx-lease-test--call (env &rest args)
  "Run bin/drgnx ARGS under ENV; (EXIT . OUTPUT), stderr included."
  (let ((process-environment env)
        (default-directory (file-name-as-directory drgnx-lease-test--dir)))
    (with-temp-buffer
      (cons (apply #'call-process drgnx-lease-test--bin nil t nil args) (buffer-string)))))

(defun drgnx-lease-test--holder (env class ready &rest wait-args)
  "Start `bin/drgnx lease CLASS WAIT-ARGS -- sh -c …' in the background; the command touches READY (a file name in
the temp dir) and sleeps.  Return the process."
  (let* ((process-environment env)
         (default-directory (file-name-as-directory drgnx-lease-test--dir))
         (p (make-process
             :name (concat "lease-" class) :noquery t :connection-type 'pipe :buffer nil
             :command (append (list drgnx-lease-test--bin "lease" class) wait-args
                              (list "--" "sh" "-c"
                                    (format "echo $$ > %s.pid; touch %s; exec sleep 30 # drgnx-lease-test-marker %s"
                                            (drgnx-lease-test--file ready) (drgnx-lease-test--file ready) drgnx-lease-test--dir))))))
    (push p drgnx-lease-test--procs)
    p))

(defun drgnx-lease-test--ready (name)
  (drgnx-test-wait (lambda () (file-exists-p (drgnx-lease-test--file name))) :what (concat "holder " name)))

(defun drgnx-lease-test--kill-command (ready)
  "Kill the command of the holder that touched READY (its pid is in READY.pid)."
  (let ((pid (string-trim (drgnx-lease-test--slurp (drgnx-lease-test--file (concat ready ".pid"))))))
    (call-process "kill" nil nil nil "-KILL" pid)))

(defun drgnx-lease-test--slurp (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(ert-deftest drgnx-lease/light-runs-and-releases ()
  (drgnx-lease-test--with
    (let* ((out (drgnx-lease-test--file "out"))
           (r (drgnx-lease-test--call (drgnx-lease-test--env) "lease" "light" "--" "sh" "-c"
                                      (format "echo $DRGNX_LEASE_HELD > %s; exit 3" out))))
      (should (= 3 (car r)))
      (should (string-match-p "\\`light:[12]$" (drgnx-lease-test--slurp out)))
      (should-not (directory-files (drgnx-lease-test--file "lease/holders") nil "\\.eld\\'")))))

(ert-deftest drgnx-lease/the-l-plus-first-holder-waits ()
  (drgnx-lease-test--with
    (let ((env (drgnx-lease-test--env)))
      (drgnx-lease-test--holder env "light" "r1")
      (drgnx-lease-test--holder env "light" "r2")
      (drgnx-lease-test--ready "r1")
      (drgnx-lease-test--ready "r2")
      (let ((r (drgnx-lease-test--call env "lease" "light" "--wait" "1" "--" "true")))
        (should (= 75 (car r)))
        (should (string-match-p "light" (cdr r)))
        (should (string-match-p "sleep 30" (cdr r)))))))

(ert-deftest drgnx-lease/heavy-takes-a-light-slot-too ()
  (drgnx-lease-test--with
    (let ((env (drgnx-lease-test--env)))
      (drgnx-lease-test--holder env "heavy" "r1")
      (drgnx-lease-test--ready "r1")
      ;; one light slot is left: a light fits, a second heavy does not (the only heavy slot), and a light after it
      ;; finds the other light slot taken by the heavy
      (should (= 0 (car (drgnx-lease-test--call env "lease" "light" "--wait" "5" "--" "true"))))
      (should (= 75 (car (drgnx-lease-test--call env "lease" "heavy" "--wait" "1" "--" "true"))))
      (drgnx-lease-test--holder env "light" "r2")
      (drgnx-lease-test--ready "r2")
      (should (= 75 (car (drgnx-lease-test--call env "lease" "light" "--wait" "1" "--" "true")))))))

(ert-deftest drgnx-lease/exclusive-waits-for-holders-and-blocks-no-one ()
  (drgnx-lease-test--with
    (let ((env (drgnx-lease-test--env)) (exclusive-ran (drgnx-lease-test--file "ex")))
      (drgnx-lease-test--holder env "light" "r1")
      (drgnx-lease-test--ready "r1")
      (let ((ex (let ((process-environment env) (default-directory drgnx-lease-test--dir))
                  (make-process :name "lease-ex" :noquery t :buffer nil
                                :command (list drgnx-lease-test--bin "lease" "exclusive" "--wait" "60" "--" "touch"
                                               exclusive-ran)))))
        (push ex drgnx-lease-test--procs)
        (drgnx-test-pause 1)
        (should-not (file-exists-p exclusive-ran))            ; it waits for the light holder
        ;; a new light holder starts while the exclusive polls
        (should (= 0 (car (drgnx-lease-test--call env "lease" "light" "--wait" "5" "--" "true"))))
        (should-not (file-exists-p exclusive-ran))))))

(ert-deftest drgnx-lease/exclusive-runs-once-the-host-is-free ()
  (drgnx-lease-test--with
    (let* ((env (drgnx-lease-test--env))
           (r (drgnx-lease-test--call env "lease" "exclusive" "--" "sh" "-c"
                                      (format "echo $DRGNX_LEASE_HELD ${DRGNX_LEASE_BUSY:-no} > %s" (drgnx-lease-test--file "o")))))
      (should (= 0 (car r)))
      (should (equal "exclusive:0 no\n" (drgnx-lease-test--slurp (drgnx-lease-test--file "o")))))))

(ert-deftest drgnx-lease/exclusive-times-out-and-still-runs ()
  (drgnx-lease-test--with
    (let ((env (drgnx-lease-test--env)))
      (drgnx-lease-test--holder env "light" "r1")
      (drgnx-lease-test--ready "r1")
      (let ((r (drgnx-lease-test--call env "lease" "exclusive" "--wait" "1" "--" "sh" "-c"
                                       (format "echo busy=$DRGNX_LEASE_BUSY > %s" (drgnx-lease-test--file "o")))))
        (should (= 0 (car r)))
        (should (string-match-p "wall clock not judged: host busy" (cdr r)))
        (should (equal "busy=1\n" (drgnx-lease-test--slurp (drgnx-lease-test--file "o"))))))))

;; review det10-13 #3: the command itself holds the slot — the lock fds are inherited, so killing the lease's bash
;; (OOM killer, a scope kill) does not free the slot while the command runs
(ert-deftest drgnx-lease/killing-the-wrapper-keeps-the-slot-while-the-command-runs ()
  (drgnx-lease-test--with
    (let* ((env (drgnx-lease-test--env "DRGNX_LEASE_LIGHT=1"))
           (p (drgnx-lease-test--holder env "light" "r1")))
      (drgnx-lease-test--ready "r1")
      (should (= 75 (car (drgnx-lease-test--call env "lease" "light" "--wait" "1" "--" "true"))))
      (let ((pid (process-id p)))
        (signal-process p 'KILL)
        (drgnx-test-wait (lambda () (not (zerop (signal-process pid 0)))) :what "the wrapper dies"))
      ;; the command (sleep) still runs, still holds the slot
      (should (= 75 (car (drgnx-lease-test--call env "lease" "light" "--wait" "1" "--" "true"))))
      ;; its end frees the slot
      (drgnx-lease-test--kill-command "r1")
      (should (= 0 (car (drgnx-lease-test--call env "lease" "light" "--wait" "10" "--" "true")))))))

(ert-deftest drgnx-lease/a-leftover-daemon-keeps-the-slot-until-it-ends ()
  (drgnx-lease-test--with
    (let ((env (drgnx-lease-test--env "DRGNX_LEASE_LIGHT=1")))
      (let ((r (drgnx-lease-test--call
                env "lease" "light" "--" "sh" "-c"
                (format "setsid sh -c 'echo $$ > %s; exec sleep 30' </dev/null >/dev/null 2>&1 & # drgnx-lease-test-marker %s"
                        (drgnx-lease-test--file "d.pid") drgnx-lease-test--dir))))
        (should (= 0 (car r))))
      (drgnx-test-wait (lambda () (not (string-empty-p (drgnx-lease-test--slurp (drgnx-lease-test--file "d.pid"))))) :what "the daemon")
      (should (= 75 (car (drgnx-lease-test--call env "lease" "light" "--wait" "1" "--" "true"))))
      (call-process "kill" nil nil nil "-KILL" (string-trim (drgnx-lease-test--slurp (drgnx-lease-test--file "d.pid"))))
      (should (= 0 (car (drgnx-lease-test--call env "lease" "light" "--wait" "10" "--" "true")))))))

;; review det10-13 minor: light and heavy never block without end
(ert-deftest drgnx-lease/light-and-heavy-wait-a-bounded-default ()
  (skip-unless (executable-find "timeout"))
  (drgnx-lease-test--with
    (let ((env (drgnx-lease-test--env "DRGNX_LEASE_LIGHT=1" "DRGNX_LEASE_HEAVY=1" "DRGNX_LEASE_WAIT=1")))
      (drgnx-lease-test--holder env "heavy" "r1")      ; holds the heavy slot and the only light slot
      (drgnx-lease-test--ready "r1")
      (dolist (class '("light" "heavy"))
        (let ((process-environment env))
          (with-temp-buffer
            ;; `timeout' only guards the test: the lease itself ends the wait
            (let ((rc (call-process "timeout" nil t nil "20" drgnx-lease-test--bin "lease" class "--" "true")))
              (should (= 75 rc))
              (should (string-match-p (format "no %s slot free in 1 s" class) (buffer-string)))
              (should (string-match-p "DRGNX_LEASE_WAIT" (buffer-string)))))))
      ;; the default is half an hour: long enough for a queue of test runs, short enough that a hung holder shows
      (should (string-search ":-1800}" (with-temp-buffer (insert-file-contents drgnx-lease-test--bin) (buffer-string)))))))

;; DET-LEASE-1: the light cap is 2G (the slot script's), heavy 4G
(ert-deftest drgnx-lease/the-memory-caps-are-2g-light-and-4g-heavy ()
  (drgnx-lease-test--with
    (let* ((bindir (drgnx-lease-test--file "fakebin"))
           (log (drgnx-lease-test--file "systemd-run.log"))
           (env (drgnx-lease-test--env "DRGNX_LEASE_CAP=on" (concat "PATH=" bindir ":" (getenv "PATH")))))
      (make-directory bindir)
      (dolist (f `(("systemctl" . "echo running\n")
                   ("systemd-run" . ,(format "echo \"$*\" >> %s\nwhile [ \"$1\" != -- ]; do shift; done; shift\nexec \"$@\"\n" log))))
        (let ((file (expand-file-name (car f) bindir)))
          (write-region (concat "#!/bin/sh\n" (cdr f)) nil file)
          (set-file-modes file #o755)))
      (should (= 0 (car (drgnx-lease-test--call env "lease" "light" "--" "true"))))
      (should (= 0 (car (drgnx-lease-test--call env "lease" "heavy" "--" "true"))))
      (let ((lines (split-string (drgnx-lease-test--slurp log) "\n" t)))
        (should (= 2 (length lines)))
        (should (string-match-p "MemoryMax=2G" (nth 0 lines)))
        (should (string-match-p "MemoryMax=4G" (nth 1 lines)))))))

(ert-deftest drgnx-lease/nested-and-ci-are-off ()
  (dolist (off '("DRGNX_LEASE_HELD=light:1" "CI=true" "DRGNX_LEASE=off"))
    (drgnx-lease-test--with
      (let ((r (drgnx-lease-test--call (drgnx-lease-test--env off) "lease" "heavy" "--" "echo" "ran")))
        (should (equal '(0 . "ran\n") r))
        (should-not (file-exists-p (drgnx-lease-test--file "lease")))))))

(ert-deftest drgnx-lease/status-lists-live-holders-and-prunes-dead-ones ()
  (drgnx-lease-test--with
    (let ((env (drgnx-lease-test--env)) (holders (drgnx-lease-test--file "lease/holders")))
      (drgnx-lease-test--holder env "light" "r1")
      (drgnx-lease-test--ready "r1")
      (make-directory holders t)
      (write-region "(:class light :slot 9 :pid 999999 :worktree \"/x\" :command \"gone\" :since \"2026-01-01T00:00:00\")"
                    nil (expand-file-name "999999.eld" holders))
      (let ((r (drgnx-lease-test--call env "lease" "status")))
        (should (= 0 (car r)))
        (should (string-match-p "^light [12] [0-9]+ .*sleep 30" (cdr r)))
        (should-not (string-match-p "gone" (cdr r))))
      (should-not (file-exists-p (expand-file-name "999999.eld" holders))))))

(ert-deftest drgnx-lease/the-slot-formulas ()
  (drgnx-lease-test--with
    (cl-flet ((slots (gib nproc)
                (let ((mem (drgnx-lease-test--file "meminfo")))
                  (write-region (format "MemTotal:       %d kB\n" (* gib 1024 1024)) nil mem)
                  (let ((r (drgnx-lease-test--call
                            (append (list (concat "DRGNX_LEASE_MEMINFO=" mem) (format "DRGNX_LEASE_NPROC=%d" nproc)
                                          "DRGNX_LEASE_LIGHT" "DRGNX_LEASE_HEAVY")
                                    (drgnx-lease-test--env))
                            "lease" "status")))
                    (when (string-match "^slots light=\\([0-9]+\\) heavy=\\([0-9]+\\)" (cdr r))
                      (list (string-to-number (match-string 1 (cdr r))) (string-to-number (match-string 2 (cdr r)))))))))
      (should (equal '(5 6) (slots 32 16)))   ; min(16/3, 28/2), (32-8)/4
      (should (equal '(6 2) (slots 16 24)))   ; min(24/3, 12/2), (16-8)/4
      (should (equal '(1 1) (slots 8 2))))))   ; never below one

;;;; The commands take their lease themselves

(defun drgnx-lease-test--stub-emacs ()
  "A fake Emacs that records DRGNX_LEASE_HELD and DRGNX_LEASE_CAP to the file `held' in the temp dir; its path."
  (let ((stub (drgnx-lease-test--file "stub-emacs")))
    (write-region (format "#!/bin/sh\necho \"${DRGNX_LEASE_HELD:-none}\" > %s\n" (drgnx-lease-test--file "held"))
                  nil stub)
    (set-file-modes stub #o755)
    stub))

(defun drgnx-lease-test--held-by (env &rest args)
  "Run bin/drgnx ARGS with a stub Emacs under ENV; what the stub saw of DRGNX_LEASE_HELD."
  (let ((stub (drgnx-lease-test--stub-emacs)))
    (delete-file (drgnx-lease-test--file "held"))
    (apply #'drgnx-lease-test--call (cons (concat "DRGNX_EMACS=" stub) env) args)
    (string-trim (drgnx-lease-test--slurp (drgnx-lease-test--file "held")))))

(ert-deftest drgnx-lease/test-takes-a-light-slot ()
  (drgnx-lease-test--with
    (should (string-match-p "\\`light:[12]\\'" (drgnx-lease-test--held-by (drgnx-lease-test--env) "test")))
    (should (string-match-p "\\`light:[12]\\'" (drgnx-lease-test--held-by (drgnx-lease-test--env) "test" "--one-process")))))

(ert-deftest drgnx-lease/ui-takes-a-heavy-slot ()
  (drgnx-lease-test--with
    (dolist (flag '("--ui" "--scenario" "--bench" "--perf" "--soak"))   ; the ones that run in the harness's Emacs
      (should (equal "heavy:1" (drgnx-lease-test--held-by (drgnx-lease-test--env) "test" flag))))))

(ert-deftest drgnx-lease/check-takes-the-host ()
  (drgnx-lease-test--with
    (should (equal "exclusive:0" (drgnx-lease-test--held-by (drgnx-lease-test--env) "check")))))

(ert-deftest drgnx-lease/perf-ab-takes-the-host ()
  (drgnx-lease-test--with
    (should (equal "exclusive:0" (drgnx-lease-test--held-by (drgnx-lease-test--env) "test" "--perf" "--ab" "HEAD")))))

(ert-deftest drgnx-lease/a-nested-bin-drgnx-takes-nothing ()
  (drgnx-lease-test--with
    (should (equal "light:7" (drgnx-lease-test--held-by (drgnx-lease-test--env "DRGNX_LEASE_HELD=light:7") "test")))
    (should (equal "light:7" (drgnx-lease-test--held-by (drgnx-lease-test--env "DRGNX_LEASE_HELD=light:7") "check")))
    (should-not (file-exists-p (drgnx-lease-test--file "lease")))))

(provide 'bin-lease-test)
