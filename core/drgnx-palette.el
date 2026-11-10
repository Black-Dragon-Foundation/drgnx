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
  "The row the list shows for LABEL: the category's icon and the title."
  (concat (drgnx-look-icon (alist-get (drgnx-palette--category label) drgnx-palette--category-icons
                                      'chevron-right nil #'equal)
                           'drgnx-text-muted)
          " " (drgnx-palette--title label)))

(defun drgnx-palette--group-title (group)
  "The title line of GROUP: its name in `drgnx-palette-group', in from the left as a row's text is."
  (concat (if (display-graphic-p)
              (propertize " " 'display `(space :width (,(drgnx-px (+ 6 drgnx-palette-row-padding)))))
            " ")
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

(defun drgnx-palette-sort (labels cands &optional ids)
  "LABELS with the recently run commands first, newest first; the rest in their order.  CANDS is (LABEL . ID); IDS,
when given, is a hash of CANDS (`drgnx-palette--ids', made once per palette, not per key).  The history is read once and
no comparison runs: the labels with a rank are placed by it and the others follow as they came."
  (let* ((ids (or ids (drgnx-palette--ids cands)))
         (rank (make-hash-table :test #'eq)) (i 0)
         (ranked nil) (rest nil))
    (dolist (e (drgnx-palette--history))
      (unless (gethash (car e) rank) (puthash (car e) i rank))
      (setq i (1+ i)))
    (dolist (l labels)
      (if-let* ((r (gethash (gethash l ids) rank))) (push (cons r l) ranked) (push l rest)))
    (nconc (mapcar #'cdr (sort (nreverse ranked) (lambda (a b) (< (car a) (car b)))))   ; the ranked few, stable
           (nreverse rest))))

(defun drgnx-palette--ids (cands)
  "A hash label → id of CANDS (the first of a label that two commands share)."
  (let ((h (make-hash-table :test #'equal :size (length cands))))
    (dolist (c cands) (unless (gethash (car c) h) (puthash (car c) (cdr c) h)))
    h))

(defun drgnx-palette-group (label)
  "The group of the candidate LABEL (\"Category: Title\"): Agents, Files or Commands."
  (cond ((string-match-p "\\`\\(Agents?\\|Work\\): " label) "Agents")
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
         ;; the keys are the ones this terminal can send, asked from the buffer the command would run in
         ;; (the annotations are made with the minibuffer current)
         (origin (current-buffer))
         (annotate (lambda (label)
                     (when-let* ((c (drgnx-commands-get (cdr (assoc label cands)))))
                       (let ((key (with-current-buffer (if (buffer-live-p origin) origin (current-buffer))
                                    (drgnx-surfaces-key c))))
                         (drgnx-palette--annotation (drgnx-cmd-category c)
                                                    (drgnx-palette-recent-age (cdr (assoc label cands)))
                                                    (and (not (string-empty-p key))
                                                         (car (split-string key " (" t))))))))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (annotation-function . ,annotate) (category . drgnx-command)
                                 (display-sort-function . ,(lambda (labels) (drgnx-palette-sort labels cands ids)))
                                 (group-function . ,(lambda (label transform)
                                                      (if transform (drgnx-palette--shown label)
                                                        (drgnx-palette--group-title (drgnx-palette-group label))))))
                    (complete-with-action action cands string pred))))
         (choice (string-trim (completing-read "Command (# for a code question): " table nil nil initial))))
    (cond ((string-empty-p choice))
          ((assoc choice cands) (drgnx-palette--run (cdr (assoc choice cands))))
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
