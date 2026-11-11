;;; drgnx-extensions-plugins.el --- Plugins in the Extensions view -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Plugins are rows of the Extensions list (the hub sends them with the packages) and their details page is the
;; plugins page of drgnx-plugins-ui.el, drawn inside the view.  This file adds what the view does with them: On and Off
;; (the user's `drgnx-agents-plugins', appended at the end, so the hook order stays yours) and move up and down in it,
;; Approve (it sends the hash the page displayed, never one read again), Replace and Remove as jobs of the job layer, and
;; the replace diff: when the files of an approved plugin changed, the page leads with what the new version adds.
;; Nothing here prompts from a timer or a hook; the hub's answers arrive in callbacks.  See docs/guide/extensions.md and
;; docs/guide/plugins.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-ui-kit)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-settings-editors-commit "drgnx-settings-editors")
(declare-function drgnx-plugins-page-insert "drgnx-plugins-ui")
(declare-function drgnx-plugins-approve "drgnx-plugins-ui")
(declare-function drgnx-plugins--listed "drgnx-plugins-ui")
(declare-function drgnx-plugins--redraw-pages "drgnx-plugins-ui")
(declare-function drgnx-plugins--project-root "drgnx-plugins-ui")
(declare-function drgnx-extensions-jobs-run "drgnx-extensions-jobs")
(declare-function drgnx-extensions-list-refresh "drgnx-extensions-list")
(declare-function drgnx-extensions-list--attention "drgnx-extensions-list")
(declare-function drgnx-extensions-list--apply-query "drgnx-extensions-list")
(declare-function drgnx-extensions-open "drgnx-extensions-list")
(declare-function drgnx-extensions-details-open "drgnx-extensions-details")
(declare-function drgnx-extensions-details--refresh "drgnx-extensions-details")
(defvar drgnx-agents-plugins)
(defvar drgnx-plugins--shown)
(defvar drgnx-plugins--rows)
(defvar drgnx-plugins-page-sections)
(defvar drgnx-hub-event-functions)
(defvar drgnx-extensions-details--id)
(defvar drgnx-extensions-list-buffer-name)

(defvar-local drgnx-extensions-plugins--shown nil
  "((NAME . HASH)…) in a details page: the hash its page displayed, which Approve sends.")

(defvar-local drgnx-extensions-plugins--changed nil
  "The names whose hash the page displayed changed while it was open (M13): Approve holds once, so the user reads it.")

(defvar-local drgnx-extensions-plugins--root nil "The project root a plugin page's \"In this project\" is about, or nil.")

;;;; Which plugin

(defun drgnx-extensions-plugins--id ()
  "The id of the plugin on this page or at point in the list, or a `user-error'."
  (let ((id (or (bound-and-true-p drgnx-extensions-details--id) (get-text-property (point) 'drgnx-extensions-id))))
    (unless (and (stringp id) (string-prefix-p "plugin:" id)) (user-error "No plugin here"))
    id))

(defun drgnx-extensions-plugins--name ()
  (substring (drgnx-extensions-plugins--id) (length "plugin:")))

;;;; On, Off and the order

(defun drgnx-extensions-plugins--names ()
  (append (default-value 'drgnx-agents-plugins) nil))

(defun drgnx-extensions-plugins--commit (names)
  (require 'drgnx-settings-editors)
  (drgnx-settings-editors-commit 'drgnx-agents-plugins 'user nil names)
  (drgnx-extensions-plugins-refresh))

(defun drgnx-extensions-plugins-set-on (name on)
  "Turn plugin NAME on (appended at the end of `drgnx-agents-plugins') or off (taken out of it).  The new list."
  (let* ((names (drgnx-extensions-plugins--names))
         (new (if on (if (member name names) names (append names (list name))) (remove name names))))
    (unless (equal new names) (drgnx-extensions-plugins--commit new))
    new))

(defun drgnx-extensions-plugins-move (name delta)
  "Move plugin NAME by DELTA places in the hook order (`drgnx-agents-plugins'); it has to be on."
  (let* ((names (drgnx-extensions-plugins--names)) (i (cl-position name names :test #'equal)))
    (unless i (user-error "%s is off: turn it on first" name))
    (let ((j (max 0 (min (1- (length names)) (+ i delta)))))
      (unless (= i j)
        (let ((v (vconcat names)))
          (cl-rotatef (aref v i) (aref v j))
          (drgnx-extensions-plugins--commit (append v nil)))))))

(defun drgnx-extensions-plugins-toggle ()
  "Turn the plugin here on or off."
  (interactive)
  (let ((name (drgnx-extensions-plugins--name)))
    (drgnx-extensions-plugins-set-on name (not (member name (drgnx-extensions-plugins--names))))))

(defun drgnx-extensions-plugins-move-up ()
  "Run the plugin here earlier in the hook order."
  (interactive)
  (drgnx-extensions-plugins-move (drgnx-extensions-plugins--name) -1))

(defun drgnx-extensions-plugins-move-down ()
  "Run the plugin here later in the hook order."
  (interactive)
  (drgnx-extensions-plugins-move (drgnx-extensions-plugins--name) 1))

;;;; The hub's plugins

(defun drgnx-extensions-plugins--redraw ()
  "Draw the list and every open details page (a plugin's, a package's) again from what the hub said."
  (when (get-buffer drgnx-extensions-list-buffer-name) (drgnx-extensions-list-refresh))
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-extensions-details-mode)
      (with-current-buffer b (drgnx-extensions-details--refresh)))))

(defvar drgnx-extensions-plugins--asked 0 "The number of the newest `plugins/list' asked: an older answer is dropped.")

(defun drgnx-extensions-plugins-refresh ()
  "Ask the hub for the plugins and draw the view's rows and plugin pages again.  Does not wait.  Only the newest
question's answer counts: a late answer to an older one never overwrites a newer list (M4)."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub-client))
  (let ((n (cl-incf drgnx-extensions-plugins--asked)))
    (drgnx-hub-call "plugins/list" nil
                    (lambda (result err)
                      (when (= n drgnx-extensions-plugins--asked)
                        (drgnx-plugins--listed result err)
                        (unless err (drgnx-extensions-plugins--redraw)))))))

(defun drgnx-extensions-plugins--event (event _data)
  "A `drgnx-hub-event-functions' handler: a `plugin' event reads the plugins again while the view shows any."
  (when (and (equal event "plugin")
             (or (get-buffer drgnx-extensions-list-buffer-name)
                 (seq-some (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-extensions-details-mode)) (buffer-list))))
    ;; a burst of events is one question, asked a moment after the last (M4)
    (drgnx-timer-debounce 'extensions-plugins-refresh 0.1 #'drgnx-extensions-plugins-refresh :owner :core)))

;;;; The page

(defun drgnx-extensions-plugins-opened ()
  "A details page for a plugin was made in the current buffer: remember its project and read the plugins."
  (setq drgnx-extensions-plugins--root (drgnx-plugins--project-root))
  (drgnx-extensions-plugins-refresh))

(defun drgnx-extensions-plugins-page-text (name)
  "The page of plugin NAME (P9's, from the rows the hub last sent) as text with its buttons, for the current page; the
hash it displays is kept for Approve."
  (let (shown)
    (prog1 (with-temp-buffer
             (drgnx-plugins-page-insert name drgnx-extensions-plugins--root)
             (setq shown drgnx-plugins--shown)
             (buffer-string))
      ;; a page drawn again with another hash than the one the user may have read: the next Approve holds once
      (dolist (cell shown)
        (let ((was (assoc (car cell) drgnx-extensions-plugins--shown)))
          (when (and was (not (equal (cdr was) (cdr cell))))
            (cl-pushnew (car cell) drgnx-extensions-plugins--changed :test #'equal))))
      (setq drgnx-extensions-plugins--shown shown))))

(defun drgnx-extensions-plugin-open (name)
  "Show the page of plugin NAME in the Extensions view (what the plugin notice's click does)."
  (interactive (list (completing-read "Plugin: " (mapcar (lambda (r) (plist-get r :name)) drgnx-plugins--rows) nil nil)))
  (pop-to-buffer (drgnx-extensions-details-open (concat "plugin:" name))))

(defun drgnx-extensions-plugins-open ()
  "Show the plugins in the Extensions list (Settings → Plugins)."
  (interactive)
  (drgnx-extensions-open)
  (drgnx-extensions-list--apply-query "@plugins"))

(defun drgnx-extensions-plugins-approve ()
  "Approve the plugin on this page at the hash the page displayed: the hub refuses it when the files hash differently
now."
  (interactive)
  (let* ((name (drgnx-extensions-plugins--name)) (hash (cdr (assoc name drgnx-extensions-plugins--shown))))
    (unless hash (user-error "Open the page of %s first: Approve sends the hash the page shows" name))
    (when (member name drgnx-extensions-plugins--changed)
      (setq drgnx-extensions-plugins--changed (delete name drgnx-extensions-plugins--changed))
      (user-error "%s changed while this page was open: read the page again, then Approve" name))
    (drgnx-plugins-approve name hash)))

;;;; The replace diff

(defun drgnx-extensions-plugins--wider (new olds)
  "What the list NEW (empty: everything) matches that none of OLDS (lists, empty: everything) did, as text, or nil."
  (cond ((seq-some #'null olds) nil)
        ((null new) "everything")
        (t (when-let* ((extra (seq-remove (lambda (x) (seq-some (lambda (o) (member x o)) olds)) new)))
             (string-join extra ", ")))))

(defun drgnx-extensions-plugins-diff (new old)
  "What the reach NEW (a plist with :abilities, :hosts and :hooks) adds to the approved reach OLD, as lines."
  (let (out)
    (dolist (h (append (plist-get new :hosts) nil))
      (unless (member h (append (plist-get old :hosts) nil)) (push (format "New host %s" h) out)))
    (dolist (a (append (plist-get new :abilities) nil))
      (unless (member a (append (plist-get old :abilities) nil)) (push (format "New ability %s" a) out)))
    (dolist (hook (append (plist-get new :hooks) nil))
      (let* ((point (plist-get hook :point))
             (olds (seq-filter (lambda (o) (equal (plist-get o :point) point)) (append (plist-get old :hooks) nil))))
        (if (null olds)
            (push (format "New hook at %s" point) out)
          (dolist (v (append (plist-get hook :verdicts) nil))
            (unless (seq-some (lambda (o) (member v (append (plist-get o :verdicts) nil))) olds)
              (push (format "New verdict %s at %s" v point) out)))
          ;; M9: a hook that stops being advisory can now deny; one point's hooks are advisory while all of them are
          (when (and (not (eq (plist-get hook :advisory) t))
                     (seq-every-p (lambda (o) (eq (plist-get o :advisory) t)) olds))
            (push (format "Not advisory any more at %s: a failure of the hook now denies" point) out))
          (dolist (key '(:tool_kinds :tools :paths))
            (when-let* ((extra (drgnx-extensions-plugins--wider
                                (append (plist-get hook key) nil)
                                (mapcar (lambda (o) (append (plist-get o key) nil)) olds))))
              (push (format "Wider %s at %s: %s" (substring (symbol-name key) 1) point extra) out))))))
    ;; M9: a bigger key-value store (an approval stored before the hub kept the size says nothing to compare)
    (let ((new-kv (plist-get new :kv_bytes)) (old-kv (plist-get old :kv_bytes)))
      (when (and (integerp new-kv) (integerp old-kv) (> new-kv old-kv))
        (push (format "Bigger key-value store: %d bytes, was %d" new-kv old-kv) out)))
    (nreverse out)))

(defun drgnx-extensions-plugins--diff-section (_name row)
  "A section of the plugins page (`drgnx-plugins-page-sections'): for a plugin that changed since it was approved, what
the new version adds, in the attention face.  Without the approved reach (an approval stored before the hub kept it,
or a stored copy that does not read) it says so, so the page never looks like nothing is new."
  (when (equal (plist-get row :state) "changed")
    (if (not (plist-get row :approved_reach))
        (insert "\n" (propertize "What you approved before is not known: read the whole reach below"
                                 'face (drgnx-extensions-list--attention))
                "\n")
      (let ((lines (drgnx-extensions-plugins-diff row (plist-get row :approved_reach))))
        (insert "\n" (propertize "What the new version adds" 'face 'bold) "\n")
        (if lines
            (dolist (l lines)
              (insert "  " (propertize (concat (drgnx-face-glyph 'warn) " " l) 'face (drgnx-extensions-list--attention)) "\n"))
          (insert "  nothing new: its files changed, what it may reach did not\n"))))))

;;;; Actions on a page

(defun drgnx-extensions-plugins-actions (row buffer)
  "The action buttons of the page of plugin ROW (a normalized list row) in BUFFER."
  (let* ((state (plist-get row :state)) (name (plist-get row :name)) (on (member name (drgnx-extensions-plugins--names)))
         (run (lambda (command) (lambda () (with-current-buffer buffer (call-interactively command))))))
    (concat
     (when (memq state '(on off))
       (concat (drgnx-ui-button (if on "[Turn off]" "[Turn on]") (funcall run #'drgnx-extensions-plugins-toggle)
                                :help "Whether the plugin runs: your plugins setting, new ones last in the hook order")
               " "
               (when on
                 (concat (drgnx-ui-button "[Move up]" (funcall run #'drgnx-extensions-plugins-move-up)
                                          :help "Run it earlier in the hook order")
                         " "
                         (drgnx-ui-button "[Move down]" (funcall run #'drgnx-extensions-plugins-move-down)
                                          :help "Run it later in the hook order")
                         " "))))
     (unless (eq state 'broken)
       (concat (drgnx-ui-button "[Replace…]" (funcall run #'drgnx-extensions-plugins-replace)
                                :help "Install a newer copy from a folder; it stays off until you approve it")
               " "))
     (drgnx-ui-button "[Remove]" (funcall run #'drgnx-extensions-plugins-remove)
                      :help "Remove the plugin and what it stored")
     " ")))

(defun drgnx-extensions-plugins--folder (prompt)
  (unless (fboundp 'drgnx-extensions-jobs-run) (user-error "The job layer is not available (its module is off)"))
  (expand-file-name (read-directory-name prompt nil nil t)))

(defun drgnx-extensions-plugins-install ()
  "Install a plugin from a folder (a background job); the hub then asks you to approve it."
  (interactive)
  (drgnx-extensions-jobs-run 'plugin-install (drgnx-extensions-plugins--folder "Plugin folder: ")))

(defun drgnx-extensions-plugins-replace ()
  "Replace the plugin here with a copy from a folder (a background job); it is `changed' until you approve it."
  (interactive)
  (let ((name (drgnx-extensions-plugins--name)))
    (drgnx-extensions-jobs-run 'plugin-install (drgnx-extensions-plugins--folder (format "Folder of the new %s: " name))
                               :replace t)))

(defun drgnx-extensions-plugins-remove ()
  "Remove the plugin here (a background job), after you say yes."
  (interactive)
  (let ((name (drgnx-extensions-plugins--name)))
    (unless (fboundp 'drgnx-extensions-jobs-run) (user-error "The job layer is not available (its module is off)"))
    (when (y-or-n-p (format "Remove plugin %s and what it stored? " name))
      (drgnx-extensions-jobs-run 'plugin-remove name))))

;;;; The module's part

(defun drgnx-extensions-plugins-setup ()
  "Called by the Extensions module's setup: the page's replace diff, the event, the commands."
  (add-hook 'drgnx-plugins-page-sections #'drgnx-extensions-plugins--diff-section)
  (add-hook 'drgnx-hub-event-functions #'drgnx-extensions-plugins--event)
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((extensions-plugin-install "Install a Plugin from a Folder" drgnx-extensions-plugins-install
                                              "Install a plugin from a folder; you approve it on its page")
                   (extensions-plugin-approve "Approve Plugin" drgnx-extensions-plugins-approve
                                              "Approve the plugin on this page at the hash the page shows")
                   (extensions-plugin-toggle "Turn Plugin On or Off" drgnx-extensions-plugins-toggle
                                             "Turn the plugin here on or off (your plugins setting)")
                   (extensions-plugin-move-up "Move Plugin Up" drgnx-extensions-plugins-move-up
                                              "Run the plugin here earlier in the hook order")
                   (extensions-plugin-move-down "Move Plugin Down" drgnx-extensions-plugins-move-down
                                                "Run the plugin here later in the hook order")
                   (extensions-plugin-replace "Replace Plugin" drgnx-extensions-plugins-replace
                                              "Replace the plugin here with a copy from a folder")
                   (extensions-plugin-remove "Remove Plugin" drgnx-extensions-plugins-remove
                                             "Remove the plugin here")))
    (drgnx-command-define id :category "Extensions" :title title :command fn :doc doc)))

(defun drgnx-extensions-plugins-teardown ()
  "Called by the Extensions module's teardown."
  (remove-hook 'drgnx-plugins-page-sections #'drgnx-extensions-plugins--diff-section)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-extensions-plugins--event))

(provide 'drgnx-extensions-plugins)
;;; drgnx-extensions-plugins.el ends here
