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
(require 'drgnx-quick-open)
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
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
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

;;;; Repo Map and Find Usages (Hrafn's `search/map' and `search/usages')

(defun drgnx-search--fresh-line (fresh)
  "What FRESH (a structural answer's `fresh') says lags, or nil when nothing does."
  (let ((n (or (plist-get fresh :files_pending) 0)))
    (when (> n 0) (format "%d file%s still to index" n (if (= n 1) "" "s")))))

(defun drgnx-search--list (buffer window items line empty)
  "Show ITEMS (xref items) in the panel's Results tab under LINE, as the command in BUFFER and WINDOW would (see
`drgnx-search--show-safely'); EMPTY is said when there are none.  Called from a callback: never signals."
  (require 'xref)
  (condition-case err
      (if (null items)
          (message "%s" empty)
        (let ((show (lambda ()
                      (xref-show-xrefs (lambda () items) nil)
                      (when-let* ((buf (get-buffer "*xref*")))
                        (with-current-buffer buf (setq header-line-format (concat " " line)))))))
          (if (buffer-live-p buffer)
              (with-current-buffer buffer
                (if (window-live-p window) (with-selected-window window (funcall show)) (funcall show)))
            (funcall show))
          (message "%s" line)))
    (error (message "Search could not show its results: %s" (error-message-string err)))))

(defun drgnx-search--map-items (root answer)
  "The xref items of a `search/map' ANSWER in the project at ROOT: each file's definitions, files in the map's order."
  (cl-loop for file in (append (plist-get answer :files) nil)
           append (mapcar (lambda (d)
                            (xref-make (string-trim (format "%s %s  %s" (plist-get d :kind) (plist-get d :name)
                                                            (or (plist-get d :sig) "")))
                                       (xref-make-file-location (expand-file-name (plist-get file :path) root)
                                                                (max 1 (plist-get d :line_start)) 0)))
                          (plist-get file :defs))))

(defun drgnx-search-repo-map ()
  "The project's most-referenced definitions, file by file, centred on the current file (Hrafn's repo map: what an
agent reads to find its way); each opens at its line from the panel's Results tab."
  (interactive)
  (require 'xref)
  (let* ((root (drgnx-search--root-or-error)) (buffer (current-buffer)) (window (selected-window))
         (file (and buffer-file-name (file-in-directory-p buffer-file-name root)
                    (file-relative-name buffer-file-name root))))
    (message "Mapping %s…" (abbreviate-file-name root))
    (drgnx-search--ask "search/map" (append (list :root (directory-file-name root))
                                            (and file (list :focus (vector file))))
                       (lambda (answer why)
                         (if (null answer)
                             (message "Repo Map: %s" (or why "no answer"))
                           (drgnx-search--list
                            buffer window (drgnx-search--map-items root answer)
                            (string-join (delq nil (list (car (last (split-string (or (plist-get answer :text) "")
                                                                                  "\n" t)))
                                                         (drgnx-search--fresh-line (plist-get answer :fresh))))
                                         "; ")
                            "Repo Map: no definitions indexed yet"))))))

(defun drgnx-search--usage-items (root answer)
  "The xref items of a `search/usages' ANSWER in the project at ROOT: the definitions, then each line a file uses the
name on, summarised by the definition that holds it."
  (let ((at (lambda (path line summary)
              (xref-make summary (xref-make-file-location (expand-file-name path root) (max 1 line) 0)))))
    (append
     (mapcar (lambda (d) (funcall at (plist-get d :path) (plist-get d :line_start)
                                  (concat "definition: " (plist-get d :sig))))
             (plist-get answer :defined))
     (cl-loop for u in (append (plist-get answer :usages) nil)
              append (mapcar (lambda (line)
                               (funcall at (plist-get u :path) line
                                        (if-let* ((e (plist-get u :enclosing))) (concat "in " e) "top level")))
                             (or (append (plist-get u :lines) nil) (list (plist-get u :line))))))))

(defun drgnx-search-usages (name)
  "Where NAME (default: the symbol at point) is defined and used in the project, by name (Hrafn's index: every
language it parses, without a language server); the uses land in the panel's Results tab."
  (interactive (progn (drgnx-search--root-or-error)
                      (let ((symbol (thing-at-point 'symbol t)))
                        (list (read-string (format-prompt "Find usages of" symbol) nil nil symbol)))))
  (require 'xref)
  (let ((root (drgnx-search--root-or-error)) (name (string-trim name))
        (buffer (current-buffer)) (window (selected-window)))
    (when (string-empty-p name) (user-error "Find Usages needs a name"))
    (drgnx-search--ask "search/usages" (list :root (directory-file-name root) :name name :k 100)
                       (lambda (answer why)
                         (if (null answer)
                             (message "Find Usages: %s" (or why "no answer"))
                           (drgnx-search--list
                            buffer window (drgnx-search--usage-items root answer)
                            (string-join (delq nil (list (format "Usages of %s" name)
                                                         (drgnx-search--fresh-line (plist-get answer :fresh))))
                                         "; ")
                            (format "Find Usages: %s is not used in the project" name)))))))

;;;; The xref backend: references and definitions by name, from the hub

(defvar drgnx-search-xref-timeout 5 "Seconds an xref request waits for the hub before it gives up.")

(defun drgnx-search-xref-backend ()
  "On `xref-backend-functions' (after a mode's or a language server's own): `drgnx-hrafn' in a project, so
Find References and Go to Definition answer from Hrafn's index where nothing better does."
  (and (drgnx-search--root) 'drgnx-hrafn))

(cl-defmethod xref-backend-identifier-at-point ((_ (eql drgnx-hrafn)))
  (thing-at-point 'symbol t))

(cl-defmethod xref-backend-identifier-completion-table ((_ (eql drgnx-hrafn)))
  nil)

(defun drgnx-search--usages-sync (name)
  "The hub's `search/usages' answer for NAME in the current project; a `user-error' when the hub cannot answer."
  (let ((root (drgnx-search--root-or-error)))
    (condition-case err
        (progn (drgnx-hub-ensure)
               (cons root (drgnx-hub-call-sync "search/usages" (list :root (directory-file-name root) :name name :k 100)
                                               drgnx-search-xref-timeout)))
      (error (user-error "Find references: %s" (drgnx-search--why err))))))

(cl-defmethod xref-backend-references ((_ (eql drgnx-hrafn)) identifier)
  (pcase-let ((`(,root . ,answer) (drgnx-search--usages-sync identifier)))
    (drgnx-search--usage-items root (plist-put (copy-sequence answer) :defined nil))))

(cl-defmethod xref-backend-definitions ((_ (eql drgnx-hrafn)) identifier)
  (pcase-let ((`(,root . ,answer) (drgnx-search--usages-sync identifier)))
    (drgnx-search--usage-items root (plist-put (copy-sequence answer) :usages nil))))

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
                                      '((go-quick-open "Quick Open" drgnx-quick-open "Open a file of the project by name")
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
                                        (search-set-up "Set Up Semantic Search" drgnx-search-set-up "Offer the built-in model and a server, then index this project in the background")
                                        (search-repo-map "Repo Map" drgnx-search-repo-map "The project's most-referenced definitions, file by file, centred on this file (in the panel)")
                                        (search-usages "Find Usages" drgnx-search-usages "Where a name is defined and used in the project, by name, in every indexed language (in the panel)")))
                         (drgnx-command-define id :category "Search" :title title :command fn :doc doc))
                       ;; after the modes' and language servers' backends (depth 90): the answer where none is better
                       (add-hook 'xref-backend-functions #'drgnx-search-xref-backend 90)
                       (drgnx-search--register-retriever)
                       ;; the hook only sets a flag; the timer tells the hub at most once per interval
                       (drgnx-module-hook 'post-command-hook typing ()
                         (setq drgnx-search--typed t))
                       (drgnx-timer-start 'search-typing drgnx-search-typing-interval #'drgnx-search--send-typing
                                          :repeat drgnx-search-typing-interval :owner 'tools/search)))

(provide 'drgnx-search)
;;; drgnx-search.el ends here
