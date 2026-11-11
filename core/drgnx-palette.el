;;; drgnx-palette.el --- The command palette -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every available registry command by "Category: Title", with its key shown beside it;
;; choosing one runs it as if typed and shows the key tip.  Works with any completion UI.  A row shows (palette.html)
;; an icon and the title, then the category and when it was last run in the subtle colour, then the keycaps at the
;; right edge; the groups are Commands, Files and Agents.
;; Input starting with `#' is a Semantic Search question.  The completion UI does not require a match (an
;; orderless or other style may never offer `#words' as a candidate); the answer is resolved here.

;;; Code:
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-type-faces)             ; `drgnx-code-small', `drgnx-ui-caption'
(require 'drgnx-faces)                  ; `drgnx-text-subtle'
(require 'drgnx-icons)                  ; `drgnx-look-icon'
(require 'drgnx-pixels)                 ; `drgnx-px'

(declare-function drgnx-surfaces-run "drgnx-surfaces")
(declare-function project-files "project" (project &optional dirs))
(declare-function project-root "project" (project))

(defconst drgnx-palette--ask-prefix "Agents: Ask an agent: \""
  "The start of the row that asks an agent; the typed text and a closing quote follow.")

;;;; Keycaps

(defface drgnx-keycap '((t :inherit (drgnx-ui-caption drgnx-text-subtle) :box (:line-width (1 . 1))))
  "One key of a shortcut, drawn as a cap: subtle text in the caption role, ringed in the strong border (the themes give
the ring's colour), radius 4 where the compositor rounds."
  :group 'drgnx-look)

(defconst drgnx-palette--key-names
  '(("SPC" . "Space") ("RET" . "Enter") ("TAB" . "Tab") ("ESC" . "Esc") ("DEL" . "Backspace"))
  "Emacs key names that read differently on a cap.")

(defconst drgnx-palette--modifier-names
  '((?C . "Ctrl") (?M . "Alt") (?A . "Alt") (?S . "Shift") (?s . "Super") (?H . "Hyper"))
  "The modifier prefixes of a key description, by letter.")

(defun drgnx-palette-keycap-names (key)
  "The caps of the key description KEY (\"C-S-p\", \"SPC f f\", \"<f1>\") as a list of names: modifiers first
\(Ctrl, Alt, Shift), then the key, for each key of a chord."
  (mapcan (lambda (chord)
            (let (mods)
              (while (string-match "\\`\\([CMASsH]\\)-\\(.+\\)\\'" chord)
                (push (cdr (assq (aref (match-string 1 chord) 0) drgnx-palette--modifier-names)) mods)
                (setq chord (match-string 2 chord)))
              (nconc (nreverse mods)
                     (list (cond ((cdr (assoc chord drgnx-palette--key-names)))
                                 ((string-match "\\`<\\(.+\\)>\\'" chord) (capitalize (match-string 1 chord)))
                                 ((= (length chord) 1) (upcase chord))
                                 (t chord))))))
          (split-string key " " t)))

(defconst drgnx-palette--keycap-pad (propertize " " 'display '(space :width (4)))
  "The room inside a keycap at either end (design §3.5 `kbd': 5 px with the 1 px ring).")

(defun drgnx-palette-keycap (name)
  "One keycap showing NAME (\"Ctrl\", \"↵\"): `drgnx-keycap' with 4 px of room inside at either end on a graphical
frame; on a terminal, which draws no ring, the name alone (a 4 px space is 4 columns there)."
  (let ((pad (if (display-graphic-p) drgnx-palette--keycap-pad "")))
    (propertize (concat pad name pad) 'face 'drgnx-keycap)))

(defun drgnx-palette-keycaps (key)
  "The key description KEY as keycaps (`drgnx-palette-keycap'), one space between."
  (mapconcat #'drgnx-palette-keycap (drgnx-palette-keycap-names key) " "))

;;;; Rows

(defvar drgnx-palette--file-rows nil
  "While the palette reads: a hash LABEL → FILE of the Files group's rows (`drgnx-palette-files').")

(defun drgnx-palette--file-table (rows)
  "A hash LABEL → FILE of ROWS, an alist of `drgnx-palette-files'."
  (let ((h (make-hash-table :test #'equal :size (max 1 (length rows)))))
    (pcase-dolist (`(,label . ,file) rows) (puthash label file h))
    h))

(defun drgnx-palette--file (label)
  "The file of the Files row LABEL, or nil when LABEL is no file's row."
  (and drgnx-palette--file-rows (gethash (substring-no-properties label) drgnx-palette--file-rows)))

(defface drgnx-palette-group '((t :inherit (drgnx-ui-caption drgnx-text-subtle) :weight semibold :slant normal))
  "A group's title in the palette: Commands, Files, Agents."
  :group 'drgnx-look)

(defconst drgnx-palette--category-icons
  '(("Agents" . bot) ("Work" . bot) ("AI" . bot) ("Agent Settings" . bot) ("Terminal" . terminal)
    ("Shell" . terminal) ("Source Control" . git-branch) ("File" . file) ("Go" . file) ("Explorer" . folder)
    ("Buffers" . layers) ("Search" . search) ("Settings" . settings) ("Preferences" . settings) ("Help" . info)
    ("Extensions" . layers) ("Plugins" . layers) ("Modules" . layers) ("Runners" . server) ("Remote" . server)
    ("Tests" . play) ("Debug" . circle-dot) ("Notices" . bell) ("Window" . panel-right) ("View" . eye)
    ("Edit" . pencil) ("Code" . file-code) ("Outline" . list-checks))
  "The icon of a command's row by its category; any other category's is `chevron-right'.")

(defconst drgnx-palette-row-padding 8
  "Logical pixels between a row's fill and its text, at either end (palette.html `.it').")

(defun drgnx-palette--title (label)
  "LABEL (\"Category: Title\") without its category, its text properties (the matched letters) kept."
  (let ((i (string-search ": " label)))
    (if i (substring label (+ i 2)) label)))

(defun drgnx-palette--category (label)
  "The category of LABEL (\"Category: Title\"), or nil."
  (let ((i (string-search ": " label)))
    (and i (substring-no-properties label 0 i))))

(defun drgnx-palette--shown (label)
  "The row the list shows for LABEL: the category's icon and the title; a file's icon and name for a file's row; the
bot and the typed text in the accent colour for the row that asks an agent."
  (cond
   ((drgnx-palette--file label)
    (concat (drgnx-look-icon 'file 'drgnx-text-muted) " " (file-name-nondirectory (drgnx-palette--title label))))
   ((string-prefix-p drgnx-palette--ask-prefix label)
    (concat (drgnx-look-icon 'bot 'drgnx-text-muted) " Ask an agent: "
            (propertize (concat "“" (truncate-string-to-width (drgnx-palette--asked label) 40) "…”")
                        'face 'drgnx-palette-asked)))
   (t (drgnx-palette--command-shown label))))

(defun drgnx-palette--command-shown (label)
  "A command's row for LABEL: the category's icon and the title."
  (concat (drgnx-look-icon (alist-get (drgnx-palette--category label) drgnx-palette--category-icons
                                      'chevron-right nil #'equal)
                           'drgnx-text-muted)
          " " (drgnx-palette--title label)))

(defface drgnx-palette-asked '((t :inherit drgnx-accent))
  "The typed text in the row that asks an agent (palette.html: the quoted words in the accent colour)."
  :group 'drgnx-look)

(defconst drgnx-palette-files-max 5000
  "How many of the project's files the Files group offers (the files open in buffers first).")

(defun drgnx-palette-files ()
  "(\"File: RELATIVE\" . FILE) for the files of the current project, those visited in buffers first, at most
`drgnx-palette-files-max'; outside a project, the files visited in buffers, relative to their folder's parent."
  (let* ((pr (and (fboundp 'project-current) (project-current)))
         (root (and pr (expand-file-name (project-root pr))))
         (open (delq nil (mapcar #'buffer-file-name (buffer-list))))
         (open (if root (seq-filter (lambda (f) (file-in-directory-p f root)) open) open))
         (all (delete-dups (append open (and pr (ignore-errors (project-files pr))))))
         (rows nil) (n 0))
    (while (and all (< n drgnx-palette-files-max))
      (let ((f (expand-file-name (pop all))))
        (push (cons (concat "File: " (if root (file-relative-name f root)
                                       (file-relative-name f (file-name-directory
                                                              (directory-file-name (file-name-directory f))))))
                    f)
              rows)
        (setq n (1+ n))))
    (nreverse rows)))

(defun drgnx-palette--file-annotation (label)
  "A file row's annotation: its folder in the subtle colour."
  (let ((dir (file-name-directory (drgnx-palette--title label))))
    (concat "  " (propertize (directory-file-name (or dir "./")) 'face 'drgnx-text-subtle))))

(defun drgnx-palette--ask-command ()
  "The `agents-ask' command when it can run, else nil."
  (when-let* ((c (drgnx-commands-get 'agents-ask))) (and (drgnx-commands-available-p c) c)))

(defun drgnx-palette-ask-label (text)
  "The row that asks an agent with TEXT, or nil when no agent can be asked or TEXT is empty or a code question."
  (let ((text (string-trim (or text ""))))
    (and (drgnx-palette--ask-command) (not (string-empty-p text)) (not (string-prefix-p "#" text))
         (concat drgnx-palette--ask-prefix (string-remove-prefix "@" text) "\""))))

(defun drgnx-palette--asked (label)
  "The text the row LABEL asks an agent with."
  (string-remove-suffix "\"" (substring-no-properties label (length drgnx-palette--ask-prefix))))

(defun drgnx-palette--ask-annotation ()
  "The agent row's annotation: the default profile's model and where it runs, then Ctrl ↵ at the right edge."
  (let* ((name (and (fboundp 'drgnx-agents-default-profile) (drgnx-agents-default-profile)))
         (model (or (and name (fboundp 'drgnx-agents-profile) (plist-get (drgnx-agents-profile name) :model)) name))
         (caps (concat (drgnx-palette-keycap "Ctrl") " " (drgnx-palette-keycap "↵"))))
    (concat "  " (propertize (string-join (delq nil (list model "this project")) " · ") 'face 'drgnx-text-subtle)
            (drgnx-palette--right caps) caps)))

(defun drgnx-palette--ask (text)
  "Ask an agent with TEXT through the `agents-ask' command."
  (let ((c (or (drgnx-palette--ask-command) (user-error "No agent to ask (module tools/agents)"))))
    (drgnx-palette-record 'agents-ask)
    (setq this-command (drgnx-cmd-command c))
    (funcall (drgnx-cmd-command c) text)))

(defvar drgnx-palette--ask-now nil "Set by Ctrl+Return in the palette: the typed text, asked of an agent at once.")

(defun drgnx-palette-ask-now ()
  "In the palette: ask an agent with what is typed."
  (interactive)
  (setq drgnx-palette--ask-now (minibuffer-contents-no-properties))
  (exit-minibuffer))

(defvar drgnx-palette--preview nil "(WINDOW BUFFER . MADE) while Tab previews a file: the window, what it showed, the buffer made.")

(defun drgnx-palette--candidate ()
  "The palette's current row: the completion UI's selected one (vertico), else the typed text."
  (or (and (fboundp 'vertico--candidate) (ignore-errors (vertico--candidate)))
      (minibuffer-contents-no-properties)))

(defun drgnx-palette-preview ()
  "In the palette: show the current file row's file in the window the palette was opened from, without leaving it.
Closing the palette without choosing the file puts the window back."
  (interactive)
  (when-let* ((file (drgnx-palette--file (drgnx-palette--candidate)))
              (win (minibuffer-selected-window)))
    (let* ((old (get-file-buffer file)) (b (or old (find-file-noselect file))))
      (unless drgnx-palette--preview (setq drgnx-palette--preview (list win (window-buffer win))))
      (when (and (not old) (not (memq b (cddr drgnx-palette--preview))))
        (setcdr (cdr drgnx-palette--preview) (cons b (cddr drgnx-palette--preview))))
      (set-window-buffer win b))))

(defun drgnx-palette--preview-end (chosen)
  "Put back the window Tab previewed in, unless CHOSEN (a file) is what it shows; kill the buffers it made."
  (when-let* ((p drgnx-palette--preview))
    (setq drgnx-palette--preview nil)
    (pcase-let ((`(,win ,was . ,made) p))
      (when (and (window-live-p win) (buffer-live-p was)
                 (not (and chosen (equal (buffer-file-name (window-buffer win)) chosen))))
        (set-window-buffer win was))
      (dolist (b made)
        (unless (or (get-buffer-window b t) (buffer-modified-p b)) (kill-buffer b))))))

(defvar-keymap drgnx-palette-minibuffer-map
  :doc "The palette's own keys, over the completion UI's: Ctrl+Return asks an agent, Tab previews a file."
  "C-<return>" #'drgnx-palette-ask-now
  "C-RET" #'drgnx-palette-ask-now
  "TAB" #'drgnx-palette-preview)

(defun drgnx-palette--keys ()
  "On the palette's `minibuffer-setup-hook', after the completion UI's: its keys over the UI's."
  (use-local-map (make-composed-keymap drgnx-palette-minibuffer-map (current-local-map))))

(defun drgnx-palette--group-title (group)
  "The title line of GROUP: its name in `drgnx-palette-group', in from the left as a row's text is.  It starts with an
empty `line-prefix', as a row does (`drgnx-completion--row')."
  (concat (if (display-graphic-p)
              (propertize " " 'display `(space :width (,(drgnx-px (+ 6 drgnx-palette-row-padding)))) 'line-prefix "")
            (propertize " " 'line-prefix ""))
          (propertize group 'face 'drgnx-palette-group)))

(defun drgnx-palette--right (s)
  "A space that puts S, which follows it, against the right edge less a row's inset and padding."
  (if (display-graphic-p)
      (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width s (current-buffer))
                                                               (drgnx-px (+ 6 drgnx-palette-row-padding)))))))
    (propertize " " 'display `(space :align-to (- right ,(+ (string-width s) 2))))))

(defun drgnx-palette--annotation (category age key)
  "A row's annotation: CATEGORY and AGE (\"used 2 min ago\", or nil) in the subtle colour, then KEY (a key
description, or nil) as keycaps at the right edge."
  (let ((hint (string-join (delq nil (list category age)) " · "))
        (caps (and key (drgnx-palette-keycaps key))))
    (concat "  " (propertize hint 'face 'drgnx-text-subtle)
            (and caps (concat (drgnx-palette--right caps) caps)))))

;;;; Recent commands

(defconst drgnx-palette-history-max 200 "How many commands the palette remembers.")

(defvar drgnx-palette--history :unloaded
  "The commands run from the palette, newest first, as (ID SECONDS); `:unloaded' until the file is read.")

(defun drgnx-palette--history-file ()
  (expand-file-name "palette-history.eld" (drgnx-paths-dir 'state)))

(defun drgnx-palette--history ()
  "The history, read from the state directory the first time (an unreadable file is an empty history)."
  (when (eq drgnx-palette--history :unloaded)
    (setq drgnx-palette--history
          (let ((file (drgnx-palette--history-file)))
            (let ((r (and (file-readable-p file) (drgnx-file-read file))))
              (and (eq (plist-get r :status) 'ok) (listp (plist-get r :data))
                   (seq-filter (lambda (e) (and (consp e) (symbolp (car e)) (numberp (cadr e))))
                               (plist-get r :data)))))))
  drgnx-palette--history)

(defun drgnx-palette-record (id)
  "Remember that command ID was run from the palette now (in memory and in the state directory)."
  (setq drgnx-palette--history
        (seq-take (cons (list id (floor (float-time)))
                        (seq-remove (lambda (e) (eq (car e) id)) (drgnx-palette--history)))
                  drgnx-palette-history-max))
  (condition-case nil
      (drgnx-file-write (drgnx-palette--history-file) drgnx-palette--history)
    (file-error nil)))

(defun drgnx-palette-recent-rank (id)
  "0 for the command run last, 1 for the one before, nil for a command not run from the palette lately."
  (cl-position id (drgnx-palette--history) :key #'car))

(defun drgnx-palette-recent-age (id)
  "\"used 2 min ago\" for command ID, or nil when it is not in the history."
  (when-let* ((entry (assq id (drgnx-palette--history))))
    (let ((d (max 0 (- (floor (float-time)) (cadr entry)))))
      (cond ((< d 60) "used just now")
            ((< d 3600) (format "used %d min ago" (/ d 60)))
            ((< d 86400) (format "used %d h ago" (/ d 3600)))
            (t (format "used %d d ago" (/ d 86400)))))))

(defun drgnx-palette--alnum-p (char)
  "Non-nil when CHAR is a letter or a digit."
  (memq (get-char-code-property char 'general-category) '(Lu Ll Lt Lm Lo Nd)))

(defun drgnx-palette--word-start-p (title pos)
  "Non-nil when POS in TITLE begins a word: the title's start, or after a character that is not a letter or digit."
  (or (zerop pos) (not (drgnx-palette--alnum-p (aref title (1- pos))))))

(defun drgnx-palette--word-after (title pos)
  "The start of the word after the one at POS in TITLE, or nil."
  (let ((n (length title)) (i pos))
    (while (and (< i n) (drgnx-palette--alnum-p (aref title i))) (setq i (1+ i)))
    (while (and (< i n) (not (drgnx-palette--alnum-p (aref title i)))) (setq i (1+ i)))
    (and (< i n) i)))

(defun drgnx-palette-match-score (title words)
  "How well TITLE (downcased) matches the typed WORDS (downcased): each word 2 at a word's start, 1 inside one, 0
when only the category holds it; 1 more when it starts the word right after the previous word's (the words in
order).  VS Code's ranking in small: word starts and order count, not where the typed letters happen to fall."
  (let ((score 0) (prev nil))
    (dolist (w words score)
      (let ((pos nil) (inside nil) (from 0))
        (while (and (not pos) (setq from (string-search w title from)))
          (if (drgnx-palette--word-start-p title from) (setq pos from)
            (unless inside (setq inside from))
            (setq from (1+ from))))
        (cond (pos (setq score (+ score 2 (if (and prev (eql pos (drgnx-palette--word-after title prev))) 1 0))
                         prev pos))
              (inside (setq score (1+ score) prev inside))
              (t (setq prev nil)))))))

(defun drgnx-palette-sort (labels cands &optional ids input)
  "LABELS in the groups' order, Commands, Files, then Agents (palette.html; the row that asks an agent is the
fallback, never first while something else matches).  Within a group, with nothing typed (INPUT nil or blank) the
recently run commands first, newest first, the rest in their order.  With text typed, how well a row's title
matches it ranks first (`drgnx-palette-match-score') and a recent run only breaks near-ties: it is worth one point,
less than a word matched at its start instead of inside one.  CANDS is (LABEL . ID); IDS, when given, is a hash of
CANDS (`drgnx-palette--ids', made once per palette, not per key).  The history is read once and the groups are split
in one pass."
  (let* ((ids (or ids (drgnx-palette--ids cands)))
         (rank (make-hash-table :test #'eq)) (i 0)
         (words (and input (split-string (downcase input) "[ \t]+" t)))
         (keyed nil) (n 0))
    (dolist (e (drgnx-palette--history))
      (unless (gethash (car e) rank) (puthash (car e) i rank))
      (setq i (1+ i)))
    (dolist (l labels)
      (let* ((r (gethash (gethash l ids) rank))
             (score (if words (+ (drgnx-palette-match-score (downcase (drgnx-palette--title l)) words) (if r 1 0)) 0)))
        ;; (SCORE RECENCY ORDER . LABEL): higher score, then newer, then as they came
        (push (cons (list (- score) (or r most-positive-fixnum) n) l) keyed)
        (setq n (1+ n))))
    (let ((commands nil) (files nil) (agents nil))
      (dolist (l (mapcar #'cdr (sort keyed (lambda (a b) (drgnx-palette--key< (car a) (car b))))))
        (pcase (drgnx-palette-group l)
          ("Files" (push l files)) ("Agents" (push l agents)) (_ (push l commands))))
      (nconc (nreverse commands) (nreverse files) (nreverse agents)))))

(defun drgnx-palette--key< (a b)
  "Non-nil when the sort key A (a list of numbers) comes before B."
  (while (and a (= (car a) (car b))) (setq a (cdr a) b (cdr b)))
  (and a (< (car a) (car b))))

(defun drgnx-palette--ids (cands)
  "A hash label → id of CANDS (the first of a label that two commands share)."
  (let ((h (make-hash-table :test #'equal :size (length cands))))
    (dolist (c cands) (unless (gethash (car c) h) (puthash (car c) (cdr c) h)))
    h))

(defun drgnx-palette-group (label)
  "The group of the candidate LABEL (\"Category: Title\"): Agents, Files or Commands."
  (cond ((drgnx-palette--file label) "Files")
        ((string-match-p "\\`\\(Agents?\\|Work\\): " label) "Agents")
        ((string-match-p "\\`\\(Files?\\|Go\\): " label) "Files")
        (t "Commands")))

(defun drgnx-palette-candidates ()
  "(LABEL . ID) for every command the palette offers, in registry order."
  (mapcar (lambda (c) (cons (drgnx-commands-label c) (drgnx-cmd-id c)))
          (seq-filter #'drgnx-surfaces--showable-p (drgnx-commands-all))))

(defun drgnx-palette--search (question)
  "Run Semantic Search for QUESTION; an empty one prompts for it."
  (let* ((cmd (drgnx-commands-get 'search-semantic))
         (fn (and cmd (drgnx-commands-available-p cmd) (drgnx-cmd-command cmd))))
    (unless fn (user-error "Semantic Search is not available (module tools/search)"))
    (if (string-empty-p question)
        (drgnx-surfaces-run 'search-semantic)
      (setq this-command fn)
      (funcall fn question))))

(defun drgnx-palette--complete (answer cands)
  "The labels of CANDS that ANSWER completes to under the current `completion-styles' (the way
`minibuffer-complete-and-exit' resolved a partial label when a match was required)."
  (let ((all (completion-all-completions answer (mapcar #'car cands) nil (length answer))))
    (when all (setcdr (last all) nil))     ; the last cdr holds the base size
    (mapcar #'substring-no-properties all)))

(defun drgnx-palette--run (id)
  "Remember command ID as the last one run from the palette, then run it."
  (drgnx-palette-record id)
  (drgnx-surfaces-run id))

(defun drgnx-palette (&optional initial)
  "Run any drgnx command by name; `#' followed by words is a Semantic Search; INITIAL is typed already.
The answer is resolved here, not by the completion UI (`require-match' is nil): a command label runs it;
text starting with `#' is a question; empty does nothing; a partial label that completes to one command
runs it; several is an \"Ambiguous\" error naming up to three; none is \"No command\"."
  (interactive)
  (let* ((cands (drgnx-palette-candidates))
         (ids (drgnx-palette--ids cands))
         (file-rows (drgnx-palette-files))
         (drgnx-palette--file-rows (drgnx-palette--file-table file-rows))
         (drgnx-palette--ask-now nil)
         (rows (append cands file-rows))
         ;; the keys are the ones this terminal can send, asked from the buffer the command would run in
         ;; (the annotations are made with the minibuffer current)
         (origin (current-buffer))
         (annotate (lambda (label)
                     (cond
                      ((drgnx-palette--file label) (drgnx-palette--file-annotation label))
                      ((string-prefix-p drgnx-palette--ask-prefix label) (drgnx-palette--ask-annotation))
                      (t
                       (when-let* ((c (drgnx-commands-get (cdr (assoc label cands)))))
                         (let ((key (with-current-buffer (if (buffer-live-p origin) origin (current-buffer))
                                      (drgnx-surfaces-key c))))
                           (drgnx-palette--annotation (drgnx-cmd-category c)
                                                      (drgnx-palette-recent-age (cdr (assoc label cands)))
                                                      (and (not (string-empty-p key))
                                                           (car (split-string key " (" t))))))))))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (annotation-function . ,annotate) (category . drgnx-command)
                                 (display-sort-function . ,(lambda (labels)
                                                             (drgnx-palette-sort labels cands ids (and (minibufferp) (minibuffer-contents-no-properties)))))
                                 (group-function . ,(lambda (label transform)
                                                      (if transform (drgnx-palette--shown label)
                                                        (drgnx-palette--group-title (drgnx-palette-group label))))))
                    ;; the row that asks an agent carries what is typed (a completion style may pass no prefix)
                    (let ((ask (and (minibufferp) (drgnx-palette-ask-label (minibuffer-contents-no-properties)))))
                      (complete-with-action action (if ask (cons (list ask) rows) rows) string pred)))))
         (choice nil) (file nil))
    (unwind-protect
        (setq choice (string-trim (minibuffer-with-setup-hook (:append #'drgnx-palette--keys)
                                    (completing-read "Command (# for a code question): " table nil nil initial)))
              file (drgnx-palette--file choice))
      (drgnx-palette--preview-end file))
    (cond (drgnx-palette--ask-now
           (let ((text (string-trim (string-remove-prefix "@" (string-trim drgnx-palette--ask-now)))))
             (unless (string-empty-p text) (drgnx-palette--ask text))))
          ((string-empty-p choice))
          ((assoc choice cands) (drgnx-palette--run (cdr (assoc choice cands))))
          (file (find-file file))
          ((string-prefix-p drgnx-palette--ask-prefix choice) (drgnx-palette--ask (drgnx-palette--asked choice)))
          ((string-prefix-p "@" choice) (drgnx-palette--ask (string-trim (substring choice 1))))
          ((string-prefix-p "#" choice) (drgnx-palette--search (string-trim (substring choice 1))))
          (t (let ((labels (drgnx-palette--complete choice cands)))
               (pcase (length labels)
                 (0 (user-error "No command: %s" choice))
                 (1 (drgnx-palette--run (cdr (assoc (car labels) cands))))
                 (_ (user-error "Ambiguous: %s%s" (string-join (seq-take labels 3) ", ")
                                (if (> (length labels) 3) ", …" "")))))))))

(defun drgnx-palette-preferences ()
  "The palette with \"Preferences: \" typed: every preference, one command away (VS Code's Cmd+,)."
  (interactive)
  (drgnx-palette "Preferences: "))

(provide 'drgnx-palette)
;;; drgnx-palette.el ends here
