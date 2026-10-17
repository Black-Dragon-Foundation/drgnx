;;; drgnx-search-setup.el --- Semantic Search: set it up, and say what is wrong with it -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Three things that make Semantic Search (docs/guide/search.md) set itself up and tell the user what is wrong:
;;
;; - `drgnx-search-doctor-facts': what the doctor's `search' check needs — SQLite and FTS5, whether an embedding
;;   provider is reachable (from the last probe's saved results; one test embedding of at most a second when an
;;   index exists, to know the provider's dimensions), and for the known projects their index and how many files
;;   are stale.  Reads only; never prompts.
;; - `drgnx-search-setup': the Set Up wizard behind the command and onboarding step 5.  It finds an embedding
;;   provider (M9's probe), tests it with one embedding, then starts the project's indexer as a background job —
;;   never indexes in the editor — or, when the index is current, runs a test query.
;; - `drgnx-search-setup-detect': what the non-interactive onboarding step reports (changes nothing).

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-ai)
(require 'drgnx-ai-client)
(require 'drgnx-ai-probe)
(require 'drgnx-search-store)
(require 'drgnx-search-chunk)
(require 'drgnx-search-index)
(require 'drgnx-search-query)
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function drgnx-projects-read "drgnx-projects")

(defconst drgnx-search-setup-max-projects 20 "The doctor looks at this many projects at most.")

(defvar drgnx-search-setup-stale-budget 4
  "Seconds the doctor may spend, over all projects, counting stale files (git hashes the changed ones).
Past it a project's :stale stays nil (unknown).")

(defconst drgnx-search-setup-start-hint
  (concat "start Text Embeddings Inference (podman run -p 8080:80 -m 4g "
          "ghcr.io/huggingface/text-embeddings-inference:cpu-latest --model-id BAAI/bge-small-en-v1.5) "
          "or Ollama (ollama pull nomic-embed-text), then Set Up Semantic Search again")
  "How to get an embedding provider running (the wizard's and the onboarding step's answer when there is none).")

;;;; SQLite and FTS5

(defun drgnx-search-setup--fts5-p ()
  "Non-nil when this Emacs' SQLite has FTS5 (tried in an in-memory database)."
  (and (fboundp 'sqlite-available-p) (sqlite-available-p)
       (condition-case nil
           (let ((db (sqlite-open)))
             (unwind-protect (progn (sqlite-execute db "create virtual table t using fts5(x)") t)
               (sqlite-close db)))
         (error nil))))

;;;; Projects and their indexes

(defun drgnx-search-setup--current-root ()
  "The current project's root without a trailing slash, or nil.  Never asks."
  (require 'project)
  (when-let* ((project (ignore-errors (project-current nil))))
    (directory-file-name (expand-file-name (project-root project)))))

(defun drgnx-search-setup--roots ()
  "The current project and the projects drgnx knows (projects.eld), local ones, at most
`drgnx-search-setup-max-projects'."
  (let ((roots (append (and (drgnx-search-setup--current-root) (list (drgnx-search-setup--current-root)))
                       (ignore-errors
                         (require 'drgnx-projects)
                         (mapcar (lambda (p) (plist-get p :root)) (plist-get (drgnx-projects-read) :projects))))))
    (seq-take (delete-dups (cl-loop for r in roots
                                    when (and (stringp r) (not (file-remote-p r)))
                                    collect (directory-file-name (expand-file-name r))))
              drgnx-search-setup-max-projects)))

(defun drgnx-search-setup--stale (root db deadline)
  "How many files of the project at ROOT differ from what DB indexed (changed, new, gone), or nil when unknown
\(not a git project, search off, git failed or timed out).  The listing gets what is left until DEADLINE (a
`float-time'), at least half a second, and is cut off when that is spent; past DEADLINE it is not tried."
  (condition-case nil
      (when-let* (((< (float-time) deadline))
                  (files (let ((drgnx-search-git-timeout (max 0.5 (- deadline (float-time)))))
                           (drgnx-search-files root))))
        (let ((stored (drgnx-search-store-files db)) (seen (make-hash-table :test #'equal)) (n 0))
          (pcase-dolist (`(,path . ,hash) files)
            (puthash path t seen)
            (unless (equal (gethash path stored) hash) (cl-incf n)))
          (maphash (lambda (path _) (unless (gethash path seen) (cl-incf n))) stored)
          n))
    (error nil)))

(defun drgnx-search-setup-index-info (root &optional stale-deadline)
  "What the index of the project at ROOT says about itself — (:chunks :files :provider :model :dims :stale) —
or nil when the project has none; (:error MESSAGE) when it cannot be read.  STALE-DEADLINE (a `float-time'):
count the stale files, giving up at that time (:stale stays nil)."
  (when (and (sqlite-available-p) (file-exists-p (drgnx-search-store-file root)))
    (condition-case err
        (when-let* ((db (drgnx-search-store-open-read root)))
          (unwind-protect
              (let ((meta (drgnx-search-store-meta db)))
                (list :chunks (caar (sqlite-select db "select count(*) from chunk"))
                      :files (caar (sqlite-select db "select count(*) from file"))
                      :provider (plist-get meta :provider) :model (plist-get meta :model) :dims (plist-get meta :dims)
                      :stale (and stale-deadline (drgnx-search-setup--stale root db stale-deadline))))
            (ignore-errors (sqlite-close db))))
      (error (list :error (error-message-string err))))))

;;;; Embedding providers

(defun drgnx-search-setup--usable (detected)
  "The steps of the `embed' role that can be tried now, DETECTED being a probe's results (an alist like
`drgnx-ai-detected'): a provider with a key when the key is there, a local one the probe found running."
  (let ((drgnx-ai-detected detected))
    (seq-filter (lambda (step) (drgnx-ai-usable-p (car step) 'embed)) (drgnx-ai-role 'embed))))

(defun drgnx-search-setup--detected-step ()
  "A step (PROVIDER . MODEL) for the `embed' role from the providers the probe found running: TEI as it is,
others with a model whose name says embedding.  Nil when there is none."
  (seq-some (lambda (e)
              (when (and (plist-get (cdr e) :up) (drgnx-ai-usable-p (car e) 'embed))
                (if (eq (plist-get (drgnx-ai-provider (car e)) :kind) 'tei)
                    (cons (car e) nil)
                  (when-let* ((model (seq-find (lambda (m) (string-match-p "embed\\|bge\\|minilm\\|e5\\|gte\\|nomic" m))
                                               (plist-get (cdr e) :models))))
                    (cons (car e) model)))))
            drgnx-ai-detected))

(defun drgnx-search-setup--probe ()
  "Probe the local providers and wait for the answers (two seconds at most); the results are in
`drgnx-ai-detected'."
  (let ((done nil) (deadline (+ (float-time) 2)))
    (drgnx-ai-probe (lambda () (setq done t)))
    (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.05))))

(defun drgnx-search-setup--label (info)
  "\"provider/model\" of INFO (:provider :model), or \"an unknown model\"."
  (cond ((and (plist-get info :provider) (plist-get info :model))
         (format "%s/%s" (plist-get info :provider) (plist-get info :model)))
        ((plist-get info :provider) (format "%s" (plist-get info :provider)))
        (t (or (plist-get info :model) "an unknown model"))))

(defun drgnx-search-setup-mismatch (index dims provider model)
  "Why the index described by INDEX (:provider :model :dims) cannot be searched with vectors of DIMS made by
PROVIDER and MODEL (PROVIDER nil: not known), as a sentence naming what differs, or nil when they fit."
  (let ((built (drgnx-search-setup--label index)))
    (cond ((and dims (plist-get index :dims) (/= dims (plist-get index :dims)))
           (format "built with %s (%d), the provider gives %d" built (plist-get index :dims) dims))
          ((and provider (plist-get index :dims)
                (not (and (equal provider (plist-get index :provider)) (equal model (plist-get index :model)))))
           (format "built with %s, the provider is %s" built
                   (drgnx-search-setup--label (list :provider provider :model model)))))))

;;;; The doctor's facts

(defun drgnx-search-doctor-facts (roots)
  "Facts for the doctor's `search' check: (:sqlite :fts5 :embed-up :embed-dims :embed-provider :embed-model
:indexes ((ROOT :chunks :files :provider :model :dims :stale)…) :unindexed N :config-errors ((ROOT . MESSAGE)…))
over the projects ROOTS; :config-errors are the projects whose .drgnx/search.eld cannot be read.
:embed-up: the last probe found an `embed' provider running (a saved result, no request).  :embed-dims and the
provider and model come from one test embedding of at most a second, made only when an index exists.
:stale is nil (unknown) past `drgnx-search-setup-stale-budget'.  Reads only; never prompts."
  (let* ((sqlite (and (fboundp 'sqlite-available-p) (sqlite-available-p) t))
         (fts5 (and sqlite (drgnx-search-setup--fts5-p) t))
         (chain (ignore-errors (drgnx-search-setup--usable (drgnx-ai-detected-cached))))
         (deadline (+ (float-time) drgnx-search-setup-stale-budget))
         (indexes nil) (unindexed 0) (test nil)
         (config-errors (cl-loop for root in roots
                                 for err = (plist-get (ignore-errors (drgnx-search-config root)) :error)
                                 when err collect (cons root err))))
    (when sqlite
      (dolist (root roots)
        (if-let* ((info (drgnx-search-setup-index-info root deadline)))
            (push (cons root info) indexes)
          (cl-incf unindexed))))
    (setq indexes (nreverse indexes))
    (when (and indexes chain)
      (let ((drgnx-ai-embed-last-info nil))
        (setq test (ignore-errors
                     (let ((v (drgnx-ai-embed-sync (vector "hello") :timeout 1 :chain (list (car chain)))))
                       (list :dims (length (aref v 0)) :provider (plist-get drgnx-ai-embed-last-info :provider)
                             :model (plist-get drgnx-ai-embed-last-info :model)))))))
    (list :sqlite sqlite :fts5 fts5 :embed-up (and chain t)
          :embed-dims (plist-get test :dims) :embed-provider (plist-get test :provider) :embed-model (plist-get test :model)
          :indexes indexes :unindexed unindexed :config-errors config-errors)))

;;;; The wizard

(defconst drgnx-search-setup-test-query "where does the program start"
  "The question of the wizard's test query.")

(defun drgnx-search-setup--index-step (root chain dims info)
  "The wizard's last steps for the project at ROOT, the provider tested giving DIMS-wide vectors (INFO: who
answered): (STATUS MESSAGE).  A current index gets a test query; else the indexer starts in the background."
  (let* ((who (format "%s, %d dims" (drgnx-search-setup--label info) dims))
         (index (drgnx-search-setup-index-info root (+ (float-time) 3)))
         (name (abbreviate-file-name root)))
    (cond
     ((plist-get (drgnx-search-config root) :error)
      (list 'warn (format "%s works, but %s: %s — fix it or delete it" who name (plist-get (drgnx-search-config root) :error))))
     ((plist-get (drgnx-search-config root) :off)
      (list 'info (format "%s works; search is turned off for %s (.drgnx/search.eld)" who name)))
     ((plist-get index :error)
      (list 'warn (format "%s works, but the index of %s cannot be read — Search: Index Project with C-u rebuilds it" who name)))
     ((and index (drgnx-search-setup-mismatch index dims (plist-get info :provider) (plist-get info :model)))
      (list 'warn (format "%s works, but the index of %s was %s — Search: Index Project with rebuild (C-u) to change the model"
                          who name (drgnx-search-setup-mismatch index dims (plist-get info :provider) (plist-get info :model)))))
     ((and index (eql (plist-get index :stale) 0) (> (plist-get index :chunks) 0))
      (let ((hit (car (drgnx-search root drgnx-search-setup-test-query :k 1
                                    :embed (lambda (inputs) (drgnx-ai-embed-sync inputs :timeout 5 :chain chain))))))
        (list 'ok (if hit
                      (format "%s works; %s is indexed (%d chunks); test query \"%s\": %s:%d"
                              who name (plist-get index :chunks) drgnx-search-setup-test-query
                              (plist-get hit :path) (plist-get hit :start))
                    (format "%s works; %s is indexed (%d chunks), but the test query found nothing (%s)"
                            who name (plist-get index :chunks) (or drgnx-search-last-notice "no reason given"))))))
     (t
      (let ((running (drgnx-search-index-busy-p root)))
        (unless running (drgnx-search-index-start root))
        (list 'ok (format "%s works; %s %s in the background — Index Status shows how far it is"
                          who (if running "is already being indexed" "is being indexed") name)))))))

(cl-defun drgnx-search-setup (root &key interactive)
  "Set up Semantic Search for the project at ROOT (nil: only the provider): (STATUS MESSAGE).
Finds an embedding provider (M9's probe; INTERACTIVE: when the `embed' role has none running but a provider
found does, that one is put first in the role), tests it with one embedding of \"hello\", then starts the
project's indexer in the background — or, when the index is current, runs a test query.  The only wait is
the probe (two seconds) and the test embedding (five).  For a command the user ran."
  (let ((root (and root (directory-file-name (expand-file-name root)))))
    (cond
     ((not (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
      (list 'warn "this Emacs has no SQLite: semantic search is off — use an Emacs built with it (the installer's does)"))
     ((not (drgnx-search-setup--fts5-p))
      (list 'warn "this Emacs' SQLite has no FTS5: semantic search is off — use an Emacs built with it (the installer's does)"))
     (t
      (drgnx-search-setup--probe)
      (let* ((chain (drgnx-search-setup--usable drgnx-ai-detected))
             (added (and (null chain) (drgnx-search-setup--detected-step))))
        (when added (setq chain (list added)))
        (if (null chain)
            (list 'info (concat "no embedding provider is running: " drgnx-search-setup-start-hint))
          (condition-case err
              (let* ((drgnx-ai-embed-last-info nil)
                     (vectors (drgnx-ai-embed-sync (vector "hello") :timeout 5 :chain chain))
                     (dims (length (aref vectors 0))) (info drgnx-ai-embed-last-info)
                     (placed (and added interactive (drgnx-search-setup--put-first added))))
                (cond ((stringp placed) (list 'warn placed))
                      ((null root)
                       (list 'ok (format "%s works (%d dims) — open a project and run Set Up Semantic Search there to index it"
                                         (drgnx-search-setup--label info) dims)))
                      (t (let ((r (drgnx-search-setup--index-step root chain dims info)))
                           (if placed (list (car r) (format "%s (put first in the embed role)" (cadr r))) r)))))
            (drgnx-ai-embed-error
             (list 'warn (format "the embedding provider did not answer a test embedding (%s) — check that it runs and serves an embedding model (docs/guide/ai.md)"
                                 (cadr err)))))))))))

(defun drgnx-search-setup--put-first (step)
  "Put STEP first in the `embed' role, in the user's ai.eld: t, or a message when that could not be written
\(`drgnx-ai-set-role' writes nothing then)."
  (condition-case err
      (progn (drgnx-ai-set-role 'embed (cons step (drgnx-ai-role 'embed))) t)
    (error (format "%s works, but it could not be put first in the embed role (%s) — AI: Choose Provider/Model, then Set Up Semantic Search again"
                   (drgnx-search-setup--label (list :provider (car step) :model (cdr step))) (error-message-string err)))))

(defun drgnx-search-setup-detect ()
  "What the non-interactive onboarding step reports: (STATUS MESSAGE).  Probes, changes nothing."
  (cond
   ((not (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
    (list 'warn "this Emacs has no SQLite: semantic search is off — use an Emacs built with it (the installer's does)"))
   ((not (drgnx-search-setup--fts5-p))
    (list 'warn "this Emacs' SQLite has no FTS5: semantic search is off — use an Emacs built with it (the installer's does)"))
   (t
    (drgnx-search-setup--probe)
    (let* ((chain (drgnx-search-setup--usable drgnx-ai-detected))
           (step (or (car chain) (drgnx-search-setup--detected-step)))
           (roots (drgnx-search-setup--roots))
           (indexed (seq-count (lambda (r) (file-exists-p (drgnx-search-store-file r))) roots)))
      (cond
       ((null step)
        (list 'info (concat "no embedding provider is running: " drgnx-search-setup-start-hint)))
       ((null roots)
        (list 'info (format "embedding provider found: %s; no project known yet — open one and run Set Up Semantic Search"
                            (drgnx-search-setup--label (list :provider (car step) :model (cdr step))))))
       ((= indexed (length roots))
        (list 'ok (format "embedding provider found: %s; %d project%s indexed"
                          (drgnx-search-setup--label (list :provider (car step) :model (cdr step)))
                          indexed (if (= indexed 1) "" "s"))))
       (t
        (list 'info (format "embedding provider found: %s; %d of %d known projects have no index — run Set Up Semantic Search in each (or Search: Index Project)"
                            (drgnx-search-setup--label (list :provider (car step) :model (cdr step)))
                            (- (length roots) indexed) (length roots)))))))))

(provide 'drgnx-search-setup)
;;; drgnx-search-setup.el ends here
