;;; drgnx-say.el --- Say it: the prompt command, the proposal view and the forecast line -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub turns one prompt into a proposed plan (`say/start'), shows what it would cost (`forecast/get') and waits for
;; the user's OK.  Here is the editor's side: the command that reads the prompt, the notice that a proposal is waiting
;; (an event, so never a prompt), the proposal buffer with its approve, revise and reject commands, and the pure pieces
;; the Work space embeds: `drgnx-say--render' inserts a proposal at point in any buffer and `drgnx-forecast-line' is the
;; one-line forecast (also the Fork prompt's).  A range is always a range with its basis, a price the hub does not have
;; is "not priced", and nothing here prints a zero for it.  See docs/guide/agents.md, "Say it".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-notice)
(require 'drgnx-registry)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function project-root "project")
(defvar drgnx-hub--event-conn)

(defface drgnx-say-label '((t :inherit bold))
  "Headings in the proposal view." :group 'drgnx)
(defface drgnx-say-agent '((t :inherit font-lock-doc-face))
  "Text the planning agent wrote: marked as such, never mixed into the hub's facts." :group 'drgnx)
(defface drgnx-say-warning '((t :inherit warning))
  "Warnings in the proposal view." :group 'drgnx)

;;;; Numbers and ranges

(defun drgnx-say--num (x)
  "X (a number) as a short string: whole above 1, cents below, \"<0.01\" for what rounds to nothing."
  (cond ((>= x 0.995) (format "%d" (round x)))
        ((>= x 0.005) (format "%.2f" x))
        (t "<0.01")))

(defun drgnx-say--range (lo hi fmt)
  "\"LO–HI\" through FMT, or the one number when they print alike."
  (let ((a (funcall fmt lo)) (b (funcall fmt hi)))
    (if (equal a b) a (concat a "–" b))))

(defun drgnx-say--tokens-num (x)
  (cond ((>= x 1e7) (format "%dM" (round (/ x 1e6))))
        ((>= x 1e6) (concat (string-remove-suffix ".0" (format "%.1f" (/ x 1e6))) "M"))
        ((>= x 1e3) (format "%dk" (round (/ x 1e3))))
        (t (format "%d" (round x)))))

(defun drgnx-say--time (range)
  "RANGE (:p50 :p90, seconds) as \"20–50 min\", in the unit of its high end."
  (let* ((lo (plist-get range :p50)) (hi (plist-get range :p90))
         (unit-secs (cond ((< hi 90) 1) ((< hi 7200) 60) (t 3600)))
         (name (cond ((= unit-secs 1) "s") ((= unit-secs 60) "min") (t "h")))
         (fmt (lambda (s) (let ((v (/ s (float unit-secs))))
                            (if (>= v 10) (format "%d" (round v))
                              (string-remove-suffix ".0" (format "%.1f" v)))))))
    (concat (drgnx-say--range lo hi fmt) " " name)))

(defun drgnx-say--cost (c)
  "The cost range C (:unit :p50 :p90 :estimate) as text, or nil when it is zero (a price is never shown as nothing)."
  (let ((lo (plist-get c :p50)) (hi (plist-get c :p90)) (unit (plist-get c :unit)))
    (when (and (numberp hi) (> hi 0))
      (cond ((equal unit "limit-share")
             (concat (drgnx-say--range (* 100 lo) (* 100 hi) (lambda (v) (format "%d" (round v)))) "% of the limit (estimate)"))
            ((member unit '("usd" "usd-est"))
             (concat (drgnx-say--range lo hi #'drgnx-say--num) " USD"
                     (if (or (equal unit "usd-est") (eq (plist-get c :estimate) t)) " (estimate)" "")))
            (t (concat (drgnx-say--range lo hi #'drgnx-say--num) " " (or unit "")))))))

(defun drgnx-say--costs (costs)
  "The texts of COSTS, each unit apart, zero ones left out."
  (delq nil (mapcar #'drgnx-say--cost costs)))

(defun drgnx-say--time-range (forecast)
  (or (plist-get forecast :wall_secs) (plist-get forecast :active_secs)))

(defun drgnx-forecast-line (forecast)
  "FORECAST as one line: \"about 1–3 USD (estimate), 2M–6M tokens, 20–50 min\".  A forecast with no price shows tokens
and time only: never \"0.00\".  Nil for no forecast."
  (when forecast
    (let ((tokens (plist-get forecast :tokens)) (time (drgnx-say--time-range forecast)))
      (concat "about "
              (mapconcat #'identity
                         (append (drgnx-say--costs (plist-get forecast :cost))
                                 (and tokens
                                      (list (concat (drgnx-say--range (plist-get tokens :p50) (plist-get tokens :p90)
                                                                      #'drgnx-say--tokens-num)
                                                    " tokens")))
                                 (and time (list (drgnx-say--time time))))
                         ", ")))))

;;;; The render (pure: it inserts at point and touches nothing else)

(defun drgnx-say--day (time)
  (format-time-string "%A" (seconds-to-time time)))

(defun drgnx-say--pace-line (p)
  "One subscription's pace effect P as text."
  (let ((who (or (plist-get p :provider) "subscription")))
    (cond ((null (plist-get p :added_share))
           (format "%s: no pace yet, so no effect to show" who))
          (t (let ((at (plist-get p :exhausted_at)) (after (plist-get p :exhausted_after)))
               (format "%s: at this pace: %s; with this plan: %s%s%s" who
                       (if at (drgnx-say--day at) "lasts to the reset")
                       (if after (drgnx-say--day after) "lasts to the reset")
                       (if (eq (plist-get p :estimate) t) " (estimate)" "")
                       (if (eq (plist-get p :runs_out_p90) t) "; one run in ten uses up the limit first" "")))))))

(defun drgnx-say--field (label text &optional face)
  (insert (propertize (concat label ": ") 'face 'drgnx-say-label)
          (if face (propertize text 'face face) text) "\n"))

(defun drgnx-say--task-line (task)
  (let ((costs (drgnx-say--costs (plist-get task :cost))) (basis (plist-get task :basis)))
    (format "  %s. %s on %s: %s%s%s" (plist-get task :n) (plist-get task :role) (plist-get task :profile)
            (if costs (string-join costs ", ") "not priced")
            (if (plist-get task :tokens)
                (format ", %s tokens" (drgnx-say--range (plist-get (plist-get task :tokens) :p50)
                                                        (plist-get (plist-get task :tokens) :p90) #'drgnx-say--tokens-num))
              "")
            (if basis (concat " (from " (plist-get basis :label) ")") ""))))

(defun drgnx-say--render (forecast job-summary)
  "Insert the proposal at point: the hub's facts (tasks, profiles, budget, forecast, wake, manager, pace, warnings, price
date), then the planning agent's text under its label.  FORECAST is `forecast/get''s answer, JOB-SUMMARY `job/status''s
for the job.  Nothing outside what is inserted moves."
  (let* ((tasks (plist-get forecast :tasks))
         (profiles (delete-dups (delq nil (mapcar (lambda (tk) (plist-get tk :profile)) tasks))))
         (costs (drgnx-say--costs (plist-get forecast :cost)))
         (wake (plist-get forecast :wake)) (manager (plist-get forecast :manager)))
    (drgnx-say--field "Status" (or (plist-get job-summary :status) "proposed"))
    (drgnx-say--field "Tasks" (format "%d%s" (or (and tasks (length tasks)) (length (plist-get job-summary :tasks)))
                                      (if profiles (concat ", on " (string-join profiles ", ")) "")))
    (drgnx-say--field "Budget" (if (plist-get job-summary :budget) (format "%s USD" (drgnx-say--num (plist-get job-summary :budget))) "none"))
    (when forecast
      (drgnx-say--field "Cost" (if costs (string-join costs ", ")
                                 (format "not priced%s" (if (plist-get forecast :unpriced)
                                                            (concat " (" (string-join (plist-get forecast :unpriced) ", ") ")") ""))))
      (when (plist-get forecast :tokens)
        (drgnx-say--field "Tokens" (drgnx-say--range (plist-get (plist-get forecast :tokens) :p50)
                                                     (plist-get (plist-get forecast :tokens) :p90) #'drgnx-say--tokens-num)))
      (when (drgnx-say--time-range forecast)
        (drgnx-say--field "Time" (drgnx-say--time (drgnx-say--time-range forecast))))
      (when wake
        (let* ((w (plist-get wake :cold_wakes)) (wc (drgnx-say--costs (plist-get wake :cost))))
          (insert (format "  of which wakes: %s cold%s\n"
                          (drgnx-say--range (plist-get w :p50) (plist-get w :p90) (lambda (v) (format "%d" (round v))))
                          (if wc (concat ", about " (string-join (mapcar (lambda (c) (replace-regexp-in-string "–[^ ]*" "" c)) wc) ", ")) "")))))
      (when manager
        (insert (format "  Manager: %s, beside the total and not in it\n"
                        (let ((mc (drgnx-say--costs (plist-get manager :cost))) (mt (plist-get manager :tokens)))
                          (cond (mc (string-join mc ", "))
                                (mt (concat "not priced, "
                                            (drgnx-say--range (plist-get mt :p50) (plist-get mt :p90) #'drgnx-say--tokens-num)
                                            " tokens"))
                                (t "not priced")))))))
    (when tasks
      (insert (propertize "Basis:\n" 'face 'drgnx-say-label))
      (dolist (tk tasks) (insert (drgnx-say--task-line tk) "\n")))
    (dolist (p (plist-get forecast :pace)) (drgnx-say--field "Pace" (drgnx-say--pace-line p)))
    (dolist (w (append (plist-get forecast :warnings) (plist-get job-summary :warnings)))
      (drgnx-say--field "Warning" (format "%s" w) 'drgnx-say-warning))
    (when (plist-get forecast :prices_as_of)
      (drgnx-say--field "Prices as of" (plist-get forecast :prices_as_of)))
    (insert "\n" (propertize "Written by the planning agent" 'face 'drgnx-say-label) "\n")
    (let ((start (point)))
      (when (plist-get job-summary :title) (insert (plist-get job-summary :title) "\n"))
      ;; the hub's summary carries a task's n, title, role, profile, status and deps; its body stays in the plan
      (dolist (tk (plist-get job-summary :tasks))
        (insert (format "  %s. %s\n" (or (plist-get tk :n) "") (or (plist-get tk :title) ""))))
      (add-face-text-property start (point) 'drgnx-say-agent))))

;;;; The proposal buffer

(defvar-local drgnx-say--job nil "The id of the job this buffer shows.")
(defvar drgnx-say--sessions nil
  "Alist (JOB . SESSION): the planning session behind each proposal this editor was told of.  An entry goes when the
proposal is decided or the planning fails; at most `drgnx-say--keep' stay.")
(defconst drgnx-say--keep 20)

(defvar drgnx-say-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m special-mode-map)
    (define-key m (kbd "C-c C-c") #'drgnx-say-approve)
    (define-key m (kbd "C-c C-e") #'drgnx-say-revise)
    (define-key m (kbd "C-c C-k") #'drgnx-say-reject)
    m)
  "Keys of the proposal buffer.")

(define-derived-mode drgnx-say-mode special-mode "Proposal"
  "The hub's proposal for a prompt: its forecast and the plan the planning agent wrote.
\\[drgnx-say-approve] approves, \\[drgnx-say-revise] asks for a change, \\[drgnx-say-reject] rejects."
  (buffer-disable-undo)
  (setq header-line-format "C-c C-c approve, C-c C-e revise, C-c C-k reject"))

(defun drgnx-say--notice-id (job) (intern (concat "say-" job)))

(defun drgnx-say--session (job) (cdr (assoc job drgnx-say--sessions)))

(defun drgnx-say--forget (job)
  (setq drgnx-say--sessions (assoc-delete-all job drgnx-say--sessions)))

(defun drgnx-say--remember (job session)
  (setq drgnx-say--sessions (cons (cons job session) (assoc-delete-all job drgnx-say--sessions)))
  (when (> (length drgnx-say--sessions) drgnx-say--keep)
    (setq drgnx-say--sessions (cl-subseq drgnx-say--sessions 0 drgnx-say--keep))))

(defun drgnx-say--buffer-name (job) (format "*drgnx proposal: %s*" job))

(defun drgnx-say--draw (buffer forecast summary)
  "One render of the proposal into BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t) (line (line-number-at-pos)))
        (erase-buffer)
        (drgnx-say--render forecast summary)
        (goto-char (point-min))
        (forward-line (1- line))))))

;;;###autoload
(defun drgnx-say-show (job)
  "Show the proposal JOB in its buffer: the hub's facts and forecast, then the plan the planning agent wrote.  The
facts arrive asynchronously; one render when both have."
  (interactive (list (or (bound-and-true-p drgnx-say--job) (read-string "Job: "))))
  (let ((buffer (get-buffer-create (drgnx-say--buffer-name job))) forecast summary (got 0))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-say-mode) (drgnx-say-mode))
      (setq drgnx-say--job job)
      (let ((inhibit-read-only t)) (erase-buffer) (insert "Asking the hub...\n")))
    (let ((done (lambda ()
                  (when (= (cl-incf got) 2) (drgnx-say--draw buffer forecast summary)))))
      (drgnx-hub-call "job/status" (list :id job) (lambda (r _err) (setq summary r) (funcall done)))
      (drgnx-hub-call "forecast/get" (list :job job) (lambda (r _err) (setq forecast r) (funcall done))))
    (pop-to-buffer buffer)))

;;;; Commands

(defun drgnx-say--repo ()
  "The repository a prompt is about: the project root of this buffer, else its directory."
  (directory-file-name
   (expand-file-name (or (and (fboundp 'project-current)
                              (when-let* ((p (project-current))) (project-root p)))
                         default-directory))))

;;;###autoload
(defun drgnx-say (text)
  "Say what you want done: the hub plans it and proposes a job, which waits for your OK.  TEXT is read here, in the
command, and never by an event."
  (interactive (list (read-string "Say it: ")))
  (when (string-empty-p (string-trim text)) (user-error "Nothing to say"))
  (drgnx-hub-call "say/start" (list :text text :repo (drgnx-say--repo))
                  (lambda (_r err) (if err (message "Say it: %s" (or (plist-get err :message) err))
                                     (message "Planning...")))))

(defun drgnx-say--job-here ()
  (or drgnx-say--job (user-error "Not a proposal buffer")))

(defun drgnx-say--end (job)
  "Forget JOB's planning session and tell the hub it may stop."
  (when-let* ((session (drgnx-say--session job)))
    (drgnx-hub-call "say/end" (list :id session) #'ignore))
  (drgnx-say--forget job)
  (drgnx-notice-clear 'hub (drgnx-say--notice-id job)))

(defun drgnx-say-approve ()
  "Approve this proposal: the job starts, and the planning session ends."
  (interactive)
  (let ((job (drgnx-say--job-here)) (buffer (current-buffer)))
    (drgnx-hub-call "job/approve" (list :id job)
                    (lambda (r err)
                      (if err (message "Approve: %s" (or (plist-get err :message) err))
                        (drgnx-say--end job)
                        (message "Job %s: %s" job (or (plist-get r :status) "approved"))
                        (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun drgnx-say-reject ()
  "Reject this proposal: the job stops, and the planning session ends."
  (interactive)
  (let ((job (drgnx-say--job-here)) (buffer (current-buffer)))
    (drgnx-hub-call "job/stop" (list :id job)
                    (lambda (_r err)
                      (if err (message "Reject: %s" (or (plist-get err :message) err))
                        (drgnx-say--end job)
                        (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun drgnx-say-revise (&optional text)
  "Ask the planning agent for a change to this proposal; TEXT is read here, in the command."
  (interactive)
  (let* ((job (drgnx-say--job-here))
         (session (or (drgnx-say--session job) (user-error "No planning session behind this proposal; approve or reject it")))
         (text (or text (read-string "Change: "))))
    (drgnx-hub-call "say/revise" (list :id session :text text)
                    (lambda (_r err) (if err (message "Revise: %s" (or (plist-get err :message) err))
                                       (message "Planning again..."))))))

(defun drgnx-forecast-accuracy ()
  "Show how past forecasts fared against the finished tasks, per role and profile."
  (interactive)
  (drgnx-hub-call "forecast/accuracy" nil
                  (lambda (r err)
                    (let ((buffer (get-buffer-create "*drgnx forecast accuracy*")))
                      (with-current-buffer buffer
                        (unless (derived-mode-p 'special-mode) (special-mode))
                        (buffer-disable-undo)
                        (let ((inhibit-read-only t))
                          (erase-buffer)
                          (cond (err (insert (format "The hub could not say: %s\n" (or (plist-get err :message) err))))
                                ((null (plist-get r :rows)) (insert "No finished task has been forecast yet.\n"))
                                (t (insert (propertize "Role / profile: tasks, share within the high end, median actual over middle\n"
                                                       'face 'drgnx-say-label))
                                   (dolist (row (plist-get r :rows))
                                     (insert (format "%s%s: %d, %d%%, %.2f\n" (plist-get row :role)
                                                     (if (plist-get row :profile) (concat " / " (plist-get row :profile)) "")
                                                     (plist-get row :n) (round (* 100 (plist-get row :coverage)))
                                                     (plist-get row :median_ratio)))))))
                        (goto-char (point-min)))
                      (pop-to-buffer buffer)))))

;;;; Events

(defun drgnx-say-event (event params)
  "`drgnx-hub-event-functions': a proposal, a question or a failure of the planning is a notice from a hub that proved
itself.  Nothing asks, nothing waits: the notice carries the command that does."
  (when (and (member event '("say-proposal" "say-message" "say-failed"))
             (processp (bound-and-true-p drgnx-hub--event-conn))
             (process-get drgnx-hub--event-conn :drgnx-proven))
    (let ((session (plist-get params :id)) (job (plist-get params :job)))
      (pcase event
        ("say-proposal"
         (when (and (stringp job) (stringp session))
           (drgnx-say--remember job session)
           (drgnx-notify 'hub 'info "A proposal is waiting for your OK"
                         :id (drgnx-say--notice-id job) :life 'condition
                         :fix "Show" :command (list 'drgnx-say-show job))))
        ("say-message"
         (when (stringp session)
           (drgnx-notify 'hub 'info "The planning agent asks something"
                         :id (intern (concat "say-ask-" session)) :life 'condition
                         :detail (format "Written by the planning agent: %s" (plist-get params :text))
                         :fix "Answer" :command (list 'drgnx-say-answer session))))
        ("say-failed"
         (drgnx-notify 'hub 'warn "The planning did not produce a proposal"
                       :id (intern (concat "say-failed-" (or session "x"))) :life 'condition
                       :detail (format "%s" (plist-get params :why))))))))

(defun drgnx-say-answer (session)
  "Answer the planning agent's question in SESSION; the text is read here, in the command."
  (drgnx-hub-call "say/revise" (list :id session :text (read-string "Answer: "))
                  (lambda (_r err) (if err (message "Answer: %s" (or (plist-get err :message) err))
                                     (drgnx-notice-clear 'hub (intern (concat "say-ask-" session)))))))

(defun drgnx-say-register-commands ()
  "The palette entries; no key in the Work space."
  (drgnx-command-define 'say-it :category "Agents" :title "Say It" :command #'drgnx-say
                        :doc "Say what you want done; the hub plans it and proposes a job for your OK")
  (drgnx-command-define 'say-approve :category "Agents" :title "Say It: Approve" :command #'drgnx-say-approve
                        :doc "Approve the proposal shown in this buffer")
  (drgnx-command-define 'say-revise :category "Agents" :title "Say It: Revise" :command #'drgnx-say-revise
                        :doc "Ask the planning agent for a change to the proposal shown in this buffer")
  (drgnx-command-define 'say-reject :category "Agents" :title "Say It: Reject" :command #'drgnx-say-reject
                        :doc "Reject the proposal shown in this buffer")
  (drgnx-command-define 'forecast-accuracy :category "Agents" :title "Forecast Accuracy"
                        :command #'drgnx-forecast-accuracy
                        :doc "How past forecasts fared against the finished tasks"))

(provide 'drgnx-say)
;;; drgnx-say.el ends here
