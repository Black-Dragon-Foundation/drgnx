;;; drgnx-surfaces.el --- Everything generated from the command registry -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The registry's outputs: menu bar, right-click menus, which-key labels, the F1 sheet, the
;; markdown cheat sheet, "next time" tips.  Keys are whatever the active key profiles bound
;; (each command's `bound' slot, set by `drgnx-keys').  Ported from the gryphn layer.  See
;; docs/develop/core.md and docs/guide/keys.md.

;;; Code:

(require 'drgnx-registry)
(require 'drgnx-paths)
(require 'easymenu)
(require 'seq)
(require 'drgnx-tty-fallback)

(defvar which-key-replacement-alist)   ; which-key, when present
(defvar drgnx-keys-last)               ; drgnx-keys (loaded after this file)

(defface drgnx-sheet-heading '((t :inherit (bold font-lock-keyword-face)))
  "Category headings in the key sheet (inherits theme faces only)."
  :group 'drgnx)

;;;; Keys and running

(defun drgnx-surfaces--here (key)
  "KEY (a key string) as the selected frame's terminal sends it (`drgnx-tty-sendable-key'): the Alt+Shift key or
the F6 form for a chord a legacy terminal cannot send, KEY itself on a graphical frame or where the terminal sends
it.  Reads what drgnx found about the terminal when it opened (never asks it), in the current buffer, which is
where the command would run."
  (or (ignore-errors (drgnx-tty-sendable-key (selected-frame) key)) key))

(defun drgnx-surfaces--always (key)
  "KEY (a key string) as the selected frame's terminal can send it whatever buffer is current: each chord it cannot
send as its F6 form (the layer's table, no check of the current buffer's maps), KEY itself on a graphical frame, where
the terminal sends it, or when the terminal has no fallback layer."
  (or (ignore-errors
        (let* ((frame (selected-frame))
               (table (and drgnx-tty-fallback (not (display-graphic-p frame))
                           (terminal-parameter (frame-terminal frame) 'drgnx-tty-fallback-table))))
          (if (or (null table) (drgnx-tty-frame-sends-p frame key)) key
            (mapconcat (lambda (ev)
                         (let ((row (cdr (drgnx-tty-fallback--row table ev))))
                           (or (plist-get row :prefix) (plist-get row :alt) (key-description (vector ev)))))
                       (key-parse key) " "))))
      key))

(defun drgnx-surfaces-key (cmd &optional plain)
  "Display string for CMD's first active key, a key in a mode's keymap suffixed with that
keymap; \"\" if none.  The key is shown as the selected frame's terminal can send it, unless PLAIN is t
\(the markdown export: the same on every frame).  PLAIN `menu': the form that is right in every buffer (F6 then the
key, never an Alt+Shift key a mode may rebind), for text a menu keeps while the buffer changes."
  (pcase (car (drgnx-cmd-bound cmd))
    ('nil "")
    (`(,key . ,map)
     (let ((mapsym (cdr (drgnx-commands--keymap-spec map)))
           (key (pcase plain ('nil (drgnx-surfaces--here key)) ('menu (drgnx-surfaces--always key)) (_ key))))
       (if (eq mapsym 'global-map) key
         (format "%s (in %s)" key (string-remove-suffix "-mode-map" (string-remove-suffix "-map" (symbol-name mapsym)))))))))

(defun drgnx-surfaces--any-key (cmd)
  "CMD's active key, else whatever key currently runs its command; as the selected frame's terminal sends it."
  (when-let* ((key (or (car (car (drgnx-cmd-bound cmd)))
                       (let ((c (drgnx-cmd-command cmd)))
                         (when-let* ((k (and (symbolp c) (where-is-internal c nil t)))) (key-description k))))))
    (drgnx-surfaces--here key)))

(defun drgnx-surfaces-tip (cmd)
  "Echo how CMD could have been run with a key, keeping any message the command printed.
Returns the tip, or nil when CMD has no key."
  (when-let* ((key (drgnx-surfaces--any-key cmd)))
    (let ((prev (current-message))
          (tip (format "%s — next time: %s" (drgnx-commands-label cmd) key)))
      (message "%s" (if (and prev (not (string-empty-p prev))) (concat prev "   ·   " tip) tip))
      tip)))

(defvar drgnx-surfaces-run-functions nil
  "Abnormal hook: functions called with the command id after a command ran from the palette or a menu.
An error in one is swallowed (it never breaks the command).  The usage counter is one of them.")

(defun drgnx-surfaces-run (id)
  "Run registry command ID as if typed, run `drgnx-surfaces-run-functions', then show the key tip."
  (let* ((cmd (drgnx-commands-get id)) (c (drgnx-cmd-command cmd)))
    (setq this-command c)
    (call-interactively c t)
    (dolist (f drgnx-surfaces-run-functions)
      (condition-case nil (funcall f id) (error nil)))
    (drgnx-surfaces-tip cmd)))

;;;; Usage counter (local and private: it never leaves this machine; feeds key suggestions)

(defconst drgnx-surfaces--usage-flush-interval 60
  "Seconds between two writes of the usage file, at most.")

(defvar drgnx-surfaces--usage nil
  "Hash table id -> (COUNT (DAY . N)…), loaded on the first run; nil until then.
COUNT is all runs; each (DAY . N) is N runs on day DAY (`time-to-days') for the last 7 days.")
(defvar drgnx-surfaces--usage-dirty nil "Non-nil when the counts differ from the file.")
(defvar drgnx-surfaces--usage-saved nil "`float-time' of the last write, or nil.")
(defvar drgnx-surfaces--usage-timer nil "The pending idle timer that writes the counts.")

(defun drgnx-shortcuts-usage-file ()
  "Where the palette's run counts are kept: command-usage.eld in drgnx's state dir."
  (expand-file-name "command-usage.eld" (drgnx-state-dir)))

(defvar drgnx-surfaces--usage-bad nil
  "Non-nil when the usage file had something unreadable in it; it is kept as a .bak file before the next write.")

(defun drgnx-surfaces--usage-entry (e)
  "E as a clean (ID COUNT (DAY . N)…) entry, or nil when it is not one.  Bad day entries are dropped."
  (when (and (consp e) (symbolp (car e)) e (natnump (cadr e)))
    (let ((days (and (proper-list-p (cddr e))
                     (seq-filter (lambda (d) (and (consp d) (integerp (car d)) (natnump (cdr d)))) (cddr e)))))
      (if (equal days (cddr e)) e `(,(car e) ,(cadr e) ,@days)))))

(defun drgnx-surfaces--usage-read (file)
  "The alist (ID COUNT (DAY . N)…) in FILE, with anything malformed left out; nil when missing or unreadable.
Sets `drgnx-surfaces--usage-bad' when something was left out."
  (condition-case nil
      (when (file-readable-p file)
        (let ((data (with-temp-buffer
                      (insert-file-contents file)
                      (read (current-buffer)))))
          (if (not (proper-list-p data))
              (setq drgnx-surfaces--usage-bad t data nil)
            (let ((clean (delq nil (mapcar #'drgnx-surfaces--usage-entry data))))
              (unless (equal clean data) (setq drgnx-surfaces--usage-bad t))
              clean))))
    (error (setq drgnx-surfaces--usage-bad t) nil)))

(defun drgnx-surfaces--usage-table ()
  "The counts, read from the file the first time."
  (or drgnx-surfaces--usage
      (let ((h (make-hash-table :test #'eq)))
        (dolist (e (drgnx-surfaces--usage-read (drgnx-shortcuts-usage-file)))
          (puthash (car e) (cdr e) h))
        (setq drgnx-surfaces--usage h))))

(defun drgnx-surfaces-usage-count (id)
  "How many times command ID ran from the palette or a menu, in all."
  (or (car (gethash id (drgnx-surfaces--usage-table))) 0))

(defun drgnx-surfaces-usage-week (id)
  "How many times command ID ran from the palette or a menu in the last 7 days."
  (let ((from (- (time-to-days nil) 6)))
    (apply #'+ 0 (mapcar #'cdr (seq-filter (lambda (d) (>= (car d) from))
                                           (cdr (gethash id (drgnx-surfaces--usage-table))))))))

(defun drgnx-surfaces--usage-arm ()
  "Make sure an idle timer will write the counts, no sooner than the interval after the last write."
  (unless (timerp drgnx-surfaces--usage-timer)
    (let ((wait (if drgnx-surfaces--usage-saved
                    (- drgnx-surfaces--usage-flush-interval (- (float-time) drgnx-surfaces--usage-saved))
                  0)))
      (setq drgnx-surfaces--usage-timer
            (run-with-idle-timer (max 2 wait) nil #'drgnx-surfaces--usage-flush)))))

(defun drgnx-surfaces--count-run (id)
  "Count one run of command ID in memory (no file write; that waits for idle).  A `drgnx-surfaces-run-functions' member."
  (let* ((h (drgnx-surfaces--usage-table)) (e (gethash id h))
         (today (time-to-days nil)) (from (- today 6))
         (days (seq-filter (lambda (d) (>= (car d) from)) (cdr e)))
         (day (assq today days)))
    (if day (setcdr day (1+ (cdr day))) (setq days (append days (list (cons today 1)))))
    (puthash id (cons (1+ (or (car e) 0)) days) h)
    (setq drgnx-surfaces--usage-dirty t)
    (drgnx-surfaces--usage-arm)))

(defun drgnx-surfaces--usage-flush (&optional force)
  "Write the counts if they changed, at most once a minute unless FORCE (exit).  Never prompts or signals."
  (when (and force (timerp drgnx-surfaces--usage-timer)) (cancel-timer drgnx-surfaces--usage-timer))
  (setq drgnx-surfaces--usage-timer nil)
  (when (and drgnx-surfaces--usage-dirty drgnx-surfaces--usage)
    (if (and (not force) drgnx-surfaces--usage-saved
             (< (- (float-time) drgnx-surfaces--usage-saved) drgnx-surfaces--usage-flush-interval))
        (drgnx-surfaces--usage-arm)
      (let ((file (drgnx-shortcuts-usage-file)) (rows nil) (tmp nil))
        (maphash (lambda (id v) (push (cons id v) rows)) drgnx-surfaces--usage)
        (setq drgnx-surfaces--usage-saved (float-time))
        (condition-case nil
            (let ((inhibit-message t) (coding-system-for-write 'utf-8-unix))
              (make-directory (file-name-directory file) t)
              ;; A file with something unreadable in it is kept before it is overwritten.
              (when (and drgnx-surfaces--usage-bad (file-exists-p file))
                (rename-file file (format-time-string (concat file ".bak-%Y%m%d-%H%M%S")) t))
              (setq drgnx-surfaces--usage-bad nil)
              ;; A temp name of its own, so two Emacs sessions never write the same one.
              (setq tmp (make-temp-file (concat file ".")))
              (with-temp-file tmp
                (let ((print-length nil) (print-level nil))
                  (prin1 (sort rows (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))) (current-buffer))
                  (insert "\n")))
              (rename-file tmp file t)
              (setq drgnx-surfaces--usage-dirty nil))
          (error (when (and tmp (file-exists-p tmp)) (ignore-errors (delete-file tmp)))
                 (drgnx-surfaces--usage-arm)))))))

(add-hook 'drgnx-surfaces-run-functions #'drgnx-surfaces--count-run)
(defun drgnx-surfaces--usage-flush-at-exit () (drgnx-surfaces--usage-flush t))
(add-hook 'kill-emacs-hook #'drgnx-surfaces--usage-flush-at-exit)

(defun drgnx-surfaces--item-command (cmd)
  (let ((id (drgnx-cmd-id cmd)))
    (lambda () (interactive) (drgnx-surfaces-run id))))

(defun drgnx-surfaces--showable-p (cmd)
  (and (drgnx-commands-available-p cmd) (not (keymapp (drgnx-cmd-command cmd)))))

;;;; Menu bar

(defconst drgnx-surfaces--builtin-menus
  '(("File" . file) ("Edit" . edit) ("Options" . options) ("Buffers" . buffer) ("Tools" . tools) ("Help" . help-menu))
  "Menu-bar names Emacs already defines, with their menu-bar keys.")

(defun drgnx-surfaces-build-menus ()
  "Put every registry entry with a :menu path into the menu bar (idempotent).  The menu bar is global and keeps
its text while the buffer changes: on a terminal frame its key texts are the F6 forms (right in every buffer),
and they are made for the selected frame's terminal (`drgnx-surfaces--update-menus')."
  (dolist (cmd (drgnx-commands-all))
    (when (and (drgnx-cmd-menu cmd) (drgnx-surfaces--showable-p cmd))
      (let* ((path (drgnx-cmd-menu cmd))
             (builtin (cdr (assoc (car path) drgnx-surfaces--builtin-menus)))
             (item (vector (drgnx-cmd-title cmd) (drgnx-surfaces--item-command cmd)
                           :help (or (drgnx-cmd-doc cmd) "")
                           :keys (drgnx-surfaces-key cmd 'menu))))
        ;; Always the GLOBAL menu bar: easy-menu's nil map means the buffer's local one.
        (if builtin
            (easy-menu-add-item (lookup-key global-map (vector 'menu-bar builtin)) (cdr path) item)
          (easy-menu-add-item (lookup-key global-map [menu-bar]) path item))))))

;;;; Right-click menus

(defvar drgnx-surfaces-contexts nil "Alist CONTEXT → predicate taking the click event.")

(defun drgnx-surfaces-define-context (context predicate)
  (setf (alist-get context drgnx-surfaces-contexts) predicate))

(drgnx-surfaces-define-context 'region (lambda (_) (use-region-p)))
(drgnx-surfaces-define-context 'code (lambda (_) (derived-mode-p 'prog-mode)))
(drgnx-surfaces-define-context 'org (lambda (_) (derived-mode-p 'org-mode)))
(drgnx-surfaces-define-context 'dired (lambda (_) (derived-mode-p 'dired-mode)))

(defun drgnx-surfaces--move-point (click)
  "Move point to CLICK in a text area, as VS Code does — unless it lands inside the region."
  (when-let* ((posn (and (mouse-event-p click) (event-start click)))   ; a key is no click (C-h m runs the filter)
              (pos (and (null (posn-area posn)) (posn-point posn))))
    (unless (and (use-region-p) (<= (region-beginning) pos (region-end)))
      (mouse-set-point click))))

(defun drgnx-surfaces-context-menu (menu click)
  "For `context-menu-functions': add registry entries whose contexts apply at CLICK."
  (drgnx-surfaces--move-point click)
  (let ((active (seq-filter (lambda (ctx) (ignore-errors (funcall (cdr ctx) click))) drgnx-surfaces-contexts))
        (separator nil))
    (dolist (cmd (drgnx-commands-all))
      (when (and (drgnx-surfaces--showable-p cmd)
                 (seq-some (lambda (c) (assq c active)) (drgnx-cmd-context cmd)))
        (let ((binding `(menu-item ,(drgnx-cmd-title cmd) ,(drgnx-surfaces--item-command cmd)
                                   :keys ,(drgnx-surfaces-key cmd) :help ,(or (drgnx-cmd-doc cmd) ""))))
          (if (drgnx-cmd-context-first cmd)
              (define-key menu (vector (drgnx-cmd-id cmd)) binding)
            (unless separator
              (define-key-after menu [drgnx-separator] menu-bar-separator)
              (setq separator t))
            (define-key-after menu (vector (drgnx-cmd-id cmd)) binding)))))
    menu))

;;;; which-key labels

(defvar drgnx-surfaces--which-key-entries nil
  "The `which-key-replacement-alist' entries drgnx added, removed again on the next refresh.")

(defun drgnx-surfaces-apply-which-key ()
  "Label every active global key in which-key with its command's title, replacing the labels of
the previous key setup.  Keys in mode keymaps are not labelled: which-key's keymap-based labels
write into the keymap, which would make an unbound key a prefix (which-key shows the command)."
  (when (require 'which-key nil t)
    (setq which-key-replacement-alist
          (seq-remove (lambda (e) (memq e drgnx-surfaces--which-key-entries)) which-key-replacement-alist)
          drgnx-surfaces--which-key-entries nil)
    (dolist (cmd (drgnx-commands-all))
      (pcase-dolist (`(,key . ,map) (drgnx-cmd-bound cmd))
        (when (eq (cdr (drgnx-commands--keymap-spec map)) 'global-map)
          (let ((before which-key-replacement-alist))
            (which-key-add-key-based-replacements key (drgnx-cmd-title cmd))
            (dolist (e which-key-replacement-alist)
              (unless (memq e before) (push e drgnx-surfaces--which-key-entries)))))))))

;;;; Cheat sheet (F1) and kb markdown

(defun drgnx-surfaces--mouse-path (cmd)
  (string-join
   (delq nil (list (and (drgnx-cmd-menu cmd) (concat "menu: " (string-join (drgnx-cmd-menu cmd) " › ")))
                   (and (drgnx-cmd-context cmd)
                        (concat "right-click: " (mapconcat #'symbol-name (drgnx-cmd-context cmd) ", ")))))
   "; "))

(defun drgnx-surfaces-sheet-rows (&optional here)
  "Rows (CATEGORY KEY TITLE MOUSE DOC) for available entries, sorted by category then title.
Uses registry keys only (no `where-is'), so the output is the same in every Emacs session, unless HERE: then
each KEY is shown as the selected frame's terminal sends it (the F1 sheet)."
  (sort (mapcar (lambda (c) (list (drgnx-cmd-category c) (drgnx-surfaces-key c (not here)) (drgnx-cmd-title c)
                                  (drgnx-surfaces--mouse-path c) (or (drgnx-cmd-doc c) "")))
                (seq-filter #'drgnx-commands-available-p (drgnx-commands-all)))
        (lambda (a b) (or (string< (car a) (car b))
                          (and (string= (car a) (car b)) (string< (nth 2 a) (nth 2 b)))))))

(defun drgnx-surfaces--limited-lines ()
  "Lines for the keys the selected frame's terminal cannot send, each with what to press instead: the key as drgnx
shows it elsewhere, its title, then the Alt+Shift key and the F6 form (or that nothing works, when the terminal has
no fallback layer).  Nil on a graphical frame and on a terminal that sends every key."
  (let ((frame (selected-frame)) lines)
    (dolist (c (seq-filter #'drgnx-commands-available-p (drgnx-commands-all)))
      (when-let* ((key (car (car (drgnx-cmd-bound c))))
                  ((not (ignore-errors (drgnx-tty-frame-sends-p frame key)))))
        (let* ((here (drgnx-surfaces--here key))
               (always (drgnx-surfaces--always key))
               (forms (delete-dups (delq nil (list (and (not (equal here key)) here)
                                                   (and (not (equal always key)) always))))))
          (push (format "  %-24s %-36s %s" key (drgnx-cmd-title c)
                        (if forms
                            (mapconcat #'drgnx-tty-fallback-label forms ", or ")
                          "this terminal cannot send it; use the palette (F1)"))
                lines))))
    (sort lines #'string<)))

(defun drgnx-surfaces-cheatsheet ()
  "Show every drgnx command: key, title and where to click.  The keys are the ones this terminal can send."
  (interactive)
  ;; computed here: the keys depend on the buffer and frame the sheet is asked from, not on the help buffer
  (let ((rows (drgnx-surfaces-sheet-rows t)) (limited (drgnx-surfaces--limited-lines)))
    (with-help-window "*drgnx keys*"
      (with-current-buffer standard-output
        (insert "drgnx keys — every command, its key and where to click.\n")
        (let (cat)
          (dolist (r rows)
            (unless (equal cat (car r))
              (setq cat (car r))
              (insert "\n" (propertize cat 'face 'drgnx-sheet-heading) "\n"))
            (insert (format "  %-24s %-36s %s\n" (nth 1 r) (nth 2 r) (nth 3 r)))))
        (when limited
          (insert "\n" (propertize "Keys this terminal cannot send, and what to press here" 'face 'drgnx-sheet-heading) "\n")
          (dolist (l limited) (insert l "\n")))
        ;; The active key profiles' conflicts and problems (drgnx-keys, docs/guide/keys.md).
        (when (fboundp 'drgnx-keys-conflict-lines)
          (pcase-dolist (`(,title . ,lines) `(("Key conflicts (the later layer won)" . ,(drgnx-keys-conflict-lines))
                                              ("Key problems" . ,(plist-get drgnx-keys-last :problems))))
            (when lines
              (insert "\n" (propertize title 'face 'drgnx-sheet-heading) "\n")
              (dolist (l lines) (insert "  " l "\n")))))))))

(defun drgnx-surfaces--md (s) (replace-regexp-in-string "|" "\\\\|" s))

(defun drgnx-surfaces--md-code (s)
  "S as inline markdown code; a key containing a backtick needs a double-backtick fence."
  (if (string-search "`" s) (format "`` %s ``" s) (format "`%s`" s)))

(defun drgnx-surfaces--md-key (key)
  "KEY as markdown: `C-c y` (in org) — code formatting around the key only."
  (if (string-empty-p key) ""
    (if (string-match "\\`\\(.*?\\) \\((in .*)\\)\\'" key)
        (format "%s %s" (drgnx-surfaces--md-code (match-string 1 key)) (match-string 2 key))
      (drgnx-surfaces--md-code key))))

(defun drgnx-surfaces-markdown ()
  "The kb cheat sheet as a string (deterministic: no timestamps)."
  (with-temp-buffer
    (insert "---\nname: emacs-keys\n"
            "description: Every drgnx command with its key, menu and right-click location — generated from the command registry\n"
            "metadata:\n  type: reference\n  generated: true\n---\n\n"
            "# Emacs keys and commands (generated — do not edit)\n\n"
            "Generated from the drgnx command registry (`drgnx-surfaces-export-markdown`).\n")
    (let (cat)
      (dolist (r (drgnx-surfaces-sheet-rows))
        (unless (equal cat (car r))
          (setq cat (car r))
          (insert (format "\n## %s\n\n| Key | Command | Mouse | What it does |\n|---|---|---|---|\n" cat)))
        (insert (format "| %s | %s | %s | %s |\n"
                        (drgnx-surfaces--md-key (nth 1 r)) (drgnx-surfaces--md (nth 2 r))
                        (drgnx-surfaces--md (nth 3 r)) (drgnx-surfaces--md (nth 4 r))))))
    (buffer-string)))

(defun drgnx-surfaces-export-markdown (file)
  "Write the cheat sheet to FILE; return FILE.  Never prompts (safe for emacsclient).
Writes a temp file and renames it over FILE: writing FILE directly would take Emacs' file lock,
which asks \"changed on disk; really edit?\" when FILE is open in a stale buffer."
  (let ((tmp (make-temp-file (expand-file-name ".emacs-keys-" (file-name-directory file)))))
    (with-temp-file tmp (insert (drgnx-surfaces-markdown)))
    (set-file-modes tmp #o644)
    (rename-file tmp file t))
  file)

;;;; Refresh

(defvar drgnx-surfaces--menu-signature nil
  "What the menu bar's key texts were built for: the selected terminal frame's terminal, its caps and fallback
table (nil on a graphical frame).")

(defun drgnx-surfaces--terminal-signature ()
  (let ((frame (selected-frame)))
    (unless (display-graphic-p frame)
      (let ((term (frame-terminal frame)))
        (list term (terminal-parameter term 'drgnx-tty-caps) (terminal-parameter term 'drgnx-tty-fallback-table))))))

(defun drgnx-surfaces--update-menus ()
  "For `menu-bar-update-hook': the menu bar is global, its key texts are made for one terminal at a time, so
build them again when the selected frame's terminal is another one or its keys changed (kkp came on).  Menus are
per terminal, not per buffer: the texts come from the terminal's own table without the current buffer's maps
(`drgnx-surfaces-key' with `menu'), so a buffer that rebinds an Alt+Shift key never makes a menu lie.
Reads what drgnx already found; asks nothing."
  (condition-case nil
      (let ((sig (drgnx-surfaces--terminal-signature)))
        (unless (equal sig drgnx-surfaces--menu-signature)
          (setq drgnx-surfaces--menu-signature sig)
          (drgnx-surfaces-build-menus)))
    (error nil)))

(defun drgnx-surfaces-refresh ()
  "Regenerate menus and which-key labels and install the context-menu hook (idempotent)."
  (drgnx-surfaces-build-menus)
  (setq drgnx-surfaces--menu-signature (drgnx-surfaces--terminal-signature))
  (add-hook 'menu-bar-update-hook #'drgnx-surfaces--update-menus)
  (drgnx-surfaces-apply-which-key)
  (add-hook 'context-menu-functions #'drgnx-surfaces-context-menu 90)
  ;; Right-click menus need the mode (also in a daemon, whose init has no graphic frame).
  (context-menu-mode 1))

(provide 'drgnx-surfaces)
;;; drgnx-surfaces.el ends here
