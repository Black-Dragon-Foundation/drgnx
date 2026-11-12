;;; work-views-test.el --- the Work space's other views: opening a trail's step and the review view -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the hub's calls are caught at `drgnx-hub-call' and answered by hand.  The trail's and the Timeline's keys on
;; the hub's rows: work-trail-nav-test.el; the Board's: work-board-rows-test.el.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-keys)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-trail-open-step "drgnx-work-trail")
(defvar drgnx-work-trail--session)

;;;; Opening a trail's step

(defconst drgnx-work-views-test--read
  '(:id 11 :seq 1 :session "s1" :class "tool" :tool "Read" :start 3600.0 :end 3601.5
        :detail (:origin "acp" :kind "read" :path "src/a.rs" :line_start 10 :line_end 14))
  "A read step with lines.")

(ert-deftest drgnx-work-trail/s-ret-opens-the-file-as-read ()
  ;; a read step's S-RET opens the file as the agent read it, from `work/file-at', in a read-only buffer `file@step-N'
  (let ((buf (generate-new-buffer " *work-trail-test*")) calls opened)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method params callback &rest _)
                     (push (cons method params) calls)
                     (funcall callback (list :bytes (base64-encode-string "one\ntwo\n") :seq 1) nil) 1)))
          (with-current-buffer buf
            (setq-local drgnx-work-trail--session "s1")
            (setq opened (drgnx-work-trail-open-step drgnx-work-views-test--read nil t)))
          (should (equal "work/file-at" (car (car calls))))
          (should (equal '(:session "s1" :path "src/a.rs" :seq 1) (cdr (car calls))))
          (should (equal "a.rs@step-1" (buffer-name opened)))
          (with-current-buffer opened
            (should buffer-read-only)
            (should (equal "one\ntwo\n" (buffer-string)))))
      (when (buffer-live-p opened) (kill-buffer opened))
      (kill-buffer buf))))

;;;; The review view and the second reviewer

(declare-function drgnx-work-review-install "drgnx-work-review")
(declare-function drgnx-work-review-decision-text "drgnx-work-review")
(declare-function drgnx-work-review--accept "drgnx-work-review")
(declare-function drgnx-work-review--reject "drgnx-work-review")
(declare-function drgnx-work-review-second "drgnx-work-review")
(declare-function drgnx-keys-load-profiles "drgnx-keys")
(defvar drgnx-work-review--keys)

(defconst drgnx-work-views-test--decisions
  '((:n 1 :id "decision:1" :kind "decision" :text "keep the lock" :origin "own" :at 1.0 :links nil)
    (:n 2 :id "decision:2" :kind "decision" :text "use SQLite" :origin "from-brief" :at 2.0 :links nil)
    (:n 3 :id "decision:3" :kind "decision" :text "drop the cache?" :origin "needs-user" :at 3.0 :links nil)
    (:n 4 :id "note:9" :kind "finding" :text "the cache is unused" :origin "own" :at 4.0 :links nil))
  "Three decisions of three origins, made in the order own, from the brief, needs your call; and a finding.")

(defconst drgnx-work-views-test--diff
  "--- a/src/a.rs\n+++ b/src/a.rs\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n@@ -9,1 +9,2 @@\n tail\n+more\n")

(ert-deftest drgnx-work-review/decisions-first-with-computed-dependents ()
  ;; pattern D: the review lists the decisions before the work, those from the brief first, then its own, then those
  ;; that need you; each says what git computed of it, and a finding is not a decision
  (let ((buf (generate-new-buffer " *work-review-test*")))
    (unwind-protect
        (with-current-buffer buf
          (drgnx-work-review-install
           buf "s1" :decisions drgnx-work-views-test--decisions
           :effects '(("decision:1" . (:decision "decision:1" :label "computed" :commits ("abc1234def")
                                                 :later_hunks ((:commit "9f3e1c2aa" :path "src/a.rs" :lines (10 20))))))
           :files '((:path "src/a.rs" :plus 2 :minus 1 :untracked nil))
           :diffs (list (cons "src/a.rs" drgnx-work-views-test--diff)))
          (should (equal '((:decisions) (:decision 2) (:decision 1) (:decision 3) (:summary) (:files)
                           (:file "src/a.rs") (:hunk "src/a.rs" 0) (:hunk "src/a.rs" 1))
                         drgnx-work-review--keys))
          (let ((text (substring-no-properties
                       (drgnx-work-review-decision-text (nth 0 drgnx-work-views-test--decisions)
                                                        (cdr (assoc "decision:1" '(("decision:1" . (:commits ("abc1234def")
                                                                                                             :later_hunks ((:commit "9f3e1c2aa" :path "src/a.rs" :lines (10 20))))))))))))
            (should (string-search "computed: 1 commit (abc1234)" text))
            (should (string-search "1 later hunk overlaps: src/a.rs:10–20 (9f3e1c2)" text))))
      (kill-buffer buf))))

(defmacro drgnx-work-views-test--calls (&rest body)
  "BODY with every call of the hub recorded, not made: `calls', newest first, of (METHOD . PARAMS)."
  (declare (indent 0))
  `(let (calls)
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params &rest _) (push (cons method params) calls) 1)))
       ,@body)
     calls))

(ert-deftest drgnx-work-review/hunk-reject-is-D ()
  ;; `a' accepts and `D' rejects, in every profile; a rejection marks the file pending and tells the agent, queued
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (dolist (p profiles)
      (let ((rows (plist-get (cdr p) :bind)))
        (should (member "D" (flatten-tree (assq 'work-review-reject rows))))
        (should (member "a" (flatten-tree (assq 'work-review-accept rows)))))))
  (let ((buf (generate-new-buffer " *work-review-test*")))
    (unwind-protect
        (with-current-buffer buf
          (drgnx-work-review-install buf "s1" :files '((:path "src/a.rs" :plus 2 :minus 1 :untracked nil))
                                     :diffs (list (cons "src/a.rs" drgnx-work-views-test--diff)))
          (let ((calls (drgnx-work-views-test--calls (drgnx-work-review--reject "src/a.rs" 1))))
            (should (= 2 (length calls)))
            (let ((mark (cdr (assoc "review/mark" calls))) (send (cdr (assoc "agents/send" calls))))
              (should (equal '("s1" "src/a.rs" "pending") (list (plist-get mark :agent) (plist-get mark :path) (plist-get mark :state))))
              (should (equal "s1" (plist-get send :id)))
              (should (string-search "src/a.rs" (plist-get send :text)))
              (should (string-search "@@ -9,1 +9,2 @@" (plist-get send :text)))))
          (let* ((calls (drgnx-work-views-test--calls (drgnx-work-review--accept "src/a.rs")))
                 (mark (cdr (assoc "review/mark" calls))))
            (should (equal "accepted" (plist-get mark :state)))
            (should (equal (secure-hash 'sha1 drgnx-work-views-test--diff) (plist-get mark :hash)))
            (should (equal "accept" (plist-get (plist-get mark :event) :kind)))))
      (kill-buffer buf))))

(ert-deftest drgnx-work-review/v-goes-through-propose ()
  ;; the second reviewer is a proposed job, never an agent started on the spot; its plan names the files and holds none of
  ;; the author's conclusions
  (let ((buf (generate-new-buffer " *work-review-test*")) file)
    (unwind-protect
        (with-current-buffer buf
          (drgnx-work-review-install buf "s1" :decisions drgnx-work-views-test--decisions
                                     :files '((:path "src/a.rs" :plus 2 :minus 1 :untracked nil))
                                     :diffs (list (cons "src/a.rs" drgnx-work-views-test--diff)))
          (setq default-directory temporary-file-directory)
          (let ((calls (drgnx-work-views-test--calls (drgnx-work-review-second))))
            (should (equal '("job/propose") (mapcar #'car calls)))
            (setq file (plist-get (cdr (car calls)) :plan))
            (should (file-name-absolute-p file))
            (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (should (string-search "**Role:** review" text))
              (should (string-search "src/a.rs" text))
              (dolist (c drgnx-work-views-test--decisions)
                (should-not (string-search (plist-get c :text) text))))))
      (when (and file (file-exists-p file)) (delete-file file))
      (kill-buffer buf))))

(provide 'work-views-test)
;;; work-views-test.el ends here
