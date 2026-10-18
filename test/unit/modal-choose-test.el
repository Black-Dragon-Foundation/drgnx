;;; modal-choose-test.el --- batch tests: choosing a modal key stack (onboarding, Keyboard Profile…), evil missing -*- lexical-binding: t -*-
;; A temp configuration (config, data, state, home); evil is not installed here.  The tests that load evil or run
;; the startup modules are in
;; test/unit/isolated/modal-choose-isolated.el, each run in its own Emacs by the test of the same name below
;; (docs/develop/harness.md, "Modal tests").
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal-choose nil t)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar drgnx-onboard--restart-needed)
(declare-function drgnx-modal-apply-pending "drgnx-modal-choose")
(declare-function drgnx-modal-prepare "drgnx-modal-choose")

(defconst drgnx-modal-choose-test--vim '((vim app editing window)))
(defconst drgnx-modal-choose-test--vscode '((vscode app editing window)))

(defun drgnx-modal-choose-test--file (name) (expand-file-name name (drgnx-user-dir)))

(defun drgnx-modal-choose-test--write (name text)
  (with-temp-file (drgnx-modal-choose-test--file name) (insert text)))

(defun drgnx-modal-choose-test--text (name)
  (and (file-exists-p (drgnx-modal-choose-test--file name))
       (with-temp-buffer (insert-file-contents (drgnx-modal-choose-test--file name)) (buffer-string))))

(defun drgnx-modal-choose-test--read (name)
  (and (file-exists-p (drgnx-modal-choose-test--file name)) (car (read-from-string (drgnx-modal-choose-test--text name)))))

(defmacro drgnx-modal-choose-test--with (&rest body)
  "BODY in a temp configuration: keys.eld with the VS Code stack and a comment, no modules.eld, the core commands
registered and the keys applied, no engine registered.  Skipped where evil can be loaded."
  (declare (indent 0))
  `(progn
     (skip-unless (not (or (featurep 'evil) (locate-library "evil"))))
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-modal-choose" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config") (concat "DRGNX_DATA_DIR=" dir "data")
                                               (concat "XDG_STATE_HOME=" dir "state") (concat "HOME=" dir "home"))
                                         process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
            (drgnx-modules--state nil) (drgnx-modal-engines nil) (drgnx-modal-running nil)
            (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (drgnx-keys--session-layers nil) (drgnx-onboard--restart-needed nil))
       (make-directory (concat dir "config") t)
       (make-directory (concat dir "home") t)
       (drgnx-modal-choose-test--write "keys.eld" ";; my keys\n(:layers ((vscode app editing window)))\n")
       (unwind-protect
           (progn (drgnx--core-commands)
                  (drgnx-keys-apply)
                  ,@body)
         (drgnx-keys--restore)
         (delete-directory dir t)))))

(defmacro drgnx-modal-choose-test--no-prompts (&rest body)
  "BODY with every prompt but `y-or-n-p' failing the test (`noninteractive' is nil around the interactive path)."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (ert-fail "read-from-minibuffer")))
             ((symbol-function 'read-key) (lambda (&rest _) (ert-fail "read-key")))
             ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "yes-or-no-p")))
             ((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "completing-read"))))
     ,@body))

(ert-deftest drgnx-modal-choose/non-interactive-records-pending ()
  ;; `drgnx onboard --non-interactive --keys Vim' without evil: editor/evil on, the stack waits in keys.eld, nothing asked.
  (drgnx-modal-choose-test--with
    (delete-file (expand-file-name "keys-report.eld" (drgnx-state-dir)))
    (let ((asked 0))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asked) t))
                ((symbol-function 'drgnx-onboard--sync-job) (lambda () (ert-fail "drgnx sync ran"))))
        (let ((r (car (drgnx-onboard-run :only '(look-and-keys) :non-interactive t :options '(:keys "Vim")))))
          (should (= asked 0))
          (should (string-match-p "keys: Vim needs drgnx sync" (nth 2 r))))))
    (let ((user (drgnx-modal-choose-test--read "keys.eld")))
      (should (equal (plist-get user :layers) drgnx-modal-choose-test--vscode))
      (should (equal (plist-get user :pending-layers) drgnx-modal-choose-test--vim)))
    (should (equal (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled) '(editor/evil)))
    ;; the key report was written then (no apply ran)
    (should (file-exists-p (expand-file-name "keys-report.eld" (drgnx-state-dir))))
    ;; a start without evil: nothing switches, nothing is asked, the pending stack stays
    (let ((inhibit-interaction t)) (should-not (drgnx-modal-apply-pending)))
    (should (equal (plist-get (drgnx-modal-choose-test--read "keys.eld") :pending-layers) drgnx-modal-choose-test--vim))
    (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vscode))))

(ert-deftest drgnx-modal-choose/declined-keeps-the-stack ()
  (drgnx-modal-choose-test--with
    (let ((keys (drgnx-modal-choose-test--text "keys.eld")) (asked nil) (noninteractive nil))
      (drgnx-modal-choose-test--no-prompts
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (push q asked) nil))
                  ((symbol-function 'drgnx-onboard--sync-job) (lambda () (ert-fail "drgnx sync ran"))))
          (drgnx-keys-choose-profile "Vim" t)))
      (should (= (length asked) 1))
      (should (string-match-p "evil" (car asked)))                ; it says what it installs
      (should (equal (drgnx-modal-choose-test--text "keys.eld") keys))
      (should-not (drgnx-modal-choose-test--text "modules.eld"))
      (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vscode)))))

(ert-deftest drgnx-modal-choose/going-back-turns-the-module-off ()
  (drgnx-modal-choose-test--with
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "asked"))))
      (drgnx-keys-choose-profile "Vim")                        ; from code, not the command: it waits for drgnx sync
      (should (memq 'editor/evil (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled)))
      (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vscode))
      (drgnx-keys-choose-profile "VS Code"))
    (should-not (memq 'editor/evil (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled)))
    (let ((user (drgnx-modal-choose-test--read "keys.eld")))
      (should-not (plist-member user :pending-layers))
      (should (equal (plist-get user :layers) drgnx-modal-choose-test--vscode)))
    (should (string-prefix-p ";; my keys\n" (drgnx-modal-choose-test--text "keys.eld")))))

(ert-deftest drgnx-modal-choose/stopping-the-sync-turns-the-module-back-off ()
  ;; C-g during drgnx sync (a quit out of the job): the keys stay, editor/evil is off again, nothing waits.
  (drgnx-modal-choose-test--with
    (let ((keys (drgnx-modal-choose-test--text "keys.eld")) (noninteractive nil) (synced nil))
      (drgnx-modal-choose-test--no-prompts
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                  ((symbol-function 'drgnx-onboard--sync-job)
                   (lambda ()
                     (setq synced (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled))
                     (signal 'quit nil))))
          (should (eq (condition-case nil (progn (drgnx-keys-choose-profile "Vim" t) 'returned) (quit 'quit)) 'quit))))
      (should (equal synced '(editor/evil)))                   ; the sync saw the module on
      (should-not (memq 'editor/evil (plist-get (drgnx-modal-choose-test--read "modules.eld") :enabled)))
      (should (equal (drgnx-modal-choose-test--text "keys.eld") keys))
      (should (equal (plist-get drgnx-keys-last :layers) drgnx-modal-choose-test--vscode)))))

(ert-deftest drgnx-modal-choose/drgnx-onboard-keeps-the-last-key-report ()
  ;; A process that never applied the keys (drgnx onboard) does not replace the last session's key report.
  (drgnx-modal-choose-test--with
    (let ((report (expand-file-name "keys-report.eld" (drgnx-state-dir)))
          (old "(:layers ((emacs app editing window)) :conflicts (\"C-x a conflict\") :problems nil)")
          (drgnx-keys-last nil))
      (with-temp-file report (insert old))
      (should (eq (drgnx-modal-prepare drgnx-modal-choose-test--vim) 'pending))
      (should (equal (with-temp-buffer (insert-file-contents report) (buffer-string)) old))
      (should (eq (drgnx-modal-prepare drgnx-modal-choose-test--vscode) 'ready))   ; the pending stack goes
      (should-not (plist-member (drgnx-modal-choose-test--read "keys.eld") :pending-layers))
      (should (equal (with-temp-buffer (insert-file-contents report) (buffer-string)) old)))))

(ert-deftest drgnx-modal-choose/onboarding-keys-on-a-mac-say-there-are-no-clashes ()
  ;; The Keys question: the presets, VS Code preselected; on a Mac a help line above it.  Return keeps a pending stack.
  (drgnx-modal-choose-test--with
    (dolist (platform '(linux macos))
      (let ((asked nil))
        (cl-letf (((symbol-function 'drgnx-platform) (lambda () platform))
                  ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
                  ((symbol-function 'completing-read)
                   (lambda (prompt _c &optional _p _r _i _h def &rest _) (push (cons prompt def) asked) (car (ensure-list def)))))
          (drgnx-onboard--look-step '(:interactive t :options (:preset full-ai :theme modus-vivendi))))
        (let ((keys (seq-find (lambda (q) (string-match-p "^Keys (" (car q))) asked)))
          (should (equal (cdr keys) "VS Code"))
          (should (string-search "Vim editing + VS Code app keys" (car keys)))
          (should (eq (and (string-search "With VS Code app keys on a Mac, Vim keeps Ctrl and VS Code uses Cmd: no clashes\nKeys ("
                                          (car keys))
                           t)
                      (eq platform 'macos))))))
    ;; a stack waiting for drgnx sync is the default: Return keeps it waiting
    (drgnx-keys-choose-profile "Vim")
    (let ((asked nil))
      (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
                ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "asked in batch")))
                ((symbol-function 'completing-read)
                 (lambda (prompt _c &optional _p _r _i _h def &rest _) (push (cons prompt def) asked) (car (ensure-list def)))))
        (should (string-match-p "keys: Vim needs drgnx sync"
                                (cadr (drgnx-onboard--look-step '(:interactive t :options (:preset full-ai :theme modus-vivendi)))))))
      (should (equal (cdr (seq-find (lambda (q) (string-match-p "^Keys (" (car q))) asked)) "Vim"))
      (should (equal (plist-get (drgnx-modal-choose-test--read "keys.eld") :pending-layers) drgnx-modal-choose-test--vim)))))

;;;; With evil, or all the startup modules: each in its own Emacs

(defconst drgnx-modal-choose-test--isolated "test/unit/isolated/modal-choose-isolated.el")

(ert-deftest drgnx-modal-choose/a-vim-stack-without-evil-stays-usable ()
  (should (null (drgnx-modal-test-isolated-result
                 drgnx-modal-choose-test--isolated "^drgnx-modal-choose/a-vim-stack-without-evil-stays-usable\\'"))))

(ert-deftest drgnx-modal-choose/interactive-asks-once-and-switches-after-the-engine-loads ()
  (should (null (drgnx-modal-test-isolated-result
                 drgnx-modal-choose-test--isolated
                 "^drgnx-modal-choose/interactive-asks-once-and-switches-after-the-engine-loads\\'"))))

(ert-deftest drgnx-modal-choose/installed-engine-switches-without-asking ()
  (should (null (drgnx-modal-test-isolated-result
                 drgnx-modal-choose-test--isolated "^drgnx-modal-choose/installed-engine-switches-without-asking\\'"))))

(ert-deftest drgnx-modal-choose/pending-applies-at-the-next-start ()
  (should (null (drgnx-modal-test-isolated-result
                 drgnx-modal-choose-test--isolated "^drgnx-modal-choose/pending-applies-at-the-next-start\\'"))))

(provide 'modal-choose-test)
;;; modal-choose-test.el ends here
