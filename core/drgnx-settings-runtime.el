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
(require 'drgnx-config)
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
(defvar drgnx-settings-changed-functions)
(defvar drgnx-settings-file-written-functions)

;;;; Settings the runtime reads

(drgnx-defsetting drgnx-sandbox-memory-max "4G"
  "The memory cap of each sandboxed agent, the `:memory-max' of a spec that does not give one: a systemd size (4G,
512M, 50%) or nil for none.  It applies where a systemd user manager answers.  An
operational guard, so that one agent's build cannot run the session out of memory; not a security boundary."
  :type '(choice (const :tag "No cap" nil) string) :group 'drgnx :scope 'global :workspace 'never :agents 'never)

(drgnx-defsetting drgnx-sandbox-secret-files
  '(".npmrc" "etc/npmrc" ".yarnrc" ".yarnrc.yml" ".pypirc" ".netrc" ".git-credentials" ".env" "credentials"
    "credentials.toml" "credentials.json" "auth.json")
  "Where package managers keep tokens, relative to a toolchain root: each that exists inside a toolchain root is
hidden in the sandbox.  npm's global config is PREFIX/etc/npmrc."
  :type '(repeat string) :group 'drgnx :scope 'global :workspace 'never :agents 'never)

(drgnx-defsetting drgnx-sandbox-proxy-pinned-addresses nil
  "Names the agents' proxies resolve to a fixed address instead of asking DNS: ((NAME . ADDRESS)…), ADDRESS an IPv4
or IPv6 literal.  A pinned name may lead to a private or loopback address (a registry on the company's network, a
test's local upstream); a name resolved through DNS never does.  Pinning only resolves: the name must still be on the
allowlist.  The hub pins them in each session's provider proxy and each container job's proxy."
  :type '(alist :key-type string :value-type string) :group 'drgnx :scope 'global :workspace 'never :agents 'never
  :runtime "ProxyPins")

(drgnx-defsetting drgnx-search-model-mirror nil
  "Where embedding models are downloaded from: a URL laid out as the Hugging Face host, or nil for that host."
  :type '(choice (const :tag "Hugging Face" nil) string) :group 'drgnx :scope 'global :workspace 'never
  :on-error 'strict :agents 'never :runtime "Option<String>" :schema '(or null string))

(drgnx-defsetting drgnx-search-builtin t
  "Non-nil: the built-in embedding model indexes every project's code and your tasks and notes, whatever servers are
running.  Nil: only a running server (TEI, Ollama) makes vectors, and with none, search is keyword and symbol only."
  :type 'boolean :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "bool" :schema 'boolean)

;; What a project's semantic search indexes: the hub (Hrafn) reads `.drgnx/search.eld' itself and takes the per-project
;; values of these settings from the editor (`config/settings'), so a file narrows what the settings left.
(drgnx-config-define 'search-project
                     :dir 'project :file "search.eld"
                     :schema '(plist (:include (list-of string)) (:exclude (list-of string)) (:off boolean))
                     :doc "Narrows what a project's semantic search indexes: only these globs, not these, or off.")

(defun drgnx-search--globs-p (x)
  "Non-nil when X is a list of strings (globs): safe from any workspace, since it can only narrow the list."
  (and (proper-list-p x) (cl-every #'stringp x)))

(drgnx-defsetting drgnx-search-include nil
  "Only files matching one of these globs are indexed (nil: all)."
  :type '(repeat string) :group 'drgnx :safe #'drgnx-search--globs-p :scope 'project
  :on-error 'strict :agents 'never :runtime "Vec<String>" :schema '(list-of string))

(drgnx-defsetting drgnx-search-exclude nil
  "Files matching one of these globs are not indexed; a workspace's are added to yours."
  :type '(repeat string) :group 'drgnx :safe #'drgnx-search--globs-p :scope 'project :merge 'append
  :on-error 'strict :agents 'never :runtime "Vec<String>" :schema '(list-of string))

(drgnx-defsetting drgnx-search-off nil
  "Non-nil turns a project's semantic search off."
  :type 'boolean :group 'drgnx :safe #'booleanp :scope 'project
  :on-error 'strict :agents 'never :runtime "bool" :schema 'boolean)

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
    (drgnx-agents-allow-unsandboxed . drgnx-settings-runtime--bool)
    (drgnx-search-builtin . drgnx-settings-runtime--bool)
    (drgnx-search-include . drgnx-settings-runtime--strings)
    (drgnx-search-exclude . drgnx-settings-runtime--strings)
    (drgnx-search-off . drgnx-settings-runtime--bool)
    (drgnx-agents-start-env-names . drgnx-settings-runtime--strings)
    (drgnx-agents-trace-opens . drgnx-settings-runtime--strings)
    ;; the agent limits (`drgnx-agents-matrix.el'); the matrix itself is read from settings.el alone
    (drgnx-agents-away-after . identity)
    (drgnx-agents-wait-refusals . identity)
    (drgnx-agents-close-idle-after . identity)
    (drgnx-agents-checkpoint-cap . identity)
    (drgnx-agents-job-memory . identity)
    (drgnx-agents-job-cpus . identity)
    (drgnx-agents-net-hosts . ,(lambda (v) (drgnx-settings-runtime--alist v #'drgnx-settings-runtime--strings)))
    (drgnx-agents-container-images . ,(lambda (v) (drgnx-settings-runtime--alist v #'identity)))
    (drgnx-agents-silent-after . ,(lambda (v) (drgnx-settings-runtime--alist v #'identity)))
    (drgnx-agents-repeat-limit . identity)
    (drgnx-agents-no-progress-tokens . identity)
    (drgnx-agents-manager-context . identity)
    ;; the runners' per-project settings (`drgnx-agents-matrix.el') and Hrafn's model mirror
    (drgnx-runners-send . drgnx-settings-runtime--str)
    (drgnx-runners-heavy . drgnx-settings-runtime--strings)
    (drgnx-runners-image . ,(lambda (v) (or (drgnx-settings-runtime--str v) :null)))
    (drgnx-runners-weight . identity)
    (drgnx-runners-project-visibility . drgnx-settings-runtime--str)
    (drgnx-search-model-mirror . ,(lambda (v) (or (drgnx-settings-runtime--str v) :null)))
    (drgnx-sandbox-proxy-pinned-addresses . ,(lambda (v) (drgnx-settings-runtime--alist v #'identity))))
  "Runtime setting → the function that turns its Lisp value into the JSON of its runtime type.  `drgnx-agents-matrix'
has none: the hub reads its plist from settings.el alone.")

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
          ;; the hub takes a project override of a `:scope project' setting only
          (when (eq (plist-get (drgnx-setting-meta var) :scope) 'project)
            (let ((global (default-value var)) (here (drgnx-setting-for-root var root)))
              (unless (equal global here)
                (push (drgnx-settings-runtime--override var here "workspace") out))))
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
    (and (process-live-p events) (process-get events :drgnx-proven))))

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
