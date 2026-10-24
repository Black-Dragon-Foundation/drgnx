;;; settings-agents-test.el --- batch tests: the editor applies an agent's granted settings change, checks it first -*- lexical-binding: t -*-
;; A fake hub: `drgnx-hub-call' collects (METHOD PARAMS) in `drgnx-sat--sent'; the events come from a connection
;; that proved itself (`drgnx-hub--event-conn').  Everything runs under a temp config and state folder
;; (`drgnx-test-with-config') and temp project roots.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-settings-agents)
(require 'drgnx-settings-described)     ; the shipped descriptions (`shell-file-name' is code), as drgnx loads them
(require 'drgnx-tty-recommend)          ; `drgnx-tty-mac-app-dirs'
(require 'drgnx-hub-client)             ; `drgnx-hub--event-conn', bound below
(require 'drgnx-notice)                ; loaded now, so the fake `drgnx-notify' below is not replaced by a late load

(defcustom drgnx-sat-width 80 "A test setting: an integer." :type 'integer :group 'drgnx)
(defcustom drgnx-sat-format-function #'ignore "A test setting: code." :type 'function :group 'drgnx)
(drgnx-defsetting drgnx-sat-secure nil "A test setting: a security one." :type 'boolean :group 'drgnx :agents 'never)

(defvar drgnx-sat--sent nil "(METHOD PARAMS) the fake hub took, newest first.")
(defvar drgnx-sat--said nil "The notices said: (TEXT . PLIST), newest first.")

(defmacro drgnx-sat--with (&rest body)
  (declare (indent 0))
  `(let* ((drgnx-sat--sent nil) (drgnx-sat--said nil)
          (drgnx-settings-history--ours (make-hash-table :test 'equal))
          (drgnx-settings-history--reverts nil) (drgnx-settings-history--pending nil)
          (proc (make-pipe-process :name "drgnx-sat-hub" :noquery t))
          (drgnx-hub--event-conn proc))
     (process-put proc :drgnx-proven t)
     (unwind-protect
         (drgnx-test-with-config
           (cl-letf (((symbol-function 'drgnx-hub-call)
                      (lambda (method params callback &rest _)
                        (push (list method params) drgnx-sat--sent)
                        (funcall callback '(:state "accepted") nil)
                        1))
                     ((symbol-function 'drgnx-notify)
                      (lambda (_source _severity text &rest args) (push (cons text args) drgnx-sat--said))))
             ,@body))
       (delete-process proc))))

(defmacro drgnx-sat--with-root (var &rest body)
  "BODY with VAR a fresh temp folder (a session's root), deleted after."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "drgnx-sat-root" t))))
     (unwind-protect (progn ,@body) (delete-directory ,var t))))

(defun drgnx-sat--propose (tx scope name value &optional root)
  "The agent's change as the hub sends it; the editor's `settings/confirm' params."
  (drgnx-settings-agents--event "settings/proposed"
                                (list :tx tx :scope scope :name name :value value :root root :agent "agent:s1"
                                      :reason "wider lines"))
  (cadr (cl-find "settings/confirm" drgnx-sat--sent :key #'car :test #'equal)))

(defun drgnx-sat--sent-p (method) (cl-find method drgnx-sat--sent :key #'car :test #'equal))

(defun drgnx-sat--value (file head var)
  (when-let* ((e (drgnx-settings-agents--entry file head var))) (drgnx-settings-entry-value e)))

(defun drgnx-sat--global () (drgnx-config-file 'settings))

(ert-deftest drgnx-settings-agents/writes-and-confirms ()
  (drgnx-sat--with
    (let ((c (drgnx-sat--propose 5 "global" "drgnx-sat-width" "100")))
      (should (equal c '(:tx 5 :ok t)))
      (should (= (drgnx-sat--value (drgnx-sat--global) 'drgnx-settings 'drgnx-sat-width) 100))
      ;; the hub recorded the agent's tx: the editor's write is not recorded again
      (should-not (drgnx-sat--sent-p "settings/record")))
    ;; a hub that did not prove itself drives nothing
    (setq drgnx-sat--sent nil)
    (process-put drgnx-hub--event-conn :drgnx-proven nil)
    (should-not (drgnx-sat--propose 6 "global" "drgnx-sat-width" "120"))
    (should (= (drgnx-sat--value (drgnx-sat--global) 'drgnx-settings 'drgnx-sat-width) 100))))

(ert-deftest drgnx-settings-agents/the-editor-refuses-a-code-setting ()
  (drgnx-sat--with
    (pcase-dolist (`(,name ,value ,why) '(("drgnx-sat-format-function" "ignore" "is code")
                                          ("drgnx-sat-secure" "t" "security setting")
                                          ("shell-file-name" "\"./x\"" "is code")
                                          ("explicit-shell-file-name" "\"./x\"" "is code")
                                          ("drgnx-tty-mac-app-dirs" "(\"./x\")" "is code")
                                          ("enable-local-eval" "t" "security setting")
                                          ("safe-local-variable-values" "nil" "security setting")
                                          (":eval" "((delete-file \"x\"))" "not a setting")
                                          ("eval" "(delete-file \"x\")" "not a setting")))
      (setq drgnx-sat--sent nil)
      (let ((c (drgnx-sat--propose 9 "global" name value)))
        (should (eq (plist-get c :ok) :false))
        (should (string-search why (plist-get c :error)))))
    (should-not (file-exists-p (drgnx-sat--global)))
    (should-not drgnx-sat--said)))

(ert-deftest drgnx-settings-agents/a-type-error-is-refused ()
  (drgnx-sat--with
    (pcase-dolist (`(,value ,why) '(("\"wide\"" "does not match")
                                    ("#.(delete-file \"x\")" "does not read as data")
                                    ("" "empty")))
      (setq drgnx-sat--sent nil)
      (let ((c (drgnx-sat--propose 11 "global" "drgnx-sat-width" value)))
        (should (eq (plist-get c :ok) :false))
        (should (string-search why (plist-get c :error)))))
    ;; a secret is never a setting
    (setq drgnx-sat--sent nil)
    (let ((c (drgnx-sat--propose 12 "global" "user-full-name"
                                 ;; in parts, as test/fixtures/secret-cases.json keeps them (the leak hook)
                                 (concat "\"-----BEGIN RSA PRIVATE KEY" "-----\\nMIIEowIBAAKCAQEA\""))))
      (should (eq (plist-get c :ok) :false))
      (should (string-search "secret" (plist-get c :error))))
    (should-not (file-exists-p (drgnx-sat--global)))))

(ert-deftest drgnx-settings-agents/lands-in-the-sessions-root ()
  (drgnx-sat--with
    (drgnx-sat--with-root root
      ;; shared: the root's .drgnx/settings.el
      (should (equal (drgnx-sat--propose 20 "shared" "drgnx-sat-width" "72" root) '(:tx 20 :ok t)))
      (should (= (drgnx-sat--value (expand-file-name ".drgnx/settings.el" root) 'drgnx-workspace-settings
                                   'drgnx-sat-width)
                 72))
      ;; private: the root's private workspace file, made for it
      (setq drgnx-sat--sent nil)
      (should (equal (drgnx-sat--propose 21 "private" "drgnx-sat-width" "73" root) '(:tx 21 :ok t)))
      (let ((private (drgnx-settings-workspace-file root)))
        (should (string-prefix-p (expand-file-name (drgnx-settings-workspace-private-dir)) private))
        (should (= (drgnx-sat--value private 'drgnx-workspace-settings 'drgnx-sat-width) 73)))
      (should-not (file-exists-p (drgnx-sat--global)))
      ;; a project's change needs the session's folder
      (setq drgnx-sat--sent nil)
      (should (eq (plist-get (drgnx-sat--propose 22 "shared" "drgnx-sat-width" "74") :ok) :false))
      ;; a .drgnx that leads out of the root is refused: nothing lands outside
      (drgnx-sat--with-root other
        (drgnx-sat--with-root root2
          (make-symbolic-link (directory-file-name other) (expand-file-name ".drgnx" root2))
          (setq drgnx-sat--sent nil)
          (let ((c (drgnx-sat--propose 23 "shared" "drgnx-sat-width" "75" root2)))
            (should (eq (plist-get c :ok) :false))
            (should (string-search "leads out of" (plist-get c :error))))
          (should-not (file-exists-p (expand-file-name "settings.el" other))))))))

(ert-deftest drgnx-settings-agents/notice-with-undo ()
  (drgnx-sat--with
    (drgnx-settings-file-put (drgnx-sat--global) 'drgnx-settings nil 'drgnx-sat-width 90)
    (setq drgnx-sat--sent nil)
    (drgnx-sat--propose 7 "global" "drgnx-sat-width" "100")
    (let* ((n (car drgnx-sat--said)) (cmd (plist-get (cdr n) :command)))
      (should (equal (car n) "s1 changed drgnx-sat-width to 100 in your settings [Undo]"))
      (should (eq (car cmd) 'drgnx-settings-agents-undo))
      (setq drgnx-sat--sent nil)
      (apply (car cmd) (cdr cmd))
      (should (= (drgnx-sat--value (drgnx-sat--global) 'drgnx-settings 'drgnx-sat-width) 90))
      ;; Undo is recorded as a revert of the agent's tx
      (let ((rec (cadr (drgnx-sat--sent-p "settings/record"))))
        (should (equal (plist-get rec :reverts) 7))
        (should (equal (plist-get (car (plist-get rec :changes)) :value) "90")))
      ;; once the setting changed again, Undo refuses: it would take back your change
      (should-error (apply (car cmd) (cdr cmd)) :type 'user-error))
    ;; a setting the agent added goes again on Undo
    (setq drgnx-sat--said nil)
    (drgnx-sat--with-root root
      (drgnx-sat--propose 8 "shared" "drgnx-sat-width" "60" root)
      (let ((cmd (plist-get (cdar drgnx-sat--said) :command)) (file (expand-file-name ".drgnx/settings.el" root)))
        (should (string-search (format "in %s [Undo]" (file-name-nondirectory (directory-file-name root)))
                               (caar drgnx-sat--said)))
        (apply (car cmd) (cdr cmd))
        (should-not (drgnx-settings-agents--entry file 'drgnx-workspace-settings 'drgnx-sat-width))))))

(ert-deftest drgnx-settings-agents/explain-answers ()
  (drgnx-sat--with
    (drgnx-settings-agents--event "settings/explain" '(:req 4 :scope "global" :names ["drgnx-sat-width"]))
    (let* ((p (cadr (drgnx-sat--sent-p "settings/explained"))) (row (aref (plist-get p :settings) 0)))
      (should (equal (plist-get p :req) 4))
      (should (= (length (plist-get p :settings)) 1))
      (should (equal (plist-get row :name) "drgnx-sat-width"))
      (should (equal (plist-get row :value) "80"))
      (should (stringp (plist-get row :source))))
    ;; for a project: its workspace files over the global value
    (drgnx-sat--with-root root
      (drgnx-sat--propose 30 "private" "drgnx-sat-width" "120" root)
      (setq drgnx-sat--sent nil)
      (drgnx-settings-agents--event "settings/explain" (list :req 5 :scope "private" :names ["drgnx-sat-width"]
                                                             :root root))
      (let ((row (aref (plist-get (cadr (drgnx-sat--sent-p "settings/explained")) :settings) 0)))
        (should (equal (plist-get row :value) "120"))
        (should (equal (plist-get row :source) "your workspace file"))))))

(defvar drgnx-sat-plain "hidden" "A test variable: no setting (no `defcustom', no description).")
(defcustom drgnx-sat-api-token "sk-not-a-real-one" "A test setting: a secret-looking name." :type 'string :group 'drgnx)

(ert-deftest drgnx-settings-agents/explain-never-shows-secrets-or-plain-variables ()
  (drgnx-sat--with
    (drgnx-settings-agents--event
     "settings/explain" '(:req 6 :scope "global" :names ["drgnx-sat-plain" "drgnx-sat-api-token" "drgnx-sat-secure"
                                                         "drgnx-sat-width"]))
    (let ((rows (plist-get (cadr (drgnx-sat--sent-p "settings/explained")) :settings)))
      (should (= (length rows) 4))
      (dotimes (i 3)
        (should-not (plist-member (aref rows i) :value))
        (should (equal (plist-get (aref rows i) :source) "not shown to agents")))
      (should (equal (plist-get (aref rows 3) :value) "80")))))

;;; settings-agents-test.el ends here

(ert-deftest drgnx-settings-agents/hub-disconnect-removes-its-hook ()
  "`drgnx-hub-disconnect' removes the hook `drgnx-hub-connect' added, and again is harmless."
  (let ((drgnx-hub-event-functions (list #'drgnx-settings-agents--event)))
    (drgnx-hub-disconnect)
    (should-not (memq #'drgnx-settings-agents--event drgnx-hub-event-functions))
    (drgnx-hub-disconnect)
    (should-not (memq #'drgnx-settings-agents--event drgnx-hub-event-functions))))

(ert-deftest drgnx-settings-agents/the-shared-deny-table ()
  "The editor's check refuses what test/fixtures/settings-deny.json denies, and takes the rest (the hub runs the same
rows, norn's `deny_table')."
  (require 'drgnx-agents)
  (require 'drgnx-ai)
  (require 'drgnx-user-lisp)
  (let ((table (with-temp-buffer
                 (insert-file-contents (expand-file-name "test/fixtures/settings-deny.json" drgnx-dir))
                 (json-parse-buffer :false-object nil)))
        (refused (lambda (name)
                   (let ((var (drgnx-settings-agents--var name)))
                     (or (null var) (and (drgnx-settings-agents--denied var) t))))))
    (seq-doseq (row (gethash "cases" table))
      (let ((name (aref row 0)))
        (unless (equal name "")         ; no name: the editor refuses it, the hub's name check too
          (should (equal (list name (funcall refused name)) (list name (aref row 1)))))))
    (seq-doseq (c (gethash "characters" table))
      (should (funcall refused (string ?f c ?x))))
    (dolist (name '("nil" "t" ":eval" ":x" "a b" "a\tb"))
      (should (funcall refused name)))))
