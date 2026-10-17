;;; drgnx-pkg.el --- Packages: manifest, lock, sync, cache, generations, upgrade -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Packages are installed by `drgnx sync' only, never by a session.  The manifest is every enabled
;; module's :packages, packages.eld's :packages and what use-package :ensure asked for in a session
;; (recorded there, not installed).  sync resolves it with package.el against the archives — or,
;; offline, against the lock and the cache — installing into a staging copy of the packages
;; directory; only when every file arrived with the right hash is the copy swapped in, the lock
;; (drgnx.lock.eld) written and a generation (a snapshot of the directory) made.  Rollback copies a
;; generation back into the same real path, so natively compiled files stay valid.  This file runs
;; in batch Emacs (bin/drgnx); sessions only activate (drgnx-pkg-activate.el).  See docs/guide/packages.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'package)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-pkg-activate)

(defvar native-comp-eln-load-path)
(defvar byte-compile-warnings)

(defvar drgnx-pkg-native-compile (and (fboundp 'native-comp-available-p) (native-comp-available-p))
  "Non-nil: sync compiles the packages it installs to native code ahead of time.")

(defconst drgnx-pkg-default-archives
  '(("gnu" . "https://elpa.gnu.org/packages/")
    ("nongnu" . "https://elpa.nongnu.org/nongnu/")
    ("melpa" . "https://melpa.org/packages/"))
  "Archives when packages.eld names none (:archives).")

(defconst drgnx-pkg-generations-kept 5)

(defun drgnx-pkg--error (fmt &rest args) (signal 'drgnx-pkg-error (list (apply #'format fmt args))))

(defun drgnx-pkg--read-file (file)
  "The first form of FILE, nil when FILE does not exist; an unreadable FILE is a `drgnx-pkg-error'."
  (when (file-exists-p file)
    (condition-case err
        (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
      (error (drgnx-pkg--error "%s is unreadable (%s); fix or remove it" file (error-message-string err))))))

(defun drgnx-pkg--write-file (file header data)
  "Write DATA to FILE (atomically: a temp file .FILE.tmp-* renamed over it), after the comment HEADER.
A write that stops half way leaves no temp file."
  (make-directory (file-name-directory file) t)
  (let ((tmp (make-temp-file (expand-file-name (concat "." (file-name-nondirectory file) ".tmp-") (file-name-directory file)))))
    (unwind-protect
        (progn (with-temp-file tmp
                 (insert ";; " header "\n")
                 (let ((print-length nil) (print-level nil)) (pp data (current-buffer))))
               (rename-file tmp file t))
      (ignore-errors (delete-file tmp)))))

(defun drgnx-pkg--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-pkg--sha256 (file) (secure-hash 'sha256 (drgnx-pkg--bytes file)))

;;;; Manifest

(defun drgnx-pkg--module-packages (dir)
  "Alist MODULE → packages of every `drgnx-module-define' in DIR's files — read, never run."
  (let (out)
    (dolist (file (and (file-directory-p dir) (directory-files-recursively dir "\\.el\\'")))
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (while t
              (pcase (read (current-buffer))
                (`(drgnx-module-define (quote ,(and (pred symbolp) name)) . ,args)
                 (push (cons name (pcase (plist-get args :packages) (`(quote ,l) l))) out))))
          (error nil))))                                ; end of file (or a file that does not read)
    (nreverse out)))

(defun drgnx-pkg--packages-eld () (drgnx-pkg--read-file (expand-file-name "packages.eld" (drgnx-user-dir))))

(defun drgnx-pkg-manifest (&optional modules-dir)
  "The packages drgnx needs, sorted: every enabled module's :packages (MODULES-DIR, default drgnx's
modules/), packages.eld's :packages and those use-package :ensure asked for in a session."
  (let ((names (append (seq-mapcat #'cdr (seq-remove (lambda (m) (drgnx-module-disabled-p (car m)))
                                                     (drgnx-pkg--module-packages
                                                      (or modules-dir (expand-file-name "modules" drgnx-dir)))))
                       (plist-get (drgnx-pkg--packages-eld) :packages)
                       (ignore-errors (drgnx-pkg--read-file (drgnx-pkg-wanted-file))))))
    (sort (delete-dups (seq-filter #'symbolp names)) (lambda (a b) (string< a b)))))

(defun drgnx-pkg-archives ()
  "The archives: packages.eld's :archives, else `drgnx-pkg-default-archives'."
  (let ((p (drgnx-pkg--packages-eld)))
    (if (plist-member p :archives) (plist-get p :archives) drgnx-pkg-default-archives)))

;;;; Lock

(defun drgnx-pkg-lock-file () (expand-file-name "drgnx.lock.eld" (drgnx-user-dir)))

(defun drgnx-pkg-read-lock ()
  "The lock: entries (NAME :version :archive :kind :file :sha256 :requires :summary), sorted; nil when
there is none.  An unreadable lock is a `drgnx-pkg-error' (never silently replaced)."
  (let ((data (drgnx-pkg--read-file (drgnx-pkg-lock-file))))
    (cond ((null data) nil)
          ((and (eql (plist-get data :version) 1) (listp (plist-get data :packages))) (plist-get data :packages))
          (t (drgnx-pkg--error "%s is not a drgnx lock (version 1)" (drgnx-pkg-lock-file))))))

(defun drgnx-pkg-write-lock (entries)
  (drgnx-pkg--write-file (drgnx-pkg-lock-file) "drgnx package lock — written by drgnx sync; commit it with your config"
                         (list :version 1 :packages (sort (copy-sequence entries)
                                                          (lambda (a b) (string< (car a) (car b)))))))

;;;; The sync lock (one writer of the packages directory at a time)

(defun drgnx-pkg--sync-lock-file () (expand-file-name "sync.lock" (drgnx-data-dir)))

(defvar drgnx-pkg--holding-lock nil "Non-nil while this process holds the sync lock (nested calls reuse it).")

(defun drgnx-pkg--file-string (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-pkg--lock-live-p (stamp)
  "Non-nil when the sync lock's STAMP (\"PID START\") names a running process: PID is alive and
started at START (another start: the pid was reused, e.g. after a reboot).  The start is compared
to half a second — Emacs's reading of it jitters by a clock tick."
  (pcase-let ((`(,pid ,start) (mapcar #'string-to-number (split-string stamp))))
    (when-let* ((attrs (and pid (> pid 0) (process-attributes pid))))
      (or (null start) (null (alist-get 'start attrs))                   ; a lock without a start: the pid decides
          (< (abs (- start (float-time (alist-get 'start attrs)))) 0.5)))))

(defun drgnx-pkg--clear-stale-lock (file seen)
  "Remove the stale lock FILE, whose content was SEEN.  It is renamed aside first (atomic), so of two
processes taking over the same lock only one does; when what was renamed is not SEEN, another
process took the lock meanwhile: it is put back and this is a `drgnx-pkg-error'."
  (let ((aside (make-temp-name (concat file ".stale-"))))
    (when (ignore-errors (rename-file file aside) t)   ; nil: another process moved it first
      (unless (equal (drgnx-pkg--file-string aside) seen)
        (ignore-errors (rename-file aside file))       ; never over a lock that appeared meanwhile
        (ignore-errors (delete-file aside))
        (drgnx-pkg--error "another drgnx sync just started (%s); wait for it" file))
      (delete-file aside))))

(defun drgnx-pkg--take-sync-lock ()
  "Take the sync lock: its file holds \"PID START\" of this process.  Returns that stamp."
  (let ((file (drgnx-pkg--sync-lock-file))
        (stamp (format "%d %.2f" (emacs-pid) (float-time (or (alist-get 'start (process-attributes (emacs-pid))) 0)))))
    (make-directory (file-name-directory file) t)
    (when-let* ((seen (and (file-exists-p file) (drgnx-pkg--file-string file))))
      (if (drgnx-pkg--lock-live-p seen)
          (drgnx-pkg--error "another drgnx sync, upgrade or rollback is running (process %s, %s); wait for it"
                            (car (split-string seen)) file)
        (drgnx-pkg--clear-stale-lock file seen)))     ; left by a process that is gone
    (condition-case nil
        (write-region stamp nil file nil 'silent nil 'excl)
      (file-already-exists (drgnx-pkg--error "another drgnx sync just started (%s); wait for it" file)))
    stamp))

(defun drgnx-pkg--release-sync-lock (stamp)
  "Remove the sync lock if it is still the one STAMP took (never another process's)."
  (let ((file (drgnx-pkg--sync-lock-file)))
    (when (equal (ignore-errors (drgnx-pkg--file-string file)) stamp)
      (ignore-errors (delete-file file)))))

(defmacro drgnx-pkg--with-sync-lock (&rest body)
  "BODY holding the sync lock — taken here unless an outer call holds it already."
  (declare (indent 0))
  (let ((stamp (make-symbol "stamp")))
    `(if drgnx-pkg--holding-lock (progn ,@body)
       (let ((,stamp (drgnx-pkg--take-sync-lock)))
         (unwind-protect (let ((drgnx-pkg--holding-lock t)) ,@body)
           (drgnx-pkg--release-sync-lock ,stamp))))))

;;;; Directories: staging, swap, generations

(defun drgnx-pkg--copy-dir (from to)
  "Copy directory FROM to TO (reflinks where the file system has them)."
  (make-directory (file-name-directory (directory-file-name to)) t)
  (if (and (memq system-type '(gnu/linux)) (executable-find "cp"))
      (unless (zerop (call-process "cp" nil nil nil "-a" "--reflink=auto"
                                   (directory-file-name from) (directory-file-name to)))
        (drgnx-pkg--error "could not copy %s to %s" from to))
    (copy-directory from to t t t)))

(defun drgnx-pkg--staging () (expand-file-name "elpa.staging/" (drgnx-data-dir)))

(defun drgnx-pkg--old () (concat (directory-file-name (drgnx-elpa-dir)) ".old"))

(defun drgnx-pkg--recover ()
  "After a crash between the two renames of a swap: the previous directory is in elpa.old — put it back."
  (when (and (not (file-exists-p (drgnx-elpa-dir))) (file-directory-p (drgnx-pkg--old)))
    (rename-file (drgnx-pkg--old) (directory-file-name (drgnx-elpa-dir)))))

(defun drgnx-pkg--sweep ()
  "Delete what a killed run left: half downloads (cache/*.part), the lock's temp files and stale locks
set aside.  Called holding the sync lock: no other run is writing them."
  (pcase-dolist (`(,dir . ,re) `((,(drgnx-package-cache-dir) . "\\.part\\'")
                                 (,(drgnx-user-dir) . "\\`\\.drgnx\\.lock\\.eld\\.tmp-")
                                 (,(drgnx-data-dir) . "\\`sync\\.lock\\.stale-")))
    (dolist (f (and (file-directory-p dir) (directory-files dir t re)))
      (ignore-errors (delete-file f)))))

(defun drgnx-pkg--swap-in (dir)
  "Make DIR the packages directory: two renames.  A running session keeps the files it loaded; it
should be restarted to use the new ones (the CLI says so)."
  (let ((elpa (directory-file-name (drgnx-elpa-dir))) (old (drgnx-pkg--old)))
    (when (file-exists-p old) (delete-directory old t))
    (when (file-exists-p elpa) (rename-file elpa old))
    (rename-file (directory-file-name dir) elpa)
    (when (file-exists-p old) (delete-directory old t))))

(defun drgnx-pkg-generations ()
  "Generations, newest first: (N :time TIME :note NOTE).  Half-written ones (N.tmp) are not listed."
  (let ((dir (drgnx-generations-dir)))
    (sort (delq nil (mapcar (lambda (d)
                              (when (string-match-p "\\`[0-9]+\\'" d)
                                (cons (string-to-number d)
                                      (ignore-errors (drgnx-pkg--read-file (expand-file-name (concat d "/generation.eld") dir))))))
                            (and (file-directory-p dir) (directory-files dir))))
          (lambda (a b) (> (car a) (car b))))))

(defun drgnx-pkg--generation-dir (n) (file-name-as-directory (expand-file-name (number-to-string n) (drgnx-generations-dir))))

(defun drgnx-pkg--current-file () (expand-file-name "current" (drgnx-generations-dir)))

(defun drgnx-pkg-current-generation ()
  "The generation the packages directory holds (the last snapshot or rollback), or nil."
  (let ((gens (mapcar #'car (drgnx-pkg-generations)))
        (n (and (file-exists-p (drgnx-pkg--current-file))
                (string-to-number (with-temp-buffer (insert-file-contents (drgnx-pkg--current-file)) (buffer-string))))))
    (if (memq n gens) n (car gens))))

(defun drgnx-pkg--set-current (n)
  (make-directory (drgnx-generations-dir) t)
  (write-region (number-to-string n) nil (drgnx-pkg--current-file) nil 'silent))

(defun drgnx-pkg-snapshot (&optional note)
  "Snapshot the packages directory and the lock as a new generation (written as N.tmp, then renamed);
keep the newest five.  Returns N."
  (let* ((n (1+ (or (car (car (drgnx-pkg-generations))) 0)))
         (dir (drgnx-pkg--generation-dir n))
         (tmp (concat (directory-file-name dir) ".tmp/")))
    (when (file-exists-p tmp) (delete-directory tmp t))
    (make-directory tmp t)
    (if (file-directory-p (drgnx-elpa-dir))
        (drgnx-pkg--copy-dir (drgnx-elpa-dir) (expand-file-name "elpa" tmp))
      (make-directory (expand-file-name "elpa" tmp)))
    (when (file-exists-p (drgnx-pkg-lock-file)) (copy-file (drgnx-pkg-lock-file) (expand-file-name "drgnx.lock.eld" tmp) t))
    (drgnx-pkg--write-file (expand-file-name "generation.eld" tmp) "drgnx generation"
                           (list :time (format-time-string "%FT%T%z") :note note))
    (rename-file (directory-file-name tmp) (directory-file-name dir))
    (drgnx-pkg--set-current n)
    (dolist (g (nthcdr drgnx-pkg-generations-kept (drgnx-pkg-generations)))
      (delete-directory (drgnx-pkg--generation-dir (car g)) t))
    n))

(defun drgnx-pkg-rollback (&optional n)
  "Make generation N (default: the one before the current one) the packages directory again, with its
lock.  Files come back at the same path, so their native code stays valid.  Returns N."
  (drgnx-pkg--with-sync-lock
    (drgnx-pkg--recover)
    (let* ((gens (drgnx-pkg-generations)) (current (drgnx-pkg-current-generation)))
      (setq n (or n (car (seq-find (lambda (g) (and current (< (car g) current))) gens))
                  (drgnx-pkg--error "no generation before %s to roll back to" (or current "the current one"))))
      (unless (assq n gens) (drgnx-pkg--error "no generation %d (have: %s)" n (mapconcat (lambda (g) (number-to-string (car g))) gens " ")))
      (let ((dir (drgnx-pkg--generation-dir n)) (staging (drgnx-pkg--staging)))
        (when (file-exists-p staging) (delete-directory staging t))
        (drgnx-pkg--copy-dir (expand-file-name "elpa" dir) staging)
        (drgnx-pkg--swap-in staging)
        (let ((lock (expand-file-name "drgnx.lock.eld" dir)))
          (if (file-exists-p lock) (copy-file lock (drgnx-pkg-lock-file) t)
            (when (file-exists-p (drgnx-pkg-lock-file)) (delete-file (drgnx-pkg-lock-file)))))
        (drgnx-pkg--set-current n)
        n))))

;;;; Installing

(defun drgnx-pkg--entry-desc (name entry)
  "A package-desc for the lock ENTRY of NAME (installing from the cache)."
  (package-desc-create :name name :version (version-to-list (plist-get entry :version))
                       :summary (or (plist-get entry :summary) "")
                       :reqs (mapcar (lambda (r) (list (car r) (version-to-list (cadr r)))) (plist-get entry :requires))
                       :kind (or (plist-get entry :kind) 'tar) :archive (plist-get entry :archive)))

(defun drgnx-pkg--desc-entry (desc file sha)
  "The lock entry of DESC, installed from FILE with hash SHA."
  (cons (package-desc-name desc)
        (list :version (package-version-join (package-desc-version desc))
              :archive (package-desc-archive desc) :kind (package-desc-kind desc)
              :file file :sha256 sha
              :requires (mapcar (lambda (r) (list (car r) (package-version-join (cadr r))))
                                (seq-remove (lambda (r) (eq (car r) 'emacs)) (package-desc-reqs desc)))
              :summary (package-desc-summary desc))))

(defun drgnx-pkg--file (desc) (concat (package-desc-full-name desc) (package-desc-suffix desc)))
(defun drgnx-pkg--cached (desc) (expand-file-name (drgnx-pkg--file desc) (drgnx-package-cache-dir)))

(defvar url-http-response-status)
(defvar url-http-end-of-headers)

(defun drgnx-pkg--http-get (url file)
  "Save URL's body to FILE; an answer other than 200 is an error (never saved as a package)."
  (let ((buf (url-retrieve-synchronously url t t 120)))
    (unless buf (error "no answer from %s" url))
    (unwind-protect
        (with-current-buffer buf
          (unless (eql url-http-response-status 200) (error "%s answered %s" url url-http-response-status))
          (let ((coding-system-for-write 'binary))
            (write-region (1+ url-http-end-of-headers) (point-max) file nil 'silent)))
      (kill-buffer buf))))

(defun drgnx-pkg--fetch (desc want)
  "DESC's file from its archive into the cache — checked (status, lock hash WANT, signature where the
archive signs) before it enters the cache; the cached path.  Any failure is a `drgnx-pkg-error'."
  (let* ((file (drgnx-pkg--file desc)) (base (package-archive-base desc))
         (cache (drgnx-pkg--cached desc)) (tmp (concat cache ".part")))
    (make-directory (drgnx-package-cache-dir) t)
    (unwind-protect                                     ; whatever stops it (an error, C-g): no .part left
        (condition-case err
            (progn
              (if (file-name-absolute-p base) (copy-file (expand-file-name file base) tmp t)
                (drgnx-pkg--http-get (concat base file) tmp))
              (when (and want (not (equal (drgnx-pkg--sha256 tmp) want)))
                (error "its sha256 is %s, the lock says %s" (drgnx-pkg--sha256 tmp) want))
              (when (and (package-check-signature) (not (member (package-desc-archive desc) package-unsigned-archives)))
                (package--check-signature base file (drgnx-pkg--bytes tmp)))
              (rename-file tmp cache t)
              cache)
          (error (drgnx-pkg--error "%s: download failed (%s) — nothing was changed" file (error-message-string err))))
      (ignore-errors (delete-file tmp)))))

(defvar drgnx-pkg--warnings nil
  "What a sync reports without failing (files that did not compile): strings, newest first.")

(defun drgnx-pkg--warn (fmt &rest args) (push (apply #'format fmt args) drgnx-pkg--warnings))

(defun drgnx-pkg--unpack (desc file)
  "Install DESC from the package FILE into `package-user-dir' (byte-compiled; no native code yet).  A
file that does not byte-compile is a warning (the package runs it uncompiled)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    ;; Third-party compiler warnings are not the user's to fix: kept out of the sync's output.
    (let ((save-silently t) (package-native-compile nil) (byte-compile-warnings nil)
          (compile (symbol-function 'byte-compile-file)))
      (cl-letf (((symbol-function 'byte-compile-file)
                 (lambda (f &rest args)
                   (let ((r (apply compile f args)))
                     (unless r                        ; nil: it did not compile
                       (drgnx-pkg--warn "%s: %s does not byte-compile (it runs uncompiled)"
                                        (package-desc-full-name desc) (file-name-nondirectory f)))
                     r))))
        (package-unpack desc)))))

(defun drgnx-pkg--install (desc lock-entry)
  "Install DESC from the cache, else from its archive, checking the lock's hash.  Returns its new lock
entry.  Every failure is a `drgnx-pkg-error' (the caller drops the staging directory); a file that
fails its hash or does not install is removed from the cache."
  (let* ((file (drgnx-pkg--file desc)) (cached (drgnx-pkg--cached desc))
         (want (and (equal (plist-get lock-entry :version) (package-version-join (package-desc-version desc)))
                    (plist-get lock-entry :sha256))))
    (unless (file-exists-p cached)
      (unless (package-desc-archive desc) (drgnx-pkg--error "%s is not in the cache" file))
      (drgnx-pkg--fetch desc want))
    (let ((sha (drgnx-pkg--sha256 cached)))
      (when (and want (not (equal sha want)))
        (delete-file cached)
        (drgnx-pkg--error "%s: its sha256 is %s, the lock says %s — refusing (a changed file or a tampered cache; removed from the cache)"
                          file sha want))
      (condition-case err (drgnx-pkg--unpack desc cached)
        (error (ignore-errors (delete-file cached))
               (drgnx-pkg--error "%s does not install (%s); removed from the cache — nothing was changed"
                                 file (error-message-string err))))
      (drgnx-pkg--desc-entry desc file sha))))

(defun drgnx-pkg--installed-desc (name) (car (alist-get name package-alist)))

(defun drgnx-pkg--installed-version (name)
  (when-let* ((d (drgnx-pkg--installed-desc name))) (package-version-join (package-desc-version d))))

(defun drgnx-pkg--drop-other-versions (desc)
  "Delete every installed version of DESC's package but DESC's (in the staging directory)."
  (dolist (d (cdr (assq (package-desc-name desc) package-alist)))
    (unless (equal (package-desc-version d) (package-desc-version desc))
      (package-delete d t t))))

(defun drgnx-pkg--lock-order (lock)
  "LOCK's entries, every package after the packages it requires."
  (let (done out)
    (cl-labels ((visit (name)
                  (unless (memq name done)
                    (push name done)
                    (when-let* ((e (assq name lock)))
                      (dolist (r (plist-get (cdr e) :requires)) (visit (car r)))
                      (push e out)))))
      (mapc (lambda (e) (visit (car e))) lock))
    (nreverse out)))

(defun drgnx-pkg--seed (from)
  "Copy the packages of the directory FROM (another Emacs's elpa) into `package-user-dir'."
  (dolist (d (directory-files from t "\\`[^.]"))
    (when (and (file-directory-p d) (directory-files d nil "-pkg\\.el\\'")
               (not (file-exists-p (expand-file-name (file-name-nondirectory d) package-user-dir))))
      (drgnx-pkg--copy-dir d (expand-file-name (file-name-nondirectory d) package-user-dir)))))

(defun drgnx-pkg-eln-dir () (expand-file-name "eln-cache/" (drgnx-data-dir)))

(defun drgnx-pkg--native-compile (dirs)
  "Compile every Lisp file of DIRS to native code, one at a time (memory stays bounded), into drgnx's
own eln cache — the first place sessions look (drgnx-pkg-activate), never another Emacs's.  DIRS are
in the packages directory itself: an .eln's name hashes its source's path."
  (when (and drgnx-pkg-native-compile (fboundp 'native-compile))
    (dolist (dir dirs)
      (dolist (f (directory-files dir t "\\`[^.].*\\.el\\'"))
        (unless (string-match-p "-\\(pkg\\|autoloads\\)\\.el\\'" f)
          (condition-case err (let ((native-comp-eln-load-path (cons (drgnx-pkg-eln-dir) native-comp-eln-load-path)))
                                (native-compile f))
            (error (drgnx-pkg--warn "%s: %s does not compile to native code (%s; it runs byte-compiled)"
                                    (file-name-nondirectory (directory-file-name dir)) (file-name-nondirectory f)
                                    (error-message-string err)))))))))

(defun drgnx-pkg-quickstart-file () (expand-file-name "drgnx-quickstart.el" (drgnx-elpa-dir)))

(defun drgnx-pkg--quickstart ()
  "Write the activation file of the packages directory (sessions load it instead of scanning)."
  (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil) (package-directory-list nil)
        (package-quickstart-file (drgnx-pkg-quickstart-file)))
    (package-load-all-descriptors)
    (package-quickstart-refresh)))

(defun drgnx-pkg--required-version (name descs)
  "The highest version of NAME that DESCS or the installed packages require, or nil."
  (let (v)
    (dolist (d (append descs (mapcar #'cadr package-alist)))
      (unless (eq (package-desc-name d) name)
        (when-let* ((r (assq name (package-desc-reqs d))))
          (when (or (null v) (version-list-< v (cadr r))) (setq v (cadr r))))))
    v))

(defun drgnx-pkg--pinned-desc (name pin)
  "A desc for the locked version PIN of NAME: the cache's file, or the archive's when it has that version."
  (let ((v (version-to-list (plist-get pin :version))))
    (or (seq-find (lambda (d) (equal (package-desc-version d) v)) (alist-get name package-archive-contents))
        (and (plist-get pin :file) (file-exists-p (expand-file-name (plist-get pin :file) (drgnx-package-cache-dir)))
             (drgnx-pkg--entry-desc name pin)))))

(defun drgnx-pkg--plan (manifest lock offline upgrade missing)
  "The packages to install, dependencies first: descs.  What cannot be had goes on MISSING (a cons
whose car is the alist NAME → reason)."
  (let (plan)
    (cl-flet ((miss (name why) (unless (assq name (car missing)) (push (cons name why) (car missing))))
              (add (desc) (unless (seq-find (lambda (d) (eq (package-desc-name d) (package-desc-name desc))) plan)
                            (setq plan (append plan (list desc))))))
      (if offline
          (progn
            (dolist (name manifest)
              (unless (or (assq name lock) (drgnx-pkg--installed-desc name) (package-built-in-p name))
                (miss name "not in the lock — sync online once")))
            (dolist (e (drgnx-pkg--lock-order lock))
              (unless (equal (drgnx-pkg--installed-version (car e)) (plist-get (cdr e) :version))
                (if (file-exists-p (expand-file-name (or (plist-get (cdr e) :file) "") (drgnx-package-cache-dir)))
                    (add (drgnx-pkg--entry-desc (car e) (cdr e)))
                  (miss (car e) (format "%s %s is not in the cache" (car e) (plist-get (cdr e) :version)))))))
        ;; The lock decides installed versions (unless upgrading).
        (unless upgrade
          (dolist (e (drgnx-pkg--lock-order lock))
            (when (and (drgnx-pkg--installed-desc (car e))
                       (not (equal (drgnx-pkg--installed-version (car e)) (plist-get (cdr e) :version))))
              (if-let* ((d (drgnx-pkg--pinned-desc (car e) (cdr e)))) (add d)
                (miss (car e) (format "the lock pins %s; no archive or cache has it (drgnx upgrade takes the archives' version)"
                                      (plist-get (cdr e) :version)))))))
        ;; Each manifest package on its own: one that cannot be resolved does not stop the others.
        (dolist (name manifest)
          (let ((want (list name)))
            (when-let* ((newest (and upgrade (car (alist-get name package-archive-contents))))
                        (inst (drgnx-pkg--installed-desc name)))
              (when (version-list-< (package-desc-version inst) (package-desc-version newest))
                (setq want (list name (package-desc-version newest)))))
            (condition-case err
                (dolist (desc (package-compute-transaction nil (list want)))
                  (add desc))
              (error (miss name (error-message-string err))))))
        (when upgrade                                   ; installed packages outside the manifest too
          (pcase-dolist (`(,name . ,descs) package-alist)
            (when-let* ((newest (car (alist-get name package-archive-contents))))
              (when (version-list-< (package-desc-version (car descs)) (package-desc-version newest))
                (condition-case err
                    (dolist (desc (package-compute-transaction nil (list (list name (package-desc-version newest)))))
                      (add desc))
                  (error (miss name (error-message-string err))))))))
        ;; Pins: the locked version, unless something needs a newer one.
        (unless upgrade
          (setq plan
                (delq nil
                      (mapcar (lambda (desc)
                                (let* ((name (package-desc-name desc)) (pin (alist-get name lock)))
                                  (if (or (null pin) (equal (plist-get pin :version) (package-version-join (package-desc-version desc))))
                                      desc
                                    (let ((need (drgnx-pkg--required-version name plan)))
                                      (cond ((and need (version-list-< (version-to-list (plist-get pin :version)) need))
                                             (miss name (format "the lock pins %s, but %s is needed — drgnx upgrade moves the lock"
                                                                (plist-get pin :version) (package-version-join need)))
                                             nil)
                                            ((drgnx-pkg--pinned-desc name pin))
                                            (t (miss name (format "the lock pins %s; no archive or cache has it (drgnx upgrade takes the archives' version)"
                                                                  (plist-get pin :version)))
                                               nil))))))
                              plan)))))
      ;; Nothing whose dependency cannot be had.
      (let (out)
        (dolist (desc plan)
          (if-let* ((dep (seq-find (lambda (r) (assq (car r) (car missing))) (package-desc-reqs desc))))
              (miss (package-desc-name desc) (format "needs %s, which cannot be installed" (car dep)))
            (push desc out)))
        (nreverse out)))))

(defun drgnx-pkg--forget-wants (installed)
  "Drop INSTALLED (names) from the packages use-package :ensure asked for."
  (let* ((file (drgnx-pkg-wanted-file)) (old (ignore-errors (drgnx-pkg--read-file file))))
    (when (seq-intersection old installed)
      (with-temp-file file (prin1 (seq-difference old installed) (current-buffer))))))

(cl-defun drgnx-pkg-sync (&key (archives nil archives-given) offline upgrade seed modules-dir)
  "Install the manifest into the packages directory.  ARCHIVES: alist (NAME . URL-or-DIR) — when not
given, `drgnx-pkg-archives'; nil: none; OFFLINE: only the lock and the cache; UPGRADE: the archives'
newest versions, not the lock's; SEED: a directory of installed packages to copy first (another
Emacs's elpa); MODULES-DIR: where modules live.  Returns (:ok :installed :missing :generation :warnings).
A failed download or install, a hash mismatch, a busy or unreadable lock is a `drgnx-pkg-error' and
changes nothing; packages that cannot be had are reported (the rest is installed, the lock kept)."
  (let* ((lock (drgnx-pkg-read-lock))               ; unreadable → error before anything changes
         (manifest (drgnx-pkg-manifest modules-dir))
         (staging (drgnx-pkg--staging))
         (missing (list nil)) (drgnx-pkg--warnings nil) installed new-entries generation)
    (drgnx-pkg--with-sync-lock
      (drgnx-pkg--recover)
      (drgnx-pkg--sweep)
      (unwind-protect
          (let ((package-user-dir staging) (package-directory-list nil)
                (package-archives (cond (offline nil) (archives-given archives) (t (drgnx-pkg-archives))))
                (package-gnupghome-dir (expand-file-name "gnupg" (drgnx-data-dir)))
                (package-alist nil) (package-archive-contents nil) (package--initialized t)
                (package-pinned-packages nil)
                ;; package-delete refreshes or deletes the quickstart file: never another Emacs's
                (package-quickstart nil) (package-quickstart-file (expand-file-name "unused-quickstart.el" staging)))
            (when (file-exists-p staging) (delete-directory staging t))
            (if (file-directory-p (drgnx-elpa-dir)) (drgnx-pkg--copy-dir (drgnx-elpa-dir) staging) (make-directory staging t))
            (when seed (drgnx-pkg--seed (expand-file-name seed)))
            (package-load-all-descriptors)
            (when package-archives (package-refresh-contents))
            (dolist (desc (drgnx-pkg--plan manifest lock offline upgrade missing))
              (let ((entry (drgnx-pkg--install desc (alist-get (package-desc-name desc) lock))))
                (drgnx-pkg--drop-other-versions desc)
                (push entry new-entries) (push (package-desc-name desc) installed)))
            ;; Everything arrived: the new directory goes in, without package.el's copy of the
            ;; archives' contents (fetched again by the next sync).
            (dolist (f '("archives" "unused-quickstart.el" "unused-quickstart.elc"))
              (let ((p (expand-file-name f staging)))
                (cond ((file-directory-p p) (delete-directory p t)) ((file-exists-p p) (delete-file p)))))
            (drgnx-pkg--swap-in staging))
        (when (file-exists-p staging) (delete-directory staging t)))
      (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil) (package-directory-list nil))
        (package-load-all-descriptors)
        (drgnx-pkg--native-compile (delq nil (mapcar (lambda (n) (when-let* ((d (drgnx-pkg--installed-desc n))) (package-desc-dir d)))
                                                     installed)))
        (drgnx-pkg--quickstart)
        (drgnx-pkg--forget-wants installed)
        (unless (car missing)
          (drgnx-pkg-write-lock
           (mapcar (lambda (p)
                     (or (assq (car p) new-entries)
                         (let ((old (assq (car p) lock)) (d (cadr p)))
                           (if (and old (equal (plist-get (cdr old) :version) (package-version-join (package-desc-version d))))
                               old
                             (drgnx-pkg--desc-entry d nil nil)))))   ; seeded, or installed by hand
                   package-alist))
          (setq generation (drgnx-pkg-snapshot (if upgrade "upgrade" "sync"))))))
    (list :ok (null (car missing)) :installed (nreverse installed) :missing (nreverse (car missing))
          :generation generation :warnings (reverse drgnx-pkg--warnings))))

;;;; Upgrade with a smoke test

(defun drgnx-pkg--smoke-features (manifest)
  "The packages of MANIFEST installed in the packages directory with a file of their own name."
  (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil) (package-directory-list nil))
    (package-load-all-descriptors)
    (seq-filter (lambda (name)
                  (when-let* ((d (drgnx-pkg--installed-desc name)))
                    (file-exists-p (expand-file-name (format "%s.el" name) (package-desc-dir d)))))
                manifest)))

(defun drgnx-pkg-smoke (manifest)
  "The default smoke test: a fresh Emacs activates the packages directory (its quickstart file, not any
other Emacs's) and loads every package of MANIFEST that has a file of its name.  nil when it works,
else its output."
  (let ((form `(progn (setq package-user-dir ,(drgnx-elpa-dir) package-directory-list nil
                            package-quickstart t package-quickstart-file ,(drgnx-pkg-quickstart-file))
                      (package-activate-all)
                      (dolist (p ',(drgnx-pkg--smoke-features manifest)) (require p)))))
    (with-temp-buffer
      (let ((rc (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                              "--batch" "-Q" "--eval" "(require 'package)" "--eval" (prin1-to-string form))))
        (unless (eql rc 0) (string-trim (buffer-string)))))))

(cl-defun drgnx-pkg-upgrade (&key archives smoke modules-dir)
  "Snapshot, upgrade every package to the archives' newest, then run SMOKE (default `drgnx-pkg-smoke';
called with the manifest, nil means it works).  If the upgrade or the smoke test fails, the snapshot
comes back.  One lock held throughout.  Returns (:ok :generation :restored :smoke :missing :error)."
  (drgnx-pkg--with-sync-lock
    (drgnx-pkg--recover)
    (let* ((before (drgnx-pkg-snapshot "before upgrade"))
           (r (condition-case err (drgnx-pkg-sync :archives archives :upgrade t :modules-dir modules-dir)
                (drgnx-pkg-error (list :ok nil :error (cadr err)))))
           (failure (and (plist-get r :ok)
                         (condition-case err (funcall (or smoke #'drgnx-pkg-smoke) (drgnx-pkg-manifest modules-dir))
                           (error (error-message-string err))))))
      (if (and (plist-get r :ok) (not failure))
          (list :ok t :generation (plist-get r :generation) :warnings (plist-get r :warnings))
        (drgnx-pkg-rollback before)
        (when-let* ((g (plist-get r :generation))) (delete-directory (drgnx-pkg--generation-dir g) t))
        (list :ok nil :smoke failure :missing (plist-get r :missing) :error (plist-get r :error) :restored before)))))

;;;; Bisect

(cl-defun drgnx-pkg-bisect (fails &key modules-dir)
  "Find the module that makes FAILS true: FAILS is called with a configuration directory (a copy of
the user's, whose modules.eld turns some modules off) and returns non-nil when the problem shows.
Halves the enabled modules each round.  Returns the module, or `:not-a-module' when the problem shows
with every module off.  The user's own files are never changed."
  (let* ((user (drgnx-user-dir))
         (state (or (drgnx-pkg--read-file (expand-file-name "modules.eld" user)) (list :version 1)))
         (off (plist-get state :disabled))
         (candidates (seq-remove (lambda (m) (memq m off))
                                 (append (mapcar #'car (drgnx-pkg--module-packages
                                                        (or modules-dir (expand-file-name "modules" drgnx-dir))))
                                         ;; external modules (modules.eld :external): turned off as external/NAME
                                         (mapcar (lambda (e) (intern (format "external/%s" (plist-get e :name))))
                                                 (plist-get state :external)))))
         (tmp (make-temp-file "drgnx-bisect" t)))
    (cl-flet ((try (on)
                (delete-directory tmp t)
                (if (file-directory-p user) (copy-directory user tmp nil t t) (make-directory tmp t))
                (drgnx-pkg--write-file (expand-file-name "modules.eld" tmp) "drgnx bisect"
                                       (plist-put (copy-sequence state) :disabled
                                                  (append off (seq-difference candidates on))))
                (funcall fails tmp)))
      (unwind-protect
          (progn
            (unless (try candidates) (drgnx-pkg--error "the problem does not show with your modules on; nothing to bisect"))
            (if (try nil) :not-a-module
              (let ((set candidates))
                (while (cdr set)
                  (let ((half (seq-take set (/ (length set) 2))))
                    (setq set (if (try half) half (seq-drop set (length half))))))
                (car set))))
        (delete-directory tmp t)))))

;;;; The service unit

(defun drgnx-pkg--systemd-word (s)
  "S as one word of a systemd ExecStart= line: % and $ doubled (no specifiers, no variables), and in
double quotes, with \\ and \" escaped, when it has spaces or quotes."
  (let ((s (replace-regexp-in-string "[%$]" (lambda (m) (concat m m)) s t t)))
    (if (string-match-p "[[:space:]\"'\\;]" s)
        (concat "\"" (replace-regexp-in-string "[\"\\]" (lambda (m) (concat "\\" m)) s t t) "\"")
      s)))

(defun drgnx-pkg-service-unit (&optional dir)
  "The systemd user unit that runs drgnx as a daemon — with the Emacs running this (bin/drgnx:
$DRGNX_EMACS); written to DIR/drgnx.service when DIR is given.  Never installed or enabled: that is the
user's step (docs/guide/packages.md)."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (unit (concat "[Unit]\nDescription=drgnx (Emacs daemon)\nDocumentation=https://github.com/Black-Dragon-Foundation/drgnx\n\n"
                       "[Service]\nType=notify\n"
                       (format "ExecStart=%s --fg-daemon=drgnx %s\n" (drgnx-pkg--systemd-word emacs)
                               (drgnx-pkg--systemd-word (concat "--init-directory=" (expand-file-name "init" drgnx-dir))))
                       "Restart=on-failure\n\n[Install]\nWantedBy=default.target\n")))
    (when dir
      (make-directory dir t)
      (write-region unit nil (expand-file-name "drgnx.service" dir) nil 'silent))
    unit))

;;;; Status (for the doctor)

(defun drgnx-pkg-status (&optional modules-dir)
  "(:manifest :installed :lock :generations), or (:error MESSAGE)."
  (condition-case err
      (list :manifest (drgnx-pkg-manifest modules-dir)
            :installed (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil) (package-directory-list nil))
                         (when (file-directory-p package-user-dir) (package-load-all-descriptors))
                         (sort (mapcar #'car package-alist) (lambda (a b) (string< a b))))
            :lock (progn (drgnx-pkg-read-lock) (file-exists-p (drgnx-pkg-lock-file)))
            :generations (length (drgnx-pkg-generations)))
    (drgnx-pkg-error (list :error (cadr err)))))

;;;; CLI (bin/drgnx sync | upgrade | rollback | generations | lock | bisect | service-unit)

(defun drgnx-pkg--print (fmt &rest args) (princ (apply #'format fmt args)) (terpri))

(defconst drgnx-pkg--restart-note
  "restart drgnx to use them (a running daemon keeps what it loaded): systemctl --user restart drgnx")

(defun drgnx-pkg--report (r)
  (when (plist-get r :installed)
    (drgnx-pkg--print "installed: %s" (mapconcat #'symbol-name (plist-get r :installed) " ")))
  (pcase-dolist (`(,name . ,why) (plist-get r :missing)) (drgnx-pkg--print "MISSING %s: %s" name why))
  (dolist (w (plist-get r :warnings)) (drgnx-pkg--print "WARNING %s" w))
  (when (plist-get r :generation) (drgnx-pkg--print "generation %d" (plist-get r :generation)))
  (when (plist-get r :error) (drgnx-pkg--print "drgnx: %s" (plist-get r :error)))
  (when (or (plist-get r :installed) (plist-get r :restored)) (drgnx-pkg--print "%s" drgnx-pkg--restart-note)))

(defun drgnx-pkg-cli-run (args)
  "Run the package command ARGS (strings); the exit code."
  (condition-case err
      (pcase args
        (`("sync" . ,flags)
         (let (opts)
           (while flags
             (pcase (pop flags)
               ("--offline" (setq opts (append opts (list :offline t))))
               ("--seed" (setq opts (append opts (list :seed (pop flags)))))
               (f (drgnx-pkg--error "unknown sync option %s (--offline, --seed DIR)" f))))
           (let ((r (apply #'drgnx-pkg-sync opts)))
             (drgnx-pkg--report r)
             (if (plist-get r :ok) 0 1))))
        (`("upgrade")
         (let ((r (drgnx-pkg-upgrade)))
           (drgnx-pkg--report r)
           (when (plist-get r :smoke) (drgnx-pkg--print "the smoke test failed:\n%s" (plist-get r :smoke)))
           (when (plist-get r :restored) (drgnx-pkg--print "restored generation %d" (plist-get r :restored)))
           (if (plist-get r :ok) 0 1)))
        (`("rollback" . ,n)
         (drgnx-pkg--print "generation %d restored" (drgnx-pkg-rollback (and n (string-to-number (car n)))))
         (drgnx-pkg--print "%s" drgnx-pkg--restart-note)
         0)
        (`("generations")
         (pcase-dolist (`(,n . ,info) (drgnx-pkg-generations))
           (drgnx-pkg--print "%3d  %s  %s" n (plist-get info :time) (or (plist-get info :note) "")))
         0)
        (`("lock")
         (drgnx-pkg--print ";; %s" (drgnx-pkg-lock-file))
         (pcase-dolist (`(,name . ,e) (drgnx-pkg-read-lock))
           (drgnx-pkg--print "%-28s %-16s %s" name (plist-get e :version) (or (plist-get e :archive) "(seeded)")))
         0)
        (`("bisect" . ,rest)
         (let* ((cmd (cdr (member "--" rest)))
                (fails (if cmd
                           (lambda (dir)
                             (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment)))
                               (not (eql 0 (apply #'call-process (car cmd) nil nil nil (cdr cmd))))))
                         (lambda (dir)
                           (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment)))
                             (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                           (concat "--init-directory=" (expand-file-name "init" drgnx-dir))))
                           (y-or-n-p "Did the problem show? "))))
                (m (drgnx-pkg-bisect fails)))
           (drgnx-pkg--print (if (eq m :not-a-module) "the problem shows with every module off: not a module (try drgnx safe)"
                               (format "the problem comes with module %s (turn it off in Preferences: Modules)" m)))
           0))
        (`("service-unit" . ,dir)
         (let ((unit (drgnx-pkg-service-unit (car dir))))
           (if dir (drgnx-pkg--print "wrote %s (not installed: see docs/guide/packages.md)" (expand-file-name "drgnx.service" (car dir)))
             (princ unit)))
         0)
        (_ (drgnx-pkg--print "usage: drgnx sync [--offline] [--seed DIR] | upgrade | rollback [N] | generations | lock | bisect [-- CMD…] | service-unit [DIR]")
           2))
    (drgnx-pkg-error (drgnx-pkg--print "drgnx: %s" (cadr err)) 1)
    (error (drgnx-pkg--print "drgnx: unexpected error: %s" (error-message-string err)) 1)))

(defun drgnx-pkg-cli ()
  "bin/drgnx's package commands: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-pkg-cli-run args))))

(provide 'drgnx-pkg)
;;; drgnx-pkg.el ends here
