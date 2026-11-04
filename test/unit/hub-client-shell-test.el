;;; hub-client-shell-test.el --- the hub client's shell keeps the orders its core is tested in -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: orders
;; hub-core-test.el runs the core (core/drgnx-hub-core.el) in every order of its sources, each source one connection's
;; lines in the order the hub wrote them, its `closed' last.  These are the shell's side of that claim, on scripted
;; peers (no hub, no timing): a connection's lines reach the core in the order they were written, whatever the chunks,
;; and its `closed' reaches it once, after them, and nothing after it.  The shell's hooks (the version read, the hello)
;; are left out: what reaches the core is the subject.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/peer-fixture" drgnx-dir) nil t)

(defmacro drgnx-hub-client-shell-test--with (fed &rest body)
  "BODY with the client's state fresh and FED the events the core got, newest first."
  (declare (indent 1))
  (let ((record (make-symbol "record")))
    ;; the challenge's and the calls' timers (2 s and more) never fire within a test: they go at its end
    `(let ((drgnx-hub--client nil) (drgnx-hub--events nil) (drgnx-hub--subscribing nil) (drgnx-hub--next-id 0)
           (drgnx-hub--pending (make-hash-table)) (drgnx-hub--last-hello nil) (drgnx-hub--editor nil)
           (drgnx-hub--keys-held :unknown) (drgnx-hub--asked-disconnect nil) (drgnx-hub--resubscribe-since nil)
           (drgnx-hub--resubscribe-delay 1) (,fed nil))
       (let ((,record (lambda (_state event) (push event ,fed))))
         (advice-add 'drgnx-hub-core-step :before ,record)
         (unwind-protect
             (cl-letf (((symbol-function 'drgnx-hub--run-hook) #'ignore))
               ,@body)
           (advice-remove 'drgnx-hub-core-step ,record)
           (drgnx-timer-cancel-owner :core))))))

(defun drgnx-hub-client-shell-test--peer (name)
  "A scripted peer read as a hub connection is: the client's filter and sentinel."
  (let ((p (drgnx-test-peer-make :name name :filter #'drgnx-hub--client-filter)))
    (set-process-sentinel p #'drgnx-hub--client-sentinel)
    p))

(defun drgnx-hub-client-shell-test--of (conn fed)
  "The kinds of the events in FED (newest first) that name CONN, oldest first."
  (mapcar #'car (seq-filter (lambda (e) (eq (nth 1 e) conn)) (reverse fed))))

(ert-deftest drgnx-hub-client-shell/the-challenge-comes-first-on-a-connection ()
  ;; three lines in one write, the last split across two: the core gets them in the order written
  (drgnx-hub-client-shell-test--with fed
    (let ((peer (drgnx-hub-client-shell-test--peer "hub-shell-challenge")))
      (unwind-protect
          (progn
            (drgnx-hub--step (list 'open peer nil))      ; what `drgnx-hub--open' does once it connected
            (drgnx-test-peer-write peer (concat "{\"event\":\"challenge\",\"data\":{\"nonce\":\"n1\"}}\n"
                                                "{\"id\":1,\"result\":{\"pid\":1}}\n{\"event\":\"no"))
            (drgnx-test-peer-write peer "tice\",\"data\":{}}\n")
            (should (equal (drgnx-hub-client-shell-test--of peer fed) '(open challenge answer event)))
            (should (equal (nth 2 (cl-find 'challenge (reverse fed) :key #'car)) "n1")))
        (drgnx-test-peer-close peer)))))

(ert-deftest drgnx-hub-client-shell/closed-is-the-last-event ()
  ;; the connection's end comes after every line written before it, once, and nothing after it; the client's own
  ;; delete (`drgnx-hub-disconnect') gives the core its `closed' at once, inside the disconnect
  (drgnx-hub-client-shell-test--with fed
    (let ((peer (drgnx-hub-client-shell-test--peer "hub-shell-end"))
          (other (drgnx-hub-client-shell-test--peer "hub-shell-delete")))
      (unwind-protect
          (progn
            (drgnx-hub--step (list 'open peer nil))
            (drgnx-test-peer-write peer "{\"id\":1,\"result\":{\"pid\":1}}\n{\"event\":\"x\",\"data\":{}}\n")
            (drgnx-test-peer-close peer)
            (accept-process-output nil 0)
            (should (equal (drgnx-hub-client-shell-test--of peer fed) '(open answer event closed)))
            (setq fed nil)
            (drgnx-hub--step (list 'open other nil))
            (should (eq drgnx-hub--client other))
            (drgnx-hub-disconnect)
            (should (equal (mapcar #'car (reverse fed)) '(open disconnect closed)))
            (accept-process-output nil 0)
            (should (equal (drgnx-hub-client-shell-test--of other fed) '(open closed))))
        (drgnx-test-peer-close peer)
        (drgnx-test-peer-close other)))))

;;; hub-client-shell-test.el ends here
