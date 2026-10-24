;;; drgnx-settings-page.el --- Settings: the Settings page -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 26 (design §7): Preferences: Settings, one page for every setting.  The rows are a drgnx view
;; (wb/drgnx-view.el): keyed by variable, drawn in slices, the visible rows first.  Above them: the scope tabs User
;; (settings.el) · Workspace (your private file for this project) · Shared (.drgnx/settings.el), the groups, the search.
;; A row shows its title, the first sentence of its documentation, the editor slot (Task 27 fills it; until then
;; `drgnx-settings-page-editor-slot' shows the plain value), "Modified in:" chips, the effective value with its source
;; at file:line, Reset and the row's history.  A setting your Lisp (or Customize) also sets gets the §4.3 message with
;; [Open FILE:LINE] and [Move into Settings].  The data functions (`drgnx-settings-page-row', `-vars', `-filter-match-p',
;; `-reset') are plain and tested; the buffer only draws them.  See docs/guide/settings.md, "The Settings page".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'drgnx-paths)
(require 'drgnx-config)
(require 'drgnx-setting)
(require 'drgnx-view)
(require 'drgnx-settings-file)
(require 'drgnx-settings-prov)
(require 'drgnx-settings-workspace)
(require 'drgnx-settings-trust)
(require 'drgnx-settings-index)
(require 'drgnx-settings-described)

(declare-function drgnx-settings-history-list "drgnx-settings-history" (&rest args))
(declare-function drgnx-settings-undo "drgnx-settings-history" (id))
(declare-function drgnx-settings-move-into-settings "drgnx-settings-move" (var))
(declare-function drgnx-settings-lisp-files "drgnx-settings-lisp-page" ())
(declare-function drgnx-modules-list "drgnx-modules" ())
(declare-function drgnx-surfaces-cheatsheet "drgnx-surfaces" ())
(declare-function drgnx-settings-workspace--old-entries "drgnx-settings-workspace" (root))

;;;; Groups

(defconst drgnx-settings-page-areas
  '((editor "Editor" "\\`drgnx-\\(?:edit\\|code\\|format\\|indent\\|lsp\\|completion\\|diff\\|git\\|snippet\\|large-files\\|spell\\|lint\\|fold\\)")
    (workbench "Workbench" nil)
    (agents "Agents" "\\`drgnx-\\(?:agents?\\|hub\\|cockpit\\|work\\|jobs\\)")
    (ai "AI" "\\`drgnx-\\(?:ai\\|embed\\|llm\\)")
    (search "Search" "\\`drgnx-\\(?:search\\|replace\\)")
    (files "Files" "\\`drgnx-\\(?:files?\\|recent\\|backup\\|autosave\\|trash\\|explorer\\|buffers\\|remote\\|project\\)")
    (look "Look" "\\`drgnx-\\(?:look\\|face\\|theme\\|font\\|colou?r\\|icon\\|zen\\|quickhelp\\|topline\\|statusbar\\|cursor\\)"))
  "The areas of drgnx's own settings: (ID LABEL REGEXP).  A drgnx variable goes to the first area whose REGEXP matches
its name; the one with no REGEXP (Workbench) takes the rest.  Keys and Modules are pages (`drgnx-settings-page-pages').")

(defconst drgnx-settings-page-pages
  '((keys "Keys" "\\`drgnx-keys?\\b") (modules "Modules" "\\`drgnx-modules?\\b"))
  "Areas that open a page of their own: (ID LABEL REGEXP).  Their variables belong to no area.")

(defun drgnx-settings-page-groups ()
  "The groups of the page, in order, as plists (:id :label :kind).  Kind `area' lists settings, `page' opens a page
\(Keys: the Keyboard Shortcuts; Modules: Preferences: Modules; Lisp files; History), `packages' and `emacs' ask for a
package or a built-in group, `workspace' lists what waits for trust or review."
  (append (mapcar (lambda (a) (list :id (car a) :label (nth 1 a) :kind 'area)) drgnx-settings-page-areas)
          (mapcar (lambda (a) (list :id (car a) :label (nth 1 a) :kind 'page)) drgnx-settings-page-pages)
          (list (list :id 'packages :label "Packages" :kind 'packages)
                (list :id 'emacs :label "Emacs" :kind 'emacs)
                (list :id 'workspace :label "Workspace" :kind 'workspace)
                (list :id 'lisp-files :label "Lisp files" :kind 'page)
                (list :id 'history :label "History" :kind 'page))))

(defvar drgnx-settings-page--all nil "Every customizable variable, sorted by name; nil until asked (cleared by a refresh).")

(defun drgnx-settings-page--all-vars ()
  "Every customizable variable (those with a standard value), sorted by name."
  (or drgnx-settings-page--all
      (let (out)
        (mapatoms (lambda (s) (when (and (get s 'standard-value) (not (get s 'byte-obsolete-variable)))
                                (push s out))))
        (setq out (append (drgnx-settings-described-vars) out))
        (setq drgnx-settings-page--all (sort (delete-dups out) (lambda (a b) (string< (symbol-name a) (symbol-name b))))))))

(defun drgnx-settings-page--page-of (var)
  "The page id (`keys', `modules') of drgnx variable VAR, or nil."
  (let ((name (symbol-name var)))
    (car (cl-find-if (lambda (p) (string-match-p (nth 2 p) name)) drgnx-settings-page-pages))))

(defun drgnx-settings-page--area-of (var)
  "The area id of drgnx variable VAR (nil for a variable of a page, or one that is not drgnx's)."
  (let ((name (symbol-name var)))
    (when (and (string-prefix-p "drgnx-" name) (not (drgnx-settings-page--page-of var)))
      (or (car (cl-find-if (lambda (a) (and (nth 2 a) (string-match-p (nth 2 a) name))) drgnx-settings-page-areas))
          'workbench))))

(defun drgnx-settings-page--lisp-file-p (file)
  "Non-nil when FILE is part of the Emacs that is running (its Lisp directory)."
  (and file (boundp 'lisp-directory) (stringp lisp-directory)
       (string-prefix-p (file-truename lisp-directory) (file-truename file))))

(defun drgnx-settings-page--group-members (group &optional seen)
  "The variables of the `defgroup' GROUP and of its subgroups, in name order."
  (let ((seen (or seen (make-hash-table :test 'eq))) out)
    (cl-labels ((walk (g)
                  (unless (gethash g seen)
                    (puthash g t seen)
                    (dolist (m (get g 'custom-group))
                      (pcase (cadr m)
                        ('custom-variable (push (car m) out))
                        ('custom-group (walk (car m))))))))
      (walk group))
    ;; Settings of packages not loaded yet (the sync-time index) and described `defvar's.
    (setq out (append (drgnx-settings-index-group-members group) (drgnx-settings-described-group-vars group) out))
    (sort (delete-dups out) (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun drgnx-settings-page-top-groups (builtin)
  "The top-level `defgroup's that are not drgnx's: those of Emacs's own Lisp when BUILTIN, else of packages."
  (let (out)
    (mapatoms (lambda (s)
                (when (and (get s 'custom-group) (get s 'group-documentation)
                           (not (string-prefix-p "drgnx" (symbol-name s)))
                           (eq (and builtin t)
                               (and (drgnx-settings-page--lisp-file-p (ignore-errors (symbol-file s 'defgroup))) t)))
                  (push s out))))
    (dolist (g (drgnx-settings-index-top-groups builtin)) (push g out))
    (sort (delete-dups out) (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun drgnx-settings-page--entries-of-root (root)
  "The variables with a top-level entry in ROOT's private or shared file."
  (let (out)
    (dolist (tab '(workspace shared))
      (when-let* ((doc (drgnx-settings-page--doc tab root)))
        (dolist (e (drgnx-settings-doc-entries doc))
          (when (and (null (drgnx-settings-entry-scope e)) (symbolp (drgnx-settings-entry-var e))
                     (not (keywordp (drgnx-settings-entry-var e))))
            (push (drgnx-settings-entry-var e) out)))))
    out))

(defun drgnx-settings-page-vars (group root)
  "The variables GROUP lists (a symbol, or a cons (area . ID), (package . G), (emacs . G)), sorted by name."
  (let ((vars
         (pcase group
           (`(area . ,id) (cl-remove-if-not (lambda (v) (eq (drgnx-settings-page--area-of v) id))
                                            (drgnx-settings-page--all-vars)))
           (`(,(or 'package 'emacs) . ,g) (drgnx-settings-page--group-members g))
           ('workspace (append (and root (mapcar (lambda (i) (plist-get i :var))
                                                 (ignore-errors (drgnx-settings-trust-waiting root))))
                               (and root (drgnx-settings-page--entries-of-root root))))
           ('all (drgnx-settings-page--all-vars)))))
    (sort (cl-remove-if-not #'symbolp (delete-dups (copy-sequence vars)))
          (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

;;;; Tabs and files

(defconst drgnx-settings-page-tab-labels '((user . "User") (workspace . "Workspace") (shared . "Shared")))

(defun drgnx-settings-page--project-p (root)
  "Non-nil when ROOT is a project: it has a repository marker, a .drgnx folder or a private workspace file."
  (and root (not (file-remote-p root))
       (or (locate-dominating-file root #'drgnx-settings-trust--marked-p)
           (file-directory-p (expand-file-name ".drgnx" root))
           (ignore-errors (drgnx-settings-workspace-file root)))
       t))

(defun drgnx-settings-page-tabs-for (var root)
  "The scope tabs VAR has: User always; Workspace and Shared too when VAR is not global and ROOT is a project."
  (if (and root (drgnx-settings-page--project-p root)
           (not (eq (plist-get (drgnx-setting-meta var) :scope) 'global)))
      '(user workspace shared)
    '(user)))

(defun drgnx-settings-page-default-tab (var root)
  "The tab VAR's row opens on: Workspace for a `buffer' or `project' row when ROOT is a project, else User."
  (if (and (memq (plist-get (drgnx-setting-meta var) :scope) '(buffer project))
           (drgnx-settings-page--project-p root))
      'workspace
    'user))

(defun drgnx-settings-page-tab-note (tab)
  "A line that says why TAB cannot be used, or nil."
  (when (and (memq tab '(workspace shared)) (null enable-local-variables))
    "Workspace settings are off: enable-local-variables is nil."))

(defun drgnx-settings-page--file (tab root)
  "(FILE . HEAD) of TAB's settings file for ROOT, or nil when there is none (yet)."
  (pcase tab
    ('user (cons (drgnx-config-file 'settings) 'drgnx-settings))
    ('workspace (when-let* ((f (and root (drgnx-settings-workspace-file root)))) (cons f 'drgnx-workspace-settings)))
    ('shared (when root (cons (expand-file-name drgnx-settings-workspace-shared-file root) 'drgnx-workspace-settings)))))

(defvar drgnx-settings-page--docs (make-hash-table :test 'equal)
  "(TAB . ROOT) → the settings doc read; emptied by every refresh and every write of a settings file.")

(defun drgnx-settings-page--doc (tab root)
  "The doc of TAB's file for ROOT (read as data, once per refresh), or nil."
  (let ((k (cons tab root)))
    (if-let* ((hit (gethash k drgnx-settings-page--docs)))
        (car hit)
      (let ((doc (when-let* ((f (drgnx-settings-page--file tab root)))
                   (and (file-exists-p (car f))
                        (condition-case nil (drgnx-settings-file-read (car f) (cdr f)) (error nil))))))
        (puthash k (list doc) drgnx-settings-page--docs)
        doc))))

(defun drgnx-settings-page--entry (var tab root &optional all)
  "VAR's top-level entry in TAB's file for ROOT (with ALL: every entry of VAR, scoped ones too, as a list)."
  (when-let* ((doc (drgnx-settings-page--doc tab root)))
    (let ((es (cl-remove-if-not (lambda (e) (and (eq (drgnx-settings-entry-var e) var)
                                                 (or all (null (drgnx-settings-entry-scope e)))))
                                (drgnx-settings-doc-entries doc))))
      (if all es (car es)))))

;;;; Rows

(defun drgnx-settings-page--title (var)
  "VAR's title: its name in words."
  (let ((name (replace-regexp-in-string "\\`drgnx-" "" (symbol-name var))))
    (capitalize (replace-regexp-in-string "[-/]" " " name))))

(defun drgnx-settings-page--first-sentence (var)
  "The first sentence of VAR's documentation, one line."
  (let* ((doc (or (ignore-errors (documentation-property var 'variable-documentation t))
                  (plist-get (drgnx-settings-described var) :doc)
                  (drgnx-settings-index-doc var) ""))
         (doc (replace-regexp-in-string "\\`\\*" "" doc))
         (doc (replace-regexp-in-string "[ \t\n]+" " " (string-trim doc)))
         (end (and (string-match "[.!?]\\(?: \\|\\'\\)" doc) (match-end 0)))
         (s (string-trim (if end (substring doc 0 end) doc))))
    (if (> (length s) 220) (concat (substring s 0 219) "…") s)))

(defun drgnx-settings-page--value-text (value)
  "VALUE as one short line."
  (let* ((print-length 8) (print-level 3) (s (prin1-to-string value)))
    (if (> (length s) 80) (concat (substring s 0 79) "…") s)))

(defun drgnx-settings-page--line-text (file line)
  "The text of FILE's line LINE, trimmed (nil when it cannot be read)."
  (when (and file line (file-readable-p file))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file nil 0 400000)
        (forward-line (1- line))
        (let ((s (string-trim (buffer-substring (line-beginning-position) (line-end-position)))))
          (if (> (length s) 100) (concat (substring s 0 99) "…") s))))))

(defun drgnx-settings-page--modified-in (var explain root)
  "The names of the layers that set VAR: User, Workspace, Shared, your Lisp, Customize, module, this session."
  (let (out)
    (when (drgnx-settings-page--entry var 'user root t) (push "User" out))
    (when root
      (when (drgnx-settings-page--entry var 'workspace root t) (push "Workspace" out))
      (when (drgnx-settings-page--entry var 'shared root t) (push "Shared" out)))
    (dolist (l (plist-get explain :layers))
      (pcase (plist-get l :kind)
        ((or 'lisp 'deferred 'use-package 'package) (cl-pushnew "your Lisp" out :test #'equal))
        ('customize (cl-pushnew "Customize" out :test #'equal))
        ('module (cl-pushnew "module" out :test #'equal))
        ('session (cl-pushnew "this session" out :test #'equal))))
    (nreverse out)))

(defun drgnx-settings-page--overridden (var explain tab root)
  "When VAR's entry at TAB is not what Emacs has because a higher layer wins (§4.3): (:by :file :line :text :value
:yours :customize), else nil.  Only User tab entries are explained (the workspace layers are above)."
  (when (eq tab 'user)
    (let ((entry (drgnx-settings-page--entry var 'user root)) (kind (plist-get explain :kind)))
      (when (and entry (memq kind '(lisp deferred use-package package customize session)))
        (list :by (if (eq kind 'customize) "Customize" (if (eq kind 'session) "Lisp, this session" "Your Lisp"))
              :customize (eq kind 'customize)
              :file (plist-get explain :file) :line (plist-get explain :line)
              :text (drgnx-settings-page--line-text (plist-get explain :file) (plist-get explain :line))
              :value (plist-get explain :value) :yours (drgnx-settings-entry-value entry))))))

(defun drgnx-settings-page-row (var tab root &optional buffer)
  "The data of VAR's row at TAB for ROOT: a plist (:var :title :doc :scope :tab :global-only :entry-p :tab-value
:effective :source :file :line :kind :modified-in :overridden :code :locked)."
  (let* ((meta (drgnx-setting-meta var))
         (explain (ignore-errors (drgnx-settings-explain var (if (buffer-live-p buffer) buffer (current-buffer)))))
         (entry (drgnx-settings-page--entry var tab root))
         (scope (plist-get meta :scope)))
    (list :var var :title (drgnx-settings-page--title var) :doc (drgnx-settings-page--first-sentence var)
          :scope scope :tab tab
          :global-only (and (eq scope 'global) (not (eq tab 'user)))
          :entry-p (and entry t) :tab-value (and entry (drgnx-settings-entry-value entry))
          :effective (plist-get explain :value) :source (plist-get explain :source)
          :file (plist-get explain :file) :line (plist-get explain :line) :certain (plist-get explain :certain)
          :kind (plist-get explain :kind) :layer (plist-get explain :layer)
          :modified-in (drgnx-settings-page--modified-in var explain root)
          :overridden (drgnx-settings-page--overridden var explain tab root)
          :code (eq (plist-get meta :workspace) 'code)
          :locked (and (memq tab '(workspace shared)) (null enable-local-variables)))))

;;;; Search and filters

(defun drgnx-settings-page-parse-query (query)
  "QUERY as (TERMS . FILTERS): the plain words (lower case) and the filters as (NAME . ARG) for each @name[:arg]."
  (let (terms filters)
    (dolist (w (split-string (or query "") "[ \t]+" t))
      (if (string-match "\\`@\\([a-z-]+\\)\\(?::\\(.*\\)\\)?\\'" w)
          (push (cons (intern (match-string 1 w)) (match-string 2 w)) filters)
        (push (downcase w) terms)))
    (cons (nreverse terms) (nreverse filters))))

(defun drgnx-settings-page--package-match-p (var name)
  "Non-nil when VAR belongs to the package NAME (its file's name or its prefix)."
  (let ((file (ignore-errors (symbol-file var 'defvar))) (name (downcase name)))
    (or (and file (string-match-p (regexp-quote name) (downcase (file-name-base file))))
        (string-prefix-p (concat name "-") (downcase (symbol-name var))))))

(defun drgnx-settings-page-filter-match-p (row filter root)
  "Whether ROW (`drgnx-settings-page-row') passes FILTER, (NAME . ARG) from `drgnx-settings-page-parse-query'."
  (let ((var (plist-get row :var)) (arg (cdr filter)))
    (pcase (car filter)
      ('modified (and (plist-get row :modified-in) t))
      ('overridden (and (plist-get row :overridden) t))
      ('runtime (and (plist-get (drgnx-setting-meta var) :runtime) t))
      ('source (let ((kind (plist-get row :kind)))
                 (pcase arg
                   ("lisp" (and (memq kind '(lisp deferred use-package package)) t))
                   ("customize" (eq kind 'customize))
                   ("settings" (eq kind 'settings))
                   ("module" (eq kind 'module))
                   ("workspace" (and (member "Workspace" (plist-get row :modified-in)) t))
                   (_ nil))))
      ('package (and arg (drgnx-settings-page--package-match-p var arg)))
      ('needs-trust (and root (eq (drgnx-settings-trust-state root) 'untrusted)
                         (drgnx-settings-page--entry var 'shared root t) t))
      ('needs-review (and root (not (eq (drgnx-settings-trust-state root) 'untrusted))
                          (cl-some (lambda (i) (eq (plist-get i :var) var))
                                   (ignore-errors (drgnx-settings-trust-waiting root)))
                          t))
      ('lang (and arg
                  (cl-some (lambda (e)
                             (let ((m (alist-get :mode (drgnx-settings-entry-scope e))))
                               (and m (string-match-p (concat "\\`" (regexp-quote arg) "\\(?:-mode\\)?\\'")
                                                      (symbol-name m)))))
                           (drgnx-settings-page--entry var 'user root t))))
      (_ nil))))

(defun drgnx-settings-page--text-match-p (var terms)
  "Whether every one of TERMS is in VAR's name, title, documentation or value."
  (or (null terms)
      (let ((hay (downcase (string-join (list (symbol-name var) (drgnx-settings-page--title var)
                                              (or (ignore-errors (documentation-property var 'variable-documentation t)) "")
                                              (if (default-boundp var) (drgnx-settings-page--value-text (default-value var)) ""))
                                        " "))))
        (cl-every (lambda (term) (string-search term hay)) terms))))

(defun drgnx-settings-page-select (group query tab root &optional buffer)
  "The variables to list: GROUP's (or, with a QUERY, all customizable ones) that match QUERY, sorted by name.
TAB is the explicit tab (nil: each row's default).  Cheap text terms first, then the filters."
  (let* ((q (drgnx-settings-page-parse-query query))
         (vars (drgnx-settings-page-vars (if (and (or (car q) (cdr q)) t) 'all group) root))
         (vars (cl-remove-if-not (lambda (v) (drgnx-settings-page--text-match-p v (car q))) vars)))
    (if (null (cdr q)) vars
      (cl-remove-if-not
       (lambda (v)
         (let ((row (drgnx-settings-page-row v (or tab (drgnx-settings-page-default-tab v root)) root buffer)))
           (cl-every (lambda (f) (drgnx-settings-page-filter-match-p row f root)) (cdr q))))
       vars))))

;;;; Actions

(defun drgnx-settings-page-reset (var tab root)
  "Reset VAR at TAB: remove this scope's entry of VAR (its top-level one; a language or directory entry stays) from
the tab's file.  Refused for a global setting at a workspace tab.  Returns t when an entry was removed."
  (when (and (memq tab '(workspace shared)) (eq (plist-get (drgnx-setting-meta var) :scope) 'global))
    (user-error "%s is one value for all of Emacs: it has no workspace entry" var))
  (let ((f (drgnx-settings-page--file tab root)))
    (prog1 (and f (file-exists-p (car f)) (drgnx-settings-page--entry var tab root)
                (progn (drgnx-settings-file-remove (car f) (cdr f) nil var) t))
      (clrhash drgnx-settings-page--docs))))

(defun drgnx-settings-page-convert (root)
  "Write ROOT's old project files (.drgnx/search.eld, ai.eld, large-files.eld) as entries of .drgnx/settings.el, and
move each old file to .drgnx/migrated-DATE/.  Returns the number of entries written."
  (let* ((entries (drgnx-settings-workspace--old-entries root))
         (file (expand-file-name drgnx-settings-workspace-shared-file root))
         (n 0))
    (when entries
      (dolist (e entries)
        (unless (drgnx-settings-page--entry (drgnx-settings-entry-var e) 'shared root)
          (drgnx-settings-file-put file 'drgnx-workspace-settings nil (drgnx-settings-entry-var e)
                                   (drgnx-settings-entry-value e) :merge (drgnx-settings-entry-merge e))
          (cl-incf n)))
      (let ((dest (expand-file-name (format-time-string "migrated-%Y-%m-%d" nil t)
                                    (expand-file-name ".drgnx" root))))
        (dolist (name (mapcar #'car drgnx-settings-workspace-old-files))
          (when (drgnx-config-defined-p name)
            (let ((old (drgnx-config-file name root)))
              (when (file-exists-p old)
                (make-directory dest t)
                (rename-file old (expand-file-name (file-name-nondirectory old) dest) t)))))))
    (clrhash drgnx-settings-page--docs)
    n))

(defun drgnx-settings-page--option-id (var tab root)
  "The history id of VAR's entry at TAB, or nil when it is not known."
  (pcase tab
    ('user (format "option:global:%s" var))
    (_ (when-let* ((p (and root (car-safe (drgnx-settings-workspace-project root)))))
         (format "option:%s/%s:%s" (if (eq tab 'shared) "shared" "private") p var)))))

;;;; Drawing

(defvar drgnx-settings-page-editor-function #'drgnx-settings-page-editor-slot
  "Draws a row's editor: called with the row (`drgnx-settings-page-row'), returns a string.  Task 27 replaces it.")

(defun drgnx-settings-page-editor-slot (row)
  "The editor slot of ROW until the editors exist: the value at the tab, as plain text."
  (cond ((plist-get row :global-only) "")
        (t (format "Value: %s" (drgnx-settings-page--value-text
                                (if (plist-get row :entry-p) (plist-get row :tab-value) (plist-get row :effective)))))))

(defun drgnx-settings-page--button (label fn &optional help)
  "A button with LABEL that calls FN."
  (make-text-button (format "[%s]" label) nil 'action (lambda (_) (funcall fn)) 'follow-link t
                    'help-echo (or help label) 'face 'link))

(defun drgnx-settings-page--visit (file line)
  "Open FILE at LINE."
  (find-file file)
  (when line (goto-char (point-min)) (forward-line (1- line))))

(defun drgnx-settings-page--source-text (row)
  "ROW's effective value with its source, the file:line a button."
  (let ((file (plist-get row :file)) (line (plist-get row :line)))
    (concat (format "Effective: %s" (drgnx-settings-page--value-text (plist-get row :effective)))
            (when-let* ((s (plist-get row :source))) (format "  from %s" s))
            (cond ((and file line)
                   (concat "  " (drgnx-settings-page--button
                                 (format "%s:%d" (file-name-nondirectory file) line)
                                 (lambda () (drgnx-settings-page--visit file line)) "Open at the line")))
                  (file "  line unknown")
                  (t "")))))

(defun drgnx-settings-page--override-text (row)
  "ROW's §4.3 message with its actions, or nil."
  (when-let* ((o (plist-get row :overridden)) (var (plist-get row :var)))
    (let ((file (plist-get o :file)) (line (plist-get o :line)))
      (concat
       (propertize (if (plist-get o :customize) "Customize sets this" (format "%s sets this" (plist-get o :by))) 'face 'bold)
       (format " (%s%s), so %s stays in effect. Your change (%s) is saved in Settings and applies if you remove that %s. "
               (if file (format "%s:%s" (file-name-nondirectory file) (or line "line unknown")) "line unknown")
               (if (plist-get o :text) (format ": `%s'" (plist-get o :text)) "")
               (drgnx-settings-page--value-text (plist-get o :value))
               (drgnx-settings-page--value-text (plist-get o :yours))
               (if (plist-get o :customize) "entry" "line"))
       (if (and file line)
           (concat (drgnx-settings-page--button (format "Open %s:%d" (file-name-nondirectory file) line)
                                                (lambda () (drgnx-settings-page--visit file line)))
                   " ")
         "")
       (drgnx-settings-page--button (if (plist-get o :customize) "Move from custom.el into Settings" "Move into Settings")
                                    (lambda () (drgnx-settings-move-into-settings var)))))))

(defun drgnx-settings-page-row-text (row)
  "ROW drawn as text: title and chips, documentation, editor, effective value and source, the message, actions.
Ends with a blank line."
  (let ((var (plist-get row :var)) (tab (plist-get row :tab)) (root (and (boundp 'drgnx-settings-page--root) drgnx-settings-page--root)))
    (concat
     (propertize (plist-get row :title) 'face 'bold)
     (when (plist-get row :modified-in)
       (propertize (format "   Modified in: %s" (string-join (plist-get row :modified-in) ", ")) 'face 'shadow))
     (when (plist-get row :code) (propertize "   code" 'face 'warning))
     (format "   %s\n" (propertize (symbol-name var) 'face 'shadow))
     (when (> (length (plist-get row :doc)) 0) (format "  %s\n" (plist-get row :doc)))
     (cond ((plist-get row :global-only) (propertize "  one value for all of Emacs\n" 'face 'shadow))
           ((plist-get row :locked) (propertize "  workspace settings are off (enable-local-variables is nil)\n" 'face 'shadow))
           (t (let ((ed (funcall drgnx-settings-page-editor-function row)))
                (if (> (length ed) 0) (format "  %s\n" ed) ""))))
     (format "  %s\n" (drgnx-settings-page--source-text row))
     (when-let* ((m (drgnx-settings-page--override-text row))) (format "  %s\n" m))
     "  "
     (unless (or (plist-get row :global-only) (not (plist-get row :entry-p)))
       (concat (drgnx-settings-page--button "Reset" (lambda () (drgnx-settings-page-reset var tab root)
                                                      (drgnx-settings-page-refresh))
                                            (format "Remove %s's entry from the %s tab" var tab))
               " "))
     (drgnx-settings-page--button "History" (lambda () (drgnx-settings-page-history var tab root)))
     "\n\n")))

;;;; The buffer

(defvar-local drgnx-settings-page--root nil "The workspace root the page was opened from, or nil.")
(defvar-local drgnx-settings-page--origin nil "The buffer the page was opened from (explains buffer-local values).")
(defvar-local drgnx-settings-page--tab nil "The explicit tab, or nil: each row's default.")
(defvar-local drgnx-settings-page--group '(area . editor) "The group listed.")
(defvar-local drgnx-settings-page--query "" "The search text with its filters.")
(defvar-local drgnx-settings-page--keys nil "The variables listed now.")
(defvar-local drgnx-settings-page--rev 0 "Counts refreshes: a row's signature, so each is drawn again.")
(defvar-local drgnx-settings-page--rows nil "Var → row data of this refresh (a hash table).")

(defun drgnx-settings-page--row-data (var)
  "VAR's row data for this page, once per refresh."
  (or (gethash var drgnx-settings-page--rows)
      (puthash var (drgnx-settings-page-row var (or drgnx-settings-page--tab (drgnx-settings-page-default-tab var drgnx-settings-page--root))
                                            drgnx-settings-page--root drgnx-settings-page--origin)
               drgnx-settings-page--rows)))

(defun drgnx-settings-page--render (var)
  "The text of VAR's row."
  (drgnx-settings-page-row-text (drgnx-settings-page--row-data var)))

(defun drgnx-settings-page--sync (view)
  "Make VIEW's rows the variables selected now."
  (with-current-buffer (drgnx-view--buffer view)
    (drgnx-view-sync-rows view drgnx-settings-page--keys (lambda (_key) drgnx-settings-page--rev))))

(drgnx-view-define 'drgnx-settings-page :render #'drgnx-settings-page--render :sync #'drgnx-settings-page--sync
                   :slice drgnx-view-slice :key-test 'eq)

(defun drgnx-settings-page--group-label (group)
  "GROUP's name for the header."
  (pcase group
    (`(area . ,id) (nth 1 (assq id drgnx-settings-page-areas)))
    (`(package . ,g) (format "Package %s" g))
    (`(emacs . ,g) (format "Emacs %s" g))
    ('workspace "Workspace")
    (_ (format "%s" group))))

(defun drgnx-settings-page--other-tools-text (root)
  "The Other tools block for ROOT: the files of other tools there, each with [Open]; nothing is imported."
  (when-let* ((files (drgnx-settings-index-other-tools-in root)))
    (concat (propertize "Other tools (their own files; nothing imported)\n" 'face 'bold)
            (mapconcat (lambda (f)
                         (concat "  " (file-name-nondirectory f) "  "
                                 (drgnx-settings-page--button "Open" (lambda () (find-file f)) (format "Open %s" f))))
                       files "\n")
            "\n\n")))

(defun drgnx-settings-page--header ()
  "The text above the rows."
  (let* ((root drgnx-settings-page--root)
         (tabs (propertize "Scope: " 'face 'shadow)))
    (dolist (tab '(user workspace shared))
      (setq tabs (concat tabs
                         (if (eq tab (or drgnx-settings-page--tab 'auto))
                             (propertize (format "%s" (alist-get tab drgnx-settings-page-tab-labels)) 'face '(bold underline))
                           (drgnx-settings-page--button (alist-get tab drgnx-settings-page-tab-labels)
                                                        (lambda () (drgnx-settings-page-set-tab tab))))
                         "  ")))
    (setq tabs (concat tabs (if drgnx-settings-page--tab "" (propertize "(each row's own)" 'face 'shadow))))
    (concat (propertize "Settings\n" 'face 'bold)
            tabs "\n"
            (propertize "Group: " 'face 'shadow)
            (mapconcat (lambda (g)
                         (let ((id (plist-get g :id)) (label (plist-get g :label)))
                           (if (equal (drgnx-settings-page--group-label drgnx-settings-page--group) label)
                               (propertize label 'face '(bold underline))
                             (drgnx-settings-page--button label (lambda () (drgnx-settings-page-set-group id))))))
                       (drgnx-settings-page-groups) " ")
            (if (memq (car-safe drgnx-settings-page--group) '(package emacs))
                (format "  (%s)" (drgnx-settings-page--group-label drgnx-settings-page--group)) "")
            "\n"
            (propertize "Search: " 'face 'shadow)
            (if (string-empty-p drgnx-settings-page--query) (propertize "(s to search; @modified @overridden @source:lisp @package:NAME @runtime @needs-trust @needs-review @lang:MODE)" 'face 'shadow)
              drgnx-settings-page--query)
            "\n"
            (when-let* ((n (drgnx-settings-page-tab-note (or drgnx-settings-page--tab 'workspace))))
              (when (memq drgnx-settings-page--tab '(workspace shared)) (propertize (concat n "\n") 'face 'warning)))
            (when (eq drgnx-settings-page--group 'workspace) (drgnx-settings-page--other-tools-text root))
            (format "%d settings%s\n\n" (length drgnx-settings-page--keys)
                    (if (and root (memq drgnx-settings-page--tab '(workspace shared)))
                        (format ", workspace %s" (abbreviate-file-name root)) "")))))

(defvar-keymap drgnx-settings-page-mode-map
  :doc "The Settings page's keys: the key profiles bind its commands here (keys/*.eld)."
  :parent special-mode-map)

(define-derived-mode drgnx-settings-page-mode special-mode "Settings"
  "Preferences: Settings, every setting by scope, group and search."
  (setq-local revert-buffer-function (lambda (&rest _) (drgnx-settings-page-refresh))))

(defun drgnx-settings-page--draw-header ()
  "Replace the text above the rows, keeping the view's start in step."
  (let* ((inhibit-read-only t) (start (and (drgnx-view-p drgnx-view) (drgnx-view--start drgnx-view)))
         (old-end (if start (marker-position start) (point-min)))
         (new (drgnx-settings-page--header)))
    ;; New header in front of the old one (the view's start moves with it), then the old one goes.
    (save-excursion
      (goto-char (point-min))
      (insert new)
      (delete-region (+ (point-min) (length new)) (+ old-end (length new))))))

(defun drgnx-settings-page-refresh ()
  "Read the files and the variables again and redraw: the header and the rows (the visible ones first)."
  (interactive)
  (when (derived-mode-p 'drgnx-settings-page-mode)
    (clrhash drgnx-settings-page--docs)
    (setq drgnx-settings-page--all nil)
    (setq drgnx-settings-page--rows (make-hash-table :test 'eq))
    (setq drgnx-settings-page--keys
          (condition-case err
              (drgnx-settings-page-select drgnx-settings-page--group drgnx-settings-page--query drgnx-settings-page--tab
                                          drgnx-settings-page--root drgnx-settings-page--origin)
            (error (message "Settings: %s" (error-message-string err)) nil)))
    (cl-incf drgnx-settings-page--rev)
    (drgnx-settings-page--draw-header)
    (when (drgnx-view-p drgnx-view) (drgnx-view-touch drgnx-view))
    (current-buffer)))

(defun drgnx-settings-page--buffer ()
  "The page's buffer, made and attached to its view."
  (let ((buf (get-buffer-create "*drgnx settings*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'drgnx-settings-page-mode)
        (drgnx-settings-page-mode)
        (let ((inhibit-read-only t)) (erase-buffer) (insert "\n"))
        (drgnx-view-attach 'drgnx-settings-page :start (point-max))))
    buf))

(defun drgnx-settings-page-set-tab (tab)
  "Show TAB (user, workspace, shared; nil: each row's own) in the page."
  (setq drgnx-settings-page--tab tab)
  (drgnx-settings-page-refresh))

(defun drgnx-settings-page-set-group (id &optional sub)
  "List the group ID (see `drgnx-settings-page-groups'); SUB names the package or built-in group for `packages' and
`emacs' (asked for when nil).  A page (Keys, Modules, Lisp files, History) is shown in the window instead.  Returns
the buffer shown."
  (let* ((g (cl-find id (drgnx-settings-page-groups) :key (lambda (g) (plist-get g :id))))
         (kind (plist-get g :kind)))
    (pcase kind
      ('page (drgnx-settings-page--show-page id))
      (_
       (setq drgnx-settings-page--group
             (pcase kind
               ('area (cons 'area id))
               ('workspace 'workspace)
               ('packages (cons 'package (or sub (drgnx-settings-page--ask-group nil))))
               ('emacs (cons 'emacs (or sub (drgnx-settings-page--ask-group t))))
               (_ (error "No group %S" id))))
       (drgnx-settings-page-refresh)))))

(defun drgnx-settings-page--ask-group (builtin)
  "Ask for a package group (or, with BUILTIN, a group of Emacs)."
  (intern (completing-read (if builtin "Emacs group: " "Package: ")
                           (mapcar #'symbol-name (drgnx-settings-page-top-groups builtin)) nil t)))

(defun drgnx-settings-page--show-page (id)
  "Show the page ID in this window: Keys, Modules, Lisp files or History.  Its buffer."
  (let ((buf (pcase id
               ('keys (progn (require 'drgnx-surfaces) (drgnx-surfaces-cheatsheet) (current-buffer)))
               ('modules (drgnx-modules-list))
               ('lisp-files (drgnx-settings-lisp-files))
               ('history (drgnx-settings-page-history nil nil nil)))))
    (when (and (bufferp buf) (not (eq buf (current-buffer)))) (switch-to-buffer buf))
    buf))

;;;; History

(defun drgnx-settings-page-history (var tab root)
  "The recorded changes of VAR (all settings when VAR is nil) in a buffer, newest first, each with an Undo.  The
hub records them (Task 25): without it the buffer says so.  Its buffer."
  (let ((buf (get-buffer-create "*drgnx settings history*"))
        (changes (condition-case err
                     (drgnx-settings-history-list :name (and var (symbol-name var))
                                                  :scope (and var (let ((id (drgnx-settings-page--option-id var tab root)))
                                                                    (and id (string-match "\\`option:\\([^:]+\\):" id)
                                                                         (match-string 1 id)))))
                   (error err))))
    (with-current-buffer buf
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (if var (format "History of %s\n\n" var) "History of settings\n\n") 'face 'bold))
        (cond ((and (consp changes) (eq (car changes) 'error) (not (plistp changes)))
               (insert (format "The history is not available now: %s\n" (error-message-string changes))))
              ((null changes) (insert "No recorded changes.\n"))
              (t (dolist (c changes)
                   (insert (format "%s  %s  %s  %s  "
                                   (let ((at (plist-get c :at)))
                                     (if (numberp at) (format-time-string "%Y-%m-%d %H:%M" at) (or at "")))
                                   (or (plist-get c :actor) "?") (or (plist-get c :class) "")
                                   (mapconcat (lambda (f) (format "%s" f)) (plist-get c :fields) " "))
                           (let ((id (plist-get c :id)))
                             (drgnx-settings-page--button "Undo" (lambda () (drgnx-settings-page-undo id))))
                           "\n")))))
      (goto-char (point-min)))
    (when (called-interactively-p 'any) (pop-to-buffer buf))
    (unless var (ignore-errors (pop-to-buffer buf)))
    buf))

(defun drgnx-settings-page-undo (&optional id)
  "Settings: Undo: put the previous value of the setting ID (an option id) back.  On the Settings page without an
ID it undoes the setting of the row at point; elsewhere it asks which of the recent changes."
  (interactive)
  (let ((id (or id
                (when-let* ((var (and (derived-mode-p 'drgnx-settings-page-mode) (drgnx-view-key-at))))
                  (drgnx-settings-page--option-id var (or drgnx-settings-page--tab (drgnx-settings-page-default-tab var drgnx-settings-page--root))
                                                  drgnx-settings-page--root))
                (completing-read "Undo the latest change of: "
                                 (delete-dups (mapcar (lambda (c) (plist-get c :id)) (drgnx-settings-history-list))) nil t))))
    (prog1 (drgnx-settings-undo id)
      (clrhash drgnx-settings-page--docs)
      (drgnx-settings-page--refresh-all))))

;;;; Commands

(defun drgnx-settings-page (&optional group)
  "Preferences: Settings: one page for every setting, by scope, group and search.  GROUP (a symbol of
`drgnx-settings-page-groups') opens that group.  The page's buffer."
  (interactive)
  (let* ((origin (current-buffer))
         (root (ignore-errors (drgnx-settings-trust--buffer-root)))
         (buf (drgnx-settings-page--buffer)))
    (with-current-buffer buf
      (setq drgnx-settings-page--origin origin drgnx-settings-page--root root)
      (if (and group (not (eq group 'editor)))
          (drgnx-settings-page-set-group group)
        (drgnx-settings-page-refresh)))
    (if (and group (memq group '(keys modules lisp-files history)))
        (current-buffer)
      (when (called-interactively-p 'any) (pop-to-buffer-same-window buf))
      buf)))

(defun drgnx-settings-page-tab ()
  "Settings: cycle the scope tab: each row's own, User, Workspace, Shared."
  (interactive)
  (drgnx-settings-page-set-tab (pcase drgnx-settings-page--tab ('nil 'user) ('user 'workspace) ('workspace 'shared) (_ nil))))

(defun drgnx-settings-page-group ()
  "Settings: choose the group to list."
  (interactive)
  (let* ((gs (drgnx-settings-page-groups))
         (label (completing-read "Group: " (mapcar (lambda (g) (plist-get g :label)) gs) nil t))
         (g (cl-find label gs :key (lambda (g) (plist-get g :label)) :test #'equal)))
    (drgnx-settings-page-set-group (plist-get g :id))))

(defun drgnx-settings-page-search (query)
  "Settings: search the settings for QUERY: words (name, title, documentation, value) and @filters."
  (interactive (list (read-string "Search settings (@modified @overridden @source:… @package:… @runtime @needs-trust @needs-review @lang:…): "
                                  drgnx-settings-page--query)))
  (setq drgnx-settings-page--query query)
  (drgnx-settings-page-refresh))

(defun drgnx-settings-page-reset-at-point ()
  "Settings: reset the setting of this row: remove this scope's entry from the tab's file."
  (interactive)
  (let ((var (or (drgnx-view-key-at) (user-error "Settings: no setting on this line"))))
    (drgnx-settings-page-reset var (or drgnx-settings-page--tab (drgnx-settings-page-default-tab var drgnx-settings-page--root))
                               drgnx-settings-page--root)
    (drgnx-settings-page-refresh)))

(defun drgnx-settings-page-history-at-point ()
  "Settings: the history of this row's setting."
  (interactive)
  (let ((var (or (drgnx-view-key-at) (user-error "Settings: no setting on this line"))))
    (pop-to-buffer (drgnx-settings-page-history var (or drgnx-settings-page--tab (drgnx-settings-page-default-tab var drgnx-settings-page--root))
                                                drgnx-settings-page--root))))

(defun drgnx-settings-page-open-source ()
  "Settings: open the file of this row's winning value at its line."
  (interactive)
  (let* ((var (or (drgnx-view-key-at) (user-error "Settings: no setting on this line")))
         (row (drgnx-settings-page--row-data var)))
    (if-let* ((file (plist-get row :file)))
        (drgnx-settings-page--visit file (plist-get row :line))
      (user-error "Settings: the source of %s has no file (line unknown)" var))))

(defun drgnx-settings-page-convert-old-files ()
  "Settings: convert this project's old files (.drgnx/search.eld …) to .drgnx/settings.el on the Shared tab."
  (interactive)
  (let ((root (or drgnx-settings-page--root (user-error "Settings: this page is not for a project"))))
    (message "Settings: %d entries written to .drgnx/settings.el" (drgnx-settings-page-convert root))
    (drgnx-settings-page-refresh)))

;;;; Live

(defun drgnx-settings-page--refresh-all (&rest _)
  "Draw every open Settings page again (a settings file was written)."
  (clrhash drgnx-settings-page--docs)
  (dolist (b (buffer-list))
    (when (and (buffer-live-p b) (eq (buffer-local-value 'major-mode b) 'drgnx-settings-page-mode))
      (with-current-buffer b (ignore-errors (drgnx-settings-page-refresh))))))

(add-hook 'drgnx-settings-file-written-functions #'drgnx-settings-page--refresh-all)

(require 'drgnx-settings-editors)

(provide 'drgnx-settings-page)
;;; drgnx-settings-page.el ends here
