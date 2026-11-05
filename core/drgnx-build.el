;;; drgnx-build.el --- Byte-compile drgnx's own Lisp -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx build' byte-compiles core/, wb/, modules/ and harness/ in place (the .elc files are not
;; tracked).  Compiled drgnx is several times faster and makes far less garbage than
;; interpreted drgnx; when Emacs has native compilation, it compiles the .elc files natively
;; in the background as they load.  drgnx's init sets `load-prefer-newer', so a stale .elc
;; never shadows newer source.  install.sh runs the build.  Each file compiles in a fresh
;; batch Emacs, as the native compiler compiles it, several at once.  See docs/develop/core.md.

;;; Code:
(require 'bytecomp)
(require 'seq)

(declare-function drgnx-guard-wrap "drgnx-guard")

(defconst drgnx-build-dirs '("core" "wb" "modules" "harness")
  "What `drgnx build' compiles, under the checkout.  The test files (test/) are not compiled: they are loaded
into a runner, not alone, so they carry no declarations for what the runner defines.")

(defun drgnx-build-files (root)
  "The .el files to compile under ROOT (a checkout)."
  (seq-mapcat (lambda (d) (let ((dir (expand-file-name d root)))
                            (and (file-directory-p dir) (directory-files-recursively dir "\\.el\\'"))))
              drgnx-build-dirs))

(defconst drgnx-build--marker "\ndrgnx-build-file: " "What precedes a compiling Emacs's result on its output.")
(defconst drgnx-build-file-timeout 120 "Seconds one file's compile may take before the build counts it as an error.")

(defun drgnx-build-compile-file (file root)
  "Byte-compile FILE of the checkout ROOT here; return (:compiled BOOL :warnings LIST :errors LIST).
`drgnx-build' calls it in a fresh batch Emacs per file."
  (let ((rel (file-relative-name file root))
        (load-path (append (mapcar (lambda (d) (expand-file-name d root)) '("core" "wb" "harness")) load-path))
        (byte-compile-docstring-max-column 120)        ; the project's line length
        (load-prefer-newer t)                           ; a changed dependency, not its old .elc
        (warnings nil) (errors nil) (ok nil))
    (let ((byte-compile-log-warning-function
           (lambda (string &optional _position _fill level)
             (push (format "%s: %s" rel string) (if (eq level :error) errors warnings))
             t)))
      (condition-case err
          (if (byte-compile-file file) (setq ok t) (push (format "%s: did not compile" rel) errors))
        (error (push (format "%s: %s" rel (error-message-string err)) errors))))
    (list :compiled ok :warnings (nreverse warnings) :errors (nreverse errors))))

(defun drgnx-build--child (file root)
  "Batch entry of a compiling Emacs: compile FILE of ROOT and print the result after `drgnx-build--marker'."
  (let ((print-length nil) (print-level nil))
    (princ drgnx-build--marker)
    (prin1 (drgnx-build-compile-file file root))
    (terpri)))

(defun drgnx-build-jobs (&optional available)
  "How many files compile at once with AVAILABLE MiB (default: MemAvailable now, Linux): one per 150 MiB
beyond 1 GiB kept free (a compiling Emacs peaks near 75 MiB), at least 1, at most the processor count.
DRGNX_BUILD_JOBS, a positive number, sets it."
  (let ((env (string-to-number (or (getenv "DRGNX_BUILD_JOBS") ""))))
    (if (> env 0) env
      (let ((mb (or available
                    (ignore-errors
                      (with-temp-buffer
                        (insert-file-contents "/proc/meminfo")
                        (and (re-search-forward "^MemAvailable: *\\([0-9]+\\) kB" nil t)
                             (/ (string-to-number (match-string 1)) 1024))))
                    2048)))
        (max 1 (min (num-processors) (floor (- mb 1024) 150)))))))

(defun drgnx-build--result (proc file root)
  "The result PROC (compiling FILE of ROOT) printed, or one with an error saying what it printed instead."
  (let* ((out (with-current-buffer (process-buffer proc) (buffer-string)))
         (at (string-search drgnx-build--marker out))
         (r (and at (ignore-errors (car (read-from-string out (+ at (length drgnx-build--marker))))))))
    (or r (list :compiled nil :warnings nil
                :errors (list (format "%s: the compiling Emacs ended without a result (exit %s): %s"
                                      (file-relative-name file root) (process-exit-status proc)
                                      (string-trim out)))))))

(defun drgnx-build--sentinel (proc _event)
  "Mark PROC's compile done once it ended.  Emacs runs a sentinel only after it read the output the process left
in its pipe; `process-status' says `exit' as soon as the process is reaped, while that output may still be unread
\(under load the build then took a finished compile for one that ended without a result)."
  (unless (process-live-p proc) (process-put proc 'drgnx-build-done t)))

(defun drgnx-build (root)
  "Byte-compile drgnx's Lisp under ROOT; return (:compiled N :warnings LIST :errors LIST).
Each file compiles in a fresh batch Emacs, as the native compiler compiles it when a session loads the .elc: a
function another file's compile happened to load cannot hide a missing `declare-function' or `require'.
`drgnx-build-jobs' of them run at once."
  (require 'drgnx-guard)                ; not at load: the compiling children load this file with -Q, no load-path
  (let* ((files (drgnx-build-files root))
         (emacs (expand-file-name invocation-name invocation-directory))
         (self (or (locate-library "drgnx-build.el") (error "drgnx-build.el is not on load-path")))
         (jobs (drgnx-build-jobs))
         (queue files) (running nil) (results nil))
    (unwind-protect
        (while (or queue running)
          (while (and queue (< (length running) jobs))
            (let* ((file (pop queue))
                   (proc (make-process
                          :name "drgnx-build" :buffer (generate-new-buffer " *drgnx-build*" t) :noquery t
                          :connection-type 'pipe :sentinel (drgnx-guard-wrap #'drgnx-build--sentinel "build compile")
                          :command (list emacs "--batch" "-Q" "-l" self
                                         "--eval" (prin1-to-string `(drgnx-build--child ,file ,root))))))
              (push (list proc file (+ (float-time) drgnx-build-file-timeout)) running)))
          (accept-process-output nil 0.05)
          (dolist (job running)
            (pcase-let ((`(,proc ,file ,deadline) job))
              (cond ((process-get proc 'drgnx-build-done)
                     (push (cons file (drgnx-build--result proc file root)) results)
                     (kill-buffer (process-buffer proc))
                     (setq running (delq job running)))
                    ((> (float-time) deadline)
                     (delete-process proc)
                     (kill-buffer (process-buffer proc))
                     (push (cons file (list :compiled nil :warnings nil
                                            :errors (list (format "%s: did not compile in %d s"
                                                                  (file-relative-name file root)
                                                                  drgnx-build-file-timeout))))
                           results)
                     (setq running (delq job running)))))))
      (dolist (job running)
        (delete-process (car job))
        (kill-buffer (process-buffer (car job)))))
    ;; in file order, whatever order they finished in
    (let ((ordered (mapcar (lambda (f) (cdr (assoc f results))) files)))
      (list :compiled (seq-count (lambda (r) (plist-get r :compiled)) ordered)
            :warnings (seq-mapcat (lambda (r) (plist-get r :warnings)) ordered)
            :errors (seq-mapcat (lambda (r) (plist-get r :errors)) ordered)))))

;;;; Trampolines ahead of time
;; Advising a primitive, or `cl-letf'-ing one, makes Emacs compile a trampoline for it (a small native function that
;; calls the replacement) the first time, and that compile waits for gcc inside whatever command was running.  A new
;; Nidhogg invalidates them all, which `drgnx update' does by installing one and then running this build.  So the
;; build compiles the trampolines of the primitives drgnx advises, here and now, into the first writable directory of
;; `native-comp-eln-load-path' (DRGNX_TEST_ELN_DIR first when a test run gives one: never the user's eln-cache).

(defconst drgnx-build-trampoline-dirs '("core" "modules" "wb")
  "Where `drgnx-build-advised-primitives' looks (harness/ and test/ replace primitives only in a test run, which has
its own trampolines).")

(defconst drgnx-build--advised-lists
  '(("core/drgnx-guard.el" . drgnx-guard-prompt-functions) ("core/drgnx-sandbox-vc.el" . drgnx-sandbox-vc--advised))
  "Advice put on a list of functions by a loop rather than by name: (FILE . VARIABLE), the variable's value a list of
symbols or of (SYMBOL . ADVICE) pairs, read from the file's `defvar' or `defconst'.")

(defun drgnx-build--quoted (form)
  "The symbol FORM quotes (a quote or a function quote of a symbol), else nil."
  (and (consp form) (memq (car form) '(quote function)) (symbolp (cadr form)) (cadr form)))

(defun drgnx-build--scan-form (form acc)
  "Add to the list ACC (returned) the symbols FORM advises or replaces: `advice-add', `drgnx-module-advice' and
a `symbol-function' of a quoted name (a `cl-letf' of a function), anywhere in FORM."
  (when (consp form)
    (let ((head (car form)) (arg (and (consp (cdr form)) (drgnx-build--quoted (cadr form)))))
      (when (and arg (memq head '(advice-add drgnx-module-advice symbol-function)))
        (push arg acc)))
    (while (consp form)
      (setq acc (drgnx-build--scan-form (car form) acc) form (cdr form))))
  acc)

(defun drgnx-build--read-forms (file)
  "The top-level forms of FILE as far as they read."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((forms nil) (read-circle nil))
      (goto-char (point-min))
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (error nil))
      (nreverse forms))))

(defun drgnx-build-advised-primitives (root)
  "The primitives (C functions, `subr-primitive-p') the Lisp under ROOT's `drgnx-build-trampoline-dirs' advises
or replaces, sorted: what a static scan of `advice-add', `drgnx-module-advice' and a quoted `symbol-function' finds, and
the functions of `drgnx-build--advised-lists'."
  (let ((syms nil))
    (dolist (d drgnx-build-trampoline-dirs)
      (let ((dir (expand-file-name d root)))
        (when (file-directory-p dir)
          (dolist (file (directory-files-recursively dir "\\.el\\'"))
            (let ((rel (file-relative-name file root)))
              (dolist (form (drgnx-build--read-forms file))
                (setq syms (drgnx-build--scan-form form syms))
                (when-let* ((var (cdr (assoc rel drgnx-build--advised-lists)))
                            ((memq (car-safe form) '(defvar defconst)))
                            ((eq (cadr form) var))
                            (value (eval (caddr form) t)))
                  (dolist (e value) (push (if (consp e) (car e) e) syms)))))))))
    (sort (seq-uniq (seq-filter (lambda (s) (and (symbolp s) (fboundp s) (not (special-form-p s))
                                                 (subr-primitive-p (symbol-function s))))
                                syms))
          #'string<)))

(defun drgnx-build-trampoline-dir ()
  "Where the trampolines go: DRGNX_TEST_ELN_DIR (absolute) when set, else the first writable directory of
`native-comp-eln-load-path'; nil when there is none."
  (let ((given (getenv "DRGNX_TEST_ELN_DIR")))
    (if (and given (file-name-absolute-p given))
        (progn (make-directory given t) (expand-file-name given))
      (seq-find (lambda (d) (ignore-errors (make-directory d t) (file-writable-p d)))
                (mapcar (lambda (d) (expand-file-name d invocation-directory))
                        (bound-and-true-p native-comp-eln-load-path))))))

(defvar native-comp-eln-load-path)
(declare-function comp-trampoline-compile "comp-run")
(declare-function comp-trampoline-search "comp-run")

(defun drgnx-build--native-p ()
  "Does this Emacs compile natively?"
  (and (fboundp 'native-comp-available-p) (native-comp-available-p)))

(defun drgnx-build-trampolines (root)
  "Compile the trampolines of the primitives under ROOT that drgnx advises (`drgnx-build-advised-primitives'), which
are not there yet, into `drgnx-build-trampoline-dir'.  Return the list of the primitives it compiled; nil without
native compilation.  One that fails to compile is skipped: Emacs compiles it when it is first advised, as before."
  (when (and (drgnx-build--native-p) (require 'comp nil t) (fboundp 'comp-trampoline-compile))
    (when-let* ((dir (drgnx-build-trampoline-dir)))
      (let ((native-comp-eln-load-path (cons dir (bound-and-true-p native-comp-eln-load-path))) done)
        (dolist (s (drgnx-build-advised-primitives root))
          (unless (and (fboundp 'comp-trampoline-search) (comp-trampoline-search s))
            (when (ignore-errors (comp-trampoline-compile s) t) (push s done))))
        (nreverse done)))))

(defun drgnx-build-cli ()
  "Batch entry: `drgnx build' — compile the checkout; exit 1 on errors."
  (let* ((root (file-name-directory (directory-file-name (file-name-directory (locate-library "drgnx-build")))))
         (r (drgnx-build root)))
    (dolist (w (plist-get r :warnings)) (princ (format "warning: %s\n" w)))
    (dolist (e (plist-get r :errors)) (princ (format "error: %s\n" e)))
    (princ (format "drgnx build: %d files compiled, %d warnings, %d errors\n" (plist-get r :compiled)
                   (length (plist-get r :warnings)) (length (plist-get r :errors))))
    (unless (plist-get r :errors)
      (let ((made (drgnx-build-trampolines root)))
        (princ (format "drgnx build: %d trampolines compiled\n" (length made)))))
    (kill-emacs (if (plist-get r :errors) 1 0))))

(provide 'drgnx-build)
;;; drgnx-build.el ends here
