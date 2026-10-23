;;; drgnx-user-lisp.el --- Settings: your Lisp files (on/off, early files, bisect) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 29 (design §8.2): the Lisp files listed in `drgnx-user-lisp-files' (settings.el), loaded
;; after config.el, and the `:early t' ones, loaded at the end of early-init.el.  early-init.el loads this file by
;; its path, before anything else of drgnx's but drgnx-paths, so it loads what it needs from its own folder the same
;; way (docs/develop/settings.md, "The start-up order").
;;
;; - Turning a file on loads it now; turning it off takes effect at the next start (code that ran cannot be
;;   unloaded; the row says so).  config.el and custom.el have rows with the same switch.
;; - `:emacs-dir DIR' binds `user-emacs-directory' to DIR while that one file loads (no other file, no later code).
;; - Add Lisp File… adds a file without copying it, finds an early-init.el beside it, and lists what it does to
;;   `user-emacs-directory' and `custom-file'; the doctor names a package-initialize, straight.el or elpaca bootstrap.
;; - `drgnx bisect' (drgnx-pkg.el) takes the files as candidates beside the modules.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-user-lisp--dir (file-name-directory (or load-file-name buffer-file-name default-directory))
  "The folder of this file, drgnx's core/: early-init.el loads this file before `load-path' has it.")

(defun drgnx-user-lisp--require (feature)
  "Require FEATURE from this file's folder, whatever `load-path' says."
  (let ((load-path (cons drgnx-user-lisp--dir load-path)))
    (require feature)))

(eval-when-compile (require 'drgnx-setting))
(drgnx-user-lisp--require 'drgnx-paths)
(drgnx-user-lisp--require 'drgnx-setting)

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-settings-prov--call-with-load "drgnx-settings-prov" (file body))
(declare-function drgnx-settings-file-read "drgnx-settings-file" (file head &rest args))
(declare-function drgnx-settings-file-put "drgnx-settings-file" (file head scope var value &rest args))
(declare-function drgnx-user-dir "drgnx-paths" ())
(declare-function drgnx-setting--declare "drgnx-setting" (var plist))
(declare-function drgnx-settings-doc-entries "drgnx-settings-file" (doc))
(declare-function drgnx-settings-entry-var "drgnx-settings-file" (entry))
(declare-function drgnx-settings-entry-value "drgnx-settings-file" (entry))
(declare-function drgnx-settings-entry-scope "drgnx-settings-file" (entry))
(declare-function drgnx-lisp-index-get "drgnx-lisp-index" (file))
(declare-function drgnx-settings-area-update "drgnx-settings-area" (vars fn &optional always))
(declare-function drgnx-settings-lisp-page-rows "drgnx-settings-lisp-page" ())
(declare-function drgnx-command-define "drgnx-registry" (id &rest args))
(autoload 'drgnx-settings-lisp-page-note-load "drgnx-settings-lisp-page")
(autoload 'drgnx-settings-lisp-page-rows "drgnx-settings-lisp-page")

(defun drgnx-user-lisp--say (text)
  "Say TEXT in the echo area: the early loader and the start-up call sites have no notices yet and never signal."
  (message "%s" (concat "drgnx: " text)))

(drgnx-defsetting drgnx-user-lisp-files nil
  "Your own Lisp files, loaded in this order after config.el: ((FILE :on BOOL [:early t] [:emacs-dir DIR])…).
FILE is relative to your config folder or absolute.  `:on' (default t) says whether it loads: turning one on loads it
now, turning one off takes effect at the next start (code that already ran cannot be unloaded).  `:early t' loads it
at the end of early-init.el, before drgnx starts.  `:emacs-dir DIR' binds `user-emacs-directory' to DIR while this one
file loads: a `setq' of it in the file is undone afterwards, and what loads later sees drgnx's folder, so use it only
for an init.el that expects its own.  config.el and custom.el may be listed too, only for their `:on' switch.
Settings: Lisp Files shows the files; Settings: Add Lisp File… adds one."
  :type '(repeat (cons :tag "Lisp file" (file) (plist :key-type symbol :value-type sexp)))
  :group 'drgnx :scope 'global :workspace 'never :agents 'never :apply #'drgnx-user-lisp--settings-apply
  :schema '(list-of any))

;;;; The list

(defun drgnx-user-lisp--normal (value)
  "VALUE (a `drgnx-user-lisp-files') as ((FILE . PLIST)…), FILE expanded in your config folder; a malformed entry is
left out."
  (let (out)
    (dolist (e (and (listp value) value))
      (let ((f (if (consp e) (car e) e)) (o (and (consp e) (cdr e))))
        (when (and (stringp f) (not (string-empty-p f)) (plistp o))
          (push (cons (expand-file-name f (drgnx-user-dir)) o) out))))
    (nreverse out)))

(defun drgnx-user-lisp--same-p (a b)
  "Non-nil when the file names A and B name the same file."
  (or (equal a b) (equal (file-truename a) (file-truename b))))

(defun drgnx-user-lisp--on (opts) "Whether the plist OPTS of a listed file says it is on (default t)."
       (if (plist-member opts :on) (and (plist-get opts :on) t) t))

(defun drgnx-user-lisp--entries ()
  "`drgnx-user-lisp-files' normalised."
  (drgnx-user-lisp--normal drgnx-user-lisp-files))

(defun drgnx-user-lisp-on-p (file)
  "Nil only when `drgnx-user-lisp-files' lists FILE with `:on' nil: config.el and custom.el call this before they load."
  (condition-case nil
      (let ((e (cl-find-if (lambda (e) (drgnx-user-lisp--same-p (car e) (expand-file-name file (drgnx-user-dir))))
                           (drgnx-user-lisp--entries))))
        (or (null e) (drgnx-user-lisp--on (cdr e))))
    (error t)))

(defun drgnx-user-lisp--read-listed (settings-file)
  "The raw `drgnx-user-lisp-files' that SETTINGS-FILE holds (read as data, never loaded), or nil."
  (when (file-exists-p settings-file)
    (drgnx-user-lisp--require 'drgnx-settings-file)
    (when-let* ((doc (ignore-errors (drgnx-settings-file-read settings-file 'drgnx-settings))))
      (cl-some (lambda (e) (and (eq (drgnx-settings-entry-var e) 'drgnx-user-lisp-files)
                                (null (drgnx-settings-entry-scope e))
                                (drgnx-settings-entry-value e)))
               (drgnx-settings-doc-entries doc)))))

;;;; Loading

(defvar drgnx-user-lisp--loaded nil "Names of the files this loader loaded (or tried to) this session.")
(defvar drgnx-user-lisp--early-notes nil
  "What the early loader saw, newest first, for the page and the notices once they exist: (FILE SECONDS ERROR).")

(defun drgnx-user-lisp--loaded-p (file)
  "Non-nil when FILE loaded this session: by this loader, config.el's or anything in `load-history'."
  (or (member file drgnx-user-lisp--loaded)
      (let ((base (file-name-sans-extension file)))
        (cl-some (lambda (h) (and (stringp (car h)) (equal (file-name-sans-extension (car h)) base))) load-history))))

(defun drgnx-user-lisp--report (file seconds err)
  "Tell the Lisp files page and the notices that FILE loaded in SECONDS with ERR (a message or nil); never signals."
  (ignore-errors (drgnx-settings-lisp-page-note-load file :seconds seconds :error err))
  (when (and err (fboundp 'drgnx-notify))
    (ignore-errors
      (drgnx-notify 'config 'fail (format "%s: %s (the rest of it did not run)" (abbreviate-file-name file) err)
                    :id (intern (format "user-lisp:%s" (file-name-nondirectory file))) :life 'condition
                    :command 'settings-lisp-files))))

(defun drgnx-user-lisp--load-1 (file opts)
  "Load FILE, with `user-emacs-directory' bound to OPTS' `:emacs-dir' if it has one: (SECONDS . ERROR-MESSAGE).
An error is returned, never signalled."
  (let* ((start (float-time)) err
         (dir (plist-get opts :emacs-dir))
         (user-emacs-directory (if (stringp dir) (file-name-as-directory (expand-file-name dir)) user-emacs-directory)))
    (condition-case e (load file nil 'nomessage 'nosuffix)
      (error (setq err (error-message-string e))))
    (cons (- (float-time) start) err)))

(defun drgnx-user-lisp--load (file opts)
  "Load your Lisp FILE (OPTS: its plist) inside provenance, so the lines it sets are recorded, and tell the page how
it went.  A file loads once per session here.  Never signals."
  (push file drgnx-user-lisp--loaded)
  (condition-case err
      (progn
        (drgnx-user-lisp--require 'drgnx-settings-prov)
        (drgnx-settings-prov--call-with-load
         file
         (lambda ()
           (let ((r (drgnx-user-lisp--load-1 file opts)))
             ;; inside the provenance scope, so an error's line is the form being read when it happened
             (drgnx-user-lisp--report file (car r) (cdr r))))))
    (error (drgnx-user-lisp--say (format "your Lisp file %s: %s" file (error-message-string err))))))

(defun drgnx-user-lisp--catch-up ()
  "Load every listed file that is on and has not loaded this session, in order; the early loader's notes first."
  (while drgnx-user-lisp--early-notes
    (pcase-let ((`(,file ,seconds ,err) (car (last drgnx-user-lisp--early-notes))))
      (setq drgnx-user-lisp--early-notes (butlast drgnx-user-lisp--early-notes))
      (drgnx-user-lisp--report file seconds err)))
  (dolist (e (drgnx-user-lisp--entries))
    (let ((file (car e)))
      (when (and (drgnx-user-lisp--on (cdr e)) (file-exists-p file) (not (drgnx-user-lisp--loaded-p file)))
        (drgnx-user-lisp--load file (cdr e))))))

(defun drgnx-user-lisp--settings-apply ()
  "`:apply' of `drgnx-user-lisp-files': a file turned on loads now (never in safe mode); one turned off stays until the
next start."
  (unless (getenv "DRGNX_SAFE")
    (drgnx-user-lisp--catch-up)))

(defun drgnx-user-lisp-load-all ()
  "Load your Lisp files that are on, after config.el; never in safe mode, never signals."
  (unless (getenv "DRGNX_SAFE")
    (condition-case err (drgnx-user-lisp--catch-up)
      (error (drgnx-user-lisp--say (format "your Lisp files: %s" (error-message-string err)))))))

(defun drgnx-user-lisp-load-early ()
  "Load your `:early t' Lisp files, from early-init.el; never in safe mode, never signals.
settings.el is read as data, and only when it mentions `:early'.  Provenance and the notices do not exist yet: what
happens is kept for `drgnx-user-lisp-load-all'."
  (unless (getenv "DRGNX_SAFE")
    (condition-case err
        (let ((file (expand-file-name "settings.el" (drgnx-user-dir))))
          (when (and (file-readable-p file)
                     (with-temp-buffer
                       (insert-file-contents file nil 0 1048576)
                       (search-forward ":early" nil t)))
            (dolist (e (drgnx-user-lisp--normal (drgnx-user-lisp--read-listed file)))
              (when (and (plist-get (cdr e) :early) (drgnx-user-lisp--on (cdr e)) (file-exists-p (car e)))
                (push (car e) drgnx-user-lisp--loaded)
                (let ((r (drgnx-user-lisp--load-1 (car e) (cdr e))))
                  (push (list (car e) (car r) (cdr r)) drgnx-user-lisp--early-notes))))))
      (error (drgnx-user-lisp--say (format "your early Lisp files: %s" (error-message-string err)))))))

;;;; Changing the list

(defun drgnx-user-lisp--entry-name (file)
  "FILE as an entry of `drgnx-user-lisp-files' names it: relative inside your config folder, else abbreviated."
  (let ((file (expand-file-name file (drgnx-user-dir))))
    (if (file-in-directory-p file (drgnx-user-dir))
        (file-relative-name file (drgnx-user-dir))
      (abbreviate-file-name file))))

(defun drgnx-user-lisp--updated (raw file fn)
  "RAW (a `drgnx-user-lisp-files') with FILE's entry replaced by (NAME . (funcall FN PLIST)), added at the end when it
has none.  The other entries stay as they are."
  (let ((file (expand-file-name file (drgnx-user-dir))) found
        (out nil))
    (dolist (e raw)
      (let ((f (if (consp e) (car e) e)))
        (if (and (not found) (stringp f) (drgnx-user-lisp--same-p (expand-file-name f (drgnx-user-dir)) file))
            (progn (setq found t) (push (cons f (funcall fn (and (consp e) (cdr e)))) out))
          (push e out))))
    (unless found (push (cons (drgnx-user-lisp--entry-name file) (funcall fn nil)) out))
    (nreverse out)))

(defun drgnx-user-lisp--plist-put (opts &rest kvs)
  "A copy of OPTS with KVS (key value…) set, :on first."
  (let ((new (copy-sequence opts)))
    (while kvs (setq new (plist-put new (pop kvs) (pop kvs))))
    (if (plist-member new :on)
        (cons :on (cons (plist-get new :on) (cl-loop for (k v) on new by #'cddr unless (eq k :on) append (list k v))))
      new)))

(defun drgnx-user-lisp--write (fn)
  "Change `drgnx-user-lisp-files' in settings.el: the new list is (funcall FN RAW-LIST); then load what is on now."
  (require 'drgnx-settings-area)
  (drgnx-settings-area-update '(drgnx-user-lisp-files)
                              (lambda (cur) (list (cons 'drgnx-user-lisp-files (funcall fn (cdr (assq 'drgnx-user-lisp-files cur)))))))
  (unless (getenv "DRGNX_SAFE")
    (drgnx-user-lisp--catch-up)))

(defun drgnx-user-lisp-set-on (file on)
  "Turn your Lisp FILE ON (non-nil) or off in `drgnx-user-lisp-files'; a file turned on loads now, one turned off
stays loaded until the next start.  Returns what happens: `loaded-now', `already-loaded', `off-at-next-start' or
`off'."
  (let ((file (expand-file-name file (drgnx-user-dir))) (was (drgnx-user-lisp--loaded-p (expand-file-name file (drgnx-user-dir)))))
    (drgnx-user-lisp--write
     (lambda (raw) (drgnx-user-lisp--updated raw file (lambda (o) (drgnx-user-lisp--plist-put o :on (and on t))))))
    (cond (on (if was 'already-loaded 'loaded-now))
          (was 'off-at-next-start)
          (t 'off))))

(defun drgnx-user-lisp-toggle (file)
  "Settings: Turn a Lisp File On or Off: your Lisp FILE (on the Lisp files page, the line's file).  On loads it now;
off takes effect at the next start, because code that already ran cannot be unloaded."
  (interactive
   (list (or (car (get-text-property (point) 'drgnx-settings-lisp-page-at))
             (let ((files (mapcar (lambda (r) (plist-get r :file))
                                  (seq-remove (lambda (r) (eq (plist-get r :role) 'data)) (drgnx-settings-lisp-page-rows)))))
               (completing-read "Lisp file: " files nil t)))))
  (when (string-suffix-p "settings.el" file)
    (user-error "Settings: settings.el is data drgnx reads, not a Lisp file to turn off"))
  (let* ((file (expand-file-name file (drgnx-user-dir)))
         (on (not (drgnx-user-lisp-on-p file)))
         (r (drgnx-user-lisp-set-on file on)))
    (message "Settings: %s is %s" (abbreviate-file-name file)
             (pcase r
               ('loaded-now "on and loaded now") ('already-loaded "on (it had loaded already)")
               ('off-at-next-start "off from the next start (code that already ran cannot be unloaded)")
               (_ "off")))
    r))

;;;; Adding a file

(defconst drgnx-user-lisp--bootstraps
  '((package-initialize . "^[ \t]*(package-initialize\\_>")
    (straight . "^[ \t]*(\\(?:defvar bootstrap-version\\|straight-use-package\\|straight-bootstrap\\)\\_>\\|straight/repos/straight\\.el")
    (elpaca . "^[ \t]*(\\(?:defvar elpaca-installer-version\\|elpaca-bootstrap\\|elpaca \\)\\|elpaca-installer"))
  "Package-manager bootstraps in a file of yours: KIND and a regexp that matches the start of a line.")

(defun drgnx-user-lisp-bootstraps (&optional files)
  "The `package-initialize', straight.el and elpaca bootstraps in FILES (default: the listed ones that exist):
a list of (:file :line :kind :text).  They are not drgnx's package manager; the doctor names them and nothing is
blocked."
  (let (out)
    (dolist (file (or files (mapcar #'car (drgnx-user-lisp--entries))))
      (when (and (file-readable-p file) (not (file-directory-p file)))
        (with-temp-buffer
          (insert-file-contents file nil 0 1048576)
          (dolist (b drgnx-user-lisp--bootstraps)
            (goto-char (point-min))
            (let ((case-fold-search nil))
              (while (re-search-forward (cdr b) nil t)
                (unless (save-excursion (goto-char (line-beginning-position))
                                        (looking-at-p "[ \t]*;"))
                  (push (list :file file :line (line-number-at-pos) :kind (car b)
                              :text (string-trim (buffer-substring (line-beginning-position) (line-end-position))))
                        out))))))))
    (sort (nreverse out) (lambda (a b) (and (equal (plist-get a :file) (plist-get b :file))
                                            (< (plist-get a :line) (plist-get b :line)))))))

(defun drgnx-user-lisp-findings (file)
  "What FILE does that drgnx tells you about, from the static index (nothing runs): a list of (:kind :line :text).
`custom-file' and `user-emacs-directory' changes, uses of `user-emacs-directory', a `setq' of a buffer-local
variable, and a change to `package-enable-at-startup' (drgnx keeps it nil)."
  (drgnx-user-lisp--require 'drgnx-lisp-index)
  (let* ((index (ignore-errors (drgnx-lisp-index-get file)))
         (own (cl-loop for s in (plist-get index :setters)
                       when (eq (plist-get s :var) 'package-enable-at-startup)
                       collect (list :kind 'package-enable-at-startup :line (plist-get s :line)
                                     :text "changes package-enable-at-startup (drgnx keeps it nil; it manages packages itself)"))))
    (sort (append (plist-get index :findings) own)
          (lambda (a b) (< (or (plist-get a :line) 0) (or (plist-get b :line) 0))))))

(defun drgnx-user-lisp-add-plan (file)
  "What adding FILE shows before it is added: (:file :findings :emacs-dir-uses :early-init :bootstraps).
EARLY-INIT is the early-init.el beside FILE, if any (offered as an early file); EMACS-DIR-USES counts the uses of
`user-emacs-directory' and `locate-user-emacs-file'; nothing is changed and no file runs."
  (let* ((file (expand-file-name file (drgnx-user-dir)))
         (early (expand-file-name "early-init.el" (file-name-directory file)))
         (findings (drgnx-user-lisp-findings file)))
    (list :file file :findings findings
          :emacs-dir-uses (cl-count 'emacs-dir-use findings :key (lambda (f) (plist-get f :kind)))
          :early-init (and (file-exists-p early) (not (drgnx-user-lisp--same-p early file)) early)
          :bootstraps (drgnx-user-lisp-bootstraps (list file)))))

(cl-defun drgnx-user-lisp-add (file &key early-init emacs-dir)
  "Add your Lisp FILE to `drgnx-user-lisp-files' without copying it, and load it now.
EARLY-INIT: the early-init.el beside it, added first as an early file (`:early t'; it loads at the next start's
early-init, and now).  EMACS-DIR: a folder to bind `user-emacs-directory' to while FILE loads.  Returns the plan
\(`drgnx-user-lisp-add-plan')."
  (let ((plan (drgnx-user-lisp-add-plan file)))
    (drgnx-user-lisp--write
     (lambda (raw)
       (when early-init
         (setq raw (drgnx-user-lisp--updated raw early-init
                                             (lambda (o) (drgnx-user-lisp--plist-put o :on t :early t)))))
       (drgnx-user-lisp--updated raw file
                                 (lambda (o) (apply #'drgnx-user-lisp--plist-put o :on t
                                                    (and emacs-dir (list :emacs-dir (abbreviate-file-name emacs-dir))))))))
    plan))

(defun drgnx-user-lisp-add-file (file)
  "Settings: Add Lisp File…: add FILE, for example ~/.emacs.d/init.el, to your Lisp files without copying it.
Shows what it finds first: an early-init.el beside it (offered as an early file), changes to `custom-file' and
`user-emacs-directory', uses of `user-emacs-directory' (offered: load it with its own folder as
`user-emacs-directory', with the caveat), a package manager's bootstrap.  Nothing is blocked."
  (interactive (list (read-file-name "Add Lisp file: " nil nil t)))
  (let* ((plan (drgnx-user-lisp-add-plan file))
         (buf (get-buffer-create "*drgnx Add Lisp File*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Adding %s to your Lisp files (it is not copied).\n\n" (abbreviate-file-name (plist-get plan :file))))
        (dolist (f (plist-get plan :findings))
          (insert (format "  line %s: %s\n" (plist-get f :line) (plist-get f :text))))
        (dolist (b (plist-get plan :bootstraps))
          (insert (format "  line %s: %s bootstrap: drgnx manages packages itself; nothing is blocked\n"
                          (plist-get b :line) (plist-get b :kind))))
        (goto-char (point-min)))
      (special-mode))
    (display-buffer buf)
    (unwind-protect
        (let* ((early (and (plist-get plan :early-init)
                           (y-or-n-p (format "%s is beside it: load it as an early file (end of early-init.el)? "
                                             (file-name-nondirectory (plist-get plan :early-init))))))
               (dir (and (> (plist-get plan :emacs-dir-uses) 0)
                         (y-or-n-p (format "It uses user-emacs-directory %d times: load it with its folder as \
user-emacs-directory?  (Only while it loads: a setq of it is undone afterwards and what loads later sees drgnx's.) "
                                           (plist-get plan :emacs-dir-uses)))
                         (file-name-directory (plist-get plan :file)))))
          (drgnx-user-lisp-add file :early-init (and early (plist-get plan :early-init)) :emacs-dir dir)
          (message "Settings: %s added and loaded" (abbreviate-file-name (plist-get plan :file))))
      (quit-windows-on buf))))

;;;; Bisect

(defun drgnx-user-lisp-bisect-files (&optional settings-file)
  "The files `drgnx bisect' may turn off: each listed file that is on, and config.el and custom.el when they exist
and are not listed off, as expanded names.  SETTINGS-FILE: the settings.el to read (default yours)."
  (let* ((settings-file (or settings-file (expand-file-name "settings.el" (drgnx-user-dir))))
         (entries (drgnx-user-lisp--normal (drgnx-user-lisp--read-listed settings-file)))
         (files (mapcar #'car (seq-filter (lambda (e) (drgnx-user-lisp--on (cdr e))) entries))))
    (dolist (name '("config.el" "custom.el"))
      (let ((f (expand-file-name name (drgnx-user-dir))))
        (when (and (file-exists-p f)
                   (not (cl-find-if (lambda (e) (drgnx-user-lisp--same-p (car e) f)) entries)))
          (setq files (append files (list f))))))
    (seq-filter #'file-exists-p (delete-dups files))))

(defun drgnx-user-lisp-bisect-put (settings-file off)
  "Write `drgnx-user-lisp-files' in SETTINGS-FILE (a copy of yours) with the files OFF (expanded names) turned off.
The other entries stay; a file OFF that is not listed gets an entry."
  (when off
    (drgnx-user-lisp--require 'drgnx-settings-file)
    (let ((raw (drgnx-user-lisp--read-listed settings-file)))
      (dolist (file off)
        (setq raw (drgnx-user-lisp--updated raw file (lambda (o) (drgnx-user-lisp--plist-put o :on nil)))))
      (drgnx-settings-file-put settings-file 'drgnx-settings nil 'drgnx-user-lisp-files raw))))

;;;; Commands

(defun drgnx-user-lisp-register-commands ()
  "Settings: Turn a Lisp File On or Off (on the Lisp files page) and Add Lisp File…, in the registry."
  (drgnx-command-define 'settings-lisp-files-toggle :category "Settings" :title "Turn a Lisp File On or Off"
                        :command #'drgnx-user-lisp-toggle
                        :map '(drgnx-settings-lisp-page . drgnx-settings-lisp-page-mode-map)
                        :when (lambda () (derived-mode-p 'drgnx-settings-lisp-page-mode))
                        :doc "Turn the Lisp file of this line on (loads now) or off (takes effect at the next start)")
  (drgnx-command-define 'settings-add-lisp-file :category "Settings" :title "Add Lisp File…"
                        :command #'drgnx-user-lisp-add-file
                        :map '(drgnx-settings-lisp-page . drgnx-settings-lisp-page-mode-map)
                        :doc "Add an existing init.el or other Lisp file without copying it: its early-init.el, findings, :emacs-dir"))

(if (featurep 'drgnx-registry)
    (drgnx-user-lisp-register-commands)
  (with-eval-after-load 'drgnx-registry (drgnx-user-lisp-register-commands)))

(provide 'drgnx-user-lisp)
;;; drgnx-user-lisp.el ends here
