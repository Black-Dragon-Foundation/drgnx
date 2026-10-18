;;; shell-completion-test.el --- batch tests: `drgnx <TAB>' in zsh, bash and fish -*- lexical-binding: t -*-
;; The completion files are static lists.  This test reads bin/drgnx (never runs it) so they cannot fall out of
;; date: every dispatch arm and every --flag of `usage' must appear in each file.  Real shells run with a temp HOME
;; and their rc files off; fish is not on every machine (the container tier has it): its parts skip.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-onboard)
(require 'drgnx-bootstrap)
(require 'seq)
(require 'subr-x)

(defconst drgnx-shell-completion-test--shell-dir (file-name-as-directory (expand-file-name "etc/shell" drgnx-dir))
  "The directory of the shell files.")

(defconst drgnx-shell-completion-test--files
  '((zsh . "_drgnx") (bash . "drgnx.bash") (fish . "drgnx.fish"))
  "Per shell, the file that holds its completion.")

(defun drgnx-shell-completion-test--read (file)
  "The text of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-shell-completion-test--bin-section (start-re end-re)
  "The text of bin/drgnx from the line matching START-RE up to the next line matching END-RE."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir))
    (goto-char (point-min))
    (re-search-forward start-re)
    (let ((start (match-end 0)))
      (re-search-forward end-re)
      (buffer-substring start (match-beginning 0)))))

(defun drgnx-shell-completion-test--arms ()
  "The words of the top-level dispatch arms of bin/drgnx's `case \"${1:-help}\"'."
  (let (words)
    (dolist (line (split-string (drgnx-shell-completion-test--bin-section "^case \"\\${1:-help}\" in$" "^esac$") "\n"))
      (when (string-match "\\`  \\([a-z][-a-z|]*\\))" line)
        (dolist (w (split-string (match-string 1 line) "|" t))
          (cl-pushnew w words :test #'equal))))
    (nreverse words)))

(defun drgnx-shell-completion-test--usage-flags ()
  "The --flag words of bin/drgnx's `usage'."
  (let (words)
    (dolist (w (split-string (drgnx-shell-completion-test--bin-section "^usage() {$" "^USAGE$") "[^-a-z]+" t))
      (when (string-match-p "\\`--[a-z][a-z-]*\\'" w) (cl-pushnew w words :test #'equal)))
    (nreverse words)))

(defun drgnx-shell-completion-test--mentions-p (shell text word)
  "Whether the completion TEXT of SHELL names WORD (a command or an option) as a word."
  (let ((case-fold-search nil)
        (q (regexp-quote word)))
    (if (and (eq shell 'fish) (string-prefix-p "-" word))
        ;; fish spells options `-l NAME' / `-s C'
        (string-match-p (if (string-prefix-p "--" word)
                            (format "\\(-l\\|--long-option\\)[ =]+%s\\([^-A-Za-z0-9]\\|$\\)" (regexp-quote (substring word 2)))
                          (format "\\(-s\\|--short-option\\)[ =]+%s\\([^-A-Za-z0-9]\\|$\\)" (regexp-quote (substring word 1))))
                        text)
      (string-match-p (format "\\(^\\|[^-A-Za-z0-9]\\)%s\\([^-A-Za-z0-9]\\|$\\)" q) text))))

(ert-deftest drgnx-shell-completion/no-subcommand-or-flag-without-completion ()
  (let ((arms (drgnx-shell-completion-test--arms))
        (flags (drgnx-shell-completion-test--usage-flags)))
    ;; the parse itself must have found the CLI (a changed layout must not turn this into a vacuous pass)
    (dolist (w '("onboard" "open" "doctor" "test" "help")) (should (member w arms)))
    (dolist (w '("--step" "--preset" "--keys" "--json")) (should (member w flags)))
    (pcase-dolist (`(,shell . ,name) drgnx-shell-completion-test--files)
      (let ((text (drgnx-shell-completion-test--read (expand-file-name name drgnx-shell-completion-test--shell-dir)))
            missing)
        (dolist (w (append arms flags))
          (unless (drgnx-shell-completion-test--mentions-p shell text w) (push w missing)))
        (should (equal (list name (nreverse missing)) (list name nil)))))))

;;;; Running the shells

(defun drgnx-shell-completion-test--exe (shell)
  "SHELL's program, or nil."
  (executable-find (symbol-name shell)))

(defun drgnx-shell-completion-test--run (program args &optional dir)
  "Run PROGRAM with ARGS in DIR (default a temp directory) with a temp HOME; returns (EXIT STDOUT STDERR).
The process is waited for before the temp directories go."
  (let* ((home (make-temp-file "drgnx-comp" t))
         (default-directory (file-name-as-directory (or dir home)))
         (err (expand-file-name "stderr" home))
         (process-environment
          (append (list (concat "HOME=" home) (concat "ZDOTDIR=" home) (concat "XDG_CONFIG_HOME=" home "/.config")
                        "HISTFILE=/dev/null" "TERM=dumb")
                  (seq-remove (lambda (e) (string-match-p "\\`\\(HOME\\|ZDOTDIR\\|XDG_CONFIG_HOME\\|HISTFILE\\|TERM\\|INSIDE_EMACS\\|EAT_SHELL_INTEGRATION_DIR\\)=" e))
                              process-environment))))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process program nil (list (current-buffer) err) nil args)))
            (list exit (buffer-string) (with-temp-buffer (insert-file-contents err) (buffer-string)))))
      (delete-directory home t))))

(defun drgnx-shell-completion-test--lines (text)
  "The non-empty lines of TEXT."
  (split-string text "\n" t))

(defun drgnx-shell-completion-test--bash (line &optional dir pre)
  "Bash's candidates for the command LINE (a list of words; the last is being completed), run in DIR.
PRE is run before the completion file is sourced (set -u, ...)."
  (let* ((words (mapconcat #'shell-quote-argument line " "))
         (script (format "%s source %s; COMP_WORDS=(%s); COMP_CWORD=%d; _drgnx; printf '%%s\\n' \"${COMPREPLY[@]}\""
                         (if pre (concat pre ";") "")
                         (shell-quote-argument (expand-file-name "drgnx.bash" (or dir drgnx-shell-completion-test--shell-dir)))
                         words (1- (length line))))
         (r (drgnx-shell-completion-test--run (drgnx-shell-completion-test--exe 'bash) (list "--norc" "--noprofile" "-c" script))))
    (should (equal (list (nth 0 r) (nth 2 r)) (list 0 "")))
    (drgnx-shell-completion-test--lines (nth 1 r))))

(defun drgnx-shell-completion-test--zsh (line &optional dir pre)
  "Zsh's candidates for the command string LINE, through the zpty fixture; sorted."
  (let* ((process-environment (append (and pre (list (concat "DRGNX_COMPLETE_PRE=" pre))) process-environment))
         (r (drgnx-shell-completion-test--run
             (drgnx-shell-completion-test--exe 'zsh)
             (list "-f" (expand-file-name "test/fixtures/zsh-complete.zsh" drgnx-dir)
                   (expand-file-name "drgnx.zsh" (or dir drgnx-shell-completion-test--shell-dir)) line))))
    (should (equal (list (nth 0 r) (nth 2 r)) (list 0 "")))
    (drgnx-shell-completion-test--lines (nth 1 r))))

(defun drgnx-shell-completion-test--fish (line &optional dir)
  "Fish's candidates (first column) for the command string LINE."
  (let ((r (drgnx-shell-completion-test--run
            (drgnx-shell-completion-test--exe 'fish)
            (list "-N" "-c" (format "source %s; complete -C %s"
                                    (shell-quote-argument (expand-file-name "drgnx.fish" (or dir drgnx-shell-completion-test--shell-dir)))
                                    (shell-quote-argument line))))))
    (should (equal (list (nth 0 r) (nth 2 r)) (list 0 "")))
    (mapcar (lambda (l) (car (split-string l "\t"))) (drgnx-shell-completion-test--lines (nth 1 r)))))

(defun drgnx-shell-completion-test--sorted (xs)
  "XS sorted, without duplicates."
  (sort (delete-dups (copy-sequence xs)) #'string<))

;;;; Static lists against the Lisp they mirror

(defun drgnx-shell-completion-test--candidates (shell line)
  "Candidates of SHELL for LINE (a string; bash gets its words), or nil when SHELL is not installed."
  (when (drgnx-shell-completion-test--exe shell)
    (drgnx-shell-completion-test--sorted
     (pcase shell
       ('bash (drgnx-shell-completion-test--bash (split-string line " ")))
       ('zsh (drgnx-shell-completion-test--zsh line))
       ('fish (drgnx-shell-completion-test--fish line))))))

(ert-deftest drgnx-shell-completion/steps-and-presets-match ()
  (let ((steps (drgnx-shell-completion-test--sorted (mapcar #'symbol-name (drgnx-onboard-steps))))
        (presets (drgnx-shell-completion-test--sorted (mapcar (lambda (p) (symbol-name (car p))) drgnx-onboard-presets)))
        (keys (drgnx-shell-completion-test--sorted
               (mapcar #'file-name-base (directory-files (expand-file-name "keys" drgnx-dir) nil "\\.eld\\'"))))
        (shells 0))
    (should (> (length steps) 3))
    (dolist (shell '(bash zsh fish))
      (when (drgnx-shell-completion-test--exe shell)
        (cl-incf shells)
        ;; "drgnx onboard --step " ends in a blank: bash gets an empty last word
        (should (equal (list shell (drgnx-shell-completion-test--candidates shell "drgnx onboard --step "))
                       (list shell steps)))
        (should (equal (list shell (drgnx-shell-completion-test--candidates shell "drgnx onboard --preset "))
                       (list shell presets)))
        (should (equal (list shell (drgnx-shell-completion-test--candidates shell "drgnx onboard --keys "))
                       (list shell keys)))))
    (should (>= shells 2))
    ;; drift in the text of every file, shells or no shells
    (pcase-dolist (`(,shell . ,name) drgnx-shell-completion-test--files)
      (let ((text (drgnx-shell-completion-test--read (expand-file-name name drgnx-shell-completion-test--shell-dir))))
        (dolist (w (append steps presets))
          (should (drgnx-shell-completion-test--mentions-p shell text w)))))
    ;; the bootstrap steps
    (pcase-dolist (`(,shell . ,name) drgnx-shell-completion-test--files)
      (let ((text (drgnx-shell-completion-test--read (expand-file-name name drgnx-shell-completion-test--shell-dir))))
        (dolist (w drgnx-bootstrap-steps)
          (should (drgnx-shell-completion-test--mentions-p shell text (symbol-name w))))))
    (dolist (shell '(bash zsh fish))
      (when (drgnx-shell-completion-test--exe shell)
        (should (equal (list shell (drgnx-shell-completion-test--candidates shell "drgnx bootstrap --step "))
                       (list shell (drgnx-shell-completion-test--sorted (mapcar #'symbol-name drgnx-bootstrap-steps)))))))))

;;;; Each shell completes

(defun drgnx-shell-completion-test--arm-words ()
  "The command words of bin/drgnx other than the dashed ones."
  (seq-remove (lambda (w) (string-prefix-p "-" w)) (drgnx-shell-completion-test--arms)))

(ert-deftest drgnx-shell-completion/bash-completes ()
  (should (drgnx-shell-completion-test--exe 'bash))
  (let ((dir (make-temp-file "drgnx comp" t)))
    (unwind-protect
        (progn
          ;; "o" is a prefix of both onboard and open
          (let ((r (drgnx-shell-completion-test--bash '("drgnx" "o") nil)))
            (should (equal (drgnx-shell-completion-test--sorted r) '("onboard" "open"))))
          ;; every command of bin/drgnx, and a file of the current folder, at the first word
          (let ((default-directory (file-name-as-directory dir)))
            (make-directory (expand-file-name "notes" dir))
            (let ((r (drgnx-shell-completion-test--run
                      (drgnx-shell-completion-test--exe 'bash)
                      (list "--norc" "--noprofile" "-c"
                            (format "source %s; COMP_WORDS=(drgnx ''); COMP_CWORD=1; _drgnx; printf '%%s\\n' \"${COMPREPLY[@]}\""
                                    (shell-quote-argument (expand-file-name "drgnx.bash" drgnx-shell-completion-test--shell-dir))))
                      dir)))
              (should (equal (nth 2 r) ""))
              (let ((got (drgnx-shell-completion-test--lines (nth 1 r))))
                (dolist (w (drgnx-shell-completion-test--arm-words)) (should (member w got)))
                (should (member "notes/" got)))))
          (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--bash '("drgnx" "onboard" "--step" "")))
                         (drgnx-shell-completion-test--sorted (mapcar #'symbol-name (drgnx-onboard-steps)))))
          (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--bash '("drgnx" "onboard" "--keys" "")))
                         '("emacs" "vim" "vscode")))
          (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--bash '("drgnx" "onboard" "--pre")))
                         '("--preset")))
          (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--bash '("drgnx" "work" "")))
                         '("record" "scan" "status")))
          ;; a path is the shell's own: nothing of ours
          (should (null (drgnx-shell-completion-test--bash '("drgnx" "/nonexistent-dir/x")))))
      (delete-directory dir t))))

(ert-deftest drgnx-shell-completion/zsh-completes ()
  (unless (drgnx-shell-completion-test--exe 'zsh) (ert-skip "zsh is not installed here"))
  (unless (zerop (car (drgnx-shell-completion-test--run (drgnx-shell-completion-test--exe 'zsh) '("-f" "-c" "zmodload zsh/zpty"))))
    (ert-skip "this zsh has no zsh/zpty"))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--zsh "drgnx o")) '("onboard" "open")))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--zsh "drgnx onboard --step "))
                 (drgnx-shell-completion-test--sorted (mapcar #'symbol-name (drgnx-onboard-steps)))))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--zsh "drgnx onboard --keys "))
                 '("emacs" "vim" "vscode")))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--zsh "drgnx work")) '("work")))
  (let ((got (drgnx-shell-completion-test--zsh "drgnx ")))
    (dolist (w (drgnx-shell-completion-test--arm-words)) (should (member w got))))
  ;; a path completes to files and folders (the shell runs in a temp folder: absolute paths)
  (should (member "shell" (drgnx-shell-completion-test--zsh (format "drgnx %setc/she" drgnx-dir))))
  (should (member "_drgnx" (drgnx-shell-completion-test--zsh (format "drgnx %setc/shell/_dr" drgnx-dir)))))

(ert-deftest drgnx-shell-completion/fish-completes ()
  (unless (drgnx-shell-completion-test--exe 'fish) (ert-skip "fish is not installed here (the container tier runs this)"))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--fish "drgnx o")) '("onboard" "open")))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--fish "drgnx onboard --step "))
                 (drgnx-shell-completion-test--sorted (mapcar #'symbol-name (drgnx-onboard-steps)))))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--fish "drgnx onboard --keys "))
                 '("emacs" "vim" "vscode")))
  (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--fish "drgnx work ")) '("record" "scan" "status")))
  (let ((got (drgnx-shell-completion-test--fish "drgnx ")))
    (dolist (w (drgnx-shell-completion-test--arm-words)) (should (member w got)))))

(ert-deftest drgnx-shell-completion/strict-modes-and-paths-with-spaces ()
  ;; the completion functions, not only loading them, under nounset, errexit and posix mode, from a folder with a space
  (let* ((base (make-temp-file "drgnx comp" t))
         (dir (file-name-as-directory (expand-file-name "my dir/etc/shell" base))))
    (unwind-protect
        (progn
          (make-directory dir t)
          (make-directory (expand-file-name "my dir/keys" base) t)
          (dolist (f (directory-files drgnx-shell-completion-test--shell-dir t "\\`[^.]")) (copy-file f dir))
          (dolist (f '("emacs.eld" "vim.eld")) (with-temp-file (expand-file-name (concat "my dir/keys/" f) base)))
          (dolist (pre '("set -u" "set -eu" "set -euo pipefail"))
            (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--bash '("drgnx" "o") dir pre))
                           '("onboard" "open")))
            (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--bash '("drgnx" "onboard" "--keys" "") dir pre))
                           '("emacs" "vim"))))
          ;; bash --posix: the file is read in POSIX mode
          (let ((r (drgnx-shell-completion-test--run
                    (drgnx-shell-completion-test--exe 'bash)
                    (list "--norc" "--noprofile" "--posix" "-c"
                          (format "source %s; COMP_WORDS=(drgnx onboard --keys ''); COMP_CWORD=3; _drgnx; echo \"${COMPREPLY[*]}\""
                                  (shell-quote-argument (expand-file-name "drgnx.bash" dir)))))))
            (should (equal (list (nth 0 r) (nth 1 r) (nth 2 r)) (list 0 "emacs vim\n" ""))))
          (when (and (drgnx-shell-completion-test--exe 'zsh)
                     (zerop (car (drgnx-shell-completion-test--run (drgnx-shell-completion-test--exe 'zsh) '("-f" "-c" "zmodload zsh/zpty")))))
            (dolist (pre '("setopt nounset" "setopt nounset errexit" "setopt ksh_arrays sh_word_split"))
              (should (equal (list pre (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--zsh "drgnx o" dir pre)))
                             (list pre '("onboard" "open"))))
              (should (equal (list pre (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--zsh "drgnx onboard --keys " dir pre)))
                             (list pre '("emacs" "vim"))))))
          (when (drgnx-shell-completion-test--exe 'fish)
            (should (equal (drgnx-shell-completion-test--sorted (drgnx-shell-completion-test--fish "drgnx onboard --keys " dir))
                           '("emacs" "vim")))))
      (delete-directory base t))))

(provide 'shell-completion-test)
;;; shell-completion-test.el ends here
