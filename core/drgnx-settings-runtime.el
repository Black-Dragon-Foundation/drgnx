;;; drgnx-settings-runtime.el --- Settings: the editor's override sender to the runtime -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 22 (design §11.1).  The hub reads `settings.el' itself.  What it cannot read is what your Lisp,
;; Customize or a workspace decided: the editor sends that, per project, as `config/settings' (the whole set each
;; time; an empty list clears it), and says `config/changed' after a write so the hub looks at settings.el's stamp.
;; Values go as JSON of the setting's runtime type (`:runtime' of `drgnx-defsetting'; docs/develop/hub.md, "Settings").
;; A provider carries no key.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-settings-prov)
(require 'drgnx-settings-workspace)
(require 'drgnx-settings-live)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-notify "drgnx-notice")
(declare-function drgnx-settings-explain "drgnx-settings-prov" (var &optional buffer))
(declare-function drgnx-setting-for-root "drgnx-settings-workspace" (var root))
(declare-function drgnx-settings-workspace-project "drgnx-settings-workspace" (dir))
(declare-function drgnx-settings-live--global-p "drgnx-settings-live" (file))
(defvar drgnx-hub--events)
(defvar drgnx-hub--behind-front)
(defvar drgnx-settings-changed-functions)
(defvar drgnx-settings-file-written-functions)

;;;; Encoding: Lisp values as the runtime types' JSON

(defun drgnx-settings-runtime--str (x)
  "X (a symbol or a string) as a string; nil stays nil."
  (if (and x (symbolp x)) (symbol-name x) x))

(defun drgnx-settings-runtime--key (name)
  "NAME (a symbol or a string) as the keyword `json-serialize' takes for an object key."
  (intern (concat ":" (drgnx-settings-runtime--str name))))

(defun drgnx-settings-runtime--strings (xs)
  "The list XS of symbols and strings as a vector of strings."
  (vconcat (mapcar #'drgnx-settings-runtime--str xs)))

(defun drgnx-settings-runtime--bool (x) (if x t :false))

(defun drgnx-settings-runtime--plist (pairs)
  "PAIRS, a list of (KEY . VALUE), as a plist without the pairs whose VALUE is nil."
  (cl-loop for (k . v) in pairs when v append (list k v)))

(defun drgnx-settings-runtime--provider (p)
  "A provider's plist P (:name :kind :url :key-env :caps :price :messages :auth) as `ProviderEntry' takes it."
  (let ((price (plist-get p :price)))
    (drgnx-settings-runtime--plist
     (list (cons :name (plist-get p :name))
           (cons :kind (drgnx-settings-runtime--str (plist-get p :kind)))
           (cons :url (plist-get p :url))
           (cons :key_env (plist-get p :key-env))
           (cons :caps (and (plist-get p :caps)
                            (drgnx-settings-runtime--strings (delete-dups (copy-sequence (plist-get p :caps))))))
           (cons :price (and (consp price) (numberp (car price)) (numberp (cdr price)) (vector (car price) (cdr price))))
           (cons :messages (and (plist-get p :messages) t))
           (cons :auth (drgnx-settings-runtime--str (plist-get p :auth)))))))

(defun drgnx-settings-runtime--profile (p)
  "An agent profile's plist P as `AgentProfile' takes it."
  (drgnx-settings-runtime--plist
   (list (cons :command (vconcat (plist-get p :command)))
         (cons :env (and (plist-get p :env) (vconcat (plist-get p :env))))
         (cons :mode (drgnx-settings-runtime--str (plist-get p :mode)))
         (cons :ai (drgnx-settings-runtime--str (plist-get p :ai)))
         (cons :model (plist-get p :model))
         (cons :tracker_tools (drgnx-settings-runtime--str (plist-get p :tracker-tools)))
         (cons :doc (plist-get p :doc))
         (cons :job_safe (and (plist-get p :job-safe) t)))))

(defun drgnx-settings-runtime--alist (alist fn)
  "ALIST (KEY . VALUE)… as an object: KEY → (FN VALUE), in order."
  (cl-loop for (k . v) in alist append (list (drgnx-settings-runtime--key k) (funcall fn v))))

(defun drgnx-settings-runtime--chain (step)
  "A role chain's STEP, (PROVIDER . MODEL) or (PROVIDER), as `{provider, model?}'."
  (let ((model (and (consp step) (cdr step))))
    (append (list :provider (drgnx-settings-runtime--str (if (consp step) (car step) step)))
            (and (stringp model) (list :model model)))))

(defconst drgnx-settings-runtime--encoders
  `((drgnx-ai-providers . ,(lambda (v) (drgnx-settings-runtime--alist v #'drgnx-settings-runtime--provider)))
    (drgnx-ai-roles . ,(lambda (v)
                         (vconcat (mapcar (lambda (r)
                                            (list :role (drgnx-settings-runtime--str (car r))
                                                  :chain (vconcat (mapcar #'drgnx-settings-runtime--chain (cdr r)))))
                                          v))))
    (drgnx-agents-profiles . ,(lambda (v) (drgnx-settings-runtime--alist v #'drgnx-settings-runtime--profile)))
    (drgnx-agents-default . ,(lambda (v) (or (drgnx-settings-runtime--str v) :null)))
    (drgnx-agents-mcp . drgnx-settings-runtime--strings)
    (drgnx-agents-routes . ,(lambda (v)
                              (drgnx-settings-runtime--alist
                               v (lambda (profiles)
                                   (drgnx-settings-runtime--strings (if (listp profiles) profiles (list profiles)))))))
    (drgnx-agents-openrouter
     . ,(lambda (v)
          (if (null v) :null
            (drgnx-settings-runtime--plist
             (list (cons :only (and (plist-get v :only) (drgnx-settings-runtime--strings (plist-get v :only))))
                   (cons :ignore (and (plist-get v :ignore) (drgnx-settings-runtime--strings (plist-get v :ignore))))
                   (cons :data_collection (drgnx-settings-runtime--str (plist-get v :data-collection)))
                   (cons :zdr (and (plist-member v :zdr) (drgnx-settings-runtime--bool (plist-get v :zdr)))))))))
    (drgnx-agents-allow-unsandboxed . drgnx-settings-runtime--bool))
  "Runtime setting → the function that turns its Lisp value into the JSON of its runtime type.")

(defun drgnx-settings-runtime--vars ()
  "The settings declared `:runtime' that this editor can encode."
  (cl-remove-if-not (lambda (v) (and (assq v drgnx-settings-runtime--encoders) (plist-get (drgnx-setting-meta v) :runtime)))
                    (drgnx-setting-names)))

(defun drgnx-settings-runtime--override (var value source)
  "The override of VAR to VALUE (a Lisp value), from SOURCE."
  (list :name (symbol-name var)
        :value (funcall (alist-get var drgnx-settings-runtime--encoders) value)
        :source (truncate-string-to-width source 256)))

;;;; What to send

(defconst drgnx-settings-runtime--editor-kinds '(customize lisp deferred use-package package session theme unknown)
  "The kinds of winner that are not settings.el, the default or a module: what the hub cannot read for itself.")

(defun drgnx-settings-runtime-overrides (&optional root)
  "The overrides to send, a list of (:name :value :source): for each `:runtime' setting, one when `drgnx-settings-explain'
says the value in effect comes from your Lisp or Customize and not from settings.el.  With ROOT, the ones a
workspace of ROOT (W1, W2) sets instead (`drgnx-setting-for-root' differs from the global value)."
  (let (out)
    (dolist (var (drgnx-settings-runtime--vars))
      (if root
          (let ((global (default-value var)) (here (drgnx-setting-for-root var root)))
            (unless (equal global here)
              (push (drgnx-settings-runtime--override var here "workspace") out)))
        (let ((e (with-temp-buffer (drgnx-settings-explain var (current-buffer)))))
          (when (memq (plist-get e :kind) drgnx-settings-runtime--editor-kinds)
            (push (drgnx-settings-runtime--override
                   var (default-value var)
                   (if (plist-get e :file) (concat "lisp:" (file-name-nondirectory (plist-get e :file))) "lisp"))
                  out)))))
    (nreverse out)))

(defun drgnx-settings-runtime--answered (_result err)
  "The hub's answer to `config/settings': a refusal is one notice."
  (when err (drgnx-notify 'hub 'warn (format "drgnx hub: the runtime settings were refused: %s" err) :id 'runtime-settings)))

(defun drgnx-settings-runtime-send (&optional root)
  "Send the hub the overrides (`drgnx-settings-runtime-overrides') as `config/settings': the global set, or ROOT's
project's (nothing until Urdr names ROOT's project).  The call's id, or nil."
  (let ((project (and root (car-safe (drgnx-settings-workspace-project root)))))
    (unless (and root (not project))
      (drgnx-hub-call "config/settings"
                      (append (and project (list :project project))
                              (list :overrides (vconcat (drgnx-settings-runtime-overrides root))))
                      #'drgnx-settings-runtime--answered))))

(defun drgnx-settings-runtime--live-p ()
  "Non-nil in an editor subscribed to a hub that proved itself: the only place settings go on a change."
  ;; the hub client may not be loaded: its variables are unbound then
  (let ((events (bound-and-true-p drgnx-hub--events)))
    (and (not (bound-and-true-p drgnx-hub--behind-front)) (process-live-p events) (process-get events :drgnx-proven))))

(defun drgnx-settings-runtime-changed ()
  "settings.el may have changed: the hub looks at its stamp (`config/changed')."
  (drgnx-hub-call "config/changed" nil #'drgnx-settings-runtime--answered))

(defun drgnx-settings-runtime--settings-changed (file _changes)
  "On `drgnx-settings-changed-functions': a connected editor sends the set again, and says so when FILE is settings.el."
  (when (drgnx-settings-runtime--live-p)
    (drgnx-settings-runtime-send)
    (when (drgnx-settings-live--global-p file) (drgnx-settings-runtime-changed))))

(defun drgnx-settings-runtime--written (file _before _after)
  "On `drgnx-settings-file-written-functions': after a write of settings.el the hub is told (`config/changed')."
  (when (and (drgnx-settings-runtime--live-p) (drgnx-settings-live--global-p file))
    (drgnx-settings-runtime-changed)))

(defun drgnx-settings-runtime-project-opened (root)
  "A project at ROOT opened: a connected editor sends the overrides its workspace files set."
  (when (drgnx-settings-runtime--live-p) (drgnx-settings-runtime-send root)))

(add-hook 'drgnx-settings-changed-functions #'drgnx-settings-runtime--settings-changed)
(add-hook 'drgnx-settings-file-written-functions #'drgnx-settings-runtime--written)

(provide 'drgnx-settings-runtime)
;;; drgnx-settings-runtime.el ends here
