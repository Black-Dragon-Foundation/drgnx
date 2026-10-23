;;; fake-hub.el --- a hub that lies, for the client's tests: a wrong proof, no proof, a legacy hub -*- lexical-binding: t -*-
;; (drgnx-fake-hub-start SOCKET &key MODE HOLD-HELLO SILENT RECORDS) serves SOCKET in this Emacs (a plain server process, not
;; `drgnx-hub--server': the client treats it as another process's hub) and keeps every line it reads:
;; - MODE `v1' (the default): a challenge on accept, the client's proof checked, the hub's proof right;
;; - `wrong-proof': the same, but the hub's proof is made with another cap;
;; - `no-proof': the same, but the reply carries no proof;
;; - `legacy': no challenge, no `hello' ("no method hello", as the Lisp hub of before protocol 1 answers); it ends on
;;   `shutdown'.
;; HOLD-HELLO: hello answers wait for `drgnx-fake-hub-release'.  SILENT: methods never answered.  ERRORS: an alist
;; (METHOD . (:code :message :path)) of methods answered with that error.  RESULTS: an alist (METHOD . RESULT) of methods
;; answered with that result (the others with true).  DELAY: seconds before the answer to any other method (hello and
;; ping answer at once).
;; `drgnx-fake-hub-lines' are the requests read, oldest first; `drgnx-fake-hub-event' sends an event to every client.
;; The cap file is written beside SOCKET.
(require 'cl-lib)
(require 'drgnx-hub-client)

(defun drgnx-fake-hub--send (conn object)
  (when (process-live-p conn) (process-send-string conn (concat (json-serialize object) "\n"))))

(defun drgnx-fake-hub--hello (server conn id params)
  "The answer to hello PARAMS (request ID) on CONN."
  (let* ((cap (process-get server :cap)) (hub-nonce (process-get conn :nonce)) (nonce (plist-get params :nonce))
         (proof (plist-get params :proof))
         (valid (and proof (equal proof (drgnx-hub-hmac cap (format "drgnx-hub client %s %s" hub-nonce nonce))))))
    (if (and proof (not valid))
        (list :id id :error (list :code "not-allowed" :message "hello: the proof does not match"))
      (list :id id
            :result (append (list :proto 1 :proto_min 1 :drgnx_version "fake" :schema 6 :records (process-get server :records)
                                  :class (if valid "user" "service") :methods ["hello" "ping" "gateway/keys" "gateway/register"])
                            (and valid (not (eq (process-get server :mode) 'no-proof))
                                 (list :proof (drgnx-hub-hmac (if (eq (process-get server :mode) 'wrong-proof) (make-string 64 ?0) cap)
                                                              (format "drgnx-hub hub %s %s" nonce hub-nonce)))))))))

(defun drgnx-fake-hub--line (server conn json)
  (process-put server :lines (cons json (process-get server :lines)))
  (let ((id (plist-get json :id)) (method (plist-get json :method)))
    (cond ((member method (process-get server :silent)))
          ((null id))
          ((equal method "hello")
           (if (eq (process-get server :mode) 'legacy)
               (drgnx-fake-hub--send conn (list :id id :error (list :message "no method hello")))
             (let ((answer (drgnx-fake-hub--hello server conn id (plist-get json :params))))
               (if (process-get server :hold-hello)
                   (process-put server :held (cons (cons conn answer) (process-get server :held)))
                 (drgnx-fake-hub--send conn answer)))))
          ((equal method "ping") (drgnx-fake-hub--send conn (list :id id :result (list :pid (emacs-pid)))))
          ;; a legacy hub ends on shutdown, as the Lisp hub does
          ((and (equal method "shutdown") (eq (process-get server :mode) 'legacy))
           (drgnx-fake-hub--send conn (list :id id :result t))
           (drgnx-fake-hub-stop server))
          (t (let* ((err (cdr (assoc method (process-get server :errors))))
                    (result (assoc method (process-get server :results)))
                    (answer (if err (list :id id :error err) (list :id id :result (if result (cdr result) t))))
                    (delay (process-get server :delay)))
               (if delay (run-at-time delay nil #'drgnx-fake-hub--send conn answer)
                 (drgnx-fake-hub--send conn answer)))))))

(defun drgnx-fake-hub--filter (conn chunk)
  (let ((server (process-get conn :fake)) (buf (concat (or (process-get conn :buf) "") chunk)))
    (while (string-match "\n" buf)
      (let ((line (substring buf 0 (match-beginning 0))))
        (setq buf (substring buf (match-end 0)))
        (drgnx-fake-hub--line server conn (json-parse-string line :object-type 'plist :array-type 'list
                                                             :null-object nil :false-object :false))))
    (process-put conn :buf buf)))

(defun drgnx-fake-hub--accept (server conn _message)
  (process-put conn :fake server)
  (unless (eq (process-get server :mode) 'legacy)
    (process-put conn :nonce (substring (secure-hash 'sha256 (format "%s %s" (random) (float-time))) 0 32))
    (drgnx-fake-hub--send conn (list :event "challenge" :data (list :nonce (process-get conn :nonce))))))

(cl-defun drgnx-fake-hub-start (socket &key (mode 'v1) hold-hello silent (records 2) errors results delay)
  "Serve SOCKET as MODE (see the file's commentary), its hello saying RECORDS; the server process."
  (drgnx-hub--private-dir (file-name-directory socket))
  (let ((cap (secure-hash 'sha256 (format "cap %s %s" (random) (float-time))))
        (server (make-network-process :name "drgnx-fake-hub" :family 'local :server t :service socket :noquery t
                                      :coding 'utf-8-unix :filter #'drgnx-fake-hub--filter :log #'drgnx-fake-hub--accept)))
    (unless (eq mode 'legacy)
      (with-file-modes #o600 (write-region cap nil (concat (file-name-sans-extension socket) ".cap") nil 'silent)))
    (process-put server :cap cap)
    (process-put server :mode mode)
    (process-put server :hold-hello hold-hello)
    (process-put server :silent silent)
    (process-put server :records records)
    (process-put server :errors errors)
    (process-put server :results results)
    (process-put server :delay delay)
    server))

(defun drgnx-fake-hub-lines (server) "The requests SERVER read, oldest first." (reverse (process-get server :lines)))

(defun drgnx-fake-hub-methods (server) "The methods of the requests SERVER read, oldest first."
       (mapcar (lambda (j) (plist-get j :method)) (drgnx-fake-hub-lines server)))

(defun drgnx-fake-hub-release (server)
  "Send the hello answers SERVER holds."
  (dolist (h (reverse (process-get server :held))) (drgnx-fake-hub--send (car h) (cdr h)))
  (process-put server :held nil))

(defun drgnx-fake-hub-event (server event data)
  "Send EVENT (a string) with DATA to every connection SERVER accepted."
  (dolist (p (process-list))
    (when (eq (process-get p :fake) server) (drgnx-fake-hub--send p (list :event event :data data)))))

(defun drgnx-fake-hub-close-clients (server)
  "Close every connection SERVER accepted."
  (dolist (p (process-list))
    (when (eq (process-get p :fake) server) (delete-process p))))

(defun drgnx-fake-hub-stop (server)
  (drgnx-fake-hub-close-clients server)
  (let ((socket (process-contact server :service)))
    (delete-process server)
    (ignore-errors (delete-file socket))))

(provide 'drgnx-fake-hub)
;;; fake-hub.el ends here
