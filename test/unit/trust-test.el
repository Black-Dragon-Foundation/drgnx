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

(defmacro drgnx-trust-test--with (spec &rest body)
  "BODY with the guards on, its own `trusted-content' and state dir, and (car SPEC) bound to a fresh folder
nobody trusted.  Buffers BODY opens are killed after it."
  (declare (indent 1))
  (let ((dir (car spec)))
    `(let* ((was drgnx-trust-mode) (buffers (buffer-list))
            (state (make-temp-file "drgnx-trust-state" t))
            (,dir (file-name-as-directory (make-temp-file "drgnx-trust-proj" t)))
            (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
       (unwind-protect
           (let ((trusted-content nil) (tramp-ignored-file-name-regexp nil))
             (drgnx-trust-mode 1)
             (unwind-protect (progn ,@body) (drgnx-trust-mode -1)))
         (dolist (b (buffer-list))
           (unless (memq b buffers) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
         (when was (drgnx-trust-mode 1))
         (delete-directory state t)
         (delete-directory ,dir t)))))

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
                  ;; a user@host part with a control or shell character, a leading -, a newline before the name
                  (dolist (n (list "/ssh:a&b@h:/x" "/ssh:a!b@h:/x" "/ssh:a,b@h:/x" "/ssh:a;b@h:/x" "/ssh:a`b@h:/x"
                                   "/ssh:a\001b@h:/x" "/ssh:a\tb@h:/x" "/ssh:-x@h:/x" "/tmp/x\n/ssh:h:/x"
                                   "/ssh:a@b|sudo:r&t@b:/x"))
                    (should-not (tramp-tramp-file-p n))
                    (should-not (file-remote-p n)))
                  ;; legitimate names stay remote (file-remote-p answers without connecting)
                  (dolist (n (list "/ssh:host:/path" "/ssh:user@host#2222:/a (1).txt" "/ssh:a@b|sudo:root@b:/x"
                                   "/podman:name:/" "/ssh:user@[::1]:/x" "/sudo::/etc/hosts" "/ssh:h:/a;b&c!d"))
                    (should (tramp-tramp-file-p n))
                    (should (file-remote-p n)))
                  (let ((process-environment (cons "USER=someone" process-environment)))
                    (should (tramp-tramp-file-p "/ssh:$USER@host:/x"))))))))

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

(ert-deftest drgnx-trust/the-user-settings-are-kept ()
  (drgnx-trust-test--with (_dir)
    (let ((trusted-content '("/mine/")) (tramp-ignored-file-name-regexp "\\`/nope:"))
      (drgnx-trust-mode 1)
      (should (equal (car trusted-content) "/mine/"))
      (should (member (drgnx-trust--entry drgnx-dir) trusted-content))
      (should (member (drgnx-trust--entry (drgnx-elpa-dir)) trusted-content))
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
      (should (plist-get s :compile)))
    (drgnx-trust-mode -1)
    (let ((s (drgnx-trust-guards-status)))
      (should-not (plist-get s :mode))
      (should-not (plist-get s :tramp))
      (should-not (plist-get s :shorthands))
      (should-not (plist-get s :compile))
      (should-not (eq (plist-get s :flymake) 'drgnx)))))

;;; trust-test.el ends here
