;;; search-mcp-test.el --- batch tests: the search MCP tool for agents, the CLI query, Ask the Codebase's retriever -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-mcp)
(require 'drgnx-search-store)
(require 'drgnx-search-query)
(require 'drgnx-search-mcp)
(load (expand-file-name "modules/tools/drgnx-search" drgnx-dir) nil t)

(defconst drgnx-search-mcp-test--dims 32)

(defun drgnx-search-mcp-test--embed-text (text)
  "A deterministic unit vector for TEXT: each word adds a +-1 pattern from its md5."
  (let ((v (make-vector drgnx-search-mcp-test--dims 0.0)))
    (dolist (word (split-string (downcase text) "[^[:alnum:]_]+" t))
      (let ((digest (secure-hash 'md5 word nil nil t)))
        (dotimes (i drgnx-search-mcp-test--dims)
          (aset v i (+ (aref v i) (if (zerop (logand 1 (ash (aref digest (% (/ i 8) 16)) (- (% i 8))))) -1.0 1.0))))))
    (let ((norm (sqrt (cl-loop for x across v sum (* x x)))))
      (vconcat (mapcar (lambda (x) (if (zerop norm) x (/ x norm))) v)))))

(defun drgnx-search-mcp-test--embed (inputs)
  "Stands for `drgnx-ai-embed-sync' (and the editor's embedder): the stub vectors of INPUTS."
  (setq drgnx-ai-embed-last-info '(:provider stub :model "stub-1"))
  (vconcat (mapcar #'drgnx-search-mcp-test--embed-text inputs)))

(defconst drgnx-search-mcp-test--texts
  '("open the database connection and read rows\nsecond line of the chunk"
    "render the user interface window"
    "parse json configuration file"))

(defmacro drgnx-search-mcp-test--project (&rest body)
  "Run BODY in a git project ROOT whose state dir is temporary; INDEXED: its index is built from the stub texts."
  (declare (indent 0))
  `(progn
     (skip-unless (sqlite-available-p))
     (let* ((root (directory-file-name (make-temp-file "drgnx-mcp-proj" t)))
            (state (make-temp-file "drgnx-mcp-state" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
            (drgnx-search-last-notice nil)
            (default-directory (file-name-as-directory root)))
       (make-directory (expand-file-name ".git" root))
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-ai-embed-sync) #'drgnx-search-mcp-test--embed))
             ,@body)
         (delete-directory root t)
         (delete-directory state t)))))

(defun drgnx-search-mcp-test--build-index (root)
  (let ((db (drgnx-search-store-open root)) (line 0))
    (unwind-protect
        (progn
          (drgnx-search-store-put-file
           db "src/a.el" "h"
           (mapcar (lambda (text) (list :start (cl-incf line) :end line :text text
                                        :vector (drgnx-search-mcp-test--embed-text text)))
                   drgnx-search-mcp-test--texts))
          (drgnx-search-store-set-meta db (list :provider 'stub :model "stub-1" :dims drgnx-search-mcp-test--dims
                                                :indexed-at (float-time))))
      (sqlite-close db))))

(defun drgnx-search-mcp-test--call (root args)
  "The reply of the server for a tools/call of `search' with ARGS (a plist): (TEXT . IS-ERROR)."
  (let* ((tools (drgnx-search-mcp-tools root))
         (reply (drgnx-mcp-handle "drgnx-search" tools
                                  (list :jsonrpc "2.0" :id 1 :method "tools/call"
                                        :params (list :name "search" :arguments args))))
         (result (plist-get reply :result)))
    (cons (plist-get (aref (plist-get result :content) 0) :text) (plist-get result :isError))))

;;;; The tool

(ert-deftest drgnx-search-mcp/tool-answers-like-the-editor ()
  (drgnx-search-mcp-test--project
    (drgnx-search-mcp-test--build-index root)
    (let* ((editor (drgnx-search root "database connection rows" :embed #'drgnx-search-mcp-test--embed))
           (top (car editor))
           (answer (drgnx-search-mcp-test--call root '(:query "database connection rows")))
           (lines (split-string (car answer) "\n" t)))
      (should (null (cdr answer)))
      (should (= (length lines) (length editor)))
      ;; the tool's first line is the editor's first hit: PATH:LINE: first line of the chunk
      (should (equal (car lines) (format "%s:%d: %s" (plist-get top :path) (plist-get top :start)
                                         "open the database connection and read rows")))
      (should (equal (car lines) "src/a.el:1: open the database connection and read rows"))
      ;; every line has the grep format
      (dolist (l lines) (should (string-match-p "\\`src/a\\.el:[0-9]+: ." l))))))

(ert-deftest drgnx-search-mcp/k-limits-the-lines-and-is-clamped ()
  (drgnx-search-mcp-test--project
    (drgnx-search-mcp-test--build-index root)
    (should (= (length (split-string (car (drgnx-search-mcp-test--call root '(:query "database" :k 1))) "\n" t)) 1))
    (should (= (length (split-string (car (drgnx-search-mcp-test--call root '(:query "database" :k 0))) "\n" t)) 1))
    (should (= (length (split-string (car (drgnx-search-mcp-test--call root '(:query "database" :k 500))) "\n" t)) 3))))

(ert-deftest drgnx-search-mcp/path-names-the-project ()
  (drgnx-search-mcp-test--project
    (drgnx-search-mcp-test--build-index root)
    (let ((other (directory-file-name (make-temp-file "drgnx-mcp-other" t))))
      (unwind-protect
          (progn
            ;; a sub-directory of the project resolves to the project; the default is the server's root
            (make-directory (expand-file-name "src" root))
            (should (string-prefix-p "src/a.el:1:" (car (drgnx-search-mcp-test--call
                                                         other (list :query "database connection rows" :path (expand-file-name "src" root))))))
            ;; outside any git project: an error result, nothing searched
            (let ((r (drgnx-search-mcp-test--call root (list :query "x" :path other))))
              (should (cdr r))
              (should (string-match-p "not inside a git project" (car r)))))
        (delete-directory other t)))))

(ert-deftest drgnx-search-mcp/missing-index-is-a-clear-error ()
  (drgnx-search-mcp-test--project
    (let ((r (drgnx-search-mcp-test--call root '(:query "database"))))
      (should (cdr r))
      (should (string-match-p "no index for .* — run `drgnx search index .*` or Search: Index Project" (car r)))
      (should (string-search root (car r))))))

(ert-deftest drgnx-search-mcp/an-empty-query-is-an-error ()
  (drgnx-search-mcp-test--project
    (drgnx-search-mcp-test--build-index root)
    (should (cdr (drgnx-search-mcp-test--call root '(:query "  "))))))

(ert-deftest drgnx-search-mcp/a-notice-is-the-last-line ()
  (drgnx-search-mcp-test--project
    (drgnx-search-mcp-test--build-index root)
    (cl-letf (((symbol-function 'drgnx-ai-embed-sync) (lambda (_) (error "provider down"))))
      (let* ((r (drgnx-search-mcp-test--call root '(:query "database connection")))
             (lines (split-string (car r) "\n" t)))
        (should (null (cdr r)))
        (should (string-prefix-p "src/a.el:" (car lines)))
        (should (string-prefix-p "note: no embedding provider answered" (car (last lines))))))))

(ert-deftest drgnx-search-mcp/the-tool-is-listed-with-its-schema ()
  (let* ((tools (drgnx-search-mcp-tools "/x"))
         (reply (drgnx-mcp-handle "drgnx-search" tools (list :jsonrpc "2.0" :id 1 :method "tools/list")))
         (tool (aref (plist-get (plist-get reply :result) :tools) 0)))
    (should (equal (plist-get tool :name) "search"))
    (should (equal (plist-get (plist-get tool :inputSchema) :required) ["query"]))
    (should (hash-table-p (plist-get (plist-get tool :inputSchema) :properties)))))

(ert-deftest drgnx-search-mcp/server-spec-carries-the-embed-environment ()
  (let* ((process-environment (append '("XDG_STATE_HOME=/tmp/st" "DRGNX_DATA_DIR=/tmp/dd") process-environment))
         (spec (drgnx-search-mcp-server-spec "/some/project")))
    (should (equal (plist-get spec :name) "drgnx-search"))
    (should (stringp (plist-get spec :command)))
    (let ((args (append (plist-get spec :args) nil)))
      (should (member "drgnx-search-mcp-main" args))
      (should (equal (car (last args)) "/some/project")))
    (let ((env (mapcar (lambda (e) (cons (plist-get e :name) (plist-get e :value))) (plist-get spec :env))))
      (should (equal (cdr (assoc "XDG_STATE_HOME" env)) "/tmp/st"))
      (should (equal (cdr (assoc "DRGNX_DATA_DIR" env)) "/tmp/dd")))))

;;;; The command line

(ert-deftest drgnx-search-mcp/cli-query-prints-the-lines ()
  (skip-unless (and (sqlite-available-p) (executable-find "bash")))
  (let* ((root (directory-file-name (make-temp-file "drgnx-mcp-cli" t)))
         (state (make-temp-file "drgnx-mcp-cli-state" t))
         (process-environment (append (list (concat "XDG_STATE_HOME=" state)) process-environment))
         (script (expand-file-name "bin/drgnx" drgnx-dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (let ((drgnx-search-last-notice nil))
            (cl-letf (((symbol-function 'drgnx-ai-embed-sync) #'drgnx-search-mcp-test--embed))
              (drgnx-search-mcp-test--build-index root)))
          ;; the subprocess has the stub index but not the stub embedder: whatever it says, the keyword hits come
          (with-temp-buffer
            (let* ((err (make-temp-file "drgnx-mcp-err"))
                   (status (call-process script nil (list t err) nil "search" "query" root "database" "connection" "-k" "2")))
              (should (= status 0))
              (should (string-match-p "\\`src/a\\.el:[0-9]+: open the database connection" (buffer-string)))
              (should (<= (length (split-string (buffer-string) "\n" t)) 2))
              (delete-file err)))
          ;; no index: status 1 and a clear message
          (let ((other (directory-file-name (make-temp-file "drgnx-mcp-cli2" t))))
            (unwind-protect
                (progn
                  (make-directory (expand-file-name ".git" other))
                  (with-temp-buffer
                    (should (= 1 (call-process script nil (list t t) nil "search" "query" other "x")))
                    (should (string-match-p "no index for" (buffer-string)))))
              (delete-directory other t))))
      (delete-directory root t)
      (delete-directory state t))))

;;;; Ask the Codebase

(ert-deftest drgnx-search/retriever-gives-snippets ()
  (drgnx-search-mcp-test--project
    (drgnx-search-mcp-test--build-index root)
    (let ((calls nil) (hits (list (list :path "src/a.el" :start 7 :end 9 :text "chunk text\nmore" :score 0.1 :why 'both))))
      (cl-letf (((symbol-function 'drgnx-search-async)
                 (lambda (_root _q callback &rest _) (funcall callback hits))))
        (drgnx-search--retriever "where is the database" root (lambda (s) (push s calls))))
      (should (= (length calls) 1))
      (should (equal (car calls) '((:file "src/a.el" :line 7 :text "chunk text\nmore")))))))

(ert-deftest drgnx-search/retriever-is-registered-and-keeps-grep ()
  (require 'drgnx-ai-ui)
  (let ((drgnx-ai-retrievers (list #'drgnx-ai--grep-retriever)))
    (drgnx-search--register-retriever)
    (drgnx-search--register-retriever)
    (should (equal drgnx-ai-retrievers (list #'drgnx-ai--grep-retriever #'drgnx-search--retriever)))))

(ert-deftest drgnx-search/retriever-without-an-index-answers-nil-once ()
  (drgnx-search-mcp-test--project
    (let ((calls nil) (asked nil))
      (cl-letf (((symbol-function 'drgnx-search-async) (lambda (&rest _) (setq asked t))))
        (drgnx-search--retriever "anything" root (lambda (s) (push (list s) calls))))
      (should (equal calls '((nil))))
      (should-not asked))))

(ert-deftest drgnx-search/retriever-answers-nil-once-when-the-search-fails ()
  (drgnx-search-mcp-test--project
    (drgnx-search-mcp-test--build-index root)
    (let ((calls nil))
      ;; the search signals before it calls back
      (cl-letf (((symbol-function 'drgnx-search-async) (lambda (&rest _) (error "boom"))))
        (drgnx-search--retriever "q" root (lambda (s) (push (list s) calls))))
      (should (equal calls '((nil))))
      ;; the search calls back twice: still once
      (setq calls nil)
      (cl-letf (((symbol-function 'drgnx-search-async)
                 (lambda (_r _q cb &rest _) (funcall cb nil) (funcall cb nil))))
        (drgnx-search--retriever "q" root (lambda (s) (push (list s) calls))))
      (should (= (length calls) 1))
      ;; the snippets cannot be made: nil, once
      (setq calls nil)
      (cl-letf (((symbol-function 'drgnx-search-async)
                 (lambda (_r _q cb &rest _) (funcall cb '(garbage)))))
        (drgnx-search--retriever "q" root (lambda (s) (push (list s) calls))))
      (should (equal calls '((nil)))))))

(provide 'search-mcp-test)
;;; search-mcp-test.el ends here
