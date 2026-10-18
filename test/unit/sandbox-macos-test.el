;;; sandbox-macos-test.el --- batch tests: the Seatbelt (SBPL) profile from a sandbox spec -*- lexical-binding: t -*-
;; Pure: the tests build a spec, generate its profile and read it back as data, on any system (sandbox-exec runs only
;; on a Mac: the MAC-SB rows of the Mac checklist).  A small evaluator applies SBPL's rule order (the last rule that
;; matches decides; `deny default' first) to an operation on a path, a socket or a host, so the tests ask what the
;; profile allows rather than how it spells it.  It models the two things Seatbelt's path rules do not see: a rename
;; moves everything under a path to another name (`drgnx-sandbox-macos-test--rename-p'), and macOS's file system is
;; case-insensitive, so a path spelled in another case is the same file, while `subpath' and `literal' compare the
;; spelling exactly (the worst case; only `regex' filters with character classes catch other spellings).  Every path
;; is in the test's temporary directory.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-sandbox)
(require 'drgnx-sandbox-macos)

(defmacro drgnx-sandbox-macos-test--with (&rest body)
  "BODY with a fixture tree under ROOT (true names): HOME the user's home with a canary in .ssh, RUN the runtime dir,
SID a session's socket dir, SOCK its socket, FOLDER a task folder in a repository under HOME with its .git and a
secret ENV (conf/.env), PHOME a private home under the state dir, TOOL a toolchain root under HOME, SECRET a file in
it, OBJECTS a dir for a read-write bind with a pinned file (commondir), SSH the ssh agent's socket, HUB the hub's
socket, and TMP the session's TMPDIR."
  (declare (indent 0))
  `(let* ((root (directory-file-name (file-truename (make-temp-file "drgnx-sbm" t))))
          (home (concat root "/home")) (run (concat root "/run")) (sid (concat run "/drgnx/s/7"))
          (sock (concat sid "/mcp.sock")) (hub (concat run "/drgnx/hub-0.sock"))
          (folder (concat home "/repo/.claude/worktrees/1-1"))
          (phome (concat root "/state/drgnx/sandbox/1/home-1"))
          (tool (concat home "/.local/share/mise/installs/node/20")) (secret (concat tool "/.npmrc"))
          (objects (concat root "/objects")) (ssh (concat root "/ssh-x/agent.1"))
          (env (concat folder "/conf/.env")) (commondir (concat objects "/commondir"))
          (temporary-file-directory (concat root "/T/"))
          (process-environment (append (list (concat "HOME=" home) (concat "XDG_RUNTIME_DIR=" run)
                                             (concat "XDG_STATE_HOME=" root "/state") (concat "DRGNX_DATA_DIR=" root "/data")
                                             (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx")
                                             (concat "SSH_AUTH_SOCK=" ssh)
                                             (concat "DBUS_SESSION_BUS_ADDRESS=unix:path=" root "/dbus/bus,guid=1"))
                                       process-environment))
          tmp)
     (unwind-protect
         (progn
           (dolist (d (list folder (concat folder "/.git") (concat folder "/conf") phome tool sid objects
                            temporary-file-directory (concat home "/.ssh") (concat root "/data") (concat root "/ssh-x")))
             (make-directory d t))
           (write-region "canary" nil (concat home "/.ssh/id_canary") nil 'silent)
           (write-region "token" nil secret nil 'silent)
           (write-region "key" nil env nil 'silent)
           (write-region "../.git" nil commondir nil 'silent)
           (setq tmp (drgnx-sandbox-macos-tmpdir "7"))
           ,@body)
       (delete-directory root t))))

(defmacro drgnx-sandbox-macos-test--full (net &rest more)
  "The spec of a job session in the fixture (inside `drgnx-sandbox-macos-test--with'), with NET; MORE properties
come first, so they win over the session's."
  `(drgnx-sandbox-spec ,@more
                       :backend 'seatbelt :home (cons phome phome) :read (list tool) :write (list folder) :run sid
                       :sockets (list sock) :binds (list (list 'ro (concat folder "/.git") (concat folder "/.git"))
                                                         (list 'rw objects objects) (list 'ro commondir commondir))
                       :hide (list secret env) :tmp tmp :net ,net))

(defun drgnx-sandbox-macos-test--own-rules (text)
  "The rules of TEXT after the base: the ones made from the spec."
  (should (string-prefix-p drgnx-sandbox-macos-base text))
  (drgnx-sandbox-macos-test--rules (substring text (length drgnx-sandbox-macos-base))))

(defconst drgnx-sandbox-macos-test--other (concat drgnx-sandbox-macos-users "/someone")
  "Another user's home on a Mac.")

;;;; Reading a profile back

(defun drgnx-sandbox-macos-test--forms (text)
  "TEXT's top-level forms, read by the Emacs reader (SBPL's `#\"…\"' regex literals read as strings).  Any unbalanced
parenthesis, unterminated string or junk signals."
  (with-temp-buffer
    (insert (replace-regexp-in-string "\\([ (\n]\\)#\"" "\\1\"" text))
    (goto-char (point-min))
    (let (forms)
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (push (read (current-buffer)) forms))
      (nreverse forms))))

(defun drgnx-sandbox-macos-test--rules (text)
  "TEXT's rules, in order: (ACTION OPS FILTERS) for each `allow' and `deny' form."
  (cl-loop for f in (drgnx-sandbox-macos-test--forms text)
           when (memq (car-safe f) '(allow deny))
           collect (list (car f) (seq-take-while #'symbolp (cdr f)) (seq-drop-while #'symbolp (cdr f)))))

(defun drgnx-sandbox-macos-test--op-covers-p (rule-op op)
  "Does RULE-OP (`default', `file-read*', `network*', or an operation) cover OP?"
  (let ((name (symbol-name rule-op)))
    (or (eq rule-op op) (eq rule-op 'default)
        (and (string-suffix-p "*" name) (string-prefix-p (substring name 0 -1) (symbol-name op))))))

(defun drgnx-sandbox-macos-test--host-match-p (pattern target)
  "Does the SBPL host:port PATTERN (host `*' or `localhost', port `*' or a number) match TARGET \"host:port\"?"
  (pcase-let ((`(,ph ,pp) (split-string pattern ":")) (`(,th ,tp) (split-string target ":")))
    (and (or (equal ph "*") (equal ph th)) (or (equal pp "*") (equal pp tp)))))

(defun drgnx-sandbox-macos-test--emacs-regexp (sbpl)
  "The Emacs regexp for the SBPL (POSIX extended) regex SBPL: groups and alternation take a backslash in Emacs, and a
backslash-escaped character is itself; brackets, anchors and repetition read the same."
  (let ((i 0) (n (length sbpl)) (out nil))
    (while (< i n)
      (let ((c (aref sbpl i)))
        (cond ((and (eq c ?\\) (< (1+ i) n)) (push (regexp-quote (string (aref sbpl (1+ i)))) out) (cl-incf i))
              ((memq c '(?\( ?\) ?|)) (push (string ?\\ c) out))
              ((eq c ?\[) (let ((end (string-search "]" sbpl (1+ i)))) (push (substring sbpl i (1+ end)) out)
                               (setq i end)))
              (t (push (string c) out))))
      (cl-incf i))
    (apply #'concat (nreverse out))))

(defun drgnx-sandbox-macos-test--filter-match-p (filter target)
  "Does FILTER match TARGET: a path, (unix . PATH), (ip . \"host:port\") or (global-name . NAME)?  `subpath' and
`literal' compare the spelling exactly; `regex' as a regex, case-sensitively."
  (pcase filter
    (`(subpath ,p) (and (stringp target) (or (equal target p) (string-prefix-p (concat p "/") target))))
    (`(,(or 'literal 'path) ,p) (equal target p))
    (`(regex ,r) (and (stringp target)
                      (let ((case-fold-search nil))
                        (string-match-p (drgnx-sandbox-macos-test--emacs-regexp r) target))))
    ('(remote unix-socket) (eq (car-safe target) 'unix))
    (`(remote unix-socket (path-literal ,p)) (equal target (cons 'unix p)))
    (`(remote ip ,hp) (and (eq (car-safe target) 'ip) (drgnx-sandbox-macos-test--host-match-p hp (cdr target))))
    (`(global-name ,n) (equal target (cons 'global-name n)))))

(defun drgnx-sandbox-macos-test--allowed-p (rules op target)
  "Is OP on TARGET allowed by RULES: the last rule whose operations cover OP and which has no filter or a matching
one decides."
  (let (verdict)
    (pcase-dolist (`(,action ,ops ,filters) rules)
      (when (and (cl-some (lambda (o) (drgnx-sandbox-macos-test--op-covers-p o op)) ops)
                 (or (null filters)
                     (cl-some (lambda (f) (drgnx-sandbox-macos-test--filter-match-p f target)) filters)))
        (setq verdict action)))
    (eq verdict 'allow)))

(defun drgnx-sandbox-macos-test--rename-p (rules from to)
  "May FROM be renamed to TO under RULES: an unlink of FROM, a create of TO and, where TO exists (on the test's
disk), an unlink of what it replaces.  A rename moves everything under FROM to TO without any rule seeing those
paths."
  (and (drgnx-sandbox-macos-test--allowed-p rules 'file-write-unlink from)
       (drgnx-sandbox-macos-test--allowed-p rules 'file-write-create to)
       (or (not (file-exists-p to)) (drgnx-sandbox-macos-test--allowed-p rules 'file-write-unlink to))))

(defun drgnx-sandbox-macos-test--position (rules pred)
  "The index of the first of RULES that PRED holds for, or nil."
  (cl-position-if pred rules))

(defun drgnx-sandbox-macos-test--allows (rules op kind)
  "The arguments of every KIND filter (`subpath', `literal', …) of an `allow' rule whose operations are exactly OP."
  (cl-loop for (action ops filters) in rules
           when (and (eq action 'allow) (equal ops (list op)))
           nconc (cl-loop for f in filters when (eq (car-safe f) kind) collect (cadr f))))

;;;; The tests

(ert-deftest drgnx-sandbox-macos/denies-by-default ()
  "The profile starts with the base (from Codex's published policy): `(version 1)', then `(deny default)' before any
allow.  Nothing allows `default'.  Of an empty spec (isolated) only the system's roots are readable, nothing is
writable and no network is reachable."
  (drgnx-sandbox-macos-test--with
    (dolist (spec (list (drgnx-sandbox-spec) (drgnx-sandbox-macos-test--full 'shared)
                        (drgnx-sandbox-macos-test--full 'isolated :proxy 4100)))
      (let* ((text (drgnx-sandbox-sbpl spec)) (forms (drgnx-sandbox-macos-test--forms text))
             (rules (drgnx-sandbox-macos-test--rules text)))
        (should (string-prefix-p drgnx-sandbox-macos-base text))
        (should (equal (car forms) '(version 1)))
        (should (equal (car rules) '(deny (default) nil)))
        (should (= 1 (cl-count '(deny (default) nil) rules :test #'equal)))
        (should-not (cl-some (lambda (r) (and (eq (car r) 'allow) (memq 'default (nth 1 r)))) rules))))
    (let ((rules (drgnx-sandbox-macos-test--rules (drgnx-sandbox-sbpl (drgnx-sandbox-spec :net 'isolated)))))
      (dolist (p (list "/usr/bin/env" "/System/Library/x" "/bin/sh" "/private/etc/hosts" "/opt/homebrew/bin/git"))
        (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data p)))
      (dolist (p (list (concat home "/.ssh/id_canary") folder (concat drgnx-sandbox-macos-test--other "/.zshrc")
                       "/private/var/folders/x/T/f"
                       "/private/tmp/x" "/Volumes/disk/x"))
        (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data p)))
      (dolist (p (list "/usr/bin/x" "/private/tmp/x" folder (concat home "/x") "/Library/x"))
        (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-write-data p)))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound '(ip . "example.com:443")))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'iokit-open nil))
      (should (drgnx-sandbox-macos-test--allowed-p rules 'process-exec nil)))))

(ert-deftest drgnx-sandbox-macos/no-appleevents-or-lsopen ()
  "No AppleEvents, no LaunchServices (`lsopen', launchservicesd): another app would run outside the sandbox.  No
Keychain (com.apple.SecurityServer): jobs on macOS use the gateway profiles.  No mach-lookup by prefix or regex."
  (drgnx-sandbox-macos-test--with
    (dolist (spec (list (drgnx-sandbox-spec) (drgnx-sandbox-macos-test--full 'shared)
                        (drgnx-sandbox-macos-test--full 'isolated :proxy 4100 :gateway 4101)))
      (let* ((text (drgnx-sandbox-sbpl spec)) (rules (drgnx-sandbox-macos-test--rules text)))
        (dolist (word '("appleevent" "lsopen" "launchservicesd" "coreservicesd" "SecurityServer" "securityd"
                        "global-name-prefix" "global-name-regex"))
          (should-not (string-search word text)))
        (dolist (op '(appleevent-send lsopen))
          (should-not (drgnx-sandbox-macos-test--allowed-p rules op nil)))
        (dolist (name '("com.apple.coreservices.launchservicesd" "com.apple.SecurityServer"
                        "com.apple.coreservices.appleevents"))
          (should-not (drgnx-sandbox-macos-test--allowed-p rules 'mach-lookup (cons 'global-name name))))
        (should (drgnx-sandbox-macos-test--allowed-p rules 'mach-lookup
                                                     '(global-name . "com.apple.system.opendirectoryd.libinfo")))))))

(ert-deftest drgnx-sandbox-macos/unix-sockets-only-the-sessions ()
  "Unix sockets: a deny of every one, then `path-literal' allows of the spec's `:sockets' after it.  The hub's, the ssh
agent's and the Emacs server's are refused.  Isolated: only the session's.  Shared: also the system's DNS resolver
\(mDNSResponder), which name lookups go through.  A socket outside `:run' is refused."
  (drgnx-sandbox-macos-test--with
    (dolist (net '(shared isolated))
      (let* ((rules (drgnx-sandbox-macos-test--rules (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full net))))
             (deny (drgnx-sandbox-macos-test--position
                    rules (lambda (r) (equal r '(deny (network-outbound) ((remote unix-socket)))))))
             (allows (cl-loop for (action ops filters) in rules
                              when (and (eq action 'allow) (memq 'network-outbound ops))
                              nconc (cl-loop for f in filters
                                             when (eq (car-safe (nth 2 f)) 'path-literal) collect (cadr (nth 2 f))))))
        (ert-info ((format "%s" net))
          (should deny)
          (should (equal allows (if (eq net 'shared) (list sock drgnx-sandbox-macos-dns-socket) (list sock))))
          ;; every unix allow comes after the deny
          (should (cl-every (lambda (i) (> i deny))
                            (cl-loop for r in rules for i from 0
                                     when (and (eq (car r) 'allow)
                                               (cl-some (lambda (f) (eq (car-safe (cdr-safe f)) 'unix-socket)) (nth 2 r)))
                                     collect i)))
          (should (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound (cons 'unix sock)))
          (dolist (other (list hub ssh (concat sid "/other.sock") (format "/private/tmp/emacs%d/server" (user-uid))
                               "/private/var/run/docker.sock"))
            (should-not (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound (cons 'unix other))))
          (should (eq (eq net 'shared)
                      (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound
                                                           (cons 'unix drgnx-sandbox-macos-dns-socket)))))))
    (should-error (drgnx-sandbox-sbpl (drgnx-sandbox-spec :run sid :sockets (list hub))) :type 'drgnx-sandbox-refused)))

(ert-deftest drgnx-sandbox-macos/users-unreadable-but-allowed-paths ()
  "`(deny file-read* (subpath \"/Users\"))' comes before every allow, so what the spec allows under /Users is
readable (SBPL's last match wins) and nothing else there is.  Home itself: its metadata only (a path is resolved
through it), never its contents.  ~ or a parent of it is refused, as on Linux."
  (drgnx-sandbox-macos-test--with
    (let* ((other drgnx-sandbox-macos-test--other)
           (user-tool (concat other "/.local/share/mise/installs/node/20"))
           (rules (drgnx-sandbox-macos-test--rules
                   (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full 'shared :read (list tool user-tool)))))
           (deny (drgnx-sandbox-macos-test--position rules (lambda (r) (equal r '(deny (file-read*) ((subpath "/Users")))))))
           (users (cl-loop for (action _ filters) in rules for i from 0
                           when (and (eq action 'allow)
                                     (cl-some (lambda (f) (and (memq (car-safe f) '(subpath literal))
                                                               (string-prefix-p "/Users" (cadr f))))
                                              filters))
                           collect i)))
      (should deny)
      ;; every allow of a path under /Users comes after the deny
      (should users)
      (should (cl-every (lambda (i) (> i deny)) users))
      (dolist (p (list (concat user-tool "/bin/node") (concat tool "/bin/node") (concat folder "/src/a.el")
                       (concat phome "/.config/x") (concat sid "/mcp.sock") (concat tmp "/x")))
        (ert-info (p) (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data p))))
      (dolist (p (list "/Users" other (concat other "/.ssh/id_rsa") (concat other "/.local/share/other")
                       home (concat home "/.ssh/id_canary") (concat home "/repo") (concat home "/.config/drgnx/agents.eld")))
        (ert-info (p) (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data p))))
      ;; the parents of what is allowed: their metadata, so realpath() can walk them; never their listing
      (dolist (p (list "/Users" other home (concat home "/repo") "/private" "/tmp" "/var" "/etc"))
        (ert-info (p) (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-metadata p))))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-metadata (concat home "/.ssh")))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-metadata (concat home "/.ssh/id_canary"))))
    (dolist (spec (list (drgnx-sandbox-spec :read (list home)) (drgnx-sandbox-spec :read (list root))
                        (drgnx-sandbox-spec :read (list "/")) (drgnx-sandbox-spec :write (list home))
                        (drgnx-sandbox-spec :home (cons home home)) (drgnx-sandbox-spec :read (list (concat root "/ssh-x")))
                        (drgnx-sandbox-spec :read (list run)) (drgnx-sandbox-spec :read (list (concat root "/state")))))
      (ert-info ((format "%S" spec))
        (should (equal (should-error (drgnx-sandbox-sbpl spec) :type 'drgnx-sandbox-refused)
                       (list 'drgnx-sandbox-refused (drgnx-sandbox-validate spec))))))))

(ert-deftest drgnx-sandbox-macos/writes-only-folder-home-tmp ()
  "`file-write*' is allowed on exactly `:write', the private home, `:tmp' and the rw `:binds'.  The ro `:binds' (the
git pins) and `:hide' come after them, in order, so a pin inside the folder is not writable and a hidden file
neither readable nor writable.  Nothing else is writable: not `:read', not `:run', not home, not /private/tmp."
  (drgnx-sandbox-macos-test--with
    (let* ((text (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full 'shared)))
           (rules (drgnx-sandbox-macos-test--rules text)))
      (should (equal (sort (cl-loop for (action ops filters) in (drgnx-sandbox-macos-test--own-rules text)
                                    when (and (eq action 'allow) (memq 'file-write* ops))
                                    nconc (mapcar #'cadr filters))
                           #'string<)
                     (sort (list folder phome tmp objects) #'string<)))
      (dolist (p (list (concat folder "/a.el") (concat phome "/.cache/x") (concat tmp "/x") (concat objects "/ab/cd")))
        (ert-info (p) (should (drgnx-sandbox-macos-test--allowed-p rules 'file-write-data p))))
      (dolist (p (list (concat folder "/.git") (concat folder "/.git/config") (concat folder "/.git/hooks/pre-commit")
                       (concat tool "/bin/node") secret sock (concat sid "/x") home (concat home "/.zshrc")
                       "/private/tmp/x" "/usr/local/bin/x" (concat drgnx-sandbox-macos-test--other "/x")))
        (ert-info (p) (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-write-data p))))
      (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data (concat folder "/.git/config")))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data secret))
      (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data (concat tool "/lib/x.js"))))
    ;; macOS has no mounts: a bind, and the private home, can only be at their own path
    (should-error (drgnx-sandbox-sbpl (drgnx-sandbox-spec :binds (list (list 'rw objects (concat folder "/o")))))
                  :type 'drgnx-sandbox-refused)
    (should-error (drgnx-sandbox-sbpl (drgnx-sandbox-spec :home (cons phome home))) :type 'drgnx-sandbox-refused)))

(ert-deftest drgnx-sandbox-macos/renames-cannot-move-protected-paths ()
  "Seatbelt's rules match paths, not files: renaming a directory above a pin or a hidden path would carry it to a name
no deny covers.  So no writable root (the folder, the private home, TMPDIR, an rw bind) and no directory between one
and a pin or a hidden path can be unlinked or renamed, in any spelling; the pins and hidden paths themselves are
covered by their own denies.  Other renames and deletions in the folder still work."
  (drgnx-sandbox-macos-test--with
    (let ((rules (drgnx-sandbox-macos-test--rules (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full 'shared)))))
      ;; the hidden file is denied by its name only: at a moved name it would be readable, so the move is refused
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data env))
      (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data (concat folder "/c2/.env")))
      (dolist (from (list (concat folder "/conf") (concat folder "/CONF") (concat folder "/Conf") env))
        (ert-info (from) (should-not (drgnx-sandbox-macos-test--rename-p rules from (concat folder "/c2")))))
      ;; the worktree folder out and back
      (should-not (drgnx-sandbox-macos-test--rename-p rules folder (concat tmp "/f")))
      (should-not (drgnx-sandbox-macos-test--rename-p rules (concat tmp "/f") folder))
      ;; every writable root and every pin, out of its place
      (dolist (from (list phome tmp objects (concat folder "/.git") commondir (concat folder "/.GIT")))
        (ert-info (from) (should-not (drgnx-sandbox-macos-test--rename-p rules from (concat tmp "/moved")))))
      (should-not (drgnx-sandbox-macos-test--rename-p rules objects (concat folder "/o")))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-write-unlink folder))
      ;; ordinary work goes on
      (should (drgnx-sandbox-macos-test--allowed-p rules 'file-write-unlink (concat folder "/a.el")))
      (should (drgnx-sandbox-macos-test--rename-p rules (concat folder "/a.el") (concat folder "/b.el")))
      (should (drgnx-sandbox-macos-test--rename-p rules (concat folder "/src") (concat folder "/lib")))
      (should (drgnx-sandbox-macos-test--rename-p rules (concat folder "/conf/other") (concat folder "/other")))
      (should (drgnx-sandbox-macos-test--rename-p rules (concat objects "/ab") (concat objects "/cd")))
      (should (drgnx-sandbox-macos-test--rename-p rules (concat phome "/.cache") (concat tmp "/c"))))))

(ert-deftest drgnx-sandbox-macos/case-variants-are-denied ()
  "macOS's file system is case-insensitive: `.GIT/config' is `.git/config'.  Every deny (the pins, `:hide', the
rename blocks, Homebrew's data) is also a regex of character classes, so another spelling is denied too.  Allows stay
exact: a path spelled otherwise is not allowed (closed).  No `(?i)', which SBPL is not known to support."
  (drgnx-sandbox-macos-test--with
    (let* ((text (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full 'shared)))
           (rules (drgnx-sandbox-macos-test--rules text)))
      (dolist (p (list (concat folder "/.GIT/config") (concat folder "/.Git/hooks/x") (concat folder "/.gIt")
                       (concat folder "/CONF/.ENV") (concat objects "/COMMONDIR") (concat objects "/CommonDir")))
        (ert-info (p) (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-write-data p))))
      (dolist (p (list (concat folder "/conf/.ENV") (concat folder "/Conf/.env") (concat tool "/.NPMRC")
                       "/opt/homebrew/VAR/postgres/x"))
        (ert-info (p) (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data p))))
      ;; a near name is not a variant
      (dolist (p (list (concat folder "/.gitx/config") (concat folder "/xconf/.env") (concat folder "/.git2")))
        (ert-info (p) (should (drgnx-sandbox-macos-test--allowed-p rules 'file-write-data p))))
      (should-not (cl-some (lambda (r) (and (eq (car r) 'allow) (assq 'regex (nth 2 r))))
                           (drgnx-sandbox-macos-test--own-rules text)))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data (concat (upcase folder) "/a.el")))
      (should-not (string-search "(?i)" text)))))

(ert-deftest drgnx-sandbox-macos/dev-only-the-devices ()
  "Of /dev, only null, zero, random, urandom, the controlling tty, dtracehelper and the process's own /dev/fd are
readable: never the user's other terminals (/dev/ttysN) nor disks.  Homebrew's data (/opt/homebrew/var,
/usr/local/var) is not readable, even when the spec reads /opt/homebrew."
  (drgnx-sandbox-macos-test--with
    (dolist (spec (list (drgnx-sandbox-spec) (drgnx-sandbox-spec :read '("/opt/homebrew"))))
      (let ((rules (drgnx-sandbox-macos-test--rules (drgnx-sandbox-sbpl spec))))
        (dolist (p '("/dev/null" "/dev/zero" "/dev/random" "/dev/urandom" "/dev/tty" "/dev/dtracehelper" "/dev/fd/3"
                     "/opt/homebrew/bin/git" "/opt/homebrew/Cellar/node/22/bin/node"))
          (ert-info (p) (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data p))))
        (dolist (p '("/dev/ttys003" "/dev/ttys000" "/dev/disk0" "/dev/rdisk1s1" "/dev/bpf0" "/dev/console" "/dev/null2"
                     "/dev/fdx" "/opt/homebrew/var/postgresql@16/base/1" "/opt/homebrew/var" "/usr/local/var/mysql/x"))
          (ert-info (p) (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data p))))))))

(ert-deftest drgnx-sandbox-macos/shared-net-phase-1 ()
  "`:net shared' (phase 1): outbound IP to anywhere, and the resolver (its socket and file), nothing inbound.  No
`(deny network*)'."
  (drgnx-sandbox-macos-test--with
    (let* ((text (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full 'shared)))
           (rules (drgnx-sandbox-macos-test--rules text)))
      (should (member '(allow (network-outbound) ((remote ip "*:*"))) rules))
      (should-not (member '(deny (network*) nil) rules))
      (dolist (target '("example.com:443" "localhost:3128" "localhost:22"))
        (should (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound (cons 'ip target))))
      (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data "/private/var/run/resolv.conf"))
      (dolist (name drgnx-sandbox-macos-net-services)
        (should (drgnx-sandbox-macos-test--allowed-p rules 'mach-lookup (cons 'global-name name))))
      (should (string-search "AF_SYSTEM" text))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'network-inbound '(ip . "localhost:8080")))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'network-bind '(ip . "localhost:8080"))))))

(ert-deftest drgnx-sandbox-macos/isolated-net-only-two-ports ()
  "`:net isolated': `(deny network*)', then outbound only to localhost's `:proxy' and `:gateway' ports.  No resolver,
and none of the network services (trustd and ocspd fetch URLs outside the sandbox) nor the AF_SYSTEM socket.
Without ports, no IP at all.  A port out of range is refused."
  (drgnx-sandbox-macos-test--with
    (let* ((text (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full 'isolated :proxy 4100 :gateway 4101)))
           (rules (drgnx-sandbox-macos-test--rules text))
           (deny (cl-position '(deny (network*) nil) rules :test #'equal)))
      (dolist (name drgnx-sandbox-macos-net-services)
        (ert-info (name) (should-not (drgnx-sandbox-macos-test--allowed-p rules 'mach-lookup (cons 'global-name name)))))
      (dolist (word '("trustd" "ocspd" "networkd" "AF_SYSTEM" "SystemConfiguration"))
        (should-not (string-search word text)))
      (should deny)
      (should (equal (cl-loop for (action ops filters) in rules for i from 0
                              when (and (eq action 'allow) (memq 'network-outbound ops)
                                        (eq (car-safe (cdr-safe (car filters))) 'ip))
                              do (should (> i deny)) and collect (nth 2 (car filters)))
                     '("localhost:4100" "localhost:4101")))
      (should (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound '(ip . "localhost:4100")))
      (should (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound '(ip . "localhost:4101")))
      (dolist (target '("localhost:22" "localhost:4102" "example.com:443" "example.com:4100"))
        (should-not (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound (cons 'ip target))))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data "/private/var/run/resolv.conf")))
    (let ((rules (drgnx-sandbox-macos-test--rules (drgnx-sandbox-sbpl (drgnx-sandbox-macos-test--full 'isolated)))))
      (should-not (drgnx-sandbox-macos-test--allowed-p rules 'network-outbound '(ip . "localhost:4100"))))
    (dolist (port '(0 65536))
      (should-error (drgnx-sandbox-sbpl (drgnx-sandbox-spec :net 'isolated :proxy port)) :type 'drgnx-sandbox-refused))))

(ert-deftest drgnx-sandbox-macos/quotes-hostile-paths ()
  "SBPL strings: `\"' and `\\' are escaped and read back as they were; a control character (a newline, a tab, NUL)
or a string too long for sandbox-exec (over 1024 bytes) is refused.  A folder whose name tries to close the string
and add a rule stays one path in one rule."
  (dolist (s '("/a/b" "/a\"b" "/a\\b" "/a\\\"b\\" "/é/ü" "/x\") (allow default) (\""))
    (let ((q (drgnx-sandbox-macos--quote s)))
      (should (string-prefix-p "\"" q))
      (should (equal (car (read-from-string q)) s))
      (should (= (cdr (read-from-string q)) (length q)))))
  (should (equal (drgnx-sandbox-macos--quote "/a\"b\\c") "\"/a\\\"b\\\\c\""))
  (dolist (bad (list "/a\nb" "/a\tb" "/a\0b" "/a\rb" "/a\177b" (concat "/" (make-string 1024 ?a)) 'sym nil 3))
    (ert-info ((format "%S" bad))
      (should-error (drgnx-sandbox-macos--quote bad) :type 'drgnx-sandbox-refused)))
  (drgnx-sandbox-macos-test--with
    (let ((hostile (concat home "/repo/x\") (allow default) (allow file-read* (subpath \"\\")))
      (make-directory hostile t)
      (let* ((rules (drgnx-sandbox-macos-test--rules
                     (drgnx-sandbox-sbpl (drgnx-sandbox-spec :write (list hostile) :read (list (concat root "/q\"d"))))))
             (allows (drgnx-sandbox-macos-test--allows rules 'file-write* 'subpath)))
        (should (equal allows (list hostile)))
        (should-not (cl-some (lambda (r) (and (eq (car r) 'allow) (memq 'default (nth 1 r)))) rules))
        (should (drgnx-sandbox-macos-test--allowed-p rules 'file-write-data (concat hostile "/f")))
        (should (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data (concat root "/q\"d/f")))
        (should-not (drgnx-sandbox-macos-test--allowed-p rules 'file-read-data (concat home "/.ssh/id_canary")))))))

(ert-deftest drgnx-sandbox-macos/balanced-parentheses ()
  "The whole text reads back, form by form, to the end: each form is `(version 1)', an `allow' or a `deny'."
  (drgnx-sandbox-macos-test--with
    (let ((odd (concat home "/repo/(a))b;c")))
      (make-directory odd t)
      (dolist (spec (list (drgnx-sandbox-spec) (drgnx-sandbox-macos-test--full 'shared)
                          (drgnx-sandbox-macos-test--full 'isolated :proxy 4100 :gateway 4101)
                          (drgnx-sandbox-spec :write (list odd))))
        (let ((forms (drgnx-sandbox-macos-test--forms (drgnx-sandbox-sbpl spec))))
          (should (> (length forms) 10))
          (should (cl-every (lambda (f) (memq (car-safe f) '(version allow deny))) forms))))
      (should (member (list 'allow '(file-write*) (list (list 'subpath odd)))
                      (drgnx-sandbox-macos-test--rules (drgnx-sandbox-sbpl (drgnx-sandbox-spec :write (list odd)))))))
    ;; the reader check itself catches what is unbalanced
    (should-error (drgnx-sandbox-macos-test--forms "(version 1)\n(allow file-read* (subpath \"/a\")"))
    (should-error (drgnx-sandbox-macos-test--forms "(version 1))"))))

(ert-deftest drgnx-sandbox-macos/wrap-writes-the-profile ()
  "`drgnx-sandbox-wrap' on the Seatbelt back end writes this profile to `:profile-file' (0600) and runs
sandbox-exec -f FILE COMMAND."
  (drgnx-sandbox-macos-test--with
    (let* ((file (concat sid "/profile.sb"))
           (spec (drgnx-sandbox-macos-test--full 'shared :profile-file file))
           (drgnx-sandbox--programs '(("sandbox-exec" . "/usr/bin/sandbox-exec"))))
      (should (equal (drgnx-sandbox-wrap spec '("agent" "--acp")) (list "/usr/bin/sandbox-exec" "-f" file "agent" "--acp")))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) (drgnx-sandbox-sbpl spec)))
      (should (= (file-modes file) #o600)))))

(ert-deftest drgnx-sandbox-macos/tmpdir-is-private ()
  "The session's TMPDIR: a new dir under `temporary-file-directory', mode 0700, its true name; one per call.  A
session id that is not a plain name is refused."
  (drgnx-sandbox-macos-test--with
    (let ((other (drgnx-sandbox-macos-tmpdir "7")))
      (dolist (d (list tmp other))
        (should (file-directory-p d))
        (should (string-prefix-p (file-truename temporary-file-directory) d))
        (should (equal d (directory-file-name (file-truename d))))
        (should (= (file-modes d) #o700)))
      (should-not (equal tmp other))
      (should (string-search "7" (file-name-nondirectory tmp))))
    (dolist (bad '("../x" "a/b" "" "." ".." "a b" "a\nb"))
      (should-error (drgnx-sandbox-macos-tmpdir bad) :type 'drgnx-sandbox-refused))))

;;; sandbox-macos-test.el ends here
