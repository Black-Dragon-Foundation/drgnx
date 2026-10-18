;;; drgnx-shortcuts.el --- Module tools/shortcuts: the Keyboard Shortcuts editor -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Preferences: Keyboard Shortcuts, as in VS Code: one row per registry command with its keys, where they come
;; from (the profile, your keys.eld, or a package) and where they work (global, or a view's keymap).  RET on a row
;; records new keys — a key, or a two-key chord such as C-k C-o — and a key taken in the same place asks Replace
;; or Keep both.  Filters: a text filter on title and category, a recorded key, Conflicts, No key and Changed by
;; me.  The header switches the key profile; a line suggests a key for a command you run often from the palette.
;; Every change goes through `drgnx-keys-edit' (keys.eld, comments kept) and applies at once; Undo takes back the
;; last one.  See docs/guide/shortcuts.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-keys)
(require 'drgnx-keys-edit)
(require 'drgnx-tty-fallback)

(defcustom drgnx-shortcuts-chord-wait 1.0
  "Seconds to wait, after the first key recorded, for the second key of a chord."
  :type 'number :group 'drgnx)

(defconst drgnx-shortcuts-suggest-runs 10
  "A command run this often from the palette in the last 7 days, without a key, is suggested for one.")

(defface drgnx-shortcuts-heading '((t :inherit bold)) "The column titles and the profile line." :group 'drgnx)
(defface drgnx-shortcuts-dim '((t :inherit shadow)) "Sources, places, hints and toggles that are off." :group 'drgnx)
(defface drgnx-shortcuts-key '((t :inherit help-key-binding)) "A key." :group 'drgnx)
(defface drgnx-shortcuts-on '((t :inherit (bold link))) "A filter that is on." :group 'drgnx)
(defface drgnx-shortcuts-conflict '((t :inherit error)) "The mark of a row in a key conflict." :group 'drgnx)
(defface drgnx-shortcuts-warning '((t :inherit warning)) "The terminal mark and the suggestion." :group 'drgnx)

(defconst drgnx-shortcuts--buffer "*drgnx keyboard shortcuts*")

(defvar-local drgnx-shortcuts--filter nil "The text filter (title or category), or nil.")
(defvar-local drgnx-shortcuts--keys-filter nil "The recorded key the rows are filtered by, or nil.")
(defvar-local drgnx-shortcuts--only nil "The filters that are on: `conflicts', `no-key', `changed'.")

;;;; Keys: where, source, the terminal

(defun drgnx-shortcuts--mapsym (spec) (cdr (drgnx-commands--keymap-spec spec)))

(defun drgnx-shortcuts--where (spec)
  "Where a key in keymap SPEC works: \"global\", or the name of the view or mode the keymap belongs to."
  (pcase (drgnx-shortcuts--mapsym spec)
    ('global-map "global")
    ('evil-normal-state-map "normal state")
    (m (replace-regexp-in-string "-\\(?:mode-\\|keys-\\)?map\\'" "" (string-remove-prefix "drgnx-" (symbol-name m))))))

(defun drgnx-shortcuts--source (layer)
  "The source of a key from resolution LAYER: keys.eld, or the profile's name."
  (if (eq layer 'user) "keys.eld"
    (or (plist-get (alist-get layer drgnx-keys-profiles) :name) (symbol-name layer))))

(defun drgnx-shortcuts--tty-caps ()
  "What drgnx found about the selected frame's terminal when it opened, or nil on a graphical frame and on a
terminal not set up (nothing is asked of it here)."
  (let ((frame (selected-frame)))
    (and (not (display-graphic-p frame)) (terminal-parameter (frame-terminal frame) 'drgnx-tty-caps))))

(defun drgnx-shortcuts-terminal-p (key)
  "Non-nil if a terminal can send KEY.  On a terminal frame, this terminal (what it can do: kitty keyboard
protocol, modifyOtherKeys or neither, `drgnx-tty-frame-sends-p'); elsewhere a terminal without the kitty keyboard
protocol: not with Super, Hyper or Alt, C-S- on a character, or C- on a character other than a letter, @ [ \\ ] ^
_ ? or space."
  (if (drgnx-shortcuts--tty-caps)
      (drgnx-tty-frame-sends-p (selected-frame) key)
    (seq-every-p (lambda (ev)
                   (let ((mods (event-modifiers ev)) (base (event-basic-type ev)))
                     (not (or (seq-intersection mods '(super hyper alt))
                              (and (memq 'control mods) (characterp base)
                                   (or (memq 'shift mods)
                                       (not (or (<= ?a base ?z) (memq base '(?@ ?\[ ?\\ ?\] ?^ ?_ ?? ?\s))))))))))
                 (key-parse key))))

(defun drgnx-shortcuts--terminal-note (key)
  "The hover text of KEY's terminal mark: that a terminal cannot send it and, on a terminal frame, what to press
here (`drgnx-tty-sendable-key': the Alt+Shift key, or F6 then the key), or that this terminal has no fallback."
  (concat "A terminal cannot send this key (a graphical frame can)"
          (when (drgnx-shortcuts--tty-caps)
            (let ((here (drgnx-tty-sendable-key (selected-frame) key)))
              (if (equal here key)
                  "; no fallback is on in this terminal"
                (format "; here: %s" (drgnx-tty-fallback-label here)))))))

(defun drgnx-shortcuts--starts-with-p (key prefix)
  "Non-nil if KEY is PREFIX or starts with it (keys compared parsed)."
  (let ((k (key-parse key)) (p (key-parse prefix)))
    (and (>= (length k) (length p)) (equal p (seq-take k (length p))))))

;;;; Rows

(defun drgnx-shortcuts--native-keys (cmd)
  "Keys that run CMD's command without drgnx binding it (Emacs' or a package's), as (KEY . MAP-SPEC)."
  (let ((c (drgnx-cmd-command cmd)) (spec (drgnx-cmd-map cmd)))
    (when (and c (symbolp c))
      (let ((maps (delq nil (list global-map (let ((m (drgnx-shortcuts--mapsym spec)))
                                               (and spec (boundp m) (keymapp (symbol-value m)) (symbol-value m)))))))
        (cl-loop for k in (where-is-internal c maps)
                 unless (seq-some (lambda (e) (and (symbolp e) (string-match-p "menu-bar\\|tool-bar\\|tab-bar\\|remap\\|mouse\\|wheel"
                                                                               (symbol-name e))))
                                  k)
                 collect (cons (key-description k) (if (eq (lookup-key global-map k) c) nil spec)))))))

(defun drgnx-shortcuts--over-default-p (conflict)
  "Non-nil if CONFLICT is a profile's key over an Emacs default no active layer claims: no conflict on the page
(the profile chose it; there is nothing to replace).  keys.eld keys and layers' claims stay conflicts."
  (and (not (eq (plist-get (plist-get conflict :winner) :layer) 'user))
       (plist-get (plist-get conflict :winner) :id)
       (seq-every-p (lambda (l) (not (or (plist-get l :id) (plist-get l :layer)))) (plist-get conflict :losers))))

(defun drgnx-shortcuts--under-profile-prefix-p (conflict all)
  "Non-nil if CONFLICT is a keys.eld key under a prefix the active profile already took from the same Emacs default
\(VS Code's C-k over kill-line, then C-k C-9 of yours): it takes nothing more, so no conflict on the page.  ALL: every
conflict of the resolution."
  (and (eq (plist-get conflict :kind) 'prefix)
       (eq (plist-get (plist-get conflict :winner) :layer) 'user)
       (seq-every-p (lambda (l) (not (or (plist-get l :id) (plist-get l :layer)))) (plist-get conflict :losers))
       (seq-some (lambda (c) (and (not (eq c conflict)) (drgnx-shortcuts--over-default-p c)
                                  (equal (plist-get c :losers) (plist-get conflict :losers))
                                  (equal (plist-get c :map) (plist-get conflict :map))))
                 all)))

(defun drgnx-shortcuts--rows ()
  "One plist per registry command: :id :cmd :title :category :keys ((KEY . MAP-SPEC)…) :native :source :where
:conflicts (TEXT…) :over (the Emacs defaults its profile keys shadow) :changed."
  (let* ((by-id (make-hash-table :test #'eq)) (conflicts (make-hash-table :test #'eq)) (over (make-hash-table :test #'eq))
         (user (drgnx-keys-read-user))
         (changed (append (mapcar #'car-safe (plist-get user :bind)) (plist-get user :unbind))))
    (dolist (b (plist-get drgnx-keys-last :bindings)) (push b (gethash (plist-get b :id) by-id)))
    (dolist (c (plist-get drgnx-keys-last :conflicts))
      (if (or (drgnx-shortcuts--over-default-p c)
              (drgnx-shortcuts--under-profile-prefix-p c (plist-get drgnx-keys-last :conflicts)))
          (dolist (l (plist-get c :losers))
            (cl-pushnew (plist-get l :claim) (gethash (plist-get (plist-get c :winner) :id) over) :test #'equal))
        (dolist (p (cons (plist-get c :winner) (plist-get c :losers)))
          (when-let* ((id (plist-get p :id)))
            (cl-pushnew (drgnx-keys-conflict-text c) (gethash id conflicts) :test #'equal)))))
    (mapcar (lambda (cmd)
              (let* ((id (drgnx-cmd-id cmd)) (bs (reverse (gethash id by-id)))
                     (native (and (null bs) (not (memq id changed)) (drgnx-shortcuts--native-keys cmd)))
                     (keys (if bs (mapcar (lambda (b) (cons (plist-get b :key) (plist-get b :map))) bs) native)))
                (list :id id :cmd cmd :title (drgnx-cmd-title cmd) :category (drgnx-cmd-category cmd)
                      :keys keys :native (and native t)
                      :source (cond (bs (drgnx-shortcuts--source (plist-get (car bs) :layer)))
                                    ((memq id changed) "keys.eld")
                                    (native "package")
                                    (t ""))
                      :where (string-join (delete-dups (mapcar (lambda (k) (drgnx-shortcuts--where (cdr k))) keys)) ", ")
                      :conflicts (reverse (gethash id conflicts)) :over (reverse (gethash id over))
                      :changed (and (memq id changed) t))))
            (drgnx-commands-all))))

(defun drgnx-shortcuts--shown-p (row)
  "Non-nil if ROW passes this buffer's filters."
  (let ((case-fold-search t))
    (and (or (null drgnx-shortcuts--filter)
             (string-match-p (regexp-quote drgnx-shortcuts--filter)
                             (format "%s: %s" (plist-get row :category) (plist-get row :title))))
         (or (null drgnx-shortcuts--keys-filter)
             (seq-some (lambda (k) (drgnx-shortcuts--starts-with-p (car k) drgnx-shortcuts--keys-filter))
                       (plist-get row :keys)))
         (or (not (memq 'conflicts drgnx-shortcuts--only)) (plist-get row :conflicts))
         (or (not (memq 'no-key drgnx-shortcuts--only)) (null (plist-get row :keys)))
         (or (not (memq 'changed drgnx-shortcuts--only)) (plist-get row :changed)))))

(defun drgnx-shortcuts--suggestion (rows)
  "(ROW . N): the keyless command run most this week from the palette, N ≥ `drgnx-shortcuts-suggest-runs' times."
  (let (best (most 0))
    (dolist (r rows)
      (unless (plist-get r :keys)
        (let ((n (drgnx-surfaces-usage-week (plist-get r :id))))
          (when (and (>= n drgnx-shortcuts-suggest-runs) (> n most)) (setq best r most n)))))
    (and best (cons best most))))

;;;; Drawing

(defun drgnx-shortcuts--profile-text ()
  "The key profile stack: a preset's name, or each layer's profile and scopes."
  (let ((layers (plist-get drgnx-keys-last :layers)))
    (or (car (rassoc layers drgnx-keys-presets))
        (mapconcat (lambda (l) (format "%s (%s)" (drgnx-shortcuts--source (car l)) (mapconcat #'symbol-name (cdr l) " ")))
                   layers " + "))))

(defun drgnx-shortcuts--button (label action &rest props)
  (apply #'insert-text-button label 'action (lambda (_) (funcall action)) 'follow-link t props))

(defun drgnx-shortcuts--toggle-text (flag label)
  (propertize (format "[%s] %s" (if (memq flag drgnx-shortcuts--only) "x" " ") label)
              'face (if (memq flag drgnx-shortcuts--only) 'drgnx-shortcuts-on 'drgnx-shortcuts-dim)))

(defun drgnx-shortcuts--keys-text (keys)
  (mapconcat (lambda (k) (concat (propertize (car k) 'face 'drgnx-shortcuts-key)
                                 (unless (drgnx-shortcuts-terminal-p (car k))
                                   (propertize "†" 'face 'drgnx-shortcuts-warning
                                               'help-echo (drgnx-shortcuts--terminal-note (car k))))))
             keys ", "))

(defun drgnx-shortcuts--pad (s width)
  "S cut or padded to WIDTH columns, its text properties kept."
  (let ((s (truncate-string-to-width s width nil nil "…")))
    (concat s (make-string (max 0 (- width (string-width s))) ?\s))))

(defun drgnx-shortcuts--insert-row (row)
  (let ((start (point)) (conflicts (plist-get row :conflicts)))
    (insert (if conflicts (propertize "!" 'face 'drgnx-shortcuts-conflict 'help-echo (string-join conflicts "\n")) " ")
            " " (drgnx-shortcuts--pad (format "%s: %s" (plist-get row :category) (plist-get row :title)) 46)
            " " (drgnx-shortcuts--pad (drgnx-shortcuts--keys-text (plist-get row :keys)) 26)
            " " (propertize (drgnx-shortcuts--pad (plist-get row :source) 12) 'face 'drgnx-shortcuts-dim)
            " " (apply #'propertize (plist-get row :where) 'face 'drgnx-shortcuts-dim
                       (and (plist-get row :over)
                            (list 'help-echo (concat "Over Emacs' " (string-join (plist-get row :over) ", "))))))
    (put-text-property start (point) 'drgnx-shortcuts-id (plist-get row :id))
    (insert "\n")))

(defun drgnx-shortcuts--draw ()
  "Draw the editor in the current buffer, keeping point on the row it was on."
  (let* ((inhibit-read-only t) (id (get-text-property (point) 'drgnx-shortcuts-id))
         (line (line-number-at-pos)) (rows (drgnx-shortcuts--rows)) (suggest (drgnx-shortcuts--suggestion rows)))
    (erase-buffer)
    (insert (propertize "Keyboard Shortcuts" 'face 'drgnx-shortcuts-heading) " — keys: "
            (propertize (drgnx-shortcuts--profile-text) 'face 'drgnx-shortcuts-heading) "  ")
    (drgnx-shortcuts--button "[Switch Profile…]" #'drgnx-shortcuts-switch-profile
                             'help-echo "VS Code, Emacs or Vim keys, or a combination; applies at once")
    (insert "\n")
    (when suggest
      (insert (propertize (format "You ran %s %d times from the palette this week; give it a key? "
                                  (drgnx-commands-label (plist-get (car suggest) :cmd)) (cdr suggest))
                          'face 'drgnx-shortcuts-warning))
      (let ((sid (plist-get (car suggest) :id)))
        (drgnx-shortcuts--button "[Record a Key]" (lambda () (drgnx-shortcuts--record sid 'change))
                                 'drgnx-shortcuts-suggest sid))
      (insert "\n"))
    (dolist (p (seq-filter (lambda (p) (string-search "keys.eld" p)) (plist-get drgnx-keys-last :problems)))
      (insert (propertize p 'face 'drgnx-shortcuts-conflict) "\n"))
    (insert "Filter: " (if drgnx-shortcuts--filter (format "\"%s\"" drgnx-shortcuts--filter) "—")
            "   Keys: " (or drgnx-shortcuts--keys-filter "—") "   "
            (drgnx-shortcuts--toggle-text 'conflicts "Conflicts") "  "
            (drgnx-shortcuts--toggle-text 'no-key "No key") "  "
            (drgnx-shortcuts--toggle-text 'changed "Changed by me") "\n"
            (propertize "! a key conflict (hover for which)   † a terminal cannot send this key (hover: what to press here)\n\n"
                        'face 'drgnx-shortcuts-dim)
            (propertize (format "  %s %s %s %s\n" (drgnx-shortcuts--pad "Command" 46) (drgnx-shortcuts--pad "Keys" 26)
                                (drgnx-shortcuts--pad "Source" 12) "Where")
                        'face 'drgnx-shortcuts-heading))
    (let ((shown (seq-filter #'drgnx-shortcuts--shown-p rows)))
      (mapc #'drgnx-shortcuts--insert-row shown)
      (unless shown (insert (propertize "  No command matches the filters.\n" 'face 'drgnx-shortcuts-dim))))
    (goto-char (point-min))
    (if-let* ((m (and id (text-property-search-forward 'drgnx-shortcuts-id id #'eq))))
        (goto-char (prop-match-beginning m))
      (forward-line (1- line)))))

(defun drgnx-shortcuts--redraw ()
  (when-let* ((b (get-buffer drgnx-shortcuts--buffer)))
    (with-current-buffer b (drgnx-shortcuts--draw))))

(define-derived-mode drgnx-shortcuts-mode special-mode "Keyboard Shortcuts"
  "Every drgnx command with its keys: change, add and reset them, filter, see conflicts (docs/guide/shortcuts.md)."
  (setq truncate-lines t)
  (setq-local revert-buffer-function (lambda (&rest _) (drgnx-shortcuts--draw))))

(declare-function evil-set-initial-state "evil-core")
(declare-function evil-initial-state "evil-core")
(defun drgnx-shortcuts--evil-state ()
  "The view's own letters, also in the Vim profile: it starts in Emacs state (the setup runs this once evil loads).
The undo puts the earlier state back, only while it is still Emacs state."
  (when (fboundp 'evil-set-initial-state)
    (let ((old (evil-initial-state 'drgnx-shortcuts-mode)))
      (evil-set-initial-state 'drgnx-shortcuts-mode 'emacs)
      (drgnx-modules-push-undo "evil state drgnx-shortcuts-mode"
                               (lambda ()
                                 (when (eq (evil-initial-state 'drgnx-shortcuts-mode) 'emacs)
                                   (evil-set-initial-state 'drgnx-shortcuts-mode old)))))))

;;;; Recording

(defun drgnx-shortcuts--cancel-p (key) (memq key '(?\C-g 27)))

(defun drgnx-shortcuts-read-keys (prompt)
  "Read a key, or a two-key chord: after the first key, wait `drgnx-shortcuts-chord-wait' seconds for a second.
C-g or ESC cancels: nil.  Only for commands the user runs."
  (let* ((inhibit-quit t) (first (read-key prompt)))
    (unless (drgnx-shortcuts--cancel-p first)
      (let* ((one (key-description (vector first)))
             (ev (read-event (format "%s%s …" prompt one) nil drgnx-shortcuts-chord-wait)))
        (if (null ev)
            one
          (push ev unread-command-events)
          (let ((second (read-key)))
            (unless (drgnx-shortcuts--cancel-p second) (key-description (vector first second)))))))))

(defun drgnx-shortcuts--row (id)
  (or (seq-find (lambda (r) (eq (plist-get r :id) id)) (drgnx-shortcuts--rows))
      (user-error "No command %s" id)))

(defun drgnx-shortcuts--id-at-point ()
  (or (get-text-property (point) 'drgnx-shortcuts-id) (user-error "No command on this line")))

(defun drgnx-shortcuts--default-map (cmd)
  "Where a new key for CMD goes: its own keymap, else the keymap of the profile that keys its scope, else global."
  (or (drgnx-cmd-map cmd)
      (let (profile)
        (dolist (l (plist-get drgnx-keys-last :layers))
          (when (memq (drgnx-cmd-scope cmd) (cdr l)) (setq profile (car l))))
        (and profile (plist-get (alist-get profile drgnx-keys-profiles) :map)))))

(defun drgnx-shortcuts--clashes (id key map)
  "What KEY in keymap MAP (a spec) runs into, besides command ID: drgnx keys there that are KEY or a prefix of it
or start with it, else Emacs' or a package's binding there.  A list of (:kind same-key|prefix :id ID :key K :map M)
or (:kind same-key|prefix :native DESCRIPTION)."
  (let* ((mapsym (drgnx-shortcuts--mapsym map)) (v (key-parse key)) out)
    (dolist (b (plist-get drgnx-keys-last :bindings))
      (when (and (not (eq (plist-get b :id) id)) (eq (drgnx-shortcuts--mapsym (plist-get b :map)) mapsym))
        (let ((k (plist-get b :key)))
          (cond ((equal v (key-parse k)) (push (list :kind 'same-key :id (plist-get b :id) :key k :map (plist-get b :map)) out))
                ((or (drgnx-shortcuts--starts-with-p k key) (drgnx-shortcuts--starts-with-p key k))
                 (push (list :kind 'prefix :id (plist-get b :id) :key k :map (plist-get b :map)) out))))))
    (unless out
      (when-let* ((m (and (boundp mapsym) (keymapp (symbol-value mapsym)) (symbol-value mapsym)))
                  (def (ignore-errors (keymap-lookup m key nil t))))
        (cond ((keymapp def) (push (list :kind 'prefix :native (format "the %s prefix" key)) out))
              ((numberp def)
               (let ((p (key-description (seq-take v def))))
                 (push (list :kind 'prefix :native (format "%s (%s)" (keymap-lookup m p nil t) p)) out)))
              ((and (symbolp def) (commandp def) (not (memq def '(self-insert-command undefined ignore)))
                    (not (eq def (drgnx-cmd-command (drgnx-commands-get id)))))
               (push (list :kind 'same-key :native (symbol-name def)) out)))))
    (nreverse out)))

(defun drgnx-shortcuts--clash-text (c)
  (let ((who (if-let* ((id (plist-get c :id)))
                 (format "%s (%s)" (drgnx-cmd-title (drgnx-commands-get id)) (plist-get c :key))
               (format "%s (Emacs or a package)" (plist-get c :native)))))
    (if (eq (plist-get c :kind) 'prefix) (format "%s — a prefix clash" who) (format "taken by %s" who))))

(defun drgnx-shortcuts--settle (id key map)
  "Ask what to do when KEY in MAP is taken: Replace (take it from the drgnx commands that have it), Keep both, or
Cancel.  Non-nil to go on."
  (let ((clashes (drgnx-shortcuts--clashes id key map)))
    (or (null clashes)
        (pcase (car (read-multiple-choice
                     (format "%s in %s: %s. " key (drgnx-shortcuts--where map)
                             (mapconcat #'drgnx-shortcuts--clash-text clashes "; "))
                     '((?r "replace" "Take the key from the other commands")
                       (?k "keep both" "Keep their keys too; the conflict is listed")
                       (?c "cancel" "Change nothing"))))
          (?r (dolist (c clashes)
                (when (plist-get c :id) (drgnx-keys-edit-unbind (plist-get c :id) (plist-get c :key) (plist-get c :map))))
              t)
          (?k t)
          (_ nil)))))

(defun drgnx-shortcuts--check-typing (key map)
  "Refuse KEY in the global keymap when it starts with a character typed as is or with Shift, RET or TAB: typing
it would run the command.  Refuse C-x, C-c, C-h and ESC alone there: every key that starts with them would go."
  (let* ((v (key-parse key)) (e (aref v 0)))
    (when (eq (drgnx-shortcuts--mapsym map) 'global-map)
      (when (and (characterp e) (or (memq e '(?\r ?\t)) (null (remq 'shift (event-modifiers e)))))
        (user-error "%s would stop you typing %s; use a modifier (C-, M-) or a chord that starts with one"
                    key (key-description (vector e))))
      (when (member v '([?\C-x] [?\C-c] [?\C-h] [27]))
        (user-error "%s alone would take every key that starts with it; record a chord such as %s k" key key)))))

(defun drgnx-shortcuts--record (id mode)
  "Record keys for command ID.  MODE `change' puts them in place of the row's key (a key of your choice when it
has several), or gives them to a command without keys; `add' adds them to its keys."
  (let* ((row (drgnx-shortcuts--row id)) (cmd (plist-get row :cmd))
         (own (and (not (plist-get row :native)) (plist-get row :keys)))
         (old (and own (eq mode 'change)
                   (if (cdr own)
                       (assoc (completing-read "Change which key: " (mapcar #'car own) nil t) own)
                     (car own))))
         (map (cond (old (cdr old)) (own (cdr (car own))) (t (drgnx-shortcuts--default-map cmd))))
         (key (drgnx-shortcuts-read-keys
               (format "Keys for %s (C-g cancels): " (drgnx-commands-label cmd)))))
    (cond ((null key) (message "Keyboard Shortcuts: nothing recorded"))
          ((seq-some (lambda (k) (equal (key-parse (car k)) (key-parse key))) own)
           (message "%s already has %s" (drgnx-commands-label cmd) key))
          (t
           (drgnx-shortcuts--check-typing key map)
           (drgnx-keys-edit-one-step      ; a Replace and the new key: one Undo
             (when (drgnx-shortcuts--settle id key map)
               (cond (old (drgnx-keys-edit-replace id (car old) key map))
                     ((and own (eq mode 'add)) (drgnx-keys-edit-add id key map))
                     (t (drgnx-keys-edit-bind id key map)))
               (message "%s: %s (%s)" (drgnx-commands-label cmd) key (drgnx-shortcuts--where map))))))
    (drgnx-shortcuts--redraw)))

;;;; Commands

(defun drgnx-shortcuts ()
  "Preferences: Keyboard Shortcuts — every command, its keys, where they come from and where they work."
  (interactive)
  (let ((b (get-buffer-create drgnx-shortcuts--buffer)))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-shortcuts-mode) (drgnx-shortcuts-mode))
      (drgnx-shortcuts--draw))
    (when (called-interactively-p 'any) (pop-to-buffer b))
    b))

(defun drgnx-shortcuts-change ()
  "Record new keys for the command on this line, in place of its key (C-g cancels)."
  (interactive)
  (drgnx-shortcuts--record (drgnx-shortcuts--id-at-point) 'change))

(defun drgnx-shortcuts-add ()
  "Record one more key for the command on this line, keeping its keys (C-g cancels)."
  (interactive)
  (drgnx-shortcuts--record (drgnx-shortcuts--id-at-point) 'add))

(defun drgnx-shortcuts-filter (text)
  "Show the commands whose title or category contains TEXT (empty: all); the list follows as you type."
  (interactive (list (drgnx-shortcuts--read-filter (current-buffer))))
  (setq drgnx-shortcuts--filter (and (not (string-empty-p text)) text))
  (drgnx-shortcuts--draw))

(defun drgnx-shortcuts--read-filter (buf)
  "Read the text filter, redrawing BUF at each change; C-g puts back the filter it had."
  (let ((old (buffer-local-value 'drgnx-shortcuts--filter buf)))
    (cl-flet ((show (text)
                (with-current-buffer buf
                  (setq drgnx-shortcuts--filter (and (not (string-empty-p text)) text))
                  (drgnx-shortcuts--draw)
                  (when-let* ((w (get-buffer-window buf))) (set-window-point w (point))))))
      (condition-case nil
          (minibuffer-with-setup-hook
              (lambda ()
                (add-hook 'after-change-functions
                          (lambda (&rest _) (show (minibuffer-contents-no-properties))) nil t))
            (read-string "Filter by title or category: " old))
        (quit (show (or old "")) (signal 'quit nil))))))

(defun drgnx-shortcuts-record-filter ()
  "Filter by keys: press a key or a chord to see the commands it, or keys starting with it, run.  Again: off."
  (interactive)
  (setq drgnx-shortcuts--keys-filter
        (and (null drgnx-shortcuts--keys-filter) (drgnx-shortcuts-read-keys "Press the keys to filter by: ")))
  (drgnx-shortcuts--draw))

(defun drgnx-shortcuts--toggle (flag)
  (setq drgnx-shortcuts--only (if (memq flag drgnx-shortcuts--only) (delq flag drgnx-shortcuts--only)
                                (cons flag drgnx-shortcuts--only)))
  (drgnx-shortcuts--draw))

(defun drgnx-shortcuts-toggle-conflicts () "Show only commands in a key conflict, or all." (interactive)
       (drgnx-shortcuts--toggle 'conflicts))
(defun drgnx-shortcuts-toggle-no-key () "Show only commands without a key, or all." (interactive)
       (drgnx-shortcuts--toggle 'no-key))
(defun drgnx-shortcuts-toggle-changed () "Show only commands you changed in keys.eld, or all." (interactive)
       (drgnx-shortcuts--toggle 'changed))

(defun drgnx-shortcuts-set-tty-fallback ()
  "Choose the Alt+Shift key a terminal that cannot send this command's key sends instead (keys.eld :tty-fallback)."
  (interactive)
  (let* ((row (drgnx-shortcuts--row (drgnx-shortcuts--id-at-point)))
         (chords (seq-uniq (mapcan (lambda (k) (unless (drgnx-shortcuts-terminal-p (car k)) (drgnx-tty-fallback-chords (list (car k)))))
                                   (plist-get row :keys))
                           #'equal)))
    (unless chords (user-error "%s: nothing to set; a terminal sends all its keys" (plist-get row :title)))
    (let* ((chord (if (cdr chords) (completing-read "Terminal fallback for which key: " chords nil t) (car chords)))
           (key (string-trim (read-string (format "Alt+Shift key for %s in a terminal that cannot send it (such as M-Z): " chord)))))
      (when (string-empty-p key) (user-error "No key given; nothing changed"))
      (drgnx-keys-edit-set-tty-fallback chord key)
      (message "%s: %s is %s in a terminal that cannot send it" (plist-get row :title) chord (drgnx-tty-fallback-label key))
      (drgnx-shortcuts--redraw))))

(defun drgnx-shortcuts-undo ()
  "Take back the last change to keys.eld."
  (interactive)
  (unwind-protect (drgnx-keys-edit-undo) (drgnx-shortcuts--redraw)))

(defun drgnx-shortcuts-reset ()
  "Give the command on this line its profile's keys again."
  (interactive)
  (drgnx-keys-edit-reset (drgnx-shortcuts--id-at-point))
  (drgnx-shortcuts--redraw))

(defun drgnx-shortcuts-reset-all ()
  "After a confirmation, give every command its profile's keys again (keys.eld keeps its profile and comments)."
  (interactive)
  (when (yes-or-no-p "Reset every key you changed to the profile's keys? ")
    (drgnx-keys-edit-reset-all)
    (drgnx-shortcuts--redraw)))

(defun drgnx-shortcuts-switch-profile ()
  "Switch the key profile — VS Code, Emacs, Vim or a combination — now, and keep it in keys.eld."
  (interactive)
  (let ((name (completing-read "Keyboard profile: " drgnx-keys-presets nil t nil nil
                               (car (rassoc (plist-get drgnx-keys-last :layers) drgnx-keys-presets)))))
    (unless (assoc name drgnx-keys-presets) (user-error "No key profile chosen; nothing changed"))
    (drgnx-keys-use (cdr (assoc name drgnx-keys-presets)) t)
    (drgnx-shortcuts--redraw)))

(defun drgnx-shortcuts--define-commands ()
  (drgnx-command-define 'keyboard-shortcuts :category "Preferences" :title "Keyboard Shortcuts"
                        :command #'drgnx-shortcuts :menu '("Options")
                        :doc "Every command with its keys: change, add, reset; filters, conflicts, the profile")
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((shortcuts-change "Change Keybinding" drgnx-shortcuts-change "Record new keys for this command")
                   (shortcuts-add "Add Keybinding" drgnx-shortcuts-add "Record one more key for this command")
                   (shortcuts-filter "Filter…" drgnx-shortcuts-filter "Commands whose title or category has some text")
                   (shortcuts-record-filter "Record Keys (Filter)" drgnx-shortcuts-record-filter
                                            "Commands on the keys you press; again to stop")
                   (shortcuts-conflicts "Show Conflicts" drgnx-shortcuts-toggle-conflicts "Only commands in a key conflict")
                   (shortcuts-no-key "Show Commands Without a Key" drgnx-shortcuts-toggle-no-key "Only commands without a key")
                   (shortcuts-changed "Show Changed by Me" drgnx-shortcuts-toggle-changed "Only commands your keys.eld changes")
                   (shortcuts-tty-fallback "Set the Terminal Fallback" drgnx-shortcuts-set-tty-fallback
                                           "The Alt+Shift key a terminal that cannot send this key sends instead")
                   (shortcuts-undo "Undo Last Change" drgnx-shortcuts-undo "keys.eld as it was before the last change")
                   (shortcuts-reset "Reset Keybinding" drgnx-shortcuts-reset "This command's profile keys again")
                   (shortcuts-reset-all "Reset All Keybindings" drgnx-shortcuts-reset-all
                                        "Every command's profile keys again (asks first)")
                   (shortcuts-profile "Switch Profile…" drgnx-shortcuts-switch-profile "VS Code, Emacs, Vim or a combination")))
    (drgnx-command-define id :category "Keyboard Shortcuts" :title title :command fn :doc doc
                          :when (lambda () (derived-mode-p 'drgnx-shortcuts-mode)))))

(defun drgnx-shortcuts--teardown ()
  "Kill the Keyboard Shortcuts view (it holds a recording's hook); never asks."
  (when-let* ((b (get-buffer drgnx-shortcuts--buffer)))
    (let ((kill-buffer-query-functions nil)) (kill-buffer b))))

(drgnx-module-define 'tools/shortcuts
                     :doc "Preferences: Keyboard Shortcuts — record chords, source and where, conflicts, filters, suggestions."
                     :stage 'idle
                     :teardown #'drgnx-shortcuts--teardown
                     :setup (lambda ()
                              (drgnx-shortcuts--define-commands)
                              (eval-after-load 'evil (drgnx-modules-with-owner (drgnx-shortcuts--evil-state)))))

(provide 'drgnx-shortcuts)
;;; drgnx-shortcuts.el ends here
