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

(defun drgnx-job-clash--side (label d &optional text)
  ;; one line: an agent's subject never reads as a line of the reviewer's prompt
  (list :label label :text (replace-regexp-in-string "[\n\r]+" " " (or text (format "#%s %s: %s" (plist-get d :n) (plist-get d :kind) (plist-get d :subject))))
        :decision (plist-get d :n) :agent (plist-get d :author) :task (plist-get d :task) :reason (plist-get d :reason)))

(defun drgnx-job-clash--card (job key rule subject title sides &optional task more)
  "A clash card of JOB about SUBJECT, once per KEY: RULE, TITLE, SIDES, MORE data; long or short."
  (unless (drgnx-job-clash--seen-p job key)
    (drgnx-job-clash--remember job key)
    (drgnx-job--card job task "clash" title nil
                     (append (list :key key :rule rule :subject (drgnx-job-clash--subject subject) :sides sides
                                   :size (drgnx-job-clash--size job rule subject more))
                             more))
    (drgnx-job-clash--ensure-reviewers job)))

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
  "A build and a won't-build of one subject among JOB's decisions.  The user's side stands at once — the other is
replaced, once, however many of the user's decisions it contradicts; two agents' are a clash card, once.  The numbers
of the decisions in a card's contradiction (`drgnx-job-clash--proposed' leaves them to it)."
  (let* ((ds (drgnx-job-clash--decisions job)) (wont (make-hash-table :test #'equal)) replaced carded)
    (dolist (w (seq-filter (lambda (d) (equal (plist-get d :kind) "wont-build")) ds))
      (let ((key (drgnx-job-clash--subject (plist-get w :subject))))
        (puthash key (append (gethash key wont) (list w)) wont)))
    (dolist (b (seq-filter (lambda (d) (equal (plist-get d :kind) "build")) ds))
      (dolist (w (gethash (drgnx-job-clash--subject (plist-get b :subject)) wont))
        (let ((bu (equal (plist-get b :author) "user")) (wu (equal (plist-get w :author) "user")))
          (cond
           ((and bu wu))                           ; the user's own two: theirs to sort out
           ((or bu wu)                             ; the user's decision stands
            (let ((other (if bu w b)))
              (unless (memq (plist-get other :n) replaced)
                (push (plist-get other :n) replaced)
                (drgnx-coord-decide :kind "replaces" :subject (plist-get other :subject) :replaces (plist-get other :n)
                                    :author "user" :reason "the user's decision stands" :job job :seen (drgnx-coord-version)))))
           ((or (memq (plist-get b :n) replaced) (memq (plist-get w :n) replaced)))
           (t (push (plist-get b :n) carded) (push (plist-get w :n) carded)
              (drgnx-job-clash--card job (format "contradiction:%s:%s" (min (plist-get b :n) (plist-get w :n)) (max (plist-get b :n) (plist-get w :n)))
                                     "contradiction" (plist-get b :subject) (format "build or not: %s" (plist-get b :subject))
                                     (list (drgnx-job-clash--side "A" b) (drgnx-job-clash--side "B" w))))))))
    carded))

(defun drgnx-job-clash--proposed (job &optional skip)
  "An agent's decision outside its own task is a card — unless its number is in SKIP (it has a card already)."
  (dolist (d (drgnx-job-clash--decisions job))
    (when (and (equal (plist-get d :status) "proposed") (not (memq (plist-get d :n) skip)))
      (drgnx-job-clash--card job (format "proposed:%s" (plist-get d :n)) "proposed" (plist-get d :subject)
                             (format "%s proposes: %s %s" (plist-get d :author) (plist-get d :kind) (plist-get d :subject))
                             (list (drgnx-job-clash--side "A" d (format "record it: #%s %s: %s" (plist-get d :n) (plist-get d :kind) (plist-get d :subject)))
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
    (drgnx-job-clash--proposed job (drgnx-job-clash--contradictions job))
    (drgnx-job-clash--stale job)
    (drgnx-job-clash--ensure-reviewers job)))

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
    ;; overlaps: advisory, once per pair (looked at once per branch head, like the rest)
    (dolist (other (and files (drgnx-coord-tasks job)))
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
                                 (list (drgnx-job-clash--side "A" d (format "the decision stands: #%s won't build %s" (plist-get d :n) (plist-get d :subject)))
                                       (list :label "B" :text (format "the change stands (Task %d)" n) :task (plist-get task :id) :agent (plist-get task :agent)))
                                 (plist-get task :id) (list :files touched :lines (drgnx-job-clash--lines job n)))))
      ;; it waits while a clash card about it is open
      (seq-find (lambda (c) (and (equal (plist-get c :kind) "clash") (equal (plist-get c :task) (plist-get task :id))))
                (drgnx-coord-cards job "open")))))

;;;; The reviewer recommends; the user's choice is a decision

(defvar drgnx-job-clash-auto-accept nil
  "Non-nil: a short clash's recommendation is accepted as soon as it comes, without the user.")

(defvar drgnx-job-clash--starts (make-hash-table :test #'equal) "(JOB . CARD) → reviewers started for that clash (this hub run).")

(defun drgnx-job-clash--reviewer (card)
  "The live reviewer of clash CARD, or nil."
  (seq-find (lambda (s) (let ((r (gethash (drgnx-agent-session-id s) drgnx-job--reviewers)))
                          (and (consp r) (eql (plist-get r :clash) card) (not (eq (drgnx-agent-session-status s) 'exited)))))
            (drgnx-agents-sessions)))

(defun drgnx-job-clash--said (s &optional since-user)
  "What S's agent said (since the last prompt, with SINCE-USER)."
  (let ((entries (drgnx-agent-session-entries s)))
    (when since-user
      (when-let* ((pos (seq-position (reverse entries) 'user (lambda (e type) (eq (plist-get e :type) type)))))
        (setq entries (last entries pos))))
    (mapconcat (lambda (e) (or (plist-get e :text) "")) (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) entries) "")))

(defun drgnx-job-clash--prompt (card &optional asks)
  "Clash CARD as its reviewer reads it (ASKS: what the user wants to discuss)."
  (let* ((c (drgnx-coord-card card)) (d (plist-get c :data)))
    (concat (format "[drgnx clash %s] %s: %s\n\n" card (plist-get d :rule) (plist-get c :title))
            (mapconcat (lambda (side) (concat (format "%s: %s" (plist-get side :label) (plist-get side :text))
                                              (if-let* ((r (plist-get side :reason))) (format "\nIts reason:\n%s" (drgnx-job--quote r)) "")))
                       (plist-get d :sides) "\n")
            (when (equal (plist-get d :size) "long")              ; a long review reads what the agents said
              (mapconcat (lambda (side)
                           (when-let* ((s (and (plist-get side :agent) (drgnx-agents-get (plist-get side :agent))))
                                       (said (drgnx-job-clash--said s)))
                             (format "\n\nThe agent of %s said lately:\n%s" (plist-get side :label)
                                     (drgnx-job--quote (substring said (max 0 (- (length said) 4000)))))))
                         (plist-get d :sides) ""))
            (and asks (format "\n\nThe user asks:\n%s" (drgnx-job--quote asks)))
            "\n\nRecommend one side. Answer with a last line RECOMMEND: A, RECOMMEND: B, or RECOMMEND: neither: why.")))

(defun drgnx-job-clash--start-reviewer (job card &optional asks)
  "A reviewer for clash CARD of JOB, in the job's worktree (the review policy): role `review', `review-long' for a
long clash when it has a route."
  (let* ((long (equal (plist-get (plist-get (drgnx-coord-card card) :data) :size) "long"))
         (profile (car (drgnx-job-route (if (and long (alist-get 'review-long (drgnx-job--routes))) 'review-long 'review))))
         (s (drgnx-agents-start profile (drgnx-job--job-tree job) nil job)) (sid (drgnx-agent-session-id s)))
    (puthash (cons job card) (1+ (gethash (cons job card) drgnx-job-clash--starts 0)) drgnx-job-clash--starts)
    (puthash sid (list :clash card) drgnx-job--reviewers)
    (drgnx-coord-card-set card :data (plist-put (plist-put (copy-sequence (plist-get (drgnx-coord-card card) :data)) :reviewer sid)   ; Discuss opens its transcript
                                                :reviewer-gone nil))
    (puthash sid (drgnx-job-clash--prompt card asks) drgnx-job--prompts)
    (drgnx-job--session-changed s)
    s))

(defun drgnx-job-clash--ensure-reviewers (job)
  "Every open clash of JOB without a recommendation has a reviewer: started at most twice per hub run (once, then
once more if it is lost — a restarted hub's included).  After that the card says `:reviewer-gone'."
  (dolist (c (drgnx-coord-cards job "open"))
    (when (and (equal (plist-get c :kind) "clash") (not (plist-get (plist-get c :data) :recommendation))
               (not (drgnx-job-clash--reviewer (plist-get c :id))))
      (if (< (gethash (cons job (plist-get c :id)) drgnx-job-clash--starts 0) 2)
          (drgnx-job-clash--start-reviewer job (plist-get c :id))
        (unless (plist-get (plist-get c :data) :reviewer-gone)
          (drgnx-coord-card-set (plist-get c :id) :data (plist-put (copy-sequence (plist-get c :data)) :reviewer-gone t))
          (drgnx-job--changed job))))))

(defun drgnx-job-clash--recommendation (s)
  "Reviewer S's last answer's recommendation: (:side \"A\"|\"B\"|nil :why TEXT), or nil when it gave none."
  (let ((text (drgnx-job-clash--said s t)) (found nil) (start 0))
    (while (string-match "^RECOMMEND: *\\(A\\|B\\|neither\\)\\_>[:,]? *\\(.*\\)$" text start)
      (setq found (list :side (and (not (equal (match-string 1 text) "neither")) (match-string 1 text))
                        :why (string-trim (match-string 2 text)))
            start (match-end 0)))
    found))

(defun drgnx-job-clash--answered (job reviewer s)
  "`drgnx-job-clash-answer-functions': the reviewer's recommendation goes on its card (accepted at once for a short
clash when `drgnx-job-clash-auto-accept'); an answer with none says so (`:no-recommendation')."
  (let* ((card (plist-get reviewer :clash)) (c (drgnx-coord-card card)) (rec (drgnx-job-clash--recommendation s)))
    (when (equal (plist-get c :state) "open")
      (drgnx-coord-card-set card :data (let ((d (copy-sequence (plist-get c :data))))
                                         (if rec (plist-put (plist-put d :recommendation rec) :no-recommendation nil)
                                           (plist-put d :no-recommendation t))))
      (drgnx-job--changed job)
      (when (and rec drgnx-job-clash-auto-accept (plist-get rec :side) (equal (plist-get (plist-get c :data) :size) "short"))
        (run-at-time 0 nil (lambda () (with-demoted-errors "drgnx job: %S" (drgnx-job-card-act card "accept"))))))))

(defun drgnx-job-clash--settle (job card side)
  "The user chose SIDE (\"A\" or \"B\") of clash CARD (a plist) of JOB: a decision of the user's, which every agent
of the job hears; its reviewer ends."
  (let* ((d (plist-get card :data)) (sides (plist-get d :sides))
         (other (seq-find (lambda (s) (not (equal (plist-get s :label) side))) sides))
         (first (car sides))
         (decide (lambda (&rest args) (apply #'drgnx-coord-decide :author "user" :job job :seen (drgnx-coord-version) args))))
    (pcase (plist-get d :rule)
      ("contradiction"
       (funcall decide :kind "replaces" :subject (plist-get d :subject) :replaces (plist-get other :decision)
                :reason (format "the user chose %s" side)))
      ("proposed"
       (let ((p (seq-find (lambda (x) (eql (plist-get x :n) (plist-get first :decision))) (drgnx-coord-decisions-since 0 job))))
         (if (equal side "A")
             (funcall decide :kind (plist-get p :kind) :subject (plist-get p :subject) :task (plist-get p :task) :paths (plist-get p :paths)
                      :replaces (plist-get p :n) :reason "the user recorded it")
           (funcall decide :kind "replaces" :subject (plist-get p :subject) :replaces (plist-get p :n) :reason "the user left it out"))))
      ("against-decision"
       (if (equal side "A")
           (drgnx-job--retry job (plist-get card :task)
                             (format "Your branch changes what decision #%s says will not be built (%s): revert your changes to %s, commit, then call complete_task."
                                     (plist-get first :decision) (plist-get d :subject) (string-join (plist-get d :files) ", ")))
         (funcall decide :kind "replaces" :subject (plist-get d :subject) :replaces (plist-get first :decision)
                  :reason "the user let the change stand"))))
    (when-let* ((r (drgnx-job-clash--reviewer (plist-get card :id)))) (drgnx-agents-kill r))))

(defun drgnx-job-clash--act (card action arg)
  "`drgnx-job-card-action-functions': a clash card's Accept, Pick A, Pick B and Discuss (ARG: the user's text)."
  (when (equal (plist-get card :kind) "clash")
    (let ((job (plist-get card :job)) (id (plist-get card :id)))
      (pcase action
        ("discuss" (if-let* ((r (drgnx-job-clash--reviewer id)))
                       (progn (drgnx-agents-send r (format "The user asks:\n%s" (drgnx-job--quote (format "%s" (or arg "")))))
                              (puthash (drgnx-agent-session-id r) t drgnx-job--reviewing))   ; its answer is read again
                     (drgnx-job-clash--start-reviewer job id (format "%s" (or arg ""))))
         t)
        ("accept" (let ((side (plist-get (plist-get (plist-get card :data) :recommendation) :side)))
                    (unless side (user-error "The reviewer has not recommended a side"))
                    (drgnx-job-clash--settle job card side)
                    t))
        ("pick-a" (drgnx-job-clash--settle job card "A") t)
        ("pick-b" (drgnx-job-clash--settle job card "B") t)))))

(add-hook 'drgnx-job-clash-answer-functions #'drgnx-job-clash--answered)
(add-hook 'drgnx-job-card-action-functions #'drgnx-job-clash--act)
(add-hook 'drgnx-job-before-review-functions #'drgnx-job-clash-before-review)
(add-hook 'drgnx-job-tick-functions #'drgnx-job-clash-scan)

(provide 'drgnx-job-clash)
;;; drgnx-job-clash.el ends here
