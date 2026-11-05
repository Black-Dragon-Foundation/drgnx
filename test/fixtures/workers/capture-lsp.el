;;; capture-lsp.el --- record a real language server's traffic into a replay corpus (batch Emacs, run in the container) -*- lexical-binding: t -*-
;; Run by capture-lsp.sh, once per server.  Environment:
;;   LSP_CAPTURE_NAME       corpus name (rust, c, ts)
;;   LSP_CAPTURE_CMD        the server's command line (a shell string)
;;   LSP_CAPTURE_ROOT       the fixture project (lsp-projects/NAME)
;;   LSP_CAPTURE_FILE       the file to open, relative to the root
;;   LSP_CAPTURE_LANG       its languageId
;;   LSP_CAPTURE_POSITIONS  completion positions, "LINE:COL,LINE:COL" (0-based)
;;   LSP_CAPTURE_QUIET      seconds without a server message that end a wait (default 4)
;;   LSP_CAPTURE_OUT        the corpus file to write (.eld.gz)
;; The corpus is what test/fixtures/lsp-replay.el serves (see its commentary): the initialize result, the server's own
;; notifications and requests in the order they came (after `initialized' and the file's didOpen), and the result of
;; every request the client made, by method.  Nothing here is invented: each body is a byte-for-byte server message.

;;; Code:
(require 'json)
(require 'subr-x)
(require 'cl-lib)
(require 'seq)

(defvar capture--proc nil)
(defvar capture--pending "")
(defvar capture--last (float-time) "When the last server message came.")
(defvar capture--next-id 0)
(defvar capture--sent nil "The client's requests: ((ID . METHOD)…).")
(defvar capture--init nil)
(defvar capture--notify nil "Server notifications and requests, newest first (bodies).")
(defvar capture--replies nil "((METHOD . RESULT-TEXT)…), newest first.")
(defvar capture--opened nil "Non-nil once the file was opened: server messages before that are part of initialize.")

(defun capture--env (name &optional default) (or (getenv name) default))

(defun capture--send (obj)
  (let ((body (encode-coding-string (json-serialize obj :null-object :null :false-object :false) 'utf-8)))
    (process-send-string capture--proc (format "Content-Length: %d\r\n\r\n%s" (length body) body))))

(defun capture--request (method params)
  (let ((id (cl-incf capture--next-id)))
    (push (cons id method) capture--sent)
    (capture--send `(:jsonrpc "2.0" :id ,id :method ,method :params ,params))
    id))

(defun capture--result-text (body)
  "The text of the \"result\" member of the JSON object BODY, byte for byte."
  (let ((i (string-match "\"result\" *:" body)))
    (when i
      (let* ((start (match-end 0)) (end (length body)))
        ;; the object ends with the closing brace after the result (the id may follow it)
        (with-temp-buffer
          (insert body) (goto-char (1+ start)) (skip-chars-forward " \t\n")
          (let ((beg (point)))
            (condition-case nil (progn (json-parse-buffer :null-object :null :false-object :false) (setq end (point)))
              (error nil))
            (string-trim (buffer-substring-no-properties beg end))))))))

(defun capture--handle (body)
  (setq capture--last (float-time))
  (let* ((obj (ignore-errors (json-parse-string body :object-type 'plist :null-object :null :false-object :false)))
         (id (plist-get obj :id)) (method (plist-get obj :method)))
    (when (plist-get obj :error) (message "capture: the server answered with an error: %S" (plist-get obj :error)))
    (cond
     ((and id (not method))                    ; a response to the client
      (let ((m (cdr (assq id capture--sent))))
        (if (equal m "initialize")
            (setq capture--init (capture--result-text body))
          (when m (push (cons m (capture--result-text body)) capture--replies)))))
     (t                                        ; a server notification or request
      (when capture--opened (push body capture--notify))
      (when (and id method)                    ; answer a server request so the server goes on (null result)
        (capture--send `(:jsonrpc "2.0" :id ,id :result :null)))))))

(defun capture--filter (_p s)
  (setq capture--pending (concat capture--pending s))
  (while (and (string-match "\\`Content-Length: *\\([0-9]+\\)\r\n\\(?:[^\r\n]+\r\n\\)*\r\n" capture--pending)
              (<= (+ (match-end 0) (string-to-number (match-string 1 capture--pending))) (length capture--pending)))
    (let* ((start (match-end 0)) (end (+ start (string-to-number (match-string 1 capture--pending))))
           (body (decode-coding-string (substring capture--pending start end) 'utf-8)))
      (setq capture--pending (substring capture--pending end))
      (capture--handle body))))

(defun capture--wait (seconds &optional until)
  "Wait until nothing came for SECONDS (or UNTIL says done), at most 120 s."
  (let ((deadline (+ (float-time) 120)))
    (setq capture--last (float-time))
    (while (and (< (float-time) deadline) (process-live-p capture--proc)
                (not (and until (funcall until)))
                (< (- (float-time) capture--last) seconds))
      (accept-process-output capture--proc 0.1))))

(defun capture--completions ()
  "How many completion answers have come."
  (seq-count (lambda (r) (equal (car r) "textDocument/completion")) capture--replies))

(let* ((name (capture--env "LSP_CAPTURE_NAME"))
       (root (expand-file-name (capture--env "LSP_CAPTURE_ROOT")))
       (file (expand-file-name (capture--env "LSP_CAPTURE_FILE") root))
       (lang (capture--env "LSP_CAPTURE_LANG"))
       (quiet (string-to-number (capture--env "LSP_CAPTURE_QUIET" "4")))
       (positions (mapcar (lambda (p) (mapcar #'string-to-number (split-string p ":")))
                          (split-string (capture--env "LSP_CAPTURE_POSITIONS") "," t)))
       (out (expand-file-name (capture--env "LSP_CAPTURE_OUT")))
       (uri (concat "file://" file)) (text (with-temp-buffer (insert-file-contents file) (buffer-string))))
  (setq capture--proc (make-process :name "lsp-capture" :command (list "sh" "-c" (capture--env "LSP_CAPTURE_CMD"))
                                    :connection-type 'pipe :coding 'binary :noquery t :stderr (get-buffer-create "*lsp-err*")
                                    :filter #'capture--filter :sentinel #'ignore))
  (capture--request "initialize"
                    `(:processId ,(emacs-pid) :rootUri ,(concat "file://" root)
                                 :capabilities (:textDocument (:completion (:completionItem (:snippetSupport :false :documentationFormat ["markdown" "plaintext"]))
                                                                           :publishDiagnostics (:relatedInformation t)
                                                                           :synchronization (:didSave t))
                                                              :window (:workDoneProgress t))
                                 :workspaceFolders [(:uri ,(concat "file://" root) :name "root")]))
  (capture--wait 30 (lambda () capture--init))
  (unless capture--init
    (error "no initialize result from %s (stderr: %s)" name
           (with-current-buffer "*lsp-err*" (buffer-substring-no-properties (max 1 (- (point-max) 600)) (point-max)))))
  (capture--send '(:jsonrpc "2.0" :method "initialized" :params ()))
  (setq capture--opened t)
  (capture--send `(:jsonrpc "2.0" :method "textDocument/didOpen"
                            :params (:textDocument (:uri ,uri :languageId ,lang :version 1 :text ,text))))
  (capture--wait quiet)                       ; indexing, diagnostics
  (let ((want 0))
    (dolist (pos positions)
      (setq want (1+ want))
      (capture--request "textDocument/completion"
                        `(:textDocument (:uri ,uri) :position (:line ,(car pos) :character ,(cadr pos))
                                        :context (:triggerKind 1)))
      (capture--wait 20 (lambda () (>= (capture--completions) want)))))
  (capture--request "textDocument/hover" `(:textDocument (:uri ,uri) :position (:line ,(car (car positions)) :character 1)))
  (capture--request "textDocument/documentSymbol" `(:textDocument (:uri ,uri)))
  (capture--wait quiet)
  (capture--request "shutdown" nil)
  (capture--wait 2)
  (capture--send '(:jsonrpc "2.0" :method "exit"))
  ;; completions: keep the largest answer as the one the replay serves (it is the richest list of real items)
  (let* ((completions (seq-filter (lambda (r) (equal (car r) "textDocument/completion")) capture--replies))
         (best (car (sort (copy-sequence completions) (lambda (a b) (> (length (cdr a)) (length (cdr b)))))))
         (replies (append (list best) (seq-remove (lambda (r) (equal (car r) "textDocument/completion")) (reverse capture--replies))))
         (replies (seq-uniq (delq nil replies) (lambda (a b) (equal (car a) (car b)))))
         (corpus (list :server name :command (capture--env "LSP_CAPTURE_CMD")
                       :init capture--init :notify (reverse capture--notify) :replies replies)))
    (make-directory (file-name-directory out) t)
    (with-temp-buffer (let ((print-length nil) (print-level nil) (coding-system-for-write 'utf-8-unix)) (prin1 corpus (current-buffer)))
                      (write-region nil nil out nil 'silent))
    (message "capture %s: init %d bytes, %d server messages, replies %S" name (length capture--init) (length capture--notify)
             (mapcar (lambda (r) (cons (car r) (length (cdr r)))) replies))
    (kill-emacs 0)))
;;; capture-lsp.el ends here
