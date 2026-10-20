;;; lint-bare-emacs-test.el --- lint: no subprocess runs a bare `emacs' -*- lexical-binding: t -*-
;; drgnx runs only on Nidhogg, and a machine with only Nidhogg has no `emacs' on PATH.  A subprocess that starts
;; "emacs" by that name fails there (exit 127).  In Lisp the Emacs to run is `(drgnx-emacs-program)'; in bash it is
;; `$(emacs_bin)' / $DRGNX_EMACS.  The lint reads core, wb, modules, harness, test, bin, install.sh and etc line by
;; line (comment lines never count) and fails on a call that starts the bare name, unless the file is listed in
;; `drgnx-lint-bare-emacs--allowed' with its reason.
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-lint-bare-emacs--allowed
  '(("test/bootstrap/in-container.sh" . "the container tier installs Fedora's stock emacs and runs no Nidhogg")
    ("test/unit/lint-bare-emacs-test.el" . "this lint's own patterns and fixtures"))
  "File (relative to the checkout) -> why a bare `emacs' subprocess there is right.")

(defconst drgnx-lint-bare-emacs--lisp-patterns
  '("(executable-find \"emacs\")"
    "(\\(call-process\\|process-file\\|process-lines\\|call-process-shell-command\\)[ \t]+\"emacs\\b"
    "(start-process[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+\"emacs\""
    "(list[ \t]+\"emacs\"[ \t]+\"-"
    "'(\"emacs\"[ \t]+\"-"
    "\"-c\"[ \t]+\"emacs\\b"
    "[ \t]\"emacs\"[ \t]*)+[ \t]*$")
  "Regexps for a Lisp line that starts the bare name as a subprocess.")

(defconst drgnx-lint-bare-emacs--shell-pattern
  "\\(\\(^\\|[;&|(`]\\|\\bexec \\|\\$(\\)[ \t]*emacs\\([ \t]\\|$\\)\\|\\b\\(echo\\|printf '%s\\\\n'\\)[ \t]+emacs\\b\\)"
  "A shell line that runs `emacs' in command position.")

(defun drgnx-lint-bare-emacs--files ()
  "The files to read, relative to the checkout."
  (let (files)
    (dolist (dir '("core" "wb" "modules" "harness" "test" "bin" "etc"))
      (dolist (f (and (file-directory-p (expand-file-name dir drgnx-dir))
                      (directory-files-recursively (expand-file-name dir drgnx-dir) "\\(\\.el\\|\\.sh\\|\\`[^.]*\\)\\'")))
        (let ((rel (file-relative-name f drgnx-dir)))
          (unless (or (string-prefix-p "test/fixtures/" rel) (string-suffix-p ".elc" rel)
                      (string-prefix-p "test/container/" rel))
            (push rel files)))))
    (push "install.sh" files)
    (sort files #'string<)))

(defun drgnx-lint-bare-emacs--hits (rel)
  "Lines (\"REL:N: TEXT\") of file REL that start a bare `emacs'."
  (let* ((lisp (string-suffix-p ".el" rel)) hits (n 0) (case-fold-search nil))   ; "Emacs" the profile is not `emacs'
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (condition-case nil (insert-file-contents (expand-file-name rel drgnx-dir)) (error nil)))
      (dolist (line (split-string (buffer-string) "\n"))
        (setq n (1+ n))
        (let ((text (string-trim-left line)))
          (unless (string-prefix-p (if lisp ";" "#") text)
            (when (if lisp
                      (seq-some (lambda (re) (string-match-p re line)) drgnx-lint-bare-emacs--lisp-patterns)
                    (and (not (string-prefix-p "#!" text))
                         (string-match-p drgnx-lint-bare-emacs--shell-pattern line)))
              (push (format "%s:%d: %s" rel n (string-trim line)) hits))))))
    (nreverse hits)))

(ert-deftest drgnx-lint-bare-emacs/no-bare-emacs-subprocess ()
  (let (bad)
    (dolist (rel (drgnx-lint-bare-emacs--files))
      (unless (assoc rel drgnx-lint-bare-emacs--allowed)
        (setq bad (append bad (drgnx-lint-bare-emacs--hits rel)))))
    (when bad
      (ert-fail (format "a bare `emacs' subprocess (Nidhogg-only machines have none on PATH): use (drgnx-emacs-program) in Lisp, $(emacs_bin) in bash:\n  %s"
                        (string-join bad "\n  "))))))

(ert-deftest drgnx-lint-bare-emacs/allowlist-is-live ()
  "Every allowed file exists and still has a hit: the list only shrinks."
  (dolist (row drgnx-lint-bare-emacs--allowed)
    (unless (equal (car row) "test/unit/lint-bare-emacs-test.el")
      (should (file-exists-p (expand-file-name (car row) drgnx-dir)))
      (should (drgnx-lint-bare-emacs--hits (car row))))))

(ert-deftest drgnx-lint-bare-emacs/patterns-catch-the-forms ()
  (dolist (s '("(executable-find \"emacs\")" "(call-process \"emacs\" nil nil nil)" "  :command (list \"emacs\" \"--batch\")"
               "(start-process \"x\" nil \"emacs\" \"-Q\")" "(or (executable-find \"nidhogg\") \"emacs\"))" "(list \"sh\" \"-c\" \"emacs --batch -Q\")"))
    (should (seq-some (lambda (re) (string-match-p re s)) drgnx-lint-bare-emacs--lisp-patterns)))
  (dolist (s '("emacs --batch -Q" "x && emacs -Q" "exec emacs -nw" "y=$(emacs --version)" "else echo emacs; fi"))
    (should (string-match-p drgnx-lint-bare-emacs--shell-pattern s)))
  (dolist (s '("$(emacs_bin) --batch" "\"$DRGNX_EMACS\" --batch" "say emacs is here"))
    (should-not (string-match-p drgnx-lint-bare-emacs--shell-pattern s))))
