;;; hub-event-dispatch-test.el --- an event from the hub costs the same whatever the client holds -*- lexical-binding: t -*-
;; test-class: det
;; Pattern A (a cost bound).  The core's step for an `event' (the hub's notification on the subscription) changes
;; nothing in the client: it hands back the same state and the one effect that runs the handlers, and copies nothing,
;; so what it allocates does not grow with the client's connections and pending calls.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-hub-core)
(require 'drgnx-hub-client)

(defun drgnx-hub-event-dispatch-test--state (n)
  "A client with N more connections and N pending calls than its subscription."
  (drgnx-hub-core-make
   :conns (cons (cons 'sub (list :live t :events t))
                (cl-loop for i below n collect (cons i (list :live t))))
   :pending (cl-loop for i below n collect (list i :cb #'ignore :method "m"))))

(defun drgnx-hub-event-dispatch-test--conses (state)
  "The conses one event's step allocates in STATE."
  (garbage-collect)
  (let ((before (car (memory-use-counts))))
    (drgnx-hub-core-step state '(event sub "x" (:a 1)))
    (- (car (memory-use-counts)) before)))

(ert-deftest drgnx-hub/event-dispatch-copies-no-state ()
  "An event's step hands back the client as it was and runs the handlers; with 500 more connections and calls it
allocates no more than with none."
  (let ((big (drgnx-hub-event-dispatch-test--state 500)) (small (drgnx-hub-event-dispatch-test--state 0)))
    (should (eq (car (drgnx-hub-core-step big '(event sub "x" (:a 1)))) big))
    (should (equal (cdr (drgnx-hub-core-step big '(event sub "x" (:a 1)))) '((hook events sub "x" (:a 1)))))
    (should-not (cdr (drgnx-hub-core-step big '(event 3 "x" (:a 1)))))  ; not the subscription: nothing runs
    (should (<= (drgnx-hub-event-dispatch-test--conses big) (+ (drgnx-hub-event-dispatch-test--conses small) 8)))))

;; the shell: an event line is handed to the handlers without a snapshot of the client's globals and connections
(ert-deftest drgnx-hub/event-line-takes-no-snapshot ()
  "An event read on the subscription runs `drgnx-hub-event-functions' and snapshots nothing; on another connection
it runs nothing."
  (let ((sub (make-pipe-process :name "drgnx-event-test-sub" :noquery t))
        (other (make-pipe-process :name "drgnx-event-test-other" :noquery t))
        (seen nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub--snapshot) (lambda (&rest _) (error "Snapshot taken"))))
          (process-put sub :drgnx-events t)
          (let ((drgnx-hub-event-functions (list (lambda (name data) (push (list name data) seen)))))
            (drgnx-hub--client-line sub '(:event "x" :data (:a 1)))
            (drgnx-hub--client-line other '(:event "y" :data (:a 2))))
          (should (equal seen '(("x" (:a 1))))))
      (delete-process sub)
      (delete-process other))))

;;; hub-event-dispatch-test.el ends here
