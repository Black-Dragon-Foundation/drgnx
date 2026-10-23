;;; settings-migrate-test.el --- batch tests: the old config files move into settings.el once; the shim -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config' (config and state folders under a temp root, so nothing reaches
;; ~), with `custom-file' in that config folder and `drgnx-notify' recorded.  The old files are copied from
;; test/fixtures/settings/migrate/ (synthetic, with comments; ai-mistaken.eld fails ai.eld's schema).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-registry)
(require 'drgnx-notice)
(require 'drgnx-agents)
(require 'drgnx-ai)
(require 'drgnx-keys)
(require 'drgnx-modules)
(require 'drgnx-session)
(require 'drgnx-doctor)
(require 'drgnx-settings-migrate)

(defconst drgnx-settings-migrate-test--fixtures (expand-file-name "test/fixtures/settings/migrate/" drgnx-dir)
  "The synthetic old files.")

(defvar drgnx-settings-migrate-test--notices nil "The `drgnx-notify' calls of the running test, newest first.")

(defun drgnx-settings-migrate-test--large-files ()
  "Define large-files.eld as its module's setup does."
  (unless (fboundp 'drgnx-large-files--define-config)
    (load (expand-file-name "modules/editor/drgnx-large-files" drgnx-dir) nil t))
  (drgnx-large-files--define-config))

(defmacro drgnx-settings-migrate-test--with (&rest body)
  "BODY under `drgnx-test-with-config', large-files.eld defined, every area in the shim, its caches empty, `custom-file' in the temp
config folder, `inhibit-interaction' t and every `drgnx-notify' recorded in `drgnx-settings-migrate-test--notices'."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-config
     (let ((custom-file (expand-file-name "custom.el" (drgnx-user-dir)))
           (inhibit-interaction t)
           ;; agents and ai left the shim's areas (Task 15); the shim still answers for them here
           (drgnx-settings-shim-areas drgnx-settings-migrate-names)
           (drgnx-settings-migrate--shim-cache nil)
           (drgnx-settings-migrate--values-cache nil)
           (drgnx-settings-migrate-test--notices nil))
       (cl-letf (((symbol-function 'drgnx-notify)
                  (lambda (&rest args) (push args drgnx-settings-migrate-test--notices) nil)))
         (drgnx-settings-migrate-test--large-files)
         ,@body))))

(defun drgnx-settings-migrate-test--file (name)
  "Old config file NAME's path."
  (expand-file-name (format "%s.eld" name) (drgnx-user-dir)))

(defun drgnx-settings-migrate-test--put (name &optional fixture)
  "Copy FIXTURE (default NAME.eld) of the fixtures to old config file NAME."
  (let ((to (drgnx-settings-migrate-test--file name)))
    (make-directory (file-name-directory to) t)
    (copy-file (expand-file-name (or fixture (format "%s.eld" name)) drgnx-settings-migrate-test--fixtures) to t)
    to))

(defun drgnx-settings-migrate-test--write (file text)
  "Write TEXT to FILE (UTF-8), making its folder."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

(defun drgnx-settings-migrate-test--put-all ()
  "All six old files."
  (mapc #'drgnx-settings-migrate-test--put drgnx-settings-migrate-names))

(defun drgnx-settings-migrate-test--text (file)
  "FILE's text, or nil when it is missing."
  (when (file-exists-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
      (buffer-string))))

(defun drgnx-settings-migrate-test--get-all ()
  "Every key of the six files as `drgnx-config-get' resolves it: ((NAME KEY VALUE)…)."
  (cl-loop for ((name . key) . _) in drgnx-settings-migrate-table collect (list name key (drgnx-config-get name key))))

(defun drgnx-settings-migrate-test--settings ()
  "settings.el's path."
  (drgnx-config-file 'settings))

(defun drgnx-settings-migrate-test--doc ()
  "settings.el read."
  (drgnx-settings-file-read (drgnx-settings-migrate-test--settings) 'drgnx-settings))

(defun drgnx-settings-migrate-test--names-sorted (list)
  "LIST of symbols, sorted by name."
  (sort (copy-sequence list) (lambda (a b) (string< (symbol-name a) (symbol-name b)))))

(ert-deftest drgnx-settings-migrate/every-schema-key-has-a-target ()
  (drgnx-settings-migrate-test--with
    (dolist (name drgnx-settings-migrate-names)
      (let ((keys (mapcar #'car (cdr (plist-get (drgnx-config-definition name) :schema))))
            (rows (drgnx-settings-migrate--rows name)))
        (should keys)
        (should (equal (drgnx-settings-migrate-test--names-sorted (mapcar #'car rows))
                       (drgnx-settings-migrate-test--names-sorted keys)))
        (pcase-dolist (`(,key . ,var) rows)
          (should (eq var (if (equal (cons name key) '(modules . :theme)) 'drgnx-look-theme
                            (intern (format "drgnx-%s-%s" name (substring (symbol-name key) 1)))))))))
    (let ((vars (mapcar #'cdr drgnx-settings-migrate-table)))
      (should (equal (length vars) (length (delete-dups (copy-sequence vars))))))))

(ert-deftest drgnx-settings-migrate/resolved-values-equal ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put-all)
    (let ((before (drgnx-settings-migrate-test--get-all))
          (whole (mapcar (lambda (n) (cons n (drgnx-settings-migrate--plist n (drgnx-config-get n))))
                         drgnx-settings-migrate-names)))
      (should (member '(agents :default "review") before))
      (let ((report (drgnx-settings-migrate-maybe)))
        (should (eq (plist-get report :status) 'migrated))
        (should (= (length (plist-get report :files)) 6))
        (should-not (plist-get report :stayed)))
      (should (= (length (drgnx-settings-doc-entries (drgnx-settings-migrate-test--doc))) 22))
      (should (equal (drgnx-settings-migrate-test--get-all) before))
      (dolist (w whole)
        (should (equal (drgnx-settings-migrate--plist (car w) (drgnx-config-get (car w))) (cdr w)))))))

(ert-deftest drgnx-settings-migrate/comments-move ()
  (drgnx-settings-migrate-test--with
    (mapc #'drgnx-settings-migrate-test--put '(agents modules session))
    (should (eq (plist-get (drgnx-settings-migrate-maybe) :status) 'migrated))
    (let ((text (drgnx-settings-migrate-test--text (drgnx-settings-migrate-test--settings))))
      (should (string-prefix-p drgnx-settings-file-global-header text))
      (should (string-search ";; the review profile reads every project\n (drgnx-agents-profiles" text))
      (should (string-search "; New Agent Session offers it\n (drgnx-agents-default \"review\")" text))
      (should (string-search ";; flags for completion\n (drgnx-modules-flags" text))
      (should (string-search ";; quit when the last window closes\n (drgnx-session-keep-running nil)" text)))
    (let ((doc (drgnx-settings-migrate-test--doc)))
      (should-not (drgnx-settings-doc-problems doc))
      ;; sorted by name, as the writer keeps it
      (let ((vars (mapcar #'drgnx-settings-entry-var (drgnx-settings-doc-entries doc))))
        (should (equal vars (drgnx-settings-migrate-test--names-sorted vars)))))))

(ert-deftest drgnx-settings-migrate/a-difference-moves-nothing ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put-all)
    (let ((orig (symbol-function 'drgnx-settings-migrate--entry-text)))
      (cl-letf (((symbol-function 'drgnx-settings-migrate--entry-text)
                 (lambda (var value)
                   (if (eq var 'drgnx-session-keep-running) "(drgnx-session-keep-running t)" (funcall orig var value)))))
        (let ((report (drgnx-settings-migrate-maybe)))
          (should (eq (plist-get report :status) 'differs))
          (should (string-search "session.eld" (plist-get report :why))))))
    (should-not (file-exists-p (drgnx-settings-migrate-test--settings)))
    (dolist (n drgnx-settings-migrate-names) (should (file-exists-p (drgnx-settings-migrate-test--file n))))
    (should-not (directory-files (drgnx-user-dir) nil "\\`migrated-"))
    (should-not (file-exists-p (expand-file-name "backups" (drgnx-state-dir))))
    (should (eq (nth 1 (car drgnx-settings-migrate-test--notices)) 'fail))
    (should (eq (drgnx-config-get 'session :keep-running) nil))
    (should (plist-member (drgnx-config-get 'session) :keep-running))))

(ert-deftest drgnx-settings-migrate/old-files-move-and-are-backed-up ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put-all)
    (let* ((texts (mapcar (lambda (n) (cons n (drgnx-settings-migrate-test--text (drgnx-settings-migrate-test--file n))))
                          drgnx-settings-migrate-names))
           (report (drgnx-settings-migrate-maybe))
           (moved (plist-get report :moved-to))
           (backup (plist-get report :backup)))
      (should (string-match-p "/migrated-[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}/\\'" moved))
      (should (file-in-directory-p moved (drgnx-user-dir)))
      (should (file-in-directory-p backup (expand-file-name "backups" (drgnx-state-dir))))
      (dolist (c texts)
        (let ((name (format "%s.eld" (car c))))
          (should-not (file-exists-p (drgnx-settings-migrate-test--file (car c))))
          (should (equal (drgnx-settings-migrate-test--text (expand-file-name name moved)) (cdr c)))
          (should (equal (drgnx-settings-migrate-test--text (expand-file-name name backup)) (cdr c))))))))

(ert-deftest drgnx-settings-migrate/a-crash-after-the-write-does-not-migrate-twice ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put-all)
    (cl-letf (((symbol-function 'drgnx-settings-migrate--move) (lambda (&rest _) (error "Crash"))))
      (should-not (drgnx-settings-migrate-maybe)))         ; never signals
    (let ((settings (drgnx-settings-migrate-test--text (drgnx-settings-migrate-test--settings)))
          (before (drgnx-settings-migrate-test--get-all)))
      (should settings)
      (dolist (n drgnx-settings-migrate-names) (should (file-exists-p (drgnx-settings-migrate-test--file n))))
      (should-not (drgnx-settings-migrate-maybe))
      (should (equal (drgnx-settings-migrate-test--text (drgnx-settings-migrate-test--settings)) settings))
      (dolist (n drgnx-settings-migrate-names) (should (file-exists-p (drgnx-settings-migrate-test--file n))))
      (should (equal (drgnx-settings-migrate-test--get-all) before))
      ;; the doctor names them, and Move Old Files Away moves them
      (let ((left (drgnx-settings-migrate-leftovers)))
        (should (equal (sort (mapcar #'file-name-nondirectory left) #'string<)
                       (sort (mapcar (lambda (n) (format "%s.eld" n)) drgnx-settings-migrate-names) #'string<)))
        (should (eq (car (drgnx-doctor--settings-leftovers-check left)) 'warn)))
      (should (= (length (drgnx-settings-migrate-move-away)) 6))
      (should-not (drgnx-settings-migrate-leftovers))
      (should-not (drgnx-doctor--settings-leftovers-check nil))
      (should (equal (drgnx-settings-migrate-test--get-all) before)))))

(ert-deftest drgnx-settings-migrate/a-mistaken-file-stays-and-is-read ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put 'keys)
    (drgnx-settings-migrate-test--put 'ai "ai-mistaken.eld")
    (drgnx-settings-migrate-test--write (drgnx-settings-migrate-test--file 'session)
                                        "(:version 1 :keep-running t :later 1)\n")
    (let* ((ai-before (drgnx-config-get 'ai))
           (session-before (drgnx-config-get 'session))
           (report (drgnx-settings-migrate-maybe))
           (stayed (plist-get report :stayed)))
      (should (eq (plist-get report :status) 'migrated))
      (should (equal (plist-get report :files) (list (drgnx-settings-migrate-test--file 'keys))))
      (should-not (file-exists-p (drgnx-settings-migrate-test--file 'keys)))
      (should (file-exists-p (drgnx-settings-migrate-test--file 'ai)))
      (should (file-exists-p (drgnx-settings-migrate-test--file 'session)))
      (should (equal (mapcar #'car stayed) (list (drgnx-settings-migrate-test--file 'ai)
                                                 (drgnx-settings-migrate-test--file 'session))))
      (should (string-match-p "\\`a mistake at line [0-9]+: " (cadr (nth 0 stayed))))
      (should (string-match-p "\\`keys this drgnx does not know: :later" (cadr (nth 1 stayed))))
      ;; still read, as before
      (should (drgnx-config-problem 'ai))
      (should (equal (drgnx-config-get 'ai) ai-before))
      (should (equal (drgnx-config-get 'session) session-before))
      (should-not (cl-intersection (mapcar #'drgnx-settings-entry-var
                                           (drgnx-settings-doc-entries (drgnx-settings-migrate-test--doc)))
                                   '(drgnx-ai-providers drgnx-ai-roles drgnx-session-keep-running))))))

(ert-deftest drgnx-settings-migrate/the-report-lists-everything ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put-all)
    (drgnx-settings-migrate-test--put 'ai "ai-mistaken.eld")
    (drgnx-settings-migrate-test--write custom-file "(custom-set-variables\n '(fill-column 90)\n '(foo-mode t))\n")
    (should (eq (plist-get (drgnx-settings-migrate-maybe) :status) 'migrated))
    (let* ((report (drgnx-settings-migrate-read-report))
           (doc (drgnx-settings-migrate-test--doc))
           (entries (plist-get report :entries)))
      (should (= (length entries) 20))                   ; 22 keys, less ai.eld's 2
      (pcase-dolist (`(,name ,key ,var ,line) entries)
        (should (eq var (cdr (assoc (cons name key) drgnx-settings-migrate-table))))
        (should (equal line (drgnx-settings-entry-line
                             (cl-find var (drgnx-settings-doc-entries doc) :key #'drgnx-settings-entry-var)))))
      (should (equal (mapcar #'car (plist-get report :stayed)) (list (drgnx-settings-migrate-test--file 'ai))))
      (should (equal (assq 'fill-column (plist-get report :custom)) '(fill-column 2)))
      (let* ((buf (drgnx-settings-migration-report))
             (text (with-current-buffer buf (buffer-string))))
        (kill-buffer buf)
        (should (string-search "keys.eld :layers → drgnx-keys-layers (line " text))
        (should (string-search "modules.eld :theme → drgnx-look-theme (line " text))
        (should (string-search "ai.eld: a mistake at line " text))
        (should (string-search "fill-column (custom.el line 2)" text))
        (should (string-search "Two machines: Commit and push" text))))
    (let ((n (car drgnx-settings-migrate-test--notices)))
      (should (equal (list (nth 0 n) (nth 1 n) (nth 2 n)) '(config info "Your settings moved into settings.el (5 files)")))
      (should (eq (plist-get (nthcdr 3 n) :command) 'settings-migration-report)))
    ;; the three commands are in the registry
    (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
      (drgnx-config-register-commands)
      (dolist (c '((settings-migration-report "Migration Report" drgnx-settings-migration-report)
                   (settings-migrate-old-files "Migrate Old Files" drgnx-settings-migrate-old-files)
                   (settings-move-old-files-away "Move Old Files Away" drgnx-settings-migrate-move-away)))
        (let ((cmd (drgnx-commands-get (car c))))
          (should (equal (list (drgnx-cmd-category cmd) (drgnx-cmd-title cmd) (drgnx-cmd-command cmd))
                         (list "Settings" (nth 1 c) (nth 2 c))))
          (should (commandp (nth 2 c))))))
    ;; Migrate Old Files only while settings.el is absent
    (should-error (drgnx-settings-migrate-old-files) :type 'user-error)))

(ert-deftest drgnx-settings-migrate/the-shim-returns-the-old-plist ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put 'agents)
    (drgnx-settings-migrate-test--put 'keys)
    (let ((old (drgnx-config-get 'agents)))
      (should (equal (plist-get old :default) "review"))
      (drgnx-settings-migrate-maybe)
      (should-not (file-exists-p (drgnx-settings-migrate-test--file 'agents)))
      (should (equal (drgnx-config-get 'agents) (drgnx-settings-migrate--plist 'agents old)))
      (dolist (key '(:profiles :default :mcp :openrouter :routes))
        (should (equal (drgnx-config-get 'agents key) (plist-get old key)))))
    (let ((settings (drgnx-settings-migrate-test--settings)))
      ;; a change in settings.el shows at once
      (drgnx-settings-file-put settings 'drgnx-settings nil 'drgnx-keys-unbind '(palette))
      (should (equal (drgnx-config-get 'keys :unbind) '(palette)))
      ;; a writer not moved to the settings yet writes keys.eld again: its keys win over settings.el
      (drgnx-config-set 'keys :mac-option 'characters)
      (should (eq (drgnx-config-get 'keys :mac-option) 'characters))
      (should (equal (drgnx-config-get 'keys :unbind) '(palette)))
      ;; settings.el with a mistake: its last good copy, except for agents (strict: their defaults)
      (drgnx-test-config-put 'settings "(drgnx-settings :version 1 (drgnx-agents-default \"x\")\n")
      (should (drgnx-config-problem 'settings))
      (should (equal (drgnx-config-get 'keys :unbind) '(palette)))
      (should (null (drgnx-config-get 'agents :default)))
      (should (equal (drgnx-config-get 'agents :mcp) '(coordination)))
      ;; out of the shim's areas, the old file alone
      (let ((drgnx-settings-shim-areas (remq 'keys drgnx-settings-shim-areas)))
        (should (null (drgnx-config-get 'keys :unbind))))))
  ;; a nil :layers means drgnx's default stack: no entry, and still nil through the shim
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--write (drgnx-settings-migrate-test--file 'keys)
                                        "(:version 1 :layers nil :unbind (keys-sheet))\n")
    (let ((report (drgnx-settings-migrate-maybe)))
      (should (equal (plist-get report :skipped) '((keys :layers)))))
    (should (equal (mapcar #'drgnx-settings-entry-var (drgnx-settings-doc-entries (drgnx-settings-migrate-test--doc)))
                   '(drgnx-keys-unbind)))
    (should (equal (drgnx-config-get 'keys) '(:unbind (keys-sheet))))
    (should (null (drgnx-config-get 'keys :layers)))))

(ert-deftest drgnx-settings-migrate/safe-mode-reads-keys-after-migration ()
  (drgnx-settings-migrate-test--with
    (drgnx-settings-migrate-test--put 'keys)
    (let ((process-environment (cons "DRGNX_SAFE=1" process-environment)))
      (should (eq (plist-get (drgnx-settings-migrate-maybe) :status) 'migrated))
      (should-not (file-exists-p (drgnx-settings-migrate-test--file 'keys)))
      (let ((user (drgnx-keys-read-user)))
        (should (equal (plist-get user :layers) '((emacs editing) (vscode app window))))
        (should (equal (plist-get user :bind) '((palette "C-S-p"))))
        (should (eq (plist-get user :mac-option) 'meta))))))

;;; settings-migrate-test.el ends here
