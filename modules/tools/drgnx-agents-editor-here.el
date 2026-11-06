;;; drgnx-agents-editor-here.el --- Explorer badges, the status segment and who is here -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of module tools/agents-in-editor.  The workspace's presence (`agents/presence/subscribe', the event
;; `agent-presence') is cached by the file it names; from it this file builds, when the presence changes and never in
;; redisplay:
;;   - Explorer badges: on each file an agent is editing (or has changed) a few marks, "+N" past three; on a folder one
;;     dot per agent with files under it.  A worktree agent's file lands on the user's tree: the entry's repository
;;     (its `.git' file names the main checkout) and path relative to its top.
;;   - the `agents-here' status segment: one mark per agent working in the project (eight, then "+N"), in the attention
;;     face for an agent that needs you; it opens who is here.
;;   - who is here: a list of the agents (mark, handle, mode, file, line); RET follows the agent.
;; An agent's ordinal comes from `drgnx-agents-editor-here-ordinal-function' when set; until the mirrored sessions carry
;; the hub's ordinal, sessions are numbered in the order this file first sees them.
;; See docs/guide/agents-in-the-editor.md and docs/develop/agents-editor.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-agent-identity)
(require 'drgnx-hub-client)

(declare-function drgnx-explorer-add-decorator "drgnx-explorer")
(declare-function drgnx-explorer-remove-decorator "drgnx-explorer")
(declare-function drgnx-statusbar-define-segment "drgnx-statusbar")
(declare-function drgnx-work-space-workspace "drgnx-work-space")
(declare-function drgnx-work-code--session "drgnx-work-code")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-permissions "drgnx-agents")
(declare-function drgnx-agents-editor-draw--apply "drgnx-agents-editor-draw")
(declare-function drgnx-agents-editor-frame "drgnx-agents-editor")
(declare-function drgnx-agents-editor-watched-buffers "drgnx-agents-editor")
(defvar drgnx-statusbar-left)
(defvar drgnx-agents-editor-followed)
(defvar drgnx-hub-event-functions)
(defvar drgnx-hub-connected-functions)

(defvar drgnx-agents-editor-here-ordinal-function nil
  "A function of a session id returning its ordinal (1-based), or nil: the hub's ordinal, once the mirror carries it.")
(defvar drgnx-agents-editor-here-needs-you-function #'drgnx-agents-editor-here--needs-you
  "A function of a session id: non-nil when the agent waits on you (its mark takes the attention colour).")
(defvar drgnx-agents-editor-here-paired-function nil
  "A function of a session id: non-nil when the agent is paired with you (its mark gets a ring).")

(defconst drgnx-agents-editor-here--editing '("pending" "write" "edit")
  "The presence modes that put a badge on a file: about to change, written by a command, changed by an edit.")

(defvar drgnx-agents-editor-here--on nil "Non-nil while the module shows who is here (work-who-is-here then lists the agents).")
(defvar drgnx-agents-editor-here--files (make-hash-table :test 'equal)
  "The agent's file name → its `agent-presence' data (:file :rel :repo :entries).")
(defvar drgnx-agents-editor-here--badges (make-hash-table :test 'equal)
  "The user's path (no trailing slash) → the badge string of its Explorer row.")
(defvar drgnx-agents-editor-here--rows nil
  "Who is here: ((SESSION ORDINAL MODE USER-FILE LINE)...), one per agent, its newest entry.")
(defvar drgnx-agents-editor-here--status nil "The status segment's string, or nil.")
(defvar drgnx-agents-editor-here--ordinals (make-hash-table :test 'equal) "Interim: session id → ordinal.")
(defvar drgnx-agents-editor-here--initials (make-hash-table) "Ordinal → the first letter of its agent's name.")
(defvar drgnx-agents-editor-here--tops (make-hash-table :test 'equal) "Directory → its repository's main checkout, or t.")

(defun drgnx-agents-editor-here--ordinal (session)
  (or (and drgnx-agents-editor-here-ordinal-function (funcall drgnx-agents-editor-here-ordinal-function session))
      (or (gethash session drgnx-agents-editor-here--ordinals)
          (puthash session (1+ (hash-table-count drgnx-agents-editor-here--ordinals)) drgnx-agents-editor-here--ordinals))))

(defun drgnx-agents-editor-here--needs-you (session)
  (when-let* ((s (and (fboundp 'drgnx-work-code--session) (drgnx-work-code--session session))))
    (and (drgnx-agent-session-permissions s) t)))

(defun drgnx-agents-editor-here--name (session)
  (if-let* ((s (and (fboundp 'drgnx-work-code--session) (drgnx-work-code--session session))))
      (drgnx-agent-session-name s)
    (format "agent %s" session)))

(defun drgnx-agents-editor-here--roots ()
  "The workspace's roots (directories with a trailing slash)."
  (plist-get (and (fboundp 'drgnx-work-space-workspace) (drgnx-work-space-workspace)) :roots))

;;;; Landing on the user's tree

(defun drgnx-agents-editor-here--main-checkout (top)
  "The main checkout (with a trailing slash) of the checkout or linked worktree TOP: TOP itself when its `.git' is a
directory, the repository its `.git' file names when TOP is a linked worktree, else nil.  Only the head of the file is
read, and no file name handler runs."
  (let* ((file-name-handler-alist nil) (git (expand-file-name ".git" top)))
    (cond ((file-directory-p git) (file-name-as-directory top))
          ((file-regular-p git)
           (with-temp-buffer
             (insert-file-contents git nil 0 4096)
             (let ((gitdir (and (re-search-forward "^gitdir: \\(.*\\)$" nil t) (match-string 1))))
               (when (and gitdir (string-match "\\`\\(.*?\\)/\\.git/worktrees/" gitdir))
                 (file-name-as-directory (match-string 1 gitdir)))))))))

(defun drgnx-agents-editor-here--user-path (fp roots)
  "The path in the user's tree that presence data FP is about, or nil when it is in none of ROOTS.  A file under a
root is itself; a file in a linked worktree lands at its relative path in the main checkout, when that is a root."
  (let ((file (plist-get fp :file)) (rel (plist-get fp :rel)))
    (or (and (cl-some (lambda (r) (string-prefix-p r file)) roots) file)
        (when-let* ((rel rel)
                    (dir (file-name-directory file))
                    (main (let ((hit (gethash dir drgnx-agents-editor-here--tops)))
                            (if hit (and (stringp hit) hit)
                              (let ((m (when-let* ((top (locate-dominating-file dir ".git")))
                                         (drgnx-agents-editor-here--main-checkout top))))
                                (puthash dir (or m t) drgnx-agents-editor-here--tops)
                                m))))
                    ((member main roots)))
          (expand-file-name rel main)))))

;;;; Building what is drawn

(defun drgnx-agents-editor-here--mark (ordinal &optional session)
  "Agent ORDINAL's mark as a propertized string."
  (let* ((face (plist-get (drgnx-agent-identity ordinal) :face))
         (needs (and session drgnx-agents-editor-here-needs-you-function
                     (funcall drgnx-agents-editor-here-needs-you-function session)))
         (paired (and session drgnx-agents-editor-here-paired-function
                      (funcall drgnx-agents-editor-here-paired-function session))))
    (propertize (concat (drgnx-agent-identity-text ordinal) (if paired "◌" ""))
                'face (if needs (list 'drgnx-status-needs-you face) face))))

(defun drgnx-agents-editor-here--badge (ordinals limit initials)
  "The marks of ORDINALS (up to LIMIT, then \"+N\"); with INITIALS, each followed by its agent's first letter."
  (let* ((shown (seq-take ordinals limit)) (more (- (length ordinals) (length shown))))
    (concat " "
            (mapconcat (lambda (o)
                         (let ((m (drgnx-agents-editor-here--mark o)))
                           (if initials (concat m (propertize (drgnx-agents-editor-here--initial o) 'face (get-text-property 0 'face m))) m)))
                       shown " ")
            (if (> more 0) (format " +%d" more) ""))))

(defun drgnx-agents-editor-here--initial (ordinal)
  (or (gethash ordinal drgnx-agents-editor-here--initials) ""))

(defun drgnx-agents-editor-here--rebuild ()
  "Work out the badges, the rows and the status segment from the cached presence."
  (clrhash drgnx-agents-editor-here--badges)
  (let ((roots (drgnx-agents-editor-here--roots)) (files (make-hash-table :test 'equal)) (dirs (make-hash-table :test 'equal))
        (sessions nil) (rows nil))
    (maphash
     (lambda (_ fp)
       (when-let* ((path (drgnx-agents-editor-here--user-path fp roots)))
         (dolist (e (plist-get fp :entries))
           (let* ((sid (plist-get e :session)) (ord (drgnx-agents-editor-here--ordinal sid)))
             (puthash ord (upcase (substring (drgnx-agents-editor-here--name sid) 0 1)) drgnx-agents-editor-here--initials)
             (cl-pushnew sid sessions :test #'equal)
             (let ((old (assoc sid rows)))
               (when (or (null old) (> (or (plist-get e :at) 0) (or (nth 5 old) 0)))
                 (setq rows (cons (list sid ord (plist-get e :mode) path (plist-get e :line) (plist-get e :at))
                                  (assoc-delete-all sid rows)))))
             (when (member (plist-get e :mode) drgnx-agents-editor-here--editing)
               (cl-pushnew ord (gethash path files))
               (let ((d (file-name-directory path)))
                 (while (and d (cl-some (lambda (r) (string-prefix-p r d)) roots))
                   (cl-pushnew ord (gethash (directory-file-name d) dirs))
                   (setq d (and (not (member d roots)) (file-name-directory (directory-file-name d)))))))))))
     drgnx-agents-editor-here--files)
    (maphash (lambda (p ords) (puthash p (drgnx-agents-editor-here--badge (sort (copy-sequence ords) #'<) 3 t)
                                       drgnx-agents-editor-here--badges))
             files)
    (maphash (lambda (p ords) (unless (gethash p files)
                                (puthash p (drgnx-agents-editor-here--badge (sort (copy-sequence ords) #'<) 6 nil)
                                         drgnx-agents-editor-here--badges)))
             dirs)
    (setq drgnx-agents-editor-here--rows (sort rows (lambda (a b) (< (nth 1 a) (nth 1 b)))))
    (setq drgnx-agents-editor-here--status
          (when sessions
            (let* ((sorted (sort (copy-sequence sessions)
                                 (lambda (a b) (< (drgnx-agents-editor-here--ordinal a) (drgnx-agents-editor-here--ordinal b)))))
                   (shown (seq-take sorted 8)) (more (- (length sorted) (length shown))))
              (concat (mapconcat (lambda (s) (drgnx-agents-editor-here--mark (drgnx-agents-editor-here--ordinal s) s)) shown " ")
                      (if (> more 0) (format " +%d" more) "")))))
    (force-mode-line-update t)
    (when (fboundp 'drgnx-explorer-add-decorator)
      (drgnx-explorer-add-decorator #'drgnx-agents-editor-here--decorate))))

;;;; The Explorer decorator and the status segment

(defun drgnx-agents-editor-here--decorate (_bol eol path _dirp _name-start)
  "The Explorer decorator: the row's badge, from the cache, in an overlay the row's next paint removes."
  (when-let* ((s (gethash (directory-file-name path) drgnx-agents-editor-here--badges)))
    (let ((o (make-overlay eol eol)))
      (overlay-put o 'drgnx-git t)
      (overlay-put o 'priority 5)
      (overlay-put o 'before-string s))))

(defun drgnx-agents-editor-here--segment ()
  "The `agents-here' segment: the marks of the agents in this project."
  drgnx-agents-editor-here--status)

;;;; Who is here

(defun drgnx-agents-editor-here--label (row)
  (pcase-let ((`(,sid ,ord ,mode ,file ,line) row))
    (format "%s %s · %s · %s%s" (drgnx-agent-identity-text ord) (drgnx-agents-editor-here--name sid) (or mode "here")
            (file-name-nondirectory file) (if line (format ":%d" line) ""))))

(defun drgnx-agents-editor-here-row (entry file)
  "The who-is-here row of presence ENTRY (a plist) in FILE: (SESSION ORDINAL MODE FILE LINE)."
  (let ((sid (plist-get entry :session)))
    (list sid (drgnx-agents-editor-here--ordinal sid) (plist-get entry :mode) file (plist-get entry :line))))

(defun drgnx-agents-editor-here-follow (row)
  "Follow the agent of ROW: open its file at its line and keep its name tag on."
  (pcase-let ((`(,sid ,_ord ,_mode ,file ,line) row))
    (setq drgnx-agents-editor-followed sid)
    (pop-to-buffer (find-file-noselect file))
    (when line (goto-char (point-min)) (forward-line (1- line)))
    (dolist (b (drgnx-agents-editor-watched-buffers))
      (when-let* ((f (drgnx-agents-editor-frame b))) (drgnx-agents-editor-draw--apply b f)))))

(defun drgnx-agents-editor-here-choose (rows)
  "Ask which of ROWS ((SESSION ORDINAL MODE FILE LINE)...) to follow: RET follows it.  Interactive commands only."
  (when rows
    (let* ((labels (mapcar (lambda (r) (cons (drgnx-agents-editor-here--label r) r)) rows))
           (pick (completing-read "Follow: " (mapcar #'car labels) nil t)))
      (when-let* ((row (cdr (assoc pick labels)))) (drgnx-agents-editor-here-follow row)))))

(defun drgnx-agents-editor-here ()
  "Who is here: the agents working in this project; RET follows the one you choose."
  (interactive)
  (if drgnx-agents-editor-here--rows
      (drgnx-agents-editor-here-choose drgnx-agents-editor-here--rows)
    (message "No agent is working in this project")))

;;;; The feed

(defun drgnx-agents-editor-here--note (fp)
  "Cache presence data FP (a file's entries) and rebuild what is drawn."
  (let ((file (plist-get fp :file)))
    (if (plist-get fp :entries) (puthash file fp drgnx-agents-editor-here--files) (remhash file drgnx-agents-editor-here--files))
    (drgnx-agents-editor-here--rebuild)))

(defun drgnx-agents-editor-here--event (event data)
  (when (equal event "agent-presence") (drgnx-agents-editor-here--note data)))

(defun drgnx-agents-editor-here--subscribe ()
  "Ask the hub for the workspace's presence; a missing hub is quiet (the next connection asks again)."
  (when-let* ((ws (and (fboundp 'drgnx-work-space-workspace) (drgnx-work-space-workspace))))
    (condition-case nil
        (drgnx-hub-call "agents/presence/subscribe" (list :workspace (list :id (plist-get ws :id) :roots (plist-get ws :roots)))
                        (lambda (result err)
                          (unless err
                            (clrhash drgnx-agents-editor-here--files)
                            (dolist (fp (append (plist-get result :files) nil))
                              (puthash (plist-get fp :file) fp drgnx-agents-editor-here--files))
                            (drgnx-agents-editor-here--rebuild))))
      (error nil))))

;;;; Setup

(defun drgnx-agents-editor-here--bar-list (left)
  "LEFT, the status bar's left segments, with `agents-here' straight after `agents'."
  (if (or (memq 'agents-here left) (not (memq 'agents left)))
      left
    (let (out) (dolist (s left) (push s out) (when (eq s 'agents) (push 'agents-here out))) (nreverse out))))

(defun drgnx-agents-editor-here-setup ()
  "Cache the workspace's presence and show it.  Called by the module's setup."
  (drgnx-module-hook 'drgnx-hub-event-functions here-event (event data)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-here--event event data))
  (drgnx-module-hook 'drgnx-hub-connected-functions here-connected ()
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-here--subscribe))
  (drgnx-command-define 'agents-here :category "Agents" :title "Who Is Here"
                        :command #'drgnx-agents-editor-here
                        :doc "The agents working in this project; RET follows the one you choose")
  (eval-after-load 'drgnx-explorer (drgnx-modules-with-owner (drgnx-explorer-add-decorator #'drgnx-agents-editor-here--decorate)))
  (eval-after-load 'drgnx-statusbar
    (drgnx-modules-with-owner
      (drgnx-statusbar-define-segment 'agents-here :fn #'drgnx-agents-editor-here--segment :click 'drgnx-agents-editor-here
                                      :help "Agents working in this project; click for who is here")
      (drgnx-module-set 'drgnx-statusbar-left (drgnx-agents-editor-here--bar-list drgnx-statusbar-left))))
  (setq drgnx-agents-editor-here--on t)
  (drgnx-agents-editor-here--subscribe))

(defun drgnx-agents-editor-here-teardown ()
  "Take the badges out of the Explorer and forget the cached presence."
  (when (fboundp 'drgnx-explorer-remove-decorator)
    (drgnx-explorer-remove-decorator #'drgnx-agents-editor-here--decorate))
  (clrhash drgnx-agents-editor-here--files)
  (clrhash drgnx-agents-editor-here--badges)
  (clrhash drgnx-agents-editor-here--ordinals)
  (clrhash drgnx-agents-editor-here--initials)
  (clrhash drgnx-agents-editor-here--tops)
  (setq drgnx-agents-editor-here--rows nil drgnx-agents-editor-here--status nil drgnx-agents-editor-here--on nil))

(provide 'drgnx-agents-editor-here)
;;; drgnx-agents-editor-here.el ends here
