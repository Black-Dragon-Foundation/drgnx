;;; drgnx-ai-client.el --- Requests to AI providers: chat and fill-in-the-middle, fallback along a role -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every request is a curl process — Emacs never waits for a provider.  The request (address, headers with
;; the key, body) goes to curl on its standard input (`-K -'), so a key is never in a command line.  A role's
;; chain is tried in order: a provider without its key or the capability is skipped; a refused connection, a
;; timeout, an error status or an answer that does not parse moves on to the next; the callback hears the text
;; and which provider gave it, or the reasons none did.  See docs/guide/ai.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-ai)

(cl-defstruct (drgnx-ai-request (:constructor drgnx-ai--make-request) (:copier nil))
  process cancelled callback chain kind payload timeout fallbacks interactive waits)

;;;; curl

(defun drgnx-ai--config-string (s)
  "S quoted for a curl config file."
  (concat "\"" (replace-regexp-in-string "[\"\\]" "\\\\\\&" (replace-regexp-in-string "\n" "\\\\n" s)) "\""))

(cl-defun drgnx-ai--curl (url callback &key body key (timeout 30))
  "Request URL (POST BODY, a plist, when given) with KEY as a bearer token; CALLBACK gets (STATUS TEXT): the HTTP
status (0 when no answer came) and the answer.  Returns the process."
  (let* ((config (concat "url = " (drgnx-ai--config-string url) "\n"
                         (if timeout (format "max-time = %s\n" timeout) "")   ; nil: no limit
                         "silent\nshow-error\n"
                         "write-out = \"\\n%{http_code}\"\n"
                         (if body (concat "header = \"Content-Type: application/json\"\n"
                                          "data-binary = " (drgnx-ai--config-string (json-serialize body)) "\n")
                           "")
                         (if key (concat "header = " (drgnx-ai--config-string (concat "Authorization: Bearer " key)) "\n") "")))
         ;; the buffers after the config (it may not encode) and gone again if curl does not start
         (out (generate-new-buffer " *drgnx-ai*" t)) (err (generate-new-buffer " *drgnx-ai-err*" t))
         (proc (condition-case e
                   (make-process :name "drgnx-ai" :buffer out :command '("curl" "-K" "-") :connection-type 'pipe
                                 :coding 'binary :noquery t :stderr err
                                 :sentinel
                                 (lambda (p _)
                                   (unless (process-live-p p)
                                     (let* ((text (with-current-buffer (process-buffer p) (decode-coding-string (buffer-string) 'utf-8-unix)))   ; the answer exactly: no EOL conversion
                                            (cut (string-match "\n\\([0-9]+\\)\\'" text))
                                            (status (if cut (string-to-number (match-string 1 text)) 0)))
                                       (kill-buffer (process-buffer p))
                                       (when (buffer-live-p err) (kill-buffer err))
                                       (unless (process-get p :cancelled)
                                         (with-demoted-errors "drgnx ai: %S"
                                           (funcall callback (if (eql 0 (process-exit-status p)) status 0)
                                                    (if cut (substring text 0 cut) text))))))))
                 (error (kill-buffer out) (kill-buffer err) (signal (car e) (cdr e))))))
    ;; a curl that exits at once is gone before its config: its sentinel has the answer
    (ignore-errors (process-send-string proc (encode-coding-string config 'utf-8)) (process-send-eof proc))
    proc))

;;;; What to send where, and what comes back

(defun drgnx-ai--fim-n (payload) (or (plist-get payload :max-tokens) 64))

(defun drgnx-ai--endpoint (provider kind model payload)
  "(URL . BODY) of a KIND (chat, fim or embed) request to PROVIDER (its plist) for MODEL."
  (let ((url (plist-get provider :url)) (msgs (plist-get payload :messages)) (inputs (plist-get payload :inputs)))
    (pcase (list (plist-get provider :kind) kind)
      (`(tei embed) (cons (concat url "/embed") (list :inputs inputs :truncate t)))   ; no model: the server has one
      (`(ollama embed) (cons (concat url "/api/embed") (list :model model :input inputs)))
      (`(llamacpp embed) (cons (concat url "/v1/embeddings") (append (and model (list :model model)) (list :input inputs))))
      (`(,_ embed) (cons (concat url "/embeddings") (append (and model (list :model model)) (list :input inputs))))
      (`(ollama chat) (cons (concat url "/api/chat") (list :model model :messages msgs :stream :false)))
      (`(ollama fim) (cons (concat url "/api/generate")
                           (list :model model :prompt (plist-get payload :prefix) :suffix (plist-get payload :suffix) :stream :false
                                 :options (list :num_predict (drgnx-ai--fim-n payload) :temperature 0))))
      (`(llamacpp chat) (cons (concat url "/v1/chat/completions") (list :model model :messages msgs :stream :false)))
      (`(llamacpp fim) (cons (concat url "/infill")
                             (list :input_prefix (plist-get payload :prefix) :input_suffix (plist-get payload :suffix)
                                   :n_predict (drgnx-ai--fim-n payload))))
      (`(,_ chat) (cons (concat url "/chat/completions") (list :model model :messages msgs :stream :false)))
      (`(,_ fim) (cons (concat url "/completions")
                       (list :model model :prompt (plist-get payload :prefix) :suffix (plist-get payload :suffix)
                             :max_tokens (drgnx-ai--fim-n payload) :temperature 0 :stream :false))))))

(defun drgnx-ai--unit (v)
  "The vector V of numbers as a vector of floats of length 1 (zero stays zero), or nil if it holds anything else
or a number that is not finite."
  (when (and (vectorp v) (> (length v) 0) (cl-every #'numberp v))
    (let* ((f (vconcat (mapcar #'float v)))
           (big (cl-loop for x across f maximize (abs x))))
      (when (cl-every (lambda (x) (< (abs x) 1.0e+INF)) f)
        (if (zerop big) f
          ;; scaled by the largest entry first: squares of tiny numbers underflow to 0 (a nonzero vector with norm 0)
          ;; and of huge ones overflow
          (let* ((s (vconcat (mapcar (lambda (x) (/ x big)) f)))
                 (norm (sqrt (cl-loop for x across s sum (* x x)))))
            (vconcat (mapcar (lambda (x) (/ x norm)) s))))))))

(defun drgnx-ai--embeddings (provider json)
  "The vectors in a parsed embedding answer JSON from PROVIDER, each of length 1, or nil when it is not that."
  (ignore-errors
    (let ((raw (pcase (plist-get provider :kind)
                 ('tei json)
                 ('ollama (plist-get json :embeddings))
                 (_ (and (vectorp (plist-get json :data))
                         ;; data[] may come in any order: :index says which input a vector is for
                         (let ((data (append (plist-get json :data) nil)))
                           (when (cl-every (lambda (d) (integerp (plist-get d :index))) data)
                             (setq data (sort data (lambda (a b) (< (plist-get a :index) (plist-get b :index))))))
                           (vconcat (mapcar (lambda (d) (plist-get d :embedding)) data))))))))
      (when (vectorp raw)
        (let ((units (vconcat (mapcar #'drgnx-ai--unit raw))))
          (and (cl-every #'identity units) units))))))

(defun drgnx-ai--extract (provider kind json)
  "The text (embed: the vector of unit float vectors) in a parsed answer JSON from PROVIDER to a KIND request, or nil."
  (let ((first (lambda (v) (and (vectorp v) (> (length v) 0) (aref v 0)))))
    (pcase (list (plist-get provider :kind) kind)
      (`(,_ embed) (drgnx-ai--embeddings provider json))
      (`(ollama chat) (plist-get (plist-get json :message) :content))
      (`(ollama fim) (plist-get json :response))
      (`(llamacpp fim) (plist-get json :content))
      (`(,_ chat) (plist-get (plist-get (funcall first (plist-get json :choices)) :message) :content))
      (`(,_ fim) (plist-get (funcall first (plist-get json :choices)) :text)))))

;;;; Requests along a role

(defvar drgnx-ai-refused-functions nil
  "Run with a provider id when a request to it found nothing listening (curl could not connect): the local runner
onboarding set up is started again from here (`drgnx-ai-ensure-local').  Called from a process sentinel: never
prompt or wait.")

;; hooked here, where the functions run: a process that never loaded the probe (a search, a script) loads it on the
;; first refusal
(autoload 'drgnx-ai--refused "drgnx-ai-probe")
(add-hook 'drgnx-ai-refused-functions #'drgnx-ai--refused)

(cl-defun drgnx-ai-request (role kind payload callback &key (timeout 30) chain interactive waits)
  "Ask ROLE's providers (or CHAIN's: ((PROVIDER . MODEL)…)), in order, for a KIND answer (`chat': PAYLOAD
(:messages [(:role :content)…]); `fim': (:prefix :suffix :max-tokens); `embed': (:inputs [STRING…])).  CALLBACK
gets (TEXT INFO): INFO (:provider :model :fallbacks ((PROVIDER . WHY)…)), and :error when no provider answered
(TEXT nil).  For `embed' TEXT is the vector of the inputs' vectors (float vectors of length 1; a zero vector stays
zero), where an answer with other numbers or another count moves on to the next provider.  INTERACTIVE:
a command the user ran (keys may come from sources that ask, see `drgnx-ai-key').  Returns a handle for
`drgnx-ai-cancel'.  Providers with a key are asked through the hub's gateway (`drgnx-ai-route'): WAITS says the
caller waits for the answer anyway, so the first request may wait for the hub to start (a command or batch process;
INTERACTIVE and a batch Emacs wait too, a daemon path never does).  Without a token yet a provider is skipped with
\"drgnx hub is starting; try again\"."
  (let ((h (drgnx-ai--make-request :callback callback :chain (or chain (drgnx-ai-role role)) :kind kind :payload payload
                                   :timeout timeout :interactive interactive :waits waits)))
    (if (and (eq kind 'embed) (zerop (length (plist-get payload :inputs))))
        ;; nothing to embed: no provider is asked (and no key looked up)
        (run-at-time 0 nil (lambda ()
                             (unless (drgnx-ai-request-cancelled h)
                               (funcall callback [] (list :provider nil :model nil :fallbacks nil)))))
      (drgnx-ai--next h))
    h))

(defun drgnx-ai--next (h)
  "Send H to the next provider of its chain that can take it, or tell its callback none could."
  (let ((step (pop (drgnx-ai-request-chain h))) (kind (drgnx-ai-request-kind h)))
    (if (null step)
        (funcall (drgnx-ai-request-callback h) nil
                 (list :fallbacks (reverse (drgnx-ai-request-fallbacks h))
                       :error (if (drgnx-ai-request-fallbacks h)
                                  (mapconcat (lambda (f) (format "%s: %s" (car f) (cdr f))) (reverse (drgnx-ai-request-fallbacks h)) "; ")
                                "no provider for this")))
      (let* ((id (car step)) (model (cdr step)) (p (drgnx-ai-provider id))
             (cap (and p (memq kind (plist-get p :caps))))
             (late nil)
             ;; (:url :key): through the gateway for a provider with a key (the hub adds it), else direct
             (route (and cap (condition-case e (drgnx-ai-route id (drgnx-ai-request-interactive h) (drgnx-ai-request-waits h))
                               (drgnx-ai-gateway-unavailable (setq late (error-message-string e)) nil))))
             (key (plist-get route :key))
             (skip (cond ((null p) "not configured")
                         ((not cap) (format "cannot %s" kind))
                         (late late)
                         ((null route) "no key"))))
        (if skip
            (progn (push (cons id skip) (drgnx-ai-request-fallbacks h)) (drgnx-ai--next h))
          (pcase-let ((`(,url . ,body) (drgnx-ai--endpoint (plist-put (copy-sequence p) :url (plist-get route :url)) kind model
                                                           (drgnx-ai-request-payload h))))
            (condition-case e
                (setf (drgnx-ai-request-process h)
                      (drgnx-ai--curl url
                                      (lambda (status text)
                                        (let* ((json (and (<= 200 status 299)
                                                          (ignore-errors (json-parse-string text :object-type 'plist :null-object nil :false-object nil))))
                                               (out (and json (drgnx-ai--extract p kind json))))
                                          (if (if (eq kind 'embed)   ; one vector per input
                                                  (and out (= (length out) (length (plist-get (drgnx-ai-request-payload h) :inputs))))
                                                (stringp out))
                                              (funcall (drgnx-ai-request-callback h) out
                                                       (list :provider id :model model :fallbacks (reverse (drgnx-ai-request-fallbacks h))))
                                            (when (and (eql status 0) (drgnx-ai-request-process h)
                                                       (eql 7 (process-exit-status (drgnx-ai-request-process h))))   ; curl: could not connect
                                              (with-demoted-errors "drgnx ai: %S" (run-hook-with-args 'drgnx-ai-refused-functions id)))
                                            (push (cons id (cond ((eql status 0) "no answer")
                                                                 ((not (<= 200 status 299)) (format "HTTP %d" status))
                                                                 (t "an answer that does not parse")))
                                                  (drgnx-ai-request-fallbacks h))
                                            (unless (drgnx-ai-request-cancelled h) (drgnx-ai--next h)))))
                                      :body body :key key :timeout (drgnx-ai-request-timeout h)))
              ;; a body that does not encode (a raw byte), no curl: a reason, and the next provider
              (error (push (cons id (format "cannot send (%s)" (error-message-string e))) (drgnx-ai-request-fallbacks h))
                     (drgnx-ai--next h)))
            (when (drgnx-ai-request-cancelled h) (drgnx-ai-cancel h))))))))

(define-error 'drgnx-ai-embed-error "Embeddings failed")

(defvar drgnx-ai-embed-last-info nil
  "INFO (:provider :model :fallbacks) of the last answer `drgnx-ai-embed-sync' returned: who gave the vectors.
A mirror for callers that read it after the call; two requests in flight overwrite each other, so a caller that
needs its own request's answer passes `:on-answer' instead.")

(cl-defun drgnx-ai-embed-sync (inputs &key (timeout 30) interactive chain on-answer)
  "The vectors (a vector of float vectors of length 1) of the vector INPUTS from the `embed' role (or CHAIN,
\((PROVIDER . MODEL)…), instead), waiting for them.  Each provider gets TIMEOUT seconds (nil: no limit).
ON-ANSWER, a function, is called with this request's INFO (:provider :model :fallbacks) when it was answered;
`drgnx-ai-embed-last-info' mirrors the last one.  Signals `drgnx-ai-embed-error' with the providers'
reasons when none answers.  C-g ends the request (its curl is killed).
Only for batch processes and commands the user ran (INTERACTIVE as for `drgnx-ai-request'): it waits, so never
from a timer, hook or sentinel."
  (if (zerop (length inputs))
      (let ((info (list :provider nil :model nil :fallbacks nil)))   ; nobody was asked
        (setq drgnx-ai-embed-last-info info)
        (when on-answer (funcall on-answer info))
        [])
    (let* ((result nil)
           (chain (or chain (drgnx-ai-role 'embed)))
           (h (drgnx-ai-request 'embed 'embed (list :inputs inputs) (lambda (v info) (setq result (cons v info)))
                                :timeout timeout :chain chain :interactive interactive :waits t))
           (deadline (and timeout (+ (float-time) (* timeout (1+ (length chain)))))))
      (unwind-protect
          (while (and (not result) (or (null deadline) (< (float-time) deadline)))
            (let ((p (drgnx-ai-request-process h)))
              (accept-process-output (and p (process-live-p p) p) 0.05)))
        (unless result (drgnx-ai-cancel h)))
      (if (car result)
          (progn (setq drgnx-ai-embed-last-info (cdr result))
                 (when on-answer (funcall on-answer (cdr result)))
                 (car result))
        (signal 'drgnx-ai-embed-error (list (or (plist-get (cdr result) :error) "timed out")))))))

(defun drgnx-ai-cancel (h)
  "Cancel request H: its process ends, its callback never runs."
  (setf (drgnx-ai-request-cancelled h) t)
  (when-let* ((p (drgnx-ai-request-process h)))
    (process-put p :cancelled t)
    (when (process-live-p p) (delete-process p))))

(provide 'drgnx-ai-client)
;;; drgnx-ai-client.el ends here
