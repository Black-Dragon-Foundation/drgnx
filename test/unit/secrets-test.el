;;; secrets-test.el --- batch tests: provider keys on a second machine (secrets.age) -*- lexical-binding: t -*-
;; A fake `age' (a bash script: -e rot13s stdin into -o, -d reverses a file to stdout, both append their argv to
;; ARGV.log, -d fails when FAKE_AGE_FAIL is set) on a temp PATH; the keyring is a hash table behind stubs of
;; `drgnx-ai--stored-key' and `drgnx-ai-store-key'.  Keys are built at run time.  The runner gives every test a temp
;; HOME, config, data, state and cache.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'rot13)
(require 'term)                         ; loaded now, so a test's stub of `make-term' is not replaced by it
(require 'drgnx-secrets)

(defun drgnx-secrets-test--key (c) "A test key, built at run time." (concat "sk-or-v1-" (make-string 24 c)))

(defconst drgnx-secrets-test--providers
  '((openrouter :name "OpenRouter" :kind openai :url "https://openrouter.ai/api/v1" :key-env "OPENROUTER_API_KEY")
    (example :name "Example" :kind openai :url "https://api.example.com/v1" :key-env "EXAMPLE_API_KEY")
    (ollama :name "Ollama" :kind openai :url "http://localhost:11434/v1"))
  "The providers the tests see: two with a key, one local runner.")

(defconst drgnx-secrets-test--fake-age
  "#!/bin/bash
PATH=/usr/bin:/bin
printf '%s\\n' \"$*\" >> \"$FAKE_AGE_LOG\"
mode= out= file=
while [ $# -gt 0 ]; do
  case $1 in
    -e|-d) mode=$1 ;;
    -p) ;;
    -r|-i) shift ;;
    -o) shift; out=$1 ;;
    *) file=$1 ;;
  esac
  shift
done
rot() { tr 'A-Za-z' 'N-ZA-Mn-za-m'; }
if [ \"$mode\" = -e ]; then rot > \"$out\"; exit $?; fi
cat > /dev/null
if [ -n \"${FAKE_AGE_FAIL-}\" ]; then echo 'age: error: incorrect passphrase' >&2; exit 1; fi
rot < \"$file\"
")

(defvar drgnx-secrets-test--handed-out nil "The strings the fake keyring returned, newest first.")

(defmacro drgnx-secrets-test--with (spec &rest body)
  "Run BODY with a fake age and keyring.  SPEC is (BIN LOG STORE STORED-CALLS); STORE is the keyring (host → key),
STORED-CALLS a list of the ids `drgnx-ai-store-key' was called with (newest first)."
  (declare (indent 1))
  (pcase-let ((`(,bin ,log ,store ,calls) spec))
    `(let* ((,bin (file-name-as-directory (make-temp-file "drgnx-secrets-bin" t)))
            (,log (expand-file-name "ARGV.log" ,bin))
            (,store (make-hash-table :test #'equal))
            (,calls nil))
       (ignore ,calls)
       (unwind-protect
           (progn
             (with-temp-file (expand-file-name "age" ,bin) (insert drgnx-secrets-test--fake-age))
             (set-file-modes (expand-file-name "age" ,bin) #o755)
             (let ((exec-path (list ,bin))
                   (drgnx-secrets-test--handed-out nil)
                   (process-environment (append (list (concat "PATH=" ,bin) (concat "FAKE_AGE_LOG=" ,log) "DRGNX_STDIN_TTY=1"
                                                      ;; a config dir of this test's own: no secrets.age from another
                                                      (concat "DRGNX_CONFIG_DIR=" ,bin "config"))
                                                process-environment)))
               (cl-letf (((symbol-function 'drgnx-ai-providers) (lambda () drgnx-secrets-test--providers))
                         ((symbol-function 'drgnx-secrets-keyring-p) (lambda () t))
                         ;; a fresh string per read, as a real store gives; each one kept to check it was wiped
                         ((symbol-function 'drgnx-ai--stored-key)
                          (lambda (host) (let ((k (copy-sequence (gethash host ,store))))
                                           (when k (push k drgnx-secrets-test--handed-out))
                                           k)))
                         ((symbol-function 'drgnx-ai-store-key)
                          (lambda (id key)
                            (push id ,calls)
                            (puthash (url-host (url-generic-parse-url (plist-get (alist-get id drgnx-secrets-test--providers) :url)))
                                     (copy-sequence key) ,store)
                            'keyring))
                         ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                 ,@body)))
         (delete-directory ,bin t)))))

(defun drgnx-secrets-test--slurp (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents-literally file) (buffer-string)) ""))

(defun drgnx-secrets-test--files-holding (needle)
  "Every file under the run's HOME, config, data, state and cache dirs whose text holds NEEDLE."
  (let (hits)
    (dolist (dir (list (expand-file-name "~") (drgnx-user-dir) (drgnx-data-dir) (drgnx-state-dir) (drgnx-cache-dir)))
      (when (file-directory-p dir)
        (dolist (f (directory-files-recursively dir "" nil nil t))
          (when (and (file-regular-p f) (string-search needle (drgnx-secrets-test--slurp f)))
            (push f hits)))))
    hits))

(defun drgnx-secrets-test--write-bundle (text)
  "Put TEXT, encrypted by the fake age (rot13), into secrets.age."
  (make-directory (drgnx-user-dir) t)
  (let ((coding-system-for-write 'no-conversion))
    (write-region (rot13-string text) nil (drgnx-secrets-file) nil 'silent)))

(defun drgnx-secrets-test--bundle (&rest entries)
  (prin1-to-string (list :version 1 :keys entries)))

;;;; Export

(ert-deftest drgnx-secrets/export-writes-only-ciphertext ()
  (drgnx-secrets-test--with (bin log store _calls)
    (let ((k1 (drgnx-secrets-test--key ?x)) (k2 (drgnx-secrets-test--key ?y)))
      (puthash "openrouter.ai" k1 store)
      (puthash "api.example.com" k2 store)
      (with-current-buffer (messages-buffer) (let ((inhibit-read-only t)) (erase-buffer)))
      (should (equal (sort (drgnx-secrets-export) #'string<) '("api.example.com" "openrouter.ai")))
      (should (file-exists-p (drgnx-secrets-file)))
      (should-not (file-exists-p (concat (drgnx-secrets-file) ".new")))
      (dolist (k (list k1 k2))
        (should-not (drgnx-secrets-test--files-holding k))
        (should-not (string-search k (drgnx-secrets-test--slurp log)))
        (should-not (string-search k (with-current-buffer (messages-buffer) (buffer-string))))
        (should-not (seq-some (lambda (s) (string-search k s)) kill-ring)))
      ;; a passphrase by default; the bundle went in on stdin (the fake age read it from there)
      (should (string-match-p "\\`-e -p -o .*secrets\\.age\\.new\n\\'" (drgnx-secrets-test--slurp log)))
      ;; the strings read from the keyring were overwritten
      (should (= (length drgnx-secrets-test--handed-out) 2))
      (dolist (s drgnx-secrets-test--handed-out) (should (string-match-p "\\`\0+\\'" s)))
      (should (equal (drgnx-secrets--parse (drgnx-secrets-decrypt))
                     (list (list :provider 'openrouter :host "openrouter.ai" :key k1)
                           (list :provider 'example :host "api.example.com" :key k2)))))))

(ert-deftest drgnx-secrets/export-with-nothing-says-so ()
  (drgnx-secrets-test--with (bin log _store _calls)
    (let ((err (should-error (drgnx-secrets-export) :type 'user-error)))
      (should (string-match-p "nothing to export" (cadr err))))
    (should-not (file-exists-p (drgnx-secrets-file)))
    (should (equal (drgnx-secrets-test--slurp log) ""))))

(ert-deftest drgnx-secrets/export-uses-recipients ()
  (drgnx-secrets-test--with (bin log store _calls)
    (puthash "openrouter.ai" (drgnx-secrets-test--key ?x) store)
    (should (equal (drgnx-secrets-export :recipients '("age1one" "age1two")) '("openrouter.ai")))
    (let ((argv (drgnx-secrets-test--slurp log)))
      (should (string-match-p "\\`-e -r age1one -r age1two -o " argv))
      (should-not (string-match-p " -p " argv)))))

(ert-deftest drgnx-secrets/a-failed-export-keeps-the-old-file ()
  (drgnx-secrets-test--with (bin log store _calls)
    (puthash "openrouter.ai" (drgnx-secrets-test--key ?x) store)
    (drgnx-secrets-test--write-bundle "old")
    (cl-letf (((symbol-function 'drgnx-ai--run-with-stdin)
               (lambda (_program args _input)
                 (with-temp-file (car (last args)) (insert "partial"))
                 1)))
      (should-error (drgnx-secrets-export) :type 'user-error))
    (should-not (file-exists-p (concat (drgnx-secrets-file) ".new")))
    (should (equal (drgnx-secrets-test--slurp (drgnx-secrets-file)) "byq"))
    ;; a no to "replace?" changes nothing and runs nothing
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (should-error (drgnx-secrets-export) :type 'user-error))
    (should (equal (drgnx-secrets-test--slurp log) ""))
    (should (equal (drgnx-secrets-test--slurp (drgnx-secrets-file)) "byq"))))

;;;; Import

(ert-deftest drgnx-secrets/import-stores-each-known-provider ()
  (drgnx-secrets-test--with (bin log store calls)
    (let ((k1 (drgnx-secrets-test--key ?x)) (k2 (drgnx-secrets-test--key ?y)))
      (drgnx-secrets-test--write-bundle
       (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key k1)
                                   (list :provider 'example :host "api.example.com" :key k2)))
      (should (equal (drgnx-secrets-import)
                     '(:stored ("openrouter.ai" "api.example.com") :same nil :differs nil :unknown nil :failed nil)))
      (should (equal (gethash "openrouter.ai" store) k1))
      (should (equal (gethash "api.example.com" store) k2))
      (should (equal calls '(example openrouter)))
      (setq calls nil)
      (should (equal (drgnx-secrets-import)
                     '(:stored nil :same ("openrouter.ai" "api.example.com") :differs nil :unknown nil :failed nil)))
      (should-not calls)
      (should (string-match-p "\\`-d .*secrets\\.age\n" (drgnx-secrets-test--slurp log)))
      (should (string-match-p "^-d -i /.*/identity\\.txt .*secrets\\.age$"
                              (progn (drgnx-secrets-import :identity "identity.txt") (drgnx-secrets-test--slurp log)))))))

(ert-deftest drgnx-secrets/an-unknown-provider-is-named-not-stored ()
  (drgnx-secrets-test--with (bin _log store calls)
    (drgnx-secrets-test--write-bundle
     (drgnx-secrets-test--bundle (list :provider 'kimi :host "api.kimi.example" :key (drgnx-secrets-test--key ?z))
                                 ;; a known id whose address differs here: not this machine's provider
                                 (list :provider 'example :host "elsewhere.example" :key (drgnx-secrets-test--key ?w))
                                 (list :provider 'openrouter :host "openrouter.ai" :key (drgnx-secrets-test--key ?x))))
    (should (equal (drgnx-secrets-import)
                   '(:stored ("openrouter.ai") :same nil :differs nil :unknown ("api.kimi.example" "elsewhere.example") :failed nil)))
    (should (equal calls '(openrouter)))
    (should-not (gethash "api.kimi.example" store))))

(ert-deftest drgnx-secrets/a-store-that-refuses-is-failed ()
  (drgnx-secrets-test--with (bin _log store _calls)
    (drgnx-secrets-test--write-bundle
     (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (drgnx-secrets-test--key ?x))))
    (cl-letf (((symbol-function 'drgnx-ai-store-key) (lambda (&rest _) (user-error "The keyring refused the key (exit 1)"))))
      (should (equal (drgnx-secrets-import)
                     '(:stored nil :same nil :differs nil :unknown nil :failed (("openrouter.ai" . "The keyring refused the key (exit 1)"))))))
    (should-not (gethash "openrouter.ai" store))))

(ert-deftest drgnx-secrets/a-bad-bundle-changes-nothing ()
  (drgnx-secrets-test--with (bin _log _store calls)
    (let ((k (drgnx-secrets-test--key ?x)))
      (drgnx-secrets-test--write-bundle
       (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key k)))
      ;; age fails (a wrong passphrase): exit 1 from the CLI, nothing stored
      (let ((process-environment (cons "FAKE_AGE_FAIL=1" process-environment)))
        (should-error (drgnx-secrets-import) :type 'user-error)
        (let ((out (with-output-to-string (should (= 1 (drgnx-secrets-cli-run '("import" "--identity" "identity.txt")))))))
          (should (string-match-p "incorrect passphrase" out))
          (should-not (string-search k out))))
      (should-not calls)
      (dolist (text (list (substring (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key k)) 0 -10)
                          (prin1-to-string (list :version 2 :keys (list (list :provider 'openrouter :host "openrouter.ai" :key k))))
                          (prin1-to-string (list (list :provider 'openrouter :host "openrouter.ai" :key k)))
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (concat k "\nsecond")))
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key 42))
                          (concat (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key k)) " trailing")
                          ;; hosts and keys that could spoof output lines, send terminal escapes or store something else
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai\e[2Kstored x" :key k))
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "evil\nstored openrouter.ai" :key k))
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (concat k "\0tail")))
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (concat k " tail")))
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (concat k (make-string 5000 ?q))))
                          (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key k)
                                                      (list :provider 'openrouter :host "openrouter.ai" :key k))))
        (drgnx-secrets-test--write-bundle text)
        (let ((err (should-error (drgnx-secrets-import) :type 'user-error)))
          (should (string-match-p "not a drgnx key bundle" (cadr err)))
          (should-not (string-search (substring k 0 12) (cadr err)))
          (should-not (string-match-p "evil\\|\e\\|stored" (cadr err))))
        (should-not calls))
      ;; a file too large for a key bundle: refused before age runs
      (drgnx-secrets-test--write-bundle (make-string (* 2 1024 1024) ?a))
      (let ((log (drgnx-secrets-test--slurp (getenv "FAKE_AGE_LOG"))))
        (should (string-match-p "too large" (cadr (should-error (drgnx-secrets-import) :type 'user-error))))
        (should (equal (drgnx-secrets-test--slurp (getenv "FAKE_AGE_LOG")) log)))
      ;; and from age's pipe
      (let ((process-environment (cons "DRGNX_SECRETS_PIPE=stdin" process-environment)))
        (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (make-string (* 2 1024 1024) ?a))))
          (should (string-match-p "too large" (with-output-to-string (should (= 1 (drgnx-secrets-cli-run '("import"))))))))))
    (should-not calls)))

(ert-deftest drgnx-secrets/a-different-key-is-kept ()
  (drgnx-secrets-test--with (bin _log store calls)
    (let ((old (drgnx-secrets-test--key ?o)) (new (drgnx-secrets-test--key ?n)))
      (puthash "openrouter.ai" old store)
      (drgnx-secrets-test--write-bundle
       (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key new)))
      (should (equal (drgnx-secrets-import)
                     '(:stored nil :same nil :differs ("openrouter.ai") :unknown nil :failed nil)))
      (should (equal (gethash "openrouter.ai" store) old))
      (should-not calls)
      (let* ((code nil) (out (with-output-to-string (setq code (drgnx-secrets-cli-run '("import" "--identity" "identity.txt"))))))
        (should (= code 1))
        (should (string-match-p "^differs +openrouter\\.ai .*--replace" out))
        (should-not (string-search old out))
        (should-not (string-search new out)))
      (should (equal (gethash "openrouter.ai" store) old))
      ;; --replace: the bundle's key goes in
      (should (equal (drgnx-secrets-import :replace t)
                     '(:stored ("openrouter.ai") :same nil :differs nil :unknown nil :failed nil)))
      (should (equal (gethash "openrouter.ai" store) new))
      (puthash "openrouter.ai" old store)
      (should (= 0 (let ((standard-output #'ignore)) (drgnx-secrets-cli-run '("import" "--identity" "identity.txt" "--replace")))))
      (should (equal (gethash "openrouter.ai" store) new))
      (should (= 2 (let ((standard-output #'ignore)) (drgnx-secrets-cli-run '("ls" "--replace"))))))))

(ert-deftest drgnx-secrets/no-keyring-skips ()
  (drgnx-secrets-test--with (bin log _store calls)
    (drgnx-secrets-test--write-bundle
     (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (drgnx-secrets-test--key ?x))))
    (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () nil)))
      (let ((r (drgnx-secrets-import)))
        (should (eq (car r) :skipped))
        (should (string-match-p "no keyring here" (cadr r)))))
    (should-not calls)
    (should (equal (drgnx-secrets-test--slurp log) ""))      ; age never asked
    (delete-file (drgnx-secrets-file))
    (should (eq (car (drgnx-secrets-import)) :skipped))))

(ert-deftest drgnx-secrets/the-keyring-test-follows-the-platform ()
  (let ((bin (file-name-as-directory (make-temp-file "drgnx-secrets-kr" t))))
    (unwind-protect
        (progn
          (with-temp-file (concat bin "security") (insert "#!/bin/sh\n"))
          (set-file-modes (concat bin "security") #o755)
          (let ((system-type 'darwin) (drgnx-ai--security-program (concat bin "security")))
            (should (drgnx-secrets-keyring-p)))
          (let ((system-type 'darwin) (drgnx-ai--security-program (concat bin "none")))
            (should-not (drgnx-secrets-keyring-p)))
          (let ((system-type 'gnu/linux) (exec-path (list bin)))
            (should-not (drgnx-secrets-keyring-p))   ; no secret-tool
            (with-temp-file (concat bin "secret-tool") (insert "#!/bin/sh\n"))
            (set-file-modes (concat bin "secret-tool") #o755)
            (cl-letf (((symbol-function 'drgnx-ai--secret-service-p) (lambda () nil)))
              (should-not (drgnx-secrets-keyring-p)))
            (cl-letf (((symbol-function 'drgnx-ai--secret-service-p) (lambda () t)))
              (should (drgnx-secrets-keyring-p)))))
      (delete-directory bin t))))

;;;; ls and the CLI

(ert-deftest drgnx-secrets/ls-shows-hosts-only ()
  (drgnx-secrets-test--with (bin _log _store calls)
    (let ((k (drgnx-secrets-test--key ?x)))
      (drgnx-secrets-test--write-bundle
       (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key k)
                                   (list :provider 'kimi :host "api.kimi.example" :key (drgnx-secrets-test--key ?z))))
      (should (equal (drgnx-secrets-ls) '("openrouter.ai" "api.kimi.example")))
      (let* ((code nil)
             (out (with-output-to-string (setq code (drgnx-secrets-cli-run '("ls" "--identity" "identity.txt"))))))
        (should (= code 0))
        (should (string-search "openrouter.ai" out))
        (should (string-search "api.kimi.example" out))
        (should-not (string-search "sk-or" out)))
      (should-not calls))))

(ert-deftest drgnx-secrets/cli-refuses-without-a-terminal ()
  (drgnx-secrets-test--with (bin log _store calls)
    (drgnx-secrets-test--write-bundle
     (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (drgnx-secrets-test--key ?x))))
    (let ((process-environment (cons "DRGNX_STDIN_TTY" process-environment)))
      (dolist (args '(("export") ("import") ("ls")))
        (let* ((code nil) (out (with-output-to-string (setq code (drgnx-secrets-cli-run args)))))
          (should (equal (list args code) (list args 3)))
          (should (string-match-p "needs a terminal" out))))
      (should (equal (drgnx-secrets-test--slurp log) ""))
      (should-not calls)
      ;; --identity / --recipient need no terminal
      (should (= 0 (let ((standard-output #'ignore)) (drgnx-secrets-cli-run '("import" "--identity" "identity.txt")))))
      (should (equal calls '(openrouter))))
    ;; a terminal and no identity: the rest runs in bin/drgnx's pipe, where age reaches the terminal (exit 10)
    (should (= 10 (let ((standard-output #'ignore)) (drgnx-secrets-cli-run '("import")))))
    (should (= 2 (let ((standard-output #'ignore)) (drgnx-secrets-cli-run '("frobnicate")))))
    (should (= 2 (let ((standard-output #'ignore)) (drgnx-secrets-cli-run '("export" "--identity" "x")))))))

(ert-deftest drgnx-secrets/the-pipe-halves ()
  ;; bin/drgnx: `drgnx secrets export' with DRGNX_SECRETS_PIPE=bundle | age -e -p …; age -d … | `drgnx secrets
  ;; import' with DRGNX_SECRETS_PIPE=stdin
  (drgnx-secrets-test--with (bin _log store calls)
    (let ((k (drgnx-secrets-test--key ?x)) (bundle nil))
      (puthash "openrouter.ai" k store)
      (let ((process-environment (cons "DRGNX_SECRETS_PIPE=bundle" process-environment)))
        (setq bundle (with-output-to-string (should (= 0 (drgnx-secrets-cli-run '("export")))))))
      (should (equal (drgnx-secrets--parse bundle) (list (list :provider 'openrouter :host "openrouter.ai" :key k))))
      (clrhash store)
      (let ((process-environment (cons "DRGNX_SECRETS_PIPE=stdin" process-environment)) (out nil))
        (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (copy-sequence bundle))))
          (setq out (with-output-to-string (should (= 0 (drgnx-secrets-cli-run '("import")))))))
        (should (string-match-p "^stored +openrouter\\.ai$" out))
        (should-not (string-search k out))
        ;; age gave nothing (a wrong passphrase): nothing stored, exit 1
        (setq calls nil)
        (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (signal 'end-of-file '("Error reading from stdin")))))
          (should (= 1 (let ((standard-output #'ignore)) (drgnx-secrets-cli-run '("import"))))))
        (should-not calls))
      (should (equal (gethash "openrouter.ai" store) k))
      ;; the halves are bin/drgnx's own: only on a terminal, never with --recipient/--identity, never another value
      (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (copy-sequence bundle))))
        (dolist (case '(("bundle" t ("export" "--recipient" "age1x"))
                        ("bundle" nil ("export" "--recipient" "age1x"))
                        ("bundle" nil ("export"))
                        ("stdin" nil ("import" "--identity" "identity.txt"))
                        ("stdin" t ("ls" "--identity" "identity.txt"))
                        ("stdin" nil ("import"))
                        ("bundle" t ("import"))
                        ("other" t ("export"))))
          (pcase-let ((`(,pipe ,tty ,args) case))
            (let* ((process-environment (append (list (concat "DRGNX_SECRETS_PIPE=" pipe)
                                                      (if tty "DRGNX_STDIN_TTY=1" "DRGNX_STDIN_TTY"))
                                                process-environment))
                   (code nil)
                   (out (with-output-to-string (setq code (drgnx-secrets-cli-run args)))))
              (should (equal (list case code) (list case 2)))
              (should-not (string-search k out))
              (should-not (string-search k (with-current-buffer (messages-buffer) (buffer-string))))))))
      (should (equal (gethash "openrouter.ai" store) k)))))

(ert-deftest drgnx-secrets/an-existing-file-needs-a-terminal-to-be-replaced ()
  (drgnx-secrets-test--with (bin log store _calls)
    (puthash "openrouter.ai" (drgnx-secrets-test--key ?x) store)
    (drgnx-secrets-test--write-bundle "old")
    (let ((process-environment (cons "DRGNX_STDIN_TTY" process-environment)))
      (let* ((code nil) (out (with-output-to-string (setq code (drgnx-secrets-cli-run '("export" "--recipient" "age1x"))))))
        (should (= code 1))
        (should (string-match-p "secrets\\.age exists: run on a terminal to replace it" out))))
    (should (equal (drgnx-secrets-test--slurp log) ""))
    (should (equal (drgnx-secrets-test--slurp (drgnx-secrets-file)) "byq"))))

(ert-deftest drgnx-secrets/an-identity-others-can-read-is-named ()
  (drgnx-secrets-test--with (bin _log _store _calls)
    (drgnx-secrets-test--write-bundle
     (drgnx-secrets-test--bundle (list :provider 'openrouter :host "openrouter.ai" :key (drgnx-secrets-test--key ?x))))
    (let ((id (expand-file-name "identity.txt" bin)))
      (with-temp-file id (insert "test identity\n"))
      (set-file-modes id #o644)
      (let ((out (with-output-to-string (drgnx-secrets-cli-run (list "ls" "--identity" id)))))
        (should (string-match-p "identity\\.txt can be read by other users: chmod 600" out)))
      (set-file-modes id #o600)
      (let ((out (with-output-to-string (drgnx-secrets-cli-run (list "ls" "--identity" id)))))
        (should-not (string-match-p "read by other users" out))))))

(ert-deftest drgnx-secrets/an-empty-config-dir-variable-counts-as-unset ()
  (let ((process-environment (cons "DRGNX_CONFIG_DIR=" process-environment)))
    (should (equal (drgnx-user-dir) (file-name-as-directory (expand-file-name "~/.config/drgnx"))))
    (should (equal (drgnx-secrets-file) (expand-file-name "~/.config/drgnx/secrets.age")))))

(ert-deftest drgnx-secrets/the-chezmoi-installer-comes-over-https ()
  (require 'drgnx-onboard)
  (let ((line (cdr (assoc "apt-get" (plist-get (plist-get (alist-get 'chezmoi drgnx-onboard-install-recipes) :linux) :by-program)))))
    (should (string-search "curl -fsLS https://get.chezmoi.io" line))
    (should-not (string-search "sudo" line)))
  ;; the line shown for it does not say it asks for a password; a sudo line does
  (let ((bin (file-name-as-directory (make-temp-file "drgnx-secrets-apt" t))) (said nil))
    (unwind-protect
        (progn
          (with-temp-file (concat bin "apt-get") (insert "#!/bin/sh\n"))
          (set-file-modes (concat bin "apt-get") #o755)
          (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
                    ((symbol-function 'drgnx-onboard--say) (lambda (s) (push s said)))
                    ((symbol-function 'kill-new) #'ignore))
            (let ((exec-path (list bin)) (drgnx-onboard-app-wait 0))
              (drgnx-onboard--install 'chezmoi '(:interactive t))
              (should (string-search "get.chezmoi.io" (car said)))
              (should-not (string-search "password" (car said)))
              (drgnx-onboard--install 'age '(:interactive t))
              (should (string-search "sudo apt-get install -y age" (car said)))
              (should (string-search "password (sudo)" (car said))))))
      (delete-directory bin t))))

(ert-deftest drgnx-secrets/the-terminal-forgets-the-typed-keys ()
  ;; the passphrase is typed into the terminal buffer, so Emacs's recent keys (C-h l) hold it until cleared
  (let ((cleared 0) (buf nil))
    (cl-letf (((symbol-function 'clear-this-command-keys) (lambda (&rest _) (cl-incf cleared)))
              ((symbol-function 'drgnx-terminal-eat-usable-p) (lambda (_) t))
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'drgnx-terminal-eat-start)
               (lambda (_dir &optional _command)
                 (setq buf (generate-new-buffer "*drgnx-secrets-test-eat*"))
                 (make-process :name "drgnx-secrets-test" :buffer buf :command '("sh" "-c" "sleep 0.2")
                               :noquery t :sentinel #'ignore)
                 buf)))
      (unwind-protect
          (progn
            (drgnx-secrets-import-keys)
            (should (= cleared 0))
            (let ((deadline (+ (float-time) 5)))
              (while (and (process-live-p (get-buffer-process buf)) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (accept-process-output nil 0.1)
            (should (= cleared 1)))
        (when (buffer-live-p buf) (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))

(ert-deftest drgnx-secrets/age-missing-names-the-install-line ()
  (let* ((bin (file-name-as-directory (make-temp-file "drgnx-secrets-dnf" t)))
         (log (concat bin "dnf.argv")))
    (unwind-protect
        (progn
          (with-temp-file (concat bin "dnf") (insert "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " log "\n"))
          (set-file-modes (concat bin "dnf") #o755)
          (let ((exec-path (list bin)) (system-type 'gnu/linux)
                (process-environment (append (list (concat "PATH=" bin) "DRGNX_STDIN_TTY=1") process-environment)))
            (dolist (args '(("export") ("import") ("ls --identity identity.txt")))
              (let* ((code nil) (out (with-output-to-string (setq code (drgnx-secrets-cli-run (split-string (car args) " "))))))
                (should (= code 3))
                (should (string-search "sudo dnf install -y age" out)))))
          (should-not (file-exists-p log)))
      (delete-directory bin t))))

(defun drgnx-secrets-test--complete (program &rest args)
  "Run shell PROGRAM with ARGS with a temp HOME; its candidate lines, sorted."
  (let* ((home (make-temp-file "drgnx-secrets-sh" t))
         (process-environment (append (list (concat "HOME=" home) (concat "ZDOTDIR=" home) "HISTFILE=/dev/null" "TERM=dumb")
                                      process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((default-directory (file-name-as-directory home)))
            (should (eql 0 (apply #'call-process program nil '(t nil) nil args))))
          (sort (split-string (buffer-string) "\n" t) #'string<))
      (delete-directory home t))))

(ert-deftest drgnx-secrets/the-shells-complete-secrets ()
  (let ((bash-file (expand-file-name "etc/shell/drgnx.bash" drgnx-dir)))
    (pcase-dolist (`(,words ,want) '(("drgnx secrets ''" ("export" "import" "ls"))
                                     ("drgnx secrets export --r" ("--recipient"))
                                     ("drgnx secrets import --" ("--identity" "--replace"))
                                     ("drgnx secrets ls --i" ("--identity"))))
      (should (equal (list words (drgnx-secrets-test--complete
                                  "bash" "--norc" "--noprofile" "-c"
                                  (format "source %s; COMP_WORDS=(%s); COMP_CWORD=%d; _drgnx; printf '%%s\\n' \"${COMPREPLY[@]}\""
                                          (shell-quote-argument bash-file) words (1- (length (split-string words " "))))))
                     (list words want)))))
  (when (and (executable-find "zsh")
             (eql 0 (call-process "zsh" nil nil nil "-f" "-c" "zmodload zsh/zpty")))
    (should (equal (drgnx-secrets-test--complete "zsh" "-f" (expand-file-name "test/fixtures/zsh-complete.zsh" drgnx-dir)
                                                 (expand-file-name "etc/shell/drgnx.zsh" drgnx-dir) "drgnx secrets ")
                   '("export" "import" "ls")))))

;;;; The commands

(ert-deftest drgnx-secrets/the-commands-open-a-terminal ()
  (let ((started nil) (termed nil) (bin (expand-file-name "bin/drgnx" drgnx-dir)) (bufs nil))
    (cl-letf (((symbol-function 'drgnx-secrets-export) (lambda (&rest _) (error "The daemon ran an export")))
              ((symbol-function 'drgnx-secrets-import) (lambda (&rest _) (error "The daemon ran an import")))
              ((symbol-function 'drgnx-secrets-decrypt) (lambda (&rest _) (error "The daemon ran age")))
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'term-char-mode) #'ignore)
              ((symbol-function 'make-term)
               (lambda (name program &optional _start &rest switches)
                 (push (cons name (cons program switches)) termed)
                 (car (push (generate-new-buffer "*drgnx-secrets-test-term*") bufs))))
              ((symbol-function 'drgnx-terminal-eat-start)
               (lambda (_dir &optional command)
                 (push command started)
                 (car (push (generate-new-buffer "*drgnx-secrets-test-eat*") bufs)))))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'drgnx-terminal-eat-usable-p) (lambda (_) t)))
              (let ((b (drgnx-secrets-export-keys)))
                (should (equal started (list (list bin "secrets" "export"))))
                (should (string-match-p "passphrase" (format "%s" (buffer-local-value 'header-line-format b)))))
              (drgnx-secrets-import-keys)
              (should (equal (car started) (list bin "secrets" "import"))))
            (cl-letf (((symbol-function 'drgnx-terminal-eat-usable-p) (lambda (_) nil)))
              (let ((b (drgnx-secrets-import-keys)))
                (should (equal (cdar termed) (list bin "secrets" "import")))
                (should (string-match-p "passphrase" (format "%s" (buffer-local-value 'header-line-format b))))))
            (should (= (length started) 2))
            (should (= (length termed) 1)))
        (mapc #'kill-buffer bufs)))))

(ert-deftest drgnx-secrets/the-commands-are-registered ()
  (require 'drgnx)
  (drgnx--core-commands)
  (dolist (id '(portability-export-keys portability-import-keys))
    (should (commandp (drgnx-cmd-command (drgnx-commands-get id)))))
  (should (equal (drgnx-commands-label (drgnx-commands-get 'portability-export-keys)) "Portability: Export Keys"))
  (should (equal (drgnx-commands-label (drgnx-commands-get 'portability-import-keys)) "Portability: Import Keys")))

(provide 'secrets-test)
;;; secrets-test.el ends here
