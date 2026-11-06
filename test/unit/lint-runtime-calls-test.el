;;; lint-runtime-calls-test.el --- no kept file calls into the Lisp agent runtime that is deleted -*- lexical-binding: t -*-
;; test-class: det
;; The Lisp agent runtime (the hub, jobs, coordination writers and MCP, ACP, the gateway, the MCP bridge, the sandbox,
;; and the in-process half of `drgnx-agents.el') goes with its files.  What stays of it lives in kept files (the
;; coordination readers in `drgnx-coord-read.el', the agent settings in `drgnx-agents.el', ...).  This lint reads
;; `core/ modules/ wb/ harness/ settings/' with the Lisp reader (comments and strings never count) and fails on any
;; symbol that only a doomed file defines, used in a kept file, and on any `require' or `declare-function' of a doomed
;; feature.  `drgnx-agents.el' was half doomed: forms after the runtime section marker, should it come back, count as
;; doomed unless the name is on `drgnx-lint-runtime--agents-kept'.  `drgnx-lint/no-runtime-lisp' checks that the
;; runtime is gone.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx)

(defconst drgnx-lint-runtime--doomed-files
  (mapcar (lambda (n) (format "core/drgnx-%s.el" n))
          '("hub" "job" "job-snapshot" "job-worktree" "job-clash" "jobs" "coord" "coord-mcp" "acp" "gateway" "mcp-bridge"
            "sandbox" "sandbox-macos" "sandbox-mcp" "sandbox-proxy" "sandbox-relay"
            ;; Hrafn (in the hub) replaced the Lisp search, and the MCP server it was the only user of
            "mcp" "search-chunk" "search-index" "search-mcp" "search-query" "search-store"))
  "The files the runtime deletion removed whole.")

(defconst drgnx-lint-runtime--agents-marker ";;;; The agent's requests"
  "In `core/drgnx-agents.el', the line from which the forms are the runtime half unless kept.")

(defconst drgnx-lint-runtime--agents-kept
  '(drgnx-agents-get drgnx-agents--remote drgnx-agents-sessions drgnx-agents-scrubbed-env drgnx-agents-own-env
                     drgnx-agents-use-gateway drgnx-agents-env-functions drgnx-agents-answer-permission drgnx-agents-finish-review
                     drgnx-agents-send drgnx-agents-deliver-queue drgnx-agents-unqueue drgnx-agents-requeue drgnx-agents-stop
                     drgnx-agents-kill drgnx-agents-free-p drgnx-agents-deliver drgnx-agents-steer)
  "Names in the runtime half of `core/drgnx-agents.el' that stay: they ask the hub (`drgnx-agents--remote').")

(defconst drgnx-lint-runtime--agents-partial nil
  "The kept names that still carry an in-process branch after their hub branch: those forms are not scanned.  None:
each of the kept names is only its `drgnx-agents--remote' call.")

(defconst drgnx-lint-runtime--waiting nil
  "(FILE :symbols S :features F): callers of the runtime that wait for the hub method or the doctor section that
replaces them.  None: the runtime files are deleted.")

(defun drgnx-lint-runtime--waiting-p (rel kind name)
  "Whether NAME (of KIND, :symbols or :features) in the file REL is on `drgnx-lint-runtime--waiting'."
  (memq name (plist-get (cdr (assoc rel drgnx-lint-runtime--waiting)) kind)))

(defconst drgnx-lint-runtime--roots '("core" "modules" "wb" "harness" "settings"))

(defconst drgnx-lint-runtime--defining
  '(defun defmacro defsubst defvar defconst defcustom cl-defun cl-defmacro drgnx-defsetting))

(defun drgnx-lint-runtime--forms (file)
  "((START . FORM)…) of FILE: the top-level forms, START the position of each form's first character."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t
            (forward-comment (buffer-size))
            (let ((start (point)))
              (push (cons start (read (current-buffer))) forms)))
        (end-of-file nil))
      (nreverse forms))))

(defun drgnx-lint-runtime--marker (file)
  "The position of the agents marker in FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file)
    (and (search-forward drgnx-lint-runtime--agents-marker nil t) (match-beginning 0))))

(defun drgnx-lint-runtime--defined (form)
  "The symbols the top-level FORM defines."
  (pcase form
    (`(cl-defstruct ,spec . ,slots)
     (let* ((name (if (consp spec) (car spec) spec))
            (ctors (and (consp spec) (delq nil (mapcar (lambda (o) (and (consp o) (eq (car o) :constructor) (cadr o)))
                                                       (cdr spec)))))
            (slots (mapcar (lambda (s) (if (consp s) (car s) s)) (seq-filter (lambda (s) (not (stringp s))) slots))))
       (append (list name (intern (format "%s-p" name))) ctors
               (mapcar (lambda (s) (intern (format "%s-%s" name s))) slots))))
    (`(define-error (quote ,name) . ,_) (list name))
    (`(defvar ,_) nil)                  ; a bare declaration defines nothing
    (`(,(pred (lambda (h) (memq h drgnx-lint-runtime--defining))) ,(and name (pred symbolp)) . ,_)
     (list name))
    (_ nil)))

(defun drgnx-lint-runtime--symbols (form acc)
  "Add every symbol in FORM to the hash ACC; the bare declaration (defvar SYM) names no use."
  (cond ((symbolp form) (when form (puthash form t acc)))
        ((and (consp form) (eq (car form) 'defvar) (null (cddr form))))
        ((consp form)
         (while (consp form) (drgnx-lint-runtime--symbols (pop form) acc))
         (when form (drgnx-lint-runtime--symbols form acc)))
        ((vectorp form) (mapc (lambda (x) (drgnx-lint-runtime--symbols x acc)) form))))

(defun drgnx-lint-runtime--files ()
  (let (out)
    (dolist (root drgnx-lint-runtime--roots)
      (let ((dir (expand-file-name root drgnx-dir)))
        (when (file-directory-p dir)
          (dolist (f (directory-files-recursively dir "\\.el\\'"))
            (let ((rel (file-relative-name f drgnx-dir)))
              (unless (string-match-p "/\\.\\|loaddefs" rel) (push rel out)))))))
    (sort out #'string<)))

(defun drgnx-lint-runtime--feature (rel) (intern (file-name-sans-extension (file-name-nondirectory rel))))

(defun drgnx-lint-runtime--scan ()
  "(DOOMED-ALIST . USES): DOOMED-ALIST ((SYMBOL . FILE)…) the symbols only a doomed file or half defines; USES a
list of (FILE . HASH-OF-SYMBOLS) for the kept forms."
  (let ((agents "core/drgnx-agents.el") doomed kept-defs uses)
    (dolist (rel (drgnx-lint-runtime--files))
      (let* ((file (expand-file-name rel drgnx-dir))
             (forms (drgnx-lint-runtime--forms file))
             (marker (and (equal rel agents) (drgnx-lint-runtime--marker file)))
             (acc (make-hash-table :test #'eq)))
        (dolist (sf forms)
          (let* ((form (cdr sf))
                 (defs (drgnx-lint-runtime--defined form))
                 (in-half (or (member rel drgnx-lint-runtime--doomed-files)
                              (and marker (>= (car sf) marker)
                                   (not (seq-some (lambda (d) (memq d drgnx-lint-runtime--agents-kept)) defs))))))
            (if in-half
                (dolist (d defs) (push (cons d rel) doomed))
              (dolist (d defs) (push d kept-defs))
              (unless (seq-some (lambda (d) (memq d drgnx-lint-runtime--agents-partial)) defs)
                (drgnx-lint-runtime--symbols form acc)))))
        (unless (member rel drgnx-lint-runtime--doomed-files) (push (cons rel acc) uses))))
    (cons (seq-remove (lambda (d) (memq (car d) kept-defs)) doomed) uses)))

(ert-deftest drgnx-lint/no-call-into-deleted-runtime ()
  (let* ((scan (drgnx-lint-runtime--scan))
         (doomed (make-hash-table :test #'eq))
         problems)
    (dolist (d (car scan)) (puthash (car d) (cdr d) doomed))
    (dolist (u (cdr scan))
      (maphash (lambda (sym _)
                 (when-let* ((home (gethash sym doomed))
                             ((not (drgnx-lint-runtime--waiting-p (car u) :symbols sym))))
                   (push (format "%s: `%s' (defined in %s)" (car u) sym home) problems)))
               (cdr u)))
    (should-not (and problems (mapconcat #'identity (sort problems #'string<) "\n")))))

(ert-deftest drgnx-lint/no-require-of-deleted-runtime ()
  "Nothing requires, autoloads or declares from a feature a runtime file provided."
  (let ((problems (drgnx-lint-runtime--feature-uses (drgnx-lint-runtime--files))))
    (should-not (and problems (mapconcat #'identity (sort problems #'string<) "\n")))))

(defun drgnx-lint-runtime--feature-uses (files)
  "\"FILE: FEATURE\" for each `require', `autoload' or `declare-function' of a runtime feature in FILES (relative)."
  (let ((features (mapcar #'drgnx-lint-runtime--feature drgnx-lint-runtime--doomed-files)) problems)
    (cl-labels ((walk (rel form)
                  (when (consp form)
                    (pcase form
                      ((or `(require (quote ,f) . ,_) `(declare-function ,_ ,(and f (pred stringp)) . ,_)
                           `(autoload ,_ ,(and f (pred stringp)) . ,_))
                       (let ((f (if (stringp f) (intern (file-name-sans-extension (file-name-nondirectory f))) f)))
                         (when (and (memq f features) (not (drgnx-lint-runtime--waiting-p rel :features f)))
                           (push (format "%s: %s" rel f) problems)))))
                    (while (consp form) (walk rel (pop form))))))
      (dolist (rel files)
        (unless (member rel drgnx-lint-runtime--doomed-files)
          (let ((file (expand-file-name rel drgnx-dir)))
            (condition-case nil
                (dolist (sf (drgnx-lint-runtime--forms file))
                  (walk rel (cdr sf)))
              ;; a test file the Lisp reader cannot read whole (a printed object, an escape it refuses): its text instead
              (error
               (with-temp-buffer
                 (insert-file-contents file)
                 (dolist (f features)
                   (goto-char (point-min))
                   (when (re-search-forward
                          (format "(\\(?:require '\\|declare-function [^ \n]+ \"\\|autoload '[^ \n]+ \"\\)%s[\")]"
                                  (regexp-quote (symbol-name f)))
                          nil t)
                     (push (format "%s: %s" rel f) problems))))))))))
    problems))

(defconst drgnx-lint-runtime--core-kept
  (cons "core/drgnx.el"
        (mapcar (lambda (n) (format "core/drgnx-%s.el" n))
                '("agent-check" "agent-config-claude" "agent-config-codex" "agent-config-gemini" "agent-config-kimi"
                  "agent-config" "agents-cards" "agents-matrix" "agents-mirror" "agents" "ai-client" "ai-probe" "ai" "bootstrap" "build"
                  "check" "color" "compat-gryphn" "config" "coord-read" "deny" "doctor" "exec" "face-state" "faces" "file"
                  "file-stream" "fmt" "frame-kind" "freezes" "gc-census" "gc" "guard" "heap" "history" "hooks" "hub-client" "hub-core" "icons"
                  "keys-edit" "keys-modal"
                  "keys" "large-file" "lisp-index" "macos" "memo" "modal-choose" "modal" "modules-fingerprint"
                  "modules-helpers" "modules-record" "modules" "notice-desktop" "notice-echo" "notice-save" "notice-toast" "notice"
                  "notices" "onboard" "owner" "palette-frame" "palette" "paths" "pixels" "pkg-activate" "pkg" "platform" "portable" "projects"
                  "quick-open" "records-review" "records" "registry" "sandbox-vc" "say" "schema" "search-setup" "secrets-scan" "secrets" "session" "setting"
                  "settings-agents" "settings-apply" "settings-area" "settings-defaults" "settings-described"
                  "settings-editors" "settings-file" "settings-history" "settings-index" "settings-lisp-page"
                  "settings-live" "settings-migrate" "settings-mode" "settings-move" "settings-page" "settings-prov"
                  "settings-resolve" "settings-review" "settings-runtime" "settings-tidy" "settings-trust"
                  "settings-workspace" "shell-env" "shell" "startup-trace" "store-privacy" "surfaces" "timer" "toml"
                  "trust" "tty-fallback" "tty-recommend" "tty" "type-faces" "ui-kit" "user-lisp" "watchdog-doctor" "watchdog" "work-db"
                  "work-client" "work-scan" "work" "workers-doctor")))
  "Every file under core/ after the Lisp agent runtime was deleted: a new core file is added here on purpose, so no
runtime file comes back unnoticed.")

(ert-deftest drgnx-lint/no-runtime-lisp ()
  "The Lisp agent runtime is gone: none of its files exists, nothing (tests included) requires, autoloads or declares
from its features, and core/ holds exactly the kept files."
  (dolist (rel drgnx-lint-runtime--doomed-files)
    (should-not (file-exists-p (expand-file-name rel drgnx-dir))))
  (let* ((tests (let (out)
                  (dolist (f (directory-files-recursively (expand-file-name "test" drgnx-dir) "\\.el\\'") out)
                    (push (file-relative-name f drgnx-dir) out))))
         ;; the frozen tests of other plans' Lisp (`:off', test/class-exempt.eld) are not loaded
         (off (let ((rows (with-temp-buffer
                            (insert-file-contents (expand-file-name "test/class-exempt.eld" drgnx-dir))
                            (read (current-buffer)))))
                (delq nil (mapcar (lambda (r) (and (plist-get (cdr r) :off) (car r))) rows))))
         (problems (drgnx-lint-runtime--feature-uses
                    (append (drgnx-lint-runtime--files) (seq-remove (lambda (f) (member f off)) tests)))))
    (should-not (and problems (mapconcat #'identity (sort problems #'string<) "\n"))))
  (let ((core (sort (seq-filter (lambda (f) (string-suffix-p ".el" f))
                                (process-lines "git" "-C" drgnx-dir "ls-files" "core"))
                    #'string<)))
    (should (equal core (sort (copy-sequence drgnx-lint-runtime--core-kept) #'string<)))))

(provide 'lint-runtime-calls-test)
;;; lint-runtime-calls-test.el ends here
