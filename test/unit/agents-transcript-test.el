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

;;;; What waits on you: the `agents' set of the one "needs you" count, as the hub derives it

(defmacro drgnx-agents-transcript-test--with-attention (&rest body)
  "BODY with no sessions, nothing noted yet, a fresh notice model, and nothing else following the sessions."
  (declare (indent 0) (debug t))
  `(drgnx-notice-test-with-model
     (let ((drgnx-agents--sessions nil) (drgnx-agents--attention nil) (drgnx-agents--at-work 0)
           (drgnx-agents-changed-functions nil) (drgnx-agents-mirror--paused nil))
       ,@body)))

(defun drgnx-agents-transcript-test--item (id)
  "The \"needs you\" item with ID, or nil."
  (seq-find (lambda (i) (equal (plist-get i :id) id)) (drgnx-needs-you-items)))

(defun drgnx-agents-transcript-test--hub-says (at-work &rest items)
  "The hub's `agents-attention' event: AT-WORK sessions work, ITEMS (each a plist as the hub sends it) wait."
  (drgnx-agents-mirror--event "agents-attention" (list :at_work at-work :items (vconcat items))))

(ert-deftest drgnx-agents-transcript/the-hubs-attention-list-is-the-agents-set ()
  (drgnx-agents-transcript-test--with-attention
    (drgnx-agents-transcript-test--hub-says
     1 (list :kind "permission" :session "s-a" :id 4 :text "mock · proj asks: Run\nmake" :job "j1"))
    (should (= (drgnx-needs-you-count) 1))
    (should (= 1 (drgnx-agents-at-work)))
    (let ((p (drgnx-agents-transcript-test--item '(permission "s-a" . 4))))
      (should (equal (plist-get p :text) "mock · proj asks: Run make"))
      (should (eq (plist-get p :command) 'agents-answer))
      (should (eq (plist-get p :source) 'agents))
      (should (equal (plist-get p :scope) "j1")))))

(ert-deftest drgnx-agents-transcript/a-new-list-replaces-the-set ()
  (drgnx-agents-transcript-test--with-attention
    (drgnx-agents-transcript-test--hub-says 2 (list :kind "permission" :session "s-a" :id 1 :text "a asks: x")
                                            (list :kind "permission" :session "s-b" :id 2 :text "b asks: y"))
    (should (= (drgnx-needs-you-count) 2))
    (drgnx-agents-transcript-test--hub-says 1 (list :kind "permission" :session "s-b" :id 2 :text "b asks: y"))
    (should (= (drgnx-needs-you-count) 1))
    (should-not (drgnx-agents-transcript-test--item '(permission "s-a" . 1)))
    (drgnx-agents-transcript-test--hub-says 0)
    (should (= (drgnx-needs-you-count) 0))
    (should (= 0 (drgnx-agents-at-work)))))

(ert-deftest drgnx-agents-transcript/an-event-makes-no-walk-over-the-sessions ()
  ;; `agent' and `agent-entries' events no longer make the set: a session with a permission in its own list and no
  ;; `agents-attention' event noted adds nothing to the count
  (drgnx-agents-transcript-test--with-attention
    (let ((s (drgnx-agents--make :name "a" :id "s-q" :remote "s-q" :status 'busy
                                 :permissions (list (list :id 1 :title "x")))))
      (push s drgnx-agents--sessions)
      (drgnx-agents--changed s)
      (should (= (drgnx-needs-you-count) 0))
      (should (= 0 (drgnx-agents-at-work))))))

(ert-deftest drgnx-agents-transcript/answering-removes-the-item ()
  ;; the answer goes to the hub; the item leaves the count at once, and the hub's next list agrees
  (drgnx-agents-transcript-test--with-attention
    (let ((s (drgnx-agents--make :name "a" :id "s-b" :remote "s-b" :status 'busy
                                 :permissions (list (list :id 1 :title "x") (list :id 3 :title "z"))))
          (calls nil))
      (push s drgnx-agents--sessions)
      (drgnx-agents-transcript-test--hub-says 1 (list :kind "permission" :session "s-b" :id 1 :text "a asks: x")
                                              (list :kind "permission" :session "s-b" :id 3 :text "a asks: z"))
      (should (= (drgnx-needs-you-count) 2))
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &rest _) (push (cons method params) calls))))
        (drgnx-agents-answer-permission s (cadr (drgnx-agent-session-permissions s)) "allow")
        (should (= (drgnx-needs-you-count) 1))
        (should-not (drgnx-agents-transcript-test--item '(permission "s-b" . 3)))
        (drgnx-agents-answer-permission s (car (drgnx-agent-session-permissions s)) "allow")
        (should (= (drgnx-needs-you-count) 0)))
      (should (equal (mapcar #'car (reverse calls)) '("agents/permission" "agents/permission"))))))

(ert-deftest drgnx-agents-transcript/the-hub-going-clears-the-set ()
  (drgnx-agents-transcript-test--with-attention
    (drgnx-agents-transcript-test--hub-says 1 (list :kind "permission" :session "s-a" :id 1 :text "a asks: x"))
    (should (= (drgnx-needs-you-count) 1))
    (drgnx-agents-mirror--hub-gone)
    (should (= (drgnx-needs-you-count) 0))
    (should (= 0 (drgnx-agents-at-work)))))

(ert-deftest drgnx-agents-transcript/tracker-tools-is-in-the-schema ()
  (should (string-search ":tracker-tools (enum on off)" (format "%S" drgnx-agents-config-schema)))
  (should (string-search "The five tracker tools; on by default" (format "%S" drgnx-agents-config-schema))))

;;; agents-transcript-test.el ends here
