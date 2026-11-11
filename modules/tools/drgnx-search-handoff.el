;;; drgnx-search-handoff.el --- Ask an Agent about a search's results  -*- lexical-binding: t -*-

;;; Commentary:

;; Ask an Agent (docs/guide/replace.md, "Ask an Agent"): the Search view's ticked matches (the row's when none is
;; ticked) go to an agent with what to do.  A small card in the popup lane takes the instruction (prefilled from the
;; replacement) and who: a new worker in a worktree of its own (the default profile), or a live session (a paired chat
;; edits in this checkout).  Send asks the hub (`search/handoff'), which builds the brief and starts or messages the
;; session; the handed-off rows show the agent's mark, and the view's status line its state chip (`sent', `editing',
;; `done 47 / 2 skipped') from `search-handoff-state'.  Re-run in Worktree runs the same search in a worker's worktree
;; to show what is left.  The agent's edits come back through the existing review (a worker's hunks in the Work space,
;; a pair's in the user's buffers): this file links to them only.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function drgnx-replace--live-view "drgnx-replace")
(declare-function drgnx-replace--rows-p "drgnx-replace")
(declare-function drgnx-replace--rows-off "drgnx-replace")
(declare-function drgnx-replace--rows-group-p "drgnx-replace")
(declare-function drgnx-replace--rows-file-matches "drgnx-replace")
(declare-function drgnx-replace--text "drgnx-replace")
(declare-function drgnx-replace--update-status "drgnx-replace")
(declare-function drgnx-replace--search-now "drgnx-replace")
(declare-function drgnx-view-nav-selection "drgnx-view-patch")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agents-default-profile "drgnx-agents")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(declare-function drgnx-agent-identity "drgnx-agent-identity")
(declare-function drgnx-agents-editor-ordinal "drgnx-agents-editor")
(declare-function drgnx-surfaces-key-label "drgnx-surfaces")
(defvar drgnx-hub--events)
(defvar drgnx-replace-view)
(defvar drgnx-replace--root)
(defvar drgnx-replace--hub-counts)
(defvar drgnx-replace-buffer-name)
(defvar drgnx-view-patch)

(defface drgnx-search-handoff-chip '((t :inherit drgnx-chip))
  "The Search view's state chip of a hand-off: `sent', `editing', `done 47 / 2 skipped'." :group 'drgnx)

(defface drgnx-search-handoff-title '((t :inherit drgnx-ui-heading))
  "The Ask an Agent card's title." :group 'drgnx)

(defconst drgnx-search-handoff-buffer-name "*drgnx ask an agent*")

;;;; What is handed off

(defun drgnx-search-handoff--what ()
  "In the Search view: (IDS OFF N) of what Ask an Agent hands off: every ticked match (IDS nil, OFF the unticked),
or, when none is ticked, the selected row's (a match, or a file's matches).  N is how many."
  (let* ((off (drgnx-replace--rows-off)) (total (or (cdr drgnx-replace--hub-counts) 0)))
    (if (< (hash-table-count off) total)
        (list nil (hash-table-keys off) (- total (hash-table-count off)))
      (let* ((id (or (get-text-property (point) 'drgnx-work-id) (drgnx-view-nav-selection)
                     (user-error "Tick matches, or select a row, to ask an agent about")))
             (ids (if (drgnx-replace--rows-group-p id) (drgnx-replace--rows-file-matches id) (list id))))
        (list ids nil (length ids))))))

(defun drgnx-search-handoff--choices (root)
  "Who a hand-off can go to: a new worker of the default profile first, then each live session (hub-run), a session
in the checkout ROOT marked as a pair.  Each (LABEL . TO), TO as `search/handoff' takes it."
  (cons (cons (format "New worker (%s), its own worktree" (drgnx-agents-default-profile))
              (list :new (list :profile (drgnx-agents-default-profile))))
        (delq nil
              (mapcar (lambda (s)
                        (when-let* ((id (drgnx-agent-session-remote s))
                                    ((not (memq (drgnx-agent-session-status s) '(exited stopped)))))
                          (cons (format "%s%s" (if (and root (drgnx-agent-session-cwd s)
                                                        (string= (file-name-as-directory
                                                                  (expand-file-name (drgnx-agent-session-cwd s)))
                                                                 (file-name-as-directory (expand-file-name root))))
                                                   "Pair · " "")
                                        (drgnx-agent-session-name s))
                                (list :session (list :id id)))))
                      (and (fboundp 'drgnx-agents-sessions) (drgnx-agents-sessions))))))

;;;; The card

(defvar-local drgnx-search-handoff--ask nil
  "The card's hand-off: (:view V :ids IDS :off OFF :n N :root ROOT :choices CHOICES :who K :hidden BOOL).")

(defvar drgnx-search-handoff-keys-map (make-sparse-keymap)
  "The Ask an Agent card's keys (Send, Cancel, next who, hidden files), from the key profiles.")

(defvar drgnx-search-handoff-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-search-handoff-keys-map) m)
  "The Ask an Agent card's keymap: the profiles' keys; the rest is the instruction's text.")

(define-derived-mode drgnx-search-handoff-mode text-mode "Ask an Agent"
  "The Ask an Agent card: the text is what the agent is to do; the header line says who it goes to."
  (setq-local header-line-format '(:eval (drgnx-search-handoff--header)) mode-line-format nil))

(defun drgnx-search-handoff--key (id)
  "Registry command ID's key, short, or nil."
  (and (fboundp 'drgnx-surfaces-key-label) (drgnx-surfaces-key-label id :short t)))

(defvar-local drgnx-search-handoff--header-text ""
  "The card's header line, made when what it shows changes (`drgnx-search-handoff--head').")

(defun drgnx-search-handoff--header ()
  "The card's header line: the title, who, hidden files, and the keys.  Reads `drgnx-search-handoff--header-text'."
  drgnx-search-handoff--header-text)

(defun drgnx-search-handoff--head ()
  "Make the card's header line from `drgnx-search-handoff--ask'."
  (let* ((a drgnx-search-handoff--ask) (who (car (nth (plist-get a :who) (plist-get a :choices))))
         (keys (lambda (id label) (if-let* ((k (drgnx-search-handoff--key id))) (format "%s %s" k label) label))))
    (setq drgnx-search-handoff--header-text
          (concat " " (propertize (format "Ask an Agent · %d match%s" (plist-get a :n) (if (= 1 (plist-get a :n)) "" "es"))
                                  'face 'drgnx-search-handoff-title)
                  "  Who: " who
                  (propertize (concat "  · " (funcall keys 'search-handoff-next-who "next")
                                      " · hidden files " (if (plist-get a :hidden) "in" "out") " ("
                                      (funcall keys 'search-handoff-hidden "switch") ") · "
                                      (funcall keys 'search-handoff-send "Send") " · "
                                      (funcall keys 'search-handoff-cancel "Cancel"))
                              'face 'shadow)))
    (force-mode-line-update)))

(defun drgnx-search-to-agent ()
  "Ask an agent to work on the Search view's ticked matches (the selected row's when none is ticked)."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (unless (drgnx-replace--rows-p) (user-error "Ask an Agent needs a text search"))
    (pcase-let* ((`(,ids ,off ,n) (drgnx-search-handoff--what))
                 (replace (drgnx-replace--text 'replace)) (find (drgnx-replace--text 'find))
                 (ask (list :view drgnx-replace-view :ids ids :off off :n n :root drgnx-replace--root
                            :choices (drgnx-search-handoff--choices drgnx-replace--root) :who 0 :hidden nil))
                 (buf (get-buffer-create drgnx-search-handoff-buffer-name)))
      (with-current-buffer buf
        (drgnx-search-handoff-mode)
        (setq drgnx-search-handoff--ask ask)
        (erase-buffer)
        (unless (string-empty-p replace)
          (insert (format "Replace `%s' with `%s' in these places, keeping behaviour." find replace)))
        (drgnx-search-handoff--head))
      (pop-to-buffer buf))))

(defun drgnx-search-handoff-next-who ()
  "On the Ask an Agent card: who it goes to next (a new worker, each live session)."
  (interactive)
  (let ((a drgnx-search-handoff--ask))
    (setq drgnx-search-handoff--ask
          (plist-put a :who (mod (1+ (plist-get a :who)) (length (plist-get a :choices)))))
    (drgnx-search-handoff--head)))

(defun drgnx-search-handoff-hidden ()
  "On the Ask an Agent card: put the matches in hidden files (dot paths, secret-looking names) in the brief, or not."
  (interactive)
  (setq drgnx-search-handoff--ask (plist-put drgnx-search-handoff--ask :hidden
                                             (not (plist-get drgnx-search-handoff--ask :hidden))))
  (drgnx-search-handoff--head))

(defun drgnx-search-handoff-cancel ()
  "Close the Ask an Agent card; nothing is sent."
  (interactive)
  (quit-window t))

;;;; Send, and the state that comes back

(defvar-local drgnx-search-handoff--live nil
  "In the Search view: the view's hand-offs, newest first, each (:handoff H :session S :name NAME :worktree W :ids
IDS :state STATE), STATE the last `search-handoff-state'.")

(defun drgnx-search-handoff--mark (session)
  "SESSION's mark for the handed-off rows: (:face NAME :glyph G) from the agents' identity scheme, or nil before the
session has its ordinal."
  (when-let* (((fboundp 'drgnx-agents-editor-ordinal)) ((fboundp 'drgnx-agent-identity))
              (n (drgnx-agents-editor-ordinal session)) (id (drgnx-agent-identity n)))
    (list :face (symbol-name (plist-get id :face)) :glyph (plist-get id :glyph))))

(defun drgnx-search-handoff-send ()
  "Send the Ask an Agent card: the hub builds the brief and starts or messages the agent."
  (interactive)
  (let* ((a drgnx-search-handoff--ask) (choice (nth (plist-get a :who) (plist-get a :choices)))
         (to (cdr choice)) (text (string-trim (buffer-string)))
         (session (plist-get (plist-get to :session) :id))
         (params (append (list :view (plist-get a :view) :instruction text :to to)
                         (if (plist-get a :ids) (list :ids (vconcat (plist-get a :ids)))
                           (list :off (vconcat (plist-get a :off))))
                         (and (plist-get a :hidden) (list :hidden t))
                         (when-let* ((m (and session (drgnx-search-handoff--mark session)))) (list :mark m)))))
    (when (string-empty-p text) (user-error "Say what the agent is to do"))
    (quit-window t)
    (with-current-buffer (drgnx-replace--live-view)
      (let ((view (current-buffer)))
        (drgnx-hub--call-on
         drgnx-hub--events "search/handoff" params
         (lambda (r err)
           (if err
               (message "Ask an Agent: %s" (or (plist-get err :message) err))
             (when (buffer-live-p view)
               (with-current-buffer view
                 (push (list :handoff (plist-get r :handoff) :session (plist-get r :session) :name (car choice)
                             :worktree (plist-get r :worktree) :ids (append (plist-get r :ids) nil)
                             :state (list :phase "sent"))
                       drgnx-search-handoff--live)
                 (drgnx-replace--update-status)))
             (message "Asked %s about %d match%s%s%s" (car choice) (length (plist-get r :ids))
                      (if (= 1 (length (plist-get r :ids))) "" "es")
                      (if (> (or (plist-get r :more) 0) 0)
                          (format " (%d in the brief, the rest through search_results)" (plist-get r :sent)) "")
                      (if (plist-get r :hidden)
                          (format "; left out (hidden): %s" (string-join (append (plist-get r :hidden) nil) ", "))
                        "")))))))))

(defun drgnx-search-handoff-event (event data)
  "`search-handoff-state' (DATA) of EVENT: the Search view's chip follows it.  Non-nil when it was one."
  (when (equal event "search-handoff-state")
    (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
      (with-current-buffer buf
        (when-let* ((h (seq-find (lambda (h) (equal (plist-get h :handoff) (plist-get data :handoff)))
                                 drgnx-search-handoff--live)))
          (setf (plist-get h :state) data)
          (drgnx-replace--update-status))))
    t))

(defun drgnx-search-handoff-chip ()
  "The Search view's chip of its newest hand-off (`sent', `editing', `done 47 / 2 skipped'), or \"\"."
  (if-let* ((h (car drgnx-search-handoff--live)))
      (let* ((s (plist-get h :state)) (phase (format "%s" (plist-get s :phase)))
             (done (length (plist-get s :done))) (left (length (plist-get s :left)))
             (unknown (length (plist-get s :unknown))))
        (concat " · " (propertize (format " %s: %s " (plist-get h :name)
                                          (pcase phase
                                            ("done" (format "done %d / %d skipped%s" done left
                                                            (if (> unknown 0) (format " / %d unknown" unknown) "")))
                                            ("editing" (format "editing, %d done" done))
                                            (_ "sent")))
                                  'face 'drgnx-search-handoff-chip)))
    ""))

(defun drgnx-search-handoff-rerun ()
  "Run the Search view's search again in the worktree of its newest hand-off's worker, to show what is left."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (let ((tree (cl-some (lambda (h) (plist-get h :worktree)) drgnx-search-handoff--live)))
      (unless tree (user-error "No hand-off to a worker in its own worktree"))
      (setq drgnx-replace--root (file-name-as-directory tree))
      (drgnx-replace--search-now))))

(provide 'drgnx-search-handoff)
;;; drgnx-search-handoff.el ends here
