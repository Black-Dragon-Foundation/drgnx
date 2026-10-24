;;; dump.el --- the editor's side of the hub's settings conformance -*- lexical-binding: t -*-
;; What the editor reads of settings/runtime-defaults.el and of providers-settings.el, and which settings it declares
;; `:runtime', as JSON for the hub's tests (runtime/crates/drgnx-ratatoskr/src/settings/conformance.rs).  Batch, in
;; a Nidhogg container (the f45 dev image), from the checkout:
;;
;;   emacs --batch -Q -L core -L wb -L harness -L modules/tools -L modules/editor -L modules/ui \
;;     -l test/conformance/settings/dump.el --eval '(drgnx-settings-dump-write "test/conformance/settings/lisp-dump.json")'
;;
;; It writes one JSON object:
;; - `defaults': each entry of runtime-defaults.el as the editor reads it (`drgnx-settings-defaults-all'), in the
;;   canonical dump of test/fixtures/huginn/README.md;
;; - `counts': how many presets, built-in profiles and default roles the editor's constants hold;
;; - `providers': the provider table `drgnx-settings-dump--providers-table' gives for providers-settings.el's
;;   `drgnx-ai-providers';
;; - `runtime': [NAME TYPE ON-ERROR] of every declared setting with a `:runtime' type, sorted by name (ON-ERROR
;;   `strict', else `last-good').
;; test/unit/settings-runtime-dump-test.el runs this very command and compares with the committed file.
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-settings-file)
(require 'drgnx-settings-defaults)
(require 'drgnx-settings-doc)
(require 'drgnx-ai)
(require 'drgnx-agents)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/huginn/gen.el" drgnx-dir) nil t)

(defconst drgnx-settings-dump-dir (file-name-directory (or load-file-name buffer-file-name))
  "This folder: test/conformance/settings/.")

(defun drgnx-settings-dump--provider-json (id p)
  "Provider ID (its entry P) as the hub's provider table has it — (:id :kind :base :auth :messages :caps [:price]) —
or nil when it cannot be one (no URL, a kind the hub does not know).  The reference the hub's table is compared with;
the editor no longer sends this form (it sends `ProviderEntry' overrides, `drgnx-settings-runtime-overrides')."
  (let ((kind (plist-get p :kind)) (url (plist-get p :url)) (price (plist-get p :price)))
    (when (and (memq kind '(openai ollama llamacpp tei anthropic)) (stringp url))
      (append (list :id (symbol-name id) :kind (symbol-name kind) :base url
                    :auth (cond ((not (plist-get p :key-env)) "none") ((eq (plist-get p :auth) 'x-api-key) "x-api-key") (t "bearer"))
                    :messages (if (plist-get p :messages) t :false)
                    :caps (vconcat (mapcar #'symbol-name (cl-remove-if-not (lambda (c) (memq c '(chat fim embed)))
                                                                           (delete-dups (copy-sequence (plist-get p :caps)))))))
              (and (consp price) (numberp (car price)) (numberp (cdr price))
                   (list :price (list :input (car price) :output (cdr price))))))))

(defun drgnx-settings-dump--providers-table ()
  "The effective providers (the presets and `drgnx-ai-providers') as `drgnx-settings-dump--provider-json' has them."
  (vconcat (delq nil (mapcar (lambda (e) (drgnx-settings-dump--provider-json (car e) (cdr e))) (drgnx-ai-providers)))))

(defun drgnx-settings-dump--providers ()
  "The editor's provider table for providers-settings.el's `drgnx-ai-providers'."
  (let* ((doc (drgnx-settings-file-read (expand-file-name "providers-settings.el" drgnx-settings-dump-dir)
                                        'drgnx-settings))
         (entry (cl-find 'drgnx-ai-providers (drgnx-settings-doc-entries doc) :key #'drgnx-settings-entry-var))
         (old (default-value 'drgnx-ai-providers)))
    (unless entry (error "providers-settings.el has no drgnx-ai-providers"))
    (unwind-protect
        (progn (set-default 'drgnx-ai-providers (drgnx-settings-entry-value entry))
               (drgnx-settings-dump--providers-table))
      (set-default 'drgnx-ai-providers old))))

(defun drgnx-settings-dump--runtime ()
  "[NAME TYPE ON-ERROR] of each declared `:runtime' setting, sorted by name."
  (drgnx-settings-doc-load)
  (let (rows)
    (dolist (var (drgnx-setting-names))
      (let ((meta (drgnx-setting-meta var)))
        (when (plist-get meta :runtime)
          (push (vector (symbol-name var) (plist-get meta :runtime)
                        (if (eq (plist-get meta :on-error) 'strict) "strict" "last-good"))
                rows))))
    (vconcat (sort rows (lambda (a b) (string< (aref a 0) (aref b 0)))))))

(defun drgnx-settings-dump-json ()
  "The dump, as one line of JSON."
  (decode-coding-string
   (json-serialize
    (list :defaults (mapcar (lambda (cell) (cons (car cell) (huginn-gen--tree (cdr cell))))
                            (drgnx-settings-defaults-all))
          :counts (list :presets (length drgnx-ai-presets) :profiles (length drgnx-agents-builtin-profiles)
                        :roles (length drgnx-ai-default-roles))
          :providers (drgnx-settings-dump--providers)
          :runtime (drgnx-settings-dump--runtime)))
   'utf-8-unix))

(defun drgnx-settings-dump-write (file)
  "Write the dump to FILE (relative: to the checkout)."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (concat (drgnx-settings-dump-json) "\n") nil (expand-file-name file drgnx-dir) nil 'silent)))

;;; dump.el ends here
