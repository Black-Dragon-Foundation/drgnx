;;; drgnx-debug-launch.el --- Debugging: launch configurations, the picker, inputs and trust -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of starting a debug session through the hub (docs/develop/debugging.md, "The `debug/*`
;; methods"): the configurations of a project (`debug/configs`: launch.json's, yours from `drgnx-debug-configurations',
;; the adapters' defaults for the file's language), the picker, the inputs a configuration asks for (`${input:…}`,
;; `${command:pickProcess}`) in the minibuffer, and trust: the hub runs nothing in a project it was not told is
;; trusted, so a start in one asks first, Trust This Folder tells the hub (`debug/trust'), and so does taking it back,
;; which stops the project's sessions.  Everything here runs from a command you invoked.
;;
;; `drgnx-debug-convert-dape-configs' turns your dape configurations into `drgnx-debug-configurations' once.

;;; Code:
(require 'cl-lib)
(require 'project)
(require 'drgnx-setting)
(require 'drgnx-hub-client)
(declare-function drgnx-trust-folder "drgnx-trust")
(declare-function drgnx-settings-defaults-save "drgnx-settings-defaults")
(defvar dape-configs)

(drgnx-defsetting drgnx-debug-configurations nil
  "Your own launch configurations, offered in every project after launch.json's: VS Code's launch.json fields as a
plist each (`:type', `:request', `:name', `:program' …), `${…}' variables as in launch.json."
  :type '(repeat (plist :key-type symbol :value-type sexp)) :group 'drgnx :scope 'global :workspace 'never)

(drgnx-defsetting drgnx-debug-adapters nil
  "Your own debug adapters, looked at before drgnx's (etc/debug-adapters.eld): a plist each in that table's fields
\(`:id', `:name', `:types', `:languages', `:find', `:start' …).  An adapter is a program run with your rights, so a
project's settings never set this."
  :type '(repeat (plist :key-type symbol :value-type sexp)) :group 'drgnx :scope 'global :workspace 'never)

(defconst drgnx-debug-launch--languages
  '(("python" . "python") ("go" . "go") ("js" . "javascript") ("javascript" . "javascript")
    ("js-jsx" . "javascript") ("typescript" . "typescript") ("tsx" . "typescript") ("c" . "c") ("c++" . "c++")
    ("rust" . "rust") ("rustic" . "rust"))
  "Major-mode stems (the name without `-ts-mode' or `-mode') and the adapter table's language for each.")

(defun drgnx-debug-launch-language (&optional mode)
  "The adapter table's language of MODE (default: this buffer's major mode), or nil."
  (let ((stem (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" (symbol-name (or mode major-mode)))))
    (cdr (assoc stem drgnx-debug-launch--languages))))

(defun drgnx-debug-launch-root ()
  "This buffer's project root (else its folder), absolute, without the trailing slash."
  (directory-file-name
   (expand-file-name (if-let* ((p (project-current))) (project-root p) default-directory))))

(defun drgnx-debug-launch--json-key (k)
  "Plist key K as a JSON key: the keyword's name, `-' as `_' (the table's Rust field names)."
  (intern (concat ":" (replace-regexp-in-string "-" "_" (substring (symbol-name k) 1)))))

(defun drgnx-debug-launch--adapter (plist)
  "One adapter PLIST of `drgnx-debug-adapters' as the hub reads it: keys with `_', nested plists too, lists as arrays."
  (let (out)
    (while plist
      (let ((v (cadr plist)))
        (push (drgnx-debug-launch--json-key (car plist)) out)
        (push (cond ((and (consp v) (keywordp (car v))) (drgnx-debug-launch--adapter v))
                    ((consp v) (vconcat v))
                    ((eq v t) t)
                    (t v))
              out))
      (setq plist (cddr plist)))
    (nreverse out)))

(defun drgnx-debug-launch--params (root &rest more)
  "The params every call about ROOT carries: the language, your configurations and adapters, then MORE."
  (append (list :root root)
          (when-let* ((l (drgnx-debug-launch-language))) (list :language l))
          (when drgnx-debug-configurations (list :user (vconcat drgnx-debug-configurations)))
          (when drgnx-debug-adapters
            (list :adapters (vconcat (mapcar #'drgnx-debug-launch--adapter drgnx-debug-adapters))))
          more))

;;;; Trust

(defun drgnx-debug-launch-trusted-p (root)
  "Whether ROOT is trusted content (`trusted-content-p' for a file in it)."
  (with-temp-buffer
    (setq buffer-file-truename (abbreviate-file-name (file-truename (expand-file-name "launch.json" root))))
    (setq default-directory (file-name-as-directory root))
    (trusted-content-p)))

(defun drgnx-debug-launch--tell-trust (root)
  "Tell the hub ROOT is trusted when it is (the hub keeps no trust of its own across starts)."
  (when (drgnx-debug-launch-trusted-p root)
    (drgnx-hub-call-sync "debug/trust" (list :root root :trusted t))))

(defun drgnx-debug-launch-trust-changed (folder trusted)
  "`drgnx-trust-changed-functions': FOLDER's new trust goes to the hub (taking it back stops its sessions)."
  (when (drgnx-hub-running-p)
    (drgnx-hub-call "debug/trust" (list :root (directory-file-name (expand-file-name folder)) :trusted (and trusted t))
                    #'ignore)))

(defun drgnx-debug-launch--trust-card (root)
  "Ask whether to trust ROOT before a start; non-nil when it is trusted now."
  (when (yes-or-no-p
         (format "%s is not trusted: a launch configuration runs programs with your rights.  Trust This Folder? "
                 (abbreviate-file-name root)))
    (require 'drgnx-trust)
    (drgnx-trust-folder root)
    (drgnx-hub-call-sync "debug/trust" (list :root root :trusted t))
    t))

;;;; Configurations and the picker

(defun drgnx-debug-launch-configs (root)
  "`debug/configs' for ROOT: (:configs [...] :last ID :error ERR)."
  (drgnx-debug-launch--tell-trust root)
  (drgnx-hub-call-sync "debug/configs"
                       (apply #'drgnx-debug-launch--params root
                              (and buffer-file-name (list :file (expand-file-name buffer-file-name))))))

(defun drgnx-debug-launch--show-error (err)
  "Open launch.json at ERR's line and column, and say what is wrong."
  (find-file (plist-get err :path))
  (goto-char (point-min))
  (forward-line (1- (plist-get err :line)))
  (move-to-column (max 0 (1- (plist-get err :col))))
  (message "launch.json: %s" (plist-get err :message)))

(defun drgnx-debug-launch-read-config (root)
  "Pick a configuration of ROOT in the minibuffer; its id.  A launch.json that does not read opens where it fails."
  (let* ((r (drgnx-debug-launch-configs root))
         (configs (append (plist-get r :configs) nil))
         (err (plist-get r :error)))
    (when (and err (null configs))
      (drgnx-debug-launch--show-error err)
      (user-error "launch.json does not read: %s" (plist-get err :message)))
    (unless configs
      (user-error "No launch configuration for %s: add .vscode/launch.json, or open a file of a language drgnx debugs"
                  (abbreviate-file-name root)))
    (let* ((rows (mapcar (lambda (c) (cons (plist-get c :name) c)) configs))
           (last (seq-find (lambda (c) (equal (plist-get c :id) (plist-get r :last))) configs))
           (completion-extra-properties
            (list :annotation-function
                  (lambda (name)
                    (let ((c (cdr (assoc name rows))))
                      (format "  %s · %s%s" (plist-get c :type) (plist-get c :source)
                              (if (eq (plist-get c :needs_trust) t) " · not trusted" ""))))))
           (name (completing-read "Debug configuration: " rows nil t nil nil (and last (plist-get last :name)))))
      (plist-get (cdr (assoc name rows)) :id))))

;;;; Inputs

(defun drgnx-debug-launch--processes ()
  "This user's processes as (\"PID  NAME  ARGS\" . PID), newest first."
  (let ((me (user-uid)) rows)
    (dolist (pid (list-system-processes))
      (let ((a (process-attributes pid)))
        (when (eql (alist-get 'euid a) me)
          (push (cons (format "%-8d %s  %s" pid (or (alist-get 'comm a) "") (or (alist-get 'args a) "")) pid) rows))))
    (sort rows (lambda (x y) (> (cdr x) (cdr y))))))

(defun drgnx-debug-launch--ask (need)
  "Ask NEED (`debug/start''s: an input plist, or \"pickProcess\"); (:id ID :value VALUE)."
  (if (equal need "pickProcess")
      (let* ((rows (drgnx-debug-launch--processes))
             (pick (completing-read "Attach to process: " rows nil t)))
        (list :id "pickProcess" :value (number-to-string (cdr (assoc pick rows)))))
    (let* ((in (plist-get need :input))
           (prompt (concat (let ((d (plist-get in :description)))
                             (if (or (null d) (string-empty-p d)) (plist-get in :id) d))
                           ": "))
           (default (plist-get in :default)))
      (list :id (plist-get in :id)
            :value (cond ((equal (plist-get in :kind) "pickString")
                          (completing-read prompt (append (plist-get in :options) nil) nil t nil nil default))
                         ((eq (plist-get in :password) t) (read-passwd prompt))
                         (t (read-string prompt nil nil default)))))))

;;;; Starting

(defun drgnx-debug-launch-start (root config)
  "Start CONFIG (an id of `debug/configs') in ROOT: trust first, then the inputs it needs; the session's id."
  (drgnx-debug-launch--tell-trust root)
  (let ((place (append (and buffer-file-name (list :file (expand-file-name buffer-file-name)))
                       (list :line (line-number-at-pos) :col (1+ (current-column)))
                       (and (use-region-p)
                            (list :selection (buffer-substring-no-properties (region-beginning) (region-end))))))
        (answers nil) (session nil) (asked 0))
    (while (not session)
      (let* ((r (drgnx-hub-call-sync "debug/start"
                                     (apply #'drgnx-debug-launch--params root
                                            (append (list :config config :inputs (vconcat answers)) place))
                                     30))
             (needs (plist-get r :needs)))
        (cond ((plist-get r :session) (setq session (plist-get r :session)))
              ((equal needs "trust")
               (unless (drgnx-debug-launch--trust-card root) (user-error "Not started: the folder is not trusted")))
              ((and needs (< (cl-incf asked) 10))
               (setq answers (append answers (mapcar #'drgnx-debug-launch--ask needs))))
              (t (error "debug/start asked for nothing it could be given")))))
    session))

;;;; dape's configurations, once

(defconst drgnx-debug-launch--dape-only
  '(modes ensure command command-args command-cwd command-env command-insert-stderr port host fn compile
          prefix-local prefix-remote)
  "dape's own keys, which say how dape starts an adapter: never in a launch configuration.")

(defun drgnx-debug-launch--dape-value (v)
  "V of a dape configuration as data: a function is called once; a list of data stays."
  (cond ((functionp v) (funcall v))
        (t v)))

(defun drgnx-debug-launch-convert-dape (configs)
  "CONFIGS (`dape-configs': (NAME . PLIST) each) as launch configurations: (CONVERTED . NOT-CONVERTED), NOT-CONVERTED
\(NAME . WHY) for each that could not be."
  (let (done failed)
    (dolist (entry configs)
      (let ((name (symbol-name (car entry))) (plist (cdr entry)) (out nil) (why nil))
        (condition-case err
            (while plist
              (let ((k (car plist)) (v (cadr plist)))
                (when (and (keywordp k) (not (memq (intern (substring (symbol-name k) 1)) drgnx-debug-launch--dape-only)))
                  (setq out (plist-put out k (drgnx-debug-launch--dape-value v)))))
              (setq plist (cddr plist)))
          (error (setq why (error-message-string err))))
        (unless (or why (plist-get out :type)) (setq why "no :type"))
        (if why
            (push (cons name why) failed)
          (push (append (list :name name) (if (plist-get out :request) out (plist-put out :request "launch"))) done))))
    (cons (nreverse done) (nreverse failed))))

(defun drgnx-debug-convert-dape-configs ()
  "Turn your dape configurations into `drgnx-debug-configurations', once: each is evaluated here, now, and the plain
result is saved in settings.el; the ones that cannot be are named."
  (interactive)
  (unless (require 'dape nil t)
    (user-error "dape is not installed: there is nothing to convert"))
  (let* ((r (drgnx-debug-launch-convert-dape dape-configs))
         (names (mapcar (lambda (c) (plist-get c :name)) drgnx-debug-configurations))
         (new (seq-remove (lambda (c) (member (plist-get c :name) names)) (car r))))
    (require 'drgnx-settings-defaults)
    (drgnx-settings-defaults-save 'drgnx-debug-configurations (append drgnx-debug-configurations new))
    (message "Converted %d dape configuration(s)%s" (length new)
             (if (cdr r)
                 (format "; not converted: %s"
                         (mapconcat (lambda (f) (format "%s (%s)" (car f) (cdr f))) (cdr r) ", "))
               ""))))

(provide 'drgnx-debug-launch)
;;; drgnx-debug-launch.el ends here
