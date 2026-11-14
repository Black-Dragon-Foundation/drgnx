;;; drgnx-record.el --- bin/drgnx record: finish, lint and export a recorded run -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A recorded run is a directory the hub wrote (docs/develop/recordings.md).  `bin/drgnx record start' and `replay'
;; run a test command with the hub's recording variables set (shell); the rest is here, in a batch Emacs:
;; `stop' (the run's end: its manifest, the report, the lint), `lint' (the secret lint, Ratatoskr's:
;; `ratatoskr recording lint'), `export' (a mock-made run into a repository fixture) and `path' (where a name is).
;; Nothing here reads or prints a secret: the lint names a file, an offset and a kind.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-record-fixture-max (* 256 1024)
  "The most a repository fixture may hold, in bytes (what `export' copies).")

(defvar drgnx-record-lint-function #'drgnx-record-lint
  "How `drgnx-record-export' lints what it made: a function of a list of directories returning (EXIT . TEXT).")

(defun drgnx-record-root ()
  "Where runs are kept: $DRGNX_RECORDINGS, else <state>/recordings."
  (file-name-as-directory
   (let ((d (getenv "DRGNX_RECORDINGS")))
     (if (and d (not (string-empty-p d)))
         (expand-file-name d)
       (expand-file-name "recordings" (drgnx-state-dir))))))

(defun drgnx-record-find (name)
  "The run directory NAME names: a directory itself, a run under `drgnx-record-root', or the newest run there
called DATE-NAME.  A `user-error' when there is none."
  (let ((root (drgnx-record-root)))
    (cond
     ((and (string-match-p "/" name) (file-directory-p name)) (directory-file-name (expand-file-name name)))
     ((file-directory-p (expand-file-name name root)) (directory-file-name (expand-file-name name root)))
     (t
      (let ((found (and (file-directory-p root)
                        (directory-files root t (concat "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]-"
                                                        (regexp-quote name) "\\'")))))
        (if found
            (car (last (sort found #'string<)))
          (user-error "no recording called %s under %s" name root)))))))

(defun drgnx-record--read (file)
  "The JSON object in FILE as an alist."
  (let ((coding-system-for-read 'utf-8))
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-buffer :object-type 'alist :null-object :null :false-object :false))))

(defun drgnx-record--write (file value)
  "VALUE (an alist) as JSON in FILE, through a temporary file."
  (let ((tmp (concat file ".tmp")) (coding-system-for-write 'utf-8-unix))
    (with-temp-file tmp
      (insert (json-serialize value :null-object :null :false-object :false) "\n"))
    (rename-file tmp file t)))

(defun drgnx-record-ratatoskr ()
  "Ratatoskr's binary: DRGNX_RATATOSKR_BIN when it is an absolute executable file, else <data>/bin/ratatoskr."
  (let ((ok (lambda (f) (and f (string-prefix-p "/" f) (file-regular-p f) (file-executable-p f) f))))
    (or (funcall ok (getenv "DRGNX_RATATOSKR_BIN"))
        (funcall ok (expand-file-name "bin/ratatoskr" (drgnx-data-dir)))
        (user-error "Ratatoskr is not built: run `drgnx runtime build'"))))

(defun drgnx-record-lint (dirs)
  "The secret lint over the run directories DIRS, as (EXIT . TEXT): EXIT 0 when clean, TEXT its findings (a file, an
offset, a kind and four characters each, never a value)."
  (with-temp-buffer
    (let ((code (apply #'call-process (drgnx-record-ratatoskr) nil t nil "recording" "lint" dirs)))
      (cons code (buffer-string)))))

;;;; export

(defun drgnx-record--export-files (run)
  "What exporting RUN copies, as (SOURCE . DESTINATION) with DESTINATION relative to the fixture: the manifest and
the streams (`llm.jsonl', `acp/', `effects/') and the normalized transcript; never `bundle/'."
  (let (out)
    (dolist (f '("manifest.json" "llm.jsonl"))
      (let ((src (expand-file-name f run)))
        (when (file-exists-p src) (push (cons src f) out))))
    (dolist (sub '("acp" "effects"))
      (let ((d (expand-file-name sub run)))
        (when (file-directory-p d)
          (dolist (f (directory-files-recursively d ""))
            (push (cons f (file-relative-name f run)) out)))))
    (let ((tr (expand-file-name "bundle/transcript.json" run)))
      (when (file-exists-p tr) (push (cons tr "transcript.json") out)))
    (nreverse out)))

(defun drgnx-record--roots (manifest)
  "MANIFEST's roots as (NAME . PATH), longest path first."
  (sort (cl-loop for (k . v) in (alist-get 'roots manifest)
                 when (and (stringp v) (> (length v) 1)) collect (cons (symbol-name k) (directory-file-name v)))
        (lambda (a b) (> (length (cdr a)) (length (cdr b))))))

(defun drgnx-record--machine-paths (text)
  "TEXT with the directory of the hub binary (a path ending in /ratatoskr or /ratatoskr-mock) replaced by $BIN and a
session socket's directory (the part before /s/SID/) by $SOCK: where they are depends on the build and the machine,
and a public fixture must not name either (the same rule as the match key's normalizer)."
  (replace-regexp-in-string
   "/[^ \"',:=()\\]*/\\(ratatoskr-mock\\|ratatoskr\\)\\([^[:alnum:]_./-]\\|\\'\\)" "$BIN/\\1\\2"
   (replace-regexp-in-string "/[^ \"',:=()\\]*\\(/s/a[0-9a-f]\\{12\\}/\\)" "$SOCK\\1" text t)
   t))

(defun drgnx-record--normalize (text roots)
  "TEXT with the machine's paths (`drgnx-record--machine-paths') and each of ROOTS' paths (at a path boundary)
replaced by their names, and `127.0.0.1:PORT' and `localhost:PORT' by $PORT: the normalizers of the recording's match
key that a stored body may hold (docs)."
  (setq text (drgnx-record--machine-paths text))
  (dolist (r roots)
    (setq text (replace-regexp-in-string
                (concat (regexp-quote (cdr r)) "\\([^[:alnum:]._-]\\|\\'\\)") (concat (car r) "\\1") text t)))
  (replace-regexp-in-string "\\(?:127\\.0\\.0\\.1\\|localhost\\):[0-9]\\{1,5\\}" "$PORT" text t t))

(defun drgnx-record--copy (src dst roots &optional manifest)
  "SRC copied to DST; a stream (`.jsonl') is normalized on the way, and the MANIFEST (its roots kept as they are)
only has the machine's paths named."
  (make-directory (file-name-directory dst) t)
  (if (or manifest (string-suffix-p ".jsonl" src))
      (let ((coding-system-for-read 'utf-8) (coding-system-for-write 'utf-8-unix))
        (let ((text (with-temp-buffer (insert-file-contents src) (buffer-string))))
          (with-temp-file dst
            (insert (if manifest (drgnx-record--machine-paths text) (drgnx-record--normalize text roots))))))
    (copy-file src dst t)))

(defun drgnx-record-export (run to)
  "RUN (a run directory) as a repository fixture in the new directory TO.  Only a run the mocks made
\(provenance `mock'): live recordings stay in the developer's own folder.  It holds the manifest (its roots kept: the
replay maps them), the streams and the effects, with the run's roots and ports normalized in the streams; never
`bundle/' (work.db, logs, screenshots).  At most `drgnx-record-fixture-max' bytes, and the lint must pass; a failure
leaves TO not made.  A `user-error' says why."
  (let* ((manifest (drgnx-record--read (expand-file-name "manifest.json" run)))
         (provenance (alist-get 'provenance manifest))
         (files (drgnx-record--export-files run))
         (size (cl-loop for f in files sum (or (file-attribute-size (file-attributes (car f))) 0))))
    (unless (equal provenance "mock")
      (user-error "refusing to export %s: its provenance is %s, and repository fixtures come only from the mocks"
                  run (if (stringp provenance) provenance "missing")))
    (when (> size drgnx-record-fixture-max)
      (user-error "refusing to export %s: %d bytes is over the %d a fixture may hold"
                  run size drgnx-record-fixture-max))
    (when (and (file-directory-p to) (directory-files to nil directory-files-no-dot-files-regexp))
      (user-error "%s is not empty" to))
    (let ((roots (drgnx-record--roots manifest)) (made (not (file-directory-p to))) (ok nil))
      (unwind-protect
          (progn
            (make-directory to t)
            (dolist (f files)
              (let ((dst (expand-file-name (cdr f) to)))
                (drgnx-record--copy (car f) dst roots (equal (cdr f) "manifest.json"))))
            (let ((lint (funcall drgnx-record-lint-function (list to))))
              (unless (eql (car lint) 0)
                (user-error "the lint refuses the export:\n%s" (cdr lint))))
            (setq ok t))
        (unless ok
          (if made
              (delete-directory to t)
            (dolist (f (directory-files to t directory-files-no-dot-files-regexp))
              (if (file-directory-p f) (delete-directory f t) (delete-file f))))))
      to)))

;;;; stop

(defun drgnx-record--lines (file)
  "The number of lines in FILE (0 when there is none)."
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (count-lines (point-min) (point-max)))
    0))

(defun drgnx-record--report (run manifest lint status)
  "The text of RUN's report.md."
  (let* ((acp (directory-files (expand-file-name "acp" run) t "\\.jsonl\\'"))
         (effects (and (file-directory-p (expand-file-name "effects" run))
                       (directory-files (expand-file-name "effects" run) nil directory-files-no-dot-files-regexp)))
         (caps (alist-get 'caps manifest))
         (stats (alist-get 'stats manifest)))
    (concat
     (format "# Recording %s\n\n" (file-name-nondirectory run))
     (format "- status: %s\n- provenance: %s\n- started: %s\n- build: %s\n"
             status (alist-get 'provenance manifest) (alist-get 'started manifest) (alist-get 'build manifest))
     (format "- gateway exchanges: %d\n" (drgnx-record--lines (expand-file-name "llm.jsonl" run)))
     (format "- agent connections: %d (%d lines)\n" (length acp)
             (apply #'+ (mapcar #'drgnx-record--lines acp)))
     (format "- worktree effects: %d\n" (length effects))
     (format "- caps: %s\n" (if caps (json-serialize caps) "none"))
     (format "- worst reader-thread stall in a worktree look: %s ms\n"
             (or (alist-get 'worst_effects_stall_ms stats) "none seen"))
     (format "- lint: %s\n" lint)
     "\nSpend is in the bundle's work.db (the spend rows) and on the provider's activity page; compare them by hand.\n")))

(defun drgnx-record-stop (run)
  "End RUN's record: its `status' (`complete' when the test command exited 0, per bundle/run.json), `ended', the lint
and report.md.  The lint (Ratatoskr's) runs over the whole run; with findings, the manifest says `fail'.  The value is
\(OK . LINT-TEXT)."
  (let* ((mfile (expand-file-name "manifest.json" run))
         (manifest (drgnx-record--read mfile))
         (runfile (expand-file-name "bundle/run.json" run))
         (exit (and (file-exists-p runfile) (alist-get 'exit (drgnx-record--read runfile))))
         (status (if (eql exit 0) "complete" "incomplete"))
         (lint (funcall drgnx-record-lint-function (list run)))
         (verdict (if (eql (car lint) 0) "pass" "fail")))
    (setf (alist-get 'status manifest) status
          (alist-get 'ended manifest) (format-time-string "%FT%TZ" nil t)
          (alist-get 'lint manifest) verdict)
    (drgnx-record--write mfile manifest)
    (with-temp-file (expand-file-name "report.md" run)
      (insert (drgnx-record--report run manifest verdict status)))
    (cons (equal verdict "pass") (cdr lint))))

;;;; the command line

(defun drgnx-record-cli-run (args)
  "bin/drgnx record's subcommands in ARGS (`stop NAME', `lint DIR-OR-NAME...', `export NAME --to DIR', `path NAME');
the exit code.  What goes wrong is said on stderr."
  (condition-case err
      (pcase args
        (`("stop" ,name)
         (let ((r (drgnx-record-stop (drgnx-record-find name))))
           (princ (if (car r) "lint: pass\n" (concat (cdr r) "lint: fail\n")))
           (if (car r) 0 1)))
        (`("lint" . ,names)
         (if (null names)
             (progn (message "usage: drgnx record lint DIR-OR-NAME…") 2)
           (let ((r (drgnx-record-lint (mapcar #'drgnx-record-find names))))
             (princ (cdr r))
             (if (eql (car r) 0) 0 1))))
        (`("export" ,name "--to" ,to)
         (princ (format "exported to %s\n" (drgnx-record-export (drgnx-record-find name) (expand-file-name to))))
         0)
        (`("path" ,name) (princ (concat (drgnx-record-find name) "\n")) 0)
        (`("root") (let ((root (drgnx-record-root))) (make-directory root t) (princ (concat (directory-file-name root) "\n")) 0))
        (_ (message "usage: drgnx record start NAME … | stop NAME | lint DIR-OR-NAME… | export NAME --to DIR") 2))
    (user-error (message "drgnx record: %s" (cadr err)) 1)
    (error (message "drgnx record: %s" (error-message-string err)) 1)))

(defun drgnx-record-cli ()
  "bin/drgnx record: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-record-cli-run args))))

(provide 'drgnx-record)
;;; drgnx-record.el ends here
