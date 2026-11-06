;;; drgnx-extensions-details.el --- Extension details pages, generations and rollback -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The page of one extension: what it is, where it comes from and how far to trust that, why it is here, and tabs for
;; its readme, changes, settings, dependencies and files.  A package that is installed shows its own text (the
;; `;;; Commentary:' of its main file, its README and NEWS files) as plain text: no mode function runs on it, no local
;; variable is applied, nothing is fontified.  Text fetched from an archive, a reviewed update and the files of a
;; package that is not installed go through the trust layer's inert text (drgnx-extensions-trust.el).  The page is a
;; view of four rows (header, actions, tabs, body) drawn from state kept in the page's buffer.  The Generations section
;; of the list (the packages as they were after each change, and Roll back) is here too.  See docs/guide/extensions.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-view)
(require 'drgnx-ui-kit)
(require 'drgnx-guard)
(unless (featurep 'drgnx-extensions-list)
  (load (expand-file-name "drgnx-extensions-list" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-extensions--before-install "drgnx-extensions-list")
(declare-function drgnx-extensions-list--name "drgnx-extensions-list")
(declare-function drgnx-extensions-list--normalize "drgnx-extensions-list")
(declare-function drgnx-extensions-list--trust "drgnx-extensions-list")
(declare-function drgnx-extensions-show-log "drgnx-extensions-list")
(defvar drgnx-extensions-list--rows)
(defvar drgnx-extensions-list--root)
(defvar drgnx-extensions-project-global-text)
(declare-function drgnx-extensions-list-note-root "drgnx-extensions-list")
(declare-function drgnx-extensions-project-describe "drgnx-extensions-project" (pkg root))
(declare-function drgnx-extensions-project-scope "drgnx-extensions-project" (pkg))
(declare-function drgnx-extensions-project-off-p "drgnx-extensions-project" (pkg root))
(declare-function drgnx-extensions-project-toggle "drgnx-extensions-project" (pkg root))

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-extensions--update "drgnx-extensions-list")
(declare-function drgnx-extensions-trust-apply "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-discard "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-fetch-readme "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-inert-string "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-list-files "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-review "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-review-text "drgnx-extensions-trust")
(declare-function drgnx-extensions-jobs-queue "drgnx-extensions-jobs")
(declare-function drgnx-extensions-jobs-run "drgnx-extensions-jobs")
(declare-function drgnx-plugins-page-insert "drgnx-plugins-ui")
(declare-function drgnx-extensions-plugins-page-text "drgnx-extensions-plugins")
(declare-function drgnx-extensions-plugins-actions "drgnx-extensions-plugins")
(declare-function drgnx-extensions-plugins-opened "drgnx-extensions-plugins")
(declare-function drgnx-settings-editors-commit "drgnx-settings-editors")
(declare-function drgnx-settings-page-package-count "drgnx-settings-page")
(declare-function drgnx-settings-page-show-package "drgnx-settings-page")
(declare-function drgnx-pkg-generations "drgnx-pkg")
(declare-function drgnx-pkg-generations-in-use "drgnx-pkg-progress")
(declare-function drgnx-pkg-current-generation "drgnx-pkg")
(declare-function drgnx-pkg-copies-p "drgnx-pkg-progress")
(declare-function drgnx-pkg--read-file "drgnx-pkg")
(declare-function drgnx-pkg--generation-dir "drgnx-pkg")
(declare-function drgnx-pkg--git-cache "drgnx-pkg")
(declare-function drgnx-user-config-file "drgnx")
(defvar drgnx-modules-disabled)
(defvar drgnx-modules-enabled)

(defconst drgnx-extensions-details-preview-name "*Extension*" "The preview page: the next page replaces it.")

(defvar-local drgnx-extensions-details--id nil "The id of the extension this page shows.")
(defvar-local drgnx-extensions-details--info nil "The hub's `extensions/details' answer for the id, once it came.")
(defvar-local drgnx-extensions-details--error nil "What the hub said when it could not answer, or nil.")
(defvar-local drgnx-extensions-details--tab 'readme "The tab shown: readme, changes, settings, dependencies or files.")
(defvar-local drgnx-extensions-details--log nil "The text of `git log' for a Git package, once its process ended.")
(defvar-local drgnx-extensions-details--readme nil
  "The readme job of a package that is not installed: (:state S :job ID :error TEXT), S `fetching', `fetched' or
`failed'; nil before one was needed.")
(defvar-local drgnx-extensions-details--readme-text nil "(README . its inert text): the readme the hub sent, made inert once.")
(defvar-local drgnx-extensions-details--files nil
  "The file list of a package that is not installed, from its cached archive: (:state S :text TEXT :error TEXT), S
`listing', `ready' or `failed'.")

(defvar drgnx-extensions-details-mode-map (make-sparse-keymap) "Keys of an extension page.")

(define-derived-mode drgnx-extensions-details-mode special-mode "Extension"
  "The page of one extension."
  (setq-local truncate-lines nil cursor-type nil)
  (buffer-disable-undo))

;;;; What a page says, in words

(defun drgnx-extensions-details--ensure-site (name)
  "Where config.el asks for NAME (\"config.el:31\"), or nil."
  (let ((file (ignore-errors (drgnx-user-config-file))))
    (when (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (when (re-search-forward (format "(use-package[ \t]+%s\\_>" (regexp-quote name)) nil t)
          (format "%s:%d" (file-name-nondirectory file) (line-number-at-pos)))))))

(defun drgnx-extensions-details-why-text (why name)
  "\"Why: …\" for the reasons WHY (the row's `why', as the hub sends it) NAME is here; nil when there is none."
  (when why
    (concat "Why: "
            (mapconcat
             (lambda (w)
               (pcase w
                 ("you" "you (Extensions)")
                 ("packages-eld" "packages.eld")
                 ("ensure" (format "%s (:ensure)" (or (drgnx-extensions-details--ensure-site name) "use-package")))
                 ("by-hand" "installed by hand")
                 (`(:module ,m) (format "module %s" m))
                 (`(:needed-by ,names) (format "needed by %s" (string-join (mapcar (lambda (n) (format "%s" n)) (append names nil)) ", ")))
                 (_ (format "%s" w))))
             (append why nil) " · "))))

(defun drgnx-extensions-details-compare-url (url from to)
  "A page comparing the commits FROM and TO of the repository URL, for GitHub, GitLab, Codeberg and sourcehut; nil
for any other host (and for no URL)."
  (when (and url from to)
    (let ((u (string-remove-suffix "/" (string-remove-suffix ".git" (string-remove-suffix "/" url)))))
      (cond ((string-prefix-p "https://github.com/" u) (format "%s/compare/%s...%s" u from to))
            ((string-prefix-p "https://gitlab.com/" u) (format "%s/-/compare/%s...%s" u from to))
            ((string-prefix-p "https://codeberg.org/" u) (format "%s/compare/%s...%s" u from to))
            ((string-prefix-p "https://git.sr.ht/" u) (format "%s/log/%s..%s" u from to))))))

(defconst drgnx-extensions-details--trust-line "Runs inside Emacs as you: it can read your files and reach the network."
  "Said on the page of everything that is code.")

;;;; Text of installed packages: plain, never a mode

(defun drgnx-extensions-details--read-plain (file)
  "FILE's text as a plain string: read into a temporary buffer in fundamental mode with `insert-file-contents',
which runs no mode, applies no local variable and sets no property."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-extensions-details--package-dir (name)
  "The directory of the installed package NAME in the packages directory, or nil."
  (let ((elpa (drgnx-elpa-dir)))
    (car (sort (and (file-directory-p elpa)
                    (directory-files elpa t (concat "\\`" (regexp-quote name) "-[0-9]") ))
               #'string>))))

(defun drgnx-extensions-details--commentary (file)
  "The `;;; Commentary:' of the Lisp file FILE as plain text, without the comment marks, or nil."
  (when (file-readable-p file)
    (let ((text (drgnx-extensions-details--read-plain file)))
      (when-let* ((start (string-search ";;; Commentary:" text)))
        (let* ((body (substring text (+ start (length ";;; Commentary:"))))
               (end (or (string-search "\n;;; Code:" body) (length body))))
          (string-join (mapcar (lambda (l) (string-trim-left (string-remove-prefix ";;" l) " "))
                               (split-string (string-trim (substring body 0 end)) "\n"))
                       "\n"))))))

(defun drgnx-extensions-details--files-named (dir prefix)
  "The files of DIR whose names start with PREFIX (case does not matter), sorted."
  (let ((case-fold-search t))
    (sort (directory-files dir t (concat "\\`" (regexp-quote prefix))) #'string<)))

(defun drgnx-extensions-details-readme-text (name)
  "The text of the installed package NAME: its main file's commentary, then each README in its directory, as plain
text; nil when it is not installed or has none."
  (when-let* ((dir (drgnx-extensions-details--package-dir name)))
    (let ((parts (delq nil (cons (drgnx-extensions-details--commentary (expand-file-name (concat name ".el") dir))
                                 (mapcar #'drgnx-extensions-details--read-plain
                                         (cl-remove-if-not #'file-regular-p (drgnx-extensions-details--files-named dir "README")))))))
      (and parts (string-join parts "\n\n")))))

(defun drgnx-extensions-details-news-text (name)
  "The NEWS and CHANGELOG files of the installed package NAME as plain text, or nil."
  (when-let* ((dir (drgnx-extensions-details--package-dir name)))
    (let ((files (cl-remove-if-not #'file-regular-p
                                   (append (drgnx-extensions-details--files-named dir "NEWS")
                                           (drgnx-extensions-details--files-named dir "CHANGELOG")))))
      (and files (string-join (mapcar #'drgnx-extensions-details--read-plain files) "\n\n")))))

(defun drgnx-extensions-details-versions (name installed)
  "The versions of NAME the cache still holds, except INSTALLED: what Install another version offers."
  (let ((dir (drgnx-package-cache-dir)) out)
    (when (file-directory-p dir)
      (dolist (f (directory-files dir nil (concat "\\`" (regexp-quote name) "-\\([0-9][^/]*?\\)\\.\\(?:tar\\|el\\)\\'")))
        (let ((v (progn (string-match (concat "\\`" (regexp-quote name) "-\\([0-9][^/]*?\\)\\.\\(?:tar\\|el\\)\\'") f)
                        (match-string 1 f))))
          (unless (equal v installed) (push v out)))))
    (sort (delete-dups out) #'version<)))

;;;; Actions

(defun drgnx-extensions-details-install-version (id version)
  "Queue the install of the version VERSION of the package ID (`pkg:NAME' or NAME): the job layer runs it, after the
trust card for a source that does not sign."
  (drgnx-extensions--before-install (list :add (intern (drgnx-extensions-list--name id)) :version version)))

(defun drgnx-extensions-details-toggle-module (module)
  "Turn MODULE (a symbol) on or off through its setting: `drgnx-modules-disabled' for a module that runs by default,
`drgnx-modules-enabled' for one that is off until chosen.  The setting's own apply turns it on or off now."
  (let* ((module (if (stringp module) (intern module) module))
         (on (not (drgnx-module-disabled-p module))))
    (if (drgnx-module-default-off-p module)
        (drgnx-settings-editors-commit 'drgnx-modules-enabled 'user nil
                                       (if on (remq module drgnx-modules-enabled) (append drgnx-modules-enabled (list module))))
      (drgnx-settings-editors-commit 'drgnx-modules-disabled 'user nil
                                     (if on (append drgnx-modules-disabled (list module)) (remq module drgnx-modules-disabled))))))

;;;; Generations

(defvar drgnx-extensions-details--generations 'unread
  "The generations as `drgnx-extensions-details-generations' read them, or `unread'; emptied by a refresh of the list.")
(defvar drgnx-extensions-details--sizes (make-hash-table :test 'equal) "Generation directory → its size in bytes.")
(defvar drgnx-extensions-details--copies 'unknown "Whether this file system copies packages: t, nil or `unknown'.")

(defun drgnx-extensions-details-forget-generations ()
  "Read the generations again at the next draw."
  (setq drgnx-extensions-details--generations 'unread))

(defun drgnx-extensions-details--dir-size (dir)
  (or (gethash dir drgnx-extensions-details--sizes)
      (puthash dir (cl-reduce #'+ (mapcar (lambda (f) (or (file-attribute-size (file-attributes f)) 0))
                                          (directory-files-recursively dir "" nil nil)))
               drgnx-extensions-details--sizes)))

(defun drgnx-extensions-details--lock-versions (n)
  "Alist NAME → version of the lock kept with generation N."
  (let ((lock (ignore-errors (drgnx-pkg--read-file (expand-file-name "drgnx.lock.eld" (drgnx-pkg--generation-dir n))))))
    (mapcar (lambda (e) (cons (format "%s" (car e)) (plist-get (cdr e) :version))) (plist-get lock :packages))))

(defun drgnx-extensions-details--differs (n older)
  "What differs between generation N and the OLDER one: \"magit 4.1 → 4.2\", \"+name\", \"-name\"."
  (let ((now (drgnx-extensions-details--lock-versions n)) (before (drgnx-extensions-details--lock-versions older)) out)
    (dolist (c now)
      (let ((b (assoc (car c) before)))
        (cond ((null b) (push (format "+%s" (car c)) out))
              ((not (equal (cdr b) (cdr c))) (push (format "%s %s → %s" (car c) (cdr b) (cdr c)) out)))))
    (dolist (b before) (unless (assoc (car b) now) (push (format "-%s" (car b)) out)))
    (nreverse out)))

(defun drgnx-extensions-details-generations ()
  "The generations, newest first, as plists (:n :time :note :differs :in-use :current :size), read from their
`generation.eld' and lock files (data only; nothing is loaded).  Read once;
`drgnx-extensions-details-forget-generations' reads them again."
  (when (eq drgnx-extensions-details--generations 'unread)
    (unless (featurep 'drgnx-pkg) (require 'drgnx-pkg))
    (let ((gens (ignore-errors (drgnx-pkg-generations)))
          (in-use (ignore-errors (drgnx-pkg-generations-in-use)))
          (current (ignore-errors (drgnx-pkg-current-generation))))
      (setq drgnx-extensions-details--generations
            (cl-loop for (g . rest) on gens
                     collect (list :n (car g) :time (plist-get (cdr g) :time) :note (plist-get (cdr g) :note)
                                   :differs (and rest (drgnx-extensions-details--differs (car g) (car (car rest))))
                                   :in-use (and (memq (car g) in-use) t) :current (eq (car g) current)
                                   :size (ignore-errors (drgnx-extensions-details--dir-size (drgnx-pkg--generation-dir (car g)))))))))
  drgnx-extensions-details--generations)

(defun drgnx-extensions-details-copies-note ()
  "A line that says each change copies the packages twice, when this file system has no clones; nil otherwise."
  (when (eq drgnx-extensions-details--copies 'unknown)
    (unless (featurep 'drgnx-pkg) (require 'drgnx-pkg))
    (setq drgnx-extensions-details--copies (and (ignore-errors (drgnx-pkg-copies-p)) t)))
  (and drgnx-extensions-details--copies
       "This file system copies the packages twice per change (the staging copy and the generation)."))

(defun drgnx-extensions-details-generation-keys ()
  "The list's keys for the Generations section: its header, then `(gen . N)' for each generation."
  (when-let* ((gens (drgnx-extensions-details-generations)))
    (cons (cons 'section 'generations) (mapcar (lambda (g) (cons 'gen (plist-get g :n))) gens))))

(defun drgnx-extensions-details-generation-row (n)
  "The text of the row of generation N."
  (let ((g (cl-find n (drgnx-extensions-details-generations) :key (lambda (g) (plist-get g :n)))))
    (propertize
     (if (null g)
         (format "generation %s\n" n)
       (concat (format "%s #%d  %s" (drgnx-face-glyph 'package) n (or (plist-get g :time) ""))
               (if (plist-get g :note) (format "  %s" (plist-get g :note)) "")
               (cond ((plist-get g :in-use) (propertize "  in use" 'face 'drgnx-status-warn))
                     ((plist-get g :current) (propertize "  current" 'face 'drgnx-status-ok))
                     (t ""))
               (if (plist-get g :size) (format "  %s" (file-size-human-readable (plist-get g :size))) "")
               "\n"
               (if (plist-get g :differs)
                   (concat "    " (propertize (string-join (plist-get g :differs) " · ") 'face 'shadow) "\n")
                 "")
               (if-let* ((note (and (eql n (plist-get (car (drgnx-extensions-details-generations)) :n))
                                    (drgnx-extensions-details-copies-note))))
                   (concat "    " (propertize note 'face 'shadow) "\n")
                 "")))
     'drgnx-extensions-gen n)))

(defun drgnx-extensions-rollback (&optional n)
  "Roll the packages back to generation N (at point, else asked): a background job; a restart then uses them."
  (interactive)
  (unless (fboundp 'drgnx-extensions-jobs-run) (user-error "The job layer is not available (its module is off)"))
  (let ((n (or n (get-text-property (point) 'drgnx-extensions-gen)
               (string-to-number
                (completing-read "Roll back to generation: "
                                 (mapcar (lambda (g) (number-to-string (plist-get g :n))) (drgnx-extensions-details-generations))
                                 nil t)))))
    (drgnx-extensions-jobs-run 'rollback n)))

;;;; The page

(defun drgnx-extensions-details--row ()
  "The row the page shows: the list's, else what the hub answered."
  (or (gethash drgnx-extensions-details--id drgnx-extensions-list--rows)
      (when-let* ((r (plist-get drgnx-extensions-details--info :row))) (drgnx-extensions-list--normalize r))))

(defun drgnx-extensions-details--button (label fn &optional help)
  (concat (drgnx-ui-button (format "[%s]" label) fn :help help) " "))

(defun drgnx-extensions-details--refresh ()
  "Draw the page again: its state changed."
  (when (drgnx-view-p drgnx-view) (drgnx-view-dirty drgnx-view t)))

(defun drgnx-extensions-details--project-text (name)
  "What package NAME's page says about the project the list was opened from: a package that changes Emacs as a whole
says so anywhere; the others need a project.  Nil without the project layer or a project."
  (when (fboundp 'drgnx-extensions-project-describe)
    (let ((pkg (intern name)))
      (cond ((eq (drgnx-extensions-project-scope pkg) 'global) drgnx-extensions-project-global-text)
            (drgnx-extensions-list--root (drgnx-extensions-project-describe pkg drgnx-extensions-list--root))))))

(defun drgnx-extensions-details--project-button (name buf)
  "The page's toggle for package NAME in the project the list was opened from: only for a package that can be off in
one project, and only with a project.  BUF is the page."
  (let ((pkg (intern name)) (root drgnx-extensions-list--root))
    (if (and root (fboundp 'drgnx-extensions-project-toggle) (eq (drgnx-extensions-project-scope pkg) 'narrow))
        (drgnx-extensions-details--button
         (if (drgnx-extensions-project-off-p pkg root) "Turn on in this project" "Turn off in this project")
         (lambda ()
           (drgnx-extensions-project-toggle pkg root)
           (when (buffer-live-p buf) (with-current-buffer buf (drgnx-extensions-details--refresh))))
         "Its file modes and buffer modes in this project only")
      "")))

(defun drgnx-extensions-details--render-header ()
  (let* ((row (drgnx-extensions-details--row)) (info drgnx-extensions-details--info)
         (name (drgnx-extensions-list--name drgnx-extensions-details--id)))
    (concat
     (propertize (if row (plist-get row :name) name) 'face 'bold)
     (if (plist-get row :version)
         (propertize (format "  %s%s" (plist-get row :version)
                             (if (plist-get row :latest) (format " → %s" (plist-get row :latest)) ""))
                     'face 'shadow)
       "")
     "\n"
     (if row (propertize (string-join (delq nil (list (plist-get row :summary) (plist-get row :source)
                                                      (drgnx-extensions-list--trust row)))
                                      " · ")
                         'face 'shadow)
       "")
     "\n"
     (if-let* ((m (plist-get info :maintainer))) (format "Maintainer: %s\n" m) "")
     (if-let* ((u (plist-get info :url))) (format "%s\n" u) "")
     (if-let* ((why (and row (drgnx-extensions-details-why-text (plist-get row :why) name)))) (concat why "\n") "")
     (if (and row (eq (plist-get row :kind) 'package))
         (propertize (concat drgnx-extensions-details--trust-line "\n") 'face 'drgnx-status-warn)
       "")
     (if-let* ((here (and row (eq (plist-get row :kind) 'package) (drgnx-extensions-details--project-text name))))
         (concat here "\n")
       "")
     (if drgnx-extensions-details--error (propertize (concat drgnx-extensions-details--error "\n") 'face 'drgnx-status-fail) "")
     "\n")))

(defun drgnx-extensions-details--render-actions ()
  (let* ((row (drgnx-extensions-details--row)) (id drgnx-extensions-details--id) (buf (current-buffer)))
    (concat
     (pcase (plist-get row :kind)
       ('plugin (if (fboundp 'drgnx-extensions-plugins-actions) (drgnx-extensions-plugins-actions row buf) ""))
       ('module (drgnx-extensions-details--button
                 (if (eq (plist-get row :state) 'off) "Turn on" "Turn off")
                 (lambda () (drgnx-extensions-details-toggle-module (drgnx-extensions-list--name id)))))
       ('package (concat
                  (when (memq (plist-get row :state) '(available missing))
                    (drgnx-extensions-details--button "Install" (lambda () (drgnx-extensions-details-install-version* id nil))))
                  (let ((review (and (fboundp 'drgnx-extensions-trust-review)
                                     (drgnx-extensions-trust-review (drgnx-extensions-list--name id)))))
                    (cond ((eq (plist-get review :state) 'ready)
                           (concat (drgnx-extensions-details--button "Apply update" 'extensions-review-apply
                                                                     "Install exactly the update shown below")
                                   (drgnx-extensions-details--button
                                    "Discard" (lambda () (drgnx-extensions-trust-discard (drgnx-extensions-list--name id)))
                                    "Forget this update; nothing is installed")))
                          (review "")
                          ((eq (plist-get row :state) 'update)
                           (drgnx-extensions-details--button "Update" (lambda () (drgnx-extensions--update (drgnx-extensions-list--name id)))))))
                  (when (memq (plist-get row :state) '(installed update held dependency incompat))
                    (drgnx-extensions-details--button "Uninstall" (lambda () (drgnx-extensions-jobs-queue (list :remove (intern (drgnx-extensions-list--name id)))))))
                  (drgnx-extensions-details--project-button (drgnx-extensions-list--name id) buf)))
       (_ ""))
     (drgnx-extensions-details--button "⋯" (lambda () (with-current-buffer buf (call-interactively #'drgnx-extensions-more)))
                                       "More: another version, copy the name, the repository, its settings, the log")
     "\n")))

(defun drgnx-extensions-details-install-version* (id version)
  "Queue the install of ID, at VERSION when given."
  (if version (drgnx-extensions-details-install-version id version)
    (drgnx-extensions--before-install (list :add (intern (drgnx-extensions-list--name id))))))

(defconst drgnx-extensions-details--tabs '(readme changes settings dependencies files) "The tabs, in order.")

(defun drgnx-extensions-details--tab-label (tab)
  (pcase tab
    ('readme "Readme") ('changes "Changes") ('dependencies "Dependencies") ('files "Files")
    ('settings (let ((n (and (eq (plist-get (drgnx-extensions-details--row) :kind) 'package)
                             (ignore-errors (drgnx-settings-page-package-count (drgnx-extensions-list--name drgnx-extensions-details--id))))))
                 (if n (format "Settings (%d)" n) "Settings")))))

(defun drgnx-extensions-details--render-tabs ()
  (let ((buf (current-buffer)))
    (concat
     (mapconcat (lambda (tab)
                  (if (eq tab drgnx-extensions-details--tab)
                      (propertize (drgnx-extensions-details--tab-label tab) 'face '(bold underline))
                    (drgnx-ui-button (drgnx-extensions-details--tab-label tab)
                                     (lambda () (drgnx-extensions-details--tab-clicked buf tab)))))
                drgnx-extensions-details--tabs " · ")
     "\n\n")))

(defun drgnx-extensions-details--module-text (name)
  "The page of the module NAME: its doc, packages, flags, stage and how long it took to start."
  (let* ((m (alist-get (intern name) drgnx-modules--table)) (report (alist-get (intern name) (drgnx-modules-report))))
    (concat (or (plist-get m :doc) "") "\n\n"
            (format "Packages: %s\n" (if (plist-get m :packages) (mapconcat #'symbol-name (plist-get m :packages) ", ") "none"))
            (format "Flags: %s\n" (if (plist-get m :flags) (mapconcat #'symbol-name (plist-get m :flags) ", ") "none"))
            (format "Stage: %s\n" (or (plist-get m :stage) "startup"))
            (if (plist-get report :ms) (format "Started in %s ms\n" (plist-get report :ms)) ""))))

(defun drgnx-extensions-details--plain (text)
  "TEXT as a string with no properties, ending in a newline."
  (let ((s (substring-no-properties (or text ""))))
    (if (string-suffix-p "\n" s) s (concat s "\n"))))

(defun drgnx-extensions-details--render-body ()
  (let* ((row (drgnx-extensions-details--row)) (id drgnx-extensions-details--id) (info drgnx-extensions-details--info)
         (name (drgnx-extensions-list--name id)) (kind (plist-get row :kind)))
    (pcase kind
      ('module (drgnx-extensions-details--plain (drgnx-extensions-details--module-text name)))
      ('plugin
       (if (and (fboundp 'drgnx-plugins-page-insert) (fboundp 'drgnx-extensions-plugins-page-text))
           (drgnx-extensions-plugins-page-text name)
         "The plugin page comes with the plugin host.\n"))
      (_
       (concat
        (or (and (fboundp 'drgnx-extensions-trust-review-text) (drgnx-extensions-trust-review-text name)) "")
        (drgnx-extensions-details--tab-body row info name))))))

(defun drgnx-extensions-details--fetched-readme (row info)
  "The readme the hub sent for a package that is not installed, made inert once; else what its job is doing."
  (let ((readme (plist-get info :readme)))
    (cond ((and (stringp readme) (fboundp 'drgnx-extensions-trust-inert-string))
           (unless (eq (car drgnx-extensions-details--readme-text) readme)
             (setq drgnx-extensions-details--readme-text (cons readme (drgnx-extensions-trust-inert-string readme 'text))))
           (cdr drgnx-extensions-details--readme-text))
          ((eq (plist-get drgnx-extensions-details--readme :state) 'failed)
           (concat (or (plist-get row :summary) "") "\n\nNo readme: "
                   (substring-no-properties (format "%s" (plist-get drgnx-extensions-details--readme :error)))))
          ((memq (plist-get drgnx-extensions-details--readme :state) '(fetching fetched))
           (concat (or (plist-get row :summary) "") "\n\nFetching the readme…"))
          (t (or (plist-get row :summary) "")))))

(defun drgnx-extensions-details--cached-archive (name row)
  "The archive of the package NAME at ROW's version in the package cache, or nil."
  (let ((dir (drgnx-package-cache-dir)) (v (or (plist-get row :latest) (plist-get row :version))))
    (and v (seq-find #'file-readable-p
                     (mapcar (lambda (ext) (expand-file-name (format "%s-%s%s" name v ext) dir)) '(".tar" ".el"))))))

(defun drgnx-extensions-details--tab-body (row info name)
  "The text of the page's tab for a package."
  (pcase drgnx-extensions-details--tab
    ('readme
     (drgnx-extensions-details--plain
      (or (and (memq (plist-get row :state) '(installed update held dependency incompat))
               (drgnx-extensions-details-readme-text name))
          (drgnx-extensions-details--fetched-readme row info))))
    ('changes
     (drgnx-extensions-details--plain
      (string-join
       (delq nil (list (and (plist-get info :revdesc) (format "Version: %s" (plist-get info :revdesc)))
                       (and (plist-get info :commit) (format "Commit: %s" (plist-get info :commit)))
                       (when-let* ((link (drgnx-extensions-details-compare-url (plist-get info :url) (plist-get info :commit) "HEAD")))
                         (format "Compare: %s" link))
                       drgnx-extensions-details--log
                       (drgnx-extensions-details-news-text name)))
       "\n\n")))
    ('settings
     (concat (format "%s\n" (let ((n (ignore-errors (drgnx-settings-page-package-count name))))
                              (if n (format "%d settings" n) "No settings found")))
             (drgnx-extensions-details--button "Show in Settings"
                                               (lambda () (drgnx-settings-page-show-package name)))
             "\n"))
    ('dependencies
     (concat "Requires:\n"
             (mapconcat (lambda (r) (format "  %s%s\n" (plist-get r :name)
                                            (if (plist-get r :version) (format " %s" (plist-get r :version)) "")))
                        (plist-get info :requires) "")
             "Needed by:\n"
             (mapconcat (lambda (n) (format "  %s\n" n)) (plist-get info :required-by) "")))
    ('files
     (drgnx-extensions-details--plain
      (if-let* ((dir (drgnx-extensions-details--package-dir name)))
          (mapconcat (lambda (f) (file-relative-name f dir)) (directory-files-recursively dir "") "\n")
        (pcase (plist-get drgnx-extensions-details--files :state)
          ('ready (plist-get drgnx-extensions-details--files :text))
          ('listing "Listing the files of the downloaded archive…")
          ('failed (format "Cannot list its files: %s" (plist-get drgnx-extensions-details--files :error)))
          (_ "Not installed: its files are listed here once it is downloaded (an Install, or an update's review)")))))))

(defun drgnx-extensions-details--tab-clicked (buffer tab)
  "TAB was clicked on BUFFER's page: show it; Files of a package that is not installed lists its downloaded archive."
  (with-current-buffer buffer
    (setq drgnx-extensions-details--tab tab)
    (let* ((row (drgnx-extensions-details--row)) (name (drgnx-extensions-list--name drgnx-extensions-details--id)))
      (when-let* (((eq tab 'files)) ((eq (plist-get row :kind) 'package)) ((null drgnx-extensions-details--files))
                  ((fboundp 'drgnx-extensions-trust-list-files))
                  ((not (drgnx-extensions-details--package-dir name)))
                  (file (drgnx-extensions-details--cached-archive name row))
                  ((string-suffix-p ".tar" file)))
        (drgnx-extensions-trust-list-files buffer file)))
    (drgnx-extensions-details--refresh)))

(defun drgnx-extensions-details--render (key)
  "The view's RENDER for the page in the current buffer."
  (pcase key
    ('header (drgnx-extensions-details--render-header))
    ('actions (drgnx-extensions-details--render-actions))
    ('tabs (drgnx-extensions-details--render-tabs))
    (_ (drgnx-extensions-details--render-body))))

(defun drgnx-extensions-details--define-view ()
  "Define the view type `extension-details' (undone with the module that calls this in its setup)."
  (drgnx-view-define 'extension-details :render #'drgnx-extensions-details--render :delay 0))

(defun drgnx-extensions-details--make (name)
  "A page buffer called NAME, with its view."
  (with-current-buffer (get-buffer-create name)
    (unless (drgnx-view-type-p 'extension-details) (drgnx-extensions-details--define-view))
    (drgnx-extensions-details-mode)
    (drgnx-view-attach 'extension-details)
    (drgnx-view-append drgnx-view '(header actions tabs body))
    (current-buffer)))

(defun drgnx-extensions-details--buffer (id pin)
  "The buffer for ID: the preview page (kept for the next one), or with PIN a page of its own."
  (let ((preview (get-buffer drgnx-extensions-details-preview-name))
        (pinned-name (format "*Extension: %s*" (drgnx-extensions-list--name id))))
    (cond ((and pin (get-buffer pinned-name)) (get-buffer pinned-name))
          ((and pin preview (equal (buffer-local-value 'drgnx-extensions-details--id preview) id))
           (with-current-buffer preview (rename-buffer pinned-name t) (current-buffer)))
          (pin (drgnx-extensions-details--make pinned-name))
          (preview preview)
          (t (drgnx-extensions-details--make drgnx-extensions-details-preview-name)))))

(defun drgnx-extensions-details--git-log (buffer name commit)
  "For a Git package, run `git log COMMIT..FETCH_HEAD' in its cached clone; its text goes to BUFFER's page."
  (when-let* ((dir (ignore-errors (drgnx-pkg--git-cache name))) ((file-directory-p dir)) (commit commit))
    (let ((out (generate-new-buffer " *extension git log*" t)))
      (make-process :name "extension-git-log" :buffer out :noquery t :connection-type 'pipe
                    :command (list "git" "-C" dir "log" "--oneline" "-n" "30" (concat commit "..FETCH_HEAD"))
                    :sentinel (drgnx-guard-wrap
                               (lambda (proc _event)
                                 (unless (process-live-p proc)
                                   (let ((text (with-current-buffer out (string-trim (buffer-string)))))
                                     (kill-buffer out)
                                     (when (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (setq drgnx-extensions-details--log
                                               (and (not (string-empty-p text)) (concat "Since this version:\n" text)))
                                         (drgnx-extensions-details--refresh))))))
                               "the git log of an extension")))))

(defun drgnx-extensions-details--fetch (buffer id)
  "Ask the hub, without waiting, for ID's details; they go to BUFFER's page."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub-client))
  (condition-case err
      (drgnx-hub-call "extensions/details" (list :id id)
                      (lambda (result error)
                        (when (and (buffer-live-p buffer) (equal id (buffer-local-value 'drgnx-extensions-details--id buffer)))
                          (with-current-buffer buffer
                            (if error
                                (setq drgnx-extensions-details--error (format "%s" error))
                              (setq drgnx-extensions-details--error nil drgnx-extensions-details--info result)
                              (when (equal (plist-get (plist-get result :row) :source) "git")
                                (drgnx-extensions-details--git-log buffer (drgnx-extensions-list--name id) (plist-get result :commit)))
                              ;; a package not installed whose readme the hub has not cached: a job fetches it
                              (when (fboundp 'drgnx-extensions-trust-fetch-readme) (drgnx-extensions-trust-fetch-readme buffer)))
                            (drgnx-extensions-details--refresh)))))
    (error (with-current-buffer buffer
             (setq drgnx-extensions-details--error (error-message-string err))
             (drgnx-extensions-details--refresh)))))

(defun drgnx-extensions-details-open (id &optional pin)
  "Show the page of the extension ID (`pkg:NAME', `module:NAME', `plugin:NAME') in the preview page, which the next
page replaces; with PIN in a page of its own.  Returns the buffer (the caller shows it).  Opened from a file of a
project, the page's toggle acts there."
  (drgnx-extensions-list-note-root)
  (let ((buffer (drgnx-extensions-details--buffer id pin)))
    (with-current-buffer buffer
      (unless (equal drgnx-extensions-details--id id)
        (setq drgnx-extensions-details--id id drgnx-extensions-details--info nil drgnx-extensions-details--error nil
              drgnx-extensions-details--log nil drgnx-extensions-details--tab 'readme drgnx-extensions-details--readme nil
              drgnx-extensions-details--readme-text nil drgnx-extensions-details--files nil)
        (drgnx-extensions-details--refresh)
        (when (string-prefix-p "pkg:" id) (drgnx-extensions-details--fetch buffer id))
        (when (and (string-prefix-p "plugin:" id) (fboundp 'drgnx-extensions-plugins-opened))
          (drgnx-extensions-plugins-opened))))
    buffer))

;;;; The ⋯ menu

(defun drgnx-extensions-details--current-id ()
  "The id of the page, or of the row at point in the list."
  (or drgnx-extensions-details--id
      (get-text-property (point) 'drgnx-extensions-id)
      (user-error "No extension here")))

(defun drgnx-extensions-more ()
  "More about the extension here: install another version, copy its name, open its repository, show its settings, show
its log."
  (interactive)
  (let* ((id (drgnx-extensions-details--current-id)) (name (drgnx-extensions-list--name id))
         (choice (completing-read "Extension: "
                                  '("Install another version" "Copy name" "Open repository" "Show in Settings" "Show log")
                                  nil t)))
    (pcase choice
      ("Install another version"
       (let* ((row (gethash id drgnx-extensions-list--rows))
              (versions (drgnx-extensions-details-versions name (plist-get row :version))))
         (if versions
             (drgnx-extensions-details-install-version id (completing-read "Version: " versions nil t))
           (user-error "No other version is kept here%s" (if (equal (plist-get row :source) "melpa")
                                                             "; an earlier generation's version comes back by Roll back" "")))))
      ("Copy name" (kill-new name) (message "Copied %s" name))
      ("Open repository"
       (browse-url (or (plist-get (if drgnx-extensions-details--id drgnx-extensions-details--info) :url)
                       (user-error "%s names no repository" name))))
      ("Show in Settings" (drgnx-settings-page-show-package name))
      ("Show log" (drgnx-extensions-show-log id)))))

(provide 'drgnx-extensions-details)
;;; drgnx-extensions-details.el ends here
