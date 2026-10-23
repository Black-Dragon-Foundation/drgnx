;;; drgnx-search-mcp.el --- Semantic code search for agents: the `search' MCP tool and `drgnx search query' -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Agents get the search the editor uses.  `drgnx-search-mcp-main' is a batch Emacs serving one tool, `search'
;; (query, k, path), over stdio (drgnx-mcp.el); it calls `drgnx-search' — the same function Semantic Search calls — so
;; the hits are the editor's.  The answer is text, one line per hit as grep prints it: PATH:LINE: first line of the
;; chunk, PATH relative to the project; a last line `note: …' says why an answer is partial (keywords only, …).
;; `drgnx search query ROOT QUESTION' prints the same lines.  The server never prompts: a key comes from its own
;; environment or a quiet auth-source (`drgnx-search-mcp-server-spec' passes no key: the spec goes to the agent).
;; See docs/guide/search.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-gc)
(require 'drgnx-mcp)
(require 'drgnx-search-store)
(require 'drgnx-search-query)
(require 'drgnx-settings-defaults)

(declare-function drgnx-search-index--dir-env "drgnx-search-index")

(defconst drgnx-search-mcp-max-k 50 "The most hits one search returns.")
(defconst drgnx-search-mcp-default-k 10)

(defun drgnx-search-mcp--project (path)
  "The root (a directory name without trailing slash) of the git project holding the directory PATH — its git top
level, so a sub-directory never makes an index of its own; an error when PATH is in none."
  (let ((dir (file-name-as-directory (expand-file-name path))))
    (or (drgnx-search-toplevel dir)
        (error "%s is not inside a git project" (directory-file-name dir)))))

(defun drgnx-search-mcp--line (hit)
  "HIT (a result of `drgnx-search') as `PATH:LINE: TEXT': TEXT the chunk's first top-level line
(`drgnx-search-hit-line'), LINE its number."
  (pcase-let ((`(,line . ,text) (drgnx-search-hit-line hit)))
    (format "%s:%d: %s" (plist-get hit :path) line (if (> (length text) 200) (substring text 0 200) text))))

(defun drgnx-search-mcp--search (root query k)
  "Search the project at ROOT for QUERY: (LINES . NOTICE).  An error when there is no index."
  (when-let* ((problem (plist-get (drgnx-search-config root) :error)))
    (signal 'error (list problem)))
  (unless (file-exists-p (drgnx-search-store-file root))
    ;; `signal', not `error': `error' would turn the backquote into a curly quote
    (signal 'error (list (format "no index for %s — run `drgnx search index %s` or Search: Index Project" root root))))
  (let ((hits (drgnx-search root query :k (max 1 (min drgnx-search-mcp-max-k (or k drgnx-search-mcp-default-k))))))
    (cons (mapcar #'drgnx-search-mcp--line hits) drgnx-search-last-notice)))

(defun drgnx-search-mcp--pinned-root (root path)
  "ROOT, for a server pinned to it (DRGNX_SEARCH_PINNED, set by the hub for a sandboxed agent): PATH, when given,
must name ROOT or a place inside it (lexically), or it is an error.  ROOT is searched whatever PATH names, and
nothing runs where PATH points: no git, no other project's index."
  (let ((root (directory-file-name (expand-file-name root))))
    (when (and (stringp path) (not (string-empty-p path)))
      (let ((p (directory-file-name (expand-file-name path root))))
        (unless (or (string= p root) (string-prefix-p (file-name-as-directory root) p))
          (error "%s is outside %s, the one project this server searches" path root))))
    root))

(defun drgnx-search-mcp--call (default-root args)
  "The `search' tool for ARGS (a plist: :query, :k, :path), the path defaulting to DEFAULT-ROOT.  Pinned
\(DRGNX_SEARCH_PINNED non-empty): DEFAULT-ROOT alone (`drgnx-search-mcp--pinned-root')."
  (let* ((query (string-trim (or (plist-get args :query) "")))
         (path (plist-get args :path))
         (pinned (let ((v (getenv "DRGNX_SEARCH_PINNED"))) (and v (not (string-empty-p v)))))
         (root (if pinned (drgnx-search-mcp--pinned-root default-root path)
                 (drgnx-search-mcp--project (if (and (stringp path) (not (string-empty-p path))) path default-root))))
         (k (plist-get args :k)))
    (when (string-empty-p query) (error "query is required: ask in words what the code does"))
    (when (and k (not (integerp k)))
      (signal 'drgnx-mcp-invalid-params (list "k must be an integer, 1 to 50")))
    (let ((answer (drgnx-search-mcp--search root query k)))
      (mapconcat #'identity
                 (append (or (car answer) (list "no matches"))
                         (and (cdr answer) (list (concat "note: " (cdr answer)))))
                 "\n"))))

(defun drgnx-search-mcp-tools (root)
  "The tools of the search server for the project at ROOT (the default of `path'): ((NAME :description :schema :call)…)."
  `(("search"
     :description "Search the project's code by meaning: ask in words what the code does and get the best chunks, one per line as PATH:LINE: first line (PATH relative to the project).  The exact words of the query are searched too.  A last line starting note: says when the answer is partial.  Needs the project's index (drgnx search index)."
     :schema ,(drgnx-mcp-schema
               '(("query" "string" "What you look for, in words")
                 ("k" "integer" "How many hits, 1 to 50 (default 10)")
                 ("path" "string" "The project (any path inside it); default: the server's project"))
               '("query"))
     :call ,(lambda (args) (drgnx-search-mcp--call root args)))))

(defun drgnx-search-mcp-main ()
  "Batch entry: `emacs --batch -L core -l drgnx-search-mcp -f drgnx-search-mcp-main [-- ROOT]'.
Serves the `search' tool on stdin/stdout for the project at ROOT (default: the working directory)."
  (drgnx-gc-batch-setup)
  (drgnx-settings-defaults-apply)               ; the embed role is the user's
  (let* ((args (cdr (member "--" command-line-args-left)))
         (root (expand-file-name (or (car args) default-directory))))
    (setq command-line-args-left nil)
    (let ((default-directory (file-name-as-directory root)))
      (drgnx-mcp-serve "drgnx-search" (drgnx-search-mcp-tools root)))))

(defun drgnx-search-mcp-server-spec (root)
  "The ACP `mcpServers' entry that gives an agent the `search' tool for the project at ROOT.
The entry goes to the agent, so its environment carries only the XDG and DRGNX_*_DIR variables — never a key: the
server reads a hosted provider's key from its own environment or auth-source, like any drgnx batch process.
Nothing adds it to a session by itself: see docs/guide/search.md."
  (require 'drgnx-search-index)
  ;; the agent starts this with the default SIGPIPE (libuv resets it): the command ignores it itself
  (let ((command (drgnx-command-ignoring-sigpipe
                  (list (expand-file-name invocation-name invocation-directory)
                        "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                        "-l" "drgnx-search-mcp" "-f" "drgnx-search-mcp-main" "--" (directory-file-name (expand-file-name root))))))
    (list :name "drgnx-search"
          :command (car command) :args (vconcat (cdr command))
          :env (vconcat (mapcar (lambda (e)
                                  (let ((i (string-search "=" e)))
                                    (list :name (substring e 0 i) :value (substring e (1+ i)))))
                                (drgnx-search-index--dir-env))))))

;;;; drgnx search query

(defun drgnx-search-mcp-query-cli ()
  "Batch entry: `… -f drgnx-search-mcp-query-cli -- ROOT QUESTION… [-k N]'.
Prints PATH:LINE: first line for each hit; the notice, if any, goes to stderr.  Exits 1 on an error (no index)."
  (drgnx-settings-defaults-apply)               ; the embed role is the user's
  (let* ((args (cdr (member "--" command-line-args-left))) (k nil) (words nil))
    (setq command-line-args-left nil)
    (while args
      (if (and (equal (car args) "-k") (cdr args))
          (setq k (string-to-number (cadr args)) args (cddr args))
        (push (pop args) words)))
    (setq words (nreverse words))
    (condition-case err
        (progn
          (when (< (length words) 2) (error "usage: drgnx search query ROOT QUESTION… [-k N]"))
          (let* ((root (drgnx-search-mcp--project (car words)))
                 (query (string-trim (mapconcat #'identity (cdr words) " ")))
                 (answer (progn (when (string-empty-p query) (error "usage: drgnx search query ROOT QUESTION… [-k N]"))
                                (drgnx-search-mcp--search root query k))))
            (dolist (line (car answer)) (princ (concat line "\n")))
            (when (cdr answer) (message "%s" (cdr answer)))
            (kill-emacs 0)))
      (error (message "drgnx search: %s" (error-message-string err))
             (kill-emacs 1)))))

(provide 'drgnx-search-mcp)
;;; drgnx-search-mcp.el ends here
