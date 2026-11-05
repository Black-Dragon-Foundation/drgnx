;;; drgnx-work-review.el --- The Work space's review view and the second reviewer (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The review view (`v') is where you decide whether an agent's work stands.  It opens with the agent's decisions, those
;; from the brief first, then its own, then those it needs your call on, each with what the hub computed from git of its
;; commits and the later hunks that overlap its lines (`decisions/effects'; labelled "computed", never guessed).  Then it
;; says where the plan stands, what the agent did and what it spent, and shows every file it edited as hunks against the
;; branch it was cut from (`work/files', `work/hunks').  On a hunk `a' accepts the file's change as it is now (a review
;; mark with the diff's hash, for the merge gate) and `D' rejects it (the agent is told, in a queued message, and the file
;; is marked pending).  Nothing here merges or pushes: merges stay on their cards.
;; `V' starts a second reviewer, which sees the code and not the author's conclusions, through `job/propose' like every
;; dispatch from the Work space.  Loaded by tools/work-space (drgnx-work-space.el); defines no module.
;; See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-trail)
  (load (expand-file-name "drgnx-work-trail" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-state-dir "drgnx-paths")
(declare-function drgnx-file-write-text "drgnx-file")
(declare-function drgnx-work-map--card-face "drgnx-work-map")
(declare-function drgnx-work-map--state "drgnx-work-map")
(declare-function drgnx-work-map--field "drgnx-work-map")
(declare-function drgnx-work-lens-map-buffer "drgnx-work-board")
(declare-function drgnx-work-lens-string "drgnx-work-map")
(declare-function drgnx-work-trail--agent-sid "drgnx-work-trail")
(declare-function drgnx-work-trail--cwd "drgnx-work-trail")
(declare-function drgnx-work-code-one-line "drgnx-work-code")
(defvar drgnx-work-lens--map)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)

(defvar drgnx-work-review-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of a review view.  The key profiles bind them (`drgnx-command-define' with this map).")

(define-derived-mode drgnx-work-review-mode special-mode "Work review"
  "The Work space's review view: an agent's decisions with what they computed to, then what it did, as hunks."
  (setq-local truncate-lines t cursor-type nil tab-line-format '("" drgnx-work-map--lens)))

(defvar-local drgnx-work-review--session nil "The hub session under review.")
(defvar-local drgnx-work-review--decisions nil "The session's decisions, in the order they show.")
(defvar-local drgnx-work-review--effects nil "Alist decision id → `decisions/effects' answer.")
(defvar-local drgnx-work-review--files nil "The files the agent edited (`work/files').")
(defvar-local drgnx-work-review--diffs nil "Alist path → that file's unified diff (`work/hunks').")
(defvar-local drgnx-work-review--keys nil "The view's row keys.")

(defun drgnx-work-review-buffers ()
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-review-mode)) (buffer-list)))

;;;; Decisions

(defconst drgnx-work-review-origins
  '(("from-brief" . "from the brief") ("own" . "its own") ("needs-user" . "needs your call") ("from-text" . "from its text"))
  "The origins of a decision in the order they show, with their words.")

(defun drgnx-work-review--ordered (conclusions)
  "The decisions among CONCLUSIONS (findings are the trail's), those from the brief first, then its own, then those it
needs your call on; within an origin, in the order they were made."
  (let ((ds (seq-filter (lambda (c) (equal (plist-get c :kind) "decision")) conclusions)))
    (apply #'append
           (mapcar (lambda (o) (seq-filter (lambda (c) (equal (plist-get c :origin) (car o))) ds))
                   drgnx-work-review-origins))))

(defun drgnx-work-review-decision-text (c effects)
  "The rows of decision C: its number, origin and text, and what EFFECTS (the hub's `decisions/effects' answer, or nil
while it is on its way) computed: the commits that implement it and the later hunks that overlap its lines."
  (let* ((commits (plist-get effects :commits)) (later (plist-get effects :later_hunks)))
    (concat (format "⚑ %d  [%s]  %s\n" (plist-get c :n) (or (cdr (assoc (plist-get c :origin) drgnx-work-review-origins)) "")
                    (plist-get c :text))
            (cond
             ((null effects) "   computed: asking git…\n")
             (t (format "   computed: %s%s\n"
                        (if commits (format "%d commit%s (%s)" (length commits) (if (cdr commits) "s" "")
                                            (mapconcat (lambda (h) (substring h 0 (min 7 (length h)))) commits ", "))
                          "no commit yet")
                        (if later
                            (format " · %d later hunk%s overlap%s: %s" (length later) (if (cdr later) "s" "") (if (cdr later) "" "s")
                                    (mapconcat (lambda (h) (format "%s:%d–%d (%s)" (plist-get h :path) (car (plist-get h :lines))
                                                                   (cadr (plist-get h :lines))
                                                                   (substring (plist-get h :commit) 0 (min 7 (length (plist-get h :commit))))))
                                               later ", "))
                          " · no later hunk overlaps")))))))

;;;; Hunks

(defun drgnx-work-review-parse-hunks (diff)
  "The hunks of the unified DIFF: a list of plists (:header \"@@ -1,2 +1,2 @@\" :text \"…\"), :text holding the
hunk's lines with their newlines.  What comes before the first `@@' line is left out."
  (let (hunks cur)
    (dolist (line (split-string diff "\n"))
      (if (string-prefix-p "@@" line)
          (progn (when cur (push cur hunks)) (setq cur (list :header line :text "")))
        (when (and cur (not (string-empty-p line)))
          (setq cur (plist-put cur :text (concat (plist-get cur :text) line "\n"))))))
    (when cur (push cur hunks))
    (nreverse hunks)))

(defun drgnx-work-review--hunk-text (path i hunk)
  (let* ((body (plist-get hunk :text))
         (lines (mapcar (lambda (l) (propertize (concat "    " l "\n")
                                                'face (pcase (and (not (string-empty-p l)) (aref l 0))
                                                        (?+ 'diff-added) (?- 'diff-removed) (_ nil))))
                        (split-string body "\n" t)))
         (head (propertize (format "  %s  %s  (a accept · D reject)\n" path (plist-get hunk :header)) 'face 'drgnx-work-label)))
    (add-text-properties 0 (length head) (list 'drgnx-work-hunk (cons path i)) head)
    (concat head (apply #'concat lines))))

;;;; Rows

(defun drgnx-work-review--summary (map-buffer session)
  "Where the plan stands, what the agent did and what it spent, from the map's card of SESSION."
  (let* ((state (and (buffer-live-p map-buffer) (drgnx-work-map--state map-buffer)))
         (item (and state (drgnx-work-client-item state (concat "agent:" session)))))
    (if (null item)
        "the map holds no card for this agent\n"
      (let* ((f (lambda (k) (drgnx-work-map--field item k))) (p (funcall f :progress)) (e (funcall f :edits)))
        (concat (format "plan:   %s\n" (if p (format "%d of %d steps done" (car p) (cadr p)) "no plan steps recorded"))
                (format "did:    %s\n"
                        (mapconcat #'identity
                                   (delq nil (list (and e (format "edits %d files (+%d −%d)" (nth 0 e) (nth 1 e) (nth 2 e)))
                                                   (and (funcall f :reads) (format "reads %d" (funcall f :reads)))
                                                   (and (funcall f :conclusion) (format "last: %s" (funcall f :conclusion)))))
                                   " · "))
                (format "spent:  %s\n"
                        (mapconcat #'identity
                                   (delq nil (list (funcall f :spend) (and (funcall f :minutes) (format "%d min" (funcall f :minutes)))))
                                   " · ")))))))

(defun drgnx-work-review--build-keys ()
  (append '((:decisions))
          (mapcar (lambda (c) (list :decision (plist-get c :n))) drgnx-work-review--decisions)
          '((:summary) (:files))
          (apply #'append
                 (mapcar (lambda (f)
                           (let ((path (plist-get f :path)))
                             (cons (list :file path)
                                   (cl-loop for i below (length (drgnx-work-review-parse-hunks (or (cdr (assoc path drgnx-work-review--diffs)) "")))
                                            collect (list :hunk path i)))))
                         drgnx-work-review--files))))

(defun drgnx-work-review--render (key)
  (pcase (car key)
    (:decisions (propertize (format "Decisions · %d\n" (length drgnx-work-review--decisions)) 'face 'drgnx-work-label))
    (:decision (if-let* ((c (seq-find (lambda (c) (eql (plist-get c :n) (cadr key))) drgnx-work-review--decisions)))
                   (drgnx-work-review-decision-text c (cdr (assoc (plist-get c :id) drgnx-work-review--effects)))
                 "\n"))
    (:summary (concat (propertize "The work\n" 'face 'drgnx-work-label)
                      (drgnx-work-review--summary drgnx-work-lens--map drgnx-work-review--session)))
    (:files (propertize (format "Edited files · %d\n" (length drgnx-work-review--files)) 'face 'drgnx-work-label))
    (:file (let ((f (seq-find (lambda (f) (equal (plist-get f :path) (cadr key))) drgnx-work-review--files)))
             (propertize (format "%s  +%d −%d%s\n" (cadr key) (or (plist-get f :plus) 0) (or (plist-get f :minus) 0)
                                 (if (plist-get f :untracked) "  new" ""))
                         'drgnx-work-hunk (cons (cadr key) nil))))
    (:hunk (let ((hunks (drgnx-work-review-parse-hunks (or (cdr (assoc (cadr key) drgnx-work-review--diffs)) ""))))
             (drgnx-work-review--hunk-text (cadr key) (nth 2 key) (nth (nth 2 key) hunks))))
    (_ "\n")))

(drgnx-view-define 'work-review :render #'drgnx-work-review--render :slice drgnx-view-slice)

(cl-defun drgnx-work-review-install (buffer session &key decisions effects files diffs)
  "Make BUFFER the review of SESSION with these facts (any of them may still be nothing), drawn from scratch.
DECISIONS: the session's conclusions; EFFECTS: an alist decision id → `decisions/effects' answer; FILES: `work/files''
files; DIFFS: an alist path → diff."
  (with-current-buffer buffer
    (unless (derived-mode-p 'drgnx-work-review-mode)
      (drgnx-work-review-mode)
      (drgnx-view-attach 'work-review))
    (setq drgnx-work-review--session session drgnx-work-review--decisions (drgnx-work-review--ordered decisions)
          drgnx-work-review--effects effects drgnx-work-review--files files drgnx-work-review--diffs diffs
          drgnx-work-review--keys (drgnx-work-review--build-keys) drgnx-work-lens-nav #'drgnx-work-review--nav)
    (drgnx-view-reset drgnx-view drgnx-work-review--keys)))

(defun drgnx-work-review--refresh ()
  (drgnx-work-review-install (current-buffer) drgnx-work-review--session
                             :decisions drgnx-work-review--decisions :effects drgnx-work-review--effects
                             :files drgnx-work-review--files :diffs drgnx-work-review--diffs))

(defun drgnx-work-review-open (map-buffer session)
  "The review of hub SESSION, made when there is none, with its facts asked of the hub: the decisions, then what git
computed of each, the edited files and their hunks.  Returns the buffer; it does not show itself."
  (let ((buffer (get-buffer-create (format "*drgnx work review: %s*" session))))
    (with-current-buffer buffer
      (unless (and (derived-mode-p 'drgnx-work-review-mode) (equal drgnx-work-review--session session))
        (drgnx-work-review-install buffer session))
      (setq drgnx-work-lens--map map-buffer drgnx-work-map--lens (drgnx-work-lens-string 'map))
      (drgnx-hub-call "work/conclusions" (list :session session)
                      (lambda (result _err)
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (setq drgnx-work-review--decisions (drgnx-work-review--ordered (plist-get result :conclusions)))
                            (drgnx-work-review--refresh)
                            (dolist (c drgnx-work-review--decisions)
                              (drgnx-hub-call "decisions/effects" (list :decision (plist-get c :id))
                                              (lambda (r err)
                                                (when (and (not err) (buffer-live-p buffer))
                                                  (with-current-buffer buffer
                                                    (push (cons (plist-get c :id) r) drgnx-work-review--effects)
                                                    (drgnx-view-dirty drgnx-view (list (list :decision (plist-get c :n)))))))))))))
      (drgnx-hub-call "work/files" (list :session session)
                      (lambda (result _err)
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (setq drgnx-work-review--files (plist-get result :files))
                            (drgnx-work-review--refresh)
                            (dolist (f drgnx-work-review--files)
                              (let ((path (plist-get f :path)))
                                (drgnx-hub-call "work/hunks" (list :session session :path path)
                                                (lambda (r err)
                                                  (when (and (not err) (buffer-live-p buffer))
                                                    (with-current-buffer buffer
                                                      (push (cons path (or (plist-get r :diff) "")) drgnx-work-review--diffs)
                                                      (drgnx-work-review--refresh)))))))))))
      buffer)))

;;;; Accept, reject

(defun drgnx-work-review--here ()
  "(PATH . HUNK-INDEX-OR-NIL) at point, or an error."
  (or (get-text-property (point) 'drgnx-work-hunk) (user-error "Point is not on a file or a hunk")))

(defun drgnx-work-review--accept (path)
  "Accept PATH's change as it is now: a review mark with the diff's hash (the merge gate compares it)."
  (let* ((diff (or (cdr (assoc path drgnx-work-review--diffs)) (user-error "%s: its diff is not here yet" path)))
         (hash (secure-hash 'sha1 diff)))
    (drgnx-hub-call "review/mark"
                    (list :agent drgnx-work-review--session :path path :state "accepted" :hash hash
                          :event (list :kind "accept" :summary (format "you accepted %s" path)
                                       :data (list :by "user" :path path :hash hash)))
                    (lambda (_r err) (message (if err "Work: %s" "Accepted %s: a review mark for the merge gate — nothing is merged")
                                              (or err path))))))

(defun drgnx-work-review--reject (path i)
  "Reject hunk I of PATH: the file is marked pending again and the agent is told, in a queued message, to take it back.
PATH and the hunk's header are the agent's words: they stay on the message's one line (`drgnx-work-code-one-line')."
  (let* ((diff (or (cdr (assoc path drgnx-work-review--diffs)) ""))
         (hunk (and i (nth i (drgnx-work-review-parse-hunks diff)))))
    (drgnx-hub-call "review/mark" (list :agent drgnx-work-review--session :path path :state "pending"
                                        :hash (secure-hash 'sha1 diff))
                    #'ignore)
    (drgnx-hub-call "agents/send"
                    (list :id drgnx-work-review--session
                          :text (format "I reject your change to %s%s. Please take it back and tell me what you changed instead."
                                        (drgnx-work-code-one-line path)
                                        (if hunk (format " (the hunk %s)" (drgnx-work-code-one-line (plist-get hunk :header))) "")))
                    #'ignore)
    (message "Work: %s is marked pending and the agent has been told" path)))

(defun drgnx-work-review-accept ()
  "Accept the file at point as its diff is now (a review mark for the merge gate); nothing is merged."
  (interactive)
  (drgnx-work-review--accept (car (drgnx-work-review--here))))

(defun drgnx-work-review-reject ()
  "Reject the hunk at point: the file goes back to pending and the agent is told (queued; it is not cancelled)."
  (interactive)
  (let ((here (drgnx-work-review--here))) (drgnx-work-review--reject (car here) (cdr here))))

(defun drgnx-work-review--nav (dir)
  "A key of the lens in a review: up and down move by rows; the others do nothing here."
  (pcase dir
    ((or 'left 'up) (forward-line -1))
    ((or 'right 'down) (forward-line 1)))
  t)

;;;; Showing it, and the second reviewer

(defun drgnx-work-review-show ()
  "The review of the selected agent, in this window."
  (interactive)
  (let ((sid (drgnx-work-trail--agent-sid)))
    (pop-to-buffer-same-window (drgnx-work-review-open (drgnx-work-lens-map-buffer) sid))))

(defun drgnx-work-review--plan (sid repo files)
  "The text of the plan for a second reviewer of SID's work in REPO: the files to read, and no word of the author's
conclusions.  The files' names are the author's: each stays on its own line (`drgnx-work-code-one-line'), so none adds
a task or a role."
  (concat (format "# Second review of %s's work\n\n" (drgnx-work-code-one-line sid))
          (format "**Repo:** %s\n\n" (drgnx-work-code-one-line repo))
          "### Task 1: Review the change\n\n**Role:** review\n\n"
          "Review the uncommitted and committed changes on the branch the agent worked on, against the branch it was cut from. "
          "Read the code yourself, run what you need to and say what is wrong or risky, with file and line. "
          "Do not edit anything.\n\n"
          (if files (concat "Files changed:\n\n" (mapconcat (lambda (f) (format "- %s" (drgnx-work-code-one-line f))) files "\n") "\n")
            "")))

(defun drgnx-work-review-second ()
  "Start a second reviewer on the selected agent's work, from another provider than the author's where the profile
allows: it is given the code and not the author's conclusions.  It starts an agent, so it goes through `job/propose'
like every dispatch from the Work space."
  (interactive)
  (let* ((sid (drgnx-work-trail--agent-sid))
         (repo (file-name-as-directory (expand-file-name (or (drgnx-work-trail--cwd sid) default-directory))))
         (files (and (derived-mode-p 'drgnx-work-review-mode) (mapcar (lambda (f) (plist-get f :path)) drgnx-work-review--files)))
         (dir (expand-file-name "work-space/reviews/" (drgnx-state-dir)))
         (file (expand-file-name (format "%s-%d.md" sid (floor (float-time))) dir)))
    (make-directory dir t)
    (drgnx-file-write-text file (drgnx-work-review--plan sid repo files))
    (drgnx-hub-call "job/propose" (list :plan file :repo repo)
                    (lambda (_r err) (message (if err "Work: the reviewer was not proposed: %s" "Work: a second reviewer is proposed (%s)")
                                              (or err (file-name-nondirectory file)))))))

(provide 'drgnx-work-review)
;;; drgnx-work-review.el ends here
