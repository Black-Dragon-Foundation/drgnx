;;; agents-transcript-test.el --- batch tests: a session's transcript model and its "needs you" set -*- lexical-binding: t -*-
;; test-class: det
;; The hub runs every agent; this Emacs keeps the transcript of a mirror and counts what waits on the user.
(require 'ert)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

;;;; The transcript

(ert-deftest drgnx-agents-transcript/chunks-are-joined-once-when-read ()
  (let* ((s (drgnx-agents--make :name "chunks" :status 'busy)))
    (dolist (c '("Hel" "lo, " "wor" "ld")) (drgnx-agents--append-text s 'agent c))
    (let ((e (car (drgnx-agent-session-entries s))))
      (should (= 1 (length (drgnx-agent-session-entries s))))
      (should (= 12 (drgnx-agents-entry-length e)))
      (should (equal "world" (drgnx-agents-entry-tail e 7)))         ; only the newest chunks
      (should (equal "lo, world" (drgnx-agents-entry-tail e 3)))
      (should (equal "" (drgnx-agents-entry-tail e 12)))
      (should (equal "Hello, world" (drgnx-agents-entry-text e)))
      (should (eq (drgnx-agents-entry-text e) (drgnx-agents-entry-text e)))   ; joined once, kept until the next chunk
      (drgnx-agents--append-text s 'agent "!")
      (should (equal "d!" (drgnx-agents-entry-tail e 11)))
      (should (equal "Hello, world!" (drgnx-agents-entry-text e)))
      ;; the turn's end: the text is whole in :text, for everything that reads the plist
      (drgnx-agents--append-text s 'agent " Bye.")
      (drgnx-agents-join-text s)
      (should (equal "Hello, world! Bye." (plist-get e :text)))
      (should-not (plist-get e :chunks)))))

(defun drgnx-agents-transcript-test--append-alloc (size)
  "What appending a 100-character chunk to a running SIZE-character answer allocates (byte-compiled; least of 3)."
  (dolist (f '(drgnx-agents--append-text drgnx-agents-entry-length))
    (unless (compiled-function-p (symbol-function f)) (let ((byte-compile-warnings nil)) (byte-compile f))))
  (let* ((s (drgnx-agents--make :name "alloc" :status 'busy)) (chunk (make-string 100 ?b)) best
         (run (byte-compile (lambda () (drgnx-agents--append-text s 'agent chunk)))))
    (drgnx-agents--append-text s 'agent (make-string size ?a))
    (dotimes (i 5)
      (let* ((a (memory-use-counts)) (_ (funcall run)) (z (memory-use-counts)) (d (apply #'+ (cl-mapcar #'- z a))))
        (when (>= i 2) (setq best (if best (min best d) d)))))
    (should (= (+ size 500) (drgnx-agents-entry-length (car (drgnx-agent-session-entries s)))))
    best))

(ert-deftest drgnx-agents-transcript/a-chunk-costs-the-chunk-not-the-answer ()
  ;; AGENTS.md: stream parsing never concatenates the whole pending input per chunk
  (let ((small (drgnx-agents-transcript-test--append-alloc 4096))
        (big (drgnx-agents-transcript-test--append-alloc 409600)))
    (should (= small big))
    (should (< big 100))))

;;;; What waits on you: the `agents' set of the one "needs you" count

(defmacro drgnx-agents-transcript-test--with-attention (&rest body)
  "BODY with no sessions, nothing noted yet, a fresh notice model, and nothing else following the sessions."
  (declare (indent 0) (debug t))
  `(drgnx-notice-test-with-model
     (let ((drgnx-agents--sessions nil) (drgnx-agents--attention-seen nil) (drgnx-agents-changed-functions nil))
       ,@body)))

(defun drgnx-agents-transcript-test--item (id)
  "The \"needs you\" item with ID, or nil."
  (seq-find (lambda (i) (equal (plist-get i :id) id)) (drgnx-needs-you-items)))

(defun drgnx-agents-transcript-test--waiting (&rest slots)
  "A busy session made of SLOTS, in the session list."
  (let ((s (apply #'drgnx-agents--make :status 'busy slots)))
    (push s drgnx-agents--sessions)
    s))

(ert-deftest drgnx-agents-transcript/permissions-and-reviews-are-the-agents-set ()
  (drgnx-agents-transcript-test--with-attention
    (let* ((file (expand-file-name "proj/a.txt" "~"))
           (s (drgnx-agents-transcript-test--waiting :name "mock · proj" :id "s-a" :job "j1"
                                                     :permissions (list (list :id 4 :title "Run\nmake"))
                                                     :reviews (list (list :id 7 :path file :content "y")))))
      (drgnx-agents--changed s)
      (should (= (drgnx-needs-you-count) 2))
      (let ((p (drgnx-agents-transcript-test--item '(permission "s-a" . 4)))
            (r (drgnx-agents-transcript-test--item '(review "s-a" . 7))))
        (should (equal (plist-get p :text) "mock · proj asks: Run make"))
        (should (eq (plist-get p :command) 'agents-answer))
        (should (eq (plist-get p :source) 'agents))
        (should (equal (plist-get r :text) "mock · proj wants to write ~/proj/a.txt"))
        (should (eq (plist-get r :command) 'agents-view))))))

(ert-deftest drgnx-agents-transcript/an-unchanged-session-allocates-nothing ()
  ;; `drgnx-agents--changed' runs on every streamed chunk: when no list changed, noting costs no cons and no tick
  (drgnx-agents-transcript-test--with-attention
    (let ((s (drgnx-agents-transcript-test--waiting :name "a" :id "s-q" :permissions (list (list :id 1 :title "x"))
                                                    :reviews (list (list :id 2 :path "/tmp/x" :content "y")))))
      (drgnx-agents-transcript-test--waiting :name "b" :id "s-r" :status 'idle)
      (drgnx-agents--changed s)
      (dolist (f '(drgnx-agents--note-attention drgnx-agents--attention-same-p drgnx-agents--same-items-p))
        (unless (compiled-function-p (indirect-function f)) (let ((byte-compile-warnings nil)) (byte-compile f))))
      (let ((tick (drgnx-notice-tick)))
        (should (= 0 (drgnx-notice-test--alloc (drgnx-agents--note-attention))))
        (should (= tick (drgnx-notice-tick)))
        (should (= 2 (drgnx-needs-you-count)))))))

(ert-deftest drgnx-agents-transcript/answering-removes-the-item ()
  ;; the answer goes to the hub; the item leaves the count at once
  (drgnx-agents-transcript-test--with-attention
    (let ((s (drgnx-agents-transcript-test--waiting :name "a" :id "s-b" :remote "s-b"
                                                    :permissions (list (list :id 1 :title "x") (list :id 3 :title "z"))
                                                    :reviews (list (list :id 2 :path "/tmp/x" :content "y"))))
          (calls nil))
      (drgnx-agents--changed s)
      (should (= (drgnx-needs-you-count) 3))
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &rest _) (push (cons method params) calls))))
        ;; the last of two: `delq' keeps the list's head, the item still goes
        (drgnx-agents-answer-permission s (cadr (drgnx-agent-session-permissions s)) "allow")
        (drgnx-agents--changed s)
        (should (= (drgnx-needs-you-count) 2))
        (should-not (drgnx-agents-transcript-test--item '(permission "s-b" . 3)))
        (drgnx-agents-answer-permission s (car (drgnx-agent-session-permissions s)) "allow")
        (drgnx-agents-finish-review s (car (drgnx-agent-session-reviews s)))
        (drgnx-agents--changed s)
        (should (= (drgnx-needs-you-count) 0)))
      (should (equal (mapcar #'car (reverse calls)) '("agents/permission" "agents/permission" "agents/do"))))))

(ert-deftest drgnx-agents-transcript/a-mirror-update-is-seen ()
  ;; a hub session's permission reaches this Emacs's count through the mirror's snapshot
  (drgnx-agents-transcript-test--with-attention
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
          (push (drgnx-agents--make :remote "s-m" :id "s-m") drgnx-agents--sessions)
          ;; the snapshot as the hub sends it (records 2): JSON, decoded by the session schema
          (drgnx-agents-mirror--event "agent" (list :id "s-m" :seq 1 :session '(:id "s-m" :name "m" :status "busy" :permissions ((:id 3 :title "Edit")))))
          (should (equal (plist-get (drgnx-agents-transcript-test--item '(permission "s-m" . 3)) :text) "m asks: Edit"))
          (drgnx-agents-mirror--event "agent" (list :id "s-m" :seq 2 :session '(:id "s-m" :name "m" :status "idle")))
          (should (= (drgnx-needs-you-count) 0)))
      (drgnx-agents-mirror-stop))))

(ert-deftest drgnx-agents-transcript/scope-is-the-sessions-job ()
  (drgnx-agents-transcript-test--with-attention
    (drgnx-agents-transcript-test--waiting :name "a" :id "s-j" :job "j1" :permissions (list (list :id 1 :title "x")))
    (let ((s (drgnx-agents-transcript-test--waiting :name "b" :id "s-n" :reviews (list (list :id 2 :path "/tmp/x" :content "y")))))
      (drgnx-agents--changed s)
      (should (= (drgnx-needs-you-count) 2))
      (should (= (drgnx-needs-you-count "j1") 1))
      (should (equal (plist-get (drgnx-agents-transcript-test--item '(permission "s-j" . 1)) :scope) "j1"))
      (should-not (plist-get (drgnx-agents-transcript-test--item '(review "s-n" . 2)) :scope)))))

(ert-deftest drgnx-agents-transcript/an-exited-session-leaves-nothing ()
  ;; whatever its lists still hold, nobody can answer an ended session
  (drgnx-agents-transcript-test--with-attention
    (let ((s (drgnx-agents-transcript-test--waiting :name "a" :id "s-x" :permissions (list (list :id 1 :title "x"))
                                                    :reviews (list (list :id 2 :path "/tmp/x" :content "y")))))
      (drgnx-agents--changed s)
      (should (= (drgnx-needs-you-count) 2))
      (setf (drgnx-agent-session-status s) 'exited)
      (drgnx-agents--changed s)
      (should (= (drgnx-needs-you-count) 0))
      (should-not (drgnx-needs-you-items)))))

(ert-deftest drgnx-agents-transcript/tracker-tools-is-in-the-schema ()
  (should (string-search ":tracker-tools (enum on off)" (format "%S" drgnx-agents-config-schema)))
  (should (string-search "The five tracker tools; on by default" (format "%S" drgnx-agents-config-schema))))

;;; agents-transcript-test.el ends here
