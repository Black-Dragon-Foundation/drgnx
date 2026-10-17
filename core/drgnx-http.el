;;; drgnx-http.el --- HTTP/1.1 requests as they arrive, and the token counts in model answers -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What the agent gateway (drgnx-gateway.el) needs of HTTP, as pure functions on unibyte strings:
;; a request parsed from the bytes received so far, and a scanner that follows a model's answer — a
;; server-sent-event stream or one JSON body — for the tokens it reports.  See docs/develop/hub.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-http-max-body (* 32 1024 1024) "The largest request body taken (bytes).")
(defconst drgnx-http-max-head (* 64 1024) "The largest request head taken (bytes).")

(defun drgnx-http-parse-request (bytes)
  "The request in BYTES (unibyte), when all of it came: (:method :path :headers ((NAME . VALUE)…) :body :rest),
NAME in lower case, REST the bytes after it.  nil while it is incomplete; (:error STATUS) when it cannot be taken:
400 malformed, 411 a chunked body, 413 a body over `drgnx-http-max-body', 431 a head over `drgnx-http-max-head'."
  (let ((end (string-search "\r\n\r\n" bytes)))
    (cond
     ((and (not end) (> (length bytes) drgnx-http-max-head)) '(:error 431))
     ((not end) nil)
     ((> end drgnx-http-max-head) '(:error 431))
     (t
      (let* ((lines (split-string (substring bytes 0 end) "\r\n"))
             (start (car lines)))
        (if (not (string-match "\\`\\([A-Z]+\\) \\([^ ]+\\) HTTP/1\\.[01]\\'" start))
            '(:error 400)
          (let* ((method (match-string 1 start)) (path (match-string 2 start))
                 (headers (delq nil (mapcar (lambda (l)
                                              (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*?\\)[ \t]*\\'" l)
                                                (cons (downcase (match-string 1 l)) (match-string 2 l))))
                                            (cdr lines))))
                 (te (cdr (assoc "transfer-encoding" headers)))
                 (cl (cdr (assoc "content-length" headers)))
                 (len (if cl (string-to-number cl) 0))
                 (body-start (+ end 4)))
            (cond
             ((and te (string-match-p "chunked" te)) '(:error 411))
             ((and cl (not (string-match-p "\\`[0-9]+\\'" cl))) '(:error 400))
             ((> len drgnx-http-max-body) '(:error 413))
             ((< (- (length bytes) body-start) len) nil)
             (t (list :method method :path path :headers headers
                      :body (substring bytes body-start (+ body-start len))
                      :rest (substring bytes (+ body-start len))))))))))))

(defun drgnx-http-header (request name)
  "REQUEST's header NAME (lower case), or nil."
  (cdr (assoc name (plist-get request :headers))))

(defun drgnx-http--usage-from (json counts)
  "COUNTS (:input :output :cost) updated from one parsed JSON object."
  (let* ((usage (or (plist-get json :usage)
                    (plist-get (plist-get json :message) :usage)))
         (in (or (plist-get usage :input_tokens) (plist-get usage :prompt_tokens)))
         (out (or (plist-get usage :output_tokens) (plist-get usage :completion_tokens)))
         (cost (plist-get usage :cost)))
    (when (numberp in) (setq counts (plist-put counts :input in)))
    (when (numberp out) (setq counts (plist-put counts :output out)))
    (when (numberp cost) (setq counts (plist-put counts :cost cost)))
    counts))

(defun drgnx-http-usage-scanner ()
  "A function fed an answer's bytes as they come; it returns the tokens reported so far, (:input N :output N
:cost USD-or-nil).  It reads server-sent events (`data:' lines: an Anthropic stream reports input in
message_start, output in each message_delta) or one JSON body (`usage': input_tokens/output_tokens, or
prompt_tokens/completion_tokens; `cost' when the provider says)."
  (let ((pending "") (counts (list :input 0 :output 0 :cost nil)) (mode nil))
    (cl-flet ((parse (s) (ignore-errors (json-parse-string (decode-coding-string s 'utf-8)
                                                           :object-type 'plist :null-object nil :false-object nil))))
      (lambda (chunk)
        (setq pending (concat pending chunk))
        ;; the first byte that is not blank says which: `{' one JSON body, anything else events
        (unless mode
          (when (string-match "[^ \t\r\n]" pending)
            (setq mode (if (eq (aref pending (match-beginning 0)) ?{) 'json 'sse))))
        (pcase mode
          ('sse
           (while (string-match "\n" pending)
             (let ((line (string-trim-right (substring pending 0 (match-beginning 0)) "\r")))
               (setq pending (substring pending (match-end 0)))
               (when (string-prefix-p "data:" line)
                 (when-let* ((json (parse (string-trim (substring line 5)))))
                   (setq counts (drgnx-http--usage-from json counts)))))))
          ('json                                      ; parsed once it is whole (pending keeps it all)
           (when-let* ((json (parse pending)))
             (setq counts (drgnx-http--usage-from json counts)))))
        (copy-sequence counts)))))

(provide 'drgnx-http)
;;; drgnx-http.el ends here
