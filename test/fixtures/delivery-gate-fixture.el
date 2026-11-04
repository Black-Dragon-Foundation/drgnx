;;; delivery-gate-fixture.el --- the hub's lines released in a schedule the test gives -*- lexical-binding: t -*-
;;
;; (drgnx-test-gated SCHEDULE BODY...)   BODY on the manual clock, every hub connection it opens gated
;; (drgnx-test-gate-continue LABEL)      resume after the schedule's (:pause LABEL)
;; (drgnx-test-deliver-all)              barrier, the remaining steps, then every held line; the barrier's marker
;; (drgnx-test-hub-advance MS [HOLD])    the hub's clock moved by MS, then `drgnx-test-deliver-all' (not with HOLD)
;; (drgnx-test-gate-conn NAME)           the process of connection NAME (`call-1', `sub-1', ...)
;; (drgnx-test-gate-held NAME)           what the gate holds for NAME: its lines, then `:eof'
;; (drgnx-test-gate-transcript)          what the gate delivered so far: ((NAME . LINE-or-:eof) ...)
;;
;; DRGNX_TEST_GATE_SWAP=K                the K-th adjacent pair of released lines from different connections is handed
;;                                       over the other way round; each gated run prints `drgnx-gate-swap-pairs: N'
;;                                       (`bin/drgnx test --orders' loops K over 0..N-1)
;;
;; The client side of the `gated' pattern.  The hub (Ratatoskr with `drgnx-test-gate-hub-args') serves the client's
;; lines in the order the gate stamped them (`__seq') and holds the writes no request made; this gate holds what the hub
;; sends, split into whole lines per connection, and hands each line to the client's own filter when the schedule says
;; so, from inside whatever wait the client is in.  Docs: docs/develop/harness.md, "The delivery gate".
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-hub-client)
(load (expand-file-name "clock-fixture" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(load (expand-file-name "wait-fixture" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defconst drgnx-test-gate-hub-args '("--test-clock" "--test-sequencer")
  "What `ratatoskr serve' takes for a gated test: the virtual hub clock and the sequencer (test-hooks builds only).")

(defvar drgnx-test-gate-block-secs 30
  "Real seconds the gate waits for a line a step needs before it fails the test.  It only bounds a failure.")

;;;; State (bound by `drgnx-test-gated')

(defvar drgnx-test-gate-unnamed-ok nil
  "Non-nil: `unnamed' writes (a real agent child's turn, whose tasks the hub cannot name) do not fail the test.  They are
held and released at the barrier like the named ones, so the order they reach the client in is the gate's; what is not
the gate's is whether a write has happened yet, so a test that sets this waits for what the agent did as a condition.")

(defvar drgnx-test-gate--active nil "Non-nil while `drgnx-test-gated' runs its body.")
(defvar drgnx-test-gate--releasing nil
  "The connection's name while the gate hands a line or an end to the client, else nil.  The audit reads it.")
(defvar drgnx-test-gate--steps nil "The schedule still to come: (:pause LABEL) or (NAME KIND ARG), normalized.")
(defvar drgnx-test-gate--implicit nil "Handshake lines due, in the order the client caused them: (CONN . KEY).")
(defvar drgnx-test-gate--conns nil "The gated connections, in open order.")
(defvar drgnx-test-gate--counts nil "(KIND . N): connections of each kind opened so far.")
(defvar drgnx-test-gate--seq 0 "The last `__seq' stamped, across every connection.")
(defvar drgnx-test-gate--transcript nil "The deliveries, newest first.")
(defvar drgnx-test-gate--failure nil "The first failure of the gate, re-raised at each later wait and at the end.")
(defvar drgnx-test-gate--raw nil "Emacs's own `accept-process-output', for the gate's real looks.")
(defvar drgnx-test-gate--opening nil "Inside `drgnx-hub--open': (EVENTS).")
(defvar drgnx-test-gate--control nil "The gate's own connection to the hub, for the barrier and the clock.")
(defvar drgnx-test-gate--real-status nil "Non-nil: `process-status' says what Emacs knows, held ends included.")
(defvar drgnx-test-gate--swap nil "K of `DRGNX_TEST_GATE_SWAP=K' for this run, or nil.")
(defvar drgnx-test-gate--swap-pairs 0 "The pairs of lines from different connections met so far (only counted with a swap).")
(defvar drgnx-test-gate--lag nil "The released line the swap holds back: (CONN . LINE), or nil.")
(defvar drgnx-test-gate--before nil "The processes there when the body began: none of them is the body's child.")
(defvar drgnx-test-gate--progress nil
  "The real time the code under test last saw output, or a child end, while it waited on its children; nil between
such waits.")

(defvar drgnx-test--active)
(defvar drgnx-test--core)
(defvar drgnx-test--accept)
(declare-function drgnx-test--call-with-clock "clock-fixture" (body allow-pending &optional auto))
(declare-function drgnx-test--drop-emacs-timers "clock-fixture" ())
(declare-function drgnx-test--wait-secs "clock-fixture" (seconds millisec))
(declare-function drgnx-test-advance "clock-fixture" (secs))
(declare-function drgnx-test-real-time "clock-fixture" ())
(declare-function drgnx-test-clock-now "clock-fixture" ())

(cl-defstruct (drgnx-test-gate--conn (:constructor drgnx-test-gate--conn-make) (:copier nil))
  name proc filter sentinel
  (queue nil) (partial "")
  (sent nil)            ; requests not answered yet: ((ID METHOD IMPLICIT) ...), oldest first
  (handshake nil)       ; the handshake methods already sent (the first ping, the hello)
  (challenged nil)      ; its challenge was delivered
  (eof nil)             ; its end is held
  (ended nil)           ; its end was seen (held or delivered)
  (deleted nil)         ; the client deleted it
  (marker 0))

;;;; Failures

(defconst drgnx-test-gate--not-callers
  "\\`\\(?:drgnx-test-gate-\\|drgnx-test-wait\\|accept-process-output\\'\\|apply\\'\\|funcall\\'\\|mapbacktrace\\'\\|advice--\\|signal\\'\\|ert-\\)"
  "Frames that are the gate's own, not the code that waits.")

(defun drgnx-test-gate--caller ()
  "The innermost function on the stack that is not the gate's or a wait's: the code that waits."
  (catch 'found
    (mapbacktrace (lambda (evald fun _args _flags)
                    (when (and evald (symbolp fun) fun (not (special-form-p fun))
                               (not (string-match-p drgnx-test-gate--not-callers (symbol-name fun))))
                      (throw 'found fun))))
    nil))

(defun drgnx-test-gate--fail (message &rest data)
  "Fail the test with MESSAGE and DATA (a plist), naming what the gate holds.  Kept, so a failure raised inside a
filter (whose guard records errors) is raised again at the next wait and at the end of `drgnx-test-gated'."
  (let ((f (append (list message) data (list :held (drgnx-test-gate--held-all)))))
    (unless drgnx-test-gate--failure (setq drgnx-test-gate--failure f))
    (signal 'ert-test-failed (list f))))

(defun drgnx-test-gate--rethrow ()
  (when drgnx-test-gate--failure (signal 'ert-test-failed (list drgnx-test-gate--failure))))

(defun drgnx-test-gate--check-active ()
  (unless drgnx-test-gate--active (error "Not inside drgnx-test-gated")))

;;;; Connections

(defun drgnx-test-gate--of (proc)
  (and (processp proc) (process-get proc :drgnx-gate)))

(defun drgnx-test-gate--find (name)
  (let ((name (if (stringp name) (intern name) name)))
    (cl-find name drgnx-test-gate--conns :key #'drgnx-test-gate--conn-name)))

(defun drgnx-test-gate--live-p (proc)
  "Whether PROC is open as far as Emacs knows: held ends do not count."
  (let ((drgnx-test-gate--real-status t)) (process-live-p proc)))

(defun drgnx-test-gate--register (proc events)
  "PROC, a connection `drgnx-hub--open' makes (EVENTS non-nil: the subscribed one), gated from now on."
  (let* ((kind (if events "sub" "call"))
         (n (1+ (or (cdr (assoc kind drgnx-test-gate--counts)) 0)))
         (c (drgnx-test-gate--conn-make :name (intern (format "%s-%d" kind n)) :proc proc
                                        :filter (process-filter proc) :sentinel (process-sentinel proc))))
    (setf (alist-get kind drgnx-test-gate--counts nil nil #'equal) n)
    ;; set before PROC is known to the gate: these two go to Emacs itself
    (set-process-filter proc #'drgnx-test-gate--input)
    (set-process-sentinel proc #'drgnx-test-gate--end)
    (process-put proc :drgnx-gate c)
    (setq drgnx-test-gate--conns (append drgnx-test-gate--conns (list c)))
    (setq drgnx-test-gate--implicit (append drgnx-test-gate--implicit (list (cons c :challenge))))
    c))

(defun drgnx-test-gate--input (proc chunk)
  "A gated connection's filter: CHUNK split into whole lines, held in PROC's queue.  The hub's barrier markers are
taken out and counted."
  (when-let* ((c (drgnx-test-gate--of proc)))
    (unless (drgnx-test-gate--conn-deleted c)
      (let ((text (concat (drgnx-test-gate--conn-partial c) chunk)) (start 0) nl)
        (while (setq nl (string-search "\n" text start))
          (let* ((line (substring text start (1+ nl)))
                 (json (condition-case nil
                           (json-parse-string line :object-type 'plist :null-object nil :false-object nil)
                         (error nil))))
            (if (equal (plist-get json :event) "__test_marker")
                (setf (drgnx-test-gate--conn-marker c) (plist-get (plist-get json :data) :marker))
              (setf (drgnx-test-gate--conn-queue c)
                    (nconc (drgnx-test-gate--conn-queue c) (list (list :line line json))))))
          (setq start (1+ nl)))
        (setf (drgnx-test-gate--conn-partial c) (substring text start))))))

(defun drgnx-test-gate--hold-end (c event)
  "C's end, EVENT, held after its lines (a part of a line left is handed over just before it)."
  (unless (or (drgnx-test-gate--conn-ended c) (drgnx-test-gate--conn-deleted c))
    (let ((rest (drgnx-test-gate--conn-partial c)))
      (setf (drgnx-test-gate--conn-partial c) "")
      (setf (drgnx-test-gate--conn-queue c)
            (nconc (drgnx-test-gate--conn-queue c)
                   (and (not (string-empty-p rest)) (list (list :line rest nil)))
                   (list (list :eof event))))
      (setf (drgnx-test-gate--conn-eof c) t (drgnx-test-gate--conn-ended c) t))))

(defun drgnx-test-gate--end (proc event)
  "A gated connection's sentinel.  The client's own delete runs the client's sentinel at once and drops what was held;
an end from the hub is held after that connection's lines."
  (when-let* ((c (drgnx-test-gate--of proc)))
    (cond ((drgnx-test-gate--conn-deleted c))
          ((string-prefix-p "deleted" event)
           (setf (drgnx-test-gate--conn-deleted c) t (drgnx-test-gate--conn-queue c) nil
                 (drgnx-test-gate--conn-partial c) "" (drgnx-test-gate--conn-eof c) nil
                 (drgnx-test-gate--conn-sent c) nil)
           (when (drgnx-test-gate--conn-sentinel c)
             (funcall (drgnx-test-gate--conn-sentinel c) proc event)))
          ((not (drgnx-test-gate--live-p proc)) (drgnx-test-gate--hold-end c event))
          ((drgnx-test-gate--conn-sentinel c) (funcall (drgnx-test-gate--conn-sentinel c) proc event)))))

(defun drgnx-test-gate--note-ended (c)
  "C closed in Emacs but its sentinel has not run yet: its end is held now, so a wait for it sees it."
  (when (and (not (drgnx-test-gate--conn-ended c)) (not (drgnx-test-gate--conn-deleted c))
             (not (drgnx-test-gate--live-p (drgnx-test-gate--conn-proc c))))
    (drgnx-test-gate--hold-end c "connection broken by remote peer\n")))

;;;; Matching held lines

(defun drgnx-test-gate--item-event (item)
  (and (eq (car item) :line) (plist-get (nth 2 item) :event)))

(defun drgnx-test-gate--item-id (item)
  "The id of the answer ITEM carries, or nil."
  (let ((json (nth 2 item)))
    (and (eq (car item) :line) (not (plist-get json :event)) (plist-get json :id))))

(defun drgnx-test-gate--match (c key)
  "The position in C's queue of the item KEY names: `:challenge', (:id . ID), (:event . NAME), `:line' or `:eof'."
  (cl-position-if
   (lambda (item)
     (pcase key
       (:challenge (equal (drgnx-test-gate--item-event item) "challenge"))
       (`(:id . ,id) (equal (drgnx-test-gate--item-id item) id))
       (`(:event . ,name) (equal (drgnx-test-gate--item-event item) name))
       (:line (eq (car item) :line))
       (:eof (eq (car item) :eof))))
   (drgnx-test-gate--conn-queue c)))

(defun drgnx-test-gate--block (c key what)
  "Wait, for real, until C holds the item KEY names; its position.  Its end, its delete or
`drgnx-test-gate-block-secs' first fails the test naming WHAT.  Only C is read, and no timer runs meanwhile."
  (let ((deadline (+ (drgnx-test-real-time) drgnx-test-gate-block-secs)) at)
    (while (not (setq at (drgnx-test-gate--match c key)))
      (drgnx-test-gate--note-ended c)
      (cond ((drgnx-test-gate--conn-deleted c)
             (drgnx-test-gate--fail "drgnx-test-gated: the client deleted the connection a step waits on"
                                    :conn (drgnx-test-gate--conn-name c) :step what))
            ((drgnx-test-gate--match c key))
            ((drgnx-test-gate--conn-eof c)
             (drgnx-test-gate--fail "drgnx-test-gated: the connection ended before the line a step waits for"
                                    :conn (drgnx-test-gate--conn-name c) :step what))
            ((> (drgnx-test-real-time) deadline)
             (drgnx-test-gate--fail "drgnx-test-gated: the line a step waits for did not come"
                                    :conn (drgnx-test-gate--conn-name c) :step what :secs drgnx-test-gate-block-secs))
            (t (funcall drgnx-test-gate--raw (drgnx-test-gate--conn-proc c) 0.05 nil 0))))
    at))

;;;; Delivery

(defun drgnx-test-gate--swap-env ()
  "K of `DRGNX_TEST_GATE_SWAP=K' (a number), or nil when it is unset."
  (let ((v (getenv "DRGNX_TEST_GATE_SWAP")))
    (and v (string-match-p "\\`[0-9]+\\'" v) (string-to-number v))))

(defun drgnx-test-gate--hand (c line)
  "Hand LINE to C's filter, as the transcript's next delivery.  Nothing when the client deleted C meanwhile."
  (unless (drgnx-test-gate--conn-deleted c)
    (let* ((name (drgnx-test-gate--conn-name c)) (drgnx-test-gate--releasing name))
      (push (cons name (string-trim-right line "\n")) drgnx-test-gate--transcript)
      (when (drgnx-test-gate--conn-filter c)
        (funcall (drgnx-test-gate--conn-filter c) (drgnx-test-gate--conn-proc c) line)))))

(defun drgnx-test-gate--flush ()
  "Hand over the line the swap holds back, if any."
  (when drgnx-test-gate--lag
    (let ((held drgnx-test-gate--lag))
      (setq drgnx-test-gate--lag nil)
      (drgnx-test-gate--hand (car held) (cdr held)))))

(defun drgnx-test-gate--emit (c line)
  "A line released for C.  With `DRGNX_TEST_GATE_SWAP' set, each line waits for the next one released in the same batch:
the two make a pair when they are on different connections, the K-th pair (counted from 0) is handed over the other
way round.  A line is never handed over after a later line of its own connection."
  (let ((prev drgnx-test-gate--lag))
    (cond ((null drgnx-test-gate--swap) (drgnx-test-gate--hand c line))
          ((or (null prev) (eq (car prev) c))
           (setq drgnx-test-gate--lag (cons c line))
           (when prev (drgnx-test-gate--hand (car prev) (cdr prev))))
          (t (let ((n drgnx-test-gate--swap-pairs))
               (cl-incf drgnx-test-gate--swap-pairs)
               (if (= n drgnx-test-gate--swap)
                   ;; PREV stays held while C's line goes first, so a later line of PREV's connection still follows it
                   (progn (drgnx-test-gate--hand c line)
                          (when (eq drgnx-test-gate--lag prev)
                            (setq drgnx-test-gate--lag nil)
                            (drgnx-test-gate--hand (car prev) (cdr prev))))
                 (setq drgnx-test-gate--lag (cons c line))
                 (drgnx-test-gate--hand (car prev) (cdr prev))))))))

(defun drgnx-test-gate-swap-pairs ()
  "How many pairs of lines from different connections the swap has met so far (nil when `DRGNX_TEST_GATE_SWAP' is unset)."
  (and drgnx-test-gate--swap drgnx-test-gate--swap-pairs))

(defun drgnx-test-gate--deliver (c upto)
  "Hand C's held items, the first through position UPTO, to the client: a line as one call of its filter, the end
as its sentinel.  A delete by the client on the way drops the rest."
  (dotimes (_ (1+ upto))
    (unless (or (drgnx-test-gate--conn-deleted c) (null (drgnx-test-gate--conn-queue c)))
      (let* ((item (pop (drgnx-test-gate--conn-queue c))) (proc (drgnx-test-gate--conn-proc c))
             (name (drgnx-test-gate--conn-name c)) (drgnx-test-gate--releasing name))
        (if (eq (car item) :eof)
            (progn (drgnx-test-gate--flush)
                   (setf (drgnx-test-gate--conn-eof c) nil)
                   (push (cons name :eof) drgnx-test-gate--transcript)
                   (when (drgnx-test-gate--conn-sentinel c)
                     (funcall (drgnx-test-gate--conn-sentinel c) proc (nth 1 item))))
          (let ((line (nth 1 item)) (id (drgnx-test-gate--item-id item)))
            (when id
              (setf (drgnx-test-gate--conn-sent c) (cl-remove id (drgnx-test-gate--conn-sent c) :key #'car :test #'equal)))
            (when (equal (drgnx-test-gate--item-event item) "challenge") (setf (drgnx-test-gate--conn-challenged c) t))
            (drgnx-test-gate--emit c line)))))))

(defun drgnx-test-gate--implicit-done-p (entry)
  (let ((c (car entry)) (key (cdr entry)))
    (or (drgnx-test-gate--conn-deleted c)
        (if (eq key :challenge) (drgnx-test-gate--conn-challenged c)
          (not (assoc (cdr key) (drgnx-test-gate--conn-sent c)))))))

(defun drgnx-test-gate--release-implicit ()
  "Release the first handshake line due (a challenge, the answer to the first ping or to the hello); whether one was.
An end that comes first leaves the lines before it delivered and the end held."
  (let (done)
    (while (and (not done) drgnx-test-gate--implicit)
      (let ((entry (pop drgnx-test-gate--implicit)))
        (unless (drgnx-test-gate--implicit-done-p entry)
          (let* ((c (car entry)) (at (drgnx-test-gate--block-quiet c (cdr entry)))
                 (end (and (not at) (drgnx-test-gate--match c :eof))))
            (cond (at (drgnx-test-gate--deliver c at) (setq done t))
                  ((and end (> end 0)) (drgnx-test-gate--deliver c (1- end)) (setq done t)))))))
    done))

(defun drgnx-test-gate--block-quiet (c key)
  "`drgnx-test-gate--block' for a handshake line: nil instead of a failure when C ends first; a timeout fails."
  (let ((deadline (+ (drgnx-test-real-time) drgnx-test-gate-block-secs)) at)
    (while (and (not (setq at (drgnx-test-gate--match c key)))
                (progn (drgnx-test-gate--note-ended c)
                       (not (or (drgnx-test-gate--conn-eof c) (drgnx-test-gate--conn-deleted c)))))
      (when (> (drgnx-test-real-time) deadline)
        (drgnx-test-gate--fail "drgnx-test-gated: a handshake line did not come"
                               :conn (drgnx-test-gate--conn-name c) :line key :secs drgnx-test-gate-block-secs))
      (funcall drgnx-test-gate--raw (drgnx-test-gate--conn-proc c) 0.05 nil 0))
    at))

(defun drgnx-test-gate--step-key (c step)
  "The item STEP waits for on C: (:id . ID) for an answer (nil when no such call is out yet), else its key."
  (pcase (nth 1 step)
    (:answer (let ((call (cl-find-if (lambda (s) (and (equal (nth 1 s) (nth 2 step)) (not (nth 2 s))))
                                     (drgnx-test-gate--conn-sent c))))
               (and call (cons :id (car call)))))
    (:event (cons :event (nth 2 step)))
    (:line :line)
    (:eof :eof)))

(defun drgnx-test-gate--paused-p ()
  (eq (car (car drgnx-test-gate--steps)) :pause))

(defun drgnx-test-gate--release-step ()
  "Release the next step of the schedule if it is due; whether it was.  A step is due once its connection is open, and
an answer once its call has gone out; the gate then waits for its line."
  (let* ((step (car drgnx-test-gate--steps))
         (c (and step (not (eq (car step) :pause)) (drgnx-test-gate--find (car step))))
         (key (and c (drgnx-test-gate--step-key c step))))
    (cond ((or (null step) (eq (car step) :pause)) nil)
          ((null c) nil)
          ((drgnx-test-gate--conn-deleted c)
           (drgnx-test-gate--fail "drgnx-test-gated: a step names a connection the client deleted" :step step))
          ((null key) nil)
          (t (pop drgnx-test-gate--steps)
             (drgnx-test-gate--deliver c (drgnx-test-gate--block c key step))
             t))))

(defun drgnx-test-gate--release ()
  "Release what is due, in order, up to the next pause: the handshake lines first each time, then the next step.
Whether anything was released."
  (let ((any nil) (go t))
    (while (and go (not (drgnx-test-gate--paused-p)))
      (setq go (or (drgnx-test-gate--release-implicit) (drgnx-test-gate--release-step)))
      (when go (setq any t)))
    (drgnx-test-gate--flush)
    any))

;;;; Waits inside the body

(defun drgnx-test-gate--held-all ()
  "((NAME ITEM...) ...) for each connection holding something: lines, then `:eof'."
  (cl-loop for c in drgnx-test-gate--conns
           for items = (drgnx-test-gate-held (drgnx-test-gate--conn-name c))
           when items collect (cons (drgnx-test-gate--conn-name c) items)))

(defun drgnx-test-gate--awaited-p ()
  "Whether some gated connection holds something or has a call out: what a wait now would wait for."
  (cl-some (lambda (c) (and (not (drgnx-test-gate--conn-deleted c))
                            (or (drgnx-test-gate--conn-queue c) (drgnx-test-gate--conn-sent c)
                                (not (drgnx-test-gate--conn-challenged c)))))
           drgnx-test-gate--conns))

(defun drgnx-test-gate--children ()
  "The body's live real children the code under test may wait on: started inside the body, not peers (a hub, a mock
server or a handshake child the test drives: `:drgnx-test-peer').  The hub's jobs are its children, not these."
  (cl-remove-if-not (lambda (p) (and (eq (process-type p) 'real) (process-live-p p)
                                     (not (memq p drgnx-test-gate--before))
                                     (not (process-get p :drgnx-test-peer))))
                    (process-list)))

(defun drgnx-test-gate--on-children (children)
  "A timed wait of the code under test while CHILDREN (`drgnx-test-gate--children') live: no virtual time moves, a
real look of up to 50 ms instead.  Non-nil when output came (from any process) or a child ended.  No output and no end
for `drgnx-test-gate-block-secs' of real time fails the test, naming the children and the code that waits."
  (let ((now (drgnx-test-real-time)))
    (unless drgnx-test-gate--progress (setq drgnx-test-gate--progress now))
    (if (or (funcall drgnx-test-gate--raw nil 0.05)
            (cl-notevery #'process-live-p children))
        (progn (setq drgnx-test-gate--progress (drgnx-test-real-time)) t)
      (when (> (- (drgnx-test-real-time) drgnx-test-gate--progress) drgnx-test-gate-block-secs)
        (drgnx-test-gate--fail "drgnx-test-gated: a real child the code under test waits on did not answer"
                               :children (mapcar (lambda (p) (cons (process-name p) (process-command p))) children)
                               :caller (drgnx-test-gate--caller) :secs drgnx-test-gate-block-secs))
      nil)))

(defun drgnx-test-gate--idle (orig process seconds millisec just-this-one)
  "A wait with nothing to release: one on another process is the clock's own.  A timed one while the body's real
children live waits on them for real (`drgnx-test-gate--on-children'); else a zero-length look, virtual time moved by
its timeout (its timers running), and a look again.  Nil: nothing was delivered."
  (if (and process (not (drgnx-test-gate--of process)))
      (funcall orig process seconds millisec just-this-one)
    (let* ((secs (drgnx-test--wait-secs seconds millisec))
           (children (and secs (> secs 0) (drgnx-test-gate--children))))
      (if children
          (drgnx-test-gate--on-children children)
        (setq drgnx-test-gate--progress nil)
        (funcall drgnx-test-gate--raw process 0 nil just-this-one)
        (when (and secs (> secs 0))
          (drgnx-test-advance secs)
          (funcall drgnx-test-gate--raw process 0 nil just-this-one))
        nil))))

(defun drgnx-test-gate--accept (orig &optional process seconds millisec just-this-one)
  "`accept-process-output' inside the gate (also deep inside the code under test): what the schedule has due is
released; with nothing to release, `drgnx-test-gate--idle'.  While paused, a wait (with a timeout above 0, or none)
with lines held or calls out fails the test at once, naming the pause and the code that waits; a zero-length look only
looks."
  (drgnx-test-gate--rethrow)
  (cond ((drgnx-test-gate--paused-p)
         (when (and (drgnx-test-gate--awaited-p)
                    (let ((secs (drgnx-test--wait-secs seconds millisec))) (or (null secs) (> secs 0))))
           (drgnx-test-gate--fail "drgnx-test-gated: a wait while the schedule is paused, on a line it holds"
                                  :pause (nth 1 (car drgnx-test-gate--steps)) :next (cadr drgnx-test-gate--steps)
                                  :caller (drgnx-test-gate--caller) :virtual-secs (drgnx-test-clock-now)))
         (drgnx-test-gate--idle orig process seconds millisec just-this-one))
        ((drgnx-test-gate--release) t)
        (t (drgnx-test-gate--idle orig process seconds millisec just-this-one))))

(defun drgnx-test-gate--test-step (secs)
  "One poll of `drgnx-test-wait' inside the gate: what is due is released (nothing while paused), else a real look of
up to SECS that moves no virtual time.  A test's own wait never fails for a pause."
  (drgnx-test-gate--rethrow)
  (unless (and (not (drgnx-test-gate--paused-p)) (drgnx-test-gate--release))
    (funcall drgnx-test-gate--raw nil secs)))

;;;; Advice on the client and on Emacs

(defun drgnx-test-gate--open (orig events)
  "`drgnx-hub--open' inside the gate: the connection is gated, and the gate waits for its challenge (held), so the hub
knows the connection before any later stamped line is written."
  (let ((proc (let ((drgnx-test-gate--opening (list events))) (funcall orig events))))
    (when (processp proc)
      (let ((c (or (drgnx-test-gate--of proc) (drgnx-test-gate--register proc events))))
        (drgnx-test-gate--block-quiet c :challenge)))
    proc))

(defun drgnx-test-gate--note-sent (c line)
  "LINE, a request C sends: its id and method, a handshake one (the first ping, the hello) due as a handshake line."
  (let* ((json (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil)))
         (id (plist-get json :id)) (method (plist-get json :method)))
    (when (and id (stringp method))
      (let ((implicit (and (member method '("ping" "hello")) (not (member method (drgnx-test-gate--conn-handshake c))))))
        (when implicit
          (push method (drgnx-test-gate--conn-handshake c))
          (setq drgnx-test-gate--implicit (append drgnx-test-gate--implicit (list (cons c (cons :id id))))))
        (setf (drgnx-test-gate--conn-sent c) (append (drgnx-test-gate--conn-sent c) (list (list id method implicit))))))))

(defun drgnx-test-gate--send-line (orig conn line)
  "`drgnx-hub--send-line' inside the gate: a line on a gated connection gets the next `__seq', counted across every
connection in the order the client writes them."
  (let ((c (or (drgnx-test-gate--of conn)
               (and drgnx-test-gate--opening (processp conn)
                    (drgnx-test-gate--register conn (car drgnx-test-gate--opening))))))
    (if (and c (not (drgnx-test-gate--conn-deleted c)) (process-live-p conn) (string-prefix-p "{" line))
        (let ((n (cl-incf drgnx-test-gate--seq)))
          (drgnx-test-gate--note-sent c line)
          (funcall orig conn (concat "{\"__seq\":" (number-to-string n)
                                     (if (string-prefix-p "{}" line) "" ",") (substring line 1))))
      (funcall orig conn line))))

(defun drgnx-test-gate--status (orig process)
  "`process-status': a gated connection whose end is held is still `open', so no close is seen before its lines."
  (let ((c (and (not drgnx-test-gate--real-status) (drgnx-test-gate--of process))))
    (if (and c (drgnx-test-gate--conn-eof c) (not (drgnx-test-gate--conn-deleted c)))
        'open
      (funcall orig process))))

(defun drgnx-test-gate--set-sentinel (orig process sentinel)
  "`set-process-sentinel' on a gated connection replaces the client's sentinel behind the gate's."
  (let ((c (drgnx-test-gate--of process)))
    (if c (setf (drgnx-test-gate--conn-sentinel c) sentinel) (funcall orig process sentinel))))

(defun drgnx-test-gate--get-sentinel (orig process)
  "`process-sentinel' of a gated connection: the client's (so `add-function' on it wraps the client's)."
  (let ((c (drgnx-test-gate--of process)))
    (if c (drgnx-test-gate--conn-sentinel c) (funcall orig process))))

(defconst drgnx-test-gate--advice
  '((accept-process-output :around drgnx-test-gate--accept)
    (process-status :around drgnx-test-gate--status)
    (set-process-sentinel :around drgnx-test-gate--set-sentinel)
    (process-sentinel :around drgnx-test-gate--get-sentinel)
    (drgnx-hub--open :around drgnx-test-gate--open)
    (drgnx-hub--send-line :around drgnx-test-gate--send-line)
    (drgnx-test-wait--manual-step :override drgnx-test-gate--test-step))
  "What the gate advises while its body runs.")

(defun drgnx-test-gate--warm ()
  "Advise and unadvise each primitive the gate advises, on scratch timer lists (see `drgnx-test--warm-trampolines')."
  (let ((timer-list nil) (timer-idle-list nil))
    (dolist (a drgnx-test-gate--advice)
      (when (subrp (symbol-function (car a)))
        (advice-add (car a) :around #'ignore)
        (advice-remove (car a) #'ignore)))
    (drgnx-test--drop-emacs-timers)))

;;;; The hub's side: the gate's own connection, the barrier and the clock

(defun drgnx-test-gate--control-input (proc chunk)
  (let ((text (concat (or (process-get proc :partial) "") chunk)) (start 0) nl)
    (while (setq nl (string-search "\n" text start))
      (let ((json (ignore-errors (json-parse-string (substring text start nl) :object-type 'plist
                                                    :null-object nil :false-object nil))))
        (cond ((equal (plist-get json :event) "challenge") (process-put proc :challenged t))
              ((plist-get json :event))
              ((plist-get json :id) (puthash (plist-get json :id) json (process-get proc :answers)))))
      (setq start (1+ nl)))
    (process-put proc :partial (substring text start))))

(defun drgnx-test-gate--control-wait (proc pred what)
  "Wait, for real, until PRED; nil when PROC closed first.  `drgnx-test-gate-block-secs' fails the test."
  (let ((deadline (+ (drgnx-test-real-time) drgnx-test-gate-block-secs)))
    (while (and (not (funcall pred)) (drgnx-test-gate--live-p proc))
      (when (> (drgnx-test-real-time) deadline)
        (drgnx-test-gate--fail "drgnx-test-gated: the hub did not answer the gate" :waiting-for what))
      (funcall drgnx-test-gate--raw proc 0.05 nil 0))
    (funcall pred)))

(defun drgnx-test-gate--control-proc ()
  "The gate's own connection to the hub, opened at its first use; nil when no hub answers."
  (unless (and drgnx-test-gate--control (drgnx-test-gate--live-p drgnx-test-gate--control))
    (setq drgnx-test-gate--control
          (condition-case nil
              (let ((p (make-network-process :name "drgnx-test-gate" :family 'local :service (drgnx-hub-socket)
                                             :noquery t :coding 'utf-8-unix :filter #'drgnx-test-gate--control-input
                                             :sentinel #'ignore)))
                (process-put p :answers (make-hash-table :test #'equal))
                (and (drgnx-test-gate--control-wait p (lambda () (process-get p :challenged)) "its challenge") p))
            (file-error nil))))
  drgnx-test-gate--control)

(defun drgnx-test-gate--control-call (method params)
  "Ask the hub METHOD with PARAMS (a plist) on the gate's own connection, stamped; its answer (a plist), or nil when
no hub answers."
  (when-let* ((p (drgnx-test-gate--control-proc)))
    (let ((id (1+ (or (process-get p :next) 0))))
      (process-put p :next id)
      (condition-case nil
          (process-send-string p (concat (json-serialize (list :__seq (cl-incf drgnx-test-gate--seq) :id id :method method
                                                               :params (or params (make-hash-table))))
                                         "\n"))
        (error nil))
      (drgnx-test-gate--control-wait p (lambda () (gethash id (process-get p :answers))) method))))

(defun drgnx-test-gate--check-answer (answer method)
  "ANSWER to the gate's METHOD: its result, after failing the test on an error or on `unnamed' writes."
  (let ((result (plist-get answer :result)))
    (when (plist-get answer :error)
      (drgnx-test-gate--fail (format "drgnx-test-gated: the hub refused %s (is Ratatoskr built with test-hooks?)" method)
                             :error (plist-get answer :error)))
    (when (and (> (or (plist-get result :unnamed) 0) 0) (not drgnx-test-gate-unnamed-ok))
      (drgnx-test-gate--fail "drgnx-test-gated: the hub wrote from tasks without an origin (not deterministic)"
                             :method method :unnamed (plist-get result :unnamed) :busy (plist-get result :busy)))
    result))

(defun drgnx-test-gate--barrier ()
  "`__test_barrier': once answered, each open gated connection's marker is waited for, so everything the hub wrote
before it is held.  The marker M, or nil when no hub answers."
  (when-let* ((answer (drgnx-test-gate--control-call "__test_barrier" nil)))
    (let ((m (plist-get (drgnx-test-gate--check-answer answer "__test_barrier") :marker)))
      (dolist (c drgnx-test-gate--conns)
        (unless (or (drgnx-test-gate--conn-deleted c) (drgnx-test-gate--conn-ended c))
          (let ((deadline (+ (drgnx-test-real-time) drgnx-test-gate-block-secs)))
            (while (not (or (>= (drgnx-test-gate--conn-marker c) m)
                            (progn (drgnx-test-gate--note-ended c) (drgnx-test-gate--conn-ended c))))
              (when (> (drgnx-test-real-time) deadline)
                (drgnx-test-gate--fail "drgnx-test-gated: a connection did not get the barrier's marker"
                                       :conn (drgnx-test-gate--conn-name c) :marker m))
              (funcall drgnx-test-gate--raw (drgnx-test-gate--conn-proc c) 0.05 nil 0)))))
      m)))

(defun drgnx-test-gate--release-all (mark alive)
  "`drgnx-test-deliver-all''s release after a barrier (ALIVE: one was answered; MARK: the last `__seq' then): every
handshake line and every step, pauses skipped.  `again' when a step waits for a line the client sent after the
barrier (another barrier is needed), else t.  A step that cannot be met fails the test."
  (let ((result nil))
    (while (not result)
      (unless (drgnx-test-gate--release-implicit)
        (let* ((step (car drgnx-test-gate--steps))
               (moved (/= drgnx-test-gate--seq mark))
               (c (and step (not (eq (car step) :pause)) (drgnx-test-gate--find (car step))))
               (key (and c (drgnx-test-gate--step-key c step))))
          (cond ((null step) (setq result t))
                ((eq (car step) :pause) (pop drgnx-test-gate--steps))
                ((and (or (null c) (null key)) moved) (setq result 'again))
                ((null c) (drgnx-test-gate--fail "drgnx-test-gated: a step names a connection that never opened" :step step))
                ((drgnx-test-gate--conn-deleted c)
                 (drgnx-test-gate--fail "drgnx-test-gated: a step names a connection the client deleted" :step step))
                ((null key) (drgnx-test-gate--fail "drgnx-test-gated: a step's call was never sent" :step step))
                ((drgnx-test-gate--match c key)
                 (pop drgnx-test-gate--steps)
                 (drgnx-test-gate--deliver c (drgnx-test-gate--match c key)))
                ((and alive moved) (setq result 'again))
                (alive (drgnx-test-gate--fail "drgnx-test-gated: a step's line had not come by the barrier" :step step))
                (t (pop drgnx-test-gate--steps)
                   (drgnx-test-gate--deliver c (drgnx-test-gate--block c key step)))))))
    result))

(defun drgnx-test-gate--settled-p (mark)
  (and (= drgnx-test-gate--seq mark) (null drgnx-test-gate--steps) (null drgnx-test-gate--implicit)
       (cl-every (lambda (c) (or (drgnx-test-gate--conn-deleted c) (null (drgnx-test-gate--conn-queue c))))
                 drgnx-test-gate--conns)))

(defun drgnx-test-deliver-all ()
  "Release everything, then return the hub's barrier marker M (nil when no hub answers any more).
`__test_barrier' first (the hub serves every line it has, releases its held writes and writes marker M on every
connection; each one's marker is waited for), then the remaining steps (pauses skipped), then every held line in
connection open order.  What the client sends meanwhile gets another barrier, until nothing moves.  Fails when the hub
wrote from a task without an origin (`unnamed' > 0) or a step cannot be met."
  (drgnx-test-gate--check-active)
  (drgnx-test-gate--rethrow)
  (let ((m nil) (rounds 0) (done nil))
    (while (not done)
      (when (> (cl-incf rounds) 100)
        (drgnx-test-gate--fail "drgnx-test-deliver-all: the client and the hub do not settle (100 barriers)"))
      (let* ((bm (drgnx-test-gate--barrier)) (mark drgnx-test-gate--seq))
        (when bm (setq m bm))
        (when (eq (drgnx-test-gate--release-all mark (and bm t)) t)
          (dolist (c drgnx-test-gate--conns)
            (let ((n (length (drgnx-test-gate--conn-queue c))))
              (when (> n 0) (drgnx-test-gate--deliver c (1- n)))))
          (drgnx-test-gate--flush)
          (setq done (drgnx-test-gate--settled-p mark)))))
    m))

(defun drgnx-test-hub-advance (ms &optional hold)
  "Move the hub's clock MS milliseconds (`__test_advance'), then `drgnx-test-deliver-all'; its marker.
HOLD non-nil: no `drgnx-test-deliver-all' (and no barrier) after it, for a test that lets the hub end first; the
advance's result."
  (drgnx-test-gate--check-active)
  (drgnx-test-gate--rethrow)
  (let* ((answer (drgnx-test-gate--control-call "__test_advance" (list :ms ms)))
         (result (progn (unless answer (drgnx-test-gate--fail "drgnx-test-hub-advance: no hub answers"))
                        (drgnx-test-gate--check-answer answer "__test_advance"))))
    (if hold result (drgnx-test-deliver-all))))

;;;; The test's view

(defun drgnx-test-gate-continue (label)
  "Resume the schedule after its (:pause LABEL); an error when it is not paused there."
  (drgnx-test-gate--check-active)
  (unless (equal (car drgnx-test-gate--steps) (list :pause label))
    (error "drgnx-test-gate-continue: the schedule is not at (:pause %S) but at %S" label (car drgnx-test-gate--steps)))
  (pop drgnx-test-gate--steps)
  nil)

(defun drgnx-test-gate-conn (name)
  "The process of gated connection NAME (a symbol or string: `call-1', `sub-1'), or nil."
  (when-let* ((c (drgnx-test-gate--find name))) (drgnx-test-gate--conn-proc c)))

(defun drgnx-test-gate-held (name)
  "What the gate holds for connection NAME: its lines (strings, without the newline), then `:eof' when its end is held."
  (when-let* ((c (drgnx-test-gate--find name)))
    (mapcar (lambda (item) (if (eq (car item) :eof) :eof (string-trim-right (nth 1 item) "\n")))
            (drgnx-test-gate--conn-queue c))))

(defun drgnx-test-gate-transcript ()
  "What the gate has delivered, oldest first: (NAME . LINE) for a line (without the newline), (NAME . :eof) for an end."
  (reverse drgnx-test-gate--transcript))

;;;; The macro

(defun drgnx-test-gate--normalize (schedule)
  "SCHEDULE checked and normalized: (:pause LABEL) or (NAME KIND ARG), NAME a symbol."
  (mapcar
   (lambda (step)
     (pcase step
       (`(:pause ,label) (list :pause label))
       (`(,name ,kind . ,args)
        (let ((name (if (stringp name) (intern name) name)))
          (unless (and (symbolp name) (string-match-p "\\`\\(?:call\\|sub\\)-[0-9]+\\'" (symbol-name name)))
            (error "drgnx-test-gated: a step's connection is call-N or sub-N: %S" step))
          (pcase kind
            ((or :answer :event)
             (unless (and (= (length args) 1) (stringp (car args)))
               (error "drgnx-test-gated: (%s %s NAME) takes a method or event name: %S" name kind step))
             (when (and (eq kind :event) (equal (car args) "challenge"))
               (error "drgnx-test-gated: the challenge is a handshake line, released by itself: %S" step))
             (list name kind (car args)))
            ((or :line :eof)
             (when args (error "drgnx-test-gated: (%s %s) takes nothing more: %S" name kind step))
             (list name kind nil))
            (_ (error "drgnx-test-gated: a step is :answer, :event, :line or :eof: %S" step)))))
       (_ (error "drgnx-test-gated: not a step: %S" step))))
   schedule))

(defun drgnx-test-gate--restore ()
  "Every gated connection still open gets the client's own filter and sentinel back; what was held is dropped."
  (dolist (c drgnx-test-gate--conns)
    (let ((proc (drgnx-test-gate--conn-proc c)))
      (process-put proc :drgnx-gate nil)
      (unless (drgnx-test-gate--conn-deleted c)
        (set-process-filter proc (drgnx-test-gate--conn-filter c))
        (set-process-sentinel proc (drgnx-test-gate--conn-sentinel c))))))

(defun drgnx-test-gate--run (schedule body)
  (let ((drgnx-test-gate--active t) (drgnx-test-gate--steps schedule) (drgnx-test-gate--implicit nil)
        (drgnx-test-gate--conns nil) (drgnx-test-gate--counts nil) (drgnx-test-gate--seq 0)
        (drgnx-test-gate--transcript nil) (drgnx-test-gate--failure nil) (drgnx-test-gate--raw drgnx-test--accept)
        (drgnx-test-gate--opening nil) (drgnx-test-gate--control nil) (drgnx-test-gate--releasing nil)
        (drgnx-test-gate--swap (drgnx-test-gate--swap-env)) (drgnx-test-gate--swap-pairs 0) (drgnx-test-gate--lag nil)
        (drgnx-test-gate--before (process-list)) (drgnx-test-gate--progress nil)
        (ok nil))
    (unwind-protect
        (progn (dolist (a drgnx-test-gate--advice) (advice-add (nth 0 a) (nth 1 a) (nth 2 a)))
               (funcall body)
               (drgnx-test-gate--flush)
               (setq ok t)
               ;; `bin/drgnx test --orders' reads the count to know how many K there are
               (when drgnx-test-gate--swap (message "drgnx-gate-swap-pairs: %d" drgnx-test-gate--swap-pairs)))
      (drgnx-test-gate--restore)
      (dolist (a drgnx-test-gate--advice) (advice-remove (nth 0 a) (nth 2 a)))
      (when (processp drgnx-test-gate--control) (delete-process drgnx-test-gate--control)))
    (when (and ok drgnx-test-gate--failure)
      (signal 'ert-test-failed (list drgnx-test-gate--failure)))))

(defun drgnx-test-gate--call (schedule body)
  "Run BODY (a function) gated by SCHEDULE; see `drgnx-test-gated'."
  (when drgnx-test-gate--active (error "drgnx-test-gated: already inside one"))
  (let ((schedule (drgnx-test-gate--normalize schedule)))
    (drgnx-test-gate--warm)
    (if (bound-and-true-p drgnx-test--active)
        (progn (when (eq drgnx-test--core 'auto) (error "drgnx-test-gated: it runs on the manual clock, not :auto"))
               (drgnx-test-gate--run schedule body))
      (drgnx-test--call-with-clock (lambda () (drgnx-test-gate--run schedule body)) t))))

(defmacro drgnx-test-gated (schedule &rest body)
  "Run BODY with every hub connection it opens (`drgnx-hub--open') behind the delivery gate.
BODY runs on the manual clock (entered, with pending timers allowed, when none is active).  SCHEDULE (evaluated) is a
list of steps:

  (CONN :answer METHOD)  the answer to CONN's next call of METHOD
  (CONN :event NAME)     CONN's next event NAME
  (CONN :line)           CONN's next line
  (CONN :eof)            CONN's end
  (:pause LABEL)         nothing more until `drgnx-test-gate-continue' LABEL

CONN is `call-N' or `sub-N' (`sub' when opened with EVENTS non-nil), numbered in open order within BODY.  A step
releases its connection's held lines up to its own, in their order: the gate reorders across connections, never within
one.  Each connection's challenge and the answers to its first `ping' and its `hello' are released by themselves at
the first wait after they fall due, in the order the client caused them.

Every wait inside BODY (`accept-process-output', also deep inside the code under test, and `drgnx-test-wait')
releases what is due up to the next pause: a step is due once its connection is open, and an answer once its call has
gone out; the gate then waits, for real, for its line.  A timed wait with nothing to release is a zero-length look and
a virtual advance by its timeout; while a real child BODY started lives (not a peer, `:drgnx-test-peer'), it is a real
look instead and no virtual time moves (`drgnx-test-gate--on-children').  While paused, a wait in the code under test with a line held or a call out fails the
test at once, naming the pause and the caller; the test's own `drgnx-test-wait' just looks.  Lines the schedule does
not name stay held until `drgnx-test-deliver-all'.  Each line the client sends on a gated connection is stamped with
`__seq'."
  (declare (indent 1))
  `(drgnx-test-gate--call ,schedule (lambda () ,@body)))

(provide 'delivery-gate-fixture)
;;; delivery-gate-fixture.el ends here
