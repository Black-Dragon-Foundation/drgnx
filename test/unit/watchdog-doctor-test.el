;;; watchdog-doctor-test.el --- batch tests: the doctor's freezes and gc checks, the watchdog's notices -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-watchdog)
(require 'drgnx-watchdog-doctor)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar nidhogg-watchdog-mode)

(defun drgnx-watchdog-doctor-test--stall(ms &rest kv)
  "A stall line of MS non-GC milliseconds; KV: :pkg, :felt, :killed."
  `((type . "stall") (nongc_ms . ,ms) (felt . ,(and (plist-get kv :felt) t)) (killed . ,(and (plist-get kv :killed) t))
    (culprit . ((pkg . ,(or (plist-get kv :pkg) "pkg-a"))))))

(defun drgnx-watchdog-doctor-test--facts (lines &rest kv)
  "Doctor facts for a running watchdog whose day holds LINES; KV adds to the `:watchdog' fact."
  (list :watchdog (append (list :running t :today (drgnx-watchdog-doctor--summarize lines)) kv)))

(defun drgnx-watchdog-doctor-test--summary-line (slow total)
  "A summary line whose typing histogram holds SLOW commands at 16 ms or more among TOTAL."
  `((type . "summary") (histograms . ((typing . ,(vector (- total slow) 0 0 slow 0 0 0 0 0))))))

(ert-deftest drgnx-watchdog/doctor-freezes ()
  ;; a day without stalls meets the goal and says the typing share
  (let ((r (drgnx-doctor-check 'freezes (drgnx-watchdog-doctor-test--facts
                                         (list (drgnx-watchdog-doctor-test--summary-line 2 100))))))
    (should (eq (car r) 'ok))
    (should (string-match-p "meets: no stall over 100 ms today; typing ≥ 16 ms: 2.0 %" (nth 1 r))))
  ;; stalls under 250 ms, none felt: info, with the counts and the top packages
  (let ((r (drgnx-doctor-check 'freezes (drgnx-watchdog-doctor-test--facts
                                         (list (drgnx-watchdog-doctor-test--stall 120)
                                               (drgnx-watchdog-doctor-test--stall 150 :pkg "pkg-b")
                                               (drgnx-watchdog-doctor-test--stall 130 :pkg "pkg-b"))))))
    (should (eq (car r) 'info))
    (should (string-match-p "missed: 3 stalls over 100 ms" (nth 1 r)))
    (should (string-match-p "pkg-b 2" (nth 1 r))))
  ;; a felt stall of a second: warn, with the fix line naming package, count, time and felt
  (let ((r (drgnx-doctor-check 'freezes (drgnx-watchdog-doctor-test--facts
                                         (list (drgnx-watchdog-doctor-test--stall 1500 :felt t :pkg "slow-pkg")
                                               (drgnx-watchdog-doctor-test--stall 200 :pkg "slow-pkg"))))))
    (should (eq (car r) 'warn))
    (should (string-match-p "missed: 2 stalls over 100 ms" (nth 1 r)))
    (should (string-match-p "Show Freezes (Help → Show Freezes) — slow-pkg stalled 2 times, 1.7 s in all, 1 felt\\."
                            (nth 2 r))))
  ;; a package with ten stalls is a warning on its own
  (let ((r (drgnx-doctor-check 'freezes (drgnx-watchdog-doctor-test--facts
                                         (cl-loop repeat 10 collect (drgnx-watchdog-doctor-test--stall 110))))))
    (should (eq (car r) 'warn)))
  ;; a killed hang is a warning even when its time is under the goal
  (let ((r (drgnx-doctor-check 'freezes (drgnx-watchdog-doctor-test--facts
                                         (list (drgnx-watchdog-doctor-test--stall 90 :killed t))))))
    (should (eq (car r) 'warn))
    (should (string-match-p "1 hang killed" (nth 1 r)))))

(ert-deftest drgnx-watchdog/doctor-gc ()
  (let* ((row (lambda (meets max &optional p95)
                (list :days (list (list :date "2026-10-27" :max max :meets meets)) :week (list :p95 p95)
                      :meets meets :target 50 :gc-max 250)))
         (check (lambda (gc &optional heap largest)
                  (drgnx-doctor-check 'gc (drgnx-watchdog-doctor-test--facts nil :gc gc :heap heap :largest largest)))))
    ;; met
    (let ((r (funcall check (funcall row t 80.0 40))))
      (should (eq (car r) 'ok))
      (should (string-match-p "meets: p95 40 ms (target 50 ms)" (nth 1 r))))
    ;; missed without a collection at the limit: info with the numbers
    (let ((r (funcall check (funcall row nil 120.0 70) (list :live-mb 300.0 :budget-mb 600 :over nil))))
      (should (eq (car r) 'info))
      (should (string-match-p "missed: p95 70 ms (target 50 ms), longest 120 ms today, live heap 300.0 MB" (nth 1 r))))
    ;; at the limit: warn, the fix names the largest owner
    (let ((r (funcall check (funcall row nil 300.0 70) (list :live-mb 300.0 :budget-mb 600 :over nil)
                      '("pkg-a" 120.5 "mod-a"))))
      (should (eq (car r) 'warn))
      (should (string-match-p "largest: pkg-a 120.5 MB (module mod-a)" (nth 2 r))))
    ;; over the heap budget although the pauses meet
    (let ((r (funcall check (funcall row t 80.0 40) (list :live-mb 700.0 :budget-mb 600 :over t))))
      (should (eq (car r) 'warn))
      (should (string-match-p "Heap Audit (Help → Heap Audit) — live heap 700.0 MB, budget 600 MB" (nth 2 r))))))

(ert-deftest drgnx-watchdog/doctor-without-the-flag ()
  (let ((r (drgnx-doctor-check 'freezes (list :watchdog nil))))
    (should (eq (car r) 'info))
    (should (string-match-p "needs Nidhogg 31.1-nidhogg.N or newer" (nth 1 r)))
    (should (string-match-p "drgnx update" (nth 2 r))))
  (let ((r (drgnx-doctor-check 'freezes (list :watchdog '(:running nil)))))
    (should (eq (car r) 'info))
    (should (string-match-p "off" (nth 1 r)))))

(ert-deftest drgnx-watchdog/doctor-reads-the-day-file ()
  "The facts come from today's day file in the state folder."
  (let* ((root (make-temp-file "drgnx-wd-doctor" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" root) process-environment)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-watchdog-available-p) (lambda () t))
                  ((symbol-function 'drgnx-watchdog--wanted-p) (lambda () t))
                  ((symbol-function 'drgnx-watchdog-doctor--heap) #'ignore)
                  ((symbol-function 'drgnx-watchdog-doctor--largest-owner) #'ignore))
          (let ((dir (drgnx-watchdog-log-directory)) (nidhogg-watchdog-mode t))
            (make-directory dir t)
            (with-temp-file (expand-file-name (format-time-string "%F.jsonl") dir)
              (insert (json-serialize '((type . "stall") (nongc_ms . 400) (felt . t) (culprit . ((pkg . "p")))))
                      "\nnot json\n"))
            (let* ((w (drgnx-watchdog-doctor-facts)) (s (plist-get w :today)))
              (should (plist-get w :running))
              (should (= 1 (plist-get s :stalls)))
              (should (= 1 (plist-get s :felt))))))
      (delete-directory root t))))

(ert-deftest drgnx-watchdog/notice-once-per-signature-day ()
  (drgnx-notice-test-with-model
    (drgnx-notice-define-source 'watchdog :title "Freezes" :command 'freezes)
    (let ((drgnx-watchdog-doctor--noticed nil)
          (felt (list :nongc-ms 1500 :felt t :signature "sig-a" :culprit '(:pkg "pkg-a")))
          (small (list :nongc-ms 400 :felt t :signature "sig-s"))
          (quiet (list :nongc-ms 3000 :felt nil :signature "sig-q")))
      (drgnx-watchdog-doctor-note small)
      (drgnx-watchdog-doctor-note quiet)
      (should (null (drgnx-notices)))                       ; neither felt-and-long nor killed
      (drgnx-watchdog-doctor-note felt)
      (drgnx-watchdog-doctor-note (plist-put (copy-sequence felt) :nongc-ms 1900))
      (should (= 1 (length (drgnx-notices))))               ; the same signature again: nothing
      (let ((n (car (drgnx-notices))))
        (should (eq (plist-get n :source) 'watchdog))
        (should (eq (plist-get n :severity) 'warn))
        (should (eq (plist-get n :command) 'freezes)))
      (drgnx-watchdog-doctor-note (list :nongc-ms 50 :killed t :signature "sig-k"))
      (should (= 2 (length (drgnx-notices))))               ; a killed hang counts at any length
      ;; the next day starts afresh
      (setcar drgnx-watchdog-doctor--noticed "2000-01-01")
      (drgnx-watchdog-doctor-note felt)
      (should (equal (cdr drgnx-watchdog-doctor--noticed) '("sig-a"))))))
