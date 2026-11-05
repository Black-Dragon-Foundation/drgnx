;;; agents-cards-test.el --- batch tests: Agents: Answer Permission Card -*- lexical-binding: t -*-
;; test-class: det

;; SPDX-License-Identifier: GPL-3.0-or-later

;; The hub is a stub that records `cards/settle' and answers it; the card arrives as the hub's `card' event through
;; `drgnx-hub--note-card' on a proven pipe connection, as in hub-client-test.el.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-notice)
(require 'drgnx-hub-client)
(require 'drgnx-agents-cards)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defconst drgnx-agents-cards-test--choices
  '((:id "once" :label "Allow once (10 minutes)") (:id "session" :label "Allow for this session")
    (:id "refuse" :label "Refuse"))
  "A browser card's choices as the hub's `card' event lists them.")

(defmacro drgnx-agents-cards-test--with (calls &rest body)
  "BODY with a fresh notice model, no kept cards, a proven event connection, prompts that signal, and a stub hub that
pushes each call's (METHOD . PARAMS) onto CALLS and answers it settled."
  (declare (indent 1))
  `(drgnx-notice-test-with-model
     (let ((conn (make-pipe-process :name "agents-cards-test" :noquery t))
           (drgnx-hub--card-choices nil)
           (,calls nil))
       (unwind-protect
           (let ((drgnx-hub--event-conn conn))
             (process-put conn :drgnx-proven t)
             (cl-letf (((symbol-function 'drgnx-hub-call)
                        (lambda (method params callback &rest _)
                          (push (cons method params) ,calls)
                          (funcall callback '(:settled t) nil)
                          1))
                       ((symbol-function 'read-string) (lambda (&rest _) (error "prompted")))
                       ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted")))
                       ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "prompted"))))
               ,@body))
         (delete-process conn)))))

(ert-deftest drgnx-agents-cards/answers-with-a-listed-choice ()
  ;; the card's choices are offered with its body first; the pick settles the card with that id, and the notice and
  ;; the kept choices go
  (drgnx-agents-cards-test--with calls
    (drgnx-hub--note-card "card" (list :id 7 :kind "matrix" :title "s1 wants to open web sites (first: example.com:443)"
                                       :body "Pages can send what the agent gives them"
                                       :choices drgnx-agents-cards-test--choices))
    (let (asked offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (setq asked prompt offered collection)
                   "Allow for this session")))
        (should (equal (drgnx-agents-answer-card 7) "session")))
      (should (string-prefix-p "Pages can send what the agent gives them\n" asked))
      (should (equal offered '("Allow once (10 minutes)" "Allow for this session" "Refuse"))))
    (should (equal calls '(("cards/settle" :card 7 :choice "session"))))
    (should-not (drgnx-notices :source 'hub))
    (should-not drgnx-hub--card-choices)
    ;; nothing left to answer
    (should-error (call-interactively #'drgnx-agents-answer-card) :type 'user-error)))

(ert-deftest drgnx-agents-cards/never-prompts-from-a-hook ()
  ;; the note function only records: no prompt, no hub call; the command is for the user to run
  (drgnx-agents-cards-test--with calls
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "prompted"))))
      (let ((inhibit-interaction t))
        (drgnx-hub--note-card "card" (list :id 9 :kind "matrix" :title "s1 wants a browser in its sandbox"
                                           :choices drgnx-agents-cards-test--choices))))
    (should-not calls)
    (should (assq 9 drgnx-hub--card-choices))
    (should (equal (plist-get (car (drgnx-notices :source 'hub)) :command) '(drgnx-agents-answer-card 9)))))

(ert-deftest drgnx-agents-cards/browser-check-asks-the-hub-and-says-the-result ()
  (let (call said)
    (cl-letf (((symbol-function 'drgnx-hub-call)
               (lambda (method params cb &rest kw)
                 (setq call (list method params kw))
                 (funcall cb '(:ok t :start_ms 812 :screenshot_bytes 2048 :peak_bytes 314572800) nil)))
              ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
      (drgnx-agents-browser-check))
    (should (equal (car call) "browser/check"))
    (should (string-search "started in 812 ms, a screenshot of 2048 bytes, peak memory 300 MiB" (car said))))
  (should (equal (drgnx-agents-browser-check--summary '(:ok nil :why "the sandbox did not start"))
                 "failed: the sandbox did not start")))

;;; agents-cards-test.el ends here
