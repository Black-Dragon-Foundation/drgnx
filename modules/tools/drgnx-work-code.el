;;; drgnx-work-code.el --- The Work space's way into the code: open at the agent's line, the files picker, who is here -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Files open where the agent is: Enter on a file in the map asks the hub's presence model (`agents/presence/get') who
;; is in it, takes the line of the agent on the selection's chain (else of the most recent agent) and opens the file in
;; that agent's worktree at that line.  Without a line it opens at the top and says "file only".  `e' lists the files an
;; agent edited (`work/files') in a popup with one hint key each; `work-who-is-here' names the agents in the file you
;; are visiting and selects it on the map.  The hub's paths are the agents' own worktrees, so every question is asked
;; for the file in each candidate worktree and in the user's checkout.  Every name the hub gives (a session's folder,
;; an entry's file, an edited file) is an agent's: it is resolved with no file name handler and only a plain local file
;; inside the agent's folder or the workspace opens, by its true name (docs/develop/core.md, "Names an agent gave").
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-file)
(require 'drgnx-work-client)
(require 'diff-mode)

(declare-function tab-line-mode "tab-line")
(defvar drgnx-agents-editor-here--on)
(declare-function drgnx-agents-editor-here-row "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here-show "drgnx-agents-editor-here")
(defvar tab-line-tabs-function)
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-work-nav-chain "drgnx-work-detail")
(declare-function drgnx-work-map-buffers "drgnx-work-map")
(declare-function drgnx-work-map--state "drgnx-work-map")
(declare-function drgnx-work-map-select "drgnx-work-map")
(declare-function drgnx-work-space-open "drgnx-work-space")
(declare-function drgnx-work-space-workspace "drgnx-work-space")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(declare-function drgnx-agent-session-name "drgnx-agents")
(defvar drgnx-agents--sessions)
(defvar drgnx-work-space--view)
(defvar drgnx-work-map--selection)

(defvar-local drgnx-work-code--file-only nil
  "Non-nil in a buffer the Work space opened without a line to go to: it is at the top, \"file only\".")

;;;; Names the hub gave

(defun drgnx-work-code-local-dir (dir)
  "DIR, a folder the hub named (an agent's), as a directory name when it is local; else nil: a remote or quoted name,
one a link of it leads to, or a link loop (`drgnx-file-truename': no file name handler runs on it).  DIR's own name,
not its true one: the hub keys presence by the names in the agent's folder."
  (and (stringp dir) (drgnx-file-truename dir)
       (let ((file-name-handler-alist nil)) (file-name-as-directory (expand-file-name dir)))))

(defun drgnx-work-code-local-file (name dirs)
  "NAME, a file the hub or an agent named (absolute, or relative to the first of DIRS), by its true name when that is a
plain regular file inside one of DIRS; else nil.  A remote or quoted name, a link out of DIRS or into a loop, a device,
a FIFO or a folder, and a name a file name handler would read (compressed, encrypted, inside an archive) are nil.
Decided with no handler running (docs/develop/core.md, \"Names an agent gave\").  Open the name this gives, never
NAME: `find-file' of NAME follows its links again, with handlers on."
  (when-let* ((dirs (delq nil (mapcar #'drgnx-work-code-local-dir dirs)))
              ((stringp name))
              (true (drgnx-file-truename name (car dirs))))
    (and (let ((file-name-handler-alist nil)) (file-regular-p true))
         (not (find-file-name-handler true 'insert-file-contents))
         (seq-some (lambda (d) (drgnx-file-inside-p true d)) dirs)
         true)))

(defconst drgnx-coord-control-chars (concat "\0-\37\177-" (string #x9f #x61c #x200e #x200f #x202a ?- #x202e #x2066 ?- #x2069
                                                                  #x2028 #x2029))
  "Characters an agent's text must not carry, as the inside of a regexp bracket: the C0 controls, DEL, the C1
controls, the BiDi controls (the Arabic letter mark, marks, embeddings, overrides, isolates) that make text
read other than it is, and the line and paragraph separators (U+2028, U+2029) that start a line a reader sees.")

(defun drgnx-work-code-one-line (s)
  "S, words of an agent's or the hub's (a path, a hunk's header), on one line: its control and bidi characters are
spaces, so in what the user sends an agent nothing of it reads as a line of its own (a forged \"[message from the user
…]\" header, a plan's \"### Task\")."
  (string-trim (replace-regexp-in-string (concat "[" drgnx-coord-control-chars "]+") " " (format "%s" s))))

;;;; Where things are

(defun drgnx-work-code--roots ()
  "The roots of the workspace: those of the newest map's subscription, else of the frame's workspace."
  (or (when-let* ((map (car (drgnx-work-map-buffers)))
                  (view (buffer-local-value 'drgnx-work-space--view map))
                  (v (drgnx-work-client--get view)))
        (plist-get (plist-get (drgnx-work-client--view-params v) :workspace) :roots))
      (plist-get (drgnx-work-space-workspace) :roots)))

(defun drgnx-work-code--root-named (name)
  "The workspace root whose directory is called NAME, with its trailing slash, or nil."
  (seq-find (lambda (r) (equal (file-name-nondirectory (directory-file-name r)) name)) (drgnx-work-code--roots)))

(defun drgnx-work-code--repo-of (top)
  "The repository the checkout or linked worktree TOP belongs to (a directory name), or nil.  A linked worktree has a
`.git' file naming its gitdir inside the repository.  TOP may be an agent's folder: no file name handler runs, and
only the head of a `.git' file is read."
  (let* ((file-name-handler-alist nil) (git (expand-file-name ".git" top)))
    (cond ((file-directory-p git) (file-name-as-directory top))
          ((file-regular-p git)
           (with-temp-buffer
             (insert-file-contents git nil 0 4096)
             (when (re-search-forward "^gitdir: \\(.*\\)$" nil t)
               (let ((gitdir (match-string 1)))
                 (when (string-match "\\`\\(.*?\\)/\\.git/worktrees/" gitdir)
                   (file-name-as-directory (match-string 1 gitdir))))))))))

(defun drgnx-work-code--key (file)
  "FILE's place in a repository: (REPO-NAME REL), or nil when it is in no repository."
  (when-let* ((top (locate-dominating-file file ".git"))
              (repo (drgnx-work-code--repo-of top)))
    (list (file-name-nondirectory (directory-file-name repo)) (file-relative-name file top))))

(defun drgnx-work-code--session (sid)
  "The mirrored session whose hub id is SID, or nil."
  (and (boundp 'drgnx-agents--sessions)
       (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) sid)) drgnx-agents--sessions)))

(defun drgnx-work-code--worktree (sid)
  "The folder session SID works in, with its trailing slash, or nil when this editor does not mirror it or the folder is
not a local one (`drgnx-work-code-local-dir')."
  (when-let* ((s (drgnx-work-code--session sid)))
    (drgnx-work-code-local-dir (drgnx-agent-session-cwd s))))

(defun drgnx-work-code--agent-name (sid)
  (if-let* ((s (drgnx-work-code--session sid))) (drgnx-agent-session-name s) (format "agent %s" sid)))

(defun drgnx-work-code--sid (id)
  "The hub session id of the map item ID (\"agent:SID\" or \"agent:SID/TOOL\"), or nil."
  (when (string-prefix-p "agent:" id) (car (split-string (substring id (length "agent:")) "/"))))

(defun drgnx-work-code--chain-sids (state sel)
  "The hub session ids on SEL's chain, SEL's own first: a selected agent, or the agents a file or branch came from."
  (let (out)
    (dolist (id (cons (cdr sel) (nth 0 (drgnx-work-nav-chain state sel))))
      (when-let* ((sid (drgnx-work-code--sid id))) (cl-pushnew sid out :test #'equal)))
    (nreverse out)))

(defun drgnx-work-code--file-item (id)
  "The map item ID \"file:REPO/REL\" as (REPO REL), or nil."
  (when (string-prefix-p "file:" id)
    (let ((parts (split-string (substring id (length "file:")) "/")))
      (when (cdr parts) (list (car parts) (string-join (cdr parts) "/"))))))

(defun drgnx-work-code--paths (repo rel sids)
  "The paths of REL of REPO that can hold an agent's work: in each of SIDS' worktrees that has it, then the user's
checkout.  Names only (REL is the hub's), made with no file name handler."
  (let ((file-name-handler-alist nil))
    (delq nil (delete-dups
               (append (mapcar (lambda (sid) (when-let* ((wt (drgnx-work-code--worktree sid)))
                                               (expand-file-name rel wt)))
                               sids)
                       (list (when-let* ((root (drgnx-work-code--root-named repo))) (expand-file-name rel root))))))))

(defun drgnx-work-code--dirs (sids)
  "The folders a file of the agents SIDS may open from: their local worktrees, then the workspace's roots."
  (delq nil (append (mapcar #'drgnx-work-code--worktree sids) (drgnx-work-code--roots))))

;;;; The presence model's answer

(defun drgnx-work-code--list (x) (append x nil))

(defun drgnx-work-code--presence (paths callback)
  "Ask the hub who is in each of PATHS; CALLBACK gets all the entries (plists) once every question was answered.  A
hub that is not there answers none."
  (let ((left (length paths)) (all nil))
    (if (null paths)
        (funcall callback nil)
      (dolist (p paths)
        (let ((done (lambda (entries)
                      (setq all (append all entries))
                      (when (zerop (cl-decf left)) (funcall callback all)))))
          (condition-case nil
              (drgnx-hub-call "agents/presence/get" (list :file p)
                              (lambda (res _err) (funcall done (drgnx-work-code--list (plist-get res :entries)))))
            (error (funcall done nil))))))))

(defun drgnx-work-code--newest (entries)
  (car (sort (copy-sequence entries) (lambda (a b) (> (or (plist-get a :at) 0) (or (plist-get b :at) 0))))))

(defun drgnx-work-code--pick (entries sids)
  "The entry to open the file at: the newest of the chain's agents (SIDS) that has a line, else the newest of any agent
with a line, else the newest of the chain's, else the newest of all (those open at the top: file only)."
  (let ((chain (seq-filter (lambda (e) (member (plist-get e :session) sids)) entries))
        (lined (lambda (es) (seq-filter (lambda (e) (plist-get e :line)) es))))
    (or (drgnx-work-code--newest (funcall lined chain))
        (drgnx-work-code--newest (funcall lined entries))
        (drgnx-work-code--newest chain)
        (drgnx-work-code--newest entries))))

;;;; Opening

(defun drgnx-work-code--visit (path line beside)
  "Visit PATH (a true name `drgnx-work-code-local-file' gave) at LINE (nil: the top, \"file only\"), in the selected
window or, with BESIDE, in another one."
  (let ((buffer (find-file-noselect path)))
    (with-current-buffer buffer
      (setq drgnx-work-code--file-only (not line))
      (goto-char (point-min))
      (when line (forward-line (1- line))))
    (if beside (display-buffer buffer) (pop-to-buffer buffer))
    (dolist (w (get-buffer-window-list buffer nil t)) (set-window-point w (with-current-buffer buffer (point))))
    (unless line (message "%s: file only" (file-name-nondirectory path)))
    buffer))

(cl-defun drgnx-work-code--open-paths (paths sids beside)
  "Open the first of PATHS the agents SIDS have an entry in at its line; with no entry, the first that is there, at the
top.  Only a plain local file inside the agents' folders or the workspace opens, by its true name; an entry naming
anything else (it is the hub's word) is passed over.  The buffer, when the hub answered at once."
  (let ((dirs (drgnx-work-code--dirs sids)) (result nil))
    (drgnx-work-code--presence
     paths
     (lambda (entries)
       (let* ((ok (lambda (p) (and (member p paths) (drgnx-work-code-local-file p dirs))))
              (e (drgnx-work-code--pick (seq-filter (lambda (e) (funcall ok (plist-get e :file))) entries) sids))
              (true (and e (funcall ok (plist-get e :file))))
              (any (and (not true) (seq-some (lambda (p) (drgnx-work-code-local-file p dirs)) paths))))
         (setq result
               (cond (true (drgnx-work-code--visit true (plist-get e :line) beside))
                     (any (drgnx-work-code--visit any nil beside))
                     (t (message "Work: %s is no plain local file in the agent's folder" (car paths)) nil))))))
    result))

(cl-defun drgnx-work-code-open-file (state sel &key beside agents)
  "Open the file SEL (\"file:REPO/REL\") of STATE at the agent's line: AGENTS' (hub session ids), else the agents on SEL's
chain, else the most recent one's; at the top with \"file only\" when no line is known.  Returns the buffer when the hub
answered at once."
  (pcase-let ((`(,repo ,rel) (or (drgnx-work-code--file-item (cdr sel)) (user-error "Not a file"))))
    (let ((sids (or agents (drgnx-work-code--chain-sids state sel))))
      (drgnx-work-code--open-paths (drgnx-work-code--paths repo rel sids) sids beside))))

;;;; The files picker

(defconst drgnx-work-code--picker-own '("q")
  "Keys the picker keeps for itself: `q' closes it (Enter opens the line at point).")

(defun drgnx-work-code-hint-keys (n)
  "The first N hint keys: `1'-`9', then `a'-`z', without the picker's own keys."
  (seq-take (seq-remove (lambda (k) (member k drgnx-work-code--picker-own))
                        (mapcar #'char-to-string (append (number-sequence ?1 ?9) (number-sequence ?a ?z))))
            n))

(defvar-local drgnx-work-files--rows nil "The picker's rows, in order: plists (:path ABSOLUTE :sid SID).")

(defun drgnx-work-files--pick (index)
  "Open the picker's row INDEX (from 0) at its agent's line."
  (if-let* ((row (nth index drgnx-work-files--rows)))
      (let ((sid (plist-get row :sid)) (path (plist-get row :path)))
        (quit-window)
        (drgnx-work-code--open-paths (list path) (list sid) nil))
    (user-error "No file for that key")))

(defun drgnx-work-files-open-at-point ()
  "Open the file on the current line."
  (interactive)
  (drgnx-work-files--pick (max 0 (- (line-number-at-pos) 1))))

(defun drgnx-work-files-hint ()
  "The key just typed in the picker: `q' closes it, a hint key opens its file at the agent's line."
  (interactive)
  (let ((key (and (characterp last-command-event) (char-to-string last-command-event))))
    (cond ((equal key "q") (quit-window))
          ((and key (member key (drgnx-work-code-hint-keys 40)))
           (drgnx-work-files--pick (cl-position key (drgnx-work-code-hint-keys 40) :test #'equal)))
          (t (user-error "No file for that key")))))

(defvar drgnx-work-files-mode-map
  (let ((m (make-sparse-keymap)))
    ;; typing in the picker is choosing: letters and digits are hint keys, Enter opens the line at point
    (define-key m [remap self-insert-command] #'drgnx-work-files-hint)
    (define-key m [remap newline] #'drgnx-work-files-open-at-point)
    m)
  "Keymap of the files picker.  Its hint keys are not bound one by one: every typed character goes to
`drgnx-work-files-hint', so the keys are the registry-free choice of whoever reads the list.")

(define-derived-mode drgnx-work-files-mode nil "Work files"
  "The files an agent edited, one hint key each; a key opens the file at the agent's line."
  (setq-local truncate-lines t cursor-type nil buffer-read-only t)
  (buffer-disable-undo))

(defun drgnx-work-files--fill (buffer sid files)
  "Fill the picker BUFFER with FILES (plists of `work/files') of session SID: edited ones, most changed first."
  (with-current-buffer buffer
    (let ((wt (drgnx-work-code--worktree sid)) (inhibit-read-only t)
          (keys (drgnx-work-code-hint-keys (length files))))
      (erase-buffer)
      (setq drgnx-work-files--rows nil)
      (when (null files) (insert "  no edited files\n"))
      (cl-loop for f in files for i from 0
               do (let ((rel (plist-get f :path)) (at (plist-get f :read_at)))
                    (push (list :path (if wt (let ((file-name-handler-alist nil)) (expand-file-name rel wt)) rel) :sid sid)
                          drgnx-work-files--rows)
                    (insert (format " %-2s %s  +%d −%d%s%s\n" (or (nth i keys) "") rel
                                    (or (plist-get f :plus) 0) (or (plist-get f :minus) 0)
                                    (if (eq (plist-get f :untracked) t) "  new file" "")
                                    (if at (format-time-string "  read %H:%M" at) "")))))
      (setq drgnx-work-files--rows (nreverse drgnx-work-files--rows))
      (goto-char (point-min)))))

(defun drgnx-work-code--selected-sid (state sel)
  "The session whose files SEL stands for: an agent, a subagent's parent, or the first agent a branch came from."
  (or (drgnx-work-code--sid (cdr sel))
      (car (drgnx-work-code--chain-sids state sel))))

(defun drgnx-work-code-files (state sel &optional no-display)
  "The files picker of the agent SEL stands for in STATE: its edited files with `+N −M', one hint key each.  Shown in
the popup lane unless NO-DISPLAY.  Returns the picker buffer, filled when the hub answered at once."
  (let* ((sid (or (drgnx-work-code--selected-sid state sel) (user-error "Select an agent or its branch first")))
         (buffer (get-buffer-create (format "*drgnx work files: %s*" (drgnx-work-code--agent-name sid)))))
    (with-current-buffer buffer
      (drgnx-work-files-mode)
      (let ((inhibit-read-only t)) (erase-buffer) (insert "  …\n")))
    (condition-case err
        (drgnx-hub-call "work/files" (list :session sid)
                        (lambda (res _err)
                          (when (buffer-live-p buffer)
                            (drgnx-work-files--fill buffer sid (drgnx-work-code--list (plist-get res :files))))))
      (error (message "Work: could not list the files: %s" (error-message-string err))))
    (unless no-display (display-buffer buffer))
    buffer))

(defun drgnx-work-code-files-command ()
  "The files picker of the selected agent (or branch)."
  (interactive)
  (let ((state (drgnx-work-map--state)))
    (unless (and state (bound-and-true-p drgnx-work-map--selection)) (user-error "Nothing is selected"))
    (select-window (display-buffer (drgnx-work-code-files state drgnx-work-map--selection t)))))

;;;; Who is here

(defun drgnx-work-who-is-here ()
  "Name the agents in the file this buffer visits, with their lines, and select the file on the map.  With nobody in it:
\"No agent in this file\", and nothing moves."
  (interactive)
  (let* ((file (or buffer-file-name (user-error "This buffer visits no file")))
         (ask (called-interactively-p 'any))
         (key (drgnx-work-code--key file))
         (repo (car key)) (rel (cadr key))
         (paths (delete-dups
                 (delq nil
                       (append (list file)
                               (when key
                                 (append (when-let* ((root (drgnx-work-code--root-named repo))) (list (expand-file-name rel root)))
                                         (mapcar (lambda (s)
                                                   (when-let* ((cwd (drgnx-work-code-local-dir (drgnx-agent-session-cwd s)))
                                                               (top (drgnx-work-code--repo-of cwd))
                                                               ((equal repo (file-name-nondirectory (directory-file-name top)))))
                                                     (let ((file-name-handler-alist nil)) (expand-file-name rel cwd))))
                                                 (and (boundp 'drgnx-agents--sessions) drgnx-agents--sessions))))))))
         (result nil))
    (drgnx-work-code--presence
     paths
     (lambda (entries)
       (let ((now (let (seen out)   ; one entry per session: its newest
                    (dolist (e (sort (copy-sequence entries) (lambda (a b) (> (or (plist-get a :at) 0) (or (plist-get b :at) 0)))))
                      (unless (member (plist-get e :session) seen)
                        (push (plist-get e :session) seen) (push e out)))
                    (nreverse out))))
         (setq result now)
         (if (null now)
             (message "No agent in this file")
           (when key (drgnx-work-code--select-file repo rel))
           (message "%s"
                    (mapconcat (lambda (e)
                                 (format "%s %s %s" (drgnx-work-code--agent-name (plist-get e :session))
                                         (pcase (plist-get e :mode) ("edit" "editing") ("write" "writing") ("read" "reading")
                                                (m (or m "in")))
                                         (if-let* ((l (plist-get e :line))) (format "line %d" l) "(file only)")))
                               now "; "))
           ;; with the editor's agents on, the agents are a small list: RET follows the one on the row, `o' opens its panel
           (when (and ask (bound-and-true-p drgnx-agents-editor-here--on))
             (drgnx-agents-editor-here-show (mapcar (lambda (e) (drgnx-agents-editor-here-row e file)) now)))))))
    result))

(defun drgnx-work-code--select-file (repo rel)
  "Show the map with the file REPO/REL selected, when the map has it."
  (when-let* ((map (or (car (drgnx-work-map-buffers)) (drgnx-work-space-open nil t)))
              (id (format "file:%s/%s" repo rel)))
    (with-current-buffer map
      (when-let* ((state (drgnx-work-map--state)) ((drgnx-work-client-item state id)))
        (drgnx-work-map-select (cons 'file id))))
    (pop-to-buffer map)))

;;;; Side-by-side diffs

(defvar drgnx-work-code--saved-windows nil
  "The window configuration from before the diffs opened; nil while no diffs are open.  The first one is kept: opening
the diffs again never replaces it.")

(defconst drgnx-work-code--hunk-keywords
  '(("^\\(?:---\\|\\+\\+\\+\\) .*" . 'diff-file-header) ("^@@ .*" . 'diff-hunk-header)
    ("^\\+.*" . 'diff-added) ("^-.*" . 'diff-removed))
  "How a hunk buffer is coloured: from its text alone, with `diff-mode''s faces.")

(define-derived-mode drgnx-work-hunk-mode special-mode "Work hunk"
  "An agent's change as diff text: read-only and coloured as a diff, and no `diff-mode' buffer.  The file names in it
are the agent's: `diff-mode' would read them with file name handlers on (its syntax colouring, which-func), and its
keys, VC and ediff would open, apply or revert the files they name — in a live agent's worktree, or in the folder the
buffer stands in.  Its folder is the root, no agent's or user's: VC finds nothing here."
  (setq-local font-lock-defaults '(drgnx-work-code--hunk-keywords t)
              default-directory "/"
              truncate-lines t)
  (buffer-disable-undo))

(define-derived-mode drgnx-work-diff-mode drgnx-work-hunk-mode "Work diff"
  "One file of an agent's work as a diff against the base its worktree was cut from.  The keys come from the key
profiles: q puts the windows back, a and D belong to the review view.")

(defun drgnx-work-code--diff-buffer (path diff)
  "A fresh read-only diff buffer for PATH holding DIFF."
  (let ((name (format "*drgnx work diff: %s*" path)))
    (when-let* ((old (get-buffer name))) (kill-buffer old))
    (with-current-buffer (get-buffer-create name)
      (let ((inhibit-read-only t))
        (drgnx-work-diff-mode)
        (insert diff))
      (goto-char (point-min))
      (current-buffer))))

(defun drgnx-work-code--diff-tabs ()
  "`tab-line-tabs-function' of the third diff window: the buffers stacked in it."
  (window-parameter (selected-window) 'drgnx-work-diff-tabs))

(defun drgnx-work-code--diff-layout (buffers)
  "Show BUFFERS: at most three windows side by side, the files beyond the second as tab-line tabs in the third.  The
window configuration is saved first."
  (unless drgnx-work-code--saved-windows
    (setq drgnx-work-code--saved-windows (current-window-configuration)))
  (delete-other-windows)
  (let ((wins (list (selected-window))))
    (dotimes (_ (1- (min 3 (length buffers))))
      (push (condition-case nil (split-window (car wins) nil 'right) (error (car wins))) wins))
    (setq wins (nreverse wins))
    (let ((last-index (1- (length wins))))
      (cl-loop for w in wins for i from 0
               do (if (< i last-index)
                      (set-window-buffer w (nth i buffers))
                    (let ((tabs (nthcdr i buffers)))
                      (set-window-parameter w 'drgnx-work-diff-tabs tabs)
                      (dolist (b tabs)
                        (with-current-buffer b
                          (setq-local tab-line-tabs-function #'drgnx-work-code--diff-tabs)
                          (tab-line-mode 1)))
                      (set-window-buffer w (car tabs))))))
    buffers))

(defun drgnx-work-code--show-diffs (files diffs)
  (drgnx-work-code--diff-layout
   (mapcar (lambda (p) (drgnx-work-code--diff-buffer p (gethash p diffs ""))) files)))

(defun drgnx-work-code-diffs (state sel)
  "Open the files the agent SEL stands for in STATE edited, each as its diff against the base its worktree was cut
from (`work/hunks'): one window per file, three side by side at most, the rest as tabs in the third.  The window
configuration is saved first; \\[drgnx-work-diff-quit] puts it back.  Returns the diff buffers when the hub answered at once."
  (let* ((sid (or (drgnx-work-code--selected-sid state sel) (user-error "Select an agent or its branch first")))
         (result nil))
    (condition-case err
        (drgnx-hub-call
         "work/files" (list :session sid)
         (lambda (res _err)
           (let* ((files (mapcar (lambda (f) (plist-get f :path)) (drgnx-work-code--list (plist-get res :files))))
                  (left (length files)) (diffs (make-hash-table :test #'equal)))
             (if (null files)
                 (message "Work: %s has edited no files" (drgnx-work-code--agent-name sid))
               (dolist (p files)
                 (drgnx-hub-call "work/hunks" (list :session sid :path p)
                                 (lambda (r _e)
                                   (puthash p (or (plist-get r :diff) "") diffs)
                                   (when (zerop (cl-decf left))
                                     (setq result (drgnx-work-code--show-diffs files diffs))))))))))
      (error (message "Work: could not fetch the diffs: %s" (error-message-string err))))
    result))

(defun drgnx-work-code-diffs-command ()
  "The diffs of the selected agent (or branch)."
  (interactive)
  (let ((state (drgnx-work-map--state)))
    (unless (and state (bound-and-true-p drgnx-work-map--selection)) (user-error "Nothing is selected"))
    (drgnx-work-code-diffs state drgnx-work-map--selection)))

(defun drgnx-work-code--diff-buffers ()
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-diff-mode)) (buffer-list)))

(defun drgnx-work-diff-quit ()
  "Close the diffs and put the windows back the way they were."
  (interactive)
  (let ((config drgnx-work-code--saved-windows))
    (setq drgnx-work-code--saved-windows nil)
    (when config (set-window-configuration config))
    (mapc #'kill-buffer (drgnx-work-code--diff-buffers))))

(defun drgnx-work-diff-accept-hunk ()
  "Accept the hunk at point: not here, the review view decides it."
  (interactive)
  (user-error "Accepting a hunk is done in the review view"))

(defun drgnx-work-diff-reject-hunk ()
  "Reject the hunk at point: not here, the review view decides it."
  (interactive)
  (user-error "Rejecting a hunk is done in the review view"))

(defun drgnx-work-code-teardown ()
  "The module is off: the diffs close and the saved window configuration is dropped."
  (setq drgnx-work-code--saved-windows nil)
  (mapc #'kill-buffer (drgnx-work-code--diff-buffers)))

(provide 'drgnx-work-code)
;;; drgnx-work-code.el ends here
