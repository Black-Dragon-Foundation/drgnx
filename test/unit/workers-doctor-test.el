;;; workers-doctor-test.el --- batch tests: the doctor's workers check -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-workers-doctor)

(defvar features)                       ; special here, so a `let' of it is dynamic
(defvar nidhogg-workers--defaults)

(defconst drgnx-workers-doctor-test--switches
  '(nidhogg-workers-process-reader nidhogg-workers-reader-pipes nidhogg-workers-reader-sockets
                                   nidhogg-workers-reader-ptys nidhogg-workers-framing nidhogg-workers-treesit nidhogg-treesit-defer
                                   nidhogg-workers-images nidhogg-image-defer nidhogg-workers-autosave nidhogg-workers-dns))

(defun drgnx-workers-doctor-test--worker (&optional jobs running fallbacks)
  "One worker's stats plist, the keys `nidhogg-workers-stats' has."
  (list :jobs (or jobs 0) :queued 0 :queued-bytes 0 :running (or running 0) :wait-ms (make-vector 9 0)
        :fallbacks fallbacks :cancels 0 :pauses 0 :backpressure 0 :slices 0 :longest-ms 0.0))

(defun drgnx-workers-doctor-test--stats (&rest kv)
  "A `nidhogg-workers-stats' value; KV maps a worker keyword to its plist."
  (append (cl-loop for w in '(:nh-io :nh-parse :nh-img :nh-blk :nh-save)
                   append (list w (or (plist-get kv w) (drgnx-workers-doctor-test--worker))))
          (list :phase-ms nil :blk-threads 1 :deferrals nil :decisions nil :costs nil :pressure nil)))

(defun drgnx-workers-doctor-test--facts (stats &optional off)
  "Live doctor facts: STATS, every switch on except those in OFF."
  (list :workers (list :live t :stats stats
                       :switches (mapcar (lambda (s) (cons s (not (memq s off))))
                                         drgnx-workers-doctor-test--switches))))

(ert-deftest drgnx-workers-doctor/ok-all-on ()
  (let ((r (drgnx-doctor-check
            'workers (drgnx-workers-doctor-test--facts
                      (drgnx-workers-doctor-test--stats
                       :nh-io (drgnx-workers-doctor-test--worker 40 2)
                       :nh-img (drgnx-workers-doctor-test--worker 5 1))))))
    (should (eq (car r) 'ok))
    (should (string-match-p "workers on: .*nidhogg-workers-treesit" (nth 1 r)))
    (should (string-match-p "running: 3" (nth 1 r)))))

(ert-deftest drgnx-workers-doctor/info-switch-off ()
  (let ((r (drgnx-doctor-check
            'workers (drgnx-workers-doctor-test--facts
                      (drgnx-workers-doctor-test--stats
                       :nh-io (drgnx-workers-doctor-test--worker 40 0 '((fd-budget . 1) (thread-create . 2))))
                      '(nidhogg-workers-images nidhogg-workers-dns)))))
    (should (eq (car r) 'info))
    (should (string-match-p "off: nidhogg-workers-images, nidhogg-workers-dns" (nth 1 r)))
    (should (string-match-p "fd-budget 1" (nth 1 r)))
    (should (string-match-p "thread-create 2" (nth 1 r)))))

(ert-deftest drgnx-workers-doctor/warn-fallbacks ()
  ;; 3 of 20 jobs (15 %) took today's path: warn, the fix names the worker's switch
  (let ((r (drgnx-doctor-check
            'workers (drgnx-workers-doctor-test--facts
                      (drgnx-workers-doctor-test--stats
                       :nh-img (drgnx-workers-doctor-test--worker 20 0 '((fd-budget . 3))))))))
    (should (eq (car r) 'warn))
    (should (string-match-p "nh-img" (nth 1 r)))
    (should (string-match-p "nidhogg-workers-images" (nth 2 r))))
  ;; exactly 10 % is not over it
  (let ((r (drgnx-doctor-check
            'workers (drgnx-workers-doctor-test--facts
                      (drgnx-workers-doctor-test--stats
                       :nh-img (drgnx-workers-doctor-test--worker 20 0 '((fd-budget . 2))))))))
    (should (eq (car r) 'info))))

(ert-deftest drgnx-workers-doctor/no-flag-info ()
  (let ((r (drgnx-doctor-check 'workers (list :workers nil))))
    (should (eq (car r) 'info))
    (should (string-match-p "needs Nidhogg 31.1-nidhogg.N or newer" (nth 1 r)))
    (should (string-match-p "drgnx update" (nth 2 r)))))

(ert-deftest drgnx-workers-doctor/batch-claims-no-counters ()
  ;; the batch doctor is its own process: it reports the build and its default switches, never job counts
  (let ((features (cons 'nidhogg-workers features)) (noninteractive t))
    (cl-letf (((symbol-function 'nidhogg-workers-stats)
               (lambda (&optional _) (drgnx-workers-doctor-test--stats
                                      :nh-io (drgnx-workers-doctor-test--worker 99 4 '((dead . 50))))))
              )
      (let* ((nidhogg-workers--defaults (quote ((nidhogg-workers-reader-pipes . t) (nidhogg-workers-framing))))
             (w (drgnx-workers-doctor-facts))
             (r (drgnx-doctor-check 'workers (list :workers w))))
        (should-not (plist-get w :live))
        (should-not (plist-get w :stats))
        (should (eq (car r) 'info))
        (should (string-match-p "this build has work off the main thread" (nth 1 r)))
        (should (string-match-p "on by default: nidhogg-workers-reader-pipes; off by default: nidhogg-workers-framing" (nth 1 r)))
        (should-not (string-match-p "running: \\|jobs\\|dead" (nth 1 r)))))))

(provide 'workers-doctor-test)
;;; workers-doctor-test.el ends here
