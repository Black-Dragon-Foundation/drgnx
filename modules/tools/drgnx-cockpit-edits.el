;;; drgnx-cockpit-edits.el --- Module tools/cockpit: each agent's edits as a live diff — accept, revert by request, comment on a line -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Click a task or an agent in the Work graph and its agent's edits open in the editor area (pane kind `agent-edits'):
;; buffer `*edits: AGENT*', one header line `FILE +A −B' per changed file with its review mark, the file's diff below
;; (`drgnx-cockpit-edits-mode': text in diff-mode's colours, not a diff-mode buffer; its `default-directory' is the
;; temp folder, so VC, patch and ediff in it find nothing of the agent's).  The files and diffs come from the cockpit's
;; model
;; (`drgnx-cockpit-changed-files', `drgnx-cockpit-file-diff': git, asynchronously, local regular files only).
;;
;; It follows the agent live while it shows (the workbench state store says so): file watches on its folder and the
;; changed files' folders, and the `edit' events it reports (an outside agent's MCP server writes them; a look at the
;; store every `drgnx-cockpit-edits-check-interval' seconds) name the files that changed.  Only those are diffed
;; again, at most once per `drgnx-cockpit-edits-delay', and only their sections of the buffer are replaced: each window
;; keeps its point and start on the same file, hunk and offset.  The changes are also listed again every few seconds,
;; so a first write in a folder nobody watches yet shows.  Hidden, the pane keeps no timer and no watch; when it shows
;; again it lists the changes again and watches their folders.
;;
;; a accepts a file (a review mark with the diff's hash, for the merge gate; it never merges or commits); when the file
;; changes again its header says so.  r asks the agent to undo its changes to a file (a queued message, never an
;; interruption); only when a job's agent is known to be stopped and the file is in its task's worktree, which drgnx
;; made and nobody else works in, does r put it back itself, after asking exactly what it will do.  c comments on a
;; line: a queued message naming the file and line.  The pane cannot be turned into another mode.  Nothing here prompts
;; or blocks on its own, and nothing touches a remote folder.  See docs/guide/cockpit.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'diff-mode)                     ; its faces only: the pane is no diff-mode buffer
(require 'filenotify)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-cockpit-model)
(require 'drgnx-panes)
(require 'drgnx-state)
(require 'drgnx-view)                    ; `drgnx-view-with-kept-windows'
(eval-when-compile (require 'drgnx-agents))     ; its session struct's places (`setf' of a mode)

(declare-function drgnx-cockpit-sessions "drgnx-cockpit")
(declare-function drgnx-cockpit--open-task "drgnx-cockpit")
(declare-function drgnx-cockpit-graph--ascii-p "drgnx-cockpit-graph")
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agents-send "drgnx-agents")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-id "drgnx-agents")
(declare-function drgnx-agent-session-mode "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-hub-socket "drgnx-hub")
(declare-function drgnx-hub-call "drgnx-hub")
(defvar drgnx-cockpit-graph-buffer-name)
(defvar drgnx-cockpit--model)

(defcustom drgnx-cockpit-edits-delay 0.3
  "Seconds between the first change an agent's edits pane hears of (a file written, an edit reported) and the new
diff of the files it named: however many changes come meanwhile, the pane is patched once."
  :type 'number :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-edits-check-interval 2
  "Seconds between two looks, while an edits pane shows, at the store: the edits its agent reported from another
process (an outside agent's MCP server) and review marks set elsewhere.  One cheap query when nothing changed."
  :type 'number :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-edits-watch-max 32
  "The most folders an edits pane watches for writes: the agent's folder and its changed files' folders.  A file in
another folder shows when the agent reports it, or at the next listing."
  :type 'natnum :group 'drgnx-cockpit)

(defface drgnx-cockpit-edits-file '((t :inherit bold))
  "A changed file's name on its header line in an agent's edits." :group 'drgnx-cockpit)
(defface drgnx-cockpit-edits-added '((t :inherit success))
  "The count of added lines (+A) on a file's header line." :group 'drgnx-cockpit)
(defface drgnx-cockpit-edits-removed '((t :inherit error))
  "The count of removed lines (−B) on a file's header line." :group 'drgnx-cockpit)
(defface drgnx-cockpit-edits-accepted '((t :inherit success))
  "The mark of a file you accepted (✓ accepted)." :group 'drgnx-cockpit)
(defface drgnx-cockpit-edits-changed '((t :inherit warning))
  "The mark of a file that changed since you accepted it." :group 'drgnx-cockpit)
(defface drgnx-cockpit-edits-note '((t :inherit shadow))
  "Notes in an agent's edits: new, deleted, a diff on its way or too large to show." :group 'drgnx-cockpit)

(defconst drgnx-cockpit-edits--git-jobs 3 "The most git processes one edits pane runs at a time.")

(defvar drgnx-cockpit-edits--list-every 2.0
  "The fewest seconds between two listings of an agent's changed files (a file not listed yet was written or
reported); a file already listed is diffed again at once.")

(defvar drgnx-cockpit-edits--draws 0 "How many times an edits pane was patched (tests and the perf lab read it).")
(defvar drgnx-cockpit-edits--last nil "The edits buffer shown last: what pane `agent-edits' shows when none is named.")
(defvar drgnx-cockpit-edits--buffers nil
  "The live edits panes: each one adds itself in its mode and goes in its `kill-buffer-hook'.
`drgnx-cockpit-edits--follow' walks these, never every buffer.")
(defvar drgnx-cockpit-edits--last-error nil "The last error said: the same one is said once.")

(defvar-local drgnx-cockpit-edits--agent nil
  "The agent this pane shows: its id, or its plist from the cockpit's model (a silent worktree's has its folder).")
(defvar-local drgnx-cockpit-edits--id nil "The agent's id.")
(defvar-local drgnx-cockpit-edits--name nil "The agent's name, for messages and the header line.")
(defvar-local drgnx-cockpit-edits--job nil "The agent's job, when it has one (its messages are of that job).")
(defvar-local drgnx-cockpit-edits--source nil "Where its edits are (`drgnx-cockpit-edit-source'), as read at the last listing.")
(defvar-local drgnx-cockpit-edits--files nil
  "The files shown, in order.  Each string is the value of its section's `drgnx-cockpit-edits-file' property.")
(defvar-local drgnx-cockpit-edits--info nil
  "Hash file → (:added :removed :status :hash :note :listed), for the files shown (pruned with them).")
(defvar-local drgnx-cockpit-edits--more 0 "Changed files past `drgnx-cockpit-changed-files-max', counted only.")
(defvar-local drgnx-cockpit-edits--note nil "The note the buffer shows instead of files (no changes, an error), or nil.")
(defvar-local drgnx-cockpit-edits--marks nil "The agent's review marks (`drgnx-coord-review-marks').")
(defvar-local drgnx-cockpit-edits--dirty nil "Hash file → t: listed files to diff again at the next tick.")
(defvar-local drgnx-cockpit-edits--list-dirty nil "Non-nil: list the changed files again at the next tick.")
(defvar-local drgnx-cockpit-edits--listed-at 0 "When the files were last listed (`float-time').")
(defvar-local drgnx-cockpit-edits--loaded nil "Non-nil once the first listing and its diffs came back.")
(defvar-local drgnx-cockpit-edits--busy nil "Non-nil while a round (a listing, its diffs) runs: the next one waits.")
(defvar-local drgnx-cockpit-edits--queue nil "This round's files waiting for git.")
(defvar-local drgnx-cockpit-edits--running 0 "This round's git processes.")
(defvar-local drgnx-cockpit-edits--ready nil "Diffs back from git, not shown yet: ((FILE . RESULT)…), newest first.")
(defvar-local drgnx-cockpit-edits--watches nil "Hash folder → its file watch, while the pane shows.")
(defvar-local drgnx-cockpit-edits--store-key nil "The store's data version and change count at the last look.")
(defvar-local drgnx-cockpit-edits--event-id 0 "The last event the pane read: edits reported after it are new.")
(defvar-local drgnx-cockpit-edits--neutral nil "The pane's own empty folder (`drgnx-cockpit-edits--neutral-dir').")
(defvar-local drgnx-cockpit-edits--quiet-gap nil
  "Seconds between the check's own listings: nil (`drgnx-cockpit-edits-check-interval') until one finds nothing new,
then twice the last, up to `drgnx-cockpit-edits--quiet-max'.  Any change heard of resets it.")
(defvar-local drgnx-cockpit-edits--quiet-next 0 "When the check lists again on its own (`float-time').")
(defconst drgnx-cockpit-edits--quiet-max 10 "The longest gap, in seconds, between the check's own listings.")

;;;; Glyphs and text

(defun drgnx-cockpit-edits--ascii-p ()
  "Whether the selected frame is a terminal's that does not write UTF-8."
  (and (fboundp 'drgnx-cockpit-graph--ascii-p) (drgnx-cockpit-graph--ascii-p)))

(defun drgnx-cockpit-edits--glyph (name unicode ascii)
  "Glyph NAME: `drgnx-face-glyph' when the face is loaded, else ASCII on a terminal that does not write UTF-8, else
UNICODE."
  (cond ((fboundp 'drgnx-face-glyph) (drgnx-face-glyph name))
        ((drgnx-cockpit-edits--ascii-p) ascii)
        (t unicode)))

(defun drgnx-cockpit-edits--face (text face)
  "TEXT in FACE: its own property (`drgnx-cockpit-edits--fontify-headers' puts it back before the diff keywords)
and `font-lock-face' (when font-lock is off)."
  (propertize text 'drgnx-cockpit-edits-face face 'font-lock-face face))

(defun drgnx-cockpit-edits--counts (text)
  "(ADDED . REMOVED): the lines diff TEXT adds and removes in its hunks."
  (let ((a 0) (r 0) (in nil) (start 0) (len (length text)))
    (while (< start len)
      (let ((end (or (string-search "\n" text start) len)))
        (when (< start end)
          (pcase (aref text start)
            (?@ (setq in t))
            (?+ (when in (cl-incf a)))
            (?- (when in (cl-incf r)))))
        (setq start (1+ end))))
    (cons a r)))

(defun drgnx-cockpit-edits--mark (file)
  "FILE's review mark as shown: `accepted' (its diff is the one accepted), `changed' (it changed since), or nil."
  (let ((m (cdr (assoc file drgnx-cockpit-edits--marks))) (hash (plist-get (gethash file drgnx-cockpit-edits--info) :hash)))
    (pcase (plist-get m :state)
      ("accepted" (cond ((null hash) nil) ((equal hash (plist-get m :hash)) 'accepted) (t 'changed)))
      ("pending" 'changed))))

(defun drgnx-cockpit-edits--header-text (file)
  "FILE's header line: `FILE +A −B', new or deleted, and its mark."
  (let* ((info (gethash file drgnx-cockpit-edits--info)) (added (plist-get info :added)) (removed (plist-get info :removed)))
    (concat (drgnx-cockpit-edits--face (drgnx-wb-display-name file) 'drgnx-cockpit-edits-file)
            " " (drgnx-cockpit-edits--face (format "+%s" (or added "?")) 'drgnx-cockpit-edits-added)
            " " (drgnx-cockpit-edits--face (format "%s%s" (if (drgnx-cockpit-edits--ascii-p) "-" "−") (or removed "?"))
                                           'drgnx-cockpit-edits-removed)
            (pcase (plist-get info :status)
              ('new (drgnx-cockpit-edits--face "  new" 'drgnx-cockpit-edits-note))
              ('deleted (drgnx-cockpit-edits--face "  deleted" 'drgnx-cockpit-edits-note))
              (_ ""))
            (pcase (drgnx-cockpit-edits--mark file)
              ('accepted (concat "  " (drgnx-cockpit-edits--face (concat (drgnx-cockpit-edits--glyph 'ok "✓" "+") " accepted")
                                                                 'drgnx-cockpit-edits-accepted)))
              ('changed (concat "  " (drgnx-cockpit-edits--face "changed since accepted" 'drgnx-cockpit-edits-changed)))
              (_ ""))
            "\n")))

(defun drgnx-cockpit-edits--note-text (text)
  (drgnx-cockpit-edits--face (concat text "\n") 'drgnx-cockpit-edits-note))

(defun drgnx-cockpit-edits--base-name ()
  (let ((src drgnx-cockpit-edits--source))
    (format "%s%s" (if (plist-get src :merge-base) "where it forked from " "")
            (let ((b (or (plist-get src :base) "HEAD"))) (if (string-match-p "\\`[0-9a-f]\\{40\\}\\'" b) (substring b 0 8) b)))))

(defun drgnx-cockpit-edits--header-line ()
  "Set the header line: the agent, how many files changed, how many you accepted, against what, and the keys (cached
text)."
  (let* ((n (length drgnx-cockpit-edits--files))
         (accepted (seq-count (lambda (f) (eq (drgnx-cockpit-edits--mark f) 'accepted)) drgnx-cockpit-edits--files))
         (ascii (drgnx-cockpit-edits--ascii-p)) (dot (if ascii " | " " · "))
         (text (concat " " drgnx-cockpit-edits--name (if ascii " - " " — ")
                       (cond ((not drgnx-cockpit-edits--loaded) (if ascii "reading its changes..." "reading its changes…"))
                             (drgnx-cockpit-edits--note drgnx-cockpit-edits--note)
                             (t (concat (format "%d file%s changed" n (if (= n 1) "" "s"))
                                        (if (> drgnx-cockpit-edits--more 0) (format " (and %d more)" drgnx-cockpit-edits--more) "")
                                        (format "%s%d accepted%sagainst %s" dot accepted dot (drgnx-cockpit-edits--base-name))
                                        (if (drgnx-cockpit-edits--stopped-p drgnx-cockpit-edits--source) (concat dot "stopped") ""))))
                       (if ascii "   a accept | r revert | c comment | n/p files" "   a accept · r revert · c comment · n/p files"))))
    (setq header-line-format (list (string-replace "%" "%%" text)))))

;;;; Sections: one per file, its header line and its diff

(defun drgnx-cockpit-edits--section (file)
  "(START . END) of FILE's section, or nil.  One step per section."
  (let ((pos (point-min)) (found nil))
    (while (and pos (not found) (< pos (point-max)))
      (if (equal (get-text-property pos 'drgnx-cockpit-edits-file) file)
          (setq found (cons pos (next-single-property-change pos 'drgnx-cockpit-edits-file nil (point-max))))
        (setq pos (next-single-property-change pos 'drgnx-cockpit-edits-file))))
    found))

(defun drgnx-cockpit-edits--start-at (pos)
  "The start of the section POS is in (POS has its property)."
  (if (and (> pos (point-min))
           (eq (get-text-property (1- pos) 'drgnx-cockpit-edits-file) (get-text-property pos 'drgnx-cockpit-edits-file)))
      (or (previous-single-property-change pos 'drgnx-cockpit-edits-file) (point-min))
    pos))

(defun drgnx-cockpit-edits--mark-hunks (start end)
  "Number the rows of the section from START to END (text property `drgnx-cockpit-edits-hunk'): 0 for its header
line and diff head, then 1, 2… from each `@@' line.  A patch keeps places by them (`drgnx-cockpit-edits--row-at')."
  (save-excursion
    (goto-char start)
    (let ((n 0) (from start))
      (while (re-search-forward "^@@ " end t)
        (put-text-property from (match-beginning 0) 'drgnx-cockpit-edits-hunk n)
        (setq from (match-beginning 0) n (1+ n)))
      (put-text-property from end 'drgnx-cockpit-edits-hunk n))))

(defun drgnx-cockpit-edits--insert-section (file body)
  "Insert FILE's section at point: its header line, BODY (its diff or a note), a blank line."
  (let ((start (point)))
    (insert (drgnx-cockpit-edits--header-text file) body (if (string-suffix-p "\n" body) "" "\n") "\n")
    (put-text-property start (point) 'drgnx-cockpit-edits-file file)
    (drgnx-cockpit-edits--mark-hunks start (point))))

(defun drgnx-cockpit-edits--put-section (file body)
  "FILE's section, with BODY, in place of the old one (else at the end)."
  (let ((s (drgnx-cockpit-edits--section file)))
    (goto-char (if s (car s) (point-max)))
    (when s (delete-region (car s) (cdr s)))
    (drgnx-cockpit-edits--insert-section file body)))

(defun drgnx-cockpit-edits--placeholder () (drgnx-cockpit-edits--note-text (if (drgnx-cockpit-edits--ascii-p) "  ..." "  …")))

(defun drgnx-cockpit-edits--row-at (pos)
  "The row POS is in, to find again after a patch: (FILE . HUNK) (`drgnx-cockpit-edits--mark-hunks'), nil off any
file.  Cheap: two text properties."
  (let ((f (get-text-property pos 'drgnx-cockpit-edits-file)))
    (and f (cons f (get-text-property pos 'drgnx-cockpit-edits-hunk)))))

(defun drgnx-cockpit-edits--row-pos (row)
  "Where ROW (`drgnx-cockpit-edits--row-at') starts now, or nil when its file's section or its hunk is gone."
  (when-let* ((s (drgnx-cockpit-edits--section (car row))))
    (text-property-any (car s) (cdr s) 'drgnx-cockpit-edits-hunk (cdr row))))

(defun drgnx-cockpit-edits--patch (fn)
  "Call FN to change the buffer, then put point and each window's start and point back on the same file, hunk and
offset (`drgnx-view-with-kept-windows'; the same line of the buffer when its hunk is gone).  It moves no other
window and selects none; a redrawn generated buffer, so no undo."
  (drgnx-view-with-kept-windows (:key-at #'drgnx-cockpit-edits--row-at :pos-of #'drgnx-cockpit-edits--row-pos)
    (let ((inhibit-read-only t)) (save-excursion (funcall fn))))
  (set-buffer-modified-p nil)
  (cl-incf drgnx-cockpit-edits--draws)
  (drgnx-cockpit-edits--header-line))

(defun drgnx-cockpit-edits--delete-runs (prop)
  "Delete every run of text whose PROP is non-nil (the files' sections, or the note), the last first."
  (let ((pos (point-max)))
    (while (> pos (point-min))
      (let ((start (or (previous-single-property-change pos prop) (point-min))))
        (when (get-text-property start prop) (delete-region start pos))
        (setq pos start)))))

(defun drgnx-cockpit-edits--show-note (text)
  "Show TEXT instead of any file (no changes, an error): every file's section goes, the note comes (text property
`drgnx-cockpit-edits-note'); nothing when it already shows."
  (unless (and (equal text drgnx-cockpit-edits--note) (null drgnx-cockpit-edits--files))
    (setq drgnx-cockpit-edits--files nil drgnx-cockpit-edits--note text)
    (clrhash drgnx-cockpit-edits--info)
    (clrhash drgnx-cockpit-edits--dirty)
    (drgnx-cockpit-edits--patch
     (lambda ()
       (drgnx-cockpit-edits--delete-runs 'drgnx-cockpit-edits-file)
       (drgnx-cockpit-edits--delete-runs 'drgnx-cockpit-edits-note)
       (goto-char (point-min))
       (insert (propertize (drgnx-cockpit-edits--note-text text) 'drgnx-cockpit-edits-note t))))))

(defun drgnx-cockpit-edits--patch-headers (files)
  "Draw again the header lines of FILES (their marks changed)."
  (when-let* ((files (seq-filter (lambda (f) (member f drgnx-cockpit-edits--files)) files)))
    (drgnx-cockpit-edits--patch
     (lambda ()
       (dolist (f files)
         (when-let* ((s (drgnx-cockpit-edits--section f)))
           (let ((obj (get-text-property (car s) 'drgnx-cockpit-edits-file)))
             (goto-char (car s))
             (delete-region (point) (line-beginning-position 2))
             (let ((start (point)))
               (insert (drgnx-cockpit-edits--header-text obj))
               (add-text-properties start (point) (list 'drgnx-cockpit-edits-file obj 'drgnx-cockpit-edits-hunk 0))))))))))

;;;; Following the agent: watches, reported edits, ticks, rounds of git

(defun drgnx-cockpit-edits--say (err)
  (let ((m (error-message-string err)))
    (unless (equal m drgnx-cockpit-edits--last-error)
      (setq drgnx-cockpit-edits--last-error m)
      (message "drgnx edits: %s" m))))

(defun drgnx-cockpit-edits--in (buffer fn &rest args)
  "FN with ARGS in BUFFER while it lives — from a timer or a watch: an error is said once, never a prompt or a signal."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (condition-case err (apply fn args)
        (error (drgnx-cockpit-edits--say err))))))

(defun drgnx-cockpit-edits--in-round (buffer fn &rest args)
  "As `drgnx-cockpit-edits--in', for a step of a round (its tick, a listing or a diff back): an error also ends the
round, so the next one can start."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (condition-case err (apply fn args)
        (error (setq drgnx-cockpit-edits--busy nil drgnx-cockpit-edits--queue nil)
               (drgnx-cockpit-edits--say err))))))

(defun drgnx-cockpit-edits--schedule (&optional delay)
  "Patch this pane within DELAY seconds (`drgnx-cockpit-edits-delay'): one tick however many calls come meanwhile.  A
listing waiting for its turn has a timer of its own (`drgnx-cockpit-edits--schedule-turn'), so it never holds this
one back."
  (let ((buffer (current-buffer)))
    (drgnx-timer-soon (cons 'cockpit-edits-tick buffer) (or delay drgnx-cockpit-edits-delay) #'drgnx-cockpit-edits--tick
                      :args (list buffer) :owner buffer)))

(defun drgnx-cockpit-edits--schedule-turn (wait)
  "Tick this pane in WAIT seconds: the listing's turn comes then (a second call moves it)."
  (let ((buffer (current-buffer)))
    (drgnx-timer-start (cons 'cockpit-edits-turn buffer) wait #'drgnx-cockpit-edits--tick
                       :args (list buffer) :owner buffer)))

(defun drgnx-cockpit-edits--touched (file)
  "FILE (relative to the agent's folder) changed: diff it again soon, or list the files again when it is not listed."
  (if (gethash file drgnx-cockpit-edits--info) (puthash file t drgnx-cockpit-edits--dirty)
    (setq drgnx-cockpit-edits--list-dirty t))
  (setq drgnx-cockpit-edits--quiet-gap nil      ; the agent is at work: the check lists at its own pace again
        drgnx-cockpit-edits--quiet-next (min drgnx-cockpit-edits--quiet-next (+ (float-time) drgnx-cockpit-edits-check-interval)))
  (drgnx-cockpit-edits--schedule))

(defun drgnx-cockpit-edits--relative (name)
  "NAME (absolute, from a watch) relative to the agent's folder, or nil: outside it, the folder itself, or in .git."
  (let ((dir (plist-get drgnx-cockpit-edits--source :dir)))
    (when (and (stringp dir) (stringp name) (string-prefix-p dir name))
      (let ((rel (substring name (length dir))))
        (unless (or (string-empty-p rel) (string-match-p "\\(?:\\`\\|/\\)\\.git\\(?:/\\|\\'\\)" rel)) rel)))))

(defun drgnx-cockpit-edits--notified (buffer event)
  "A file watch of BUFFER's pane saw EVENT: the file it names changed (cheap: it only notes the file)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (pcase-let ((`(,_ ,action ,file ,file1) event))
        (when (memq action '(created changed deleted renamed))
          (dolist (f (list file (and (eq action 'renamed) file1)))
            (when-let* ((rel (drgnx-cockpit-edits--relative f))) (drgnx-cockpit-edits--touched rel))))))))

(defun drgnx-cockpit-edits--update-watches ()
  "Watch the agent's folder and the folders of its changed files (at most `drgnx-cockpit-edits-watch-max'), and no
other: a local folder only, never a remote one.  The folders are the agent's names: placed, checked and watched with
no file name handler (an `a.zip/' folder reached tramp-archive; docs/develop/core.md, \"Names an agent gave\")."
  (let* ((file-name-handler-alist nil)
         (dir (plist-get drgnx-cockpit-edits--source :dir))
         (want (and (stringp dir) (not (drgnx-cockpit--remote-p dir)) (file-directory-p dir)
                    (seq-take (delete-dups (cons dir (mapcar (lambda (f) (file-name-directory (expand-file-name f dir)))
                                                             drgnx-cockpit-edits--files)))
                              drgnx-cockpit-edits-watch-max)))
         (buffer (current-buffer)))
    (maphash (lambda (d w) (unless (and (member d want) (file-notify-valid-p w))
                             (ignore-errors (file-notify-rm-watch w)) (remhash d drgnx-cockpit-edits--watches)))
             drgnx-cockpit-edits--watches)
    (dolist (d want)
      (unless (or (gethash d drgnx-cockpit-edits--watches) (not (file-directory-p d)))
        (when-let* ((w (ignore-errors (file-notify-add-watch d '(change) (apply-partially #'drgnx-cockpit-edits--notified buffer)))))
          (puthash d w drgnx-cockpit-edits--watches))))))

(defun drgnx-cockpit-edits--store-key ()
  (car (sqlite-select (drgnx-work-db) "select (select data_version from pragma_data_version()), total_changes()")))

(defun drgnx-cockpit-edits--read-marks ()
  "Read the agent's review marks; non-nil when they changed."
  (let ((old drgnx-cockpit-edits--marks))
    (setq drgnx-cockpit-edits--marks (drgnx-coord-review-marks drgnx-cockpit-edits--id))
    (not (equal old drgnx-cockpit-edits--marks))))

(defun drgnx-cockpit-edits--event-paths (e)
  "The paths edit event E names, relative to the agent's folder; a remote name or one outside the folder is left out
\(no remote name is expanded).  They are the agent's names: placed with no file name handler."
  (let* ((file-name-handler-alist nil)
         (dir (plist-get drgnx-cockpit-edits--source :dir)) (data (plist-get e :data)) (root (or (plist-get data :root) dir)))
    (when (and (stringp dir) (stringp root) (not (drgnx-cockpit--remote-p dir)) (not (drgnx-cockpit--remote-p root)))
      (delq nil (mapcar (lambda (p)
                          (when (and (stringp p) (not (drgnx-cockpit--remote-p p)))
                            (let ((abs (expand-file-name p (file-name-as-directory root))))
                              (and (string-prefix-p dir abs) (file-relative-name abs dir)))))
                        (plist-get data :paths))))))

(defun drgnx-cockpit-edits--look ()
  "Look at the store (one query when nothing changed): the edits the agent reported since the last look name files
to diff again; review marks set elsewhere redraw their headers."
  (let ((key (drgnx-cockpit-edits--store-key)))
    (unless (equal key drgnx-cockpit-edits--store-key)
      (setq drgnx-cockpit-edits--store-key key)
      (dolist (e (drgnx-coord-events :since drgnx-cockpit-edits--event-id :agent drgnx-cockpit-edits--id :kinds '("edit")))
        (setq drgnx-cockpit-edits--event-id (max drgnx-cockpit-edits--event-id (plist-get e :id)))
        (mapc #'drgnx-cockpit-edits--touched (drgnx-cockpit-edits--event-paths e)))
      (let ((old drgnx-cockpit-edits--marks))
        (when (drgnx-cockpit-edits--read-marks)
          (drgnx-cockpit-edits--patch-headers (delete-dups (mapcar #'car (append old drgnx-cockpit-edits--marks)))))))))

(defun drgnx-cockpit-edits--check (buffer)
  "Every `drgnx-cockpit-edits-check-interval' s while BUFFER shows (its timer `(cockpit-edits-check . BUFFER)',
started and cancelled by `drgnx-cockpit-edits--follow'): look at the store."
  (when (buffer-live-p buffer)
    (drgnx-cockpit-edits--in buffer #'drgnx-cockpit-edits--look-and-list)))

(defun drgnx-cockpit-edits--look-and-list ()
  "The check's work: look at the store, and list the changes again when it is time
(`drgnx-cockpit-edits--quiet-next'), so a first write in a folder nobody watches yet shows without g.  Listings that
find nothing new space themselves out, up to `drgnx-cockpit-edits--quiet-max' seconds apart."
  (drgnx-cockpit-edits--look)
  (when (>= (float-time) drgnx-cockpit-edits--quiet-next)
    (setq drgnx-cockpit-edits--list-dirty t)
    (drgnx-cockpit-edits--schedule)))

(defun drgnx-cockpit-edits--tick (buffer)
  "The scheduled patch (a timer): list again when due, and diff the files that changed.  A hidden pane does nothing:
what changed stays noted, and showing it lists the changes again (`drgnx-cockpit-edits--follow'); a round still
running goes first."
  (drgnx-cockpit-edits--in-round
   buffer
   (lambda ()
     (cond
      ((not (drgnx-cockpit-shown-p buffer)))
      (drgnx-cockpit-edits--busy (drgnx-cockpit-edits--schedule))
      (t
       (let* ((wait (- (+ drgnx-cockpit-edits--listed-at drgnx-cockpit-edits--list-every) (float-time)))
              (list (and drgnx-cockpit-edits--list-dirty (<= wait 0)))
              (files (hash-table-keys drgnx-cockpit-edits--dirty)))
         (when (and drgnx-cockpit-edits--list-dirty (not list)) (drgnx-cockpit-edits--schedule-turn wait))   ; its turn comes
         (when (or list files)
           (clrhash drgnx-cockpit-edits--dirty)
           (when list (setq drgnx-cockpit-edits--list-dirty nil drgnx-cockpit-edits--listed-at (float-time)))
           (drgnx-cockpit-edits--round list files))))))))

(defun drgnx-cockpit-edits--sessions ()
  (and (fboundp 'drgnx-cockpit-sessions) (drgnx-cockpit-sessions)))

(defun drgnx-cockpit-edits--read-source ()
  "Where the agent's edits are now (`drgnx-cockpit-edit-source'): its reported paths and whether it is stopped too."
  (drgnx-cockpit-edit-source drgnx-cockpit-edits--agent (drgnx-cockpit-edits--sessions)))

(defun drgnx-cockpit-edits--round (list files)
  "Start a round: list the changed files again when LIST, and diff FILES (and what the listing shows changed)."
  (let ((buffer (current-buffer)))
    (setq drgnx-cockpit-edits--busy t)
    (if (not list)
        (drgnx-cockpit-edits--diff (seq-filter (lambda (f) (gethash f drgnx-cockpit-edits--info)) files))
      (setq drgnx-cockpit-edits--source (drgnx-cockpit-edits--read-source))
      (if (null drgnx-cockpit-edits--source)
          (drgnx-cockpit-edits--listed '(:error "no folder is known for its edits") files)
        (drgnx-cockpit-changed-files drgnx-cockpit-edits--source
                                     (lambda (r) (drgnx-cockpit-edits--in-round buffer #'drgnx-cockpit-edits--listed r files)))))))

(defun drgnx-cockpit-edits--listed (r files)
  "The listing R came back (`drgnx-cockpit-changed-files'), in a round that diffs FILES too: show the files it lists,
then diff the new ones, FILES and those whose counts moved."
  (if-let* ((err (plist-get r :error)))
      (progn (drgnx-cockpit-edits--show-note (format "cannot list its changes: %s" err))
             (drgnx-cockpit-edits--finish))
    (let* ((entries (seq-filter (lambda (e) (plist-get e :file)) r))   ; not (:more N) or (:refused N)
           (names (mapcar (lambda (e) (plist-get e :file)) entries))
           (todo nil))
      (setq drgnx-cockpit-edits--more (or (seq-some (lambda (e) (plist-get e :more)) r) 0))
      (dolist (e entries)
        (let* ((f (plist-get e :file)) (info (gethash f drgnx-cockpit-edits--info))
               (listed (list (plist-get e :added) (plist-get e :removed) (plist-get e :status))))
          (when (or (null info) (member f files) (not (equal listed (plist-get info :listed))))
            (push f todo))
          (puthash f (append (list :listed listed :status (plist-get e :status))
                             (if info (list :added (plist-get info :added) :removed (plist-get info :removed)
                                            :hash (plist-get info :hash) :note (plist-get info :note))
                               (list :added (plist-get e :added) :removed (plist-get e :removed))))
                   drgnx-cockpit-edits--info)))
      ;; nothing new (no file to diff, none gone): the check's next listing waits twice as long
      (let ((base drgnx-cockpit-edits-check-interval))
        (setq drgnx-cockpit-edits--quiet-gap
              (if (or todo (/= (length names) (length drgnx-cockpit-edits--files))) nil
                (min (max base drgnx-cockpit-edits--quiet-max) (* 2 (or drgnx-cockpit-edits--quiet-gap base))))
              drgnx-cockpit-edits--quiet-next (+ (float-time) (or drgnx-cockpit-edits--quiet-gap base))))
      (drgnx-cockpit-edits--show-list names)
      (drgnx-cockpit-edits--diff (nreverse todo)))))

(defun drgnx-cockpit-edits--show-list (names)
  "Show the files NAMES: a file gone loses its section, a new one gets one at the end (its diff on its way)."
  (let* ((old drgnx-cockpit-edits--files)
         (gone (seq-remove (lambda (f) (member f names)) old))
         (new (seq-remove (lambda (f) (member f old)) names)))
    (dolist (f gone) (remhash f drgnx-cockpit-edits--info) (remhash f drgnx-cockpit-edits--dirty))
    (cond
     ((null names) (drgnx-cockpit-edits--show-note (format "no changes since %s" (drgnx-cockpit-edits--base-name))))
     ((null old)                                      ; from a note (or nothing) to files: the note goes
      (setq drgnx-cockpit-edits--files (copy-sequence names) drgnx-cockpit-edits--note nil)
      (drgnx-cockpit-edits--patch
       (lambda ()
         (drgnx-cockpit-edits--delete-runs 'drgnx-cockpit-edits-note)
         (goto-char (point-max))
         (dolist (f drgnx-cockpit-edits--files) (drgnx-cockpit-edits--insert-section f (drgnx-cockpit-edits--placeholder))))))
     ((or gone new)
      (setq drgnx-cockpit-edits--files (append (seq-remove (lambda (f) (member f gone)) old) new))
      (drgnx-cockpit-edits--patch
       (lambda ()
         (dolist (f gone) (when-let* ((s (drgnx-cockpit-edits--section f))) (delete-region (car s) (cdr s))))
         (goto-char (point-max))
         (dolist (f new) (drgnx-cockpit-edits--insert-section f (drgnx-cockpit-edits--placeholder))))))
     (t (drgnx-cockpit-edits--header-line)))))

(defun drgnx-cockpit-edits--diff (files)
  "Diff FILES, at most `drgnx-cockpit-edits--git-jobs' at a time; the round ends when all came back."
  (setq drgnx-cockpit-edits--queue (append drgnx-cockpit-edits--queue files))
  (if (and (null drgnx-cockpit-edits--queue) (<= drgnx-cockpit-edits--running 0))
      (drgnx-cockpit-edits--finish)
    (drgnx-cockpit-edits--pump)))

(defun drgnx-cockpit-edits--pump ()
  (let ((buffer (current-buffer)) (src drgnx-cockpit-edits--source))
    (while (and drgnx-cockpit-edits--queue (< drgnx-cockpit-edits--running drgnx-cockpit-edits--git-jobs))
      (let ((f (pop drgnx-cockpit-edits--queue)))
        (cl-incf drgnx-cockpit-edits--running)
        (drgnx-cockpit-file-diff src f (lambda (r) (drgnx-cockpit-edits--in-round buffer #'drgnx-cockpit-edits--diffed f r)))))))

(defun drgnx-cockpit-edits--diffed (file r)
  "FILE's diff R came back: keep it; show what came back when the round ends (or every `drgnx-cockpit-edits-delay'
while a long one runs)."
  (setq drgnx-cockpit-edits--running (max 0 (1- drgnx-cockpit-edits--running)))
  (push (cons file r) drgnx-cockpit-edits--ready)
  (drgnx-cockpit-edits--pump)
  (cond ((and (null drgnx-cockpit-edits--queue) (zerop drgnx-cockpit-edits--running)) (drgnx-cockpit-edits--finish))
        (t (drgnx-timer-soon (cons 'cockpit-edits-flush (current-buffer)) drgnx-cockpit-edits-delay
                             #'drgnx-cockpit-edits--in-round :args (list (current-buffer) #'drgnx-cockpit-edits--flush)
                             :owner (current-buffer)))))

(defun drgnx-cockpit-edits--flush ()
  (drgnx-cockpit-edits--apply-diffs))

(defun drgnx-cockpit-edits--finish ()
  "The round ended: show its diffs, watch the folders now listed (only while the pane shows), and start the next
round when changes came meanwhile."
  (drgnx-timer-cancel (cons 'cockpit-edits-flush (current-buffer)))
  (drgnx-cockpit-edits--apply-diffs)
  (setq drgnx-cockpit-edits--busy nil)
  (unless drgnx-cockpit-edits--loaded
    (setq drgnx-cockpit-edits--loaded t)
    (drgnx-cockpit-edits--header-line))
  (if (drgnx-cockpit-shown-p (current-buffer)) (drgnx-cockpit-edits--update-watches) (drgnx-cockpit-edits--drop-watches))
  (when (or drgnx-cockpit-edits--list-dirty (> (hash-table-count drgnx-cockpit-edits--dirty) 0)) (drgnx-cockpit-edits--schedule)))

(defun drgnx-cockpit-edits--apply-diffs ()
  "Show the diffs that came back: only the sections whose diff changed are replaced, in one patch."
  (let ((ops nil))
    (pcase-dolist (`(,f . ,r) (reverse drgnx-cockpit-edits--ready))
      (when-let* ((file (car (member f drgnx-cockpit-edits--files))) (info (gethash file drgnx-cockpit-edits--info)))
        (cond
         ((equal r "") (push (cons file nil) ops))     ; no change against the base any more
         ((stringp r)
          (let ((hash (secure-hash 'sha1 r)))
            (unless (and (equal hash (plist-get info :hash)) (null (plist-get info :note)))
              (let ((c (drgnx-cockpit-edits--counts r)))
                (puthash file (plist-put (plist-put (plist-put (plist-put info :hash hash) :added (car c)) :removed (cdr c)) :note nil)
                         drgnx-cockpit-edits--info)
                (push (cons file r) ops)))))
         (t
          (let ((note (if (plist-get r :too-large)
                          (format "  too large to show here (%s): open the file to read it" (file-size-human-readable (plist-get r :too-large)))
                        (format "  cannot show its diff: %s" (plist-get r :error)))))
            (unless (equal note (plist-get info :note))
              (puthash file (plist-put (plist-put info :hash nil) :note note) drgnx-cockpit-edits--info)
              (push (cons file (drgnx-cockpit-edits--note-text note)) ops)))))))
    (setq drgnx-cockpit-edits--ready nil)
    (when ops
      (let ((gone (delq nil (mapcar (lambda (op) (and (null (cdr op)) (car op))) ops))))
        (dolist (f gone) (remhash f drgnx-cockpit-edits--info) (remhash f drgnx-cockpit-edits--dirty))
        (setq drgnx-cockpit-edits--files (seq-remove (lambda (f) (memq f gone)) drgnx-cockpit-edits--files))
        (if (null drgnx-cockpit-edits--files)
            (drgnx-cockpit-edits--show-note (format "no changes since %s" (drgnx-cockpit-edits--base-name)))
          (drgnx-cockpit-edits--patch
           (lambda ()
             (pcase-dolist (`(,file . ,body) (nreverse ops))
               (if body (drgnx-cockpit-edits--put-section file body)
                 (when-let* ((s (drgnx-cockpit-edits--section file))) (delete-region (car s) (cdr s))))))))))))

(defun drgnx-cockpit-edits--refresh ()
  "List the agent's changes again and diff every file (g)."
  (dolist (f drgnx-cockpit-edits--files) (puthash f t drgnx-cockpit-edits--dirty))
  (setq drgnx-cockpit-edits--list-dirty t drgnx-cockpit-edits--listed-at 0)
  (ignore-errors (drgnx-cockpit-edits--read-marks))
  (drgnx-cockpit-edits--schedule 0))

(defun drgnx-cockpit-edits--revert (&rest _) (drgnx-cockpit-edits--refresh))

(defun drgnx-cockpit-edits--drop-watches ()
  "Remove this pane's file watches."
  (when (hash-table-p drgnx-cockpit-edits--watches)
    (maphash (lambda (_ w) (ignore-errors (file-notify-rm-watch w))) drgnx-cockpit-edits--watches)
    (clrhash drgnx-cockpit-edits--watches)))

(defconst drgnx-cockpit-edits--timers '(cockpit-edits-check cockpit-edits-tick cockpit-edits-turn cockpit-edits-flush)
  "The names of a pane's timer keys, each `(NAME . BUFFER)' and owned by its buffer.")

(defun drgnx-cockpit-edits--follow ()
  "Each agent's edits pane follows its agent while a window of a visible frame shows it (`drgnx-cockpit-shown-p'):
shown, its check runs (`(cockpit-edits-check . BUFFER)', every `drgnx-cockpit-edits-check-interval') and, when it was
not running, the changes are listed again at once, which watches their folders again.  Hidden, the check, the
ticks and the file watches go: it keeps no timer and no watch.  It walks `drgnx-cockpit-edits--buffers' only."
  (dolist (b drgnx-cockpit-edits--buffers)
    (when (buffer-live-p b)
      (with-current-buffer b
        (let ((check (cons 'cockpit-edits-check b)))
          (cond ((drgnx-cockpit-shown-p b)
                 (unless (drgnx-timer-active-p check)
                   (drgnx-timer-start check drgnx-cockpit-edits-check-interval #'drgnx-cockpit-edits--check
                                      :repeat drgnx-cockpit-edits-check-interval :args (list b) :owner b)
                   (setq drgnx-cockpit-edits--list-dirty t)
                   (drgnx-cockpit-edits--schedule 0)))
                (t (dolist (name drgnx-cockpit-edits--timers) (drgnx-timer-cancel (cons name b)))
                   (drgnx-cockpit-edits--drop-watches))))))))

(defun drgnx-cockpit-edits--pane-shown (data)
  "`pane-shown', on the store's `now' lane: an agent's edits show — `drgnx-cockpit-edits--follow'."
  (when (eq (plist-get data :kind) 'agent-edits) (drgnx-cockpit-edits--follow)))

(defun drgnx-cockpit-edits--pane-hidden (data)
  "`pane-hidden', on the store's `now' lane: an agent's edits went — `drgnx-cockpit-edits--follow'."
  (when (eq (plist-get data :kind) 'agent-edits) (drgnx-cockpit-edits--follow)))

(defun drgnx-cockpit-edits--windows-changed (_data)
  "`windows-changed', on the store's `idle' lane (never inside redisplay): a window shows another buffer — one agent's
edits in place of another's in the same window, which is no pane event, or edits shown with `C-x b' —
`drgnx-cockpit-edits--follow'."
  (when drgnx-cockpit-edits--buffers (drgnx-cockpit-edits--follow)))

(defun drgnx-cockpit-edits--subscribe ()
  "Hear of the edits panes from the workbench state store (tools/cockpit's setup; recorded there)."
  (drgnx-state-subscribe 'pane-shown #'drgnx-cockpit-edits--pane-shown :lane 'now)
  (drgnx-state-subscribe 'pane-hidden #'drgnx-cockpit-edits--pane-hidden :lane 'now)
  (drgnx-state-subscribe 'windows-changed #'drgnx-cockpit-edits--windows-changed))

(defun drgnx-cockpit-edits--unwatch ()
  "The pane is killed (its `kill-buffer-hook'): it leaves `drgnx-cockpit-edits--buffers' and its file watches go (the
buffer owns its timers)."
  (setq drgnx-cockpit-edits--buffers (delq (current-buffer) drgnx-cockpit-edits--buffers))
  (drgnx-cockpit-edits--drop-watches)
  ;; its private folder goes too (only while empty: nothing put there by hand is deleted)
  (when (and (stringp drgnx-cockpit-edits--neutral) (file-directory-p drgnx-cockpit-edits--neutral))
    (ignore-errors (delete-directory drgnx-cockpit-edits--neutral))))

;;;; The buffer and its mode

(defun drgnx-cockpit-edits--fontify-headers (limit)
  "A font-lock matcher that matches nothing: it gives the header lines' parts between point and LIMIT their faces
before the diff keywords run, which then leave them alone."
  (let ((pos (point)))
    (while (< pos limit)
      (let ((next (next-single-property-change pos 'drgnx-cockpit-edits-face nil limit)))
        (when-let* ((face (get-text-property pos 'drgnx-cockpit-edits-face))) (put-text-property pos next 'face face))
        (setq pos next))))
  nil)

(defconst drgnx-cockpit-edits--font-lock-keywords
  '((drgnx-cockpit-edits--fontify-headers)
    ("^\\(?:diff --git\\|index \\|new file mode\\|deleted file mode\\|old mode\\|new mode\\|similarity\\|Binary files\\).*$"
     . 'diff-header)
    ("^\\(?:---\\|\\+\\+\\+\\) .*$" . 'diff-file-header)
    ("^@@ .*$" . 'diff-hunk-header)
    ("^\\+.*$" . 'diff-added)
    ("^-.*$" . 'diff-removed))
  "The pane's colours: diff-mode's faces (headers, hunks, added and removed lines), none of its code.  The header
lines come first (`drgnx-cockpit-edits--fontify-headers').")

(defun drgnx-cockpit-edits--keep-mode ()
  "`change-major-mode-hook' of an agent's edits: it stays what it is — a pane shown as text, never a diff or patch
buffer that other commands (diff-mode, VC, ediff) would apply."
  (user-error "An agent's edits stay as they are: r asks the agent to undo a file, c comments on a line"))

(defun drgnx-cockpit-edits--neutral-dir ()
  "A new empty folder of the pane's own (mode 0700, under `temporary-file-directory'), removed when the pane is killed:
its `default-directory', never the agent's — so VC, patch, compile and shells in the pane find nothing of the agent's
(or anyone's) to act on.  The agent's folder lives in `drgnx-cockpit-edits--source'."
  (file-name-as-directory (with-file-modes #o700 (make-temp-file "drgnx-edits-" t))))

(defvar drgnx-cockpit-edits-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "An agent's edits' keys (from the key profiles: a, r, c, n, p, RET, TAB, S-TAB) over `special-mode-map'.")

(define-derived-mode drgnx-cockpit-edits-mode special-mode "Agent Edits"
  "An agent's edits as a live diff: a header line per file, its diff below (docs/guide/cockpit.md).  It is text,
not a diff-mode buffer, and its `default-directory' is a neutral folder: nothing outside its own commands acts on
the agent's files."
  (setq truncate-lines t drgnx-cockpit-edits--neutral (drgnx-cockpit-edits--neutral-dir)
        default-directory drgnx-cockpit-edits--neutral)
  (buffer-disable-undo)
  (setq-local font-lock-defaults '(drgnx-cockpit-edits--font-lock-keywords t))
  (setq-local revert-buffer-function #'drgnx-cockpit-edits--revert)
  (add-hook 'change-major-mode-hook #'drgnx-cockpit-edits--keep-mode nil t)
  (add-hook 'kill-buffer-hook #'drgnx-cockpit-edits--unwatch nil t)
  (cl-pushnew (current-buffer) drgnx-cockpit-edits--buffers))

(dolist (v '(drgnx-cockpit-edits--agent drgnx-cockpit-edits--id drgnx-cockpit-edits--source drgnx-cockpit-edits--neutral))
  (put v 'permanent-local t))
;; a clone would share the pane's timers and watches (killing it would stop the original's updates): none
(put 'drgnx-cockpit-edits-mode 'no-clone t)
(put 'drgnx-cockpit-edits-mode 'no-clone-indirect t)

(defun drgnx-cockpit-edits--teardown ()
  "Undo the module's part for agents' edits: kill every edits pane (each one's `kill-buffer-hook' ends its timers and
watches) and the pane's placeholder.  Nothing else of it is global (its state subscriptions are the setup's)."
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-cockpit-edits-mode) (kill-buffer b)))
  (when-let* ((b (get-buffer " *drgnx agent-edits*"))) (kill-buffer b))
  (setq drgnx-cockpit-edits--last nil))

(defun drgnx-cockpit-edits--agent-id (agent) (if (consp agent) (plist-get agent :id) agent))

(defun drgnx-cockpit-edits-buffer (agent)
  "AGENT's edits buffer, `*edits: ID*' — AGENT an id, or its plist from the cockpit's model — made the first time; it
follows the agent's edits while it shows (`drgnx-cockpit-edits--follow'), and lists them first once it shows."
  (let* ((id (drgnx-cockpit-edits--agent-id agent)) (name (format "*edits: %s*" id)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (let ((enable-local-variables nil) (enable-dir-local-variables nil)) (drgnx-cockpit-edits-mode))
          (setq drgnx-cockpit-edits--agent agent drgnx-cockpit-edits--id id
                drgnx-cockpit-edits--name (or (and (consp agent) (plist-get agent :name)) (plist-get (drgnx-coord-agent id) :name) id)
                drgnx-cockpit-edits--job (and (consp agent) (plist-get agent :job))
                drgnx-cockpit-edits--info (make-hash-table :test #'equal)
                drgnx-cockpit-edits--dirty (make-hash-table :test #'equal)
                drgnx-cockpit-edits--watches (make-hash-table :test #'equal)
                drgnx-cockpit-edits--list-dirty t
                drgnx-cockpit-edits--event-id (or (caar (sqlite-select (drgnx-work-db) "select max(id) from event")) 0))
          (ignore-errors (drgnx-cockpit-edits--read-marks))
          (drgnx-cockpit-edits--header-line)
          (drgnx-cockpit-edits--schedule 0)
          (current-buffer)))))

(defun drgnx-cockpit-edits-show (agent)
  "Show AGENT's edits in the editor area (pane `agent-edits') and select them; returns the buffer."
  (let ((b (drgnx-cockpit-edits-buffer agent)))
    (setq drgnx-cockpit-edits--last b)
    (if (drgnx-pane-kind 'agent-edits) (drgnx-pane-show 'agent-edits :buffer b :select t) (pop-to-buffer b))
    b))

(defun drgnx-cockpit-edits-pane-buffer ()
  "What pane `agent-edits' shows when no agent is named: the edits shown last, else a note saying how to pick one."
  (if (buffer-live-p drgnx-cockpit-edits--last) drgnx-cockpit-edits--last
    (or (get-buffer " *drgnx agent-edits*")
        (with-current-buffer (get-buffer-create " *drgnx agent-edits*" t)
          (special-mode)
          (let ((inhibit-read-only t)) (insert "Click a task or an agent in the Work graph to see its edits here.\n"))
          (current-buffer)))))

;;;; Opening from the Work graph

(defun drgnx-cockpit-edits--model ()
  (when-let* ((g (and (boundp 'drgnx-cockpit-graph-buffer-name) (get-buffer drgnx-cockpit-graph-buffer-name))))
    (buffer-local-value 'drgnx-cockpit--model g)))

(defun drgnx-cockpit-edits--model-agent (id)
  "Agent ID as the Work graph's model has it (a plist), else ID."
  (or (seq-find (lambda (a) (equal (plist-get a :id) id)) (plist-get (drgnx-cockpit-edits--model) :agents)) id))

(defun drgnx-cockpit-edits--task-agent (node)
  "The id of the agent task NODE is assigned to in the Work graph, or nil."
  (seq-some (lambda (e) (let ((to (plist-get e :to)))
                          (and (eq (plist-get e :kind) 'assigned) (equal (plist-get e :from) (plist-get node :id))
                               (stringp to) (string-prefix-p "agent:" to) (substring to (length "agent:")))))
            (plist-get (drgnx-cockpit-edits--model) :edges)))

(defun drgnx-cockpit-edits-open-agent (node)
  "Open agent NODE of the Work graph: its edits."
  (drgnx-cockpit-edits-show (drgnx-cockpit-edits--model-agent (plist-get node :agent))))

(defun drgnx-cockpit-edits-open-task (node)
  "Open task NODE of the Work graph: the edits of the agent working on it, else its plan at its heading."
  (if-let* ((id (drgnx-cockpit-edits--task-agent node)))
      (drgnx-cockpit-edits-show (drgnx-cockpit-edits--model-agent id))
    (drgnx-cockpit--open-task node)))

;;;; Commands: move by file, accept, revert, comment

(defun drgnx-cockpit-edits--here ()
  (unless (derived-mode-p 'drgnx-cockpit-edits-mode) (user-error "Not in an agent's edits")))

(defun drgnx-cockpit-edits--file-here ()
  "The file of the section at point."
  (drgnx-cockpit-edits--here)
  (or (get-text-property (line-beginning-position) 'drgnx-cockpit-edits-file)
      (user-error "No file here: n and p move between files")))

(defun drgnx-cockpit-edits--line-here ()
  "The line of the file that the diff line at point stands for: its new side (a removed line: where it was); 1 off
any hunk."
  (let* ((bol (line-beginning-position)) (start (drgnx-cockpit-edits--start-at bol)))
    (save-excursion
      (goto-char (line-end-position))
      (if (not (re-search-backward "^@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" start t)) 1
        (let ((n (string-to-number (match-string 1))) (count 0))
          (forward-line 1)
          (while (< (point) bol)
            (when (memq (char-after) '(?\s ?+)) (cl-incf count))
            (forward-line 1))
          (max 1 (+ n count)))))))

(defun drgnx-cockpit-edits-next-file (&optional n)
  "Move to the next changed file's header line; with N, N files on (back when negative)."
  (interactive "p")
  (drgnx-cockpit-edits--here)
  (let ((n (or n 1)))
    (if (< n 0) (drgnx-cockpit-edits-previous-file (- n))
      (dotimes (_ n)
        (let ((pos (point)))
          (while (and (setq pos (next-single-property-change pos 'drgnx-cockpit-edits-file))
                      (not (get-text-property pos 'drgnx-cockpit-edits-file))))
          (if pos (goto-char pos) (user-error "No next file")))))))

(defun drgnx-cockpit-edits-previous-file (&optional n)
  "Move to this file's header line, or the previous file's when on it; with N, N files back."
  (interactive "p")
  (drgnx-cockpit-edits--here)
  (dotimes (_ (or n 1))
    (let* ((on (get-text-property (point) 'drgnx-cockpit-edits-file))
           (start (if on (drgnx-cockpit-edits--start-at (point)) (point))))
      (if (and on (< start (point))) (goto-char start)
        (let ((pos start))
          (while (and (> pos (point-min)) (not (get-text-property (1- pos) 'drgnx-cockpit-edits-file))) (setq pos (1- pos)))
          (if (> pos (point-min)) (goto-char (drgnx-cockpit-edits--start-at (1- pos))) (user-error "No previous file")))))))

(defun drgnx-cockpit-edits-next-hunk (&optional n)
  "Move to the next hunk's `@@' line, in this file or a later one; with N, N hunks on (back when negative)."
  (interactive "p")
  (drgnx-cockpit-edits--here)
  (let ((n (or n 1)))
    (if (< n 0) (drgnx-cockpit-edits-previous-hunk (- n))
      (dotimes (_ n)
        (let ((to (save-excursion (goto-char (line-end-position)) (and (re-search-forward "^@@ " nil t) (line-beginning-position)))))
          (if to (goto-char to) (user-error "No next hunk")))))))

(defun drgnx-cockpit-edits-previous-hunk (&optional n)
  "Move to the previous hunk's `@@' line; with N, N hunks back."
  (interactive "p")
  (drgnx-cockpit-edits--here)
  (dotimes (_ (or n 1))
    (let ((to (save-excursion (goto-char (line-beginning-position)) (and (re-search-backward "^@@ " nil t) (point)))))
      (if to (goto-char to) (user-error "No previous hunk")))))

(defun drgnx-cockpit-edits-visit ()
  "Open the file of the section at point, from the agent's folder, at the line the diff line at point stands for (in
another window).  A deleted file, or a remote folder, is said, never opened."
  (interactive)
  (let* ((file (drgnx-cockpit-edits--file-here)) (line (drgnx-cockpit-edits--line-here))
         (dir (plist-get drgnx-cockpit-edits--source :dir)) (ok (and (stringp dir) (drgnx-cockpit--file-ok dir file)))
         ;; opened by the true name it was checked by: `find-file-noselect' of the agent's own name follows its links
         ;; again, with handlers on (a link out through `ssh:host:' and back reached Tramp)
         (true (and (eq ok t) (drgnx-file-truename file dir))))
    (cond ((or (not (stringp dir)) (drgnx-cockpit--remote-p dir)) (user-error "The agent's folder is not a local one"))
          ((not true) (user-error "%s is not there to open (deleted, or not a regular file)" (drgnx-wb-display-name file)))
          (t (let ((b (find-file-noselect true)))
               (pop-to-buffer b t)
               (goto-char (point-min))
               (forward-line (1- line))
               b)))))

(defun drgnx-cockpit-edits--event (kind summary data)
  (drgnx-coord-event-add :agent drgnx-cockpit-edits--id :job drgnx-cockpit-edits--job :kind kind :summary summary
                         :data (append (list :by "user") data)))

(defun drgnx-cockpit-edits-accept-file (file)
  "Accept FILE's change as it shows now: a review mark (with the diff's hash) for the merge gate.  It never merges or
commits.  When the file changes again its header says so (\"changed since accepted\"): the mark's hash no longer
matches the diff's, which is what the merge gate compares."
  (interactive (list (drgnx-cockpit-edits--file-here)))
  (drgnx-cockpit-edits--here)
  (let* ((info (gethash file drgnx-cockpit-edits--info)) (hash (plist-get info :hash)))
    (unless hash
      (user-error "%s: its diff does not show here (%s), so it cannot be accepted" (drgnx-wb-display-name file)
                  (string-trim (or (plist-get info :note) "on its way"))))
    (drgnx-coord-review-mark drgnx-cockpit-edits--id file "accepted" hash)
    (drgnx-cockpit-edits--event "accept" (format "you accepted %s" (drgnx-wb-display-name file)) (list :path file :hash hash))
    (drgnx-cockpit-edits--read-marks)
    (drgnx-cockpit-edits--patch-headers (list file))
    (message "Accepted %s: a review mark for the merge gate — nothing is merged" (drgnx-wb-display-name file))))

(defun drgnx-cockpit-edits--session (id)
  "Agent ID's session in this Emacs (its own or a mirror of the hub's), exited or not, or nil."
  (and (fboundp 'drgnx-agents-sessions)
       (seq-find (lambda (s) (equal (or (drgnx-agent-session-remote s) (drgnx-agent-session-id s)) id)) (drgnx-agents-sessions))))

(defun drgnx-cockpit-edits--notify-hub ()
  "Tell the hub a message waits in the store, so it delivers it now (never waits, never fails)."
  (when (and (fboundp 'drgnx-hub-socket) (fboundp 'drgnx-hub-call) (file-exists-p (drgnx-hub-socket)))
    (ignore-errors (drgnx-hub-call "coord/notify" nil #'ignore))))

(defun drgnx-cockpit-edits--queue (src text)
  "Queue TEXT for the pane's agent (SRC: its `drgnx-cockpit-edit-source'), never interrupting it.  The same routes as
`drgnx-cockpit-feed--queue' (the Work cockpit's feed), to be one function when both are in:
- a silent worktree: nobody reads messages there — a `user-error';
- a live session of this Emacs: `drgnx-agents-send', its mode `queue' for the call (one set to interrupt waits all the
  same);
- a live hub session's mirror not set to interrupt: `drgnx-agents-send', the hub's `agents/send' (queued, or steered
  into its turn);
- anything else (a mirror set to interrupt, an exited or failed session, a job's agent elsewhere, an outside agent): a
  message in the store, which the hub gives the agent when it is free (an outside agent reads it with read_inbox); the
  hub is told at once.
`session', `message', or nil when the store held it back (said)."
  (when (eq (plist-get src :kind) 'silent) (user-error "Nobody reads messages in this worktree: no agent reports from it"))
  (let* ((s (drgnx-cockpit-edits--session drgnx-cockpit-edits--id))
         (live (and s (not (memq (drgnx-agent-session-status s) '(exited failed)))))
         (mode (and s (drgnx-agent-session-mode s))))
    (cond
     ((and live (not (drgnx-agent-session-remote s)))
      (if (not (eq mode 'interrupt)) (drgnx-agents-send s text)
        (setf (drgnx-agent-session-mode s) 'queue)
        (unwind-protect (drgnx-agents-send s text)
          (setf (drgnx-agent-session-mode s) mode)))
      'session)
     ((and live (not (eq mode 'interrupt))) (drgnx-agents-send s text) 'session)
     (t
      (let ((r (drgnx-coord-send :job (or (plist-get src :job) drgnx-cockpit-edits--job) :recipient drgnx-cockpit-edits--id :text text)))
        (if (equal (plist-get r :state) "held")
            (progn (message "Work cockpit: held, not sent — %s"
                            (or (plist-get (drgnx-coord-message (plist-get r :id)) :reason) "too many messages"))
                   nil)
          (drgnx-cockpit-edits--notify-hub)
          'message))))))

(defun drgnx-cockpit-edits--stopped-p (src)
  "Whether SRC's agent is known to have stopped — positive evidence only; not being among the sessions never counts.
Only a job's agent can be: its session here (or the hub's mirror) has exited or failed, and its job task is no longer
claimed, running or waiting for input.  Any other agent (an outside one's stop event can be forged): nil."
  (when (eq (plist-get src :kind) 'job)
    (let ((s (drgnx-cockpit-edits--session drgnx-cockpit-edits--id))
          (status (and (plist-get src :task)
                       (caar (sqlite-select (drgnx-work-db) "select status from jtask where id = ?" (list (plist-get src :task)))))))
      (and s (memq (drgnx-agent-session-status s) '(exited failed))
           (stringp status) (not (member status '("claimed" "running" "needs-input")))
           t))))

(defun drgnx-cockpit-edits--inside-p (dir name)
  "Whether NAME (a folder, local) is DIR or inside it, by true names (links resolved, with no file name handler: an
agent names its folder); a remote NAME, or one a link leads to, is not (it is never expanded)."
  (and (stringp name) (stringp dir)
       (let ((d (drgnx-cockpit--true-dir dir)) (n (drgnx-cockpit--true-dir name)))   ; nil for a remote one
         (and d n (string-prefix-p d n)))))

(defun drgnx-cockpit-edits--alone-p (src)
  "Whether no other agent works in SRC's folder: no other live session (here or the hub's) and no other registered
agent has its cwd or worktree in it."
  (let ((dir (plist-get src :dir)) (id drgnx-cockpit-edits--id))
    (not (or (seq-some (lambda (s) (and (not (equal (plist-get s :id) id)) (drgnx-cockpit-edits--inside-p dir (plist-get s :cwd))))
                       (drgnx-cockpit-edits--sessions))
             (seq-some (lambda (r) (and (not (equal (plist-get r :id) id))
                                        (or (drgnx-cockpit-edits--inside-p dir (plist-get r :cwd))
                                            (drgnx-cockpit-edits--inside-p dir (plist-get r :worktree)))))
                       (drgnx-coord-agents))))))

(defun drgnx-cockpit-edits--job-worktree-p (src)
  "Whether git says SRC's folder is the top of a worktree on exactly its task's branch (`job/JOB-N', N from its
jtask id); a git failure is a no."
  (let ((dir (plist-get src :dir)) (job (plist-get src :job)) (task (plist-get src :task)))
    (ignore-errors
      (and (stringp job) (stringp task) (string-match "#\\([0-9]+\\)\\'" task)
           (let ((branch (format "job/%s-%d" job (string-to-number (match-string 1 task)))))
             (and (equal (file-name-as-directory (file-truename (drgnx-cockpit-edits--git dir "rev-parse" "--show-toplevel")))
                         (file-name-as-directory (file-truename dir)))
                  (equal (drgnx-cockpit-edits--git dir "rev-parse" "--abbrev-ref" "HEAD") branch)))))))

(defun drgnx-cockpit-edits--direct-p (src file)
  "Whether r may put FILE back itself.  Only for a job's agent, and only when all hold:
- SRC's folder is the task worktree drgnx made (`.claude/worktrees/JOB-N/' with its jtask row: :job-worktree), local,
  a linked worktree (never a main checkout), and git says it is a worktree's top on the job's branch;
- no other agent works in it (`drgnx-cockpit-edits--alone-p');
- FILE is a regular file inside it (or gone: a deleted file);
- the agent is known to be stopped (`drgnx-cockpit-edits--stopped-p').
An outside agent (its worktree may be the user's own), a native session or a silent worktree: never."
  (let ((dir (plist-get src :dir)))
    (and (eq (plist-get src :kind) 'job) (plist-get src :job-worktree)
         (stringp dir) (not (drgnx-cockpit--remote-p dir)) (drgnx-cockpit--linked-worktree-p dir)
         (drgnx-cockpit--file-ok dir file)
         (drgnx-cockpit-edits--alone-p src)
         (drgnx-cockpit-edits--stopped-p src)
         (drgnx-cockpit-edits--job-worktree-p src))))

(defun drgnx-cockpit-edits--git (dir &rest args)
  "Run git ARGS in local DIR and wait (a command's own step): its output, trimmed; an error when git fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir))
          (process-environment (append '("GIT_TERMINAL_PROMPT=0") process-environment)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args))
        (error "git %s: %s" (car (seq-remove (lambda (a) (string-prefix-p "--" a)) args)) (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun drgnx-cockpit-edits--revert-plan (src file)
  "What putting FILE back in SRC's folder means: (ACTION COMMIT), ACTION `checkout' (the base has FILE) or `delete'
\(it does not: FILE is new), COMMIT the base's full commit id (the merge-base when SRC says :merge-base).  git failing
— no such base, a broken repository — signals: a failure is never taken for \"FILE is not in the base\"."
  (let* ((dir (plist-get src :dir))
         (base (or (plist-get src :base) "HEAD"))
         (base (if (plist-get src :merge-base) (drgnx-cockpit-edits--git dir "merge-base" base "HEAD") base))
         (commit (drgnx-cockpit-edits--git dir "rev-parse" "--verify" (concat base "^{commit}"))))
    (list (if (string-empty-p (drgnx-cockpit-edits--git dir "--literal-pathspecs" "ls-tree" "--name-only" commit "--" file))
              'delete 'checkout)
          commit)))

(defun drgnx-cockpit-edits--revert-question (plan file dir)
  "The question asked before PLAN (`drgnx-cockpit-edits--revert-plan') is carried out on FILE in DIR: exactly what
will happen, names masked (`drgnx-wb-display-name'), the folder abbreviated."
  (let ((f (drgnx-wb-display-name file)) (wt (drgnx-wb-display-name (abbreviate-file-name (directory-file-name dir)))))
    (if (eq (car plan) 'delete)
        (format "Delete new file %s in %s (the agent's own worktree)? " f wt)
      (format "Put %s back as %s has it, in %s, discarding the agent's changes? " f (substring (cadr plan) 0 8) wt))))

(defun drgnx-cockpit-edits-revert-file (file)
  "Undo the agent's changes to FILE.  As a rule: a queued request to the agent (\"[revert] please undo your changes to
FILE\"), never an interruption.  Only when the agent is known to be stopped and FILE is in a worktree that is its alone
\(`drgnx-cockpit-edits--direct-p'): after you confirm the exact action, FILE as its base has it (`git checkout BASE --
FILE'), or deleted when the base has no such file.  A native session's folder, a silent worktree and the main checkout
are never touched."
  (interactive (list (drgnx-cockpit-edits--file-here)))
  (drgnx-cockpit-edits--here)
  (let ((src (drgnx-cockpit-edits--read-source)) (shown (drgnx-wb-display-name file)))   ; nil: no folder known
    (if (and src (drgnx-cockpit-edits--direct-p src file))
        (let* ((dir (plist-get src :dir)) (plan (drgnx-cockpit-edits--revert-plan src file)))
          (cond
           ((not (yes-or-no-p (drgnx-cockpit-edits--revert-question plan file dir))) (message "Nothing reverted"))
           ;; while you were asked, the agent may have started again, another may have come: check it all again
           ((let ((now (drgnx-cockpit-edits--read-source)))
              (not (and now (equal (plist-get now :dir) dir) (drgnx-cockpit-edits--direct-p now file)
                        (equal (drgnx-cockpit-edits--revert-plan now file) plan))))
            (drgnx-cockpit-edits--request src file shown "things changed while you were asked; "))
           (t
            (if (eq (car plan) 'checkout)
                (drgnx-cockpit-edits--git dir "--literal-pathspecs" "checkout" (cadr plan) "--" file)
              (when (eq t (drgnx-cockpit--file-ok dir file)) (delete-file (expand-file-name file dir))))
            (drgnx-cockpit-edits--event "revert" (format "you reverted %s" shown) (list :path file :direct t :to (cadr plan)))
            (puthash file t drgnx-cockpit-edits--dirty)
            (setq drgnx-cockpit-edits--list-dirty t drgnx-cockpit-edits--listed-at 0)
            (drgnx-cockpit-edits--schedule 0)
            (message "Reverted %s in %s's own worktree" shown drgnx-cockpit-edits--name))))
      (drgnx-cockpit-edits--request src file shown ""))))

(defun drgnx-cockpit-edits--request (src file shown why)
  "Queue a request to SRC's agent to undo its changes to FILE (SHOWN: its masked name), WHY said first in the echo."
  (when (drgnx-cockpit-edits--queue src (format "[revert] please undo your changes to %s" shown))
    (drgnx-cockpit-edits--event "revert" (format "you asked to undo %s" shown) (list :path file :requested t))
    (message "%s %s to undo its changes to %s (queued: it never interrupts)"
             (if (string-empty-p why) "Asked" (concat why "asked")) drgnx-cockpit-edits--name shown)))

(defun drgnx-cockpit-edits-comment (file line text)
  "Comment TEXT on LINE of FILE (the diff line at point): a queued message \"[comment] FILE:LINE: TEXT\" to the
agent, never an interruption."
  (interactive (let* ((file (drgnx-cockpit-edits--file-here)) (line (drgnx-cockpit-edits--line-here)))
                 (list file line (read-string (format "Comment on %s:%d: " (drgnx-wb-display-name file) line)))))
  (drgnx-cockpit-edits--here)
  (let ((text (string-trim (or text ""))) (shown (drgnx-wb-display-name file)))
    (when (string-empty-p text) (user-error "No comment"))
    (when (drgnx-cockpit-edits--queue (drgnx-cockpit-edits--read-source) (format "[comment] %s:%d: %s" shown line text))
      (drgnx-cockpit-edits--event "comment" (format "you commented on %s:%d: %s" shown line text) (list :path file :line line))
      (message "Comment queued for %s (it never interrupts)" drgnx-cockpit-edits--name))))

;;;; The module's part

(defun drgnx-cockpit-edits--setup ()
  "tools/cockpit's part for agents' edits: their commands and their subscriptions to the workbench state store (the
pane kind is `agent-edits').  Nothing else global: `drgnx-cockpit-edits--teardown' only kills the panes."
  (drgnx-cockpit-edits--subscribe)
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((cockpit-accept-file "Accept File" drgnx-cockpit-edits-accept-file
                                        "Mark the agent's change to this file accepted (a review mark; never a merge)")
                   (cockpit-revert-file "Revert File…" drgnx-cockpit-edits-revert-file
                                        "Ask the agent to undo its changes to this file (stopped, in a worktree that is its alone: put it back, after asking)")
                   (cockpit-comment "Comment on Line…" drgnx-cockpit-edits-comment
                                    "A queued message to the agent about this line of the file")
                   (cockpit-edits-next-file "Next Changed File" drgnx-cockpit-edits-next-file "The next file of the agent's edits")
                   (cockpit-edits-previous-file "Previous Changed File" drgnx-cockpit-edits-previous-file
                                                "The previous file of the agent's edits")
                   (cockpit-edits-next-hunk "Next Hunk" drgnx-cockpit-edits-next-hunk "The next hunk of the agent's edits")
                   (cockpit-edits-previous-hunk "Previous Hunk" drgnx-cockpit-edits-previous-hunk
                                                "The previous hunk of the agent's edits")
                   (cockpit-edits-visit "Open File at Line" drgnx-cockpit-edits-visit
                                        "The changed file, from the agent's folder, at the line the diff line stands for")))
    (drgnx-command-define id :category "Work" :title title :command fn :doc doc :map 'drgnx-cockpit-edits-mode-map)))

(provide 'drgnx-cockpit-edits)
;;; drgnx-cockpit-edits.el ends here
