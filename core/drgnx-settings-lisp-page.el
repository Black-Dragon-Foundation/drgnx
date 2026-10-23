;;; drgnx-settings-lisp-page.el --- Settings: the Lisp files page -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 28 (design §8.1): Settings: Lisp Files, a page of Settings that lists your Lisp files in load
;; order (the early files, custom.el, config.el, `drgnx-user-lisp-files', the files those loaded), then the data files
;; drgnx reads and never loads (settings.el, the workspace files).  A row says whether the file is on, whether it
;; loaded, how long that took and the error with its line, every setting it sets with its line and whether it won,
;; and the findings of the static index.  RET opens the file at the line; Settings: Move into Settings on a setting's
;; line moves it (drgnx-settings-move.el).  The rows come from `drgnx-settings-lisp-page-rows' (data, tested), drawn
;; on the user's action.  Until the Settings page (Task 26) links it, the page is its own command and buffer.
;; See docs/guide/settings.md, "Your Lisp files".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-config)
(require 'drgnx-settings-file)
(require 'drgnx-lisp-index)
(require 'drgnx-settings-prov)

(declare-function drgnx-settings-workspace-files "drgnx-settings-workspace" ())
(defvar drgnx-user-lisp-files)

(defvar drgnx-settings-lisp-page--loads (make-hash-table :test 'equal)
  "Truename of a Lisp file of yours → what its last load this session said: (:seconds :error :parent), as the loader
told `drgnx-settings-lisp-page-note-load'.  One entry per file, replaced at its next load.")

(cl-defun drgnx-settings-lisp-page-note-load (file &key seconds error parent)
  "Remember that your Lisp FILE loaded in SECONDS, with ERROR (its message) or none, loaded by PARENT (a file of
yours) or by drgnx.  The loader of your Lisp calls it (inside `drgnx-settings-prov-with-load', so an error's line is
the form being read when it happened).  Never signals."
  (condition-case nil
      (let ((line (and error (car (drgnx-settings-prov--form file)))))
        (puthash (file-truename file)
                 (list :seconds seconds :error (and error (list :text error :line line)) :parent parent)
                 drgnx-settings-lisp-page--loads))
    (error nil)))

;;;; The rows

(defun drgnx-settings-lisp-page--listed ()
  "`drgnx-user-lisp-files' as ((FILE . PLIST)…), FILE expanded in the config dir; nil while it is not defined."
  (let (out)
    (dolist (e (and (boundp 'drgnx-user-lisp-files) (listp drgnx-user-lisp-files) drgnx-user-lisp-files))
      (let ((f (if (consp e) (car e) e)))
        (when (stringp f)
          (push (cons (expand-file-name f (drgnx-user-dir)) (and (consp e) (plistp (cdr e)) (cdr e))) out))))
    (nreverse out)))

(defun drgnx-settings-lisp-page--loaded-files ()
  "The files `load-history' has, oldest first."
  (let (out)
    (dolist (e load-history) (when (stringp (car e)) (push (car e) out)))
    out))

(defun drgnx-settings-lisp-page--loaded-p (file loaded)
  "Non-nil when FILE (its .el or .elc) is among LOADED."
  (cl-some (lambda (f) (drgnx-settings-prov--same-file-p file f)) loaded))

(defun drgnx-settings-lisp-page--won (file line var)
  "Whether FILE's line LINE is what gives VAR its value: `won', `lost' (with the winner's source), or `unknown'
when provenance is not certain: (WON . SOURCE)."
  (let ((e (and (boundp var) (ignore-errors (drgnx-settings-explain var)))))
    (cond ((null e) (cons 'unknown nil))
          ((and (plist-get e :certain) (plist-get e :file) (drgnx-settings-prov--same-file-p file (plist-get e :file))
                (eql line (plist-get e :line)))
           (cons 'won (plist-get e :source)))
          ((plist-get e :certain) (cons 'lost (plist-get e :source)))
          (t (cons 'unknown (plist-get e :source))))))

(defun drgnx-settings-lisp-page--setting (file s)
  "The row of setter S of FILE: (:var :line :kind :conditional :won :source)."
  (let ((won (drgnx-settings-lisp-page--won file (plist-get s :line) (plist-get s :var))))
    (list :var (plist-get s :var) :line (plist-get s :line) :kind (plist-get s :kind)
          :conditional (plist-get s :conditional) :won (car won) :source (cdr won))))

(defun drgnx-settings-lisp-page--row (file role opts loaded)
  "The row of your Lisp FILE in ROLE, with OPTS (its `drgnx-user-lisp-files' plist); LOADED: the loaded files."
  (let* ((exists (file-exists-p file))
         (index (and exists (ignore-errors (drgnx-lisp-index-get file))))
         (rec (gethash (file-truename file) drgnx-settings-lisp-page--loads)))
    (list :file file :role role :exists exists :emacs-dir (plist-get opts :emacs-dir)
          :on (if (plist-member opts :on) (and (plist-get opts :on) t) t) :early (plist-get opts :early)
          :loaded (and exists (drgnx-settings-lisp-page--loaded-p file loaded) t)
          :seconds (plist-get rec :seconds) :error (plist-get rec :error) :parent (plist-get rec :parent)
          :settings (mapcar (lambda (s) (drgnx-settings-lisp-page--setting file s)) (plist-get index :setters))
          :findings (plist-get index :findings))))

(defun drgnx-settings-lisp-page--data-row (file head)
  "The row of the data FILE (a settings file of HEAD): its entries, each with its line; its problems as findings."
  (let* ((doc (ignore-errors (drgnx-settings-file-read file head)))
         (settings-p (eq head 'drgnx-settings)))
    (list :file file :role 'data :exists (and doc (drgnx-settings-doc-text doc) t)
          :settings (and doc
                         (mapcar (lambda (e)
                                   (let* ((var (drgnx-settings-entry-var e))
                                          (won (if (and settings-p (null (drgnx-settings-entry-scope e)) (symbolp var)
                                                        (not (keywordp var)))
                                                   (drgnx-settings-lisp-page--won file (drgnx-settings-entry-line e) var)
                                                 (cons 'unknown nil))))
                                     (list :var var :line (drgnx-settings-entry-line e) :scope (drgnx-settings-entry-scope e)
                                           :won (car won) :source (cdr won))))
                                 (drgnx-settings-doc-entries doc)))
          :findings (and doc (mapcar (lambda (p) (list :kind 'problem :line (plist-get p :line) :text (plist-get p :text)))
                                     (drgnx-settings-doc-problems doc))))))

(defun drgnx-settings-lisp-page-rows ()
  "The Lisp files page's rows, in load order: a list of plists.
Your Lisp: the early files of `drgnx-user-lisp-files' (`:early t'), custom.el (`custom-file'), config.el, the other
files of `drgnx-user-lisp-files', then the files in your config dir those loaded (from `load-history').  Each is
\(:file :role :exists :on :early :loaded :seconds :error :parent :settings :findings): ROLE `early', `custom',
`config', `listed' or `loaded'; ON from `drgnx-user-lisp-files' (default t); SECONDS, ERROR (:text :line) and PARENT
as the loader noted them (`drgnx-settings-lisp-page-note-load'); SETTINGS what the static index finds the file sets,
each (:var :line :kind :conditional :won :source) with WON `won', `lost' (SOURCE: the winner) or `unknown'; FINDINGS
the index's.  Then the data files, ROLE `data': settings.el and the workspace files read this session, their
entries as settings and their problems as findings."
  (let* ((dir (drgnx-user-dir))
         (listed (drgnx-settings-lisp-page--listed))
         (loaded (drgnx-settings-lisp-page--loaded-files))
         (opts (lambda (file) (cdr (cl-find-if (lambda (l) (drgnx-settings-prov--same-file-p (car l) file)) listed))))
         (custom (expand-file-name (or (bound-and-true-p custom-file) "custom.el") dir))
         (config (expand-file-name "config.el" dir))
         (settings (drgnx-config-file 'settings))
         (rows (append
                (cl-loop for (f . o) in listed when (plist-get o :early)
                         collect (drgnx-settings-lisp-page--row f 'early o loaded))
                (list (drgnx-settings-lisp-page--row custom 'custom (funcall opts custom) loaded)
                      (drgnx-settings-lisp-page--row config 'config (funcall opts config) loaded))
                (cl-loop for (f . o) in listed
                         unless (or (plist-get o :early) (drgnx-settings-prov--same-file-p f custom)
                                    (drgnx-settings-prov--same-file-p f config))
                         collect (drgnx-settings-lisp-page--row f 'listed o loaded))))
         (seen (mapcar (lambda (r) (plist-get r :file)) rows))
         (more nil))
    (dolist (f loaded)
      (let ((el (drgnx-settings-prov--source-file f)))
        (when (and (file-in-directory-p el dir)
                   (not (drgnx-settings-prov--same-file-p el settings))
                   (not (cl-some (lambda (s) (drgnx-settings-prov--same-file-p el s)) (append seen more))))
          (push el more))))
    (append rows
            (mapcar (lambda (f) (drgnx-settings-lisp-page--row f 'loaded nil loaded)) (nreverse more))
            (list (drgnx-settings-lisp-page--data-row settings 'drgnx-settings))
            (mapcar (lambda (f) (drgnx-settings-lisp-page--data-row f 'drgnx-workspace-settings))
                    (and (fboundp 'drgnx-settings-workspace-files) (ignore-errors (drgnx-settings-workspace-files)))))))

;;;; Drawing

(defconst drgnx-settings-lisp-page--roles
  '((early . "early file, loaded at the end of early-init.el") (custom . "what Customize saved")
    (config . "your config") (listed . "your Lisp file") (loaded . "loaded by your Lisp")
    (data . "data: read, never loaded"))
  "What each role is called on the page.")

(defconst drgnx-settings-lisp-page--findings
  '((custom-file . "moves custom-file") (user-emacs-directory . "changes user-emacs-directory")
    (emacs-dir-use . "uses user-emacs-directory")
    (buffer-local-setq . "a setq of a buffer-local variable sets only the buffer it runs in (setq-default?)")
    (problem . "a problem"))
  "What each finding kind is called on the page.")

(defun drgnx-settings-lisp-page--state (row)
  "ROW's state line text: on/off, loaded, time, error."
  (if (eq (plist-get row :role) 'data) (if (plist-get row :exists) "" "not there")
    (string-join
     (delq nil (list (if (plist-get row :on) "on" "off (at the next start)")
                     (cond ((not (plist-get row :exists)) "not there")
                           ((plist-get row :loaded)
                            (concat "loaded" (if (plist-get row :seconds)
                                                 (format " in %d ms" (round (* 1000 (plist-get row :seconds))))
                                               "")))
                           (t "not loaded"))
                     (when-let* ((p (plist-get row :parent))) (format "by %s" (file-name-nondirectory p)))
                     (when-let* ((d (plist-get row :emacs-dir)))
                       (format "user-emacs-directory is %s only while it loads (a setq of it is undone afterwards; \
what loads later sees drgnx's)" d))))
     " · ")))

(defun drgnx-settings-lisp-page--put (beg file line &optional var)
  "Mark the text from BEG to point as FILE's LINE (and VAR's, for a setting)."
  (put-text-property beg (point) 'drgnx-settings-lisp-page-at (cons file line))
  (when var (put-text-property beg (point) 'drgnx-settings-lisp-page-var var)))

(defun drgnx-settings-lisp-page--insert-row (row)
  "Insert ROW's lines at point."
  (let ((file (plist-get row :file)) (beg (point)))
    (insert (propertize (abbreviate-file-name file) 'face 'bold)
            (propertize (format "  %s" (alist-get (plist-get row :role) drgnx-settings-lisp-page--roles)) 'face 'shadow))
    (let ((state (drgnx-settings-lisp-page--state row)))
      (unless (string-empty-p state) (insert "  " state)))
    (insert "\n")
    (drgnx-settings-lisp-page--put beg file 1)
    (when-let* ((err (plist-get row :error)))
      (setq beg (point))
      (insert (propertize (format "    error%s: %s\n" (if (plist-get err :line) (format " at line %d" (plist-get err :line)) "")
                                  (plist-get err :text))
                          'face 'error))
      (drgnx-settings-lisp-page--put beg file (plist-get err :line)))
    (let ((settings (plist-get row :settings)))
      (when settings
        (insert (propertize (format "    sets %d:\n" (length settings)) 'face 'shadow)))
      (dolist (s settings)
        (setq beg (point))
        (insert (format "      %-32s line %-5s %s%s\n" (plist-get s :var) (plist-get s :line)
                        (pcase (plist-get s :won)
                          ('won (propertize "won" 'face 'success))
                          ('lost (propertize (format "lost to %s" (plist-get s :source)) 'face 'warning))
                          (_ (propertize "?" 'face 'shadow)))
                        (if (plist-get s :conditional) (propertize "  (conditional)" 'face 'shadow) "")))
        (drgnx-settings-lisp-page--put beg file (plist-get s :line) (and (not (plist-get s :scope)) (plist-get s :var)))))
    (dolist (f (plist-get row :findings))
      (setq beg (point))
      (insert (propertize (format "    ! line %s: %s: %s\n" (plist-get f :line)
                                  (or (alist-get (plist-get f :kind) drgnx-settings-lisp-page--findings) (plist-get f :kind))
                                  (plist-get f :text))
                          'face 'warning))
      (drgnx-settings-lisp-page--put beg file (plist-get f :line)))
    (insert "\n")))

(defun drgnx-settings-lisp-page--draw ()
  "Draw the page in the current buffer, point kept on its line."
  (let ((inhibit-read-only t) (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize "Your Lisp files, in load order, then the data files drgnx reads\n" 'face 'bold)
            (propertize "RET opens a file at the line.  On a setting's line, Settings: Move into Settings moves it into \
settings.el.  t turns the file of the line on (loads now) or off (from the next start); a adds a file.\n\n" 'face 'shadow))
    (mapc #'drgnx-settings-lisp-page--insert-row (drgnx-settings-lisp-page-rows))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun drgnx-settings-lisp-page--revert (&rest _)
  "`revert-buffer-function' of the page: draw it again."
  (drgnx-settings-lisp-page--draw))

(defvar-keymap drgnx-settings-lisp-page-mode-map
  :doc "The Lisp files page's keys: the key profiles bind its commands here (keys/*.eld)."
  :parent special-mode-map)

(define-derived-mode drgnx-settings-lisp-page-mode special-mode "Lisp Files"
  "Settings: Lisp Files, your Lisp files and what they set."
  (buffer-disable-undo)
  (setq-local revert-buffer-function #'drgnx-settings-lisp-page--revert))

;;;; Commands

(defun drgnx-settings-lisp-files ()
  "Settings: Lisp Files: your Lisp files in load order, what each sets at which line and whether it won, its findings,
then the data files.  The buffer."
  (interactive)
  (let ((buf (get-buffer-create "*drgnx Lisp files*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'drgnx-settings-lisp-page-mode) (drgnx-settings-lisp-page-mode))
      (drgnx-settings-lisp-page--draw))
    (when (called-interactively-p 'any) (pop-to-buffer buf))
    buf))

(defun drgnx-settings-lisp-page-open ()
  "Open the file of the Lisp files page's line at point, at its line.  The file's buffer."
  (interactive)
  (let ((at (get-text-property (point) 'drgnx-settings-lisp-page-at)))
    (unless at (user-error "Settings: no file on this line"))
    (with-current-buffer (find-file (car at))
      (when (cdr at)
        (goto-char (point-min))
        (forward-line (1- (cdr at))))
      (current-buffer))))

(provide 'drgnx-settings-lisp-page)
;;; drgnx-settings-lisp-page.el ends here
