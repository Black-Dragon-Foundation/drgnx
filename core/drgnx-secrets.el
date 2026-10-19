;;; drgnx-secrets.el --- Provider keys on a second machine: secrets.age -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx secrets export' puts the keys of the providers that have one (`:key-env') from this machine's keyring
;; into one age-encrypted file, secrets.age in the config folder; `drgnx secrets import' on the other machine puts
;; them into its keyring.  The plaintext bundle only ever travels on pipes: never in a file, a command line, a
;; buffer, *Messages* or the kill ring, and the strings that held it are overwritten after use.
;;
;; age asks for a passphrase on the terminal (it opens /dev/tty itself), and a process Emacs starts has no
;; terminal: Emacs starts every asynchronous child in a session of its own.  So with a passphrase, age runs in
;; bin/drgnx's pipeline (`emacs … | age -e -p -o FILE.new', `age -d FILE | emacs …') and this file does both
;; halves (`DRGNX_SECRETS_PIPE'); with --recipient or --identity, Emacs runs age itself.  These are batch commands
;; a user runs on a terminal: the one place, besides storing a key a user typed, where drgnx opens the keyring
;; from batch Emacs (`DRGNX_STDIN_TTY', set by bin/drgnx).  See docs/guide/second-machine.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'drgnx-paths)
(require 'drgnx-ai)

(defvar drgnx-onboard-install-recipes)
(declare-function drgnx-onboard--linux-shell "drgnx-onboard")
(declare-function drgnx-terminal-eat-usable-p "drgnx-terminal")
(declare-function drgnx-terminal-eat-start "drgnx-terminal-eat")
(declare-function term-char-mode "term")
(defvar drgnx-ai--security-program)

(defun drgnx-secrets-file ()
  "The encrypted key bundle: secrets.age in `drgnx-user-dir'."
  (expand-file-name "secrets.age" (drgnx-user-dir)))

(defun drgnx-secrets--wipe (s)
  "Overwrite string S in place (a string that held plaintext), so its text is gone before the collector frees it."
  (when (stringp s)
    (condition-case nil (fillarray s ?\0)
      (error (ignore-errors (dotimes (i (length s)) (aset s i ?\0)))))))

(defun drgnx-secrets--wipe-entries (entries)
  "Overwrite the keys of bundle ENTRIES."
  (dolist (e entries) (drgnx-secrets--wipe (plist-get e :key))))

(defun drgnx-secrets--host (provider)
  "The host of PROVIDER's address (a provider plist), or nil."
  (let ((url (plist-get provider :url)))
    (and (stringp url) (url-host (url-generic-parse-url url)))))

(defun drgnx-secrets-keyring-p ()
  "Non-nil when this machine has a keyring drgnx can store keys in: macOS's Keychain tool, or on Linux
`secret-tool' and a Secret Service on a session bus."
  (if (eq system-type 'darwin)
      (file-executable-p drgnx-ai--security-program)
    (and (executable-find "secret-tool") (drgnx-ai--secret-service-p) t)))

;;;; The bundle

(defconst drgnx-secrets-max-size (* 1024 1024)
  "The largest secrets.age, and the most plaintext, drgnx reads (bytes): a key bundle is a few hundred.")

(defconst drgnx-secrets-max-key 4096 "The longest key a bundle may hold (characters).")

(defun drgnx-secrets--entry-problem (e hosts)
  "Why bundle entry E is not one, or nil; HOSTS are the hosts of the entries before it.  Never shows a value."
  (cond ((not (and (proper-list-p e) (= (length e) 6) (eq (nth 0 e) :provider) (eq (nth 2 e) :host) (eq (nth 4 e) :key)))
         "an entry that is not (:provider ID :host HOST :key KEY)")
        ((not (and (nth 1 e) (symbolp (nth 1 e)))) "a provider that is not a name")
        ;; a host is printed (ls, import's lines): letters, digits, dots and dashes only, so it cannot fake a line
        ((not (and (stringp (nth 3 e)) (<= (length (nth 3 e)) 253) (string-match-p "\\`[A-Za-z0-9.-]+\\'" (nth 3 e))))
         "a host that is not a host name")
        ((member (nth 3 e) hosts) "the same host twice")
        ;; a key goes to the keyring as is: no spaces or control characters (NUL, ESC, CR, LF), no unbounded length
        ((not (and (stringp (nth 5 e)) (string-match-p "\\`[[:graph:]]+\\'" (nth 5 e))))
         "a key that is empty or holds spaces or control characters")
        ((> (length (nth 5 e)) drgnx-secrets-max-key) "a key that is too long")))

(defun drgnx-secrets--parse (text)
  "The entries of the key bundle TEXT, a list of (:provider ID :host HOST :key KEY); else a `user-error'.
TEXT must be exactly (:version 1 :keys ENTRIES): a host a host name, each once; a key printable characters with no
space, at most `drgnx-secrets-max-key' long.  The error says what is wrong by name and never shows TEXT."
  (let ((bad (lambda (why)
               (user-error "secrets.age is not a drgnx key bundle (%s); nothing was changed" why)))
        form end problem hosts)
    (when (> (length text) drgnx-secrets-max-size) (funcall bad "too large"))
    (condition-case nil
        (setq form (read-from-string text) end (cdr form) form (car form))
      (error (funcall bad "wrong file, damaged, or not age's output")))
    (setq problem
          (cond ((not (string-blank-p (substring text end))) "more text after the bundle")
                ((not (and (proper-list-p form) (= (length form) 4) (eq (nth 0 form) :version) (eq (nth 2 form) :keys)
                           (proper-list-p (nth 3 form))))
                 "not a bundle")
                ((not (eql (nth 1 form) 1)) "from another drgnx version")
                (t (seq-some (lambda (e) (prog1 (drgnx-secrets--entry-problem e hosts)
                                           (when (proper-list-p e) (push (plist-get e :host) hosts))))
                             (nth 3 form)))))
    (when problem
      (when (and (proper-list-p form) (proper-list-p (nth 3 form)))
        (ignore-errors (drgnx-secrets--wipe-entries (seq-filter #'proper-list-p (nth 3 form)))))
      (funcall bad problem))
    (nth 3 form)))

(defun drgnx-secrets--entries ()
  "This machine's keys, one entry per host: each provider with a `:key-env' whose host's key is in the keyring
\(`drgnx-ai--stored-key'; never the environment)."
  (let (entries hosts)
    (dolist (p (drgnx-ai-providers))
      (let ((host (and (plist-get (cdr p) :key-env) (drgnx-secrets--host (cdr p)))))
        (when (and host (not (member host hosts)))
          (push host hosts)
          (when-let* ((key (drgnx-ai--stored-key host)))
            (push (list :provider (car p) :host host :key key) entries)))))
    (or (nreverse entries)
        (user-error "No provider key in your keyring: nothing to export (keys in the environment are not exported)"))))

(defun drgnx-secrets--print (entries)
  "ENTRIES as the bundle's text (one line).  The caller wipes it."
  (let ((print-length nil) (print-level nil) (print-escape-newlines t))
    (prin1-to-string (list :version 1 :keys entries))))

;;;; Export, decrypt, import, ls

(defun drgnx-secrets--age ()
  "The age program, or a `user-error' naming its install line."
  (or (executable-find "age") (user-error "%s" (drgnx-secrets--age-missing))))

(defun drgnx-secrets--confirm-replace ()
  "When secrets.age exists, ask before it is replaced; a no is a `user-error'.  Asked before age runs."
  (let ((file (drgnx-secrets-file)))
    (when (and (file-exists-p file)
               (not (y-or-n-p (format "Replace %s (the keys it holds now are lost)? " (abbreviate-file-name file)))))
      (user-error "Kept %s; nothing exported" (abbreviate-file-name file)))))

(cl-defun drgnx-secrets-export (&key recipients)
  "Write this machine's provider keys to secrets.age with age, for RECIPIENTS (age public keys) or, without them,
a passphrase.  Returns the hosts written.  An existing secrets.age is replaced only after a yes; it is replaced
only when age succeeded (age writes FILE.new, renamed over it).  A passphrase needs age on a terminal, which a
program Emacs starts never has: from Lisp, without RECIPIENTS, age fails and nothing changes; `drgnx secrets
export' runs age in bin/drgnx's pipe instead (`drgnx-secrets-cli-run')."
  (let* ((age (drgnx-secrets--age))
         (file (drgnx-secrets-file))
         (new (concat file ".new"))
         (args (append '("-e") (if recipients (mapcan (lambda (r) (list "-r" r)) recipients) '("-p")) (list "-o" new)))
         (entries nil) (text nil) (status nil))
    (drgnx-secrets--confirm-replace)
    (setq entries (drgnx-secrets--entries))
    (make-directory (file-name-directory file) t)
    (when (file-exists-p new) (delete-file new))
    (unwind-protect
        (let ((drgnx-ai--store-timeout 600))       ; a passphrase typed twice
          (setq text (drgnx-secrets--print entries))
          (setq status (drgnx-ai--run-with-stdin age args text)))
      (drgnx-secrets--wipe text)
      (drgnx-secrets--wipe-entries entries)
      (unless (eql status 0) (when (file-exists-p new) (delete-file new))))
    (unless (eql status 0)
      (user-error "age did not encrypt the keys (%s); %s is unchanged"
                  (if (eq status 'timeout) "no answer" (format "exit %s" status)) (abbreviate-file-name file)))
    (rename-file new file t)
    (mapcar (lambda (e) (plist-get e :host)) entries)))

(defun drgnx-secrets--identity-warning (identity)
  "A warning when the age identity file IDENTITY can be read by users other than its owner, else nil."
  (let ((modes (file-modes (expand-file-name identity))))
    (when (and modes (/= 0 (logand modes #o077)))
      (format "%s can be read by other users: chmod 600 %s" identity (shell-quote-argument identity)))))

(cl-defun drgnx-secrets-decrypt (&key identity)
  "The plaintext of secrets.age, by `age -d' with IDENTITY (a file), else a passphrase.
The output is gathered from a pipe by a filter, never a buffer or a file; the caller wipes the string
\(`drgnx-secrets--wipe').  A failure is a `user-error' with age's reason.  Without IDENTITY age needs a terminal,
which a program Emacs starts never has (see `drgnx-secrets-export'): it fails, and bin/drgnx's pipe does it."
  (let* ((age (drgnx-secrets--age))
         (file (drgnx-secrets-file))
         (chunks nil) (size 0) (err nil) proc errproc)
    (unless (file-exists-p file) (user-error "No secrets.age in %s" (abbreviate-file-name (drgnx-user-dir))))
    (when (> (or (file-attribute-size (file-attributes file)) 0) drgnx-secrets-max-size)
      (user-error "%s is too large for a key bundle; nothing was read" (abbreviate-file-name file)))
    (when-let* ((warning (and identity (drgnx-secrets--identity-warning identity))))
      (drgnx-secrets--say "drgnx secrets: %s" warning))
    (unwind-protect
        (progn
          (setq errproc (make-pipe-process :name "drgnx-age-err" :buffer nil :noquery t :coding 'utf-8-unix
                                           :filter (lambda (_p s) (push s err))))
          (setq proc (make-process :name "drgnx-age" :buffer nil :connection-type 'pipe :noquery t
                                   :command (append (list age "-d") (and identity (list "-i" (expand-file-name identity)))
                                                    (list file))
                                   :coding 'no-conversion :stderr errproc
                                   :filter (lambda (p s)
                                             (setq size (+ size (length s)))
                                             (if (> size drgnx-secrets-max-size)
                                                 (progn (drgnx-secrets--wipe s) (delete-process p))
                                               (push s chunks)))
                                   :sentinel #'ignore))
          (ignore-errors (process-send-eof proc)) ; age may be gone already (it reads the file): never an error
          (let ((deadline (+ (float-time) 600)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (while (accept-process-output errproc 0.05))
          (cond ((> size drgnx-secrets-max-size) (user-error "age gave more than a key bundle holds; nothing was changed"))
                ((process-live-p proc) (user-error "age did not answer; nothing was read"))
                ((not (eql (process-exit-status proc) 0))
                 (user-error "age could not decrypt %s: %s" (abbreviate-file-name file)
                             (let ((why (string-trim (string-join (reverse err) ""))))
                               (if (string-empty-p why) (format "exit %s" (process-exit-status proc))
                                 (car (split-string why "\n"))))))
                (t (apply #'concat (reverse chunks)))))
      (mapc #'drgnx-secrets--wipe chunks)
      (when (process-live-p proc) (delete-process proc))
      (when errproc (delete-process errproc)))))

(defun drgnx-secrets--reason (err &optional key)
  "ERR's message, unless it is not one of drgnx's own (a `user-error') and holds KEY: then only its symbol."
  (let ((msg (error-message-string err)))
    (if (or (eq (car err) 'user-error) (not (and key (string-search key msg))))
        msg
      (symbol-name (car err)))))

(defun drgnx-secrets--import-text (text &optional replace)
  "Store the keys of bundle TEXT in the keyring; see `drgnx-secrets-import' (REPLACE as there).  TEXT is not wiped
here."
  (let ((entries (drgnx-secrets--parse text)) stored same differs unknown failed)
    (unwind-protect
        (dolist (e entries)
          (let* ((id (plist-get e :provider)) (host (plist-get e :host))
                 (p (drgnx-ai-provider id)))
            (if (not (and p (plist-get p :key-env) (equal (drgnx-secrets--host p) host)))
                (push host unknown)
              (condition-case err
                  (let ((held (drgnx-ai--stored-key host)))
                    (unwind-protect
                        (cond ((equal held (plist-get e :key)) (push host same))
                              ((and held (not replace)) (push host differs))   ; never lose a key without --replace
                              (t (drgnx-ai-store-key id (copy-sequence (plist-get e :key)))
                                 (push host stored)))
                      (drgnx-secrets--wipe held)))
                (error (push (cons host (drgnx-secrets--reason err (plist-get e :key))) failed))))))
      (drgnx-secrets--wipe-entries entries))
    (list :stored (nreverse stored) :same (nreverse same) :differs (nreverse differs) :unknown (nreverse unknown)
          :failed (nreverse failed))))

(defun drgnx-secrets--import-ready (&optional from-stdin)
  "Nil when an import can go ahead, else (:skipped REASON).  FROM-STDIN: the bundle comes from a pipe, not the file."
  (cond ((not (drgnx-secrets-keyring-p))
         (list :skipped "no keyring here: set the key in the environment instead (docs/guide/ai.md)"))
        ((and (not from-stdin) (not (file-exists-p (drgnx-secrets-file))))
         (list :skipped (format "no secrets.age in %s: nothing to import" (abbreviate-file-name (drgnx-user-dir)))))))

(cl-defun drgnx-secrets-import (&key identity replace)
  "Put the keys of secrets.age into this machine's keyring (decrypted with IDENTITY; a passphrase only through
bin/drgnx's pipe, see `drgnx-secrets-decrypt').
Returns (:stored HOSTS :same HOSTS :differs HOSTS :unknown HOSTS :failed ((HOST . REASON)…)): an entry whose
provider is not known here, or whose host differs here, is unknown and not stored; a key the keyring already holds
is the same; where the keyring holds a different key, that key is kept and the host differs — unless REPLACE (the
user asked for it: `--replace'), which stores the bundle's; a key the keyring refused is failed.  Without a keyring
or secrets.age: (:skipped REASON), and age is not run.  A bundle that does not decrypt or parse stores nothing (a
`user-error')."
  (or (drgnx-secrets--import-ready)
      (let ((text (drgnx-secrets-decrypt :identity identity)))
        (unwind-protect (drgnx-secrets--import-text text replace)
          (drgnx-secrets--wipe text)))))

(defun drgnx-secrets--hosts (text)
  "The hosts of bundle TEXT; its keys are wiped."
  (let ((entries (drgnx-secrets--parse text)))
    (prog1 (mapcar (lambda (e) (plist-get e :host)) entries)
      (drgnx-secrets--wipe-entries entries))))

(cl-defun drgnx-secrets-ls (&key identity)
  "The hosts whose keys secrets.age holds (never the keys), decrypted with IDENTITY (see `drgnx-secrets-decrypt')."
  (let ((text (drgnx-secrets-decrypt :identity identity)))
    (unwind-protect (drgnx-secrets--hosts text)
      (drgnx-secrets--wipe text))))

;;;; CLI: drgnx secrets

(defun drgnx-secrets--age-missing ()
  "What to say when age is not installed: the install line of `drgnx-onboard-install-recipes' for this platform."
  (require 'drgnx-onboard)
  (let* ((r (alist-get 'age drgnx-onboard-install-recipes))
         (line (if (eq (drgnx-platform) 'macos)
                   (string-join (plist-get (plist-get r :macos) :install) " ")
                 (drgnx-onboard--linux-shell (plist-get r :linux)))))
    (if line (format "age is not installed: install it with  %s  (docs/guide/second-machine.md)" line)
      "age is not installed: install it with your package manager (https://age-encryption.org; docs/guide/second-machine.md)")))

(defvar drgnx-secrets--say-on-stderr nil
  "Non-nil while standard output is age's input (the bundle half of the pipe): `drgnx-secrets--say' uses stderr.")

(defun drgnx-secrets--say (fmt &rest args)
  "Print FMT with ARGS and a newline on standard output (stderr in the bundle half of the pipe)."
  (if drgnx-secrets--say-on-stderr
      (message "%s" (apply #'format fmt args))
    (princ (concat (apply #'format fmt args) "\n"))))

(defun drgnx-secrets--print-import (r)
  "Print import result R, one host a line; the exit code (1 when any failed or differs, or nothing could be imported)."
  (if (eq (car r) :skipped)
      (progn (drgnx-secrets--say "drgnx secrets: %s" (cadr r)) 1)
    (dolist (h (plist-get r :stored)) (drgnx-secrets--say "stored   %s" h))
    (dolist (h (plist-get r :same)) (drgnx-secrets--say "same     %s" h))
    (dolist (h (plist-get r :differs))
      (drgnx-secrets--say "differs  %s  (your keyring's key is kept: drgnx secrets import --replace to overwrite it)" h))
    (dolist (h (plist-get r :unknown)) (drgnx-secrets--say "unknown  %s  (no provider with this address here: not stored)" h))
    (dolist (f (plist-get r :failed)) (drgnx-secrets--say "failed   %s  %s" (car f) (cdr f)))
    (if (or (plist-get r :failed) (plist-get r :differs)) 1 0)))

(defun drgnx-secrets--read-stdin ()
  "The bundle on standard input (bin/drgnx's pipe from age), or a `user-error' when age gave nothing.
Its size is checked by `drgnx-secrets--parse'."
  (condition-case nil (read-from-minibuffer "")
    (end-of-file (user-error "age gave nothing to read (a wrong passphrase or a damaged file?): nothing was changed"))))

(defun drgnx-secrets-cli-run (args)
  "Run `drgnx secrets' ARGS: export [--recipient R]… | import [--identity FILE] [--replace] | ls [--identity FILE].
The exit code: 0 done, 1 failed (or a key differs), 2 a usage error, 3 needs a terminal or age.  10: with a
passphrase, the checks passed and bin/drgnx runs age in its pipeline, which runs this again with
DRGNX_SECRETS_PIPE set: `bundle' (export: print the bundle on stdout, into age) or `stdin' (import, ls: the
plaintext arrives from age on stdin).  The halves run only on a terminal and without --recipient/--identity: the
bundle goes nowhere but into age."
  (let* ((sub (car args)) (rest (cdr args)) recipients identity replace bad
         (pipe (getenv "DRGNX_SECRETS_PIPE"))
         (tty (equal (getenv "DRGNX_STDIN_TTY") "1"))
         (drgnx-secrets--say-on-stderr (equal pipe "bundle")))
    (while rest
      (pcase (pop rest)
        ((and "--recipient" (guard (and rest (equal sub "export")))) (push (pop rest) recipients))
        ((and "--identity" (guard (and rest (member sub '("import" "ls")) (not identity)))) (setq identity (pop rest)))
        ((and "--replace" (guard (equal sub "import"))) (setq replace t))
        (_ (setq bad t))))
    (setq recipients (nreverse recipients))
    (condition-case err
        (cond
         ((or bad (not (member sub '("export" "import" "ls")))
              ;; the halves of bin/drgnx's pipeline, and nothing else
              (and pipe (not (and tty (not recipients) (not identity)
                                  (or (and (equal pipe "bundle") (equal sub "export"))
                                      (and (equal pipe "stdin") (member sub '("import" "ls"))))))))
          (drgnx-secrets--say "usage: drgnx secrets export [--recipient R]… | import [--identity FILE] [--replace] | ls [--identity FILE]")
          2)
         ((not (or tty recipients identity))
          (drgnx-secrets--say "drgnx secrets: needs a terminal (for age's passphrase), or %s"
                              (if (equal sub "export") "--recipient R" "--identity FILE"))
          3)
         ((equal pipe "bundle")
          (let* ((entries (drgnx-secrets--entries)) (text nil))
            (unwind-protect (princ (setq text (drgnx-secrets--print entries)))
              (drgnx-secrets--wipe text)
              (drgnx-secrets--wipe-entries entries)))
          0)
         ((equal pipe "stdin")
          (if (and (equal sub "import") (drgnx-secrets--import-ready t))
              (drgnx-secrets--print-import (drgnx-secrets--import-ready t))
            (let ((text (drgnx-secrets--read-stdin)))
              (unwind-protect
                  (if (equal sub "import") (drgnx-secrets--print-import (drgnx-secrets--import-text text replace))
                    (dolist (h (drgnx-secrets--hosts text)) (drgnx-secrets--say "%s" h))
                    0)
                (drgnx-secrets--wipe text)))))
         ((not (executable-find "age")) (drgnx-secrets--say "drgnx secrets: %s" (drgnx-secrets--age-missing)) 3)
         ((equal sub "export")
          ;; replacing secrets.age asks first, and only a terminal can answer
          (when (and (not tty) (file-exists-p (drgnx-secrets-file)))
            (user-error "secrets.age exists: run on a terminal to replace it (nothing exported)"))
          (if recipients
              (let ((hosts (drgnx-secrets-export :recipients recipients)))
                (drgnx-secrets--say "drgnx secrets: wrote %s (keys of %s)" (abbreviate-file-name (drgnx-secrets-file))
                                    (string-join hosts ", "))
                0)
            ;; a passphrase: the checks and the question here, before age asks anything; then bin/drgnx's pipe
            (drgnx-secrets--wipe-entries (drgnx-secrets--entries))
            (drgnx-secrets--confirm-replace)
            10))
         ((equal sub "import")
          (cond ((drgnx-secrets--import-ready) (drgnx-secrets--print-import (drgnx-secrets--import-ready)))
                (identity (drgnx-secrets--print-import (drgnx-secrets-import :identity identity :replace replace)))
                (t 10)))
         (t
          (cond ((not (file-exists-p (drgnx-secrets-file)))
                 (user-error "No secrets.age in %s" (abbreviate-file-name (drgnx-user-dir))))
                (identity (dolist (h (drgnx-secrets-ls :identity identity)) (drgnx-secrets--say "%s" h)) 0)
                (t 10))))
      ;; every error is caught: an uncaught one would print a backtrace, with the plaintext among its arguments
      (user-error (drgnx-secrets--say "drgnx secrets: %s" (error-message-string err)) 1)
      (error (drgnx-secrets--say "drgnx secrets: failed (%s); nothing more was done" (car err)) 1))))

(defun drgnx-secrets-cli ()
  "bin/drgnx secrets: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-secrets-cli-run args))))

;;;; Commands: Portability: Export Keys / Import Keys

(defconst drgnx-secrets-export-header
  "Type a passphrase for secrets.age twice: you type it again on the other machine. Then copy secrets.age with your config"
  "The header of the Export Keys terminal.")

(defconst drgnx-secrets-import-header
  "Type the passphrase of secrets.age: its keys go into this machine's keyring"
  "The header of the Import Keys terminal.")

(defun drgnx-secrets--terminal (sub header)
  "A terminal running `drgnx secrets SUB' with HEADER as its header line, shown; returns its buffer.
Eat when it can run here, else `term'.  This Emacs runs nothing of age's: age asks in the terminal."
  (let* ((bin (expand-file-name "bin/drgnx" drgnx-dir))
         (dir (expand-file-name "~/"))
         (buf (if (and (fboundp 'drgnx-terminal-eat-usable-p) (drgnx-terminal-eat-usable-p dir))
                  (drgnx-terminal-eat-start dir (list bin "secrets" sub))
                (require 'term)
                (let ((default-directory dir) (b (make-term (format "drgnx secrets %s" sub) bin nil "secrets" sub)))
                  (with-current-buffer b (term-char-mode))
                  (pop-to-buffer b)
                  b))))
    (with-current-buffer buf (setq header-line-format header))
    (when-let* ((proc (get-buffer-process buf)))
      (add-function :after (process-sentinel proc) #'drgnx-secrets--forget-keys))
    buf))

(defun drgnx-secrets--forget-keys (proc _event)
  "When PROC (a secrets terminal) has ended, clear Emacs's record of recent keys (`recent-keys', C-h l): the
passphrase was typed there.  A sentinel: no prompt."
  (unless (process-live-p proc) (clear-this-command-keys)))

(defun drgnx-secrets-export-keys ()
  "Export this machine's provider keys to secrets.age, in a terminal (age asks for a passphrase there)."
  (interactive)
  (drgnx-secrets--terminal "export" drgnx-secrets-export-header))

(defun drgnx-secrets-import-keys ()
  "Import the provider keys of secrets.age into this machine's keyring, in a terminal (age asks for the passphrase)."
  (interactive)
  (drgnx-secrets--terminal "import" drgnx-secrets-import-header))

(provide 'drgnx-secrets)
;;; drgnx-secrets.el ends here
