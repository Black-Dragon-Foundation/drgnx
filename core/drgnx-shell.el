;;; drgnx-shell.el --- The rc line: `drgnx shell install', onboarding step 7 -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One line in the user's shell rc file sources etc/shell/drgnx.SHELL (completion, eat's shell integration;
;; docs/guide/shell.md).  The line is added only when the user says yes: `drgnx-shell-install' asks (a function
;; of one question string), shows what it will change, and never writes without the answer.  With no ASK it
;; prints the line, as install.sh does under --yes.  Nothing here runs by itself: no timer, no hook.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-portable)

(defconst drgnx-shell-names '(zsh bash fish) "The shells drgnx has an integration file for.")

(defun drgnx-shell-name (&optional shell)
  "The shell named by SHELL (default $SHELL; a path or a name) as `zsh', `bash' or `fish'; nil for any other."
  (let ((base (file-name-nondirectory (or shell (getenv "SHELL") ""))))
    (car (memq (intern base) drgnx-shell-names))))

(defun drgnx-shell-rc-file (name)
  "The rc file of shell NAME that its interactive shells read: zsh ${ZDOTDIR:-~}/.zshrc, bash ~/.bashrc, fish
${XDG_CONFIG_HOME:-~/.config}/fish/config.fish."
  (expand-file-name
   (pcase name
     ('zsh ".zshrc")
     ('bash ".bashrc")
     ('fish "fish/config.fish")
     (_ (error "drgnx: no rc file for shell %s" name)))
   (pcase name
     ('zsh (let ((z (getenv "ZDOTDIR"))) (if (and z (not (string-empty-p z))) z "~")))
     ('fish (or (drgnx-paths-env-dir "XDG_CONFIG_HOME") "~/.config"))   ; only an absolute value counts
     (_ "~"))))

(defun drgnx-shell--word (file)
  "FILE as one shell word: \"~/\" stays unquoted so the shell expands it, the rest is backslash-quoted."
  (let ((f (drgnx-portable-path file)))
    (if (string-prefix-p "~/" f)
        (concat "~/" (shell-quote-argument (substring f 2)))
      (shell-quote-argument f))))

(defun drgnx-shell-line (name)
  "The line for shell NAME's rc file.  Guarded with -r, and ending in success, so a moved or removed checkout
leaves the shell silent and the rc file's status 0."
  (let ((p (drgnx-shell--word (expand-file-name (format "etc/shell/drgnx.%s" name) drgnx-dir))))
    (if (eq name 'fish)
        (format "test -r %s; and source %s; or true" p p)
      (format "[ -r %s ] && source %s || true" p p))))

(defun drgnx-shell--read (file)
  "The text of FILE, or nil when it cannot be read."
  (when (file-readable-p file)
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

(defun drgnx-shell-line-present-p (name)
  "Non-nil when an uncommented line of shell NAME's rc file mentions etc/shell/drgnx.NAME."
  (let ((needle (format "etc/shell/drgnx.%s" name)))
    (seq-some (lambda (l) (and (string-search needle l) (not (string-prefix-p "#" (string-trim-left l)))))
              (split-string (or (drgnx-shell--read (drgnx-shell-rc-file name)) "") "\n"))))

(cl-defun drgnx-shell-install (name &key ask)
  "Put the integration line for shell NAME into its rc file, if the user says yes.
Returns `present' (an uncommented line names the file already: nothing happens), `added', `declined', `failed'
(the file cannot be written: a read-only rc, say one linked into a managed store; nothing is changed) or
`printed'.  ASK is a function of one question string (`y-or-n-p' in a terminal); with none, the line is printed
on stdout and nothing is written.  A symlinked rc file is named with its target in the question, and the
target is what gains the line."
  (let* ((rc (drgnx-shell-rc-file name))
         (line (drgnx-shell-line name))
         (target (if (file-symlink-p rc) (file-truename rc) rc))
         (shown (if (equal target rc) (drgnx-portable-path rc)
                  (format "%s → %s" (drgnx-portable-path rc) (drgnx-portable-path target)))))
    (cond ((drgnx-shell-line-present-p name) 'present)
          ((null ask) (princ (format "add this to %s: %s\n" (drgnx-portable-path rc) line)) 'printed)
          ((funcall ask (format "Add this line to %s? %s" shown line))
           (condition-case nil
               (progn
                 (make-directory (file-name-directory target) t)
                 (write-region (format "\n# added by drgnx (docs/guide/shell.md)\n%s\n" line) nil target t 'silent)
                 'added)
             (file-error 'failed)))
          (t 'declined))))

;;;; Command line

(defconst drgnx-shell-usage
  "usage: drgnx shell install [--shell zsh|bash|fish] [--yes]\n       drgnx shell line [--shell zsh|bash|fish]\n")

(defun drgnx-shell-cli-run (args)
  "Run `drgnx shell' ARGS (strings); the exit code: 0, 2 for a usage error, 1 for a shell drgnx has no file for.
`install' asks only when stdin is a terminal (DRGNX_STDIN_TTY=1) and --yes is absent; otherwise it prints the
line it would add."
  (let ((cmd (car args)) (rest (cdr args)) shell yes bad)
    (while (and rest (not bad))
      (pcase (pop rest)
        ("--shell" (if rest (setq shell (pop rest)) (setq bad "--shell needs a shell")))
        ("--yes" (if (equal cmd "install") (setq yes t) (setq bad "--yes: only install takes it")))
        (a (setq bad (format "unknown argument %s" a)))))
    (cond
     ((not (member cmd '("install" "line"))) (princ drgnx-shell-usage) 2)
     (bad (princ (format "drgnx shell: %s\n%s" bad drgnx-shell-usage)) 2)
     (t
      (let ((name (drgnx-shell-name (or shell (getenv "SHELL")))) (code 0))
        (if (null name)
            (progn (princ (format "drgnx shell: no integration for %s (zsh, bash and fish have one; --shell NAME)\n"
                                  (let ((s (or shell (getenv "SHELL")))) (if (member s '(nil "")) "an unknown shell ($SHELL is empty)" s))))
                   1)
          (if (equal cmd "line")
              (princ (concat (drgnx-shell-line name) "\n"))
            (pcase (drgnx-shell-install name :ask (and (not yes) (equal (getenv "DRGNX_STDIN_TTY") "1") #'y-or-n-p))
              ('present (princ (format "drgnx shell: the line is in %s already\n" (drgnx-portable-path (drgnx-shell-rc-file name)))))
              ('added (princ (format "drgnx shell: added to %s; open a new terminal (or: source it)\n"
                                     (drgnx-portable-path (drgnx-shell-rc-file name)))))
              ('declined (princ "drgnx shell: nothing changed\n"))
              ('failed (princ (format "drgnx shell: %s cannot be written; add it by hand: %s\n"
                                      (drgnx-portable-path (drgnx-shell-rc-file name)) (drgnx-shell-line name)))
                       (setq code 1))))
          code))))))

(defun drgnx-shell-cli ()
  "bin/drgnx shell: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-shell-cli-run args))))

(provide 'drgnx-shell)
;;; drgnx-shell.el ends here
