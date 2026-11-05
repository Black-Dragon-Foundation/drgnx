;;; drgnx-search.el --- Module tools/search: quick open, search in project, go to symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Quick Open (a project file by name), Search in Project (results in the panel's Results tab),
;; Go to Symbol in the file and in the project, Find in File, Replace in Project, Recent Buffers.
;; Built on project.el, xref and imenu (consult when installed).  See docs/guide/modules.md.
;;
;; Semantic Search (docs/guide/search.md): a question in words finds the code that means it.  The search itself is
;; Hrafn, inside the hub: the index, the model and the query live there (`search/*' methods).  This file only asks and
;; renders: the hits are xref items, shown the way Search in Project shows its matches, so they land in the panel's
;; Results tab with the same jump and preview, under a line that says which model answered and what lags.  Index
;; Project / Index Status drive the hub's indexer; the hub's watcher keeps the index current (no save hook here).  A
;; keystroke signal (`search/typing') tells the hub to hold the vectors back while you type.  Set Up Semantic Search
;; (core/drgnx-search-setup.el) offers the built-in model and a server.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'subr-x)
(require 'cl-lib)
(declare-function project-find-regexp "project")
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function xref-make "xref")
(declare-function xref-make-file-location "xref")
(declare-function xref-show-xrefs "xref")
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-search-setup "drgnx-search-setup")
(declare-function drgnx-search-setup--current-root "drgnx-search-setup")

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
  "Ask, once per project root, about the remote providers the project at ROOT routes AI roles to (its .drgnx/ai.eld)
— here, in the command the user ran, never later from a job or timer and never for several projects at once.
Denied or not asked, the remote steps are simply left out."
  (require 'drgnx-ai)
  (let ((default-directory (file-name-as-directory root))) (drgnx-ai-confirm-project-route)))

(defun drgnx-search--why (err)
  "ERR (a signal's data) as the sentence a search command says when the hub cannot be asked."
  (format "the drgnx hub is not available (%s)" (error-message-string err)))

(defun drgnx-search--ask (method params callback)
  "Ask the hub METHOD with PARAMS from a command, starting it when it is not running (`drgnx-hub-ensure'); CALLBACK
gets (RESULT WHY) once: RESULT the answer, or nil with WHY a sentence.  Never signals."
  (condition-case err
      (progn (drgnx-hub-ensure)
             (drgnx-hub-call method params (lambda (result why) (funcall callback result why))))
    (error (funcall callback nil (drgnx-search--why err)))))

(defun drgnx-search--model-line (answer)
  "The line over a list of hits: the model that took part, and what lags (the hub's own words)."
  (let ((model (plist-get answer :model)))
    (concat (if model (format "model %s" model) "keyword and symbol results only")
            (when-let* ((notice (plist-get answer :notice))) (format " (%s)" notice))
            "; " (or (plist-get answer :lag_line) ""))))

(defun drgnx-search--xref (root hit)
  "An xref item for HIT (a hit of `search/query') in the project at ROOT: at its first line, summarised by the first
line of its text, else its symbol, else its path."
  (let* ((preview (string-trim (or (plist-get hit :preview) "")))
         (summary (string-trim (car (split-string preview "\n"))))
         (summary (cond ((not (string-empty-p summary)) summary)
                        ((plist-get hit :symbol))
                        (t (plist-get hit :path)))))
    (xref-make summary (xref-make-file-location (expand-file-name (plist-get hit :path) root)
                                                (max 1 (plist-get hit :line_start)) 0))))

(defun drgnx-search--show (root query answer)
  "Show the hits of ANSWER for QUERY in the project at ROOT as an xref list (the panel's Results tab), under the model
and lag line.  Non-nil when a list was shown."
  (require 'xref)
  (let ((hits (plist-get answer :hits)) (line (drgnx-search--model-line answer)))
    (if (null hits)
        (progn (message "No semantic matches for \"%s\": %s" query line) nil)
      (let ((items (mapcar (lambda (h) (drgnx-search--xref root h)) hits)))
        (xref-show-xrefs (lambda () items) nil)
        (when-let* ((buf (get-buffer "*xref*")))
          (with-current-buffer buf (setq header-line-format (concat " " line))))
        (message "%s" line)
        t))))

(defun drgnx-search--show-safely (buffer window root query answer why)
  "`drgnx-search--show' as the command had it: BUFFER current and WINDOW selected (when still live, else
whatever is now), so xref's marker goes on the right buffer and the panel routing sees the right window.  WHY: the
sentence to say when there is no ANSWER.  Called from a callback: an error becomes one message, never a signal."
  (condition-case err
      (if (null answer)
          (message "Semantic search: %s" (or why "no answer"))
        (let ((show (lambda ()
                      (if (buffer-live-p buffer)
                          (with-current-buffer buffer (drgnx-search--show root query answer))
                        (drgnx-search--show root query answer)))))
          (when (if (window-live-p window) (with-selected-window window (funcall show)) (funcall show))
            ;; the answer came after the command returned: the results get the focus, as for Search in Project
            ;; not while the user is in the minibuffer (another command began), nor in another frame
            (when-let* (((not (active-minibuffer-window)))
                        (buf (get-buffer "*xref*")) (win (get-buffer-window buf)))
              (select-window win)))))
    (error (message "Semantic search could not show its results: %s" (error-message-string err)))))

(defun drgnx-search-semantic (query)
  "Search the project by meaning: QUERY in words; the best chunks of code land in the panel's Results tab.
The hub answers with keyword, symbol and path results at once, and with vectors when a model is ready; the
line over the list says which, and the echo area says why when there are none."
  (interactive (progn (drgnx-search--root-or-error) ; a project first, then the question
                      (let ((symbol (thing-at-point 'symbol t)))   ; the default (RET), not text to delete
                        (list (read-string (format-prompt "Semantic search" symbol) nil nil symbol)))))
  (let ((root (drgnx-search--root-or-error)) (query (string-trim query))
        (buffer (current-buffer)) (window (selected-window)))
    (when (string-empty-p query) (user-error "Semantic search needs a question"))
    (drgnx-search--confirm-route root)
    (message "Searching %s…" (abbreviate-file-name root))
    (drgnx-search--ask "search/query" (list :root (directory-file-name root) :text query :scope "code" :k 10)
                       (lambda (answer why)
                         (drgnx-search--show-safely buffer window root query answer why)))))

(defun drgnx-search-index-project (&optional rebuild)
  "Index (or bring up to date) this project for Semantic Search, in the hub.
With a prefix argument REBUILD, start from scratch — the way to change the chunking."
  (interactive "P")
  (let* ((root (drgnx-search--root-or-error)) (name (abbreviate-file-name (directory-file-name root))))
    (drgnx-search--confirm-route root)
    (drgnx-search--ask "search/index" (list :root (directory-file-name root) :rebuild (if rebuild t :false))
                       (lambda (_result why)
                         (message "%s" (if why (format "Semantic search: %s" why)
                                         (format "Indexing %s in the background — Index Status shows how far it is" name)))))))

(defun drgnx-search-set-up ()
  "Set Up Semantic Search: offer the built-in model (and, when one can run, a server), then index this project in the
background (or, when the index is current, run a test query).  Asks only in a frame; confirms this project's remote
route once, here."
  (interactive)
  (require 'drgnx-search-setup)
  (let ((root (drgnx-search-setup--current-root)))
    (when root (drgnx-search--confirm-route root))
    (message "Setting up semantic search…")
    (pcase-let ((`(,status ,text) (drgnx-search-setup root :interactive (called-interactively-p 'any))))
      (message "%s%s" (if (memq status '(warn fail)) "Semantic search: " "") text))))

(defun drgnx-search--device-text (worker)
  "WORKER (the `worker' of `search/status' or the `device' of `search/embedders') as words, or nil."
  (let ((device (plist-get worker :device)) (fallback (plist-get worker :fallback)))
    (when device
      (concat (format "%s %s" (upcase (or (plist-get device :kind) "")) (or (plist-get device :name) ""))
              (when fallback (format " (fell back to the CPU: %s)" fallback))))))

(defun drgnx-search-status-line (status)
  "One line about a project's index from STATUS, the answer of `search/status': files and chunks, the models that
have vectors, the device, what tier 2 is doing, coverage errors, and the lag."
  (let* ((lag (plist-get status :lag)) (models (plist-get status :models))
         (errors (plist-get status :coverage_errors)) (device (drgnx-search--device-text (plist-get status :worker))))
    (concat
     (format "%d chunk%s in %d file%s" (plist-get status :chunks) (if (eql (plist-get status :chunks) 1) "" "s")
             (plist-get status :files) (if (eql (plist-get status :files) 1) "" "s"))
     (if models
         (format "; vectors: %s" (mapconcat (lambda (m) (format "%s (%d)" (plist-get m :model) (plist-get m :vectors)))
                                            models ", "))
       "; vectors: none (keyword and symbol results only)")
     (when device (format "; device: %s" device))
     (format "; tier 2 %s" (or (plist-get status :tier2) "unknown"))
     (when errors (format "; coverage: %s" (string-join errors ", ")))
     (when lag (format "; behind: %d chunk%s in %d file%s"
                       (or (plist-get lag :chunks_behind) 0) (if (eql (plist-get lag :chunks_behind) 1) "" "s")
                       (or (plist-get lag :files_behind) 0) (if (eql (plist-get lag :files_behind) 1) "" "s"))))))

(defun drgnx-search-index-status ()
  "Say how this project's index stands."
  (interactive)
  (let ((root (drgnx-search--root-or-error)))
    (drgnx-search--ask "search/status" (list :root (directory-file-name root))
                       (lambda (status why)
                         (message "%s" (if status (drgnx-search-status-line status)
                                         (format "Semantic search: %s" why)))))))

;;;; The editor's keystrokes, for the hub's pacing

(defconst drgnx-search-typing-interval 2
  "Seconds between the keystroke signals the hub gets: it holds the vectors back for 3 s after each.")

(defvar drgnx-search--typed nil "Non-nil when a command ran since the last `search/typing' went out.")

(defun drgnx-search--send-typing ()
  "Tell the hub the user is typing, when a command ran since the last time; never waits for the answer and never
starts the hub."
  (when drgnx-search--typed
    (setq drgnx-search--typed nil)
    (condition-case nil (drgnx-hub-call "search/typing" nil #'ignore) (error nil))))

;;;; Ask the Codebase

(defvar drgnx-ai-retrievers)

(defun drgnx-search--retriever (question root done)
  "Ask the Codebase's semantic retriever: the best chunks of the project at ROOT for QUESTION, to DONE as snippets
\((:file :line :text)…).  DONE is called once, without waiting for the hub's model, and with nil when the hub is
not there or anything goes wrong.  Never asks anything and never starts the hub."
  (let ((called nil))
    (cl-flet ((finish (snippets) (unless called (setq called t) (funcall done snippets))))
      (condition-case nil
          (drgnx-hub-call "search/query" (list :root (directory-file-name root) :text question :scope "code" :k 5)
                          (lambda (answer _why)
                            (finish (condition-case nil
                                        (mapcar (lambda (h) (list :file (plist-get h :path)
                                                                  :line (max 1 (plist-get h :line_start))
                                                                  :text (plist-get h :preview)))
                                                (plist-get answer :hits))
                                      (error nil)))))
        (error (finish nil))))))

(defun drgnx-search--register-retriever ()
  "Add the semantic retriever to `drgnx-ai-retrievers' (once; the grep retriever stays)."
  ;; Not `add-to-list': the bare `defvar' above makes the compiler turn it into a `setq' the recorder cannot see.
  (eval-after-load 'drgnx-ai-ui
    (drgnx-modules-with-owner
      (unless (memq #'drgnx-search--retriever drgnx-ai-retrievers)
        (setq drgnx-ai-retrievers (append drgnx-ai-retrievers (list #'drgnx-search--retriever)))
        (drgnx-modules-push-undo "retriever drgnx-search--retriever"
                                 (lambda () (setq drgnx-ai-retrievers (remq #'drgnx-search--retriever drgnx-ai-retrievers))))))))

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
                                        (search-index-status "Index Status" drgnx-search-index-status "Chunks, files, models, device and lag of this project's index")
                                        (search-set-up "Set Up Semantic Search" drgnx-search-set-up "Offer the built-in model and a server, then index this project in the background")))
                         (drgnx-command-define id :category "Search" :title title :command fn :doc doc))
                       (drgnx-search--register-retriever)
                       ;; the hook only sets a flag; the timer tells the hub at most once per interval
                       (drgnx-module-hook 'post-command-hook typing ()
                         (setq drgnx-search--typed t))
                       (drgnx-timer-start 'search-typing drgnx-search-typing-interval #'drgnx-search--send-typing
                                          :repeat drgnx-search-typing-interval :owner 'tools/search)))

(provide 'drgnx-search)
;;; drgnx-search.el ends here
