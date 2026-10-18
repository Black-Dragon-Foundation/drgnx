;;; drgnx-agent-config.el --- the settings model shared by the agent settings pages -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What every agent settings page (Claude Code, Codex, Gemini, Kimi Code) shares: where each agent keeps its files,
;; the shape of an item (an MCP server, a hook, a skill), the generic functions each agent file implements
;; (`drgnx-agent-config-read', `-scopes', `-write'), JSON files read and written safely (key order and indent kept,
;; one backup, atomic, never a file the reader could not parse), secret masking, a status check that runs nothing,
;; and skills.  See docs/develop/core.md.
;;
;; An item is a plist (:kind :section mcp|hook|skill :name :from user|project|local|plugin|extension|system|legacy
;; :file :line :spec :enabled :readonly :problem).  :spec for an MCP server is (:type stdio|http|sse :command :args
;; :env :url :headers), for a hook (:event :matcher :command :timeout), for a skill (:dir :description).  :env and
;; :headers are alists (("NAME" . "value")…), their keys strings or symbols.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'json)

(defconst drgnx-agent-config-kinds '(claude codex gemini kimi)
  "The agents with a settings page.")

(define-error 'drgnx-agent-config-unreadable "Unreadable settings file")

(defconst drgnx-agent-config-mask "••••"
  "What replaces a secret in text shown to the user.")

;;;; Kinds and homes

(defun drgnx-agent-config-title (kind)
  "The name of agent KIND as the user knows it."
  (pcase kind
    ('claude "Claude Code")
    ('codex "Codex")
    ('gemini "Gemini")
    ('kimi "Kimi Code")
    (_ (error "No such agent: %S" kind))))

(defun drgnx-agent-config--env-dir (variable)
  "The directory VARIABLE names, or nil when it is unset or empty."
  (let ((value (getenv variable)))
    (and value (not (string-empty-p value)) value)))

(defun drgnx-agent-config-home (kind)
  "The directory (with a trailing slash) where agent KIND keeps its user-level files.
Claude: $CLAUDE_CONFIG_DIR, else ~/.claude.  Codex: $CODEX_HOME, else ~/.codex.  Gemini: .gemini under
$GEMINI_CLI_HOME (the variable gemini 0.64 replaces the home directory with), else ~/.gemini.  Kimi: $KIMI_CODE_HOME,
else ~/.kimi-code."
  (file-name-as-directory
   (expand-file-name
    (pcase kind
      ('claude (or (drgnx-agent-config--env-dir "CLAUDE_CONFIG_DIR") "~/.claude"))
      ('codex (or (drgnx-agent-config--env-dir "CODEX_HOME") "~/.codex"))
      ('gemini (if-let* ((home (drgnx-agent-config--env-dir "GEMINI_CLI_HOME")))
                   (expand-file-name ".gemini" home)
                 "~/.gemini"))
      ('kimi (or (drgnx-agent-config--env-dir "KIMI_CODE_HOME") "~/.kimi-code"))
      (_ (error "No such agent: %S" kind))))))

;;;; What each agent file implements

(cl-defgeneric drgnx-agent-config-read (kind root)
  "Everything agent KIND has configured, for the project ROOT (or nil).
Returns (:rules FILES :items ITEMS :problems ((FILE LINE MESSAGE)…) :routes ROUTES :notes STRINGS).")

(cl-defmethod drgnx-agent-config-read (kind _root)
  (error "No settings model for agent %S" kind))

(cl-defgeneric drgnx-agent-config-scopes (kind section root)
  "Where an item of SECTION (mcp, hook or skill) may be added for KIND: ((SCOPE LABEL FILE)…).")

(cl-defmethod drgnx-agent-config-scopes (kind _section _root)
  (error "No settings model for agent %S" kind))

(cl-defgeneric drgnx-agent-config-write (kind op item scope root callback)
  "Do OP (add, edit, remove or toggle) with ITEM in SCOPE for KIND, in the project ROOT.
CALLBACK gets (:ok t :note STRING) or (:error STRING): at once for a file, later for a CLI.")

(cl-defmethod drgnx-agent-config-write (kind _op _item _scope _root _callback)
  (error "No settings model for agent %S" kind))

;;;; Files: text, JSON, backups

(defun drgnx-agent-config-read-text (file)
  "FILE's text, byte for byte (UTF-8, line ends and a byte order mark kept)."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (buffer-string)))

(defun drgnx-agent-config--temp-file (file)
  "A new private temp file next to FILE."
  (make-temp-file (concat (file-name-directory file) ".drgnx-tmp-")))

(defun drgnx-agent-config--save-backup (file)
  "Copy FILE to FILE.drgnx-bak (replacing the last backup), atomically, with FILE's modes."
  (let ((tmp (drgnx-agent-config--temp-file file)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            (let ((coding-system-for-write 'no-conversion))
              (write-region nil nil tmp nil 'silent)))
          (set-file-modes tmp (file-modes file))
          (rename-file tmp (concat file ".drgnx-bak") t))
      (when (file-exists-p tmp) (delete-file tmp)))))

(defun drgnx-agent-config-write-text (file text check &optional verify)
  "Replace the content of FILE with TEXT, safely.
CHECK is called with FILE's current text (when FILE exists) and must not signal; otherwise nothing is touched.
VERIFY, when given, is called the same way with TEXT.  Then FILE is copied to FILE.drgnx-bak (the one backup),
TEXT goes to a temp file next to FILE with FILE's modes (0600 for a new file), and the temp file is renamed over
FILE.  A symbolic link is written through.  Parent directories are made."
  (let* ((file (file-truename (expand-file-name file)))
         (exists (file-exists-p file)))
    (when exists (funcall check (drgnx-agent-config-read-text file)))
    (when verify (funcall verify text))
    (make-directory (file-name-directory file) t)
    (when exists (drgnx-agent-config--save-backup file))
    (let ((tmp (drgnx-agent-config--temp-file file)))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region text nil tmp nil 'silent))
            (set-file-modes tmp (if exists (file-modes file) #o600))
            (rename-file tmp file t))
        (when (file-exists-p tmp) (delete-file tmp))))
    file))

(defun drgnx-agent-config--json-fail (file line message)
  "Signal `drgnx-agent-config-unreadable' for FILE at LINE with MESSAGE."
  (signal 'drgnx-agent-config-unreadable (list file line message)))

(defun drgnx-agent-config--json-parse (file text)
  "The JSON value in TEXT (FILE's text, for messages); nil for a blank text.
Signals `drgnx-agent-config-unreadable' with (FILE LINE MESSAGE)."
  (with-temp-buffer
    (insert (string-remove-prefix "\ufeff" text))
    (goto-char (point-min))
    (skip-chars-forward " \t\r\n")
    (if (eobp)
        nil
      (let ((value
             (condition-case err
                 (json-parse-buffer :object-type 'alist :array-type 'array
                                    :null-object :null :false-object :false)
               (error
                (let* ((data (cdr err))
                       (line (and (integerp (car-safe data)) (car data)))
                       (pos (nth 2 data))
                       (message (or (get (car err) 'error-message) "Invalid JSON")))
                  ;; The parser names the closing bracket after a trailing comma; name the comma's line.
                  (when (and (integerp pos) (<= (point-min) pos (point-max))
                             (memq (char-after pos) '(?\} ?\])))
                    (goto-char pos)
                    (skip-chars-backward " \t\r\n")
                    (when (eq (char-before) ?,)
                      (setq line (line-number-at-pos (1- (point))) message "trailing comma")))
                  (drgnx-agent-config--json-fail file line message))))))
        (skip-chars-forward " \t\r\n")
        (unless (eobp)
          (drgnx-agent-config--json-fail file (line-number-at-pos) "unexpected text after the JSON value"))
        value))))

(defun drgnx-agent-config-json-read (file)
  "Read the JSON file FILE as (:value VALUE :indent N).
Objects are alists with symbol keys (insertion order), arrays vectors, null `:null', false `:false'.  A missing or
blank file is (:value nil :indent 2).  A file that does not parse signals `drgnx-agent-config-unreadable' with
data (FILE LINE MESSAGE).  N is the file's indent in spaces (2 when unknown, or for tabs)."
  (if (not (file-exists-p file))
      (list :value nil :indent 2)
    (let* ((text (drgnx-agent-config-read-text file))
           (value (drgnx-agent-config--json-parse file text))
           (indent (if (string-match "^\\([ \t]+\\)[^ \t\r\n]" text)
                       (let ((lead (match-string 1 text)))
                         (if (eq (aref lead 0) ?\t) 2 (length lead)))
                     2)))
      (list :value value :indent indent))))

(defun drgnx-agent-config--json-scalar (value)
  "VALUE (string, number, t, :null or :false) as JSON text."
  (decode-coding-string (substring (json-serialize (vector value)) 1 -1) 'utf-8))

(defun drgnx-agent-config--json-encode (value indent level)
  "VALUE as JSON text, objects and arrays one entry per line, INDENT spaces per LEVEL."
  (let ((pad (make-string (* indent (1+ level)) ?\s))
        (end (make-string (* indent level) ?\s)))
    (cond
     ((null value) "{}")
     ((vectorp value)
      (if (zerop (length value))
          "[]"
        (concat "[\n"
                (mapconcat (lambda (v) (concat pad (drgnx-agent-config--json-encode v indent (1+ level))))
                           value ",\n")
                "\n" end "]")))
     ((and (consp value) (consp (car value)))
      (concat "{\n"
              (mapconcat
               (lambda (pair)
                 (unless (and (consp pair) (or (symbolp (car pair)) (stringp (car pair))))
                   (error "Not a JSON object entry: %S" pair))
                 (concat pad
                         (drgnx-agent-config--json-scalar (if (symbolp (car pair)) (symbol-name (car pair)) (car pair)))
                         ": " (drgnx-agent-config--json-encode (cdr pair) indent (1+ level))))
               value ",\n")
              "\n" end "}"))
     ((consp value) (error "Not a JSON value (an array is a vector): %S" value))
     (t (drgnx-agent-config--json-scalar value)))))

(defun drgnx-agent-config-json-write (file value indent)
  "Write VALUE (as `drgnx-agent-config-json-read' returns it) to FILE, INDENT spaces per level.
Key order as in VALUE, a final newline.  Goes through `drgnx-agent-config-write-text': a FILE that does not parse
is not written, and neither is a text that does not parse back."
  (let ((text (concat (drgnx-agent-config--json-encode value indent 0) "\n")))
    (drgnx-agent-config-write-text
     file text
     (lambda (current) (drgnx-agent-config--json-parse file current))
     (lambda (new) (drgnx-agent-config--json-parse file new)))))

;;;; Secrets

(defconst drgnx-agent-config--secret-key-re "token\\|secret\\|key\\|password\\|authorization"
  "Keys whose values are secrets.")

(defun drgnx-agent-config--key-name (key)
  "KEY (a keyword, symbol or string) as a plain string, or nil."
  (cond ((keywordp key) (substring (symbol-name key) 1))
        ((and key (symbolp key)) (symbol-name key))
        ((stringp key) key)))

(defun drgnx-agent-config--pairs (x)
  "The (KEY . VALUE) pairs of X when it is a plist or an alist, else nil."
  (cond ((and (consp x) (keywordp (car x)) (cl-evenp (length x)))
         (cl-loop for (k v) on x by #'cddr collect (cons k v)))
        ((and (consp x) (cl-every (lambda (e) (and (consp e) (atom (car e)))) x)) x)))

(defun drgnx-agent-config-secrets (spec)
  "The secret strings in SPEC (an item's :spec): every :env and :headers value, and the value of any key
matching token, secret, key, password or authorization (case-insensitive), when longer than 3 characters.
A header value like \"Bearer abc\" also gives the bare \"abc\"."
  (let ((case-fold-search t) out)
    (cl-labels ((add (v)
                  (when (and (stringp v) (> (length v) 3))
                    (cl-pushnew v out :test #'equal)
                    (when (and (string-match "\\`\\(?:Bearer\\|Basic\\|Token\\)[ \t]+\\(.+\\)\\'" v)
                               (> (length (match-string 1 v)) 3))
                      (cl-pushnew (match-string 1 v) out :test #'equal))))
                (walk (x)
                  (cond
                   ((drgnx-agent-config--pairs x)
                    (dolist (pair (drgnx-agent-config--pairs x))
                      (let ((name (drgnx-agent-config--key-name (car pair))))
                        (cond ((member (and name (downcase name)) '("env" "headers"))
                               (dolist (p (drgnx-agent-config--pairs (cdr pair))) (add (cdr p))))
                              ((and name (string-match-p drgnx-agent-config--secret-key-re name)
                                    (stringp (cdr pair)))
                               (add (cdr pair)))
                              (t (walk (cdr pair)))))))
                   ((vectorp x) (mapc #'walk x))
                   ((consp x) (mapc #'walk x)))))
      (walk spec))
    (nreverse out)))

(defun drgnx-agent-config-mask-text (text secrets)
  "TEXT with every string of SECRETS replaced by `drgnx-agent-config-mask'."
  (when text
    (dolist (s (sort (copy-sequence secrets) (lambda (a b) (> (length a) (length b)))) text)
      (unless (string-empty-p s)
        (setq text (string-replace s drgnx-agent-config-mask text))))))

;;;; Status without running anything

(defun drgnx-agent-config--command-found-p (command)
  "Non-nil when COMMAND is an executable file, or is found on `exec-path'."
  (if (string-search "/" command)
      (file-executable-p (expand-file-name command))
    (and (executable-find command) t)))

(defun drgnx-agent-config-cheap-status (item)
  "(STATUS . DETAIL) of ITEM, from files and PATH only; nothing is run.
STATUS is ok, missing-command (a stdio MCP server whose command is not found), no-url (an http or sse MCP server
without one) or unreadable (the item has a :problem, or an MCP server has no usable spec)."
  (let ((spec (plist-get item :spec)))
    (cond
     ((plist-get item :problem) (cons 'unreadable (plist-get item :problem)))
     ((eq (plist-get item :section) 'mcp)
      (let* ((type (plist-get spec :type))
             (command (plist-get spec :command))
             (url (plist-get spec :url))
             (type (or type (cond (command 'stdio) (url 'http)))))
        (pcase type
          ('stdio
           (cond ((not (and (stringp command) (not (string-empty-p command))))
                  (cons 'missing-command "no command"))
                 ((drgnx-agent-config--command-found-p command) (cons 'ok command))
                 (t (cons 'missing-command command))))
          ((or 'http 'sse)
           (if (and (stringp url) (not (string-empty-p url))) (cons 'ok url) (cons 'no-url "no url")))
          (_ (cons 'unreadable "no usable server entry")))))
     (t (cons 'ok nil)))))

;;;; Skills

(defun drgnx-agent-config--unquote (value)
  "VALUE, a YAML scalar, without its quotes."
  (cond ((string-match "\\`\"\\(.*\\)\"\\'" value)
         (replace-regexp-in-string
          "\\\\\\(.\\)"
          (lambda (m) (pcase (aref m 1) (?n "\n") (?t "\t") (c (string c))))
          (match-string 1 value) t t))
        ((string-match "\\`'\\(.*\\)'\\'" value)
         (string-replace "''" "'" (match-string 1 value)))
        (t value)))

(defun drgnx-agent-config--front-matter (text)
  "The scalar keys of the front matter at the start of TEXT, as an alist of strings (nil when it has none).
Block scalars (`>', `|') and indented continuation lines are joined with spaces."
  (let ((lines (split-string (string-remove-prefix "\ufeff" text) "\r?\n")) pairs key)
    (when (string-match-p "\\`---[ \t]*\\'" (or (car lines) ""))
      (catch 'done
        (dolist (line (cdr lines))
          (cond
           ((string-match-p "\\`---[ \t]*\\'" line) (throw 'done nil))
           ((string-match "\\`\\([A-Za-z0-9_-]+\\):[ \t]*\\(.*?\\)[ \t]*\\'" line)
            (setq key (match-string 1 line))
            (push (cons key (let ((v (match-string 2 line)))
                              (if (string-match-p "\\`[>|][+-]?\\'" v) "" v)))
                  pairs))
           ((and key (string-match "\\`[ \t]+\\(.+?\\)[ \t]*\\'" line))
            (let ((cell (assoc key pairs)))
              (setcdr cell (string-trim (concat (cdr cell) " " (match-string 1 line))))))))))
    (mapcar (lambda (p) (cons (car p) (drgnx-agent-config--unquote (cdr p)))) (nreverse pairs))))

(defun drgnx-agent-config-skills-in (dir from kind)
  "The skills under DIR (one per DIR/*/SKILL.md, hidden directories skipped) as items of agent KIND from FROM.
Name and description come from the front matter; the name falls back to the directory's."
  (when (file-directory-p dir)
    (cl-loop
     for sub in (directory-files dir t "\\`[^.]")
     for file = (expand-file-name "SKILL.md" sub)
     when (and (file-directory-p sub) (file-regular-p file))
     collect
     (let* ((text (condition-case err
                      (with-temp-buffer
                        (let ((coding-system-for-read 'utf-8-unix))
                          (insert-file-contents file nil 0 16384))
                        (buffer-string))
                    (error (cons 'problem (error-message-string err)))))
            (front (and (stringp text) (drgnx-agent-config--front-matter text)))
            (name (let ((n (cdr (assoc "name" front)))) (if (member n '(nil "")) (file-name-nondirectory sub) n))))
       (append (list :kind kind :section 'skill :name name :from from :file file :line 1
                     :spec (list :dir sub :description (or (cdr (assoc "description" front)) ""))
                     :enabled t :readonly nil)
               (when (consp text) (list :problem (cdr text))))))))

(defun drgnx-agent-config--yaml-scalar (text)
  "TEXT as a one-line YAML scalar, quoted when plain would be misread."
  (let ((line (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " text))))
    (if (or (string-empty-p line) (string-match-p "[]:#'\"[{}&*!|>%@`,\\]\\|\\`[-?]" line))
        (concat "\"" (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" line) "\"")
      line)))

(defun drgnx-agent-config-new-skill (dir name description)
  "Create DIR/NAME/SKILL.md with front matter (name, description) and a one-line body; return its file name.
NAME is lowercase letters, digits and hyphens.  An existing NAME is refused."
  (unless (string-match-p "\\`[a-z0-9][a-z0-9-]*\\'" name)
    (error "A skill name is lowercase letters, digits and hyphens: %S" name))
  (let* ((skill-dir (expand-file-name name dir))
         (file (expand-file-name "SKILL.md" skill-dir)))
    (when (file-exists-p skill-dir) (error "Skill %s already exists" name))
    (drgnx-agent-config-write-text
     file
     (format "---\nname: %s\ndescription: %s\n---\n\nDescribe what to do when this skill applies.\n"
             name (drgnx-agent-config--yaml-scalar description))
     #'ignore)
    file))

(provide 'drgnx-agent-config)
;;; drgnx-agent-config.el ends here
