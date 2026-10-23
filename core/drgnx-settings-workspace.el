;;; drgnx-settings-workspace.el --- Settings: the workspace layers (shared and private) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 17 (design §4.1, §4.2, §5.3; docs/develop/settings.md, "Workspace layers").
;; - W2, your private workspace file `<config>/workspaces/<slug>.el', and W1, the shared `<root>/.drgnx/settings.el'
;;   (64 KiB), are functions on `hack-dir-local-get-variables-functions': W2 at depth -90 (it wins over
;;   `.dir-locals.el' at the same directory), W1 at depth 90 (it loses).  Each returns items (DIR . ALIST), one for the
;;   root and one per `(:dir "SUB/" …)' section that holds the buffer, so Emacs's own order applies: nearest
;;   directory first.  `(:mode M …)' sections apply in buffers of M (or a mode derived from it).
;; - Each item's DIR is a fresh string this file remembers (weakly).  An `:around' advice on
;;   `hack-local-variables-filter' binds `enable-local-variables' to `:all' for a call whose DIR is one of them, and
;;   only while it is t: so drgnx's items never prompt and never write `safe-local-variable-values'; under `:safe'
;;   only safe values apply, as stock; under nil Emacs runs no dir-local function at all.
;; - Refused, with a problem naming the file and line: an entry of a `:scope global' setting, of a `:workspace never'
;;   setting, and the pseudo-variables `eval' and `mode' (code goes in an `(:eval …)' section).  `:scope project'
;;   entries are not buffer values: `drgnx-setting-for-root' reads them (W2 > W1 > global, by `:merge').
;; - W2's `:eval' runs after its values (it is your file).  W1 applies only what
;;   `drgnx-settings-workspace-filter-function' passes: safe values only (Task 18 replaces it).
;; - Today's `.drgnx/{search,ai,large-files}.eld' are read as W1 entries for `drgnx-setting-for-root' (the shim):
;;   the large-file sizes as `:merge lower-only'.
;; - `drgnx-settings-workspace-rehack' applies a root's values again in its open buffers, without their major mode;
;;   `drgnx-settings-workspace-sync' is what `drgnx-settings-live-sync' calls for a workspace file.
;; Nothing here prompts, and a hook function never signals.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-setting)
(require 'drgnx-settings-file)

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-notice-clear "drgnx-notice" (source &optional id))
(declare-function drgnx-settings-live-watch "drgnx-settings-live" (file))
(declare-function editorconfig--get-dir-local-variables "editorconfig" ())

(defvar drgnx-settings-explain-functions)

(defconst drgnx-settings-workspace-shared-file ".drgnx/settings.el"
  "Where a workspace's shared settings (W1) live, relative to its root.")

(defconst drgnx-settings-workspace-cache-max 128
  "The most workspace files whose read docs are kept; past it the cache is emptied (it is keyed by file name).")

(defconst drgnx-settings-workspace-old-files
  '((search-project (:include drgnx-search-include) (:exclude drgnx-search-exclude) (:off drgnx-search-off))
    (ai-project (:roles drgnx-ai-roles))
    (large-files-project (:ask-above drgnx-large-files-ask-above lower-only)
                         (:chunks-above drgnx-large-files-chunks-above lower-only)))
  "Today's project files read as W1 entries (the shim): (CONFIG-NAME (KEY VAR [MERGE])…).  A file is read through
the config layer, by its own definition and schema, only while that definition exists.")

(defvar drgnx-settings-workspace-filter-function #'drgnx-settings-workspace-safe-only
  "Which entries of a shared workspace file (W1) apply.  Called with ROOT, FILE and ENTRIES (the
`drgnx-settings-entry's left after the refusals; `:eval' sections among them) and returns those to apply.  The
default, `drgnx-settings-workspace-safe-only', passes safe values only; workspace trust (Task 18) replaces it.")

(defvar drgnx-settings-workspace--docs (make-hash-table :test 'equal)
  "File -> (STAMP . DOC): a workspace file read, read again when its stamp changed.  Bounded by
`drgnx-settings-workspace-cache-max'.")

(defvar drgnx-settings-workspace--seen (make-hash-table :test 'equal)
  "File -> (ROOTS . FACTS): the workspace files drgnx has read (the open projects' files, which live changes watch),
their roots and their entries as last synced.  Emptied with `drgnx-settings-workspace--docs'.")

(defvar drgnx-settings-workspace--marks (make-hash-table :test 'eq :weakness 'key)
  "The directory strings of drgnx's dir-local items (by identity; weak: an item gone is forgotten).")

;;;; Places, files and docs

(defun drgnx-settings-workspace--norm (dir)
  "DIR as roots are compared: an absolute truename ending in a slash."
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun drgnx-settings-workspace-private-dir ()
  "The folder of your private workspace files: <config>/workspaces/."
  (expand-file-name "workspaces/" (drgnx-user-dir)))

(defun drgnx-settings-workspace--private-files ()
  "Your private workspace files, sorted."
  (let ((dir (drgnx-settings-workspace-private-dir)))
    (and (file-directory-p dir) (directory-files dir t "\\`[^.].*\\.el\\'"))))

(defun drgnx-settings-workspace-file-p (file)
  "Non-nil when FILE is a workspace settings file: a private one (W2) or a shared .drgnx/settings.el (W1)."
  (let ((file (expand-file-name file)))
    (or (string-suffix-p (concat "/" drgnx-settings-workspace-shared-file) file)
        (and (string-suffix-p ".el" file)
             (equal (file-name-directory file) (expand-file-name (drgnx-settings-workspace-private-dir)))))))

(defun drgnx-settings-workspace--place ()
  "Where the current buffer is: (DIR . NAME), DIR its directory and NAME its file (or DIR), both truenames; nil
for a remote buffer (no workspace layer applies there)."
  (let ((name (or buffer-file-name default-directory)))
    (unless (or (null name) (file-remote-p name))
      (let ((dir (drgnx-settings-workspace--norm (if buffer-file-name (file-name-directory name) name))))
        (cons dir (if buffer-file-name (file-truename buffer-file-name) dir))))))

(defun drgnx-settings-workspace--facts (doc)
  "DOC's entries as ((SCOPE VAR) . VALUE), in file order."
  (mapcar (lambda (e) (cons (list (drgnx-settings-entry-scope e) (drgnx-settings-entry-var e))
                            (drgnx-settings-entry-value e)))
          (and doc (drgnx-settings-doc-entries doc))))

(defun drgnx-settings-workspace--file-roots (file doc)
  "The roots workspace FILE (read as DOC) belongs to."
  (if (string-suffix-p (concat "/" drgnx-settings-workspace-shared-file) (expand-file-name file))
      (list (drgnx-settings-workspace--norm (expand-file-name "../.." file)))
    (drgnx-settings-workspace--roots doc)))

(defun drgnx-settings-workspace--doc (file)
  "Workspace FILE read (head `drgnx-workspace-settings'), again when its stamp changed; nil when it is missing.
The first read of a file records it for live changes and says its problems; a later read says them again."
  (let* ((file (expand-file-name file))
         (stamp (drgnx-file-stamp file))
         (hit (gethash file drgnx-settings-workspace--docs)))
    (cond ((null stamp) (remhash file drgnx-settings-workspace--docs) nil)
          ((and hit (equal (car hit) stamp)) (cdr hit))
          (t (let ((doc (drgnx-settings-file-read file 'drgnx-workspace-settings)))
               (when (>= (hash-table-count drgnx-settings-workspace--docs) drgnx-settings-workspace-cache-max)
                 (clrhash drgnx-settings-workspace--docs)
                 (clrhash drgnx-settings-workspace--seen))
               (puthash file (cons stamp doc) drgnx-settings-workspace--docs)
               (unless (gethash file drgnx-settings-workspace--seen)
                 (puthash file (cons (drgnx-settings-workspace--file-roots file doc)
                                     (drgnx-settings-workspace--facts doc))
                          drgnx-settings-workspace--seen)
                 (when (fboundp 'drgnx-settings-live-watch)
                   (ignore-errors (drgnx-settings-live-watch file))))
               (drgnx-settings-workspace--say file)
               doc)))))

(defun drgnx-settings-workspace--roots (doc)
  "The roots DOC's `:roots' names, as `drgnx-settings-workspace--norm' gives them."
  (let ((roots (and doc (plist-get (drgnx-settings-doc-meta doc) :roots))))
    (and (proper-list-p roots)
         (mapcar #'drgnx-settings-workspace--norm (cl-remove-if-not #'stringp roots)))))

;;;; Refusals and problems

(defun drgnx-settings-workspace--refusal (entry)
  "Why ENTRY may not be in a workspace file, as text; nil when it may."
  (let ((var (drgnx-settings-entry-var entry)))
    (cond ((eq var :eval) nil)
          ((memq var '(eval mode))
           (format "%s is a pseudo-variable of .dir-locals.el; workspace code goes in an (:eval …) section" var))
          (t (let ((meta (drgnx-setting-meta var)))
               (cond ((eq (plist-get meta :workspace) 'never)
                      (format "%s is never set by a workspace (it guards your security); set it in Settings → User"
                              var))
                     ((eq (plist-get meta :scope) 'global)
                      (format "%s has one value for all of Emacs; set it in Settings → User" var))))))))

(defun drgnx-settings-workspace--usable (file)
  "Workspace FILE's entries and problems: (ENTRIES . PROBLEMS).  ENTRIES are those not refused, in file order;
PROBLEMS the file's own and one per refused entry, plists (:file :line :text :var)."
  (let ((doc (drgnx-settings-workspace--doc file)) (entries nil) (problems nil))
    (when doc
      (setq problems (copy-sequence (drgnx-settings-doc-problems doc)))
      (dolist (e (drgnx-settings-doc-entries doc))
        (if-let* ((why (drgnx-settings-workspace--refusal e)))
            (push (list :file (drgnx-settings-doc-file doc) :line (drgnx-settings-entry-line e) :text why
                        :var (drgnx-settings-entry-var e))
                  problems)
          (push e entries))))
    (cons (nreverse entries)
          (sort problems (lambda (a b) (< (or (plist-get a :line) 0) (or (plist-get b :line) 0)))))))

(defun drgnx-settings-workspace-problems (file)
  "Workspace FILE's problems: its mistakes and its refused entries, plists (:file :line :text), by line."
  (cdr (drgnx-settings-workspace--usable file)))

(defun drgnx-settings-workspace--say (file)
  "Say FILE's problems as one notice condition (none: it goes).  Never signals."
  (condition-case err
      (let ((problems (drgnx-settings-workspace-problems file))
            (id (concat "workspace:" file)))
        (cond ((null problems) (when (featurep 'drgnx-notice) (drgnx-notice-clear 'config id)))
              ((require 'drgnx-notice nil t)
               (let ((lines (mapcar (lambda (p) (format "%s:%s: %s" (abbreviate-file-name file)
                                                        (or (plist-get p :line) "?") (plist-get p :text)))
                                    problems)))
                 (drgnx-notify 'config 'warn (if (cdr lines)
                                                 (format "%s: %d entries do not apply"
                                                         (abbreviate-file-name file) (length lines))
                                               (car lines))
                               :id id :life 'condition :detail (string-join lines "\n"))))))
    (error (message "drgnx: %s: its problems were not recorded: %s" file (error-message-string err)))))

;;;; The entries that apply in a buffer

(defun drgnx-settings-workspace-safe-only (_root _file entries)
  "The default `drgnx-settings-workspace-filter-function': ENTRIES whose value is safe for their variable
\(`safe-local-variable-p'); never an `:eval' section."
  (cl-remove-if-not (lambda (e) (and (not (eq (drgnx-settings-entry-var e) :eval))
                                     (safe-local-variable-p (drgnx-settings-entry-var e)
                                                            (drgnx-settings-entry-value e))))
                    entries))

(defun drgnx-settings-workspace--project-p (entry)
  "Non-nil when ENTRY's setting is `:scope project': read with a root, never a buffer value."
  (and (not (eq (drgnx-settings-entry-var entry) :eval))
       (eq (plist-get (drgnx-setting-meta (drgnx-settings-entry-var entry)) :scope) 'project)))

(defun drgnx-settings-workspace--rank (entry)
  "How specific ENTRY's scope is within its directory: 0 at the top, else its mode's number of parents."
  (if-let* ((mode (alist-get :mode (drgnx-settings-entry-scope entry))))
      (length (derived-mode-all-parents mode))
    0))

(defun drgnx-settings-workspace--groups (entries root name)
  "ENTRIES that apply to NAME (a truename under ROOT) in the current buffer, grouped by directory, nearest first:
\((DIR . ENTRIES)…) with DIR ROOT or ROOT/SUB/ for a `(:dir \"SUB/\" …)' section holding NAME.  In a group, entries
come in the order they apply: the more specific mode after the less, `:eval' sections last."
  (let ((rel (substring name (min (length root) (length name)))) (groups nil))
    (dolist (e entries)
      (unless (drgnx-settings-workspace--project-p e)
        (let* ((scope (drgnx-settings-entry-scope e))
               (sub (alist-get :dir scope))
               (sub (and sub (file-name-as-directory sub)))
               (mode (alist-get :mode scope)))
          (when (and (or (null sub) (and (not (file-name-absolute-p sub)) (string-prefix-p sub rel)))
                     (or (null mode) (derived-mode-p mode)))
            (let* ((dir (if sub (concat root sub) root))
                   (cell (assoc dir groups)))
              (if cell (setcdr cell (cons e (cdr cell))) (push (list dir e) groups)))))))
    (mapcar (lambda (g)
              (cons (car g)
                    (let ((es (nreverse (cdr g))))
                      (append (sort (cl-remove-if (lambda (e) (eq (drgnx-settings-entry-var e) :eval)) es)
                                    (lambda (a b) (< (drgnx-settings-workspace--rank a)
                                                     (drgnx-settings-workspace--rank b))))
                              (cl-remove-if-not (lambda (e) (eq (drgnx-settings-entry-var e) :eval)) es)))))
            (sort groups (lambda (a b) (> (length (car a)) (length (car b))))))))

(defun drgnx-settings-workspace--alist (entries)
  "ENTRIES (in the order they apply) as a dir-local item's alist: each variable once (the last entry wins), its
value a fresh copy, an `:eval' section as (eval . (progn FORM…)).  Emacs applies an item's alist from its end, so
the alist is reversed: values apply first, in order, then the `:eval' forms."
  (let ((values nil) (evals nil))
    (dolist (e entries)
      (let ((var (drgnx-settings-entry-var e)) (value (copy-tree (drgnx-settings-entry-value e))))
        (if (eq var :eval)
            (push (cons 'eval (cons 'progn value)) evals)
          (setq values (cons (cons var value) (assq-delete-all var values))))))
    (append evals values)))

(defun drgnx-settings-workspace--items (groups)
  "GROUPS as the result of a dir-local function: ((DIR . ALIST)…), each DIR a fresh string remembered as drgnx's."
  (delq nil (mapcar (lambda (g)
                      (when-let* ((alist (drgnx-settings-workspace--alist (cdr g))))
                        (let ((dir (copy-sequence (car g))))
                          (puthash dir t drgnx-settings-workspace--marks)
                          (cons dir alist))))
                    groups)))

(defun drgnx-settings-workspace-project (_dir)
  "The Urdr project holding DIR, (ID . ROOT), for matching a private workspace file after its folder moved.
Nil until the Urdr gate (Task 17's post-gate row): matching is by root only."
  nil)

(defun drgnx-settings-workspace--private-for (dir)
  "The private workspace file for DIR (a normalized directory): (FILE . ROOT), ROOT the longest of its `:roots'
holding DIR; else the file whose `:project' is DIR's Urdr project, with that project's root; else nil."
  (let ((best nil) (files (drgnx-settings-workspace--private-files)))
    (dolist (file files)
      (dolist (root (drgnx-settings-workspace--roots (drgnx-settings-workspace--doc file)))
        (when (and (string-prefix-p root dir) (or (null best) (> (length root) (length (cdr best)))))
          (setq best (cons file root)))))
    (or best
        (when-let* ((project (drgnx-settings-workspace-project dir)))
          (when-let* ((file (drgnx-settings-workspace--by-project (car project) files)))
            (cons file (drgnx-settings-workspace--norm (cdr project))))))))

(defun drgnx-settings-workspace--by-project (id files)
  "The first of FILES whose `:project' is ID, or nil."
  (cl-find-if (lambda (file)
                (when-let* ((doc (drgnx-settings-workspace--doc file)))
                  (equal (plist-get (drgnx-settings-doc-meta doc) :project) id)))
              files))

(defun drgnx-settings-workspace--shared-for (dir)
  "The shared workspace file for DIR (a normalized directory): (FILE . ROOT) for the nearest .drgnx/settings.el."
  (when-let* ((root (locate-dominating-file dir drgnx-settings-workspace-shared-file)))
    (let ((root (drgnx-settings-workspace--norm root)))
      (cons (expand-file-name drgnx-settings-workspace-shared-file root) root))))

(defun drgnx-settings-workspace--shared-entries (file root)
  "Shared FILE's entries (of ROOT) that apply: not refused, then passed by `drgnx-settings-workspace-filter-function'."
  (funcall drgnx-settings-workspace-filter-function root file (car (drgnx-settings-workspace--usable file))))

(defun drgnx-settings-workspace--private-groups (place)
  "The W2 groups at PLACE ((DIR . NAME)), with the file: (FILE . GROUPS), or nil."
  (when-let* ((match (drgnx-settings-workspace--private-for (car place))))
    (cons (car match) (drgnx-settings-workspace--groups (car (drgnx-settings-workspace--usable (car match)))
                                                        (cdr match) (cdr place)))))

(defun drgnx-settings-workspace--shared-groups (place)
  "The W1 groups at PLACE ((DIR . NAME)), with the file: (FILE . GROUPS), or nil."
  (when-let* ((match (drgnx-settings-workspace--shared-for (car place))))
    (cons (car match) (drgnx-settings-workspace--groups
                       (drgnx-settings-workspace--shared-entries (car match) (cdr match)) (cdr match) (cdr place)))))

(defun drgnx-settings-workspace--hook-result (groups-fn)
  "The dir-local items GROUPS-FN gives for the current buffer; nil, with one message, when it fails."
  (condition-case err
      (when-let* ((place (drgnx-settings-workspace--place)))
        (drgnx-settings-workspace--items (cdr (funcall groups-fn place))))
    (error (message "drgnx: workspace settings were not applied in %s: %s" (buffer-name) (error-message-string err))
           nil)))

(defun drgnx-settings-workspace--private-variables ()
  "W2, your private workspace file, on `hack-dir-local-get-variables-functions' (depth -90).  Never signals."
  (drgnx-settings-workspace--hook-result #'drgnx-settings-workspace--private-groups))

(defun drgnx-settings-workspace--shared-variables ()
  "W1, the workspace's shared .drgnx/settings.el, on `hack-dir-local-get-variables-functions' (depth 90).  Never
signals."
  (drgnx-settings-workspace--hook-result #'drgnx-settings-workspace--shared-groups))

(defvar drgnx-settings-workspace--quiet nil
  "Non-nil while drgnx applies a buffer's dir-local values again: Emacs's own items then apply their safe values
only, so a re-hack never prompts (what you accepted at the open stays set).")

(defun drgnx-settings-workspace--filter-around (fn &rest args)
  "Around `hack-local-variables-filter' (FN, ARGS = VARIABLES DIR-NAME): for an item of drgnx's (its DIR-NAME a
remembered string) while `enable-local-variables' is t, bind it to `:all' for this call only: no prompt, nothing
saved.  Every other call, and every call under `:safe' or nil, is Emacs's own (during a re-hack, under `:safe')."
  (let ((dir (nth 1 args)))
    (cond ((not (eq enable-local-variables t)) (apply fn args))
          ((and (stringp dir) (gethash dir drgnx-settings-workspace--marks))
           (let ((enable-local-variables :all)) (apply fn args)))
          ((and drgnx-settings-workspace--quiet dir) (let ((enable-local-variables :safe)) (apply fn args)))
          (t (apply fn args)))))

;;;; Project-scoped settings

(defun drgnx-settings-workspace--old-entries (root)
  "Today's .drgnx/{search,ai,large-files}.eld of ROOT as W1 entries (the shim, `drgnx-settings-workspace-old-files'),
each read through the config layer while its definition exists."
  (let ((out nil))
    (pcase-dolist (`(,name . ,keys) drgnx-settings-workspace-old-files)
      (when (drgnx-config-defined-p name)
        (let ((data (ignore-errors (drgnx-config-get name nil root))))
          (when (proper-list-p data)
            (dolist (k keys)                    ; (KEY VAR [MERGE])
              (when (plist-member data (car k))
                (push (make-drgnx-settings-entry :var (nth 1 k) :value (plist-get data (car k)) :merge (nth 2 k))
                      out)))))))
    (nreverse out)))

(defun drgnx-settings-workspace--merge (var entry lower)
  "ENTRY's value for VAR over LOWER, by the entry's `:merge', else the setting's: `replace' (the default),
`alist' (ENTRY's keys win, LOWER's others stay), `append' (LOWER's elements, then ENTRY's new ones) or `lower-only'
\(the lower of two numbers; anything else keeps LOWER)."
  (let ((v (copy-tree (drgnx-settings-entry-value entry)))
        (kind (or (drgnx-settings-entry-merge entry) (plist-get (drgnx-setting-meta var) :merge) 'replace)))
    (pcase kind
      ('alist (if (and (proper-list-p v) (proper-list-p lower))
                  (append v (cl-remove-if (lambda (c) (and (consp c) (assoc (car c) v))) lower))
                v))
      ('append (if (and (proper-list-p v) (proper-list-p lower))
                   (append lower (cl-remove-if (lambda (x) (member x lower)) v))
                 v))
      ('lower-only (if (and (numberp v) (numberp lower)) (min v lower) lower))
      (_ v))))

(defun drgnx-setting-for-root (var root)
  "VAR's value for the project at ROOT: W2 > W1 > the global value (`default-value'), each layer over the one below
by its `:merge' (`drgnx-settings-workspace--merge').  W1 is today's .drgnx/{search,ai,large-files}.eld (the shim),
then ROOT/.drgnx/settings.el's entries that `drgnx-settings-workspace-filter-function' passes; W2 is ROOT's
private file.  Only top-level entries count; refused ones never do.  Never signals for a missing file."
  (let* ((root (drgnx-settings-workspace--norm root))
         (value (and (default-boundp var) (copy-tree (default-value var))))
         (top (lambda (entries) (cl-remove-if-not (lambda (e) (and (eq (drgnx-settings-entry-var e) var)
                                                                   (null (drgnx-settings-entry-scope e))))
                                                  entries)))
         (shared (expand-file-name drgnx-settings-workspace-shared-file root))
         (private (drgnx-settings-workspace-file root)))
    (dolist (e (append (funcall top (cl-remove-if #'drgnx-settings-workspace--refusal
                                                  (drgnx-settings-workspace--old-entries root)))
                       (funcall top (drgnx-settings-workspace--shared-entries shared root))
                       (and private (funcall top (car (drgnx-settings-workspace--usable private))))))
      (setq value (drgnx-settings-workspace--merge var e value)))
    value))

;;;; Your private files

(defun drgnx-settings-workspace--slug (root)
  "The name of ROOT's private file, before a clash: its folder's name, with anything but letters, digits, `.', `_'
and `-' made `-', and no leading dot."
  (let ((name (replace-regexp-in-string "\\`\\.+" ""
                                        (replace-regexp-in-string "[^[:alnum:]._-]" "-"
                                                                  (file-name-nondirectory (directory-file-name root))))))
    (if (string-empty-p name) "workspace" name)))

(defun drgnx-settings-workspace--create (root)
  "Make a private workspace file for ROOT (normalized): <slug>.el, or <slug>-2.el … when taken; the file."
  (let* ((dir (drgnx-settings-workspace-private-dir))
         (slug (drgnx-settings-workspace--slug root))
         (project (car-safe (drgnx-settings-workspace-project root)))
         (data `(drgnx-workspace-settings :version ,drgnx-settings-file-version
                                          :roots (,(abbreviate-file-name root))
                                          ,@(and project (list :project project))))
         (made nil))
    (make-directory dir t)
    (cl-loop for n from 1 to 1000
             for file = (expand-file-name (if (= n 1) (concat slug ".el") (format "%s-%d.el" slug n)) dir)
             unless (file-exists-p file)
             do (drgnx-file-update
                 file (lambda (old) (if old old (setq made file) data))
                 :render (lambda (_old _data new)
                           (concat (drgnx-settings-file--header file 'drgnx-workspace-settings)
                                   (format "(drgnx-workspace-settings\n :version %d\n :roots (%s)%s)\n"
                                           drgnx-settings-file-version (prin1-to-string (car (plist-get (cdr new) :roots)))
                                           (if project (format "\n :project %s" (prin1-to-string project)) "")))))
             until made)
    (or made (signal 'drgnx-settings-refused (list (format "no free name for %s's workspace file in %s" root dir))))))

(defun drgnx-settings-workspace-file (root &optional create)
  "ROOT's private workspace file in <config>/workspaces/: the one whose `:roots' holds ROOT, else (after the folder
moved) the one whose `:project' is ROOT's Urdr project id (`drgnx-settings-workspace-project'); nil when there is
none, unless CREATE: then a new one, named after ROOT's folder (<slug>.el, <slug>-2.el on a clash, …), holding
`:roots' (ROOT) and `:project' when known.  Signals `drgnx-settings-refused' when it cannot be made."
  (let* ((root (drgnx-settings-workspace--norm root))
         (files (drgnx-settings-workspace--private-files)))
    (or (cl-find-if (lambda (file) (member root (drgnx-settings-workspace--roots (drgnx-settings-workspace--doc file))))
                    files)
        (when-let* ((project (drgnx-settings-workspace-project root)))
          (drgnx-settings-workspace--by-project (car project) files))
        (and create (drgnx-settings-workspace--create root)))))

;;;; Applying again: re-hack and live changes

(defun drgnx-settings-workspace--rehack-buffer ()
  "Apply the current buffer's dir-local variables again, without its major mode: the file's own local variables
keep winning, a `mode' entry is not run again, and a value no source gives any more is taken away (only when it is
still the value the source gave)."
  (let* ((inhibit-interaction t)
         (drgnx-settings-workspace--quiet t)
         (old dir-local-variables-alist)
         (old-file file-local-variables-alist)
         (own (cl-remove-if (lambda (e) (memq e old)) file-local-variables-alist)))
    (setq dir-local-variables-alist nil file-local-variables-alist nil)
    (condition-case err (hack-dir-local-variables)
      (error (setq dir-local-variables-alist old file-local-variables-alist old-file)
             (signal (car err) (cdr err))))
    (setq file-local-variables-alist
          (cl-remove-if (lambda (e) (or (eq (car e) 'mode) (and (not (eq (car e) 'eval)) (assq (car e) own))))
                        file-local-variables-alist))
    (hack-local-variables-apply)
    (setq file-local-variables-alist (append file-local-variables-alist own))
    (dolist (cell old)
      (let ((var (car cell)))
        (unless (or (memq var '(eval mode)) (assq var dir-local-variables-alist) (assq var own))
          (when (and (local-variable-p var) (equal (symbol-value var) (cdr cell)))
            (kill-local-variable var)))))))

(defun drgnx-settings-workspace-rehack (root)
  "Apply the workspace values again in ROOT's open buffers (those visiting a file under ROOT, and other buffers there
with dir-local values), without re-running their major mode.  Returns the buffers.  Never signals, never prompts."
  (let ((root (ignore-errors (drgnx-settings-workspace--norm root))) (done nil))
    (when root
      (dolist (b (buffer-list))
        (with-current-buffer b
          (when-let* ((place (ignore-errors (drgnx-settings-workspace--place))))
            (when (and (string-prefix-p root (car place)) (or buffer-file-name dir-local-variables-alist))
              (condition-case err (progn (drgnx-settings-workspace--rehack-buffer) (push b done))
                (error (message "drgnx: %s: workspace settings were not applied again: %s" (buffer-name)
                                (error-message-string err)))))))))
    (nreverse done)))

(defun drgnx-settings-workspace-files ()
  "The workspace files drgnx has read (the open projects'), which live changes watch."
  (hash-table-keys drgnx-settings-workspace--seen))

(defun drgnx-settings-workspace--changes (old new)
  "The (SCOPE VAR OLD NEW) list between the facts OLD and NEW (`:unset' for an entry added or taken out)."
  (let ((changes nil))
    (dolist (cell new)
      (let ((o (assoc (car cell) old)))
        (unless (and o (equal (cdr o) (cdr cell)))
          (push (list (car (car cell)) (cadr (car cell)) (if o (cdr o) :unset) (cdr cell)) changes))))
    (dolist (cell old)
      (unless (assoc (car cell) new)
        (push (list (car (car cell)) (cadr (car cell)) (cdr cell) :unset) changes)))
    (nreverse changes)))

(defun drgnx-settings-workspace-sync (file)
  "Read workspace FILE again: its changes since the last sync, (SCOPE VAR OLD NEW)…, and, when there are any, its
roots' open buffers re-hacked (`drgnx-settings-workspace-rehack').  Never prompts."
  (let* ((file (expand-file-name file))
         (seen (gethash file drgnx-settings-workspace--seen))
         (doc (drgnx-settings-workspace--doc file))
         (roots (if doc (drgnx-settings-workspace--file-roots file doc) (car seen)))
         (changes (drgnx-settings-workspace--changes (cdr seen) (drgnx-settings-workspace--facts doc))))
    (puthash file (cons roots (drgnx-settings-workspace--facts doc)) drgnx-settings-workspace--seen)
    (when changes
      (dolist (root (delete-dups (append roots (car seen))))
        (drgnx-settings-workspace-rehack root)))
    changes))

;;;; Explaining a buffer's value

(defun drgnx-settings-workspace--layer-of (layer kind file groups var)
  "The layer plist of VAR from GROUPS (nearest first) of workspace FILE, or nil."
  (cl-some (lambda (g)
             (when-let* ((e (car (last (cl-remove-if-not (lambda (e) (eq (drgnx-settings-entry-var e) var)) (cdr g))))))
               (list :layer layer :kind kind :value (drgnx-settings-entry-value e) :file file
                     :line (drgnx-settings-entry-line e) :certain t
                     :source (if (eq layer 'W2)
                                 (format "Workspace (%s:%s)" (file-name-nondirectory file) (drgnx-settings-entry-line e))
                               (format "Shared (%s:%s)" drgnx-settings-workspace-shared-file
                                       (drgnx-settings-entry-line e))))))
           groups))

(defun drgnx-settings-workspace--line-of (file var)
  "The line of FILE where VAR's entry starts, or nil."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (when (re-search-forward (concat "(\\s-*" (regexp-quote (symbol-name var)) "\\_>") nil t)
        (line-number-at-pos (match-beginning 0) t)))))

(defun drgnx-settings-workspace--dir-locals-layers (var)
  "The layers of VAR from the nearest `.dir-locals.el' and `.dir-locals-2.el' of the current buffer."
  (let* ((found (dir-locals-find-file (or buffer-file-name default-directory)))
         (dir (if (consp found) (car found) found))
         (layers nil))
    (when (stringp dir)
      (dolist (f (dir-locals--all-files dir))
        (let* ((alist (ignore-errors (with-temp-buffer (insert-file-contents f) (read (current-buffer)))))
               (vars (and (proper-list-p alist) (ignore-errors (dir-locals-collect-variables alist dir nil)))))
          (when-let* ((cell (assq var vars)))
            (let ((line (drgnx-settings-workspace--line-of f var)))
              (push (list :layer 'dir-local :kind 'dir-locals :value (cdr cell) :file f :line line :certain t
                          :source (format "Directory-local (%s%s)" (abbreviate-file-name f)
                                          (if line (format ":%d" line) "")))
                    layers))))))
    (nreverse layers)))

(defun drgnx-settings-workspace--editorconfig-layer (var)
  "The layer of VAR from EditorConfig in the current buffer, when `editorconfig-mode' is on; else nil."
  (when (and (bound-and-true-p editorconfig-mode) (fboundp 'editorconfig--get-dir-local-variables))
    (when-let* ((r (ignore-errors (editorconfig--get-dir-local-variables)))
                (cell (assq var (cdr r))))
      (let ((f (expand-file-name ".editorconfig" (car r))))
        (list :layer 'dir-local :kind 'editorconfig :value (cdr cell) :file f :certain t
              :source (format "EditorConfig (%s)" (abbreviate-file-name f)))))))

(defun drgnx-settings-workspace--layers (var buffer)
  "On `drgnx-settings-explain-functions': VAR's directory-local layers in BUFFER: W2, W1, the nearest
`.dir-locals.el' and `.dir-locals-2.el', EditorConfig.  Only while VAR has a dir-local value there."
  (with-current-buffer buffer
    (when (assq var dir-local-variables-alist)
      (let ((place (drgnx-settings-workspace--place)))
        (delq nil (append (and place (let ((w2 (drgnx-settings-workspace--private-groups place)))
                                       (list (and w2 (drgnx-settings-workspace--layer-of 'W2 'workspace (car w2)
                                                                                         (cdr w2) var)))))
                          (and place (let ((w1 (drgnx-settings-workspace--shared-groups place)))
                                       (list (and w1 (drgnx-settings-workspace--layer-of 'W1 'shared (car w1)
                                                                                         (cdr w1) var)))))
                          (drgnx-settings-workspace--dir-locals-layers var)
                          (list (drgnx-settings-workspace--editorconfig-layer var))))))))

;;;; On and off

(defun drgnx-settings-workspace-enable ()
  "Put the workspace layers in: the two dir-local functions, the filter advice and the explain function.
Idempotent; done when this file loads."
  (add-hook 'hack-dir-local-get-variables-functions #'drgnx-settings-workspace--private-variables -90)
  (add-hook 'hack-dir-local-get-variables-functions #'drgnx-settings-workspace--shared-variables 90)
  (advice-add 'hack-local-variables-filter :around #'drgnx-settings-workspace--filter-around)
  (add-hook 'drgnx-settings-explain-functions #'drgnx-settings-workspace--layers))

(defun drgnx-settings-workspace-disable ()
  "Take the workspace layers out again (`drgnx-settings-workspace-enable')."
  (remove-hook 'hack-dir-local-get-variables-functions #'drgnx-settings-workspace--private-variables)
  (remove-hook 'hack-dir-local-get-variables-functions #'drgnx-settings-workspace--shared-variables)
  (advice-remove 'hack-local-variables-filter #'drgnx-settings-workspace--filter-around)
  (remove-hook 'drgnx-settings-explain-functions #'drgnx-settings-workspace--layers))

(drgnx-settings-workspace-enable)

(provide 'drgnx-settings-workspace)
;;; drgnx-settings-workspace.el ends here
