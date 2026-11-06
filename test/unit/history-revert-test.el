;;; history-revert-test.el --- batch tests: revert, fork, redo, compare and the cards, against the hub's answers -*- lexical-binding: t -*-
;; The cards and prompts are drawn from the hub's answers (the shapes of runtime/protocol/methods.json); the hub client's
;; two calls are the seam, replaced by canned answers in the rows that need a particular preview.  One row asks the real
;; hub through the delivery gate, so a refusal's path from the hub to the user is the hub's own.  The proof rows
;; (test/conformance/rewind, fork, edit-history) run the whole chain.
;; test-class: cond
;; test-pattern: gated
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-hub-client)
(require 'drgnx-history)
(require 'drgnx-history-revert)
(require 'drgnx-history-compare)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers

(defvar drgnx-hub--event-conn)
(defvar drgnx-work-trail--session)

(defconst drgnx-history-revert-test--preview
  '(:preview_id 7 :session "s1" :seq 12 :files ("a.txt" "b.txt") :non_overlapping_files ("c.txt")
                :overlaps ((:path "b.txt" :reverted "agent text" :users "user text"))
                :effects (:pushed ((:commit "abc123" :refs ("origin/main"))) :messages_read (1 2) :decisions_relied_on nil
                                  :tasks_filed ("fix the build") :merges nil :settings nil :spent (:cost_by_unit nil :tokens 1200)
                                  :jobs_running ("j1 (here)") :label "computed")
                :level "message" :needs_message :false :blocked nil :skipped nil :conversation (:state "restored") :fork :false)
  "A preview as `history/revert/preview' answers it.")

(defun drgnx-history-revert-test--with-preview (&rest changes)
  "The sample preview with CHANGES (a plist) on top."
  (let ((p (copy-sequence drgnx-history-revert-test--preview)))
    (while changes (setq p (plist-put p (pop changes) (pop changes))))
    p))

(defmacro drgnx-history-revert-test--hub (replies &rest body)
  "BODY with the hub client's two calls answered from REPLIES (an alist METHOD → result; a method it lacks is an error).
Every call is pushed on `calls' as (METHOD . PARAMS), newest first."
  (declare (indent 1))
  `(let ((calls nil) (replies ,replies))
     (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &optional _timeout)
                  (push (cons method params) calls)
                  (if (assoc method replies) (cdr (assoc method replies)) (error "drgnx hub: no %s" method))))
               ((symbol-function 'drgnx-hub-call)
                (lambda (method params callback &rest _)
                  (push (cons method params) calls)
                  (if (assoc method replies) (funcall callback (cdr (assoc method replies)) nil)
                    (funcall callback nil (format "no %s" method)))
                  1)))
       ,@body)))

(defun drgnx-history-revert-test--card (preview)
  "Open the revert card for PREVIEW; its text."
  (let ((b (drgnx-history-revert--open preview)))
    (with-current-buffer b (buffer-substring-no-properties (point-min) (point-max)))))

(defun drgnx-history-revert-test--kill-cards ()
  "Kill the buffers the commands open."
  (dolist (b (buffer-list))
    (when (string-match-p "\\`\\*drgnx \\(revert\\|merge\\|compare\\)" (buffer-name b)) (kill-buffer b))))

(ert-deftest drgnx-history/card-shows-effects-before-files ()
  ;; B: what the revert cannot undo comes first, then the files and the overlaps, then the conversation level
  (unwind-protect
      (let* ((text (drgnx-history-revert-test--card drgnx-history-revert-test--preview))
             (at (lambda (s) (or (string-search s text) (ert-fail (list "missing" s text))))))
        (should (< (funcall at "What this cannot undo") (funcall at "pushed: abc123")))
        (should (< (funcall at "pushed: abc123") (funcall at "job running: j1 (here)")))
        (should (< (funcall at "job running: j1 (here)") (funcall at "Files")))
        (should (< (funcall at "Files") (funcall at "a.txt")))
        (should (< (funcall at "a.txt") (funcall at "Your later edits it meets")))
        (should (< (funcall at "Your later edits it meets") (funcall at "Conversation")))
        (should (string-search "(computed)" text))
        (should (string-search "c.txt  (merged with your edit)" text)))
    (drgnx-history-revert-test--kill-cards)))

(ert-deftest drgnx-history/card-keep-mine-and-roll-back ()
  ;; B: Apply sends the mode the card shows and one choice per overlap; the reverted file is taken at the overlap the
  ;; user chose; a successful Apply closes the card
  (drgnx-history-revert-test--hub '(("history/revert/apply" . (:op 4 :session "s1" :skipped nil)))
    (unwind-protect
        (progn
          (drgnx-history-revert-test--card drgnx-history-revert-test--preview)
          (with-current-buffer "*drgnx revert: s1 step 12*"
            (drgnx-history-revert-apply))
          (let ((params (cdr (assoc "history/revert/apply" calls))))
            (should (equal (plist-get params :mode) "keep-mine"))
            (should (equal (plist-get params :choices) '((:choice "keep-users"))))
            (should (= (plist-get params :preview_id) 7)))
          (should-not (get-buffer "*drgnx revert: s1 step 12*"))
          (setq calls nil)
          (drgnx-history-revert-test--card drgnx-history-revert-test--preview)
          (with-current-buffer "*drgnx revert: s1 step 12*"
            (drgnx-history-revert-roll-back-mine)
            (goto-char (point-min))
            (search-forward "[your file stays]")
            (backward-char 3)
            (drgnx-history-revert-take-reverted)
            (should (string-search "[reverted file]" (buffer-string)))
            (drgnx-history-revert-apply))
          (let ((params (cdr (assoc "history/revert/apply" calls))))
            (should (equal (plist-get params :mode) "roll-back-mine"))
            (should (equal (plist-get params :choices) '((:choice "take-reverted"))))))
      (drgnx-history-revert-test--kill-cards))))

(ert-deftest drgnx-history/card-labels-a-summary-and-asks-a-message ()
  ;; B: a summary-level revert says so, and Apply sends the user's message with it
  (drgnx-history-revert-test--hub '(("history/revert/apply" . (:op 4 :session "s1" :skipped nil)))
    (unwind-protect
        (let ((text (drgnx-history-revert-test--card
                     (drgnx-history-revert-test--with-preview :level "summary" :needs_message t))))
          (should (string-search "Summary: a new conversation told a summary" text))
          (should (string-search "(none yet; e writes it)" text))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "carry on from here")))
            (with-current-buffer "*drgnx revert: s1 step 12*" (drgnx-history-revert-apply)))
          (should (equal (plist-get (cdr (assoc "history/revert/apply" calls)) :message) "carry on from here")))
      (drgnx-history-revert-test--kill-cards))))

(ert-deftest drgnx-history/blocked-card-offers-fork ()
  ;; B: a blocked revert shows why and offers Fork, not Apply; Apply refuses
  (unwind-protect
      (let ((text (drgnx-history-revert-test--card
                   (drgnx-history-revert-test--with-preview
                    :blocked '((:decision 3 :commit "def456" :session "s2" :branch "job/x"))))))
        (should (string-search "blocked: def456 on job/x depends on decision 3" text))
        (should (string-search "Fork" text))
        (should-not (string-search "Apply" text))
        (with-current-buffer "*drgnx revert: s1 step 12*"
          (should-error (drgnx-history-revert-apply) :type 'user-error)))
    (drgnx-history-revert-test--kill-cards)))

(ert-deftest drgnx-history/finished-worker-card-labels-the-conversation-and-offers-fork ()
  ;; B: a finished worker's card says the conversation is not restored and offers Apply and Fork side by side
  (unwind-protect
      (let ((text (drgnx-history-revert-test--card
                   (drgnx-history-revert-test--with-preview
                    :conversation '(:state "not-restored" :label "conversation not restored: the agent has finished")
                    :fork t))))
        (should (string-search "conversation not restored: the agent has finished" text))
        (should (string-match-p "Apply +Fork" text)))
    (drgnx-history-revert-test--kill-cards)))

(ert-deftest drgnx-history/card-says-a-hook-refused-a-step ()
  ;; B: a path the hub left out because a hook refused it shows as "refused by hook"
  (unwind-protect
      (should (string-search "z.txt  (refused by hook)"
                             (drgnx-history-revert-test--card
                              (drgnx-history-revert-test--with-preview
                               :skipped '((:path "z.txt" :reason "refused-by-hook"))))))
    (drgnx-history-revert-test--kill-cards)))

(defconst drgnx-history-revert-test--fork-replies
  '(("history/fork" . (:id "f1" :branch "fork/f1" :source_branch "main" :path "/t" :level "message"))
    ("history/compare" . (:files ((:path "a.txt" :hunks ((:ours_start 0 :ours_end 3 :theirs_start 0 :theirs_end 5
                                                                      :ours_text "one" :theirs_text "three" :author (:kind "agent" :session "f1")
                                                                      :session "f1" :step "9" :record 2)))))))
  "The hub's answers to a fork and its comparison.")

(ert-deftest drgnx-history/fork-prompt-shows-the-forecast-line ()
  ;; B: the prompt for the first message carries part 5's one line, and the message goes to the hub
  (let ((prompt nil))
    (drgnx-history-revert-test--hub (cons '("forecast/session" . (:tokens (:p50 2000000 :p90 6000000)))
                                          drgnx-history-revert-test--fork-replies)
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-forecast-line) (lambda (_f) "about 1–3 USD (estimate), 2M–6M tokens"))
                    ((symbol-function 'read-string) (lambda (p &rest _) (setq prompt p) "try it differently")))
            (drgnx-history-fork-here "s1" 12)
            (should (equal prompt "Fork from step 12 (about 1–3 USD (estimate), 2M–6M tokens): "))
            (should (equal (cdr (assoc "history/fork" calls))
                           '(:session "s1" :seq 12 :message "try it differently"))))
        (drgnx-history-revert-test--kill-cards)))))

(ert-deftest drgnx-history/fork-prompt-without-a-forecast-still-forks ()
  ;; B: without part 5's function, or when the hub cannot forecast, the prompt has no line and the fork starts
  (let ((prompts nil))
    (drgnx-history-revert-test--hub drgnx-history-revert-test--fork-replies
      (unwind-protect
          (cl-letf (((symbol-function 'read-string) (lambda (p &rest _) (push p prompts) "go")))
            (cl-letf (((symbol-function 'drgnx-forecast-line) nil))
              (drgnx-history-fork-here "s1" 12))
            (cl-letf (((symbol-function 'drgnx-forecast-line) (lambda (_f) "never reached")))
              (drgnx-history-fork-here "s1" 12))   ; forecast/session is not answered: an error, no line
            (should (equal prompts '("Fork from step 12: " "Fork from step 12: ")))
            (should (= 2 (cl-count "history/fork" calls :key #'car :test #'equal))))
        (drgnx-history-revert-test--kill-cards)))))

(ert-deftest drgnx-history/fork-opens-compare ()
  ;; B: a fork opens the comparison of its branch with the source, each hunk naming author and step
  (drgnx-history-revert-test--hub drgnx-history-revert-test--fork-replies
    (unwind-protect
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "go")))
          (drgnx-history-fork-here "s1" 12)
          (should (equal (cdr (assoc "history/compare" calls)) '(:a "main" :b "fork/f1")))
          (with-current-buffer "*drgnx compare: main..fork/f1*"
            (let ((text (buffer-string)))
              (should (string-search "a.txt" text))
              (should (string-search "by agent f1, session f1, step 9" text))
              (should (string-search "- one" text))
              (should (string-search "+ three" text)))))
      (drgnx-history-revert-test--kill-cards))))

(ert-deftest drgnx-history/commands-take-a-session-and-step ()
  ;; B: each command takes (SESSION SEQ) and asks the hub about exactly those; from M-x the session of the work trail
  ;; and its last step stand in
  (drgnx-history-revert-test--hub
      (append `(("history/revert/preview" . ,drgnx-history-revert-test--preview)
                ("timeline/get" . (:steps ((:seq 9 :undone_by 31))))
                ("history/redo" . (:op 32 :written ("a.txt") :skipped nil)))
              drgnx-history-revert-test--fork-replies)
    (unwind-protect
        (progn
          (drgnx-history-revert-to-here "s1" 12)
          (should (equal (cdr (assoc "history/revert/preview" calls)) '(:session "s1" :seq 12)))
          (drgnx-history-redo "s1" 9)
          (should (equal (cdr (assoc "history/redo" calls)) '(:session "s1" :op 31)))
          (let ((drgnx-work-trail--session "s1"))
            (should (equal (drgnx-history-revert--args) '("s1" 9))))
          (dolist (c '(drgnx-history-revert-to-here drgnx-history-fork-here drgnx-history-redo))
            (should (commandp c))
            (should (equal (cdr (func-arity c)) 2))))
      (drgnx-history-revert-test--kill-cards))))

(ert-deftest drgnx-history/redo-of-a-step-nothing-undid-says-so ()
  ;; B: a step no revert abandoned has nothing to redo
  (drgnx-history-revert-test--hub '(("timeline/get" . (:steps ((:seq 9 :undone_by nil)))))
    (should-error (drgnx-history-redo "s1" 9) :type 'user-error)
    (should-not (assoc "history/redo" calls))))

(ert-deftest drgnx-history/who-wrote-this-names-author-and-step ()
  ;; B: the answer is one line naming each author once, with the step
  (let ((file (make-temp-file "who" nil ".txt")))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name file)
          (insert "hello")
          (cl-letf (((symbol-function 'drgnx-history-tracked-p) (lambda (&optional _) t))
                    ((symbol-function 'locate-dominating-file) (lambda (&rest _) (file-name-directory file))))
            (drgnx-history-revert-test--hub
                '(("history/blame" . (:spans ((:start 0 :end 3 :author (:kind "agent" :session "s1") :record 6 :session "s1" :step "4")
                                              (:start 3 :end 5 :author (:kind "user") :record 7)))))
              (let (said)
                (cl-letf (((symbol-function 'message) (lambda (f &rest a) (setq said (apply #'format f a)))))
                  (drgnx-history-who-wrote-this 1 4))
                (should (equal said "agent s1 (step 4), you"))
                (should (equal (plist-get (cdr (assoc "history/blame" calls)) :start) 0))))))
      (delete-file file))))

;;;; The files a revert wrote

(defun drgnx-history-revert-test--proven-conn ()
  "A process standing for the event connection of a hub that proved itself."
  (let ((p (make-pipe-process :name "history-revert-test" :noquery t)))
    (process-put p :drgnx-proven t)
    p))

(defmacro drgnx-history-revert-test--project (&rest body)
  "BODY with `dir' a temp folder holding a.txt (\"disk one\\n\"), `clean' the unmodified buffer visiting it and `conn'
the proven event connection; the notices and the waiting list are this body's own."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "history-revert" t)))
          (drgnx-history-revert--waiting nil)
          (conn (drgnx-history-revert-test--proven-conn))
          (drgnx-hub--event-conn conn)
          (file (expand-file-name "a.txt" dir))
          (buffer nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert "disk one\n"))
           (setq buffer (find-file-noselect file))
           ,@body)
       (when (buffer-live-p buffer) (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))
       (delete-process conn)
       (drgnx-history-revert-test--kill-cards)
       (delete-directory dir t))))

(ert-deftest drgnx-history/clean-buffer-reverts-under-the-hubs-origin ()
  ;; B: after history/applied a buffer without unsaved changes shows the file as the hub wrote it, and the change is
  ;; recorded as the hub's, not the user's
  (drgnx-history-revert-test--project
    (let ((origin nil))
      (with-temp-file file (insert "disk two\n"))
      (advice-add 'revert-buffer :before
                  (lambda (&rest _) (setq origin (bound-and-true-p nidhogg-history-origin)))
                  '((name . history-revert-test)))
      (unwind-protect
          (drgnx-history-revert--event "history/applied" (list :op 5 :paths '("a.txt") :worktree (directory-file-name dir)))
        (advice-remove 'revert-buffer 'history-revert-test))
      (should (equal origin "revert"))
      (should (equal (with-current-buffer buffer (buffer-string)) "disk two\n"))
      (should-not drgnx-history-revert--waiting))))

(ert-deftest drgnx-history/dirty-buffer-gets-a-card-not-an-overwrite ()
  ;; B: a buffer with unsaved changes keeps its text when a revert wrote its file; a notice leads to a card whose
  ;; answers are keep mine, take theirs and edit
  (drgnx-history-revert-test--project
    (with-current-buffer buffer (goto-char (point-max)) (insert "my unsaved line\n"))
    (with-temp-file file (insert "disk two\n"))
    (let ((posted nil))
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (&rest args) (push args posted))))
        (drgnx-history-revert--event "history/applied" (list :op 5 :paths '("a.txt") :worktree (directory-file-name dir))))
      (should (equal (with-current-buffer buffer (buffer-string)) "disk one\nmy unsaved line\n"))
      (should (buffer-modified-p buffer))
      (should (equal (plist-get (cdddr (car posted)) :command) '(drgnx-history-resolve-dirty 5)))
      (should (= (length drgnx-history-revert--waiting) 1)))
    ;; the card shows the difference between the file and the unsaved text
    (drgnx-history-resolve-dirty 5)
    (with-current-buffer (format "*drgnx merge: %s*" (buffer-name buffer))
      (let ((text (buffer-string)))
        (should (string-search "has unsaved changes" text))
        (should (string-search "keep mine" text))
        (should (string-search "take theirs" text))
        (should (string-search "edit" text))
        (should (string-search "+my unsaved line" text))
        (should (string-search "-disk two" text)))
      ;; take theirs: the file's text replaces the unsaved text
      (drgnx-history-merge-take-theirs))
    (should (equal (with-current-buffer buffer (buffer-string)) "disk two\n"))
    (should-not (buffer-modified-p buffer))
    (should-not drgnx-history-revert--waiting)))

(ert-deftest drgnx-history/dirty-buffer-keep-mine-keeps-the-text ()
  ;; B: keep mine leaves the unsaved text and accepts it over the file; the card and the waiting entry go
  (drgnx-history-revert-test--project
    (with-current-buffer buffer (goto-char (point-max)) (insert "mine\n"))
    (with-temp-file file (insert "disk two\n"))
    (cl-letf (((symbol-function 'drgnx-notify) #'ignore))
      (drgnx-history-revert--event "history/applied" (list :op 6 :paths '("a.txt") :worktree (directory-file-name dir))))
    (drgnx-history-resolve-dirty 6)
    (with-current-buffer (format "*drgnx merge: %s*" (buffer-name buffer))
      (drgnx-history-merge-keep-mine))
    (should (equal (with-current-buffer buffer (buffer-string)) "disk one\nmine\n"))
    (should (verify-visited-file-modtime buffer))
    (should-not drgnx-history-revert--waiting)
    (should-not (get-buffer (format "*drgnx merge: %s*" (buffer-name buffer))))))

(ert-deftest drgnx-history/an-unproven-hub-changes-no-buffer ()
  ;; B: an event on a connection that did not prove itself is ignored
  (drgnx-history-revert-test--project
    (process-put conn :drgnx-proven nil)
    (with-temp-file file (insert "disk two\n"))
    (drgnx-history-revert--event "history/applied" (list :op 5 :paths '("a.txt") :worktree (directory-file-name dir)))
    (should (equal (with-current-buffer buffer (buffer-string)) "disk one\n"))))

;;;; The real hub

(ert-deftest drgnx-history/refusal-reaches-the-user ()
  ;; B: the real hub refuses a revert of a session it does not know; the command signals what the hub said and opens no card
  (drgnx-hub-client-test--with-hub
    (drgnx-test-gated '((:answers t))
      (drgnx-hub-call-sync "ping" nil 10)
      (unwind-protect
          (let ((err (condition-case e (progn (drgnx-history-revert-to-here "no-such-session" 1) nil) (error e))))
            (drgnx-test-deliver-all)
            (should err)
            (should (string-prefix-p "drgnx hub:" (cadr err)))
            (should-not (cl-some (lambda (b) (string-prefix-p "*drgnx revert" (buffer-name b))) (buffer-list))))
        (drgnx-history-revert-test--kill-cards)))))

(provide 'history-revert-test)
;;; history-revert-test.el ends here
