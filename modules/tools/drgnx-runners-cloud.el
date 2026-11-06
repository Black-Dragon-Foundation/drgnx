;;; drgnx-runners-cloud.el --- Runners in your cloud: setup, the first-start card, cost and off (library of tools/runners) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's side of cloud runners (docs/guide/runners.md, "Cloud: what you give drgnx").  The hub says where cloud
;; stands with the event `runners/cloud-changed' (a plist: :state "off", "confirm", "login", "unproven" or "on", plus
;; :projection, :checks, :command, :spent, :cap).  That event only raises or settles a card, and never prompts: the
;; commands the user runs (Set Up Cloud, Start the First Cloud Machine, Turn Cloud Off, Retry Cloud, Cloud Cost, Rotate
;; the Cloud CA) are the only ones that ask or call the hub.  Module `tools/runners' (drgnx-runners.el) defines them.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-command-define "drgnx-registry")

(defvar drgnx-runners-cloud--status nil
  "Where cloud stands as the hub last said (a plist, `runners/cloud-changed'), or nil.")

(defconst drgnx-runners-cloud-credential-sources '("aws sso" "aws profile" "environment" "gcloud")
  "The credential sources the setup form offers.  The default is the first.")

(defconst drgnx-runners-cloud-default-regions "us-east-1" "The regions the setup form starts with.")
(defconst drgnx-runners-cloud-default-sizes "c7a.4xlarge" "The machine sizes the setup form starts with.")

(defun drgnx-runners-cloud--list (text)
  "The comma-separated words of TEXT, as a vector for the hub."
  (vconcat (split-string (or text "") "[ ,]+" t)))

(defun drgnx-runners-cloud--cap (text)
  "TEXT as a cap in dollars, or a user error: the cap is typed, never defaulted, and above zero."
  (let ((s (string-trim (if (stringp text) text ""))))
    (unless (string-match-p "\\`[0-9]+\\(\\.[0-9]+\\)?\\'" s)
      (user-error "Cloud needs a monthly cap in dollars (a number above zero); none was given"))
    (let ((n (float (string-to-number s))))
      (unless (> n 0) (user-error "The cloud cap must be above zero"))
      n)))

;;;; Cards

(defun drgnx-runners-cloud-cards (status)
  "The notice items for cloud STATUS (the hub's plist): the first-start confirm, a login, or not yet proven."
  (pcase (plist-get status :state)
    ("confirm"
     (list (list :id '(cloud confirm) :text "Start the first cloud machine: confirm to go ahead"
                 :command 'runners-cloud-confirm
                 :detail (string-join
                          (append (list (or (plist-get status :projection) ""))
                                  (mapcar (lambda (c)
                                            (format "%s %s%s" (if (plist-get c :pass) "ok:" "fails:") (plist-get c :line)
                                                    (if (plist-get c :fix) (format " (%s)" (plist-get c :fix)) "")))
                                          (append (plist-get status :checks) nil))
                                  (list "Declining: Turn Cloud Off."))
                          "\n"))))
    ("login"
     (list (list :id '(cloud login)
                 :text (format "The cloud credentials need a login: run `%s`, then Runners: Retry Cloud"
                               (or (plist-get status :command) "your login command"))
                 :command 'runners-cloud-retry)))
    ("unproven"
     (list (list :id '(cloud unproven) :text "cloud: on, not yet proven on this account"
                 :command 'runners-cloud-off
                 :detail "A first machine is checked before cloud counts as on.  Turn Cloud Off ends it and removes what drgnx made.")))))

(defun drgnx-runners-cloud-strip (status)
  "The strip's text for cloud STATUS: `cloud $3.10/$50', or nil while cloud is off."
  (when (and status (member (plist-get status :state) '("on" "unproven" "confirm" "login"))
             (numberp (plist-get status :spent)) (numberp (plist-get status :cap)))
    (format "cloud $%.2f/$%g" (plist-get status :spent) (plist-get status :cap))))

;;;; Commands the user runs

;;;###autoload
(defun drgnx-runners-cloud-setup (cap regions sizes credentials)
  "Set up cloud runners: a monthly CAP in dollars (typed; empty is refused), the REGIONS and machine SIZES (comma
separated) and the CREDENTIALS source.  The hub then pre-flights the account and asks for your confirm before the first
machine starts: nothing starts here."
  (interactive
   (list (read-string "Monthly cloud cap in dollars (required): ")
         (read-string "Regions: " drgnx-runners-cloud-default-regions)
         (read-string "Machine sizes: " drgnx-runners-cloud-default-sizes)
         (completing-read "Credentials from: " drgnx-runners-cloud-credential-sources nil t nil nil
                          (car drgnx-runners-cloud-credential-sources))))
  (let ((n (drgnx-runners-cloud--cap cap)))
    (drgnx-hub-ensure)
    (drgnx-hub-call "runners/cloud/setup"
                    (list :cap n :regions (drgnx-runners-cloud--list regions) :sizes (drgnx-runners-cloud--list sizes)
                          :credentials credentials)
                    (lambda (_result err)
                      (message (if err "Runners: cloud setup failed: %s" "Runners: cloud is set up; the hub checks the account next%.0s") err))
                    :deadline 120)))

;;;###autoload
(defun drgnx-runners-cloud-confirm ()
  "Say yes to \"Start the first cloud machine\": the projection and the pre-flight lines are on the card."
  (interactive)
  (when (yes-or-no-p "Start the first cloud machine as the card describes (it costs money)? ")
    (drgnx-hub-ensure)
    (drgnx-hub-call "runners/cloud/confirm" nil
                    (lambda (_result err) (message (if err "Runners: cloud confirm failed: %s" "Runners: starting the first cloud machine%.0s") err))
                    :deadline 120)))

;;;###autoload
(defun drgnx-runners-cloud-off ()
  "Turn cloud off: every cloud machine drgnx started ends, and its images, snapshots and rule are deleted."
  (interactive)
  (when (yes-or-no-p "Turn cloud off (ends every cloud machine of ours and deletes what drgnx made)? ")
    (drgnx-hub-ensure)
    (drgnx-hub-call "runners/cloud/off" nil
                    (lambda (result err)
                      (if err (message "Runners: cloud off failed: %s" err)
                        (message "Runners: %s" (or (and (listp result) (plist-get result :report)) "cloud is off"))))
                    :deadline 300)))

;;;###autoload
(defun drgnx-runners-cloud-retry ()
  "Try the cloud credentials again, after you logged in."
  (interactive)
  (drgnx-hub-ensure)
  (drgnx-hub-call "runners/cloud/retry" nil
                  (lambda (_result err) (message (if err "Runners: cloud retry failed: %s" "Runners: cloud credentials checked%.0s") err))
                  :deadline 60))

;;;###autoload
(defun drgnx-runners-cloud-cost ()
  "Say what cloud has cost this month against the cap."
  (interactive)
  (drgnx-hub-ensure)
  (drgnx-hub-call "runners/cloud/cost" nil
                  (lambda (result err)
                    (if err (message "Runners: cloud cost failed: %s" err)
                      (message "Runners: %s" (or (drgnx-runners-cloud-strip result) "cloud is off"))))
                  :deadline 30))

;;;###autoload
(defun drgnx-runners-cloud-rotate-ca ()
  "Rotate the SSH certificate authority cloud machines trust; the confirm asks again after it."
  (interactive)
  (when (yes-or-no-p "Rotate the cloud SSH certificate authority? ")
    (drgnx-hub-ensure)
    (drgnx-hub-call "runners/cloud/rotate-ca" nil
                    (lambda (_result err) (message (if err "Runners: rotating the CA failed: %s" "Runners: the cloud CA is rotated%.0s") err))
                    :deadline 60)))

(defun drgnx-runners-cloud-define-commands ()
  "Register the cloud commands in the registry (called by tools/runners' setup)."
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((runners-cloud-setup "Runners: Set Up Cloud…" drgnx-runners-cloud-setup
                                        "Set the cap, regions, sizes and credentials for cloud runners")
                   (runners-cloud-confirm "Runners: Start the First Cloud Machine" drgnx-runners-cloud-confirm
                                          "Confirm the first cloud machine the card describes")
                   (runners-cloud-off "Runners: Turn Cloud Off" drgnx-runners-cloud-off
                                      "End every cloud machine of ours and delete what drgnx made")
                   (runners-cloud-retry "Runners: Retry Cloud" drgnx-runners-cloud-retry
                                        "Check the cloud credentials again after a login")
                   (runners-cloud-cost "Runners: Cloud Cost" drgnx-runners-cloud-cost
                                       "What cloud has cost this month against the cap")
                   (runners-cloud-rotate-ca "Runners: Rotate Cloud CA" drgnx-runners-cloud-rotate-ca
                                            "Rotate the SSH certificate authority cloud machines trust")))
    (drgnx-command-define id :category "Runners" :title title :command fn :doc doc)))

(provide 'drgnx-runners-cloud)
;;; drgnx-runners-cloud.el ends here
