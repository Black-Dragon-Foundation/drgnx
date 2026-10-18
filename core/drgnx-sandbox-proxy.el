;;; drgnx-sandbox-proxy.el --- A job's allowlisting proxy: CONNECT only, no TLS termination -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Phase 2 of the job sandbox (docs/develop/sandbox.md, "The proxy").  An isolated sandbox has no network but its own
;; loopback; the relay inside forwards the agent's `HTTPS_PROXY' to this proxy's Unix socket (on macOS, a random port
;; of 127.0.0.1).  One proxy per job, a batch Emacs started by the hub, so that streaming never blocks the hub:
;; `emacs --batch -Q -L CORE -l drgnx-sandbox-proxy -f drgnx-sandbox-proxy-main SOCKET|tcp ENTRY…'.
;;
;; It answers `CONNECT host:port' only.  A target on the job's allowlist gets `200' and the bytes are spliced both
;; ways as they are: TLS stays end to end.  Everything else gets `403': other methods, a bad request line, a head
;; larger than `drgnx-sandbox-proxy-max-head' or later than `drgnx-sandbox-proxy-head-timeout', a wildcard target, a
;; connection past `drgnx-sandbox-proxy-max-connections', a target not listed.  An address literal that is not public
;; and not listed says `refused HOST:PORT private' instead of `denied', so that no card offers it.  A target not listed is said once on stdout,
;; `denied HOST:PORT', so that the hub can ask the user with a card.
;;
;; Names are matched exactly after normalization (`drgnx-sandbox-proxy-normalize'); `*.example.com:443' matches
;; subdomains only.  A name is resolved once and the proxy connects to the address it checked, never resolving again:
;; DNS that answers only private, loopback or link-local addresses gets `403' (`refused HOST:PORT private' on
;; stdout), so a listed name cannot lead to the user's own loopback services.  Only an address literal on the list,
;; or a name pinned in `drgnx-sandbox-proxy-pinned-addresses', reaches such an address.
;;
;; The hub changes the list with stdin lines `allow HOST:PORT' and `deny HOST:PORT'.  A batch Emacs cannot wait on
;; stdin and sockets at once, so the start command hands stdin to the proxy as fd 3, and a `cat' child reads it
;; there; when the hub ends, stdin closes, `cat' ends, and the proxy with it.

;;; Code:
(require 'subr-x)

(declare-function puny-encode-domain "puny" (domain))
(defvar drgnx-dir)

(defcustom drgnx-sandbox-proxy-pinned-addresses nil
  "Names the job proxies resolve to a fixed address instead of asking DNS: ((NAME . ADDRESS)…), ADDRESS an IPv4 or
IPv6 literal.  A pinned name may lead to a private or loopback address (a registry on the company's network, a
test's local upstream); a name resolved through DNS never does.  Pinning only resolves: the name must still be on the
job's allowlist."
  :type '(alist :key-type string :value-type string) :group 'drgnx)

(defvar drgnx-sandbox-proxy-denied-functions nil
  "Called with (JOB HOST-PORT) for each target a job's proxy refused because it is not on the allowlist: once per
HOST-PORT and proxy.  HOST-PORT is normalized (`drgnx-sandbox-proxy-normalize'), so it can be passed back to
`drgnx-sandbox-proxy-allow' as it is.")

(defconst drgnx-sandbox-proxy-max-head 8192 "The largest request head, in bytes, the line and headers: a longer one gets 403.")

(defvar drgnx-sandbox-proxy-head-timeout 10
  "Seconds a client has to send its whole request head: then it gets 403.")

(defvar drgnx-sandbox-proxy-max-connections 64
  "The most client connections a proxy keeps at once: one more is answered 403 at once.")

(defconst drgnx-sandbox-proxy--max-early 65536
  "The most bytes a client may send after its head before the upstream is connected: more closes the connection.")

;;;; Names and addresses

(defun drgnx-sandbox-proxy--port (s)
  "S as a port, an integer 1-65535 written in decimal without a leading zero, else nil."
  (and (string-match-p "\\`[1-9][0-9]\\{0,4\\}\\'" s)
       (let ((n (string-to-number s))) (and (<= n 65535) n))))

(defun drgnx-sandbox-proxy--ipv4 (s)
  "S as an IPv4 address, a list of four octets, else nil.  Only four decimal parts without leading zeros: no
`127.1', `2130706433', `0x7f.0.0.1' or `017.0.0.1'."
  (let ((parts (split-string s "\\.")) octets)
    (when (= (length parts) 4)
      (catch 'bad
        (dolist (p parts (nreverse octets))
          (unless (string-match-p "\\`\\(?:0\\|[1-9][0-9]\\{0,2\\}\\)\\'" p) (throw 'bad nil))
          (let ((n (string-to-number p)))
            (when (> n 255) (throw 'bad nil))
            (push n octets)))))))

(defun drgnx-sandbox-proxy--ipv6 (s)
  "S (without brackets) as an IPv6 address, a list of eight 16-bit words, else nil.  No zone index."
  (when (and (string-match-p "\\`[0-9a-fA-F:.]+\\'" s) (string-search ":" s))
    (let ((a (car (ignore-errors (network-lookup-address-info s 'ipv6 'numeric)))))
      (and (vectorp a) (= (length a) 9) (append (substring a 0 8) nil)))))

(defun drgnx-sandbox-proxy--hostname (s)
  "S as a host name, in lower case with one trailing dot dropped, else nil.
Each label is letters, digits, `_' and inner `-', 1-63 bytes; the whole at most 253; and the last label starts with
a letter, so that no name is one a resolver would read as an address."
  (let ((case-fold-search nil) (h (downcase s)))
    (when (string-suffix-p "." h) (setq h (substring h 0 -1)))
    (and (<= 1 (length h) 253)
         (string-match-p "\\`[a-z0-9_.-]+\\'" h)
         (let ((labels (split-string h "\\.")))
           (and (catch 'bad
                  (dolist (l labels t)
                    (unless (string-match-p "\\`[a-z0-9_]\\(?:[a-z0-9_-]\\{0,61\\}[a-z0-9_]\\)?\\'" l) (throw 'bad nil))))
                (string-match-p "\\`[a-z]" (car (last labels)))))
         h)))

(defun drgnx-sandbox-proxy--literal (s)
  "S, an IPv4 literal or an IPv6 one in brackets or not, as an address vector without its port, else nil."
  (let ((o (drgnx-sandbox-proxy--ipv4 s)))
    (if o (vconcat o)
      (when (string-match "\\`\\[\\(.*\\)\\]\\'" s) (setq s (match-string 1 s)))
      (let ((w (drgnx-sandbox-proxy--ipv6 s))) (and w (vconcat w))))))

(defun drgnx-sandbox-proxy--parse (text &optional request)
  "TEXT, `HOST:PORT' or `*.NAME:PORT', parsed: (KEY NAME PORT ADDRESS), else nil.
KEY is the normalized text, NAME the host name (nil for an address), ADDRESS the address vector with PORT for an
address literal (an IPv6 one in brackets).  A name in Unicode becomes its IDNA ASCII form, unless REQUEST: a
request's target must already be ASCII.  A wildcard needs a name of two labels or more, and is never a REQUEST's
target (it would reach the apex, or ask the user for a wildcard grant)."
  (let ((case-fold-search nil))
    (when (and (stringp text) (string-match "\\`\\(\\*\\.\\)?\\(\\[[^]]*\\]\\|[^]:[]*\\):\\([^:]*\\)\\'" text))
      (let ((wild (match-beginning 1)) (host (match-string 2 text))
            (port (drgnx-sandbox-proxy--port (match-string 3 text))))
        (when (and port (not (and wild request)))
          (let ((addr (drgnx-sandbox-proxy--literal host)))
            (cond
             (addr
              (unless wild
                (list (if (= (length addr) 4) (format "%s:%d" (mapconcat #'number-to-string addr ".") port)
                        (format "[%s]:%d" (mapconcat (lambda (x) (format "%x" x)) addr ":") port))
                      nil port (vconcat addr (list port)))))
             ((string-prefix-p "[" host) nil)
             (t
              (when (string-match-p "[^[:ascii:]]" host)
                (setq host (unless request (require 'puny) (ignore-errors (puny-encode-domain (downcase host))))))
              (let ((name (and host (drgnx-sandbox-proxy--hostname host))))
                (when (and name (or (not wild) (string-search "." name)))
                  (list (format "%s%s:%d" (if wild "*." "") name port) name port nil)))))))))))

(defun drgnx-sandbox-proxy-normalize (text &optional request)
  "TEXT (`HOST:PORT', `[IPV6]:PORT' or `*.NAME:PORT') as the proxy compares it, or nil when it is none of those.
Names are in lower case without a trailing dot, in IDNA ASCII form (a Unicode name is encoded, unless REQUEST);
addresses are in a fixed form.  A name that a resolver would read as an address (`127.1', `0x7f.0.0.1') is refused."
  (car (drgnx-sandbox-proxy--parse text request)))

(defun drgnx-sandbox-proxy--public-v4 (a b c)
  "Whether the IPv4 address A.B.C.x is public: not this-network, private, shared, loopback, link-local,
documentation, benchmarking, multicast or reserved."
  (not (or (memq a '(0 10 127)) (>= a 224)
           (and (= a 100) (<= 64 b 127)) (and (= a 169) (= b 254)) (and (= a 172) (<= 16 b 31))
           (and (= a 192) (= b 0) (memq c '(0 2))) (and (= a 192) (= b 168)) (and (= a 198) (memq b '(18 19)))
           (and (= a 198) (= b 51) (= c 100)) (and (= a 203) (= b 0) (= c 113)))))

(defun drgnx-sandbox-proxy--public-p (addr)
  "Whether ADDR, an address vector with a port, is public.  An IPv6 address that carries an IPv4 one (mapped, NAT64,
6to4) is judged by that; unique-local, link-local, site-local, multicast, documentation, Teredo, discard and
`::/96' are not public."
  (if (= (length addr) 5) (drgnx-sandbox-proxy--public-v4 (aref addr 0) (aref addr 1) (aref addr 2))
    (let ((w0 (aref addr 0)) (w1 (aref addr 1)) (w2 (aref addr 2)) (w5 (aref addr 5)) (w6 (aref addr 6)))
      (cond
       ((= 0 w0 w1 w2 (aref addr 3) (aref addr 4))
        (and (= w5 #xffff) (drgnx-sandbox-proxy--public-v4 (ash w6 -8) (logand w6 255) (ash (aref addr 7) -8))))
       ((and (= w0 #x64) (= w1 #xff9b) (= 0 w2 (aref addr 3) (aref addr 4) w5))
        (drgnx-sandbox-proxy--public-v4 (ash w6 -8) (logand w6 255) (ash (aref addr 7) -8)))
       ((= w0 #x2002) (drgnx-sandbox-proxy--public-v4 (ash w1 -8) (logand w1 255) (ash w2 -8)))
       (t (not (or (= (logand w0 #xfe00) #xfc00) (= (logand w0 #xffc0) #xfe80) (= (logand w0 #xffc0) #xfec0)
                   (= (logand w0 #xff00) #xff00) (and (= w0 #x2001) (memq w1 '(0 #xdb8)))
                   (and (= w0 #x100) (= 0 w1 w2 (aref addr 3))))))))))

;;;; The proxy (batch)

(defvar drgnx-sandbox-proxy--allowed (make-hash-table :test #'equal) "The allowlist: normalized entries.")
(defvar drgnx-sandbox-proxy--pins nil "The pinned names: ((NAME . ADDRESS)…), ADDRESS a vector without its port.")
(defvar drgnx-sandbox-proxy--said (make-hash-table :test #'equal) "The stdout lines said once already.")

(defun drgnx-sandbox-proxy--die (status text)
  "End the proxy with STATUS, TEXT on stderr."
  (message "drgnx-sandbox-proxy: %s" text)
  (kill-emacs status))

(defun drgnx-sandbox-proxy--say-once (line)
  "Write LINE to stdout, unless it was written before."
  (unless (gethash line drgnx-sandbox-proxy--said)
    (puthash line t drgnx-sandbox-proxy--said)
    (send-string-to-terminal (concat line "\n"))))

(defun drgnx-sandbox-proxy--allowed-p (key name port)
  "Whether the target KEY (NAME, PORT) is on the allowlist: KEY itself, or `*.PARENT:PORT' for a parent of NAME."
  (or (gethash key drgnx-sandbox-proxy--allowed)
      (and name
           (let ((rest name) i found)
             (while (and (not found) (setq i (string-search "." rest)))
               (setq rest (substring rest (1+ i))
                     found (gethash (format "*.%s:%d" rest port) drgnx-sandbox-proxy--allowed)))
             found))))

(defun drgnx-sandbox-proxy--addresses (name port addr)
  "Where to connect for an allowed target (NAME, PORT, ADDR): a list of address vectors, or the symbol `private'
\(DNS answered only addresses that are not public) or `unresolved'.  NAME is resolved here, once."
  (let ((pin (and name (cdr (assoc name drgnx-sandbox-proxy--pins)))))
    (cond (addr (list addr))
          (pin (list (vconcat pin (list port))))
          (t (let ((all (ignore-errors (network-lookup-address-info name))) public)
               (dolist (a all)
                 (let ((v (copy-sequence a)))
                   (aset v (1- (length v)) port)
                   (when (drgnx-sandbox-proxy--public-p v) (push v public))))
               (cond (public (nreverse public)) (all 'private) (t 'unresolved)))))))

(defun drgnx-sandbox-proxy--refuse (conn &optional status)
  "Answer CONN with STATUS (default 403 Forbidden) and close it."
  (process-put conn :phase 'closed)
  (ignore-errors
    (process-send-string conn (format "HTTP/1.1 %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                                      (or status "403 Forbidden"))))
  (delete-process conn))

(defun drgnx-sandbox-proxy--close (proc)
  "Close PROC and its peer."
  (let ((peer (process-get proc :peer)))
    (process-put proc :phase 'closed)
    (delete-process proc)
    (when (and peer (process-live-p peer)) (delete-process peer))))

(defun drgnx-sandbox-proxy--pass (to chunk from)
  "Send CHUNK, which came from FROM, on to TO; close both when TO cannot take it."
  (condition-case nil (process-send-string to chunk)
    (error (drgnx-sandbox-proxy--close from))))

(defun drgnx-sandbox-proxy--connect (conn addrs)
  "Connect CONN's upstream to the first of ADDRS (the next on failure); answer 502 when none connects."
  (let* ((addr (car addrs))
         (up (ignore-errors
               ;; :remote is the address checked, so nothing resolves again; :service only for the signature
               (make-network-process :name "drgnx-sandbox-proxy-up" :remote addr :service (aref addr (1- (length addr)))
                                     :nowait t :noquery t
                                     :coding 'binary :filter #'drgnx-sandbox-proxy--upstream-filter
                                     :sentinel #'drgnx-sandbox-proxy--upstream-sentinel))))
    (cond (up (process-put up :peer conn) (process-put up :next (cdr addrs)) (process-put conn :peer up))
          ((cdr addrs) (drgnx-sandbox-proxy--connect conn (cdr addrs)))
          (t (drgnx-sandbox-proxy--refuse conn "502 Bad Gateway")))))

(defun drgnx-sandbox-proxy--upstream-filter (up chunk)
  "Pass CHUNK from UP to its client."
  (drgnx-sandbox-proxy--pass (process-get up :peer) chunk up))

(defun drgnx-sandbox-proxy--upstream-sentinel (up event)
  "UP connected (answer its client 200 and send what came early), failed (try the next address) or ended (close)."
  (let ((conn (process-get up :peer)))
    (cond ((not (process-live-p conn)) (delete-process up))
          ((string-prefix-p "open" event)
           (process-put conn :phase 'open)
           (drgnx-sandbox-proxy--pass conn "HTTP/1.1 200 Connection established\r\n\r\n" up)
           (dolist (c (nreverse (process-get conn :early))) (drgnx-sandbox-proxy--pass up c conn))
           (process-put conn :early nil))
          ((and (string-prefix-p "failed" event) (eq (process-get conn :phase) 'connecting))
           (if (process-get up :next) (drgnx-sandbox-proxy--connect conn (process-get up :next))
             (drgnx-sandbox-proxy--refuse conn "502 Bad Gateway")))
          (t (drgnx-sandbox-proxy--close up)))))

(defun drgnx-sandbox-proxy--request (conn head rest)
  "Answer CONN's request HEAD (without its blank line); REST came after it."
  (let* ((case-fold-search nil)
         (line (substring head 0 (string-search "\r\n" head)))
         (target (and (string-match "\\`CONNECT \\([!-~]+\\) HTTP/1\\.[01]\\'" line)
                      (drgnx-sandbox-proxy--parse (match-string 1 line) t))))
    (when (process-get conn :timer) (cancel-timer (process-get conn :timer)))
    (pcase-let ((`(,key ,name ,port ,addr) target))
      (cond
       ((null target) (drgnx-sandbox-proxy--refuse conn))
       ;; an address that is not public is reached only when listed itself: never offered on a card
       ((and addr (not (drgnx-sandbox-proxy--public-p addr)) (not (drgnx-sandbox-proxy--allowed-p key name port)))
        (drgnx-sandbox-proxy--say-once (format "refused %s private" key))
        (drgnx-sandbox-proxy--refuse conn))
       ((not (drgnx-sandbox-proxy--allowed-p key name port))
        (drgnx-sandbox-proxy--say-once (concat "denied " key))
        (drgnx-sandbox-proxy--refuse conn))
       (t (let ((addrs (drgnx-sandbox-proxy--addresses name port addr)))
            (if (symbolp addrs)
                (progn (drgnx-sandbox-proxy--say-once (format "refused %s %s" key addrs))
                       (drgnx-sandbox-proxy--refuse conn))
              (process-put conn :phase 'connecting)
              (process-put conn :early (and (> (length rest) 0) (list rest)))
              (process-put conn :early-bytes (length rest))
              (drgnx-sandbox-proxy--connect conn addrs))))))))

(defun drgnx-sandbox-proxy--client-filter (conn chunk)
  "Read CONN's request head, then pass what it sends to its upstream."
  (condition-case nil
      (pcase (process-get conn :phase)
        ('open (drgnx-sandbox-proxy--pass (process-get conn :peer) chunk conn))
        ('connecting
         (let ((bytes (+ (process-get conn :early-bytes) (length chunk))))
           (process-put conn :early (cons chunk (process-get conn :early)))
           (process-put conn :early-bytes bytes)
           (when (> bytes drgnx-sandbox-proxy--max-early) (drgnx-sandbox-proxy--close conn))))
        ('closed nil)
        (_ (let* ((head (concat (process-get conn :head) chunk)) (end (string-search "\r\n\r\n" head)))
             (cond ((and end (<= (+ end 4) drgnx-sandbox-proxy-max-head))
                    (process-put conn :head nil)
                    (drgnx-sandbox-proxy--request conn (substring head 0 end) (substring head (+ end 4))))
                   ((or end (> (length head) drgnx-sandbox-proxy-max-head)) (drgnx-sandbox-proxy--refuse conn))
                   (t (process-put conn :head head))))))
    (error (drgnx-sandbox-proxy--close conn))))

(defun drgnx-sandbox-proxy--head-expired (conn)
  "Answer CONN 403 when it still has not sent its whole head."
  (when (and (process-live-p conn) (null (process-get conn :phase))) (drgnx-sandbox-proxy--refuse conn)))

(defun drgnx-sandbox-proxy--accept (_server conn _message)
  "Take the new client CONN: 403 at once past `drgnx-sandbox-proxy-max-connections', else a deadline for its head."
  (process-put conn :client t)
  (let ((n 0))
    (dolist (p (process-list)) (when (and (process-get p :client) (process-live-p p)) (setq n (1+ n))))
    (if (> n drgnx-sandbox-proxy-max-connections) (drgnx-sandbox-proxy--refuse conn)
      (process-put conn :timer (run-at-time drgnx-sandbox-proxy-head-timeout nil
                                            #'drgnx-sandbox-proxy--head-expired conn)))))

(defun drgnx-sandbox-proxy--client-sentinel (conn event)
  "Close CONN's upstream once CONN has ended."
  (unless (string-prefix-p "open" event) (drgnx-sandbox-proxy--close conn)))

(defun drgnx-sandbox-proxy--command (line)
  "Apply LINE from the hub: `allow HOST:PORT' or `deny HOST:PORT'.  Other lines are ignored."
  (let ((case-fold-search nil))
    (when (string-match "\\`\\(allow\\|deny\\) \\(.*\\)\\'" line)
      (let ((allow (equal (match-string 1 line) "allow")) (key (drgnx-sandbox-proxy-normalize (match-string 2 line))))
        (when key
          (if allow (puthash key t drgnx-sandbox-proxy--allowed) (remhash key drgnx-sandbox-proxy--allowed)))))))

(defun drgnx-sandbox-proxy--control-filter (proc chunk)
  "Apply each line of CHUNK from the hub (through PROC, the `cat' of fd 3)."
  (let ((all (concat (process-get proc :pending) chunk)) (start 0) nl)
    (while (setq nl (string-search "\n" all start))
      (drgnx-sandbox-proxy--command (substring all start nl))
      (setq start (1+ nl)))
    (process-put proc :pending (and (< (- (length all) start) 4096) (substring all start)))))

(defun drgnx-sandbox-proxy--control-sentinel (proc _event)
  "End the proxy once the hub's stdin has closed (PROC, its reader, ended)."
  (unless (process-live-p proc) (kill-emacs 0)))

(defun drgnx-sandbox-proxy-main ()
  "Batch entry: `SOCKET|tcp ARG…', each ARG an allowlist entry `HOST:PORT' or a pin `NAME=ADDRESS'.
Listens on the Unix socket SOCKET (an absolute path), or with `tcp' on a random port of 127.0.0.1, and writes
`ready' (`ready PORT') to stdout.  Reads `allow'/`deny' lines from fd 3 and ends when it closes.  Exits 2 with a
line on stderr on a bad argument, 1 when it cannot listen."
  (setq gc-cons-percentage 0.2)
  (let ((args command-line-args-left) (where (car command-line-args-left)) server)
    (setq command-line-args-left nil)
    (unless (and where (or (equal where "tcp") (file-name-absolute-p where)))
      (drgnx-sandbox-proxy--die 2 "usage: drgnx-sandbox-proxy-main SOCKET|tcp [HOST:PORT|NAME=ADDRESS]…"))
    (dolist (arg (cdr args))
      (let ((i (string-search "=" arg)))
        (if i
            (let ((name (drgnx-sandbox-proxy--hostname (substring arg 0 i)))
                  (addr (drgnx-sandbox-proxy--literal (substring arg (1+ i)))))
              (unless (and name addr) (drgnx-sandbox-proxy--die 2 (format "not a pin: %S" arg)))
              (push (cons name addr) drgnx-sandbox-proxy--pins))
          (let ((key (drgnx-sandbox-proxy-normalize arg)))
            (unless key (drgnx-sandbox-proxy--die 2 (format "not an entry: %S" arg)))
            (puthash key t drgnx-sandbox-proxy--allowed)))))
    (make-process :name "drgnx-sandbox-proxy-control" :command '("/bin/sh" "-c" "exec cat <&3")
                  :connection-type 'pipe :noquery t :coding 'binary :filter #'drgnx-sandbox-proxy--control-filter
                  :sentinel #'drgnx-sandbox-proxy--control-sentinel)
    (condition-case err
        (setq server
              (if (equal where "tcp")
                  (make-network-process :name "drgnx-sandbox-proxy" :server t :host "127.0.0.1" :service t
                                        :family 'ipv4 :noquery t :coding 'binary :log #'drgnx-sandbox-proxy--accept
                                        :filter #'drgnx-sandbox-proxy--client-filter
                                        :sentinel #'drgnx-sandbox-proxy--client-sentinel)
                (let ((modes (file-attribute-modes (file-attributes where))))
                  (when (and modes (eq (aref modes 0) ?s)) (delete-file where)))
                (with-file-modes #o700
                  (make-network-process :name "drgnx-sandbox-proxy" :server t :family 'local :service where
                                        :noquery t :coding 'binary :log #'drgnx-sandbox-proxy--accept
                                        :filter #'drgnx-sandbox-proxy--client-filter
                                        :sentinel #'drgnx-sandbox-proxy--client-sentinel))))
      (error (drgnx-sandbox-proxy--die 1 (format "cannot listen: %s" (error-message-string err)))))
    (send-string-to-terminal (if (equal where "tcp") (format "ready %d\n" (process-contact server :service)) "ready\n"))
    (while t (accept-process-output nil 30))))

;;;; The hub's side

(defun drgnx-sandbox-proxy-command (hosts socket)
  "The argv that runs a proxy for HOSTS on SOCKET (nil: a random port of 127.0.0.1), with the pins of
`drgnx-sandbox-proxy-pinned-addresses'.  Its stdin becomes fd 3 (the control lines), its own stdin /dev/null, and
SIGPIPE is ignored."
  (require 'drgnx-paths)
  (let (pins)
    (dolist (p drgnx-sandbox-proxy-pinned-addresses)
      (let ((name (and (stringp (car p)) (drgnx-sandbox-proxy--hostname (car p)))))
        (if (and name (stringp (cdr p)) (drgnx-sandbox-proxy--literal (cdr p)))
            (push (format "%s=%s" name (cdr p)) pins)
          (message "drgnx: drgnx-sandbox-proxy-pinned-addresses: %S is not (NAME . ADDRESS); skipped" p))))
    (append (list "/bin/sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\" 3<&0 </dev/null"
                  (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                  "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                  "-l" "drgnx-sandbox-proxy" "-f" "drgnx-sandbox-proxy-main" (or socket "tcp"))
            (nreverse pins)
            (mapcar (lambda (h) (or (drgnx-sandbox-proxy-normalize h) (error "Not a proxy entry: %S" h))) hosts))))

(defun drgnx-sandbox-proxy--hub-filter (proc chunk)
  "Read PROC's stdout lines: `ready' sets `:ready' (and `:port'), `denied HOST:PORT' runs
`drgnx-sandbox-proxy-denied-functions'; any other line is kept as `:said', the last one."
  (let ((all (concat (process-get proc :pending) chunk)) (start 0) nl)
    (while (setq nl (string-search "\n" all start))
      (let ((line (substring all start nl)) (case-fold-search nil))
        (cond ((string-match "\\`ready\\(?: \\([0-9]+\\)\\)?\\'" line)
               (when (match-beginning 1) (process-put proc :port (string-to-number (match-string 1 line))))
               (process-put proc :ready t))
              ((and (string-match "\\`denied \\(.+\\)\\'" line)
                    (let ((hp (match-string 1 line))) (equal (drgnx-sandbox-proxy-normalize hp t) hp)))
               (let ((hp (substring line 7)))
                 (with-demoted-errors "drgnx-sandbox-proxy: %S"
                   (run-hook-with-args 'drgnx-sandbox-proxy-denied-functions (process-get proc :job) hp))))
              (t (process-put proc :said line))))
      (setq start (1+ nl)))
    (process-put proc :pending (and (< (- (length all) start) 4096) (substring all start)))))

(defun drgnx-sandbox-proxy-start (job hosts socket)
  "Start JOB's proxy, the hub's child, allowing HOSTS (`host:port' strings; `*.example.com:443' matches subdomains
only) on the Unix socket SOCKET, or with SOCKET nil on a random port of 127.0.0.1.  Returns the process at once: it
has `:ready' once it listens, and `:port' its port when it has no socket.  It ends when the hub's Emacs does.
Signals an error when an entry of HOSTS is not one."
  (let ((proc (make-process :name (format "drgnx-sandbox-proxy-%s" job) :command (drgnx-sandbox-proxy-command hosts socket)
                            :connection-type 'pipe :noquery t :coding 'utf-8-unix
                            :filter #'drgnx-sandbox-proxy--hub-filter :sentinel #'ignore)))
    (process-put proc :job job)
    proc))

(defun drgnx-sandbox-proxy-send (proc verb host-port)
  "Tell the proxy PROC to VERB (\"allow\" or \"deny\") HOST-PORT: its normalized form, or an error when it is no entry."
  (unless (member verb '("allow" "deny")) (error "Not a proxy command: %S" verb))
  (let ((key (or (drgnx-sandbox-proxy-normalize host-port) (error "Not a proxy entry: %S" host-port))))
    (process-send-string proc (format "%s %s\n" verb key))
    key))

(defun drgnx-sandbox-proxy-allow (proc host-port)
  "Add HOST-PORT to the allowlist of the proxy PROC (for its job only): its normalized form.  The agent's next
CONNECT to it goes through."
  (drgnx-sandbox-proxy-send proc "allow" host-port))

(provide 'drgnx-sandbox-proxy)
;;; drgnx-sandbox-proxy.el ends here
