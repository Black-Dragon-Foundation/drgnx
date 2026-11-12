;;; debug-investigation-test.el --- batch tests: debugging with an agent in the editor -*- lexical-binding: t -*-
;; test-class: det
;; The hub's `debug-investigation' and `debug-probes' events are fed by hand and its answers scripted
;; (`drgnx-hub-call-sync' replaced): what is tested is what the editor draws, sends and takes.  The hub side has its
;; Rust tests (debug::tests_agent, the matrix's rows) and the conformance scenario debug/partner-agent.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-gutter" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-debug-timeline" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-debug-investigation" drgnx-dir) nil t)

(defmacro debug-investigation-test--with (&rest body)
  "BODY with an empty investigation; the hub's calls in `calls'."
  (declare (indent 0))
  `(let ((calls nil) (drgnx-debug-investigation--hypotheses nil) (drgnx-debug-investigation--fixes nil))
     (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &optional _timeout) (push (cons method params) calls) t)))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (string-prefix-p "*Debug " (buffer-name b)) (kill-buffer b)))))))

(ert-deftest drgnx-debug-investigation/the-agents-ring-on-its-marks ()
  "An agent's breakpoint and probe are ringed and say whose they are; the user's are not."
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (let ((drgnx-debug-gutter--bps (list (list :id 1 :line 1 :enabled t :verified t)
                                         (list :id 2 :line 2 :enabled t :verified t :agent "s1"))))
      (cl-letf (((symbol-function 'drgnx-debug-gutter--claim) #'ignore))
        (drgnx-debug-gutter--draw))
      (let ((mine (cdr (assq 1 drgnx-debug-gutter--overlays))) (its (cdr (assq 2 drgnx-debug-gutter--overlays))))
        (should-not (overlay-get mine 'drgnx-debug-agent))
        (should (equal (overlay-get its 'drgnx-debug-agent) "s1"))
        (should (string-match-p "set by agent s1" (overlay-get its 'drgnx-debug-help)))
        ;; in a terminal the glyph's character wears the ring's face
        (should (eq (get-text-property 0 'face (drgnx-debug-gutter--ring-char "●" "s1")) 'drgnx-debug-agent-ring))))
    (should (string-match-p "agent s2"
                            (drgnx-debug-timeline--probe-help (list :id "p1" :expr "total" :agent "s2"))))
    (should-not (string-match-p "agent" (drgnx-debug-timeline--probe-help (list :id "p1" :expr "total"))))))

(ert-deftest drgnx-debug-investigation/probes-an-agent-changed-are-drawn ()
  "`debug-probes' is taken as a `debug/probe/op' answer."
  (debug-investigation-test--with
    (let (taken)
      (cl-letf (((symbol-function 'drgnx-debug-timeline--take) (lambda (r) (setq taken r))))
        (drgnx-debug-investigation--event "debug-probes" '(:root "/p" :probes [(:id "p1" :agent "s1")])))
      (should (equal (plist-get taken :root) "/p")))))

(ert-deftest drgnx-debug-investigation/the-investigation-section ()
  "Hypotheses are listed by state with their evidence; a changed one replaces itself."
  (debug-investigation-test--with
    (drgnx-debug-investigation--event
     "debug-investigation" '(:root "/p" :hypothesis (:id "h1" :title "reserve goes negative" :state "open"
                                                         :evidence ["run r1 stop 4"] :agent "s1")))
    (drgnx-debug-investigation--event
     "debug-investigation" '(:root "/p" :hypothesis (:id "h2" :title "a stale cache" :state "rejected"
                                                         :evidence [] :agent "s1")))
    (drgnx-debug-investigation--event
     "debug-investigation" '(:root "/p" :hypothesis (:id "h1" :title "reserve goes negative" :state "confirmed"
                                                         :evidence ["run r1 stop 4" "fork f2"] :agent "s1")))
    (should (= (length drgnx-debug-investigation--hypotheses) 2))
    (with-current-buffer (drgnx-debug-investigation--render)
      (let ((s (buffer-string)))
        (should (string-match-p "Confirmed\n  h1  reserve goes negative  s1\n      run r1 stop 4\n      fork f2" s))
        (should (string-match-p "Rejected\n  h2  a stale cache" s))
        (should-not (string-match-p "Open" s))))))

(ert-deftest drgnx-debug-investigation/explain-asks-the-agent-in-its-chat ()
  (debug-investigation-test--with
    (should-error (call-interactively #'drgnx-debug-investigation-explain) :type 'user-error)
    (drgnx-debug-investigation--event
     "debug-investigation" '(:root "/p" :hypothesis (:id "h1" :title "t" :state "open" :evidence [] :agent "s1")))
    (call-interactively #'drgnx-debug-investigation-explain)
    (should (equal (car (car calls)) "agents/send"))
    (should (equal (plist-get (cdr (car calls)) :id) "s1"))
    (should (string-match-p "Explain your debugging investigation" (plist-get (cdr (car calls)) :text)))))

(ert-deftest drgnx-debug-investigation/the-fix-card-and-accept ()
  "A fix is reviewed as its diff with the hypothesis' evidence; Accept puts it in the buffer as the agent's change."
  (debug-investigation-test--with
    (let* ((root (make-temp-file "drgnx-fix" t)) (file (expand-file-name "stock.py" root)) origin)
      (unwind-protect
          (progn
            (with-temp-file file (insert "reserve = total - used\n"))
            (drgnx-debug-investigation--event
             "debug-investigation"
             `(:root ,root :hypothesis (:id "h1" :title "reserve goes negative" :state "confirmed"
                                            :evidence ["fork f2"] :agent "s1")))
            (should-error (drgnx-debug-investigation-review-fix "h1") :type 'user-error)
            (drgnx-debug-investigation--event
             "debug-investigation"
             `(:root ,root :fix (:hypothesis "h1" :run "r1" :agent "s1" :passed t
                                             :files [(:path "stock.py" :text "reserve = max(0, total - used)\n")])))
            (drgnx-debug-investigation-review-fix "h1")
            (with-current-buffer "*Debug Fix: h1*"
              (let ((s (buffer-string)))
                (should (string-match-p "Fix for reserve goes negative" s))
                (should (string-match-p "passed in a fresh fork of run r1" s))
                (should (string-match-p "fork f2" s))
                (should (string-match-p "^\\+reserve = max(0, total - used)" s))))
            (cl-letf (((symbol-function 'replace-region-contents)
                       (let ((real (symbol-function 'replace-region-contents)))
                         (lambda (&rest args) (setq origin (bound-and-true-p nidhogg-history-origin))
                           (apply real args)))))
              (drgnx-debug-investigation-accept-fix "h1"))
            (should (equal origin "agent:s1#fix-h1"))
            (with-current-buffer (find-buffer-visiting file)
              (should (equal (buffer-string) "reserve = max(0, total - used)\n"))
              (should (buffer-modified-p))
              (set-buffer-modified-p nil)
              (kill-buffer))
            (should-not drgnx-debug-investigation--fixes))
        (delete-directory root t)))))

;;; debug-investigation-test.el ends here
