;;; drgnx-watchdog-doctor.el --- The doctor's freezes and gc checks, and the watchdog's quiet notices -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Two checks in the group "Speed", each with a verdict beside its severity: `freezes' judges the stalls of today
;; against the 100 ms goal (by non-GC time), `gc' the GC row against its target and the live heap against its
;; budget.  Their facts (`:watchdog') are read from the watchdog's day files in (drgnx-state-dir)/watchdog/, so the
;; checks work without Nidhogg's Lisp; without the watchdog in this Emacs `freezes' says what to update.
;; The notices: source `watchdog', at most once per signature per day for a felt stall of 1 s or more or a killed
;; hang (called from `nidhogg-watchdog-record-functions' while the drain runs: numbers and one `drgnx-notify', no
;; I/O, no prompt), and the GC at most once a day from an idle timer.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-doctor)
(require 'drgnx-notice)
(require 'drgnx-timer)
(require 'drgnx-owner)
(require 'drgnx-watchdog)

(defvar nidhogg-watchdog-record-functions)
(defvar nidhogg-watchdog-log-directory)
(defvar nidhogg-watchdog-mode)
(defvar drgnx-heap-budgets)
(declare-function nidhogg-watchdog-gc-row "nidhogg-watchdog-gc")
(declare-function drgnx-heap-check "drgnx-heap")
(declare-function drgnx-heap-dir "drgnx-heap")

(defconst drgnx-watchdog-doctor-goal-ms 100 "The goal: no stall of this many milliseconds of non-GC time.")
(defconst drgnx-watchdog-doctor-felt-warn-ms 1000 "A felt stall this long (non-GC) is a warning and a notice.")
(defconst drgnx-watchdog-doctor-package-warn 10 "A package with this many stalls in a day is a warning.")
(defconst drgnx-watchdog-doctor-update-fix
  "run `drgnx update': it builds the newest Nidhogg (docs/guide/speed.md, \"The watchdog\")"
  "What to do when this Emacs has no watchdog.")

;;;; Reading the day

(defun drgnx-watchdog-doctor--read-day (file)
  "FILE's JSON lines as alists; a line that does not parse is skipped.  Never signals."
  (when (and (file-readable-p file) (< (file-attribute-size (file-attributes file)) (* 32 1024 1024)))
    (let (out)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
        (dolist (l (split-string (buffer-string) "\n" t))
          (let ((v (condition-case nil (json-parse-string l :object-type 'alist :null-object nil :false-object nil)
                     (error nil))))
            (when (consp v) (push v out)))))
      (nreverse out))))

(defun drgnx-watchdog-doctor--num (line key)
  "LINE's number at KEY, else 0."
  (let ((v (alist-get key line))) (if (numberp v) v 0)))

(defun drgnx-watchdog-doctor--summarize (lines)
  "The day LINES (alists) as a plist: :stalls (non-GC time of the goal or more), :slow (250 ms or more), :felt,
:felt-max (ms), :killed, :longest (ms), :typing-slow (percent of typing commands at 16 ms or more, or nil) and
:packages, rows (PACKAGE :count :total-ms :felt) by total, biggest first."
  (let ((stalls 0) (slow 0) (felt 0) (felt-max 0) (killed 0) (longest 0) (pkgs nil) (typing (make-vector 9 0)))
    (dolist (l lines)
      (let ((type (alist-get 'type l)))
        (cond
         ((equal type "stall")
          (let ((ms (drgnx-watchdog-doctor--num l 'nongc_ms)) (f (eq (alist-get 'felt l) t)))
            (when (alist-get 'killed l) (setq killed (1+ killed)))
            (when (>= ms drgnx-watchdog-doctor-goal-ms)
              (setq stalls (1+ stalls) longest (max longest ms))
              (when (>= ms 250) (setq slow (1+ slow)))
              (when f (setq felt (1+ felt) felt-max (max felt-max ms)))
              (let* ((culprit (alist-get 'culprit l))
                     (pkg (or (and (consp culprit) (alist-get 'pkg culprit)) "unsampled"))
                     (row (or (assoc pkg pkgs) (car (push (list pkg :count 0 :total-ms 0 :felt 0) pkgs)))))
                (setf (plist-get (cdr row) :count) (1+ (plist-get (cdr row) :count))
                      (plist-get (cdr row) :total-ms) (+ ms (plist-get (cdr row) :total-ms)))
                (when f (setf (plist-get (cdr row) :felt) (1+ (plist-get (cdr row) :felt))))))))
         (t (let ((h (alist-get 'typing (alist-get 'histograms l))))
              (when (and (vectorp h) (= (length h) 9))
                (dotimes (i 9) (aset typing i (+ (aref typing i) (if (numberp (aref h i)) (aref h i) 0))))))))))
    (let ((all (apply #'+ (append typing nil))) (over (apply #'+ (nthcdr 3 (append typing nil)))))
      (list :stalls stalls :slow slow :felt felt :felt-max felt-max :killed killed :longest longest
            :typing-slow (and (> all 0) (/ (round (* 1000.0 (/ over (float all)))) 10.0))
            :packages (sort (mapcar (lambda (r) (cons (car r) (cdr r))) pkgs)
                            (lambda (a b) (> (plist-get (cdr a) :total-ms) (plist-get (cdr b) :total-ms))))))))

(defun drgnx-watchdog-doctor--module (package)
  "The name of the drgnx module that enables PACKAGE, or nil."
  (when-let* ((m (drgnx-owner-module-for-package package))) (symbol-name m)))

(defun drgnx-watchdog-doctor--largest-owner ()
  "The largest owner of the newest heap audit snapshot as (OWNER MB MODULE), or nil when there is none."
  (when (and (fboundp 'drgnx-heap-dir) (file-directory-p (drgnx-heap-dir)))
    (when-let* ((file (car (last (directory-files (drgnx-heap-dir) t "\\`heap-[0-9-]+\\.json\\'")))))
      (condition-case nil
          (let* ((snap (with-temp-buffer
                         (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
                         (json-parse-buffer :object-type 'alist :null-object nil :false-object nil)))
                 (top (seq-first (alist-get 'owners snap))))
            (and top (list (alist-get 'owner top) (/ (round (/ (* 10.0 (alist-get 'bytes top)) 1048576)) 10.0)
                           (alist-get 'module top))))
        (error nil)))))

(defun drgnx-watchdog-doctor--live-mb (lines)
  "The live heap (MB) of the newest `gc' line in LINES (the day's alists) that has one, or nil.  The watchdog's own
session wrote it; this process's heap says nothing about that session (`drgnx doctor' is a batch Emacs)."
  (cl-some (lambda (l)
             (let ((mb (and (equal (alist-get 'type l) "gc") (alist-get 'live_mb (alist-get 'heap l)))))
               (and (numberp mb) mb)))
           (reverse lines)))

(defun drgnx-watchdog-doctor--heap (live-mb)
  "LIVE-MB (the watchdog session's live heap) against its budget: (:live-mb MB :budget-mb MB-or-nil :over BOOL), or nil."
  (when (and (numberp live-mb) (require 'drgnx-heap nil t))
    (let* ((rows (drgnx-heap-check (list :heap (list :live-mb live-mb))))
           (row (seq-find (lambda (r) (eq (plist-get r :measure) 'live)) rows)))
      (and row (list :live-mb (plist-get row :value-mb) :budget-mb (plist-get row :cap)
                     :over (eq (plist-get row :state) 'over))))))

(defconst drgnx-watchdog-doctor-recent-s 900
  "A day file written within this many seconds shows the watchdog running (it writes a summary every ten minutes).")

(defun drgnx-watchdog-doctor--recent-p (file)
  "Non-nil when FILE was written within `drgnx-watchdog-doctor-recent-s'."
  (when-let* ((a (file-attributes file)))
    (< (float-time (time-since (file-attribute-modification-time a))) drgnx-watchdog-doctor-recent-s)))

(defun drgnx-watchdog-doctor-facts ()
  "The `:watchdog' fact: nil without the watchdog in this Emacs, else (:running BOOL :wanted BOOL :today SUMMARY :gc ROW
:heap HEAP :largest OWNER), read from the day files.  `drgnx doctor' is a batch Emacs, so :running is the setting
being on and a day file written in the last quarter hour (or the mode, in a live session), and :heap the live heap the
watchdog's session recorded.  Never signals."
  (when (drgnx-watchdog-available-p)
    (condition-case err
        (let* ((dir (drgnx-watchdog-log-directory))
               (file (expand-file-name (format-time-string "%F.jsonl") dir))
               (lines (drgnx-watchdog-doctor--read-day file))
               (nidhogg-watchdog-log-directory dir)
               (gc (and (require 'nidhogg-watchdog-gc nil t) (fboundp 'nidhogg-watchdog-gc-row)
                        (nidhogg-watchdog-gc-row)))
               (wanted (and (drgnx-watchdog--wanted-p) t)))
          (list :running (or (bound-and-true-p nidhogg-watchdog-mode)
                             (and wanted (drgnx-watchdog-doctor--recent-p file) t))
                :wanted wanted
                :today (drgnx-watchdog-doctor--summarize lines)
                :gc gc
                :heap (drgnx-watchdog-doctor--heap (or (drgnx-watchdog-doctor--live-mb lines)
                                                       (plist-get (plist-get (plist-get gc :week) :heap) :live_mb)))
                :largest (drgnx-watchdog-doctor--largest-owner)))
      (error (list :error (error-message-string err))))))

;;;; The checks

(defun drgnx-watchdog-doctor--seconds (ms) (format "%.1f" (/ ms 1000.0)))

(defun drgnx-watchdog-doctor--freezes (facts)
  "The `freezes' check on FACTS: (STATUS DETAIL FIX)."
  (let ((w (plist-get facts :watchdog)))
    (cond
     ((null w) (list 'info "the watchdog needs Nidhogg 31.1-nidhogg.N or newer" drgnx-watchdog-doctor-update-fix))
     ((plist-get w :error) (list 'info (format "the watchdog's day could not be read: %s" (plist-get w :error)) nil))
     ((and (not (plist-get w :running)) (plist-get w :wanted))
      (list 'info "no recent watchdog record (is drgnx running?)"
            "start drgnx: the watchdog writes a summary every ten minutes (docs/guide/speed.md)"))
     ((not (plist-get w :running))
      (list 'info "the watchdog is off" "turn it on: set drgnx-speed-watchdog to t (docs/guide/speed.md)"))
     (t
      (let* ((s (plist-get w :today)) (stalls (plist-get s :stalls)) (typing (plist-get s :typing-slow))
             (pkgs (plist-get s :packages))
             (top (car pkgs))
             (typing-text (if typing (format "typing ≥ 16 ms: %s %%" typing) "typing ≥ 16 ms: no data"))
             (heavy (seq-find (lambda (p) (>= (plist-get (cdr p) :count) drgnx-watchdog-doctor-package-warn)) pkgs)))
        (cond
         ((and (zerop stalls) (zerop (plist-get s :killed)))
          (list 'ok (format "meets: no stall over %d ms today; %s" drgnx-watchdog-doctor-goal-ms typing-text) nil))
         ((or (>= (plist-get s :felt-max) drgnx-watchdog-doctor-felt-warn-ms) heavy (> (plist-get s :killed) 0))
          (let* ((p (or (and (>= (plist-get s :felt-max) drgnx-watchdog-doctor-felt-warn-ms)
                             (seq-find (lambda (r) (> (plist-get (cdr r) :felt) 0)) pkgs))
                        heavy top))
                 (name (car p)) (row (cdr p)) (module (and p (drgnx-watchdog-doctor--module name))))
            (list 'warn
                  (format "missed: %d stalls over %d ms today (longest %s s, %d felt%s); %s" stalls
                          drgnx-watchdog-doctor-goal-ms (drgnx-watchdog-doctor--seconds (plist-get s :longest))
                          (plist-get s :felt)
                          (if (> (plist-get s :killed) 0) (format ", %d hang killed" (plist-get s :killed)) "")
                          typing-text)
                  (if p
                      (format "Show Freezes (Help → Show Freezes) — %s%s stalled %d times, %s s in all, %d felt."
                              name (if module (format " (module %s)" module) "") (plist-get row :count)
                              (drgnx-watchdog-doctor--seconds (plist-get row :total-ms)) (plist-get row :felt))
                    "Show Freezes (Help → Show Freezes) shows the killed hang"))))
         (t
          (list 'info
                (format "missed: %d stalls over %d ms today, none felt (longest %s ms); %s; most: %s; %s" stalls
                        drgnx-watchdog-doctor-goal-ms (round (plist-get s :longest))
                        (string-join (mapcar (lambda (p) (format "%s %d" (car p) (plist-get (cdr p) :count)))
                                             (seq-take pkgs 3))
                                     ", ")
                        (if top (car top) "unsampled") typing-text)
                nil))))))))

(defun drgnx-watchdog-doctor--gc (facts)
  "The `gc' check on FACTS: (STATUS DETAIL FIX)."
  (let* ((w (plist-get facts :watchdog)) (gc (plist-get w :gc)) (heap (plist-get w :heap))
         (days (plist-get gc :days)) (day (car (last days)))
         (target (plist-get gc :target)) (gc-max (plist-get gc :gc-max))
         (max-ms (and day (plist-get day :max))) (p95 (plist-get (plist-get gc :week) :p95))
         (over-max (and (numberp max-ms) (numberp gc-max) (>= max-ms gc-max)))
         (over-heap (plist-get heap :over)) (largest (plist-get w :largest)))
    (cond
     ((null w) (list 'info "the watchdog needs Nidhogg 31.1-nidhogg.N or newer" drgnx-watchdog-doctor-update-fix))
     ((plist-get w :error) (list 'info (format "the GC row could not be read: %s" (plist-get w :error)) nil))
     ((and (null day) (not over-heap)) (list 'info "no collection recorded yet" nil))
     ((or over-max over-heap)
      (list 'warn
            (format "missed: %s; live heap %s MB%s"
                    (if over-max (format "a collection took %d ms (limit %d ms)" (round max-ms) gc-max)
                      "the live heap is over its budget")
                    (or (plist-get heap :live-mb) "?")
                    (if (plist-get heap :budget-mb) (format " of %s MB" (plist-get heap :budget-mb)) ""))
            (format "Heap Audit (Help → Heap Audit) — live heap %s MB, budget %s MB%s"
                    (or (plist-get heap :live-mb) "?") (or (plist-get heap :budget-mb) "not set")
                    (if largest (format "; largest: %s %s MB%s" (nth 0 largest) (nth 1 largest)
                                        (if (nth 2 largest) (format " (module %s)" (nth 2 largest)) ""))
                      "; run an audit to see the largest owner"))))
     ((plist-get gc :meets)
      (list 'ok (format "meets: p95 %s ms (target %s ms), longest %d ms today"
                        (or p95 "-") target (round (or max-ms 0)))
            nil))
     (t (list 'info (format "missed: p95 %s ms (target %s ms), longest %d ms today, live heap %s MB"
                            (or p95 "not enough collections yet") target (round (or max-ms 0))
                            (or (plist-get heap :live-mb) "?"))
              nil)))))

(drgnx-doctor-define 'freezes :group "Speed" :doc "Emacs answers within 100 ms (the stall watchdog's day)"
                     :check #'drgnx-watchdog-doctor--freezes)
(drgnx-doctor-define 'gc :group "Speed" :doc "Garbage collections meet their target and the heap its budget"
                     :check #'drgnx-watchdog-doctor--gc)

;;;; The notices

(defvar drgnx-watchdog-doctor--noticed nil
  "(DAY . SIGNATURES): the signatures already noticed on DAY (YYYY-MM-DD); another day starts afresh.")
(defvar drgnx-watchdog-doctor--gc-noticed nil "The day (YYYY-MM-DD) the GC was last noticed, or nil.")
(defvar drgnx-watchdog-doctor--gc-checked 0 "When the GC row was last read (float time).")

(defun drgnx-watchdog-doctor-note (record)
  "Notice the stall RECORD (a plist, from `nidhogg-watchdog-record-functions') once per signature per day: only a
felt stall of 1 s or more, or a killed hang.  Numbers and one `drgnx-notify'; never prompts."
  (let ((ms (or (plist-get record :nongc-ms) 0)))
    (when (or (plist-get record :killed)
              (and (plist-get record :felt) (>= ms drgnx-watchdog-doctor-felt-warn-ms)))
      (let* ((day (format-time-string "%F"))
             (culprit (plist-get record :culprit))
             (sig (or (plist-get record :signature) (plist-get culprit :pkg) "unsampled"))
             (pkg (or (and (consp culprit) (or (plist-get culprit :pkg) (alist-get 'pkg culprit))) "unsampled")))
        (unless (equal (car drgnx-watchdog-doctor--noticed) day)
          (setq drgnx-watchdog-doctor--noticed (list day)))
        (unless (member sig (cdr drgnx-watchdog-doctor--noticed))
          (setcdr drgnx-watchdog-doctor--noticed (cons sig (cdr drgnx-watchdog-doctor--noticed)))
          (drgnx-notify 'watchdog 'warn
                        (format "Emacs %s for %.1f s in %s" (if (plist-get record :killed) "hung" "stalled")
                                (/ ms 1000.0) pkg)
                        :id (format "stall-%s" sig) :echo nil :command 'freezes
                        :fix "Show Freezes (Help → Show Freezes) says where the time went"))))))

(defun drgnx-watchdog-doctor--gc-facts ()
  "The `:watchdog' fact for the `gc' check alone: the GC row and, from it, the live heap.  It reads neither the day's
file nor the heap audit snapshot (an idle timer calls it).  Never signals."
  (when (drgnx-watchdog-available-p)
    (condition-case err
        (let* ((nidhogg-watchdog-log-directory (drgnx-watchdog-log-directory))
               (gc (and (require 'nidhogg-watchdog-gc nil t) (fboundp 'nidhogg-watchdog-gc-row)
                        (nidhogg-watchdog-gc-row))))
          (list :gc gc :heap (drgnx-watchdog-doctor--heap (plist-get (plist-get (plist-get gc :week) :heap) :live_mb))))
      (error (list :error (error-message-string err))))))

(defun drgnx-watchdog-doctor--gc-check ()
  "Once a day, notice a collection at the limit or a heap over its budget; read the day files at most every 30
minutes.  An idle timer's function."
  (let ((day (format-time-string "%F")) (now (float-time)))
    (when (and (not (equal drgnx-watchdog-doctor--gc-noticed day))
               (> (- now drgnx-watchdog-doctor--gc-checked) 1800))
      (setq drgnx-watchdog-doctor--gc-checked now)
      (let* ((facts (drgnx-watchdog-doctor--gc-facts))
             (r (drgnx-watchdog-doctor--gc (list :watchdog facts))))
        (when (eq (car r) 'warn)
          ;; the snapshot is read only to word the warning
          (setq r (drgnx-watchdog-doctor--gc
                   (list :watchdog (append facts (list :largest (drgnx-watchdog-doctor--largest-owner))))))
          (setq drgnx-watchdog-doctor--gc-noticed day)
          (drgnx-notify 'watchdog 'warn (format "Garbage collection: %s" (nth 1 r)) :id 'gc :echo nil
                        :command 'heap-audit :fix (nth 2 r)))))))

(defun drgnx-watchdog-doctor-start ()
  "The notice source, the record hook and the daily GC look; `drgnx-watchdog-mode' calls it."
  (drgnx-notice-define-source 'watchdog :title "Freezes" :command 'freezes)
  (add-hook 'nidhogg-watchdog-record-functions #'drgnx-watchdog-doctor-note)
  (drgnx-timer-start 'watchdog-gc 120 #'drgnx-watchdog-doctor--gc-check :idle t :repeat t :owner :core))

(defun drgnx-watchdog-doctor-stop ()
  "Undo `drgnx-watchdog-doctor-start'."
  (remove-hook 'nidhogg-watchdog-record-functions #'drgnx-watchdog-doctor-note)
  (drgnx-timer-cancel 'watchdog-gc))

(provide 'drgnx-watchdog-doctor)
;;; drgnx-watchdog-doctor.el ends here
