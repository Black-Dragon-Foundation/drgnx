;;; drgnx-config.el --- drgnx's config files: definitions, the fallback, versions, the surgical writer -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The file layer under every config file drgnx keeps (docs/develop/core.md, "Config files: drgnx-config").
;; - `drgnx-config-define' declares a file: its folder, shape, format version, schema, default and reload rule.
;; - `drgnx-config-get' gives the applied value: the file's data, or its default when the file is absent.  A file
;;   with a mistake is never applied: its last good copy (kept per machine in <state>/config-good/) is, else the
;;   default; one problem says why.  An `mtime' file costs one stat per get.
;; - An older file is migrated in memory; only a user's write (or `drgnx-config-migrate') writes it back, after a
;;   backup.  A newer file is applied when it fits our schema, read-only.
;; - `drgnx-config-set', `-unset' and `-update' change a file under its lock, surgically: only the top-level plist keys
;;   or alist entries that changed are replaced in the text, so comments and unknown keys stay byte for byte.  They
;;   refuse a file with a mistake and a newer one (`drgnx-config-refused').  `drgnx-config-write-text' replaces the
;;   whole file by an editor's text, after the same checks on that text and a stamp check.
;; - Shape `settings' is a settings file, `(HEAD :version 1 ENTRY…)': this layer reads it, keeps its last good copy
;;   and says its mistake; `drgnx-settings-file' parses its entries and writes it (docs/develop/settings.md).
;; It requires only cl-lib, subr-x, drgnx-paths, drgnx-file and drgnx-schema, so the `emacs --batch -Q' hub loads it.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-schema)

(declare-function drgnx-modules-push-undo "drgnx-modules-record" (label undo))
(declare-function drgnx-command-define "drgnx-registry" (id &rest args))
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-notice-clear "drgnx-notice" (source &optional id))

;; A `file-error' too, as `drgnx-file-refused' is: Emacs prints a file error's text as it is, not in quotes.
(define-error 'drgnx-config-refused "" '(user-error file-error))

(defvar drgnx-config--defs (make-hash-table :test 'eq)
  "NAME → the definition plist made by `drgnx-config-define'.  Bounded by the definitions in the code.")

(defvar drgnx-config--state (make-hash-table :test 'equal)
  "NAME, or (NAME . ROOT) for a project file → (:stamp :value :status :problem :version :file :fallback): what was
read and applied.  Bounded: one entry per definition and project root read; an undefine drops a name's entries.")

(defvar drgnx-config--notified (make-hash-table :test 'equal)
  "The keys of `drgnx-config--state' → the problem text last said for it, so each mistake is said once.  An entry
goes when its file reads well again.")

(defvar drgnx-config-changed-functions nil
  "Functions called with NAME when config file NAME's applied value changes: after a write of ours, or when a get
or `drgnx-config-reread' sees a new file.  They run with `inhibit-interaction' t; an error is one message.  Code
that draws from a config value caches it and listens here, rather than getting it per redisplay.")

(defvar drgnx-config-user-save nil
  "Non-nil while `drgnx-config-changed-functions' run because the user saved a config file in the buffer
`drgnx-config-open' visited: a listener that applies its file at once (keys.eld) acts then, and not for drgnx's own
writes, which apply what they write themselves.")

(defvar-local drgnx-config--visiting nil
  "In a buffer `drgnx-config-open' visited: the name of the config file it shows.")

(defvar drgnx-config--in-changed nil
  "Non-nil while `drgnx-config-changed-functions' run: a change they cause runs no listener again.")

;;;; Definitions

(defun drgnx-config--migrate-ok-p (migrate)
  "Whether MIGRATE is an alist of (INTEGER . FUNCTION) (a symbol counts: it may be defined later)."
  (and (proper-list-p migrate)
       (let ((ok t))
         (dolist (step migrate ok)
           (unless (and (consp step) (natnump (car step))
                        (or (functionp (cdr step)) (and (cdr step) (symbolp (cdr step)))))
             (setq ok nil))))))

(defun drgnx-config--forget (name)
  "Drop what was applied and said for config file NAME (every project root's too)."
  (dolist (table (list drgnx-config--state drgnx-config--notified))
    (let ((keys nil))
      (maphash (lambda (k _) (when (or (eq k name) (eq (car-safe k) name)) (push k keys))) table)
      (dolist (k keys) (remhash k table)))))

(cl-defun drgnx-config-define (name &key file (dir 'config) (shape 'plist) (version 1) schema default (reload 'mtime)
                                    (last-good t) max-bytes migrate header doc on-mistake)
  "Declare the config file NAME (a symbol): FILE (a file name) in DIR.  Return NAME.
DIR: `config' (`drgnx-user-dir'), `state' (`drgnx-state-dir') or `project' (ROOT/.drgnx/, read-only and untrusted).
SHAPE: `plist' or `alist', the top form, or `settings', a settings file (HEAD :version 1 ENTRY…) whose SCHEMA is
\(settings HEAD) and whose entries `drgnx-settings-file' reads and writes.  VERSION: the format this drgnx writes; a
plist's `:version', missing meaning 1.  SCHEMA: a `drgnx-schema' whose head is SHAPE, validated now.  DEFAULT: the
value applied when the file is absent or has a mistake.  RELOAD: `mtime' (a get stats the file and reads it
again when it changed) or `start' (read at the first get, then only by `drgnx-config-reread').  LAST-GOOD: on a
mistake, apply the last good copy rather than DEFAULT (never for a project file).  MAX-BYTES: the read and write
limit (1 MiB; 64 KiB for a project file).  MIGRATE: ((FROM . FN)…), FN taking format FROM's data to FROM+1's.
HEADER: the comment a new file starts with.  DOC: one line for the reference.  ON-MISTAKE: a string saying what
happens instead of using the file, when that is not its last good copy or the defaults (the notice and the
reference say it).
In a module's setup the definition is undone at teardown: the previous one comes back, if any.  Redefining NAME
drops what was applied from it."
  (unless (and name (symbolp name)) (error "drgnx-config: %S is not a config file name" name))
  (unless (and (stringp file) (not (string-empty-p file)) (not (string-search "/" file)))
    (error "drgnx-config: %s: :file must be a file name, not %S" name file))
  (unless (memq dir '(config state project))
    (error "drgnx-config: %s: :dir must be config, state or project, not %S" name dir))
  (unless (memq shape '(plist alist settings))
    (error "drgnx-config: %s: :shape must be plist, alist or settings, not %S" name shape))
  (unless (memq reload '(start mtime)) (error "drgnx-config: %s: :reload must be start or mtime, not %S" name reload))
  (unless (and (integerp version) (> version 0)) (error "drgnx-config: %s: :version must be 1 or more" name))
  (unless (or (null max-bytes) (natnump max-bytes)) (error "drgnx-config: %s: :max-bytes must be a size" name))
  (unless (or (null on-mistake) (stringp on-mistake)) (error "drgnx-config: %s: :on-mistake must be a string" name))
  (unless (eq (car-safe schema) shape) (error "drgnx-config: %s: a %s file needs a (%s …) schema" name shape shape))
  (if (not (eq shape 'settings)) (drgnx-schema-validate schema)
    (unless (and (cadr schema) (symbolp (cadr schema)) (null (cddr schema)))
      (error "drgnx-config: %s: a settings file's schema is (settings HEAD)" name)))
  (unless (drgnx-config--migrate-ok-p migrate)
    (error "drgnx-config: %s: :migrate must be an alist of (FORMAT . FUNCTION)" name))
  (let* ((project (eq dir 'project))
         (def (list :name name :file file :dir dir :shape shape :version version :schema schema :default default
                    :reload reload :last-good (and last-good (not project) t)
                    :max-bytes (or max-bytes (if project 65536 1048576)) :migrate migrate
                    :header (or header (format ";; drgnx: %s (docs/reference/config.md)\n" file)) :doc doc
                    :on-mistake on-mistake))
         (old (gethash name drgnx-config--defs)))
    (puthash name def drgnx-config--defs)
    (drgnx-config--forget name)
    (when (fboundp 'drgnx-modules-push-undo)           ; the hub has no module system
      (drgnx-modules-push-undo (format "config %s" name)
                               (lambda ()
                                 (when (eq (gethash name drgnx-config--defs) def)
                                   (if old (puthash name old drgnx-config--defs) (remhash name drgnx-config--defs))
                                   (drgnx-config--forget name)))))
    name))

(defun drgnx-config-undefine (name)
  "Forget config file NAME's definition and what was applied from it.  NAME when it was defined, else nil."
  (when (gethash name drgnx-config--defs)
    (remhash name drgnx-config--defs)
    (drgnx-config--forget name)
    name))

(defun drgnx-config--def (name)
  "NAME's definition; an error when there is none (the caller's bug)."
  (or (gethash name drgnx-config--defs) (error "drgnx-config: %S is not a defined config file" name)))

(defun drgnx-config-defined-p (name)
  "Whether config file NAME has a definition (a module's file only while the module is set up)."
  (and (gethash name drgnx-config--defs) t))

(defun drgnx-config-definition (name)
  "NAME's definition, a plist (:name :file :dir :shape :version :schema :default :reload :last-good :max-bytes
:migrate :header :doc); nil when there is none.  Read it, do not change it."
  (gethash name drgnx-config--defs))

(defun drgnx-config-names (&optional dir)
  "The names of the defined config files, sorted.  DIR is `config', `state' or `project' (or a list of them) to
keep only the files in those folders; nil keeps every file."
  (let ((dirs (if (listp dir) dir (list dir))) (names nil))
    (maphash (lambda (name def) (when (or (null dirs) (memq (plist-get def :dir) dirs)) (push name names)))
             drgnx-config--defs)
    (sort names (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

;;;; Where files are

(defun drgnx-config--path (def root)
  "DEF's file, absolute; ROOT is the project's folder of a project file.  No file name handler runs."
  (let ((default-directory "/") (file-name-handler-alist nil) (file (plist-get def :file)))
    (pcase (plist-get def :dir)
      ('config (expand-file-name file (drgnx-user-dir)))
      ('state (expand-file-name file (drgnx-state-dir)))
      (_ (unless (and (stringp root) (file-name-absolute-p root))
           (error "drgnx-config: %s is a project file: it needs the project's folder" (plist-get def :name)))
         (expand-file-name file (expand-file-name ".drgnx" root))))))

(defun drgnx-config--key (def root)
  "DEF's key in `drgnx-config--state': its name, or (NAME . ROOT) for a project file."
  (if (eq (plist-get def :dir) 'project)
      (cons (plist-get def :name) (let ((default-directory "/") (file-name-handler-alist nil))
                                    (file-name-as-directory (expand-file-name root))))
    (plist-get def :name)))

(defun drgnx-config-file (name &optional root)
  "Config file NAME's absolute path: in `drgnx-user-dir' (config), `drgnx-state-dir' (state) or ROOT/.drgnx/
\(project: ROOT is required).  Worked out with `default-directory' \"/\", so a remote buffer changes nothing."
  (drgnx-config--path (drgnx-config--def name) root))

(defun drgnx-config--shown (file)
  "FILE as a message shows it."
  (let ((file-name-handler-alist nil)) (abbreviate-file-name file)))

;;;; Reading

(defun drgnx-config--top-pos (text)
  "(LINE . COLUMN), both 1-based, of TEXT's first form after its comments; (1 . 1) without TEXT."
  (if (not text) (cons 1 1)
    (with-temp-buffer
      (insert text)
      (set-syntax-table lisp-data-mode-syntax-table)
      (goto-char (point-min))
      (forward-comment (buffer-size))
      (cons (line-number-at-pos nil t) (1+ (- (point) (line-beginning-position)))))))

(defun drgnx-config--at-top (text message)
  "The problem MESSAGE, placed at TEXT's top form."
  (let ((pos (drgnx-config--top-pos text)))
    (list :text message :line (car pos) :column (cdr pos))))

(defun drgnx-config--path-text (path text)
  "A schema problem's TEXT with its PATH in front."
  (if path (format "%s: %s" (mapconcat (lambda (p) (format "%S" p)) path " ") text) text))

(defun drgnx-config--version-of (def data)
  "DATA's format by DEF's rules: an integer, or a string saying why it has none.
An alist file is always 1.  A plist file's `:version', 1 when it is missing; 0 for a list that does not start with a
keyword (a bare list some files had before they were plists).  A settings file's `drgnx-config--settings-version'."
  (cond ((eq (plist-get def :shape) 'alist) 1)
        ((eq (plist-get def :shape) 'settings) (drgnx-config--settings-version (cadr (plist-get def :schema)) data))
        ((and (consp data) (not (keywordp (car data)))) 0)
        ((not (proper-list-p data)) 1)                  ; the schema says what is wrong with it
        (t (let ((m (plist-member data :version)))
             (cond ((null m) 1)
                   ((natnump (cadr m)) (cadr m))
                   (t "its :version is not a whole number"))))))

(defun drgnx-config--settings-version (head data)
  "The format of DATA, a settings file's form of head HEAD, by the rules both settings readers share (`huginn' and
`drgnx-settings-file'): the first `:version' among the keyword pairs after HEAD, a whole number; else a string
saying why it has none."
  (if (not (and (consp data) (proper-list-p data) (eq (car data) head)))
      (format "expected (%s …)" head)
    (let ((rest (cdr data)) (found nil))
      (while (and (not found) (keywordp (car rest)) (cdr rest))
        (if (eq (car rest) :version) (setq found rest) (setq rest (cddr rest))))
      (cond ((null found) "the file has no :version")
            ((natnump (cadr found)) (cadr found))
            (t "unsupported :version")))))

(defun drgnx-config--put-version (data version)
  "The plist DATA with `:version' VERSION, in place of its own, else first."
  (if (plist-member data :version) (plist-put data :version version) (cons :version (cons version data))))

(defun drgnx-config--migrate (def data from)
  "DATA, in format FROM, brought up to DEF's format by its :migrate steps: (ok . DATA) or (problem . TEXT)."
  (let ((to (plist-get def :version)) (v from))
    (catch 'done
      (while (< v to)
        (let ((fn (alist-get v (plist-get def :migrate))))
          (unless fn (throw 'done (cons 'problem (format "no migration from format %d" v))))
          (condition-case err (setq data (funcall fn data))
            (error (throw 'done (cons 'problem (format "the migration from format %d failed: %s"
                                                       v (error-message-string err))))))
          (setq v (1+ v))))
      (cons 'ok (if (and (eq (plist-get def :shape) 'plist) (proper-list-p data))
                    (drgnx-config--put-version data to)
                  data)))))

(defun drgnx-config--unknown (def data)
  "The paths of DATA's keys DEF's schema does not name; a plist file's own `:version' is not one.  A settings file
has none: its entries are not keys of a schema."
  (unless (eq (plist-get def :shape) 'settings)
    (let ((keys (drgnx-schema-unknown-keys (plist-get def :schema) data)))
      (if (eq (plist-get def :shape) 'plist) (delete '(:version) keys) keys))))

(defun drgnx-config--analyze (def r file)
  "The config read of FILE from R, `drgnx-file-read's result for it, by DEF's rules (see `drgnx-config-read').
A settings file (shape `settings') that holds no form, or one in a newer format, is a mistake, as `huginn' has it."
  (let ((text (plist-get r :text)) (data (plist-get r :data)) (want (plist-get def :version))
        (settings (eq (plist-get def :shape) 'settings))
        status problem version)
    (pcase (plist-get r :status)
      ('absent (if (and settings text)
                   (setq status 'problem problem (drgnx-config--at-top text "the file holds no form"))
                 (setq status 'absent data nil)))
      ('unreadable (setq status 'problem problem (plist-get r :problem)))
      (_
       (let ((v (drgnx-config--version-of def data)))
         (if (stringp v) (setq status 'problem problem (drgnx-config--at-top text v))
           (setq version v)
           (cond ((< v want)
                  (let ((m (drgnx-config--migrate def data v)))
                    (if (eq (car m) 'problem) (setq status 'problem problem (drgnx-config--at-top text (cdr m)))
                      (setq status 'migrated data (cdr m)))))
                 ((and settings (> v want))
                  (setq status 'problem
                        problem (drgnx-config--at-top text (format "version %d was written by a newer drgnx" v))))
                 ((> v want) (setq status 'newer))
                 (t (setq status 'ok)))
           (unless (or settings (eq status 'problem))
             (when-let* ((bad (drgnx-schema-check (plist-get def :schema) data)))
               (setq problem (drgnx-config--at-top
                              text (concat (if (eq status 'newer) (format "a newer drgnx's format %d: " v) "")
                                           (drgnx-config--path-text (car bad) (cdr bad))))
                     status 'problem)))))))
    (let ((good (memq status '(ok migrated newer))))
      (list :status status :data (and good data) :problem problem :version version
            :unknown-keys (and good (drgnx-config--unknown def data)) :file file :stamp (plist-get r :stamp)))))

(defun drgnx-config--read (def file)
  "FILE read fresh by DEF's rules: (CONFIG-READ . TEXT)."
  (let ((r (drgnx-file-read file :max-bytes (plist-get def :max-bytes))))
    (cons (drgnx-config--analyze def r file) (plist-get r :text))))

(defun drgnx-config-read (name &optional root)
  "Config file NAME (ROOT for a project file) read fresh, applying nothing:
\(:status S :data D :problem P :version V :unknown-keys K :file F :stamp ST).
S: `ok', `absent', `problem' (a mistake: unreadable, failing the schema, or an older format no migration
reaches), `newer' (a later format that fits our schema) or `migrated' (an older format brought up in memory).
D: the data (migrated, for `migrated'), nil unless S is ok, newer or migrated.  P: (:text :line :column), 1-based; a
schema problem names its path and sits at the top form.  V: the file's format.  K: the paths of keys the schema does
not name.  ST: `drgnx-file-stamp'."
  (let ((def (drgnx-config--def name)))
    (car (drgnx-config--read def (drgnx-config--path def root)))))

;;;; The applied value

(defun drgnx-config--good-file (def)
  "Where DEF's last good copy is kept: <state>/config-good/NAME.eld."
  (let ((default-directory "/"))
    (expand-file-name (format "config-good/%s.eld" (plist-get def :name)) (drgnx-state-dir))))

(defun drgnx-config-last-good-file (name)
  "Where config file NAME's last good copy is kept (<state>/config-good/NAME.eld), whether or not there is one yet.
The layer writes it when a good read of the file has a new stamp; read it, never write it."
  (drgnx-config--good-file (drgnx-config--def name)))

(defun drgnx-config--last-good (def)
  "(DATA) of DEF's last good copy when it reads well against the schema (an older format migrated), else nil."
  (let* ((good (drgnx-config--good-file def))
         (r (car (drgnx-config--read def good))))
    (and (memq (plist-get r :status) '(ok migrated)) (list (plist-get r :data)))))

(defun drgnx-config--keep-good (def text)
  "Keep TEXT, which read well, as DEF's last good copy (written only when it differs).  An error is one message."
  (condition-case err
      (let ((good (drgnx-config--good-file def)))
        (unless (equal (drgnx-file-read-bounded good :max-bytes (plist-get def :max-bytes)) text)
          (drgnx-file-write-text good text)))
    (error (drgnx-config--warn (format "the last good copy of %s was not kept: %s" (plist-get def :file)
                                       (error-message-string err))))))

(defun drgnx-config--warn (text)
  "A `warn' event of source `config' (the model loads at the first one).  Never signals."
  (condition-case failed
      (progn (require 'drgnx-notice) (drgnx-notify 'config 'warn text))
    (error (message "drgnx: %s (not recorded: %s)" text (error-message-string failed)))))

(defun drgnx-config--notify (key file problem fallback def)
  "Say PROBLEM of FILE (state KEY) once per text: a `drgnx-notify' condition, else one message.
FALLBACK is what is applied instead: `last-good' or `default'; DEF's `:on-mistake' (a project file: that the file
is refused) says what happens when it is not the last good copy."
  (let ((text (plist-get problem :text)))
    (unless (equal (gethash key drgnx-config--notified) text)
      (puthash key text drgnx-config--notified)
      (let ((line (format "%s: %s (line %d) — %s" (drgnx-config--shown file) text (plist-get problem :line)
                          (cond ((eq fallback 'last-good) "using its last good copy")
                                (t (or (plist-get def :on-mistake)
                                       (if (eq (plist-get def :dir) 'project) "the file is refused" "using the defaults")))))))
        (if (fboundp 'drgnx-notify)
            (drgnx-notify 'config 'fail line :id key :life 'condition :command 'config-open)
          (message "drgnx: %s" line))))))

(defun drgnx-config--unnotify (key)
  "KEY's file reads well: forget its problem, and clear its notice."
  (when (gethash key drgnx-config--notified)
    (remhash key drgnx-config--notified)
    (when (fboundp 'drgnx-notice-clear) (drgnx-notice-clear 'config key))))

(defun drgnx-config--run-changed (name)
  "Run `drgnx-config-changed-functions' with NAME: not from inside them, each under `condition-case', no prompt."
  (unless drgnx-config--in-changed
    (let ((drgnx-config--in-changed t) (inhibit-interaction t))
      (run-hook-wrapped 'drgnx-config-changed-functions
                        (lambda (fn)
                          (condition-case err (funcall fn name)
                            (error (drgnx-config--warn (format "%s, run because %s changed, failed: %s"
                                                               fn name (error-message-string err)))))
                          nil)))))

(defun drgnx-config--refresh (def key file &optional wrote)
  "Read FILE (DEF's) fresh and apply it under KEY; the new state.  WROTE: our write just changed it, so the
listeners run even when nothing had been applied yet."
  (let* ((old (gethash key drgnx-config--state))
         (read (drgnx-config--read def file))
         (r (car read))
         (status (plist-get r :status))
         (fallback nil)
         (value (pcase status
                  ((or 'ok 'migrated 'newer) (plist-get r :data))
                  ('absent (plist-get def :default))
                  (_ (let ((good (and (plist-get def :last-good) (drgnx-config--last-good def))))
                       (setq fallback (if good 'last-good 'default))
                       (if good (car good) (plist-get def :default))))))
         (st (list :stamp (plist-get r :stamp) :value value :status status :problem (plist-get r :problem)
                   :version (plist-get r :version) :file file :fallback fallback)))
    (puthash key st drgnx-config--state)
    (when (and (eq status 'ok) (plist-get def :last-good)
               (not (and old (equal (plist-get old :stamp) (plist-get r :stamp)))))
      (drgnx-config--keep-good def (cdr read)))
    (if (eq status 'problem)
        (drgnx-config--notify key file (plist-get r :problem) fallback def)
      (drgnx-config--unnotify key))
    (when (if old (not (equal (plist-get old :value) value)) wrote)
      (drgnx-config--run-changed (plist-get def :name)))
    st))

(defun drgnx-config--same-stamp-p (file stamp)
  "Whether FILE still has STAMP (`drgnx-file-stamp'), from one `file-attributes' call that allocates nothing more.
A symbolic link is stamped by its target, as `drgnx-file-stamp' does."
  (let ((attrs (let ((file-name-handler-alist nil)) (file-attributes file))))
    (cond ((null attrs) (null stamp))
          ((stringp (file-attribute-type attrs)) (equal (drgnx-file-stamp file) stamp))
          (t (and stamp
                  (equal (file-attribute-inode-number attrs) (car stamp))
                  (equal (file-attribute-modification-time attrs) (nth 1 stamp))
                  (equal (file-attribute-size attrs) (nth 2 stamp)))))))

(defun drgnx-config--current (name root)
  "The applied state of config file NAME (ROOT for a project file), read again when its reload rule says so."
  (let* ((def (drgnx-config--def name))
         (file (drgnx-config--path def root))
         (key (drgnx-config--key def root))
         (st (gethash key drgnx-config--state)))
    (if (and st (equal (plist-get st :file) file)       ; another folder (the environment changed): read it
             (or (eq (plist-get def :reload) 'start) (drgnx-config--same-stamp-p file (plist-get st :stamp))))
        st
      (drgnx-config--refresh def key file))))

(defun drgnx-config--lookup (def value key)
  "KEY's value in VALUE, else in DEF's default (a plist key that is not `plist-member', an alist key not `assoc')."
  (if (eq (plist-get def :shape) 'alist)
      (let ((cell (assoc key value))) (if cell (cdr cell) (cdr (assoc key (plist-get def :default)))))
    (let ((m (plist-member value key))) (if m (cadr m) (plist-get (plist-get def :default) key)))))

(defvar drgnx-settings-shim-areas nil
  "The old config files whose values moved into settings.el and that `drgnx-config-get' still answers, from the
settings (the shim, `drgnx-settings-migrate-shim'; docs/develop/settings.md, \"The migration and the shim\").  An
area leaves this list when its callers read the settings themselves (unified-settings Tasks 15 and 16; agents and ai
left with Task 15, keys, modules, large-files and session with Task 16).")

(declare-function drgnx-settings-migrate-shim "drgnx-settings-migrate" (name state))

(defun drgnx-config-get (name &optional key root)
  "Config file NAME's applied value (ROOT for a project file), or KEY's value in it: the default's when KEY is absent.
The applied value is the file's data, the default when the file is absent and, when the file has a mistake, its last
good copy (`:last-good') or the default.  An `mtime' file costs one stat, and is read again when it changed; a
`start' file is read once.  While NAME is in `drgnx-settings-shim-areas' (and drgnx-settings-migrate is loaded), the
value is the plist settings.el's entries give.  Do not change the value returned: it is shared."
  (let* ((st (drgnx-config--current name root))
         (value (if (and (null root) (memq name drgnx-settings-shim-areas) (fboundp 'drgnx-settings-migrate-shim))
                    (drgnx-settings-migrate-shim name st)
                  (plist-get st :value))))
    (if key (drgnx-config--lookup (gethash name drgnx-config--defs) value key) value)))

(defun drgnx-config-reread (name &optional root)
  "Read config file NAME (ROOT for a project file) again now, whatever its reload rule; the applied value."
  (let* ((def (drgnx-config--def name)) (file (drgnx-config--path def root)))
    (plist-get (drgnx-config--refresh def (drgnx-config--key def root) file) :value)))

;;;; Problems

(defun drgnx-config--problem-of (name st)
  "The problem plist of state ST of NAME, or nil."
  (when (eq (plist-get st :status) 'problem)
    (let ((p (plist-get st :problem)))
      (list :name name :file (plist-get st :file) :text (plist-get p :text) :line (plist-get p :line)
            :column (plist-get p :column)))))

(defun drgnx-config-problem (name &optional root)
  "Config file NAME's mistake (ROOT for a project file): (:name :file :text :line :column), or nil.
It is the applied state's, read again when the reload rule says so."
  (drgnx-config--problem-of name (drgnx-config--current name root)))

(defun drgnx-config-problems ()
  "Every config file's current mistake, as `drgnx-config-problem' gives it, from what was applied (no I/O)."
  (let ((out nil))
    (maphash (lambda (k st) (when-let* ((p (drgnx-config--problem-of (if (consp k) (car k) k) st))) (push p out)))
             drgnx-config--state)
    (sort out (lambda (a b) (string< (plist-get a :file) (plist-get b :file))))))

;;;; The surgical render

(defun drgnx-config--pp (data)
  "DATA pretty-printed for a file, ending in one newline, indented with spaces only."
  (let ((indent-tabs-mode nil)) (drgnx-file--print data t)))

(defun drgnx-config--print-value (value column)
  "VALUE's text for COLUMN: `prin1' under the file layer's print bindings, or `pp' indented to COLUMN when wider
than 70 columns (a newline inside a string is not indented)."
  (let ((flat (string-trim-right (drgnx-file--print value nil) "\n")))
    (if (<= (length flat) 70) flat
      (with-temp-buffer
        (insert (string-trim-right (drgnx-config--pp value) "\n"))
        (set-syntax-table lisp-data-mode-syntax-table)
        (goto-char (point-min))
        (while (and (zerop (forward-line 1)) (not (eobp)))
          (unless (nth 3 (syntax-ppss)) (insert (make-string column ?\s))))
        (buffer-string)))))

(defun drgnx-config--items (shape)
  "The items of the list whose open paren point is after: ((KEY BEG END VBEG VEND)…) in order.  BEG..END is the
item's text (a plist key with its value, or an alist entry), VBEG..VEND what a changed item replaces.  Point ends
before the close paren."
  (let ((items nil) (read-circle nil) (read-symbol-shorthands nil))
    (while (progn (forward-comment (buffer-size)) (not (eq (char-after) ?\))))
      (when (eobp) (error "The list does not end"))
      (let ((beg (point)) (first (read (current-buffer))))
        (if (eq shape 'alist)
            (if (consp first) (push (list (car first) beg (point) beg (point)) items)
              (error "An alist entry that is not a pair"))
          (forward-comment (buffer-size))
          (when (eq (char-after) ?\)) (error "A key with no value"))
          (let ((vbeg (point)))
            (read (current-buffer))
            (push (list first beg (point) vbeg (point)) items)))))
    (nreverse items)))

(defun drgnx-config--pairs (shape data)
  "DATA's items as ((KEY . TEXT-VALUE)…): a plist key and its value, or an alist key and its whole entry."
  (if (eq shape 'alist) (mapcar (lambda (e) (cons (car e) e)) data)
    (let ((out nil))
      (while data (push (cons (pop data) (pop data)) out))
      (nreverse out))))

(defun drgnx-config--deletion (item)
  "The edit (BEG END \"\") taking ITEM out with its following blanks: to the next item, or to a comment after it."
  (save-excursion
    (goto-char (nth 2 item))
    (skip-chars-forward " \t")
    (when (eolp) (skip-chars-forward "\n") (skip-chars-forward " \t"))
    (list (nth 1 item) (point) "")))

(defun drgnx-config--back-skip (pos)
  "POS moved back over blanks, and over the newline before them unless a comment ends there."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward " \t")
    (let ((p (point)))
      (when (and (bolp) (> p (point-min)) (not (nth 4 (save-excursion (syntax-ppss (1- p))))))   ; it moves point
        (goto-char (1- p))
        (skip-chars-backward " \t")))
    (point)))

(defun drgnx-config--item-text (shape pair column)
  "The text of the new item PAIR at COLUMN."
  (if (eq shape 'alist) (drgnx-config--print-value (cdr pair) column)
    (let ((key (string-trim-right (drgnx-file--print (car pair) nil) "\n")))
      (concat key " " (drgnx-config--print-value (cdr pair) (+ column (length key) 1))))))

(defun drgnx-config--insertion (shape anchor pairs open sep indent)
  "The edit inserting the new items PAIRS after ANCHOR (an old item; nil: first, after OPEN, the open paren).
SEP goes between items; INDENT is their column."
  (let ((texts (mapconcat (lambda (p) (drgnx-config--item-text shape p indent)) pairs sep)))
    (if (null anchor)
        (let ((pos (1+ open)))
          (list pos pos (if (save-excursion (goto-char pos) (forward-comment (buffer-size)) (eq (char-after) ?\)))
                            texts
                          (concat texts sep))))
      (save-excursion
        (goto-char (nth 2 anchor))
        (skip-chars-forward " \t")
        (if (eq (char-after) ?\;)                       ; the anchor's own comment stays on its line
            (progn (end-of-line) (list (point) (point) (concat "\n" (make-string indent ?\s) texts)))
          (list (nth 2 anchor) (nth 2 anchor) (concat sep texts)))))))

(defun drgnx-config--order-edits (edits)
  "EDITS, (BEG END TEXT)…, in the order they are applied: deletions that touch are joined, one that reaches the
close paren also takes the blanks before it, and all go from the end of the buffer to its start (at one place, a
deletion before an insertion)."
  (let ((dels nil) (others nil) (joined nil))
    (dolist (e edits) (if (equal (nth 2 e) "") (push e dels) (push e others)))
    (dolist (d (sort dels (lambda (a b) (< (car a) (car b)))))
      (if (and joined (<= (car d) (nth 1 (car joined))))
          (setcar joined (list (car (car joined)) (max (nth 1 (car joined)) (nth 1 d)) ""))
        (push d joined)))
    (dolist (d joined)
      (when (eq (char-after (nth 1 d)) ?\)) (setcar d (drgnx-config--back-skip (car d)))))
    (sort (append joined others)
          (lambda (a b) (or (> (car a) (car b)) (and (= (car a) (car b)) (> (nth 1 a) (nth 1 b))))))))

(defun drgnx-config--edit (def name old-data new)
  "The current buffer's text (point at its top list) changed from OLD-DATA to NEW item by item."
  (let* ((shape (plist-get def :shape))
         (open (point))
         (items (progn (forward-char 1) (drgnx-config--items shape)))
         (close (point))
         (old-pairs (drgnx-config--pairs shape old-data))
         (new-pairs (drgnx-config--pairs shape new))
         (old-keys (mapcar #'car items))
         (new-keys (mapcar #'car new-pairs))
         (multi (save-excursion (goto-char open) (search-forward "\n" close t)))
         (indent (if items (save-excursion (goto-char (nth 1 (car items))) (current-column))
                   (1+ (save-excursion (goto-char open) (current-column)))))
         (sep (if multi (concat "\n" (make-string indent ?\s)) " "))
         (edits nil))
    (unless (equal old-keys (mapcar #'car old-pairs))
      (error "drgnx-config: %s: the file's text and its data do not match" name))
    (let ((kept-old nil) (kept-new nil))
      (dolist (k old-keys) (when (member k new-keys) (push k kept-old)))
      (dolist (k new-keys) (when (member k old-keys) (push k kept-new)))
      (unless (equal kept-old kept-new)
        (error "drgnx-config: %s: the new data moves items the file has; nothing was written" name)))
    (dolist (item items)
      (let ((pair (assoc (car item) new-pairs)))
        (cond ((null pair) (push (drgnx-config--deletion item) edits))
              ((not (equal (cdr pair) (cdr (assoc (car item) old-pairs))))
               (push (list (nth 3 item) (nth 4 item)
                           (drgnx-config--print-value (cdr pair) (save-excursion (goto-char (nth 3 item)) (current-column))))
                     edits)))))
    (let ((anchor nil) (pending nil))
      (dolist (pair new-pairs)
        (if (not (member (car pair) old-keys)) (push pair pending)
          (when pending (push (drgnx-config--insertion shape anchor (nreverse pending) open sep indent) edits))
          (setq pending nil anchor (assoc (car pair) items))))
      (when pending (push (drgnx-config--insertion shape anchor (nreverse pending) open sep indent) edits)))
    (dolist (e (drgnx-config--order-edits edits))
      (goto-char (car e))
      (delete-region (car e) (nth 1 e))
      (insert (nth 2 e)))
    (buffer-string)))

(defun drgnx-config--render (def old-text old-data new whole-on-error)
  "The text that takes the file from OLD-TEXT (OLD-DATA) to NEW, changing only the items that changed.
An absent file: DEF's header and NEW pretty-printed.  WHOLE-ON-ERROR (a migration, after its backup): an old text
the items cannot be matched in is written whole instead of refused."
  (if (null old-text) (concat (plist-get def :header) (drgnx-config--pp new))
    (with-temp-buffer
      (insert old-text)
      (set-syntax-table lisp-data-mode-syntax-table)
      (goto-char (point-min))
      (forward-comment (buffer-size))
      (cond ((eobp)                                     ; only comments
             (concat old-text (if (string-suffix-p "\n" old-text) "" "\n") (drgnx-config--pp new)))
            ((or (null old-data) (not (eq (char-after) ?\()))   ; `nil' or `()'
             (let ((beg (point)))
               (let ((read-circle nil)) (read (current-buffer)))
               (delete-region beg (point))
               (goto-char beg)
               (insert (string-trim-right (drgnx-config--pp new) "\n"))
               (buffer-string)))
            (whole-on-error
             (condition-case nil (drgnx-config--edit def (plist-get def :name) old-data new)
               (error (concat (plist-get def :header) (drgnx-config--pp new)))))
            (t (drgnx-config--edit def (plist-get def :name) old-data new))))))

;;;; Writers

(defun drgnx-config--refuse (file r want)
  "Signal `drgnx-config-refused' for FILE when R (its config read) is a mistake or newer than format WANT."
  (pcase (plist-get r :status)
    ('problem
     (let ((p (plist-get r :problem)))
       (signal 'drgnx-config-refused
               (list (format "%s has a mistake at line %d: %s — fix it (Preferences: Open Config File…) or reset it; it was not changed"
                             (drgnx-config--shown file) (plist-get p :line) (plist-get p :text))))))
    ('newer
     (signal 'drgnx-config-refused
             (list (format "%s was written by a newer drgnx (format %d; this one writes %d): update drgnx here; it was not changed"
                           (drgnx-config--shown file) (plist-get r :version) want))))))

(defun drgnx-config-ensure-writable (name &optional root)
  "Signal `drgnx-config-refused' when config file NAME (a fresh read) has a mistake or is newer than this drgnx
writes; else nil.  Call it before the first side effect of a flow that ends in a write to NAME, so a refusal
changes nothing at all.  Nothing is applied or written.  An undefined NAME is an `error' (the caller's bug)."
  (let* ((def (drgnx-config--def name))
         (file (drgnx-config--path def root)))
    (drgnx-config--refuse file (car (drgnx-config--read def file)) (plist-get def :version))))

(defun drgnx-config--versioned (def status new)
  "NEW with DEF's format as its `:version' when it is written to a plist file that was migrated, or absent."
  (if (and (eq (plist-get def :shape) 'plist) (proper-list-p new)
           (or (eq status 'migrated) (and (eq status 'absent) new)))
      (drgnx-config--put-version new (plist-get def :version))
    new))

(cl-defun drgnx-config-update (name fn &key root (timeout 1.0))
  "Change config file NAME: (FN DATA) under its lock, on a fresh read; the new applied value.
FN gets the file's data (migrated when it is older; nil when the file is absent, not the default) and may change it
in place.  Its result must fit the schema, else an `error' (the caller's bug).  A result `equal' to the data writes
nothing.  Only the items that changed are written: comments, layout and unknown keys stay byte for byte; a result
that moves items the file has is an `error'.  An older file is backed up first and gets this format's `:version'; a
new file gets the header (and the `:version' first, for a plist).  Signals `drgnx-config-refused' when the file has a
mistake or is newer, and leaves it as it was; a project file is read-only.  TIMEOUT is the lock's (0 from timers,
filters and sentinels: `drgnx-file-busy' at once).  Then the listeners run."
  (let ((def (drgnx-config--def name)))
    (when (eq (plist-get def :dir) 'project) (error "%s is read-only" name))
    (when (eq (plist-get def :shape) 'settings)
      (error "%s is a settings file: `drgnx-settings-file-put' writes it, one entry at a time" name))
    (let* ((file (drgnx-config--path def root))
           (max (plist-get def :max-bytes))
           (migrated nil) (wrote nil))
      (condition-case err
          (drgnx-file-update
           file
           (lambda (_data)                              ; read again by our rules: under the lock, the same bytes
             (let* ((r (car (drgnx-config--read def file)))
                    (status (plist-get r :status)))
               (drgnx-config--refuse file r (plist-get def :version))
               (let ((new (drgnx-config--versioned def status (funcall fn (plist-get r :data)))))
                 (when-let* ((bad (drgnx-schema-check (plist-get def :schema) new)))
                   (error "drgnx-config: %s: the new data does not fit its schema: %s"
                          name (drgnx-config--path-text (car bad) (cdr bad))))
                 (when (eq status 'migrated)
                   (drgnx-file-backup file)
                   (setq migrated t))
                 new)))
           :timeout timeout :max-bytes max
           :render (lambda (old-text old-data new)
                     (setq wrote t)
                     (drgnx-config--render def old-text old-data new migrated)))
        (drgnx-file-refused                             ; an unreadable file: say where its mistake is
         (let ((r (car (drgnx-config--read def file))))
           (if (eq (plist-get r :status) 'problem)
               (drgnx-config--refuse file r (plist-get def :version))
             (signal (car err) (cdr err))))))
      (plist-get (drgnx-config--refresh def (drgnx-config--key def root) file wrote) :value))))

(defun drgnx-config--put (def data key value)
  "DATA with KEY's value VALUE: in place, else added at the end."
  (if (eq (plist-get def :shape) 'alist)
      (let ((cell (assoc key data)))
        (if cell (progn (setcdr cell value) data) (append data (list (cons key value)))))
    (plist-put data key value)))

(defun drgnx-config--remove (def data key)
  "DATA without KEY."
  (let ((out nil))
    (if (eq (plist-get def :shape) 'alist)
        (dolist (e data) (unless (equal (car-safe e) key) (push e out)))
      (while data
        (let ((k (pop data)) (v (pop data)))
          (unless (eq k key) (push k out) (push v out)))))
    (nreverse out)))

(defun drgnx-config-set (name key value &optional root)
  "Set KEY (a plist key, or an alist entry's key) to VALUE in config file NAME; the new applied value.
A `drgnx-config-update': only that item changes in the file.  ROOT: a project file, which is read-only."
  (let ((def (drgnx-config--def name)))
    (drgnx-config-update name (lambda (data) (drgnx-config--put def data key value)) :root root)))

(defun drgnx-config-unset (name key)
  "Take KEY (a plist key, or an alist entry's key) and its value out of config file NAME; the new applied value.
A get of KEY then gives the default's."
  (let ((def (drgnx-config--def name)))
    (drgnx-config-update name (lambda (data) (drgnx-config--remove def data key)))))

(defun drgnx-config--text-read (def file text)
  "TEXT, as the text of FILE (DEF's), analyzed by DEF's rules like a file read: the config read of it."
  (let* ((parsed (drgnx-file--parse text))
         (r (pcase (car parsed)
              ('ok (list :status 'ok :data (cdr parsed) :text text))
              ('absent (list :status 'absent :text text))
              (_ (list :status 'unreadable :problem (cdr parsed) :text text)))))
    (drgnx-config--analyze def r file)))

(cl-defun drgnx-config-write-text (name text &key (expect-stamp nil stamp-p) (timeout 1.0))
  "Replace config file NAME by TEXT whole, under its lock; the new applied value.
For an editor that holds the file's whole text (the keys editor): it changes the file's bytes to exactly TEXT.
TEXT must read, fit the schema and be no newer than this drgnx writes, and fit the size limit, else
`drgnx-config-refused' names its line.  With EXPECT-STAMP (`drgnx-file-stamp' of the file as the editor read it; nil
for a file that was absent) given and not `equal' to the file's stamp now it refuses: \"FILE changed since you opened
it\", and nothing is written.  Without EXPECT-STAMP it also refuses a file that has a mistake (the editor was shown
none) and one a newer drgnx wrote; with it the editor has seen the file, so a mistake may be written over.  A project
file is read-only.  TIMEOUT is the lock's, as in `drgnx-config-update'.  Then the listeners run."
  (let ((def (drgnx-config--def name)))
    (when (eq (plist-get def :dir) 'project) (error "%s is read-only" name))
    (let* ((file (drgnx-config--path def nil))
           (want (plist-get def :version))
           (new (drgnx-config--text-read def file text)))
      (pcase (plist-get new :status)
        ('problem
         (let ((p (plist-get new :problem)))
           (signal 'drgnx-config-refused
                   (list (format "the new text of %s has a mistake at line %d: %s; it was not written"
                                 (drgnx-config--shown file) (plist-get p :line) (plist-get p :text))))))
        ('newer
         (signal 'drgnx-config-refused
                 (list (format "the new text of %s is in format %d, newer than this drgnx writes (%d); it was not written"
                               (drgnx-config--shown file) (plist-get new :version) want)))))
      (when (> (length (encode-coding-string text 'utf-8-unix)) (plist-get def :max-bytes))
        (signal 'drgnx-config-refused
                (list (format "the new text of %s is over %d bytes; it was not written"
                              (drgnx-config--shown file) (plist-get def :max-bytes)))))
      (let* ((target (drgnx-file--target file))
             (held (drgnx-file--lock target timeout)))
        (unwind-protect
            (let ((cur (car (drgnx-config--read def target))))
              (if (not stamp-p)
                  (drgnx-config--refuse file cur want)
                (unless (equal (drgnx-file-stamp target) expect-stamp)
                  (signal 'drgnx-config-refused
                          (list (format "%s changed since you opened it; nothing was written"
                                        (drgnx-config--shown file)))))
                (when (eq (plist-get cur :status) 'newer) (drgnx-config--refuse file cur want)))
              (drgnx-file-write-text target text))
          (drgnx-file--unlock held)))
      (plist-get (drgnx-config--refresh def name file t) :value))))

;;;; Commands

(defun drgnx-config--read-name (prompt)
  "A config file's name, read with PROMPT: those with a mistake first (project files are not offered)."
  (let ((bad nil) (good nil))
    (maphash (lambda (name def)
               (unless (eq (plist-get def :dir) 'project)
                 (if (eq (plist-get (gethash name drgnx-config--state) :status) 'problem)
                     (push (symbol-name name) bad)
                   (push (symbol-name name) good))))
             drgnx-config--defs)
    (let ((names (append (sort bad #'string<) (sort good #'string<))))
      (unless names (user-error "No config files are defined"))
      (intern (completing-read prompt
                               (lambda (string pred action)
                                 (if (eq action 'metadata)
                                     '(metadata (display-sort-function . identity) (cycle-sort-function . identity))
                                   (complete-with-action action names string pred)))
                               nil t)))))

(defun drgnx-config--after-save ()
  "After the user saved a buffer `drgnx-config-open' visited: read the file again now, so a fix applies at once
\(the notice clears, `drgnx-config-changed-functions' run with `drgnx-config-user-save' t).  Never signals."
  (when (and drgnx-config--visiting (drgnx-config-defined-p drgnx-config--visiting))
    (condition-case err
        (let ((drgnx-config-user-save t)) (drgnx-config-reread drgnx-config--visiting))
      (error (drgnx-config--warn (format "%s was saved, but reading it again failed: %s" drgnx-config--visiting
                                         (error-message-string err)))))))

(defun drgnx-config-open (name)
  "Visit config file NAME, at its mistake when it has one."
  (interactive (list (drgnx-config--read-name "Open config file: ")))
  (let ((problem (drgnx-config-problem name))
        (file (drgnx-config-file name)))
    (let ((default-directory "/")) (make-directory (file-name-directory file) t))
    (find-file file)
    (setq drgnx-config--visiting name)
    (add-hook 'after-save-hook #'drgnx-config--after-save nil t)      ; buffer-local: it goes with the buffer
    (when problem
      (goto-char (point-min))
      (forward-line (1- (plist-get problem :line)))
      (forward-char (max 0 (min (1- (plist-get problem :column)) (- (line-end-position) (point))))))))

(defun drgnx-config--reset (name)
  "Back up config file NAME and write its header and default, under its lock; the new applied value.  Never
prompts.  A file a newer drgnx wrote is refused (`drgnx-config-refused'); a project file is read-only."
  (let ((def (drgnx-config--def name)))
    (when (eq (plist-get def :dir) 'project) (error "%s is read-only" name))
    (let* ((file (drgnx-config--path def nil))
           (target (drgnx-file--target file))
           (held (drgnx-file--lock target 1.0)))
      (unwind-protect
          (let ((r (car (drgnx-config--read def target))) (want (plist-get def :version)))
            (when (and (integerp (plist-get r :version)) (> (plist-get r :version) want))
              (drgnx-config--refuse file (plist-put r :status 'newer) want))
            (drgnx-file-backup target)
            (let ((data (if (eq (plist-get def :shape) 'plist)
                            (drgnx-config--put-version (copy-tree (plist-get def :default)) want)
                          (plist-get def :default))))
              (drgnx-file-write target data :text (concat (plist-get def :header) (drgnx-config--pp data))
                                :max-bytes (plist-get def :max-bytes))))
        (drgnx-file--unlock held))
      (plist-get (drgnx-config--refresh def name file t) :value))))

(defun drgnx-config-reset (name)
  "Put config file NAME back to drgnx's defaults, after asking; the old file is backed up beside it."
  (interactive (list (drgnx-config--read-name "Reset config file: ")))
  (when noninteractive
    (user-error "Reset Config File… asks first, so it runs only in a session (it was not changed)"))
  (let ((file (drgnx-config-file name)))
    (when (yes-or-no-p (format "Reset %s to drgnx's defaults? A backup is kept. " (drgnx-config--shown file)))
      (drgnx-config--reset name)
      (message "drgnx: %s now holds the defaults; the old one is backed up beside it" (drgnx-config--shown file)))))

(defun drgnx-config-migrate (name)
  "Write config file NAME, made by an older drgnx, in this drgnx's format; the old file is backed up beside it."
  (interactive (list (drgnx-config--read-name "Migrate config file: ")))
  (let* ((r (drgnx-config-read name)) (file (plist-get r :file)))
    (unless (eq (plist-get r :status) 'migrated)
      (user-error "%s is not in an older format: there is nothing to migrate" (drgnx-config--shown file)))
    (drgnx-config-update name #'identity)
    (message "drgnx: %s now has format %d; the old one is backed up beside it"
             (drgnx-config--shown file) (plist-get (drgnx-config--def name) :version))))

(autoload 'drgnx-settings-file-sort "drgnx-settings-file"
  "Sort a settings file's entries by name, then its sections by kind and name." t)
(autoload 'drgnx-settings-turn-off-package-settings "drgnx-settings-apply"
  "Take settings.el's values for packages and Emacs out of Emacs now; drgnx's own stay." t)
(autoload 'drgnx-settings-turn-on-package-settings "drgnx-settings-apply"
  "Apply settings.el's values for packages and Emacs again now." t)
(autoload 'drgnx-settings-keep-module-entries "drgnx-settings-resolve"
  "Keep the modules' entries of a variable beside your value in settings.el (`:merge alist')." t)
(autoload 'drgnx-settings-migration-report "drgnx-settings-migrate"
  "What the move of the old settings files into settings.el did." t)
(autoload 'drgnx-settings-migrate-old-files "drgnx-settings-migrate"
  "Move the old settings files into settings.el now, while it does not exist." t)
(autoload 'drgnx-settings-migrate-move-away "drgnx-settings-migrate"
  "Move the old settings files settings.el already holds into migrated-DATE/." t)
(autoload 'drgnx-settings-lisp-files "drgnx-settings-lisp-page"
  "Your Lisp files in load order, what each sets at which line and whether it won." t)
(autoload 'drgnx-settings-lisp-page-open "drgnx-settings-lisp-page"
  "Open the file of the Lisp files page's line at point, at its line." t)
(autoload 'drgnx-settings-move-into-settings "drgnx-settings-move"
  "Move a setting's line of your Lisp into settings.el, with a diff first." t)
(autoload 'drgnx-settings-move-to-lisp "drgnx-settings-move"
  "Move a setting of settings.el to the end of config.el as a `setopt', with a diff first." t)
(autoload 'drgnx-settings-move-undo "drgnx-settings-move"
  "Put both files of the last move back as they were." t)

(defun drgnx-config-register-commands ()
  "Open, Reset and Migrate Config File… (Preferences), and Settings: Sort File, Turn Off / Turn On Package
Settings, Keep Module Entries…, Migration Report, Migrate Old Files, Move Old Files Away, Lisp Files (and its Open at
Line), Move into Settings…, Move to My Lisp… and Undo Move, in the registry."
  (drgnx-command-define 'config-open :category "Preferences" :title "Open Config File…" :command #'drgnx-config-open
                        :doc "Open one of drgnx's config files, at its mistake when it has one")
  (drgnx-command-define 'config-reset :category "Preferences" :title "Reset Config File…" :command #'drgnx-config-reset
                        :doc "Put one of drgnx's config files back to its defaults; the old one is backed up")
  (drgnx-command-define 'config-migrate :category "Preferences" :title "Migrate Config File…"
                        :command #'drgnx-config-migrate
                        :doc "Write a config file an older drgnx made in this drgnx's format; the old one is backed up")
  (drgnx-command-define 'settings-sort-file :category "Settings" :title "Sort File" :command #'drgnx-settings-file-sort
                        :doc "Sort settings.el or the workspace settings file you are in: entries by name, then sections")
  (drgnx-command-define 'settings-package-off :category "Settings" :title "Turn Off Package Settings"
                        :command #'drgnx-settings-turn-off-package-settings
                        :doc "Take settings.el's values for packages and Emacs out now (your Lisp's stay); drgnx's own stay")
  (drgnx-command-define 'settings-package-on :category "Settings" :title "Turn On Package Settings"
                        :command #'drgnx-settings-turn-on-package-settings
                        :doc "Apply settings.el's values for packages and Emacs again now, where your Lisp does not set them")
  (drgnx-command-define 'settings-keep-module-entries :category "Settings" :title "Keep Module Entries…"
                        :command #'drgnx-settings-keep-module-entries
                        :doc "Keep the modules' entries of an alist beside your value in Settings (merge per key)")
  (drgnx-command-define 'settings-migration-report :category "Settings" :title "Migration Report"
                        :command #'drgnx-settings-migration-report
                        :doc "What moved from the old files into settings.el, each key at its line; what stayed and why")
  (drgnx-command-define 'settings-migrate-old-files :category "Settings" :title "Migrate Old Files"
                        :command #'drgnx-settings-migrate-old-files
                        :doc "Move the old files (keys.eld, agents.eld …) into settings.el now, while it does not exist")
  (drgnx-command-define 'settings-move-old-files-away :category "Settings" :title "Move Old Files Away"
                        :command #'drgnx-settings-migrate-move-away
                        :doc "Move old settings files settings.el already holds into migrated-DATE/ (a copy is kept)")
  (drgnx-command-define 'settings-lisp-files :category "Settings" :title "Lisp Files"
                        :command #'drgnx-settings-lisp-files :menu '("Options")
                        :doc "Your Lisp files in load order: what each sets at which line, whether it won, its findings")
  (drgnx-command-define 'settings-lisp-files-open :category "Settings" :title "Open at Line"
                        :command #'drgnx-settings-lisp-page-open
                        :map '(drgnx-settings-lisp-page . drgnx-settings-lisp-page-mode-map)
                        :when (lambda () (derived-mode-p 'drgnx-settings-lisp-page-mode))
                        :doc "Open the file of this line of the Lisp files page, at its line")
  (drgnx-command-define 'settings-move-into :category "Settings" :title "Move into Settings…"
                        :command #'drgnx-settings-move-into-settings
                        :doc "Move a setting's line of your Lisp into settings.el: a diff of both files first, one Undo")
  (drgnx-command-define 'settings-move-to-lisp :category "Settings" :title "Move to My Lisp…"
                        :command #'drgnx-settings-move-to-lisp
                        :doc "Move a setting of settings.el to the end of config.el as a setopt: a diff first, one Undo")
  (drgnx-command-define 'settings-move-undo :category "Settings" :title "Undo Move"
                        :command #'drgnx-settings-move-undo
                        :doc "Put both files of the last Move into Settings or Move to My Lisp back as they were"))

(provide 'drgnx-config)
;;; drgnx-config.el ends here
