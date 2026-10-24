;;; drgnx-settings-agents.el --- Settings: the editor applies agents' changes -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 33 (design §13): the editor's half of the agents' settings tools.  The hub checks an agent's
;; `settings_change' against its grant and the deny-list, records it as a proposed tx and sends the editor
;; `settings/proposed {tx, scope, name, value, root, agent, reason}'; `settings_get' sends `settings/explain {req,
;; scope, names?, root?}'.  Only events of a hub that proved itself are taken.
;; - A proposed change is checked again here, the last gate before a file is written: a name that is no variable or
;;   is `:eval', `eval' or `mode'; a setting marked `:agents never', `:workspace never' or `:workspace code'; a value
;;   that does not read as data; a type, bounds or secret refusal (`drgnx-settings-editors-check').  A refusal writes
;;   nothing and answers `settings/confirm' with `ok' false and the reason.
;; - Otherwise it is written through the settings writer to the file the scope names: global → settings.el; shared →
;;   ROOT/.drgnx/settings.el, refused unless that file's true path is under ROOT's; private → ROOT's private
;;   workspace file (made when there is none).  The write is not reported with `settings/record' again: the hub
;;   recorded the agent's tx already.  Then `settings/confirm' with `ok' true and a notice "AGENT changed NAME to
;;   VALUE in PROJECT [Undo]"; Undo writes the earlier value back, reported as a revert of the agent's tx.
;; - `settings/explain' is answered with `settings/explained {req, settings}': per setting its value (printed), the
;;   layer and source it comes from (`drgnx-settings-explain'; for a project, the workspace files over it).  Only a
;;   drgnx, described or `defcustom' setting is answered, never an `:agents never' one or a name that looks like it
;;   holds a secret (password, token, secret, auth, credential): those rows carry no value.
;; Nothing here prompts; a handler never signals to the hub.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-config)
(require 'drgnx-file)
(require 'drgnx-notice)
(require 'drgnx-setting)
(require 'drgnx-settings-file)
(require 'drgnx-settings-workspace)
(require 'drgnx-settings-editors)
(require 'drgnx-settings-prov)
(require 'drgnx-settings-history)
(require 'drgnx-settings-described)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(defvar drgnx-hub--event-conn)

(defconst drgnx-settings-agents-max-rows 1000 "The most settings one `settings/explained' carries.")
(defconst drgnx-settings-agents-max-value 16384 "The longest printed value a row of `settings/explained' carries.")

;;;; The checks

(defun drgnx-settings-agents--var (name)
  "NAME (a string) as the variable an agent may change, or nil: no keyword, no `eval' or `mode' pseudo-variable."
  (when (and (stringp name) (< 0 (length name) 201)
             (not (string-match-p "[[:space:][:cntrl:]()\"';`,#\\[\\]]" name))
             (not (string-prefix-p ":" name))
             (not (member name '("eval" "mode" "nil" "t"))))
    (intern name)))

(defun drgnx-settings-agents--denied (var)
  "Why VAR is never an agent's to change, or nil: drgnx's deny-list metadata (design §13)."
  (let* ((m (drgnx-setting-meta var)) (ws (plist-get m :workspace)))
    (cond ((eq ws 'code) (format "%s is code: never an agent's" var))
          ((or (eq ws 'never) (eq (plist-get m :agents) 'never))
           (format "%s is a security setting: never an agent's" var)))))

(defun drgnx-settings-agents--value (text)
  "TEXT read as one datum of data: (ok . VALUE), or (problem . MESSAGE)."
  (if (not (stringp text)) (cons 'problem "the value is not text")
    (pcase (drgnx-file--parse text)
      (`(ok . ,x) (cons 'ok (drgnx-settings-file--unquote x)))
      (`(problem . ,p) (cons 'problem (format "the value does not read as data: %s"
                                              (if (consp p) (or (plist-get p :message) p) p))))
      (_ (cons 'problem "the value is empty")))))

(defun drgnx-settings-agents--under-p (file root)
  "Non-nil when FILE's true path is under ROOT's (both followed through links)."
  (string-prefix-p (file-name-as-directory (file-truename root)) (file-truename file)))

(defun drgnx-settings-agents--target (scope root)
  "(FILE HEAD TAB) of SCOPE (\"global\", \"private\", \"shared\") for ROOT, or a string saying why there is none."
  (let ((root (and (stringp root) (not (string-empty-p root)) root)))
    (cond ((equal scope "global") (list (drgnx-config-file 'settings) 'drgnx-settings 'user))
          ((not (member scope '("private" "shared"))) (format "%S is not a settings scope" scope))
          ((or (null root) (not (file-name-absolute-p root)) (file-remote-p root) (not (file-directory-p root)))
           "the session has no folder of its own for a project's settings")
          ((equal scope "shared")
           (let ((file (expand-file-name drgnx-settings-workspace-shared-file (file-name-as-directory root))))
             (if (drgnx-settings-agents--under-p file root)
                 (list file 'drgnx-workspace-settings 'shared)
               (format "%s leads out of %s" drgnx-settings-workspace-shared-file root))))
          (t (list (drgnx-settings-workspace-file root t) 'drgnx-workspace-settings 'workspace)))))

(defun drgnx-settings-agents--entry (file head var)
  "VAR's top-level entry in settings FILE of head HEAD, or nil."
  (cl-find-if (lambda (e) (and (eq (drgnx-settings-entry-var e) var) (null (drgnx-settings-entry-scope e))))
              (drgnx-settings-doc-entries (drgnx-settings-file-read file head))))

(defun drgnx-settings-agents--printed (value)
  (let ((print-length nil) (print-level nil) (print-escape-newlines t)) (prin1-to-string value)))

;;;; settings/proposed

(defun drgnx-settings-agents--confirm (tx ok &optional error)
  "Answer the hub's `settings/proposed' of TX: OK, or refused with ERROR."
  (condition-case err
      (drgnx-hub-call "settings/confirm"
                      (append (list :tx tx :ok (if ok t :false))
                              (and error (list :error (truncate-string-to-width error 4000))))
                      (lambda (_r e) (when e (message "drgnx settings: the hub took no confirm of tx %s: %s" tx e))))
    (error (message "drgnx settings: no confirm of tx %s: %s" tx (error-message-string err)))))

(defun drgnx-settings-agents--short (text)
  (truncate-string-to-width (replace-regexp-in-string "[\n\r]+" " " text) 60 nil nil "…"))

(defun drgnx-settings-agents--where (scope root)
  "Where SCOPE's file is, as the notice says it."
  (pcase scope
    ("global" "your settings")
    ("private" (format "%s (your workspace file)" (file-name-nondirectory (directory-file-name root))))
    (_ (file-name-nondirectory (directory-file-name root)))))

(defun drgnx-settings-agents-apply (data)
  "Apply the agent's change of `settings/proposed' DATA (a plist) if it passes the editor's checks, and confirm it.
Nil when it was refused (and nothing written), else the file written."
  (let* ((tx (plist-get data :tx)) (scope (plist-get data :scope)) (root (plist-get data :root))
         (agent (string-remove-prefix "agent:" (format "%s" (or (plist-get data :agent) "an agent"))))
         (var (drgnx-settings-agents--var (plist-get data :name)))
         (parsed (drgnx-settings-agents--value (plist-get data :value)))
         (value (cdr parsed))
         (tab (pcase scope ("global" 'user) ("private" 'workspace) (_ 'shared)))
         (target nil)
         ;; the file last: a private workspace file is made only for a change that passed every other check
         (why (cond ((null var) (format "%S is not a setting an agent may change" (plist-get data :name)))
                    ((drgnx-settings-agents--denied var))
                    ((eq (car parsed) 'problem) value)
                    ((when-let* ((bad (drgnx-settings-editors-check var value tab)))
                       (format "%s: %s%s" var (if (car bad) (format "%s: " (car bad)) "") (cdr bad))))
                    ((stringp (setq target (condition-case err (drgnx-settings-agents--target scope root)
                                             (error (error-message-string err)))))
                     target))))
    (when (natnump tx)
      (if why
          (progn (drgnx-settings-agents--confirm tx nil why) nil)
        (pcase-let* ((`(,file ,head ,_tab) target)
                     (before (when-let* ((e (drgnx-settings-agents--entry file head var)))
                               (drgnx-settings-agents--printed (drgnx-settings-entry-value e))))
                     (after (drgnx-settings-agents--printed value)))
          (condition-case err
              ;; the hub recorded the agent's tx: the history collects this write and sends nothing
              (let ((drgnx-settings-history--pending (list nil)))
                (drgnx-settings-file-put file head nil var value))
            (error (setq why (format "%s: not written: %s" var (error-message-string err)))))
          (drgnx-settings-agents--confirm tx (not why) why)
          (unless why
            (drgnx-notify 'config 'info
                          (format "%s changed %s to %s in %s [Undo]" agent var (drgnx-settings-agents--short after)
                                  (drgnx-settings-agents--where scope root))
                          :id (intern (format "settings-agent-%s" tx))
                          :command (list 'drgnx-settings-agents-undo tx file head var before after))
            file))))))

(defun drgnx-settings-agents-undo (tx file head var before after)
  "Undo the agent's change TX of VAR in settings FILE (head HEAD): write BEFORE (VAR's printed earlier value; nil:
it had no entry) back, reported as a revert of TX.  A `user-error' when VAR's entry is no longer AFTER."
  (let ((e (drgnx-settings-agents--entry file head var)))
    (unless (equal (and e (drgnx-settings-agents--printed (drgnx-settings-entry-value e))) after)
      (user-error "%s changed since the agent's change: change it in Settings" var))
    (drgnx-settings-history--undo-plans (list (list nil file head nil var before)) tx)))

;;;; settings/explain

(defconst drgnx-settings-agents--secret-name-regexp "password\\|passwd\\|token\\|secret\\|auth\\|credential"
  "A name matching this is never explained to an agent: it may hold a secret.")

(defun drgnx-settings-agents--explainable-p (var)
  "Non-nil when an agent may read VAR's value: a drgnx, described or `defcustom' setting, not `:agents never',
whose name does not look like it holds a secret."
  (and (or (drgnx-setting-own-p var) (get var 'standard-value) (drgnx-settings-described var))
       (not (eq (plist-get (drgnx-setting-meta var) :agents) 'never))
       (not (string-match-p drgnx-settings-agents--secret-name-regexp (symbol-name var)))))

(defun drgnx-settings-agents--row (var root)
  "VAR's row for `settings/explained': its value and where it comes from (for the project at ROOT when given).
A variable that is not `drgnx-settings-agents--explainable-p' gets a row with no value."
  (if (not (drgnx-settings-agents--explainable-p var))
      (list :name (symbol-name var) :source "not shown to agents")
    (drgnx-settings-agents--row-1 var root)))

(defun drgnx-settings-agents--row-1 (var root)
  (let* ((x (with-temp-buffer (drgnx-settings-explain var)))
         (row (list :name (symbol-name var) :value (plist-get x :value) :layer (plist-get x :layer)
                    :source (plist-get x :source) :file (plist-get x :file) :line (plist-get x :line))))
    (when-let* (((and root (default-boundp var) (file-directory-p root)))
                (v(drgnx-setting-for-root var root))
                ((not (equal v (plist-get x :value)))))
      (let* ((private (drgnx-settings-workspace-file root))
             (file (if (and private (drgnx-settings-agents--entry private 'drgnx-workspace-settings var)) private
                     (expand-file-name drgnx-settings-workspace-shared-file root))))
        (setq row (list :name (symbol-name var) :value v :layer (if (equal file private) "W2" "W1")
                        :source (if (equal file private) "your workspace file" "the project's .drgnx/settings.el")
                        :file file))))
    (let ((text (drgnx-settings-agents--printed (plist-get row :value))))
      (plist-put row :value (if (> (length text) drgnx-settings-agents-max-value)
                                (concat (substring text 0 drgnx-settings-agents-max-value) "…")
                              text)))
    (cl-loop for (k v) on row by #'cddr when v append (list k (if (symbolp v) (format "%s" v) v)))))

(defun drgnx-settings-agents-explain (data)
  "The rows that answer `settings/explain' DATA (a plist: :names, :root)."
  (let* ((names (plist-get data :names))
         (vars (if names (delq nil (mapcar #'drgnx-settings-agents--var (append names nil)))
                 (drgnx-setting-names)))
         (root (and (member (plist-get data :scope) '("private" "shared")) (stringp (plist-get data :root))
                    (plist-get data :root))))
    (cl-loop for var in vars for n from 1 to drgnx-settings-agents-max-rows
             collect (condition-case nil (drgnx-settings-agents--row var root)
                       (error (list :name (symbol-name var) :source "could not be explained"))))))

(defun drgnx-settings-agents--answer-explain (data)
  (let ((req (plist-get data :req)))
    (when (natnump req)
      (drgnx-hub-call "settings/explained" (list :req req :settings (vconcat (drgnx-settings-agents-explain data)))
                      #'ignore))))

;;;; The events

(defun drgnx-settings-agents--event (event data)
  "`drgnx-hub-event-functions': the agents' `settings/proposed' and `settings/explain', from a hub that proved itself."
  (when (and (member event '("settings/proposed" "settings/explain"))
             (processp (bound-and-true-p drgnx-hub--event-conn)) (process-get drgnx-hub--event-conn :drgnx-proven))
    (let ((inhibit-interaction t))
      (if (equal event "settings/proposed")
          (drgnx-settings-agents-apply data)
        (drgnx-settings-agents--answer-explain data)))))

(provide 'drgnx-settings-agents)
;;; drgnx-settings-agents.el ends here
