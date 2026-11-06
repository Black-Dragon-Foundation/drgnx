;;; agent-panel-hub-test.el --- batch tests: the agent panel against a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process; this Emacs plays the editor inside the delivery gate (`drgnx-test-gated').  The
;; agent is a real child (mock-acp) whose turns run in real time: what it did is a condition the test sees after each
;; release of the hub's lines (the helpers of agents-mirror-test.el), never a deadline.  Skipped without the hub binary.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-modules)
(require 'drgnx-agents)
(require 'drgnx-hub-client)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures
(load (expand-file-name "modules/tools/drgnx-agent-panel" drgnx-dir) nil t)
(defvar drgnx-hub-event-functions)
(declare-function drgnx-agent-panel--event "drgnx-agent-panel")
(declare-function drgnx-agent-panel-buffers "drgnx-agent-panel")

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel-sync-windows "drgnx-agent-panel")
(declare-function drgnx-agent-panel-older "drgnx-agent-panel")
(defvar drgnx-agent-panel--entries)
(defvar drgnx-agent-panel--subscribed)
(defvar drgnx-agent-panel--loaded)
(defvar drgnx-agent-panel--more)
(defvar drgnx-agent-panel--steps)
(defvar drgnx-agent-panel-page-steps)

(defmacro drgnx-agent-panel-hub-test--with (&rest body)
  "BODY with a gated hub, the panel listening to the hub's events and this Emacs connected; `id' is a started mock
session.  The module's own setup is not used: the module fixture moves the config, and the hub's socket with it."
  (declare (indent 0))
  `(drgnx-agents-mirror-test--with '()
     (save-window-excursion
       (delete-other-windows)
       (add-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
       (unwind-protect
           (progn
             (drgnx-agents-mirror-sync)           ; connects, and mirrors the sessions the helpers wait on
             (let ((id (plist-get (drgnx-agents-mirror-test--ask "agents/start" (list :profile "mock" :cwd (getenv "HOME"))) :id)))
               ,@body))
         (remove-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
         (mapc #'kill-buffer (drgnx-agent-panel-buffers))))))

(defun drgnx-agent-panel-hub-test--entry-text (buf)
  (with-current-buffer buf
    (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) (plist-get e :title) "")))
               (hash-table-values drgnx-agent-panel--entries) " ")))

(defun drgnx-agent-panel-hub-test--turn (id text)
  (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text text)))

(ert-deftest drgnx-agent-panel/subscribes-only-while-shown ()
  (drgnx-agent-panel-hub-test--with
    (let ((buf (drgnx-agent-panel-buffer id)) (other (get-buffer-create "*panel-other*")))
      (unwind-protect
          (progn
            ;; hidden: nothing is subscribed and a turn leaves no entry in the panel
            (set-window-buffer (selected-window) other)
            (drgnx-agent-panel-sync-windows)
            (should-not (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (drgnx-agent-panel-hub-test--turn id "hidden turn")
            (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the hidden turn over")
            (should-not (string-search "hidden turn" (drgnx-agent-panel-hub-test--entry-text buf)))
            ;; shown: subscribed, the last page comes and the next turn arrives as entries
            (set-window-buffer (selected-window) buf)
            (drgnx-agent-panel-sync-windows)
            (should (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-agent-panel--loaded buf)) "the first page")
            (drgnx-agent-panel-hub-test--turn id "shown turn")
            (drgnx-agents-mirror-test--settle
             (lambda () (string-search "You said: shown turn" (drgnx-agent-panel-hub-test--entry-text buf)))
             "the shown turn's entries in the panel")
            ;; hidden again: unsubscribed, and the next turn's entries do not come
            (set-window-buffer (selected-window) other)
            (drgnx-agent-panel-sync-windows)
            (should-not (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (drgnx-agent-panel-hub-test--turn id "later turn")
            (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the later turn over")
            (should-not (string-search "later turn" (drgnx-agent-panel-hub-test--entry-text buf))))
        (kill-buffer other)))))

(ert-deftest drgnx-agent-panel/pages-back-50-steps ()
  ;; the page size is lowered to 2 so that three tool turns make two pages; 50 is the hub's own limit for it
  (drgnx-agent-panel-hub-test--with
    (let ((drgnx-agent-panel-page-steps 2) (buf (drgnx-agent-panel-buffer id)))
      (dotimes (i 3)
        (drgnx-agent-panel-hub-test--turn id (format "tool %d" i))
        (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "a tool turn over"))
      (set-window-buffer (selected-window) buf)
      (drgnx-agent-panel-sync-windows)
      (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-agent-panel--loaded buf)) "the last page")
      (let ((first-count (hash-table-count (buffer-local-value 'drgnx-agent-panel--steps buf))))
        (should (<= first-count 2))
        (should (buffer-local-value 'drgnx-agent-panel--more buf))
        (with-current-buffer buf (drgnx-agent-panel-older))
        (drgnx-agents-mirror-test--settle
         (lambda () (> (hash-table-count (buffer-local-value 'drgnx-agent-panel--steps buf)) first-count))
         "the page before")))))

(declare-function drgnx-agent-panel-send "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-edit-queued "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-drop-queued "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer--read "drgnx-agent-panel-composer")
(defvar drgnx-agent-panel--snap)

(defun drgnx-agent-panel-hub-test--show (buf)
  (set-window-buffer (selected-window) buf)
  (drgnx-agent-panel-sync-windows)
  (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-agent-panel--loaded buf)) "the first page"))

(defun drgnx-agent-panel-hub-test--send (buf text)
  (with-current-buffer buf
    (cl-letf (((symbol-function 'drgnx-agent-panel-composer--read) (lambda (_) text)))
      (drgnx-agent-panel-send))))

(defun drgnx-agent-panel-hub-test--queue (buf) (append (plist-get (buffer-local-value 'drgnx-agent-panel--snap buf) :queue) nil))

(ert-deftest drgnx-agent-panel/send-never-cancels-a-turn ()
  (drgnx-agent-panel-hub-test--with
    (let ((buf (drgnx-agent-panel-buffer id)))
      (drgnx-agent-panel-hub-test--show buf)
      (drgnx-agent-panel-hub-test--turn id "slow")
      (drgnx-agents-mirror-test--settle (lambda () (eq 'busy (drgnx-agent-session-status (drgnx-agents-mirror-test--mirror id))))
                                        "the slow turn running")
      (drgnx-agent-panel-hub-test--send buf "second message")
      ;; the slow turn runs to its end, and the message goes in after it
      (drgnx-agents-mirror-test--settle
       (lambda () (string-search "You said: second message" (drgnx-agent-panel-hub-test--entry-text buf)))
       "the second message answered")
      (should-not (cl-some (lambda (e) (equal (plist-get e :stop) "cancelled"))
                           (hash-table-values (buffer-local-value 'drgnx-agent-panel--entries buf)))))))

(ert-deftest drgnx-agent-panel/unqueue-and-requeue ()
  (drgnx-agent-panel-hub-test--with
    (let ((buf (drgnx-agent-panel-buffer id)))
      (drgnx-agent-panel-hub-test--show buf)
      (drgnx-agent-panel-hub-test--turn id "slow")
      (drgnx-agents-mirror-test--settle (lambda () (eq 'busy (drgnx-agent-session-status (drgnx-agents-mirror-test--mirror id))))
                                        "the slow turn running")
      (drgnx-agent-panel-hub-test--send buf "keep me")
      (drgnx-agent-panel-hub-test--send buf "drop me")
      (drgnx-agents-mirror-test--settle (lambda () (equal '("keep me" "drop me") (drgnx-agent-panel-hub-test--queue buf)))
                                        "both notes queued in the panel's snapshot")
      (with-current-buffer buf
        (goto-char (point-min))
        (drgnx-view-draw-now drgnx-view)
        (goto-char (drgnx-view-row-start drgnx-view '(:q 0)))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "kept and edited")))
          (drgnx-agent-panel-edit-queued))
        (goto-char (drgnx-view-row-start drgnx-view '(:q 1)))
        (drgnx-agent-panel-drop-queued))
      (drgnx-agents-mirror-test--settle (lambda () (equal '("kept and edited") (drgnx-agent-panel-hub-test--queue buf)))
                                        "the edit and the drop in the snapshot")
      (drgnx-agents-mirror-test--settle
       (lambda () (string-search "You said: kept and edited" (drgnx-agent-panel-hub-test--entry-text buf)))
       "the edited note answered")
      (should-not (string-search "drop me" (drgnx-agent-panel-hub-test--entry-text buf))))))

(load (expand-file-name "modules/tools/drgnx-work-space" drgnx-dir) nil t)   ; the review view the cards call
(declare-function drgnx-agent-panel-accept "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-reject "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-allow "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel--reconcile "drgnx-agent-panel")
(declare-function drgnx-agents-mirror-test--asking "agents-mirror-test")
(defvar drgnx-agent-panel--diffs)

(defmacro drgnx-agent-panel-hub-test--spying (calls-var msgs-var &rest body)
  "BODY with every hub call pushed on CALLS-VAR (METHOD . PARAMS) and every message on MSGS-VAR."
  (declare (indent 2))
  `(cl-letf* ((orig (symbol-function 'drgnx-hub-call))
              ((symbol-function 'drgnx-hub-call)
               (lambda (m p &rest r) (push (cons m p) ,calls-var) (apply orig m p r)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) ,msgs-var)))))
     ,@body))

(defun drgnx-agent-panel-hub-test--card (buf key)
  (with-current-buffer buf
    (drgnx-agent-panel--reconcile)
    (drgnx-view-draw-now drgnx-view)
    (goto-char (drgnx-view-row-start drgnx-view key))))

(ert-deftest drgnx-agent-panel/accept-writes-the-review-mark ()
  (drgnx-agent-panel-hub-test--with
    (let ((buf (drgnx-agent-panel-buffer id)) (diff "@@ -1 +1 @@\n-a\n+b\n") calls msgs)
      (drgnx-agent-panel-hub-test--show buf)
      (with-current-buffer buf (setq drgnx-agent-panel--diffs (list (cons "a.txt" diff))))
      (drgnx-agent-panel-hub-test--card buf '(:diff "a.txt" 0))
      (drgnx-agent-panel-hub-test--spying calls msgs
        (with-current-buffer buf (drgnx-agent-panel-accept))
        (drgnx-agents-mirror-test--settle (lambda () (seq-find (lambda (m) (string-prefix-p "Accepted a.txt" m)) msgs))
                                          "the hub's answer to the review mark"))
      (let ((mark (cdr (assoc "review/mark" calls))))
        (should (equal id (plist-get mark :agent)))
        (should (equal "accepted" (plist-get mark :state)))
        (should (equal (secure-hash 'sha1 diff) (plist-get mark :hash)))))))

(ert-deftest drgnx-agent-panel/reject-queues-the-take-it-back-message ()
  (drgnx-agent-panel-hub-test--with
    (let ((buf (drgnx-agent-panel-buffer id)) (diff "@@ -1 +1 @@\n-a\n+b\n") calls msgs)
      (drgnx-agent-panel-hub-test--show buf)
      (drgnx-agent-panel-hub-test--turn id "slow")
      (drgnx-agents-mirror-test--settle (lambda () (eq 'busy (drgnx-agent-session-status (drgnx-agents-mirror-test--mirror id))))
                                        "the slow turn running")
      (with-current-buffer buf (setq drgnx-agent-panel--diffs (list (cons "a.txt" diff))))
      (drgnx-agent-panel-hub-test--card buf '(:diff "a.txt" 0))
      (drgnx-agent-panel-hub-test--spying calls msgs
        (with-current-buffer buf (drgnx-agent-panel-reject)))
      ;; the message is in the agent's queue, behind the turn that is running, which is not cancelled
      (drgnx-agents-mirror-test--settle
       (lambda () (seq-some (lambda (q) (string-prefix-p "I reject your change to a.txt" q)) (drgnx-agent-panel-hub-test--queue buf)))
       "the take-it-back message queued")
      (should (equal "pending" (plist-get (cdr (assoc "review/mark" calls)) :state)))
      (should (assoc "agents/send" calls))
      (should-not (assoc "agents/stop" calls)))))

(ert-deftest drgnx-agent-panel/allow-answers-the-permission ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-test--asking root)   ; before anything starts: the hub reads the profiles and the matrix then
    (add-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "asks" :role "worker")) (sid (drgnx-agent-session-remote m))
           (buf (drgnx-agent-panel-buffer sid)))
      (drgnx-agent-panel-hub-test--show buf)
      (drgnx-agent-panel-hub-test--turn sid "ask:permission edit")
      (drgnx-agents-mirror-test--settle (lambda () (plist-get (buffer-local-value 'drgnx-agent-panel--snap buf) :permissions))
                                        "the permission request in the panel's snapshot")
      (drgnx-agent-panel-hub-test--card buf (list :perm (plist-get (car (append (plist-get (buffer-local-value 'drgnx-agent-panel--snap buf) :permissions) nil)) :id)))
      (with-current-buffer buf (drgnx-agent-panel-allow))
      (drgnx-agents-mirror-test--settle
       (lambda () (string-search "permission: allow" (drgnx-agent-panel-hub-test--entry-text buf))) "the agent's word on the answer")
      (should-not (plist-get (buffer-local-value 'drgnx-agent-panel--snap buf) :permissions))
      (remove-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
      (mapc #'kill-buffer (drgnx-agent-panel-buffers)))))

(declare-function drgnx-agent-panel-output-open "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-output-more "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-output-search "drgnx-agent-panel-steps")
(defvar drgnx-agent-panel-output--next)
(defvar drgnx-agent-panel-output--total)

(ert-deftest drgnx-agent-panel/open-in-a-buffer-pages-by-range ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-test--asking root)   ; the "asks" profile runs ratatoskr-mock, which knows the tool words
    (add-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "asks" :role "worker")) (id (drgnx-agent-session-remote m))
           (buf (drgnx-agent-panel-buffer id)))
      (drgnx-agent-panel-hub-test--show buf)
      (drgnx-agent-panel-hub-test--turn id "tool:exec yes x | head -c 600000")
      (drgnx-agents-mirror-test--settle
       (lambda () (cl-some (lambda (e) (plist-get e :outputBytes)) (hash-table-values (buffer-local-value 'drgnx-agent-panel--entries buf))))
       "the large tool entry in the panel")
      (let* ((idx (car (seq-filter (lambda (i) (plist-get (gethash i (buffer-local-value 'drgnx-agent-panel--entries buf)) :outputBytes))
                                   (hash-table-keys (buffer-local-value 'drgnx-agent-panel--entries buf)))))
             (out (with-current-buffer buf
                    (drgnx-view-draw-now drgnx-view)
                    (goto-char (drgnx-view-row-start drgnx-view (list :e idx)))
                    (save-window-excursion (drgnx-agent-panel-output-open)))))
        (unwind-protect
            (progn
              ;; the first range only: never the whole output at once
              (drgnx-agents-mirror-test--settle (lambda () (> (buffer-local-value 'drgnx-agent-panel-output--next out) 0)) "the first range")
              (should (= 600000 (buffer-local-value 'drgnx-agent-panel-output--total out)))
              (should (< (buffer-size out) 600000))
              (let ((first (buffer-local-value 'drgnx-agent-panel-output--next out)))
                (with-current-buffer out (drgnx-agent-panel-output-more))
                (drgnx-agents-mirror-test--settle (lambda () (> (buffer-local-value 'drgnx-agent-panel-output--next out) first))
                                                  "the second range")
                (should (= (buffer-size out) (buffer-local-value 'drgnx-agent-panel-output--next out))))
              ;; and the search pages through the same calls
              (with-current-buffer buf (drgnx-agent-panel-output-search "x"))
              (drgnx-agents-mirror-test--settle (lambda () (get-buffer "*drgnx output search: x*")) "the search results")
              (should (string-search "Stopped at 200 matches." (with-current-buffer "*drgnx output search: x*" (buffer-string)))))
          (kill-buffer out)
          (when (get-buffer "*drgnx output search: x*") (kill-buffer "*drgnx output search: x*"))
          (remove-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
          (mapc #'kill-buffer (drgnx-agent-panel-buffers)))))))

;; Pattern B (gate): the reopened panel reads the history through `agents/slice'; the hub's blocks come with it.
(ert-deftest drgnx-agent-panel/a-reopened-sessions-messages-keep-their-styling ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-test--asking root)   ; the "asks" profile runs ratatoskr-mock, whose messages have ids
    (add-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "asks" :role "worker")) (id (drgnx-agent-session-remote m)))
      (drgnx-agent-panel-hub-test--turn id "say a **loud** word")
      (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the turn over")
      ;; the panel opens after the turn: everything it has came as history
      (let ((buf (drgnx-agent-panel-buffer id)))
        (unwind-protect
            (progn
              (drgnx-agent-panel-hub-test--show buf)
              (with-current-buffer buf
                (drgnx-view-draw-now drgnx-view)
                (ert-info ((format "%S" (hash-table-values drgnx-agent-panel--entries)))
                  (should (seq-some (lambda (e) (and (equal (plist-get e :type) "agent") (> (length (plist-get e :blocks)) 0)))
                                    (hash-table-values drgnx-agent-panel--entries))))
                (should-not (string-search "**" (buffer-substring-no-properties (point-min) (point-max))))
                (goto-char (point-min))
                (should (search-forward "loud" nil t))
                (should (memq 'drgnx-agent-panel-md-strong (ensure-list (get-text-property (1- (point)) 'face))))))
          (remove-hook 'drgnx-hub-event-functions #'drgnx-agent-panel--event)
          (mapc #'kill-buffer (drgnx-agent-panel-buffers)))))))

(provide 'agent-panel-hub-test)
;;; agent-panel-hub-test.el ends here
