;;; drgnx-settings-migrate.el --- Settings: the move from the old files into settings.el, and the shim -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 14 (design §14, §5.4; docs/develop/settings.md, "The migration and the shim").
;; - `drgnx-settings-migrate-maybe' runs first at every start, also in safe mode, and acts only while settings.el does
;;   not exist: agents.eld, ai.eld, keys.eld, modules.eld, large-files.eld and session.eld are read through the config
;;   layer, their keys become entries (`drgnx-settings-migrate-table'; a comment above a key goes above its entry),
;;   settings.el is written once, read back and compared with the old files' values.  Any difference removes it again
;;   and moves nothing.  Then each old file is copied to <state>/backups/migrated-DATE/ and moved to
;;   <config>/migrated-DATE/, and the report goes to <state>/settings-migration.eld.  A file with a mistake (or keys
;;   this drgnx does not know, or a newer format) stays where it is and is still read.
;; - The shim: while an area is in `drgnx-settings-shim-areas', `drgnx-config-get' of its old name gives the plist
;;   the settings hold (`drgnx-settings-migrate-shim').  Tasks 15 and 16 take the areas out.
;; - Settings: Migration Report, Migrate Old Files and Move Old Files Away; the doctor's `settings-migrated' check.
;; Nothing here prompts; the start-up call never signals.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-settings-file)

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-lisp-index-file "drgnx-lisp-index" (file))
(declare-function drgnx-large-files--define-user-config "drgnx-large-files" ())

(defconst drgnx-settings-migrate-names '(agents ai keys modules large-files session)
  "The config files that fold into settings.el (design §5.4), in the order the migration reads them.
Each is NAME.eld in the config dir.")

(defconst drgnx-settings-migrate-table
  '(((agents . :profiles) . drgnx-agents-profiles)
    ((agents . :default) . drgnx-agents-default)
    ((agents . :mcp) . drgnx-agents-mcp)
    ((agents . :openrouter) . drgnx-agents-openrouter)
    ((agents . :routes) . drgnx-agents-routes)
    ((ai . :providers) . drgnx-ai-providers)
    ((ai . :roles) . drgnx-ai-roles)
    ((keys . :layers) . drgnx-keys-layers)
    ((keys . :pending-layers) . drgnx-keys-pending-layers)
    ((keys . :bind) . drgnx-keys-bind)
    ((keys . :unbind) . drgnx-keys-unbind)
    ((keys . :mac-option) . drgnx-keys-mac-option)
    ((keys . :tty-fallback) . drgnx-keys-tty-fallback)
    ((modules . :disabled) . drgnx-modules-disabled)
    ((modules . :enabled) . drgnx-modules-enabled)
    ((modules . :flags) . drgnx-modules-flags)
    ((modules . :external) . drgnx-modules-external)
    ((modules . :theme) . drgnx-look-theme)
    ((large-files . :ask-above) . drgnx-large-files-ask-above)
    ((large-files . :chunks-above) . drgnx-large-files-chunks-above)
    ((large-files . :chunk-size) . drgnx-large-files-chunk-size)
    ((session . :keep-running) . drgnx-session-keep-running))
  "Every key of the old files and its setting: ((FILE . KEY) . VAR), FILE a config file's name (FILE.eld).
The setting is drgnx-AREA-KEY (design §5.4), except modules.eld's `:theme', which is `drgnx-look-theme'.")

(defconst drgnx-settings-migrate-unset-when-nil '((keys . :layers))
  "Keys whose nil means \"not chosen\": they get no entry.  keys.eld's `:layers' nil is drgnx's default stack
\(`drgnx-keys-layers'); an entry would set that stack to nil.  The shim gives nil for them, as the old file did.")

(defconst drgnx-settings-migrate--features
  '((agents . drgnx-agents) (ai . drgnx-ai) (keys . drgnx-keys) (modules . drgnx-modules) (session . drgnx-session))
  "The features that define each old config file; large-files.eld is its module's (loaded by its path).")

(defconst drgnx-settings-migrate--strict '(agents)
  "The areas whose settings are `:on-error strict': while settings.el has a mistake, the shim gives their defaults
rather than its last good copy (design §5.2).")

;;;; The table, the old files and the settings

(defun drgnx-settings-migrate--rows (name)
  "Config file NAME's rows of the table: ((KEY . VAR)…), in order."
  (cl-loop for ((n . key) . var) in drgnx-settings-migrate-table when (eq n name) collect (cons key var)))

(defun drgnx-settings-migrate--unset-p (name key value)
  "Whether KEY of config file NAME holding VALUE gets no entry (`drgnx-settings-migrate-unset-when-nil')."
  (and (null value) (member (cons name key) drgnx-settings-migrate-unset-when-nil) t))

(defun drgnx-settings-migrate--plist (name data)
  "DATA, config file NAME's data, as the plist its settings hold: each key of the table that DATA has, in the
table's order, without `:version', keys the table does not name and a nil that means not chosen."
  (let ((out nil))
    (when (proper-list-p data)
      (pcase-dolist (`(,key . ,_var) (drgnx-settings-migrate--rows name))
        (when-let* ((m (plist-member data key)))
          (unless (drgnx-settings-migrate--unset-p name key (cadr m))
            (setq out (append out (list key (cadr m))))))))
    out))

(defun drgnx-settings-migrate--assemble (name values)
  "The plist of config file NAME that VALUES, settings as ((VAR . VALUE)…), give: each key of the table whose
setting has a value, in the table's order."
  (let ((out nil))
    (pcase-dolist (`(,key . ,var) (drgnx-settings-migrate--rows name))
      (when-let* ((cell (assq var values))) (setq out (append out (list key (cdr cell))))))
    out))

(defun drgnx-settings-migrate--doc-values (doc)
  "DOC's top-level entries as ((VAR . VALUE)…), in file order."
  (cl-loop for e in (drgnx-settings-doc-entries doc)
           unless (or (drgnx-settings-entry-scope e) (keywordp (drgnx-settings-entry-var e)))
           collect (cons (drgnx-settings-entry-var e) (drgnx-settings-entry-value e))))

(defun drgnx-settings-migrate--form-values (form)
  "FORM, settings.el's data form as the config layer reads it, as ((VAR . VALUE)…): its top-level entries by the
rules of `drgnx-settings-file-parse' (the first of two wins, one leading quote dropped)."
  (when (and (consp form) (proper-list-p form))
    (let ((rest (cdr form)) (out nil))
      (while (and (keywordp (car rest)) (cdr rest)) (setq rest (cddr rest)))
      (dolist (x rest)
        (when (and (consp x) (proper-list-p x) (car x) (symbolp (car x)) (not (keywordp (car x))) (not (eq (car x) t))
                   (or (= (length x) 2) (and (= (length x) 4) (eq (nth 2 x) :merge))))
          (unless (assq (car x) out) (push (cons (car x) (drgnx-settings-file--unquote (cadr x))) out))))
      (nreverse out))))

(defun drgnx-settings-migrate--old-file (name)
  "Where old config file NAME is: its definition's file, else NAME.eld in the config dir."
  (if (drgnx-config-defined-p name) (drgnx-config-file name)
    (let ((default-directory "/")) (expand-file-name (format "%s.eld" name) (drgnx-user-dir)))))

(defun drgnx-settings-migrate--there-p (file)
  "Whether FILE exists (a dangling symbolic link counts)."
  (let ((file-name-handler-alist nil)) (or (file-exists-p file) (file-symlink-p file))))

(defun drgnx-settings-migrate--settings-there-p ()
  "Whether settings.el exists."
  (drgnx-settings-migrate--there-p (drgnx-config-file 'settings)))

(defun drgnx-settings-migrate--ensure-defs (names)
  "Define the config files of NAMES not defined yet; the names defined only for this, to undefine after.
large-files.eld is defined by its module (loaded by its path, which registers nothing); the others by their core
feature.  One that fails to load is a message: its file then stays."
  (let ((temp nil))
    (dolist (name names)
      (unless (drgnx-config-defined-p name)
        (condition-case err
            (if (eq name 'large-files)
                (let ((before (cl-remove-if #'drgnx-config-defined-p '(large-files))))
                  (unless (fboundp 'drgnx-large-files--define-user-config)
                    (load (expand-file-name "modules/editor/drgnx-large-files" drgnx-dir) nil t))
                  (drgnx-large-files--define-user-config)
                  (setq temp (append before temp)))
              (require (alist-get name drgnx-settings-migrate--features)))
          (error (drgnx-settings-migrate--warn (format "%s.eld could not be read now: %s"
                                                       name (error-message-string err)))))))
    temp))

(defmacro drgnx-settings-migrate--with-defs (names &rest body)
  "BODY with the config files of NAMES defined (`drgnx-settings-migrate--ensure-defs'), undefined after."
  (declare (indent 1) (debug t))
  (let ((temp (make-symbol "temp")))
    `(let ((,temp (drgnx-settings-migrate--ensure-defs ,names)))
       (unwind-protect (progn ,@body)
         (mapc #'drgnx-config-undefine ,temp)))))

(defun drgnx-settings-migrate--present ()
  "The names of the old config files that exist."
  (cl-remove-if-not (lambda (n) (drgnx-settings-migrate--there-p (drgnx-settings-migrate--old-file n)))
                    drgnx-settings-migrate-names))

(defun drgnx-settings-migrate--old (name)
  "Old config file NAME as the migration finds it: nil when it is absent or holds no form, else
\(:name :file :data :text) for a file that moves, or (:name :file :why) for one that stays, WHY saying why: a
mistake, keys this drgnx does not know, a newer format, or a definition that did not load."
  (let ((file (drgnx-settings-migrate--old-file name)))
    (when (drgnx-settings-migrate--there-p file)
      (if (not (drgnx-config-defined-p name))
          (list :name name :file file :why "drgnx could not load what reads it")
        (let* ((r (drgnx-config-read name)) (p (plist-get r :problem)))
          (pcase (plist-get r :status)
            ('absent nil)
            ((or 'ok 'migrated)
             (if-let* ((unknown (plist-get r :unknown-keys)))
                 (list :name name :file file
                       :why (format "keys this drgnx does not know: %s"
                                    (mapconcat (lambda (k) (mapconcat (lambda (x) (format "%s" x)) k " ")) unknown ", ")))
               (list :name name :file file :data (plist-get r :data)
                     :text (plist-get (drgnx-file-read file :max-bytes (plist-get (drgnx-config-definition name) :max-bytes))
                                      :text))))
            ('newer (list :name name :file file :why (format "written by a newer drgnx (format %s)" (plist-get r :version))))
            (_ (list :name name :file file
                     :why (format "a mistake at line %s: %s" (plist-get p :line) (plist-get p :text))))))))))

;;;; Converting

(defun drgnx-settings-migrate--comments (text)
  "The comments of TEXT, an old plist file, by key: ((KEY . LINES)…).  LINES are the `;' lines directly above the
key (no blank line between) and the comment at the end of its value's last line, each trimmed.  nil when TEXT is not
a plist that reads: a comment inside a value, or outside the keys, is not carried (the old file keeps it)."
  (when text
    (condition-case nil
        (drgnx-settings-file--in-text text
          (forward-comment (buffer-size))
          (when (eq (char-after) ?\()
            (forward-char 1)
            (let ((out nil))
              (dolist (item (drgnx-config--items 'plist))
                (pcase-let ((`(,start ,stop ,eol) (drgnx-settings-file--block (nth 1 item) (nth 2 item))))
                  (let ((lines (append
                                (and (< start (nth 1 item))
                                     (split-string (buffer-substring-no-properties
                                                    start (save-excursion (goto-char (nth 1 item)) (line-beginning-position)))
                                                   "\n" t "[ \t]+"))
                                (and eol (list (string-trim (buffer-substring-no-properties (nth 2 item) stop)))))))
                    (setq lines (cl-remove-if-not (lambda (l) (string-prefix-p ";" l)) lines))
                    (when lines (push (cons (car item) lines) out)))))
              (nreverse out))))
      (error nil))))

(defun drgnx-settings-migrate--convert (old)
  "OLD, a file that moves (`drgnx-settings-migrate--old'), as (:entries ((VAR VALUE COMMENTS NAME KEY)…) :skipped
\((NAME KEY)…)), or (:why TEXT) when a value cannot be written as data."
  (let ((name (plist-get old :name)) (data (plist-get old :data))
        (comments (drgnx-settings-migrate--comments (plist-get old :text)))
        (entries nil) (skipped nil))
    (catch 'why
      (pcase-dolist (`(,key . ,var) (drgnx-settings-migrate--rows name))
        (when-let* ((m (and (proper-list-p data) (plist-member data key))))
          (let ((value (cadr m)))
            (cond ((drgnx-settings-migrate--unset-p name key value) (push (list name key) skipped))
                  ((drgnx-settings-file--why-not value)
                   (throw 'why (list :why (format "the value of %s cannot be written as data: %s"
                                                  key (drgnx-settings-file--why-not value)))))
                  ((not (eq (drgnx-settings-file--unquote value) value))
                   (throw 'why (list :why (format "the value of %s, (%s …), would read as its argument" key (car value)))))
                  (t (push (list var value (cdr (assq key comments)) name key) entries))))))
      (list :entries (nreverse entries) :skipped (nreverse skipped)))))

(defun drgnx-settings-migrate--entry-text (var value)
  "The text of VAR's entry with VALUE in a new settings.el, at column 1."
  (drgnx-settings-file--entry-text var value nil 1))

(defun drgnx-settings-migrate--text (entries)
  "The text of a new settings.el holding ENTRIES, ((VAR VALUE COMMENTS …)…): the header, then the entries sorted
by name, each with its comment lines above it."
  (concat drgnx-settings-file-global-header
          (format "(drgnx-settings\n :version %d" drgnx-settings-file-version)
          (mapconcat (lambda (e) (concat (mapconcat (lambda (c) (concat "\n " c)) (nth 2 e) "")
                                         "\n " (drgnx-settings-migrate--entry-text (car e) (nth 1 e))))
                     (sort (copy-sequence entries) (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))
                     "")
          ")\n"))

;;;; Writing, comparing, moving

(defun drgnx-settings-migrate--difference (doc want)
  "Why DOC, settings.el read back, does not hold WANT, ((NAME . PLIST)…) for every file that moves: a text, or nil
when every file's plist is what DOC's entries give (`drgnx-settings-migrate--assemble') and DOC holds nothing else."
  (if (or (drgnx-settings-doc-failed doc) (drgnx-settings-doc-problems doc))
      (format "it does not read cleanly: %s" (plist-get (car (drgnx-settings-doc-problems doc)) :text))
    (let* ((values (drgnx-settings-migrate--doc-values doc))
           (bad (cl-find-if-not (lambda (w) (equal (drgnx-settings-migrate--assemble (car w) values) (cdr w))) want)))
      (cond (bad (format "%s.eld's values differ" (car bad)))
            ((/= (length values) (cl-loop for w in want sum (/ (length (cdr w)) 2)))
             "it holds other entries")))))

(defun drgnx-settings-migrate--write (file text want)
  "Write TEXT as the new settings FILE once, under its lock, only while FILE does not exist; read it back from disk
and compare it with WANT (`drgnx-settings-migrate--difference').  The doc read back; (differs WHY) after the file was
removed again; or `exists' when FILE appeared meanwhile (nothing written)."
  (let* ((target (drgnx-file--target file))
         (held (drgnx-file--lock target drgnx-settings-file-lock-timeout)))
    (unwind-protect
        (if (drgnx-settings-migrate--there-p target) 'exists
          (drgnx-file-write-text target text)
          (let* ((doc (drgnx-settings-file-read target 'drgnx-settings))
                 (why (drgnx-settings-migrate--difference doc want)))
            (if (not why) doc
              (let ((file-name-handler-alist nil)) (delete-file target))
              (list 'differs why))))
      (drgnx-file--unlock held))))

(defun drgnx-settings-migrate--dirs ()
  "Where this move puts the old files: (MIGRATED . BACKUP), <config>/migrated-YYYY-MM-DD/ and
<state>/backups/migrated-YYYY-MM-DD/, with -2, -3 … after the date when either exists already."
  (let ((day (format-time-string "%Y-%m-%d")) (n 1) (dirs nil) (default-directory "/"))
    (while (let ((base (if (= n 1) (format "migrated-%s" day) (format "migrated-%s-%d" day n))))
             (setq dirs (cons (file-name-as-directory (expand-file-name base (drgnx-user-dir)))
                              (file-name-as-directory (expand-file-name base (expand-file-name "backups" (drgnx-state-dir))))))
             (or (file-exists-p (car dirs)) (file-exists-p (cdr dirs))))
      (setq n (1+ n)))
    dirs))

(defun drgnx-settings-migrate--warn (text)
  "A `warn' notice of source `config'.  Never signals."
  (condition-case failed
      (progn (require 'drgnx-notice) (drgnx-notify 'config 'warn text))
    (error (message "Settings: %s (not recorded: %s)" text (error-message-string failed)))))

(defun drgnx-settings-migrate--move (files dirs)
  "Copy each of FILES to the backup dir of DIRS, (MIGRATED . BACKUP), then move it into the migrated dir: the files
moved.  A file whose copy or move fails stays where it is (one notice); it is still read."
  (let ((moved nil) (file-name-handler-alist nil))
    (dolist (f files)
      (condition-case err
          (let ((name (file-name-nondirectory f)))
            (make-directory (cdr dirs) t)
            (make-directory (car dirs) t)
            (copy-file f (expand-file-name name (cdr dirs)) nil t)
            (rename-file f (expand-file-name name (car dirs)))
            (push f moved))
        (file-error (drgnx-settings-migrate--warn (format "%s was not moved into %s: %s; it stays and is still read"
                                                          (abbreviate-file-name f) (abbreviate-file-name (car dirs))
                                                          (error-message-string err))))))
    (nreverse moved)))

(defun drgnx-settings-migrate--reread (files)
  "Read the config files of FILES (old file paths) again, so what was applied from them goes.  Never signals."
  (dolist (f files)
    (let ((name (intern (file-name-base f))))
      (when (drgnx-config-defined-p name)
        (condition-case nil (drgnx-config-reread name) (error nil))))))

(defun drgnx-settings-migrate--custom ()
  "custom.el's `custom-set-variables' entries whose values are data, which Settings could hold: ((VAR LINE)…)."
  (let ((file (or custom-file (expand-file-name "custom.el" (drgnx-user-dir)))))
    (when (file-exists-p file)
      (condition-case nil
          (progn
            (require 'drgnx-lisp-index)
            (cl-loop for s in (plist-get (drgnx-lisp-index-file file) :setters)
                     when (and (eq (plist-get s :kind) 'custom-set-variables) (plist-get s :const-p))
                     collect (list (plist-get s :var) (plist-get s :line))))
        (error nil)))))

;;;; The report

(defun drgnx-settings-migrate-report-file ()
  "Where the last migration's report is kept: <state>/settings-migration.eld."
  (let ((default-directory "/")) (expand-file-name "settings-migration.eld" (drgnx-state-dir))))

(defun drgnx-settings-migrate--save-report (report)
  "Keep REPORT in `drgnx-settings-migrate-report-file'.  Never signals."
  (condition-case err (drgnx-file-write (drgnx-settings-migrate-report-file) report :pretty t)
    (error (drgnx-settings-migrate--warn (format "the migration report was not kept: %s" (error-message-string err))))))

(defun drgnx-settings-migrate-read-report ()
  "The last migration's report (a plist), or nil when there is none."
  (let ((r (drgnx-file-read (drgnx-settings-migrate-report-file))))
    (and (eq (plist-get r :status) 'ok) (plist-get r :data))))

(defun drgnx-settings-migrate--run ()
  "The migration, design §14 steps 1.1–1.4, when settings.el does not exist: the report, or nil when no old file is
there.  Its :status is `migrated' (settings.el written and the old files moved), `differs' (settings.el did not read
back as the old files: removed again, nothing moved), `exists' (settings.el appeared meanwhile) or `nothing' (no file
could move).  May signal; `drgnx-settings-migrate-maybe' catches."
  (when-let* ((present (drgnx-settings-migrate--present)))
    (drgnx-settings-migrate--with-defs present
      (let ((settings (drgnx-config-file 'settings))
            (moving nil) (stayed nil) (entries nil) (skipped nil))
        (dolist (old (delq nil (mapcar #'drgnx-settings-migrate--old present)))
          (let ((conv (and (not (plist-get old :why)) (drgnx-settings-migrate--convert old))))
            (if (or (plist-get old :why) (plist-get conv :why))
                (push (list (plist-get old :file) (or (plist-get old :why) (plist-get conv :why))) stayed)
              (push old moving)
              (setq entries (append entries (plist-get conv :entries))
                    skipped (append skipped (plist-get conv :skipped))))))
        (setq moving (nreverse moving) stayed (nreverse stayed))
        (let* ((base (list :version 1 :date (format-time-string "%Y-%m-%d") :settings settings :stayed stayed
                           :custom (drgnx-settings-migrate--custom)))
               (done (and moving (drgnx-settings-migrate--write
                                  settings (drgnx-settings-migrate--text entries)
                                  (mapcar (lambda (o) (cons (plist-get o :name)
                                                            (drgnx-settings-migrate--plist (plist-get o :name)
                                                                                           (plist-get o :data))))
                                          moving)))))
          (cond
           ((null moving) (append (list :status 'nothing) base))
           ((eq done 'exists) (append (list :status 'exists) base))
           ((eq (car-safe done) 'differs)
            (append (list :status 'differs :why (cadr done)
                          :files (mapcar (lambda (o) (plist-get o :file)) moving))
                    base))
           (t
            (let* ((dirs (drgnx-settings-migrate--dirs))
                   (files (mapcar (lambda (o) (plist-get o :file)) moving))
                   (moved (drgnx-settings-migrate--move files dirs))
                   (lines (mapcar (lambda (e) (cons (drgnx-settings-entry-var e) (drgnx-settings-entry-line e)))
                                  (drgnx-settings-doc-entries done))))
              (drgnx-settings-migrate--reread moved)
              (append (list :status 'migrated :moved-to (car dirs) :backup (cdr dirs) :files moved
                            :not-moved (cl-set-difference files moved :test #'equal)
                            :entries (mapcar (lambda (e) (list (nth 3 e) (nth 4 e) (car e) (cdr (assq (car e) lines))))
                                             entries)
                            :skipped skipped)
                      base)))))))))

(defconst drgnx-settings-migrate--two-machines
  "Commit and push your config folder before you start drgnx on another machine, and pull there first. Update drgnx
on your other machines: an older drgnx finds no agents.eld and uses its defaults."
  "What the report and the notice say about other machines (design §14 items 4 and 8).")

(defun drgnx-settings-migrate--say (report)
  "The notice for REPORT: one for a migration, one for a difference; nothing otherwise.  Never signals."
  (condition-case err
      (pcase (plist-get report :status)
        ('migrated
         (require 'drgnx-notice)
         (let ((n (length (plist-get report :files))))
           (drgnx-notify 'config 'info (format "Your settings moved into settings.el (%d file%s)" n (if (= n 1) "" "s"))
                         :id 'settings-migration :command 'settings-migration-report
                         :detail drgnx-settings-migrate--two-machines)))
        ('differs
         (require 'drgnx-notice)
         (drgnx-notify 'config 'fail (format "Your settings were not moved into settings.el (%s); the old files stay"
                                             (plist-get report :why))
                       :id 'settings-migration :command 'settings-migration-report)))
    (error (message "Settings: the migration's notice failed: %s" (error-message-string err)))))

(defun drgnx-settings-migrate-maybe ()
  "Move the old settings files into settings.el, once: only while settings.el does not exist (design §14).
Called first at every start, also in safe mode.  The report (also kept in `drgnx-settings-migrate-report-file'), or
nil when there was nothing to do.  Never signals and never prompts: a failure is one notice, and what was not moved
is still read."
  (condition-case err
      (let ((inhibit-interaction t))
        (unless (drgnx-settings-migrate--settings-there-p)
          (when-let* ((report (drgnx-settings-migrate--run)))
            (when (memq (plist-get report :status) '(migrated differs))
              (drgnx-settings-migrate--save-report report)
              (drgnx-settings-migrate--say report))
            report)))
    (error (drgnx-settings-migrate--warn (format "the old settings files were not moved into settings.el: %s"
                                                 (error-message-string err)))
           nil)))

(defun drgnx-settings-migrate--report-text (report)
  "REPORT as the text Settings: Migration Report shows."
  (let ((shown (lambda (f) (let ((file-name-handler-alist nil)) (abbreviate-file-name f)))))
    (with-temp-buffer
      (insert (format "Settings: Migration Report (%s)\n\n" (plist-get report :date)))
      (pcase (plist-get report :status)
        ('migrated
         (insert (format "Your old settings files moved into %s.\nThey are in %s, and a copy is in %s.\n"
                         (funcall shown (plist-get report :settings)) (funcall shown (plist-get report :moved-to))
                         (funcall shown (plist-get report :backup))))
         (insert "\nEach old key and its setting (its line in settings.el):\n")
         (pcase-dolist (`(,name ,key ,var ,line) (plist-get report :entries))
           (insert (format "  %s.eld %s → %s (line %s)\n" name key var (or line "?"))))
         (when-let* ((skipped (plist-get report :skipped)))
           (insert "\nNo entry needed (nil means drgnx's default):\n")
           (pcase-dolist (`(,name ,key) skipped)
             (insert (format "  %s.eld %s nil\n" name key))))
         (insert "\nA comment above a key moved above its entry; a comment inside a value or outside the keys did not \
\(the old file keeps it).\n")
         (when-let* ((left (plist-get report :not-moved)))
           (insert "\nCopied into settings.el but not moved (still read over it; Settings: Move Old Files Away):\n")
           (dolist (f left) (insert (format "  %s\n" (funcall shown f))))))
        ('differs
         (insert (format "Your old settings files were NOT moved: settings.el, read back, did not hold the same values \
\(%s).\nsettings.el was removed again and nothing moved; drgnx reads the old files as before. Settings: Migrate Old \
Files tries again.\n" (plist-get report :why))))
        (_ (insert "Nothing moved.\n")))
      (when-let* ((stayed (plist-get report :stayed)))
        (insert "\nWhat stayed, and why (each is still read where it is; fix it, then Settings: Migrate Old Files while \
settings.el does not exist, or set its values in Settings):\n")
        (pcase-dolist (`(,file ,why) stayed)
          (insert (format "  %s: %s\n" (funcall shown file) why))))
      (when-let* ((custom (plist-get report :custom)))
        (insert "\ncustom.el entries Settings could hold (Tidy moves them):\n")
        (pcase-dolist (`(,var ,line) custom)
          (insert (format "  %s (custom.el line %s)\n" var line))))
      (when (eq (plist-get report :status) 'migrated)
        (insert "\nTwo machines: " (replace-regexp-in-string "\n" " " drgnx-settings-migrate--two-machines) "\n"))
      (buffer-string))))

;;;; Commands

(defun drgnx-settings-migration-report ()
  "Settings: Migration Report: each old key and its setting at its settings.el line, what stayed and why, and the
custom.el entries Tidy could move (design §14)."
  (interactive)
  (let ((report (drgnx-settings-migrate-read-report)))
    (unless report
      (user-error "Settings: no migration report here (%s)" (abbreviate-file-name (drgnx-settings-migrate-report-file))))
    (let ((buf (get-buffer-create "*drgnx settings migration*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (drgnx-settings-migrate--report-text report))
          (goto-char (point-min)))
        (special-mode))
      (when (called-interactively-p 'any) (pop-to-buffer buf))
      buf)))

(defun drgnx-settings-migrate-old-files ()
  "Settings: Migrate Old Files: move agents.eld, ai.eld, keys.eld, modules.eld, large-files.eld and session.eld into
settings.el now, as the first start does.  Only while settings.el does not exist."
  (interactive)
  (when (drgnx-settings-migrate--settings-there-p)
    (user-error "Settings: settings.el exists, so the old files are not moved again (Settings: Move Old Files Away)"))
  (let ((report (let ((inhibit-interaction t)) (drgnx-settings-migrate--run))))
    (if (null report) (message "Settings: there are no old settings files to move")
      (when (memq (plist-get report :status) '(migrated differs))
        (drgnx-settings-migrate--save-report report)
        (drgnx-settings-migrate--say report)
        (when (called-interactively-p 'any) (call-interactively #'drgnx-settings-migration-report)))
      (pcase (plist-get report :status)
        ('nothing (message "Settings: nothing moved: %s"
                           (mapconcat (lambda (s) (format "%s (%s)" (file-name-nondirectory (car s)) (cadr s)))
                                      (plist-get report :stayed) "; ")))
        ('exists (message "Settings: settings.el appeared meanwhile; nothing moved"))))
    report))

(defun drgnx-settings-migrate-leftovers ()
  "The old settings files still in the config dir whose values settings.el holds already (a crash between the
write and the move, or a copy that came back): their paths.  nil while settings.el is absent or does not read."
  (when (drgnx-settings-migrate--settings-there-p)
    (let ((doc (drgnx-settings-file-read (drgnx-config-file 'settings) 'drgnx-settings)))
      (unless (drgnx-settings-doc-failed doc)
        (let ((values (drgnx-settings-migrate--doc-values doc)) (present (drgnx-settings-migrate--present)))
          (drgnx-settings-migrate--with-defs present
            (cl-loop for name in present
                     for old = (drgnx-settings-migrate--old name)
                     when (and old (not (plist-get old :why))
                               (equal (drgnx-settings-migrate--plist name (plist-get old :data))
                                      (drgnx-settings-migrate--assemble name values)))
                     collect (plist-get old :file))))))))

(defun drgnx-settings-migrate-move-away ()
  "Settings: Move Old Files Away: the old settings files settings.el already holds (`drgnx-settings-migrate-leftovers')
go to <config>/migrated-DATE/, a copy to <state>/backups/.  One that differs from settings.el stays.  The files moved."
  (interactive)
  (let ((files (drgnx-settings-migrate-leftovers)))
    (if (null files)
        (progn (when (called-interactively-p 'any) (message "Settings: no old settings file is left over")) nil)
      (let* ((dirs (drgnx-settings-migrate--dirs)) (moved (drgnx-settings-migrate--move files dirs)))
        (drgnx-settings-migrate--reread moved)
        (when (called-interactively-p 'any)
          (message "Settings: %d old file%s moved to %s (a copy in %s)" (length moved) (if (= (length moved) 1) "" "s")
                   (abbreviate-file-name (car dirs)) (abbreviate-file-name (cdr dirs))))
        moved))))

;;;; The shim

(defvar drgnx-settings-migrate--shim-cache nil
  "((NAME FORM OLD . VALUE)…): the shim's last value per area, for settings.el's data form FORM and the old file's
value OLD (both compared by `eq').  Bounded: one entry per area.")

(defvar drgnx-settings-migrate--values-cache nil
  "(FORM . VALUES): settings.el's data form last read and its entries (`drgnx-settings-migrate--form-values').")

(defun drgnx-settings-migrate--settings-values (name)
  "settings.el's top-level values as the shim reads them for area NAME, and the data form they come from: (FORM .
VALUES).  The config layer's applied form: its last good copy while the file has a mistake, except for a strict
area (nothing then: its defaults)."
  (let* ((st (drgnx-config--current 'settings nil))
         (form (unless (and (eq (plist-get st :status) 'problem) (memq name drgnx-settings-migrate--strict))
                 (plist-get st :value))))
    (unless (eq form (car drgnx-settings-migrate--values-cache))
      (setq drgnx-settings-migrate--values-cache (cons form (drgnx-settings-migrate--form-values form))))
    drgnx-settings-migrate--values-cache))

(defun drgnx-settings-migrate-shim (name state)
  "The value `drgnx-config-get' gives for old config file NAME while it is in `drgnx-settings-shim-areas'.
STATE is the file's applied state (:value :status …).  The plist settings.el's entries give
\(`drgnx-settings-migrate-table'), with the keys of an old file that is still there and reads well over it (a writer
that has not moved to the settings yet); STATE's value when settings.el has no entry for NAME, so a file with a
mistake that stayed is read as before.  Never signals: on an error, STATE's value."
  (let ((old (plist-get state :value)))
    (condition-case nil
        (let* ((sv (drgnx-settings-migrate--settings-values name))
               (hit (assq name drgnx-settings-migrate--shim-cache)))
          (if (and hit (eq (nth 1 hit) (car sv)) (eq (nth 2 hit) old)) (nthcdr 3 hit)
            (let ((plist (drgnx-settings-migrate--assemble name (cdr sv))))
              (if (null plist) (setq plist old)
                (when (and (memq (plist-get state :status) '(ok migrated newer)) (proper-list-p old))
                  (cl-loop for (k v) on old by #'cddr unless (eq k :version) do (setq plist (plist-put plist k v)))))
              (setf (alist-get name drgnx-settings-migrate--shim-cache) (cons (car sv) (cons old plist)))
              plist)))
      (error old))))

(provide 'drgnx-settings-migrate)
;;; drgnx-settings-migrate.el ends here
