;;; drgnx-gc-census.el --- The GC census: each collection's pause, origin and live heap -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The first measure of the stall watchdog (docs/develop/perf.md, "GC census").  `drgnx-gc-census-mode' puts one
;; function on `post-gc-hook', `drgnx-gc-census--note', which only records numbers into a fixed ring: the pause (the
;; change in `gc-elapsed', which Emacs updates before it runs the hook), the origin (`nidhogg-watchdog-gc-origin',
;; bound by drgnx's own collections), whether it ran inside a command or a timer rather than at idle, `gcs-done', the
;; time, the live heap by type (`garbage-collect-heapsize') and the threshold.  It does no I/O, never asks whether input
;; is pending and allocates only that heap list.  An idle timer writes the ring as collection lines (JSON Lines, the
;; watchdog's format) into (drgnx-state-dir)/watchdog/YYYY-MM-DD.jsonl; day files older than 14 days are deleted when
;; the mode starts.  `drgnx-gc-census-report' reads the day files back; the command `gc-census' (Help) shows it.
;; Off by default: speed.eld's :gc-census turns it on at start, `drgnx-gc-census-mode' for this session.  While the
;; watchdog's own mode (`nidhogg-watchdog-mode') is on, the census stands down: one writer.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-timer)
(require 'drgnx-registry)
(require 'drgnx-gc)

(defvar nidhogg-watchdog-mode)
(declare-function drgnx-ui-insert-button "drgnx-ui-kit" (label action &rest keys))

(defconst drgnx-gc-census-ring-size 64 "Collections the ring holds between two writes; more are counted as dropped.")
(defconst drgnx-gc-census-keep-days 14 "Day files older than this many days are deleted when the census starts.")
(defconst drgnx-gc-census-max-day-bytes (* 32 1024 1024) "The largest day file the report reads.")
(defconst drgnx-gc-census-buckets [4 8 16 33 50 100 250 1000]
  "Upper edges (ms) of the watchdog's histogram buckets; a ninth bucket holds the pauses of 1000 ms and more.")

(defconst drgnx-gc-census--heap-types
  '((conses . conses_mb) (strings . strings_mb) (string-bytes . string_bytes_mb) (vectors . vectors_mb)
    (vector-slots . vectors_mb) (symbols . symbols_mb) (intervals . intervals_mb) (floats . floats_mb)
    (buffers . buffers_mb))
  "`garbage-collect-heapsize' types → the collection line's heap keys.  Vector slots count with vectors; its `heap'
entry (malloc's arena, not the Lisp heap) is left out.")

(defconst drgnx-gc-census--heap-keys
  '(conses_mb strings_mb string_bytes_mb vectors_mb symbols_mb intervals_mb floats_mb buffers_mb)
  "The per-type keys of a collection line's heap, in order (after live_mb and free_mb).")

(defconst drgnx-gc-census--day-re "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\.jsonl\\'" "A day file's name.")

;;;; The setting

(drgnx-config-define 'speed
                     :file "speed.eld" :shape 'plist :version 1 :reload 'start :last-good t
                     :schema '(plist (:gc-census boolean "Record every garbage collection (Help → GC Census)"))
                     :default nil
                     :doc "Speed measurements you turn on (read at every start).")

(defun drgnx-gc-census-maybe-start ()
  "Turn the census on when speed.eld's :gc-census is t; `drgnx-gc-setup' calls it at start."
  (when (eq (drgnx-config-get 'speed :gc-census) t)
    (drgnx-gc-census-mode 1)))

;;;; The ring (the hook's side)

(defvar drgnx-gc-census--ring nil
  "`drgnx-gc-census-ring-size' slots, each a vector [PAUSE-MS ORIGIN FELT GCS WALL HEAP THRESHOLD PERCENTAGE], made
once by `drgnx-gc-census--reset' so that recording a collection fills a slot and allocates nothing for it.")
(defvar drgnx-gc-census--start 0 "The index of the oldest entry in the ring.")
(defvar drgnx-gc-census--count 0 "How many entries the ring holds.")
(defvar drgnx-gc-census--dropped 0 "Collections not recorded since the census started: the ring was full.")
(defvar drgnx-gc-census--last-elapsed 0.0 "`gc-elapsed' at the last note (or at the start).")
(defvar drgnx-gc-census--last-error nil "Why the last write failed, or nil.")

(defun drgnx-gc-census--reset ()
  "An empty ring, no drops, and the pause measured from `gc-elapsed' now."
  (let ((ring (make-vector drgnx-gc-census-ring-size nil)))
    (dotimes (i drgnx-gc-census-ring-size) (aset ring i (make-vector 8 nil)))
    (setq drgnx-gc-census--ring ring drgnx-gc-census--start 0 drgnx-gc-census--count 0 drgnx-gc-census--dropped 0
          drgnx-gc-census--last-elapsed gc-elapsed)))

(defun drgnx-gc-census--note ()
  "On `post-gc-hook': record this collection in the ring, or count it as dropped when the ring is full.
Numbers only, for it runs inside every collection: no file I/O, no `process-attributes', no message, and no
`input-pending-p' (on pgtk it can dispatch GLib events inside the collection's span); FELT is only whether it ran
inside a command or a timer rather than at idle.  It allocates `garbage-collect-heapsize''s small list and two floats.
Nothing while the watchdog's own mode is on."
  (unless (bound-and-true-p nidhogg-watchdog-mode)
    (let ((elapsed gc-elapsed))
      (if (>= drgnx-gc-census--count drgnx-gc-census-ring-size)
          (setq drgnx-gc-census--dropped (1+ drgnx-gc-census--dropped))
        (let ((slot (aref drgnx-gc-census--ring
                          (% (+ drgnx-gc-census--start drgnx-gc-census--count) drgnx-gc-census-ring-size))))
          (aset slot 0 (* 1000 (- elapsed drgnx-gc-census--last-elapsed)))
          (aset slot 1 (or nidhogg-watchdog-gc-origin 'auto))
          (aset slot 2 (null (current-idle-time)))
          (aset slot 3 gcs-done)
          (aset slot 4 (float-time))
          (aset slot 5 (garbage-collect-heapsize))
          (aset slot 6 gc-cons-threshold)
          (aset slot 7 gc-cons-percentage)
          (setq drgnx-gc-census--count (1+ drgnx-gc-census--count))))
      (setq drgnx-gc-census--last-elapsed elapsed))))

(defun drgnx-gc-census--entries ()
  "The ring's entries, oldest first: plists (:pause-ms :origin :felt :gcs :wall :heap :threshold :percentage)."
  (let (out)
    (dotimes (i drgnx-gc-census--count)
      (let ((s (aref drgnx-gc-census--ring (% (+ drgnx-gc-census--start i) drgnx-gc-census-ring-size))))
        (push (list :pause-ms (aref s 0) :origin (aref s 1) :felt (aref s 2) :gcs (aref s 3) :wall (aref s 4)
                    :heap (aref s 5) :threshold (aref s 6) :percentage (aref s 7))
              out)))
    (nreverse out)))

(defun drgnx-gc-census--drop (n)
  "Take the N oldest entries out of the ring.  No allocation, so no collection can add one in between."
  (dotimes (i n)
    (aset (aref drgnx-gc-census--ring (% (+ drgnx-gc-census--start i) drgnx-gc-census-ring-size)) 5 nil))
  (setq drgnx-gc-census--start (% (+ drgnx-gc-census--start n) drgnx-gc-census-ring-size)
        drgnx-gc-census--count (- drgnx-gc-census--count n)))

;;;; The writer (at idle)

(defun drgnx-gc-census-directory ()
  "Where the census writes its day files: the watchdog's log folder, (drgnx-state-dir)/watchdog/."
  (expand-file-name "watchdog/" (drgnx-state-dir)))

(defun drgnx-gc-census--mb (bytes)
  "BYTES in MB (MiB), to 0.1."
  (/ (fround (/ bytes 104857.6)) 10.0))

(defun drgnx-gc-census--heap (heapsize)
  "HEAPSIZE (`garbage-collect-heapsize') as (LIVE-BYTES . HEAP): HEAP the line's alist of MB, live_mb and free_mb
first; live bytes per type are SIZE × USED, free ones SIZE × FREE."
  (let ((acc (mapcar (lambda (k) (cons k 0)) drgnx-gc-census--heap-keys)) (live 0) (free 0))
    (dolist (e heapsize)
      (when-let* ((key (alist-get (car e) drgnx-gc-census--heap-types)))
        (let ((size (nth 1 e)) (used (or (nth 2 e) 0)) (unused (or (nth 3 e) 0)))
          (cl-incf (alist-get key acc) (* size used))
          (cl-incf live (* size used))
          (cl-incf free (* size unused)))))
    (cons live `((live_mb . ,(drgnx-gc-census--mb live)) (free_mb . ,(drgnx-gc-census--mb free))
                 ,@(mapcar (lambda (c) (cons (car c) (drgnx-gc-census--mb (cdr c)))) acc)))))

(defun drgnx-gc-census--line (entry rss)
  "ENTRY (from `drgnx-gc-census--entries') as a collection line; RSS the process's MB now, or nil."
  (let ((heap (drgnx-gc-census--heap (plist-get entry :heap))))
    (json-serialize
     `((v . 1) (type . "gc") (at . ,(format-time-string "%FT%T.%3N%:z" (plist-get entry :wall))) (pid . ,(emacs-pid))
       (pause_ms . ,(/ (fround (* 10 (plist-get entry :pause-ms))) 10.0))
       (origin . ,(symbol-name (plist-get entry :origin))) (felt . ,(if (plist-get entry :felt) t :false))
       (gcs_done . ,(plist-get entry :gcs)) (heap . ,(cdr heap)) (rss_mb . ,(or rss :null))
       ;; the threshold in effect: gc-cons-percentage of the live heap when that is more
       (threshold_mb . ,(drgnx-gc-census--mb (max (plist-get entry :threshold)
                                                  (* (plist-get entry :percentage) (car heap)))))))))

(defun drgnx-gc-census--rss-mb ()
  "This Emacs's resident size in MB, or nil where the system does not tell."
  (let ((default-directory "/") (file-name-handler-alist nil))
    (when-let* ((kb (alist-get 'rss (process-attributes (emacs-pid)))))
      (round (/ kb 1024.0)))))

(defun drgnx-gc-census--write ()
  "The idle writer: the ring's entries as collection lines in their day's file, then out of the ring.  The RSS is
read now, once for all of them.  A failed write drops them and is kept in `drgnx-gc-census--last-error'.
Nothing while the watchdog's own mode is on."
  (unless (or (bound-and-true-p nidhogg-watchdog-mode) (zerop drgnx-gc-census--count))
    (let ((entries (drgnx-gc-census--entries)) (rss (drgnx-gc-census--rss-mb)) (dir (drgnx-gc-census-directory)))
      (drgnx-gc-census--drop (length entries))
      (condition-case err
          (dolist (e entries)
            (drgnx-file-append-line (expand-file-name (format-time-string "%F.jsonl" (plist-get e :wall)) dir)
                                    (drgnx-gc-census--line e rss)))
        (error (setq drgnx-gc-census--last-error (error-message-string err)))))))

(defun drgnx-gc-census--prune ()
  "Delete the day files dated more than `drgnx-gc-census-keep-days' days ago (by the date in their name)."
  (let* ((default-directory "/") (file-name-handler-alist nil) (dir (drgnx-gc-census-directory))
         (cutoff (format-time-string "%F" (time-subtract (current-time) (* drgnx-gc-census-keep-days 86400)))))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir nil drgnx-gc-census--day-re))
        (when (string< f cutoff)
          (ignore-errors (delete-file (expand-file-name f dir))))))))

(define-minor-mode drgnx-gc-census-mode
  "The GC census: every collection's pause, origin and live heap, written at idle to the watchdog's day files.
Turned on at start by speed.eld's :gc-census; Help → GC Census shows what it recorded."
  :global t :group 'drgnx
  (cond (drgnx-gc-census-mode
         (drgnx-gc-census--reset)
         (drgnx-gc-census--prune)
         (add-hook 'post-gc-hook #'drgnx-gc-census--note)
         (drgnx-timer-start 'gc-census 1 #'drgnx-gc-census--write :repeat t :idle t :owner :core))
        (t (remove-hook 'post-gc-hook #'drgnx-gc-census--note)
           (drgnx-timer-cancel 'gc-census)
           (drgnx-gc-census--write))))                 ; what the ring still holds

;;;; The report

(defun drgnx-gc-census--day-files (days)
  "The newest DAYS day files, oldest first (absolute names)."
  (let ((dir (drgnx-gc-census-directory)) (file-name-handler-alist nil))
    (and (file-directory-p dir) (last (directory-files dir t drgnx-gc-census--day-re) days))))

(defun drgnx-gc-census--read-day (file)
  "FILE's collection lines, oldest first, as plists (`json-parse-string'); other lines and broken ones are skipped."
  (let (out)
    (dolist (l (split-string (or (drgnx-file-read-bounded file :max-bytes drgnx-gc-census-max-day-bytes) "") "\n" t))
      (let ((o (ignore-errors (json-parse-string l :object-type 'plist :false-object nil :null-object nil))))
        (when (and (equal (plist-get o :type) "gc") (numberp (plist-get o :pause_ms)))
          (push o out))))
    (nreverse out)))

(defun drgnx-gc-census--bucket (ms)
  "The index of the bucket of a pause of MS."
  (or (cl-position-if (lambda (edge) (< ms edge)) drgnx-gc-census-buckets) (length drgnx-gc-census-buckets)))

(defun drgnx-gc-census--percentile (counts q max)
  "The Q quantile (0 to 1) of the pauses counted in the bucket vector COUNTS: linear inside its bucket, at most MAX
\(the open last bucket ends at MAX).  nil when COUNTS is empty."
  (let* ((n (apply #'+ (append counts nil))) (rank (* q n)) (cum 0) (i 0) (edges drgnx-gc-census-buckets) result)
    (when (> n 0)
      (while (not result)
        (let ((c (aref counts i)))
          (if (and (> c 0) (>= (+ cum c) rank))
              (let ((lo (if (= i 0) 0 (aref edges (1- i)))) (hi (if (< i (length edges)) (aref edges i) max)))
                (setq result (min max (+ lo (* (- hi lo) (/ (- rank cum) (float c)))))))
            (setq cum (+ cum c) i (1+ i)))))
      (float result))))

(defun drgnx-gc-census--summary (lines)
  "LINES summed up: (:count :max :total-s :buckets :p50 :p95 :p99 :felt :origins), origins as (ORIGIN . SHARE)."
  (let ((counts (make-vector (1+ (length drgnx-gc-census-buckets)) 0)) (max 0.0) (total 0.0) (felt 0) (origins nil)
        (n (length lines)))
    (dolist (l lines)
      (let ((ms (plist-get l :pause_ms)))
        (cl-incf (aref counts (drgnx-gc-census--bucket ms)))
        (setq max (max max ms) total (+ total ms))
        (when (eq (plist-get l :felt) t) (cl-incf felt))
        (cl-incf (alist-get (intern (or (plist-get l :origin) "auto")) origins 0))))
    (list :count n :max (float max) :total-s (/ total 1000.0) :buckets counts
          :p50 (drgnx-gc-census--percentile counts 0.5 max) :p95 (drgnx-gc-census--percentile counts 0.95 max)
          :p99 (drgnx-gc-census--percentile counts 0.99 max) :felt felt
          :origins (sort (mapcar (lambda (o) (cons (car o) (/ (cdr o) (float n)))) origins)
                         (lambda (a b) (string< (car a) (car b)))))))

(defun drgnx-gc-census--slope (lines)
  "(SLOPE . POINTS): the least-squares slope of pause against live heap over LINES, in ms per 100 MB, and how many
collections it is fitted on.  SLOPE is nil under two collections or when the heap never changed."
  (let* ((pts (delq nil (mapcar (lambda (l) (let ((x (plist-get (plist-get l :heap) :live_mb)) (y (plist-get l :pause_ms)))
                                              (and (numberp x) (numberp y) (cons x y))))
                                lines)))
         (n (length pts)))
    (cons (when (>= n 2)
            (let* ((mx (/ (apply #'+ (mapcar #'car pts)) (float n)))
                   (my (/ (apply #'+ (mapcar #'cdr pts)) (float n)))
                   (sxx (apply #'+ (mapcar (lambda (p) (expt (- (car p) mx) 2)) pts)))
                   (sxy (apply #'+ (mapcar (lambda (p) (* (- (car p) mx) (- (cdr p) my))) pts))))
              (and (> sxx 0) (* 100 (/ sxy sxx)))))
          n)))

(cl-defun drgnx-gc-census-report (&key (days 7))
  "What the census recorded in the newest DAYS day files: a plist.
:days, one plist per day, oldest first: :date and `drgnx-gc-census--summary''s :count :max (ms) :total-s :buckets
\(counts in `drgnx-gc-census-buckets') :p50 :p95 :p99 (ms, from the buckets) :felt :origins ((ORIGIN . SHARE)…).
:all, the same over every day; :slope (ms per 100 MB of live heap, least squares) and :points; :heap and :heap-at,
the live heap by type after the last collection; :dropped and :error, this session's; :directory."
  (let* ((per-day (mapcar (lambda (f) (cons (file-name-base f) (drgnx-gc-census--read-day f)))
                          (drgnx-gc-census--day-files days)))
         (all (apply #'append (mapcar #'cdr per-day)))
         (slope (drgnx-gc-census--slope all))
         (newest (car (last all))))
    (list :days (mapcar (lambda (d) (cons :date (cons (car d) (drgnx-gc-census--summary (cdr d))))) per-day)
          :all (drgnx-gc-census--summary all) :slope (car slope) :points (cdr slope)
          :heap (plist-get newest :heap) :heap-at (plist-get newest :at)
          :dropped drgnx-gc-census--dropped :error drgnx-gc-census--last-error
          :directory (drgnx-gc-census-directory))))

(defun drgnx-gc-census--ms (x)
  "X ms as text, or \"-\"."
  (if x (format "%.1f" x) "-"))

(defun drgnx-gc-census--row (label s)
  "One table row: LABEL and the summary S."
  (format "%-12s %6d %7s %7s %7s %7s %8.2f %5d  %s" label (plist-get s :count) (drgnx-gc-census--ms (plist-get s :max))
          (drgnx-gc-census--ms (plist-get s :p50)) (drgnx-gc-census--ms (plist-get s :p95))
          (drgnx-gc-census--ms (plist-get s :p99)) (plist-get s :total-s) (plist-get s :felt)
          (mapconcat (lambda (o) (format "%s %d%%" (car o) (round (* 100 (cdr o))))) (plist-get s :origins) ", ")))

(defun drgnx-gc-census-report-text (report)
  "REPORT (`drgnx-gc-census-report') as plain text."
  (let ((days (plist-get report :days)) (heap (plist-get report :heap)))
    (concat
     (format "GC census: every garbage collection's pause (ms), by day\nFolder: %s\n\n" (plist-get report :directory))
     (if (null days)
         (concat "No collections recorded yet.  Turn the census on: (:gc-census t) in speed.eld (at every start), or\n"
                 "M-x drgnx-gc-census-mode for this session.\n")
       (concat
        (format "%-12s %6s %7s %7s %7s %7s %8s %5s  %s\n" "Day" "Count" "Max" "p50" "p95" "p99" "Total s" "Felt"
                "Origins")
        (mapconcat (lambda (d) (drgnx-gc-census--row (plist-get d :date) d)) days "\n") "\n"
        (drgnx-gc-census--row "All" (plist-get report :all)) "\n\n"
        (format "%-12s%s\n" "Buckets (ms)"
                (mapconcat (lambda (e) (format "%6s" e))
                           (append (mapcar (lambda (e) (format "<%d" e)) drgnx-gc-census-buckets) '(">=1000")) ""))
        (mapconcat (lambda (d) (format "%-12s%s" (plist-get d :date)
                                       (mapconcat (lambda (c) (format "%6d" c)) (plist-get d :buckets) "")))
                   days "\n")
        "\n\n"
        (format "Slope: %s (%d collections)\n"
                (if (plist-get report :slope) (format "%.1f ms per 100 MB of live heap" (plist-get report :slope)) "-")
                (plist-get report :points))
        (if (not heap) ""
          (format "Live heap after the last collection (%s): %s MB, %s MB free\n  %s\n"
                  (plist-get report :heap-at) (plist-get heap :live_mb) (plist-get heap :free_mb)
                  (mapconcat (lambda (k) (format "%s %s" (string-remove-suffix "_mb" (symbol-name k))
                                                 (plist-get heap (intern (concat ":" (symbol-name k))))))
                             drgnx-gc-census--heap-keys " · ")))))
     (format "\nThis session: %d collections not recorded (the ring was full)%s\n" (plist-get report :dropped)
             (if (plist-get report :error) (format "; the last write failed: %s" (plist-get report :error)) "")))))

(defconst drgnx-gc-census-buffer-name "*drgnx GC census*")

(defvar drgnx-gc-census--shown nil "The text of the report the view shows, for Copy.")

(defun drgnx-gc-census-copy ()
  "Copy the report the view shows."
  (kill-new (or drgnx-gc-census--shown ""))
  (message "Copied the GC census report"))

(defun drgnx-gc-census-show ()
  "Show the GC census report: pauses by day, origins, the slope and the live heap; Copy puts it on the clipboard."
  (interactive)
  (require 'drgnx-ui-kit)
  (let ((buffer (get-buffer-create drgnx-gc-census-buffer-name)))
    (setq drgnx-gc-census--shown (drgnx-gc-census-report-text (drgnx-gc-census-report)))
    (with-current-buffer buffer
      (special-mode)
      (buffer-disable-undo)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (drgnx-ui-insert-button "Copy" #'drgnx-gc-census-copy :help "Copy the report, to paste it elsewhere")
        (insert "\n\n" drgnx-gc-census--shown))
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

(defun drgnx-gc-census-register-commands ()
  "The census's command."
  (drgnx-command-define 'gc-census :category "Help" :title "GC Census" :command #'drgnx-gc-census-show :menu '("Help")
                        :doc "Every garbage collection's pause, origin and live heap, by day (once the census is on)"))

(provide 'drgnx-gc-census)
;;; drgnx-gc-census.el ends here
