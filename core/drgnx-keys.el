;;; drgnx-keys.el --- Key profiles, layers and conflicts -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Commands are registered without keys (`drgnx-command-define'); keys come from profiles —
;; data files keys/<profile>.eld mapping command ids to keys (VS Code, Emacs, Vim), plus entries
;; modules add with `drgnx-keys-define'.  The active setup is a stack of layers, each a profile
;; with the command scopes it covers (editing, app, window); later layers win, the user's
;; keys.eld wins over all, and every conflict is reported, never silently resolved.
;; `drgnx-keys-resolve' is the pure part: inputs in, (bindings conflicts problems) out.  On macOS
;; the VS Code profile's C- is Cmd (s-) unless an entry's :mac says otherwise, and applying it sets
;; Cmd, left and right Option for it.  See docs/guide/keys.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-paths)

(defvar drgnx-keys-profiles nil
  "Alist PROFILE → plist (:name :doc :bind :claims :map :mac-cmd :claims-defaults).")

(defvar drgnx-keys-problems nil "Problems found while loading profiles or keys.eld.")

;;;; Profiles

(defun drgnx-keys--read-file (file)
  "The first form in FILE; nil if it holds only comments, or nil with a problem recorded if it
cannot be read (never an error or a prompt)."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (set-syntax-table emacs-lisp-mode-syntax-table)   ; so `;' starts a comment
        (goto-char (point-min))
        (forward-comment (buffer-size))
        (unless (eobp) (read (current-buffer))))
    (end-of-file (push (format "%s: incomplete (a missing closing parenthesis?)" (abbreviate-file-name file))
                       drgnx-keys-problems)
                 nil)
    (error (push (format "%s: %s" (abbreviate-file-name file) (error-message-string err)) drgnx-keys-problems)
           nil)))

(defun drgnx-keys--map-spec-p (m)
  "Non-nil if M is a keymap spec: a keymap symbol or (FEATURE . KEYMAP-SYMBOL)."
  (or (and (symbolp m) m (not (keywordp m)))
      (and (consp m) (symbolp (car m)) (car m) (symbolp (cdr m)) (cdr m))))

(defun drgnx-keys--entry-error (entry)
  "Why ENTRY is not (ID KEY… [:map M] [:mac K…]) or (ID :none [REASON] [:mac K…]); nil if it is."
  (cond ((not (and (consp entry) (symbolp (car entry)) (proper-list-p entry))) "not a list (ID KEY…)")
        ((eq (cadr entry) :none)
         (let ((rest (if (stringp (nth 2 entry)) (nthcdr 3 entry) (nthcdr 2 entry))))
           (cond ((null rest) nil)
                 ((not (and (eq (car rest) :mac) (= (length rest) 2) (seq-every-p #'stringp (ensure-list (cadr rest)))))
                  (format "%S after :none (only a reason and :mac KEYS may follow it)" rest)))))
        (t (let ((rest (cdr entry)))
             (while (stringp (car rest)) (pop rest))
             (cond ((eq rest (cdr entry)) "no keys (write (ID :none \"reason\") for none)")
                   ((or (cl-oddp (length rest))
                        (not (seq-every-p (lambda (k) (memq k '(:map :mac))) (cl-loop for k in rest by #'cddr collect k))))
                    (format "%S is not a key (keys are strings; only :map and :mac may follow them)" (car rest)))
                   ((and (plist-member rest :map) (not (drgnx-keys--map-spec-p (plist-get rest :map))))
                    (format ":map %S is not a keymap symbol or (FEATURE . KEYMAP)" (plist-get rest :map)))
                   ((and (plist-member rest :mac)
                         (not (seq-every-p #'stringp (ensure-list (plist-get rest :mac)))))
                    (format ":mac %S is not a key or a list of keys" (plist-get rest :mac))))))))

(defun drgnx-keys--layers-error (layers)
  "Why LAYERS is not a list of (PROFILE SCOPE…) with known scopes; nil if it is."
  (cond ((not (proper-list-p layers)) "must be a list of (PROFILE SCOPE…)")
        ((seq-find (lambda (l) (not (and (consp l) (symbolp (car l)) (proper-list-p (cdr l)) (cdr l)))) layers)
         (format "%S is not (PROFILE SCOPE…)" (seq-find (lambda (l) (not (and (consp l) (proper-list-p (cdr l)) (cdr l)))) layers)))
        ((seq-find (lambda (s) (not (memq s drgnx-command-scopes))) (apply #'append (mapcar #'cdr layers)))
         (format "unknown scope %s (scopes: %s)" (seq-find (lambda (s) (not (memq s drgnx-command-scopes)))
                                                           (apply #'append (mapcar #'cdr layers)))
                 (mapconcat #'symbol-name drgnx-command-scopes " ")))))

(defun drgnx-keys-load-profiles (dir)
  "Profiles from DIR/*.eld, as an alist PROFILE → plist, in file-name order."
  (let (out)
    (dolist (f (directory-files dir t "\\.eld\\'"))
      (when-let* ((spec (drgnx-keys--read-file f)))
        (push (cons (intern (file-name-base f)) spec) out)))
    (nreverse out)))

(defun drgnx-keys-define (profile entries)
  "Add ENTRIES, in profile :bind form, to PROFILE (for modules); later entries for an id win."
  (drgnx-keys--ensure-profiles)          ; modules run before the first apply
  (let ((spec (alist-get profile drgnx-keys-profiles)))
    (setf (alist-get profile drgnx-keys-profiles)
          (plist-put spec :bind (append (seq-remove (lambda (e) (assq (car e) entries)) (plist-get spec :bind))
                                        entries)))))

;;;; Resolution

(defun drgnx-keys--mac-cmd (key &optional keep-ctrl)
  "KEY as macOS sends it: every C- turned into s- (Cmd), as VS Code does there (not with KEEP-CTRL),
and Cmd+Shift+letter as the capital letter, as GNU Emacs' NS port sends it (S-s-p is s-P; Shift stays
on named keys and other characters: C-S-s-<right>).  The modifiers stay in the order keys are written
in (A-C-H-M-S-s): C-M-b is M-s-b, C-M-S-c is M-s-C."
  (mapconcat (lambda (event)
               (if (string-match "\\`\\(\\(?:[ACHMSs]-\\)*\\)\\(.+\\)\\'" event)
                   (let* ((base (match-string 2 event)) (mods (split-string (match-string 1 event) "-" t)))
                     (unless keep-ctrl
                       (when (member "C" mods) (setq mods (cons "s" (remove "C" mods)))))
                     (when (and (member "S" mods) (member "s" mods) (string-match-p "\\`[a-z]\\'" base))
                       (setq mods (remove "S" mods) base (upcase base)))
                     (concat (mapconcat (lambda (m) (concat m "-"))
                                        (seq-filter (lambda (m) (member m mods)) '("A" "C" "H" "M" "S" "s"))
                                        "")
                             base))
                 event))
             (split-string key " ") " "))

(defun drgnx-keys--entry (entry spec platform)
  "ENTRY (ID KEY… [:map M] [:mac K…]) or (ID :none [REASON] [:mac K…]) of SPEC → plist (:keys :map
:profile-map).  On macOS, :mac's keys replace the others (`:mac ()': none there); without it a :mac-cmd
profile's C- becomes s-.  Every macOS key has Cmd+Shift+letter as macOS sends it (`S-s-w' is s-W).
The keymap used is the entry's, else the command's, else the profile's."
  (let ((rest (cdr entry)) keys)
    (cl-flet ((mac (opts) (mapcar (lambda (k) (drgnx-keys--mac-cmd k t)) (ensure-list (plist-get opts :mac)))))
      (if (eq (car rest) :none)
          (let ((opts (if (stringp (cadr rest)) (cddr rest) (cdr rest))))
            (list :keys (and (eq platform 'macos) (mac opts)) :profile-map (plist-get spec :map)))
        (while (stringp (car rest)) (push (pop rest) keys))
        (setq keys (nreverse keys))
        (when (eq platform 'macos)
          (setq keys (cond ((plist-member rest :mac) (mac rest))
                           ((plist-get spec :mac-cmd) (mapcar #'drgnx-keys--mac-cmd keys))
                           (t (mapcar (lambda (k) (drgnx-keys--mac-cmd k t)) keys)))))
        (list :keys keys :map (plist-get rest :map) :profile-map (plist-get spec :map))))))

(defun drgnx-keys--lookup (map key)
  "KEY in MAP, ignoring command remapping (which depends on the current buffer)."
  (ignore-errors (keymap-lookup map key nil t)))

(defun drgnx-keys--existing (map key)
  "What KEY does in MAP: (claim . DESCRIPTION), (prefix . DESCRIPTION) or nil."
  (let ((def (drgnx-keys--lookup map key)))
    (cond ((keymapp def) (cons 'prefix (format "the %s prefix" key)))
          ((numberp def)                 ; KEY's prefix is bound to a command (unbound: nothing replaced)
           (let* ((prefix (key-description (seq-take (key-parse key) def))) (cmd (drgnx-keys--lookup map prefix)))
             (and cmd (cons 'prefix (format "%s (%s)" cmd prefix)))))
          ((and (symbolp def) def (commandp def) (not (memq def '(self-insert-command undefined ignore))))
           (cons 'claim (symbol-name def))))))

(defvar drgnx-keys--parsed (make-hash-table :test #'equal) "Key string → `key-parse' vector (keys never change).")

(defun drgnx-keys--parse (key)
  (or (gethash key drgnx-keys--parsed) (puthash key (key-parse key) drgnx-keys--parsed)))

(defun drgnx-keys--prefix-of-p (a b)
  "Non-nil if key A is a strict prefix of key B."
  (let ((a (drgnx-keys--parse a)) (b (drgnx-keys--parse b)))
    (and (< (length a) (length b)) (equal a (seq-take b (length a))))))

(cl-defun drgnx-keys-resolve (&key commands profiles layers user platform defaults maps)
  "Resolve keys for COMMANDS (registry structs) → plist (:bindings :conflicts :problems).
PROFILES: alist PROFILE → plist.  LAYERS: list of (PROFILE SCOPE…), later wins.  USER: the
keys.eld plist (:bind :unbind), which wins over every layer.  PLATFORM: `macos' turns VS Code's
C- into s-.  DEFAULTS: Emacs' own global keymap, for the emacs layer's claims and prefix checks.
MAPS: a function MAPSYM → the loaded keymap or nil, for prefix checks in mode keymaps.
A binding is a plist (:id :key :map :layer); a conflict is (:key :map :kind :winner :losers),
KIND `same-key', `claim' (a key another layer uses natively) or `prefix'."
  (let ((cmds (make-hash-table :test #'eq)) (assign (make-hash-table :test #'eq))
        (rank 0) claims defaults-claim problems bindings conflicts)
    (dolist (c commands) (puthash (drgnx-cmd-id c) c cmds))
    (cl-flet ((take (entry spec layer where)
                (if-let* ((why (drgnx-keys--entry-error entry)))
                    (push (format "%s: %S: %s" where entry why) problems)
                  (let ((c (gethash (car entry) cmds)))
                    (cond ((null c) (when (eq layer 'user)
                                      (push (format "%s: no command %s (in :bind)" where (car entry)) problems)))
                          (t (puthash (car entry) (append (list :layer layer :rank rank)
                                                          (drgnx-keys--entry entry spec platform))
                                      assign)))))))
      ;; Each command takes its keys from the last layer covering its scope.
      (if-let* ((why (drgnx-keys--layers-error layers)))
          (push (format "key layers %S: %s" layers why) problems)
        (pcase-dolist (`(,profile . ,scopes) layers)
          (cl-incf rank)
          (if-let* ((spec (alist-get profile profiles)))
              (progn
                (dolist (entry (plist-get spec :bind))
                  (when (or (not (consp entry)) (not (gethash (car entry) cmds))
                            (memq (drgnx-cmd-scope (gethash (car entry) cmds)) scopes))
                    (take entry spec profile (format "key profile %s" profile))))
                (pcase-dolist (`(,scope ,key ,desc) (plist-get spec :claims))
                  (when (memq scope scopes) (push (list :key key :claim desc :layer profile :rank rank) claims)))
                (when (and (plist-get spec :claims-defaults) (memq 'editing scopes))
                  (setq defaults-claim (list :layer profile :rank rank))))
            (push (format "key layer %s: no such profile (known: %s)" profile
                          (mapconcat #'symbol-name (mapcar #'car profiles) ", "))
                  problems))))
      (cl-incf rank)
      (dolist (entry (plist-get user :bind)) (take entry nil 'user "keys.eld")))
    (dolist (id (plist-get user :unbind))
      (if (gethash id cmds) (puthash id (list :layer 'user :rank rank :keys nil) assign)
        (push (format "keys.eld: no command %s (in :unbind)" id) problems)))
    ;; Flatten, in registry order.
    (dolist (c commands)
      (when-let* ((a (gethash (drgnx-cmd-id c) assign)))
        (dolist (k (plist-get a :keys))
          (if (key-valid-p k)
              (push (list :id (drgnx-cmd-id c) :key k :map (or (plist-get a :map) (drgnx-cmd-map c) (plist-get a :profile-map))
                          :layer (plist-get a :layer) :rank (plist-get a :rank))
                    bindings)
            (push (format "%s: \"%s\" is not a valid key" (drgnx-cmd-id c) k) problems)))))
    (setq bindings (nreverse bindings))
    (cl-flet ((mapsym (b) (cdr (drgnx-commands--keymap-spec (plist-get b :map))))
              (party (b) (list :id (plist-get b :id) :layer (plist-get b :layer))))
      ;; Two commands on one key in one keymap: the higher layer keeps it.  Keys are compared parsed
      ;; ("TAB" and "C-i" are one key).
      (let ((groups nil))
        (dolist (b bindings)
          (push b (alist-get (cons (drgnx-keys--parse (plist-get b :key)) (mapsym b)) groups nil nil #'equal)))
        (pcase-dolist (`((,_ . ,map) . ,group) (reverse groups))
          (when (cdr (delete-dups (mapcar (lambda (b) (plist-get b :id)) group)))
            (let* ((group (reverse group)) (key (plist-get (car group) :key))
                   (winner (seq-reduce (lambda (w b) (if (> (plist-get b :rank) (plist-get w :rank)) b w)) group (car group)))
                   (losers (remq winner group)))
              (push (list :key key :map map :kind 'same-key :winner (party winner) :losers (mapcar #'party losers))
                    conflicts)
              (setq bindings (seq-remove (lambda (b) (memq b losers)) bindings))))))
      ;; One drgnx key a prefix of another in the same keymap: the higher layer keeps its key.
      ;; Only keys in one keymap starting with the same event can be prefixes of each other: compare
      ;; within those groups (all pairs made startup slow).
      (let ((groups (make-hash-table :test #'equal)) (gone (make-hash-table :test #'eq)))
        (dolist (b bindings)
          (push b (gethash (cons (mapsym b) (aref (drgnx-keys--parse (plist-get b :key)) 0)) groups)))
        (dolist (w (sort (copy-sequence bindings) (lambda (a b) (> (plist-get a :rank) (plist-get b :rank)))))
          (unless (gethash w gone)
            (let ((losers (seq-filter (lambda (b) (and (not (eq b w)) (not (gethash b gone))
                                                       (or (drgnx-keys--prefix-of-p (plist-get b :key) (plist-get w :key))
                                                           (drgnx-keys--prefix-of-p (plist-get w :key) (plist-get b :key)))))
                                      (reverse (gethash (cons (mapsym w) (aref (drgnx-keys--parse (plist-get w :key)) 0)) groups)))))
              (when losers
                (push (list :key (plist-get w :key) :map (mapsym w) :kind 'prefix :winner (party w)
                            :losers (mapcar #'party losers))
                      conflicts)
                (dolist (l losers) (puthash l t gone))))))
        (setq bindings (seq-remove (lambda (b) (gethash b gone)) bindings)))
      ;; Keys other layers use natively (claims), Emacs' defaults, and prefixes in the target keymap.
      (dolist (b (copy-sequence bindings))
        (let* ((key (plist-get b :key)) (rank (plist-get b :rank)) (parsed (drgnx-keys--parse key))
               (rivals (seq-filter (lambda (cl) (and (equal (drgnx-keys--parse (plist-get cl :key)) parsed)
                                                     (not (eq (plist-get cl :layer) (plist-get b :layer)))))
                                   claims))
               (kind (and rivals 'claim))
               (global (eq (mapsym b) 'global-map))
               (target (if global defaults (and maps (funcall maps (mapsym b))))))
          (when target
            (pcase (drgnx-keys--existing target key)
              (`(prefix . ,desc)
               (setq kind 'prefix)
               (push (list :claim desc :layer (and global (plist-get defaults-claim :layer))
                           :rank (or (and global (plist-get defaults-claim :rank)) 0))
                     rivals))
              (`(claim . ,desc)
               (when (and global defaults-claim
                          (not (equal desc (format "%s" (drgnx-cmd-command (gethash (plist-get b :id) cmds))))))
                 (setq kind (or kind 'claim))
                 (push (list :claim desc :layer (plist-get defaults-claim :layer) :rank (plist-get defaults-claim :rank))
                       rivals)))))
          (when rivals
            (let* ((top (seq-reduce (lambda (w r) (if (> (plist-get r :rank) (plist-get w :rank)) r w)) rivals (car rivals)))
                   (b-wins (>= rank (plist-get top :rank)))
                   (them (mapcar (lambda (r) (list :claim (plist-get r :claim) :layer (plist-get r :layer))) rivals))
                   (top-party (seq-find (lambda (x) (equal (plist-get x :claim) (plist-get top :claim))) them)))
              (push (list :key key :map (mapsym b) :kind kind
                          :winner (if b-wins (party b) top-party)
                          :losers (if b-wins them (cons (party b) (remq top-party them))))
                    conflicts)
              (unless b-wins (setq bindings (remq b bindings))))))))
    (list :bindings (mapcar (lambda (b) (list :id (plist-get b :id) :key (plist-get b :key)
                                              :map (plist-get b :map) :layer (plist-get b :layer)))
                            bindings)
          :conflicts (nreverse conflicts)
          :problems (nreverse problems))))

;;;; Applying

(defcustom drgnx-keys-layers '((vscode app editing window))
  "The key-profile stack when keys.eld names none: (PROFILE SCOPE…), later layers win."
  :type '(repeat (cons symbol (repeat symbol))) :group 'drgnx)

(defconst drgnx-keys-presets
  '(("VS Code" . ((vscode app editing window)))
    ("Emacs" . ((emacs app editing window)))
    ("Vim (needs the evil module)" . ((vim app editing window)))
    ("Emacs editing + VS Code app keys" . ((emacs editing) (vscode app window)))
    ("Vim editing + VS Code app keys" . ((vim editing) (vscode app window))))
  "Named stacks offered by `drgnx-keys-choose-profile'.")

(defvar drgnx-keys--defaults (copy-keymap global-map)
  "Emacs' own global bindings, taken before drgnx binds anything.")

(defvar drgnx-keys--applied nil "What drgnx bound, newest first: (MAPSYM KEY PREVIOUS OURS).")
(defvar drgnx-keys--generation 0 "Incremented by every apply; stale deferred bindings check it.")
(defvar drgnx-keys--session-layers nil "Layers chosen in this session; win over keys.eld and the default.")
(defvar drgnx-keys-last nil "The last applied resolution, plus :layers, :problems from loading too.")

(defun drgnx-keys--ensure-profiles ()
  (unless drgnx-keys-profiles
    (setq drgnx-keys-profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))))

(defun drgnx-keys-file () (expand-file-name "keys.eld" (drgnx-user-dir)))

(defun drgnx-keys-read-user ()
  "The user's keys.eld plist (:layers :bind :unbind), nil if absent; problems, never errors."
  (let ((file (drgnx-keys-file)))
    (when (file-exists-p file)
      (let ((form (drgnx-keys--read-file file)) (name (abbreviate-file-name file)))
        (cond ((null form) nil)
              ((not (and (proper-list-p form) (cl-evenp (length form)) (keywordp (car form))))
               (push (format "%s: not a plist like (:layers … :bind … :unbind …)" name) drgnx-keys-problems)
               nil)
              (t
               (setq form (copy-sequence form))
               (when-let* ((why (and (plist-member form :layers) (drgnx-keys--layers-error (plist-get form :layers)))))
                 (push (format "%s: :layers %s — using the default stack" name why) drgnx-keys-problems)
                 (setq form (plist-put form :layers nil)))
               (unless (proper-list-p (plist-get form :bind))
                 (push (format "%s: :bind must be a list of (ID KEY…)" name) drgnx-keys-problems)
                 (setq form (plist-put form :bind nil)))
               (unless (and (proper-list-p (plist-get form :unbind)) (seq-every-p #'symbolp (plist-get form :unbind)))
                 (push (format "%s: :unbind must be a list of command ids" name) drgnx-keys-problems)
                 (setq form (plist-put form :unbind nil)))
               form))))))

(define-obsolete-function-alias 'drgnx-keys-platform #'drgnx-platform "drgnx M12a")

(defvar drgnx-keys--mac-modifiers
  '((ns-command-modifier . super) (ns-alternate-modifier . meta) (ns-right-alternate-modifier . none)
    (mac-command-modifier . super) (mac-option-modifier . meta) (mac-right-option-modifier . none))
  "On macOS with VS Code keys: Cmd is s-, left Option is Meta (Option+← moves by word), right Option
types characters (@ # { [ on any layout).  The ns- variables are Emacs' own port's, the mac- ones the
Mac port's; only those this Emacs has are set.")

(defvar drgnx-keys--saved-modifiers nil "What `drgnx-keys--mac-modifiers' replaced: ((VARIABLE . VALUE)…).")

(defvar drgnx-keys--mac-option-variables '(ns-alternate-modifier mac-option-modifier)
  "The left Option's variables in `drgnx-keys--mac-modifiers' (GNU Emacs' ns- port, the Mac port).")

(defconst drgnx-keys--option-types-characters '(:ordinary none :function meta :mouse meta)
  "The left Option when it types characters (keys.eld :mac-option characters — German, French, … layouts type
@ # { [ with it): no modifier for ordinary keys, so macOS makes the character; Meta for function keys and the mouse,
so Option+← / → still move by word.  Both ports take such a plist (the ns- variables' custom type says so).")

(defun drgnx-keys--set-mac-modifiers (layers &optional option)
  "On macOS, with the vscode profile in LAYERS: set the modifiers VS Code's keys need — the left Option Meta, or,
with OPTION `characters', `drgnx-keys--option-types-characters'; otherwise put back what was there before."
  (if (and (eq (drgnx-platform) 'macos) (assq 'vscode layers))
      (pcase-dolist (`(,var . ,value) drgnx-keys--mac-modifiers)
        (when (boundp var)
          (unless (assq var drgnx-keys--saved-modifiers) (push (cons var (symbol-value var)) drgnx-keys--saved-modifiers))
          (set var (if (and (eq option 'characters) (memq var drgnx-keys--mac-option-variables))
                       drgnx-keys--option-types-characters
                     value))))
    (pcase-dolist (`(,var . ,value) drgnx-keys--saved-modifiers) (set var value))
    (setq drgnx-keys--saved-modifiers nil)))

(defun drgnx-keys--set (map key def)
  "Bind KEY to DEF in MAP; nil DEF removes the entry."
  (if def (define-key map (key-parse key) def) (keymap-unset map key t)))

(defun drgnx-keys--bind (mapsym key def)
  "Bind KEY in MAPSYM's keymap, remembering what was there; a command blocking KEY as a prefix
is lifted first (and remembered).  Returns what was lifted, \"COMMAND (PREFIX)\", or nil."
  (let* ((map (symbol-value mapsym)) (prev (drgnx-keys--lookup map key)) (lifted nil))
    (when (numberp prev)
      (let* ((prefix (key-description (seq-take (key-parse key) prev))) (cmd (drgnx-keys--lookup map prefix)))
        (push (list mapsym prefix cmd :prefix) drgnx-keys--applied)
        (keymap-unset map prefix t)
        (setq prev nil lifted (format "%s (%s)" cmd prefix))))
    (push (list mapsym key prev def) drgnx-keys--applied)
    (define-key map (key-parse key) def)
    lifted))

(defun drgnx-keys--restore ()
  "Undo every binding drgnx made, newest first — except one someone else changed since."
  (pcase-dolist (`(,mapsym ,key ,prev ,ours) drgnx-keys--applied)
    (when (and (boundp mapsym) (keymapp (symbol-value mapsym)))
      (let* ((map (symbol-value mapsym)) (now (drgnx-keys--lookup map key)))
        (when (if (eq ours :prefix) (or (null now) (equal now '(keymap))) (equal now ours))
          (drgnx-keys--set map key prev)))))
  (setq drgnx-keys--applied nil))

(defun drgnx-keys--apply-binding (b cmd generation)
  "Bind resolution binding B (command CMD) now, or when its keymap's feature loads.  A late binding
adds what it finds (a failure, a lifted prefix) to `drgnx-keys-last' and rewrites the report."
  (pcase-let* ((`(,feature . ,mapsym) (drgnx-commands--keymap-spec (plist-get b :map)))
               (key (plist-get b :key))
               (bind (lambda (&optional late)
                       (when (= generation drgnx-keys--generation)
                         (condition-case err
                             (let ((lifted (drgnx-keys--bind mapsym key (drgnx-cmd-command cmd))))
                               (when (and late lifted)   ; at apply time the resolver saw this prefix
                                 (setq drgnx-keys-last
                                       (plist-put drgnx-keys-last :conflicts
                                                  (append (plist-get drgnx-keys-last :conflicts)
                                                          (list (list :key key :map mapsym :kind 'prefix
                                                                      :winner (list :id (plist-get b :id) :layer (plist-get b :layer))
                                                                      :losers (list (list :claim lifted :layer nil)))))))
                                 (drgnx-keys--write-report)))
                           (error (let ((p (format "%s: cannot bind %s in %s: %s" (plist-get b :id) key
                                                   mapsym (error-message-string err))))
                                    (push p drgnx-keys-problems)
                                    (when late
                                      (setq drgnx-keys-last (plist-put drgnx-keys-last :problems
                                                                       (append (plist-get drgnx-keys-last :problems) (list p))))
                                      (drgnx-keys--write-report)))))))))
    (cond ((and feature (not (featurep feature))) (with-eval-after-load feature (funcall bind t)))
          ((and (boundp mapsym) (keymapp (symbol-value mapsym))) (funcall bind))
          (t (push (format "%s: no keymap %s for %s" (plist-get b :id) mapsym (plist-get b :key)) drgnx-keys-problems)))))

(defun drgnx-keys-apply ()
  "Bind the keys of the active stack and keys.eld, replacing what drgnx bound before.
Never prompts: problems are collected in `drgnx-keys-last'.  Returns the resolution."
  (setq drgnx-keys-problems nil)
  (condition-case err
      (progn
        (drgnx-keys--ensure-profiles)
        ;; Restore first: resolution then sees Emacs' own bindings, not drgnx's previous ones.
        (drgnx-keys--restore)
        (cl-incf drgnx-keys--generation)
        (let* ((user (drgnx-keys-read-user))
               (layers (or drgnx-keys--session-layers (plist-get user :layers) drgnx-keys-layers))
               (r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-profiles :layers layers
                                      :user user :platform (drgnx-platform) :defaults drgnx-keys--defaults
                                      :maps (lambda (m) (and (boundp m) (keymapp (symbol-value m)) (symbol-value m))))))
          (drgnx-keys--set-mac-modifiers layers (plist-get user :mac-option))
          (dolist (c (drgnx-commands-all)) (setf (drgnx-cmd-bound c) nil))
          (dolist (b (plist-get r :bindings))
            (let ((cmd (drgnx-commands-get (plist-get b :id))))
              (setf (drgnx-cmd-bound cmd) (append (drgnx-cmd-bound cmd) (list (cons (plist-get b :key) (plist-get b :map)))))
              (drgnx-keys--apply-binding b cmd drgnx-keys--generation)))
          (setq drgnx-keys-last (append (list :layers layers
                                              :problems (append (reverse drgnx-keys-problems) (plist-get r :problems)))
                                        r))))
    ;; Startup must go on whatever happens here (drgnx-init, a daemon): record it.
    (error (setq drgnx-keys-last (list :layers nil :bindings nil :conflicts nil
                                       :problems (append (reverse drgnx-keys-problems)
                                                         (list (format "keys could not be applied: %s"
                                                                       (error-message-string err))))))))
  (drgnx-keys--write-report)
  drgnx-keys-last)

;;;; Reporting

(defun drgnx-keys--party (p)
  "A conflict party P, (:id ID :layer L) or (:claim DESCRIPTION :layer L), as text."
  (format "%s (%s)"
          (if-let* ((id (plist-get p :id))) (if-let* ((c (drgnx-commands-get id))) (drgnx-cmd-title c) id)
            (plist-get p :claim))
          (or (plist-get p :layer) "Emacs")))

(defun drgnx-keys-conflict-text (c)
  "Conflict C as one line: KEY WINNER over LOSERS [KIND]."
  (format "%s %s over %s [%s%s]" (plist-get c :key) (drgnx-keys--party (plist-get c :winner))
          (mapconcat #'drgnx-keys--party (plist-get c :losers) ", ") (plist-get c :kind)
          (if (memq (plist-get c :map) '(nil global-map)) "" (format ", in %s" (plist-get c :map)))))

(defun drgnx-keys--group-text (group)
  "Prefix conflicts GROUP (one keymap, the same losers) as one line: COMMON-PREFIX … N keys over LOSERS."
  (let* ((vs (mapcar (lambda (c) (drgnx-keys--parse (plist-get c :key))) group))
         (n (apply #'min (mapcar #'length vs))) (i 0) (c (car group)))
    (while (and (< i n) (seq-every-p (lambda (v) (equal (aref v i) (aref (car vs) i))) vs)) (cl-incf i))
    (format "%s … %d keys over %s [prefix%s]: %s" (key-description (seq-take (car vs) i)) (length group)
            (mapconcat #'drgnx-keys--party (plist-get c :losers) ", ")
            (if (memq (plist-get c :map) '(nil global-map)) "" (format ", in %s" (plist-get c :map)))
            (mapconcat (lambda (c) (format "%s %s" (plist-get c :key) (drgnx-keys--party (plist-get c :winner)))) group ", "))))

(defun drgnx-keys-conflict-lines ()
  "The last apply's conflicts as text lines; prefix conflicts in one keymap over the same losers (VS
Code's C-k chords over kill-line) are one line."
  (let ((groups nil))
    (dolist (c (plist-get drgnx-keys-last :conflicts))
      (let ((id (if (eq (plist-get c :kind) 'prefix) (list (plist-get c :map) (plist-get c :losers)) c)))
        (push c (alist-get id groups nil nil #'equal))))
    (mapcar (lambda (g) (if (cddr g) (drgnx-keys--group-text (reverse (cdr g))) (drgnx-keys-conflict-text (cadr g))))
            (reverse groups))))

(defun drgnx-keys--write-report ()
  "Write the conflicts and problems to the state dir for `drgnx doctor' (never prompts)."
  (condition-case err
      (let* ((file (expand-file-name "keys-report.eld" (drgnx-state-dir)))
             (tmp (progn (make-directory (file-name-directory file) t)
                         (make-temp-file (expand-file-name ".keys-report-" (file-name-directory file))))))
        (with-temp-file tmp
          (prin1 (list :time (format-time-string "%FT%T%z") :layers (plist-get drgnx-keys-last :layers)
                       :conflicts (drgnx-keys-conflict-lines) :problems (plist-get drgnx-keys-last :problems))
                 (current-buffer)))
        (rename-file tmp file t))
    (error (push (format "cannot write the key report: %s" (error-message-string err))
                 (plist-get drgnx-keys-last :problems)))))

(defun drgnx-keys-use (layers &optional save)
  "Switch to the key stack LAYERS now (no restart); with SAVE, also write it to keys.eld."
  (setq drgnx-keys--session-layers layers)
  (when save (drgnx-keys--save-layers layers))
  (prog1 (drgnx-keys-apply)
    (when (fboundp 'drgnx-surfaces-refresh) (drgnx-surfaces-refresh))))

(defun drgnx-keys--save-layers (layers)
  "Write LAYERS into keys.eld: only the :layers value changes; comments and layout stay."
  (drgnx-keys--save-key :layers layers))

(defun drgnx-keys-set-mac-option (option)
  "Save what the left Option does on a Mac with VS Code's keys — OPTION `characters' (it types @ # { [ on German,
French, … layouts; Option+← / → still move by word) or `meta' — in keys.eld, and apply it when keys are applied here."
  (drgnx-keys--save-key :mac-option option)
  (when drgnx-keys-last (drgnx-keys-apply)))

(defun drgnx-keys--save-key (key data &optional file header)
  "Write DATA as KEY's value into keys.eld (FILE: another .eld, started with HEADER): only that value changes;
comments and layout stay."
  (let* ((file (or file (drgnx-keys-file)))
         (value (prin1-to-string data))
         (text (with-temp-buffer
                 (if (file-exists-p file)
                     (insert-file-contents file)
                   (insert (or header (concat ";; drgnx keys (docs/guide/keys.md): :layers — profile stack, :bind — (ID KEY… [:map M]),\n"
                                              ";; :unbind — (ID…)\n"))))
                 (set-syntax-table emacs-lisp-mode-syntax-table)
                 (goto-char (point-min))
                 (forward-comment (buffer-size))
                 (if (eobp)
                     (insert (format "(%s " key) value ")\n")
                   (let ((start (point)) found)
                     (unless (and (eq (char-after) ?\() (ignore-errors (scan-sexps start 1)))
                       (user-error "%s cannot be read — fix it first (it was not changed)" (abbreviate-file-name file)))
                     (down-list 1)
                     (while (and (not found) (progn (forward-comment (buffer-size)) (not (eq (char-after) ?\)))))
                       (let ((k (read (current-buffer))))
                         (forward-comment (buffer-size))
                         (let ((vbeg (point)))
                           (forward-sexp 1)
                           (when (eq k key)
                             (delete-region vbeg (point))
                             (goto-char vbeg)
                             (insert value)
                             (setq found t)))))
                     (unless found
                       (goto-char (1+ start))
                       (insert (format "%s " key) value "\n "))))
                 (buffer-string)))
         (tmp (progn (make-directory (file-name-directory file) t)
                     (make-temp-file (expand-file-name ".keys-" (file-name-directory file))))))
    ;; A temp file renamed over keys.eld: writing it directly could ask about a stale buffer.
    (with-temp-file tmp (insert text))
    (set-file-modes tmp #o644)
    (rename-file tmp file t)))

(defun drgnx-keys-choose-profile (name)
  "Switch the key profile to the preset NAME and save it in keys.eld."
  (interactive (list (completing-read "Keyboard profile: " drgnx-keys-presets nil t nil nil
                                      ;; RET at once: the current profile (else the default), never none
                                      (or (car (rassoc (plist-get drgnx-keys-last :layers) drgnx-keys-presets))
                                          (car (rassoc drgnx-keys-layers drgnx-keys-presets))))))
  (unless (assoc name drgnx-keys-presets)
    (user-error "No keyboard profile %S (profiles: %s)" name (mapconcat #'car drgnx-keys-presets ", ")))
  (drgnx-keys-use (cdr (assoc name drgnx-keys-presets)) t)
  (message "Keys: %s%s" name
           (if-let* ((n (length (drgnx-keys-conflict-lines))) ((> n 0)))
               (format " — %d conflict%s, see Keyboard Shortcuts" n (if (= n 1) "" "s"))
             "")))

(provide 'drgnx-keys)
;;; drgnx-keys.el ends here
