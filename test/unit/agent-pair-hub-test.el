;;; agent-pair-hub-test.el --- batch tests: pair mode's editor side against a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process (a test-hooks Ratatoskr behind the delivery gate); this Emacs plays the editor with
;; the module tools/agent-pair on.  The chat is `ratatoskr-mock acp --as claude' (beside the hub's binary), which
;; calls the drgnx tools a message names, so no provider is called.  The agent is a real child: what it did is a
;; condition the test settles on after each release of the hub's lines, never a deadline.  A write the test wants
;; held stays queued because a command "runs" (`drgnx-agent-pair--commands'), as it would while you type.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(require 'drgnx-notice)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers
(load (expand-file-name "modules/tools/drgnx-agent-pair" drgnx-dir) t t)

(defmacro drgnx-agent-pair-hub-test--with (&rest body)
  "BODY inside `drgnx-test-gated' with a gated Ratatoskr serving drgnx's dirs under ROOT, the profile \"mock-claude\",
`project' a folder holding README (\"readme\"), the module tools/agent-pair on and this Emacs subscribed.  Skipped
without the binary."
  (declare (indent 0))
  `(drgnx-hub-client-test--with-hub
     (let* ((project (file-name-as-directory (concat root "project")))
            (drgnx-test-gate-unnamed-ok t))
       (make-directory project t)
       (with-temp-file (concat project "README") (insert "readme\n"))
       (drgnx-test-write-settings
        (concat root "config/settings.el")
        'drgnx-agents-matrix '(:preset autonomous)
        'drgnx-agents-profiles
        (list (list "mock-claude" :provider 'claude
                    :command (list (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-hub-client-test--bin)))
                                   "acp" "--as" "claude"))))
       (drgnx-test-gated '()
         (unwind-protect
             (let ((env process-environment))
               (drgnx-test-with-modules '(tools/agent-pair)
                 ;; the module fixture's own dirs are for the module's state; the hub's socket is under ROOT's
                 (let ((process-environment env))
                   (drgnx-hub-connect)
                   (drgnx-agent-pair-hub-test--settle (lambda () (process-live-p drgnx-hub--events)) "the subscription")
                   ,@body)))
           (dolist (b (buffer-list))
             (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b)))
               (with-current-buffer b (set-buffer-modified-p nil))
               (kill-buffer b)))
           (drgnx-notice-clear 'hub))))))

(defun drgnx-agent-pair-hub-test--settle (pred what)
  "Wait until PRED holds, the hub's clock moved and what it has written released before each look."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (funcall pred)) :what what))

(defun drgnx-agent-pair-hub-test--ask (method params)
  "The hub's answer to METHOD with PARAMS as (RESULT . ERROR), asked without a wait of its own."
  (let (done answer)
    (drgnx-hub-call method params (lambda (r e) (setq answer (cons r e) done t)))
    (drgnx-agent-pair-hub-test--settle (lambda () done) (format "the hub's answer to %s" method))
    answer))

(defun drgnx-agent-pair-hub-test--chat (project)
  "A chat of \"mock-claude\" in PROJECT, paired: its id."
  (let ((sid (plist-get (car (drgnx-agent-pair-hub-test--ask "agents/start" (list :profile "mock-claude" :cwd project)))
                        :id)))
    (should (stringp sid))
    (should (eq (car (drgnx-agent-pair-hub-test--ask "agents/pair" (list :id sid :on t))) t))
    sid))

(defun drgnx-agent-pair-hub-test--send (sid &rest calls)
  "Ask chat SID to make CALLS, each \"TOOL ARGS-JSON\" (the mock agent's `call:' lines)."
  (should (eq (car (drgnx-agent-pair-hub-test--ask
                    "agents/send" (list :id sid :text (mapconcat (lambda (c) (concat "call:" c)) calls "\n"))))
              t)))

(defun drgnx-agent-pair-hub-test--session (sid)
  "Chat SID's snapshot and entries: (SESSION . ENTRIES)."
  (let ((r (car (drgnx-agent-pair-hub-test--ask "agents/get" (list :id sid)))))
    (cons (plist-get r :session) (plist-get r :entries))))

(defun drgnx-agent-pair-hub-test--said (sid text)
  "Wait until chat SID's transcript holds TEXT in an agent entry (the mock says each tool's answer)."
  (let ((asked nil) (found nil))
    (drgnx-agent-pair-hub-test--settle
     (lambda ()
       (unless asked
         (setq asked t)
         (drgnx-hub-call "agents/get" (list :id sid)
                         (lambda (r _e)
                           (setq asked nil)
                           (when (cl-some (lambda (e) (and (equal (plist-get e :type) "agent")
                                                           (string-search text (or (plist-get e :text) ""))))
                                          (plist-get r :entries))
                             (setq found t)))))
       found)
     (format "the agent said %S" text))))

(defun drgnx-agent-pair-hub-test--idle (sid &optional unpaired)
  "Wait until chat SID's turn ended by itself (idle), and with UNPAIRED until its snapshot says `paired' false too:
the `agents/get' answer."
  (let ((asked nil) (found nil))
    (drgnx-agent-pair-hub-test--settle
     (lambda ()
       (unless asked
         (setq asked t)
         (drgnx-hub-call "agents/get" (list :id sid)
                         (lambda (r _e)
                           (setq asked nil)
                           (let ((s (plist-get r :session)))
                             (when (and (equal (plist-get s :status) "idle")
                                        (or (not unpaired) (and (plist-member s :paired) (not (plist-get s :paired)))))
                               (setq found r))))))
       found)
     "the turn ended")))

(defun drgnx-agent-pair-hub-test--edit (file)
  "The mock's `edit_file' of FILE, readme → README."
  (format "edit_file {\"path\": %s, \"old\": \"readme\", \"new\": \"README\"}" (json-serialize file)))

(defun drgnx-agent-pair-hub-test--read (file)
  (format "read_file {\"path\": %s}" (json-serialize file)))

;;;; Task: the queue and the open set

(ert-deftest drgnx-agent-pair-hub/read-serves-unsaved-text ()
  "A paired chat's `read_file' of a file open here gets the buffer's text, unsaved edits included."
  (drgnx-agent-pair-hub-test--with
    (let* ((file (concat project "README")) (buf (find-file-noselect file)))
      (with-current-buffer buf (goto-char (point-max)) (insert "unsaved\n"))
      (let ((sid (drgnx-agent-pair-hub-test--chat project)))
        (drgnx-agent-pair-hub-test--send sid (drgnx-agent-pair-hub-test--read file))
        (drgnx-agent-pair-hub-test--said sid "call: readme\nunsaved\n")
        (drgnx-test-deliver-all)
        (should (buffer-modified-p buf))))))

(ert-deftest drgnx-agent-pair-hub/open-and-closed-reach-the-hub ()
  "The hub reads a file from the editor while a buffer has it open (`pair/open', from `find-file-hook') and from the
disk once the buffer is killed (`pair/closed', from `kill-buffer-hook'), where a write then lands too."
  (drgnx-agent-pair-hub-test--with
    (let* ((file (concat project "README")) (buf (find-file-noselect file)))
      (with-current-buffer buf (goto-char (point-max)) (insert "unsaved\n"))
      (let ((sid (drgnx-agent-pair-hub-test--chat project)))
        (drgnx-agent-pair-hub-test--send sid (drgnx-agent-pair-hub-test--read file))
        (drgnx-agent-pair-hub-test--said sid "call: readme\nunsaved\n")
        (drgnx-agent-pair-hub-test--idle sid)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)
        (drgnx-agent-pair-hub-test--send sid (drgnx-agent-pair-hub-test--read file) (drgnx-agent-pair-hub-test--edit file))
        ;; from the disk now, and a write of a file no editor has open lands on the disk (the hub writes it)
        (drgnx-agent-pair-hub-test--said sid "call: readme\ncall: written to the file on disk (no editor has it open)")
        (drgnx-test-deliver-all)
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "README\n"))))))

(ert-deftest drgnx-agent-pair-hub/open-set-is-resent-after-a-restart ()
  "A new subscription (after the hub went away or this Emacs reconnected) sends the whole open set again: the hub
reads the open buffer's text, not the disk's."
  (drgnx-agent-pair-hub-test--with
    (let* ((file (concat project "README")) (buf (find-file-noselect file)))
      (with-current-buffer buf (goto-char (point-max)) (insert "unsaved\n"))
      (let ((old drgnx-hub--events))
        (drgnx-hub-disconnect)
        (drgnx-hub-connect)
        (drgnx-agent-pair-hub-test--settle (lambda () (and (process-live-p drgnx-hub--events)
                                                           (not (eq drgnx-hub--events old))))
                                           "the new subscription"))
      (let ((sid (drgnx-agent-pair-hub-test--chat project)))
        (drgnx-agent-pair-hub-test--send sid (drgnx-agent-pair-hub-test--read file))
        (drgnx-agent-pair-hub-test--said sid "call: readme\nunsaved\n")
        (drgnx-test-deliver-all)))))

(ert-deftest drgnx-agent-pair-hub/a-never-cell-drops-the-queued-writes ()
  "A write waits in the queue (a command runs); the matrix then makes the chat's `chat.project-edit' never: the hub
sends `pair-drop', the write is answered dropped and never lands, and the agent is told why."
  (drgnx-agent-pair-hub-test--with
    (let* ((file (concat project "README")) (buf (find-file-noselect file))
           (drgnx-agent-pair--commands 1)
           (sid (drgnx-agent-pair-hub-test--chat project)))
      (drgnx-agent-pair-hub-test--send sid (drgnx-agent-pair-hub-test--edit file))
      (drgnx-agent-pair-hub-test--settle (lambda () (buffer-local-value 'drgnx-agent-pair--queue buf)) "the write queued")
      (let ((write (plist-get (car (buffer-local-value 'drgnx-agent-pair--queue buf)) :write)))
        ;; the editor's own matrix rows: chat.project-edit never for every chat
        (should-not (cdr (drgnx-agent-pair-hub-test--ask
                          "config/settings"
                          (list :overrides
                                (vector (list :name "drgnx-agents-matrix" :source "row"
                                              :value (list :cells (vector (list :action "chat.project-edit"
                                                                                :column (list :role "chat")
                                                                                :verdict "never")))))))))
        (drgnx-agent-pair-hub-test--settle (lambda () (null (buffer-local-value 'drgnx-agent-pair--queue buf)))
                                           "the queue dropped")
        (should (equal (plist-get (drgnx-agent-pair-answer-of write) :result) "dropped"))
        (should (equal (plist-get (drgnx-agent-pair-answer-of write) :reason) "never"))
        (drgnx-agent-pair-hub-test--said sid "chat.project-edit is now never")
        (drgnx-test-deliver-all)
        (should (equal (with-current-buffer buf (buffer-string)) "readme\n"))))))

;;;; Task: the toggle and the module

(defun drgnx-agent-pair-hub-test--held-write (project)
  "A paired chat in PROJECT whose first of two `edit_file' calls on README waits in the queue (a command runs, so the
caller binds `drgnx-agent-pair--commands'): (SID BUFFER WRITE)."
  (let* ((file (concat project "README")) (buf (find-file-noselect file))
         (sid (drgnx-agent-pair-hub-test--chat project)))
    (drgnx-agent-pair-hub-test--send sid (drgnx-agent-pair-hub-test--edit file) (drgnx-agent-pair-hub-test--edit file))
    (drgnx-agent-pair-hub-test--settle (lambda () (buffer-local-value 'drgnx-agent-pair--queue buf)) "the write queued")
    (list sid buf (plist-get (car (buffer-local-value 'drgnx-agent-pair--queue buf)) :write))))

(ert-deftest drgnx-agent-pair-hub/toggle-reaches-the-hub-and-cancels-nothing ()
  "Turning Pair off for a chat with a write queued here: the hub has it off, the queued write is dropped and never
lands, and the chat's turn goes on to its next call and ends by itself."
  (drgnx-agent-pair-hub-test--with
    (let ((drgnx-agent-pair--commands 1))
      (pcase-let ((`(,sid ,buf ,write) (drgnx-agent-pair-hub-test--held-write project)) (done nil))
        (drgnx-agent-pair-set sid nil (lambda (r e) (setq done (list r e))))
        (drgnx-agent-pair-hub-test--settle (lambda () done) "the toggle's answer")
        (should (equal done '(t nil)))
        (drgnx-agent-pair-hub-test--settle (lambda () (null (buffer-local-value 'drgnx-agent-pair--queue buf)))
                                           "the queue dropped")
        (should (equal (plist-get (drgnx-agent-pair-answer-of write) :reason) "pair-off"))
        (drgnx-agent-pair-hub-test--said sid "call: pair mode was turned off by the usercall: ")
        (let ((r (drgnx-agent-pair-hub-test--idle sid)))
          (should (plist-member (plist-get r :session) :paired))
          (should-not (plist-get (plist-get r :session) :paired))
          (should (cl-find "stop" (plist-get r :entries) :key (lambda (e) (plist-get e :type)) :test #'equal)))
        (drgnx-test-deliver-all)
        (should (equal (with-current-buffer buf (buffer-string)) "readme\n"))))))

(ert-deftest drgnx-agent-pair-hub/module-off-turns-pair-off-and-cancels-nothing ()
  "Turning tools/agent-pair off with a write queued: the write is dropped, the hub has the chat unpaired and routes
nothing here, nothing of the chat's turn is cancelled, and nothing applied is undone."
  (drgnx-agent-pair-hub-test--with
    (let ((drgnx-agent-pair--commands 1))
      (pcase-let ((`(,sid ,buf ,_write) (drgnx-agent-pair-hub-test--held-write project)))
        (should-not (drgnx-module-teardown 'tools/agent-pair))
        (should-not (buffer-local-value 'drgnx-agent-pair--queue buf))
        (drgnx-agent-pair-hub-test--said sid "call: pair mode was turned off by the user")
        (let ((r (drgnx-agent-pair-hub-test--idle sid t)))
          (should (cl-find "stop" (plist-get r :entries) :key (lambda (e) (plist-get e :type)) :test #'equal)))
        (drgnx-test-deliver-all)
        (should (equal (with-current-buffer buf (buffer-string)) "readme\n"))))))

;;; agent-pair-hub-test.el ends here
