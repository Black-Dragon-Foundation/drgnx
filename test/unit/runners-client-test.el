;;; runners-client-test.el --- the runners client: the key handover, cards, settings -*- lexical-binding: t -*-
;; test-class: det
;; Pattern B (through the gate): the hub's calls and the key store are the two gates, each replaced by a recorder that
;; counts what passes; the hub's own events go straight into the handler, as the client's connection delivers them.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-runners-view" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-runners" drgnx-dir) nil t)

(defvar drgnx-runners--session-keys)
(defvar drgnx-runners--state)

(defmacro runners-client-test--with (reads calls &rest body)
  "BODY with a fresh notice model and the `runners' source, the key store replaced by a recorder (it counts its reads
in READS and answers \"secret-NAME\"), and the hub's calls recorded in CALLS (METHOD PARAMS), each answered well.  The
client's session keys are empty before and after."
  (declare (indent 2) (debug t))
  `(drgnx-notice-test-with-model
     (drgnx-notice-define-source 'runners :title "Runners" :command 'runners-load-keys)
     (let ((drgnx-runners--session-keys nil) (drgnx-runners--state (drgnx-runners-state)))
       (cl-letf (((symbol-function 'drgnx-runners--read-key)
                  (lambda (name) (cl-incf ,reads) (concat "secret-" name)))
                 ((symbol-function 'drgnx-runners--proven-p) (lambda () t))
                 ((symbol-function 'drgnx-hub-ensure) #'ignore)
                 ((symbol-function 'force-mode-line-update) #'ignore)
                 ((symbol-function 'drgnx-hub-call)
                  (lambda (method params cb &rest _) (push (list method params) ,calls) (funcall cb t nil) 1)))
         ,@body))))

(defun runners-client-test--texts ()
  (mapcar (lambda (i) (plist-get i :text)) (drgnx-needs-you-items)))

;; pattern D: the Mac onboarding card names each step a person takes on the Mac (a standard account, Remote Login for it
;; alone, the Command Line Tools and Homebrew in their own account, a way to reach it) and the host to add; no step asks
;; for sudo or makes the runner an administrator
(ert-deftest drgnx-runners-client/the-mac-card-names-the-steps ()
  (dolist (s '("standard account named drgnx-runner" "Remote Login for that account only" "xcode-select --install"
               "drgnx-runners-mac-tools" "brew install mise" "drgnx-runners-mac-toolchains" "tailscaled"
               "drgnx-runner@YOUR-MAC"))
    (should (string-search s drgnx-runners-mac-steps)))
  (should (string-search "never runs sudo" drgnx-runners-mac-steps))
  (should-not (string-search "sudo " (replace-regexp-in-string "never runs sudo" "" drgnx-runners-mac-steps))))

(ert-deftest drgnx-runners-client/need-keys-event-never-reads-the-store ()
  "Pattern B: the hub's `runners/need-keys' raises a card saying what to run, and the store is read 0 times and the hub
is called 0 times: only a command the user runs reads it."
  (let ((reads 0) (calls nil))
    (runners-client-test--with reads calls
      (drgnx-runners--event "runners/need-keys" '(:names ["CRATES_IO_TOKEN"]))
      (should (= 0 reads))
      (should-not calls)
      (should (equal (runners-client-test--texts) '("needs your keys: run Runners: Load Keys")))
      ;; an event from a hub that did not prove itself changes nothing
      (cl-letf (((symbol-function 'drgnx-runners--proven-p) (lambda () nil)))
        (drgnx-runners--event "runners/need-keys" '(:names ["OTHER"]))
        (should (equal (drgnx-runners--needed) '("CRATES_IO_TOKEN")))))))

(ert-deftest drgnx-runners-client/load-keys-sends-and-keeps-for-the-session ()
  "Pattern B: Runners: Load Keys reads what the hub asked for, sends it with `runners/keys', keeps it in memory for the
session and settles the card."
  (let ((reads 0) (calls nil))
    (runners-client-test--with reads calls
      (drgnx-runners--event "runners/need-keys" '(:names ["A" "B"]))
      (should (runners-client-test--texts))
      (drgnx-runners-load-keys)
      (should (= 2 reads))
      (should (equal (reverse calls) '(("runners/keys" (:keys (:A "secret-A" :B "secret-B"))))))
      (should (equal (sort (mapcar #'car drgnx-runners--session-keys) #'string<) '("A" "B")))
      (should-not (runners-client-test--texts))
      ;; a refusal keeps the card
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest args) (funcall (nth 2 args) nil "refused") 1)))
        (drgnx-runners--event "runners/need-keys" '(:names ["A"]))
        (drgnx-runners-load-keys)
        (should (runners-client-test--texts))))))

(ert-deftest drgnx-runners-client/keys-resent-after-a-proven-reconnect ()
  "Pattern B: on each hello a hub proves, the kept keys go again and the store is not read; with none kept nothing is sent."
  (let ((reads 0) (calls nil))
    (runners-client-test--with reads calls
      (drgnx-runners--resend)
      (should-not calls)
      (setq drgnx-runners--session-keys (list (cons "A" "secret-A")))
      (drgnx-runners--resend)
      (should (equal (reverse calls) '(("runners/keys" (:keys (:A "secret-A"))))))
      (should (= 0 reads)))))

(ert-deftest drgnx-runners-client/teardown-forgets-the-keys ()
  "Pattern B: turning the module off clears the kept keys, and takes the connected hook and the source with it."
  (let ((reads 0) (calls nil))
    (runners-client-test--with reads calls
      (drgnx-notice-undefine-source 'runners)   ; the module's setup defines it
      (drgnx-test-with-modules '(tools/runners) :strict t
                               (should (memq 'drgnx-runners--resend drgnx-hub-connected-functions))
                               (setq drgnx-runners--session-keys (list (cons "A" "secret-A"))))
      (should-not drgnx-runners--session-keys)
      (should-not (memq 'drgnx-runners--resend drgnx-hub-connected-functions)))))

(ert-deftest drgnx-runners-client/every-runner-setting-is-workspace-never ()
  "Pattern D: no setting of the runners about trust, keys or where jobs go can be set by a repository's own files.  The
five queue settings a project chooses for itself (`jobs.md', \"The queue and priority\") are the only ones its files may set."
  (let ((names (seq-filter (lambda (s) (string-prefix-p "drgnx-runners-" (symbol-name s))) (drgnx-setting-names)))
        (project-chooses '(drgnx-runners-send drgnx-runners-heavy drgnx-runners-image drgnx-runners-weight
                                              drgnx-runners-project-visibility)))
    (should (> (length names) 8))
    (should (memq 'drgnx-runners-key-host names))
    (dolist (s names)
      (should (eq (if (memq s project-chooses) 'data 'never) (plist-get (drgnx-setting-meta s) :workspace))))))

(provide 'runners-client-test)
;;; runners-client-test.el ends here
