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

(defconst drgnx-portable-install-url "https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh"
  "install.sh, for the command a new machine runs.")

(defconst drgnx-portable-key-patterns
  '("\\bsk-or-v1-[A-Za-z0-9]\\{20,\\}"         ; OpenRouter
    "\\bsk-ant-[A-Za-z0-9_-]\\{20,\\}"         ; Anthropic
    "\\bsk-[A-Za-z0-9]\\{32,\\}"               ; OpenAI-style
    "\\bgh[pousr]_[A-Za-z0-9]\\{30,\\}"        ; GitHub tokens
    "\\bAKIA[0-9A-Z]\\{16\\}"                  ; AWS access keys
    "-----BEGIN [A-Z ]*PRIVATE KEY-----"
    "\\bAGE-SECRET-KEY-1[0-9A-Z]\\{58\\}")     ; an age identity
  "Text that is a secret: the pre-commit hook's key patterns (.githooks/pre-commit), and an age identity.
A new provider's key prefix goes here and in the hook.")

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
  (if (file-directory-p path) (delete-directory path t) (delete-file path)))

(defun drgnx-portable-move-machine-local ()
  "Move the machine-local items of the config dir to the data dir: copy, verify, then delete.
Returns (ITEM . STATUS) for each item the config dir has: `moved'; `dropped' (an identical copy is in the data
dir already: the config dir's is deleted); `kept' (a different copy is there: neither is touched)."
  (let ((config (drgnx-user-dir)) (data (drgnx-data-dir)))
    (cl-loop for item in drgnx-portable-machine-local
             for from = (directory-file-name (expand-file-name item config))
             for to = (directory-file-name (expand-file-name item data))
             when (file-exists-p from)
             collect (cons item
                           (cond ((file-exists-p to)
                                  (if (drgnx-portable--same-p from to) (progn (drgnx-portable--delete from) 'dropped)
                                    'kept))
                                 (t (make-directory data t)
                                    (if (file-directory-p from) (copy-directory from to t t)
                                      (copy-file from to nil t t t))
                                    (unless (drgnx-portable--same-p from to)
                                      (drgnx-portable--delete to)
                                      (error "drgnx: copying %s to %s did not give the same files: nothing moved" from to))
                                    (drgnx-portable--delete from)
                                    'moved))))))

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
  "Config-relative names of the regular files under CONFIG (not .git/, not secrets.age, not symlinks) that hold
a secret.  Names only: a key's text never leaves this function."
  (when (file-directory-p config)
    (sort (cl-loop for f in (directory-files-recursively
                             config "" nil (lambda (d) (not (equal (file-name-nondirectory d) ".git"))))
                   for name = (file-relative-name f config)
                   when (and (not (equal name "secrets.age")) (not (file-symlink-p f)) (file-regular-p f)
                             (file-readable-p f) (drgnx-portable--secret-p f name))
                   collect name)
          #'string<)))

(defun drgnx-portable--missing-roots ()
  "projects.eld's roots that are not directories on this machine, as written (\"~/...\")."
  (require 'drgnx-projects)
  (cl-loop for p in (plist-get (drgnx-projects-read) :projects)
           for root = (plist-get p :root)
           when (and (stringp root) (not (file-directory-p root)))
           collect (drgnx-portable-path root)))

(defun drgnx-portable-config-problems ()
  "What keeps the config dir from travelling as it is: (:keys FILES :machine-local ITEMS :missing-roots ROOTS).
FILES: config-relative names of files that hold a key in plain text (never the key); ITEMS: members of
`drgnx-portable-machine-local' present there; ROOTS: projects.eld roots not cloned here."
  (let ((config (drgnx-user-dir)))
    (list :keys (drgnx-portable--key-files config)
          :machine-local (cl-remove-if-not (lambda (i) (file-exists-p (expand-file-name i config))) drgnx-portable-machine-local)
          :missing-roots (drgnx-portable--missing-roots))))

(provide 'drgnx-portable)
;;; drgnx-portable.el ends here
