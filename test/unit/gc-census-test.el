;;; gc-census-test.el --- batch tests: the GC census (W0 of the stall watchdog) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-gc)
(require 'drgnx-gc-census)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar nidhogg-watchdog-mode)

(defmacro drgnx-gc-census-test--fresh (&rest body)
  "BODY with an empty ring of its own, no origin bound, and no real collection in the way (a huge threshold)."
  (declare (indent 0) (debug t))
  `(let ((drgnx-gc-census--ring nil) (drgnx-gc-census--start 0) (drgnx-gc-census--count 0)
         (drgnx-gc-census--dropped 0) (drgnx-gc-census--last-elapsed 0.0) (drgnx-gc-census--last-error nil)
         (nidhogg-watchdog-gc-origin nil)
         (gc-cons-threshold most-positive-fixnum))
     (drgnx-gc-census--reset)
     ,@body))

(defmacro drgnx-gc-census-test--in-dirs (&rest body)
  "BODY with temporary state and config folders (XDG_STATE_HOME, DRGNX_CONFIG_DIR), removed after."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "drgnx-gc-census" t))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root "/state")
                                             (concat "DRGNX_CONFIG_DIR=" root "/config"))
                                       process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(defun drgnx-gc-census-test--lines (file)
  "FILE's lines, parsed as JSON objects (alists)."
  (with-temp-buffer
    (insert-file-contents file)
    (mapcar (lambda (l) (json-parse-string l :object-type 'alist))
            (split-string (buffer-string) "\n" t))))

(defun drgnx-gc-census-test--day (date lines)
  "Write the day file DATE.jsonl in the census folder: LINES are (PAUSE-MS ORIGIN FELT LIVE-MB)."
  (let ((dir (drgnx-gc-census-directory)) (i 0))
    (make-directory dir t)
    (with-temp-file (expand-file-name (concat date ".jsonl") dir)
      (pcase-dolist (`(,ms ,origin ,felt ,live) lines)
        (insert (json-serialize
                 `((v . 1) (type . "gc") (at . ,(format "%sT10:%02d:00.000+00:00" date (cl-incf i))) (pid . 1)
                   (pause_ms . ,ms) (origin . ,origin) (felt . ,(if felt t :false))
                   (heap . ((live_mb . ,live) (free_mb . 1.0) (conses_mb . ,(/ live 2.0))))
                   (rss_mb . 100) (threshold_mb . 64.0)))
                "\n")
        ;; a stall line the census report skips
        (insert "{\"v\":1,\"type\":\"stall\",\"wall_ms\":500}\n")))))

(ert-deftest drgnx-gc-census/hook-records-into-the-ring ()
  (drgnx-gc-census-test--fresh
    (let ((gc-elapsed 2.0))
      (drgnx-gc-census--reset)                          ; the baseline: gc-elapsed now
      (setq gc-elapsed 2.125)
      (drgnx-gc-census--note)
      (let ((e (drgnx-gc-census--entries)))
        (should (= (length e) 1))
        (should (< (abs (- (plist-get (car e) :pause-ms) 125.0)) 1e-6))
        (should (eq (plist-get (car e) :origin) 'auto))
        (should (= (plist-get (car e) :gcs) gcs-done))
        (should (assq 'conses (plist-get (car e) :heap)))
        (should (= (plist-get (car e) :threshold) gc-cons-threshold)))
      (setq gc-elapsed 2.5)                             ; the next pause is measured from the last note
      (drgnx-gc-census--note)
      (should (< (abs (- (plist-get (cadr (drgnx-gc-census--entries)) :pause-ms) 375.0)) 1e-6)))))

(ert-deftest drgnx-gc-census/hook-does-no-io ()
  (drgnx-gc-census-test--fresh
    (unless (compiled-function-p (symbol-function 'drgnx-gc-census--note))
      (byte-compile 'drgnx-gc-census--note))            ; as a session runs it: interpreted code conses its environment
    (drgnx-gc-census--note)                             ; warm
    (let ((calls nil))
      ;; the stubs first: installing one may load its trampoline, which is file I/O of the test's own
      (cl-letf (((symbol-function 'write-region) (lambda (&rest _) (push 'write-region calls)))
                ((symbol-function 'input-pending-p) (lambda (&rest _) (push 'input-pending-p calls)))
                ((symbol-function 'process-attributes) (lambda (&rest _) (push 'process-attributes calls)))
                ((symbol-function 'message) (lambda (&rest _) (push 'message calls))))
        (let ((file-name-handler-alist (list (cons "" (lambda (op &rest _) (push op calls) (error "No file I/O"))))))
          (drgnx-gc-census--note)))
      (should-not calls))
    ;; (CONSES FLOATS VECTOR-CELLS SYMBOLS STRING-CHARS INTERVALS STRINGS)
    (let* ((before (memory-use-counts)) (_ (drgnx-gc-census--note)) (after (memory-use-counts))
           (d (cl-mapcar #'- after before)))
      (should (< (nth 0 d) 64))                         ; garbage-collect-heapsize's list (~50) and memory-use-counts' own 7
      (should (<= (nth 1 d) 4))                         ; the pause and the time
      (should (equal (list (nth 2 d) (nth 3 d) (nth 4 d) (nth 5 d) (nth 6 d)) '(0 0 0 0 0))))
    (should (= (length (drgnx-gc-census--entries)) 3))))

(ert-deftest drgnx-gc-census/origin-from-binding ()
  (drgnx-gc-census-test--fresh
    (cl-letf (((symbol-function 'garbage-collect) (lambda () (drgnx-gc-census--note) nil)))
      (let ((gc-cons-threshold 1000) (drgnx-gc--base 0))
        (drgnx-gc--idle)                                ; drgnx's idle collection
        (cl-letf (((symbol-function 'current-idle-time) (lambda () '(0 1 0 0)))
                  ((symbol-function 'input-pending-p) #'ignore))
          (let ((drgnx-gc-gap-quiet 0.02)) (should (drgnx-gc-gap)))))   ; a producer's quiet gap
      (let ((nidhogg-watchdog-gc-origin 'audit)) (garbage-collect))     ; the heap audit binds it
      (garbage-collect))                                                ; anything else
    (let ((e (drgnx-gc-census--entries)))
      (should (equal (mapcar (lambda (x) (plist-get x :origin)) e) '(idle gap audit auto)))
      (should (equal (mapcar (lambda (x) (plist-get x :felt)) e) '(t nil t t))))))   ; the gap ran at idle

(ert-deftest drgnx-gc-census/writer-lines-match-the-schema ()
  (drgnx-gc-census-test--in-dirs
    (drgnx-gc-census-test--fresh
      (let ((gc-elapsed 1.0))
        (drgnx-gc-census--reset)
        (setq gc-elapsed 1.0425)
        (let ((nidhogg-watchdog-gc-origin 'idle)) (drgnx-gc-census--note))
        (setq gc-elapsed 1.1)
        (drgnx-gc-census--note))
      (drgnx-gc-census--write)
      (should (= (length (drgnx-gc-census--entries)) 0))
      (let* ((files (directory-files (drgnx-gc-census-directory) t "\\`[0-9-]+\\.jsonl\\'"))
             (lines (apply #'append (mapcar #'drgnx-gc-census-test--lines files))))
        (should (= (length lines) 2))
        (dolist (f files) (should (= (file-modes f) #o600)))
        (should (equal (mapcar (lambda (l) (alist-get 'origin l)) lines) '("idle" "auto")))
        (should (equal (mapcar (lambda (l) (alist-get 'pause_ms l)) lines) '(42.5 57.5)))
        (dolist (l lines)
          (should (equal (alist-get 'v l) 1))
          (should (equal (alist-get 'type l) "gc"))
          (should (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]T[0-9:]\\{8\\}\\.[0-9]\\{3\\}[-+][0-9][0-9]:[0-9][0-9]\\'"
                                  (alist-get 'at l)))
          (should (equal (alist-get 'pid l) (emacs-pid)))
          (should (memq (alist-get 'felt l) '(t :false)))
          (should (integerp (alist-get 'gcs_done l)))
          (should (numberp (alist-get 'rss_mb l)))
          (should (numberp (alist-get 'threshold_mb l)))
          (let ((heap (alist-get 'heap l)))
            (should (equal (mapcar #'car heap)
                           '(live_mb free_mb conses_mb strings_mb string_bytes_mb vectors_mb symbols_mb
                                     intervals_mb floats_mb buffers_mb)))
            (should (cl-every #'numberp (mapcar #'cdr heap)))
            (should (> (alist-get 'live_mb heap) 0))
            ;; live is the sum of the types (each rounded to 0.1 MB)
            (should (< (abs (- (alist-get 'live_mb heap) (apply #'+ (mapcar #'cdr (cddr heap))))) 1.0))))))))

(ert-deftest drgnx-gc-census/ring-overflow-counted ()
  (drgnx-gc-census-test--fresh
    (dotimes (_ 70) (drgnx-gc-census--note))
    (should (= (length (drgnx-gc-census--entries)) 64))
    (should (= drgnx-gc-census--dropped 6))))

(ert-deftest drgnx-gc-census/stands-down-under-the-watchdog ()
  (drgnx-gc-census-test--in-dirs
    (drgnx-gc-census-test--fresh
      (drgnx-gc-census--note)                           ; one before the watchdog came on
      (let ((nidhogg-watchdog-mode t))
        (drgnx-gc-census--note)
        (should (= (length (drgnx-gc-census--entries)) 1))
        (drgnx-gc-census--write)
        (should-not (file-exists-p (drgnx-gc-census-directory)))))))

(ert-deftest drgnx-gc-census/report-percentiles ()
  (drgnx-gc-census-test--in-dirs
    (drgnx-gc-census-test--day "2026-10-20" (append (make-list 10 '(5.0 "idle" nil 100.0))
                                                    (make-list 9 '(40.0 "auto" t 100.0))
                                                    (list '(300.0 "gap" t 100.0))))
    (drgnx-gc-census-test--day "2026-10-21" (list '(12.0 "auto" nil 100.0)))
    (let* ((r (drgnx-gc-census-report :days 7))
           (day (seq-find (lambda (d) (equal (plist-get d :date) "2026-10-20")) (plist-get r :days))))
      (should (equal (mapcar (lambda (d) (plist-get d :date)) (plist-get r :days)) '("2026-10-20" "2026-10-21")))
      (should (= (plist-get day :count) 20))
      (should (= (plist-get day :max) 300.0))
      (should (< (abs (- (plist-get day :total-s) 0.71)) 1e-9))
      (should (equal (plist-get day :buckets) [0 10 0 0 9 0 0 1 0]))
      (should (< (abs (- (plist-get day :p50) 8.0)) 1e-9))      ; rank 10: the top of [4, 8)
      (should (< (abs (- (plist-get day :p95) 50.0)) 1e-9))     ; rank 19: the top of [33, 50)
      (should (< (abs (- (plist-get day :p99) 300.0)) 1e-9))    ; inside [250, 1000), never above the max
      (should (= (plist-get day :felt) 10))
      (should (equal (plist-get day :origins) '((auto . 0.45) (gap . 0.05) (idle . 0.5))))
      (should (= (plist-get (plist-get r :all) :count) 21))
      ;; :days counts the newest day files
      (should (equal (mapcar (lambda (d) (plist-get d :date)) (plist-get (drgnx-gc-census-report :days 1) :days))
                     '("2026-10-21")))
      ;; and the command's text shows it
      (should (string-match-p "2026-10-20 +20 +300\\.0" (drgnx-gc-census-report-text r))))))

(ert-deftest drgnx-gc-census/report-slope ()
  (drgnx-gc-census-test--in-dirs
    (drgnx-gc-census-test--day "2026-10-19" (list '(20.0 "auto" nil 100.0) '(40.4 "auto" nil 200.0)))
    (drgnx-gc-census-test--day "2026-10-20" (list '(59.6 "idle" nil 300.0) '(80.0 "auto" nil 400.0)))
    (let ((r (drgnx-gc-census-report)))
      (should (= (plist-get r :points) 4))
      (should (< (abs (- (plist-get r :slope) 20.0)) 0.2))     ; ms per 100 MB, within 1 %
      (should (equal (plist-get (plist-get r :heap) :live_mb) 400.0))   ; after the last collection
      (should (equal (plist-get (plist-get r :heap) :conses_mb) 200.0)))))

(ert-deftest drgnx-gc-census/old-files-deleted-at-start ()
  (drgnx-gc-census-test--in-dirs
    (let* ((dir (drgnx-gc-census-directory))
           (day (lambda (n) (format-time-string "%F.jsonl" (time-subtract nil (* n 86400)))))
           (old (funcall day 20)) (recent (funcall day 3)) (today (funcall day 0)))
      (make-directory dir t)
      (dolist (f (list old recent today "notes.txt" (concat "heap-" (string-remove-suffix ".jsonl" old) ".json")))
        (write-region "" nil (expand-file-name f dir) nil 'silent))
      ;; the setting turns the census on at start (drgnx-gc-setup)
      (make-directory (getenv "DRGNX_CONFIG_DIR") t)
      (write-region "(:gc-census t)\n" nil (expand-file-name "speed.eld" (getenv "DRGNX_CONFIG_DIR")) nil 'silent)
      (let ((gc-cons-threshold (* 64 1024 1024)) (gc-cons-percentage 0.1))
        (drgnx-test-with-clock ()
          (unwind-protect
              (progn
                (drgnx-gc-setup)
                (should drgnx-gc-census-mode)
                (should (memq #'drgnx-gc--note post-gc-hook))           ; the owner's hook calls the census
                (should (drgnx-timer-active-p 'gc-census)))
            (drgnx-gc-census-mode -1)
            (drgnx-gc-mode -1)
            (drgnx-timer-cancel 'gc-idle))))
      (should-not drgnx-gc-census-mode)
      (should-not (memq #'drgnx-gc--note post-gc-hook))
      (should (equal (sort (directory-files dir nil "\\`[^.]") #'string<)
                     (sort (list recent today "notes.txt" (concat "heap-" (string-remove-suffix ".jsonl" old) ".json"))
                           #'string<))))))

(ert-deftest drgnx-gc-census/gc-census-command-is-registered ()
  (require 'drgnx)
  (drgnx--core-commands)
  (should (drgnx-commands-get 'gc-census)))

(provide 'gc-census-test)
;;; gc-census-test.el ends here
