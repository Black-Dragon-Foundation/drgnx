;;; drgnx-store-privacy.el --- Personal files opened to the store one by one, and paths kept out for good -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Everything under ~/org except board.org stays out of drgnx's store (Ratatoskr's deny-list, norn::deny).  These
;; commands are how the user changes that, one path at a time (docs/guide/security.md, "Personal notes"):
;; - `drgnx-store-allow-personal-file' opens one file under ~/org (personal-notes-allow.json); a file of the hard tier
;;   (notes.org, names starting notes/journal/diary/personal, the user's own deny entries) is refused at once;
;; - `drgnx-store-revoke-personal-file' closes it again: the hub excises what came in from it;
;; - `drgnx-store-deny-personal-path' keeps a file, folder or glob out for good (personal-notes-deny.json): what came
;;   in from it is excised; `drgnx-store-undeny-personal-path' takes one of the user's own entries back (the built-in
;;   list cannot be shortened).
;; Each confirms with the path, writes its file atomically (0600, in the config dir), then asks the hub to apply it
;; now (`graph/privacy', waiting a few seconds) and shows what it did.  No command reads a personal file's content.
;; Interactive only: nothing here runs from a timer, hook or the daemon.  The hub also applies any other change of
;; either file at its next tick, and says so to every editor.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)

(declare-function drgnx-hub-call-sync "drgnx-hub-client" (method params &optional timeout))

(defconst drgnx-store-privacy-allow-file "personal-notes-allow.json"
  "The opt-in file in the config dir: {\"version\": 1, \"paths\": [...]}.")

(defconst drgnx-store-privacy-deny-file "personal-notes-deny.json"
  "The user's own deny entries in the config dir: {\"version\": 1, \"entries\": [{\"kind\", \"path\"}...]}.")

(defconst drgnx-store-privacy--hard-names '("notes" "journal" "diary" "personal")
  "The built-in hard tier under ~/org: a file or folder whose name (any case) starts with one of these.
The same list as norn::deny's HARD_PATTERNS; the hub's check is the one that counts.")

(defconst drgnx-store-privacy--max-bytes (* 1024 1024)
  "Either file larger than this is refused (the hub's limit too).")

(defvar drgnx-store-privacy-timeout 30
  "Seconds a command waits for the hub to apply a change (an excise and a scrub can take a while).")

;;;; The files

(defun drgnx-store-privacy--file (name)
  "Config file NAME's absolute path."
  (expand-file-name name (drgnx-user-dir)))

(defun drgnx-store-privacy--read (name key)
  "The list under KEY in config file NAME (nil when the file is missing).
A file that cannot be read, or is not {\"version\": 1, KEY: [...]}, is a `user-error': it is never overwritten."
  (let* ((file (drgnx-store-privacy--file name))
         (text (condition-case err (drgnx-file-read-bounded file :max-bytes drgnx-store-privacy--max-bytes)
                 (drgnx-file-refused (user-error "%s: %s; fix it or remove it first" (abbreviate-file-name file)
                                                 (car (last err))))))
         (json (and text (condition-case nil
                             (json-parse-string text :object-type 'alist :array-type 'list
                                                :null-object nil :false-object nil)
                           (json-error :bad)))))
    (cond ((null text) nil)
          ((and (consp json) (equal (alist-get 'version json) 1) (listp (alist-get key json)))
           (alist-get key json))
          (t (user-error "%s is not {\"version\": 1, \"%s\": [...]}; fix it or remove it first"
                         (abbreviate-file-name file) key)))))

(defun drgnx-store-privacy--write (name key items)
  "Write config file NAME as {\"version\": 1, KEY: ITEMS}, atomically (a temp file renamed over it), mode 0600."
  (drgnx-file-write-text (drgnx-store-privacy--file name)
                         (concat (json-serialize `((version . 1) (,key . ,(vconcat items)))) "\n")
                         :private t))

;;;; Paths

(defun drgnx-store-privacy--fold (path)
  "PATH as compared: case folded on macOS, whose volumes fold case (as the hub compares)."
  (if (eq system-type 'darwin) (downcase path) path))

(defun drgnx-store-privacy--expand (path)
  "PATH expanded from \"/\", \"~\" the local home, with no file name handler (a remote buffer changes nothing)."
  (let ((default-directory "/") (file-name-handler-alist nil))
    (expand-file-name path)))

(defun drgnx-store-privacy--true (path)
  "PATH expanded (\"~\" is the local home) with its links resolved, no file name handler; PATH expanded when that fails."
  (let ((name (drgnx-store-privacy--expand path)))
    (or (drgnx-file-truename name "/") name)))

(defun drgnx-store-privacy--org ()
  "~/org, resolved."
  (drgnx-store-privacy--true "~/org"))

(defun drgnx-store-privacy--inside-p (path dir)
  "Whether PATH is DIR or under it (both resolved)."
  (let ((p (drgnx-store-privacy--fold (directory-file-name path)))
        (d (drgnx-store-privacy--fold (directory-file-name dir))))
    (or (equal p d) (string-prefix-p (file-name-as-directory d) p))))

(defun drgnx-store-privacy--entries ()
  "The user's own deny entries: a list of (KIND . PATH), PATH as written."
  (delq nil (mapcar (lambda (e) (let ((kind (alist-get 'kind e)) (path (alist-get 'path e)))
                                  (and (stringp kind) (stringp path) (cons kind path))))
                    (drgnx-store-privacy--read drgnx-store-privacy-deny-file 'entries))))

(defun drgnx-store-privacy--entry-covers-p (entry path)
  "Whether the user's ENTRY (KIND . PATH) keeps the resolved PATH out."
  (pcase-let ((`(,kind . ,where) entry))
    (if (equal kind "glob")
        (let* ((dir (drgnx-store-privacy--true (file-name-directory (drgnx-store-privacy--expand where))))
               (pattern (file-name-nondirectory where))
               (rel (and (drgnx-store-privacy--inside-p path dir)
                         (not (equal (directory-file-name path) (directory-file-name dir)))
                         (car (split-string (file-relative-name path dir) "/" t)))))
          (and rel (let ((case-fold-search (eq system-type 'darwin)))
                     (string-match-p (wildcard-to-regexp pattern) rel))
               t))
      (drgnx-store-privacy--inside-p path (drgnx-store-privacy--true where)))))

(defun drgnx-store-privacy--built-in-p (path org)
  "Whether the resolved PATH is in the built-in hard tier under ORG: notes.org, or a part named as
`drgnx-store-privacy--hard-names' says."
  (and (drgnx-store-privacy--inside-p path org)
       (not (equal (directory-file-name path) (directory-file-name org)))
       (cl-some (lambda (part) (cl-some (lambda (name) (string-prefix-p name (downcase part)))
                                        drgnx-store-privacy--hard-names))
                (split-string (file-relative-name path org) "/" t))))

(defun drgnx-store-privacy--hard-p (path org)
  "Whether the resolved PATH is always kept out: the built-in hard tier or one of the user's own entries."
  (or (drgnx-store-privacy--built-in-p path org)
      (cl-some (lambda (e) (drgnx-store-privacy--entry-covers-p e path)) (drgnx-store-privacy--entries))))

;;;; The hub

(defun drgnx-store-privacy--reload (&optional more)
  "Ask the hub to apply both files now, with the params MORE too (`:delete_copies'): its answer (a plist), or nil when
it did not answer (it applies the files at its next tick or start)."
  (unless (fboundp 'drgnx-hub-call-sync) (require 'drgnx-hub-client))
  (condition-case err
      (drgnx-hub-call-sync "graph/privacy" (append (list :reload t) more) drgnx-store-privacy-timeout)
    (error (message "drgnx: saved; the hub did not apply it now (%s): it does when it next runs"
                    (error-message-string err))
           nil)))

(defun drgnx-store-privacy--report (what answer)
  "Say WHAT was done, with what the hub's ANSWER says it did."
  (let ((excised (or (plist-get answer :excised) 0))
        (ignored (length (plist-get answer :ignored)))
        (exports (append (plist-get answer :exports_holding) nil)))
    (message "drgnx: %s%s%s%s" what
             (if (> excised 0) (format "; %d entr%s excised from the store" excised (if (= excised 1) "y" "ies")) "")
             (if (> ignored 0) (format "; %d entr%s of your files ignored (`drgnx doctor' says why)" ignored
                                       (if (= ignored 1) "y" "ies"))
               "")
             (if exports (format "; your exports still hold its text (yours to delete): %s" (string-join exports ", "))
               ""))))

(defun drgnx-store-privacy--offer-delete (answer)
  "When the hub's ANSWER lists backups that still hold what was excised, ask once and have the hub delete them.
They cannot be found again later (what they hold is gone from the store), so a no keeps them, said with their names."
  (when-let* ((held (append (plist-get answer :backups_holding) nil)))
    (if (yes-or-no-p (format "Delete these %d cop%s? They still hold the revoked file's text: %s "
                             (length held) (if (= (length held) 1) "y" "ies") (string-join held ", ")))
        (let ((gone (append (plist-get (drgnx-store-privacy--reload (list :delete_copies (vconcat held)))
                                       :backups_removed)
                            nil)))
          (message "drgnx: %d of %d cop%s deleted%s" (length gone) (length held) (if (= (length held) 1) "y" "ies")
                   (let ((left (seq-difference held gone)))
                     (if left (format "; still there (delete them yourself): %s" (string-join left ", ")) ""))))
      (message "drgnx: kept, and they still hold its text; delete them yourself to remove it there too: %s"
               (string-join held ", ")))))

;;;; Opening one file

(defun drgnx-store-privacy--allowable (file)
  "FILE resolved, when it may be opened to the store; else a `user-error' saying why.  Its content is never read."
  (let ((org (drgnx-store-privacy--org))
        (true (drgnx-store-privacy--true file)))
    (cond ((not (file-exists-p true)) (user-error "%s: no such file" (abbreviate-file-name file)))
          ((file-directory-p true) (user-error "%s is a folder: name one file" (abbreviate-file-name true)))
          ((not (file-regular-p true)) (user-error "%s is not a regular file" (abbreviate-file-name true)))
          ((not (drgnx-store-privacy--inside-p true org))
           (user-error "%s is outside ~/org: it is not kept out, so there is nothing to open" (abbreviate-file-name true)))
          ((equal (drgnx-store-privacy--fold true) (drgnx-store-privacy--fold (expand-file-name "board.org" org)))
           (user-error "%s is your board: the tracker always reads it" (abbreviate-file-name true)))
          ((drgnx-store-privacy--hard-p true org)
           (user-error "%s is always kept out (personal notes); an opt-in cannot open it" (abbreviate-file-name true)))
          (t true))))

;;;###autoload
(defun drgnx-store-allow-personal-file (file)
  "Open FILE, one file under ~/org, to drgnx's store: the tracker may read it (a plan's spec, a reading list).
Agents in your projects may then read what the tracker parses from it.  Never a file that is always kept out."
  (interactive (list (read-file-name "Open a personal file to the store: " "~/org/" nil t)))
  (let* ((true (drgnx-store-privacy--allowable file))
         (paths (drgnx-store-privacy--read drgnx-store-privacy-allow-file 'paths))
         (shown (abbreviate-file-name true)))
    (when (member true (mapcar (lambda (p) (and (stringp p) (drgnx-store-privacy--true p))) paths))
      (user-error "%s is already open to the store" shown))
    (unless (yes-or-no-p (format "Open %s to the store? Agents in your projects may read what the tracker parses from it "
                                 shown))
      (user-error "Nothing changed"))
    (drgnx-store-privacy--write drgnx-store-privacy-allow-file 'paths (append paths (list true)))
    (drgnx-store-privacy--report (format "%s is open to the store; the next scan reads it" shown)
                                 (drgnx-store-privacy--reload))))

(defun drgnx-store-privacy--opened ()
  "The opt-in file's entries that are strings."
  (seq-filter #'stringp (drgnx-store-privacy--read drgnx-store-privacy-allow-file 'paths)))

;;;###autoload
(defun drgnx-store-revoke-personal-file (file)
  "Close FILE to drgnx's store again: what came in from it is excised (every version, the search index).  The backups
that still hold it are deleted when you say so; your exports are listed."
  (interactive
   (let ((paths (drgnx-store-privacy--opened)))
     (unless paths (user-error "No personal file is open to the store"))
     (list (completing-read "Close which personal file to the store? " (mapcar #'abbreviate-file-name paths) nil t))))
  (let* ((paths (drgnx-store-privacy--read drgnx-store-privacy-allow-file 'paths))
         (true (drgnx-store-privacy--true file))
         (keep (seq-remove (lambda (p) (or (not (stringp p)) (equal (drgnx-store-privacy--true p) true))) paths))
         (shown (abbreviate-file-name true)))
    (when (= (length keep) (length (seq-filter #'stringp paths)))
      (user-error "%s is not open to the store" shown))
    (unless (yes-or-no-p (format "Close %s to the store? What came in from it is excised for good " shown))
      (user-error "Nothing changed"))
    (drgnx-store-privacy--write drgnx-store-privacy-allow-file 'paths keep)
    (let ((answer (drgnx-store-privacy--reload)))
      (drgnx-store-privacy--report (format "%s is closed to the store" shown) answer)
      (drgnx-store-privacy--offer-delete answer))))

;;;; Keeping a path out for good

(defun drgnx-store-privacy--entry-for (path)
  "The deny entry (an alist) for PATH: a glob when its last part has * or ?, a folder, else a file; resolved."
  (let* ((expanded (drgnx-store-privacy--expand path))
         (name (file-name-nondirectory (directory-file-name expanded))))
    (cond ((string-match-p "[*?]" (file-name-directory expanded))
           (user-error "%s: wildcards go in the last part only" path))
          ((string-match-p "[][{}]" name) (user-error "%s: only * and ? are wildcards" path))
          ((string-match-p "[*?]" name)
           `((kind . "glob") (path . ,(concat (file-name-as-directory
                                               (drgnx-store-privacy--true (file-name-directory expanded)))
                                              name))))
          ((file-directory-p expanded) `((kind . "folder") (path . ,(drgnx-store-privacy--true expanded))))
          (t `((kind . "file") (path . ,(drgnx-store-privacy--true expanded)))))))

;;;###autoload
(defun drgnx-store-deny-personal-path (path)
  "Keep PATH, a file, a folder or a glob (* and ? in its last part), out of drgnx's store for good, as firmly as
~/org/notes.org: what came in from it is excised, and no opt-in opens it."
  (interactive (list (read-file-name "Keep out of the store for good (a file, folder or glob): " "~/org/")))
  (let* ((entry (drgnx-store-privacy--entry-for path))
         (entries (drgnx-store-privacy--read drgnx-store-privacy-deny-file 'entries))
         (shown (abbreviate-file-name (alist-get 'path entry))))
    (when (cl-some (lambda (e) (and (equal (alist-get 'kind e) (alist-get 'kind entry))
                                    (stringp (alist-get 'path e))
                                    (equal (drgnx-store-privacy--true (alist-get 'path e)) (alist-get 'path entry))))
                   entries)
      (user-error "%s is already kept out" shown))
    (unless (yes-or-no-p (format "Keep %s (%s) out of the store for good? What came in from it is excised "
                                 shown (alist-get 'kind entry)))
      (user-error "Nothing changed"))
    (drgnx-store-privacy--write drgnx-store-privacy-deny-file 'entries (append entries (list entry)))
    (let ((answer (drgnx-store-privacy--reload)))
      (drgnx-store-privacy--report (format "%s is kept out of the store" shown) answer)
      (drgnx-store-privacy--offer-delete answer))))

;;;###autoload
(defun drgnx-store-undeny-personal-path (path)
  "Take PATH, one of your own entries in the deny list, back out of it.  Nothing stored changes; a later scan may read
it.  The built-in list (~/org/notes.org and the like) cannot be shortened."
  (interactive
   (let ((entries (drgnx-store-privacy--entries)))
     (unless entries (user-error "Your deny list is empty: the built-in list cannot be shortened"))
     (list (completing-read "Stop keeping out: " (mapcar (lambda (e) (cdr e)) entries) nil t))))
  (let* ((entries (drgnx-store-privacy--read drgnx-store-privacy-deny-file 'entries))
         (true (drgnx-store-privacy--true path))
         (keep (seq-remove (lambda (e) (let ((p (alist-get 'path e)))
                                         (and (stringp p) (or (equal p path) (equal (drgnx-store-privacy--true p) true)))))
                           entries))
         (shown (abbreviate-file-name true)))
    (when (= (length keep) (length entries))
      (if (drgnx-store-privacy--built-in-p true (drgnx-store-privacy--org))
          (user-error "%s is kept out by drgnx itself: the built-in list cannot be shortened" shown)
        (user-error "%s is not in your deny list" shown)))
    (unless (yes-or-no-p (format "Stop keeping %s out of the store? Nothing stored changes; a later scan may read it "
                                 shown))
      (user-error "Nothing changed"))
    (drgnx-store-privacy--write drgnx-store-privacy-deny-file 'entries keep)
    (drgnx-store-privacy--report (format "%s is no longer kept out by your list" shown) (drgnx-store-privacy--reload))))

(provide 'drgnx-store-privacy)
;;; drgnx-store-privacy.el ends here
