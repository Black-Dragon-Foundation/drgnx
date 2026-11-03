;;; lint-runtime-calls-test.el --- no kept file calls into the Lisp agent runtime that is deleted -*- lexical-binding: t -*-
;; test-class: det
;; The Lisp agent runtime (the hub, jobs, coordination writers and MCP, ACP, the gateway, the MCP bridge, the sandbox,
;; and the in-process half of `drgnx-agents.el') goes with its files.  What stays of it lives in kept files (the
;; coordination readers in `drgnx-coord-read.el', the agent settings in `drgnx-agents.el', ...).  This lint reads
;; `core/ modules/ wb/ harness/ settings/' with the Lisp reader (comments and strings never count) and fails on any
;; symbol that only a doomed file defines, used in a kept file, and on any `require' or `declare-function' of a doomed
;; feature.  `drgnx-agents.el' is half doomed: its forms after the runtime section marker count as doomed unless the
;; name is on `drgnx-lint-runtime--agents-kept'.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx)

(defconst drgnx-lint-runtime--doomed-files
  (mapcar (lambda (n) (format "core/drgnx-%s.el" n))
          '("hub" "job" "job-snapshot" "job-worktree" "job-clash" "coord" "coord-mcp" "acp" "gateway" "mcp-bridge"
            "sandbox" "sandbox-macos" "sandbox-mcp" "sandbox-proxy" "sandbox-relay"))
  "The files the runtime deletion removes whole.  `core/drgnx-jobs.el' (its callers move to `drgnx-exec') and
`core/drgnx-mcp.el' (it goes with the search indexer's port) join the list when their callers are gone.")

(defconst drgnx-lint-runtime--agents-marker ";;;; The agent's requests"
  "In `core/drgnx-agents.el', the line from which the forms are the runtime half unless kept.")

(defconst drgnx-lint-runtime--agents-kept
  '(drgnx-agents-get drgnx-agents--remote drgnx-agents-sessions drgnx-agents-scrubbed-env drgnx-agents-own-env
                     drgnx-agents-use-gateway drgnx-agents-env-functions drgnx-agents-answer-permission drgnx-agents-finish-review
                     drgnx-agents-send drgnx-agents-deliver-queue drgnx-agents-unqueue drgnx-agents-requeue drgnx-agents-stop
                     drgnx-agents-kill drgnx-agents-free-p drgnx-agents-deliver drgnx-agents-steer)
  "Names in the runtime half of `core/drgnx-agents.el' that stay: they ask the hub (`drgnx-agents--remote').")

(defconst drgnx-lint-runtime--agents-partial
  '(drgnx-agents-answer-permission drgnx-agents-finish-review drgnx-agents-send drgnx-agents-deliver-queue
                                   drgnx-agents-unqueue drgnx-agents-requeue drgnx-agents-stop drgnx-agents-kill)
  "The kept names that still carry the in-process branch after their hub branch: those forms are not scanned.  The
branch is the runtime half's, and goes with it; each of these is then only its `drgnx-agents--remote' call.")

(defconst drgnx-lint-runtime--waiting
  '(("core/drgnx-onboard.el" :symbols (drgnx-acp-start drgnx-acp-request drgnx-acp-stop) :features (drgnx-acp))
    ("core/drgnx-doctor.el" :symbols (drgnx-sandbox-check) :features (drgnx-sandbox)))
  "(FILE :symbols S :features F): callers of the runtime that wait for the hub method or the doctor section that
replaces them (the onboarding's agent probe, the doctor's sandbox check).  The list is empty when the runtime files
are deleted.")

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
  "Nothing but the half-doomed `drgnx-agents.el' requires or declares from a feature a runtime file provides."
  (let ((features (mapcar #'drgnx-lint-runtime--feature drgnx-lint-runtime--doomed-files)) problems)
    (cl-labels ((walk (rel form)
                  (when (consp form)
                    (pcase form
                      ((or `(require (quote ,f) . ,_) `(declare-function ,_ ,(and f (pred stringp)) . ,_))
                       (let ((f (if (stringp f) (intern f) f)))
                         (when (and (memq f features) (not (drgnx-lint-runtime--waiting-p rel :features f)))
                           (push (format "%s: %s" rel f) problems)))))
                    (while (consp form) (walk rel (pop form))))))
      (dolist (rel (drgnx-lint-runtime--files))
        (unless (or (member rel drgnx-lint-runtime--doomed-files) (equal rel "core/drgnx-agents.el"))
          (dolist (sf (drgnx-lint-runtime--forms (expand-file-name rel drgnx-dir)))
            (walk rel (cdr sf))))))
    (should-not (and problems (mapconcat #'identity (sort problems #'string<) "\n")))))

(provide 'lint-runtime-calls-test)
;;; lint-runtime-calls-test.el ends here
