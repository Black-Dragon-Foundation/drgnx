;;; drgnx-pkg-progress.el --- Packages: a run's progress file, and the generations a running drgnx uses -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx sync', `upgrade' and `rollback' with `--progress FILE' replace FILE, by rename, with one JSON object (at most
;; 1 KiB) at each step of the run: start, plan, download / unpack / byte (per package), swap, lock, native (per file),
;; done.  The plan of each swap also goes to FILE.plan.json, written once by rename before that swap and never by a
;; later step, so a reader that missed the plan object (FILE moved on) still finds it; `seq' grows per swap of the run
;; (an upgrade whose smoke test fails swaps twice).  The editor watches FILE's directory and reads it; a running drgnx
;; repoints its load path into the plan's generation before the swap deletes the old copies.
;;
;; Generations a running drgnx uses stay: each session writes <state>/elpa-in-use/<pid>.eld, (:pid P :start S
;; :generations (N…)), and snapshot rotation keeps every generation a live one names (`drgnx-pkg-generations-in-use').
;; Writing the progress never fails the run.  See docs/guide/packages.md, "Progress".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)

(declare-function drgnx-pkg--lock-live-p "drgnx-pkg" (stamp))

(defvar drgnx-pkg--progress-file nil "This run's progress file (`--progress FILE'), or nil: no progress is written.")

(defvar drgnx-pkg--plan-seq 0 "The plans this run wrote (a plan per swap).")

(defvar drgnx-pkg--step-function nil
  "For tests: called with each step of a run (a symbol) and its plist, after the step is written.")

(defconst drgnx-pkg-progress-max-bytes 1024 "The largest progress object.")

(defun drgnx-pkg--json-string (s)
  "S as text JSON can carry: a raw byte becomes U+FFFD."
  (let ((m (string-to-multibyte s)))
    (if (seq-some (lambda (c) (>= c #x3fff80)) m)
        (apply #'string (mapcar (lambda (c) (if (>= c #x3fff80) #xfffd c)) m))
      m)))

(defun drgnx-pkg--json-value (v)
  "V as a JSON value: nil null, t true, :false false, a symbol its name, a list or a vector an array (an empty one:
a vector)."
  (cond ((null v) :null)
        ((memq v '(t :false)) v)
        ((stringp v) (drgnx-pkg--json-string v))
        ((numberp v) v)
        ((symbolp v) (drgnx-pkg--json-string (symbol-name v)))
        ((or (listp v) (vectorp v)) (vconcat (mapcar #'drgnx-pkg--json-value v)))
        (t (drgnx-pkg--json-string (format "%s" v)))))

(defun drgnx-pkg--json-text (step plist &optional max)
  "The JSON object {\"step\": STEP, …PLIST}, UTF-8 (a unibyte string); with MAX bytes, its long lists are dropped
\(warnings first) until it fits."
  (let* ((object (cons :step (cons (symbol-name step)
                                   (let (out) (while plist (push (pop plist) out) (push (drgnx-pkg--json-value (pop plist)) out))
                                        (nreverse out)))))
         (text (json-serialize object)))
    (dolist (key '(:warnings :replaces :removes :adds :tickets))
      (when (and max (plist-member object key) (> (length text) max))
        (setq object (let (out) (while object (let ((k (pop object)) (v (pop object))) (unless (eq k key) (push k out) (push v out))))
                          (nreverse out))
              text (json-serialize object))))
    text))

(defun drgnx-pkg--progress-write (file text)
  "Replace FILE with TEXT (UTF-8 bytes), by rename: a reader sees the old object or the new one, never half of one.
No fsync: a step is replaced by the next one within moments."
  (drgnx-file-write-text file (decode-coding-string text 'utf-8) :fsync nil))

(defun drgnx-pkg-progress (step &rest plist)
  "Report STEP (a symbol) of the run, with PLIST, to the progress file when there is one.  Never fails the run."
  (when drgnx-pkg--progress-file
    (condition-case nil
        (drgnx-pkg--progress-write drgnx-pkg--progress-file (drgnx-pkg--json-text step plist drgnx-pkg-progress-max-bytes))
      (error nil)))
  (when drgnx-pkg--step-function (apply drgnx-pkg--step-function step plist)))

(defun drgnx-pkg-progress-plan (generation replaces removes adds)
  "Announce the next swap: GENERATION holds the copies of the package directories REPLACES and REMOVES (names
\"magit-4.1\") the swap takes away; ADDS are the new ones.  FILE.plan.json first, then the plan step, both with the
same `seq'."
  (let ((plist (list :seq (setq drgnx-pkg--plan-seq (1+ drgnx-pkg--plan-seq)) :generation generation
                     :replaces (vconcat replaces) :removes (vconcat removes) :adds (vconcat adds))))
    (when drgnx-pkg--progress-file
      (condition-case nil
          (drgnx-pkg--progress-write (concat drgnx-pkg--progress-file ".plan.json") (drgnx-pkg--json-text 'plan plist))
        (error nil)))
    (apply #'drgnx-pkg-progress 'plan plist)))

;;;; What a swap changes

(defun drgnx-pkg--dir-package (dir)
  "The package name and version of the package directory name DIR (\"magit-4.1\"): (NAME . VERSION), or nil."
  (when (string-match "\\`\\(.+\\)-\\([0-9][^-]*\\)\\'" dir)
    (cons (match-string 1 dir) (match-string 2 dir))))

(defun drgnx-pkg--package-dirs (dir)
  "The package directories in DIR (an elpa directory): their names, sorted."
  (and (file-directory-p dir)
       (sort (seq-filter (lambda (d) (and (drgnx-pkg--dir-package d) (file-directory-p (expand-file-name d dir))))
                         (directory-files dir nil "\\`[^.]"))
             #'string<)))

(defun drgnx-pkg--dirs-change (from to)
  "What making the elpa directory TO's package directories those of FROM changes: (REPLACES REMOVES ADDS), names of
directories — a package of TO at another version in FROM is replaced, one FROM lacks removed, one TO lacks added."
  (let* ((old (drgnx-pkg--package-dirs to)) (new (drgnx-pkg--package-dirs from))
         (old-names (mapcar (lambda (d) (car (drgnx-pkg--dir-package d))) old))
         (new-names (mapcar (lambda (d) (car (drgnx-pkg--dir-package d))) new))
         replaces removes adds)
    (dolist (d old)
      (unless (member d new)
        (if (member (car (drgnx-pkg--dir-package d)) new-names) (push d replaces) (push d removes))))
    (dolist (d new)
      (unless (member (car (drgnx-pkg--dir-package d)) old-names) (push d adds)))
    (list (nreverse replaces) (nreverse removes) (nreverse adds))))

;;;; Generations a running drgnx uses

(defun drgnx-pkg-in-use-dir () (expand-file-name "elpa-in-use/" (drgnx-state-dir)))

(defun drgnx-pkg-generations-in-use (&optional sweep)
  "The generations a running drgnx uses: those named by the files of `drgnx-pkg-in-use-dir' whose pid and start
time are a live process (`drgnx-pkg--lock-live-p').  With SWEEP, a file of a session that is gone (or that does not
read) is deleted."
  (let (out)
    (dolist (f (and (file-directory-p (drgnx-pkg-in-use-dir)) (directory-files (drgnx-pkg-in-use-dir) t "\\.eld\\'")))
      (let* ((data (plist-get (ignore-errors (drgnx-file-read f)) :data))
             (pid (plist-get data :pid)) (start (plist-get data :start)))
        (if (and (natnump pid) (numberp start) (drgnx-pkg--lock-live-p (format "%d %f" pid start)))
            (dolist (n (plist-get data :generations)) (when (natnump n) (cl-pushnew n out)))
          (when sweep (ignore-errors (delete-file f))))))
    (sort out #'<)))

(defun drgnx-pkg-copies-p ()
  "Non-nil when the file system of the packages directory makes full copies (no reflinks or clones): each change then
copies the packages twice (the staging copy and the generation)."
  (let* ((dir (drgnx-data-dir)))
    (make-directory dir t)
    (let* ((a (make-temp-file (expand-file-name "clone-probe-" dir))) (b (concat a "-copy")))
      (unwind-protect
          (not (and (executable-find "cp")
                    (eql 0 (call-process "cp" nil nil nil (if (eq system-type 'darwin) "-c" "--reflink=always") a b))))
        (ignore-errors (delete-file a))
        (ignore-errors (delete-file b))))))

(provide 'drgnx-pkg-progress)
;;; drgnx-pkg-progress.el ends here
