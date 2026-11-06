;;; drgnx-extensions-refresh.el --- the catalog refresh job (batch only)  -*- lexical-binding: t -*-

;; `drgnx extensions refresh' reads the archives' contents with package.el and writes one normalized catalog,
;; <cache>/extensions/catalog.json, that the hub's extensions/* methods load (docs/develop/extensions.md, "The catalog
;; file").  `drgnx extensions fetch-readme ARCHIVE NAME' caches one package's readme beside it.
;;
;; It is a hub job's command, never the editor's: it reaches the network.  It changes nothing under the packages
;; directory (elpa/): the archives' files land in <cache>/extensions/pkg/, what is installed is read from the lock
;; (`drgnx-pkg-read-lock'), and the update plan is `drgnx-pkg--plan' in upgrade mode over descs made from the lock, so a
;; swap during a refresh changes nothing this reads.  A failed refresh (an archive that does not answer, a signature
;; that does not verify) leaves the old catalog in place and exits 1.

(require 'drgnx-pkg)
(require 'package)
(require 'seq)
(require 'subr-x)
(require 'url-handlers)

(defconst drgnx-extensions-refresh-version 1 "The catalog file's `version'.")

(defun drgnx-extensions-refresh-dir ()
  "<cache>/extensions/: the catalog, the download counts, the readmes and the archives' files."
  (file-name-as-directory (expand-file-name "extensions" (drgnx-cache-dir))))

(defun drgnx-extensions-refresh-file () (expand-file-name "catalog.json" (drgnx-extensions-refresh-dir)))
(defun drgnx-extensions-refresh--counts-file () (expand-file-name "download_counts.json" (drgnx-extensions-refresh-dir)))
(defun drgnx-extensions-refresh--pkg-dir () (expand-file-name "pkg/" (drgnx-extensions-refresh-dir)))

(defvar drgnx-extensions-refresh--progress nil "The progress file of this run, or nil.")

(defun drgnx-extensions-refresh--step (fmt &rest args)
  "Say what the job is doing: a line on the progress file, when there is one."
  (when drgnx-extensions-refresh--progress
    (let ((line (concat (apply #'format fmt args) "\n")))
      (write-region line nil drgnx-extensions-refresh--progress t 'silent))))

;;;; The archives

(defun drgnx-extensions-refresh--url-p (location) (string-match-p "\\`https?://" location))

(defmacro drgnx-extensions-refresh--with-settings (archives &rest body)
  "BODY with package.el set up as a sync sets it up for ARCHIVES, apart from the packages directory, which is the
refresh's own: the signatures, keyring and priorities are `drgnx-pkg-with-archive-settings' (the one place that binds
them), so an archive a sync checks is checked here too."
  (declare (indent 1))
  `(let* ((package-user-dir (drgnx-extensions-refresh--pkg-dir)) (package-directory-list nil)
          (package-archives ,archives)
          (package-alist nil) (package-archive-contents nil) (package--initialized t)
          (package-pinned-packages nil)
          (package-quickstart nil)
          (package-quickstart-file (expand-file-name "unused-quickstart.el" package-user-dir)))
     (drgnx-pkg-with-archive-settings ,@body)))

(defun drgnx-extensions-refresh--fetch-contents ()
  "Fetch every archive's contents into the refresh's own directory; an archive that does not answer, or whose
signature does not verify, is an error (package.el itself only warns)."
  (let ((dir (expand-file-name "archives" package-user-dir)))
    (when (file-directory-p dir) (delete-directory dir t)) ; an old copy must not hide a failed download
    (make-directory package-user-dir t)
    (let ((inhibit-message t)) (package-refresh-contents))
    (dolist (a package-archives)
      (unless (file-exists-p (expand-file-name (format "archives/%s/archive-contents" (car a)) package-user-dir))
        (drgnx-pkg--error "the archive %s did not answer, or its signature did not verify" (car a))))))

;;;; The catalog

(defun drgnx-extensions-refresh--text (x)
  "X when it is a string, else nil."
  (and (stringp x) x))

(defun drgnx-extensions-refresh--maintainer (extras)
  (let ((m (alist-get :maintainer extras)))
    (cond ((stringp m) m)
          ((and (consp m) (stringp (car m))) (car m))
          ((and (consp m) (stringp (cdr m))) (cdr m)))))

(defun drgnx-extensions-refresh--reqs (desc)
  "DESC's requirements besides Emacs, as a vector of [NAME VERSION] vectors."
  (vconcat (mapcar (lambda (r) (vector (symbol-name (car r)) (package-version-join (cadr r))))
                   (seq-remove (lambda (r) (eq (car r) 'emacs)) (package-desc-reqs desc)))))

(defun drgnx-extensions-refresh--incompat-p (desc)
  "Whether DESC needs a newer Emacs than this one."
  (when-let* ((r (assq 'emacs (package-desc-reqs desc))))
    (version-list-< (version-to-list emacs-version) (cadr r))))

(defun drgnx-extensions-refresh--lock-descs (lock)
  "The packages the lock says are installed, as the descs `drgnx-pkg--plan' reads from `package-alist'."
  (mapcar (lambda (e) (list (car e) (drgnx-pkg--entry-desc (car e) (cdr e))))
          (seq-remove (lambda (e) (eq (plist-get (cdr e) :kind) 'git)) lock)))

(defun drgnx-extensions-refresh--updates (lock)
  "The update plan's upgrades, without installing anything: an alist NAME → (FROM . DESC), over LOCK's packages."
  (let* ((package-alist (drgnx-extensions-refresh--lock-descs lock))
         (names (mapcar #'car package-alist))
         (plan (drgnx-pkg--plan names lock nil t (list nil)))
         out)
    (dolist (desc plan)
      (when-let* ((e (assq (package-desc-name desc) lock))
                  (from (plist-get (cdr e) :version))
                  ((version-list-< (version-to-list from) (package-desc-version desc))))
        (push (cons (package-desc-name desc) (cons from desc)) out)))
    out))

(defun drgnx-extensions-refresh--counts ()
  "MELPA's download counts, NAME string → number, from the file the job keeps; nil without it or when it is not JSON."
  (let ((file (drgnx-extensions-refresh--counts-file)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (json-parse-buffer :object-type 'hash-table))
        (error nil)))))

(defun drgnx-extensions-refresh--fetch-counts ()
  "Fetch MELPA's download counts when MELPA is an archive; a failure is a message, never a failed refresh."
  (when-let* ((m (seq-find (lambda (a) (string-match-p "\\`https?://melpa\\.org/" (cdr a))) package-archives)))
    (let ((tmp (concat (drgnx-extensions-refresh--counts-file) ".tmp")))
      (condition-case err
          (progn
            (url-copy-file "https://melpa.org/download_counts.json" tmp t)
            (rename-file tmp (drgnx-extensions-refresh--counts-file) t))
        (error (drgnx-pkg--print "drgnx: no download counts (%s)" (error-message-string err))
               (ignore-errors (delete-file tmp)))))))

(defun drgnx-extensions-refresh--package (name descs lock updates counts)
  "The catalog entry (a plist) of NAME, whose archive descs are DESCS (the preferred one first)."
  (let* ((cand (car descs)) (extras (package-desc-extras cand))
         (summary (package-desc-summary cand))
         (inst (cdr (assq name lock)))
         (inst-v (and inst (not (eq (plist-get inst :kind) 'git)) (version-to-list (plist-get inst :version))))
         (up (cdr (assq name updates)))
         (newest (car (sort (mapcar #'package-desc-version descs) (lambda (a b) (version-list-< b a)))))
         (count (and counts (gethash (symbol-name name) counts))))
    (unless (stringp summary) (error "its summary is not text"))
    (append
     (list :name (symbol-name name) :summary summary
           :keywords (vconcat (seq-filter #'stringp (alist-get :keywords extras)))
           :kind (symbol-name (package-desc-kind cand))
           :versions (vconcat (mapcar (lambda (d) (list :archive (package-desc-archive d)
                                                        :version (package-version-join (package-desc-version d))
                                                        :reqs (drgnx-extensions-refresh--reqs d)))
                                      descs))
           :candidate (list :archive (package-desc-archive cand) :version (package-version-join (package-desc-version cand)))
           :held (if (and inst-v (not up) (version-list-< inst-v newest)) t :false)
           :incompat (if (drgnx-extensions-refresh--incompat-p cand) t :false))
     (when-let* ((m (drgnx-extensions-refresh--maintainer extras))) (list :maintainer m))
     (when-let* ((u (drgnx-extensions-refresh--text (alist-get :url extras)))) (list :url u))
     (when-let* ((c (drgnx-extensions-refresh--text (alist-get :commit extras)))) (list :commit c))
     (when-let* ((r (drgnx-extensions-refresh--text (alist-get :revdesc extras)))) (list :revdesc r))
     (when up
       (list :update (append (list :from (car up) :to (package-version-join (package-desc-version (cdr up))))
                             (when-let* ((c (plist-get (cdr (assq name lock)) :commit))) (list :from_commit c))
                             (when-let* ((c (drgnx-extensions-refresh--text (alist-get :commit (package-desc-extras (cdr up))))))
                               (list :to_commit c)))))
     (when (integerp count) (list :downloads count))
     (when (floatp count) (list :downloads (truncate count))))))

(defun drgnx-extensions-refresh--builtins ()
  "The packages Emacs ships, as catalog entries."
  (let (out)
    (dolist (b (bound-and-true-p package--builtins))
      (let ((v (cdr b)))
        (when (and (vectorp v) (> (length v) 2) (stringp (aref v 2)))
          (push (list :name (symbol-name (car b)) :version (package-version-join (aref v 0)) :summary (aref v 2)) out))))
    (vconcat (sort out (lambda (a b) (string< (plist-get a :name) (plist-get b :name)))))))

(defun drgnx-extensions-refresh--build (archives lock)
  "The catalog plist for ARCHIVES (an alist NAME → location) over the contents package.el holds now, inside
`drgnx-extensions-refresh--with-settings' (an archive signs unless it is in `package-unsigned-archives')."
  (let* ((counts (drgnx-extensions-refresh--counts))
         (updates (drgnx-extensions-refresh--updates lock))
         packages skipped)
    (pcase-dolist (`(,name . ,descs) (sort (copy-sequence package-archive-contents) (lambda (a b) (string< (car a) (car b)))))
      (condition-case err
          (let ((entry (drgnx-extensions-refresh--package name descs lock updates counts)))
            (ignore (json-serialize entry)) ; text that is not valid text fails here, not in the file
            (push entry packages))
        (error (push (list :archive (or (package-desc-archive (car descs)) "") :name (symbol-name name)
                           :why (if (equal (cadr err) "its summary is not text") "its summary is not text"
                                  "its text is not valid text"))
                     skipped))))
    (list :version drgnx-extensions-refresh-version :written (float-time) :emacs emacs-version
          :archives (vconcat (mapcar (lambda (a) (list :name (car a) :url (cdr a)
                                                       :signed (if (member (car a) package-unsigned-archives) :false t)))
                                     archives))
          :packages (vconcat (nreverse packages))
          :builtins (drgnx-extensions-refresh--builtins)
          :skipped (vconcat (nreverse skipped)))))

(defun drgnx-extensions-refresh--write (catalog)
  "Write CATALOG as catalog.json by rename: a reader sees the old file or the new one, never half of one."
  (let* ((file (drgnx-extensions-refresh-file)) (tmp (format "%s.%d.tmp" file (emacs-pid))))
    (make-directory (file-name-directory file) t)
    (unwind-protect
        (progn
          (with-temp-file tmp
            (set-buffer-multibyte nil)
            (insert (json-serialize catalog)))
          (rename-file tmp file t))
      (when (file-exists-p tmp) (delete-file tmp)))))

(defun drgnx-extensions-refresh ()
  "Refresh the catalog: fetch the archives' contents, merge the lock and the download counts, write catalog.json.
Returns the number of packages.  Any failure is a `drgnx-pkg-error' (or another error) and leaves the old catalog."
  (let* ((archives (drgnx-pkg-archives))
         (lock (drgnx-pkg-read-lock)))
    (make-directory (drgnx-extensions-refresh-dir) t)
    (drgnx-extensions-refresh--with-settings archives
      (drgnx-extensions-refresh--step "fetching the archives")
      (drgnx-extensions-refresh--fetch-contents)
      (drgnx-extensions-refresh--fetch-counts)
      (drgnx-extensions-refresh--step "reading the packages")
      (let ((catalog (drgnx-extensions-refresh--build archives lock)))
        (drgnx-extensions-refresh--step "writing the catalog")
        (drgnx-extensions-refresh--write catalog)
        (length (plist-get catalog :packages))))))

;;;; Readmes

(defun drgnx-extensions-refresh-readme (archive name)
  "Cache the readme of archive ARCHIVE's package NAME: <cache>/extensions/readme/ARCHIVE/NAME-readme.txt.  A directory
archive's file is copied, a URL archive's downloaded.  Returns the file; an archive or package that has none is a
`drgnx-pkg-error'."
  (let* ((location (cdr (assoc archive (drgnx-pkg-archives))))
         (plain (lambda (s) (and (stringp s) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._+-]*\\'" s))))
         (target (and (funcall plain archive) (funcall plain name)
                      (expand-file-name (format "readme/%s/%s-readme.txt" archive name) (drgnx-extensions-refresh-dir)))))
    (unless target (drgnx-pkg--error "%S/%S is not an archive and package name" archive name))
    (unless location (drgnx-pkg--error "no archive named %s" archive))
    (make-directory (file-name-directory target) t)
    (let ((tmp (format "%s.%d.tmp" target (emacs-pid))))
      (unwind-protect
          (progn
            (condition-case err
                (if (drgnx-extensions-refresh--url-p location)
                    (url-copy-file (format "%s%s-readme.txt" (file-name-as-directory location) name) tmp t)
                  (copy-file (expand-file-name (format "%s-readme.txt" name) location) tmp t))
              (error (drgnx-pkg--error "%s has no readme for %s (%s)" archive name (error-message-string err))))
            (rename-file tmp target t))
        (when (file-exists-p tmp) (delete-file tmp))))
    target))

;;;; The command line

(defun drgnx-extensions-refresh-cli-run (args)
  "bin/drgnx's `extensions' commands over ARGS (refresh [--progress FILE] | fetch-readme ARCHIVE NAME); the exit code."
  (condition-case err
      (pcase args
        ((or `("refresh") `("refresh" "--progress" ,_))
         (let ((drgnx-extensions-refresh--progress (and (cdr args) (expand-file-name (nth 2 args)))))
           (princ (format "catalog written: %d packages\n" (drgnx-extensions-refresh)))
           0))
        (`("fetch-readme" ,archive ,name)
         (princ (format "%s\n" (drgnx-extensions-refresh-readme archive name)))
         0)
        (_ (princ "usage: drgnx extensions refresh [--progress FILE] | fetch-readme ARCHIVE NAME\n" #'external-debugging-output)
           2))
    (error (drgnx-pkg--print "drgnx: %s" (error-message-string err))
           1)))

(defun drgnx-extensions-refresh-cli ()
  "bin/drgnx's `extensions' command: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-extensions-refresh-cli-run args))))

(provide 'drgnx-extensions-refresh)
;;; drgnx-extensions-refresh.el ends here
