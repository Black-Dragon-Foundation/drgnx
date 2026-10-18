;;; core-notice-test.el --- batch tests: the notice model (events, conditions, attention sets, the now lane) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defvar drgnx-notice-test--clock 1000.0 "The time `drgnx-notice--now' reads in tests that set it.")

(defmacro drgnx-notice-test--with-clock (&rest body)
  "BODY with `drgnx-notice--now' reading `drgnx-notice-test--clock' (from 1000.0)."
  (declare (indent 0))
  `(let ((drgnx-notice-test--clock 1000.0))
     (cl-letf (((symbol-function 'drgnx-notice--now) (lambda () drgnx-notice-test--clock)))
       ,@body)))

(defun drgnx-notice-test--tick (secs) (setq drgnx-notice-test--clock (+ drgnx-notice-test--clock secs)))

;;;; Posting

(ert-deftest drgnx-notice/notify-returns-the-key-and-stores-a-readable-plist ()
  (drgnx-notice-test-with-model
    (let* ((key (drgnx-notify 'modules 'fail "tools/x did not start" :id 'tools/x :life 'condition
                              :fix "Turn it off" :command '(drgnx-job-ui-show "j1") :scope "j1"))
           (n (car (drgnx-notices))))
      (should (equal key '(modules . tools/x)))
      (should (eq (plist-get n :source) 'modules))
      (should (eq (plist-get n :id) 'tools/x))
      (should (eq (plist-get n :severity) 'fail))
      (should (eq (plist-get n :life) 'condition))
      (should (equal (plist-get n :fix) "Turn it off"))
      (should (floatp (plist-get n :at)))
      (should-not (plist-member n :detail))           ; only non-nil keys
      (should (equal (car (read-from-string (prin1-to-string n))) n)))))

(ert-deftest drgnx-notice/a-repeat-only-counts ()
  (drgnx-notice-test-with-model
    (let (calls)
      (add-hook 'drgnx-notice-functions (lambda (c) (push (plist-get c :op) calls)))
      (drgnx-notify 'keys 'warn "C-c x is taken")
      (let ((tick (drgnx-notice-tick)) (at (plist-get (car (drgnx-notices)) :at)))
        (drgnx-notify 'keys 'warn "C-c x is taken")
        (drgnx-notify 'keys 'warn "C-c x is taken")
        (should (= (drgnx-notice-tick) tick))
        (should (equal calls '(post)))
        (should (= (length (drgnx-notices)) 1))
        (should (= (plist-get (car (drgnx-notices)) :count) 3))
        (should (eql (plist-get (car (drgnx-notices)) :at) at))))))

(ert-deftest drgnx-notice/other-text-is-a-change ()
  (drgnx-notice-test-with-model
    (drgnx-notify 'hub 'warn "not answering" :id 'conn :life 'condition)
    (let ((tick (drgnx-notice-tick)))
      (drgnx-notify 'hub 'warn "still not answering" :id 'conn :life 'condition)
      (should (> (drgnx-notice-tick) tick))
      (should (equal (plist-get (car (drgnx-notices)) :text) "still not answering"))
      (should-not (plist-get (car (drgnx-notices)) :count))
      (setq tick (drgnx-notice-tick))
      (drgnx-notify 'hub 'fail "still not answering" :id 'conn :life 'condition)   ; another severity
      (should (> (drgnx-notice-tick) tick))
      (should (equal (drgnx-problems-count) '(0 . 1)))
      (should (= (length (drgnx-notices)) 1)))))

(ert-deftest drgnx-notice/life-defaults-to-event ()
  (drgnx-notice-test-with-model
    (let ((key (drgnx-notify 'hooks 'fail "a hook function failed")))
      (should (equal key '(hooks . "a hook function failed")))   ; an event without ID: its text is its ID
      (should (eq (plist-get (car (drgnx-notices)) :life) 'event))
      (should (equal drgnx-notice--events (list key)))
      (should (equal (drgnx-problems-count) '(0 . 0))))))       ; events are not problems

(ert-deftest drgnx-notice/attention-is-refused-in-notify ()
  (drgnx-notice-test-with-model
    (should-error (drgnx-notify 'hub 'warn "x" :life 'attention) :type 'wrong-type-argument)
    (should-error (drgnx-notify 'hub 'warn "x" :life 'forever) :type 'wrong-type-argument)
    (should-error (drgnx-notify 'hub 'needs-you "x") :type 'wrong-type-argument)
    (should-error (drgnx-notify 'hub 'ok "x") :type 'wrong-type-argument)
    (should-not (drgnx-notices))
    (should (= (drgnx-notice-tick) 0))))

(ert-deftest drgnx-notice/text-is-one-line-without-the-prefix ()
  (drgnx-notice-test-with-model
    (drgnx-notify 'config 'warn "drgnx: line one\nline two" :id 'a)
    (should (equal (plist-get (car (drgnx-notices)) :text) "line one line two"))
    (let ((s "plain"))
      (drgnx-notify 'config 'warn s :id 'b)
      (should (eq (plist-get (car (drgnx-notices :source 'config :life 'event)) :text) s)))))   ; nothing copied

(ert-deftest drgnx-notice/command-must-be-readable ()
  (drgnx-notice-test-with-model
    (should (drgnx-notify 'hub 'warn "a" :command 'notices))
    (should (drgnx-notify 'hub 'warn "b" :command '(drgnx-job-ui-show "j1" 2 (x . y))))
    (should-error (drgnx-notify 'hub 'warn "c" :command (lambda () 1)) :type 'wrong-type-argument)
    (should-error (drgnx-notify 'hub 'warn "d" :command '(lambda () 1)) :type 'wrong-type-argument)
    (should-error (drgnx-notify 'hub 'warn "e" :command (list 'f (current-buffer))) :type 'wrong-type-argument)
    (should-error (drgnx-notify 'hub 'warn "f" :command "a string") :type 'wrong-type-argument)
    (should-error (drgnx-notice-set 'hub (list (list :id 'x :text "x" :command (lambda () 1))))
                  :type 'wrong-type-argument)
    (should (= (length (drgnx-notices)) 2))))

(ert-deftest drgnx-notice/an-undefined-source-is-refused ()
  (drgnx-notice-test-with-model
    (should-error (drgnx-notify 'my-module 'warn "x") :type 'wrong-type-argument)
    (should-error (drgnx-notice-set 'my-module nil) :type 'wrong-type-argument)
    (drgnx-notice-define-source 'my-module :title "Mine")
    (should (drgnx-notify 'my-module 'warn "x"))))

(ert-deftest drgnx-notice/core-sources-need-no-definition ()
  (drgnx-notice-test-with-model
    (dolist (s '(modules keys hooks commands bus guard hub config agents timers terminal wb store render notice))
      (should (memq s drgnx-notice-core-sources))
      (should (drgnx-notify s 'info "x")))
    (should-error (drgnx-notice-define-source 'modules :title "Modules"))))

;;;; Bounds

(ert-deftest drgnx-notice/events-age-out-of-a-200-ring ()
  (drgnx-notice-test-with-model
    (should (= drgnx-notice-event-limit 200))
    (dotimes (i 201) (drgnx-notify 'hooks 'warn (format "event %d" i)))
    (drgnx-notify 'hub 'fail "a condition" :id 'c :life 'condition)
    (should (= (length drgnx-notice--events) 200))
    (should (= (hash-table-count drgnx-notice--table) 201))       ; 200 events + the condition
    (should-not (gethash '(hooks . "event 0") drgnx-notice--table))
    (should (gethash '(hooks . "event 1") drgnx-notice--table))
    (should (equal (car drgnx-notice--events) '(hooks . "event 200")))))

(ert-deftest drgnx-notice/conditions-cap-at-100-per-source-with-and-n-more ()
  (drgnx-notice-test-with-model
    (should (= drgnx-notice-condition-limit 100))
    (dotimes (i 102) (drgnx-notify 'keys 'fail (format "problem %d" i) :id i :life 'condition))
    (drgnx-notify 'keys 'fail "problem 5" :id 5 :life 'condition)          ; a repeat at the cap still counts
    (drgnx-notify 'hub 'fail "other source" :id 'x :life 'condition)
    (should-not (gethash '(keys . 100) drgnx-notice--table))
    (should (= (plist-get (gethash '(keys . 5) drgnx-notice--table) :count) 2))
    (let ((more (gethash '(keys . more) drgnx-notice--table)))
      (should (equal (plist-get more :text) "and 2 more"))
      (should (eq (plist-get more :severity) 'warn)))
    (should (= (length (drgnx-notices :source 'keys)) 101))
    (should (gethash '(hub . x) drgnx-notice--table))
    (should (equal (drgnx-problems-count) '(1 . 101)))
    (drgnx-notice-clear 'keys)
    (should (equal (drgnx-problems-count) '(0 . 1)))
    (drgnx-notify 'keys 'fail "problem 0" :id 0 :life 'condition)
    (should (= (length (drgnx-notices :source 'keys)) 1))))

;;;; Clearing

(ert-deftest drgnx-notice/clear-one-and-clear-all ()
  (drgnx-notice-test-with-model
    (drgnx-notify 'modules 'fail "a failed" :id 'a :life 'condition)
    (drgnx-notify 'modules 'warn "b degraded" :id 'b :life 'condition)
    (drgnx-notify 'modules 'fail "an event")
    (drgnx-notify 'hub 'fail "hub" :id 'h :life 'condition)
    (should (equal (drgnx-problems-count) '(1 . 2)))
    (let ((tick (drgnx-notice-tick)))
      (should (drgnx-notice-clear 'modules 'a))
      (should (> (drgnx-notice-tick) tick)))
    (should (equal (drgnx-problems-count) '(1 . 1)))
    (setq tick (drgnx-notice-tick))
    (should-not (drgnx-notice-clear 'modules 'nothing))
    (should (= (drgnx-notice-tick) tick))
    (drgnx-notice-clear 'modules)
    (should (equal (mapcar (lambda (n) (plist-get n :source)) (drgnx-notices)) '(hub)))
    (should-not drgnx-notice--events)
    (should (equal (drgnx-problems-count) '(0 . 1)))))

(ert-deftest drgnx-notice/dismiss-hides-until-other-text ()
  (drgnx-notice-test-with-model
    (let ((key (drgnx-notify 'hub 'fail "not answering" :id 'conn :life 'condition)))
      (should (equal (drgnx-problems-count) '(0 . 1)))
      (should (drgnx-notice-dismiss key))
      (should-not (drgnx-notices))
      (should (equal (drgnx-problems-count) '(0 . 0)))
      (drgnx-notify 'hub 'fail "not answering" :id 'conn :life 'condition)    ; a repeat: still hidden
      (should-not (drgnx-notices))
      (drgnx-notice-clear 'hub 'conn)
      (drgnx-notify 'hub 'fail "not answering" :id 'conn :life 'condition)    ; back with the same text: hidden
      (should-not (drgnx-notices))
      (should (equal (drgnx-problems-count) '(0 . 0)))
      (drgnx-notify 'hub 'fail "not answering (3 tries)" :id 'conn :life 'condition)
      (should (= (length (drgnx-notices)) 1))
      (should (equal (drgnx-problems-count) '(0 . 1))))))

(ert-deftest drgnx-notice/attention-cannot-be-dismissed ()
  (drgnx-notice-test-with-model
    (drgnx-notice-set 'agents '((:id (permission "s1" . 3) :text "Edit a file?")))
    (should-error (drgnx-notice-dismiss '(permission "s1" . 3)))
    (should (= (drgnx-needs-you-count) 1))))

;;;; Sets

(ert-deftest drgnx-notice/set-replaces-the-whole-set ()
  (drgnx-notice-test-with-model
    (drgnx-notice-define-source 'jobs :title "Jobs")
    (drgnx-notice-set 'jobs '((:id (card . 1) :text "j1 — one") (:id (card . 2) :text "j1 — two")))
    (should (= (drgnx-needs-you-count) 2))
    (let (change)
      (add-hook 'drgnx-notice-functions (lambda (c) (setq change c)))
      (drgnx-notice-set 'jobs '((:id (card . 2) :text "j1 — two") (:id (card . 3) :text "first")
                                (:id (card . 3) :text "j1 — three")))       ; a later item with the same ID wins
      (should (= (drgnx-needs-you-count) 2))
      (should (equal (plist-get change :added) '((card . 3))))
      (should (equal (plist-get change :removed) '((card . 1))))
      (should (eq (plist-get change :op) 'set)))
    (let ((items (drgnx-needs-you-items)))
      (should (equal (sort (mapcar (lambda (n) (plist-get n :text)) items) #'string<) '("j1 — three" "j1 — two")))
      (should (eq (plist-get (car items) :severity) 'needs-you))
      (should (eq (plist-get (car items) :life) 'attention)))))

(ert-deftest drgnx-notice/a-bad-item-changes-nothing ()
  ;; the items are all checked before the set changes
  (drgnx-notice-test-with-model
    (drgnx-notice-set 'agents '((:id a :text "A") (:id b :text "B")))
    (let ((tick (drgnx-notice-tick)))
      (should-error (drgnx-notice-set 'agents '((:id a :text "A") (:id c :text "C") (:id b :text "B, now")
                                                (:text "no id")))
                    :type 'wrong-type-argument)
      (should (= (drgnx-notice-tick) tick))
      (should (equal (sort (mapcar (lambda (n) (plist-get n :text)) (drgnx-needs-you-items)) #'string<) '("A" "B")))
      (drgnx-notice-set 'agents '((:id a :text "A") (:id b :text "B, now")))
      (should (equal (sort (mapcar (lambda (n) (plist-get n :text)) (drgnx-needs-you-items)) #'string<)
                     '("A" "B, now")))
      (should (= (drgnx-needs-you-count) 2)))))

(ert-deftest drgnx-notice/an-unchanged-set-does-not-tick ()
  (drgnx-notice-test-with-model
    (drgnx-notice-test--with-clock
      (drgnx-notice-set 'agents '((:id a :text "A") (:id b :text "B")))
      (let ((tick (drgnx-notice-tick)) (at (plist-get (gethash 'a drgnx-notice--union) :at)))
        (drgnx-notice-test--tick 5)
        (drgnx-notice-set 'agents (list (list :id 'a :text (concat "A" "")) (list :id 'b :text "B")))
        (should (= (drgnx-notice-tick) tick))
        (drgnx-notice-set 'agents '((:id a :text "A, again") (:id b :text "B")))
        (should (> (drgnx-notice-tick) tick))
        (should (eql (plist-get (gethash 'a drgnx-notice--union) :at) at))))))   ; an unchanged ID keeps :at

(ert-deftest drgnx-notice/an-id-in-two-sources-counts-once ()
  (drgnx-notice-test-with-model
    (drgnx-notice-test--with-clock
      (drgnx-notice-define-source 'jobs :title "Jobs")
      (drgnx-notice-define-source 'questions :title "Questions")
      (drgnx-notice-set 'jobs '((:id (card . 7) :text "from jobs") (:id (card . 8) :text "eight")))
      (drgnx-notice-set 'questions '((:id (card . 7) :text "from questions")))
      (should (= (drgnx-needs-you-count) 2))
      ;; same :at: the source defined first wins
      (should (equal (plist-get (gethash '(card . 7) drgnx-notice--union) :text) "from jobs"))
      (drgnx-notice-test--tick 1)
      (drgnx-notice-set 'questions '((:id (card . 7) :text "from questions, later")))
      ;; other text, same ID: :at is kept, so still a tie
      (should (equal (plist-get (gethash '(card . 7) drgnx-notice--union) :text) "from jobs"))
      (drgnx-notice-set 'questions '((:id (card . 9) :text "nine")))
      (drgnx-notice-test--tick 1)
      (drgnx-notice-set 'questions '((:id (card . 9) :text "nine") (:id (card . 7) :text "newer")))
      (should (equal (plist-get (gethash '(card . 7) drgnx-notice--union) :text) "newer"))  ; the later :at wins
      (should (= (drgnx-needs-you-count) 3))
      (drgnx-notice-set 'jobs nil)
      (should (= (drgnx-needs-you-count) 2)))))

(ert-deftest drgnx-notice/unknown-drops-items-and-posts-a-condition ()
  (drgnx-notice-test-with-model
    (drgnx-notice-define-source 'jobs :title "Jobs" :command 'jobs-show)
    (drgnx-notice-set 'jobs '((:id (card . 1) :text "one")))
    (drgnx-notice-set 'jobs :unknown :reason "Jobs: not known — the hub did not answer")
    (should (= (drgnx-needs-you-count) 0))
    (should (equal (drgnx-needs-you-unknown) '(jobs)))
    (let ((c (gethash '(jobs . unknown) drgnx-notice--table)))
      (should (eq (plist-get c :severity) 'warn))
      (should (eq (plist-get c :life) 'condition))
      (should (eq (plist-get c :command) 'jobs-show))
      (should (equal (plist-get c :text) "Jobs: not known — the hub did not answer")))
    (drgnx-notice-define-source 'questions :title "Questions")
    (drgnx-notice-set 'questions :unknown)
    (should (equal (plist-get (gethash '(questions . unknown) drgnx-notice--table) :text) "not known"))
    (should (equal (drgnx-problems-count) '(2 . 0)))))

(ert-deftest drgnx-notice/a-set-after-unknown-clears-the-condition ()
  (drgnx-notice-test-with-model
    (drgnx-notice-define-source 'jobs :title "Jobs")
    (drgnx-notice-set 'jobs :unknown)
    (drgnx-notice-set 'jobs '((:id (card . 1) :text "one")))
    (should-not (gethash '(jobs . unknown) drgnx-notice--table))
    (should-not (drgnx-needs-you-unknown))
    (should (= (drgnx-needs-you-count) 1))
    (should (equal (drgnx-problems-count) '(0 . 0)))))

(ert-deftest drgnx-notice/scoped-counts ()
  (drgnx-notice-test-with-model
    (drgnx-notice-define-source 'jobs :title "Jobs")
    (drgnx-notice-set 'jobs '((:id (card . 1) :text "a" :scope "j1") (:id (card . 2) :text "b" :scope "j1")
                              (:id (card . 3) :text "c" :scope "j2") (:id (card . 4) :text "d")))
    (should (= (drgnx-needs-you-count) 4))
    (should (= (drgnx-needs-you-count "j1") 2))
    (should (= (drgnx-needs-you-count "j2") 1))
    (should (= (drgnx-needs-you-count "j3") 0))
    (should (= (length (drgnx-needs-you-items "j1")) 2))
    (should (= (length (drgnx-notices :scope "j2")) 1))
    (drgnx-notice-set 'jobs '((:id (card . 1) :text "a" :scope "j1")))
    (should (= (drgnx-needs-you-count "j1") 1))))                ; the memo follows the tick

(ert-deftest drgnx-notice/stale-is-opt-in ()
  (drgnx-notice-test-with-model
    (drgnx-notice-test--with-clock
      (drgnx-notice-define-source 'quiet :title "Quiet")
      (drgnx-notice-define-source 'watched :title "Watched" :stale 600)
      (drgnx-notice-define-source 'other :title "Other")
      (drgnx-notice-set 'quiet '((:id q :text "q")))
      (drgnx-notice-set 'watched '((:id w :text "w")))
      (drgnx-notice-test--tick 599)
      (drgnx-notice-set 'other nil)
      (should-not (drgnx-needs-you-unknown))
      (drgnx-notice-test--tick 2)
      (drgnx-notice--check-stale)
      (should (equal (drgnx-needs-you-unknown) '(watched)))
      (should (equal (plist-get (gethash '(watched . unknown) drgnx-notice--table) :text)
                     "not heard from in 10 min"))
      (should (= (drgnx-needs-you-count) 1))                    ; quiet never goes stale
      (drgnx-notice-test--tick 100000)
      (drgnx-notice--check-stale)
      (should (equal (drgnx-needs-you-unknown) '(watched))))))

;;;; Counts

(ert-deftest drgnx-notice/problems-count-is-warn-and-fail-not-dismissed ()
  (drgnx-notice-test-with-model
    (drgnx-notify 'modules 'fail "f1" :id 1 :life 'condition)
    (drgnx-notify 'modules 'fail "f2" :id 2 :life 'condition)
    (drgnx-notify 'modules 'warn "w1" :id 3 :life 'condition)
    (drgnx-notify 'modules 'info "i1" :id 4 :life 'condition)
    (drgnx-notify 'modules 'fail "an event")
    (drgnx-notice-set 'agents '((:id a :text "a")))
    (should (equal (drgnx-problems-count) '(1 . 2)))
    (drgnx-notice-dismiss '(modules . 1))
    (should (equal (drgnx-problems-count) '(1 . 1)))
    (drgnx-notice-dismiss '(modules . 1))                     ; twice: counted down once
    (should (equal (drgnx-problems-count) '(1 . 1)))
    (drgnx-notify 'modules 'warn "f2 is a warning now" :id 2 :life 'condition)
    (should (equal (drgnx-problems-count) '(2 . 0)))))

;;;; The now lane

(ert-deftest drgnx-notice/functions-get-each-change-once ()
  (drgnx-notice-test-with-model
    (let (seen)
      (add-hook 'drgnx-notice-functions (lambda (c) (push c seen)))
      (drgnx-notice-define-source 'jobs :title "Jobs")
      (let ((key (drgnx-notify 'hub 'warn "x" :id 'x :life 'condition)))
        (drgnx-notify 'hub 'warn "x" :id 'x :life 'condition)
        (drgnx-notice-dismiss key)
        (drgnx-notice-clear 'hub 'x))
      (drgnx-notice-set 'jobs '((:id a :text "a")))
      (drgnx-notice-set 'jobs '((:id a :text "a")))
      (drgnx-notice-set 'jobs :unknown)
      (drgnx-notice-undefine-source 'jobs)
      (should (equal (mapcar (lambda (c) (plist-get c :op)) (reverse seen))
                     '(post dismiss clear set post unknown undefine)))
      (let ((post (car (last seen))))
        (should (equal (plist-get post :key) '(hub . x)))
        (should (eq (plist-get post :source) 'hub))
        (should (equal (plist-get (plist-get post :notice) :text) "x"))
        (should-not (plist-member post :added))))))           ; nil keys are not stored

(defvar drgnx-notice-test--depth 0)
(defvar drgnx-notice-test--log nil)

(defun drgnx-notice-test--reposter (change)
  (cl-incf drgnx-notice-test--depth)
  (unwind-protect
      (progn
        (push (list (plist-get change :key) drgnx-notice-test--depth) drgnx-notice-test--log)
        (when (equal (plist-get change :key) '(hub . first))
          (drgnx-notify 'hub 'warn "second" :id 'second)
          ;; the model has it at once; its hook call waits
          (push (list 'inside (and (gethash '(hub . second) drgnx-notice--table) t)) drgnx-notice-test--log)))
    (cl-decf drgnx-notice-test--depth)))

(ert-deftest drgnx-notice/a-post-from-a-hook-function-is-queued-not-recursive ()
  (drgnx-notice-test-with-model
    (setq drgnx-notice-test--log nil drgnx-notice-test--depth 0)
    (add-hook 'drgnx-notice-functions #'drgnx-notice-test--reposter)
    (drgnx-notify 'hub 'warn "first" :id 'first)
    (should (equal (reverse drgnx-notice-test--log)
                   '(((hub . first) 1) (inside t) ((hub . second) 1))))
    (should-not drgnx-notice--queue)))

(ert-deftest drgnx-notice/a-failing-hook-function-is-recorded-outside-the-model ()
  (drgnx-notice-test-with-model
    (let ((messages nil) (after nil))
      (add-hook 'drgnx-notice-functions (lambda (_) (setq after t)) 90)
      (add-hook 'drgnx-notice-functions (lambda (_) (error "Boom")))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (drgnx-notify 'hub 'warn "one")
        (drgnx-notify 'hub 'warn "two"))
      (should after)                                          ; the next function still ran
      (should (= (length drgnx-notice--hook-errors) 2))
      (should (string-match-p "Boom" (format "%s" (car drgnx-notice--hook-errors))))
      (should (= (length messages) 1))                         ; one message per function
      (should (string-match-p "\\`drgnx: notice hook .* failed: Boom" (car messages)))
      (should (= (length (drgnx-notices)) 2))                  ; nothing went back into the model
      (dotimes (i 30) (ignore-errors (let ((inhibit-message t)) (drgnx-notify 'hub 'warn (format "e%d" i)))))
      (should (= (length drgnx-notice--hook-errors) 20)))))

(ert-deftest drgnx-notice/hook-functions-never-prompt ()
  (drgnx-notice-test-with-model
    (let ((automatic nil) (answered 'never))
      (add-hook 'drgnx-notice-functions
                (lambda (_) (setq automatic (drgnx-guard-automatic-p)) (setq answered (y-or-n-p "Really? "))))
      (let ((inhibit-message t)) (drgnx-notify 'hub 'warn "x"))
      (should automatic)
      (should (eq answered 'never))
      (should (= (length drgnx-notice--hook-errors) 1)))))

;;;; Ownership

(defmacro drgnx-notice-test--with-modules (&rest body)
  "BODY with an empty module table, report and cleanup stacks, and one module test/notices."
  (declare (indent 0))
  `(let ((drgnx-modules--table (list (list 'test/notices :doc "t"))) (drgnx-modules--report nil)
         (drgnx-modules--stacks nil) (drgnx-modules--runs nil))
     ,@body))

(ert-deftest drgnx-notice/define-source-pushes-its-undo ()
  (drgnx-notice-test-with-model
    (drgnx-notice-test--with-modules
      (drgnx-notice-define-source 'outside :title "Outside")
      (should-not drgnx-modules--stacks)
      (should-not (drgnx-modules--run-setup 'test/notices
                                            (lambda () (drgnx-notice-define-source 'test-src :title "T"))))
      (should (equal (mapcar #'car (alist-get 'test/notices drgnx-modules--stacks)) '("notice source test-src")))
      (should (eq (plist-get (gethash 'test-src drgnx-notice--sources) :owner) 'test/notices))
      ;; defined again by someone else: the module's undo leaves it alone
      (drgnx-notice-define-source 'test-src :title "Again")
      (funcall (cdar (alist-get 'test/notices drgnx-modules--stacks)))
      (should (equal (plist-get (gethash 'test-src drgnx-notice--sources) :title) "Again")))))

(ert-deftest drgnx-notice/teardown-clears-a-module-source ()
  (drgnx-notice-test-with-model
    (drgnx-notice-test--with-modules
      (should-not (drgnx-modules--run-setup 'test/notices
                                            (lambda () (drgnx-notice-define-source 'test-src :title "T"))))
      (drgnx-modules--record 'test/notices 'startup 0 'ok)
      (drgnx-notify 'test-src 'fail "broken" :id 'a :life 'condition)
      (drgnx-notify 'test-src 'warn "an event")
      (drgnx-notice-set 'test-src '((:id x :text "x")))
      (should (= (drgnx-needs-you-count) 1))
      (should-not (drgnx-module-teardown 'test/notices))
      (should-not (gethash 'test-src drgnx-notice--sources))
      (should-not (gethash 'test-src drgnx-notice--sets))
      (should (= (drgnx-needs-you-count) 0))
      (should-not (drgnx-notices))
      (should-not drgnx-notice--events)
      (should (equal (drgnx-problems-count) '(0 . 0)))
      (should-error (drgnx-notify 'test-src 'warn "x") :type 'wrong-type-argument))))

;;;; Cost

(defvar drgnx-notice-test--texts nil)
(defvar drgnx-notice-test--i 0)

(ert-deftest drgnx-notice/a-count-read-allocates-nothing ()
  (drgnx-notice-test-with-model
    (drgnx-notice-set 'agents '((:id a :text "a" :scope "s") (:id b :text "b")))
    (drgnx-notify 'hub 'fail "x" :id 'x :life 'condition)
    (should (= (drgnx-notice-test--alloc (drgnx-needs-you-count) (drgnx-needs-you-count "s") (drgnx-problems-count)
                                         (drgnx-notice-tick))
               0))))

(ert-deftest drgnx-notice/a-post-allocates-at-most-15 ()
  (drgnx-notice-test-with-model
    (setq drgnx-notice-test--texts (vconcat (mapcar (lambda (i) (format "event %d" i)) (number-sequence 0 20)))
          drgnx-notice-test--i 0)
    (let ((n (drgnx-notice-test--alloc
              (drgnx-notify 'hooks 'fail (aref drgnx-notice-test--texts
                                               (setq drgnx-notice-test--i (1+ drgnx-notice-test--i)))))))
      (message "a new post: %d conses" n)
      (should (<= n 15)))
    (add-hook 'drgnx-notice-functions #'ignore)
    (let ((n (drgnx-notice-test--alloc
              (drgnx-notify 'hooks 'fail (aref drgnx-notice-test--texts
                                               (setq drgnx-notice-test--i (1+ drgnx-notice-test--i)))))))
      (message "a new post with one hook function: %d conses" n)
      (should (<= n 22)))))

(ert-deftest drgnx-notice/a-repeat-allocates-at-most-1 ()
  (drgnx-notice-test-with-model
    (let ((n (drgnx-notice-test--alloc (drgnx-notify 'hooks 'fail "the same"))))
      (message "a repeat: %d conses" n)
      (should (<= n 1)))))

(defvar drgnx-notice-test--sets nil "Variants of the 3 sets (40/40/20 items, 80 distinct ids), fresh plists each.")

(defun drgnx-notice-test--make-sets (churn)
  "The 3 sets as a producer sends them, each a fresh list of fresh plists.  CHURN non-nil: in each set the first
item says something else and the last is another entity — what changes between two recounts."
  (cl-flet ((items (from to)
              (cl-loop for i from from below to
                       collect (list :id (cons 'card (if (and churn (= i (1- to))) (+ i 1000) i))
                                     :text (format "j1 — card %d%s" i (if (and churn (= i from)) " (answered)" ""))
                                     :scope "j1" :command (list 'drgnx-job-ui-show "j1")))))
    (list (items 0 40) (items 20 60) (items 60 80))))

(ert-deftest drgnx-notice/a-set-replace-and-recount-is-cheap ()
  :tags '(:timing)
  (drgnx-notice-test-with-model
    (drgnx-notice-define-source 'jobs :title "Jobs")
    (drgnx-notice-define-source 'questions :title "Questions")
    (drgnx-notice-test--compile)
    ;; 202 fresh copies, alternating: each run replaces all 3 sets, 3 items say something else, 3 ids come and 3 go
    (setq drgnx-notice-test--sets (vconcat (mapcar (lambda (i) (drgnx-notice-test--make-sets (cl-oddp i)))
                                                   (number-sequence 0 201))))
    (let ((run (byte-compile
                '(lambda (v)
                   (let ((s (aref drgnx-notice-test--sets v)))
                     (drgnx-notice-set 'jobs (nth 0 s))
                     (drgnx-notice-set 'questions (nth 1 s))
                     (drgnx-notice-set 'agents (nth 2 s))
                     (drgnx-needs-you-count)))))
          (samples nil))
      (should (= (funcall run 0) 80))
      (should (= (funcall run 1) 81))                           ; card 59 leaves, 1039, 1059 and 1079 come
      (let ((tick (drgnx-notice-tick)))
        (dotimes (i 101)
          (let ((t0 (float-time)))
            (funcall run (+ 2 i))
            (push (* 1e6 (- (float-time) t0)) samples)))
        (should (= (drgnx-notice-tick) (+ tick (* 3 101)))))     ; every set changed
      (let ((median (nth 50 (sort samples #'<))))
        (message "replace 3 sets and recount: median %.1f µs" median)
        (should (<= median (* 60 (if (fboundp 'drgnx-run-ert-time-factor) (drgnx-run-ert-time-factor) 1))))))))

;;; core-notice-test.el ends here
