;;; drgnx-portable.el --- What travels to a second machine and what stays -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The whole config dir (`drgnx-user-dir') travels: copied, or kept as a git repo of its own.  So nothing in it may
;; be this machine's alone, and no secret may be in it in plain text.  This machine's files (the Emacs install.sh
;; recorded, onboarding's systemd unit and desktop entry) live in the data dir; `drgnx-portable-move-machine-local'
;; moves old copies there.  Paths under home are written "~/..." (`drgnx-portable-path'), and read back with
;; `expand-file-name', so they name the same place on a machine whose home is elsewhere.
;; `drgnx-portable-config-problems' is what the doctor's `portable-config' check reports: files that hold a key
;; (named, never quoted), machine-local items, project roots not cloned here.  See docs/guide/second-machine.md.
;; Nothing here runs by itself: no timer, no hook, no prompt.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-portable-machine-local '("emacs" "systemd/" "applications/")
  "The config dir's items that belong to one machine (a trailing slash: a directory).  They live in the data dir.")

(defconst drgnx-portable-leftovers '("*.bak-*" ".*.lock" ".*.lock.stale-*" ".*.tmp-*" "keys.eld.undo")
  "Name patterns (shell globs) of the config layer's own files: backups, lock directories (and a stale one being
taken over), temp files and the keys undo file.  They never travel: onboarding's repository leaves them out (and
its .gitignore names them), bootstrap's empty-config check ignores them, and they are neither moved nor
machine-local.")

(defconst drgnx-portable-install-url "https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh"
  "install.sh, for the command a new machine runs.")

(defconst drgnx-portable-key-patterns
  '("sk-or-v1-[A-Za-z0-9]\\{20,\\}"           ; OpenRouter
    "sk-ant-[A-Za-z0-9_-]\\{20,\\}"           ; Anthropic
    "\\bsk-\\(?:proj\\|svcacct\\|admin\\)-[A-Za-z0-9_-]\\{20,\\}" ; OpenAI project, service account, admin keys
    "\\bsk-[A-Za-z0-9]\\{32,\\}"               ; OpenAI-style (legacy)
    "gh[pousr]_[A-Za-z0-9]\\{30,\\}"          ; GitHub tokens
    "github_pat_[A-Za-z0-9_]\\{22,\\}"        ; GitHub fine-grained tokens
    "AKIA[0-9A-Z]\\{16\\}"                    ; AWS access keys
    "-----BEGIN [A-Z ]*PRIVATE KEY-----"
    "AGE-SECRET-KEY-1[0-9A-Z]\\{58\\}")       ; an age identity
  "Text that is a secret: the pre-commit hook's key patterns (.githooks/pre-commit), and an age identity.
A distinctive prefix matches after any character (\"KEY_sk-ant-…\", \"xsk-or-v1-…\"); the generic sk- forms only at
a word start, so \"task-<hash>\" or \"desk-admin-…\" is not a key.  Plain text only: a base64-wrapped key is not
found.  A new provider's key prefix goes here and in the hook.")

(defconst drgnx-portable-secret-file-regexp "\\`\\(?:\\.env\\(?:\\..*\\)?\\|secrets\\.env\\|.*\\.pem\\|.*\\.key\\)\\'"
  "File names that hold secrets whatever their text (the pre-commit hook's list).")

(defconst drgnx-portable-scan-bytes (* 1024 1024) "Bytes of each config file the key scan reads.")

;;;; ~/ paths

(defun drgnx-portable--under (file home)
  "FILE as \"~\" or \"~/REL\" when it is HOME or under it, else nil.  HOME \"/\" counts as no home."
  (let ((home (directory-file-name home)))
    (unless (equal home "/")
      (cond ((equal (directory-file-name file) home) (if (string-suffix-p "/" file) "~/" "~"))
            ((string-prefix-p (file-name-as-directory home) file)
             (concat "~/" (substring file (length (file-name-as-directory home)))))))))

(defun drgnx-portable-path (file)
  "FILE as \"~/REL\" when it is under home, else FILE absolute.  Home is compared as $HOME says and as its
`file-truename' (Silverblue: /home/u is /var/home/u); FILE as written, then as its truename.  Read it back
with `expand-file-name'."
  (let* ((file (expand-file-name file))
         (home (expand-file-name "~"))
         (homes (delete-dups (list home (file-truename home)))))
    (or (cl-some (lambda (h) (drgnx-portable--under file h)) homes)
        (let ((true (file-truename file)))
          (and (not (equal true file))
               (cl-some (lambda (h) (drgnx-portable--under (if (string-suffix-p "/" file) (file-name-as-directory true) true) h))
                        homes)))
        file)))

;;;; Machine-local items

(defun drgnx-portable--files (dir)
  "The files under DIR, relative to it, sorted."
  (sort (mapcar (lambda (f) (file-relative-name f dir)) (directory-files-recursively dir "" nil nil))
        #'string<))

(defun drgnx-portable--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-portable--same-p (a b)
  "Non-nil when A and B (two files, or two directories) hold the same files with the same bytes."
  (cond ((and (file-directory-p a) (file-directory-p b))
         (let ((fa (drgnx-portable--files a)))
           (and (equal fa (drgnx-portable--files b))
                (cl-every (lambda (f) (drgnx-portable--same-p (expand-file-name f a) (expand-file-name f b))) fa))))
        ((or (file-directory-p a) (file-directory-p b)) nil)
        (t (equal (drgnx-portable--bytes a) (drgnx-portable--bytes b)))))

(defun drgnx-portable--delete (path)
  "Delete PATH: a directory with its files; a symlink (to a directory too) as the link only."
  (if (and (file-directory-p path) (not (file-symlink-p path))) (delete-directory path t) (delete-file path)))

(defun drgnx-portable--delete-new (to)
  "Delete TO.drgnx-new, the unfinished copy a crash left, when it is there."
  (let ((new (concat to ".drgnx-new")))
    (when (or (file-exists-p new) (file-symlink-p new)) (drgnx-portable--delete new))))

(defun drgnx-portable--copy-into-place (from to)
  "Copy FROM (a file or a directory) to TO, which is not there: into TO.drgnx-new, verified, then renamed to TO.
An error leaves neither TO nor TO.drgnx-new; a crash can leave only TO.drgnx-new."
  (let ((new (concat to ".drgnx-new")))
    (unwind-protect
        (progn
          (if (file-directory-p from) (copy-directory from new t t) (copy-file from new nil t t t))
          (unless (drgnx-portable--same-p from new)
            (error "drgnx: copying %s to %s did not give the same files: nothing moved" from to))
          (rename-file new to))
      (drgnx-portable--delete-new to))))

(defun drgnx-portable-move-machine-local ()
  "Move the machine-local items of the config dir to the data dir: copy, verify, then delete.
Returns (ITEM . STATUS) for each item the config dir has: `moved'; `dropped' (an identical copy is in the data
dir already: the config dir's is deleted); `kept' (a different copy is there: neither is touched).  The copy is
renamed into place only once verified, so the data dir never holds part of an item; an unfinished copy
\(ITEM.drgnx-new in the data dir, left by a crash) is drgnx's own and is deleted first."
  (let ((config (drgnx-user-dir)) (data (drgnx-data-dir)))
    (cl-loop for item in drgnx-portable-machine-local
             for from = (directory-file-name (expand-file-name item config))
             for to = (directory-file-name (expand-file-name item data))
             do (drgnx-portable--delete-new to)
             when (file-exists-p from)
             collect (cons item
                           (cond ((file-exists-p to)
                                  (if (drgnx-portable--same-p from to) (progn (drgnx-portable--delete from) 'dropped)
                                    'kept))
                                 (t (make-directory data t)
                                    (drgnx-portable--copy-into-place from to)
                                    (drgnx-portable--delete from)
                                    'moved))))))

(defconst drgnx-portable--leftover-regexp (mapconcat #'wildcard-to-regexp drgnx-portable-leftovers "\\|")
  "`drgnx-portable-leftovers' as one regexp, matched against a file name's last part.")

(defun drgnx-portable-leftover-p (name)
  "Non-nil when NAME's last part is one of the config layer's own files (`drgnx-portable-leftovers')."
  (string-match-p drgnx-portable--leftover-regexp (file-name-nondirectory (directory-file-name name))))

;;;; Problems: keys in plain text, machine-local items, roots not here

(declare-function drgnx-projects-read "drgnx-projects")

(defun drgnx-portable--secret-p (file name)
  "Non-nil when FILE (config-dir relative NAME) looks like a secret: by its name, or a key in its first bytes."
  (or (string-match-p drgnx-portable-secret-file-regexp (file-name-nondirectory name))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 drgnx-portable-scan-bytes)
        (let ((case-fold-search nil))
          (cl-some (lambda (re) (goto-char (point-min)) (re-search-forward re nil t)) drgnx-portable-key-patterns)))))

(defun drgnx-portable--key-files (config)
  "(:keys FILES :unchecked NAMES) for the regular files under CONFIG (not .git/, not secrets.age, not symlinks).
FILES hold a secret; NAMES are the files and directories (\"DIR/\") that could not be read, so were not checked.
Config-relative names only: a key's text never leaves this function."
  (let (keys unchecked)
    (when (file-directory-p config)
      (dolist (f (directory-files-recursively
                  config "" nil (lambda (d)
                                  (cond ((equal (file-name-nondirectory d) ".git") nil)
                                        ((file-accessible-directory-p d) t)
                                        (t (push (file-name-as-directory (file-relative-name d config)) unchecked) nil)))))
        (let ((name (file-relative-name f config)))
          (when (and (not (equal name "secrets.age")) (not (file-symlink-p f)) (file-regular-p f))
            (condition-case nil
                (when (drgnx-portable--secret-p f name) (push name keys))
              (file-error (push name unchecked)))))))
    (list :keys (sort keys #'string<) :unchecked (sort unchecked #'string<))))

(defun drgnx-portable--missing-roots ()
  "projects.eld's roots that are not directories on this machine, as written (\"~/...\")."
  (require 'drgnx-projects)
  (cl-loop for p in (plist-get (drgnx-projects-read) :projects)
           for root = (plist-get p :root)
           when (and (stringp root) (not (file-directory-p root)))
           collect (drgnx-portable-path root)))

(defun drgnx-portable-config-problems ()
  "What keeps the config dir from travelling as it is:
(:keys FILES :unchecked NAMES :machine-local ITEMS :in-both ITEMS :missing-roots ROOTS).
FILES: config-relative names of files that hold a key in plain text (never the key); NAMES: files and directories
the scan could not read; ITEMS: members of `drgnx-portable-machine-local' present there (:in-both: those the data
dir has too, which drgnx uses); ROOTS: projects.eld roots not cloned here."
  (let* ((config (drgnx-user-dir))
         (local (cl-remove-if-not (lambda (i) (file-exists-p (expand-file-name i config))) drgnx-portable-machine-local)))
    (append (drgnx-portable--key-files config)
            (list :machine-local local
                  :in-both (cl-remove-if-not (lambda (i) (file-exists-p (expand-file-name i (drgnx-data-dir)))) local)
                  :missing-roots (drgnx-portable--missing-roots)))))

(provide 'drgnx-portable)
;;; drgnx-portable.el ends here
