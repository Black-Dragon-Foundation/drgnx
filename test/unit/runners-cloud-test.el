;;; runners-cloud-test.el --- cloud in the runner list: setup, the confirm card, off -*- lexical-binding: t -*-
;; test-class: det
;; Pattern B (through the gate): the hub's calls are replaced by a recorder; the hub's events go straight into the handler.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-runners-view" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-runners" drgnx-dir) nil t)

(defvar drgnx-runners--state)
(defvar drgnx-runners-cloud--status)

(defmacro runners-cloud-test--with (calls &rest body)
  "BODY with a fresh notice model and the `runners' source, the hub's calls recorded in CALLS (METHOD PARAMS) and each
answered well, and no cloud status before or after."
  (declare (indent 1) (debug t))
  `(drgnx-notice-test-with-model
     (drgnx-notice-define-source 'runners :title "Runners" :command 'runners-load-keys)
     (let ((drgnx-runners--state (drgnx-runners-state)) (drgnx-runners-cloud--status nil))
       (cl-letf (((symbol-function 'drgnx-runners--proven-p) (lambda () t))
                 ((symbol-function 'drgnx-hub-ensure) #'ignore)
                 ((symbol-function 'force-mode-line-update) #'ignore)
                 ((symbol-function 'drgnx-hub-call)
                  (lambda (method params cb &rest _) (push (list method params) ,calls) (funcall cb nil nil) 1)))
         ,@body))))

(defun runners-cloud-test--cards ()
  (drgnx-needs-you-items))

(defconst runners-cloud-test--confirm
  '(:state "confirm"
           :projection "First machine: c7a.4xlarge spot, eu-west-1, about $0.31/h (on-demand fallback $0.82/h). It stops after 10 min idle and ends by 4 h. Worst case with drgnx down: 4 machines x 4 h = about $13. This month: $0 of your $50 cap."
           :checks [(:line "Instance profile can be read" :pass t :fix nil)
                    (:line "Spot requests are allowed" :pass nil :fix "Allow ec2:RequestSpotInstances in the role")]))

(ert-deftest drgnx-runners-cloud/setup-refuses-an-empty-cap ()
  "Pattern B: an empty, zero or non-number cap is refused before the hub is called; a cap, regions, sizes and a
credential source are sent as `runners/cloud/setup'."
  (let ((calls nil))
    (runners-cloud-test--with calls
      (dolist (bad '("" "  " "0" "-5" "abc"))
        (should-error (drgnx-runners-cloud-setup bad "eu-west-1" "c7a.4xlarge" "aws sso") :type 'user-error))
      (should-error (drgnx-runners-cloud-setup nil "eu-west-1" "c7a.4xlarge" "aws sso") :type 'user-error)
      (should-not calls)
      (drgnx-runners-cloud-setup "50" "eu-west-1, eu-west-2" "c7a.4xlarge" "aws sso")
      (should (equal calls '(("runners/cloud/setup"
                              (:cap 50.0 :regions ["eu-west-1" "eu-west-2"] :sizes ["c7a.4xlarge"]
                                    :credentials "aws sso"))))))))

(ert-deftest drgnx-runners-cloud/confirm-card-shows-projection-and-preflight ()
  "Pattern B: the hub's cloud status `confirm' raises the card \"Start the first cloud machine\" with the projection and
every pre-flight line (a failed one with its fix); its command is the confirm, which sends `runners/cloud/confirm' only
after a yes, and the card goes when the hub says the cloud is on."
  (let ((calls nil))
    (runners-cloud-test--with calls
      (drgnx-runners--event "runners/cloud-changed" runners-cloud-test--confirm)
      (let* ((card (seq-find (lambda (i) (string-search "Start the first cloud machine" (plist-get i :text)))
                             (runners-cloud-test--cards)))
             (detail (plist-get card :detail)))
        (should card)
        (should (string-search "about $0.31/h" detail))
        (should (string-search "This month: $0 of your $50 cap." detail))
        (should (string-search "Instance profile can be read" detail))
        (should (string-search "Spot requests are allowed" detail))
        (should (string-search "Allow ec2:RequestSpotInstances in the role" detail))
        (should (eq 'runners-cloud-confirm (plist-get card :command))))
      (should-not calls)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (drgnx-runners-cloud-confirm))
      (should-not calls)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (drgnx-runners-cloud-confirm))
      (should (equal (mapcar #'car calls) '("runners/cloud/confirm")))
      (drgnx-runners--event "runners/cloud-changed" '(:state "on" :spent 0.0 :cap 50.0))
      (should-not (seq-find (lambda (i) (string-search "Start the first cloud machine" (plist-get i :text)))
                            (runners-cloud-test--cards))))))

(ert-deftest drgnx-runners-cloud/off-from-the-card ()
  "Pattern B: while cloud is on but not yet proven the card offers Turn Cloud Off; the command asks first, sends
`runners/cloud/off', and the card settles when the hub says the cloud is off.  A login card offers the retry."
  (let ((calls nil))
    (runners-cloud-test--with calls
      (drgnx-runners--event "runners/cloud-changed" '(:state "unproven"))
      (let ((card (seq-find (lambda (i) (string-search "not yet proven" (plist-get i :text)))
                            (runners-cloud-test--cards))))
        (should card)
        (should (eq 'runners-cloud-off (plist-get card :command))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (drgnx-runners-cloud-off))
      (should-not calls)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (drgnx-runners-cloud-off))
      (should (equal (mapcar #'car calls) '("runners/cloud/off")))
      (drgnx-runners--event "runners/cloud-changed" '(:state "off"))
      (should-not (seq-find (lambda (i) (string-search "not yet proven" (plist-get i :text)))
                            (runners-cloud-test--cards)))
      (drgnx-runners--event "runners/cloud-changed" '(:state "login" :command "aws sso login"))
      (let ((card (seq-find (lambda (i) (string-search "aws sso login" (plist-get i :text)))
                            (runners-cloud-test--cards))))
        (should card)
        (should (eq 'runners-cloud-retry (plist-get card :command)))))))

(ert-deftest drgnx-runners-cloud/strip-text ()
  "Pattern D: the strip's text is `cloud $spent/$cap', and nothing while cloud is off."
  (should (equal (drgnx-runners-cloud-strip '(:state "on" :spent 3.1 :cap 50.0)) "cloud $3.10/$50"))
  (should-not (drgnx-runners-cloud-strip '(:state "off")))
  (should-not (drgnx-runners-cloud-strip nil)))

(provide 'runners-cloud-test)
;;; runners-cloud-test.el ends here
