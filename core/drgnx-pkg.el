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
;; in batch Emacs (bin/drgnx); sessions only activate (drgnx-pkg-activate.el).  See docs/packages.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'package)
(require 'drgnx-paths)
(require 'drgnx-modules)

(define-error 'drgnx-pkg-error "drgnx packages")

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
  "Write DATA to FILE (atomically: a temp file renamed over it), after the comment HEADER."
  (make-directory (file-name-directory file) t)
  (let ((tmp (make-temp-file (expand-file-name ".tmp-" (file-name-directory file)))))
    (with-temp-file tmp
      (insert ";; " header "\n")
      (let ((print-length nil) (print-level nil)) (pp data (current-buffer))))
    (rename-file tmp file t)))

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

(defun drgnx-pkg-wanted-file () (expand-file-name "packages-wanted.eld" (drgnx-state-dir)))

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
  (or (plist-get (drgnx-pkg--packages-eld) :archives) drgnx-pkg-default-archives))

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

;;;; The sync lock (one sync at a time)

(defun drgnx-pkg--sync-lock-file () (expand-file-name "sync.lock" (drgnx-data-dir)))

(defun drgnx-pkg--take-sync-lock ()
  (let ((file (drgnx-pkg--sync-lock-file)))
    (make-directory (file-name-directory file) t)
    (when-let* ((pid (and (file-exists-p file)
                          (string-to-number (with-temp-buffer (insert-file-contents file) (buffer-string))))))
      (if (and (> pid 0) (process-attributes pid))
          (drgnx-pkg--error "another drgnx sync is running (process %d); wait for it" pid)
        (delete-file file)))                            ; left by a process that is gone
    (condition-case nil
        (write-region (number-to-string (emacs-pid)) nil file nil 'silent nil 'excl)
      (file-already-exists (drgnx-pkg--error "another drgnx sync just started; wait for it")))))

(defun drgnx-pkg--release-sync-lock () (ignore-errors (delete-file (drgnx-pkg--sync-lock-file))))

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

(defun drgnx-pkg--swap-in (dir)
  "Make DIR the packages directory: two renames, so a session never sees half of one."
  (let* ((elpa (directory-file-name (drgnx-elpa-dir))) (old (concat elpa ".old")))
    (when (file-exists-p old) (delete-directory old t))
    (when (file-exists-p elpa) (rename-file elpa old))
    (rename-file (directory-file-name dir) elpa)
    (when (file-exists-p old) (delete-directory old t))))

(defun drgnx-pkg-generations ()
  "Generations, newest first: (N :time TIME :note NOTE)."
  (let ((dir (drgnx-generations-dir)))
    (sort (delq nil (mapcar (lambda (d)
                              (when (string-match-p "\\`[0-9]+\\'" d)
                                (cons (string-to-number d)
                                      (ignore-errors (drgnx-pkg--read-file (expand-file-name (concat d "/generation.eld") dir))))))
                            (and (file-directory-p dir) (directory-files dir))))
          (lambda (a b) (> (car a) (car b))))))

(defun drgnx-pkg--generation-dir (n) (file-name-as-directory (expand-file-name (number-to-string n) (drgnx-generations-dir))))

(defun drgnx-pkg-snapshot (&optional note)
  "Snapshot the packages directory and the lock as a new generation; keep the newest five.  Returns N."
  (let* ((n (1+ (or (car (car (drgnx-pkg-generations))) 0))) (dir (drgnx-pkg--generation-dir n)))
    (make-directory dir t)
    (if (file-directory-p (drgnx-elpa-dir))
        (drgnx-pkg--copy-dir (drgnx-elpa-dir) (expand-file-name "elpa" dir))
      (make-directory (expand-file-name "elpa" dir)))
    (when (file-exists-p (drgnx-pkg-lock-file)) (copy-file (drgnx-pkg-lock-file) (expand-file-name "drgnx.lock.eld" dir) t))
    (drgnx-pkg--write-file (expand-file-name "generation.eld" dir) "drgnx generation"
                           (list :time (format-time-string "%FT%T%z") :note note))
    (dolist (g (nthcdr drgnx-pkg-generations-kept (drgnx-pkg-generations)))
      (delete-directory (drgnx-pkg--generation-dir (car g)) t))
    n))

(defun drgnx-pkg-rollback (&optional n)
  "Make generation N (default: the one before the newest) the packages directory again, with its lock.
Files come back at the same path, so their native code stays valid.  Returns N."
  (let ((gens (drgnx-pkg-generations)))
    (setq n (or n (car (cadr gens)) (drgnx-pkg--error "no earlier generation to roll back to")))
    (unless (assq n gens) (drgnx-pkg--error "no generation %d (have: %s)" n (mapconcat (lambda (g) (number-to-string (car g))) gens " ")))
    (let ((dir (drgnx-pkg--generation-dir n)) (staging (drgnx-pkg--staging)))
      (when (file-exists-p staging) (delete-directory staging t))
      (drgnx-pkg--copy-dir (expand-file-name "elpa" dir) staging)
      (drgnx-pkg--swap-in staging)
      (let ((lock (expand-file-name "drgnx.lock.eld" dir)))
        (if (file-exists-p lock) (copy-file lock (drgnx-pkg-lock-file) t)
          (when (file-exists-p (drgnx-pkg-lock-file)) (delete-file (drgnx-pkg-lock-file)))))
      n)))

;;;; Installing

(defun drgnx-pkg--entry-desc (name entry)
  "A package-desc for the lock ENTRY of NAME (installing offline)."
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

(defun drgnx-pkg--fetch (desc file)
  "FILE of DESC from its archive into the cache (signature checked where the archive signs); the cached path."
  (let* ((base (package-archive-base desc)) (cache (expand-file-name file (drgnx-package-cache-dir)))
         (tmp (concat cache ".part")))
    (make-directory (drgnx-package-cache-dir) t)
    (if (file-name-absolute-p base)
        (copy-file (expand-file-name file base) tmp t)
      (url-copy-file (concat base file) tmp t))
    (when (and (package-check-signature) (not (member (package-desc-archive desc) package-unsigned-archives)))
      (package--check-signature base file (drgnx-pkg--bytes tmp)))
    (rename-file tmp cache t)
    cache))

(defun drgnx-pkg--unpack (desc file)
  "Install DESC from the package FILE into `package-user-dir' (byte-compiled; no native code yet)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (let ((save-silently t) (package-native-compile nil)) (package-unpack desc))))

(defun drgnx-pkg--install (desc lock-entry missing)
  "Install DESC — from the cache when the file is there, else from its archive — checking the
lock's hash.  Returns the new lock entry, or nil after pushing (NAME . REASON) onto MISSING (a cons
cell whose car is the list).  A hash that differs from the lock is a `drgnx-pkg-error'."
  (let* ((file (concat (package-desc-full-name desc) (package-desc-suffix desc)))
         (cached (expand-file-name file (drgnx-package-cache-dir)))
         (path (cond ((file-exists-p cached) cached)
                     ((package-desc-archive desc)
                      (condition-case err (drgnx-pkg--fetch desc file)
                        (error (push (cons (package-desc-name desc) (format "download failed: %s" (error-message-string err)))
                                     (car missing))
                               nil)))
                     (t (push (cons (package-desc-name desc) (format "%s is not in the cache" file)) (car missing)) nil))))
    (when path
      (let ((sha (drgnx-pkg--sha256 path)) (want (plist-get lock-entry :sha256)))
        (when (and want (equal (plist-get lock-entry :version) (package-version-join (package-desc-version desc)))
                   (not (equal sha want)))
          (drgnx-pkg--error "%s: its sha256 is %s, the lock says %s — refusing (a changed file or a tampered cache)"
                            file sha want))
        (drgnx-pkg--unpack desc path)
        (drgnx-pkg--desc-entry desc file sha)))))

(defun drgnx-pkg--installed-desc (name) (car (alist-get name package-alist)))

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

(defun drgnx-pkg--native-compile (dirs)
  "Compile every Lisp file of DIRS to native code, one at a time (memory stays bounded)."
  (when (and drgnx-pkg-native-compile (fboundp 'native-compile))
    (dolist (dir dirs)
      (dolist (f (directory-files dir t "\\`[^.].*\\.el\\'"))
        (unless (string-match-p "-\\(pkg\\|autoloads\\)\\.el\\'" f)
          (condition-case err (native-compile f)
            (error (message "drgnx sync: native compilation of %s failed: %s" f (error-message-string err)))))))))

(defun drgnx-pkg-quickstart-file () (expand-file-name "drgnx-quickstart.el" (drgnx-elpa-dir)))

(defun drgnx-pkg--quickstart ()
  "Write the activation file of the packages directory (sessions load it instead of scanning)."
  (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil) (package-directory-list nil)
        (package-quickstart-file (drgnx-pkg-quickstart-file)))
    (package-load-all-descriptors)
    (package-quickstart-refresh)))

(cl-defun drgnx-pkg-sync (&key (archives nil archives-given) offline upgrade seed modules-dir)
  "Install the manifest into the packages directory.  ARCHIVES: alist (NAME . URL-or-DIR) — when not
given, `drgnx-pkg-archives'; nil: none; OFFLINE: only the lock and the cache; UPGRADE: the archives' newest versions,
not the lock's; SEED: a directory of installed packages to copy first (another Emacs's elpa);
MODULES-DIR: where modules live.  Returns (:ok :installed :missing :generation).  A hash
mismatch, a busy or unreadable lock is a `drgnx-pkg-error' and changes nothing."
  (let* ((lock (drgnx-pkg-read-lock))               ; unreadable → error before anything changes
         (manifest (drgnx-pkg-manifest modules-dir))
         (staging (drgnx-pkg--staging))
         (missing (list nil)) installed new-entries generation)
    (drgnx-pkg--take-sync-lock)
    (unwind-protect
        (let ((package-user-dir staging) (package-directory-list nil)
              (package-archives (cond (offline nil) (archives-given archives) (t (drgnx-pkg-archives))))
              (package-gnupghome-dir (expand-file-name "gnupg" (drgnx-data-dir)))
              (package-alist nil) (package-archive-contents nil) (package--initialized t)
              (package-pinned-packages nil) (package-quickstart nil))
          (when (file-exists-p staging) (delete-directory staging t))
          (if (file-directory-p (drgnx-elpa-dir)) (drgnx-pkg--copy-dir (drgnx-elpa-dir) staging) (make-directory staging t))
          (when seed (drgnx-pkg--seed (expand-file-name seed)))
          (package-load-all-descriptors)
          (if offline
              (dolist (e (drgnx-pkg--lock-order lock))
                (unless (let ((d (drgnx-pkg--installed-desc (car e))))
                          (and d (equal (package-version-join (package-desc-version d)) (plist-get (cdr e) :version))))
                  (when-let* ((entry (drgnx-pkg--install (drgnx-pkg--entry-desc (car e) (cdr e)) (cdr e) missing)))
                    (push entry new-entries) (push (car e) installed))))
            (when package-archives (package-refresh-contents))
            (let ((wanted (mapcar #'list manifest)))
              (when upgrade                               ; every installed package at the archive's newest
                (pcase-dolist (`(,name . ,descs) package-alist)
                  (when-let* ((newest (car (alist-get name package-archive-contents))))
                    (when (version-list-< (package-desc-version (car descs)) (package-desc-version newest))
                      (setq wanted (cons (list name (package-desc-version newest)) (assq-delete-all name wanted)))))))
              (dolist (desc (condition-case err (package-compute-transaction nil wanted)
                              (error (push (cons 'resolve (error-message-string err)) (car missing)) nil)))
                (let* ((name (package-desc-name desc)) (pin (and (not upgrade) (alist-get name lock)))
                       (pinned (and pin (not (equal (plist-get pin :version) (package-version-join (package-desc-version desc))))))
                       (desc (if pinned (drgnx-pkg--entry-desc name pin) desc)))
                  (if (and pinned (not (file-exists-p (expand-file-name (or (plist-get pin :file) "") (drgnx-package-cache-dir)))))
                      (push (cons name (format "the lock pins %s; no archive or cache has it (drgnx upgrade takes the archives' version)"
                                               (plist-get pin :version)))
                            (car missing))
                    (let ((old (drgnx-pkg--installed-desc name)))
                      (when-let* ((entry (drgnx-pkg--install desc pin missing)))
                        (when (and old (not (equal (package-desc-dir old) (package-desc-dir (drgnx-pkg--installed-desc name)))))
                          (package-delete old t t))
                        (push entry new-entries) (push name installed))))))))
          (drgnx-pkg--native-compile (mapcar (lambda (n) (package-desc-dir (drgnx-pkg--installed-desc n))) installed))
          ;; Everything arrived (or is reported missing): the new directory goes in, without
          ;; package.el's copy of the archives' contents (fetched again by the next sync).
          (let ((archives-dir (expand-file-name "archives" staging)))
            (when (file-exists-p archives-dir) (delete-directory archives-dir t)))
          (drgnx-pkg--swap-in staging)
          (drgnx-pkg--quickstart)
          (unless (car missing)
            (let ((package-user-dir (drgnx-elpa-dir)) (package-alist nil))
              (package-load-all-descriptors)
              (drgnx-pkg-write-lock
               (mapcar (lambda (p)
                         (or (assq (car p) new-entries)
                             (let ((old (assq (car p) lock)) (d (cadr p)))
                               (if (and old (equal (plist-get (cdr old) :version) (package-version-join (package-desc-version d))))
                                   old
                                 (drgnx-pkg--desc-entry d nil nil)))))   ; seeded, or installed by hand
                       package-alist)))
            (setq generation (drgnx-pkg-snapshot (if upgrade "upgrade" "sync")))))
      (when (file-exists-p staging) (delete-directory staging t))
      (drgnx-pkg--release-sync-lock))
    (list :ok (null (car missing)) :installed (nreverse installed) :missing (nreverse (car missing))
          :generation generation)))

;;;; Upgrade with a smoke test

(defun drgnx-pkg-smoke (manifest)
  "The default smoke test: a fresh Emacs activates the packages directory and loads every package of
MANIFEST.  nil when it works, else its output."
  (let ((form `(progn (setq package-user-dir ,(drgnx-elpa-dir) package-directory-list nil)
                      (package-activate-all)
                      (dolist (p ',manifest) (require p)))))
    (with-temp-buffer
      (let ((rc (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                              "--batch" "-Q" "--eval" "(require 'package)" "--eval" (prin1-to-string form))))
        (unless (eql rc 0) (string-trim (buffer-string)))))))

(cl-defun drgnx-pkg-upgrade (&key archives smoke modules-dir)
  "Upgrade every package to the archives' newest, then run SMOKE (default `drgnx-pkg-smoke'; called
with the manifest, nil means it works); if it fails, the previous generation comes back.
Returns (:ok :generation :restored :smoke :missing)."
  (let* ((before (or (car (car (drgnx-pkg-generations))) (drgnx-pkg-snapshot "before upgrade")))
         (r (drgnx-pkg-sync :archives archives :upgrade t :modules-dir modules-dir))
         (failure (and (plist-get r :ok)
                       (condition-case err (funcall (or smoke #'drgnx-pkg-smoke) (drgnx-pkg-manifest modules-dir))
                         (error (error-message-string err))))))
    (cond ((not (plist-get r :ok)) (list :ok nil :missing (plist-get r :missing) :restored nil))
          (failure
           (drgnx-pkg-rollback before)
           (when-let* ((g (plist-get r :generation))) (delete-directory (drgnx-pkg--generation-dir g) t))
           (list :ok nil :smoke failure :restored before))
          (t (list :ok t :generation (plist-get r :generation))))))

(provide 'drgnx-pkg)
;;; drgnx-pkg.el ends here
