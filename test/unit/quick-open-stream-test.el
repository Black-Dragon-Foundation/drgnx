;;; quick-open-stream-test.el --- Quick Open's list and highlight while the listing streams, in every order -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: orders
;; Pattern A.  The core (core/drgnx-quick-open.el) takes the listing's batches, the user's typing and moves,
;; and the end of the listing: three sources, in every order they can come in (`drgnx-test-every-order').  The listing
;; ends after its last batch.  The shell (vertico, the process) is not here; its conversion is file-stream-test.el.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-quick-open)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defconst drgnx-quick-open-stream-test--batches
  '((batch ("src/main.el" "README.md" "docs/a.org"))
    (batch ("lib/main-extra.el" "main.c" "notes/MAIN-plan.org"))
    (batch ("test/main-test.el" "z.txt")))
  "The listing, in three batches; \"main\" matches something in each.")

(defun drgnx-quick-open-stream-test--matches (names input)
  "The names containing the single word INPUT (any case), by a test independent of the core's."
  (seq-filter (lambda (n) (string-search (downcase input) (downcase n))) names))

(defun drgnx-quick-open-stream-test--best (names input)
  "The best of the names matching INPUT: a file name that contains it, then the shorter, then by name."
  (car (sort (drgnx-quick-open-stream-test--matches names input)
             (lambda (a b)
               (let ((ka (if (string-search (downcase input) (downcase (file-name-nondirectory a))) 0 1))
                     (kb (if (string-search (downcase input) (downcase (file-name-nondirectory b))) 0 1)))
                 (or (< ka kb) (and (= ka kb) (or (< (length a) (length b))
                                                  (and (= (length a) (length b)) (string< a b))))))))))

(defun drgnx-quick-open-stream-test--run (check-fn)
  "Every order of the batches, three user events and the end; CHECK-FN gets (STATE TRACE) and returns nil or a message.
TRACE: one plist per fed event, newest first: :kind :before :after (the highlight), :done, :candidates (after), :cands-before,
:input, :received (every name received so far)."
  (drgnx-test-every-order
   :kinds '(batch input move done)
   :sources (list (cons 'listing drgnx-quick-open-stream-test--batches)
                  (cons 'user (list '(input "") '(input "main") '(move 1)))
                  (cons 'end (list '(done))))
   :edges (list (cons (cons 'listing 2) (cons 'end 0)))
   :init (lambda () (cons (drgnx-quick-open--init) nil))
   :step (lambda (st ev)
           (let* ((before (car st)) (after (car (drgnx-quick-open--step before ev))))
             (cons (cons after
                         (cons (list :kind (car ev) :before (drgnx-quick-open--s-sel before)
                                     :after (drgnx-quick-open--s-sel after) :done (drgnx-quick-open--s-done after)
                                     :candidates (drgnx-quick-open--candidates after)
                                     :cands-before (drgnx-quick-open--candidates before)
                                     :input (drgnx-quick-open--s-input after)
                                     :received (apply #'append (drgnx-quick-open--s-names after)))
                               (cdr st)))
                   nil)))
   :check (lambda (st _order) (funcall check-fn (car st) (cdr st)))))

(ert-deftest drgnx-quick-open/selection-stable ()
  "Pattern A: a batch re-sorts the list and the highlighted file stays that file; it moves only on input and move.
At the end the list holds the received names that match the last input, and the highlight is one of them."
  (let ((all (apply #'append (mapcar #'cadr drgnx-quick-open-stream-test--batches))))
    (drgnx-quick-open-stream-test--run
     (lambda (state trace)
       (or (cl-loop for e in trace
                    when (and (memq (plist-get e :kind) '(batch done)) (plist-get e :before)
                              (not (equal (plist-get e :before) (plist-get e :after))))
                    return (format "a %s moved the highlight from %S to %S" (plist-get e :kind)
                                   (plist-get e :before) (plist-get e :after)))
           (let ((got (sort (copy-sequence (drgnx-quick-open--candidates state)) #'string<))
                 (want (sort (drgnx-quick-open-stream-test--matches all (drgnx-quick-open--s-input state)) #'string<)))
             (unless (equal got want) (format "the list %S is not the matches %S" got want)))
           (and (drgnx-quick-open--candidates state)
                (not (member (drgnx-quick-open--s-sel state) (drgnx-quick-open--candidates state)))
                (format "the highlight %S is not in the list" (drgnx-quick-open--s-sel state))))))))

(ert-deftest drgnx-quick-open/first-candidates-early ()
  "Pattern A: after any batch the received names that match what is typed are candidates already, and the listing has
not ended (it ends after the last batch): candidates come before the end."
  (let ((batches-with-matches 0))
    (drgnx-quick-open-stream-test--run
     (lambda (_state trace)
       (cl-loop for e in trace
                when (eq (plist-get e :kind) 'batch)
                do (let ((want (drgnx-quick-open-stream-test--matches (plist-get e :received) (plist-get e :input))))
                     (when want (cl-incf batches-with-matches))
                     (when (or (plist-get e :done) (/= (length want) (length (plist-get e :candidates))))
                       (cl-return (format "after a batch: done=%S, candidates %S, matches %S" (plist-get e :done)
                                          (plist-get e :candidates) want)))))))
    (should (> batches-with-matches 0))))

(ert-deftest drgnx-quick-open/typing-and-moving-are-the-only-ways-the-highlight-moves ()
  "Pattern A: typed input puts the highlight on the best match of what was received; `move' goes one down the list
\(and stops at its end)."
  (drgnx-quick-open-stream-test--run
   (lambda (_state trace)
     (cl-loop for e in trace
              do (pcase (plist-get e :kind)
                   ('input (unless (equal (plist-get e :after)
                                          (drgnx-quick-open-stream-test--best (plist-get e :received) (plist-get e :input)))
                             (cl-return (format "input %S: the highlight is %S, the best match %S" (plist-get e :input)
                                                (plist-get e :after)
                                                (drgnx-quick-open-stream-test--best (plist-get e :received)
                                                                                    (plist-get e :input))))))
                   ('move (when-let* ((b (plist-get e :before)) (cs (plist-get e :cands-before))
                                      (at (cl-position b cs :test #'equal)))
                            (unless (equal (plist-get e :after) (nth (min (1- (length cs)) (1+ at)) cs))
                              (cl-return (format "a move from %S went to %S" b (plist-get e :after)))))))))))
