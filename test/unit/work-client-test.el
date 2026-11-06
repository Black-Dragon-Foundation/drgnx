;;; work-client-test.el --- the Work map client's pure core: versions, gaps, marks and the restart -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; `drgnx-work-client-step' (core/drgnx-work-client.el) takes a state and one `work-map' event and returns the next
;; state with the marks the view must act on.  No process, timer or clock: the deliveries run in every order they can
;; arrive in (`drgnx-test-every-order'), against the frame in test/fixtures/work-space/frame.json.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-dir) nil t)

(defun drgnx-work-client-test--minutes (state id)
  (plist-get (plist-get (drgnx-work-client-item state id) :fields) :minutes))

(defun drgnx-work-client-test--state (state ev)
  "The adapter for `drgnx-test-every-order': EV is (delta EVENT), (frame FRAME) or (lost)."
  (pcase ev
    (`(delta ,e) (cons (car (drgnx-work-client-step state e)) nil))
    (`(frame ,f) (cons (drgnx-work-client-init f) nil))
    (`(lost) (cons (drgnx-work-client-lost state) nil))))

(ert-deftest drgnx-work-client/every-order-same-frame ()
  ;; two deltas and one of them again, in any order: version 5, both changes, nothing applied twice
  (let* ((f (drgnx-work-fixture-frame))
         (d4 (drgnx-work-fixture-delta 4 3 :changed (list (drgnx-work-fixture-changed f "agent:a1" :state "waiting"))))
         (d5 (drgnx-work-fixture-delta 5 4 :changed (list (drgnx-work-fixture-changed f "agent:a2" :minutes 6))))
         (r (drgnx-test-every-order
             :kinds '(delta)
             :sources `((one (delta ,d4)) (two (delta ,d5)) (again (delta ,d4)))
             :init (lambda () (drgnx-work-client-init f))
             :step #'drgnx-work-client-test--state
             :check (lambda (s _order)
                      (cond ((/= 5 (drgnx-work-client-version s)) (format "version %S, not 5" (drgnx-work-client-version s)))
                            ((not (equal "waiting" (plist-get (plist-get (drgnx-work-client-item s "agent:a1") :fields) :state)))
                             "a1 did not change")
                            ((/= 6 (drgnx-work-client-test--minutes s "agent:a2")) "a2 did not change")
                            ((drgnx-work-client-held s) "a delta is still held"))))))
    (should (eq 'exhaustive (plist-get r :mode)))))

(ert-deftest drgnx-work-client/old-delta-is-dropped ()
  (let* ((f (drgnx-work-fixture-frame)) (s (drgnx-work-client-init f))
         (old (drgnx-work-fixture-delta 3 2 :changed (list (drgnx-work-fixture-changed f "agent:a1" :minutes 99))))
         (r (drgnx-work-client-step s old)))
    (should (equal 32 (drgnx-work-client-test--minutes (car r) "agent:a1")))
    (should (= 3 (drgnx-work-client-version (car r))))
    (should-not (plist-get (cdr r) :rows))
    (should-not (plist-get (cdr r) :resync))))

(ert-deftest drgnx-work-client/gap-asks-resync ()
  (let* ((f (drgnx-work-fixture-frame)) (s (drgnx-work-client-init f))
         (gap (drgnx-work-fixture-delta 6 5 :changed (list (drgnx-work-fixture-changed f "agent:a1" :minutes 99))))
         (r (drgnx-work-client-step s gap)))
    (should (plist-get (cdr r) :resync))
    (should (= 3 (drgnx-work-client-version (car r))))                 ; nothing applied
    (should (equal 32 (drgnx-work-client-test--minutes (car r) "agent:a1")))
    (should (= 1 (length (drgnx-work-client-held (car r)))))
    ;; the full frame the resync fetches replaces the state and drops what was held
    (let ((fresh (drgnx-work-client-init (plist-put (drgnx-work-fixture-frame) :version 7))))
      (should (= 7 (drgnx-work-client-version fresh)))
      (should-not (drgnx-work-client-held fresh)))))

(ert-deftest drgnx-work-client/marks-only-changed-rows ()
  (let* ((f (drgnx-work-fixture-frame)) (s (drgnx-work-client-init f))
         (d (drgnx-work-fixture-delta 4 3 :changed (list (drgnx-work-fixture-changed f "agent:a1" :minutes 33))))
         (r (drgnx-work-client-step s d)))
    (should (equal '((:row 4 0 0)) (plist-get (cdr r) :rows)))
    (should (equal '("agent:a1") (plist-get (cdr r) :items)))
    (should-not (plist-get (cdr r) :strip))
    (should-not (plist-get (cdr r) :layout))
    ;; a removed item marks the row it had; a needs-you change marks the strip
    (let ((r2 (drgnx-work-client-step
               (car r) (drgnx-work-fixture-delta 5 4 :removed '("agent:a1/t1") :needs_you nil))))
      (should (equal '((:row 4 0 1)) (plist-get (cdr r2) :rows)))
      (should (plist-get (cdr r2) :strip))
      (should-not (drgnx-work-client-item (car r2) "agent:a1/t1")))))

(ert-deftest drgnx-work-client/restart-mid-delta-resyncs-with-the-gap-facts ()
  ;; the hub goes away between two deltas; the new hub's frame, built after the overlap, holds it.  The second old
  ;; delta may land before or after the loss: dropped when after.  Whatever the order the state is the new frame's.
  (let* ((f (drgnx-work-fixture-frame))
         (d4 (drgnx-work-fixture-delta 4 3 :changed (list (drgnx-work-fixture-changed f "agent:a1" :minutes 33))))
         (d5 (drgnx-work-fixture-delta 5 4 :changed (list (drgnx-work-fixture-changed f "agent:a1" :minutes 34))))
         (gap-edge '(:from "branch:drgnx/rp-df-hub" :to "branch:drgnx/rp-fx-sess" :kind "overlap"))
         (fresh (let ((n (drgnx-work-fixture-frame)))
                  (setq n (plist-put n :version 1))
                  (setq n (plist-put n :edges (append (plist-get n :edges) (list gap-edge))))
                  (plist-put n :items (mapcar (lambda (it) (if (equal (plist-get it :id) "agent:a2")
                                                               (drgnx-work-fixture-changed n "agent:a2" :minutes 99)
                                                             it))
                                              (plist-get n :items)))))
         (d2 (drgnx-work-fixture-delta 2 1 :changed (list (drgnx-work-fixture-changed fresh "agent:a2" :minutes 100)))))
    (drgnx-test-every-order
     :kinds '(delta frame lost)
     :sources `((old (delta ,d4) (delta ,d5)) (loss (lost)) (new (frame ,fresh) (delta ,d2)))
     :edges '(((old . 0) . (loss . 0)) ((loss . 0) . (new . 0)) ((old . 1) . (new . 0)))
     :init (lambda () (drgnx-work-client-init (drgnx-work-fixture-frame)))
     :step #'drgnx-work-client-test--state
     :check (lambda (s _order)
              (cond ((not (drgnx-work-client-live-p s)) "not live after the new frame")
                    ((/= 2 (drgnx-work-client-version s)) (format "version %S, not 2" (drgnx-work-client-version s)))
                    ((/= 100 (drgnx-work-client-test--minutes s "agent:a2")) "the new hub's delta is missing")
                    ((/= 32 (drgnx-work-client-test--minutes s "agent:a1")) "an old delta leaked into the new frame")
                    ((not (member gap-edge (drgnx-work-client-edges s))) "the overlap of the gap is missing")
                    ((drgnx-work-client-held s) "a delta is still held"))))))

(provide 'work-client-test)
;;; work-client-test.el ends here
