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
;; project schedules an incremental re-index 30 s after the last save (one timer per project, never a prompt).
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
(declare-function drgnx-search-index--running-job "drgnx-search-index")
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

(defun drgnx-search--xref (root hit)
  "An xref item for HIT (a result plist of `drgnx-search') in the project at ROOT."
  (let ((summary (string-trim (car (split-string (or (plist-get hit :text) "") "\n")))))
    (xref-make (if (string-empty-p summary) (plist-get hit :path) summary)
               (xref-make-file-location (expand-file-name (plist-get hit :path) root)
                                        (max 1 (or (plist-get hit :start) 1)) 0))))

(defun drgnx-search--show (root query hits notice)
  "Show HITS for QUERY in the project at ROOT as an xref list (the panel's Results tab); say NOTICE."
  (require 'xref)
  (if (null hits)
      (message "No semantic matches for \"%s\"%s" query (if notice (concat ": " notice) ""))
    (let ((items (mapcar (lambda (h) (drgnx-search--xref root h)) hits)))
      (xref-show-xrefs (lambda () items) nil)
      (when-let* ((buf (get-buffer "*xref*")))
        (with-current-buffer buf (setq header-line-format (and notice (concat " " notice)))))
      (when notice (message "%s" notice)))))

(defun drgnx-search--show-safely (buffer window root query hits notice)
  "`drgnx-search--show' as the command had it: BUFFER current and WINDOW selected (when still live, else
whatever is now), so xref's marker goes on the right buffer and the panel routing sees the right window.
Called from a process sentinel: an error becomes one message, never a signal."
  (condition-case err
      (let ((show (lambda ()
                    (if (buffer-live-p buffer)
                        (with-current-buffer buffer (drgnx-search--show root query hits notice))
                      (drgnx-search--show root query hits notice)))))
        (if (window-live-p window) (with-selected-window window (funcall show)) (funcall show)))
    (error (message "Semantic search could not show its results: %s" (error-message-string err)))))

(defun drgnx-search-semantic (query)
  "Search the project by meaning: QUERY in words; the best chunks of code land in the panel's Results tab.
Needs the project's index (Index Project); without an embedding provider only the keyword hits are shown,
and the echo area says why."
  (interactive (progn (drgnx-search--root-or-error) ; a project first, then the question
                      (list (read-string "Semantic search: " (thing-at-point 'symbol t)))))
  (let ((root (drgnx-search--root-or-error)) (query (string-trim query))
        (buffer (current-buffer)) (window (selected-window)))
    (when (string-empty-p query) (user-error "Semantic search needs a question"))
    (require 'drgnx-search-query)
    (message "Searching %s…" (abbreviate-file-name root))
    (drgnx-search-async root query
                        (lambda (hits)
                          (drgnx-search--show-safely buffer window root query hits drgnx-search-last-notice)))))

(defun drgnx-search-index-project (&optional rebuild)
  "Index (or bring up to date) this project for Semantic Search, in a background job.
With a prefix argument REBUILD, start from scratch — the way to change the embedding model."
  (interactive "P")
  (let ((root (drgnx-search--root-or-error)))
    (require 'drgnx-search-index)
    (if (plist-get (drgnx-search-config root) :off)
        (message "Search is turned off for this project (.drgnx/search.eld)")
      (drgnx-search-index-start root (and rebuild t))
      (message "Indexing %s in the background — Index Status shows how far it is" (abbreviate-file-name root)))))

(defun drgnx-search-set-up ()
  "Set Up Semantic Search: find an embedding model, test it, and index this project in the background (or,
when the index is current, run a test query).  Outside a project it only finds and tests the model."
  (interactive)
  (require 'drgnx-search-setup)
  (message "Setting up semantic search…")
  (pcase-let ((`(,status ,text) (drgnx-search-setup (drgnx-search-setup--current-root) :interactive t)))
    (message "%s%s" (if (memq status '(warn fail)) "Semantic search: " "") text)))

(defun drgnx-search-status (root)
  "One line about the index of the project at ROOT: chunks, files, model, when, and whether a job runs."
  (require 'drgnx-search-index)
  (let* ((root (directory-file-name (expand-file-name root)))
         (db (and (sqlite-available-p) (ignore-errors (drgnx-search-store-open-read root))))
         (running (drgnx-search-index--running-job root)))
    (concat
     (if (null db)
         (if (file-exists-p (drgnx-search-store-file root))
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
     (if (plist-get (drgnx-search-config root) :off) "; search is off for this project" ""))))

(defun drgnx-search-index-status ()
  "Say how this project's index stands."
  (interactive)
  (message "%s" (drgnx-search-status (drgnx-search--root-or-error))))

;;;; Index on save

(defvar drgnx-search--timers (make-hash-table :test #'equal)
  "Project root → the timer that will re-index it (one per project: a new save replaces it).")

(defun drgnx-search--indexed-p (root)
  "Non-nil when the project at ROOT has a search index and search is not turned off for it."
  (require 'drgnx-search-store)
  (require 'drgnx-search-chunk)
  (and (file-exists-p (drgnx-search-store-file root))
       (not (plist-get (drgnx-search-config root) :off))))

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

(defun drgnx-search--reindex (root)
  "Start the incremental indexing of the project at ROOT; while a job already runs, wait again.
Does nothing when the index is gone or search was turned off since the save."
  (remhash root drgnx-search--timers)
  (condition-case nil
      (when (drgnx-search--indexed-p root)
        (require 'drgnx-search-index)
        (if (drgnx-search-index--running-job (directory-file-name root))
            (drgnx-search--schedule root)   ; that job may have passed the saved file already
          (drgnx-search-index-start root)))
    (error nil)))

(defun drgnx-search--schedule (root)
  (when-let* ((old (gethash root drgnx-search--timers))) (cancel-timer old))
  (puthash root (run-with-timer drgnx-search-reindex-delay nil #'drgnx-search--reindex root)
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
                       (add-hook 'after-save-hook #'drgnx-search--after-save)))

(provide 'drgnx-search)
;;; drgnx-search.el ends here
