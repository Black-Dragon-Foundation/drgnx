;;; drgnx-pkg.el --- Packages: manifest, lock, sync, cache, generations, upgrade -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Packages are installed by `drgnx sync' only, never by a session.  The manifest is every enabled
;; module's :packages, packages.eld's :packages and what use-package :ensure asked for in a session
;; (recorded there, not installed).  sync resolves it with package.el against the archives — or,
;; offline, against the lock and the cache — installing into a staging copy of the packages
;; directory; only when every file arrived with the right hash is the copy swapped in, the lock
;; (drgnx.lock.eld) written and a generation (a snapshot of the directory) made.  Rollback copies a
;; generation back into the same real path, so natively compiled files stay valid.  A first sync (no
;; lock yet) starts from the known-good lock drgnx ships, etc/drgnx.lock.eld.  This file runs
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

(defconst drgnx-pkg-default-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1))
  "Archive priorities when packages.eld has no :archive-priorities: releases over MELPA's snapshots.  package.el
still takes a lower priority archive's package when only it satisfies a requirement.")

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

(defun drgnx-pkg--module-specs (dir)
  "Alist MODULE → (:packages LIST :default on|off) of every `drgnx-module-define' in DIR's files.
Read, never run."
  (let (out)
    (dolist (file (and (file-directory-p dir) (directory-files-recursively dir "\\.el\\'")))
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (while t
              (pcase (read (current-buffer))
                (`(drgnx-module-define (quote ,(and (pred symbolp) name)) . ,args)
                 ;; :default counts only as the literal 'off (read, never evaluated)
                 (push (list name :packages (pcase (plist-get args :packages) (`(quote ,l) l))
                             :default (pcase (plist-get args :default) (`(quote off) 'off) (_ 'on)))
                       out))))
          (error nil))))                                ; end of file (or a file that does not read)
    (nreverse out)))

(defun drgnx-pkg--module-packages (dir)
  "Alist MODULE → packages of every `drgnx-module-define' in DIR's files — read, never run."
  (mapcar (lambda (m) (cons (car m) (plist-get (cdr m) :packages))) (drgnx-pkg--module-specs dir)))

(defun drgnx-pkg--packages-eld () (drgnx-pkg--read-file (expand-file-name "packages.eld" (drgnx-user-dir))))

(defun drgnx-pkg-manifest (&optional modules-dir)
  "The packages drgnx needs, sorted: every enabled module's :packages (MODULES-DIR, default drgnx's
modules/; one that is off until chosen counts once modules.eld :enabled lists it), packages.eld's
:packages and :git, and those use-package :ensure asked for in a session."
  (let ((names (append (seq-mapcat (lambda (m) (plist-get (cdr m) :packages))
                                   (seq-remove (lambda (m) (drgnx-module-disabled-p (car m) (plist-get (cdr m) :default)))
                                               (drgnx-pkg--module-specs
                                                (or modules-dir (expand-file-name "modules" drgnx-dir)))))
                       (plist-get (drgnx-pkg--packages-eld) :packages)
                       (mapcar #'car (plist-get (drgnx-pkg--packages-eld) :git))
                       (ignore-errors (drgnx-pkg--read-file (drgnx-pkg-wanted-file))))))
    (sort (delete-dups (seq-filter #'symbolp names)) (lambda (a b) (string< a b)))))

(defun drgnx-pkg-archives ()
  "The archives: packages.eld's :archives, else `drgnx-pkg-default-archives'."
  (let ((p (drgnx-pkg--packages-eld)))
    (if (plist-member p :archives) (plist-get p :archives) drgnx-pkg-default-archives)))

(defun drgnx-pkg-archive-priorities ()
  "packages.eld's :archive-priorities when it has the key (even empty: the user's own choice), else
`drgnx-pkg-default-archive-priorities' — unless packages.eld names its own :archives: package.el ranks an archive
not listed below every listed one, so the default would put theirs under MELPA.  Their ranking is theirs to say.
A value that is not an alist (ARCHIVE-NAME . NUMBER) is a `drgnx-pkg-error'."
  (let ((p (drgnx-pkg--packages-eld)))
    (cond ((plist-member p :archive-priorities)
           (let ((v (plist-get p :archive-priorities)))
             (unless (and (listp v) (seq-every-p (lambda (x) (and (consp x) (stringp (car x)) (numberp (cdr x)))) v))
               (drgnx-pkg--error "packages.eld: :archive-priorities must be an alist of (\"archive-name\" . NUMBER), e.g. ((\"gnu\" . 3) (\"melpa\" . 1))"))
             v))
          ((plist-member p :archives) nil)
          (t drgnx-pkg-default-archive-priorities))))

;;;; Lock

(defun drgnx-pkg-lock-file () (expand-file-name "drgnx.lock.eld" (drgnx-user-dir)))

(defun drgnx-pkg--read-lock-file (file)
  "The entries of the lock FILE, nil when there is none; one that is not a lock is a `drgnx-pkg-error'."
  (let ((data (drgnx-pkg--read-file file)))
    (cond ((null data) nil)
          ((and (eql (plist-get data :version) 1) (listp (plist-get data :packages))) (plist-get data :packages))
          (t (drgnx-pkg--error "%s is not a drgnx lock (version 1)" file)))))

(defun drgnx-pkg-read-lock ()
  "The lock: entries (NAME :version :archive :kind :file :sha256 :size :requires :summary), sorted; nil when
there is none.  An unreadable lock is a `drgnx-pkg-error' (never silently replaced)."
  (drgnx-pkg--read-lock-file (drgnx-pkg-lock-file)))

(defun drgnx-pkg--write-lock-file (file header entries &optional marks)
  "ENTRIES as the lock FILE, after the comment HEADER; MARKS: more of its plist (:from-shipped t)."
  (drgnx-pkg--write-file file header (append (list :version 1) marks
                                             (list :packages (sort (copy-sequence entries)
                                                                   (lambda (a b) (string< (car a) (car b))))))))

(defun drgnx-pkg-write-lock (entries)
  (drgnx-pkg--write-lock-file (drgnx-pkg-lock-file) "drgnx package lock — written by drgnx sync; commit it with your config"
                              entries))

(defvar drgnx-pkg-shipped-lock nil
  "The known-good lock drgnx ships (a file), which a first sync starts from; nil: etc/drgnx.lock.eld in drgnx.")

(defun drgnx-pkg-shipped-lock-file ()
  (or drgnx-pkg-shipped-lock (expand-file-name "etc/drgnx.lock.eld" drgnx-dir)))

(defun drgnx-pkg--start-from-shipped-lock ()
  "With no lock yet (a new user), the shipped lock becomes the user's (written whole, atomically), marked
:from-shipped until a sync writes it: its pins are soft then (`drgnx-pkg-sync')."
  (when (and (not (file-exists-p (drgnx-pkg-lock-file))) (file-exists-p (drgnx-pkg-shipped-lock-file)))
    (drgnx-pkg--write-lock-file (drgnx-pkg-lock-file)
                                "drgnx package lock — copied from the one drgnx ships; the first drgnx sync completes it"
                                (drgnx-pkg--read-lock-file (drgnx-pkg-shipped-lock-file)) '(:from-shipped t))))

(defun drgnx-pkg--shipped-extras (lock)
  "The shipped lock's entries for packages that LOCK (the user's) lacks and that are not installed: the soft
pins of a module turned on after the first sync.  An installed package the lock lacks (by hand) is the user's."
  (seq-remove (lambda (e) (or (assq (car e) lock) (drgnx-pkg--installed-desc (car e))))
              (drgnx-pkg--read-lock-file (drgnx-pkg-shipped-lock-file))))

(defun drgnx-pkg--lock-from-shipped-p ()
  "Is the user lock still the shipped one, copied by a first sync that has not completed?"
  (plist-get (ignore-errors (drgnx-pkg--read-file (drgnx-pkg-lock-file))) :from-shipped))

(defun drgnx-pkg--lock-closure (names lock &optional with-built-ins)
  "NAMES that LOCK has, and every package their entries require that LOCK has too — not one a built-in package
satisfies at the version required (package.el would not install it either), unless WITH-BUILT-INS."
  (let (out)
    (cl-labels ((visit (name &optional min)
                  (when (and (assq name lock) (not (memq name out))
                             (not (and min (not with-built-ins) (package-built-in-p name min))))
                    (push name out)
                    (dolist (r (plist-get (alist-get name lock) :requires)) (visit (car r) (version-to-list (cadr r)))))))
      (mapc #'visit names))
    out))

(defun drgnx-pkg--beyond-lock (names lock)
  "What the LOCK entries of NAMES require that LOCK does not have and no built-in package satisfies: ((NAME .
VERSION-LIST)…), the highest version required of each."
  (let (out)
    (dolist (name names)
      (dolist (r (plist-get (alist-get name lock) :requires))
        (let ((n (car r)) (v (version-to-list (cadr r))))
          ;; a Git-sourced name is not in the archives: it installs from its source, so it is inside the lock
          (unless (or (eq n 'emacs) (assq n lock) (drgnx-pkg-git-source n) (package-built-in-p n v))
            (when (or (not (assq n out)) (version-list-< (alist-get n out) v))
              (setf (alist-get n out) v))))))
    (nreverse out)))

(defun drgnx-pkg-ship-lock (&optional modules-dir)
  "Write the shipped lock from the user lock (maintainers: `drgnx lock --ship'): the entries of every module's
packages in MODULES-DIR (default drgnx's modules/; on or off — every preset) and of what they need.  A lock
that lacks one of them is a `drgnx-pkg-error' and nothing is written."
  (let* ((lock (or (drgnx-pkg-read-lock) (drgnx-pkg--error "no lock (%s): run drgnx sync first" (drgnx-pkg-lock-file))))
         (wanted (delete-dups (seq-filter #'symbolp (seq-mapcat #'cdr (drgnx-pkg--module-packages
                                                                       (or modules-dir (expand-file-name "modules" drgnx-dir)))))))
         (lacking (seq-remove (lambda (n) (assq n lock)) wanted)))
    (when lacking
      (drgnx-pkg--error "the lock lacks %s: turn every module on (drgnx onboard --non-interactive --preset full-ai), run drgnx sync, then ship"
                        (mapconcat #'symbol-name (sort lacking (lambda (a b) (string< a b))) " ")))
    (let* ((names (drgnx-pkg--lock-closure wanted lock t))     ; built-ins too: a user's Emacs may be older
           (unchecked (seq-filter (lambda (n) (let ((e (alist-get n lock)))
                                                (not (plist-get e (if (eq (plist-get e :kind) 'git) :commit :sha256)))))
                                  names)))
      (when unchecked                                   ; a new user would install them unchecked
        (drgnx-pkg--error "%s have no hash or commit in the lock (seeded or installed by hand): sync them from an archive or Git, then ship"
                          (mapconcat #'symbol-name (sort unchecked (lambda (a b) (string< a b))) " ")))
      (drgnx-pkg--write-lock-file (drgnx-pkg-shipped-lock-file)
                                  "drgnx's known-good package lock — a first drgnx sync installs these; maintainers: drgnx lock --ship"
                                  (seq-filter (lambda (e) (memq (car e) names)) lock)))))

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

(defun drgnx-pkg--desc-entry (desc file sha &optional size)
  "The lock entry of DESC, installed from FILE with hash SHA, SIZE bytes (what onboarding says it downloads).
An archive that carries the commit DESC was built from and its repository (MELPA's archive-contents do) has them
recorded as :commit and :url: what `drgnx-pkg--restore-prepare' needs once the archive no longer serves that version."
  (let ((extras (package-desc-extras desc)))
    (cons (package-desc-name desc)
          (append (list :version (package-version-join (package-desc-version desc))
                        :archive (package-desc-archive desc) :kind (package-desc-kind desc)
                        :file file :sha256 sha :size size
                        :requires (mapcar (lambda (r) (list (car r) (package-version-join (cadr r))))
                                          (seq-remove (lambda (r) (eq (car r) 'emacs)) (package-desc-reqs desc)))
                        :summary (package-desc-summary desc))
                  (and (drgnx-pkg--full-commit-p (alist-get :commit extras)) (alist-get :url extras)
                       (list :commit (alist-get :commit extras) :url (alist-get :url extras)))))))

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

(defvar drgnx-pkg-verbose nil
  "Non-nil: a sync says what it is doing, a line per package (on stderr; `drgnx sync' — onboarding shows the last one).")

(defun drgnx-pkg--progress (fmt &rest args) (when drgnx-pkg-verbose (apply #'message fmt args)))

(defun drgnx-pkg--unpack (desc file)
  "Install DESC from the package FILE into `package-user-dir' (byte-compiled; no native code yet).  A
file that does not byte-compile is a warning (the package runs it uncompiled)."
  ;; Loaded first: the wrapper below calls, and afterwards puts back, the real function.  Captured as an autoload,
  ;; the first package's compile loads bytecomp, the autoload comes back and every later call fails (symbolp).
  (require 'bytecomp)
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
      (drgnx-pkg--desc-entry desc file sha (file-attribute-size (file-attributes cached))))))

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
      (drgnx-pkg--progress "compiling %s to native code" (file-name-nondirectory (directory-file-name dir)))
      (dolist (f (directory-files dir t "\\`[^.].*\\.el\\'"))
        ;; compat-NN.el need their siblings at compile time; compat loads one only on an Emacs older than NN
        (unless (or (string-match-p "-\\(pkg\\|autoloads\\)\\.el\\'" f)
                    (and (string-match "/compat-\\([0-9]+\\)\\.el\\'" f)
                         (<= (string-to-number (match-string 1 f)) emacs-major-version)))
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

;;;; Git sources: a package from a repository, pinned to a commit

(defvar drgnx-pkg-git-sources
  '((eglot-booster :url "https://github.com/jdtsmith/eglot-booster" :rev "main"))
  "Packages drgnx's modules use that no archive has: alist NAME → (:url URL :rev REF [:lisp-dir DIR]).  packages.eld's
:git entries (the same shape) come first.")

(defun drgnx-pkg-git-source (name)
  "Where NAME comes from when it comes from Git: (:url :rev [:lisp-dir]), or nil."
  (or (alist-get name (plist-get (drgnx-pkg--packages-eld) :git)) (alist-get name drgnx-pkg-git-sources)))

(defvar drgnx-pkg--git-env nil "More environment (\"VAR=VALUE\"…) for `drgnx-pkg--git'.")

(defconst drgnx-pkg--restore-git-env '("GIT_ALLOW_PROTOCOL=https:file")
  "What a rebuild from an archive's URL runs git with: only https and local directories, whatever the user's git
config allows (no ext::, no ssh:// with their keys).")

(defun drgnx-pkg--git (dir &rest args)
  "git ARGS in DIR, never asking for anything (no terminal, no credential helper, an ssh that never asks):
(EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir))
          (process-environment (append drgnx-pkg--git-env
                                       '("GIT_TERMINAL_PROMPT=0" "GIT_ASKPASS=true" "SSH_ASKPASS=true")
                                       (unless (getenv "GIT_SSH_COMMAND") '("GIT_SSH_COMMAND=ssh -o BatchMode=yes"))
                                       process-environment)))
      (cons (apply #'call-process "git" nil t nil "-c" "credential.helper=" args) (string-trim (buffer-string))))))

(defun drgnx-pkg--git-cache (name) (expand-file-name (format "git/%s/" name) (drgnx-package-cache-dir)))

(defun drgnx-pkg--git-fetch (name src)
  "NAME's clone in the package cache, up to date with SRC's :url (cloned the first time): its directory."
  (let* ((dir (drgnx-pkg--git-cache name)) (url (plist-get src :url)))
    (if (file-directory-p (expand-file-name ".git" dir))
        (progn (pcase (drgnx-pkg--git dir "remote" "set-url" "origin" "--" url)   ; never fetch the old origin instead
                 (`(0 . ,_))
                 (`(,_ . ,err) (drgnx-pkg--error "%s: setting its URL to %s failed: %s" name url err)))
               (pcase (drgnx-pkg--git dir "fetch" "--quiet" "--tags" "--force" "origin" "+refs/heads/*:refs/remotes/origin/*")
                 (`(0 . ,_))
                 (`(,_ . ,err) (drgnx-pkg--error "%s: fetching %s failed: %s" name url err))))
      (make-directory (file-name-directory (directory-file-name dir)) t)
      (pcase (drgnx-pkg--git (file-name-directory (directory-file-name dir)) "clone" "--quiet" "--no-checkout" "--" url
                             (directory-file-name dir))
        (`(0 . ,_))
        (`(,_ . ,err) (drgnx-pkg--error "%s: cloning %s failed: %s" name url err))))
    dir))

(defun drgnx-pkg--git-resolve (dir rev)
  "REV (a branch, a tag or a commit) as a commit of the clone DIR, or nil."
  (seq-some (lambda (r) (pcase (drgnx-pkg--git dir "rev-parse" "--verify" "--quiet" (concat r "^{commit}")) (`(0 . ,sha) sha)))
            (list (concat "origin/" rev) rev)))

(defun drgnx-pkg--git-has-p (dir commit)
  (and (file-directory-p dir) (eql 0 (car (drgnx-pkg--git dir "cat-file" "-e" (concat commit "^{commit}"))))))

(defun drgnx-pkg--git-export (name dir commit)
  "COMMIT of the clone DIR as files in a fresh temporary directory: its path."
  (let ((out (make-temp-file (format "drgnx-git-%s" name) t)))
    (unless (eql 0 (call-process "sh" nil nil nil "-c" (format "git -C %s archive --format=tar %s | tar -x -C %s"
                                                               (shell-quote-argument dir) (shell-quote-argument commit)
                                                               (shell-quote-argument out))))
      (delete-directory out t)
      (drgnx-pkg--error "%s: commit %s could not be read from its clone" name commit))
    (file-name-as-directory out)))

(defun drgnx-pkg--git-desc (name tree dir commit)
  "NAME's package from TREE's NAME.el (version: its header, else 0.0.0.DATE of the commit), a directory package."
  (let ((main (expand-file-name (format "%s.el" name) tree)))
    (unless (file-exists-p main) (drgnx-pkg--error "%s: its source has no %s.el" name name))
    (with-temp-buffer
      (insert-file-contents main)
      (setq buffer-file-name main)
      (goto-char (point-min))
      (unless (re-search-forward "^;+ *\\(Package-\\)?Version *:" nil t)   ; no version: the commit's date (read here only)
        (goto-char (point-min)) (forward-line 1)
        (insert (format ";; Version: 0.0.0.%s\n" (cdr (drgnx-pkg--git dir "log" "-1" "--format=%cd" "--date=format:%Y%m%d" commit)))))
      (let ((d (package-buffer-info)))
        (set-buffer-modified-p nil)
        (setq buffer-file-name nil)
        (setf (package-desc-kind d) 'dir)
        d))))

(defun drgnx-pkg--git-prepare (names lock offline upgrade missing)
  "The Git packages among NAMES to install: ((NAME DESC TREE COMMIT SRC ROOT)…) — the lock's commit (the newest of
:rev when upgrading or not locked), skipped when installed at it.  What cannot be had goes on MISSING."
  (let (out)
    (dolist (name names)
      (condition-case err
          (let* ((src (drgnx-pkg-git-source name)) (pin (alist-get name lock)) (dir (drgnx-pkg--git-cache name))
                 (pinned (and (not upgrade) (eq (plist-get pin :kind) 'git) (equal (plist-get pin :url) (plist-get src :url))
                              (plist-get pin :commit))))
            (cond (offline (unless (and pinned (drgnx-pkg--git-has-p dir pinned))
                             (drgnx-pkg--error "%s: its locked commit is not in the cache — sync online once" name)))
                  ((not (and pinned (drgnx-pkg--git-has-p dir pinned))) (drgnx-pkg--git-fetch name src)))
            (let ((commit (or pinned (drgnx-pkg--git-resolve dir (or (plist-get src :rev) "HEAD"))
                              (drgnx-pkg--error "%s: %s has no %s" name (plist-get src :url) (or (plist-get src :rev) "HEAD")))))
              (unless (and (equal (plist-get pin :commit) commit) (drgnx-pkg--installed-version name)
                           (equal (drgnx-pkg--installed-version name) (plist-get pin :version)))
                (let* ((root (drgnx-pkg--git-export name dir commit))
                       (tree (if (plist-get src :lisp-dir) (file-name-as-directory (expand-file-name (plist-get src :lisp-dir) root)) root)))
                  (condition-case e (push (list name (drgnx-pkg--git-desc name tree dir commit) tree commit src root) out)
                    (error (delete-directory root t) (signal (car e) (cdr e))))))))
        (error (unless (assq name (car missing)) (push (cons name (error-message-string err)) (car missing))))))
    (nreverse out)))

(defun drgnx-pkg--git-unpack (prep)
  "Install the prepared Git package PREP (from `drgnx-pkg--git-prepare') into the packages directory; its export is
deleted.  A package that does not install is a `drgnx-pkg-error'."
  (pcase-let ((`(,name ,desc ,tree ,commit ,_src ,root) prep))
    (unwind-protect
        (condition-case err (let ((default-directory tree)) (drgnx-pkg--unpack desc (expand-file-name (format "%s.el" name) tree)))
          (error (drgnx-pkg--error "%s at %s does not install (%s) — nothing was changed" name (substring commit 0 (min 12 (length commit)))
                                   (error-message-string err))))
      (delete-directory root t))))

(defun drgnx-pkg--git-install (prep)
  "Install the prepared Git package PREP (from `drgnx-pkg--git-prepare'): its lock entry."
  (pcase-let ((`(,name ,desc ,_tree ,commit ,src ,_root) prep))
    (drgnx-pkg--git-unpack prep)
    (drgnx-pkg--drop-other-versions desc)
    (cons name (list :kind 'git :url (plist-get src :url) :rev (plist-get src :rev) :commit commit
                     :version (package-version-join (package-desc-version desc))
                     :requires (mapcar (lambda (r) (list (car r) (package-version-join (cadr r))))
                                       (seq-remove (lambda (r) (eq (car r) 'emacs)) (package-desc-reqs desc)))
                     :summary (package-desc-summary desc)))))

(defvar drgnx-pkg--restored nil
  "While a sync runs: the locked versions it rebuilds from their commits, ((NAME DESC TREE COMMIT SRC ROOT)…) —
`drgnx-pkg--restore-prepare'.  `drgnx-pkg--pinned-desc' answers with their descs.")

(defvar drgnx-pkg--restore-failed nil
  "While a sync runs: why a restore could not be prepared, ((NAME . REASON)…); it ends the package's MISSING reason.")

(defun drgnx-pkg--full-commit-p (commit)
  "Is COMMIT a full object id (40 hex characters, 64 in a SHA-256 repository), not a name or a prefix?"
  (and (stringp commit) (string-match-p "\\`\\(?:[0-9a-f]\\{40\\}\\|[0-9a-f]\\{64\\}\\)\\'" commit)))

(defun drgnx-pkg--restore-prepare (names pins soft-names)
  "Prepare the rebuild from its commit of every locked version of NAMES (and what their PINS require) that no
archive and no cache has any more — the MELPA snapshots that vanish — and that the lock records a :commit and :url
for: the repository is cloned (into the package cache, as a Git source's is) and the commit exported.  The result is
in `drgnx-pkg--restored'; what cannot be rebuilt is in `drgnx-pkg--restore-failed'.  The pins of SOFT-NAMES (the
shipped lock's) are not restored: they fall back to the archive's version.  A pin without a commit is left as it is:
the plan reports it missing."
  (dolist (name (drgnx-pkg--lock-closure names pins))
    (let* ((pin (alist-get name pins)) (commit (plist-get pin :commit)) (url (plist-get pin :url)))
      (when (and commit url (not (eq (plist-get pin :kind) 'git)) (not (memq name soft-names))
                 (not (equal (drgnx-pkg--installed-version name) (plist-get pin :version)))
                 (not (drgnx-pkg--pinned-desc name pin)))
        (condition-case err
            (let* ((src (list :url url :rev commit)) (dir (drgnx-pkg--git-cache name))
                   (drgnx-pkg--git-env (append drgnx-pkg--restore-git-env drgnx-pkg--git-env)))
              ;; the commit is the package's only check (no hash): a full id, and the one the checkout resolves to
              (unless (drgnx-pkg--full-commit-p commit) (drgnx-pkg--error "the lock's commit %s is not a full commit id" commit))
              (unless (or (string-prefix-p "https://" url) (and (file-name-absolute-p url) (file-directory-p url)))
                (drgnx-pkg--error "%s is neither an https URL nor a local directory" url))
              (unless (drgnx-pkg--git-has-p dir commit) (drgnx-pkg--git-fetch name src))
              (unless (and (drgnx-pkg--git-has-p dir commit)
                           (equal (cdr (drgnx-pkg--git dir "rev-parse" "--verify" "--quiet" (concat commit "^{commit}"))) commit))
                (drgnx-pkg--error "%s has no commit %s" url commit))
              (let* ((root (drgnx-pkg--git-export name dir commit))
                     ;; the code at the top, else in lisp/ (as forge, ghub and closql have it; MELPA's default recipe too)
                     (tree (if (and (not (file-exists-p (expand-file-name (format "%s.el" name) root)))
                                    (file-exists-p (expand-file-name (format "lisp/%s.el" name) root)))
                               (expand-file-name "lisp/" root)
                             root)))
                (condition-case e
                    (let ((desc (drgnx-pkg--git-desc name tree dir commit)))
                      ;; the locked version, not the header's (MELPA's are dates): the lock then finds it installed
                      (setf (package-desc-version desc) (version-to-list (plist-get pin :version)))
                      (push (list name desc tree commit src root) drgnx-pkg--restored))
                  (error (delete-directory root t) (signal (car e) (cdr e))))))
          (error (push (cons name (error-message-string err)) drgnx-pkg--restore-failed)))))))

(defun drgnx-pkg--restore-install (prep pin)
  "Install the version PIN locks from the prepared rebuild PREP: PIN, the lock entry as it was (the archive's
version of it, found again on the next sync).  Says so as a warning: the files are the repository's, not the archive's."
  (drgnx-pkg--git-unpack prep)
  (drgnx-pkg--warn "%s: %s is no longer served; rebuilt from its commit %s" (car prep) (plist-get pin :version)
                   (substring (nth 3 prep) 0 (min 12 (length (nth 3 prep)))))
  (cons (car prep) pin))

(defun drgnx-pkg--gone-why (name pin)
  "Why the locked version PIN of NAME cannot be had, for the MISSING line."
  (format "the lock pins %s; no archive or cache has it%s (drgnx upgrade takes the archives' version)"
          (plist-get pin :version)
          (cond ((alist-get name drgnx-pkg--restore-failed)
                 (format ", and rebuilding it from its commit failed: %s" (alist-get name drgnx-pkg--restore-failed)))
                ((not (and (plist-get pin :commit) (plist-get pin :url))) "; the lock records no commit to rebuild it from")
                (t ""))))

(defun drgnx-pkg--required-version (name descs)
  "The highest version of NAME that DESCS or the installed packages require, or nil."
  (let (v)
    (dolist (d (append descs (mapcar #'cadr package-alist)))
      (unless (eq (package-desc-name d) name)
        (when-let* ((r (assq name (package-desc-reqs d))))
          (when (or (null v) (version-list-< v (cadr r))) (setq v (cadr r))))))
    v))

(defun drgnx-pkg--pinned-desc (name pin)
  "A desc for the locked version PIN of NAME: the archive's when it has that version, the cache's file, or the
rebuild from its commit (`drgnx-pkg--restore-prepare')."
  (let ((v (version-to-list (plist-get pin :version))))
    (or (seq-find (lambda (d) (equal (package-desc-version d) v)) (alist-get name package-archive-contents))
        (and (plist-get pin :file) (file-exists-p (expand-file-name (plist-get pin :file) (drgnx-package-cache-dir)))
             (drgnx-pkg--entry-desc name pin))
        (nth 1 (assq name drgnx-pkg--restored)))))

(defun drgnx-pkg--plan (manifest lock offline upgrade missing &optional pin-failed)
  "The packages to install, dependencies first: descs.  What cannot be had goes on MISSING (a cons
whose car is the alist NAME → reason); a locked version that cannot be had, or one older than a package
needs, goes on PIN-FAILED too (same shape; reason: \"shipped V no longer served\" or \"shipped V is older
than V2 needs\")."
  (let* ((locked (unless upgrade (drgnx-pkg--lock-closure manifest lock)))
         ;; resolved by package.el: the manifest's packages outside the lock, and what locked ones need beyond it
         (others (let ((o (mapcar #'list (seq-difference manifest locked))))
                   (pcase-dolist (`(,n . ,v) (unless upgrade (drgnx-pkg--beyond-lock locked lock)))
                     (setf (alist-get n o) v))
                   o))
         plan)
    (cl-flet ((miss (name why) (unless (assq name (car missing)) (push (cons name why) (car missing))))
              (pin-fail (name why) (when (and pin-failed (not (assq name (car pin-failed))))
                                     (push (cons name why) (car pin-failed))))
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
                  (miss (car e) (format "%s %s is not in the cache%s" (car e) (plist-get (cdr e) :version)
                                        (if (and (plist-get (cdr e) :commit) (plist-get (cdr e) :url))
                                            " — sync online to rebuild it from its commit"
                                          "")))))))
        ;; The lock decides installed versions (unless upgrading), and the versions of the manifest's packages it
        ;; has, with what their entries require: those install as locked, never as the archives' newest asks.
        (unless upgrade
          (dolist (e (drgnx-pkg--lock-order lock))
            (when (if (drgnx-pkg--installed-desc (car e))
                      (not (equal (drgnx-pkg--installed-version (car e)) (plist-get (cdr e) :version)))
                    (memq (car e) locked))
              (if-let* ((d (drgnx-pkg--pinned-desc (car e) (cdr e)))) (add d)
                (pin-fail (car e) (format "shipped %s no longer served" (plist-get (cdr e) :version)))
                (miss (car e) (drgnx-pkg--gone-why (car e) (cdr e)))))))
        ;; Each other package on its own: one that cannot be resolved does not stop the others.
        (pcase-dolist (`(,name . ,min) others)
          (let ((want (if min (list name min) (list name))))
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
            (when-let* (((not (drgnx-pkg-git-source name)))   ; a Git package moves by its source
                        (newest (car (alist-get name package-archive-contents))))
              (when (version-list-< (package-desc-version (car descs)) (package-desc-version newest))
                (condition-case err
                    (dolist (desc (package-compute-transaction nil (list (list name (package-desc-version newest)))))
                      (add desc))
                  (error (miss name (error-message-string err))))))))
        ;; Pins: the locked version, unless something needs a newer one (a locked package already in the plan too).
        (unless upgrade
          (setq plan
                (delq nil
                      (mapcar (lambda (desc)
                                (let* ((name (package-desc-name desc)) (pin (alist-get name lock))
                                       (need (and pin (drgnx-pkg--required-version name plan))))
                                  (cond ((null pin) desc)
                                        ((and need (version-list-< (version-to-list (plist-get pin :version)) need))
                                         (pin-fail name (format "shipped %s is older than %s needs" (plist-get pin :version)
                                                                (package-version-join need)))
                                         (miss name (format "the lock pins %s, but %s is needed — drgnx upgrade moves the lock"
                                                            (plist-get pin :version) (package-version-join need)))
                                         nil)
                                        ((equal (plist-get pin :version) (package-version-join (package-desc-version desc))) desc)
                                        ((drgnx-pkg--pinned-desc name pin))
                                        (t (pin-fail name (format "shipped %s no longer served" (plist-get pin :version)))
                                           (miss name (drgnx-pkg--gone-why name pin))
                                           nil))))
                              plan)))))
      ;; Nothing whose dependency cannot be had; every package after the packages it requires.
      (let (out)
        (dolist (desc plan)
          (if-let* ((dep (seq-find (lambda (r) (assq (car r) (car missing))) (package-desc-reqs desc))))
              (miss (package-desc-name desc) (format "needs %s, which cannot be installed" (car dep)))
            (push desc out)))
        (drgnx-pkg--deps-first (nreverse out))))))

(defun drgnx-pkg--deps-first (descs)
  "DESCS (keeping their order otherwise), each after those of DESCS it requires."
  (let (done out)
    (cl-labels ((visit (d)
                  (unless (memq d done)
                    (push d done)
                    (dolist (r (package-desc-reqs d))
                      (when-let* ((dep (seq-find (lambda (x) (eq (package-desc-name x) (car r))) descs))) (visit dep)))
                    (push d out))))
      (mapc #'visit descs))
    (nreverse out)))

(defun drgnx-pkg--prunable (manifest)
  "The installed packages (`package-alist' as loaded from `package-user-dir') that MANIFEST neither names nor
needs, through the requirements of the installed ones: ((NAME . DESCS)…), sorted by name."
  (let (keep doomed)
    (cl-labels ((visit (name)
                  (unless (memq name keep)
                    (push name keep)
                    (when-let* ((d (cadr (assq name package-alist))))
                      (dolist (r (package-desc-reqs d)) (visit (car r)))))))
      (mapc #'visit manifest))
    (pcase-dolist (`(,name . ,descs) package-alist)
      (unless (memq name keep) (push (cons name descs) doomed)))
    (sort doomed (lambda (a b) (string< (car a) (car b))))))

(defun drgnx-pkg--prune (manifest)
  "Delete from the packages directory being built (`package-user-dir') every package that MANIFEST neither
names nor needs; the names deleted, sorted."
  (setq package-alist nil)
  (package-load-all-descriptors)
  (mapcar (lambda (p) (dolist (d (cdr p)) (package-delete d t t)) (car p)) (drgnx-pkg--prunable manifest)))

(defun drgnx-pkg-prune-candidates (&optional modules-dir)
  "What `drgnx sync --prune' would remove now: the names of the packages in the packages directory that the
manifest (MODULES-DIR: where modules live) neither names nor needs.  Reads; changes nothing."
  (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil) (package-directory-list nil))
    (when (file-directory-p package-user-dir) (package-load-all-descriptors))
    (mapcar #'car (drgnx-pkg--prunable (drgnx-pkg-manifest modules-dir)))))

(cl-defun drgnx-pkg-sync (&key (archives nil archives-given) offline upgrade seed modules-dir prune)
  "Install the manifest into the packages directory.  ARCHIVES: alist (NAME . URL-or-DIR) — when not
given, `drgnx-pkg-archives'; nil: none; OFFLINE: only the lock and the cache; UPGRADE: the archives'
newest versions, not the lock's; SEED: a directory of installed packages to copy first (another
Emacs's elpa); MODULES-DIR: where modules live; PRUNE: also remove the installed packages the manifest
no longer names or needs (hand-installed ones too), when nothing is missing — a generation of the state
before is kept first, for `drgnx rollback'.  Returns (:ok :installed :pruned :missing :generation :warnings).
A failed download or install, a hash mismatch, a busy or unreadable lock is a `drgnx-pkg-error' and
changes nothing; packages that cannot be had are reported (the rest is installed, the lock kept).  With no
lock yet (a new user) and no SEED, the shipped lock (`drgnx-pkg-shipped-lock-file') is copied to the user's
first; until a sync writes the lock, a shipped pin nobody serves falls back to the archives' version (a
warning), never a missing package.  So do the shipped lock's entries for packages the user's lock lacks (a module
turned on later).  A version of the user's lock that no archive serves any more is rebuilt from the :commit and :url
the lock records (`drgnx-pkg--restore-prepare'), else reported missing."
  (let* ((manifest (drgnx-pkg-manifest modules-dir))
         (staging (drgnx-pkg--staging))
         (missing (list nil)) (drgnx-pkg--warnings nil) (drgnx-pkg--restored nil) (drgnx-pkg--restore-failed nil)
         lock installed new-entries generation pruned)
    (drgnx-pkg--with-sync-lock
      (unless (or upgrade seed) (drgnx-pkg--start-from-shipped-lock))   ; seeded versions are the user's choice
      (setq lock (drgnx-pkg-read-lock))                 ; unreadable → error before anything changes
      (drgnx-pkg--recover)
      (drgnx-pkg--sweep)
      (unwind-protect
          (let ((package-user-dir staging) (package-directory-list nil)
                (package-archives (cond (offline nil) (archives-given archives) (t (drgnx-pkg-archives))))
                (package-gnupghome-dir (expand-file-name "gnupg" (drgnx-data-dir)))
                (package-alist nil) (package-archive-contents nil) (package--initialized t)
                (package-pinned-packages nil)
                (package-archive-priorities (drgnx-pkg-archive-priorities))
                ;; package-delete refreshes or deletes the quickstart file: never another Emacs's
                (package-quickstart nil) (package-quickstart-file (expand-file-name "unused-quickstart.el" staging)))
            (when (file-exists-p staging) (delete-directory staging t))
            (if (file-directory-p (drgnx-elpa-dir)) (drgnx-pkg--copy-dir (drgnx-elpa-dir) staging) (make-directory staging t))
            (when seed (drgnx-pkg--seed (expand-file-name seed)))
            (package-load-all-descriptors)
            (when package-archives (package-refresh-contents))
            (let* ((plain (not (or upgrade offline)))
                   ;; the shipped lock's entries for packages the user's lock lacks (a module turned on later): soft pins,
                   ;; like a first sync's; a seeded sync's packages are the user's choice
                   (extras (and plain (not seed) (drgnx-pkg--shipped-extras lock)))
                   (git-names (seq-filter #'drgnx-pkg-git-source manifest))
                   (git (drgnx-pkg--git-prepare git-names (append lock extras) offline upgrade missing))
                   (needs (seq-difference (delete-dups (mapcar #'car (seq-mapcat (lambda (p) (package-desc-reqs (nth 1 p))) git)))
                                          (cons 'emacs git-names))))
              (let* ((names (sort (delete-dups (append (seq-difference manifest git-names) needs)) (lambda (a b) (string< a b))))
                     (pins (seq-remove (lambda (e) (eq (plist-get (cdr e) :kind) 'git)) (append lock extras)))
                     (soft-names (mapcar #'car (if (and plain (drgnx-pkg--lock-from-shipped-p)) pins
                                                 (seq-remove (lambda (e) (eq (plist-get (cdr e) :kind) 'git)) extras))))
                     (git-missing (car missing))
                     dropped plan)
                ;; The shipped lock's pins are soft (a first sync's, and those of packages the user's lock lacks): one
                ;; nobody serves (or too old for what needs it) is dropped
                ;; and package.el resolves the name — from the entry's own archive when it still has the package —
                ;; then the plan is made again.  Each round drops a pin: at most as many rounds as there are pins.
                (when plain (drgnx-pkg--restore-prepare names pins soft-names))
                (while (let* ((m (list (copy-sequence git-missing))) (failed (list nil))
                              (_ (setq plan (drgnx-pkg--plan names pins offline upgrade m failed)))
                              (soft-failed (seq-filter (lambda (f) (memq (car f) soft-names)) (car failed))))
                         (if (null soft-failed)
                             (progn (setcar missing (car m)) nil)
                           (pcase-dolist (`(,name . ,why) soft-failed)
                             (let* ((e (alist-get name pins))
                                    (d (seq-find (lambda (d) (equal (package-desc-archive d) (plist-get e :archive)))
                                                 (alist-get name package-archive-contents))))
                               (push (list name why) dropped)
                               (setq pins (assq-delete-all name pins))
                               ;; first, not alone: a dependent may need a newer version than that archive has
                               (when d (setf (alist-get name package-archive-contents)
                                             (cons d (delete d (alist-get name package-archive-contents)))))))
                           t)))
                (dolist (desc plan)
                  (drgnx-pkg--progress "installing %s" (package-desc-full-name desc))
                  (let ((entry (if-let* ((prep (assq (package-desc-name desc) drgnx-pkg--restored)) ((eq desc (nth 1 prep))))
                                   (drgnx-pkg--restore-install prep (alist-get (package-desc-name desc) pins))
                                 (drgnx-pkg--install desc (alist-get (package-desc-name desc) pins)))))
                    (drgnx-pkg--drop-other-versions desc)
                    (push entry new-entries) (push (package-desc-name desc) installed)))
                (pcase-dolist (`(,name ,why) (reverse dropped))
                  (when-let* ((e (assq name new-entries)))
                    (drgnx-pkg--warn "%s: %s; installed %s" name why (plist-get (cdr e) :version)))))
              ;; then the Git packages, their dependencies in place
              (dolist (p git)
                (if-let* ((dep (seq-find (lambda (r) (assq (car r) (car missing))) (package-desc-reqs (nth 1 p)))))
                    (push (cons (car p) (format "needs %s, which cannot be installed" (car dep))) (car missing))
                  (drgnx-pkg--progress "installing %s from Git" (car p))
                  (push (drgnx-pkg--git-install p) new-entries) (push (car p) installed))))
            (when (and prune (not (car missing)))
              (setq pruned (drgnx-pkg--prune manifest))
              (when pruned (drgnx-pkg-snapshot "before prune")))
            ;; Everything arrived: the new directory goes in, without package.el's copy of the
            ;; archives' contents (fetched again by the next sync).
            (dolist (f '("archives" "unused-quickstart.el" "unused-quickstart.elc"))
              (let ((p (expand-file-name f staging)))
                (cond ((file-directory-p p) (delete-directory p t)) ((file-exists-p p) (delete-file p)))))
            (drgnx-pkg--swap-in staging))
        (when (file-exists-p staging) (delete-directory staging t))
        (dolist (p drgnx-pkg--restored)                 ; the rebuilds not installed (a failed sync, a dependency missing)
          (ignore-errors (delete-directory (nth 5 p) t))))
      (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil) (package-directory-list nil))
        (package-load-all-descriptors)
        (drgnx-pkg--native-compile (delq nil (mapcar (lambda (n) (when-let* ((d (drgnx-pkg--installed-desc n))) (package-desc-dir d)))
                                                     installed)))
        (drgnx-pkg--quickstart)
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
    (list :ok (null (car missing)) :installed (nreverse installed) :pruned pruned :missing (nreverse (car missing))
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
                                 (append (mapcar #'car (seq-remove   ; off until chosen and not chosen: not running, not a suspect
                                                        (lambda (m) (and (eq (plist-get (cdr m) :default) 'off)
                                                                         (not (memq (car m) (plist-get state :enabled)))))
                                                        (drgnx-pkg--module-specs
                                                         (or modules-dir (expand-file-name "modules" drgnx-dir)))))
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
         (unit (concat "[Unit]\nDescription=drgnx (Emacs daemon)\nDocumentation=https://github.com/Black-Dragon-Foundation/drgnx\n"
                       "StartLimitIntervalSec=60\nStartLimitBurst=3\n\n"      ; a held server name stops the restarts
                       "[Service]\nType=notify\n"
                       (format "ExecStart=%s --fg-daemon=drgnx %s\n" (drgnx-pkg--systemd-word emacs)
                               (drgnx-pkg--systemd-word (concat "--init-directory=" (expand-file-name "init" drgnx-dir))))
                       "Restart=on-failure\nRestartSec=2\n\n[Install]\nWantedBy=default.target\n")))
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
  (when (plist-get r :pruned)
    (drgnx-pkg--print "pruned: %s" (mapconcat #'symbol-name (plist-get r :pruned) " ")))
  (pcase-dolist (`(,name . ,why) (plist-get r :missing)) (drgnx-pkg--print "MISSING %s: %s" name why))
  (dolist (w (plist-get r :warnings)) (drgnx-pkg--print "WARNING %s" w))
  (when (plist-get r :generation) (drgnx-pkg--print "generation %d" (plist-get r :generation)))
  (when (plist-get r :error) (drgnx-pkg--print "drgnx: %s" (plist-get r :error)))
  (when (or (plist-get r :installed) (plist-get r :restored) (plist-get r :pruned))
    (drgnx-pkg--print "%s" drgnx-pkg--restart-note)))

(defun drgnx-pkg-cli-run (args)
  "Run the package command ARGS (strings); the exit code."
  (condition-case err
      (pcase args
        (`("sync" . ,flags)
         (let (opts dry-run)
           (while flags
             (pcase (pop flags)
               ("--offline" (setq opts (append opts (list :offline t))))
               ("--seed" (setq opts (append opts (list :seed (pop flags)))))
               ("--prune" (setq opts (append opts (list :prune t))))
               ("--dry-run" (setq dry-run t))
               (f (drgnx-pkg--error "unknown sync option %s (--offline, --seed DIR, --prune [--dry-run])" f))))
           (when (and dry-run (not (plist-get opts :prune))) (drgnx-pkg--error "--dry-run goes with --prune"))
           (if dry-run
               (let ((names (drgnx-pkg-prune-candidates)))
                 (drgnx-pkg--print "%s" (if names (format "would prune: %s" (mapconcat #'symbol-name names " ")) "nothing to prune"))
                 0)
             (let ((r (let ((drgnx-pkg-verbose t)) (apply #'drgnx-pkg-sync opts))))
               (drgnx-pkg--report r)
               (if (plist-get r :ok) 0 1)))))
        (`("upgrade")
         (let ((r (let ((drgnx-pkg-verbose t)) (drgnx-pkg-upgrade))))
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
           (drgnx-pkg--print "%-28s %-16s %s" name (plist-get e :version)
                             (if (eq (plist-get e :kind) 'git)
                                 (format "git %s" (truncate-string-to-width (or (plist-get e :commit) "") 12))
                               (or (plist-get e :archive) "(seeded)"))))
         0)
        (`("lock" "--ship")
         (drgnx-pkg-ship-lock)
         (drgnx-pkg--print "wrote %s (%d packages): commit it" (drgnx-pkg-shipped-lock-file)
                           (length (drgnx-pkg--read-lock-file (drgnx-pkg-shipped-lock-file))))
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
        (_ (drgnx-pkg--print "usage: drgnx sync [--offline] [--seed DIR] [--prune] | upgrade | rollback [N] | generations | lock [--ship] | bisect [-- CMD…] | service-unit [DIR]")
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
