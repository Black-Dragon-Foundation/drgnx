;;; drgnx-runners.el --- Module tools/runners: the runner list, the key handover and the cards -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's side of the runners (docs/guide/runners.md): the list of runners and what to do with a row, and the
;; hand-over of job keys.  The hub asks for keys with the event `runners/need-keys' (names only).  That event raises a
;; card saying what to run and does nothing else: it never reads the key store and never prompts.  Only the commands the
;; user runs (Runners: Load Keys, Runners: Add) read the store, and send the keys with `runners/keys'.  The editor keeps
;; the keys it sent in memory for the session, sends them again on every hello a hub proves, and forgets them when the
;; module is turned off.  The cards ("Log in to NAME", "benched: …", "needs your keys") are a notice source: they stand
;; while the hub's list or ask says so, and settle when it does not.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-setting)
(require 'drgnx-notice)
(require 'drgnx-hub-client)

(unless (featurep 'drgnx-runners-view)
  (load (expand-file-name "drgnx-runners-view" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(unless (featurep 'drgnx-runners-cloud)
  (load (expand-file-name "drgnx-runners-cloud" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-runners-cloud-cards "drgnx-runners-cloud")
(declare-function drgnx-runners-cloud-define-commands "drgnx-runners-cloud")
(defvar drgnx-runners-cloud--status)
(declare-function drgnx-runners-view-forget "drgnx-runners-view")
(declare-function drgnx-runners-view-define "drgnx-runners-view")
(declare-function drgnx-runners-view-runner-at "drgnx-runners-view")
(declare-function drgnx-runners-view--view "drgnx-runners-view")
(declare-function drgnx-runners-view-set "drgnx-runners-view")
(declare-function drgnx-view-attach "drgnx-view")
(defvar drgnx-runners-view-buffer-name)
(declare-function auth-source-search "auth-source")
(defvar drgnx-hub--event-conn)
(defvar auth-source-do-cache)
(defvar drgnx-runners-job-keys)
(defvar drgnx-runners-origin-key)

(drgnx-defsetting drgnx-runners-key-host "drgnx-runner-keys"
  "The host a job key is filed under in your key store (auth-source): a key named CRATES_IO_TOKEN is the entry with this
host and that user.  Read only by the commands you run (Runners: Load Keys), never by the editor on its own."
  :type 'string :group 'drgnx :scope 'global :workspace 'never :agents 'never)

;;;; The pure core: runners, and the key names the hub asked for

(defun drgnx-runners-state ()
  "A fresh state: (RUNNERS . NEEDED), the runners the hub listed last (plists) and the key names it still asks for."
  (cons nil nil))

(defun drgnx-runners-step (state event)
  "STATE after EVENT, which is (runners LIST), (need NAMES) or (sent NAMES).  Pure: STATE is not changed.
A list replaces the runners; an ask adds names; a hand-over removes the names it carried."
  (pcase event
    (`(runners ,list) (cons list (cdr state)))
    (`(need ,names) (cons (car state) (append (cdr state) (seq-difference names (cdr state) #'equal))))
    (`(sent ,names) (cons (car state) (seq-difference (cdr state) names #'equal)))
    (_ state)))

(defun drgnx-runners-cards (state)
  "The notice items (plists with :id :text) for STATE: a card per runner that waits for a login or is benched, and one
card while keys are asked for."
  (append
   (cl-loop for r in (car state)
            for name = (plist-get r :name) for st = (or (plist-get r :state) "")
            when (string-prefix-p "needs a login" st)
            collect (list :id (list 'login name)
                          :text (format "Log in to %s: run `ssh %s true` in a terminal" name (plist-get r :host)))
            when (string-prefix-p "benched" st)
            collect (list :id (list 'benched name) :text (format "%s %s" name st)))
   (when (cdr state)
     (list (list :id '(keys) :text "needs your keys: run Runners: Load Keys" :detail (string-join (cdr state) ", ")
                 :command 'runners-load-keys)))))

;;;; The editor's state

(defvar drgnx-runners--state (drgnx-runners-state) "The pure core's state (`drgnx-runners-state').")

(defvar drgnx-runners--session-keys nil
  "The job keys this editor sent the hub: an alist NAME → value, in memory only, for the session.  They go again on every
hello a hub proves (`drgnx-runners--resend') and are forgotten when the module is turned off.")

(defun drgnx-runners--needed ()
  "The key names the hub still asks for."
  (cdr drgnx-runners--state))

(defun drgnx-runners--proven-p ()
  "Whether the event being handled came on a connection to a hub that proved itself."
  (and (processp drgnx-hub--event-conn) (process-get drgnx-hub--event-conn :drgnx-proven)))

(defun drgnx-runners--publish (runners-p)
  "The cards follow the state now; with RUNNERS-P the list's rows do too."
  (when (gethash 'runners drgnx-notice--sources)
    (drgnx-notice-set 'runners (append (drgnx-runners-cards drgnx-runners--state)
                                       (drgnx-runners-cloud-cards drgnx-runners-cloud--status))))
  (when runners-p (drgnx-runners-view-set (car drgnx-runners--state))))

(defun drgnx-runners--apply (event)
  "Feed EVENT to the core and show the result."
  (setq drgnx-runners--state (drgnx-runners-step drgnx-runners--state event))
  (drgnx-runners--publish (eq (car event) 'runners)))

(defun drgnx-runners--strings (v)
  "The strings of V (a list or a vector from JSON)."
  (seq-filter #'stringp (append v nil)))

(defun drgnx-runners--event (event data)
  "`drgnx-hub-event-functions': `runners-changed' carries the list again; `runners/need-keys' (DATA (:names [NAME…]))
asks for keys.  Only for a hub that proved itself.  This runs in a process filter, a daemon path: it raises a card and
nothing else — it never reads the key store, never prompts and never calls the hub."
  (when (drgnx-runners--proven-p)
    (pcase event
      ("runners-changed" (drgnx-runners--apply (list 'runners (append (plist-get data :runners) nil))))
      ("runners/need-keys" (drgnx-runners--apply (list 'need (drgnx-runners--strings (plist-get data :names)))))
      ("runners/cloud-changed" (setq drgnx-runners-cloud--status data) (drgnx-runners--publish nil)))))

;;;; The key handover: only in commands the user ran

(defun drgnx-runners--read-key (name)
  "The value of the job key NAME from the key store (auth-source: host `drgnx-runners-key-host', user NAME), or nil.
The store may ask for a passphrase: call it only from a command the user ran."
  (when inhibit-interaction (error "drgnx: the key store is read only by a command you run"))
  (require 'auth-source)
  (let* ((auth-source-do-cache nil)
         (found (car (auth-source-search :host drgnx-runners-key-host :user name :max 1 :create nil)))
         (secret (plist-get found :secret))
         (value (if (functionp secret) (funcall secret) secret)))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun drgnx-runners--keys-params (keys)
  "The params of `runners/keys' for KEYS, an alist NAME → value."
  (list :keys (cl-loop for (name . value) in keys append (list (intern (concat ":" name)) value))))

(defun drgnx-runners--send (keys)
  "Send KEYS (an alist NAME → value) to the hub with `runners/keys'.  Once the hub took them they are kept for the
session and the cards for their names settle; a refusal keeps the cards."
  (drgnx-hub-call "runners/keys" (drgnx-runners--keys-params keys)
                  (lambda (_result err)
                    (if err
                        (message "Runners: the hub did not take the keys: %s" err)
                      (dolist (k keys) (setf (alist-get (car k) drgnx-runners--session-keys nil nil #'equal) (cdr k)))
                      (drgnx-runners--apply (list 'sent (mapcar #'car keys)))))))

(defun drgnx-runners--resend ()
  "`drgnx-hub-connected-functions': a hub proved itself, and it keeps keys in memory only: send the kept keys again.
The key store is not read."
  (when drgnx-runners--session-keys
    (drgnx-hub-call "runners/keys" (drgnx-runners--keys-params drgnx-runners--session-keys) #'ignore)))

(defun drgnx-runners--listed-names ()
  "The key names the current project lists: its job keys and its origin key."
  (delq nil (append drgnx-runners-job-keys (list drgnx-runners-origin-key))))

(defun drgnx-runners--load (names)
  "Read NAMES from the key store and send what is found: the names found.  A command's job."
  (let (found)
    (dolist (n names)
      (when-let* ((v (drgnx-runners--read-key n))) (push (cons n v) found)))
    (setq found (nreverse found))
    (when found (drgnx-runners--send found))
    (mapcar #'car found)))

;;;###autoload
(defun drgnx-runners-load-keys ()
  "Read the keys the hub asked for (else the keys this project lists) from your key store and hand them to the hub,
which keeps them in memory for the jobs that name them.  The store may ask for a passphrase: this is the command that
may.  Nothing else in drgnx reads it for the runners."
  (interactive)
  (let ((names (or (drgnx-runners--needed) (drgnx-runners--listed-names))))
    (unless names (user-error "No job keys to load: the hub asked for none and this project lists none (drgnx-runners-job-keys)"))
    (drgnx-hub-ensure)
    (let* ((found (drgnx-runners--load names)) (missing (seq-difference names found #'equal)))
      (cond ((null found) (user-error "No key found in the key store for %s (host %s)" (string-join missing ", ") drgnx-runners-key-host))
            (missing (message "Runners: sent %s; not in the key store: %s" (string-join found ", ") (string-join missing ", ")))
            (t (message "Runners: sent %s" (string-join found ", ")))))))

;;;; The list and its row actions

(defvar drgnx-runners-mode-map (make-sparse-keymap) "Keys come from the key profiles (commands `runners-check' …).")

(define-derived-mode drgnx-runners-mode special-mode "Runners"
  "Your runners, one row each: the commands act on the row at point.  \\`g' reads the list again."
  (setq-local revert-buffer-function (lambda (&rest _) (drgnx-runners--refresh))))

(defun drgnx-runners--refresh ()
  "Ask the hub for the runners; the answer is the list's rows and the cards' source."
  (condition-case err
      (drgnx-hub-call "runners/list" nil
                      (lambda (result e)
                        (unless e (drgnx-runners--apply (list 'runners (append (plist-get result :runners) nil))))))
    (error (message "Runners: %s" (error-message-string err)))))

;;;###autoload
(defun drgnx-runners-show ()
  "Show the Runners list: every machine that runs your jobs, its state and what it is doing."
  (interactive)
  (drgnx-hub-ensure)
  (let ((buffer (get-buffer-create drgnx-runners-view-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-runners-mode) (drgnx-runners-mode))
      (unless (drgnx-runners-view--view) (drgnx-view-attach 'runners-list))
      (drgnx-runners-view-set (car drgnx-runners--state)))
    (drgnx-runners--refresh)
    (pop-to-buffer buffer)))

(defun drgnx-runners--at-point ()
  "The name of the runner on this row, or a user error."
  (or (plist-get (drgnx-runners-view-runner-at) :name) (user-error "No runner on this row")))

(defun drgnx-runners--act (method params what)
  "Call METHOD with PARAMS, then say WHAT and read the list again."
  (drgnx-hub-call method params
                  (lambda (_result err)
                    (if err (message "Runners: %s failed: %s" what err)
                      (message "Runners: %s" what)
                      (drgnx-runners--refresh)))
                  :deadline 120))

(defun drgnx-runners-check ()
  "Check the runner on this row now: its probe, its contract and a canary."
  (interactive)
  (let ((name (drgnx-runners--at-point))) (drgnx-runners--act "runners/check" (list :name name) (format "checked %s" name))))

(defun drgnx-runners-bench ()
  "Take the runner on this row out of rotation: no job is placed there until it is unbenched."
  (interactive)
  (let ((name (drgnx-runners--at-point))) (drgnx-runners--act "runners/bench" (list :name name) (format "benched %s" name))))

(defun drgnx-runners-unbench ()
  "Put the benched runner on this row back in rotation at once."
  (interactive)
  (let ((name (drgnx-runners--at-point))) (drgnx-runners--act "runners/unbench" (list :name name) (format "%s is back" name))))

(defun drgnx-runners-trust ()
  "Set what the runner on this row may see of your work: mine, my-cloud or shared."
  (interactive)
  (let* ((name (drgnx-runners--at-point))
         (trust (completing-read (format "Trust for %s: " name) '("mine" "my-cloud" "shared") nil t)))
    (drgnx-runners--act "runners/set" (list :name name :trust trust) (format "%s is %s" name trust))))

(defun drgnx-runners-accept ()
  "Set which jobs the runner on this row takes: all of them, or only the heavy ones."
  (interactive)
  (let* ((name (drgnx-runners--at-point))
         (accept (completing-read (format "Jobs %s takes: " name) '("all" "heavy") nil t)))
    (drgnx-runners--act "runners/set" (list :name name :accept accept) (format "%s takes %s jobs" name accept))))

(defun drgnx-runners-remove ()
  "Remove the runner on this row: its units and containers there stop and its folder is deleted."
  (interactive)
  (let ((name (drgnx-runners--at-point)))
    (when (yes-or-no-p (format "Remove runner %s (stops our units and containers there, deletes its folder)? " name))
      (drgnx-runners--act "runners/remove" (list :name name :confirm t) (format "removed %s" name)))))

(defun drgnx-runners-show-log ()
  "Show what the hub knows of the runner on this row: its state, strikes and last strike."
  (interactive)
  (let ((r (drgnx-runners-view-runner-at)))
    (unless r (user-error "No runner on this row"))
    (with-current-buffer (get-buffer-create (format "*drgnx Runner %s*" (plist-get r :name)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s\n\nstate: %s\nstrikes: %s\nlast strike: %s\nhost: %s\n"
                        (plist-get r :name) (plist-get r :state) (or (plist-get r :strikes) 0)
                        (or (plist-get r :last_strike) "none") (plist-get r :host))))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

;;;###autoload
(defun drgnx-runners-add (host trust)
  "Add the machine HOST (as your ssh knows it) as a runner of TRUST: mine, my-cloud or shared.  When this project lists job
keys and the runner may have them, they are read from your key store first (this command may ask for a passphrase)."
  (interactive (list (read-string "Host (as ssh knows it): ")
                     (completing-read "Trust: " '("mine" "my-cloud" "shared") nil t nil nil "mine")))
  (drgnx-hub-ensure)
  (when (and (not (equal trust "shared")) (drgnx-runners--listed-names))
    (drgnx-runners--load (seq-difference (drgnx-runners--listed-names) (mapcar #'car drgnx-runners--session-keys) #'equal)))
  (message "Runners: adding %s (probe, copy, image, bench)…" host)
  (drgnx-runners--act "runners/add" (list :host host :trust trust) (format "added %s" host)))

;;;; A Mac as a runner

(defconst drgnx-runners-mac-steps
  "Prepare the Mac once, in your own account there (drgnx never runs sudo on it):

1. Create a standard account named drgnx-runner (System Settings, Users & Groups; not an administrator).
   Jobs run as that account, so your own files and keychain stay out of their reach.
2. Turn on Remote Login for that account only (System Settings, General, Sharing, Remote Login,
   \"Only these users\"), and put this machine's ssh key in ~drgnx-runner/.ssh/authorized_keys.
3. Install the Command Line Tools (xcode-select --install), mise (brew install mise) and the Homebrew
   packages your projects list in drgnx-runners-mac-tools, in your own account: the runner never installs
   into Homebrew.  The toolchains your projects pin in drgnx-runners-mac-toolchains (rust@1.95) the runner
   installs itself, through your mise, into its own folder.
4. If the Mac is not on this machine's network, reach it through tailscaled, the open-source Tailscale
   daemon (brew install tailscale), or any VPN your ssh can use.

Then add it: Runners: Add Runner…, host drgnx-runner@YOUR-MAC.  The runner refuses a Mac that lacks
something and names the fix."
  "The steps that make a Mac ready to be a runner, as the onboarding card shows them (docs/guide/runners.md).")

(defun drgnx-runners-add-mac ()
  "Show how to prepare a Mac as a runner, then ask for its host and add it as yours (`mine')."
  (interactive)
  (with-help-window "*drgnx Mac Runner*"
    (princ drgnx-runners-mac-steps))
  (let ((host (read-string "Mac host (drgnx-runner@your-mac), empty to stop: ")))
    (unless (string-empty-p host)
      (drgnx-runners-add host "mine"))))

;;;; The module

(defun drgnx-runners--setup ()
  "tools/runners' `:setup': the view type, the notice source, the hub hooks and the commands."
  (drgnx-runners-view-define)
  (drgnx-runners-cloud-define-commands)
  (drgnx-notice-define-source 'runners :title "Runners" :command 'runners-load-keys)
  (add-hook 'drgnx-hub-event-functions #'drgnx-runners--event)
  (add-hook 'drgnx-hub-connected-functions #'drgnx-runners--resend)
  (add-hook 'drgnx-hub-connected-functions #'drgnx-runners--refresh)
  (pcase-dolist (`(,id ,title ,fn ,doc ,global)
                 '((runners "Show Runners" drgnx-runners-show "Your runners: the machines that run your jobs" t)
                   (runners-add "Add Runner…" drgnx-runners-add "Add a machine as a runner of your jobs" t)
                   (runners-add-mac "Add Mac Runner…" drgnx-runners-add-mac
                                    "Prepare a Mac as a runner (its own account, Remote Login), then add it" t)
                   (runners-load-keys "Load Keys" drgnx-runners-load-keys
                                      "Hand the job keys the hub asks for from your key store to the hub" t)
                   (runners-check "Check Runner" drgnx-runners-check "Check the runner on this row now" nil)
                   (runners-bench "Bench Runner" drgnx-runners-bench "Take the runner on this row out of rotation" nil)
                   (runners-unbench "Unbench Runner" drgnx-runners-unbench "Put the runner on this row back in rotation" nil)
                   (runners-trust "Set Runner Trust…" drgnx-runners-trust "Set what the runner on this row may see" nil)
                   (runners-accept "Set Runner Jobs…" drgnx-runners-accept "Set which jobs the runner on this row takes" nil)
                   (runners-remove "Remove Runner" drgnx-runners-remove "Remove the runner on this row and its folder there" nil)
                   (runners-show-log "Show Runner Log" drgnx-runners-show-log "What the hub knows of the runner on this row" nil)))
    (if global
        (drgnx-command-define id :category "Runners" :title title :command fn :doc doc)
      (drgnx-command-define id :category "Runners" :title title :command fn :doc doc :map 'drgnx-runners-mode-map
                            :when (lambda () (derived-mode-p 'drgnx-runners-mode))))))

(defun drgnx-runners--teardown ()
  "tools/runners' `:teardown': the editor forgets the keys it kept, and the list's rows."
  (setq drgnx-runners--session-keys nil
        drgnx-runners-cloud--status nil
        drgnx-runners--state (drgnx-runners-state))
  (drgnx-runners-view-forget))

(drgnx-module-define 'tools/runners
                     :doc "Runners: the list of your other machines that run jobs, the key handover and the cards."
                     :stage 'startup :requires '(core/workbench)
                     :setup #'drgnx-runners--setup :teardown #'drgnx-runners--teardown)

(provide 'drgnx-runners)
;;; drgnx-runners.el ends here
