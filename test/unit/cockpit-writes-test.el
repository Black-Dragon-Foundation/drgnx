;;; cockpit-writes-test.el --- batch tests: the editor's five writes are hub calls -*- lexical-binding: t -*-
;; The cockpit writes nothing to work.db: cards/settle, messages/send, messages/mark, events/add and review/mark go to
;; the hub (docs/develop/coordination.md, "The editor writes through the hub").  Here the hub is stubbed (it records
;; each call and answers as ANSWER says) and `drgnx-coord-writer' is `refuse'; the last test runs the real thing.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)   ; a fresh notice model: the real `drgnx-notify' runs

(defvar drgnx-coord-writer)

(defvar drgnx-cockpit-writes-test--writers
  '(drgnx-coord-send drgnx-coord-mark drgnx-coord-event-add drgnx-coord-event-add-best-effort drgnx-coord-card-settle
                     drgnx-coord-card-create drgnx-coord-card-set drgnx-coord-review-mark drgnx-coord-job-create drgnx-coord-job-set
                     drgnx-coord-force-status drgnx-coord-claim drgnx-coord-heartbeat drgnx-coord-renew drgnx-coord-release-stale
                     drgnx-coord-set-status drgnx-coord-decide drgnx-coord-agent-register drgnx-coord-agent-seen drgnx-coord-note-held
                     drgnx-coord-set-seen drgnx-coord-events-prune drgnx-coord-events-prune-daily sqlite-execute)
  "The writers of work.db's coordination tables, and the raw write.")

(defmacro drgnx-cockpit-writes-test--editor (&rest body)
  "BODY with the hub stubbed and the store's writer `refuse': CALLS is the hub calls newest first ((METHOD . PARAMS)…),
SAID what `message' said, newest first; ANSWER (a function of METHOD and PARAMS → (RESULT ERROR), default (t nil)) is
what the hub answers.  The pane's agent is AGENT of JOB, with no session; SRC is its edit source."
  (declare (indent 0))
  `(let ((drgnx-coord-writer 'refuse) (calls nil) (said nil) (answer nil)
         (drgnx-cockpit-edits--id "a1") (drgnx-cockpit-edits--job "j1") (drgnx-cockpit-edits--name "agent a1")
         (src (list :kind 'job :job "j1"))
         (drgnx-cockpit-edits--info (make-hash-table :test 'equal))
         (drgnx-cockpit-feed--in-flight nil) (read nil) (patched nil))
     (ignore src read patched)
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params cb &rest _)
                  (push (cons method params) calls)
                  (let ((r (if answer (funcall answer method params)
                             ;; each method's real answer shape (Task 9): the product reads these
                             (list (pcase method
                                     ("cards/settle" (list :settled t))
                                     ("messages/mark" (list :changed t))
                                     ("events/add" (list :id 1))
                                     ("messages/send" (list :ok t :id 1 :state "queued"))
                                     (_ t))
                                   nil))))
                    (funcall cb (car r) (cadr r)))
                  1))
               ((symbol-function 'message) (lambda (f &rest a) (when f (push (apply #'format f a) said))))
               ((symbol-function 'drgnx-cockpit-feed--changed) #'ignore)
               ((symbol-function 'drgnx-cockpit-cards--changed) #'ignore)
               ((symbol-function 'drgnx-cockpit-cards--hub) #'ignore)
               ((symbol-function 'drgnx-cockpit-feed--name) (lambda (a) a))
               ((symbol-function 'drgnx-cockpit-feed--session) #'ignore)
               ((symbol-function 'drgnx-cockpit-edits--session) #'ignore)
               ((symbol-function 'drgnx-cockpit-edits--here) #'ignore)
               ((symbol-function 'drgnx-cockpit-edits--read-source) (lambda () src))
               ((symbol-function 'drgnx-cockpit-edits--read-marks) (lambda () (push 'marks read)))
               ((symbol-function 'drgnx-cockpit-edits--patch-headers) (lambda (files) (push files patched)))
               ((symbol-function 'drgnx-wb-display-name) #'identity)
               ((symbol-function 'drgnx-coord-version) (lambda () 42)))
       (drgnx-notice-test-with-model ,@body))))

(defun drgnx-cockpit-writes-test--methods (calls)
  "CALLS' method names, oldest first."
  (mapcar #'car (reverse calls)))

(ert-deftest drgnx-cockpit-feed/answer-settles-then-adds-the-answer-and-marks ()
  (drgnx-cockpit-writes-test--editor
    ;; a job's message: the hub's job/reply, then the answer event, then the message marked acted
    (should (eq 'job (drgnx-cockpit-answer (list :id 5 :kind "question" :agent "a1" :job "j1" :data (list :message 9)) "this way")))
    (should (equal (drgnx-cockpit-writes-test--methods calls) '("job/reply" "events/add" "messages/mark")))
    (should (equal (cdr (assoc "events/add" calls))
                   (list :kind "answer" :agent "user" :job "j1" :summary "this way" :data (list :question 5))))
    (should (equal (cdr (assoc "messages/mark" calls)) (list :id 9 :state "acted")))
    ;; an ask card: cards/settle (which writes the answer itself), then the message marked
    (setq calls nil)
    (should (eq 'card (drgnx-cockpit-answer (list :id 6 :kind "question" :agent "a1" :job "j1" :card 3 :data (list :message 9)) "bar")))
    (should (equal (drgnx-cockpit-writes-test--methods calls) '("cards/settle" "messages/mark")))
    (should (equal (cdr (assoc "cards/settle" calls)) (list :card 3 :choice "bar")))))

(ert-deftest drgnx-cockpit-feed/a-settled-card-says-so ()
  (drgnx-cockpit-writes-test--editor
    (setq answer (lambda (_m _p) (list (list :settled nil) nil)))
    (drgnx-cockpit-answer (list :id 6 :kind "question" :agent "a1" :job "j1" :card 3 :data (list :message 9)) "bar")
    (should (member "That card was settled already" said))
    (should-not (member "Answer queued for a1: it never interrupts" (cdr said)))
    (should (equal (drgnx-cockpit-writes-test--methods calls) '("cards/settle")))))

(ert-deftest drgnx-cockpit-feed/queue-sends-a-message ()
  (drgnx-cockpit-writes-test--editor
    (let ((done 0))
      (should (eq 'message (drgnx-cockpit-feed--queue "a1" "hello" (lambda () (cl-incf done)) nil 4)))
      (should (equal calls (list (cons "messages/send" (list :recipient "a1" :text "hello" :answers 4)))))
      (should (= done 1)))))

(ert-deftest drgnx-cockpit-feed/a-held-message-shows-its-reason ()
  (drgnx-cockpit-writes-test--editor
    (setq answer (lambda (_m _p) (list (list :ok t :id 7 :state "held" :reason "queue full") nil)))
    (let ((done 0))
      (drgnx-cockpit-feed--queue "a1" "hello" (lambda () (cl-incf done)))
      (should (= done 0))
      (should (equal said '("Work cockpit: held, not sent — queue full"))))))

(ert-deftest drgnx-cockpit-cards/message-from-a-card-carries-the-version ()
  (drgnx-cockpit-writes-test--editor
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "hi")))
      (drgnx-cockpit-cards--message "j1" "a1"))
    (should (equal calls (list (cons "messages/send" (list :job "j1" :recipient "a1" :text "hi" :seen 42)))))))

(ert-deftest drgnx-cockpit-edits/accept-file-marks-with-its-event-in-one-call ()
  (drgnx-cockpit-writes-test--editor
    (puthash "README" (list :hash "abc") drgnx-cockpit-edits--info)
    (drgnx-cockpit-edits-accept-file "README")
    (should (equal calls
                   (list (cons "review/mark"
                               (list :agent "a1" :path "README" :state "accepted" :hash "abc"
                                     :event (list :kind "accept" :job "j1" :summary "you accepted README"
                                                  :data (list :by "user" :path "README" :hash "abc")))))))
    ;; the pane reads the marks again once the hub answered
    (should (equal read '(marks)))
    (should (equal patched '(("README"))))))

(ert-deftest drgnx-cockpit-edits/comment-and-revert-add-events ()
  (drgnx-cockpit-writes-test--editor
    (drgnx-cockpit-edits-comment "README" 3 "name it better")
    (should (equal (drgnx-cockpit-writes-test--methods calls) '("messages/send" "events/add")))
    (should (equal (plist-get (cdr (assoc "messages/send" calls)) :text) "[comment] README:3: name it better"))
    (let ((e (cdr (assoc "events/add" calls))))
      (should (equal (plist-get e :kind) "comment"))
      (should (equal (plist-get (plist-get e :data) :line) 3)))
    (setq calls nil)
    (drgnx-cockpit-edits--request src "README" "README" "")
    (should (equal (drgnx-cockpit-writes-test--methods calls) '("messages/send" "events/add")))
    (let ((e (cdr (assoc "events/add" calls))))
      (should (equal (plist-get e :kind) "revert"))
      (should (plist-get (plist-get e :data) :requested)))
    ;; a held request leaves no event
    (setq calls nil
          answer (lambda (_m _p) (list (list :ok t :id 7 :state "held" :reason "queue full") nil)))
    (drgnx-cockpit-edits--request src "README" "README" "")
    (should (equal (drgnx-cockpit-writes-test--methods calls) '("messages/send")))))

(ert-deftest drgnx-cockpit-feed/no-coord-notify-after-a-send ()
  (drgnx-cockpit-writes-test--editor
    (drgnx-cockpit-feed--queue "a1" "hello" #'ignore)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "hi")))
      (drgnx-cockpit-cards--message "j1" "a1"))
    (drgnx-cockpit-edits--queue src "text")
    (should (= 3 (length calls)))
    (should-not (member "coord/notify" (drgnx-cockpit-writes-test--methods calls)))))

(defun drgnx-cockpit-writes-test--hub-notices ()
  "How many times the hub's errors were posted (the notices of source `hub', their counts added)."
  (apply #'+ (mapcar (lambda (n) (or (plist-get n :count) 1)) (drgnx-notices :source 'hub))))

(ert-deftest drgnx-cockpit-feed/an-error-is-shown-once ()
  ;; each failed write posts one notice, "drgnx hub: TEXT" (the real Notices model; a repeat counts)
  (drgnx-cockpit-writes-test--editor
    (setq answer (lambda (_m _p) (list nil "boom")))
    (drgnx-cockpit-feed--queue "a1" "hello" #'ignore)
    (should (equal (mapcar (lambda (n) (plist-get n :text)) (drgnx-notices :source 'hub)) '("drgnx hub: boom")))
    (should (= 1 (drgnx-cockpit-writes-test--hub-notices)))
    (drgnx-cockpit-edits--event "comment" "s" nil)
    (should (= 2 (drgnx-cockpit-writes-test--hub-notices)))
    (drgnx-cockpit-answer (list :id 6 :kind "question" :agent "a1" :job "j1" :card 3) "bar")
    (should (= 3 (drgnx-cockpit-writes-test--hub-notices)))))

(ert-deftest drgnx-cockpit/no-writer-call-in-the-modules ()
  ;; static: no symbol of a coordination writer, nor `sqlite-execute', in the cockpit's modules or its model
  (let ((files (append (directory-files (expand-file-name "modules/tools" drgnx-dir) t "\\`drgnx-cockpit.*\\.el\\'")
                       (list (expand-file-name "core/drgnx-cockpit-model.el" drgnx-dir))))
        (found nil))
    (should (cl-plusp (length files)))
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let (form)
          (while (condition-case nil (progn (setq form (read (current-buffer))) t) (end-of-file nil))
            (let ((walk nil))
              (setq walk (lambda (x)
                           (cond ((consp x) (funcall walk (car x)) (funcall walk (cdr x)))
                                 ((vectorp x) (mapc walk x))
                                 ((and x (symbolp x) (memq x drgnx-cockpit-writes-test--writers))
                                  (push (format "%s: %s" (file-name-nondirectory file) x) found)))))
              (funcall walk form))))))
    (should-not found)))

(ert-deftest drgnx-cockpit-feed/writes-nothing-directly ()
  ;; the gate's runtime half: every write path runs with the writer `refuse' and the stubbed hub, with no error
  (drgnx-cockpit-writes-test--editor
    (drgnx-cockpit-answer (list :id 5 :kind "question" :agent "a1" :job "j1" :data (list :message 9)) "this way")
    (drgnx-cockpit-answer (list :id 6 :kind "question" :agent "a1" :job "j1" :card 3) "bar")
    (drgnx-cockpit-feed--queue "a1" "hello" #'ignore)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "hi")))
      (drgnx-cockpit-cards--message "j1" "a1"))
    (drgnx-cockpit-edits-comment "README" 1 "c")
    (puthash "README" (list :hash "abc") drgnx-cockpit-edits--info)
    (drgnx-cockpit-edits-accept-file "README")
    (should (cl-every (lambda (m) (member m '("job/reply" "events/add" "messages/mark" "cards/settle" "messages/send" "review/mark")))
                      (drgnx-cockpit-writes-test--methods calls)))))

;;;; Binary: the real hub

(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers

(ert-deftest drgnx-cockpit-feed/an-answer-reaches-the-store-through-ratatoskr ()
  ;; binary + Lisp backend: an ask card made with `coord/card-create'; the answer settles it in work.db
  (drgnx-hub-client-test--with-ratatoskr
    (drgnx-hub-client-test--backend-up)
    (let ((id (plist-get (drgnx-hub-call-sync "coord/card-create" (list :job "j1" :kind "ask" :title "which?") 10) :id)))
      (should (natnump id))
      (cl-letf (((symbol-function 'drgnx-cockpit-feed--changed) #'ignore))
        (should (eq 'card (drgnx-cockpit-answer (list :kind "question" :agent "a1" :job "j1" :card id) "this one"))))
      (drgnx-hub-client-test--wait (lambda () (equal (plist-get (drgnx-coord-card id) :state) "settled")) "the card is settled")
      (should (equal (plist-get (drgnx-coord-card id) :choice) "this one")))))

;;; cockpit-writes-test.el ends here
