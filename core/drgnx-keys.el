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
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-keys-modal)

(defvar drgnx-keys-profiles nil
  "Alist PROFILE → plist (:name :doc :bind :claims :map :mac-cmd :claims-defaults :modal).")

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
  "Why ENTRY is not (ID KEY… [:map M] [:mac K…] [:everywhere K…]) or (ID :none [REASON] [:mac K…]); nil if it is."
  (cond ((not (and (consp entry) (symbolp (car entry)) (proper-list-p entry))) "not a list (ID KEY…)")
        ((eq (cadr entry) :none)
         (let ((rest (if (stringp (nth 2 entry)) (nthcdr 3 entry) (nthcdr 2 entry))))
           (cond ((null rest) nil)
                 ((not (and (eq (car rest) :mac) (= (length rest) 2) (seq-every-p #'stringp (ensure-list (cadr rest)))))
                  (format "%S after :none (only a reason and :mac KEYS may follow it)" rest)))))
        (t (let ((rest (cdr entry)))
             (while (stringp (car rest)) (pop rest))
             (cond ((and (eq rest (cdr entry)) (not (plist-member rest :everywhere)))
                    "no keys (write (ID :none \"reason\") for none)")
                   ((or (cl-oddp (length rest))
                        (not (seq-every-p (lambda (k) (memq k '(:map :mac :everywhere))) (cl-loop for k in rest by #'cddr collect k))))
                    (format "%S is not a key (keys are strings; only :map, :mac and :everywhere may follow them)" (car rest)))
                   ((and (plist-member rest :everywhere)
                         (not (seq-every-p (lambda (k) (and (stringp k) (= 1 (length (ignore-errors (key-parse k))))))
                                           (ensure-list (plist-get rest :everywhere)))))
                    (format ":everywhere %S is not a one-stroke key or a list of them" (plist-get rest :everywhere)))
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

;;;; keys.eld, on the config layer

(defun drgnx-keys--layers-ok-p (layers)
  "Non-nil when LAYERS is a key stack; else a `user-error' saying why, which the schema's problem shows."
  (if-let* ((why (drgnx-keys--layers-error layers))) (user-error "%s" why) t))

(defun drgnx-keys--bind-entry-p (entry)
  "Non-nil when ENTRY is a keys.eld `:bind' entry; else a `user-error' saying why, which the schema's problem shows."
  (if-let* ((why (drgnx-keys--entry-error entry))) (user-error "%s" why) t))

(defun drgnx-keys--mac-option-p (option)
  "Whether OPTION is what the left Option key can be set to: `characters' or `meta' (`drgnx-keys-set-mac-option')."
  (and (memq option '(characters meta)) t))

(defconst drgnx-keys--header
  ";; drgnx keys (docs/guide/keys.md): :layers — profile stack, :bind — (ID KEY… [:map M]),\n;; :unbind — (ID…)\n"
  "The comment a new keys.eld starts with.")

(drgnx-config-define 'keys
                     :file "keys.eld" :shape 'plist :version 1 :reload 'start :last-good t
                     :schema '(plist
                               (:layers (pred drgnx-keys--layers-ok-p "a profile stack such as ((emacs editing) (vscode app window))")
                                        "The key profile stack, later layers winning; omitted: the default (VS Code)")
                               (:pending-layers (pred drgnx-keys--layers-ok-p "a profile stack such as ((vim app editing window))")
                                                "A stack waiting for its modal engine to be installed (drgnx sync)")
                               (:bind (list-of (pred drgnx-keys--bind-entry-p "(ID KEY… [:map MAP])"))
                                      "Command id → keys, winning over every layer")
                               (:unbind (list-of symbol) "Command ids that get no key")
                               (:mac-option (pred drgnx-keys--mac-option-p "characters or meta")
                                            "What the left Option key does on a Mac with VS Code's keys")
                               (:tty-fallback any "Chord → another Alt key for it, in a legacy terminal: ((\"C-S-p\" . \"M-Z\"))"))
                     :default '(:layers nil)
                     :header drgnx-keys--header
                     :doc "Your key bindings: the profile stack, entries that win over it, keys taken away.")

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
  (let ((case-fold-search nil))   ; a capital is not a lower-case letter, whatever the user's setting
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
               (split-string key " ") " ")))

(defun drgnx-keys--entry (entry spec platform)
  "ENTRY (ID KEY… [:map M] [:mac K…] [:everywhere K…]) or (ID :none [REASON] [:mac K…]) of SPEC → plist
(:keys [:everywhere] :map :profile-map [:modal]).  :modal is the profile's (absent for a profile without one),
which `drgnx-keys-modal-key-map' reads to place each key.  :everywhere's keys are also in :keys; they also go in
the override keymap (`drgnx-keys--set-everywhere').  On macOS, :mac's keys replace the others, :everywhere's too
(`:mac ()': none there); without it a :mac-cmd profile's C- becomes s-.  Every macOS key has Cmd+Shift+letter
as macOS sends it (`S-s-w' is s-W).  The keymap used is the entry's, else the command's, else the profile's."
  (let ((rest (cdr entry)) keys)
    (cl-flet ((mac (opts) (mapcar (lambda (k) (drgnx-keys--mac-cmd k t)) (ensure-list (plist-get opts :mac)))))
      (if (eq (car rest) :none)
          (let ((opts (if (stringp (cadr rest)) (cddr rest) (cdr rest))))
            (append (list :keys (and (eq platform 'macos) (mac opts)) :profile-map (plist-get spec :map))
                    (and (plist-get spec :modal) (list :modal (plist-get spec :modal)))))
        (while (stringp (car rest)) (push (pop rest) keys))
        (setq keys (nreverse keys))
        (let ((everywhere (ensure-list (plist-get rest :everywhere))))
          (when (eq platform 'macos)
            (if (plist-member rest :mac)
                (setq keys (mac rest) everywhere nil)
              (let ((f (if (plist-get spec :mac-cmd) #'drgnx-keys--mac-cmd (lambda (k) (drgnx-keys--mac-cmd k t)))))
                (setq keys (mapcar f keys) everywhere (mapcar f everywhere)))))
          (append (list :keys (append keys everywhere))
                  (and everywhere (list :everywhere everywhere))
                  (list :map (plist-get rest :map) :profile-map (plist-get spec :map))
                  (and (plist-get spec :modal) (list :modal (plist-get spec :modal)))))))))

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

(defun drgnx-keys--claim-parties (claims)
  "State CLAIMS (`drgnx-keys-modal-claims') as conflict parties (:id ID or :claim DESCRIPTION, :layer, :states): one
per command or description and layer, with the states of all its claims."
  (let (out)
    (dolist (c claims)
      (let* ((who (if (plist-get c :id) (list :id (plist-get c :id)) (list :claim (plist-get c :claim))))
             (p (seq-find (lambda (p) (and (equal (seq-take p 2) who) (eq (plist-get p :layer) (plist-get c :layer)))) out)))
        (if p
            (setf (plist-get p :states) (drgnx-keys-modal-order (append (plist-get p :states) (plist-get c :states))))
          (push (append who (list :layer (plist-get c :layer) :states (plist-get c :states))) out))))
    (nreverse out)))

(cl-defun drgnx-keys-resolve (&key commands profiles layers user platform defaults maps snapshots)
  "Resolve keys for COMMANDS (registry structs) → plist (:bindings :conflicts :problems).
PROFILES: alist PROFILE → plist.  LAYERS: list of (PROFILE SCOPE…), later wins.  USER: the
keys.eld plist (:bind :unbind), which wins over every layer.  PLATFORM: `macos' turns VS Code's
C- into s-.  DEFAULTS: Emacs' own global keymap, for the emacs layer's claims and prefix checks.
MAPS: a function MAPSYM → the loaded keymap or nil, for prefix checks in mode keymaps.
A binding is a plist (:id :key :map :layer [:also MAPS]); a conflict is (:key :map :kind :winner :losers),
KIND `same-key', `claim' (a key another layer uses natively) or `prefix'.
A profile with `:modal' (keys/vim.eld) places each key by `drgnx-keys-modal-key-map', and its entries for commands
outside the layer's scopes still bind their keys that land in one of its modal `:maps' (the leader keys): extras,
next to the keys of the command's own layer, never replacing them (a keys.eld entry for the command replaces both).
A keys.eld key that starts with the modal layer's leader goes in its leader map.
Claims per state (`drgnx-keys-modal-claims'): SNAPSHOTS (alist KEYMAP-SYMBOL → keymap, `drgnx-keys-modal-snapshots')
say what the modal engine binds; without them the modal profile's claims with STATES stand in.  A binding meeting
one is kept, and the conflict, (:key :map :kind claim :states STATES :winner :losers :elsewhere t), says who wins
in STATES: the higher layer.  A binding that wins gets :also, the engine's keymaps to bind it in too; the leader or
panel keys it beats are dropped."
  (let ((cmds (make-hash-table :test #'eq)) (assign (make-hash-table :test #'eq))
        (extras (make-hash-table :test #'eq))
        (stack (and (not (drgnx-keys--layers-error layers)) (drgnx-keys-modal-of-stack layers profiles)))
        (mixed (drgnx-keys-modal-mixed-p layers profiles))
        (rank 0) claims modal-layer defaults-claim problems bindings conflicts)
    (dolist (c commands) (puthash (drgnx-cmd-id c) c cmds))
    (cl-flet ((extra (entry spec layer)
                ;; ENTRY of a modal profile for a command outside its scopes: the keys in its modal maps only.
                (unless (drgnx-keys--entry-error entry)
                  (let* ((c (gethash (car entry) cmds)) (a (append (list :layer layer :rank rank)
                                                                   (drgnx-keys--entry entry spec platform)))
                         (modal (plist-get a :modal))
                         (keys (seq-filter (lambda (k)
                                             (drgnx-keys-modal-states
                                              (drgnx-keys-modal-key-map k modal (plist-get a :map) (drgnx-cmd-map c)
                                                                        (plist-get a :profile-map))
                                              modal))
                                           (plist-get a :keys))))
                    (when keys
                      (push (plist-put (plist-put a :keys keys) :everywhere nil) (gethash (car entry) extras))))))
              (take (entry spec layer where &optional no-everywhere)
                (if-let* ((why (drgnx-keys--entry-error entry)))
                    (push (format "%s: %S: %s" where entry why) problems)
                  (let ((c (gethash (car entry) cmds)))
                    (cond ((null c) (when (eq layer 'user)
                                      (push (format "%s: no command %s (in :bind)" where (car entry)) problems)))
                          (t (let ((a (append (list :layer layer :rank rank)
                                              (drgnx-keys--entry entry spec platform))))
                               (puthash (car entry) (if no-everywhere (plist-put a :everywhere nil) a) assign))))))))
      ;; Each command takes its keys from the last layer covering its scope.
      (if-let* ((why (drgnx-keys--layers-error layers)))
          (push (format "key layers %S: %s" layers why) problems)
        (pcase-dolist (`(,profile . ,scopes) layers)
          (cl-incf rank)
          (if-let* ((spec (alist-get profile profiles)))
              (progn
                (dolist (entry (plist-get spec :bind))
                  (if (or (not (consp entry)) (not (gethash (car entry) cmds))
                          (memq (drgnx-cmd-scope (gethash (car entry) cmds)) scopes))
                      ;; :everywhere keys override the modes' own: only for a profile that owns the editing keys
                      ;; (another profile's editing layer keeps its C-j in Org, lisp-interaction, …).
                      (take entry spec profile (format "key profile %s" profile)
                            (and (not (memq 'editing scopes)) (seq-some (lambda (l) (memq 'editing (cdr l))) layers)))
                    (when (plist-get spec :modal) (extra entry spec profile))))
                ;; Claims with STATES (a modal profile's) are claims per state, the others hold in every state.
                (pcase-dolist (`(,scope ,key ,desc ,states) (plist-get spec :claims))
                  (when (and (memq scope scopes) (not (and states (plist-get spec :modal))))
                    (push (list :key key :claim desc :layer profile :rank rank) claims)))
                (when (and (plist-get spec :modal) (not modal-layer))
                  (setq modal-layer
                        (list :modal (plist-get spec :modal) :profile profile :rank rank
                              :hand (seq-filter (lambda (cl) (and (memq (car cl) scopes) (nth 3 cl)))
                                                (plist-get spec :claims)))))
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
      (let* ((main (gethash (drgnx-cmd-id c) assign))
             (more (and (not (eq (plist-get main :layer) 'user)) (reverse (gethash (drgnx-cmd-id c) extras)))))
        (dolist (a (if main (cons main more) more))
          (dolist (k (plist-get a :keys))
            (if (key-valid-p k)
                (let* ((map (if-let* (((eq (plist-get a :layer) 'user)) (m (plist-get stack :modal)))
                                ;; keys.eld in a modal stack: a leader key goes in the leader map, the rest as before
                                (drgnx-keys-modal-key-map k (list :leader (plist-get m :leader)) (plist-get a :map)
                                                          (drgnx-cmd-map c)
                                                          (and (drgnx-keys-modal-leader-p k m) (plist-get stack :map)))
                              (drgnx-keys-modal-key-map k (plist-get a :modal) (plist-get a :map) (drgnx-cmd-map c)
                                                        (plist-get a :profile-map))))
                       (everywhere (and (member k (plist-get a :everywhere))
                                        (or (eq (cdr (drgnx-commands--keymap-spec map)) 'global-map)
                                            (progn (push (format "%s: %s is :everywhere in %s; only keys of the global keymap can be"
                                                                 (drgnx-cmd-id c) k (cdr (drgnx-commands--keymap-spec map)))
                                                         problems)
                                                   nil)))))
                  (push (append (list :id (drgnx-cmd-id c) :key k :map map
                                      :layer (plist-get a :layer) :rank (plist-get a :rank))
                                (and everywhere (list :everywhere t)))
                        bindings))
              (push (format "%s: \"%s\" is not a valid key" (drgnx-cmd-id c) k) problems))))))
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
      ;; An :everywhere key beats the same key in every other keymap: where one of those is as high a layer
      ;; (keys.eld's), the mode keeps it and the key is only global; either way, the sheet says so.
      (dolist (b (seq-filter (lambda (b) (plist-get b :everywhere)) bindings))
        (let* ((parsed (drgnx-keys--parse (plist-get b :key)))
               (rivals (seq-filter (lambda (r) (and (not (eq (mapsym r) (mapsym b)))
                                                    (equal (drgnx-keys--parse (plist-get r :key)) parsed)))
                                   bindings))
               (top (and rivals (seq-reduce (lambda (w r) (if (> (plist-get r :rank) (plist-get w :rank)) r w))
                                            rivals (car rivals))))
               (b-wins (and top (> (plist-get b :rank) (plist-get top :rank)))))
          (when rivals
            (unless b-wins (setf (plist-get b :everywhere) nil))
            (push (list :key (plist-get b :key) :map (mapsym top) :kind 'same-key
                        :winner (party (if b-wins b top))
                        :losers (mapcar #'party (if b-wins rivals (cons b (remq top rivals)))))
                  conflicts))))
      ;; Keys other layers use natively (claims),Emacs' defaults, and prefixes in the target keymap.
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
              (unless b-wins (setq bindings (remq b bindings)))))))
      ;; Keys the modal layer has in some states (claims per state): the binding stays, the higher layer wins in
      ;; those states only.  A binding that wins is bound in the engine's keymaps too (:also), and the leader or
      ;; panel keys it beats are dropped.
      (when modal-layer
        (let ((groups nil))
          (dolist (cl (drgnx-keys-modal-claims bindings (plist-get modal-layer :modal) (plist-get modal-layer :profile)
                                               (plist-get modal-layer :rank) snapshots (drgnx-keys-modal-panel-maps)
                                               (plist-get modal-layer :hand) mixed))
            (push cl (alist-get (plist-get cl :binding) groups nil nil #'eq)))
          (pcase-dolist (`(,b . ,cls) (nreverse groups))
            (when (memq b bindings)
              (let* ((cls (reverse cls))
                     (top (seq-reduce (lambda (w c) (if (> (plist-get c :rank) (plist-get w :rank)) c w)) cls (car cls)))
                     (b-wins (> (plist-get b :rank) (plist-get top :rank)))
                     (states (drgnx-keys-modal-order (apply #'append (mapcar (lambda (c) (plist-get c :states)) cls))))
                     (them (drgnx-keys--claim-parties cls)))
                (when b-wins
                  (nconc b (list :also (delete-dups (delq nil (mapcar (lambda (c) (and (not (plist-get c :drop)) (plist-get c :map)))
                                                                      cls)))))   ; in place: B is in `bindings'
                  (let ((drop (apply #'append (mapcar (lambda (c) (plist-get c :drop)) cls))))
                    (setq bindings (seq-remove (lambda (x) (memq x drop)) bindings))))
                (push (list :key (plist-get b :key) :map (mapsym b) :kind 'claim :states states
                            :winner (if b-wins (party b)
                                      (plist-put (copy-sequence (car (drgnx-keys--claim-parties (list top)))) :states states))
                            ;; the leader or panel keys dropped are losers too, so their commands are marked
                            :losers (if b-wins
                                        (append them (mapcar #'party (apply #'append (mapcar (lambda (c) (plist-get c :drop)) cls))))
                                      (list (party b)))
                            :elsewhere t)
                      conflicts)))))))
    (list :bindings (mapcar (lambda (b) (append (list :id (plist-get b :id) :key (plist-get b :key)
                                                      :map (plist-get b :map) :layer (plist-get b :layer))
                                                (and (plist-get b :everywhere) (list :everywhere t))
                                                (and (plist-get b :also) (list :also (plist-get b :also)))))
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
    ("Vim" . ((vim app editing window)))
    ("Emacs editing + VS Code app keys" . ((emacs editing) (vscode app window)))
    ("Vim editing + VS Code app keys" . ((vscode app window) (vim editing))))
  "Named stacks offered by `drgnx-keys-choose-profile'.  The Vim mix puts Vim last, so its Ctrl keys (C-o C-w C-b …)
stay Vim's in normal and visual state, as in VSCodeVim; VS Code's keys still work in insert state and panels.")

(defvar drgnx-keys-after-apply-functions nil
  "Functions called with the key layers at the end of every `drgnx-keys-apply' (abnormal hook).  The modal core
adds `drgnx-modal-sync-engine' so a runtime switch starts and stops the engine.  An error in one is said in
*Messages* and does not stop the others.")

(defvar drgnx-keys--defaults (copy-keymap global-map)
  "Emacs' own global bindings, taken before drgnx binds anything.")

(defvar drgnx-keys--applied nil "What drgnx bound, newest first: (MAPSYM KEY PREVIOUS OURS).")
(defvar drgnx-keys--generation 0 "Incremented by every apply; stale deferred bindings check it.")
(defvar drgnx-keys--session-layers nil "Layers chosen in this session; win over keys.eld and the default.")
(defvar drgnx-keys-last nil "The last applied resolution, plus :layers, :problems from loading too.")

(defun drgnx-keys--ensure-profiles ()
  (unless drgnx-keys-profiles
    (setq drgnx-keys-profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))))

(defun drgnx-keys--config-changed (name)
  "A listener on `drgnx-config-changed-functions': keys.eld, saved by hand (Open Config File…), applies at once.
The file is the authority then, so a stack chosen earlier in this session no longer wins over its `:layers'.
Not for drgnx's own writes: they apply what they write."
  (when (and (eq name 'keys) drgnx-config-user-save drgnx-keys-last)
    (setq drgnx-keys--session-layers nil)
    (drgnx-keys-apply)
    (when (fboundp 'drgnx-surfaces-refresh) (drgnx-surfaces-refresh))))

(add-hook 'drgnx-config-changed-functions #'drgnx-keys--config-changed)

(defun drgnx-keys-unload-function ()
  "Remove the keys.eld listener (`unload-feature'); nil, so the feature unloads as usual."
  (remove-hook 'drgnx-config-changed-functions #'drgnx-keys--config-changed)
  nil)

(defun drgnx-keys-file () (expand-file-name "keys.eld" (drgnx-user-dir)))

(defun drgnx-keys-read-user ()
  "The user's keys.eld plist (:layers :bind :unbind …) as applied (`drgnx-config-get'): the file, else its last good
copy when the file has a mistake, else the default stack; never an error.  A file is never applied in part.  The
mistake's text goes on `drgnx-keys-problems'.  The file is read at the first call and again by `drgnx-keys-apply'."
  (let ((value (drgnx-config-get 'keys)))
    (when-let* ((p (drgnx-config-problem 'keys)))
      (cl-pushnew (format "%s: %s (line %d) — not applied: its last good copy (else the default stack) is used"
                          (abbreviate-file-name (plist-get p :file)) (plist-get p :text) (plist-get p :line))
                  drgnx-keys-problems :test #'equal))
    value))

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
is lifted first (and remembered).  The prefix maps the binding makes are remembered too (with no command), so
that `drgnx-keys--restore' takes each out again once it is empty and every apply records the same.  Returns what
was lifted, \"COMMAND (PREFIX)\", or nil."
  (let* ((map (symbol-value mapsym)) (prev (drgnx-keys--lookup map key)) (lifted nil))
    (when (numberp prev)
      ;; a number also when the prefix is unbound: then there is nothing to lift; either way the prefix maps from
      ;; there on are made here (the restore removes them newest first: the deepest goes before its parent)
      (let* ((keys (key-parse key)) (n prev)
             (prefix (key-description (seq-take keys n))) (cmd (drgnx-keys--lookup map prefix)))
        (setq prev nil)
        (push (list mapsym prefix cmd :prefix) drgnx-keys--applied)
        (when cmd
          (keymap-unset map prefix t)
          (setq lifted (format "%s (%s)" cmd prefix)))
        (while (< (setq n (1+ n)) (length keys))
          (push (list mapsym (key-description (seq-take keys n)) nil :prefix) drgnx-keys--applied))))
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
  (drgnx-keys--set-everywhere nil)
  (setq drgnx-keys--applied nil))

(defvar drgnx-keys--everywhere-map (make-sparse-keymap)
  "The keys of `:everywhere' entries; above every major and minor mode map, so a profile's key works in any mode.")
(defvar drgnx-keys--everywhere-on nil "Non-nil while `drgnx-keys--everywhere-map' has keys (its switch in the alist).")
(defvar drgnx-keys--everywhere-alist (list (cons 'drgnx-keys--everywhere-on drgnx-keys--everywhere-map))
  "The entry `emulation-mode-map-alists' holds (as this symbol) while there are `:everywhere' keys.")

(defun drgnx-keys--everywhere-filter (command)
  "COMMAND, except in the minibuffer: there C-j and its like are the minibuffer's."
  (and (not (minibufferp)) command))

(defun drgnx-keys--set-everywhere (bindings)
  "Make the keys of BINDINGS that are `:everywhere' work in every mode: they go in a keymap on
`emulation-mode-map-alists', ahead of the major and minor mode maps.  No such BINDINGS: the keymap is
emptied and leaves the list, so a profile switch leaves nothing behind."
  (setcdr drgnx-keys--everywhere-map nil)
  (setq drgnx-keys--everywhere-on nil)
  (dolist (b bindings)
    (when-let* (((plist-get b :everywhere))
                (cmd (drgnx-commands-get (plist-get b :id))))
      (define-key drgnx-keys--everywhere-map (key-parse (plist-get b :key))
                  `(menu-item "" ,(drgnx-cmd-command cmd) :filter drgnx-keys--everywhere-filter))
      (setq drgnx-keys--everywhere-on t)))
  (if drgnx-keys--everywhere-on
      (add-to-list 'emulation-mode-map-alists 'drgnx-keys--everywhere-alist)
    (setq emulation-mode-map-alists (delq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))))

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
                                      (drgnx-keys--notify-problems (plist-get drgnx-keys-last :problems))
                                      (drgnx-keys--write-report)))))))))
    (cond ((and feature (not (featurep feature))) (with-eval-after-load feature (funcall bind t)))
          ((and (boundp mapsym) (keymapp (symbol-value mapsym))) (funcall bind))
          (t (push (format "%s: no keymap %s for %s" (plist-get b :id) mapsym (plist-get b :key)) drgnx-keys-problems)))))

(defun drgnx-keys--theirs (spec key)
  "What the user bound on KEY in the engine keymap SPEC since evil made it: its definition now, when that is
neither empty nor what `drgnx-keys-modal-snapshots' holds for KEY; else nil (also before the engine loads).  Called
after `drgnx-keys--restore', so drgnx's own bindings are gone."
  (let* ((sym (cdr (drgnx-commands--keymap-spec spec))) (snap (alist-get sym drgnx-keys-modal-snapshots)))
    (when (and snap (boundp sym) (keymapp (symbol-value sym)))
      (let ((now (drgnx-keys--lookup (symbol-value sym) key)))
        (and now (not (equal now (drgnx-keys--lookup snap key))) now)))))

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-notice-clear "drgnx-notice" (source &optional id))

(defun drgnx-keys--notify-problems (problems)
  "Make PROBLEMS (strings) the `warn' conditions of source `keys', each its own id; the last apply's go.
Keys problems are `warn', so they never echo.  Never signals."
  (condition-case err
      (progn
        (require 'drgnx-notice)
        (drgnx-notice-clear 'keys)
        (dolist (p problems)
          (let ((text (format "%s" p)))
            (drgnx-notify 'keys 'warn text :id text :life 'condition
                          :fix (format "fix %s (docs/guide/keys.md)"
                                       (abbreviate-file-name (expand-file-name "keys.eld" (drgnx-user-dir))))))))
    (error (message "drgnx: key problems not recorded as notices: %s" (error-message-string err)))))

(defun drgnx-keys-apply ()
  "Bind the keys of the active stack and keys.eld, replacing what drgnx bound before.
Never prompts: problems are collected in `drgnx-keys-last'.  Returns the resolution."
  (setq drgnx-keys-problems nil)
  (condition-case err
      (progn
        (drgnx-config-reread 'keys)                     ; keys.eld is read at start and at each apply
        (drgnx-keys--ensure-profiles)
        ;; Restore first: resolution then sees Emacs' own bindings, not drgnx's previous ones.
        (drgnx-keys--restore)
        (cl-incf drgnx-keys--generation)
        (let* ((user (drgnx-keys-read-user))
               (layers (or drgnx-keys--session-layers (plist-get user :layers) drgnx-keys-layers))
               (r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-profiles :layers layers
                                      :user user :platform (drgnx-platform) :defaults drgnx-keys--defaults
                                      :maps (lambda (m) (and (boundp m) (keymapp (symbol-value m)) (symbol-value m)))
                                      :snapshots drgnx-keys-modal-snapshots)))
          (drgnx-keys--set-mac-modifiers layers (plist-get user :mac-option))
          (dolist (c (drgnx-commands-all)) (setf (drgnx-cmd-bound c) nil))
          (dolist (b (plist-get r :bindings))
            (let ((cmd (drgnx-commands-get (plist-get b :id))))
              ;; A key that beats the modal engine's in some states is bound in the engine's keymaps too (:also);
              ;; `drgnx-keys--restore' puts the engine's own key back on the next apply.  A key the user bound in
              ;; such a keymap (config.el) is left alone and said.
              (dolist (map (cons (plist-get b :map) (plist-get b :also)))
                (if-let* ((theirs (and (not (eq map (plist-get b :map))) (drgnx-keys--theirs map (plist-get b :key)))))
                    (setq r (plist-put r :conflicts
                                       (append (plist-get r :conflicts)
                                               (list (list :key (plist-get b :key)
                                                           :map (cdr (drgnx-commands--keymap-spec map)) :kind 'claim
                                                           :winner (list :claim (format "%s" theirs) :layer "your own binding, kept")
                                                           :losers (list (list :id (plist-get b :id) :layer (plist-get b :layer))))))))
                  (setf (drgnx-cmd-bound cmd) (append (drgnx-cmd-bound cmd) (list (cons (plist-get b :key) map))))
                  (drgnx-keys--apply-binding (plist-put (copy-sequence b) :map map) cmd drgnx-keys--generation)))))
          (drgnx-keys--set-everywhere (plist-get r :bindings))
          (setq drgnx-keys-last (append (list :layers layers
                                              :problems (append (reverse drgnx-keys-problems) (plist-get r :problems)))
                                        r))))
    ;; Startup must go on whatever happens here (drgnx-init, a daemon): record it.
    (error (setq drgnx-keys-last (list :layers nil :bindings nil :conflicts nil
                                       :problems (append (reverse drgnx-keys-problems)
                                                         (list (format "keys could not be applied: %s"
                                                                       (error-message-string err))))))))
  (drgnx-keys--notify-problems (plist-get drgnx-keys-last :problems))
  (drgnx-keys--write-report)
  (let ((layers (plist-get drgnx-keys-last :layers)))
    (dolist (fn (default-value 'drgnx-keys-after-apply-functions))
      (condition-case err (funcall fn layers)
        (error (message "drgnx: %S failed after applying keys: %s" fn (error-message-string err))))))
  drgnx-keys-last)

;;;; Reporting

(defun drgnx-keys--party (p)
  "A conflict party P, (:id ID :layer L) or (:claim DESCRIPTION :layer L), as text."
  (format "%s (%s)"
          (if-let* ((id (plist-get p :id))) (if-let* ((c (drgnx-commands-get id))) (drgnx-cmd-title c) id)
            (plist-get p :claim))
          (or (plist-get p :layer) "Emacs")))

(defun drgnx-keys--states-text (states)
  "STATES (`drgnx-keys-modal-places') as words: \"normal, visual, motion state and panels\", \"panels\"."
  (let* ((ss (remq 'panels states)) (s (and ss (concat (mapconcat #'symbol-name ss ", ") " state"))))
    (cond ((and s (memq 'panels states)) (concat s " and panels"))
          (s)
          ((memq 'panels states) "panels")
          (t ""))))

(defun drgnx-keys--state-party (p)
  "A conflict party P of a state conflict as text: its states after the layer."
  (if-let* ((states (plist-get p :states)))
      (format "%s (%s; %s)" (string-remove-suffix (format " (%s)" (or (plist-get p :layer) "Emacs")) (drgnx-keys--party p))
              (or (plist-get p :layer) "Emacs") (drgnx-keys--states-text states))
    (drgnx-keys--party p)))

(defun drgnx-keys-conflict-text (c)
  "Conflict C as one line: KEY WINNER over LOSERS [KIND].  A conflict in some states (claims per state) names them,
and where the losing key still works: \"C-o Jump Back (vim; normal, visual, motion state) over Open File (vscode)
[claim]; Open File in insert state and panels\"."
  (let ((states (plist-get c :states)))
    (concat
     (format "%s %s over %s [%s%s]" (plist-get c :key)
             (funcall (if states #'drgnx-keys--state-party #'drgnx-keys--party) (plist-get c :winner))
             (mapconcat (if states #'drgnx-keys--state-party #'drgnx-keys--party) (plist-get c :losers) ", ")
             (plist-get c :kind)
             (if (memq (plist-get c :map) '(nil global-map)) "" (format ", in %s" (plist-get c :map))))
     (when (and states (plist-get (plist-get c :winner) :states))   ; the modal layer won: where the other key works
       (let* ((loser (car (plist-get c :losers)))
              (name (string-remove-suffix (format " (%s)" (plist-get loser :layer)) (drgnx-keys--party loser)))
              (left (seq-remove (lambda (s) (memq s states))
                                (if (eq (plist-get c :map) 'global-map) drgnx-keys-modal-places '(panels)))))
         (if left (format "; %s in %s" name (drgnx-keys--states-text left))
           (format "; %s when modal editing is off" name)))))))

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

(defvar drgnx-modal-running)
(declare-function drgnx-modal-engine-for "drgnx-modal")
(declare-function drgnx-modal-default-notes "drgnx-modal")
(declare-function drgnx-modal--engine-module "drgnx-modal-choose")

(defvar drgnx-modal-suspended)

(defun drgnx-keys--report-modal ()
  "The report's `:modal': (:engine ENGINE :module MODULE :running BOOL :pending LAYERS :suspended BOOL
:module-status STATUS).  STATUS is MODULE's status in `drgnx-modules-report' (left out when it has none).  ENGINE is
the modal engine the stack in force needs (nil without one, and nil while the user has turned modal editing off for
these layers: the engine is not wanted, not missing; SUSPENDED says so), MODULE the module that provides it (for the
doctor, which runs without the modal core), RUNNING whether it runs, PENDING the layers a non-interactive choice of
Vim keys left waiting for `drgnx sync' (`:pending-layers' in keys.eld, read as data; nil when none)."
  (let* ((layers (plist-get drgnx-keys-last :layers))
         (suspended (and (bound-and-true-p drgnx-modal-suspended) (equal (car drgnx-modal-suspended) layers) t))
         (engine (and (fboundp 'drgnx-modal-engine-for) (not suspended)
                      (ignore-errors (drgnx-modal-engine-for layers)))))
    (let* ((module (and engine (fboundp 'drgnx-modal--engine-module) (drgnx-modal--engine-module engine)))
           (status (and module (fboundp 'drgnx-modules-report)
                        (plist-get (alist-get module (drgnx-modules-report)) :status))))
      (append (list :engine engine
                    :module module
                    :running (and engine (eq engine drgnx-modal-running) t)
                    :pending (let ((drgnx-keys-problems nil)) (plist-get (drgnx-keys-read-user) :pending-layers))
                    :suspended suspended)
              (and status (list :module-status status))))))

(defun drgnx-keys--leader-menu-key ()
  "The key the Leader Menu is on in the global map (\"M-SPC\" in the Vim profile), or nil."
  (when-let* ((cmd (drgnx-commands-get 'modal-leader)))
    (car (seq-find (lambda (b) (eq (cdr (drgnx-commands--keymap-spec (cdr b))) 'global-map)) (drgnx-cmd-bound cmd)))))

(defun drgnx-keys--write-report ()
  "Write the conflicts to the state dir for `drgnx doctor' (never prompts); the problems are notices of source `keys'.
The conflicts end with the modal core's notes (`drgnx-modal-default-notes'); `:modal' says which engine the stack
needs and whether it runs."
  (condition-case err
      (drgnx-file-write (expand-file-name "keys-report.eld" (drgnx-state-dir))
                        (list :time (format-time-string "%FT%T%z") :layers (plist-get drgnx-keys-last :layers)
                              :conflicts (append (drgnx-keys-conflict-lines)
                                                 (and (fboundp 'drgnx-modal-default-notes) (drgnx-modal-default-notes)))
                              :modal (drgnx-keys--report-modal) :leader-menu-key (drgnx-keys--leader-menu-key))
                        :fsync nil)
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

(defun drgnx-keys--save-key (key data)
  "Write DATA as KEY's value into keys.eld: only that value changes; comments, layout and the other keys stay.
A keys.eld with a mistake is refused (`drgnx-config-refused'), not written."
  (drgnx-config-set 'keys key data))

(declare-function drgnx-modal-prepare "drgnx-modal-choose")
(declare-function drgnx-modal-wait-text "drgnx-modal-choose")

(defun drgnx-keys-choose-profile (name &optional interactive)
  "Switch the key profile to the preset NAME and save it in keys.eld.
A stack that needs a modal engine (Vim: evil) switches only once the engine is loaded (`drgnx-modal-prepare'):
when it is not installed, INTERACTIVE (the command) asks once to install it; called from code it waits for drgnx
sync and the next start.  Until then the current stack stays and the message says why."
  (interactive (list (completing-read "Keyboard profile: " drgnx-keys-presets nil t nil nil
                                      ;; RET at once: the current profile (else the default), never none
                                      (or (car (rassoc (plist-get drgnx-keys-last :layers) drgnx-keys-presets))
                                          (car (rassoc drgnx-keys-layers drgnx-keys-presets))))
                     t))
  (unless (assoc name drgnx-keys-presets)
    (user-error "No keyboard profile %S (profiles: %s)" name (mapconcat #'car drgnx-keys-presets ", ")))
  (drgnx-config-ensure-writable 'keys)                  ; a keys.eld with a mistake: refused before anything changes
  (require 'drgnx-modal-choose)
  (let* ((layers (cdr (assoc name drgnx-keys-presets)))
         (ready (drgnx-modal-prepare layers interactive)))
    (if (not (memq ready '(ready started installed)))
        (message "Keys: still %s — %s%s" (or (car (rassoc (plist-get drgnx-keys-last :layers) drgnx-keys-presets)) "yours")
                 (drgnx-modal-wait-text name ready)
                 (if (eq ready 'pending) " (its engine is not installed); then they switch at the next start" ""))
      ;; The engine runs once the keys are applied, before keys.eld names the stack.
      (drgnx-keys-use layers)
      (drgnx-keys--save-layers layers)
      (message "Keys: %s%s" name
               (if-let* ((n (length (drgnx-keys-conflict-lines))) ((> n 0)))
                   (format " — %d conflict%s, see Keyboard Shortcuts" n (if (= n 1) "" "s"))
                 "")))))

(provide 'drgnx-keys)
;;; drgnx-keys.el ends here
