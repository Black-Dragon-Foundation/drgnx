;;; drgnx-terminal-test.el --- live: drgnx's terminal (eat running zsh) in a GUI session (config=drgnx) -*- lexical-binding: t -*-
;; Real keys in a headless session.  The terminal runs zsh with a temp ZDOTDIR whose .zshrc sources etc/shell/drgnx.zsh,
;; the checkout's bin/ first on PATH (never an installed drgnx), and git's identity from the environment; HOME is the
;; runner's temp home.  eat is loaded read-only from the user's packages (DRGNX_USER_ELPA).
(require 'ert)
(require 'seq)
(require 'drgnx-ui)

(defconst drgnx-live-term--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))
  "The user's ELPA, read-only, for eat (the runner passes it as DRGNX_USER_ELPA).")

(defun drgnx-live-term--eat-dir ()
  "eat's package directory in `drgnx-live-term--elpa', or nil."
  (let ((elpa drgnx-live-term--elpa))
    (and (file-directory-p elpa) (car (directory-files elpa t "\\`eat-[0-9]")))))

(defun drgnx-live-term--q (sess form &optional timeout)
  "FORM (a string) evaluated in SESS, its value read back."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form) timeout) :v))))

(defun drgnx-live-term--until (sess form seconds)
  "FORM's value in SESS once it is non-nil, polled for up to SECONDS; nil if it never is."
  (let ((deadline (+ (float-time) seconds)) v)
    (while (and (not (setq v (drgnx-live-term--q sess form))) (< (float-time) deadline))
      (sleep-for 0.1))
    v))

(defun drgnx-live-term--setup-form (zdotdir)
  "The session's setup: eat on `load-path', module tools/terminal-eat run, zsh with ZDOTDIR, the checkout's bin/ first."
  (let ((bin (expand-file-name "bin" drgnx-ui-repo-dir)))
    (prin1-to-string
     `(progn
        (add-to-list 'load-path ,(drgnx-live-term--eat-dir))
        (require 'eat)
        ;; the session has no packages of its own, so the module was skipped (missing-packages): run it as it runs for a
        ;; user who has eat
        (unless (drgnx-modules--ok-p 'tools/terminal-eat)
          (drgnx-modules--run-one 'tools/terminal-eat (cdr (assq 'tools/terminal-eat drgnx-modules--table)) 'startup))
        (setenv "SHELL" ,(executable-find "zsh"))
        (setenv "ZDOTDIR" ,zdotdir)
        (setenv "PATH" (concat ,bin path-separator (getenv "PATH")))
        (setq exec-path (cons ,bin exec-path))
        (setenv "GIT_AUTHOR_NAME" "drgnx test")
        (setenv "GIT_AUTHOR_EMAIL" "test@drgnx.invalid")
        (setenv "GIT_COMMITTER_NAME" "drgnx test")
        (setenv "GIT_COMMITTER_EMAIL" "test@drgnx.invalid")
        (and (drgnx-modules--ok-p 'tools/terminal-eat) t)))))

(defun drgnx-live-term--start (root)
  "Start a session for the terminal tests, its state and zsh's ZDOTDIR under ROOT; return (START-PLIST . SESSION)."
  (let* ((zdotdir (expand-file-name "zdotdir" root))
         (s (progn (make-directory zdotdir)
                   (write-region (format "source %s\n" (shell-quote-argument
                                                        (expand-file-name "etc/shell/drgnx.zsh" drgnx-ui-repo-dir)))
                                 nil (expand-file-name ".zshrc" zdotdir) nil 'silent)
                   (drgnx-ui-start "drgnx" "1400x800" 30)))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (cons s sess)))

(defmacro drgnx-live-term--with (sess root &rest body)
  "BODY with SESS a terminal-ready session and ROOT a temp directory (both gone afterwards); skipped without zsh or eat."
  (declare (indent 2))
  `(progn
     (skip-unless (executable-find "zsh"))
     (skip-unless (drgnx-live-term--eat-dir))
     (let* ((,root (make-temp-file "drgnx-term" t))
            (process-environment (cons (concat "DRGNX_UI_STATE=" ,root) process-environment))
            (started (drgnx-live-term--start ,root))
            (,sess (cdr started)))
       (unwind-protect
           (progn
             (should (eq t (drgnx-live-term--q ,sess (drgnx-live-term--setup-form (expand-file-name "zdotdir" ,root)))))
             ,@body)
         (drgnx-ui-stop (plist-get (car started) :name))
         (delete-directory ,root t)))))

(defun drgnx-live-term--open (sess dir)
  "A new terminal in DIR (New Terminal's function), its shell's integration reporting; its buffer name."
  (let ((name (drgnx-live-term--q sess (format "(buffer-name (drgnx-terminal-new %S))" dir))))
    (should (stringp name))
    (should (drgnx-live-term--until sess (format "(buffer-local-value 'drgnx-terminal-eat--integrated (get-buffer %S))" name) 15))
    name))

(defun drgnx-live-term--run (sess line)
  "Type LINE and Return in the selected window."
  (drgnx-ui-measure sess (list (list :type line) (list :keys "RET"))))

(defun drgnx-live-term--select (sess name)
  "Select the window that shows buffer NAME."
  (should (drgnx-live-term--q sess (format "(when-let* ((w (get-buffer-window %S))) (select-window w) t)" name))))

(ert-deftest drgnx-live/terminal-runs-zsh-and-follows-cd ()
  (drgnx-live-term--with sess root
    ;; New Terminal by its key (VS Code profile): eat in the panel, selected, running zsh
    (drgnx-ui-measure sess (list (list :keys "C-S-`")))
    (let ((name (drgnx-live-term--until sess "(with-current-buffer (window-buffer (selected-window)) (and (derived-mode-p 'eat-mode) (buffer-name)))" 10)))
      (should (stringp name))
      (should (eq 'panel (drgnx-live-term--q sess (format "(window-parameter (get-buffer-window %S) 'drgnx-role)" name))))
      (should (equal "zsh" (drgnx-live-term--q sess (format "(file-name-nondirectory (car (last (process-command (get-buffer-process %S)))))" name))))
      (should (drgnx-live-term--until sess (format "(buffer-local-value 'drgnx-terminal-eat--integrated (get-buffer %S))" name) 15))
      ;; the shell starts silently: its first line is the prompt (zsh's ends with %)
      (should (string-suffix-p "%" (car (split-string (drgnx-live-term--q sess (format "(with-current-buffer %S (buffer-substring-no-properties (point-min) (point-max)))" name))
                                                      "\n" t "[[:space:]]+"))))
      (drgnx-live-term--run sess "cd /tmp")
      (should (equal "/tmp/" (drgnx-live-term--until
                              sess (format "(let ((d (buffer-local-value 'default-directory (get-buffer %S)))) (and (equal d \"/tmp/\") d))" name)
                              5)))
      ;; find-file from the terminal starts there (eat leaves C-x to Emacs)
      (drgnx-ui-measure sess (list (list :keys "C-x C-f")))
      (should (equal "/tmp/" (drgnx-live-term--until
                              sess "(when-let* ((w (active-minibuffer-window))) (with-current-buffer (window-buffer w) (minibuffer-contents)))" 5)))
      (drgnx-ui-measure sess (list (list :keys "C-g"))))))

(ert-deftest drgnx-live/terminal-odd-paths-open-here ()
  (drgnx-live-term--with sess root
    (let* ((dir (file-name-as-directory (expand-file-name "work" root)))
           (file (expand-file-name "My \"File\" café.py" dir))
           (folder (expand-file-name "a b/" dir)))
      (make-directory folder t)
      (write-region "print(1)\n" nil file nil 'silent)
      (let ((name (drgnx-live-term--open sess dir)))
        ;; the shell's drgnx is the checkout's
        (drgnx-live-term--run sess "command -v drgnx > where.txt")
        (should (drgnx-live-term--until sess (format "(let ((a (file-attributes %S))) (and a (> (file-attribute-size a) 0)))" (expand-file-name "where.txt" dir)) 5))
        (should (equal (expand-file-name "bin/drgnx" drgnx-ui-repo-dir)
                       (string-trim (with-temp-buffer (insert-file-contents (expand-file-name "where.txt" dir)) (buffer-string)))))
        ;; as when drgnx shows only a terminal frame (`drgnx -t'): no graphical window to find, yet none is made
        (drgnx-live-term--q sess "(progn (advice-add 'drgnx-session-gui-frame-p :override #'ignore) t)")
        (drgnx-live-term--run sess "drgnx 'My \"File\" café.py'")
        (should (drgnx-live-term--until
                 sess (format "(when-let* ((b (get-file-buffer %S))) (and (eq (window-buffer (selected-window)) b) (drgnx-signal-editor-window-p (selected-window))))" file)
                 10))
        (should (= 1 (drgnx-live-term--q sess "(length (seq-remove #'frame-parent (frame-list)))")))
        (drgnx-live-term--select sess name)
        (drgnx-live-term--run sess "drgnx 'a b'")
        (should (equal folder (drgnx-live-term--until sess (format "(let ((r (car (drgnx-explorer-roots)))) (and (equal r %S) r))" folder) 10)))
        (should (= 1 (drgnx-live-term--q sess "(length (seq-remove #'frame-parent (frame-list)))")))))))

(ert-deftest drgnx-live/terminal-git-commit-round-trips ()
  (skip-unless (executable-find "git"))
  (drgnx-live-term--with sess root
    (let* ((repo (file-name-as-directory (expand-file-name "repo" root)))
           (git (lambda (&rest args)
                  (with-temp-buffer
                    (let ((default-directory repo)) (apply #'call-process "git" nil t nil args))
                    (string-trim (buffer-string))))))
      (make-directory repo)
      (funcall git "init" "-q")
      (write-region "hello\n" nil (expand-file-name "a.txt" repo) nil 'silent)
      (funcall git "add" "a.txt")
      (drgnx-live-term--open sess repo)
      (drgnx-live-term--run sess "git commit")
      (should (drgnx-live-term--until sess "(and (get-buffer \"COMMIT_EDITMSG\") t)" 10))
      (should (equal (expand-file-name ".git/COMMIT_EDITMSG" repo)
                     (drgnx-live-term--q sess "(buffer-file-name (get-buffer \"COMMIT_EDITMSG\"))")))
      (drgnx-live-term--q sess "(with-current-buffer \"COMMIT_EDITMSG\" (goto-char (point-min)) (insert \"first\") (save-buffer) (server-edit) t)")
      (let ((deadline (+ (float-time) 10)) subject)
        (while (and (not (equal (setq subject (funcall git "log" "-1" "--format=%s")) "first")) (< (float-time) deadline))
          (sleep-for 0.2))
        (should (equal subject "first"))))))

(ert-deftest drgnx-live/terminal-keys-split ()
  (drgnx-live-term--with sess root
    (let ((name (drgnx-live-term--open sess root)))
      ;; an app key reaches drgnx: the palette
      (drgnx-ui-measure sess (list (list :keys "C-S-p")))
      (should (drgnx-live-term--until sess "(and (active-minibuffer-window) t)" 5))
      (drgnx-ui-measure sess (list (list :keys "C-g")))
      (should (drgnx-live-term--until sess "(not (active-minibuffer-window))" 5))
      (should (equal name (drgnx-live-term--q sess "(buffer-name (window-buffer (selected-window)))")))
      ;; an editing key reaches the shell: C-a is the start of the line in zle
      (drgnx-ui-measure sess (list (list :type "abc") (list :keys "C-a") (list :type "X")))
      (should (drgnx-live-term--until
               sess (format "(with-current-buffer %S (save-excursion (goto-char (point-max)) (skip-chars-backward \" \\n\") (string-suffix-p \"Xabc\" (buffer-substring (line-beginning-position) (point)))))" name)
               5)))))

;;; drgnx-terminal-test.el ends here
