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
(define-error 'drgnx-agent-config-changed "Settings file changed since it was read")

(defconst drgnx-agent-config-mask "••••"
  "What replaces a secret in text shown to the user.")

(defconst drgnx-agent-config-vendor-env
  '("ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL" "ANTHROPIC_SMALL_FAST_MODEL"
    "ANTHROPIC_DEFAULT_HAIKU_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL"
    "ANTHROPIC_DEFAULT_FABLE_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL" "CLAUDE_CODE_OAUTH_TOKEN" "CLAUDE_CODE_USE_BEDROCK"
    "CLAUDE_CODE_USE_VERTEX" "OPENAI_API_KEY" "OPENAI_BASE_URL" "OPENROUTER_API_KEY" "MOONSHOT_API_KEY"
    "DEEPSEEK_API_KEY" "GEMINI_API_KEY" "GOOGLE_API_KEY")
  "The model vendors' keys and switches in Emacs's environment that what drgnx starts for an agent never inherits:
the default of `drgnx-agents-scrubbed-env' (agents), and what MCP Test and Hook Test unset (drgnx-agent-check.el).")

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

(defun drgnx-agent-config-save-backup (file)
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

(defun drgnx-agent-config--make-private-dirs (dir)
  "Make DIR and the parents that are missing, each new one with modes 0700."
  (unless (file-directory-p dir)
    (drgnx-agent-config--make-private-dirs (file-name-directory (directory-file-name dir)))
    (make-directory dir)
    (set-file-modes dir #o700)))

(defun drgnx-agent-config-write-text (file text check &optional verify expect)
  "Replace the content of FILE with TEXT, safely.
EXPECT, when given, is what the caller saw when it read FILE: its text (a string), or its modification time.
If FILE differs now (or is gone), `drgnx-agent-config-changed' is signalled with FILE and nothing is touched.
CHECK is called with FILE's current text (when FILE exists) and must not signal; otherwise nothing is touched.
When TEXT is what FILE holds already, nothing is written and the backup stays as it was.
VERIFY, when given, is called the same way with TEXT.  Then FILE is copied to FILE.drgnx-bak (the one backup),
TEXT goes to a temp file next to FILE with FILE's modes (0600 for a new file), and the temp file is renamed over
FILE.  A symbolic link is written through.  Parent directories that are missing are made with modes 0700."
  (let* ((given file)
         (file (file-truename (expand-file-name file)))
         (exists (file-exists-p file))
         (current (and exists (drgnx-agent-config-read-text file))))
    (when (and expect
               (not (and exists
                         (if (stringp expect)
                             (equal expect current)
                           (time-equal-p expect (file-attribute-modification-time (file-attributes file)))))))
      (signal 'drgnx-agent-config-changed (list (expand-file-name given))))
    (when exists (funcall check current))
    (unless (and exists (equal text current))
      (when verify (funcall verify text))
      (drgnx-agent-config--make-private-dirs (file-name-directory file))
      (when exists (drgnx-agent-config-save-backup file))
      (let ((tmp (drgnx-agent-config--temp-file file)))
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region text nil tmp nil 'silent))
              (set-file-modes tmp (if exists (file-modes file) #o600))
              (rename-file tmp file t))
          (when (file-exists-p tmp) (delete-file tmp)))))
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
    (drgnx-agent-config-json-read-text file (drgnx-agent-config-read-text file))))

(defun drgnx-agent-config-json-read-text (file text)
  "TEXT, the content of the JSON file FILE, as (:value VALUE :indent N): `drgnx-agent-config-json-read' for a text
already read (so a caller can keep the very text its value comes from).  FILE is for the error data only."
  (let ((value (drgnx-agent-config--json-parse file text))
        (indent (if (string-match "^\\([ \t]+\\)[^ \t\r\n]" text)
                    (let ((lead (match-string 1 text)))
                      (if (eq (aref lead 0) ?\t) 2 (length lead)))
                  2)))
    (list :value value :indent indent)))

(defun drgnx-agent-config--json-type (value)
  "A description of VALUE's type that shows none of its content."
  (cond ((consp value) "a list")
        ((functionp value) "a function")
        ((symbolp value) "a symbol")
        (t (format "a %s" (type-of value)))))

(defun drgnx-agent-config--json-bad (path value &optional expected)
  "Signal that VALUE at PATH (reversed keys) is not JSON, saying its type and where, never the data."
  (error "Not a JSON value at %s (%s%s)" (if path (mapconcat #'identity (reverse path) ".") "the top level")
         (drgnx-agent-config--json-type value) (if expected (concat ", expected " expected) "")))

(defun drgnx-agent-config--json-scalar (value path)
  "VALUE (string, number, t, :null or :false) at PATH as JSON text."
  (unless (or (stringp value) (numberp value) (memq value '(t :null :false)))
    (drgnx-agent-config--json-bad path value))
  (condition-case nil
      (decode-coding-string (substring (json-serialize (vector value)) 1 -1) 'utf-8)
    (error (drgnx-agent-config--json-bad path value))))

(defun drgnx-agent-config--json-encode (value indent level &optional path)
  "VALUE as JSON text, objects and arrays one entry per line, INDENT spaces per LEVEL.
PATH is the keys leading here, innermost first, for error messages."
  (let ((pad (make-string (* indent (1+ level)) ?\s))
        (end (make-string (* indent level) ?\s)))
    (cond
     ((null value) "{}")
     ((vectorp value)
      (if (zerop (length value))
          "[]"
        (concat "[\n"
                (mapconcat (lambda (v) (concat pad (drgnx-agent-config--json-encode v indent (1+ level) path)))
                           value ",\n")
                "\n" end "]")))
     ((and (consp value) (consp (car value)))
      (concat "{\n"
              (mapconcat
               (lambda (pair)
                 (unless (and (consp pair) (or (symbolp (car pair)) (stringp (car pair))))
                   (drgnx-agent-config--json-bad path pair "an object entry"))
                 (let ((key (if (symbolp (car pair)) (symbol-name (car pair)) (car pair))))
                   (concat pad (drgnx-agent-config--json-scalar key path)
                           ": " (drgnx-agent-config--json-encode (cdr pair) indent (1+ level) (cons key path)))))
               value ",\n")
              "\n" end "}"))
     ((consp value) (drgnx-agent-config--json-bad path value "a vector"))
     (t (drgnx-agent-config--json-scalar value path)))))

(defun drgnx-agent-config-json-write (file value indent &optional expect)
  "Write VALUE (as `drgnx-agent-config-json-read' returns it) to FILE, INDENT spaces per level.
Key order as in VALUE, a final newline.  Goes through `drgnx-agent-config-write-text' (EXPECT is passed on): a FILE
that does not parse is not written, and neither is a text that does not parse back.  A VALUE that is not JSON is
an error naming its place and type, never its content."
  (let ((text (concat (drgnx-agent-config--json-encode value indent 0) "\n")))
    (drgnx-agent-config-write-text
     file text
     (lambda (current) (drgnx-agent-config--json-parse file current))
     (lambda (new) (drgnx-agent-config--json-parse file new))
     expect)))

;;;; Parsed JSON, taken apart and changed
;; Shared by the agent files.  Objects are alists with symbol keys, arrays vectors, as `drgnx-agent-config-json-read'
;; returns them; a path into an object is a list of key strings.

(defun drgnx-agent-config-json-keystr (key)
  "KEY (a symbol or string) as a string."
  (if (symbolp key) (symbol-name key) key))

(defun drgnx-agent-config-json-str (x)
  "X when it is a string."
  (and (stringp x) x))

(defun drgnx-agent-config-json-alist-p (x)
  "Non-nil when X is a parsed JSON object that has members."
  (and (consp x) (cl-every #'consp x)))

(defun drgnx-agent-config-json-cell (obj key)
  "The member of the object OBJ called KEY (a string), or nil."
  (and (listp obj)
       (cl-find-if (lambda (c) (and (consp c) (equal (drgnx-agent-config-json-keystr (car c)) key))) obj)))

(defun drgnx-agent-config-json-get (obj &rest keys)
  "The value in OBJ at KEYS (strings), or nil."
  (dolist (k keys obj)
    (setq obj (cdr (drgnx-agent-config-json-cell obj k)))))

(defun drgnx-agent-config-json-set (obj keys value)
  "OBJ with VALUE at KEYS (strings): an existing member keeps its place, a new one goes last."
  (unless (or (null obj) (drgnx-agent-config-json-alist-p obj))
    (error "The file has no object where drgnx has to write"))
  (let* ((key (car keys))
         (cell (drgnx-agent-config-json-cell obj key))
         (new (if (cdr keys) (drgnx-agent-config-json-set (cdr cell) (cdr keys) value) value)))
    (if cell
        (mapcar (lambda (c) (if (eq c cell) (cons (car c) new) c)) obj)
      (append obj (list (cons (intern key) new))))))

(defun drgnx-agent-config-json-del (obj keys)
  "OBJ without the member at KEYS (strings); OBJ itself when it is not there."
  (let ((cell (drgnx-agent-config-json-cell obj (car keys))))
    (cond ((null cell) obj)
          ((cdr keys) (mapcar (lambda (c)
                                (if (eq c cell) (cons (car c) (drgnx-agent-config-json-del (cdr c) (cdr keys))) c))
                              obj))
          (t (remq cell obj)))))

(defun drgnx-agent-config-json-strings (x)
  "The strings of the vector X, as a list (anything else in it as text)."
  (and (vectorp x) (mapcar (lambda (e) (if (stringp e) e (format "%s" e))) x)))

(defun drgnx-agent-config-json-string-alist (obj)
  "The members of the object OBJ as ((\"NAME\" . \"value\")…)."
  (and (drgnx-agent-config-json-alist-p obj)
       (mapcar (lambda (c) (cons (drgnx-agent-config-json-keystr (car c))
                                 (if (stringp (cdr c)) (cdr c) (format "%s" (cdr c)))))
               obj)))

(defun drgnx-agent-config-json-pairs (pairs)
  "The alist PAIRS ((\"NAME\" . \"value\")…) as a JSON object; a value that is not text is an error."
  (mapcar (lambda (p)
            (unless (stringp (cdr p)) (error "A value of an environment variable or header must be text"))
            (cons (intern (drgnx-agent-config-json-keystr (car p))) (cdr p)))
          pairs))

(defun drgnx-agent-config-json-modify (file function)
  "Replace the JSON object in FILE with (FUNCTION VALUE), VALUE being what FILE holds now.
FILE is read again just before each attempt and the write is refused when it changed since: an agent rewrites its
files often, so a refused write is tried once more with the new content.  A second refusal signals
`drgnx-agent-config-changed'.  Returns FILE."
  (let ((attempt 0) done)
    (while (not done)
      (setq attempt (1+ attempt))
      ;; one read: the value and the text EXPECT is checked against are the same version of the file
      (let* ((text (and (file-exists-p file) (drgnx-agent-config-read-text file)))
             (read (if text (drgnx-agent-config-json-read-text file text) (list :value nil :indent 2)))
             (value (plist-get read :value)))
        (unless (or (null value) (drgnx-agent-config-json-alist-p value))
          (error "The file does not hold a JSON object"))
        (condition-case nil
            (progn (drgnx-agent-config-json-write file (funcall function value) (plist-get read :indent) text)
                   (setq done t))
          (drgnx-agent-config-changed
           (when (>= attempt 2) (signal 'drgnx-agent-config-changed (list file)))))))
    file))

(defun drgnx-agent-config-hook-matcher= (group matcher)
  "Non-nil when the JSON hook GROUP has the matcher MATCHER (nil and \"\" are the same)."
  (equal (or (drgnx-agent-config-json-str (drgnx-agent-config-json-get group "matcher")) "")
         (or matcher "")))

(defun drgnx-agent-config-error-text (err item)
  "The message for the error ERR of a write of ITEM: where and why, never the item's data."
  (pcase (car err)
    ('drgnx-agent-config-unreadable
     (let ((data (cdr err)))
       (format "%s does not parse (line %s: %s); nothing was written" (nth 0 data) (or (nth 1 data) "?") (nth 2 data))))
    ('drgnx-agent-config-changed
     (format "%s was changed by another program while it was being written; nothing was written, try again" (cadr err)))
    (_ (drgnx-agent-config-mask-text (error-message-string err)
                                     (ignore-errors (drgnx-agent-config-secrets (plist-get item :spec)))))))

;;;; Secrets

(defconst drgnx-agent-config--secret-key-re "token\\|secret\\|key\\|password\\|authorization"
  "Keys whose values are secrets.")

(defconst drgnx-agent-config--secret-name-re
  "[A-Za-z0-9_.-]*\\(?:token\\|secret\\|key\\|password\\|passwd\\|authorization\\)[A-Za-z0-9_.-]*"
  "A flag, variable or query parameter name that suggests a secret.")

(defconst drgnx-agent-config--text-patterns
  `(;; NAME=VALUE, --flag=VALUE and ?param=VALUE with a secret-ish name
    (,(concat "\\(?:\\`\\|[ \t;&|?\"']\\)" drgnx-agent-config--secret-name-re
              "=\\(\"[^\"]+\"\\|'[^']+'\\|[^ \t;&|\"'#]+\\)")
     1 t)
    ;; Bearer TOKEN, Basic TOKEN, Token TOKEN
    ("\\<\\(?:Bearer\\|Basic\\|Token\\)[ \t]+\\([^ \t\"']\\{4,\\}\\)" 1 t)
    ;; Authorization: VALUE
    ("Authorization:[ \t]*\\([^\"'\n]+?\\)[ \t]*\\(?:[\"'\n]\\|\\'\\)" 1 t)
    ;; user:PASSWORD@host
    ("://[^/:@ \t\"']*:\\([^/@ \t\"']+\\)@" 1 t)
    ;; a secret-ish query parameter
    ("[?&]\\(?:key\\|api[_-]?key\\|token\\|access[_-]?token\\|secret\\|password\\|sig\\|signature\\|auth\\)=\\([^& \t\"'#]+\\)"
     1 t)
    ;; well-known token shapes (case matters)
    ("\\<sk-[A-Za-z0-9_-]\\{16,\\}" 0 nil)
    ("\\<gh[pousr]_[A-Za-z0-9]\\{20,\\}" 0 nil)
    ("\\<github_pat_[A-Za-z0-9_]\\{10,\\}" 0 nil)
    ("\\<xox[abprs]-[A-Za-z0-9-]\\{4,\\}" 0 nil)
    ("\\<AKIA[0-9A-Z]\\{16\\}" 0 nil)
    ("\\<AIza[A-Za-z0-9_-]\\{30,\\}" 0 nil)
    ("\\<eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+" 0 nil))
  "The secret parts inside a free string (an argument, a URL, a command): (REGEXP GROUP FOLD-CASE).")

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

(defun drgnx-agent-config--unquote-shell (value)
  "VALUE without a pair of quotes around it."
  (if (string-match "\\`\\([\"']\\)\\(.*\\)\\1\\'" value) (match-string 2 value) value))

(defun drgnx-agent-config--text-secrets (text)
  "The secret parts of the free string TEXT (an argument, a command, a URL): only the secret, not its context."
  (let (out)
    (dolist (spec drgnx-agent-config--text-patterns)
      (let ((case-fold-search (nth 2 spec)) (pos 0))
        (while (string-match (car spec) text pos)
          (push (drgnx-agent-config--unquote-shell (match-string (nth 1 spec) text)) out)
          (setq pos (max (match-end 0) (1+ pos))))))
    (nreverse out)))

(defun drgnx-agent-config--header-secret (header)
  "The secret part of an HTTP HEADER given as \"Name: value\" (nil when it is not secret-looking)."
  (let ((case-fold-search t))
    (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.+?\\)[ \t]*\\'" header)
      (let ((name (match-string 1 header)) (value (match-string 2 header)))
        (when (or (string-match-p drgnx-agent-config--secret-key-re name)
                  (string-match-p "\\`\\(?:Bearer\\|Basic\\|Token\\)[ \t]" value))
          value)))))

(defun drgnx-agent-config--args-secrets (args)
  "The secrets in the argument list ARGS (a list or vector of strings): the argument after a secret-ish flag,
after -H / --header (the secret part of the header) and after -e / --env (the value)."
  (let ((rest (append args nil)) out)
    (while rest
      (let ((arg (pop rest)) (next (car rest)))
        (when (and (stringp arg) (stringp next))
          (cond
           ((or (string= arg "-H") (string-match-p "\\`--header\\'" arg))
            (when-let* ((s (drgnx-agent-config--header-secret next))) (push s out)))
           ((or (string= arg "-e") (string-match-p "\\`--env\\'" arg))
            (when (string-match "=\\(.+\\)\\'" next) (push (match-string 1 next) out)))
           ((or (string= arg "-p")
                (let ((case-fold-search t))
                  (string-match-p "\\`--?[A-Za-z-]*\\(?:token\\|secret\\|key\\|password\\|passwd\\|pass\\|auth\\)[A-Za-z-]*\\'"
                                  arg)))
            (push next out))))))
    out))

(defun drgnx-agent-config--url-secrets (url)
  "The secrets in URL beyond what `drgnx-agent-config--text-secrets' finds: long path segments."
  (when (string-match "\\`[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*\\(/[^?#]*\\)" url)
    (cl-remove-if-not (lambda (seg) (string-match-p "\\`[A-Za-z0-9_-]\\{24,\\}\\'" seg))
                      (split-string (match-string 1 url) "/" t))))

(defun drgnx-agent-config-secrets (spec)
  "The secret strings in SPEC (an item's :spec), each longer than 3 characters:
- every :env and :headers value, and the value of any key matching token, secret, key, password or authorization
  (case-insensitive); of such a key holding a list or object, every string in it;
- in :args and in every other string (a hook's :command, a :url): the secret part of NAME=VALUE with a secret-ish
  name, of Bearer / Basic / Token and Authorization: values, of URL userinfo and secret-ish query parameters, of
  well-known token shapes, the argument after a secret-ish flag, -H / --header, -e / --env, and :url path segments of
  24 or more letters, digits, `_' and `-'.
A value like \"Bearer abc\" also gives the bare \"abc\"."
  (let ((case-fold-search t) out)
    (cl-labels ((add (v)
                  (when (and (stringp v) (> (length v) 3))
                    (cl-pushnew v out :test #'equal)
                    (when (and (string-match "\\`\\(?:Bearer\\|Basic\\|Token\\)[ \t]+\\(.+\\)\\'" v)
                               (> (length (match-string 1 v)) 3))
                      (cl-pushnew (match-string 1 v) out :test #'equal))))
                (all (x)
                  (cond ((stringp x) (add x))
                        ((vectorp x) (mapc #'all x))
                        ((drgnx-agent-config--pairs x) (dolist (p (drgnx-agent-config--pairs x)) (all (cdr p))))
                        ((consp x) (mapc #'all x))))
                (walk (x)
                  (cond
                   ((stringp x) (mapc #'add (drgnx-agent-config--text-secrets x)))
                   ((drgnx-agent-config--pairs x)
                    (dolist (pair (drgnx-agent-config--pairs x))
                      (let ((name (downcase (or (drgnx-agent-config--key-name (car pair)) ""))))
                        (cond ((member name '("env" "headers")) (all (cdr pair)))
                              ((string-match-p drgnx-agent-config--secret-key-re name) (all (cdr pair)))
                              (t (when (string= name "args") (mapc #'add (drgnx-agent-config--args-secrets (cdr pair))))
                                 (when (and (string= name "url") (stringp (cdr pair)))
                                   (mapc #'add (drgnx-agent-config--url-secrets (cdr pair))))
                                 (walk (cdr pair)))))))
                   ((vectorp x) (mapc #'walk x))
                   ((consp x) (mapc #'walk x)))))
      (walk spec))
    (nreverse out)))

(defun drgnx-agent-config-mask-text (text secrets)
  "TEXT with every string of SECRETS replaced by `drgnx-agent-config-mask'.
Matches that overlap (\"abcdef\" and \"defghi\" in \"abcdefghi\") are one range, replaced once, so no end of either
stays."
  (when text
    (let ((ranges nil) (out nil) (pos 0))
      (dolist (s secrets)
        (when (and (stringp s) (not (string-empty-p s)))
          (let ((from 0) (hit nil))
            (while (setq hit (string-search s text from))
              (push (cons hit (+ hit (length s))) ranges)
              (setq from (1+ hit))))))
      (if (null ranges)
          text
        (setq ranges (sort ranges (lambda (a b) (< (car a) (car b)))))
        (let ((beg (caar ranges)) (end (cdar ranges)))
          (dolist (r (cdr ranges))
            (if (< (car r) end)
                (setq end (max end (cdr r)))
              (push (substring text pos beg) out)
              (push drgnx-agent-config-mask out)
              (setq pos end beg (car r) end (cdr r))))
          (push (substring text pos beg) out)
          (push drgnx-agent-config-mask out)
          (push (substring text end) out))
        (apply #'concat (nreverse out))))))

;;;; Status without running anything

(defun drgnx-agent-config--command-found-p (command &optional base)
  "Non-nil when COMMAND is an executable file (a relative one is BASE's, else the home directory's), or is found on
`exec-path'."
  (if (string-search "/" command)
      (file-executable-p (expand-file-name command (or base "~/")))
    (and (executable-find command) t)))

(defun drgnx-agent-config-cheap-status (item &optional root)
  "(STATUS . DETAIL) of ITEM, from files and PATH only; nothing is run.
STATUS is ok, missing-command (a stdio MCP server whose command is not found), no-url (an http or sse MCP server
without one) or unreadable (the item has a :problem, or an MCP server has no usable spec).  A relative command is
the server's working directory's (its `:cwd', relative to ROOT), else the project ROOT's, else the home directory's
— never the current buffer's directory."
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
           (if (not (and (stringp command) (not (string-empty-p command))))
               (cons 'missing-command "no command")
             (cons (if (drgnx-agent-config--command-found-p
                        command (let ((cwd (plist-get spec :cwd)) (base (or root "~/")))
                                  (if (and (stringp cwd) (not (string-empty-p cwd))) (expand-file-name cwd base) base)))
                       'ok 'missing-command)
                   (drgnx-agent-config-mask-text command (drgnx-agent-config-secrets (list :command command))))))
          ((or 'http 'sse)
           (if (and (stringp url) (not (string-empty-p url)))
               (cons 'ok (drgnx-agent-config-mask-text url (drgnx-agent-config-secrets (list :url url))))
             (cons 'no-url "no url")))
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
