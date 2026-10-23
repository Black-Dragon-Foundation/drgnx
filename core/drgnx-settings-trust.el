;;; drgnx-settings-trust.el --- Settings: workspace trust -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 18 (design §9, §13, decisions 7 and 11; docs/develop/settings.md, "Workspace trust").
;; Which workspace entries apply depends on the entry's class and the workspace's state.
;; - Classes (`drgnx-settings-trust-class'): `never' (the deny-list, and `ignored-local-variables'), `code' (an
;;   `:eval' section, an `eval' or `mode' entry, every value of a `:workspace code' setting), `safe' (its
;;   `safe-local-variable' predicate passes), else `data'.
;; - States (`drgnx-settings-trust-state'): `untrusted' (the default), `location' (under a folder of
;;   `drgnx-trust-parents'), `trusted' (Trust This Folder), `everything' (a `drgnx-trust-parents' entry with :code t).
;; - In a trusted workspace (location, trusted) safe values and data apply, and code applies per allowed pair
;;   (FILE VAR VALUE), kept per root in trusted-folders.eld (version 2, `:allowed'); a new or changed pair waits, a
;;   denied one is ignored.  `everything' applies code with no review.  Untrusted: W1 applies safe values only, and
;;   `.dir-locals*.el' are Emacs's own (the stock prompt on an interactive open).
;; - How: an `:around' advice on `hack-dir-local--get-variables' (the stock .dir-locals source) splits its item in a
;;   trusted workspace and marks what applies (`drgnx-settings-workspace-mark'), so the stock filter applies it with
;;   no prompt; W1 goes through `drgnx-settings-trust-filter'.  No root ever goes into
;;   `safe-local-variable-directories' and nothing is written to `safe-local-variable-values'.
;; - drgnx's security settings are marked risky and kept in `ignored-local-variables', so no dir-local or file-local
;;   spec sets them; drgnx reads them with `default-value'.
;; Nothing here prompts in an automatic path, and the hook functions never signal.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-setting)
(require 'drgnx-settings-file)
(require 'drgnx-trust)

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-settings-review--schedule "drgnx-settings-review" (root))
(declare-function drgnx-settings-workspace-rehack"drgnx-settings-workspace" (root))
(declare-function drgnx-settings-workspace-mark "drgnx-settings-workspace" (dir))
(declare-function drgnx-settings-workspace--usable "drgnx-settings-workspace" (file))

(defvar drgnx-settings-workspace-shared-file)

;;;; Trusted locations

(drgnx-defsetting drgnx-trust-parents nil
  "Folders whose projects are trusted for data: their workspace settings apply, and their code waits for Review
and Allow.  Each entry is (\"DIR/\") or (\"DIR/\" :code t); :code t trusts everything below DIR, code included, with
no review (and puts DIR into `trusted-content').  A remote folder, your home folder, `/', the temp folders and their
ancestors are never trusted.  Agents can never change it, and no workspace sets it."
  :type '(repeat (cons (directory :tag "Folder") (plist :tag "Options" :options ((:code boolean)))))
  :group 'drgnx :risky t
  :scope 'global :workspace 'never :agents 'never :on-error 'strict
  :apply #'drgnx-settings-trust--parents-apply)

(defun drgnx-settings-trust--norm (dir)
  "DIR as roots are compared: an absolute truename ending in a slash (DIR is local)."
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun drgnx-settings-trust--parents ()
  "The usable entries of `drgnx-trust-parents' (its default value) as ((DIR . CODE)…), DIR normalized and CODE t
for :code t.  Remote, broad (`drgnx-trust--broad-p') and malformed entries are left out."
  (let ((value (default-value 'drgnx-trust-parents)))
    (delq nil (mapcar (lambda (e)
                        (condition-case nil
                            (let ((dir (car-safe e)))
                              (when (and (stringp dir) (not (file-remote-p dir)) (plistp (cdr e)))
                                (let* ((file-name-handler-alist nil) (d (drgnx-settings-trust--norm dir)))
                                  (unless (drgnx-trust--broad-p d) (cons d (and (plist-get (cdr e) :code) t))))))
                          (error nil)))
                      (and (proper-list-p value) value)))))

;;;; trusted-folders.eld: the folders, the pairs and the exceptions

(defvar drgnx-settings-trust--data nil
  "(STAMP . DATA): trusted-folders.eld as last read, DATA nil when it is missing or cannot be used.")

(defun drgnx-settings-trust--state-data ()
  "trusted-folders.eld's plist, read again when its stamp changed; nil when there is none or it cannot be used (a
mistake or a newer drgnx's: then nothing in it is trusted or allowed)."
  (let* ((file (drgnx-trust-folders-file)) (stamp (drgnx-file-stamp file)))
    (if (and stamp drgnx-settings-trust--data (equal (car drgnx-settings-trust--data) stamp))
        (cdr drgnx-settings-trust--data)
      (let* ((r (drgnx-file-read file)) (data (plist-get r :data))
             (ok (and (eq (plist-get r :status) 'ok) (listp (drgnx-trust--folders-of data)) data)))
        (setq drgnx-settings-trust--data (cons stamp ok))
        ok))))

(defun drgnx-settings-trust--unkey (key)
  "A root as trusted-folders.eld keeps it (abbreviated) back as roots are compared."
  (file-name-as-directory (expand-file-name key)))

(defun drgnx-settings-trust--folders ()
  "The folders of Trust This Folder, normalized: those `drgnx-trust--read-entry-p' accepts."
  (delq nil (mapcar (lambda (f) (and (drgnx-trust--read-entry-p f) (ignore-errors (drgnx-settings-trust--norm f))))
                    (plist-get (drgnx-settings-trust--state-data) :folders))))

(defun drgnx-settings-trust--root-pairs (slot root &optional data)
  "The pairs DATA (default: trusted-folders.eld's) keeps under SLOT (`:allowed' or `:denied') for ROOT: ((FILE VAR
TEXT)…)."
  (cl-loop for entry in (plist-get (or data (drgnx-settings-trust--state-data)) slot)
           when (equal (drgnx-settings-trust--unkey (car entry)) root) append (cdr entry)))

(defun drgnx-settings-trust--text (value)
  "VALUE as an allowed pair keeps it: its printed text, whatever the user's print settings (a value need not be
plain data: an `eval' form may hold a backquote)."
  (let ((print-length nil) (print-level nil) (print-circle nil) (print-escape-newlines nil) (print-quoted t)
        (print-escape-nonascii nil) (print-escape-multibyte nil) (print-escape-control-characters nil)
        (print-integers-as-characters nil) (float-output-format nil))
    (prin1-to-string value)))

(defun drgnx-settings-trust--pair (p)
  "P, a pair (FILE VAR VALUE) or a plist with :file :var :value, as (FILE VAR TEXT)."
  (if (keywordp (car-safe p))
      (list (plist-get p :file) (plist-get p :var) (drgnx-settings-trust--text (plist-get p :value)))
    (list (nth 0 p) (nth 1 p) (drgnx-settings-trust--text (nth 2 p)))))

;;;; Roots and states

(defconst drgnx-settings-trust-root-markers '(".git" ".hg" ".jj" ".svn" ".bzr" "_darcs" ".fslckout")
  "What marks a project's root for workspace trust: a version-control folder or file.")

(defun drgnx-settings-trust--marked-p (dir)
  "Does DIR hold one of `drgnx-settings-trust-root-markers'?"
  (seq-some (lambda (m) (file-exists-p (expand-file-name m dir))) drgnx-settings-trust-root-markers))

(defun drgnx-settings-trust-root (dir)
  "The workspace DIR belongs to, normalized: the longest folder of Trust This Folder holding DIR, else the nearest
folder at or above DIR holding one of `drgnx-settings-trust-root-markers' (unless that is broad: home, `/', a temp
folder), else DIR.  Nil for a remote DIR.  Allowed pairs are kept per root."
  (unless (or (null dir) (file-remote-p dir))
    (let* ((dir (drgnx-settings-trust--norm dir))
           (folder (car (sort (seq-filter (lambda (f) (string-prefix-p f dir)) (drgnx-settings-trust--folders))
                              (lambda (a b) (> (length a) (length b)))))))
      (or folder
          (when-let* ((vc (locate-dominating-file dir #'drgnx-settings-trust--marked-p)))
            (let ((r (drgnx-settings-trust--norm vc))) (unless (drgnx-trust--broad-p r) r)))
          dir))))

(defun drgnx-settings-trust--buffer-root ()
  "The workspace root of the current buffer (its file's folder, else `default-directory'), or nil."
  (ignore-errors
    (drgnx-settings-trust-root (if buffer-file-name (file-name-directory buffer-file-name) default-directory))))

(defun drgnx-settings-trust-state (root)
  "The trust state of the workspace ROOT: `untrusted' (the default, a remote root, and a root you untrusted),
`everything' (below a `drgnx-trust-parents' entry with :code t), `trusted' (below a folder of Trust This Folder) or
`location' (below another `drgnx-trust-parents' entry), checked in that order."
  (if (or (null root) (file-remote-p root)) 'untrusted
    (let* ((root (drgnx-settings-trust--norm root))
           (data (drgnx-settings-trust--state-data))
           (parents (drgnx-settings-trust--parents))
           (under (lambda (dirs) (seq-some (lambda (d) (string-prefix-p d root)) dirs))))
      (cond ((member root (mapcar #'drgnx-settings-trust--unkey (plist-get data :untrusted))) 'untrusted)
            ((funcall under (mapcar #'car (seq-filter #'cdr parents))) 'everything)
            ((funcall under (drgnx-settings-trust--folders)) 'trusted)
            ((funcall under (mapcar #'car parents)) 'location)
            (t 'untrusted)))))

;;;; Classes

(defun drgnx-settings-trust-security-settings ()
  "drgnx's security settings: its own settings declared `:workspace never' or `:agents never', and
`drgnx-user-lisp-files' and `drgnx-trust-parents' (the deny-list of design §13 that drgnx declares)."
  (cl-union (cl-remove-if-not (lambda (v) (let ((m (drgnx-setting-meta v)))
                                            (or (eq (plist-get m :workspace) 'never) (eq (plist-get m :agents) 'never))))
                              (drgnx-setting-names))
            '(drgnx-user-lisp-files drgnx-trust-parents)))

(defun drgnx-settings-trust-class (var value &optional source)
  "The class of a workspace entry setting VAR to VALUE: `never', `code', `safe' or `data' (design §9).
`never': VAR is in `ignored-local-variables' or its setting is `:workspace never'.  `code': an `:eval' section, an
`eval' or `mode' entry, or any value of a `:workspace code' setting (risky, program-naming, function and hook
settings).  `safe': VALUE passes VAR's `safe-local-variable' predicate (or the setting is `:workspace safe').  Else
`data'.  SOURCE is where the entry is: `dir-locals', `shared' (W1) or `private' (W2, your file: never classed, so
`safe' unless `never')."
  (cond ((memq var '(:eval eval mode)) (if (eq source 'private) 'safe 'code))
        ((memq var (default-value 'ignored-local-variables)) 'never)
        (t (let ((ws (plist-get (drgnx-setting-meta var) :workspace)))
             (cond ((eq ws 'never) 'never)
                   ((eq source 'private) 'safe)
                   ((eq ws 'code) 'code)
                   ((or (eq ws 'safe) (safe-local-variable-p var value)) 'safe)
                   (t 'data))))))

(defun drgnx-settings-trust--decide (state root file var value &optional data)
  "What becomes of a code entry (FILE VAR VALUE) in the workspace ROOT in STATE: `apply', `wait' or `deny'."
  (pcase state
    ('everything 'apply)
    ((or 'location 'trusted)
     (let ((pair (list file var (drgnx-settings-trust--text value))))
       (cond ((member pair (drgnx-settings-trust--root-pairs :allowed root data)) 'apply)
             ((member pair (drgnx-settings-trust--root-pairs :denied root data)) 'deny)
             (t 'wait))))
    (_ 'wait)))

;;;; What waits, and the first notice of a location

(defvar drgnx-settings-trust--waiting (make-hash-table :test 'equal)
  "ROOT -> the entries seen waiting there this session (plists, newest first), so that the code of a subfolder's
.dir-locals.el is listed too.  Emptied past `drgnx-settings-trust--waiting-max' roots.")

(defconst drgnx-settings-trust--waiting-max 128 "The most roots `drgnx-settings-trust--waiting' keeps.")

(defun drgnx-settings-trust--note (root item)
  "Remember ITEM (a plist :file :var :value :line :class) as waiting in ROOT this session."
  (when (>= (hash-table-count drgnx-settings-trust--waiting) drgnx-settings-trust--waiting-max)
    (clrhash drgnx-settings-trust--waiting))
  (let ((items (gethash root drgnx-settings-trust--waiting)))
    (unless (cl-find-if (lambda (i) (drgnx-settings-trust--same-p i item)) items)
      (puthash root (cons item items) drgnx-settings-trust--waiting)
      ;; the quiet path (Task 19): one notice per workspace and session, posted after the filters ran
      (when (or (fboundp 'drgnx-settings-review--schedule) (require 'drgnx-settings-review nil t))
        (drgnx-settings-review--schedule root)))))

(defun drgnx-settings-trust--same-p (a b)
  "Do the waiting items A and B name the same pair?"
  (and (equal (plist-get a :file) (plist-get b :file)) (eq (plist-get a :var) (plist-get b :var))
       (equal (plist-get a :value) (plist-get b :value))))

(defvar drgnx-settings-trust--announced nil "The roots trusted by location that were announced this session.")

(defun drgnx-settings-trust--announced-roots (data)
  "The roots DATA (trusted-folders.eld's plist) keeps under `:announced', normalized; anything else there is ignored."
  (let ((a (plist-get data :announced)))
    (and (proper-list-p a) (mapcar #'drgnx-settings-trust--unkey (seq-filter #'stringp a)))))

(defun drgnx-settings-trust--announced-p (root)
  "Was ROOT's trust by location announced: this session, or on this machine before (trusted-folders.eld's
`:announced', the roots it keeps abbreviated)?"
  (or (member root drgnx-settings-trust--announced)
      (member root (drgnx-settings-trust--announced-roots (drgnx-settings-trust--state-data)))))

(defun drgnx-settings-trust--announce (root)
  "The first time on this machine ROOT is trusted by its location: one information notice, with [Untrust].  The root
is kept in trusted-folders.eld (`:announced'), so the notice does not come back at the next start.  Never signals."
  (unless (drgnx-settings-trust--announced-p root)
    (push root drgnx-settings-trust--announced)
    (condition-case nil
        (drgnx-trust-update
         (lambda (data)
           (if (member root (drgnx-settings-trust--announced-roots data)) data
             (let ((a (plist-get data :announced)))
               (plist-put data :announced (append (and (proper-list-p a) (seq-filter #'stringp a))
                                                  (list (abbreviate-file-name root))))))))
      (error nil))
    (condition-case nil
        (when (require 'drgnx-notice nil t)
          (let ((parent (seq-find (lambda (d) (string-prefix-p d root)) (mapcar #'car (drgnx-settings-trust--parents)))))
            (drgnx-notify 'config 'info
                          (format "%s is trusted for data: it is below %s (drgnx-trust-parents); its code waits for review"
                                  (abbreviate-file-name root) (abbreviate-file-name (or parent "a trusted location")))
                          :id (concat "trust-location:" root)
                          :command (list 'drgnx-settings-trust-untrust (abbreviate-file-name root)))))
      (error nil))))

;;;; The split: .dir-locals.el and .dir-locals-2.el in a trusted workspace

(defun drgnx-settings-trust--read-dir-locals (file)
  "FILE's alist, read as Emacs reads a .dir-locals file (no circular data), or nil."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (let* ((read-circle nil) (x (read (current-buffer)))) (and (listp x) x)))
    (error nil)))

(defun drgnx-settings-trust--line (file var value)
  "The line of FILE (a .dir-locals file) whose entry sets VAR to VALUE: the first `(VAR' that reads as (VAR .
VALUE), else the first `(VAR'; nil when there is none."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (let ((re (concat "(\\s-*" (regexp-quote (symbol-name var)) "\\_>")) (first nil) (found nil))
          (while (and (not found) (re-search-forward re nil t))
            (let ((pos (match-beginning 0)))
              (unless first (setq first pos))
              (when (equal (ignore-errors (save-excursion (goto-char pos) (let ((read-circle nil)) (read (current-buffer)))))
                           (cons var value))
                (setq found pos))))
          (when-let* ((pos (or found first))) (line-number-at-pos pos t))))
    (error nil)))

(defun drgnx-settings-trust--sources (dir)
  "DIR's .dir-locals files, highest priority first, each (FILE . VARIABLES): what it gives the current buffer."
  (mapcar (lambda (file)
            (cons file (ignore-errors (dir-locals-collect-variables (drgnx-settings-trust--read-dir-locals file) dir nil))))
          (reverse (dir-locals--all-files dir))))

(defun drgnx-settings-trust--source-of (sources elt)
  "The file of SOURCES that gives ELT (VAR . VALUE), the first of them when none does."
  (car (or (cl-find-if (lambda (s) (member elt (cdr s))) sources) (car sources))))

(defun drgnx-settings-trust--split (res)
  "Split RES, the (DIR . ALIST) of `hack-dir-local--get-variables', by the trust of DIR's workspace.  Untrusted, or
no .dir-locals file at DIR (a class set from Lisp): RES as it is.  Else a marked item (DIR . KEPT): safe values,
data, and code that applies (`drgnx-settings-trust--decide'); the code that waits is remembered, `never' entries are
dropped."
  (let ((dir (car-safe res)) (alist (cdr-safe res)))
    (if (or (not (stringp dir)) (null alist) (file-remote-p dir)) res
      (let* ((root (drgnx-settings-trust-root dir))
             (state (drgnx-settings-trust-state root))
             (files (and (not (eq state 'untrusted)) (dir-locals--all-files dir))))
        (if (null files) res
          (when (eq state 'location) (drgnx-settings-trust--announce root))
          (let ((kept nil) (sources nil) (data (drgnx-settings-trust--state-data)))
            (dolist (elt alist)
              (let ((class (drgnx-settings-trust-class (car elt) (cdr elt) 'dir-locals)))
                (pcase class
                  ('never nil)
                  ('code
                   (let* ((srcs (or sources (setq sources (drgnx-settings-trust--sources dir))))
                          (file (drgnx-settings-trust--source-of srcs elt))
                          (rel (file-relative-name (file-truename file) root)))
                     (pcase (drgnx-settings-trust--decide state root rel (car elt) (cdr elt) data)
                       ('apply (push elt kept))
                       ('wait (drgnx-settings-trust--note
                               root (list :file rel :var (car elt) :value (cdr elt) :class 'code
                                          :line (drgnx-settings-trust--line file (car elt) (cdr elt))))))))
                  (_ (push elt kept)))))
            (cons (drgnx-settings-workspace-mark dir) (nreverse kept))))))))

(defun drgnx-settings-trust--split-around (fn &optional predicate)
  "Around `hack-dir-local--get-variables' (FN): its result split by `drgnx-settings-trust--split'.  A call with a
PREDICATE (`set-auto-mode' asking for `auto-mode-alist') is left alone.  Never signals: on an error, Emacs's own
result (stock behaviour), with a config notice."
  (let ((res (funcall fn predicate)))
    (if predicate res
      (condition-case err (drgnx-settings-trust--split res)
        (error (drgnx-settings-file--warn
                (format "Workspace trust: %s; directory-local variables apply as in plain Emacs"
                        (error-message-string err)))
               res)))))

;;;; The shared file (W1)

(defun drgnx-settings-trust-filter (root file entries)
  "The `drgnx-settings-workspace-filter-function' of workspace trust: which ENTRIES of the shared FILE of ROOT apply.
Untrusted: safe values only.  Trusted by location or Trust This Folder: safe values, data, and code (`:eval' sections,
`:workspace code' settings) whose pair is allowed.  `everything': all.  What waits is remembered."
  (let* ((root (or (drgnx-settings-trust-root root) root))
         (state (drgnx-settings-trust-state root))
         (rel (file-relative-name file root))
         (data (drgnx-settings-trust--state-data))
         (kept nil))
    (when (eq state 'location) (drgnx-settings-trust--announce root))
    (dolist (e entries)
      (let* ((var (drgnx-settings-entry-var e)) (value (drgnx-settings-entry-value e))
             (class (drgnx-settings-trust-class var value 'shared))
             (item (list :file rel :var var :value value :line (drgnx-settings-entry-line e) :class class)))
        (pcase class
          ('safe (push e kept))
          ('data (if (eq state 'untrusted) (drgnx-settings-trust--note root item) (push e kept)))
          ('code (pcase (drgnx-settings-trust--decide state root rel var value data)
                   ('apply (push e kept))
                   ('wait (drgnx-settings-trust--note root item)))))))
    (nreverse kept)))

;;;; What a workspace holds, and what waits there

(defun drgnx-settings-trust--dir-locals-leaves (alist)
  "Every (VAR . VALUE) of a .dir-locals ALIST, in all of its sections (modes, subfolders), but `subdirs'."
  (let ((out nil))
    (cl-labels ((walk (sections)
                  (dolist (s (and (proper-list-p sections) sections))
                    (when (consp s)
                      (if (stringp (car s)) (walk (cdr s))
                        (dolist (pair (and (proper-list-p (cdr s)) (cdr s)))
                          (when (and (consp pair) (symbolp (car pair)) (not (eq (car pair) 'subdirs)))
                            (push pair out))))))))
      (walk alist))
    (nreverse out)))

(defun drgnx-settings-trust--shared-items (root)
  "The entries of ROOT's .drgnx/settings.el that are not refused, as plists (:file :var :value :line :class)."
  (let ((file (expand-file-name (or (bound-and-true-p drgnx-settings-workspace-shared-file) ".drgnx/settings.el") root)))
    (when (and (fboundp 'drgnx-settings-workspace--usable) (file-exists-p file))
      (mapcar (lambda (e)
                (let ((var (drgnx-settings-entry-var e)) (value (drgnx-settings-entry-value e)))
                  (list :file (file-relative-name file root) :var var :value value :line (drgnx-settings-entry-line e)
                        :class (drgnx-settings-trust-class var value 'shared))))
              (car (drgnx-settings-workspace--usable file))))))

(defun drgnx-settings-trust-code-pairs (root)
  "The code in the workspace ROOT's own files now, as plists (:file :var :value :line :class code), FILE relative to
ROOT: every code entry of ROOT/.dir-locals.el and ROOT/.dir-locals-2.el (all of their sections) and of
ROOT/.drgnx/settings.el.  What Trust This Folder shows and allows."
  (let ((root (drgnx-settings-trust--norm root)) (out nil))
    (dolist (file (dir-locals--all-files root))
      (dolist (pair (drgnx-settings-trust--dir-locals-leaves (drgnx-settings-trust--read-dir-locals file)))
        (when (eq (drgnx-settings-trust-class (car pair) (cdr pair) 'dir-locals) 'code)
          (let ((item (list :file (file-relative-name file root) :var (car pair) :value (cdr pair)
                            :line (drgnx-settings-trust--line file (car pair) (cdr pair)) :class 'code)))
            (unless (cl-find-if (lambda (i) (drgnx-settings-trust--same-p i item)) out) (push item out))))))
    (append (nreverse out)
            (seq-filter (lambda (i) (eq (plist-get i :class) 'code)) (drgnx-settings-trust--shared-items root)))))

(defun drgnx-settings-trust--was (root item data)
  "For a changed pair: the value ROOT's allowed pair of ITEM's file and variable holds (not for `eval' and `:eval',
which a file may hold many of), as (VALUE); nil when there is none."
  (unless (memq (plist-get item :var) '(eval :eval))
    (when-let* ((p (cl-find-if (lambda (p) (and (equal (nth 0 p) (plist-get item :file)) (eq (nth 1 p) (plist-get item :var))))
                               (drgnx-settings-trust--root-pairs :allowed root data))))
      (ignore-errors (list (car (read-from-string (nth 2 p))))))))

(defun drgnx-settings-trust-waiting (root)
  "What waits in the workspace ROOT now, as plists (:file :var :value :line :class), FILE relative to ROOT, with
:was VALUE for a changed pair (the value allowed before).  Trusted by location or Trust This Folder: each code entry
neither allowed nor denied, of ROOT's own files (`drgnx-settings-trust-code-pairs') and of any .dir-locals file below
ROOT seen this session.  Untrusted: the shared file's data and code entries (they wait for trust).  `everything':
nothing."
  (let* ((root (drgnx-settings-trust--norm root))
         (state (drgnx-settings-trust-state root))
         (data (drgnx-settings-trust--state-data))
         (out nil))
    (pcase state
      ('untrusted
       (setq out (seq-filter (lambda (i) (memq (plist-get i :class) '(data code))) (drgnx-settings-trust--shared-items root))))
      ((or 'location 'trusted)
       (dolist (item (append (drgnx-settings-trust-code-pairs root)
                             (reverse (gethash root drgnx-settings-trust--waiting))))
         (when (and (eq (plist-get item :class) 'code)
                    (eq (drgnx-settings-trust--decide state root (plist-get item :file) (plist-get item :var)
                                                      (plist-get item :value) data)
                        'wait)
                    (not (cl-find-if (lambda (i) (drgnx-settings-trust--same-p i item)) out)))
           (push (if-let* ((was (drgnx-settings-trust--was root item data))) (append item (list :was (car was))) item)
                 out)))
       (setq out (nreverse out))))
    out))

;;;; Allow, deny, trust, untrust

(defun drgnx-settings-trust--put-pairs (data slot root pairs)
  "DATA with PAIRS ((FILE VAR TEXT)…) added under SLOT for ROOT."
  (let* ((key (abbreviate-file-name root))
         (entries (cl-remove-if (lambda (e) (equal (drgnx-settings-trust--unkey (car e)) root)) (plist-get data slot)))
         (old (drgnx-settings-trust--root-pairs slot root data))
         (new (append (cl-remove-if (lambda (p) (member p pairs)) old) pairs)))
    (plist-put data slot (if new (append entries (list (cons key new))) entries))))

(defun drgnx-settings-trust--drop-pairs (data slot root pred)
  "DATA without ROOT's pairs under SLOT for which PRED is non-nil (all of them when PRED is t)."
  (let* ((entries (cl-remove-if (lambda (e) (equal (drgnx-settings-trust--unkey (car e)) root)) (plist-get data slot)))
         (left (and (not (eq pred t)) (cl-remove-if pred (drgnx-settings-trust--root-pairs slot root data)))))
    (plist-put data slot (if left (append entries (list (cons (abbreviate-file-name root) left))) entries))))

(defun drgnx-settings-trust--forget-waiting (root pairs)
  "Take PAIRS ((FILE VAR TEXT)…) out of what ROOT was seen waiting for."
  (puthash root (cl-remove-if (lambda (i) (member (drgnx-settings-trust--pair i) pairs))
                              (gethash root drgnx-settings-trust--waiting))
           drgnx-settings-trust--waiting))

(defun drgnx-settings-trust--rehack (root)
  "ROOT's open buffers apply their workspace values again (never signals)."
  (when (fboundp 'drgnx-settings-workspace-rehack) (drgnx-settings-workspace-rehack root)))

(defun drgnx-settings-trust-allow (root pairs)
  "Allow PAIRS in the workspace ROOT and apply them at once in its open buffers.  Each pair is (FILE VAR VALUE),
FILE relative to ROOT, or a plist with :file :var :value (as `drgnx-settings-trust-waiting' gives them).  They are
kept in trusted-folders.eld; a pair no longer denied, and for a variable other than `eval' and `:eval' an allowed
value of the same file and variable is replaced.  An allowed pair applies while ROOT is trusted (by location or
Trust This Folder) and its value is unchanged.  Returns ROOT."
  (let* ((root (drgnx-settings-trust--norm root))
         (pairs (mapcar #'drgnx-settings-trust--pair pairs))
         (single (cl-remove-if (lambda (p) (memq (nth 1 p) '(eval :eval))) pairs)))
    (drgnx-trust-update
     (lambda (data)
       (let ((data (drgnx-settings-trust--drop-pairs
                    data :allowed root
                    (lambda (p) (cl-find-if (lambda (s) (and (equal (car s) (car p)) (eq (nth 1 s) (nth 1 p))
                                                             (not (equal s p))))
                                            single)))))
         (setq data (drgnx-settings-trust--drop-pairs data :denied root (lambda (p) (member p pairs))))
         (drgnx-settings-trust--put-pairs data :allowed root pairs))))
    (drgnx-settings-trust--forget-waiting root pairs)
    (drgnx-settings-trust--rehack root)
    root))

(defun drgnx-settings-trust-deny (root pairs)
  "Deny PAIRS (as `drgnx-settings-trust-allow' takes them) in the workspace ROOT: remembered in trusted-folders.eld
and ignored silently from now on (no longer allowed, if they were); ROOT's open buffers apply that at once.
Returns ROOT."
  (let ((root (drgnx-settings-trust--norm root)) (pairs (mapcar #'drgnx-settings-trust--pair pairs)))
    (drgnx-trust-update
     (lambda (data)
       (drgnx-settings-trust--put-pairs (drgnx-settings-trust--drop-pairs data :allowed root (lambda (p) (member p pairs)))
                                        :denied root pairs)))
    (drgnx-settings-trust--forget-waiting root pairs)
    (drgnx-settings-trust--rehack root)
    root))

(defun drgnx-settings-trust--show (root pairs)
  "Show PAIRS, the code in ROOT that Trust This Folder would allow, and ask: non-nil to go on."
  (with-output-to-temp-buffer "*Trust This Folder*"
    (princ (format "Trusting %s allows this code, exactly as it is now:\n\n" (abbreviate-file-name root)))
    (dolist (p pairs)
      (princ (format "%s:%s  %s  %s\n" (plist-get p :file) (or (plist-get p :line) "?") (plist-get p :var)
                     (drgnx-settings-trust--text (plist-get p :value)))))
    (princ "\nCode added or changed later waits for Settings: Review Workspace Code.\n"))
  (yes-or-no-p (format "Trust %s and allow the %d piece%s of code shown? " (abbreviate-file-name root) (length pairs)
                       (if (cdr pairs) "s" ""))))

(defun drgnx-settings-trust-this-folder (&optional root shown)
  "Trust This Folder: trust ROOT (default: this buffer's project, else its folder), so that its data applies and
Flymake checkers and symbol shorthands work in its files, and allow SHOWN, the code it showed (plists or (FILE VAR
VALUE) pairs), and only that: code added or changed later waits for review.  Interactively the code there now is
shown first, and you confirm it.  ROOT is no longer an exception you untrusted.  Returns ROOT."
  (interactive (list nil :ask))
  (let* ((root (drgnx-settings-trust--norm (or root (drgnx-trust--folder))))
         (shown (if (eq shown :ask)
                    (let ((pairs (drgnx-settings-trust-code-pairs root)))
                      (when (and pairs (not (drgnx-settings-trust--show root pairs))) (user-error "Not trusted"))
                      pairs)
                  shown)))
    (drgnx-trust-folder root)
    (let ((pairs (mapcar #'drgnx-settings-trust--pair shown)))
      (drgnx-trust-update
       (lambda (data)
         (setq data (plist-put data :untrusted (cl-remove-if (lambda (k) (equal (drgnx-settings-trust--unkey k) root))
                                                             (plist-get data :untrusted))))
         (if pairs (drgnx-settings-trust--put-pairs data :allowed root pairs) data)))
      (drgnx-settings-trust--forget-waiting root pairs))
    (drgnx-settings-trust--rehack root)
    root))

(defun drgnx-settings-trust-untrust (&optional root)
  "Untrust the workspace ROOT (default: this buffer's): Trust This Folder's trust of it ends, a trust by location
becomes an exception kept on this machine, its allowed pairs are forgotten, and its open buffers lose the values
trust gave them at once.  Effects of code that already ran cannot be undone; the message says so.  Returns ROOT."
  (interactive)
  (let* ((root (if root (drgnx-settings-trust--norm root)
                 (or (drgnx-settings-trust--buffer-root) (user-error "Untrust works in a file's buffer"))))
         (located (seq-some (lambda (p) (string-prefix-p (car p) root)) (drgnx-settings-trust--parents))))
    (when (member root (drgnx-settings-trust--folders)) (drgnx-trust-untrust-folder root))
    (drgnx-trust-update
     (lambda (data)
       (setq data (drgnx-settings-trust--drop-pairs data :allowed root t))
       (if (and located (not (member root (mapcar #'drgnx-settings-trust--unkey (plist-get data :untrusted)))))
           (plist-put data :untrusted (append (plist-get data :untrusted) (list (abbreviate-file-name root))))
         data)))
    (remhash root drgnx-settings-trust--waiting)
    (drgnx-settings-trust--rehack root)
    (message "No longer trusted: %s (its workspace values are taken back; code that already ran cannot be undone)"
             (abbreviate-file-name root))
    root))

(defun drgnx-settings-trust-untrustable-p ()
  "Is this buffer's workspace trusted in any way (so that Untrust This Folder has something to take back)?"
  (and buffer-file-name (not (file-remote-p buffer-file-name))
       (or (drgnx-trust--user-entry)
           (not (eq (drgnx-settings-trust-state (drgnx-settings-trust--buffer-root)) 'untrusted)))))

;;;; Security settings out of reach of dir-locals and file-locals

(defvar drgnx-settings-trust--guarded nil
  "The variables workspace trust put into `ignored-local-variables' (taken out again when it is turned off).")

(defvar drgnx-settings-trust--guarded-count -1 "How many settings were declared at the last guard.")

(defun drgnx-settings-trust--guard ()
  "Mark drgnx's security settings (`drgnx-settings-trust-security-settings') risky and keep them in the default value
of `ignored-local-variables', so that Emacs's filter drops them from every dir-local and file-local spec before any
prompt.  Cheap when no setting was declared since the last call."
  (let ((n (length (drgnx-setting-names))))
    (unless (= n drgnx-settings-trust--guarded-count)
      (setq drgnx-settings-trust--guarded-count n)
      (dolist (v (drgnx-settings-trust-security-settings))
        (put v 'risky-local-variable t)
        (unless (memq v (default-value 'ignored-local-variables))
          (set-default 'ignored-local-variables (cons v (default-value 'ignored-local-variables)))
          (push v drgnx-settings-trust--guarded))))))

(defun drgnx-settings-trust--guard-hook ()
  "First on `hack-dir-local-get-variables-functions' (depth -100): `drgnx-settings-trust--guard' before any local
variable is filtered (a setting may have been declared since).  Gives no item; never signals."
  (ignore-errors (drgnx-settings-trust--guard))
  nil)

;;;; trusted-content for :code t, and start-up

(defvar drgnx-settings-trust--content nil
  "The `drgnx-trust-parents' folders with :code t that workspace trust put into `trusted-content'.")

(defun drgnx-settings-trust--sync-content ()
  "Make `trusted-content' hold the folders of `drgnx-trust-parents' with :code t, and no longer those it held before."
  (let ((want (mapcar (lambda (p) (abbreviate-file-name (car p))) (seq-filter #'cdr (drgnx-settings-trust--parents)))))
    (unless (eq trusted-content :all)
      (dolist (e drgnx-settings-trust--content)
        (unless (or (member e want) (member e (drgnx-trust--builtin)) (member e drgnx-trust--added))
          (setq trusted-content (delete e (copy-sequence trusted-content)))))
      (drgnx-trust--add want))
    (setq drgnx-settings-trust--content want)
    (when (bound-and-true-p drgnx-trust-mode) (drgnx-trust--refresh))))

(defun drgnx-settings-trust--parents-apply ()
  "`drgnx-trust-parents''s `:apply': `trusted-content' follows it, and every open buffer applies its workspace
values again."
  (drgnx-settings-trust--sync-content)
  (drgnx-settings-trust--rehack "/"))

(defun drgnx-settings-trust-migrate ()
  "Once, at the first start with workspace trust: a trusted-folders.eld older than version 2 becomes version 2, its
folders stay trusted, and the code now in each (`drgnx-settings-trust-code-pairs') is recorded as allowed, with one
notice listing it.  Returns ((ROOT . PAIRS)…) recorded, nil when there was nothing to do.  Never signals."
  (condition-case err
      (let* ((r (drgnx-file-read (drgnx-trust-folders-file))) (data (plist-get r :data)) (recorded nil))
        (when (and (eq (plist-get r :status) 'ok) (listp (drgnx-trust--folders-of data))
                   (memq (plist-get data :version) '(nil 1)))
          (drgnx-trust-update
           (lambda (d)
             (if (not (memq (plist-get d :version) '(nil 1))) d   ; another Emacs migrated it meanwhile
               (setq recorded nil)
               (dolist (f (plist-get d :folders))
                 (when (drgnx-trust--read-entry-p f)
                   (let* ((root (drgnx-settings-trust--norm f))
                          (pairs (mapcar #'drgnx-settings-trust--pair (drgnx-settings-trust-code-pairs root))))
                     (when pairs
                       (push (cons root pairs) recorded)
                       (setq d (drgnx-settings-trust--put-pairs d :allowed root pairs))))))
               (plist-put d :version drgnx-trust-folders-version))))
          (when (and recorded (require 'drgnx-notice nil t))
            (drgnx-notify 'config 'info
                          (format "Workspace trust: the code in %d folder%s you trusted was recorded as allowed; new or changed code there waits for review"
                                  (length recorded) (if (cdr recorded) "s" ""))
                          :id 'trust-migrated
                          :detail (mapconcat (lambda (r)
                                               (concat (abbreviate-file-name (car r)) ":\n"
                                                       (mapconcat (lambda (p) (format "  %s  %s  %s" (nth 0 p) (nth 1 p) (nth 2 p)))
                                                                  (cdr r) "\n")))
                                             (reverse recorded) "\n"))))
        (nreverse recorded))
    (error (drgnx-settings-file--warn
            (format "Workspace trust: trusted-folders.eld was not migrated: %s" (error-message-string err)))
           nil)))

(defun drgnx-settings-trust-start ()
  "At start-up (`drgnx-trust-mode' on): guard the security settings, migrate trusted-folders.eld once, and put the
:code t locations into `trusted-content'.  Never signals."
  (condition-case err
      (progn (drgnx-settings-trust--guard) (drgnx-settings-trust-migrate) (drgnx-settings-trust--sync-content))
    (error (drgnx-settings-file--warn
            (format "Workspace trust did not start fully: %s" (error-message-string err))))))

;;;; The doctor

(defun drgnx-settings-trust-doctor-roots ()
  "The folders in `safe-local-variable-directories' (its value, and the one saved in custom.el) that are not folders
of Trust This Folder: every directory-local value there applies with no question, risky ones included."
  (let* ((saved (pcase (car (get 'safe-local-variable-directories 'saved-value)) (`(quote ,x) x)))
         (dirs (seq-filter #'stringp (delete-dups (append (default-value 'safe-local-variable-directories)
                                                          (and (proper-list-p saved) saved)))))
         (folders (drgnx-trust-folders)))
    (seq-remove (lambda (d) (and (not (file-remote-p d)) (member (ignore-errors (drgnx-trust--entry d)) folders))) dirs)))

;;;; On and off

(defun drgnx-settings-trust-enable ()
  "Put workspace trust in: the split of `.dir-locals*.el' and the guard of the security settings.  Idempotent;
`drgnx-settings-workspace-enable' calls it."
  (add-hook 'hack-dir-local-get-variables-functions #'drgnx-settings-trust--guard-hook -100)
  (advice-add 'hack-dir-local--get-variables :around #'drgnx-settings-trust--split-around)
  (drgnx-settings-trust--guard))

(defun drgnx-settings-trust-disable ()
  "Take workspace trust out again (`drgnx-settings-trust-enable')."
  (remove-hook 'hack-dir-local-get-variables-functions #'drgnx-settings-trust--guard-hook)
  (advice-remove 'hack-dir-local--get-variables #'drgnx-settings-trust--split-around)
  (set-default 'ignored-local-variables
               (cl-remove-if (lambda (v) (memq v drgnx-settings-trust--guarded)) (default-value 'ignored-local-variables)))
  (setq drgnx-settings-trust--guarded nil drgnx-settings-trust--guarded-count -1))

(provide 'drgnx-settings-trust)
;;; drgnx-settings-trust.el ends here
