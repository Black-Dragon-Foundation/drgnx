;;; trust-test.el --- batch tests: trusted folders and the guards for files from the others -*- lexical-binding: t -*-
;; Harmless only: TRAMP is asked whether a name is its own (nothing connects: connections signal), Flymake runs
;; stub backends that record their calls, compile output is parsed with TRAMP's handler stubbed.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-trust)
(require 'tramp)
(require 'tramp-sh)
(require 'flymake)
(require 'compile)
(require 'ffap)
(require 'autorevert)

(defmacro drgnx-trust-test--with (spec &rest body)
  "BODY with the guards on, its own `trusted-content' and state dir, and (car SPEC) bound to a fresh folder
nobody trusted.  Buffers BODY opens are killed after it."
  (declare (indent 1))
  (let ((dir (car spec)))
    ;; The mode is put back as it was only outside the temp state and `trusted-content' bindings, so that the
    ;; test's folders never reach the global trusted set.
    `(let ((was drgnx-trust-mode))
       (unwind-protect
           (let* ((buffers (buffer-list))
                  (state (make-temp-file "drgnx-trust-state" t))
                  (,dir (file-name-as-directory (make-temp-file "drgnx-trust-proj" t)))
                  (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
             (unwind-protect
                 (let ((trusted-content nil) (drgnx-trust--added nil) (drgnx-trust--told nil)
                       (tramp-ignored-file-name-regexp nil)
                       (ffap-machine-p-known 'ping) (remote-file-name-inhibit-auto-save-visited nil))
                   (drgnx-trust-mode 1)
                   (unwind-protect (progn ,@body) (drgnx-trust-mode -1)))
               (dolist (b (buffer-list))
                 (unless (memq b buffers) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
               (delete-directory state t)
               (delete-directory ,dir t)))
         (drgnx-trust-mode (if was 1 -1))))))

(defun drgnx-trust-test--file (dir name text)
  (let ((f (expand-file-name name dir)))
    (with-temp-file f (insert text))
    f))

(defmacro drgnx-trust-test--no-connections (&rest body)
  "BODY where opening a TRAMP connection signals; returns how many were attempted."
  `(let ((opened 0))
     (cl-letf (((symbol-function 'tramp-maybe-open-connection)
                (lambda (&rest _) (cl-incf opened) (error "No connections in tests"))))
       ,@body)
     opened))

;;;; TRAMP

(ert-deftest drgnx-trust/crafted-tramp-names-stay-local ()
  (drgnx-trust-test--with (_dir)
    (should (= 0 (drgnx-trust-test--no-connections
                  ;; a control character anywhere; a user@host part with a shell character, or a user or host starting with -
                  (dolist (n (list "/ssh:a&b@h:/x" "/ssh:a!b@h:/x" "/ssh:a,b@h:/x" "/ssh:a;b@h:/x" "/ssh:a`b@h:/x"
                                   "/ssh:a\001b@h:/x" "/ssh:a\tb@h:/x" "/ssh:-x@h:/x" "/tmp/x\n/ssh:h:/x"
                                   "/ssh:a@b|sudo:r&t@b:/x" "/ssh:a@-h:/x" "/ssh:-h:/x"))
                    (should-not (tramp-tramp-file-p n))
                    (should-not (file-remote-p n)))
                  ;; legitimate names stay remote (file-remote-p answers without connecting)
                  (dolist (n (list "/ssh:host:/path" "/ssh:user@host#2222:/a (1).txt" "/ssh:a@b|sudo:root@b:/x"
                                   "/podman:name:/" "/ssh:user@[::1]:/x" "/sudo::/etc/hosts" "/ssh:h:/a;b&c!d"
                                   "/-:host:/x" "/-:user@host:/x" "/ssh:a@b|-:root@b:/x" "/ssh:a-b@h-c:/x"))
                    (should (tramp-tramp-file-p n))
                    (should (file-remote-p n)))
                  (let ((process-environment (cons "USER=someone" process-environment)))
                    (should (tramp-tramp-file-p "/ssh:$USER@host:/x"))))))))

(ert-deftest drgnx-trust/a-symlink-to-a-refused-name-stays-local ()
  ;; `file-truename' follows a link in Lisp: the target is checked as a name of its own
  (drgnx-trust-test--with (dir)
    (let ((link (expand-file-name "link" dir)))
      (make-symbolic-link "/ssh:a&b@h:/x" link)
      (should (= 0 (drgnx-trust-test--no-connections
                    (should (string-suffix-p "/ssh:a&b@h:/x" (file-truename link)))
                    (should-not (file-remote-p (file-truename link)))
                    (with-current-buffer (find-file-noselect link)
                      (should-not (file-remote-p default-directory)))))))))

;;;; Flymake

(defvar drgnx-trust-test--called nil "Stub backends that ran.")
(defun drgnx-trust-test--canary (report &rest _) (push 'canary drgnx-trust-test--called) (funcall report nil))
(defun drgnx-trust-test--safe (report &rest _) (push 'safe drgnx-trust-test--called) (funcall report nil))
(function-put 'drgnx-trust-test--safe 'flymake-always-safe t)

(defun drgnx-trust-test--flymake (file)
  "Visit FILE and run Flymake on it with the two stub backends; return the buffer."
  (with-current-buffer (find-file-noselect file)
    (setq-local flymake-diagnostic-functions '(drgnx-trust-test--canary drgnx-trust-test--safe))
    (let ((flymake-start-on-flymake-mode nil) (inhibit-message t)) (flymake-mode 1) (flymake-start))
    (current-buffer)))

(ert-deftest drgnx-trust/flymake-runs-only-safe-backends-outside-trusted-folders ()
  (drgnx-trust-test--with (dir)
    (should (function-get 'eglot-flymake-backend 'flymake-always-safe))
    (let* ((drgnx-trust-test--called nil)
           (b (drgnx-trust-test--flymake (drgnx-trust-test--file dir "a.txt" "text\n"))))
      (should (equal drgnx-trust-test--called '(safe)))
      (with-current-buffer b (should (memq 'drgnx-trust-test--canary (flymake-disabled-backends))))
      ;; Trust This Folder runs it in the folder's open buffers…
      (setq drgnx-trust-test--called nil)
      (let ((inhibit-message t)) (drgnx-trust-folder dir))
      (should (memq 'canary drgnx-trust-test--called))
      ;; …and in its files opened afterwards
      (setq drgnx-trust-test--called nil)
      (drgnx-trust-test--flymake (drgnx-trust-test--file dir "b.txt" "text\n"))
      (should (memq 'canary drgnx-trust-test--called)))))

;;;; Shorthands

(defconst drgnx-trust-test--shorthands '(("dt-" . "drgnx-trust-test-")))

(defun drgnx-trust-test--el (dir name)
  (drgnx-trust-test--file dir name (concat ";;; " name " -*- lexical-binding: t -*-\n(dt-x)\n"
                                           ";; Local Variables:\n;; read-symbol-shorthands: ((\"dt-\" . \"drgnx-trust-test-\"))\n"
                                           ";; End:\n")))

(ert-deftest drgnx-trust/shorthands-only-in-trusted-files ()
  (drgnx-trust-test--with (dir)
    (let ((b (find-file-noselect (drgnx-trust-test--el dir "a.el"))))
      (with-current-buffer b
        (should-not read-symbol-shorthands)
        (should (equal drgnx-trust--held-shorthands drgnx-trust-test--shorthands)))
      ;; Trust This Folder gives them back without reading the file's variables again
      (let ((inhibit-message t)) (drgnx-trust-folder dir))
      (with-current-buffer b
        (should (equal read-symbol-shorthands drgnx-trust-test--shorthands))
        (should-not drgnx-trust--held-shorthands))
      (with-current-buffer (find-file-noselect (drgnx-trust-test--el dir "b.el"))
        (should (equal read-symbol-shorthands drgnx-trust-test--shorthands))))))

;;;; Trust This Folder, the trusted set, the mark

(ert-deftest drgnx-trust/trusted-folders-persist-and-reload ()
  (drgnx-trust-test--with (dir)
    (let ((e (drgnx-trust--entry dir)) (inhibit-message t))
      (should (string-suffix-p "/" e))
      (drgnx-trust-folder dir)
      (should (member e (drgnx-trust-folders)))
      (should (member e trusted-content))
      ;; the next session reads them back
      (setq trusted-content nil)
      (drgnx-trust-mode 1)
      (should (member e trusted-content))
      (drgnx-trust-untrust-folder dir)
      (should-not (member e (drgnx-trust-folders)))
      (should-not (member e trusted-content))
      (setq trusted-content nil)
      (drgnx-trust-mode 1)
      (should-not (member e trusted-content))
      (should-error (drgnx-trust-untrust-folder drgnx-dir) :type 'user-error))))

(ert-deftest drgnx-trust/broad-folders-are-never-trusted ()
  ;; `/', home, an ancestor of home, the temp dir: each would trust far more than a project
  (drgnx-trust-test--with (dir)
    (let ((inhibit-message t))
      (dolist (d (list "/" "~/" (file-name-directory (directory-file-name (expand-file-name "~")))
                       temporary-file-directory))
        (should-error (drgnx-trust-folder d) :type 'user-error)
        (should-not (member (drgnx-trust--entry d) trusted-content)))
      (should-not (drgnx-trust-folders))
      ;; a file straight in home: its folder is home, refused the same way
      (let ((f (expand-file-name "notes.txt" "~")))
        (with-temp-file f (insert "x\n"))
        (unwind-protect (with-current-buffer (find-file-noselect f)
                          (should-error (drgnx-trust-folder) :type 'user-error))
          (delete-file f)))
      (should (drgnx-trust-folder dir)))))                       ; a project folder is fine

;;;; trusted-folders.eld: a file drgnx cannot use trusts nothing, and is never lost

(defun drgnx-trust-test--put (text)
  "Make trusted-folders.eld hold TEXT; its path."
  (let ((file (drgnx-trust-folders-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    file))

(defun drgnx-trust-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-trust-test--backups (file)
  (directory-files (file-name-directory file) t (concat "\\`" (regexp-quote (file-name-nondirectory file)) "\\.bak")))

(defun drgnx-trust-test--trusts-from-file-p (entry)
  "Does a fresh start (the mode switched on with an empty `trusted-content') trust ENTRY?"
  (setq trusted-content nil)
  (drgnx-trust-mode 1)
  (and (member entry trusted-content) t))

(ert-deftest drgnx-trust/an-unreadable-file-trusts-nothing-and-is-backed-up-on-write ()
  (drgnx-trust-test--with (dir)
    (let* ((text "(:version 1 :folders (\"/x/\" \"/y/\"") ; cut short
           (file (drgnx-trust-test--put text)) (inhibit-message t))
      (should-not (drgnx-trust-folders))
      (should-not (drgnx-trust-test--trusts-from-file-p "/x/"))
      (drgnx-trust-folder dir)
      (should (equal (drgnx-trust-folders) (list (drgnx-trust--entry dir))))
      (should-not (drgnx-trust-test--trusts-from-file-p "/x/"))
      (let ((backups (drgnx-trust-test--backups file)))
        (should (= (length backups) 1))
        (should (string-match-p "\\.bak-[0-9]\\{8\\}-" (car backups)))
        (should (equal (drgnx-trust-test--bytes (car backups)) text)))
      (should (string-prefix-p ";; drgnx: the folders you trusted" (drgnx-trust-test--bytes file))))))

(ert-deftest drgnx-trust/a-mistake-or-a-newer-file-trusts-nothing ()
  (drgnx-trust-test--with (_dir)
    (dolist (text '("(:version 1 :folders (\"/x/\" x))"   ; one entry is not a string
                    "(:version 1 :folders \"/x/\")"        ; not a list
                    "(:version 1 :folders (\"/x/\" . \"/y/\"))"
                    "(\"/x/\")"                            ; not a plist
                    "(:version 1)"                         ; no :folders
                    "(:version \"1\" :folders (\"/x/\"))"
                    "(:version 2 :folders (\"/x/\"))"))    ; a newer drgnx's
      (drgnx-trust-test--put text)
      (should-not (drgnx-trust-folders))
      (should-not (drgnx-trust-test--trusts-from-file-p "/x/")))
    ;; what older drgnx wrote, and a hand-written file with no version, keep working
    (dolist (text '(";; drgnx: the folders you trusted (Trust This Folder; docs/guide/security.md)
(:version 1 :folders (\"/x/\" \"/y/\"))\n"
                    "(:folders (\"/x/\" \"/y/\"))"))
      (drgnx-trust-test--put text)
      (should (equal (drgnx-trust-folders) '("/x/" "/y/")))
      (should (drgnx-trust-test--trusts-from-file-p "/x/")))))

(ert-deftest drgnx-trust/a-newer-file-is-never-overwritten ()
  (drgnx-trust-test--with (dir)
    (let* ((text "(:version 2 :folders (\"/x/\") :except (\"/x/secret/\"))")
           (file (drgnx-trust-test--put text)) (inhibit-message t))
      (should-error (drgnx-trust-folder dir) :type 'user-error)
      (should-error (drgnx-trust-untrust-folder "/x/") :type 'user-error)
      (should (equal (drgnx-trust-test--bytes file) text))
      (should-not (drgnx-trust-test--backups file))
      (should-not (member (drgnx-trust--entry dir) trusted-content)))))

(ert-deftest drgnx-trust/a-mistake-is-backed-up-and-unknown-keys-are-kept ()
  (drgnx-trust-test--with (dir)
    (let* ((text "(:version 1 :folders (\"/x/\" x))") (file (drgnx-trust-test--put text)) (inhibit-message t)
           (e (drgnx-trust--entry dir)))
      (drgnx-trust-folder dir)
      (should (equal (drgnx-trust-folders) (list e)))
      (should (equal (mapcar #'drgnx-trust-test--bytes (drgnx-trust-test--backups file)) (list text)))
      ;; a key this drgnx does not know survives Trust and Untrust
      (drgnx-trust-test--put "(:version 1 :folders (\"/x/\") :note \"mine\")")
      (drgnx-trust-folder dir)
      (drgnx-trust-untrust-folder "/x/")
      (let ((data (car (read-from-string (drgnx-trust-test--bytes file)))))
        (should (equal (plist-get data :note) "mine"))
        (should (equal (plist-get data :folders) (list e)))))))

(ert-deftest drgnx-trust/untrust-takes-effect-when-the-file-became-unusable ()
  (drgnx-trust-test--with (dir)
    (let* ((inhibit-message t) (a (concat dir "a/")) (b (concat dir "b/")) (ea (drgnx-trust--entry a))
           (eb (drgnx-trust--entry b)))
      (make-directory a) (make-directory b)
      (drgnx-trust-test--put (format "(:version 1 :folders (%S %S))" ea eb))
      (setq trusted-content nil)
      (drgnx-trust-mode 1)                                       ; the start: both trusted
      (should (member ea trusted-content))
      ;; then another drgnx writes a newer file: Untrust A still takes effect; the file is left as it is
      (let ((file (drgnx-trust-test--put "(:version 2 :folders ())")))
        (drgnx-trust-untrust-folder a)
        (should-not (member ea trusted-content))
        (should (equal (drgnx-trust-test--bytes file) "(:version 2 :folders ())")))
      ;; a mistake: Untrust This Folder in a file of B (no argument) finds B among the folders trusted at the start
      (let ((file (drgnx-trust-test--put "(:version 1 :folders (x))")))
        (with-current-buffer (find-file-noselect (drgnx-trust-test--file b "x.txt" "x\n"))
          (drgnx-trust-untrust-folder)
          (should (eq drgnx-trust--state 'restricted)))
        (should-not (member eb trusted-content))
        (should (equal (drgnx-trust-test--bytes file) "(:version 1 :folders (x))"))))))

(ert-deftest drgnx-trust/broad-entries-in-the-file-are-not-trusted ()
  (drgnx-trust-test--with (dir)
    (let ((e (drgnx-trust--entry dir)) (up (file-name-directory (directory-file-name (expand-file-name "~")))))
      (drgnx-trust-test--put (format "(:version 1 :folders (\"~/\" \"/\" %S %S %S))"
                                     up (drgnx-trust--entry temporary-file-directory) e))
      (should (equal (drgnx-trust-folders) (list e)))
      (should (drgnx-trust-test--trusts-from-file-p e))
      (dolist (d (list "~/" "/" up (drgnx-trust--entry temporary-file-directory)))
        (should-not (member d trusted-content))))))

(ert-deftest drgnx-trust/an-entry-that-signals-never-stops-the-guards ()
  (drgnx-trust-test--with (dir)
    (let ((e (drgnx-trust--entry dir)) (inhibit-message t)
          (guards-on (lambda ()
                       (let ((s (drgnx-trust-guards-status)))
                         (and (plist-get s :mode) (plist-get s :tramp) (plist-get s :ffap) (plist-get s :shorthands)
                              (plist-get s :compile))))))
      (drgnx-trust-test--put (format "(:version 1 :folders (\"/nosuchmethod:h:/x/\" %S))" e))
      (drgnx-trust-mode -1)
      (setq trusted-content nil)
      (drgnx-trust-mode 1)                                       ; no error
      (should (funcall guards-on))
      (should (member e trusted-content))
      (should-not (seq-find (lambda (c) (string-search "nosuchmethod" c)) trusted-content))
      ;; whatever the read signals, the mode still installs every guard
      (drgnx-trust-mode -1)
      (cl-letf (((symbol-function 'drgnx-trust--read) (lambda () (error "Boom"))))
        (drgnx-trust-mode 1))
      (should (funcall guards-on)))))

(ert-deftest drgnx-trust/the-temp-dirs-and-their-ancestors-are-broad ()
  (drgnx-trust-test--with (dir)
    (let ((tmp (file-name-as-directory (file-truename temporary-file-directory))))
      (dolist (d (list tmp (file-name-directory (directory-file-name tmp)) "/tmp/" "/var/tmp/" "/dev/shm/"))
        (should (drgnx-trust--broad-p d)))
      (should-not (drgnx-trust--broad-p (drgnx-trust--entry dir)))
      (should-not (drgnx-trust--broad-p "/tmp/a-project/")))))

(ert-deftest drgnx-trust/an-unusable-file-is-told-once-per-change ()
  (drgnx-trust-test--with (_dir)
    (let* ((told nil) (file (drgnx-trust-folders-file)) (name (file-name-nondirectory file)))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (when fmt (push (apply #'format-message fmt args) told)))))
        (drgnx-trust-test--put "(:version 1 :folders (\"/x/\"")
        (dotimes (_ 3) (should-not (drgnx-trust-folders)))
        (should (= (length told) 1))
        (should (string-search name (car told)))
        (should (string-search "cannot be read" (car told)))
        (drgnx-trust-test--put "(:version 2 :folders (\"/x/\"))")  ; another problem
        (dotimes (_ 3) (should-not (drgnx-trust-folders)))
        (should (= (length told) 2))
        (should (string-search "newer" (car told)))
        (drgnx-trust-test--put "(:version 1 :folders (\"/x/\"))")  ; fixed: nothing to tell
        (should (equal (drgnx-trust-folders) '("/x/")))
        (should (= (length told) 2))))))

(defun drgnx-trust-test--children (forms)
  "Run each of FORMS (strings) in a child `emacs --batch' with this run's environment and load path, started
together; wait for all under a 30 s bound.  Fails the test unless every child exits 0."
  (let* ((at (+ (float-time) 2)) (bufs nil)
         (procs (mapcar
                 (lambda (form)
                   (let ((b (generate-new-buffer " *trust-child*" t)))
                     (push b bufs)
                     (make-process
                      :name "trust-child" :buffer b :noquery t
                      :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                     "--eval" (format "(setq load-path '%S load-prefer-newer t)" load-path)
                                     "--eval" "(require 'drgnx-trust)"
                                     "--eval" (format "(progn (sleep-for (max 0 (- %f (float-time)))) %s)" at form)))))
                 forms))
         (deadline (+ (float-time) 30)))
    (unwind-protect
        (progn
          (while (and (cl-some #'process-live-p procs) (< (float-time) deadline)) (accept-process-output nil 0.05))
          (dolist (p procs) (should (not (process-live-p p))))
          (cl-loop for p in procs for b in (reverse bufs)
                   do (should (equal (list (process-exit-status p) (with-current-buffer b (buffer-string)))
                                     (list 0 (with-current-buffer b (buffer-string)))))))
      (mapc #'delete-process procs)
      (mapc #'kill-buffer bufs))))

(ert-deftest drgnx-trust/two-trusts-at-once-both-kept ()
  (drgnx-trust-test--with (dir)
    (let* ((dirs (lambda (tag) (mapcar (lambda (i) (format "%s%s-%d/" dir tag i)) (number-sequence 1 15))))
           (form (lambda (tag) (format "(let ((inhibit-message t)) (dolist (d '%S) (drgnx-trust-folder d)))"
                                       (funcall dirs tag)))))
      (drgnx-trust-test--children (list (funcall form "a") (funcall form "b")))
      (should (equal (sort (copy-sequence (drgnx-trust-folders)) #'string<)
                     (sort (mapcar #'drgnx-trust--entry (append (funcall dirs "a") (funcall dirs "b"))) #'string<))))))

(ert-deftest drgnx-trust/the-user-settings-are-kept ()
  (drgnx-trust-test--with (_dir)
    (let ((trusted-content '("/mine/")) (tramp-ignored-file-name-regexp "\\`/nope:"))
      (drgnx-trust-mode 1)
      (should (equal (car trusted-content) "/mine/"))
      (should (member (drgnx-trust--entry drgnx-dir) trusted-content))
      (should (member (drgnx-trust--entry (drgnx-elpa-dir)) trusted-content))
      (should (member (drgnx-trust--entry lisp-directory) trusted-content))      ; Emacs's own Lisp
      (should (equal tramp-ignored-file-name-regexp (concat "\\`/nope:\\|" drgnx-trust-tramp-ignored-regexp)))
      (drgnx-trust-mode 1)                                       ; twice: nothing added twice
      (should (equal tramp-ignored-file-name-regexp (concat "\\`/nope:\\|" drgnx-trust-tramp-ignored-regexp)))
      (should (= (length trusted-content) (length (delete-dups (copy-sequence trusted-content)))))
      (drgnx-trust-mode -1)
      (should (equal tramp-ignored-file-name-regexp "\\`/nope:")))
    (let ((trusted-content :all))
      (drgnx-trust-mode 1)
      (should (eq trusted-content :all)))))

(defvar drgnx-trust-test--io 0 "File operations seen.")
(defun drgnx-trust-test--count-io (op &rest args)
  "A file name handler for every name: count OP, then do it."
  (cl-incf drgnx-trust-test--io)
  (let ((inhibit-file-name-handlers (cons 'drgnx-trust-test--count-io
                                          (and (eq inhibit-file-name-operation op) inhibit-file-name-handlers)))
        (inhibit-file-name-operation op))
    (apply op args)))

(ert-deftest drgnx-trust/restricted-mark-only-for-untrusted-local-files ()
  (drgnx-trust-test--with (dir)
    (should (member drgnx-trust--mark-segment global-mode-string))
    (let ((b (find-file-noselect (drgnx-trust-test--file dir "a.txt" "text\n")))
          ;; the segment's form, evaluated in B as redisplay does (`format-mode-line' is empty in batch)
          (mark (lambda (b) (with-current-buffer b (eval (cadr drgnx-trust--mark-segment) t)))))
      (should (equal (funcall mark b) " restricted"))
      (should (eq (get-text-property 1 'local-map (funcall mark b)) drgnx-trust-mark-map))
      (with-temp-buffer (should (equal (funcall mark (current-buffer)) "")))
      (with-temp-buffer                                         ; a remote file's buffer: no mark, no connection
        (setq buffer-file-name "/ssh:host:/x.txt")
        (should (= 0 (drgnx-trust-test--no-connections (drgnx-trust--update))))
        (should (equal (funcall mark (current-buffer)) "")))
      ;; redisplay reads no file
      (let ((file-name-handler-alist (cons '("" . drgnx-trust-test--count-io) file-name-handler-alist))
            (drgnx-trust-test--io 0))
        (dotimes (_ 20) (funcall mark b))
        (should (= drgnx-trust-test--io 0))
        (file-exists-p dir)                                      ; the counter counts
        (should (> drgnx-trust-test--io 0)))
      (let ((inhibit-message t)) (drgnx-trust-folder dir))
      (should (equal (funcall mark b) ""))
      (let ((inhibit-message t)) (drgnx-trust-untrust-folder dir))
      (should (equal (funcall mark b) " restricted")))))

;;;; Compile output, links, status

(defvar drgnx-trust-test--tramp-ops nil "Operations that reached TRAMP's handler.")
(defun drgnx-trust-test--tramp-stub (handler op &rest args)
  "Around `tramp-file-name-handler': record OP when TRAMP would handle it; then only `file-remote-p' (which never
connects) goes on, anything else returns its first argument."
  (if (not (and tramp-mode (tramp-tramp-file-p (apply #'tramp-file-name-for-operation op args))))
      (apply handler op args)
    (push op drgnx-trust-test--tramp-ops)
    (if (eq op 'file-remote-p) (apply handler op args) (car args))))

(defun drgnx-trust-test--file-structs ()
  "The file structures of the compilation messages in this buffer: ((FILE DIR) …)."
  (let ((pos (point-min)) out)
    (while (setq pos (next-single-property-change pos 'compilation-message))
      (when-let* ((msg (get-text-property pos 'compilation-message)) (loc (compilation--message->loc msg)))
        (push (car (compilation--loc->file-struct loc)) out)))
    (delete-dups (nreverse out))))

(ert-deftest drgnx-trust/compile-output-never-names-a-remote ()
  (drgnx-trust-test--with (dir)
    (let ((drgnx-trust-test--tramp-ops nil))
      (advice-add 'tramp-file-name-handler :around #'drgnx-trust-test--tramp-stub)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory dir)
            (insert "make: Entering directory '/ssh:host:/src'\nfoo.c:3:1: error: x\n/ssh:host:/y.c:4:1: error: y\n"
                    "make: Entering directory '/ssh:host:~/lib'\nbar.c:5:1: error: z\n")
            (compilation-mode)
            (compilation--ensure-parse (point-max))
            (let ((structs (drgnx-trust-test--file-structs)))
              (should (equal (length structs) 3))
              (should (member '("foo.c" "/:/ssh:host:/src") structs))
              (dolist (s structs)                               ; every absolute name is quoted
                (dolist (name s)
                  (should (or (null name) (not (file-name-absolute-p name)) (string-prefix-p "/:" name)))))))
        (advice-remove 'tramp-file-name-handler #'drgnx-trust-test--tramp-stub))
      (should (seq-every-p (lambda (op) (eq op 'file-remote-p)) drgnx-trust-test--tramp-ops)))))

(ert-deftest drgnx-trust/links-to-remote-names-only-from-remote-buffers ()
  (with-temp-buffer
    (setq default-directory temporary-file-directory)
    (should (drgnx-trust-link-ok-p "/tmp/x"))
    (should-not (drgnx-trust-link-ok-p "/ssh:host:/x"))
    (let ((local (current-buffer)))
      (with-temp-buffer
        (setq default-directory "/ssh:host:/")
        (should (drgnx-trust-link-ok-p "/ssh:host:/x"))
        (should-not (drgnx-trust-link-ok-p "/ssh:host:/x" local))))))

(ert-deftest drgnx-trust/status-says-which-guards-are-on ()
  (drgnx-trust-test--with (_dir)
    (let ((s (drgnx-trust-guards-status)))
      (should (plist-get s :mode))
      (should (plist-get s :tramp))
      (should (memq (plist-get s :flymake) '(emacs drgnx)))
      (should (plist-get s :eglot-safe))
      (should (plist-get s :shorthands))
      (should (plist-get s :compile))
      (should (plist-get s :ffap)))
    (drgnx-trust-mode -1)
    (let ((s (drgnx-trust-guards-status)))
      (should-not (plist-get s :mode))
      (should-not (plist-get s :tramp))
      (should-not (plist-get s :shorthands))
      (should-not (plist-get s :compile))
      (should-not (plist-get s :ffap))
      (should-not (eq (plist-get s :flymake) 'drgnx)))))

(ert-deftest drgnx-trust/remote-settings-ffap-set-the-others-pinned ()
  (drgnx-trust-test--with (_dir)
    ;; ffap never pings a host name taken from text, while the user left it at its default
    (should (eq ffap-machine-p-known 'reject))
    (drgnx-trust-mode -1)
    (should (eq ffap-machine-p-known 'ping))
    (let ((ffap-machine-p-known 'accept))                       ; the user's own choice stays
      (drgnx-trust-mode 1)
      (should (eq ffap-machine-p-known 'accept))
      (drgnx-trust-mode -1)
      (should (eq ffap-machine-p-known 'accept)))
    (drgnx-trust-mode 1)
    ;; auto-save-visited-mode, if the user turns it on, never saves remote files (Emacs's default, nil, would)
    (should (eq remote-file-name-inhibit-auto-save-visited t))
    (drgnx-trust-mode -1)
    (should-not remote-file-name-inhibit-auto-save-visited)
    (let ((remote-file-name-inhibit-auto-save-visited 'yes))   ; a value the user set stays
      (drgnx-trust-mode 1)
      (should (eq remote-file-name-inhibit-auto-save-visited 'yes))
      (drgnx-trust-mode -1)
      (should (eq remote-file-name-inhibit-auto-save-visited 'yes)))
    (drgnx-trust-mode 1)
    ;; not set by drgnx, pinned at Emacs's defaults and reported
    (should-not enable-remote-dir-locals)
    (should-not auto-revert-remote-files)
    (let ((s (drgnx-trust-guards-status)))
      (should (equal (list (plist-get s :enable-remote-dir-locals) (plist-get s :auto-revert-remote-files)
                           (plist-get s :remote-file-name-inhibit-auto-save-visited))
                     '(nil nil t))))))

;;;; Fix round 2: entries read from trusted-folders.eld never reach a file name handler

(ert-deftest drgnx-trust/a-remote-entry-is-not-trusted-and-connects-nowhere ()
  (drgnx-trust-test--with (dir)
    (let ((e (drgnx-trust--entry dir)) (drgnx-trust-test--tramp-ops nil) (inhibit-message t))
      (drgnx-trust-test--put (format "(:version 1 :folders (\"/ssh:drgnx-test.invalid:/proj/\" %S))" e))
      (advice-add 'tramp-file-name-handler :around #'drgnx-trust-test--tramp-stub)
      (unwind-protect
          (should (= 0 (drgnx-trust-test--no-connections
                        (should (equal (drgnx-trust-folders) (list e)))
                        (should (drgnx-trust-test--trusts-from-file-p e))
                        (should-not (member "/ssh:drgnx-test.invalid:/proj/" trusted-content))
                        ;; Trust This Folder refuses a remote folder: the next session would not trust it
                        (should-error (drgnx-trust-folder "/ssh:drgnx-test.invalid:/proj/") :type 'user-error))))
        (advice-remove 'tramp-file-name-handler #'drgnx-trust-test--tramp-stub))
      ;; TRAMP was only asked whether the name is remote, which never connects
      (should (seq-every-p (lambda (op) (eq op 'file-remote-p)) drgnx-trust-test--tramp-ops)))))

;;; trust-test.el ends here
