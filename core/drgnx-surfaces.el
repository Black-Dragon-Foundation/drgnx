;;; drgnx-surfaces.el --- Everything generated from the command registry -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The registry's outputs: menu bar, right-click menus, which-key labels, the F1 sheet, the
;; markdown cheat sheet, "next time" tips.  Keys are whatever the active key profiles bound
;; (each command's `bound' slot, set by `drgnx-keys').  Ported from the gryphn layer.  See
;; docs/core.md and docs/keys.md.

;;; Code:

(require 'drgnx-registry)
(require 'easymenu)

(defface drgnx-sheet-heading '((t :inherit (bold font-lock-keyword-face)))
  "Category headings in the key sheet (inherits theme faces only)."
  :group 'drgnx)

;;;; Keys and running

(defun drgnx-surfaces-key (cmd)
  "Display string for CMD's first active key, a key in a mode's keymap suffixed with that
keymap; \"\" if none."
  (pcase (car (drgnx-cmd-bound cmd))
    ('nil "")
    (`(,key . ,map)
     (let ((mapsym (cdr (drgnx-commands--keymap-spec map))))
       (if (eq mapsym 'global-map) key
         (format "%s (in %s)" key (string-remove-suffix "-mode-map" (string-remove-suffix "-map" (symbol-name mapsym)))))))))

(defun drgnx-surfaces--any-key (cmd)
  "CMD's active key, else whatever key currently runs its command."
  (or (car (car (drgnx-cmd-bound cmd)))
      (let ((c (drgnx-cmd-command cmd)))
        (when-let* ((k (and (symbolp c) (where-is-internal c nil t)))) (key-description k)))))

(defun drgnx-surfaces-tip (cmd)
  "Echo how CMD could have been run with a key, keeping any message the command printed.
Returns the tip, or nil when CMD has no key."
  (when-let* ((key (drgnx-surfaces--any-key cmd)))
    (let ((prev (current-message))
          (tip (format "%s — next time: %s" (drgnx-commands-label cmd) key)))
      (message "%s" (if (and prev (not (string-empty-p prev))) (concat prev "   ·   " tip) tip))
      tip)))

(defun drgnx-surfaces-run (id)
  "Run registry command ID as if typed, then show the key tip."
  (let* ((cmd (drgnx-commands-get id)) (c (drgnx-cmd-command cmd)))
    (setq this-command c)
    (call-interactively c t)
    (drgnx-surfaces-tip cmd)))

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
  "Put every registry entry with a :menu path into the menu bar (idempotent)."
  (dolist (cmd (drgnx-commands-all))
    (when (and (drgnx-cmd-menu cmd) (drgnx-surfaces--showable-p cmd))
      (let* ((path (drgnx-cmd-menu cmd))
             (builtin (cdr (assoc (car path) drgnx-surfaces--builtin-menus)))
             (item (vector (drgnx-cmd-title cmd) (drgnx-surfaces--item-command cmd)
                           :help (or (drgnx-cmd-doc cmd) "")
                           :keys (drgnx-surfaces-key cmd))))
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
  (when-let* ((posn (and click (event-start click)))
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

(defun drgnx-surfaces-apply-which-key ()
  "Label every active key in which-key with its command's title."
  (when (require 'which-key nil t)
    (dolist (cmd (drgnx-commands-all))
      (pcase-dolist (`(,key . ,map) (drgnx-cmd-bound cmd))
        (pcase-let ((`(,feature . ,mapsym) (drgnx-commands--keymap-spec map)))
          (if (eq mapsym 'global-map)
              (which-key-add-key-based-replacements key (drgnx-cmd-title cmd))
            (let ((label (lambda () (which-key-add-keymap-based-replacements
                                     (symbol-value mapsym) key (drgnx-cmd-title cmd)))))
              (if feature (with-eval-after-load feature (funcall label)) (funcall label)))))))))

;;;; Cheat sheet (F1) and kb markdown

(defun drgnx-surfaces--mouse-path (cmd)
  (string-join
   (delq nil (list (and (drgnx-cmd-menu cmd) (concat "menu: " (string-join (drgnx-cmd-menu cmd) " › ")))
                   (and (drgnx-cmd-context cmd)
                        (concat "right-click: " (mapconcat #'symbol-name (drgnx-cmd-context cmd) ", ")))))
   "; "))

(defun drgnx-surfaces-sheet-rows ()
  "Rows (CATEGORY KEY TITLE MOUSE DOC) for available entries, sorted by category then title.
Uses registry keys only (no `where-is'), so the output is the same in every Emacs session."
  (sort (mapcar (lambda (c) (list (drgnx-cmd-category c) (drgnx-surfaces-key c) (drgnx-cmd-title c)
                                  (drgnx-surfaces--mouse-path c) (or (drgnx-cmd-doc c) "")))
                (seq-filter #'drgnx-commands-available-p (drgnx-commands-all)))
        (lambda (a b) (or (string< (car a) (car b))
                          (and (string= (car a) (car b)) (string< (nth 2 a) (nth 2 b)))))))

(defun drgnx-surfaces-cheatsheet ()
  "Show every drgnx command: key, title and where to click."
  (interactive)
  (with-help-window "*drgnx keys*"
    (with-current-buffer standard-output
      (insert "drgnx keys — every command, its key and where to click.\n")
      (let (cat)
        (dolist (r (drgnx-surfaces-sheet-rows))
          (unless (equal cat (car r))
            (setq cat (car r))
            (insert "\n" (propertize cat 'face 'drgnx-sheet-heading) "\n"))
          (insert (format "  %-24s %-36s %s\n" (nth 1 r) (nth 2 r) (nth 3 r)))))
      ;; The active key profiles' conflicts and problems (drgnx-keys, docs/keys.md).
      (when (fboundp 'drgnx-keys-conflict-lines)
        (pcase-dolist (`(,title . ,lines) `(("Key conflicts (the later layer won)" . ,(drgnx-keys-conflict-lines))
                                            ("Key problems" . ,(plist-get drgnx-keys-last :problems))))
          (when lines
            (insert "\n" (propertize title 'face 'drgnx-sheet-heading) "\n")
            (dolist (l lines) (insert "  " l "\n"))))))))

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

(defun drgnx-surfaces-refresh ()
  "Regenerate menus and which-key labels and install the context-menu hook (idempotent)."
  (drgnx-surfaces-build-menus)
  (drgnx-surfaces-apply-which-key)
  (add-hook 'context-menu-functions #'drgnx-surfaces-context-menu 90)
  ;; Right-click menus need the mode (also in a daemon, whose init has no graphic frame).
  (context-menu-mode 1))

(provide 'drgnx-surfaces)
;;; drgnx-surfaces.el ends here
