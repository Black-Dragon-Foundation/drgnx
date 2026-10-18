;;; drgnx-search.el --- Module tools/search: quick open, search in project, go to symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Quick Open (a project file by name), Search in Project (results in the panel's Results tab),
;; Go to Symbol in the file and in the project, Find in File, Replace in Project, Recent Buffers.
;; Built on project.el, xref and imenu (consult when installed).  See docs/guide/modules.md.
;;
;; Semantic Search (docs/guide/search.md): a question in words finds the code that means it.  The hits are xref
;; items, shown the way Search in Project shows its matches, so they land in the panel's Results tab with the
;; same jump and preview.  Index Project / Index Status drive the background indexer; a saved file of an indexed
;; project schedules an incremental re-index 30 s after the last save, started at the next idle moment (one timer
;; per project, never a prompt; the project's lock file, not the job list, says whether an indexer runs).
;; Set Up Semantic Search (core/drgnx-search-setup.el) finds and tests the embedding model and starts the first index.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'subr-x)
(require 'cl-lib)
(declare-function project-find-regexp "project")
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function xref-make "xref")
(declare-function xref-make-file-location "xref")
(declare-function xref-show-xrefs "xref")
(declare-function drgnx-search-async "drgnx-search-query")
(declare-function drgnx-search-store-file "drgnx-search-store")
(declare-function drgnx-search-store-open-read "drgnx-search-store")
(declare-function drgnx-search-store-meta "drgnx-search-store")
(declare-function drgnx-search-config "drgnx-search-chunk")
(declare-function drgnx-search--dot-path-p "drgnx-search-chunk")
(declare-function drgnx-search--sensitive-name-p "drgnx-search-chunk")
(declare-function drgnx-search--glob-regexp "drgnx-search-chunk")
(declare-function drgnx-search--matches-p "drgnx-search-chunk")
(declare-function drgnx-search-index-start "drgnx-search-index")
(declare-function drgnx-search-setup "drgnx-search-setup")
(declare-function drgnx-search-setup--current-root "drgnx-search-setup")
(declare-function drgnx-search-index-running-p "drgnx-search-index")
(declare-function drgnx-search-index-busy-p "drgnx-search-index")
(declare-function drgnx-search-hit-line "drgnx-search-query")
(defvar drgnx-search-last-notice)

(defun drgnx-search-project (regexp)
  "Search the project for REGEXP; the results go to the panel."
  (interactive (list (read-regexp "Search in project: " (thing-at-point 'symbol t))))
  (require 'project)
  (project-find-regexp regexp))

(defun drgnx-search-file ()
  "Find in this file: consult-line when it is installed, else incremental search."
  (interactive)
  (call-interactively (if (fboundp 'consult-line) #'consult-line #'isearch-forward)))

(defun drgnx-search-recent ()
  "Switch to a buffer or a recent file: consult-buffer when it is installed, else switch-to-buffer."
  (interactive)
  (call-interactively (if (fboundp 'consult-buffer) #'consult-buffer #'switch-to-buffer)))

;;;; Semantic Search

(defconst drgnx-search-reindex-delay 30 "Seconds after the last save of a project's file before it is re-indexed.")

(defun drgnx-search--root ()
  "The root of the current project, as a directory name, or nil outside a project.  Never asks."
  (require 'project)
  (when-let* ((project (project-current nil)))
    (expand-file-name (project-root project))))

(defun drgnx-search--root-or-error ()
  (or (drgnx-search--root)
      (user-error "Semantic search needs a project: open a file of one first")))

(declare-function drgnx-ai-confirm-project-route "drgnx-ai")

(defun drgnx-search--confirm-route (root)
  "Ask, once, about the remote providers the project at ROOT routes AI roles to (its .drgnx/ai.eld) — here, in the
command the user ran, never later from a job or timer.  Denied or not asked, the remote steps are simply left out."
  (require 'drgnx-ai)
  (let ((default-directory (file-name-as-directory root))) (drgnx-ai-confirm-project-route)))

(defun drgnx-search--xref (root hit)
  "An xref item for HIT (a result plist of `drgnx-search') in the project at ROOT: the chunk's first top-level line,
at that line (`drgnx-search-hit-line', the rule the MCP tool and the command line use too)."
  (require 'drgnx-search-query)
  (pcase-let ((`(,line . ,summary) (drgnx-search-hit-line hit)))
    (xref-make (if (string-empty-p summary) (plist-get hit :path) summary)
               (xref-make-file-location (expand-file-name (plist-get hit :path) root) line 0))))

(defun drgnx-search--show (root query hits notice)
  "Show HITS for QUERY in the project at ROOT as an xref list (the panel's Results tab); say NOTICE.
Non-nil when a list was shown."
  (require 'xref)
  (if (null hits)
      (progn (message "No semantic matches for \"%s\"%s" query (if notice (concat ": " notice) ""))
             nil)
    (let ((items (mapcar (lambda (h) (drgnx-search--xref root h)) hits)))
      (xref-show-xrefs (lambda () items) nil)
      (when-let* ((buf (get-buffer "*xref*")))
        (with-current-buffer buf (setq header-line-format (and notice (concat " " notice)))))
      (when notice (message "%s" notice))
      t)))

(defun drgnx-search--show-safely (buffer window root query hits notice)
  "`drgnx-search--show' as the command had it: BUFFER current and WINDOW selected (when still live, else
whatever is now), so xref's marker goes on the right buffer and the panel routing sees the right window.
Called from a process sentinel: an error becomes one message, never a signal."
  (condition-case err
      (let ((show (lambda ()
                    (if (buffer-live-p buffer)
                        (with-current-buffer buffer (drgnx-search--show root query hits notice))
                      (drgnx-search--show root query hits notice)))))
        (when (if (window-live-p window) (with-selected-window window (funcall show)) (funcall show))
          ;; the answer came after the command returned: the results get the focus, as for Search in Project
          ;; not while the user is in the minibuffer (another command began), nor in another frame
          (when-let* (((not (active-minibuffer-window)))
                      (buf (get-buffer "*xref*")) (win (get-buffer-window buf)))
            (select-window win))))
    (error (message "Semantic search could not show its results: %s" (error-message-string err)))))

(defun drgnx-search-semantic (query)
  "Search the project by meaning: QUERY in words; the best chunks of code land in the panel's Results tab.
Needs the project's index (Index Project); without an embedding provider only the keyword hits are shown,
and the echo area says why."
  (interactive (progn (drgnx-search--root-or-error) ; a project first, then the question
                      (let ((symbol (thing-at-point 'symbol t)))   ; the default (RET), not text to delete
                        (list (read-string (format-prompt "Semantic search" symbol) nil nil symbol)))))
  (let ((root (drgnx-search--root-or-error)) (query (string-trim query))
        (buffer (current-buffer)) (window (selected-window)))
    (when (string-empty-p query) (user-error "Semantic search needs a question"))
    (require 'drgnx-search-query)
    (drgnx-search--confirm-route root)
    (message "Searching %s…" (abbreviate-file-name root))
    (drgnx-search-async root query
                        (lambda (hits &optional notice)
                          (drgnx-search--show-safely buffer window root query hits notice)))))

(defconst drgnx-search--no-sqlite "this Emacs has no SQLite — semantic search needs Emacs built with SQLite"
  "What every search command says, and all it does, in an Emacs without SQLite.")

(defun drgnx-search-index-project (&optional rebuild)
  "Index (or bring up to date) this project for Semantic Search, in a background job.
With a prefix argument REBUILD, start from scratch — the way to change the embedding model."
  (interactive "P")
  (let ((root (drgnx-search--root-or-error)))
    (if (not (sqlite-available-p))
        (message "%s" drgnx-search--no-sqlite)
      (require 'drgnx-search-index)
      (drgnx-search--confirm-route root)
      (let ((config (drgnx-search-config root)) (name (abbreviate-file-name (directory-file-name root))))
        (cond ((plist-get config :error) (message "%s" (plist-get config :error)))
              ((plist-get config :off) (message "Search is turned off for this project (.drgnx/search.eld)"))
              ((drgnx-search-index-busy-p root)
               (if rebuild
                   (message "an index job is already running for %s; rebuild after it finishes" name)
                 (message "%s is already being indexed — Index Status shows how far it is" name)))
              ((drgnx-search-index-start root (and rebuild t))
               (message "Indexing %s in the background — Index Status shows how far it is" name))
              (t (message "an index job for %s started a moment ago and is still being cleaned up; try again shortly" name)))))))

(defun drgnx-search-set-up ()
  "Set Up Semantic Search: find an embedding model, test it, and index this project in the background (or,
when the index is current, run a test query).  Outside a project it only finds and tests the model."
  (interactive)
  (require 'drgnx-search-setup)
  (drgnx-search--confirm-route (or (drgnx-search-setup--current-root) default-directory))
  (message "Setting up semantic search…")
  (pcase-let ((`(,status ,text) (drgnx-search-setup (drgnx-search-setup--current-root) :interactive t)))
    (message "%s%s" (if (memq status '(warn fail)) "Semantic search: " "") text)))

(defun drgnx-search-status (root)
  "One line about the index of the project at ROOT: chunks, files, model, when, whether a job runs, the index file
\(delete it to drop the index) and what is wrong with the project's .drgnx/search.eld."
  (if (not (sqlite-available-p))
      drgnx-search--no-sqlite
    (require 'drgnx-search-index)
    (let* ((root (directory-file-name (expand-file-name root)))
           (file (drgnx-search-store-file root))
           (db (ignore-errors (drgnx-search-store-open-read root)))
           (running (drgnx-search-index-busy-p root))
           (config (drgnx-search-config root)))
      (concat
       (if (null db)
           (if (file-exists-p file)
               "the index cannot be read — Search: Index Project with C-u rebuilds it"
             "no index for this project — Search: Index Project")
         (unwind-protect
             (condition-case nil
                 (let* ((meta (drgnx-search-store-meta db))
                        (chunks (caar (sqlite-select db "select count(*) from chunk")))
                        (files (caar (sqlite-select db "select count(*) from file")))
                        (at (plist-get meta :indexed-at)))
                   (format "%d chunk%s in %d file%s; model %s (%s dims); last indexed %s"
                           chunks (if (= chunks 1) "" "s") files (if (= files 1) "" "s")
                           (or (plist-get meta :model) (plist-get meta :provider) "unknown") (or (plist-get meta :dims) "?")
                           (if at (format-time-string "%Y-%m-%d %H:%M" at) "never")))
               (error "the index cannot be read — Search: Index Project with C-u rebuilds it"))
           (ignore-errors (sqlite-close db))))
       (if running "; indexing now" "; indexer not running")
       (if (file-exists-p file) (format "; index file %s" (abbreviate-file-name file)) "")
       (cond ((plist-get config :error) (concat "; " (plist-get config :error)))
             ((plist-get config :off) "; search is off for this project")
             (t ""))))))

(defun drgnx-search-index-status ()
  "Say how this project's index stands."
  (interactive)
  (message "%s" (drgnx-search-status (drgnx-search--root-or-error))))

;;;; Index on save

(defvar drgnx-search--timers (make-hash-table :test #'equal)
  "Project root → the timer that will re-index it (one per project: a new save replaces it).")

(defun drgnx-search--indexed-p (root)
  "Non-nil when the project at ROOT has a search index, and its .drgnx/search.eld neither turns search off nor
is broken (the indexer would refuse it; Index Status and Index Project say why)."
  (require 'drgnx-search-store)
  (require 'drgnx-search-chunk)
  (and (file-exists-p (drgnx-search-store-file root))
       (let ((config (drgnx-search-config root)))
         (not (or (plist-get config :off) (plist-get config :error))))))

(defun drgnx-search--indexable-p (root file)
  "Non-nil when FILE could be indexed in the project at ROOT: not a dot file, not named like a secret, and
passing the project's :include and :exclude (the size and binary tests are the indexer's)."
  (let* ((rel (file-relative-name file root)) (config (drgnx-search-config root))
         (include (mapcar #'drgnx-search--glob-regexp (plist-get config :include)))
         (exclude (mapcar #'drgnx-search--glob-regexp (plist-get config :exclude))))
    (and (not (string-prefix-p ".." rel))
         (not (drgnx-search--dot-path-p rel))
         (not (drgnx-search--sensitive-name-p rel))
         (or (null include) (drgnx-search--matches-p rel include))
         (not (drgnx-search--matches-p rel exclude)))))

(defconst drgnx-search-reindex-idle 2
  "Seconds Emacs must be idle before a due re-index starts: starting the job never lands in the middle of typing.")

(defun drgnx-search--reindex (root)
  "Start the incremental indexing of the project at ROOT (an idle timer calls this); while an indexer holds the
project's lock, wait again.  Does nothing when the index is gone, or search was turned off or its config broken
since the save.  Never lists the jobs: the lock file says whether an indexer runs."
  (remhash root drgnx-search--timers)
  (condition-case nil
      (when (drgnx-search--indexed-p root)
        (require 'drgnx-search-index)
        (if (drgnx-search-index-running-p root)
            (drgnx-search--schedule root)   ; that job may have passed the saved file already
          (drgnx-search-index-start root)))
    (error nil)))

(defun drgnx-search--reindex-when-idle (root)
  "The re-index of ROOT is due (30 s after the last save): start it at the next idle moment."
  (puthash root (run-with-idle-timer drgnx-search-reindex-idle nil #'drgnx-search--reindex root) drgnx-search--timers))

(defun drgnx-search--schedule (root)
  (when-let* ((old (gethash root drgnx-search--timers))) (cancel-timer old))
  (puthash root (run-with-timer drgnx-search-reindex-delay nil #'drgnx-search--reindex-when-idle root)
           drgnx-search--timers))

(defun drgnx-search--after-save ()
  "`after-save-hook': a saved file of a project that has a search index schedules that project's re-index.
Never prompts and does nothing without an index file, with search off, outside a project, or for a file the
indexer would never index (dot files, secrets by name, the project's :exclude)."
  (when-let* ((file buffer-file-name)
              ((not (file-remote-p file)))
              (project (ignore-errors (project-current nil (file-name-directory file))))
              (root (expand-file-name (project-root project))))
    (when (and (drgnx-search--indexed-p root) (drgnx-search--indexable-p root file))
      (drgnx-search--schedule root))))

;;;; Ask the Codebase

(defvar drgnx-ai-retrievers)

(defun drgnx-search--retriever (question root done)
  "Ask the Codebase's semantic retriever: the best chunks of the project at ROOT for QUESTION, to DONE as snippets
\((:file :line :text)…).  DONE is called once — without waiting for the embedding provider — and with nil when
the project has no index or anything goes wrong.  Never asks anything."
  (let ((called nil))
    (cl-flet ((finish (snippets) (unless called (setq called t) (funcall done snippets))))
      (condition-case nil
          (if (not (drgnx-search--indexed-p root))
              (finish nil)
            (require 'drgnx-search-query)
            (drgnx-search-async
             root question
             (lambda (hits &optional _notice)
               (finish (condition-case nil
                           (mapcar (lambda (h) (list :file (plist-get h :path) :line (max 1 (plist-get h :start))
                                                     :text (plist-get h :text)))
                                   hits)
                         (error nil))))
             :k 5))
        (error (finish nil))))))

(defun drgnx-search--register-retriever ()
  "Add the semantic retriever to `drgnx-ai-retrievers' (once; the grep retriever stays)."
  (with-eval-after-load 'drgnx-ai-ui
    (add-to-list 'drgnx-ai-retrievers #'drgnx-search--retriever t)))

(drgnx-module-define 'tools/search
                     :doc "Quick Open, Search in Project, Go to Symbol, Semantic Search."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((go-quick-open "Quick Open" project-find-file "Open a file of the project by name")
                                        (search-project "Search in Project" drgnx-search-project "Every match in the project (in the panel)")
                                        (go-symbol "Go to Symbol" imenu "Jump to a definition of this file")
                                        (go-symbol-project "Go to Symbol in Project" xref-find-apropos "Search symbols across the project")
                                        (go-recent "Recent Buffers" drgnx-search-recent "Switch buffer or recent file")
                                        (search-file "Find in File" drgnx-search-file "Search this buffer")
                                        (search-replace "Replace in Project" project-query-replace-regexp "Replace a regexp in the project's files")))
                         (drgnx-command-define id :category "Go" :title title :command fn :doc doc))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((search-semantic "Semantic Search" drgnx-search-semantic "Find code by meaning (in the panel)")
                                        (search-index-project "Index Project" drgnx-search-index-project "Build or refresh the semantic search index of this project")
                                        (search-index-status "Index Status" drgnx-search-index-status "Chunks, files, model and age of this project's index")
                                        (search-set-up "Set Up Semantic Search" drgnx-search-set-up "Find and test an embedding model, then index this project in the background")))
                         (drgnx-command-define id :category "Search" :title title :command fn :doc doc))
                       (drgnx-search--register-retriever)
                       (add-hook 'after-save-hook #'drgnx-search--after-save)))

(provide 'drgnx-search)
;;; drgnx-search.el ends here
