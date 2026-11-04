;;; perf-watchdog-test.el --- batch tests: the perf lab's stall-watchdog rows (env switch, stalls probe, GC and budget rows) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf)
(require 'drgnx-paths)

;; special here too: without the feature (Emacs 31.1), the stubs' `let' would otherwise bind them lexically
;; (`features' is not special in Emacs either: fns.c makes it non-special)
(defvar features)
(defvar nidhogg-watchdog-mode)
(defvar nidhogg-watchdog-threshold)
(defvar nidhogg-watchdog-record-functions)
(defvar drgnx-watchdog-mode)
(defvar nidhogg-watchdog--bucket-edges)

(defmacro perf-watchdog-test--with-feature (&rest body)
  "Run BODY as if `nidhogg-watchdog' were loaded on a system it runs on, with its mode and functions stubbed.
`drgnx-watchdog-mode' is stubbed the way the real one acts: it carries Nidhogg's mode with it."
  `(let ((features (cons 'nidhogg-watchdog features))
         (drgnx-perf--watchdog-applied nil)
         (nidhogg-watchdog-mode nil)
         (drgnx-watchdog-mode nil)
         (nidhogg-watchdog-threshold 100)
         (nidhogg-watchdog--bucket-edges [4 8 16 33 50 100 250 1000]))
     (cl-letf (((symbol-function 'drgnx-perf--watchdog-runs-p) (lambda () t))
               ((symbol-function 'nidhogg-watchdog-mode)
                (lambda (&optional arg) (setq nidhogg-watchdog-mode (and (not (eq arg -1)) t))))
               ((symbol-function 'drgnx-watchdog-mode)
                (lambda (&optional arg)
                  (setq drgnx-watchdog-mode (and (not (eq arg -1)) t))
                  (funcall 'nidhogg-watchdog-mode arg))))
       ,@body)))

(defun perf-watchdog-test--env (value)
  "The (MODE-ON . THRESHOLD) `drgnx-perf--watchdog-env' leaves with $DRGNX_PERF_WATCHDOG set to VALUE (nil: unset)."
  (let ((process-environment (if value (cons (concat "DRGNX_PERF_WATCHDOG=" value) process-environment)
                               (cons "DRGNX_PERF_WATCHDOG" process-environment))))
    (perf-watchdog-test--with-feature
     (drgnx-perf--watchdog-env)
     (cons nidhogg-watchdog-mode nidhogg-watchdog-threshold))))

(ert-deftest drgnx-perf/watchdog-env ()
  (should (equal (perf-watchdog-test--env "on") '(t . 1)))
  (should (equal (perf-watchdog-test--env nil) '(t . 100)))
  (should (equal (perf-watchdog-test--env "default") '(t . 100)))
  (should (null (car (perf-watchdog-test--env "off")))))

(ert-deftest drgnx-perf/watchdog-env-off-is-fully-off ()
  ;; init has already started drgnx's mode (and with it the doctor's hook and idle timer); the `off' arm must stop
  ;; all of it, and the other arms must start it through drgnx's mode, not around it
  (let ((process-environment (cons "DRGNX_PERF_WATCHDOG=off" process-environment)))
    (perf-watchdog-test--with-feature
     (setq drgnx-watchdog-mode t nidhogg-watchdog-mode t)
     (drgnx-perf--watchdog-env)
     (should-not drgnx-watchdog-mode)
     (should-not nidhogg-watchdog-mode)))
  (let ((process-environment (cons "DRGNX_PERF_WATCHDOG=on" process-environment)))
    (perf-watchdog-test--with-feature
     (setq drgnx-watchdog-mode t nidhogg-watchdog-mode t)
     (drgnx-perf--watchdog-env)
     (should drgnx-watchdog-mode)
     (should nidhogg-watchdog-mode)
     (should (= nidhogg-watchdog-threshold 1)))))

(ert-deftest drgnx-perf/no-watchdog-arm-where-it-cannot-run ()
  ;; macOS: the feature is built in, but Nidhogg's start signals "not on this platform yet"; a recording applies and
  ;; restores nothing, so `drgnx-perf-begin' does not signal
  (let ((features (cons 'nidhogg-watchdog features)) (system-type 'darwin) (drgnx-perf--watchdog-applied nil)
        (drgnx-perf--watchdog-prior nil) (nidhogg-watchdog-mode nil) (calls 0))
    (cl-letf (((symbol-function 'nidhogg-watchdog-mode)
               (lambda (&optional _) (cl-incf calls) (error "nidhogg-watchdog: not on this platform yet"))))
      (unwind-protect
          (progn (should-not (drgnx-perf--watchdog-env))
                 (should-not drgnx-perf--watchdog-applied)
                 (drgnx-perf-begin)
                 (drgnx-perf-end)
                 (should (= calls 0)))
        (remove-hook 'pre-command-hook #'drgnx-perf--pre)
        (remove-hook 'post-command-hook #'drgnx-perf--post)
        (remove-hook 'post-gc-hook #'drgnx-perf--gc)))))

(defun perf-watchdog-test--stats (spans missed cpu drain)
  (list :spans spans :missed missed :stale 0 :stalls 0 :monitor-cpu-ms cpu :drain drain))

(ert-deftest drgnx-perf/a-recording-puts-the-watchdog-back ()
  ;; begin applies the arm for the recording, end puts the watchdog back as it found it (mode and threshold), and the
  ;; next begin applies the arm again; what the synthetic day applied itself stays through its recordings
  (cl-letf (((symbol-function 'nidhogg-watchdog-drain-now) #'ignore)
            ((symbol-function 'nidhogg-watchdog-stats)
             (lambda (&optional _) (perf-watchdog-test--stats 0 0 0.0 [0 0 0 0 0 0 0 0 0]))))
    ;; (ARM WAS-ON THRESHOLD ON-DURING THRESHOLD-DURING)
    (dolist (case '(("off" t 100 nil 100) ("on" t 100 t 1) ("default" nil 100 t 100) ("default" t 100 t 100)))
      (pcase-let ((`(,arm ,was ,thr ,during ,during-thr) case))
        (let ((process-environment (cons (concat "DRGNX_PERF_WATCHDOG=" arm) process-environment)))
          (perf-watchdog-test--with-feature
           (let ((drgnx-perf--watchdog-prior nil) (nidhogg-watchdog-record-functions nil))
             (setq drgnx-watchdog-mode was nidhogg-watchdog-mode was nidhogg-watchdog-threshold thr)
             (dotimes (_ 2)
               (drgnx-perf-begin)
               (should (eq nidhogg-watchdog-mode during))
               (should (= nidhogg-watchdog-threshold during-thr))
               (drgnx-perf-end)
               (should (eq nidhogg-watchdog-mode was))
               (should (eq drgnx-watchdog-mode was))
               (should (= nidhogg-watchdog-threshold thr))))))))
    (let ((process-environment (cons "DRGNX_PERF_WATCHDOG=off" process-environment)))
      (perf-watchdog-test--with-feature
       (let ((drgnx-perf--watchdog-prior nil) (nidhogg-watchdog-record-functions nil))
         (setq drgnx-watchdog-mode t nidhogg-watchdog-mode t)
         (drgnx-perf--watchdog-env)
         (drgnx-perf-begin)
         (drgnx-perf-end)
         (should-not nidhogg-watchdog-mode)
         (should-not drgnx-watchdog-mode))))))

(defvar nidhogg-watchdog--drain-edges)

(ert-deftest drgnx-perf/stalls-probe-shape ()
  ;; the probe subtracts a snapshot; it never resets the counters (the watchdog's own summary lines and the day-wide
  ;; totals read them), and the record it keeps carries the signature.  A build without Nidhogg's own drain edges and
  ;; stats delta: the C bucket edges and drgnx's subtraction, whatever the running Nidhogg has.
  (perf-watchdog-test--with-feature
   (let ((drains 0) (resets nil) (calls 0) (drgnx-perf--stalls nil) (nidhogg-watchdog-record-functions nil)
         (nidhogg-watchdog--drain-edges [4 8 16 33 50 100 250 1000]))
     (setq nidhogg-watchdog-mode t)
     (cl-letf (((symbol-function 'nidhogg-watchdog--stats-delta) nil)
               ((symbol-function 'nidhogg-watchdog-drain-now) (lambda () (cl-incf drains)))
               ((symbol-function 'nidhogg-watchdog-stats)
                (lambda (&optional reset)
                  (when reset (push t resets))
                  (if (= (cl-incf calls) 1)
                      (perf-watchdog-test--stats 100 1 10.0 [1 0 0 0 0 0 0 0 0])
                    (perf-watchdog-test--stats 300 3 13.5 [5 0 0 0 0 0 0 1 0])))))
       (drgnx-perf--stalls-begin)
       (should (memq #'drgnx-perf--stall-record nidhogg-watchdog-record-functions))
       (funcall #'drgnx-perf--stall-record '(:wall-ms 120.0 :felt t :signature "a.el:f" :culprit "f"))
       (funcall #'drgnx-perf--stall-record '(:wall-ms 40.0 :felt nil))
       (should (equal (plist-get (car (last drgnx-perf--stalls)) :signature) "a.el:f"))
       (let ((r (drgnx-perf--stalls-end)))
         (should (= drains 2))                  ; at the start and the end
         (should-not resets)
         (should-not (memq #'drgnx-perf--stall-record nidhogg-watchdog-record-functions))
         (should (= (plist-get r :stalls) 2))
         (should (= (plist-get r :stalls-felt) 1))
         (should (= (plist-get r :stall-max-ms) 120.0))
         (let ((w (plist-get r :watchdog)))
           (should (= (plist-get w :missed) 2))
           (should (= (plist-get w :monitor-cpu-ms) 3.5))
           (should (= (plist-get w :spans) 200))
           (should (= (plist-get w :drain-p95-ms) 1000.0)) ; the histogram delta [4 0 0 0 0 0 0 1 0]
           (should (= (plist-get w :drain-max-ms) 1000.0))))))
   (should (equal (drgnx-perf--gc-row '(10.0 30.0 20.0)) '(:count 3 :max 30.0 :p95 30.0)))
   (should (equal (plist-get (drgnx-perf--typing-row '(5 10 20 30)) :ge16) 50.0))))

(defun perf-watchdog-test--probe (stats-fn)
  "Run the stalls probe over two `nidhogg-watchdog-stats' values (STATS-FN gets the call number); the :watchdog plist."
  (let ((calls 0) (drgnx-perf--stalls nil) (nidhogg-watchdog-record-functions nil))
    (setq nidhogg-watchdog-mode t)
    (cl-letf (((symbol-function 'nidhogg-watchdog-drain-now) #'ignore)
              ((symbol-function 'nidhogg-watchdog-stats) (lambda (&optional _) (funcall stats-fn (cl-incf calls)))))
      (drgnx-perf--stalls-begin)
      (plist-get (drgnx-perf--stalls-end) :watchdog))))

(ert-deftest drgnx-perf/probe-reads-the-drain-on-its-own-edges ()
  ;; Nidhogg's drain histogram has finer edges than the C ones: the 2 ms budget has to be readable from it
  (perf-watchdog-test--with-feature
   (let ((nidhogg-watchdog--drain-edges [1 2 4 8 16 33 50 100]))
     (let ((w (perf-watchdog-test--probe
               (lambda (n)
                 (append (perf-watchdog-test--stats (* n 100) 0 1.0 (if (= n 1) [1 0 0 0 0 0 0 0 0] [1 6 0 0 0 0 0 0 0]))
                         (list :samples (* n 120) :drain-over-budget (* n 0)))))))
       (should (= (plist-get w :drain-p95-ms) 2.0))
       (should (= (plist-get w :drain-max-ms) 2.0))
       (should (= (plist-get w :samples) 120))))))

(ert-deftest drgnx-perf/probe-subtracts-through-nidhoggs-delta ()
  ;; when Nidhogg has `--stats-delta' the probe uses it (it copes with a reset in between) and takes its ready p95
  (perf-watchdog-test--with-feature
   (let ((nidhogg-watchdog--drain-edges [1 2 4 8 16 33 50 100]) (args nil))
     (cl-letf (((symbol-function 'nidhogg-watchdog--stats-delta)
                (lambda (now base)
                  (push (cons now base) args)
                  (list :spans 40 :samples 55 :missed 1 :stale 0 :stalls 0 :monitor-cpu-ms 2.0
                        :drain [0 0 3 0 0 0 0 0 0] :drain-p95-ms 4.0 :drain-over-budget 3))))
       (let ((w (perf-watchdog-test--probe
                 (lambda (n) (perf-watchdog-test--stats (* n 1000) 0 (* n 10.0) [9 9 9 9 9 9 9 9 9])))))
         (should (= (length args) 1))
         (should (= (plist-get (cdar args) :spans) 1000))
         (should (= (plist-get (caar args) :spans) 2000))
         (should (= (plist-get w :spans) 40))
         (should (= (plist-get w :samples) 55))
         (should (= (plist-get w :missed) 1))
         (should (= (plist-get w :drain-p95-ms) 4.0)))))))

(ert-deftest drgnx-perf/stalls-probe-without-the-flag ()
  (let ((features (remq 'nidhogg-watchdog features)))
    (should (equal (drgnx-perf--stalls-end) '(:watchdog nil)))
    ;; no stalls row to judge, so nothing fails
    (let ((drgnx-perf-watchdog-gated t))
      (should-not (drgnx-perf-verdict '((typing :watchdog nil :gc (:count 0))) '((typing (:stalls) 0) (typing (:gc :max) 250)))))))

(ert-deftest drgnx-perf/gc-p95-needs-20 ()
  (let ((drgnx-perf-watchdog-gated t) (budgets '((typing (:gc :p95) 50))))
    (should-not (drgnx-perf-verdict `((typing :gc (:count 19 :max 90.0 :p95 90.0))) budgets))
    (should (drgnx-perf-verdict `((typing :gc (:count 20 :max 90.0 :p95 90.0))) budgets))))

(ert-deftest drgnx-perf/budget-rows-parse ()
  (let ((rows (with-temp-buffer
                (insert-file-contents (expand-file-name "test/perf/budgets.eld" drgnx-dir))
                (goto-char (point-min))
                (read (current-buffer)))))
    (dolist (r rows)
      (should (symbolp (car r)))
      (should (consp (cadr r)))
      (should (numberp (nth 2 r))))
    (should (member '(typing (:stalls) 0) rows))
    (should (member '(typing (:gc :max) 250) rows))
    (should (member '(typing (:gc :p95) 50) rows))))

;;; perf-watchdog-test.el ends here
