;;; delivery-gate-test.el --- the delivery gate: the hub's lines released in the schedule a test gives -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub is the real Ratatoskr, built with test-hooks (DRGNX_RATATOSKR_BIN; the tests skip without it), started with
;; its clock and sequencer (`drgnx-test-with-ratatoskr' with `:gated t').  test/fixtures/delivery-gate-fixture.el is
;; the gate; docs/develop/harness.md, "The delivery gate".
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-hub-client)
(require 'drgnx-exec)
(require 'drgnx-ai)
(require 'drgnx-settings-runtime)
(require 'drgnx-settings-agents nil t)
(require 'drgnx-records-review nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)

(defvar drgnx-exec--jobs)
(defvar drgnx-exec--stale)

(defmacro drgnx-delivery-gate-test--with-hub (&rest body)
  "BODY with ROOT a fresh folder, drgnx's dirs under it, and a gated Ratatoskr serving them; this Emacs not connected."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-gate" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY")
                                       process-environment))
          (drgnx-hub--asked-disconnect nil) (drgnx-hub--resubscribe-since nil) (drgnx-hub--resubscribe-delay 1)
          (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil)
          (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil))
     (dolist (d '("config" "data" "state" "home")) (make-directory (concat root d) t))
     (unwind-protect
         (drgnx-test-with-ratatoskr root :gated t ,@body)
       (delete-directory root t))))

(defun drgnx-delivery-gate-test--json (line)
  (and (stringp line) (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil))))

(defun drgnx-delivery-gate-test--answer-held-p (name &optional key)
  "Whether connection NAME holds an answer (with KEY in its result, when given)."
  (cl-some (lambda (line)
             (let ((j (drgnx-delivery-gate-test--json line)))
               (and (plist-get j :id) (not (plist-get j :event))
                    (or (null key) (and (consp (plist-get j :result)) (plist-member (plist-get j :result) key))))))
           (drgnx-test-gate-held name)))

(defun drgnx-delivery-gate-test--shape (entry)
  "A delivery (NAME . LINE) as what it is, not what varies by run (ids, nonces, tokens): (NAME . :eof),
\(NAME :event EVENT), (NAME :error) or (NAME :answer RESULT-KEYS)."
  (cons (car entry)
        (if (eq (cdr entry) :eof) :eof
          (let ((j (drgnx-delivery-gate-test--json (cdr entry))))
            (cond ((plist-get j :event) (list :event (plist-get j :event)))
                  ((plist-get j :error) (list :error))
                  (t (let ((r (plist-get j :result)))
                       (list :answer (and (consp r) (keywordp (car r))
                                          (cl-loop for (k _) on r by #'cddr collect k))))))))))

(defun drgnx-delivery-gate-test--position (pred transcript)
  (cl-position-if pred transcript))

;;;; What the gate holds, and when it lets go

(ert-deftest drgnx-delivery-gate/lines-are-held-until-their-step ()
  "The hub has answered `subscribe', but the client sees the answer only at its step."
  (drgnx-delivery-gate-test--with-hub
    (let (before held)
      (drgnx-test-gated '((call-1 :answer "graph/settings") (:pause "held") (sub-1 :answer "subscribe"))
        (drgnx-hub-connect)
        (drgnx-test-wait (lambda () (drgnx-delivery-gate-test--answer-held-p 'sub-1)) :what "the subscribe answer, held")
        (setq before drgnx-hub--events held (drgnx-test-gate-held 'sub-1))
        (drgnx-test-gate-continue "held")
        (drgnx-test-deliver-all)
        (should-not before)
        (should held)
        (should (eq drgnx-hub--events (drgnx-test-gate-conn 'sub-1)))))))

(ert-deftest drgnx-delivery-gate/a-chunk-of-two-lines-is-two-releases ()
  "What Emacs reads in one chunk (here two lines, the second split over two reads) reaches the client's filter one whole
line per call, each at its own step; so does everything the real hub sends."
  (drgnx-delivery-gate-test--with-hub
    (let* ((chunks nil) (events nil)
           (record (lambda (orig conn chunk) (push (cons conn chunk) chunks) (funcall orig conn chunk))))
      (advice-add 'drgnx-hub--client-filter :around record)
      (unwind-protect
          (drgnx-test-gated '((sub-1 :answer "subscribe") (:pause "inject")
                              (sub-1 :event "drgnx-gate-a") (sub-1 :event "drgnx-gate-b"))
            (add-hook 'drgnx-hub-event-functions (lambda (e _d) (push e events)))
            (drgnx-hub-connect)
            (drgnx-test-wait (lambda () drgnx-hub--events) :what "the subscription")
            (let ((sub (drgnx-test-gate-conn 'sub-1)))
              (funcall (process-filter sub) sub "{\"event\":\"drgnx-gate-a\",\"data\":{}}\n{\"event\":\"drgnx-gate-b\",\"da")
              (funcall (process-filter sub) sub "ta\":{}}\n"))
            (drgnx-test-gate-continue "inject")
            (drgnx-test-deliver-all)
            (should (member "drgnx-gate-a" events))
            (should (member "drgnx-gate-b" events))
            (should (member "{\"event\":\"drgnx-gate-a\",\"data\":{}}\n" (mapcar #'cdr chunks)))
            (should (member "{\"event\":\"drgnx-gate-b\",\"data\":{}}\n" (mapcar #'cdr chunks)))
            (should (cl-every (lambda (c) (let ((s (cdr c)))
                                            (and (string-suffix-p "\n" s) (= 1 (cl-count ?\n s)))))
                              chunks)))
        (advice-remove 'drgnx-hub--client-filter record)))))

(ert-deftest drgnx-delivery-gate/eof-comes-after-the-connections-held-lines ()
  "The hub stops while the subscribe answer is held: the client sees that answer, then the end, and the connection is
open to it until then."
  (drgnx-delivery-gate-test--with-hub
    (let* ((seen nil) held live-while-held
           (line (lambda (conn json) (push (list conn :line (plist-get json :event)) seen)))
           (end (lambda (conn _event) (push (list conn :end) seen))))
      (advice-add 'drgnx-hub--client-line :before line)
      (advice-add 'drgnx-hub--client-sentinel :before end)
      (unwind-protect
          (drgnx-test-gated '((call-1 :answer "graph/settings") (:pause "stop"))
            (drgnx-hub-connect)
            (drgnx-test-wait (lambda () (drgnx-delivery-gate-test--answer-held-p 'sub-1)) :what "the subscribe answer, held")
            (signal-process drgnx-test-ratatoskr-process 'term)
            (drgnx-test-wait (lambda () (memq :eof (drgnx-test-gate-held 'sub-1))) :what "the end of sub-1, held")
            (setq held (drgnx-test-gate-held 'sub-1)
                  live-while-held (process-live-p (drgnx-test-gate-conn 'sub-1))
                  seen nil)
            (drgnx-test-gate-continue "stop")
            (drgnx-test-deliver-all)
            (let* ((sub (drgnx-test-gate-conn 'sub-1))
                   (mine (reverse (cl-remove-if-not (lambda (s) (eq (car s) sub)) seen)))
                   (lines (cl-count-if #'stringp held)))
              (should (>= lines 1))
              (should (eq (car (last held)) :eof))
              (should live-while-held)
              ;; every held line, then the end, which is the last thing the client sees on it
              (should (equal (mapcar #'cadr mine) (append (make-list lines :line) '(:end))))
              (should-not (process-live-p sub))))
        (advice-remove 'drgnx-hub--client-line line)
        (advice-remove 'drgnx-hub--client-sentinel end)))))

;;;; Waits inside the code under test

(ert-deftest drgnx-delivery-gate/a-nested-wait-releases-the-schedule ()
  "`drgnx-hub-call-sync' waits on `accept-process-output' inside itself: the gate releases the handshake and the step
there, so it returns with no help from the test, and no virtual time passed."
  (drgnx-delivery-gate-test--with-hub
    (let (result now)
      (drgnx-test-gated '((call-1 :answer "ping"))
        (setq result (drgnx-hub-call-sync "ping" nil)
              now (drgnx-test-clock-now))
        (drgnx-test-deliver-all)
        (should (natnump (plist-get result :pid)))
        (should (= now 0))))))

(ert-deftest drgnx-delivery-gate/a-nested-wait-on-a-held-line-fails-naming-the-step ()
  "At a pause, `drgnx-hub-call-sync' waiting for a line the gate holds fails the test at once (no deadline, no pass),
naming the pause, the next step and the caller."
  (drgnx-delivery-gate-test--with-hub
    (let* ((err (should-error (drgnx-test-gated '((:pause "held") (call-1 :answer "ping"))
                                (drgnx-hub-call-sync "ping" nil))
                              :type 'ert-test-failed))
           (data (cdr (cadr err))))
      (should (string-match-p "paused" (car (cadr err))))
      (should (equal (plist-get data :pause) "held"))
      (should (equal (plist-get data :next) '(call-1 :answer "ping")))
      (should (eq (plist-get data :caller) 'drgnx-hub-call-sync))
      ;; at its first wait: not one virtual tick toward the call's deadline went by
      (should (equal (plist-get data :virtual-secs) 0.0)))))

(ert-deftest drgnx-delivery-gate/a-deleted-connection-gets-nothing-it-held ()
  "The client deletes a connection while the gate holds its lines: its sentinel runs once, at the delete, and nothing
it held is delivered after."
  (drgnx-delivery-gate-test--with-hub
    (let ((runs 0) runs-at-delete held after-delete)
      (drgnx-test-gated '((call-1 :answer "graph/settings") (:pause "held"))
        (drgnx-hub-connect)
        (add-function :after (process-sentinel (drgnx-test-gate-conn 'sub-1)) (lambda (_p _e) (cl-incf runs)))
        (drgnx-test-wait (lambda () (drgnx-delivery-gate-test--answer-held-p 'sub-1)) :what "the subscribe answer, held")
        (setq held (drgnx-test-gate-held 'sub-1))
        (drgnx-hub-disconnect)
        (setq runs-at-delete runs after-delete (length (drgnx-test-gate-transcript)))
        (drgnx-test-gate-continue "held")
        (drgnx-test-deliver-all)
        (should held)
        (should (= runs-at-delete 1))
        (should (= runs 1))
        (should-not (drgnx-test-gate-held 'sub-1))
        (should-not (cl-find 'sub-1 (nthcdr after-delete (drgnx-test-gate-transcript)) :key #'car))))))

;;;; Determinism

(ert-deftest drgnx-delivery-gate/the-same-schedule-gives-the-same-transcript ()
  "Twenty runs of one schedule, each against a fresh hub: the same deliveries in the same order."
  (let (shapes)
    (dotimes (_ 20)
      (drgnx-delivery-gate-test--with-hub
        (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "graph/settings"))
          (drgnx-hub-connect)
          (drgnx-test-deliver-all)
          (push (mapcar #'drgnx-delivery-gate-test--shape (drgnx-test-gate-transcript)) shapes))))
    (should (= (length shapes) 20))
    (should (cl-some (lambda (e) (and (eq (car e) 'sub-1) (eq (car-safe (cdr e)) :answer))) (car shapes)))
    (should (= 1 (length (delete-dups (copy-sequence shapes)))))))

(ert-deftest drgnx-delivery-gate/virtual-time-moves-only-when-the-test-advances ()
  "A connection's challenge held through 2.5 s of real time: its 2 s challenge timer does not fire; a virtual advance
of 2 s fires it."
  (drgnx-delivery-gate-test--with-hub
    (let (state-held now-held state-advanced now-advanced)
      (drgnx-test-gated '((:pause "held"))
        (let ((c (drgnx-hub--open nil)) (t0 (drgnx-test-real-time)))
          (drgnx-test-wait (lambda () (> (- (drgnx-test-real-time) t0) 2.5)) :what "2.5 s of real time")
          (setq state-held (process-get c :drgnx-state) now-held (drgnx-test-clock-now))
          (drgnx-test-advance 2)
          (setq state-advanced (process-get c :drgnx-state) now-advanced (drgnx-test-clock-now))
          (drgnx-test-gate-continue "held")
          (drgnx-test-deliver-all)
          (should (eq state-held 'wait))
          (should (= now-held 0))
          (should (eq state-advanced 'rejected))
          (should (= now-advanced 2)))))))

(ert-deftest drgnx-delivery-gate/deliver-all-sees-every-marker ()
  "`drgnx-test-deliver-all' returns once each connection has its barrier marker; the markers never reach the client."
  (drgnx-delivery-gate-test--with-hub
    (let (m1 m2 markers held (events nil))
      (drgnx-test-gated '((sub-1 :answer "subscribe"))
        (add-hook 'drgnx-hub-event-functions (lambda (e _d) (push e events)))
        (drgnx-hub-connect)
        (setq m1 (drgnx-test-deliver-all)
              markers (mapcar (lambda (n) (drgnx-test-gate--conn-marker (drgnx-test-gate--find n))) '(sub-1 call-1))
              m2 (drgnx-test-deliver-all)
              held (append (drgnx-test-gate-held 'sub-1) (drgnx-test-gate-held 'call-1)))
        (should (natnump m1))
        (should (> m2 m1))
        (should (equal markers (list m1 m1)))
        (should-not held)
        (should-not (member "__test_marker" events))))))

(ert-deftest drgnx-delivery-gate/chaos-leaves-gated-connections-alone ()
  "With hub chaos on (DRGNX_TEST_HUB_CHAOS), a gated body's connections get no delay advice."
  (let ((had (advice-member-p #'drgnx-test-hub-chaos--open 'drgnx-hub--open)) count filters)
    (unwind-protect
        (let ((drgnx-test-hub-chaos--seed "1") (process-environment (cons "DRGNX_TEST_HUB_CHAOS=1" process-environment)))
          (unless had (advice-add 'drgnx-hub--open :filter-return #'drgnx-test-hub-chaos--open))
          (setq count drgnx-test-hub-chaos--count)
          (drgnx-delivery-gate-test--with-hub
            (drgnx-test-gated '((sub-1 :answer "subscribe"))
              (drgnx-hub-connect)
              (drgnx-test-deliver-all)
              (setq filters (mapcar (lambda (n) (process-filter (drgnx-test-gate-conn n))) '(sub-1 call-1)))
              (should (= count drgnx-test-hub-chaos--count))
              (should (equal filters '(drgnx-test-gate--input drgnx-test-gate--input))))))
      (unless had (advice-remove 'drgnx-hub--open #'drgnx-test-hub-chaos--open)))))

;;;; Across connections: one connection's answer held past another's end

(defun drgnx-delivery-gate-test--stop-while-held (after-stop)
  "Subscribe, hold the hand-over's `gateway/editor-token' answer on call-1, stop the hub, then release AFTER-STOP (a
schedule of `(sub-1 :eof)' and `(call-1 :answer \"gateway/editor-token\")' in some order).  (TOKEN-SEEN EDITOR
TRANSCRIPT): whether the token reached `drgnx-hub-editor-token-hook', the token kept at the end, the deliveries."
  (let (seen editor transcript)
    (drgnx-delivery-gate-test--with-hub
      (drgnx-test-gated (append '((sub-1 :answer "subscribe") (:pause "stop")) after-stop)
        (add-hook 'drgnx-hub-editor-token-hook (lambda () (setq seen t)))
        (drgnx-hub-connect)
        (drgnx-test-wait (lambda () (drgnx-delivery-gate-test--answer-held-p 'call-1 :token)) :what "the token answer, held")
        (signal-process drgnx-test-ratatoskr-process 'term)
        (drgnx-test-wait (lambda () (and (memq :eof (drgnx-test-gate-held 'sub-1)) (memq :eof (drgnx-test-gate-held 'call-1))))
                         :what "both ends, held")
        (drgnx-test-gate-continue "stop")
        (drgnx-test-deliver-all)
        (setq editor drgnx-hub--editor transcript (drgnx-test-gate-transcript))))
    (list seen editor transcript)))

(ert-deftest drgnx-delivery-gate/a-held-answer-comes-after-another-connections-eof ()
  "The gate holds call-1's token answer and delivers sub-1's end first: the end forgets the subscription, and the
answer read after it is dropped (the forget race, every run).  The other order is the token, then the forget."
  (pcase-let ((`(,seen-a ,editor-a ,tr-a)
               (drgnx-delivery-gate-test--stop-while-held '((sub-1 :eof) (call-1 :answer "gateway/editor-token"))))
              (`(,seen-b ,editor-b ,tr-b)
               (drgnx-delivery-gate-test--stop-while-held '((call-1 :answer "gateway/editor-token") (sub-1 :eof)))))
    (let ((eof (lambda (e) (equal e '(sub-1 . :eof))))
          (token (lambda (e) (and (eq (car e) 'call-1) (stringp (cdr e))
                                  (let ((r (plist-get (drgnx-delivery-gate-test--json (cdr e)) :result)))
                                    (and (consp r) (plist-member r :token)))))))
      (should (< (drgnx-delivery-gate-test--position eof tr-a) (drgnx-delivery-gate-test--position token tr-a)))
      (should-not seen-a)
      (should-not editor-a)
      (should (> (drgnx-delivery-gate-test--position eof tr-b) (drgnx-delivery-gate-test--position token tr-b)))
      (should seen-b)
      (should-not editor-b))))

(provide 'delivery-gate-test)
;;; delivery-gate-test.el ends here
