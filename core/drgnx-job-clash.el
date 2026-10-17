;;; drgnx-job-clash.el --- Clashes in a job: found by fixed rules, settled by a reviewer and the user -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Runs in the hub (drgnx-hub.el requires it).  Fixed rules, no model judgment (that is the reviewer's):
;; - contradiction: a build and a won't-build of one subject among a job's current or proposed decisions — the
;;   user's side wins at once (no card); agents' are a clash card;
;; - proposed: an agent's decision outside its own task;
;; - against-decision: a task in review whose branch changes files a won't-build decision covers (its review waits);
;; - stale: an agent whose last two coordination writes were held (behind the log) — a stalled card;
;; - overlap: a task in review that changes files another open task changes too — advisory.
;; Each clash is carded once (its key in the job's data).  See docs/develop/coordination.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-coord)
(require 'drgnx-job)

(defvar drgnx-job-clash-long-lines 200 "A clash whose diff is longer than this many lines gets a long review.")

(defun drgnx-job-clash--subject (s)
  "S as compared: lower case, spaces collapsed, trimmed."
  (downcase (string-trim (replace-regexp-in-string "[[:space:]]+" " " (or s "")))))

(defun drgnx-job-clash--paths (v)
  "A decision's paths (text: commas, spaces or lines between them) as a list."
  (cond ((stringp v) (split-string v "[,[:space:]]+" t))
        ((or (consp v) (vectorp v)) (mapcar (lambda (p) (format "%s" p)) (append v nil)))))

(defun drgnx-job-clash--covers-p (path pattern)
  "Does PATTERN cover PATH (relative to the repository)?  A directory (ending in / or not), a file, or a glob with `*'."
  (cond ((string-match-p "[*?]" pattern)
         (let ((re (wildcard-to-regexp pattern)))
           (or (string-match-p re path) (and (not (string-search "/" pattern)) (string-match-p re (file-name-nondirectory path))))))
        (t (let ((dir (file-name-as-directory (directory-file-name pattern))))
             (or (equal path (directory-file-name pattern)) (string-prefix-p dir path))))))

(defun drgnx-job-clash--seen-p (job key)
  (member key (plist-get (plist-get (drgnx-coord-job job) :data) :clashes)))

(defun drgnx-job-clash--remember (job key)
  (let ((data (plist-get (drgnx-coord-job job) :data)))
    (drgnx-coord-job-set job :data (plist-put data :clashes (cons key (plist-get data :clashes))))))

(defun drgnx-job-clash--side (label d)
  (list :label label :text (format "#%s %s: %s" (plist-get d :n) (plist-get d :kind) (plist-get d :subject))
        :decision (plist-get d :n) :agent (plist-get d :author) :task (plist-get d :task) :reason (plist-get d :reason)))

(defun drgnx-job-clash--card (job key rule subject title sides &optional task more)
  "A clash card of JOB about SUBJECT, once per KEY: RULE, TITLE, SIDES, MORE data; long or short."
  (unless (drgnx-job-clash--seen-p job key)
    (drgnx-job-clash--remember job key)
    (drgnx-job--card job task "clash" title nil
                     (append (list :key key :rule rule :subject (drgnx-job-clash--subject subject) :sides sides
                                   :size (drgnx-job-clash--size job rule subject more))
                             more))))

(defun drgnx-job-clash--size (job rule subject more)
  "`long' for work against a decision, a diff over `drgnx-job-clash-long-lines', or a SUBJECT that clashed before;
else `short'."
  (if (or (equal rule "against-decision")
          (> (or (plist-get more :lines) 0) drgnx-job-clash-long-lines)
          (seq-find (lambda (c) (and (equal (plist-get c :kind) "clash")
                                     (equal (plist-get (plist-get c :data) :subject) (drgnx-job-clash--subject subject))))
                    (drgnx-coord-cards job "settled")))
      "long" "short"))

;;;; The rules

(defun drgnx-job-clash--decisions (job)
  (seq-filter (lambda (d) (member (plist-get d :status) '("current" "proposed"))) (drgnx-coord-decisions-since 0 job)))

(defun drgnx-job-clash--contradictions (job)
  (let ((ds (drgnx-job-clash--decisions job)))
    (dolist (b (seq-filter (lambda (d) (equal (plist-get d :kind) "build")) ds))
      (dolist (w (seq-filter (lambda (d) (equal (plist-get d :kind) "wont-build")) ds))
        (when (equal (drgnx-job-clash--subject (plist-get b :subject)) (drgnx-job-clash--subject (plist-get w :subject)))
          (let ((bu (equal (plist-get b :author) "user")) (wu (equal (plist-get w :author) "user")))
            (cond
             ((and bu wu))                           ; the user's own two: theirs to sort out
             ((or bu wu)                             ; the user's decision stands
              (let ((other (if bu w b)))
                (drgnx-coord-decide :kind "replaces" :subject (plist-get other :subject) :replaces (plist-get other :n)
                                    :author "user" :reason "the user's decision stands" :job job :seen (drgnx-coord-version))))
             (t (drgnx-job-clash--card job (format "contradiction:%s:%s" (min (plist-get b :n) (plist-get w :n)) (max (plist-get b :n) (plist-get w :n)))
                                       "contradiction" (plist-get b :subject) (format "build or not: %s" (plist-get b :subject))
                                       (list (drgnx-job-clash--side "A" b) (drgnx-job-clash--side "B" w)))))))))))

(defun drgnx-job-clash--proposed (job)
  (dolist (d (drgnx-job-clash--decisions job))
    (when (equal (plist-get d :status) "proposed")
      (drgnx-job-clash--card job (format "proposed:%s" (plist-get d :n)) "proposed" (plist-get d :subject)
                             (format "%s proposes: %s %s" (plist-get d :author) (plist-get d :kind) (plist-get d :subject))
                             (list (append (drgnx-job-clash--side "A" d) (list :text (format "record it: #%s %s: %s" (plist-get d :n) (plist-get d :kind) (plist-get d :subject))))
                                   (list :label "B" :text "leave it out" :decision (plist-get d :n)))))))

(defun drgnx-job-clash--stale (job)
  (dolist (s (drgnx-agents-sessions))
    (when (and (equal (drgnx-agent-session-job s) job) (not (eq (drgnx-agent-session-status s) 'exited))
               (>= (drgnx-coord-held (drgnx-agent-session-id s)) 2))
      (drgnx-coord-note-held (drgnx-agent-session-id s) nil)
      (drgnx-job--card job (drgnx-agent-session-task s) "stalled"
                       "its coordination writes are held: it keeps acting on an old decision log"))))

(defun drgnx-job-clash-scan (job)
  "Look for clashes in JOB (the hub's tick, and after an agent wrote)."
  (when (member (plist-get (drgnx-coord-job job) :status) '("running" "paused"))
    (drgnx-job-clash--contradictions job)
    (drgnx-job-clash--proposed job)
    (drgnx-job-clash--stale job)))

;;;; Before a review: work against a decision, overlaps

(defun drgnx-job-clash--changed (job n)
  "The files task N's branch changes against JOB's branch."
  (pcase (drgnx-job--git (drgnx-job--repo job) "diff" "--name-only" (format "job/%s...job/%s-%d" job job n))
    (`(0 . ,out) (split-string out "\n" t))))

(defun drgnx-job-clash--lines (job n)
  (pcase (drgnx-job--git (drgnx-job--repo job) "diff" "--numstat" (format "job/%s...job/%s-%d" job job n))
    (`(0 . ,out) (apply #'+ 0 (mapcar (lambda (l) (pcase (split-string l "\t") (`(,a ,b . ,_) (+ (string-to-number a) (string-to-number b))) (_ 0)))
                                      (split-string out "\n" t))))
    (_ 0)))

(defvar drgnx-job-clash--checked (make-hash-table :test #'equal) "Task → its branch head when last checked.")

(defun drgnx-job-clash-before-review (job task)
  "`drgnx-job-before-review-functions': non-nil when TASK (a store plist) of JOB must wait — it changes what a
won't-build decision covers (a clash card, the review after it).  An overlap with another open task is a card too,
advisory.  The diffs are looked at once per branch head."
  (let* ((n (plist-get task :n))
         (head (cdr (drgnx-job--git (drgnx-job--repo job) "rev-parse" (format "job/%s-%d" job n))))
         (files (unless (equal (gethash (plist-get task :id) drgnx-job-clash--checked) head)
                  (puthash (plist-get task :id) head drgnx-job-clash--checked)
                  (drgnx-job-clash--changed job n))))
    ;; overlaps: advisory, once per pair
    (dolist (other (drgnx-coord-tasks job))
      (when (and (/= (plist-get other :n) n) (member (plist-get other :status) '("claimed" "running" "needs-input" "in-review")))
        (when-let* ((same (seq-intersection files (drgnx-job-clash--changed job (plist-get other :n)))))
          (let ((key (format "overlap:%d:%d" (min n (plist-get other :n)) (max n (plist-get other :n)))))
            (unless (drgnx-job-clash--seen-p job key)
              (drgnx-job-clash--remember job key)
              (drgnx-job--card job (plist-get task :id) "overlap"
                               (format "Task %d and Task %d both change %s" n (plist-get other :n) (string-join same ", "))
                               nil (list :key key :files same)))))))
    ;; against a current won't-build: wait, once per branch head
    (let ((hits (seq-filter #'cdr
                            (mapcar (lambda (d) (cons d (seq-filter (lambda (f) (seq-some (lambda (p) (drgnx-job-clash--covers-p f p))
                                                                                          (drgnx-job-clash--paths (plist-get d :paths))))
                                                                    files)))
                                    (seq-filter (lambda (d) (and (equal (plist-get d :kind) "wont-build") (equal (plist-get d :status) "current")
                                                                 (plist-get d :paths)))
                                                (drgnx-job-clash--decisions job))))))
      (when hits
        (let* ((d (car (car hits))) (touched (cdr (car hits))) (key (format "against:%s:%s" (plist-get task :id) head)))
          (drgnx-job-clash--card job key "against-decision" (plist-get d :subject)
                                 (format "Task %d changes what #%s says will not be built: %s" n (plist-get d :n) (string-join touched ", "))
                                 (list (append (drgnx-job-clash--side "A" d) (list :text (format "the decision stands: #%s won't build %s" (plist-get d :n) (plist-get d :subject))))
                                       (list :label "B" :text (format "the change stands (Task %d)" n) :task (plist-get task :id) :agent (plist-get task :agent)))
                                 (plist-get task :id) (list :files touched :lines (drgnx-job-clash--lines job n)))))
      ;; it waits while a clash card about it is open
      (seq-find (lambda (c) (and (equal (plist-get c :kind) "clash") (equal (plist-get c :task) (plist-get task :id))))
                (drgnx-coord-cards job "open")))))

(add-hook 'drgnx-job-before-review-functions #'drgnx-job-clash-before-review)
(add-hook 'drgnx-job-tick-functions #'drgnx-job-clash-scan)

(provide 'drgnx-job-clash)
;;; drgnx-job-clash.el ends here
