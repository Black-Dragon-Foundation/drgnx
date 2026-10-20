;;; drgnx-review.el --- Module tools/review: Review Branch — an agent reviews the branch, findings in a tab -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Review Branch asks an agent — the `review' route's profile, the one jobs use (docs/guide/jobs.md) — to review
;; this branch's changes against its base (origin/HEAD, main or master) before you push.  It works under the job
;; reviewer's policy: it may read, search and run read-only git; it never writes (anything else is asked of you,
;; as for any agent).  It answers one line per problem, FINDING: path:line: severity: what and why, and a verdict;
;; the panel's Review tab lists them, worst first — RET opens the line, Show Branch Diff the diff view.  The
;; session is an ordinary agent session: its transcript is in the agents view.  See docs/guide/git.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-file)                   ; `drgnx-file-truename': the model's paths, with no file name handler

(declare-function drgnx-diff-default-base "drgnx-diff")
(declare-function drgnx-diff-show "drgnx-diff")
(declare-function drgnx-job-route "drgnx-job")
(declare-function drgnx-job-policy "drgnx-job")
(declare-function drgnx-agents-start "drgnx-agents")
(declare-function drgnx-agents-free-p "drgnx-agents")
(declare-function drgnx-agents-deliver "drgnx-agents")
(declare-function drgnx-agent-session-id "drgnx-agents")
(declare-function drgnx-agent-session-entries "drgnx-agents")
(declare-function drgnx-agents-entry-text "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-paused "drgnx-agents")
(declare-function drgnx-agents-kill "drgnx-agents")
(declare-function drgnx-agents-get "drgnx-agents")
(declare-function drgnx-wb-define-tab "drgnx-area")
(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function drgnx-wb-editor-window "drgnx-wb")
(defvar drgnx-agents-request-functions)
(defvar drgnx-agents-changed-functions)

(defface drgnx-review-critical '((t :inherit error)) "A critical finding." :group 'drgnx)
(defface drgnx-review-important '((t :inherit warning)) "An important finding." :group 'drgnx)
(defface drgnx-review-minor '((t :inherit shadow)) "A minor finding." :group 'drgnx)

(defvar drgnx-review--runs (make-hash-table :test #'equal)
  "Session id → (:root :base :branch :head :state reviewing|done :prompted :result).")
(defvar drgnx-review--current nil "The session id the Review tab shows.")

(defconst drgnx-review--severities '("critical" "important" "minor"))

(defun drgnx-review-parse (text)
  "The FINDING: and VERDICT: lines of TEXT: (:findings ((:path :line :severity :text)…) :verdict pass|fail|nil),
worst first, then by path and line."
  (let ((findings nil) (verdict nil) (case-fold-search nil))
    (dolist (raw (split-string (or text "") "\n"))
      ;; as models write them: in a list, in bold or backticks, a capital severity, a line range
      (let ((l (replace-regexp-in-string "\\*\\*\\|`" "" (replace-regexp-in-string "\\`[-*>[:space:]]*\\(?:[0-9]+[.)][[:space:]]*\\)?" "" raw))))
        (cond
         ((string-match "\\`FINDING: *\\(.+?\\):\\([0-9]+\\)\\(?:-[0-9]+\\)?: *\\([A-Za-z]+\\): *\\(.+\\)$" l)
          (push (list :path (match-string 1 l) :line (string-to-number (match-string 2 l))
                      :severity (let ((s (downcase (match-string 3 l)))) (if (member s drgnx-review--severities) s "minor"))
                      :text (string-trim (match-string 4 l)))
                findings))
         ((string-match "VERDICT: *\\(pass\\|fail\\)" l) (setq verdict (intern (match-string 1 l)))))))
    (list :findings (sort (nreverse findings)
                          (lambda (a b)
                            (let ((sa (seq-position drgnx-review--severities (plist-get a :severity)))
                                  (sb (seq-position drgnx-review--severities (plist-get b :severity))))
                              (if (/= sa sb) (< sa sb)
                                (if (string= (plist-get a :path) (plist-get b :path)) (< (plist-get a :line) (plist-get b :line))
                                  (string< (plist-get a :path) (plist-get b :path)))))))
          :verdict verdict)))

(defun drgnx-review--prompt (base)
  (format "[drgnx review] Review this branch: the changes are `git diff %s...HEAD`. Report each problem on its own line \
as FINDING: <path>:<line>: <critical|important|minor>: <what is wrong and why>, paths relative to the repository root. \
End with VERDICT: pass or VERDICT: fail." base))

(defun drgnx-review--git (root &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory root)))
      (and (eql 0 (apply #'call-process "git" nil '(t nil) nil args)) (string-trim (buffer-string))))))

;;;; The session

(defun drgnx-review--answer-text (s)
  "What S said since drgnx's prompt: its agent entries after the last user entry."
  (let ((after nil))
    (dolist (e (drgnx-agent-session-entries s))
      (pcase (plist-get e :type)
        ('user (setq after nil))
        ('agent (push (drgnx-agents-entry-text e) after))))
    (string-join (nreverse after) "\n")))

(defun drgnx-review--turn-over-p (s)
  "Has S finished a turn since drgnx's prompt (a stop entry after the last user entry)?"
  (let ((over nil))
    (dolist (e (drgnx-agent-session-entries s))
      (pcase (plist-get e :type) ('user (setq over nil)) ('stop (setq over t))))
    over))

(defun drgnx-review--changed (s)
  "`drgnx-agents-changed-functions': a review session, once free, gets its prompt; free after its turn, its answer."
  (when-let* ((run (gethash (drgnx-agent-session-id s) drgnx-review--runs)))
    (when (eq (plist-get run :state) 'reviewing)
      (cond
       ;; ended or stopped before it answered: say so (never Reviewing… for good)
       ((or (eq (drgnx-agent-session-status s) 'exited) (drgnx-agent-session-paused s))
        (plist-put run :state 'done)
        (plist-put run :stopped t)
        (when (equal drgnx-review--current (drgnx-agent-session-id s)) (drgnx-review-refresh)))
       ((not (drgnx-agents-free-p s)))
       ((not (plist-get run :prompted))
        (when (drgnx-agents-deliver s (drgnx-review--prompt (plist-get run :base)))
          (plist-put run :prompted t)))
       ((drgnx-review--turn-over-p s)
        (plist-put run :result (drgnx-review-parse (drgnx-review--answer-text s)))
        (plist-put run :state 'done)
        (when (fboundp 'drgnx-agents-kill) (drgnx-agents-kill s))   ; answered: no idle agent left (its transcript stays)
        (when (equal drgnx-review--current (drgnx-agent-session-id s)) (drgnx-review-refresh)))))))

(defun drgnx-review--request (s method params _id)
  "`drgnx-agents-request-functions': a review session's routine reads are allowed by the review policy; it never writes."
  (when-let* ((run (gethash (drgnx-agent-session-id s) drgnx-review--runs)))
    (pcase method
      ("session/request_permission"
       (require 'drgnx-job)
       (when (eq (drgnx-job-policy "review" (plist-get params :toolCall) (plist-get run :root)) 'allow)
         (let ((opt (seq-find (lambda (o) (equal (plist-get o :kind) "allow_once")) (append (plist-get params :options) nil))))
           (and opt (list :result (list :outcome (list :outcome "selected" :optionId (plist-get opt :optionId))))))))
      ("fs/write_text_file" (list :error (list :code -32000 :message "a review only reads"))))))

;;;; The tab

(defvar drgnx-review-mode-map (make-sparse-keymap) "Keys come from the key profiles (review-* commands).")

(define-derived-mode drgnx-review-mode special-mode "Review"
  "The findings of Review Branch: RET opens the line."
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function (lambda (_ignore-auto _noconfirm) (drgnx-review-refresh))))

(defun drgnx-review--buffer ()
  (or (get-buffer "*drgnx review*")
      (with-current-buffer (get-buffer-create "*drgnx review*") (drgnx-review-mode) (current-buffer))))

(defun drgnx-review--check-head (run)
  "Ask git in the background where HEAD is now; the answer lands in RUN's :now and the tab is drawn again when
that changes whether HEAD has moved.  One check at a time; the summary never runs git itself.  A check asked for while
one runs is coalesced into one more check after it (the running one may have read HEAD before it moved), and only the
run's latest check (its :checking) sets :now: an older one's answer, come late, is stale."
  (if (process-live-p (plist-get run :checking))
      (plist-put run :recheck t)
    (plist-put run :recheck nil)
    (let* ((out (generate-new-buffer " *drgnx-review head*" t)) (default-directory (plist-get run :root)))
      (plist-put run :checking
                 (condition-case nil               ; the root may be gone by now
                     (make-process
                      :name "drgnx-review-head" :buffer out :noquery t :connection-type 'pipe
                      :command '("git" "rev-parse" "HEAD")
                      :sentinel (lambda (proc _event)
                                  (unless (process-live-p proc)
                                    (let ((now (and (eql 0 (process-exit-status proc))
                                                    (with-current-buffer out
                                                      (let ((s (string-trim (buffer-string)))) ; a sha only: stderr shares the buffer
                                                        (and (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" s) s))))))
                                      (kill-buffer out)
                                      (when (eq proc (plist-get run :checking))
                                        (when (and now (not (equal now (plist-get run :now))))
                                          (let ((was (drgnx-review--moved-p run)))
                                            (plist-put run :now now)
                                            (unless (eq was (drgnx-review--moved-p run))
                                              (when (equal (gethash drgnx-review--current drgnx-review--runs) run) (drgnx-review--draw)))))
                                        (when (and (plist-get run :recheck) (equal (gethash drgnx-review--current drgnx-review--runs) run))
                                          (drgnx-review--check-head run)))))))
                   (error (kill-buffer out) nil))))))

(defun drgnx-review--moved-p (run)
  (and (plist-get run :now) (not (equal (plist-get run :now) (plist-get run :head)))))

(defun drgnx-review--summary (run)
  (let* ((result (plist-get run :result)) (n (length (plist-get result :findings)))
         (head (format "%s vs %s" (plist-get run :branch) (plist-get run :base)))
         (moved (if (drgnx-review--moved-p run) "  (HEAD has moved since)" "")))
    (concat head " · "
            (cond ((eq (plist-get run :state) 'reviewing) "Reviewing…")
                  ((plist-get run :stopped) "the reviewer stopped before answering — see its transcript")
                  ((and (zerop n) (null (plist-get result :verdict))) "the reviewer gave no verdict — see its transcript")
                  (t (format "%d finding%s · %s" n (if (= n 1) "" "s") (or (plist-get result :verdict) "no verdict"))))
            moved)))

(defun drgnx-review-refresh ()
  "Draw the Review tab again."
  (interactive)
  (drgnx-review--draw)
  (when-let* ((run (drgnx-review--run))) (drgnx-review--check-head run)))

(defun drgnx-review--draw ()
  (with-current-buffer (drgnx-review--buffer)
    (let* ((inhibit-read-only t) (run (and drgnx-review--current (gethash drgnx-review--current drgnx-review--runs)))
           (line (line-number-at-pos))                       ; the reader keeps their row when the tab is drawn again
           (windows (mapcar (lambda (w) (cons w (line-number-at-pos (window-point w)))) (get-buffer-window-list nil nil t))))
      (erase-buffer)
      (if (null run) (insert "No review yet — run Review Branch.\n")
        (insert (propertize (drgnx-review--summary run) 'face 'bold) "\n\n")
        (dolist (f (plist-get (plist-get run :result) :findings))
          (let ((b (point)))
            (insert (propertize (format "%-10s" (plist-get f :severity)) 'face (intern (concat "drgnx-review-" (plist-get f :severity))))
                    (format "%s:%d" (plist-get f :path) (plist-get f :line)) "  " (plist-get f :text) "\n")
            (put-text-property b (point) 'drgnx-review-finding f))))
      (goto-char (point-min))
      (forward-line (1- line))
      (pcase-dolist (`(,w . ,l) windows)
        (set-window-point w (save-excursion (goto-char (point-min)) (forward-line (1- l)) (point)))))))

(defun drgnx-review--show ()
  (let ((b (drgnx-review--buffer)))
    (if (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'panel 'review b) (display-buffer b))
    b))

(defun drgnx-review-view ()
  "Review: Show Findings — the Review tab."
  (interactive)
  (drgnx-review-refresh)
  (drgnx-review--show))

(defun drgnx-review--run () (and drgnx-review--current (gethash drgnx-review--current drgnx-review--runs)))

(defun drgnx-review-visit ()
  "Open the finding at point: its file, at its line."
  (interactive)
  (let ((f (get-text-property (point) 'drgnx-review-finding)) (run (drgnx-review--run)))
    (unless (and f run) (user-error "No finding here"))
    ;; the path is the model's: resolved with no file name handler (`drgnx-file-truename'), checked, and opened by that
    ;; true name — `find-file' of the model's own name follows its links again, with handlers on; only a file inside
    (let ((file (drgnx-file-truename (plist-get f :path) (plist-get run :root))))
      (unless (and file (drgnx-file-inside-p file (plist-get run :root)))
        (user-error "%s is outside the repository" (plist-get f :path)))
      (unless (let ((file-name-handler-alist nil)) (file-exists-p file))
        (user-error "%s is not in the working tree" (plist-get f :path)))
      (let ((w (and (fboundp 'drgnx-wb-editor-window) (drgnx-wb-editor-window)))) (when (window-live-p w) (select-window w)))
      (find-file file)
      (goto-char (point-min))
      (forward-line (1- (max 1 (plist-get f :line)))))))

(defun drgnx-review-show-diff ()
  "Review: Show Branch Diff — the reviewed changes in the diff view, at the finding's file."
  (interactive)
  (let ((run (or (drgnx-review--run) (user-error "No review yet")))
        (f (get-text-property (point) 'drgnx-review-finding)))
    (drgnx-diff-show (list 'range (plist-get run :base) (or (plist-get run :head) "HEAD")) (plist-get run :root) (plist-get f :path))))

(defun drgnx-review-branch (&optional base)
  "Review Branch — an agent (the review route) reviews this branch against BASE (default: origin/HEAD, main or
master); its findings land in the Review tab."
  (interactive)
  (let* ((root (or (drgnx-review--git default-directory "rev-parse" "--show-toplevel")
                   (user-error "Not in a git repository")))
         (base (or base (drgnx-diff-default-base root) (user-error "No base branch: set origin/HEAD or create main")))
         (count (drgnx-review--git root "rev-list" "--count" (format "%s..HEAD" base))))
    (when (member count '(nil "0")) (user-error "Nothing to review against %s" base))
    (require 'drgnx-job)
    (require 'drgnx-agents)
    (let* ((s (drgnx-agents-start (car (drgnx-job-route 'review)) (file-name-as-directory root)))
           (sid (drgnx-agent-session-id s)))
      (puthash sid (list :root (file-name-as-directory root) :base base
                         :branch (or (drgnx-review--git root "rev-parse" "--abbrev-ref" "HEAD") "HEAD")
                         :head (drgnx-review--git root "rev-parse" "HEAD") :state 'reviewing :prompted nil :result nil)
               drgnx-review--runs)
      (setq drgnx-review--current sid)
      (drgnx-review-view)
      (drgnx-review--changed s)                            ; ready already: the prompt goes now
      s)))

(defun drgnx-review--teardown ()
  "Turned off: the reviewers still working are killed (the hooks that confine and feed them go with the module),
the runs are forgotten and the Review tab is closed."
  (maphash (lambda (sid run)
             (when (eq (plist-get run :state) 'reviewing)
               (when-let* (((fboundp 'drgnx-agents-get)) (s (drgnx-agents-get sid)))
                 (drgnx-agents-kill s))))
           drgnx-review--runs)
  (clrhash drgnx-review--runs)
  (setq drgnx-review--current nil)
  (dolist (b (buffer-list))
    (when (provided-mode-derived-p (buffer-local-value 'major-mode b) 'drgnx-review-mode)
      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))

(drgnx-module-define 'tools/review
                     :doc "Review Branch: the review route's agent reads this branch's diff; findings in the Review tab."
                     :stage 'idle :requires '(tools/diff) :teardown #'drgnx-review--teardown
                     :setup
                     (lambda ()
                       (add-hook 'drgnx-agents-request-functions #'drgnx-review--request)
                       (add-hook 'drgnx-agents-changed-functions #'drgnx-review--changed)
                       (when (fboundp 'drgnx-wb-define-tab) (drgnx-wb-define-tab 'panel 'review :title "Review"))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((review-branch "Review Branch" drgnx-review-branch "An agent reviews this branch before you push")
                                        (review-view "Review: Show Findings" drgnx-review-view "The Review tab")
                                        (review-refresh "Review: Refresh" drgnx-review-refresh "Draw the Review tab again")
                                        (review-visit "Review: Open Finding" drgnx-review-visit "The finding's file, at its line")
                                        (review-show-diff "Review: Show Branch Diff" drgnx-review-show-diff "The reviewed changes in the diff view")))
                         (drgnx-command-define id :category "Source Control" :title title :command fn :doc doc))))

(provide 'drgnx-review)
;;; drgnx-review.el ends here
