;;; agents-matrix-test.el --- batch tests: the matrix setting and the away signal -*- lexical-binding: t -*-
;; The ids the setting accepts are the hub's (read from the protocol's golden file); the away signal is driven with
;; a fake idle time and a recorded `drgnx-hub-call', never a hub.
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-setting)
(require 'drgnx-schema)
(require 'drgnx-agents-matrix)
(require 'drgnx-hub-client)
(require 'drgnx-settings-workspace)
(require 'drgnx-settings-defaults)

(defconst drgnx-agents-matrix-test--vars
  '(drgnx-agents-matrix drgnx-agents-away-after drgnx-agents-wait-refusals drgnx-agents-close-idle-after
                        drgnx-agents-checkpoint-cap drgnx-agents-job-memory drgnx-agents-job-cpus drgnx-agents-net-hosts
                        drgnx-agents-container-images drgnx-agents-silent-after drgnx-agents-repeat-limit
                        drgnx-agents-no-progress-tokens drgnx-agents-manager-context)
  "The settings of this file.")

(ert-deftest drgnx-agents-matrix/schema-ids-equal-the-hubs ()
  (let* ((golden (with-temp-buffer
                   (insert-file-contents (expand-file-name "runtime/protocol/methods.json" drgnx-dir))
                   (json-parse-buffer :object-type 'alist :array-type 'list)))
         (check (cl-find "matrix/check" (alist-get 'methods golden) :key (lambda (m) (alist-get 'name m)) :test #'equal))
         (hub (alist-get 'enum (alist-get 'Action (alist-get '$defs (alist-get 'params check))))))
    (should (> (length hub) 20))
    (should (equal (mapcar #'symbol-name drgnx-agents-matrix-actions) hub))))

(ert-deftest drgnx-agents-matrix/defaults-are-balanced ()
  (should (equal (default-value 'drgnx-agents-matrix) '(:preset balanced)))
  (should-not (drgnx-schema-check drgnx-agents-matrix-schema (default-value 'drgnx-agents-matrix)))
  (should-not (drgnx-schema-check
               drgnx-agents-matrix-schema
               '(:preset cautious :time ((:when away :preset autonomous) (:when (between 1320 420) :preset cautious))
                         :cells ((:action push.main :column (:role worker) :verdict never)
                                 (:action spend :column (:agent "claude") :verdict ask
                                          :limit (:amount 2 :unit usd))))))
  (should (drgnx-schema-check drgnx-agents-matrix-schema '(:preset wild)))
  (should (drgnx-schema-check drgnx-agents-matrix-schema '(:cells ((:action fly :column (:role worker) :verdict ask)))))
  (dolist (var drgnx-agents-matrix-test--vars)
    (should (equal (eval (car (get var 'standard-value)) t) (drgnx-settings-defaults-value var)))
    (should-not (drgnx-setting-check var (eval (car (get var 'standard-value)) t)))))

(ert-deftest drgnx-agents-matrix/a-repo-workspace-file-cannot-set-it ()
  (dolist (var drgnx-agents-matrix-test--vars)
    (let ((meta (drgnx-setting-meta var)))
      (should (drgnx-setting-own-p var))
      (should (eq (plist-get meta :workspace) 'never))
      (should (eq (plist-get meta :scope) 'global))
      (should (eq (plist-get meta :on-error) 'strict))
      (should (stringp (plist-get meta :runtime)))
      (should (string-match-p "never set by a workspace"
                              (drgnx-settings-workspace--refusal (make-drgnx-settings-entry :var var :value 1)))))))

(ert-deftest drgnx-agents-matrix/settings-change-tool-refuses-it ()
  ;; the editor's last gate refuses what is marked `:agents never' (docs/guide/agents.md, "Changing settings")
  (dolist (var drgnx-agents-matrix-test--vars)
    (should (eq (plist-get (drgnx-setting-meta var) :agents) 'never))))

(defmacro drgnx-agents-matrix-test--presence (idle &rest body)
  "BODY with a live-looking subscription, IDLE seconds of idleness (a variable BODY may `setq') and CALLS recorded."
  (declare (indent 1))
  `(let ((calls nil) (idle ,idle) (drgnx-hub--presence-sent :unknown) (drgnx-agents-away-after 600)
         (drgnx-hub--events (start-process "presence-test" nil "cat")))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-timer--idle-time) (lambda () (and idle (seconds-to-time idle))))
                   ((symbol-function 'drgnx-hub-call)
                    (lambda (method params &rest _) (push (cons method params) calls))))
           ,@body)
       (drgnx-hub--presence-stop)
       (delete-process drgnx-hub--events))))

(ert-deftest drgnx-agents-matrix/away-sent-once-per-change ()
  (drgnx-agents-matrix-test--presence 10
    (drgnx-hub--presence-start)
    (should (drgnx-timer-active-p 'hub-presence))
    (should-not calls)                  ; back, and a hub starts with you back
    (setq idle 700)
    (drgnx-hub--presence-tick)
    (drgnx-hub--presence-tick)          ; the same state again: nothing
    (should (equal calls '(("presence/set" :away t))))
    (should (drgnx-timer-active-p 'hub-presence-back))
    (setq idle 2)
    (drgnx-hub--presence-tick)
    (drgnx-hub--presence-tick)
    (should (equal (mapcar #'cdr calls) '((:away :false) (:away t))))
    (should-not (drgnx-timer-active-p 'hub-presence-back))))

(ert-deftest drgnx-agents-matrix/away-without-a-subscription-sends-nothing ()
  (drgnx-agents-matrix-test--presence 700
    (delete-process drgnx-hub--events)
    (drgnx-hub--presence-tick)
    (should-not calls)))
