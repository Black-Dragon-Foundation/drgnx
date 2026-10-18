;;; shell-files-test.el --- batch tests: etc/shell/drgnx.{zsh,bash,fish} -*- lexical-binding: t -*-
;; Each shell runs with a temp HOME and ZDOTDIR and no rc files of its own (zsh -f, bash --norc --noprofile,
;; fish -N): never the user's rc files, ~/.config or live Emacs.  fish is not on every machine: its parts skip.
(require 'ert)
(require 'drgnx)
(require 'seq)
(require 'subr-x)

(defconst drgnx-shell-files-test--dir (file-name-as-directory (expand-file-name "etc/shell" drgnx-dir))
  "The directory of the shell files.")

(defconst drgnx-shell-files-test--shells
  '((zsh "drgnx.zsh" ("-f" "-i" "-c") "print -r -- OK")
    (bash "drgnx.bash" ("--norc" "--noprofile" "-i" "-c") "echo OK")
    (fish "drgnx.fish" ("-N" "-c") "echo OK"))
  "Per shell: name, its file, the arguments before the script, and the script that prints OK.")

(defun drgnx-shell-files-test--exe (shell)
  "The absolute path of SHELL's program, or nil."
  (executable-find (symbol-name shell)))

(defun drgnx-shell-files-test--file (shell)
  "SHELL's integration file."
  (expand-file-name (nth 1 (assq shell drgnx-shell-files-test--shells)) drgnx-shell-files-test--dir))

(defun drgnx-shell-files-test--available ()
  "The shells installed here; fails the test unless zsh and bash are among them."
  (let ((have (seq-filter #'drgnx-shell-files-test--exe '(zsh bash fish))))
    (should (memq 'zsh have))
    (should (memq 'bash have))
    have))

(defun drgnx-shell-files-test--run (shell script &optional env path args)
  "Run SCRIPT in SHELL with its own rc files off and a temp HOME; returns (EXIT STDOUT STDERR).
ENV is a list of VAR=VALUE entries added to a clean environment (no INSIDE_EMACS); PATH replaces PATH;
ARGS replace the shell's usual arguments before the script."
  (let* ((home (make-temp-file "drgnx-shell" t))
         (err (expand-file-name "stderr" home))
         (process-environment
          (append env (list (concat "HOME=" home) (concat "ZDOTDIR=" home) (concat "XDG_CONFIG_HOME=" home "/.config")
                            "TERM=dumb")
                  (when path (list (concat "PATH=" path)))
                  (seq-remove (lambda (e) (string-match-p "\\`\\(HOME\\|ZDOTDIR\\|XDG_CONFIG_HOME\\|TERM\\|INSIDE_EMACS\\|EAT_SHELL_INTEGRATION_DIR\\|PATH\\)=" e))
                              process-environment)
                  (unless path (list (concat "PATH=" (getenv "PATH")))))))
    (unwind-protect
        (with-temp-buffer
          (let* ((exit (apply #'call-process (drgnx-shell-files-test--exe shell) nil (list (current-buffer) err) nil
                              (append (or args (nth 2 (assq shell drgnx-shell-files-test--shells))) (list script))))
                 (stderr (with-temp-buffer (insert-file-contents err) (buffer-string))))
            ;; bash -i without a terminal grumbles about job control: not the file's doing
            (setq stderr (string-join (seq-remove (lambda (l) (string-match-p "\\`bash: \\(cannot set terminal process group\\|no job control\\)" l))
                                                  (split-string stderr "\n" t))
                                      "\n"))
            (list exit (buffer-string) stderr)))
      (delete-directory home t))))

(defun drgnx-shell-files-test--source (shell &optional times)
  "The script that sources SHELL's file TIMES times (default 1)."
  (string-join (make-list (or times 1) (format "source '%s'" (drgnx-shell-files-test--file shell))) "; "))

(ert-deftest drgnx-shell-files/silent-outside-eat ()
  (dolist (shell (drgnx-shell-files-test--available))
    (let ((r (drgnx-shell-files-test--run shell (format "%s; %s" (drgnx-shell-files-test--source shell)
                                                        (nth 3 (assq shell drgnx-shell-files-test--shells))))))
      (should (equal (list shell (nth 0 r) (nth 1 r) (nth 2 r)) (list shell 0 "OK\n" ""))))))

(ert-deftest drgnx-shell-files/runs-no-program ()
  (dolist (shell (drgnx-shell-files-test--available))
    ;; builtins only: an external command would fail with "command not found"
    (let* ((show (pcase shell
                   ('zsh "print -r -- \"fpath1=$fpath[1]\"")
                   ('bash "complete -p drgnx")
                   ('fish "complete -c drgnx")))
           (r (drgnx-shell-files-test--run shell (format "%s; %s" (drgnx-shell-files-test--source shell) show)
                                           nil "/nonexistent")))
      (should (equal (list shell (nth 0 r) (nth 2 r)) (list shell 0 "")))
      (pcase shell
        ('zsh (should (string-search (concat "fpath1=" (directory-file-name drgnx-shell-files-test--dir)) (nth 1 r))))
        ('bash (should (string-search "_drgnx" (nth 1 r))))
        ('fish (should (string-search "drgnx" (nth 1 r))))))
    ;; and the text: no command substitution (in fish, no unquoted parentheses before the eat-only functions)
    (let ((text (with-temp-buffer (insert-file-contents (drgnx-shell-files-test--file shell)) (buffer-string))))
      (should-not (string-search "$(" text))
      (should-not (string-search "`" text))
      (when (eq shell 'fish)
        (let ((before (car (split-string text "^function __drgnx_eat" t))))
          (dolist (line (split-string before "\n"))
            (should-not (string-match-p "\\`[^#']*(" line))))))))

(ert-deftest drgnx-shell-files/sourcing-twice-is-harmless ()
  (dolist (shell (drgnx-shell-files-test--available))
    ;; shadow the registering command with a function that counts, then source twice
    (let* ((count (pcase shell
                    ('zsh "compdef() { print -r -- \"compdef $*\" }")
                    ('bash "complete() { echo \"complete $*\"; builtin complete \"$@\"; }")
                    ('fish "function complete; echo \"complete $argv\"; builtin complete $argv; end")))
           (r (drgnx-shell-files-test--run shell (format "%s; %s" count (drgnx-shell-files-test--source shell 2)))))
      (should (equal (list shell (nth 0 r) (nth 2 r)) (list shell 0 "")))
      (should (= 1 (seq-count (lambda (l) (string-match-p "\\`\\(compdef _drgnx drgnx\\|complete .*drgnx\\)" l))
                              (split-string (nth 1 r) "\n" t)))))
    (when (eq shell 'zsh)
      (let ((r (drgnx-shell-files-test--run shell (format "%s; print -r -- ${(j: :)fpath}" (drgnx-shell-files-test--source shell 2)))))
        ;; the directory is in fpath once: two pieces around it
        (should (= 2 (length (split-string (nth 1 r) (regexp-quote (directory-file-name drgnx-shell-files-test--dir))))))))))

(ert-deftest drgnx-shell-files/completion-registered ()
  (let ((have (drgnx-shell-files-test--available)))
    ;; zsh: compinit ran before the file -> compdef; compinit runs after -> found through fpath
    (let ((before (drgnx-shell-files-test--run 'zsh (format "autoload -Uz compinit; compinit -D -u; %s; print -r -- \"comp=$_comps[drgnx]\""
                                                            (drgnx-shell-files-test--source 'zsh))))
          (after (drgnx-shell-files-test--run 'zsh (format "%s; autoload -Uz compinit; compinit -D -u; print -r -- \"comp=$_comps[drgnx]\""
                                                           (drgnx-shell-files-test--source 'zsh))))
          (plain (drgnx-shell-files-test--run 'zsh (format "%s; print -r -- \"first=$fpath[1]\"" (drgnx-shell-files-test--source 'zsh)))))
      (should (equal (nth 1 before) "comp=_drgnx\n"))
      (should (equal (nth 1 after) "comp=_drgnx\n"))
      (should (equal (nth 1 plain) (concat "first=" (directory-file-name drgnx-shell-files-test--dir) "\n"))))
    (let ((r (drgnx-shell-files-test--run 'bash (format "%s; complete -p drgnx" (drgnx-shell-files-test--source 'bash)))))
      (should (string-match-p "-F _drgnx drgnx" (nth 1 r))))
    (when (memq 'fish have)
      (let ((r (drgnx-shell-files-test--run 'fish (format "%s; complete -c drgnx" (drgnx-shell-files-test--source 'fish)))))
        (should (string-match-p "\\`complete drgnx" (nth 1 r)))))))

(ert-deftest drgnx-shell-files/eat-integration-only-inside-eat ()
  (let ((integ (make-temp-file "drgnx-eat" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "zsh" integ) (insert "__drgnx_marker=hit\n"))
          (with-temp-file (expand-file-name "bash" integ) (insert "__drgnx_marker=hit\n"))
          (dolist (shell '(zsh bash))
            (let ((show (format "%s; print -r -- \"marker=${__drgnx_marker-unset}\"" (drgnx-shell-files-test--source shell)))
                  (dir (concat "EAT_SHELL_INTEGRATION_DIR=" integ)))
              (when (eq shell 'bash) (setq show (format "%s; echo \"marker=${__drgnx_marker-unset}\"" (drgnx-shell-files-test--source shell))))
              (dolist (case `(("31.1,eat" ,dir "hit")
                              ("31.1,eat" nil "unset")             ; eat's dir missing
                              (nil ,dir "unset")                   ; not in Emacs
                              ("31.1,comint" ,dir "unset")         ; in Emacs, not eat
                              ("31.1,vterm" ,dir "unset")))
                (let ((r (drgnx-shell-files-test--run shell show (delq nil (list (and (car case) (concat "INSIDE_EMACS=" (car case))) (cadr case))))))
                  (should (equal (list shell case (nth 0 r) (nth 1 r) (nth 2 r))
                                 (list shell case 0 (format "marker=%s\n" (nth 2 case)) "")))))))
          (when (drgnx-shell-files-test--exe 'fish)
            (dolist (case `(("31.1,eat" t) (nil nil) ("31.1,comint" nil)))
              (let ((r (drgnx-shell-files-test--run
                        'fish (format "%s; functions -q __drgnx_eat_prompt; and echo defined; or echo none" (drgnx-shell-files-test--source 'fish))
                        (delq nil (list (and (car case) (concat "INSIDE_EMACS=" (car case)))
                                        (concat "EAT_SHELL_INTEGRATION_DIR=" integ))))))
                (should (equal (nth 1 r) (if (cadr case) "defined\n" "none\n")))))))
      (delete-directory integ t))))

(ert-deftest drgnx-shell-files/fish-emits-eats-sequences ()
  (unless (drgnx-shell-files-test--exe 'fish) (ert-skip "fish is not installed here (the container tier runs this)"))
  (let* ((env '("INSIDE_EMACS=31.1,eat" "EAT_SHELL_INTEGRATION_DIR=/nonexistent"))
         (r (drgnx-shell-files-test--run
             'fish (format "%s; cd /tmp; emit fish_preexec 'echo hi'; emit fish_prompt" (drgnx-shell-files-test--source 'fish))
             env nil '("-N" "-i" "-c")))
         (host (base64-encode-string (encode-coding-string (system-name) 'utf-8) t))
         (pwd (base64-encode-string "/tmp" t)))
    (should (equal (nth 2 r) ""))
    (should (string-search (format "\e]51;e;A;%s;%s\e\\" host pwd) (nth 1 r)))
    (should (string-search "\e]51;e;B\e\\" (nth 1 r)))
    (should (string-search (format "\e]51;e;F;%s\e\\" (base64-encode-string "echo hi" t)) (nth 1 r)))
    (should (string-search "\e]51;e;G\e\\" (nth 1 r)))
    (should (string-search "\e]51;e;H;0\e\\\e]51;e;J\e\\\e]51;e;A;" (nth 1 r)))))

(defun drgnx-shell-files-test--run-in-mode (shell pre args dir)
  "Run SHELL with PRE before sourcing its file from DIR, outside eat and inside it.
Returns ((OUT-EXIT OUT STDERR) (IN-EXIT IN STDERR)); inside, a marker file stands for eat's integration."
  (let ((integ (make-temp-file "drgnx-eat" t))
        (file (expand-file-name (nth 1 (assq shell drgnx-shell-files-test--shells)) dir)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name (symbol-name shell) integ) (insert "__drgnx_marker=hit\n"))
          (let* ((show (if (eq shell 'zsh) "print -r --" "echo"))
                 (script (format "%s; source '%s'; %s \"marker=${__drgnx_marker-unset}\"" pre file show)))
            (list (drgnx-shell-files-test--run shell script nil nil args)
                  (drgnx-shell-files-test--run shell script (list "INSIDE_EMACS=31.1,eat" (concat "EAT_SHELL_INTEGRATION_DIR=" integ))
                                               nil args))))
      (delete-directory integ t))))

(ert-deftest drgnx-shell-files/strict-modes-stay-silent-and-correct ()
  ;; unset variables are errors (nounset), POSIX and sh emulation, and a path with a space in it
  (let* ((base (make-temp-file "drgnx shell" t))
         (dir (file-name-as-directory (expand-file-name "my dir/shell" base))))
    (unwind-protect
        (progn
          (make-directory dir t)
          (dolist (f (directory-files drgnx-shell-files-test--dir t "\\`[^.]")) (copy-file f dir))
          (dolist (c '((zsh "setopt nounset" nil) (zsh "setopt nounset errexit" nil) (zsh "emulate sh -c 'true'" nil)
                       (zsh "setopt ksh_arrays sh_word_split" nil) (zsh "true" nil)
                       (bash "set -u" nil) (bash "set -eu" nil) (bash "true" ("--norc" "--noprofile" "--posix" "-i" "-c"))))
            (pcase-let* ((`(,shell ,pre ,args) c)
                         (`(,out ,in) (drgnx-shell-files-test--run-in-mode shell pre args dir)))
              (should (equal (list c (nth 0 out) (nth 1 out) (nth 2 out)) (list c 0 "marker=unset\n" "")))
              (should (equal (list c (nth 0 in) (nth 1 in) (nth 2 in)) (list c 0 "marker=hit\n" "")))))
          ;; zsh under emulate sh: the whole sourcing happens in sh emulation
          (let* ((file (expand-file-name "drgnx.zsh" dir))
                 (r (drgnx-shell-files-test--run 'zsh (format "emulate sh -c \"source '%s'\"; print -r -- \"first=$fpath[1]\"" file))))
            (should (equal (list (nth 0 r) (nth 2 r)) (list 0 "")))
            (should (string-search (concat "first=" (directory-file-name dir)) (nth 1 r)))))
      (delete-directory base t))))

(defun drgnx-shell-files-test--median (xs)
  "The median of the numbers XS."
  (nth (/ (length xs) 2) (sort (copy-sequence xs) #'<)))

(defun drgnx-shell-files-test--startup-cost (shell)
  "Median extra milliseconds that sourcing SHELL's file adds to `SHELL -i -c exit' (20 runs each, interleaved)."
  (let* ((home (make-temp-file "drgnx-shell" t))
         (process-environment (append (list (concat "HOME=" home) (concat "ZDOTDIR=" home) "TERM=dumb")
                                      (seq-remove (lambda (e) (string-match-p "\\`\\(HOME\\|ZDOTDIR\\|TERM\\|INSIDE_EMACS\\)=" e))
                                                  process-environment)))
         (exe (drgnx-shell-files-test--exe shell))
         (rc (expand-file-name (if (eq shell 'zsh) ".zshrc" ".bashrc") home))
         (time (lambda (text)
                 (with-temp-file rc (insert text))
                 (let ((start (float-time)))
                   (if (eq shell 'zsh)
                       (call-process exe nil nil nil "-d" "-i" "-c" "exit")
                     (call-process exe nil nil nil "--noprofile" "--rcfile" rc "-i" "-c" "exit"))
                   (* 1000 (- (float-time) start)))))
         (rc-with (format "source '%s'\n" (drgnx-shell-files-test--file shell))) (rc-without "")
         (a nil) (b nil))
    (should (file-exists-p (drgnx-shell-files-test--file shell)))
    (unwind-protect
        (progn
          (funcall time rc-with) (funcall time rc-without)          ; warm the file cache
          (dotimes (_ 20)
            (push (funcall time rc-with) a)
            (push (funcall time rc-without) b))
          (- (drgnx-shell-files-test--median a) (drgnx-shell-files-test--median b)))
      (delete-directory home t))))

(ert-deftest drgnx-shell-files/startup-cost ()
  :tags '(:timing)                                      ; a quiet machine: bin/drgnx check runs it alone
  (dolist (shell '(zsh bash))
    (should (drgnx-shell-files-test--exe shell))
    (let ((ms (drgnx-shell-files-test--startup-cost shell)))
      (message "drgnx-shell-files/startup-cost %s: %.2f ms" shell ms)
      (should (< ms 5)))))

(provide 'shell-files-test)
;;; shell-files-test.el ends here
