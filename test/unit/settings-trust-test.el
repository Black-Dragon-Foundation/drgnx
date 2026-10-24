;;; settings-trust-test.el --- batch tests: workspace trust (classes, states, locations, allowed pairs) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Every test runs under `drgnx-test-with-config' (temp config and state folders, so trusted-folders.eld is a temp
;; file) with a location folder ws/ beside them and a project ws/proj/ (a git root) in it, fresh trust and workspace
;; caches, `safe-local-variable-values' and `safe-local-variable-directories' nil, a temp `custom-file' that must
;; never appear, and `inhibit-interaction' t around every open.  `hack-local-variables-confirm' (the stock prompt)
;; is recorded: in batch it would only say no, so a test sees whether it was asked.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-setting)
(require 'drgnx-settings-prov)
(require 'drgnx-settings-apply)
(require 'drgnx-settings-workspace)
(require 'drgnx-settings-trust)
(require 'drgnx-doctor)
(require 'drgnx-notice)

(defvar drgnx-stt-data nil "A variable with no safe predicate and no risky name: data.")
(defvar drgnx-stt-risky-function nil "A variable risky by its name: code.")
(defvar drgnx-stt--evals nil "What the workspaces' eval forms pushed.")
(defvar drgnx-stt--prompts nil "The variables the stock prompt was asked about.")
(defvar drgnx-stt--ws nil "The location folder (normalized).")
(defvar drgnx-stt--proj nil "The project ws/proj/ (normalized).")
(defvar drgnx-stt--buffers nil "The buffers a test opened.")

(define-minor-mode drgnx-stt-minor-mode "A minor mode a `mode' entry turns on." :lighter nil)

(defconst drgnx-stt--settings '(drgnx-stt--own drgnx-stt--secure drgnx-stt--routes)
  "The fixture settings, declared fresh by `drgnx-stt--with'.")

(defun drgnx-stt--declare ()
  (eval '(drgnx-defsetting drgnx-stt--own 1 "One of drgnx's own settings." :type 'integer :group 'drgnx-stt
           :safe #'integerp)
        t)
  (eval '(drgnx-defsetting drgnx-stt--secure nil "A security setting." :type 'boolean :group 'drgnx-stt
           :workspace 'never :agents 'never)
        t)
  (eval '(drgnx-defsetting drgnx-stt--routes nil "Never an agent's, but a project's to set (like `drgnx-ai-roles')."
           :type 'sexp :group 'drgnx-stt :scope 'project :workspace 'data :agents 'never)
        t))

(defun drgnx-stt--undeclare ()
  (dolist (var drgnx-stt--settings)
    (makunbound var)
    (dolist (p '(standard-value theme-value saved-value custom-type drgnx-setting safe-local-variable
                                risky-local-variable))
      (put var p nil))
    (setq drgnx-setting--names (delq var drgnx-setting--names))))

(defun drgnx-stt--norm (dir) (file-name-as-directory (file-truename (expand-file-name dir))))

(defun drgnx-stt--write (file text)
  "Make FILE hold TEXT: a new file renamed over it."
  (make-directory (file-name-directory file) t)
  (let ((tmp (concat file ".test-new")) (coding-system-for-write 'utf-8-unix))
    (write-region text nil tmp nil 'silent)
    (rename-file tmp file t)
    (setq dir-locals-directory-cache nil)             ; Emacs's cache is by mtime, which may not tick between writes
    file))

(defun drgnx-stt--project (dir)
  "Make DIR a project folder (a git root); DIR normalized."
  (make-directory (expand-file-name ".git" dir) t)
  (drgnx-stt--norm dir))

(defmacro drgnx-stt--with (parents &rest body)
  "BODY with the fixture: `drgnx-trust-parents' PARENTS, evaluated with `drgnx-stt--ws' bound."
  (declare (indent 1) (debug t))
  `(drgnx-test-with-config
     (let* ((drgnx-stt--ws (drgnx-stt--project (expand-file-name "ws/" drgnx-test-config-root)))
            (drgnx-stt--proj (drgnx-stt--project (expand-file-name "proj/" drgnx-stt--ws)))
            (drgnx-trust-parents ,parents)
            (drgnx-settings-workspace--docs (make-hash-table :test 'equal))
            (drgnx-settings-workspace--seen (make-hash-table :test 'equal))
            (drgnx-settings-workspace-filter-function #'drgnx-settings-trust-filter)
            (drgnx-settings-trust--data nil)
            (drgnx-settings-trust--waiting (make-hash-table :test 'equal))
            (drgnx-settings-trust--announced nil)
            (drgnx-settings-trust--content nil)
            (drgnx-settings-trust--guarded nil)
            (drgnx-settings-trust--guarded-count -1)
            (ignored-local-variables (default-value 'ignored-local-variables))
            (trusted-content nil)
            (drgnx-trust--added nil)
            (safe-local-variable-values nil)
            (safe-local-variable-directories nil)
            (custom-file (expand-file-name "custom.el" drgnx-test-config-root))
            (enable-local-variables t)
            (enable-local-eval 'maybe)
            (drgnx-stt--evals nil)
            (drgnx-stt--prompts nil)
            (drgnx-stt--buffers nil))
       (drgnx-stt--declare)
       (unwind-protect
           (cl-letf (((symbol-function 'hack-local-variables-confirm)
                      (lambda (all-vars &rest _) (setq drgnx-stt--prompts (append drgnx-stt--prompts (mapcar #'car all-vars)))
                        nil)))
             ,@body)
         (dolist (b drgnx-stt--buffers) (when (buffer-live-p b) (kill-buffer b)))
         (drgnx-stt--undeclare)
         (should-not (file-exists-p custom-file))
         (should-not safe-local-variable-values)))))

(defun drgnx-stt--put (rel text &optional root)
  "Make REL under ROOT (default the project) hold TEXT."
  (drgnx-stt--write (expand-file-name rel (or root drgnx-stt--proj)) text))

(defun drgnx-stt--open (rel &optional root)
  "Visit REL under ROOT (default the project; made when missing), with `inhibit-interaction' t; its buffer."
  (let ((file (expand-file-name rel (or root drgnx-stt--proj))))
    (unless (file-exists-p file) (drgnx-stt--write file "hi\n"))
    (let* ((inhibit-interaction t) (b (find-file-noselect file)))
      (push b drgnx-stt--buffers)
      b)))

(defun drgnx-stt--reopen (rel &optional root)
  "Kill REL's buffer and visit it again."
  (when-let* ((b (get-file-buffer (expand-file-name rel (or root drgnx-stt--proj))))) (kill-buffer b))
  (drgnx-stt--open rel root))

(defmacro drgnx-stt--in (rel &rest body)
  (declare (indent 1) (debug t))
  `(with-current-buffer (drgnx-stt--open ,rel) ,@body))

(defun drgnx-stt--vars (items) (mapcar (lambda (i) (plist-get i :var)) items))

(defconst drgnx-stt--dl
  "((nil . ((fill-column . 66)
         (drgnx-stt-data . \"dl\")
         (drgnx-stt-risky-function . ignore)
         (eval . (push 'dl drgnx-stt--evals)))))\n"
  "A .dir-locals.el with a safe value, data, a risky value and an eval, all on line 1–4.")

;;;; States and classes

(ert-deftest drgnx-settings-trust/untrusted-applies-safe-only ()
  (drgnx-stt--with nil
    (drgnx-stt--put ".drgnx/settings.el"
                    "(drgnx-workspace-settings\n :version 1\n (fill-column 77)\n (drgnx-stt-data \"w1\")\n (:eval (push 'w1 drgnx-stt--evals)))\n")
    (should (eq (drgnx-settings-trust-state drgnx-stt--proj) 'untrusted))
    (drgnx-stt--in "a.txt"
      (should (= fill-column 77))
      (should-not (local-variable-p 'drgnx-stt-data))
      (should-not drgnx-stt--evals)
      (should-not drgnx-stt--prompts))
    ;; what waits: the data and the code, for trust
    (should (equal (sort (mapcar #'symbol-name (drgnx-stt--vars (drgnx-settings-trust-waiting drgnx-stt--proj))) #'string<)
                   '(":eval" "drgnx-stt-data")))
    ;; .dir-locals.el stays Emacs's own: the stock prompt is asked (an untrusted folder), nothing applied in batch
    (drgnx-stt--put ".dir-locals.el" "((nil . ((drgnx-stt-data . \"dl\"))))\n")
    (with-current-buffer (drgnx-stt--reopen "b.txt")
      (should (memq 'drgnx-stt-data drgnx-stt--prompts))
      (should-not (local-variable-p 'drgnx-stt-data)))))

(ert-deftest drgnx-settings-trust/a-location-applies-data-holds-code ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (should (eq (drgnx-settings-trust-state drgnx-stt--proj) 'location))
    (drgnx-stt--in "a.txt"
      (should (= fill-column 66))
      (should (equal drgnx-stt-data "dl"))
      (should-not (local-variable-p 'drgnx-stt-risky-function))
      (should-not drgnx-stt--evals)
      (should-not drgnx-stt--prompts))
    (let ((waiting (drgnx-settings-trust-waiting drgnx-stt--proj)))
      (should (equal (drgnx-stt--vars waiting) '(drgnx-stt-risky-function eval)))
      (should (equal (mapcar (lambda (i) (plist-get i :file)) waiting) '(".dir-locals.el" ".dir-locals.el")))
      (should (equal (mapcar (lambda (i) (plist-get i :line)) waiting) '(3 4))))))

(ert-deftest drgnx-settings-trust/allow-applies-at-once ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (drgnx-stt--in "a.txt"
      (should-not (local-variable-p 'drgnx-stt-risky-function))
      (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
      ;; the open buffer, not reopened
      (should (eq drgnx-stt-risky-function 'ignore))
      (should (equal drgnx-stt--evals '(dl)))
      (should-not drgnx-stt--prompts))
    (should-not (drgnx-settings-trust-waiting drgnx-stt--proj))))

(ert-deftest drgnx-settings-trust/a-symlinked-dir-locals-is-allowed-by-its-written-name ()
  ;; one path form: the open's split and Trust This Folder's pairs both name the link, never its target
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put "conf/dl.el" drgnx-stt--dl)
    (make-symbolic-link (expand-file-name "conf/dl.el" drgnx-stt--proj) (expand-file-name ".dir-locals.el" drgnx-stt--proj))
    (setq dir-locals-directory-cache nil)
    (drgnx-stt--in "a.txt"
      (should-not (local-variable-p 'drgnx-stt-risky-function))
      (let ((waiting (drgnx-settings-trust-waiting drgnx-stt--proj)))
        (should (equal (delete-dups (mapcar (lambda (i) (plist-get i :file)) waiting)) '(".dir-locals.el")))
        (drgnx-settings-trust-allow drgnx-stt--proj waiting))
      (should (eq drgnx-stt-risky-function 'ignore)))
    (should-not (drgnx-settings-trust-waiting drgnx-stt--proj))
    (with-current-buffer (drgnx-stt--reopen "a.txt")
      (should (eq drgnx-stt-risky-function 'ignore))
      (should-not drgnx-stt--prompts))))

(ert-deftest drgnx-settings-trust/a-changed-pair-waits-again ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (drgnx-stt--open "a.txt")
    (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
    (setq drgnx-stt--evals nil)
    ;; a pull changes the risky value; the eval stays as allowed
    (drgnx-stt--put ".dir-locals.el" (replace-regexp-in-string "ignore" "identity" drgnx-stt--dl))
    (with-current-buffer (drgnx-stt--reopen "a.txt")
      (should-not (local-variable-p 'drgnx-stt-risky-function))
      (should (equal drgnx-stt--evals '(dl)))         ; the unchanged pair keeps applying
      (should (equal drgnx-stt-data "dl")))
    (let ((waiting (drgnx-settings-trust-waiting drgnx-stt--proj)))
      (should (equal (drgnx-stt--vars waiting) '(drgnx-stt-risky-function)))
      (should (eq (plist-get (car waiting) :value) 'identity))
      (should (eq (plist-get (car waiting) :was) 'ignore)))))

(ert-deftest drgnx-settings-trust/mode-entries-are-code ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (should (eq (drgnx-settings-trust-class 'mode 'drgnx-stt-minor 'dir-locals) 'code))
    (should (eq (drgnx-settings-trust-class 'eval '(ignore) 'dir-locals) 'code))
    (should (eq (drgnx-settings-trust-class :eval '((ignore)) 'shared) 'code))
    (should (eq (drgnx-settings-trust-class 'drgnx-stt-risky-function 'ignore 'shared) 'code))
    (should (eq (drgnx-settings-trust-class 'fill-column 70 'shared) 'safe))
    (should (eq (drgnx-settings-trust-class 'drgnx-stt-data "x" 'shared) 'data))
    (should (eq (drgnx-settings-trust-class 'enable-local-eval t 'shared) 'never))
    (drgnx-stt--put ".dir-locals.el" "((nil . ((mode . drgnx-stt-minor))))\n")
    (drgnx-stt--in "a.txt"
      (should-not drgnx-stt-minor-mode)
      (should-not drgnx-stt--prompts))
    (should (equal (drgnx-stt--vars (drgnx-settings-trust-waiting drgnx-stt--proj)) '(mode)))
    (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
    (with-current-buffer (drgnx-stt--reopen "a.txt") (should drgnx-stt-minor-mode))))

(ert-deftest drgnx-settings-trust/program-naming-settings-are-code ()
  "The shell M-x compile and grep run, and the Emacs Flymake starts, wait for review even in a trusted location."
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (dolist (v '(shell-file-name explicit-shell-file-name shell-command-switch invocation-name invocation-directory))
      (should (eq (drgnx-settings-trust-class v "./x" 'shared) 'code))
      (should (eq (drgnx-settings-trust-class v "./x" 'dir-locals) 'code)))
    (drgnx-stt--put ".dir-locals.el" "((nil . ((shell-file-name . \"./x\") (fill-column . 66))))\n")
    (should (eq (drgnx-settings-trust-state drgnx-stt--proj) 'location))
    (drgnx-stt--in "a.txt"
      (should (= fill-column 66))
      (should-not (local-variable-p 'shell-file-name))
      (should-not drgnx-stt--prompts))
    (should (equal (drgnx-stt--vars (drgnx-settings-trust-waiting drgnx-stt--proj)) '(shell-file-name)))))

(ert-deftest drgnx-settings-trust/dir-locals-2-and-dir-sections-are-split-too ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" "((\"src/\" . ((nil . ((eval . (push 'src drgnx-stt--evals)) (fill-column . 55))))))\n")
    (drgnx-stt--put ".dir-locals-2.el" "((nil . ((drgnx-stt-risky-function . ignore))))\n")
    (drgnx-stt--put "lib/.dir-locals.el" "((nil . ((eval . (push 'lib drgnx-stt--evals)))))\n")
    (drgnx-stt--in "src/b.txt"
      (should (= fill-column 55))
      (should-not (local-variable-p 'drgnx-stt-risky-function))
      (should-not drgnx-stt--evals))
    (drgnx-stt--in "lib/c.txt" (should-not drgnx-stt--evals))
    (should-not drgnx-stt--prompts)
    (let ((waiting (drgnx-settings-trust-waiting drgnx-stt--proj)))
      (should (equal (sort (mapcar (lambda (i) (format "%s %s" (plist-get i :file) (plist-get i :var))) waiting) #'string<)
                     '(".dir-locals-2.el drgnx-stt-risky-function" ".dir-locals.el eval" "lib/.dir-locals.el eval"))))))

;;;; Trust This Folder, Untrust

(ert-deftest drgnx-settings-trust/trust-this-folder-allows-what-it-showed ()
  (drgnx-stt--with nil
    (drgnx-stt--put ".dir-locals.el" "((nil . ((drgnx-stt-data . \"dl\") (eval . (push 'a drgnx-stt--evals)))))\n")
    (let ((shown (drgnx-settings-trust-code-pairs drgnx-stt--proj)))
      (should (equal (drgnx-stt--vars shown) '(eval)))
      ;; code added after it was shown
      (drgnx-stt--put ".dir-locals.el"
                      "((nil . ((drgnx-stt-data . \"dl\") (eval . (push 'a drgnx-stt--evals)) (eval . (push 'b drgnx-stt--evals)))))\n")
      (drgnx-settings-trust-this-folder drgnx-stt--proj shown))
    (should (eq (drgnx-settings-trust-state drgnx-stt--proj) 'trusted))
    (drgnx-stt--in "a.txt"
      (should (equal drgnx-stt-data "dl"))
      (should (equal drgnx-stt--evals '(a)))
      (should (trusted-content-p))
      (should-not drgnx-stt--prompts))
    (should (equal (mapcar (lambda (i) (plist-get i :value)) (drgnx-settings-trust-waiting drgnx-stt--proj))
                   '((push 'b drgnx-stt--evals))))))

(ert-deftest drgnx-settings-trust/untrust-takes-everything-back ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (drgnx-stt--in "a.txt"
      (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
      (should (eq drgnx-stt-risky-function 'ignore))
      (let ((inhibit-message t)) (drgnx-settings-trust-untrust drgnx-stt--proj))
      (should-not (local-variable-p 'drgnx-stt-risky-function))
      (should-not (local-variable-p 'drgnx-stt-data))
      (should-not drgnx-stt--prompts))
    (should (eq (drgnx-settings-trust-state drgnx-stt--proj) 'untrusted))   ; an exception on this machine
    (should-not (drgnx-settings-trust--root-pairs :allowed drgnx-stt--proj))
    ;; a folder of Trust This Folder: no longer trusted
    (let ((other (drgnx-stt--project (expand-file-name "other/" drgnx-test-config-root))) (inhibit-message t))
      (drgnx-settings-trust-this-folder other nil)
      (should (eq (drgnx-settings-trust-state other) 'trusted))
      (drgnx-settings-trust-untrust other)
      (should (eq (drgnx-settings-trust-state other) 'untrusted))
      (should-not (drgnx-trust-folders)))))

;;;; Everything, and its limits

(ert-deftest drgnx-settings-trust/everything-runs-code-without-review ()
  (drgnx-stt--with (list (list drgnx-stt--ws :code t))
    (should-not (drgnx-setting-check 'drgnx-trust-parents drgnx-trust-parents))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (should (eq (drgnx-settings-trust-state drgnx-stt--proj) 'everything))
    (drgnx-settings-trust--sync-content)
    (drgnx-stt--in "a.txt"
      (should (eq drgnx-stt-risky-function 'ignore))
      (should (equal drgnx-stt--evals '(dl)))
      (should (trusted-content-p))
      (should-not drgnx-stt--prompts))
    (should-not (drgnx-settings-trust-waiting drgnx-stt--proj))))

(ert-deftest drgnx-settings-trust/everything-is-refused-on-home ()
  (drgnx-test-with-config
    (let* ((home (file-name-as-directory (expand-file-name "home" drgnx-test-config-root)))
           (process-environment (cons (concat "HOME=" home) process-environment))
           (abbreviated-home-dir nil))
      (make-directory home t)
      (let ((proj (drgnx-stt--project (expand-file-name "proj/" home))))
        (dolist (parents (list '(("~/" :code t)) '(("/" :code t))
                               (list (list (file-name-directory (directory-file-name home)) :code t))
                               (list (list temporary-file-directory :code t))))
          (let ((drgnx-trust-parents parents))
            (should (eq (drgnx-settings-trust-state proj) 'untrusted))
            (should-not (drgnx-settings-trust--parents))))
        (let ((drgnx-trust-parents '(("~/proj/" :code t))))   ; a project folder is fine
          (should (eq (drgnx-settings-trust-state proj) 'everything)))))))

(ert-deftest drgnx-settings-trust/a-new-clone-under-a-location-is-covered ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (let ((clone (drgnx-stt--project (expand-file-name "clone/" drgnx-stt--ws))))   ; made after the setting
      (drgnx-stt--put ".dir-locals.el" "((nil . ((drgnx-stt-data . \"clone\"))))\n" clone)
      (should (eq (drgnx-settings-trust-state clone) 'location))
      (with-current-buffer (drgnx-stt--open "x.txt" clone)
        (should (equal drgnx-stt-data "clone"))
        (should-not drgnx-stt--prompts)))))

(ert-deftest drgnx-settings-trust/the-location-notice-comes-once-per-machine ()
  ;; The first trust by location is announced once on this machine: trusted-folders.eld keeps the root (:announced),
  ;; so the next session (fresh session state) says nothing again.
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" "((nil . ((drgnx-stt-data . \"x\"))))\n")
    (let ((told nil))
      (cl-letf (((symbol-function 'drgnx-notify)
                 (lambda (_s _v text &rest _) (when (string-match-p "is trusted for data" text) (push text told)) nil)))
        (drgnx-stt--open "a.txt")
        (drgnx-stt--open "b.txt")
        (should (= 1 (length told)))
        (should (equal (mapcar #'drgnx-stt--norm
                               (plist-get (plist-get (drgnx-file-read (drgnx-trust-folders-file)) :data) :announced))
                       (list drgnx-stt--proj)))
        (setq drgnx-settings-trust--announced nil drgnx-settings-trust--data nil)   ; the next start
        (drgnx-stt--reopen "a.txt")
        (should (= 1 (length told)))))))

(ert-deftest drgnx-settings-trust/location-trust-is-not-trusted-content ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-settings-trust--sync-content)
    (drgnx-stt--in "a.txt" (should-not (trusted-content-p)))
    (should-not (member (abbreviate-file-name drgnx-stt--ws) trusted-content))
    (let ((drgnx-trust-parents (list (list drgnx-stt--ws :code t))))
      (drgnx-settings-trust--sync-content)
      (should (member (abbreviate-file-name drgnx-stt--ws) trusted-content)))
    (drgnx-settings-trust--sync-content)               ; :code t taken away: out of trusted-content again
    (should-not (member (abbreviate-file-name drgnx-stt--ws) trusted-content))))

;;;; Nothing in Emacs's own trust stores

(ert-deftest drgnx-settings-trust/nothing-reaches-safe-local-variable-values ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (drgnx-stt--open "a.txt")
    (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
    (drgnx-settings-trust-this-folder drgnx-stt--proj (drgnx-settings-trust-code-pairs drgnx-stt--proj))
    (drgnx-stt--reopen "a.txt")
    (should-not safe-local-variable-values)
    (should-not (default-value 'safe-local-variable-values))
    (should-not (file-exists-p custom-file))))

(ert-deftest drgnx-settings-trust/never-a-root-in-safe-local-variable-directories ()
  (drgnx-stt--with (list (list drgnx-stt--ws))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (drgnx-stt--open "a.txt")
    (drgnx-settings-trust-allow drgnx-stt--proj (drgnx-settings-trust-waiting drgnx-stt--proj))
    (drgnx-settings-trust-this-folder drgnx-stt--proj (drgnx-settings-trust-code-pairs drgnx-stt--proj))
    (let ((drgnx-trust-parents (list (list drgnx-stt--ws :code t))))
      (drgnx-settings-trust--sync-content)
      (drgnx-settings-workspace-rehack drgnx-stt--proj)
      (drgnx-stt--reopen "a.txt"))
    (should-not safe-local-variable-directories)
    (should-not (default-value 'safe-local-variable-directories))))

(ert-deftest drgnx-settings-trust/security-settings-ignored-in-dir-locals ()
  (drgnx-stt--with (list (list drgnx-stt--ws :code t))
    (drgnx-stt--put ".dir-locals.el"
                    "((nil . ((drgnx-trust-parents . ((\"/\" :code t))) (drgnx-stt--secure . t) (fill-column . 61))))\n")
    (drgnx-stt--write (expand-file-name "f.txt" drgnx-stt--proj) "-*- drgnx-stt--secure: t -*-\n")
    (drgnx-stt--in "a.txt"
      (should (= fill-column 61))
      (should-not (local-variable-p 'drgnx-trust-parents))
      (should-not (local-variable-p 'drgnx-stt--secure)))
    (drgnx-stt--in "f.txt" (should-not (local-variable-p 'drgnx-stt--secure)))
    (should-not drgnx-stt--prompts)
    (dolist (v '(drgnx-trust-parents drgnx-stt--secure))
      (should (memq v (default-value 'ignored-local-variables)))
      (should (get v 'risky-local-variable))
      (should (eq (drgnx-settings-trust-class v nil 'dir-locals) 'never)))))

(ert-deftest drgnx-settings-trust/an-agents-never-project-setting-is-not-guarded ()
  ;; `:agents never' alone (like `drgnx-ai-roles', `:workspace data') is a project's to set: not in
  ;; `ignored-local-variables', so its W1 entry goes through the filter (applies when trusted, waits when not)
  (drgnx-stt--with nil
    (drgnx-settings-trust--guard)
    (should-not (memq 'drgnx-stt--routes (default-value 'ignored-local-variables)))
    (should (memq 'drgnx-stt--secure (default-value 'ignored-local-variables)))
    (should (eq (drgnx-settings-trust-class 'drgnx-stt--routes '((chat x)) 'shared) 'data))
    (drgnx-stt--put ".drgnx/settings.el" "(drgnx-workspace-settings\n :version 1\n (drgnx-stt--routes ((chat x))))\n")
    (should-not (drgnx-setting-for-root 'drgnx-stt--routes drgnx-stt--proj))
    (setq drgnx-trust-parents (list (list drgnx-stt--ws)) drgnx-settings-trust--data nil)
    (should (equal (drgnx-setting-for-root 'drgnx-stt--routes drgnx-stt--proj) '((chat x))))))

(ert-deftest drgnx-settings-trust/the-ai-eld-shim-goes-through-the-filter ()
  (require 'drgnx-ai)
  (drgnx-stt--with nil
    (drgnx-stt--put ".drgnx/ai.eld" "(:version 1 :roles ((chat (ollama . \"m\"))))\n")
    (let ((drgnx-ai-roles nil))
      (should-not (drgnx-setting-for-root 'drgnx-ai-roles drgnx-stt--proj))   ; untrusted: the roles wait
      (setq drgnx-trust-parents (list (list drgnx-stt--ws)) drgnx-settings-trust--data nil)
      (should (equal (drgnx-setting-for-root 'drgnx-ai-roles drgnx-stt--proj) '((chat (ollama . "m"))))))))

(ert-deftest drgnx-settings-trust/enable-local-eval-nil-still-blocks-eval ()
  (drgnx-stt--with (list (list drgnx-stt--ws :code t))
    (drgnx-stt--put ".dir-locals.el" drgnx-stt--dl)
    (let ((enable-local-eval nil))
      (drgnx-stt--in "a.txt"
        (should (eq drgnx-stt-risky-function 'ignore))
        (should-not drgnx-stt--evals)
        (should-not drgnx-stt--prompts)))))

;;;; The migration of today's trust

(ert-deftest drgnx-settings-trust/old-trust-migrates-once ()
  (drgnx-stt--with nil
    (drgnx-stt--put ".dir-locals.el" "((nil . ((eval . (push 'old drgnx-stt--evals)))))\n")
    (drgnx-stt--write (drgnx-trust-folders-file)
                      (format "(:version 1 :folders (%S))\n" (abbreviate-file-name drgnx-stt--proj)))
    (let ((told nil))
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (_s _v text &rest _) (push text told) nil)))
        (let ((recorded (drgnx-settings-trust-migrate)))
          (should (equal (mapcar #'car recorded) (list drgnx-stt--proj)))
          (should (equal (cdar recorded) '((".dir-locals.el" eval "(push 'old drgnx-stt--evals)")))))
        (should-not (drgnx-settings-trust-migrate))      ; once
        (should (= (length told) 1)))
      (let ((data (plist-get (drgnx-file-read (drgnx-trust-folders-file)) :data)))
        (should (eq (plist-get data :version) 2))
        (should (equal (plist-get data :folders) (list (abbreviate-file-name drgnx-stt--proj))))))
    (should (eq (drgnx-settings-trust-state drgnx-stt--proj) 'trusted))
    (drgnx-stt--in "a.txt" (should (equal drgnx-stt--evals '(old))))
    (should-not drgnx-stt--prompts)))

;;;; Safe mode and Turn Off Package Settings (US-WORKSPACE-SAFE-MODE-1)

(ert-deftest drgnx-settings-trust/workspace-layers-own-only-in-safe-mode-and-turned-off ()
  (drgnx-stt--with (list (list drgnx-stt--ws :code t))
    (drgnx-stt--write (expand-file-name "proj.el" (drgnx-settings-workspace-private-dir))
                      (format "(drgnx-workspace-settings\n :version 1\n :roots (%S)\n (fill-column 91)\n (drgnx-stt--own 5)\n (:eval (push 'w2 drgnx-stt--evals)))\n"
                              drgnx-stt--proj))
    (drgnx-stt--put ".drgnx/settings.el" "(drgnx-workspace-settings\n :version 1\n (tab-width 3)\n (:eval (push 'w1 drgnx-stt--evals)))\n")
    (dolist (env '(("DRGNX_SAFE=1") nil))
      (let ((process-environment (append env process-environment))
            (drgnx-settings-package-settings-off (null env)))
        (should (drgnx-settings-own-only-p))
        (with-current-buffer (drgnx-stt--reopen "a.txt")
          (should (= drgnx-stt--own 5))
          (should-not (local-variable-p 'fill-column))
          (should-not (local-variable-p 'tab-width))
          (should-not drgnx-stt--evals))))
    (with-current-buffer (drgnx-stt--reopen "a.txt")      ; back on
      (should (= fill-column 91))
      (should (= tab-width 3))
      (should (equal (sort (copy-sequence drgnx-stt--evals) #'string<) '(w1 w2))))))

;;;; The doctor

(ert-deftest drgnx-settings-trust/doctor-names-dir-locals-trust-outside-trusted-folders ()
  (drgnx-stt--with nil
    (should-not (drgnx-doctor--dir-locals-trusted-check (drgnx-doctor--dir-locals-trusted)))
    (let ((safe-local-variable-directories (list drgnx-stt--proj)))
      (should (eq (car (drgnx-doctor--dir-locals-trusted-check (drgnx-doctor--dir-locals-trusted))) 'warn))
      (let ((inhibit-message t)) (drgnx-trust-folder drgnx-stt--proj))
      (should-not (drgnx-doctor--dir-locals-trusted-check (drgnx-doctor--dir-locals-trusted))))))

(provide 'settings-trust-test)
;;; settings-trust-test.el ends here
