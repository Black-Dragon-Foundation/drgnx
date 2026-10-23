;;; drgnx-deny.el --- The personal-notes deny-list, Lisp side: what the work scan and the code indexer never read -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A security check, the same rules as norn's `deny.rs' (storage design §5.6; Urdr Tasks 9 and 16), held to them by one
;; table (test/fixtures/deny-cases.json):
;; - everything under ~/org except ~/org/board.org is denied, after links, `..' and `//' are resolved; a path is also
;;   denied by the name it was given by (a link in ~/org to a file elsewhere);
;; - a hard tier no opt-in lifts: ~/org/notes.org, any file under ~/org whose name (case folded) starts with
;;   `drgnx-deny-hard-patterns', or under a folder so named, and the user's own entries in personal-notes-deny.json;
;; - a soft tier (the rest of ~/org) the user's per-file opt-ins lift (personal-notes-allow.json), unless the check is
;;   HARD-ONLY (the code indexer: opt-ins do not reach the Lisp code store).
;; Fail closed: an opt-in file that is unreadable, malformed, too large or writable by group or others opens nothing; a
;; deny file with a problem leaves the built-in list and drops every opt-in.  A relative path is denied.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-deny-hard-patterns '("notes" "journal" "diary" "personal")
  "Under ~/org at any depth, a file whose name (case folded) starts with one of these, or a file under a folder so
named, is never opened by an opt-in (call 19).")

(defconst drgnx-deny-allow-file "personal-notes-allow.json"
  "The user's per-file opt-ins, in the config directory: {\"version\": 1, \"paths\": [...]}, mode 0600.")

(defconst drgnx-deny-deny-file "personal-notes-deny.json"
  "The user's own hard entries: {\"version\": 1, \"entries\": [{\"kind\": \"file\"|\"folder\"|\"glob\", \"path\": \"...\"}]}.")

(defconst drgnx-deny--max-file (* 1024 1024) "A config file larger than this is refused unread.")

(defvar drgnx-deny--cache nil "(STAMP . RULES) of the last rules read.")

;;;; Paths

(defun drgnx-deny--collapse (path) (replace-regexp-in-string "//+" "/" path))

(defun drgnx-deny--fold (path)
  "PATH as compared: macOS volumes fold case by default, Linux compares bytes."
  (if (eq system-type 'darwin) (downcase path) path))

(defun drgnx-deny--lexical (path)
  "PATH with `.', `..' and doubled slashes removed by text alone (the name a path was given by)."
  (directory-file-name (expand-file-name (drgnx-deny--collapse path) "/")))

(defun drgnx-deny--resolve (path)
  "PATH with every link resolved (a path not made yet keeps its tail), or nil when that fails (a link loop)."
  (condition-case nil
      (directory-file-name (file-truename (expand-file-name (drgnx-deny--collapse path) "/")))
    (error nil)))

(defun drgnx-deny--home () (directory-file-name (expand-file-name "~")))

(defun drgnx-deny--expand (raw)
  "RAW with a leading ~ read as HOME, else as written."
  (cond ((equal raw "~") (drgnx-deny--home))
        ((string-prefix-p "~/" raw) (concat (drgnx-deny--home) "/" (string-trim-left (substring raw 2) "/+")))
        (t raw)))

(defun drgnx-deny--wildcard-regexp (pattern)
  "The regexp of PATTERN, where * is any run of characters and ? one character."
  (concat "\\`" (mapconcat (lambda (c) (pcase c (?* ".*") (?? ".") (_ (regexp-quote (string c))))) pattern "") "\\'"))

;;;; The config files

(defun drgnx-deny--read-json (file)
  "FILE's JSON: (:json J :loose L) (L: writable by group or others), :missing, or (:bad WHY)."
  (let ((attrs (file-attributes file)))
    (cond ((null attrs) :missing)
          ((not (file-regular-p file)) (list :bad "not a regular file"))
          ((> (file-attribute-size attrs) drgnx-deny--max-file) (list :bad "larger than 1 MiB"))
          (t (condition-case err
                 (list :json (with-temp-buffer
                               (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                               (json-parse-buffer :object-type 'alist :array-type 'list :null-object nil :false-object nil))
                       :loose (/= 0 (logand (file-modes file) #o022)))
               (error (list :bad (format "not JSON (%s)" (error-message-string err)))))))))

(defun drgnx-deny--versioned (json key)
  "JSON's KEY list when JSON is {\"version\": 1, KEY: [...]}, else `none'."
  (if (and (consp json) (eql (alist-get 'version json) 1) (listp (alist-get key json)) (alist-get key json))
      (alist-get key json)
    (if (and (consp json) (eql (alist-get 'version json) 1) (assq key json)) nil 'none)))

(defun drgnx-deny--user-entry (value)
  "(KIND . PATH) of one entry of the deny file, PATH folded; nil when the entry is ignored."
  (when-let* (((consp value))
              (kind (alist-get 'kind value)) (raw (alist-get 'path value))
              ((member kind '("file" "folder" "glob"))) ((stringp raw))
              (path (drgnx-deny--expand raw)) ((string-prefix-p "/" path)))
    (if (equal kind "glob")
        (unless (or (string-match-p "[][{}]" raw) (string-match-p "[*?]" (file-name-directory path)))
          (when-let* ((dir (drgnx-deny--resolve (file-name-directory path))))
            (cons 'glob (drgnx-deny--fold (concat dir "/" (file-name-nondirectory path))))))
      (unless (string-match-p "[*?]" raw)
        (cons 'path (drgnx-deny--fold (or (drgnx-deny--resolve path) (drgnx-deny--lexical path))))))))

(defun drgnx-deny--tier-in (p rules)
  "nil (allowed), `board', `opted-in', `hard' or `soft' for the folded absolute path P against RULES."
  (let ((org (plist-get rules :org)))
    (cond
     ((seq-some (lambda (e)
                  (if (eq (car e) 'glob)
                      (let* ((dir (file-name-directory (cdr e)))
                             (first (and (string-prefix-p dir p) (car (split-string (substring p (length dir)) "/" t)))))
                        (and first (string-match-p (drgnx-deny--wildcard-regexp (file-name-nondirectory (cdr e))) first)))
                    (or (equal p (cdr e)) (string-prefix-p (concat (cdr e) "/") p))))
                (plist-get rules :user))
      'hard)
     ((not (or (equal p org) (string-prefix-p (concat org "/") p))) nil)
     ((equal p (plist-get rules :board)) 'board)
     ((or (equal p (plist-get rules :notes))
          (and (not (equal p org))
               (seq-some (lambda (part) (seq-some (lambda (pat) (string-prefix-p pat (downcase part))) drgnx-deny-hard-patterns))
                         (split-string (substring p (1+ (length org))) "/" t))))
      'hard)
     ((member p (plist-get rules :opt-ins)) 'opted-in)
     (t 'soft))))

(defun drgnx-deny--rules ()
  "The rules now: (:org :board :notes :user :opt-ins), read again when either config file or HOME changed."
  (let* ((config (drgnx-paths-dir 'config))
         (deny (expand-file-name drgnx-deny-deny-file config)) (allow (expand-file-name drgnx-deny-allow-file config))
         (stamp (list (drgnx-deny--home) (file-attributes deny) (file-attributes allow))))
    (if (equal (car drgnx-deny--cache) stamp)
        (cdr drgnx-deny--cache)
      (let* ((literal (concat (drgnx-deny--home) "/org"))
             (org (drgnx-deny--fold (or (drgnx-deny--resolve literal) literal)))
             (rules (list :org org :board (concat org "/board.org") :notes (concat org "/notes.org") :user nil :opt-ins nil))
             (trouble nil)
             (d (drgnx-deny--read-json deny)))
        (cond
         ((eq d :missing))
         ((eq (car d) :bad) (setq trouble t))
         (t (when (plist-get d :loose) (setq trouble t))
            (let ((entries (drgnx-deny--versioned (plist-get d :json) 'entries)))
              (if (eq entries 'none)
                  (setq trouble t)
                (dolist (v entries)
                  (if-let* ((e (drgnx-deny--user-entry v)))
                      (cl-pushnew e (plist-get rules :user) :test #'equal)
                    (setq trouble t)))
                (setq rules (plist-put rules :user (nreverse (plist-get rules :user))))))))
        (unless trouble
          (let ((a (drgnx-deny--read-json allow)))
            (when (and (consp a) (eq (car a) :json) (not (plist-get a :loose)))
              (let ((paths (drgnx-deny--versioned (plist-get a :json) 'paths)))
                (unless (eq paths 'none)
                  (dolist (raw paths)
                    (when-let* (((stringp raw)) ((not (string-match-p "[*?[]" raw)))
                                (path (drgnx-deny--expand raw)) ((string-prefix-p "/" path))
                                (real (drgnx-deny--resolve path)) ((file-regular-p real))
                                (p (drgnx-deny--fold real))
                                ((not (memq (drgnx-deny--tier-in p rules) '(nil board)))))
                      (cl-pushnew p (plist-get rules :opt-ins) :test #'equal))))))))
        (setq drgnx-deny--cache (cons stamp rules))
        rules))))

;;;; The check

(defun drgnx-deny--rank (tier) (pcase tier ('hard 2) ('soft 1) (_ 0)))

(defun drgnx-deny-classify (file)
  "FILE's verdict: nil (allowed), `board' (exactly ~/org/board.org), `opted-in' (a soft-tier file the user opted in),
`hard' or `soft' (denied).  The path is resolved first (`..', `//', links) and also read by the name it was given by;
the stricter wins.  A relative path (or `~/…') is `hard'."
  (if (not (and (stringp file) (string-prefix-p "/" file)))
      'hard
    (let ((rules (drgnx-deny--rules)) (real (drgnx-deny--resolve file)))
      (if (null real)
          'hard
        (let ((resolved (drgnx-deny--tier-in (drgnx-deny--fold real) rules))
              (named (drgnx-deny--tier-in (drgnx-deny--fold (drgnx-deny--lexical file)) rules)))
          (if (> (drgnx-deny--rank named) (drgnx-deny--rank resolved)) named resolved))))))

(defun drgnx-deny-path-p (file &optional hard-only)
  "Non-nil (the tier, `hard' or `soft') when FILE is personal notes: never read, indexed or sent.  The board is not,
and a soft-tier file the user opted in is not either — unless HARD-ONLY, which ignores the opt-ins (the code
indexer: they do not reach the Lisp code store)."
  (pcase (drgnx-deny-classify file)
    ((and (or 'hard 'soft) tier) tier)
    ('opted-in (and hard-only 'soft))
    (_ nil)))

(provide 'drgnx-deny)
;;; drgnx-deny.el ends here
