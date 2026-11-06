;;; drgnx-plugins-ui.el --- Module tools/plugins: the plugins page, approving what a plugin may reach -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Plugins (docs/guide/plugins.md) run inside the agent hub only once you approved exactly the files you were shown.
;; This module is the page where you do that.  `drgnx-plugins-page-insert' draws one plugin: its state and hash, the
;; abilities it offers, each hook's point, verdicts and (for `change') what it may rewrite, the hosts it may reach, what
;; it sees, the project's own choice ("In this project") and Approve, Disable.  `drgnx-plugins-open' (Settings →
;; Plugins) lists every plugin; `drgnx-plugins-page-open' (the plugin notice's click) shows one.  Approve sends the
;; hash the page displayed, never one fetched again: a plugin whose files changed since is refused by the hub.
;; Opening and Refresh ask the hub for `plugins/list' (a command of yours); nothing here prompts or approves on its own.
;; The per-project choice is a setting only you can write (`drgnx-plugins-project-set').

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-ui-kit)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-setting-for-root "drgnx-settings-workspace" (var root))
(declare-function drgnx-settings-editors-commit "drgnx-settings-editors" (var tab root value))
(declare-function drgnx-wb-place "drgnx-rules")
(declare-function project-root "project")

(defface drgnx-plugins-heading '((t :inherit bold)) "A plugin's name on its page." :group 'drgnx)
(defface drgnx-plugins-label '((t :inherit shadow)) "A fact's label on a plugin's page." :group 'drgnx)
(defface drgnx-plugins-warn '((t :inherit warning)) "A plugin that does not run until you act." :group 'drgnx)

(defvar drgnx-plugins-page-sections nil
  "Functions called with (NAME ROW) after a plugin's header on its page, each inserting a section at point (the
Extensions view adds the replace diff).  ROW is the plugin's row of `plugins/list'.")

(defvar drgnx-plugins--rows nil "The `plugins' of the last `plugins/list' answer: rows as plists.")

(defvar-local drgnx-plugins--only nil "The plugin name this page shows alone, or nil for every plugin.")
(defvar-local drgnx-plugins--root nil "The project root this page's \"In this project\" is about, or nil.")
(defvar-local drgnx-plugins--shown nil
  "((NAME . HASH)…): the hash each plugin's section displayed.  Approve sends that one.")

(defvar drgnx-plugins-page-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "Keys come from the key profiles (commands `plugins-refresh', `plugins-approve', `plugins-disable',
`plugins-project-toggle').")

(define-derived-mode drgnx-plugins-page-mode special-mode "Plugins"
  "Plugins and what each may reach: Approve, Disable, and whether one runs in this project."
  (setq-local truncate-lines nil
              revert-buffer-function (lambda (&rest _) (drgnx-plugins-refresh)))
  (buffer-disable-undo))

;;;; Reading the manifest's reach

(defun drgnx-plugins--list (x) (append x nil))

(defun drgnx-plugins--words (items) (if items (string-join (drgnx-plugins--list items) ", ") "none"))

(defun drgnx-plugins--rewrites (hook)
  "What HOOK (a `HookReach' plist) may rewrite when it may `change': by its point."
  (pcase (plist-get hook :point)
    ("before-tool" (if (plist-get hook :tools)
                       (format "the arguments of %s" (drgnx-plugins--words (plist-get hook :tools)))
                     "the arguments of any tool call it sees"))
    ("after-edit" "the file contents of writes")
    ("before-commit" "the commit message")
    ("at-review" "the review notes")
    (_ "what the point hands it")))

(defun drgnx-plugins--hook-lines (hook)
  "HOOK's lines: its point, the verdicts it may give, what it matches, and for `change' what it may rewrite."
  (let* ((verdicts (drgnx-plugins--list (plist-get hook :verdicts)))
         (matches (delq nil (list (and (plist-get hook :tool_kinds) (format "kinds %s" (drgnx-plugins--words (plist-get hook :tool_kinds))))
                                  (and (plist-get hook :tools) (format "tools %s" (drgnx-plugins--words (plist-get hook :tools))))
                                  (and (plist-get hook :paths) (format "paths %s" (drgnx-plugins--words (plist-get hook :paths))))))))
    (concat (format "    %s: may %s%s\n" (plist-get hook :point) (string-join verdicts ", ")
                    (if matches (format " · only on %s" (string-join matches " · ")) " · on everything the point sees"))
            (when (member "change" verdicts) (format "      it may rewrite %s\n" (drgnx-plugins--rewrites hook))))))

(defun drgnx-plugins--reach-lines (abilities hosts hooks)
  "The reach of ABILITIES, HOSTS and HOOKS as page lines."
  (concat
   (format "  %s %s\n" (propertize "Abilities (tools the agents may call, behind the permissions matrix):" 'face 'drgnx-plugins-label)
           (drgnx-plugins--words abilities))
   (if hooks
       (concat (propertize "  Hooks:\n" 'face 'drgnx-plugins-label)
               (mapconcat #'drgnx-plugins--hook-lines (drgnx-plugins--list hooks) ""))
     (format "  %s none\n" (propertize "Hooks:" 'face 'drgnx-plugins-label)))
   (format "  %s %s\n" (propertize "Hosts it may reach (https):" 'face 'drgnx-plugins-label) (drgnx-plugins--words hosts))))

(defun drgnx-plugins--sees-lines (row)
  "What plugin ROW sees where it is enabled, as page lines: diffs and file contents, what it may send out, its store."
  (concat
   (format "  %s%s\n" (propertize "What it sees: " 'face 'drgnx-plugins-label)
           (if (plist-get row :hooks)
               "diffs and file contents in the projects where it is enabled"
             "nothing of your projects (it has no hooks); its abilities get only the arguments an agent gives them"))
   (if (plist-get row :hosts)
       (format "  %s%s\n" (propertize "It may send it to: " 'face 'drgnx-plugins-label) (drgnx-plugins--words (plist-get row :hosts)))
     (format "  %s\n" (propertize "It may send nothing out: it has no hosts." 'face 'drgnx-plugins-label)))
   (format "  %s%s\n" (propertize "Its key-value store: " 'face 'drgnx-plugins-label)
           (format "%s, shared across the projects where it is enabled"
                   (if (numberp (plist-get row :kv_bytes)) (format "up to %d KiB" (/ (plist-get row :kv_bytes) 1024)) "no size stated")))))

;;;; The project's own choice

(defun drgnx-plugins--project-names (root)
  "The plugins that run in the project at ROOT (its own list replaces the global one)."
  (and root (drgnx-plugins--list (drgnx-setting-for-root 'drgnx-agents-plugins root))))

(defun drgnx-plugins-project-set (root names)
  "Make NAMES (a list of plugin names) the plugins that run in the project at ROOT: the one writer of that choice.
It goes into your private workspace file for ROOT (`drgnx-agents-plugins' is a setting no repository and no agent can
write); a refused value or a missing file is a `user-error'."
  (require 'drgnx-settings-editors)
  (drgnx-settings-editors-commit 'drgnx-agents-plugins 'workspace root (copy-sequence names)))

(defun drgnx-plugins--project-lines (name root)
  "The \"In this project\" lines of plugin NAME for ROOT: whether it runs there, the rules in force and those off."
  (if (not root)
      (format "  %s no project: open the page from a file in one to choose per project\n"
              (propertize "In this project:" 'face 'drgnx-plugins-label))
    (let ((names (drgnx-plugins--project-names root)))
      (concat
       (format "  %s %s (%s)\n" (propertize "In this project:" 'face 'drgnx-plugins-label)
               (if (member name names) "runs" "does not run")
               (abbreviate-file-name root))
       (format "    this project's plugins: %s\n" (drgnx-plugins--words names))
       (let ((rules (drgnx-plugins--list (drgnx-setting-for-root 'drgnx-agents-hook-rules root)))
             (off (drgnx-plugins--list (drgnx-setting-for-root 'drgnx-agents-hook-rules-off root))))
         (format "    hook rules in force: %d · switched off here: %s\n" (length rules) (drgnx-plugins--words off)))))))

;;;; One plugin

(defun drgnx-plugins--state-line (row)
  (let ((state (plist-get row :state)))
    (propertize
     (pcase state
       ("unapproved" "not approved yet: it does not run")
       ("approved" "approved: it runs where it is enabled")
       ("changed" "changed since you approved it: it does not run until you approve it again")
       ("disabled" "disabled by you: it does not run")
       ("broken" (format "broken: %s" (or (plist-get row :problem) "its manifest does not read")))
       (_ (or state "unknown")))
     'face (if (equal state "approved") 'default 'drgnx-plugins-warn))))

(defun drgnx-plugins--button (label action)
  (make-text-button (copy-sequence label) nil 'action (lambda (_) (funcall action)) 'follow-link t))

(defun drgnx-plugins-page-insert (name &optional root)
  "Insert the page of plugin NAME at point (from the rows of the last `plugins/list'): its state and hash, abilities,
hooks with their reach, hosts, what it sees, \"In this project\" for ROOT, then Approve and Disable, and the
sections on `drgnx-plugins-page-sections'.  The hash shown is kept (`drgnx-plugins--shown') for Approve."
  (let ((row (seq-find (lambda (r) (equal (plist-get r :name) name)) drgnx-plugins--rows)) (start (point)))
    (if (not row)
        (insert (format "%s is not installed.\n" name))
      (let ((state (plist-get row :state)) (hash (plist-get row :hash)))
        (insert (propertize (format "%s %s" name (or (plist-get row :version) "")) 'face 'drgnx-plugins-heading) "\n")
        (insert "  " (drgnx-plugins--state-line row) "\n")
        (insert (format "  %s %s\n" (propertize "Hash:" 'face 'drgnx-plugins-label) (or hash "unreadable: it cannot be approved")))
        (when hash (setf (alist-get name drgnx-plugins--shown nil nil #'equal) hash))
        (dolist (f drgnx-plugins-page-sections) (funcall f name row))
        (insert "\n" (propertize "What it may reach" 'face 'drgnx-plugins-label) "\n"
                (drgnx-plugins--reach-lines (plist-get row :abilities) (plist-get row :hosts) (plist-get row :hooks)))
        (when (and (equal state "changed") (plist-get row :approved_reach))
          (let ((r (plist-get row :approved_reach)))
            (insert "\n" (propertize "What you approved before" 'face 'drgnx-plugins-label) "\n"
                    (drgnx-plugins--reach-lines (plist-get r :abilities) (plist-get r :hosts) (plist-get r :hooks)))))
        (insert "\n" (drgnx-plugins--sees-lines row) "\n" (drgnx-plugins--project-lines name root) "\n  ")
        (when (and hash (member state '("unapproved" "changed" "disabled")))
          (insert (drgnx-plugins--button (if (equal state "disabled") "[Approve again]" "[Approve this version]")
                                         (lambda () (drgnx-plugins-approve name hash)))
                  " "))
        (unless (member state '("disabled" "broken"))
          (insert (drgnx-plugins--button "[Disable]" (lambda () (drgnx-plugins-disable name))) " "))
        (when root
          (insert (drgnx-plugins--button (if (member name (drgnx-plugins--project-names root)) "[Turn off in this project]" "[Turn on in this project]")
                                         (lambda () (drgnx-plugins-project-toggle name root)))
                  " "))
        ;; in the Extensions view the page has Replace and Remove buttons of its own
        (if (drgnx-module-running-p 'tools/extensions)
            (insert "\n")
          (insert "\n  " (propertize (format "Replace: ratatoskr plugins install PATH --replace · Remove: ratatoskr plugins remove %s" name)
                                     'face 'drgnx-plugins-label)
                  "\n"))))
    (put-text-property start (point) 'drgnx-plugins-name name)
    (put-text-property start (point) 'drgnx-plugins-hash (cdr (assoc name drgnx-plugins--shown)))))

;;;; The page

(defun drgnx-plugins--render ()
  "Draw this page (every plugin, or the one it shows) from `drgnx-plugins--rows'."
  (let ((inhibit-read-only t) (line (line-number-at-pos)))
    (erase-buffer)
    (setq drgnx-plugins--shown nil)
    (let ((names (if drgnx-plugins--only (list drgnx-plugins--only)
                   (mapcar (lambda (r) (plist-get r :name)) drgnx-plugins--rows))))
      (if (null names)
          (insert "No plugins installed.  Install one with: ratatoskr plugins install PATH\n")
        (dolist (n names) (drgnx-plugins-page-insert n drgnx-plugins--root) (insert "\n"))))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun drgnx-plugins--redraw-pages ()
  "Draw every open plugins page again from the rows held."
  (dolist (b (buffer-list))
    (when (and (buffer-live-p b) (eq (buffer-local-value 'major-mode b) 'drgnx-plugins-page-mode))
      (with-current-buffer b (drgnx-plugins--render)))))

(defun drgnx-plugins--listed (result err)
  "The answer of `plugins/list': keep its rows and draw the pages."
  (if err (message "plugins/list: %s" err)
    (setq drgnx-plugins--rows (drgnx-plugins--list (plist-get result :plugins)))
    (drgnx-plugins--redraw-pages)))

(defun drgnx-plugins-refresh ()
  "Ask the hub for the plugins again and draw the pages."
  (interactive)
  (require 'drgnx-hub-client)
  (drgnx-hub-call "plugins/list" nil #'drgnx-plugins--listed))

(defun drgnx-plugins--project-root ()
  (when-let* ((p (and (require 'project nil t) (project-current)))) (project-root p)))

(defun drgnx-plugins--buffer (only)
  "The plugins page buffer for ONLY (a plugin name, or nil for the list), made and shown."
  (let ((b (get-buffer-create (if only (format "*drgnx plugin: %s*" only) "*drgnx plugins*")))
        (root (drgnx-plugins--project-root)))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-plugins-page-mode) (drgnx-plugins-page-mode))
      (setq drgnx-plugins--only only drgnx-plugins--root root
            default-directory (or root (expand-file-name "~/")))
      (drgnx-plugins--render))
    (pop-to-buffer b)
    b))

(defun drgnx-plugins-open ()
  "Show every plugin: the Settings → Plugins page, which is the Extensions list's plugins when the module
`tools/extensions' runs."
  (interactive)
  (if (and (fboundp 'drgnx-extensions-plugins-open) (drgnx-module-running-p 'tools/extensions))
      (funcall 'drgnx-extensions-plugins-open)
    (require 'drgnx-hub-client)
    (drgnx-hub-ensure)
    (prog1 (drgnx-plugins--buffer nil) (drgnx-plugins-refresh))))

(defun drgnx-plugins-page-open (name)
  "Show the page of plugin NAME: the Extensions view's details page when the module `tools/extensions' runs, else a
buffer of this module's own (both draw it with `drgnx-plugins-page-insert')."
  (interactive (list (completing-read "Plugin: " (mapcar (lambda (r) (plist-get r :name)) drgnx-plugins--rows) nil nil)))
  (if (and (fboundp 'drgnx-extensions-plugin-open) (drgnx-module-running-p 'tools/extensions))
      (funcall 'drgnx-extensions-plugin-open name)
    (require 'drgnx-hub-client)
    (drgnx-hub-ensure)
    (prog1 (drgnx-plugins--buffer name) (drgnx-plugins-refresh))))

;;;; Actions

(defun drgnx-plugins--done (what)
  "A callback for the hub's answer to WHAT: say how it went, then read the plugins again."
  (lambda (_result err)
    (message "%s" (if err (format "%s: %s" what err) (format "%s: done" what)))
    (drgnx-plugins-refresh)))

(defun drgnx-plugins-approve (name hash)
  "Approve plugin NAME at HASH, the hash its page displayed (never one fetched again: the hub refuses a plugin whose
files hash differently now)."
  (require 'drgnx-hub-client)
  (drgnx-hub-call "plugins/approve" (list :name name :hash hash) (drgnx-plugins--done (format "approve %s" name))))

(defun drgnx-plugins-disable (name)
  "Disable plugin NAME: it stops running everywhere until you approve it again."
  (require 'drgnx-hub-client)
  (drgnx-hub-call "plugins/disable" (list :name name) (drgnx-plugins--done (format "disable %s" name))))

(defun drgnx-plugins-project-toggle (name root)
  "Turn plugin NAME on or off for the project at ROOT, and draw the pages again."
  (let* ((names (drgnx-plugins--project-names root))
         (new (if (member name names) (remove name names) (append names (list name)))))
    (drgnx-plugins-project-set root new)
    (drgnx-plugins--redraw-pages)
    (message "%s %s in %s" name (if (member name new) "runs" "does not run") (abbreviate-file-name root))))

(defun drgnx-plugins--at-point ()
  "(NAME . HASH) of the plugin section at point: the hash that section displayed."
  (let ((name (get-text-property (point) 'drgnx-plugins-name)))
    (unless name (user-error "Put point on a plugin"))
    (cons name (get-text-property (point) 'drgnx-plugins-hash))))

(defun drgnx-plugins-approve-at-point ()
  "Approve the plugin at point, at the hash its section shows."
  (interactive)
  (pcase-let ((`(,name . ,hash) (drgnx-plugins--at-point)))
    (unless hash (user-error "%s has no readable hash: it cannot be approved" name))
    (drgnx-plugins-approve name hash)))

(defun drgnx-plugins-disable-at-point ()
  "Disable the plugin at point."
  (interactive)
  (drgnx-plugins-disable (car (drgnx-plugins--at-point))))

(defun drgnx-plugins-project-toggle-at-point ()
  "Turn the plugin at point on or off in this page's project."
  (interactive)
  (drgnx-plugins-project-toggle (car (drgnx-plugins--at-point))
                                (or drgnx-plugins--root (user-error "No project: open the page from a file in one"))))

;;;; The module

(defun drgnx-plugins--on-page-p () (derived-mode-p 'drgnx-plugins-page-mode))

(defun drgnx-plugins--event (event _data)
  "A `drgnx-hub-event-functions' handler: a `plugin' event draws the open plugins pages again from the hub's list."
  (when (and (equal event "plugin")
             (seq-some (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-plugins-page-mode)) (buffer-list)))
    (drgnx-plugins-refresh)))

(defun drgnx-plugins--teardown ()
  "Turned off: the rows held are dropped (the pages go with their buffers' mode and the cleanup stack)."
  (setq drgnx-plugins--rows nil))

(drgnx-module-define 'tools/plugins
                     :doc "Plugins: the page where you approve what a plugin may reach, and choose per project"
                     :stage 'idle
                     :teardown #'drgnx-plugins--teardown
                     :setup
                     (lambda ()
                       (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-plugins-page-mode 'editor))
                       (add-hook 'drgnx-hub-event-functions #'drgnx-plugins--event)
                       (drgnx-command-define 'plugins-open :category "Settings" :title "Plugins…" :command #'drgnx-plugins-open
                                             :doc "The plugins: what each may reach, Approve, Disable, and which run in this project")
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((plugins-refresh "Refresh" drgnx-plugins-refresh "Ask the hub for the plugins again")
                                        (plugins-approve "Approve Plugin" drgnx-plugins-approve-at-point
                                                         "Approve the plugin at point at the hash the page shows")
                                        (plugins-disable "Disable Plugin" drgnx-plugins-disable-at-point "Stop the plugin at point everywhere")
                                        (plugins-project-toggle "Turn On or Off in This Project" drgnx-plugins-project-toggle-at-point
                                                                "Whether the plugin at point runs in this page's project")))
                         (drgnx-command-define id :category "Plugins" :title title :command fn :doc doc
                                               :map '(drgnx-plugins-ui . drgnx-plugins-page-mode-map)
                                               :when #'drgnx-plugins--on-page-p))))

(provide 'drgnx-plugins-ui)
;;; drgnx-plugins-ui.el ends here
