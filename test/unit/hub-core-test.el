;;; hub-core-test.el --- the hub client's connection and subscription lifecycle, in every order -*- lexical-binding: t -*-
;; test-class: det
;; The core (core/drgnx-hub-core.el) runs here in every order its inputs can arrive in (`drgnx-test-every-order'):
;; the subscription connection's lines, the call connection's lines, the client's actions and the timers.  An adapter
;; stands in for the shell and the hub: it names the connections the core dials (sub-1, cli-1, …), turns an answer
;; given by method into the id the core gave that call, feeds what an effect raises (a `delete' is that connection's
;; `closed'; the hand-over, the dial and the hello are the calls the shell would make), and drops a line on a
;; connection that is not open (the hub cannot write there).  The edges are claims the shell keeps: on one connection
;; the challenge comes first and `closed' last (each source is one connection, in order; hub-client-shell-test.el
;; checks the shell keeps it), and an answer comes after its call.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-hub-core)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defconst drgnx-hub-core-test--reply '(:proto 1 :proto_min 1 :records 2 :schema 6 :proof "hub-proof" :class "user")
  "A current hub's answer to the hello, its proof the one the adapter's hello expects.")

(defvar drgnx-hub-core-test--proves t "Whether the adapter's hellos carry a proof (`drgnx-hub-client-proves').")

(cl-defstruct (drgnx-hub-core-test--w (:constructor drgnx-hub-core-test--w-make) (:copier drgnx-hub-core-test--w-copy))
  "The adapter's state: the core's, and what the shell and the hub would know.  SENT: (ID METHOD CONN PARAMS STEP)
newest first; MADE: (ID . METHOD) newest first; TRACE: (EVENT OLD NEW HOOKS ARMED) per fed event, newest first."
  core (subs 0) (clis 0) sent made answered armed results trace)

(defun drgnx-hub-core-test--init ()
  (drgnx-hub-core-test--w-make
   :core (drgnx-hub-core-make :config '(:call-deadline 30 :challenge-wait 2 :subscribe-deadline 5 :give-up 600
                                                       :schema 6 :noninteractive t))))

(defun drgnx-hub-core-test--live-p (core conn)
  (plist-get (cdr (assq conn (drgnx-hub-core-conns core))) :live))

(defun drgnx-hub-core-test--state (core conn)
  (plist-get (cdr (assq conn (drgnx-hub-core-conns core))) :state))

(defun drgnx-hub-core-test--name (w kind)
  "A new connection's name: sub-N for a subscription, cli-N for the call connection."
  (if (eq kind 'sub)
      (intern (format "sub-%d" (cl-incf (drgnx-hub-core-test--w-subs w))))
    (intern (format "cli-%d" (cl-incf (drgnx-hub-core-test--w-clis w))))))

(defun drgnx-hub-core-test--under-calls (core)
  "The hand-over's two questions (`drgnx-hub--fetch-editor'), asked under the subscription CORE has."
  (let ((sub (drgnx-hub-core-events core)))
    (list (list 'call :client nil "gateway/editor-token" nil :role 'token :under sub)
          (list 'call :client nil "gateway/keys-held" nil :role 'keys-held :under sub))))

(defun drgnx-hub-core-test--translate (w event)
  "EVENT, as the adapter writes it, as the core's: (CORE-EVENT) to feed, (nil . EVENTS) to feed EVENTS instead, or
nil to drop it (a line on a connection that is not open, an answer to a call never sent, a timer not armed)."
  (let* ((core (drgnx-hub-core-test--w-core w))
         (open (lambda (c) (drgnx-hub-core-test--live-p core c))))
    (pcase event
      (`(call :client ,tag ,method ,params . ,keys)
       ;; `drgnx-hub-call': a call connection is opened when there is none
       (let ((client (drgnx-hub-core-client core)))
         (if (funcall open client)
             (list (append (list 'call client method params tag) keys))
           (let ((c (drgnx-hub-core-test--name w 'cli)))
             (cons nil (list (list 'open c nil) (append (list 'call c method params tag) keys)))))))
      (`(hand-over) (cons nil (drgnx-hub-core-test--under-calls core)))
      (`(call . ,_) (list event))
      (`(open . ,_) (list event))
      (`(connect . ,keys)
       (list (append (list 'connect (or (plist-get keys :at) 0))
                     (and (plist-get keys :opened) (list :opened (plist-get keys :opened))))))
      (`(challenge ,c) (and (funcall open c) (list (list 'challenge c "hub-nonce" "SOCK"))))
      (`(answer ,c ,method ,result . ,err)
       (when-let* (((funcall open c))
                   (sent (cl-find-if (lambda (s) (and (equal (nth 1 s) method) (eq (nth 2 s) c)
                                                      (not (memq (car s) (drgnx-hub-core-test--w-answered w)))))
                                     (reverse (drgnx-hub-core-test--w-sent w)))))
         (push (car sent) (drgnx-hub-core-test--w-answered w))
         (list (list 'answer c (car sent) result (car err)))))
      (`(event ,c ,name) (and (funcall open c) (list (list 'event c name nil))))
      (`(closed ,c :deleted) (list (list 'closed c 0)))
      (`(closed ,c) (and (funcall open c) (list (list 'closed c 0))))
      (`(timer ,_ :read t . ,_) (list event))
      (`(timer (hub-call . ,(and method (pred stringp))))
       (when-let* ((made (cl-find-if (lambda (m) (and (equal (cdr m) method)
                                                      (member (cons 'hub-call (car m)) (drgnx-hub-core-test--w-armed w))))
                                     (drgnx-hub-core-test--w-made w))))
         (drgnx-hub-core-test--translate w (list 'timer (cons 'hub-call (car made))))))
      (`(timer ,key)
       (when (member key (drgnx-hub-core-test--w-armed w))
         (setf (drgnx-hub-core-test--w-armed w) (remove key (drgnx-hub-core-test--w-armed w)))
         (list event)))
      ('(disconnect) (list event))
      (`(version-known . ,_) (list event))
      (_ (error "The adapter has no event %S" event)))))

(defun drgnx-hub-core-test--effects (w effects)
  "Run EFFECTS as the shell would: the events they raise, in order."
  (let ((core (drgnx-hub-core-test--w-core w)) raised hooks)
    (dolist (e effects)
      (pcase e
        (`(send ,c ,msg)
         (push (list (plist-get msg :id) (plist-get msg :method) c (plist-get msg :params)
                     (length (drgnx-hub-core-test--w-trace w)))
               (drgnx-hub-core-test--w-sent w)))
        (`(delete ,c) (push (list 'closed c :deleted) raised))
        (`(timer-start ,key ,_)
         (cl-pushnew key (drgnx-hub-core-test--w-armed w) :test #'equal)
         (when (eq (car-safe key) 'hub-call)
           (push (cons (cdr key) (plist-get (cdr (assq (cdr key) (drgnx-hub-core-pending core))) :method))
                 (drgnx-hub-core-test--w-made w))))
        (`(timer-cancel ,key) (setf (drgnx-hub-core-test--w-armed w) (remove key (drgnx-hub-core-test--w-armed w))))
        (`(callback ,tag ,_ ,args) (push (cons tag args) (drgnx-hub-core-test--w-results w)))
        (`(notify . ,_) (push e hooks))
        (`(hook ,name . ,args)
         (push (cons name args) hooks)
         (pcase name
           ('version (push (list 'version-known (nth 0 args) (nth 1 args)) raised))
           ('hello (push (list 'call (nth 0 args) "hello" '(:proto 1) nil :full t :first t
                               :hello (list :proves drgnx-hub-core-test--proves :expect "hub-proof" :socket "SOCK"
                                            :cap-file "CAP"))
                         raised))
           ('read (push (list 'timer (cons 'hub-challenge (car args)) :read t :socket "SOCK") raised))
           ('hand-over (dolist (c (drgnx-hub-core-test--under-calls core)) (push c raised)))
           ('dial (let ((c (drgnx-hub-core-test--name w 'sub)))
                    (push (list 'open c t) raised)
                    (push (list 'connect :opened c) raised)
                    (push (list 'call c "subscribe" nil nil) raised)))
           ('redial (push (list 'connect) raised))))
        (_ (error "The adapter has no effect %S" e))))
    (cons (nreverse raised) (nreverse hooks))))

(defvar drgnx-hub-core-test--raised (make-hash-table :test #'eq :weakness 'key)
  "The events the adapter raised (each a fresh list): the others are the sources'.")

(defun drgnx-hub-core-test--raise (events)
  (dolist (e events) (puthash e t drgnx-hub-core-test--raised))
  events)

(defun drgnx-hub-core-test--step (w event)
  "The adapter's step: (W . RAISED).  A trace entry is (EVENT OLD NEW HOOKS ARMED EXTERNAL)."
  (let* ((w (drgnx-hub-core-test--w-copy w))
         (external (not (gethash event drgnx-hub-core-test--raised)))
         (tr (drgnx-hub-core-test--translate w event)))
    (cond ((null tr) (cons w nil))
          ((null (car tr))              ; the shell's own steps, in order: in the trace, the core unchanged
           (let ((core (drgnx-hub-core-test--w-core w)))
             (push (list event core core nil (drgnx-hub-core-test--w-armed w) external) (drgnx-hub-core-test--w-trace w))
             (cons w (drgnx-hub-core-test--raise (cdr tr)))))
          (t (let* ((old (drgnx-hub-core-test--w-core w)) (r (drgnx-hub-core-step old (car tr))))
               (setf (drgnx-hub-core-test--w-core w) (car r))
               (pcase-let ((`(,raised . ,hooks) (drgnx-hub-core-test--effects w (cdr r))))
                 (push (list event old (car r) hooks (drgnx-hub-core-test--w-armed w) external)
                       (drgnx-hub-core-test--w-trace w))
                 (cons w (drgnx-hub-core-test--raise raised))))))))

(defun drgnx-hub-core-test--observable (trace)
  "The indices of TRACE after which a test could look: the last step an external event raised, before the next
external event (a filter or a timer runs to its end before anything else does)."
  (cl-loop for tail on trace for i from 0
           when (or (null (cdr tail)) (nth 5 (cadr tail))) collect i))

(defun drgnx-hub-core-test--kind (event)
  "The adapter's events by kind: the ensure's hand-over is two calls."
  (if (eq (car event) 'hand-over) 'call (car event)))

(defun drgnx-hub-core-test--handshake (c)
  "A v1 hub's first lines on C: the challenge, the probe's answer, the hello's."
  (list (list 'challenge c) (list 'answer c "ping" '(:pid 1)) (list 'answer c "hello" drgnx-hub-core-test--reply)))

(defun drgnx-hub-core-test--trace (w) (reverse (drgnx-hub-core-test--w-trace w)))

(defun drgnx-hub-core-test--fed-at (w event)
  "The index in W's trace where EVENT (an adapter event) was fed, or nil."
  (cl-position event (drgnx-hub-core-test--trace w) :key #'car :test #'equal))

(defun drgnx-hub-core-test--hook-p (entry name)
  (assq name (nth 3 entry)))

(cl-defun drgnx-hub-core-test--run (&key kinds sources edges check)
  (drgnx-test-every-order :kinds kinds :kind-of #'drgnx-hub-core-test--kind :sources sources :edges edges
                          :init #'drgnx-hub-core-test--init :step #'drgnx-hub-core-test--step :check check))

;;;; The tests

(ert-deftest drgnx-hub-core/every-call-is-answered-exactly-once ()
  ;; an answer, a deadline, a closed connection or a disconnect, in any order: each callback runs once
  (let ((r (drgnx-hub-core-test--run
            :kinds '(open call challenge answer closed timer disconnect version-known)
            :sources `((act (call :client a "agents/list" nil) (call :client b "agents/get" nil)
                            (call :client c "agents/kill" nil) (disconnect))
                       (cli-1 ,@(drgnx-hub-core-test--handshake 'cli-1)
                              (answer cli-1 "agents/list" (:ok t)) (answer cli-1 "agents/get" (:ok t)) (closed cli-1))
                       (timers (timer (hub-call . "agents/list")) (timer (hub-challenge . cli-1))))
            :edges '(((act . 0) . (cli-1 . 0)) ((act . 0) . (timers . 0)) ((act . 0) . (timers . 1)))
            :check (lambda (w _order)
                     (cl-loop for tag in '(a b c)
                              for n = (cl-count tag (drgnx-hub-core-test--w-results w) :key #'car)
                              unless (= n 1) return (format "call %s was answered %d times" tag n))))))
    (should (eq (plist-get r :mode) 'exhaustive))))

(ert-deftest drgnx-hub-core/an-answer-under-an-ended-subscription-sets-nothing ()
  ;; the forget race: the hub ends its connections in any order, so the hand-over's token and held-keys answers on the
  ;; call connection can be read after the subscription's end forgot both; they are the gone hub's and set nothing
  (let* ((late 0)
         (r (drgnx-hub-core-test--run
             :kinds '(open connect call challenge answer closed version-known)
             :sources `((act (connect))
                        (sub-1 ,@(drgnx-hub-core-test--handshake 'sub-1) (answer sub-1 "subscribe" t) (closed sub-1))
                        (cli-1 ,@(drgnx-hub-core-test--handshake 'cli-1)
                               (answer cli-1 "gateway/editor-token" (:token "tok" :url "http://127.0.0.1:1"))
                               (answer cli-1 "gateway/keys-held" (:providers ["openrouter"])) (closed cli-1)))
             ;; the hand-over is asked when the subscription is answered: the call connection opens then
             :edges '(((act . 0) . (sub-1 . 0)) ((sub-1 . 3) . (cli-1 . 0)))
             :check (lambda (w _order)
                      (let ((end (drgnx-hub-core-test--fed-at w '(closed sub-1)))
                            (core (drgnx-hub-core-test--w-core w)))
                        (when (cl-some (lambda (e) (and (eq (car (car e)) 'answer) (eq (nth 1 (car e)) 'cli-1)
                                                        (string-prefix-p "gateway/" (nth 2 (car e)))))
                                       (nthcdr (1+ end) (drgnx-hub-core-test--trace w)))
                          (cl-incf late))
                        (cond ((drgnx-hub-core-editor core)
                               (format "the token %S was set after the subscription ended" (drgnx-hub-core-editor core)))
                              ((not (eq (drgnx-hub-core-keys-held core) :unknown))
                               (format "the held keys %S were set after the subscription ended"
                                       (drgnx-hub-core-keys-held core)))))))))
    (should (eq (plist-get r :mode) 'exhaustive))
    (should (> late 0))))               ; some order read the call connection after the end

(defun drgnx-hub-core-test--one-subscription (w _order)
  "Nil when no state in W's run had two live subscription connections."
  (cl-loop for e in (drgnx-hub-core-test--trace w)
           for live = (cl-loop for (c . p) in (drgnx-hub-core-conns (nth 2 e))
                               when (and (plist-get p :events) (plist-get p :live)) collect c)
           when (cdr live) return (format "after %S, two subscriptions at once: %S" (car e) live)))

(ert-deftest drgnx-hub-core/at-most-one-subscription-at-once ()
  ;; connect again and again, a lost subscription redialled, and a subscribe left unanswered given up
  (should (drgnx-hub-core-test--run
           :kinds '(open connect call challenge answer event closed timer version-known)
           :sources `((act (connect) (connect))
                      (sub-1 ,@(drgnx-hub-core-test--handshake 'sub-1) (answer sub-1 "subscribe" t) (event sub-1 "notice")
                             (closed sub-1))
                      (timers (timer hub-resubscribe))
                      (sub-2 ,@(drgnx-hub-core-test--handshake 'sub-2) (answer sub-2 "subscribe" t)))
           ;; sub-2 can open only once sub-1 is gone, here
           :edges '(((act . 0) . (sub-1 . 0)) ((sub-1 . 5) . (sub-2 . 0)))
           :check #'drgnx-hub-core-test--one-subscription))
  (let* ((gave-up 0)
         (r (drgnx-hub-core-test--run
             :kinds '(open connect call challenge answer closed version-known)
             :sources `((act (connect) (connect :at 10) (connect :at 10))
                        (sub-1 ,@(drgnx-hub-core-test--handshake 'sub-1) (answer sub-1 "subscribe" t))
                        (sub-2 ,@(drgnx-hub-core-test--handshake 'sub-2) (answer sub-2 "subscribe" t)))
             :edges '(((act . 0) . (sub-1 . 0)) ((act . 1) . (sub-2 . 0)))
             :check (lambda (w order)
                      (when (cl-some (lambda (e) (drgnx-hub-core-test--hook-p e 'quiet)) (drgnx-hub-core-test--trace w))
                        (cl-incf gave-up))
                      (drgnx-hub-core-test--one-subscription w order)))))
    (should (eq (plist-get r :mode) 'exhaustive))
    (should (> gave-up 0))))

(defun drgnx-hub-core-test--redials (asked-at)
  "A check: a subscription lost before ASKED-AT (the adapter event that asked for the end) arms the redial and a
fired redial dials; from ASKED-AT on nothing dials, and the run ends with no redial armed."
  (lambda (w _order)
    (let* ((trace (drgnx-hub-core-test--trace w))
           (asked (drgnx-hub-core-test--fed-at w asked-at))
           (lost (drgnx-hub-core-test--fed-at w '(closed sub-1)))
           (last (car (last trace))))
      (cond ((and lost (< lost asked) (not (member 'hub-resubscribe (nth 4 (nth lost trace)))))
             "the subscription was lost before the end was asked, and no redial was armed")
            ((cl-loop for e in (seq-take trace asked)
                      thereis (and (equal (car e) '(timer hub-resubscribe)) (not (drgnx-hub-core-test--hook-p e 'redial))))
             "a redial fired and did not dial")
            ((cl-some (lambda (e) (drgnx-hub-core-test--hook-p e 'dial)) (nthcdr asked trace))
             (format "a dial after %S" asked-at))
            ((or (member 'hub-resubscribe (nth 4 last)) (drgnx-hub-core-resubscribe-since (nth 2 last)))
             "the run ended with a redial under way after an asked end")))))

(ert-deftest drgnx-hub-core/a-lost-subscription-redials-an-asked-one-never ()
  ;; every event kind the core declares: a subscription the hub ends is redialled; after `drgnx-hub-disconnect' or a
  ;; `shutdown' this editor sent, nothing redials
  (should (drgnx-hub-core-test--run
           :kinds drgnx-hub-core-event-kinds
           :sources `((act (connect) (disconnect))
                      (sub-1 ,@(drgnx-hub-core-test--handshake 'sub-1) (answer sub-1 "subscribe" t) (event sub-1 "notice")
                             (closed sub-1))
                      (timers (timer hub-resubscribe) (timer hub-resubscribe)))
           :edges '(((act . 0) . (sub-1 . 0)))
           :check (drgnx-hub-core-test--redials '(disconnect))))
  (should (drgnx-hub-core-test--run
           :kinds '(open connect call challenge answer closed timer version-known)
           :sources `((act (connect) (call :client x "shutdown" nil))
                      (sub-1 ,@(drgnx-hub-core-test--handshake 'sub-1) (answer sub-1 "subscribe" t) (closed sub-1))
                      (timers (timer hub-resubscribe)))
           :edges '(((act . 0) . (sub-1 . 0)))
           :check (drgnx-hub-core-test--redials '(call :client x "shutdown" nil)))))

(defun drgnx-hub-core-test--queued (proven legacy)
  "A check for `queued-calls-go-in-order-after-hello-keys-only-when-proven'."
  (lambda (w _order)
    (let* ((sent (reverse (drgnx-hub-core-test--w-sent w)))
           (user (cl-remove-if (lambda (s) (member (nth 1 s) '("ping" "hello"))) sent))
           (ready (drgnx-hub-core-test--fed-at w (if legacy '(answer cli-1 "ping" (:pid 1))
                                                   `(answer cli-1 "hello" ,drgnx-hub-core-test--reply))))
           (keys (cdr (assq 'k (drgnx-hub-core-test--w-results w))))
           (reg (cl-find "gateway/register" sent :key #'cadr :test #'equal)))
      (cond ((not (equal (mapcar #'cadr (seq-take sent (if legacy 1 2))) (if legacy '("ping") '("ping" "hello"))))
             (format "the first lines were %S" (mapcar #'cadr sent)))
            ((cl-find-if (lambda (s) (< (nth 4 s) ready)) user)
             (format "%s went before the hub was proven or legacy" (nth 1 (cl-find-if (lambda (s) (< (nth 4 s) ready)) user))))
            ((not (equal (mapcar #'cadr user)
                         (cl-remove-if-not (lambda (m) (member m (mapcar #'cadr user)))
                                           '("agents/list" "gateway/keys" "gateway/register"))))
             (format "the calls went in the order %S" (mapcar #'cadr user)))
            ((not (equal (and (assoc "gateway/keys" (mapcar #'cdr sent)) t) proven))
             (if proven "the proven hub got no keys" "keys went to a hub that did not prove itself"))
            ((and (not proven) (not (equal keys '(nil "keys go only to a hub that proved itself"))))
             (format "gateway/keys was answered %S" keys))
            ((not (equal (and (plist-member (nth 3 reg) :keys) t) proven))
             (format "gateway/register went with %S" (nth 3 reg)))))))

(ert-deftest drgnx-hub-core/queued-calls-go-in-order-after-hello-keys-only-when-proven ()
  ;; nothing but the probe and the hello goes before the hello's answer; then the calls in the order made; keys only
  ;; to a hub that proved itself (an unproven one, and a legacy one, get gateway/register without its keys)
  (let ((act '(act (call :client a "agents/list" nil) (call :client k "gateway/keys" (:keys (:openrouter "sk")))
                   (call :client r "gateway/register" (:chain [] :keys (:openrouter "sk"))))))
    (dolist (proves '(t nil))
      (let ((drgnx-hub-core-test--proves proves))
        (should (drgnx-hub-core-test--run
                 :kinds '(open call challenge answer version-known)
                 :sources (list act (cons 'cli-1 (drgnx-hub-core-test--handshake 'cli-1)))
                 :edges '(((act . 0) . (cli-1 . 0)))
                 :check (drgnx-hub-core-test--queued proves nil)))))
    (should (drgnx-hub-core-test--run
             :kinds '(open call answer)
             :sources (list act '(cli-1 (answer cli-1 "ping" (:pid 1))))
             :edges '(((act . 0) . (cli-1 . 0)))
             :check (drgnx-hub-core-test--queued nil t)))))

(defun drgnx-hub-core-test--gateway-ready (core)
  "What test/unit/ai-gateway-test.el's fixture waits for before its body: the subscription is answered and no call
waits (`drgnx-hub-settled-p').  A body that starts earlier sees the hand-over's later answers overwrite what it set."
  (drgnx-hub-core-settled-p core))

(ert-deftest drgnx-hub-core/events-before-the-subscribe-answer-are-not-the-subscription ()
  ;; D2's class: the ensure's hand-over on the call connection answers while the subscription is still being made;
  ;; only the subscribe answer makes the subscription, and once the client is settled (what the gateway tests wait
  ;; for) no answer still changes the token or the held keys
  (let ((r (drgnx-hub-core-test--run
            :kinds '(open connect call challenge answer version-known)
            :sources `((act (connect) (hand-over))
                       (sub-1 ,@(drgnx-hub-core-test--handshake 'sub-1) (answer sub-1 "subscribe" t))
                       (cli-1 ,@(drgnx-hub-core-test--handshake 'cli-1)
                              (answer cli-1 "gateway/editor-token" (:token "t1" :url "http://127.0.0.1:1"))
                              (answer cli-1 "gateway/keys-held" (:providers ["a"]))
                              (answer cli-1 "gateway/editor-token" (:token "t2" :url "http://127.0.0.1:1"))
                              (answer cli-1 "gateway/keys-held" (:providers ["a" "b"]))))
            ;; the second pair answers the subscription's own hand-over, asked when the subscribe is answered
            :edges '(((act . 0) . (sub-1 . 0)) ((act . 1) . (cli-1 . 0)) ((sub-1 . 3) . (cli-1 . 5)))
            :check (lambda (w _order)
                     (let* ((trace (drgnx-hub-core-test--trace w))
                            (answered (drgnx-hub-core-test--fed-at w '(answer sub-1 "subscribe" t)))
                            (ready (cl-find-if (lambda (i) (drgnx-hub-core-test--gateway-ready (nth 2 (nth i trace))))
                                               (drgnx-hub-core-test--observable trace))))
                       (or (cl-loop for e in trace for i from 0
                                    when (and (drgnx-hub-core-events (nth 2 e)) (or (null answered) (< i answered)))
                                    return (format "subscribed by %S, before the subscribe answer" (car e)))
                           (and (null ready) "the client never settled")
                           (cl-loop for e in (nthcdr (1+ ready) trace)
                                    for old = (nth 1 e) for new = (nth 2 e)
                                    unless (and (equal (drgnx-hub-core-editor old) (drgnx-hub-core-editor new))
                                                (equal (drgnx-hub-core-keys-held old) (drgnx-hub-core-keys-held new)))
                                    return (format "settled after %S, and then %S changed the token or the keys to %S"
                                                   (car (nth ready trace)) (car e)
                                                   (list (drgnx-hub-core-editor new) (drgnx-hub-core-keys-held new))))))))))
    (should (plist-get r :orders))))

(ert-deftest drgnx-hub-core/a-late-challenge-never-makes-legacy ()
  ;; review S2: the challenge wait can pass before the challenge is read; a probe answered first, then a challenge, is
  ;; a v1 hub taken for legacy.  A connection that read a challenge is never left `legacy', and its call is answered once
  (pcase-dolist (`(,kinds . ,lines)
                 (list (cons '(open call challenge answer closed timer version-known)
                             (append (drgnx-hub-core-test--handshake 'cli-1) '((answer cli-1 "agents/list" (:ok t)))))
                       ;; taken for legacy first: no hello, so no version read
                       (cons '(open call challenge answer closed timer)
                             '((answer cli-1 "ping" (:pid 1)) (challenge cli-1) (answer cli-1 "agents/list" (:ok t))))))
    (should (drgnx-hub-core-test--run
             :kinds kinds
             :sources `((act (call :client a "agents/list" nil)) (cli-1 ,@lines) (timers (timer (hub-challenge . cli-1))))
             :edges '(((act . 0) . (cli-1 . 0)) ((act . 0) . (timers . 0)))
             :check (lambda (w _order)
                      (let ((at (drgnx-hub-core-test--fed-at w '(challenge cli-1)))
                            (n (cl-count 'a (drgnx-hub-core-test--w-results w) :key #'car)))
                        (or (and at (cl-loop for e in (nthcdr at (drgnx-hub-core-test--trace w))
                                             when (eq (drgnx-hub-core-test--state (nth 2 e) 'cli-1) 'legacy)
                                             return (format "legacy after %S, which followed the challenge" (car e))))
                            (and (/= n 1) (format "the call was answered %d times" n)))))))))

(ert-deftest drgnx-hub-core/an-event-of-no-kind-signals ()
  ;; the shell's dispatch is exhaustive over the kinds: anything else is a bug, never ignored
  (should-error (drgnx-hub-core-step (drgnx-hub-core-make) '(nonsense)))
  (should-error (drgnx-hub-core-step (drgnx-hub-core-make) '(timer no-such-timer))))

;;; hub-core-test.el ends here
