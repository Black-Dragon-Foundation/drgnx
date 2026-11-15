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
(require 'drgnx-setting)
(require 'drgnx-settings-area)
(require 'drgnx-keys-modal)

(defvar drgnx-keys-profiles nil
  "Alist PROFILE → plist (:name :doc :bind :claims :map :mac-cmd :claims-defaults :modal :indent-tabs-mode).")

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

(defun drgnx-keys--key-map-error (key-map keys)
  "Why KEY-MAP is not a list of (KEY MAP), each KEY one of KEYS and MAP a keymap spec; nil if it is."
  (if (not (proper-list-p key-map))
      (format ":key-map %S is not a list of (KEY MAP)" key-map)
    (seq-some (lambda (km)
                (cond ((not (and (proper-list-p km) (= (length km) 2) (stringp (car km))
                                 (drgnx-keys--map-spec-p (cadr km))))
                       (format ":key-map entry %S is not (KEY MAP)" km))
                      ((not (member (car km) keys))
                       (format ":key-map names %s, which is not one of the entry's keys" (car km)))))
              key-map)))

(defun drgnx-keys--entry-error (entry)
  "Why ENTRY is not (ID KEY… [:map M] [:key-map ((KEY M)…)] [:mac K…] [:everywhere K…]) or (ID :none [REASON] [:mac
K…]); nil if it is."
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
                        (not (seq-every-p (lambda (k) (memq k '(:map :key-map :mac :everywhere)))
                                          (cl-loop for k in rest by #'cddr collect k))))
                    (format "%S is not a key (keys are strings; only :map, :key-map, :mac and :everywhere may follow them)"
                            (car rest)))
                   ((and (plist-member rest :key-map)
                         (drgnx-keys--key-map-error (plist-get rest :key-map) (seq-take-while #'stringp (cdr entry)))))
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

;;;; keys.eld, the old file
;; Your keys are settings now (`drgnx-keys-layers' … below; settings.el).  keys.eld is still defined here for one
;; reason: `drgnx-settings-migrate-maybe' reads it once to move its values into settings.el.

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
                     :doc "Your key bindings: the profile stack, entries that win over it, keys taken away (moved into settings.el).")

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
  "ENTRY (ID KEY… [:map M] [:key-map ((KEY M)…)] [:mac K…] [:everywhere K…]) or (ID :none [REASON] [:mac K…]) of
SPEC → plist (:keys [:everywhere] :map :profile-map [:key-maps] [:modal]).  :key-maps, an alist KEY → keymap spec
from the entry's `:key-map', gives a key its own keymap in place of :map (a key that works in two places: the
view's M-p and the Find field's C-p); `drgnx-keys-entry-map' reads it.  :modal is the profile's (absent for a profile
without one), which `drgnx-keys-modal-key-map' reads to place each key.  :everywhere's keys are also in :keys;
they also go in the override keymap (`drgnx-keys--set-everywhere').  On macOS, :mac's keys replace the others,
:everywhere's too (`:mac ()': none there); without it a :mac-cmd profile's C- becomes s-.  Every macOS key has
Cmd+Shift+letter as macOS sends it (`S-s-w' is s-W).  The keymap used is the entry's, else the command's, else the
profile's."
  (let ((rest (cdr entry)) keys)
    (cl-flet ((mac (opts) (mapcar (lambda (k) (drgnx-keys--mac-cmd k t)) (ensure-list (plist-get opts :mac)))))
      (if (eq (car rest) :none)
          (let ((opts (if (stringp (cadr rest)) (cddr rest) (cdr rest))))
            (append (list :keys (and (eq platform 'macos) (mac opts)) :profile-map (plist-get spec :map))
                    (and (plist-get spec :modal) (list :modal (plist-get spec :modal)))))
        (while (stringp (car rest)) (push (pop rest) keys))
        (setq keys (nreverse keys))
        (let ((everywhere (ensure-list (plist-get rest :everywhere)))
              (key-maps (mapcar (lambda (km) (cons (car km) (cadr km))) (plist-get rest :key-map))))
          (when (eq platform 'macos)
            (if (plist-member rest :mac)
                (setq keys (mac rest) everywhere nil key-maps nil)
              (let ((f (if (plist-get spec :mac-cmd) #'drgnx-keys--mac-cmd (lambda (k) (drgnx-keys--mac-cmd k t)))))
                (setq keys (mapcar f keys) everywhere (mapcar f everywhere)
                      key-maps (mapcar (lambda (km) (cons (funcall f (car km)) (cdr km))) key-maps)))))
          (append (list :keys (append keys everywhere))
                  (and everywhere (list :everywhere everywhere))
                  (list :map (plist-get rest :map) :profile-map (plist-get spec :map))
                  (and key-maps (list :key-maps key-maps))
                  (and (plist-get spec :modal) (list :modal (plist-get spec :modal)))))))))

(defun drgnx-keys-entry-map (a key)
  "The keymap spec entry A (`drgnx-keys--entry') names for KEY: its `:key-maps' one, else its :map (nil: none)."
  (or (cdr (assoc key (plist-get a :key-maps))) (plist-get a :map)))

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

(defun drgnx-keys--def-text (def)
  "DEF, a key definition, as the short text the sheet prints: a command's name, \"a lambda\" for any anonymous
function or closure (never its body), \"nothing\" for nil."
  (cond ((null def) "nothing")
        ((symbolp def) (symbol-name def))
        ((or (functionp def) (closurep def)) "a lambda")
        ((keymapp def) "a prefix map")
        ((or (stringp def) (vectorp def)) "a keyboard macro")
        ((eq (car-safe def) 'menu-item) "a menu item")
        (t "a binding")))

(defun drgnx-keys--yours-table (yours)
  "YOURS (alist KEY → DEFINITION, nil unbound) as a table from the parsed key to (DEFINITION)."
  (let ((h (make-hash-table :test #'equal)))
    (pcase-dolist (`(,k . ,d) yours) (puthash (drgnx-keys--parse k) (list d) h))
    h))

(defun drgnx-keys--yours-cover (table key)
  "How the keys of yours in TABLE (`drgnx-keys--yours-table') cover KEY: (DEFINITION) when KEY is yours, (DEFINITION
PREFIX) when a command of yours sits on PREFIX, a strict prefix of KEY (KEY is unreachable); else nil."
  (let ((v (drgnx-keys--parse key)))
    (or (gethash v table)
        (cl-loop for i from 1 below (length v)
                 for c = (gethash (seq-take v i) table)
                 when (and c (car c)) return (list (car c) (key-description (seq-take v i)))))))

(cl-defun drgnx-keys-resolve (&key commands profiles layers user platform defaults maps snapshots yours)
  "Resolve keys for COMMANDS (registry structs) → plist (:bindings :conflicts :problems :held).
PROFILES: alist PROFILE → plist.  LAYERS: list of (PROFILE SCOPE…), later wins.  USER: the
keys.eld plist (:bind :unbind), which wins over every layer.  PLATFORM: `macos' turns VS Code's
C- into s-.  DEFAULTS: Emacs' own global keymap, for the emacs layer's claims and prefix checks (`global-map',
read live, unless given).  YOURS: your own global keys, alist KEY → DEFINITION (nil: you unbound it), the top layer
above every profile and keys.eld: a binding on such a key (or under a command of yours on a prefix of it) is
dropped from :bindings and kept in :held (it comes back when you hand the key back); its conflict names the key as
your own binding, kept.  Every conflict in the global map gets :verdict, what `key-binding' answers for the key
(`drgnx-keys--def-text'), and :under PREFIX when a command of yours on PREFIX makes the key unreachable.
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
        (defaults (or defaults global-map)) (ytable (drgnx-keys--yours-table yours)) held
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
                                              (drgnx-keys-modal-key-map k modal (drgnx-keys-entry-map a k) (drgnx-cmd-map c)
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
                                      (push (format "%s: no command %s (in drgnx-keys-bind)" where (car entry))
                                            problems)))
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
      (dolist (entry (plist-get user :bind)) (take entry nil 'user "settings.el")))
    (dolist (id (plist-get user :unbind))
      (if (gethash id cmds) (puthash id (list :layer 'user :rank rank :keys nil) assign)
        (push (format "settings.el: no command %s (in drgnx-keys-unbind)" id) problems)))
    ;; Flatten, in registry order.
    (dolist (c commands)
      (let* ((main (gethash (drgnx-cmd-id c) assign))
             (more (and (not (eq (plist-get main :layer) 'user)) (reverse (gethash (drgnx-cmd-id c) extras)))))
        (dolist (a (if main (cons main more) more))
          (dolist (k (plist-get a :keys))
            (if (key-valid-p k)
                (let* ((map (if-let* (((eq (plist-get a :layer) 'user)) (m (plist-get stack :modal)))
                                ;; keys.eld in a modal stack: a leader key goes in the leader map, the rest as before
                                (drgnx-keys-modal-key-map k (list :leader (plist-get m :leader)) (drgnx-keys-entry-map a k)
                                                          (drgnx-cmd-map c)
                                                          (and (drgnx-keys-modal-leader-p k m) (plist-get stack :map)))
                              (drgnx-keys-modal-key-map k (plist-get a :modal) (drgnx-keys-entry-map a k) (drgnx-cmd-map c)
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
               (global (eq (mapsym b) 'global-map))
               (mine (and global (drgnx-keys--yours-cover ytable key)))
               (kind (and (or rivals mine) 'claim))
               (target (if global defaults (and maps (funcall maps (mapsym b))))))
          (when mine
            ;; the top layer: the key is yours, and its one conflict is this one (one verdict for the key)
            (setq conflicts (seq-remove (lambda (c) (and (equal (drgnx-keys--parse (plist-get c :key)) parsed)
                                                         (eq (plist-get c :map) 'global-map)))
                                        conflicts))
            (push (list :claim (cond ((cdr mine) (format "%s on %s" (drgnx-keys--def-text (car mine)) (cadr mine)))
                                     ((car mine) (drgnx-keys--def-text (car mine)))
                                     (t "nothing (you unbound it)"))
                        :layer "your own binding, kept" :rank most-positive-fixnum :under (cadr mine))
                  rivals))
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
              (push (append (list :key key :map (mapsym b) :kind kind
                                  :winner (if b-wins (party b) top-party)
                                  :losers (if b-wins them (cons (party b) (remq top-party them))))
                            (and mine (plist-get top :under) (list :under (plist-get top :under))))
                    conflicts)
              (unless b-wins
                (when mine (push b held))
                (setq bindings (remq b bindings)))))))
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
    (cl-flet ((out (bs) (mapcar (lambda (b) (append (list :id (plist-get b :id) :key (plist-get b :key)
                                                          :map (plist-get b :map) :layer (plist-get b :layer))
                                                    (and (plist-get b :everywhere) (list :everywhere t))
                                                    (and (plist-get b :also) (list :also (plist-get b :also)))))
                                bs)))
      (list :bindings (out bindings)
            :held (out (nreverse held))
            :conflicts (mapcar (lambda (c) (drgnx-keys--with-verdict c cmds ytable)) (nreverse conflicts))
            :problems (nreverse problems)))))

(defun drgnx-keys--with-verdict (c cmds ytable)
  "Conflict C with :verdict, the text `key-binding' answers for its key (`drgnx-keys--def-text'), when that is
known: a conflict in the global map that is not per modal state, and not a Emacs prefix kept over a drgnx key.  CMDS
is the resolver's table of commands, YTABLE that of yours."
  (let ((w (plist-get c :winner)))
    (if (or (not (memq (plist-get c :map) '(nil global-map))) (plist-get c :states))
        c
      (if-let* ((text (cond ((plist-get c :under) "nothing")
                            ((plist-get w :id) (when-let* ((cmd (gethash (plist-get w :id) cmds)))
                                                 (drgnx-keys--def-text (drgnx-cmd-command cmd))))
                            ((equal (plist-get w :layer) "your own binding, kept")
                             (drgnx-keys--def-text (car (gethash (drgnx-keys--parse (plist-get c :key)) ytable))))
                            ((not (eq (plist-get c :kind) 'prefix)) (plist-get w :claim)))))
          (append c (list :verdict text))
        c))))

;;;; Applying

(drgnx-defsetting drgnx-keys-layers '((vscode app editing window))
  "The key-profile stack: (PROFILE SCOPE…), later layers win.  Settings: Keyboard Profile sets it."
  :type '(repeat (cons symbol (repeat symbol))) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never :apply #'drgnx-keys--layers-settings-apply
  :schema '(pred drgnx-keys--layers-ok-p "a profile stack such as ((emacs editing) (vscode app window))"))

(drgnx-defsetting drgnx-keys-pending-layers nil
  "A stack waiting for its modal engine to be installed (drgnx sync); nil when none waits."
  :type '(repeat (cons symbol (repeat symbol))) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never :apply #'drgnx-keys--settings-apply
  :schema '(or null (pred drgnx-keys--layers-ok-p "a profile stack such as ((vim app editing window))")))

(drgnx-defsetting drgnx-keys-bind nil
  "Command id -> keys, entries (ID KEY… [:map MAP]) that win over every layer.  Keyboard Shortcuts writes them."
  :type '(repeat sexp) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never :apply #'drgnx-keys--settings-apply
  :schema '(list-of (pred drgnx-keys--bind-entry-p "(ID KEY… [:map MAP])")))

(drgnx-defsetting drgnx-keys-unbind nil
  "Command ids that get no key, whatever the layers say."
  :type '(repeat symbol) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never :apply #'drgnx-keys--settings-apply
  :schema '(list-of symbol))

(drgnx-defsetting drgnx-keys-mac-option nil
  "What the left Option key does on a Mac with VS Code's keys: `characters' (it types @ # { [) or `meta'; nil: Meta."
  :type '(choice (const :tag "Meta" nil) (const characters) (const meta)) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never :apply #'drgnx-keys--settings-apply
  :schema '(or null (pred drgnx-keys--mac-option-p "characters or meta")))

(drgnx-defsetting drgnx-keys-tty-fallback nil
  "Chord -> another Alt key for it, in a legacy terminal: ((\"C-S-p\" . \"M-Z\"))."
  :type '(alist :key-type string :value-type string) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never :apply #'drgnx-keys--settings-apply
  :schema 'any)

(defconst drgnx-keys--settings
  '((:layers . drgnx-keys-layers) (:pending-layers . drgnx-keys-pending-layers) (:bind . drgnx-keys-bind)
    (:unbind . drgnx-keys-unbind) (:mac-option . drgnx-keys-mac-option) (:tty-fallback . drgnx-keys-tty-fallback))
  "keys.eld's keys and the settings that hold them now.")

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

(defvar drgnx-keys--generation 0 "Incremented by every apply; stale deferred bindings check it.")
(defvar drgnx-keys--session-layers nil "Layers chosen in this session; win over keys.eld and the default.")
(defvar drgnx-keys-last nil "The last applied resolution, plus :layers, :problems from loading too.")

(defun drgnx-keys--ensure-profiles ()
  (unless drgnx-keys-profiles
    (setq drgnx-keys-profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))))

(defun drgnx-keys--settings-apply ()
  "The `:apply' of the keys settings: bind the keys again (and refresh the menus), once keys were applied here.
Runs on an idle tick after settings.el, a `setq' or the Keyboard Shortcuts editor changed one of them."
  (when drgnx-keys-last
    (drgnx-keys-apply)
    (when (fboundp 'drgnx-surfaces-refresh) (drgnx-surfaces-refresh))))

(defun drgnx-keys--layers-settings-apply ()
  "The `:apply' of `drgnx-keys-layers': the settings are the authority, so a stack chosen earlier in this session no
longer wins over them; then as `drgnx-keys--settings-apply'."
  (setq drgnx-keys--session-layers nil)
  (drgnx-keys--settings-apply))

(defun drgnx-keys--layers ()
  "The stack `drgnx-keys-layers' holds; nil (no stack) gives its standard value."
  (or drgnx-keys-layers (eval (car (get 'drgnx-keys-layers 'standard-value)) t)))

(defun drgnx-keys-read-user ()
  "The user's keys as a plist (:layers :pending-layers :bind :unbind :mac-option :tty-fallback), from the settings
\(`drgnx-keys--settings'): their values now, whatever set them (settings.el, a `setq' in config.el), and settings.el's
in a batch command that has not applied it (`drgnx-settings-area-values'); never an error."
  (let ((values (drgnx-settings-area-values (mapcar #'cdr drgnx-keys--settings))))
    (cl-loop for (key . var) in drgnx-keys--settings append (list key (cdr (assq var values))))))

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

;;;; The global layers: yours, then the profile's, then `global-map'

;; The global map is composed: `drgnx-keys-user-map' (your keys), `drgnx-keys--profile-map' (the profile's global
;; keys, refilled by every apply) and `global-map' (Emacs's and the packages', never written by drgnx).  Nidhogg's
;; `nidhogg-define-key-redirect-function' sees every `define-key', from Lisp or native code: one of yours goes into
;; your map, any other goes into `global-map', and none lands in the composed map or a profile prefix map.

(defvar nidhogg-define-key-redirect-function)

(defvar drgnx-keys-user-map (make-sparse-keymap)
  "Your own global keys: what your Lisp files (config.el, its `with-eval-after-load' bodies) and your keyboard
commands, M-: and emacsclient --eval bind in the global map.  Above the profile's keys, kept through applies and
profile switches.  A nil here (you unbound a key) shadows the profile's key and Emacs's.")

(defvar drgnx-keys--profile-map (make-sparse-keymap)
  "The profile's global keys, refilled by every apply; without the keys of yours (`drgnx-keys--yours').")

(defvar drgnx-keys--global-map (make-composed-keymap (list drgnx-keys-user-map drgnx-keys--profile-map) global-map)
  "The global map drgnx installs: your keys, then the profile's, then `global-map'.")

(defvar drgnx-keys--yours (make-hash-table :test #'equal)
  "Your global keys: key description → (DEF . SOURCE), SOURCE the Lisp file of yours that bound it (its name without
the extension: .el, .elc and .eln are one file; an after-load body counts as the file that registered it) or
`command' (a keyboard command, M-:, emacsclient --eval).  DEF nil: you unbound the key.  When a file of yours has
loaded again, its entries that load did not write go (`drgnx-keys--loaded'); a command's stay.")

(defvar drgnx-keys--yours-in-maps (make-hash-table :test #'equal)
  "Your keys in the maps a profile or settings `:map' names (`drgnx-keys--named-maps'): (MAPSYM . KEY) → (DEF .
SOURCE), as in `drgnx-keys--yours'.  The write itself stays in the map; the foreign layer steps aside for the key.")

(defvar drgnx-keys--named-maps nil
  "The keymap symbols the last apply's profile and settings keys name, besides the global map and the modal engine's:
drgnx's own maps and foreign ones.  Watched (`drgnx-keys--watch-named'): your writes into them are recorded.")

(defvar drgnx-keys--foreign-last nil
  "What the foreign layer was last made from (`drgnx-keys--fill-foreign''s TARGETS), to make it again when a key of
yours in one of those maps comes or goes.")

(defvar drgnx-keys--everywhere-events nil
  "The events of the last apply's `:everywhere' keys (one stroke each), watched in every keymap.")

(defvar drgnx-keys--yours-everywhere nil
  "Your bindings of an `:everywhere' key in other keymaps: ((EVENT . KEYMAP) . (DEF . SOURCE)) each, KEYMAP compared
by identity.  The `:everywhere' entry steps aside wherever such a keymap is active.")

(defvar drgnx-keys--loading (make-hash-table :test #'equal)
  "SOURCE (a file of yours, as in `drgnx-keys--yours') → (LOAD . ITEMS): the keys its load now running wrote, LOAD that
load's `load-file-name', an item a global key's text or (MAPSYM . KEY).  Only writes of the file's own load count
\(not an after-load body of it that runs while another file loads); a load that fails takes its list with it
\(`drgnx-keys--load-scope').")

(defvar drgnx-keys--load-sources nil
  "Within a Lisp `load' (`drgnx-keys--load-scope'): the sources whose `drgnx-keys--loading' lists that load began.")

(defvar drgnx-keys--stale nil
  "Non-nil when a key of yours changed since the last apply: the sheet and the key labels are settled first
\(`drgnx-keys-settle').")

(defvar drgnx-keys--profile-keys nil "The profile's global keys of the last apply: ((KEY . DEF) …), KEY a description.")

(defvar drgnx-keys--paths (make-hash-table :test #'eq :weakness 'key)
  "Keymap → (LAYER . PREFIX): the prefix maps of `global-map' (LAYER `global'), of the profile map (`profile') and
of your map (`user'), and the three maps themselves, PREFIX the key vector that reaches the map.")

(defvar drgnx-keys--after-load nil
  "Non-nil while a file's after-load bodies run (`do-after-load-evaluation').  `load' has unbound `load-file-name' by
then, so the file rule cannot tell them apart: only a body you registered is yours (`drgnx-keys--yours-body').")
(defvar drgnx-keys--yours-body nil
  "While a scope of yours runs (an after-load body you registered, `drgnx-keys--after-load-yours'; `drgnx-keys-mine'):
\(FILE . LOAD), FILE the file that registered the body or holds the macro (nil: a command, M-:) and LOAD the
`load-file-name' when the scope began.  A write while that same load runs is the scope's; a file loaded inside it
moves `load-file-name' on and is judged by the file rule (`drgnx-keys--yours-p').")
(defvar drgnx-keys--server-eval nil "Non-nil while the server evaluates an emacsclient --eval.")
(defvar drgnx-keys--in-timer nil
  "Non-nil while a timer runs (`drgnx-keys--timer-scope'): a timer is never you, even inside a command's wait.")

(defun drgnx-keys-redirect-available-p ()
  "Non-nil when this Emacs has Nidhogg's define-key redirect, which tells your bindings from packages'."
  (boundp 'nidhogg-define-key-redirect-function))

(defun drgnx-keys--note-paths (map layer prefix)
  "Record MAP and its prefix maps (to depth 4) as LAYER's, MAP reached by PREFIX."
  (puthash map (cons layer prefix) drgnx-keys--paths)
  (when (< (length prefix) 4)
    (map-keymap (lambda (ev def)
                  (let ((sub (and (not (memq ev '(menu-bar tool-bar tab-bar remap))) (keymapp def)
                                  (not (functionp def)) (drgnx-keys--keymap-of def))))
                    (when (and sub (not (gethash sub drgnx-keys--paths)))
                      (drgnx-keys--note-paths sub layer (vconcat prefix (vector ev))))))
                map)))

(defun drgnx-keys--keymap-of (def)
  "DEF's keymap when it is a keymap or a symbol whose function is one, else nil."
  (cond ((and (consp def) (eq (car def) 'keymap)) def)
        ((and (symbolp def) (fboundp def) (keymapp (symbol-function def))) (symbol-function def))))

(defun drgnx-keys--refresh-paths ()
  "Record the three layers' maps and their prefix maps afresh."
  (clrhash drgnx-keys--paths)
  (drgnx-keys--note-paths drgnx-keys-user-map 'user [])
  (drgnx-keys--note-paths drgnx-keys--profile-map 'profile [])
  (drgnx-keys--note-paths global-map 'global [])
  (puthash drgnx-keys--global-map '(composed . []) drgnx-keys--paths)
  (drgnx-keys--watch-named))

(defun drgnx-keys--yours-p ()
  "Whether a write into the global map now is yours: from a Lisp file of yours while it loads (whatever loads it:
startup, M-x load-file), an after-load body you registered (not a file it loads in turn), emacsclient --eval, or a
keyboard command (no file loading, no after-load body, no timer, process filter or sentinel running: Emacs binds
`last-nonmenu-event' to t around a filter and a sentinel, emacsclient's own included, so that test comes after it).
A scope of yours (`drgnx-keys-mine', a body you registered) counts inside a hook, a timer or a filter, and while
the load it began in runs; a file loaded inside it is judged by the file rule: a package required there is not you."
  (cond ((and drgnx-keys--yours-body (eq load-file-name (cdr drgnx-keys--yours-body))) t)
        (load-file-name
         (and (fboundp 'drgnx-settings-prov--user-file-p) (drgnx-settings-prov--user-file-p load-file-name)))
        (drgnx-keys--after-load nil)
        (drgnx-keys--server-eval t)
        ((eq last-nonmenu-event t) nil)
        (drgnx-keys--in-timer nil)
        (t (and this-command t))))

(defun drgnx-keys--source ()
  "Where a write of yours now comes from: the Lisp file (without its extension) or `command'.  In an after-load body
you registered, the registering file, unless a file loads inside the body (`load-file-name' moved on)."
  (let* ((body drgnx-keys--yours-body)
         (file (if (and body (eq load-file-name (cdr body))) (car body) load-file-name)))
    (if (and file (not drgnx-keys--server-eval)) (file-name-sans-extension (file-truename file)) 'command)))

(defun drgnx-keys--note-load (src item)
  "Note ITEM (a global key's text, or (MAPSYM . KEY)) in the list of the load of SRC now running, when the write
comes from that file's own load."
  (when (and load-file-name (stringp src)
             (equal src (file-name-sans-extension (file-truename load-file-name))))
    (let ((cell (gethash src drgnx-keys--loading)))
      (unless (eq (car cell) load-file-name)
        (setq cell (list load-file-name))
        (push src drgnx-keys--load-sources))
      (push item (cdr cell))
      (puthash src cell drgnx-keys--loading))))

(defmacro drgnx-keys-mine (&rest body)
  "Run BODY with its global key writes counted as yours.  A write your config makes later from a hook function or a
timer is outside every scope drgnx can see, so it counts as a package's (below the profile's keys); wrap it in this
macro, or bind the key at the top of `config.el'.  In `config.el' the keys it binds go with a reload of that file.  A
file BODY loads is judged by itself (`drgnx-keys--yours-p'): a package's writes stay the package's."
  (declare (indent 0))
  `(let ((drgnx-keys--yours-body (cons ,(or (macroexp-file-name) load-file-name) load-file-name)))
     ,@body))

(defun drgnx-keys--submap (map prefix)
  "MAP's prefix map at PREFIX (a vector), made when there is none; recorded in `drgnx-keys--paths'."
  (if (= (length prefix) 0) map
    (let ((sub (lookup-key map prefix)))
      (unless (keymapp sub)
        (setq sub (make-sparse-keymap))
        (let ((nidhogg-define-key-redirect-function nil)) (define-key map prefix sub)))
      (unless (gethash sub drgnx-keys--paths)
        (puthash sub (cons (car (gethash map drgnx-keys--paths)) prefix) drgnx-keys--paths))
      sub)))

(defun drgnx-keys--global-at (prefix)
  "`global-map''s prefix map at PREFIX, for a write under it that is not yours.  Where `global-map' binds a command on
PREFIX it gives `:non-prefix' (the write must fail as it would in any Emacs); where it binds nothing, the prefix map is
made."
  (if (= (length prefix) 0) global-map
    (let ((sub (lookup-key global-map prefix)))
      (cond ((keymapp sub) sub)
            ((null sub) (drgnx-keys--submap global-map prefix))
            (t :non-prefix)))))

(defun drgnx-keys--key-text (prefix key)
  "PREFIX (a vector) and KEY as one key description."
  (string-trim (concat (key-description prefix) " " (key-description key))))

(defun drgnx-keys--take (text def remove)
  "Your write of DEF (or a REMOVE) on the global key TEXT: record it, and take the key out of the profile's layers
at once, or give it back to them."
  (let ((nidhogg-define-key-redirect-function nil) (k (key-parse text)) (src (drgnx-keys--source)))
    (drgnx-keys--note-load src text)
    (if remove
        (progn (remhash text drgnx-keys--yours)
               (when-let* ((d (assoc text drgnx-keys--profile-keys))) (drgnx-keys--define drgnx-keys--profile-map k (cdr d))))
      (puthash text (cons def src) drgnx-keys--yours)
      (when (lookup-key drgnx-keys--profile-map k) (ignore-errors (define-key drgnx-keys--profile-map k nil t))))
    (drgnx-keys--mark-stale)
    (drgnx-keys--set-everywhere (append (plist-get drgnx-keys-last :bindings) (plist-get drgnx-keys-last :held)))))

(declare-function drgnx-timer-start "drgnx-timer")
(defvar drgnx-keys--settling nil "Non-nil while `drgnx-keys-settle' applies.")

(defun drgnx-keys--mark-stale ()
  "A key of yours changed: the next sheet settles first, and so does an idle moment."
  (unless drgnx-keys--stale
    (setq drgnx-keys--stale t)
    (unless (or noninteractive (not (fboundp 'drgnx-timer-start))) (drgnx-timer-start 'keys-settle 0.2 #'drgnx-keys-settle :idle t :owner :core))))

(defun drgnx-keys-settle ()
  "Apply the keys again when a key of yours changed since the last apply, so what the sheet, the key labels and
the conflicts say is what `key-binding' answers.  Never prompts."
  (when (and drgnx-keys--stale drgnx-keys-last (not drgnx-keys--settling))
    (let ((drgnx-keys--settling t)) (drgnx-keys-apply))))

(defun drgnx-keys--yours-alist ()
  "Your global keys as the resolver takes them (`drgnx-keys-resolve' :yours): ((KEY . DEFINITION) …)."
  (let (out) (maphash (lambda (k v) (push (cons k (car v)) out)) drgnx-keys--yours) out))

(defconst drgnx-keys--chrome-events
  '(menu-bar tool-bar tab-bar tab-line mode-line header-line left-fringe right-fringe left-margin right-margin
             vertical-line vertical-scroll-bar horizontal-scroll-bar)
  "Events of the frame's chrome: a write of a key starting with one is never redirected (menus are not keys).")

(defun drgnx-keys--redirect (map key def remove)
  "`nidhogg-define-key-redirect-function': a write into the global map's layers goes to your map when it is yours
\(`drgnx-keys--yours-p'), else to `global-map'; any other write stays where it was asked for (one hash lookup: C
calls `define-key' too, on a tty's `input-decode-map' at its set-up).  It never signals for its own trouble, which
it records as a problem and leaves the write where it was asked for; the one error it gives is the one any Emacs
gives, for a key under a prefix `global-map' binds to a command (`drgnx-keys--global-at').
A write of yours into a map a profile names (`drgnx-keys--named-maps'), or of an `:everywhere' key into any map, stays
where it was asked for and is recorded (`drgnx-keys--take-in', `drgnx-keys--take-everywhere')."
  (let ((path (gethash map drgnx-keys--paths)))
    (cond ((and (> (length key) 0) (memq (aref key 0) drgnx-keys--chrome-events)) nil)
          ((eq (car-safe (car path)) 'map)
           (if (drgnx-keys--aux-p def)        ; evil makes the map's auxiliary keymap: watched, not a key
               (puthash def (cons (car path) (vconcat (cdr path) key)) drgnx-keys--paths)
             (ignore-errors (when (drgnx-keys--yours-p)
                              (drgnx-keys--take-in (cdar path) (drgnx-keys--key-text (cdr path) key) def remove))))
           nil)
          ((eq (car-safe (car path)) 'evil) (drgnx-keys--redirect-evil path key def remove))
          (path (drgnx-keys--redirect-global path key def remove))
          ((and drgnx-keys--everywhere-events (= (length key) 1))
           (let ((ev (if (stringp key) (car (listify-key-sequence key)) (aref key 0))))
             (when (memq ev drgnx-keys--everywhere-events)
               (ignore-errors (when (drgnx-keys--yours-p) (drgnx-keys--take-everywhere ev map def remove)))))
           nil))))

(defun drgnx-keys--redirect-evil (path key def remove)
  "`drgnx-keys--redirect' for a write into evil's state map of PATH ((evil . STATE) . PREFIX): yours goes to your map's
auxiliary keymap for STATE (key text \"<normal-state> g d\", `drgnx-keys--take'), any other stays in evil's map."
  (condition-case err
      (when (drgnx-keys--yours-p)
        (let ((prefix (vconcat (vector (drgnx-keys--state-event (cdar path))) (cdr path))))
          (drgnx-keys--aux drgnx-keys-user-map (aref prefix 0))
          (prog1 (drgnx-keys--submap drgnx-keys-user-map prefix)
            (drgnx-keys--take (drgnx-keys--key-text prefix key) def remove)
            (drgnx-keys--normalize-evil))))
    (error (push (format "your evil key %s could not be placed: %s"
                         (ignore-errors (drgnx-keys--key-text (cdr path) key)) (error-message-string err))
                 drgnx-keys-problems)
           nil)))

(defun drgnx-keys--redirect-global (path key def remove)
  "`drgnx-keys--redirect' for a write into the global map's layers: PATH is the written map's (LAYER . PREFIX)."
  (let* ((layer (car path)) (prefix (cdr path))
         (to (condition-case err
                 (if (drgnx-keys--yours-p)
                     (prog1 (unless (eq layer 'user) (drgnx-keys--submap drgnx-keys-user-map prefix))
                       (drgnx-keys--take (drgnx-keys--key-text prefix key) def remove))
                   (unless (eq layer 'global) (drgnx-keys--global-at prefix)))
               (error (push (format "the global key %s could not be placed: %s"
                                    (ignore-errors (drgnx-keys--key-text prefix key)) (error-message-string err))
                            drgnx-keys-problems)
                      nil))))
    (if (eq to :non-prefix)
        (error "Key sequence %s starts with non-prefix key %s"
               (key-description (vconcat prefix (if (stringp key) (listify-key-sequence key) key)))
               (key-description prefix))
      to)))

(defun drgnx-keys--after-load-yours (args)
  "Filter of `eval-after-load''s ARGS: a body you register (`drgnx-keys--yours-p') makes writes that are yours when
it runs (not those of a file it loads in turn, nor of that file's after-load bodies)."
  (let ((form (nth 1 args)))
    (if (and (functionp form) (drgnx-keys--yours-p))
        (let ((from (and (stringp (drgnx-keys--source))
                         (if (and drgnx-keys--yours-body (eq load-file-name (cdr drgnx-keys--yours-body)))
                             (car drgnx-keys--yours-body)
                           load-file-name))))
          (list (car args)
                (lambda () (let ((drgnx-keys--yours-body (cons from load-file-name))) (funcall form)))))
      args)))

(defun drgnx-keys--after-load-scope (fn &rest args)
  "Around `do-after-load-evaluation' (FN, ARGS): the after-load bodies of a file are not yours unless you
registered them (`drgnx-keys--after-load-yours'), whatever command or body loaded the file.  A map a profile names that
this load made is watched before those bodies run (`drgnx-keys--watch-named')."
  (drgnx-keys--watch-named)
  (let ((drgnx-keys--after-load t) (drgnx-keys--yours-body nil)) (apply fn args)))

(defun drgnx-keys--load-scope (fn &rest args)
  "Around `load' (FN, ARGS) from Lisp: a load that stops with an error drops the per-load lists it began
\(`drgnx-keys--loading'), so the next load of the file is not judged by them.  (A `require' calls the C `load'
directly: a file of yours it loads that fails leaves its list to the enclosing Lisp `load'.)"
  (let ((drgnx-keys--load-sources nil) (ok nil))
    (unwind-protect (prog1 (apply fn args) (setq ok t))
      (unless ok (dolist (s drgnx-keys--load-sources) (remhash s drgnx-keys--loading))))))

(defun drgnx-keys--timer-scope (fn &rest args)
  "Around `timer-event-handler' (FN, ARGS): what a timer binds is not yours, even when it runs inside a command's
wait (`sit-for', `accept-process-output')."
  (let ((drgnx-keys--in-timer t)) (apply fn args)))

(defun drgnx-keys--loaded (file)
  "On `after-load-functions': FILE has loaded (whatever loaded it: the start, M-x load-file, a `load' in config.el).
The keys it bound in an earlier load and not in this one leave your map, and the profile's key comes back on each.
Keys you bound by command stay.  A load that fails midway does not get here, so nothing is forgotten then."
  (let* ((base (file-name-sans-extension (file-truename file)))
         (kept (cdr (gethash base drgnx-keys--loading))))
    (remhash base drgnx-keys--loading)
    (drgnx-keys--forget-file base kept)))

(defun drgnx-keys--forget-file (base &optional kept)
  "Forget the keys of yours whose source is BASE (a file's truename without its extension), except those in KEPT
\(global key descriptions, or (MAPSYM . KEY)): a global one leaves your map, and the profile's key comes back on each."
  (let (gone in-maps)
    (maphash (lambda (k v) (when (and (equal (cdr v) base) (not (member k kept))) (push k in-maps)))
             drgnx-keys--yours-in-maps)
    (when in-maps
      (dolist (k in-maps) (remhash k drgnx-keys--yours-in-maps))
      (drgnx-keys--fill-foreign drgnx-keys--foreign-last))
    (maphash (lambda (k v) (when (and (equal (cdr v) base) (not (member k kept))) (push k gone))) drgnx-keys--yours)
    (when gone
      (let ((nidhogg-define-key-redirect-function nil))
        (dolist (k gone)
          (remhash k drgnx-keys--yours)
          (ignore-errors (define-key drgnx-keys-user-map (key-parse k) nil t))
          (when-let* ((d (assoc k drgnx-keys--profile-keys))) (drgnx-keys--define drgnx-keys--profile-map (key-parse k) (cdr d)))))
      (drgnx-keys--mark-stale)
      (drgnx-keys--set-everywhere (append (plist-get drgnx-keys-last :bindings) (plist-get drgnx-keys-last :held))))))

(defun drgnx-keys--take-in (sym text def remove)
  "Your write of DEF (or a REMOVE) on KEY TEXT in keymap SYM, a map a profile names: record it, and make the foreign
layer again, which steps aside for it (`drgnx-keys--yours-blocks-p')."
  (let ((src (drgnx-keys--source)))
    (drgnx-keys--note-load src (cons sym text))
    (if remove (remhash (cons sym text) drgnx-keys--yours-in-maps)
      (puthash (cons sym text) (cons def src) drgnx-keys--yours-in-maps))
    (when (assq sym drgnx-keys--foreign-last) (drgnx-keys--fill-foreign drgnx-keys--foreign-last))))

(defun drgnx-keys--take-everywhere (event map def remove)
  "Your write of DEF (or a REMOVE) on the `:everywhere' key EVENT in keymap MAP: record it; the entry steps aside
where MAP is active (`drgnx-keys--everywhere-filter')."
  (setq drgnx-keys--yours-everywhere
        (seq-remove (lambda (y) (and (eq (caar y) event) (eq (cdar y) map))) drgnx-keys--yours-everywhere))
  (unless remove (push (cons (cons event map) (cons def (drgnx-keys--source))) drgnx-keys--yours-everywhere)))

(defun drgnx-keys--yours-blocks-p (sym key)
  "Whether a key of yours in keymap SYM is KEY (a description), a prefix of it, or under it: the profile's KEY in
SYM's layer steps aside."
  (catch 'hit
    (maphash (lambda (k _)
               (when (and (eq (car k) sym)
                          (let ((y (cdr k)))
                            (or (equal y key) (string-prefix-p (concat y " ") key) (string-prefix-p (concat key " ") y))))
                 (throw 'hit t)))
             drgnx-keys--yours-in-maps)
    nil))

(defun drgnx-keys--watch-named ()
  "Watch the maps of `drgnx-keys--named-maps' that exist now, and their own prefix maps (not a parent's): a write
into one is recorded when it is yours (`drgnx-keys--redirect').  A map a package makes again at its load is watched
afresh by identity."
  (dolist (sym drgnx-keys--named-maps)
    (when (and (boundp sym) (keymapp (symbol-value sym)) (not (gethash (symbol-value sym) drgnx-keys--paths)))
      (drgnx-keys--note-own-paths (symbol-value sym) (cons 'map sym) [])))
  (drgnx-keys--watch-evil))

(defun drgnx-keys--note-own-paths (map layer prefix)
  "Record MAP and its own prefix maps (to depth 4; a parent's are left out) as LAYER's, MAP reached by PREFIX."
  (puthash map (cons layer prefix) drgnx-keys--paths)
  (when (< (length prefix) 4)
    (map-keymap-internal
     (lambda (ev def)
       (let ((sub (and (not (memq ev '(menu-bar tool-bar tab-bar remap))) (keymapp def) (not (functionp def))
                       (drgnx-keys--keymap-of def))))
         (when (and sub (not (gethash sub drgnx-keys--paths)))
           (drgnx-keys--note-own-paths sub layer (vconcat prefix (vector ev))))))
     map)))

(defun drgnx-keys--server-eval-yours (fn &rest args)
  "Around `server-eval-and-print' (FN, ARGS): emacsclient --eval is you."
  (let ((drgnx-keys--server-eval t)) (apply fn args)))

(defvar drgnx-keys--guard-said nil "Non-nil once the guard said a command replaced the global map.")

(defun drgnx-keys--guard-global-map ()
  "On `post-command-hook': put the composed global map back if a command left another one current, saying so once.
Not while the minibuffer reads or a keyboard macro runs or is recorded (a command there may swap maps on purpose)."
  (unless (or (eq (current-global-map) drgnx-keys--global-map) (minibufferp) executing-kbd-macro defining-kbd-macro)
    (unless drgnx-keys--guard-said
      (setq drgnx-keys--guard-said t)
      (push (format "%s made another keymap the global map: drgnx's keys were put back" this-command)
            drgnx-keys-problems))
    (use-global-map drgnx-keys--global-map)))

(defconst drgnx-keys--global-readers
  '(comint-delchar-or-maybe-eof comint-insert-input message-tab tutorial--find-changed-keys isearchb)
  "Emacs functions that read the variable `global-map' as \"the global binding\" (comint's C-d and mouse paste,
message's TAB, the tutorial's changed keys, isearchb where an Emacs still has it).  drgnx composes the global map
\(your keys, the profile's, then `global-map'), so a key the profile binds would not be seen there: each runs with
`global-map' bound to the map that is global now (`drgnx-keys--with-live-global-map').  An advice on a function that is
not defined (isearchb is not in every Emacs) waits for it.  Calc scans `global-map' for DEL keys once, at load: a
known gap (the spec's decisions, T11).  The advice is part of the keys core: on for the session, removed by
`drgnx-keys--uninstall-redirect' (`unload-feature').")

(defun drgnx-keys--with-live-global-map (fn &rest args)
  "Around advice: call FN (with ARGS) with `global-map' bound to `current-global-map', the composed map, while the
composed map is the current one and Nidhogg's redirect is on.  Then a package that loads inside FN and writes
`global-map' reaches the redirect, which sends the write to the real map.  Otherwise FN runs as it is."
  (if (and (eq (current-global-map) drgnx-keys--global-map) (drgnx-keys-redirect-available-p)
           (bound-and-true-p nidhogg-define-key-redirect-function))
      (let ((global-map (current-global-map))) (apply fn args))
    (apply fn args)))

(defun drgnx-keys--install-redirect ()
  "Turn the redirect on, when the keys core loads: config.el and your Lisp files load before the first apply, and
their global keys must already land in your map.  Without the redirect (an Emacs that is not Nidhogg) your
bindings cannot be told from packages': the first apply says so as a problem (`drgnx-keys--install-global')."
  (drgnx-keys--refresh-paths)
  (pcase-dolist (`(,sym ,how ,fn) (drgnx-keys--advices)) (advice-add sym how fn))
  (add-hook 'after-load-functions #'drgnx-keys--loaded)
  (when (drgnx-keys-redirect-available-p)
    (setq nidhogg-define-key-redirect-function #'drgnx-keys--redirect)))

(defun drgnx-keys--advices ()
  "Every advice the keys core puts on Emacs, (SYMBOL HOW FUNCTION): those that record what is yours (after-load
bodies, emacsclient --eval, timers, a load that fails) and the readers of `global-map'.  They are on for the session,
with `drgnx-keys--loaded' on `after-load-functions'; `drgnx-keys--uninstall-redirect' takes them all off."
  (append (list (list 'eval-after-load :filter-args #'drgnx-keys--after-load-yours)
                (list 'do-after-load-evaluation :around #'drgnx-keys--after-load-scope)
                (list 'server-eval-and-print :around #'drgnx-keys--server-eval-yours)
                (list 'timer-event-handler :around #'drgnx-keys--timer-scope)
                (list 'load :around #'drgnx-keys--load-scope))
          (mapcar (lambda (f) (list f :around #'drgnx-keys--with-live-global-map)) drgnx-keys--global-readers)))

(defun drgnx-keys--uninstall-redirect ()
  "The owner of `drgnx-keys--install-redirect': the redirect off, every advice of `drgnx-keys--advices' removed and
the reload rule off `after-load-functions'."
  (pcase-dolist (`(,sym ,_how ,fn) (drgnx-keys--advices)) (advice-remove sym fn))
  (remove-hook 'after-load-functions #'drgnx-keys--loaded)
  (when (drgnx-keys-redirect-available-p) (setq nidhogg-define-key-redirect-function nil)))

(defun drgnx-keys-unload-function ()
  "`unload-feature' hook: the redirect and the advices go with the keys core."
  (drgnx-keys--uninstall-redirect)
  nil)

(defun drgnx-keys--install-global ()
  "Make the composed map the global map, with its guard, at every apply."
  (drgnx-keys--refresh-paths)
  (unless (eq (current-global-map) drgnx-keys--global-map) (use-global-map drgnx-keys--global-map))
  (add-hook 'post-command-hook #'drgnx-keys--guard-global-map)
  (unless (drgnx-keys-redirect-available-p)
    (push "this Emacs has no define-key redirect (Nidhogg's): bindings from your config cannot be told from packages'"
          drgnx-keys-problems)))

(defun drgnx-keys--uninstall-global ()
  "Undo `drgnx-keys--install-global': `global-map' current again, the profile's keys gone.  Your map keeps your
keys (they come back with the next apply), and the redirect stays on to record them."
  (remove-hook 'post-command-hook #'drgnx-keys--guard-global-map)
  (when (eq (current-global-map) drgnx-keys--global-map) (use-global-map global-map))
  (drgnx-keys--empty drgnx-keys--profile-map)
  (setq drgnx-keys--profile-keys nil))

(defun drgnx-keys-forget-yours ()
  "Forget every key of yours: your map emptied, the profile's keys back on them, the layers' too."
  (let ((nidhogg-define-key-redirect-function nil))
    (drgnx-keys--empty drgnx-keys-user-map)
    (clrhash drgnx-keys--yours)
    (clrhash drgnx-keys--yours-in-maps)
    (setq drgnx-keys--yours-everywhere nil)
    (clrhash drgnx-keys--loading)
    (drgnx-keys--fill-foreign drgnx-keys--foreign-last)
    (drgnx-keys--mark-stale)
    (pcase-dolist (`(,k . ,d) drgnx-keys--profile-keys) (drgnx-keys--define drgnx-keys--profile-map (key-parse k) d))
    (drgnx-keys--set-everywhere (append (plist-get drgnx-keys-last :bindings) (plist-get drgnx-keys-last :held)))))

(defun drgnx-keys--fill-profile (bindings)
  "Put the global keys of BINDINGS ((KEY . COMMAND) …) into the profile map, leaving out your keys.  A KEY
\"<normal-state> g d\" is a key for evil's normal state: it goes in the map's auxiliary keymap for it."
  (let ((nidhogg-define-key-redirect-function nil))
    (drgnx-keys--empty drgnx-keys--profile-map)
    (setq drgnx-keys--profile-keys nil)
    (dolist (b bindings)
      (push (cons (car b) (cdr b)) drgnx-keys--profile-keys)
      (unless (gethash (car b) drgnx-keys--yours)
        (drgnx-keys--define drgnx-keys--profile-map (key-parse (car b)) (cdr b))))
    (setq drgnx-keys--profile-keys (nreverse drgnx-keys--profile-keys))))

(defun drgnx-keys--restore ()
  "Take the profile's keys out of every keymap but the profile map (refilled by the next apply): the `:everywhere'
keys, the foreign layer, the layers of drgnx's own maps, the indentation default; the global map back to `global-map'.
drgnx writes no other map, so there is nothing else to undo."
  (drgnx-keys--set-everywhere nil)
  (drgnx-keys--fill-foreign nil)
  (drgnx-keys--detach-all)
  (drgnx-keys--profile-indent nil)
  (drgnx-keys--uninstall-global))

(defvar drgnx-keys--indent-orig 'unset
  "The default `indent-tabs-mode' before a profile set it (`unset': none did).")

(defun drgnx-keys--profile-indent (layers)
  "Give `indent-tabs-mode' the default a profile in LAYERS asks for (`:indent-tabs-mode' in its spec, VS Code's nil);
with none, put back what it was before."
  (let ((want (cl-some (lambda (l)
                         (let ((spec (alist-get (car l) drgnx-keys-profiles)))
                           (and (plist-member spec :indent-tabs-mode) (list (plist-get spec :indent-tabs-mode)))))
                       layers)))
    (cond (want (when (eq drgnx-keys--indent-orig 'unset)
                  (setq drgnx-keys--indent-orig (default-value 'indent-tabs-mode)))
                (setq-default indent-tabs-mode (car want)))
          ((not (eq drgnx-keys--indent-orig 'unset))
           (setq-default indent-tabs-mode drgnx-keys--indent-orig
                         drgnx-keys--indent-orig 'unset)))))

(defvar drgnx-keys--everywhere-map (make-sparse-keymap)
  "The keys of `:everywhere' entries; above every major and minor mode map, so a profile's key works in any mode.")
(defvar drgnx-keys--everywhere-on nil "Non-nil while `drgnx-keys--everywhere-map' has keys (its switch in the alist).")
(defvar drgnx-keys--everywhere-alist (list (cons 'drgnx-keys--everywhere-on drgnx-keys--everywhere-map))
  "The entry `emulation-mode-map-alists' holds (as this symbol) while there are `:everywhere' keys.")

(defun drgnx-keys--everywhere-filter (event command)
  "COMMAND for the `:everywhere' key EVENT, except in the minibuffer (there C-j and its like are the minibuffer's)
and where a keymap holding your binding of EVENT is active (`drgnx-keys--yours-everywhere')."
  (and (not (minibufferp))
       (not (seq-some (lambda (y) (and (eq (caar y) event) (drgnx-keys--foreign-active-p (cdar y))))
                      drgnx-keys--yours-everywhere))
       command))

(defun drgnx-keys--set-everywhere (bindings)
  "Make the keys of BINDINGS that are `:everywhere' work in every mode: they go in a keymap on
`emulation-mode-map-alists', ahead of the major and minor mode maps.  No such BINDINGS: the keymap is
emptied and leaves the list, so a profile switch leaves nothing behind."
  (setcdr drgnx-keys--everywhere-map nil)
  (setq drgnx-keys--everywhere-on nil drgnx-keys--everywhere-events nil)
  (dolist (b bindings)
    (when-let* (((plist-get b :everywhere))
                (key (key-parse (plist-get b :key)))
                ((push (aref key 0) drgnx-keys--everywhere-events))
                ;; a key of yours: it steps aside (one stroke, so no prefix of yours is over it)
                ((not (gethash (plist-get b :key) drgnx-keys--yours)))
                (cmd (drgnx-commands-get (plist-get b :id))))
      (define-key drgnx-keys--everywhere-map key
                  `(menu-item "" ,(drgnx-cmd-command cmd)
                              :filter ,(apply-partially #'drgnx-keys--everywhere-filter (aref key 0))))
      (setq drgnx-keys--everywhere-on t)))
  (if drgnx-keys--everywhere-on
      (add-to-list 'emulation-mode-map-alists 'drgnx-keys--everywhere-alist)
    (setq emulation-mode-map-alists (delq 'drgnx-keys--everywhere-alist emulation-mode-map-alists))))

;;;; evil's auxiliary keymaps
;; evil looks, in each state, for an auxiliary keymap in every active map: the event `normal-state' (`motion-state', …)
;; bound to a keymap whose prompt starts "Auxiliary keymap".  drgnx never writes evil's state maps.  The profile's keys
;; for a state sit in the profile map's auxiliary keymap for it, your evil writes in your map's (key text
;; "<normal-state> g d"), so they are the global map's: below every mode's auxiliary keymap (evil-collection's keys
;; win), above evil's state maps.  A mode map's profile keys for normal and motion state sit in auxiliary keymaps of
;; its layer.  Each auxiliary keymap is made once and emptied in place, never replaced: evil collects them per buffer
;; when it normalizes (`evil-normalize-keymaps'), so a new one is taken in by every evil buffer at once.

(defconst drgnx-keys--evil-aux-states '(normal motion)
  "The states whose auxiliary keymaps get a mode map's profile keys: evil's state maps for them sit above every
mode map, and would shadow those keys there.")

(defvar drgnx-keys--aux-made nil
  "Non-nil when an auxiliary keymap was made since evil's buffers last took them in (`drgnx-keys--normalize-evil').")

(declare-function evil-normalize-keymaps "evil-core" (&optional state))

(defun drgnx-keys--state-event (state)
  "The event evil binds STATE's auxiliary keymap on: `normal-state' for normal."
  (intern (format "%s-state" state)))

(defun drgnx-keys--state-event-p (ev)
  "Whether event EV is an evil state's (`normal-state', `motion-state', …)."
  (and (symbolp ev) (string-suffix-p "-state" (symbol-name ev))))

(defun drgnx-keys--engine-state (spec)
  "The evil state whose state map keymap SPEC names (`evil-normal-state-map' → normal), else nil."
  (let ((name (symbol-name (cdr (drgnx-commands--keymap-spec spec)))))
    (and (string-match "\\`evil-\\([a-z]+\\)-state-map\\'" name) (intern (match-string 1 name)))))

(defun drgnx-keys--aux-p (map)
  "Whether MAP is an evil auxiliary keymap (its prompt says so, as `evil-auxiliary-keymap-p' reads it)."
  (and (keymapp map) (let ((p (keymap-prompt map))) (and p (string-prefix-p "Auxiliary keymap" p)))))

(defun drgnx-keys--own-cell (map ev)
  "MAP's own binding of the symbol event EV, its parent left out; nil when it has none."
  (let ((tail (cdr map)) found)
    (while (and (consp tail) (not (eq (car tail) 'keymap)) (not found))
      (when (eq (car-safe (car tail)) ev) (setq found (car tail)))
      (setq tail (cdr tail)))
    (cdr found)))

(defun drgnx-keys--aux (map ev)
  "MAP's own auxiliary keymap for the state event EV (`normal-state'): made, with evil's prompt, when MAP has none."
  (let ((aux (drgnx-keys--own-cell map ev)))
    (unless (drgnx-keys--aux-p aux)
      (setq aux (make-sparse-keymap (format "Auxiliary keymap for %s state"
                                            (capitalize (string-remove-suffix "-state" (symbol-name ev))))))
      (let ((nidhogg-define-key-redirect-function nil)) (define-key map (vector ev) aux))
      (setq drgnx-keys--aux-made t))
    aux))

(defun drgnx-keys--define (map key def)
  "Bind KEY (a vector) to DEF in MAP, the redirect off; a KEY that starts with a state's event goes into MAP's
auxiliary keymap for it (`drgnx-keys--aux')."
  (let ((nidhogg-define-key-redirect-function nil))
    (when (and (> (length key) 1) (drgnx-keys--state-event-p (aref key 0))) (drgnx-keys--aux map (aref key 0)))
    (define-key map key def)))

(defun drgnx-keys--empty (map)
  "Empty MAP in place (its parent too), keeping its own auxiliary keymaps, each emptied in place: evil's buffers go on
seeing them."
  (let (kept (tail (cdr map)))
    (while (and (consp tail) (not (eq (car tail) 'keymap)))
      (when (and (consp (car tail)) (drgnx-keys--aux-p (cdar tail)))
        (setcdr (cdar tail) (list (keymap-prompt (cdar tail))))
        (push (car tail) kept))
      (setq tail (cdr tail)))
    (setcdr map (nreverse kept))))

(defun drgnx-keys--normalize-evil ()
  "When an auxiliary keymap was made and evil is loaded: every evil buffer takes it in (`evil-normalize-keymaps')."
  (when drgnx-keys--aux-made
    (setq drgnx-keys--aux-made nil)
    (when (fboundp 'evil-normalize-keymaps)
      (dolist (b (buffer-list))
        (with-current-buffer b
          (when (bound-and-true-p evil-local-mode) (evil-normalize-keymaps)))))))

(defun drgnx-keys--watch-evil ()
  "When evil is loaded, watch its state maps: a write of yours into one goes to your map's auxiliary keymap for the
state (`drgnx-keys--redirect'); any other write stays there."
  (when (featurep 'evil)
    (dolist (sym '(evil-normal-state-map evil-motion-state-map evil-visual-state-map evil-insert-state-map
                                         evil-operator-state-map evil-replace-state-map evil-emacs-state-map))
      (when (and (boundp sym) (keymapp (symbol-value sym)) (not (gethash (symbol-value sym) drgnx-keys--paths)))
        (drgnx-keys--note-own-paths (symbol-value sym) (cons 'evil (drgnx-keys--engine-state sym)) [])))))

(defun drgnx-keys--evil-aux-p (b mapsym)
  "Whether binding B in MAPSYM also goes in the map's auxiliary keymaps for normal and motion state: a mode map
(`…-mode-map') and a layer without modal keys (another editor's profile, keys.eld; a modal profile's keys are written
for their states)."
  (and (string-suffix-p "-mode-map" (symbol-name mapsym))
       (not (plist-get (cdr (assq (plist-get b :layer) drgnx-keys-profiles)) :modal))))

;;;; Layers for other keymaps
;; A profile's key in a map other than the global map is never written into that map.  drgnx's own maps get a
;; layer as their parent (child -> layer -> old parent).  Foreign maps (a package's, wgrep's) get entries in one
;; global layer that is active only while the buffer's local map is, or inherits, the target map.  The modal
;; engine's maps (evil's state maps) keep the ledger of `drgnx-keys--bind' until their layer exists.

(defvar drgnx-keys--own-layers (make-hash-table :test #'eq)
  "MAPSYM → the profile layer of drgnx's own keymap MAPSYM: a sparse keymap, the child's parent while attached.")

(defvar drgnx-keys--attached nil
  "The layers inserted by the last apply: (MAPSYM CHILD . LAYER) each, CHILD the keymap MAPSYM held then.")

(defun drgnx-keys--own-map-p (mapsym)
  "Whether MAPSYM names one of drgnx's own keymaps."
  (string-prefix-p "drgnx-" (symbol-name mapsym)))

(defun drgnx-keys--problem (text late)
  "Record TEXT as a keys problem; LATE (a binding made after the apply, when a feature loaded): also on the report."
  (push text drgnx-keys-problems)
  (when late
    (setq drgnx-keys-last (plist-put drgnx-keys-last :problems (append (plist-get drgnx-keys-last :problems) (list text))))
    (drgnx-keys--notify-problems (plist-get drgnx-keys-last :problems))
    (drgnx-keys--write-report)))

(defun drgnx-keys--when-map-ready (feature sym generation fn)
  "Call FN (with LATE, whether it runs after the apply) once keymap SYM exists: now, or when FEATURE loads.
A stale GENERATION never runs; an error is a problem."
  (let ((run (lambda (late)
               (when (= generation drgnx-keys--generation)
                 (condition-case err (funcall fn late)
                   (error (drgnx-keys--problem (format "cannot layer the keys of %s: %s" sym (error-message-string err))
                                               late)))))))
    (cond ((and feature (not (featurep feature))) (with-eval-after-load feature (funcall run t)))
          ((and (boundp sym) (keymapp (symbol-value sym))) (funcall run nil))
          (t (push (format "no keymap %s" sym) drgnx-keys-problems)))))

;;;;; Parent layers for drgnx's own maps

(defun drgnx-keys--natural-parent-name (sym)
  "The variable `define-derived-mode' takes the parent of keymap SYM from, when SYM is a derived mode's map: the
parent mode's map, `PARENT-map'.  (A parent that installs another map than `PARENT-map' with `use-local-map' is not
found: derived.el reads `current-local-map' after the parent ran.)  Else nil."
  (let ((name (symbol-name sym)))
    (when (string-suffix-p "-map" name)
      (when-let* ((parent (get (intern (string-remove-suffix "-map" name)) 'derived-mode-parent)))
        (intern (format "%s-map" parent))))))

(defun drgnx-keys--natural-parent (sym)
  "The parent `define-derived-mode' gives keymap SYM when its mode first runs, when SYM is a derived mode's map and
has none yet (derived.el sets one only `unless (keymap-parent map)'): the parent mode's map, else nil."
  (when-let* ((pmap (drgnx-keys--natural-parent-name sym)) ((boundp pmap)) ((keymapp (symbol-value pmap))))
    (symbol-value pmap)))

(defvar drgnx-keys--pending-parents nil
  "Layers (MAPSYM) that have no parent yet because the parent mode's map was not loaded at the apply.")

(defun drgnx-keys--complete-parents (&rest _)
  "On `after-load-functions' while a layer waits for its parent mode's map: give each layer the parent
`define-derived-mode' will take, once that map exists.  The mode's first run would otherwise see the layer as its
parent and never set the real one."
  (dolist (sym drgnx-keys--pending-parents)
    (let ((entry (assq sym drgnx-keys--attached)))
      (if (null entry) (setq drgnx-keys--pending-parents (delq sym drgnx-keys--pending-parents))
        (when-let* (((null (keymap-parent (cddr entry)))) (parent (drgnx-keys--natural-parent sym)))
          (set-keymap-parent (cddr entry) parent)
          (setq drgnx-keys--pending-parents (delq sym drgnx-keys--pending-parents))))))
  (unless drgnx-keys--pending-parents (remove-hook 'after-load-functions #'drgnx-keys--complete-parents)))

(defun drgnx-keys-own-layer (sym)
  "The profile's layer of drgnx's own keymap SYM while it is inserted above the map, else nil."
  (cddr (assq sym drgnx-keys--attached)))

(defun drgnx-keys--detach (entry)
  "Take layer ENTRY (`drgnx-keys--attached') out of its child's chain again, saying so when someone else set the
child's parent meanwhile (the layer is then left out of the chain until the next apply puts it back)."
  (pcase-let ((`(,sym ,child . ,layer) entry))
    (if (eq (keymap-parent child) layer)
        (set-keymap-parent child (keymap-parent layer))
      (when (and (boundp sym) (eq (symbol-value sym) child))
        (push (format "%s: its parent was replaced after drgnx's keys were put above it; they are put back" sym)
              drgnx-keys-problems)))
    (setcdr layer nil)))

(defun drgnx-keys--detach-all ()
  "Take every layer out of its child's chain."
  (mapc #'drgnx-keys--detach drgnx-keys--attached)
  (setq drgnx-keys--attached nil drgnx-keys--pending-parents nil)
  (remove-hook 'after-load-functions #'drgnx-keys--complete-parents))

(defun drgnx-keys--resolver-map (sym)
  "Keymap SYM as the resolver reads it: drgnx's own maps without their parents, because the profile's layer sits above
the parent on purpose (a parent's command on a prefix is not a clash to lift); any other map as it is."
  (let ((map (symbol-value sym)))
    (if (drgnx-keys--own-map-p sym)
        (let (cells (tail (cdr map)))              ; the map's own cells, up to the parent (a tail that is a keymap)
          (while (and (consp tail) (not (eq (car tail) 'keymap))) (push (pop tail) cells))
          (cons 'keymap (nreverse cells)))
      map)))

(defun drgnx-keys--fill-own (sym items)
  "Fill SYM's layer with ITEMS ((KEY . COMMAND) …) and insert it between the keymap and its parent: child → layer →
old parent, or the parent the derived mode will take.  Called after the mode is defined (its map exists)."
  (let* ((child (symbol-value sym))
         (layer (or (gethash sym drgnx-keys--own-layers) (puthash sym (make-sparse-keymap) drgnx-keys--own-layers)))
         (nidhogg-define-key-redirect-function nil))
    (when-let* ((old (assq sym drgnx-keys--attached))) (drgnx-keys--detach old) (setq drgnx-keys--attached (delq old drgnx-keys--attached)))
    (drgnx-keys--empty layer)
    (dolist (item items)
      (condition-case err (drgnx-keys--define layer (key-parse (car item)) (cdr item))
        (error (drgnx-keys--problem (format "cannot bind %s in %s: %s" (car item) sym (error-message-string err)) nil))))
    (let ((parent (or (keymap-parent child) (drgnx-keys--natural-parent sym))))
      (set-keymap-parent layer parent)
      (set-keymap-parent child layer)
      (push (cons sym (cons child layer)) drgnx-keys--attached)
      (when (and (null parent) (drgnx-keys--natural-parent-name sym))   ; the parent mode's library is not loaded yet
        (cl-pushnew sym drgnx-keys--pending-parents)
        (add-hook 'after-load-functions #'drgnx-keys--complete-parents)))
    (drgnx-keys--normalize-evil)))

(defun drgnx-keys--layer-keys (map &optional prefix)
  "The key vectors MAP binds to a command, prefix maps walked."
  (let (keys)
    (map-keymap (lambda (ev def)
                  (let ((k (vconcat prefix (vector ev))))
                    (if (keymapp def) (setq keys (nconc (drgnx-keys--layer-keys def k) keys)) (push k keys))))
                map)
    keys))

(defun drgnx-keys-lint-children ()
  "Profile keys that sit in a drgnx map itself instead of in its layer, (\"MAPSYM KEY\" …) for each: the layer is the
map's parent, so such a key would shadow it, and a profile switch would leave it behind."
  (let (found)
    (pcase-dolist (`(,sym ,child . ,layer) drgnx-keys--attached)
      (let ((own (copy-keymap child)))
        (set-keymap-parent own nil)
        (dolist (k (drgnx-keys--layer-keys layer))
          (let ((d (lookup-key own k)))
            (when (and d (not (numberp d))) (push (format "%s %s" sym (key-description k)) found))))))
    (nreverse found)))

;;;;; The foreign layer

(defvar drgnx-keys--foreign-map (make-sparse-keymap)
  "The foreign layer: one wrapped keymap per target map, entries filtered by `drgnx-keys--foreign-filter'.")
(defvar drgnx-keys--foreign-on nil "Non-nil while the foreign layer has entries (its switch in `minor-mode-map-alist').")
(defvar drgnx-keys--foreign-entry (cons 'drgnx-keys--foreign-on drgnx-keys--foreign-map)
  "The layer's `minor-mode-map-alist' entry, kept last: another minor mode's key beats a profile key in the major map.")

(defvar drgnx-keys--foreign-aux (make-sparse-keymap)
  "Holds the foreign layer's auxiliary keymaps (`normal-state', `motion-state' cells), made once and refilled in
place; their cells lead the layer's keymap (`drgnx-keys--fill-foreign').")

(defun drgnx-keys--map-reaches-p (map target)
  "Whether keymap MAP is TARGET or inherits it (parents, and the keymaps a composed map holds)."
  (let (hit)
    (while (and map (not hit))
      (if (eq map target) (setq hit t)
        (dolist (m (cdr-safe map)) (when (and (not hit) (eq (car-safe m) 'keymap)) (setq hit (drgnx-keys--map-reaches-p m target))))
        (setq map (keymap-parent map))))
    hit))

(defun drgnx-keys--foreign-active-p (target)
  "Whether keymap TARGET is active here: the buffer's local map is, or inherits, it (wgrep's `use-local-map' swap, a
mode derived from the target's), or a minor mode's map does (`current-minor-mode-maps': `minor-mode-map-alist', the
overriding and the emulation alists), or the `keymap' or `local-map' property at point does (an overlay, a button).
A `local-map' property replaces the buffer's local map, which then does not count."
  (cl-flet ((map-of (km) (and km (keymapp km) (if (symbolp km) (symbol-function km) km))))
    (let ((local (map-of (get-char-property (point) 'local-map))))
      (or (drgnx-keys--map-reaches-p (or local (current-local-map)) target)
          (let (hit)
            (dolist (m (current-minor-mode-maps))
              (when (and (not hit) (drgnx-keys--map-reaches-p m target)) (setq hit t)))
            hit)
          (let ((km (map-of (get-char-property (point) 'keymap))))
            (and km (drgnx-keys--map-reaches-p km target)))))))

(defun drgnx-keys--foreign-filter (sym def)
  "DEF while keymap SYM is active here (`drgnx-keys--foreign-active-p'), else nil: the key is not the layer's here."
  (and (boundp sym) (keymapp (symbol-value sym)) (drgnx-keys--foreign-active-p (symbol-value sym)) def))

(defun drgnx-keys--foreign-keep-last ()
  "Put the layer's entry last in `minor-mode-map-alist' (out of it while the layer is empty)."
  (setq minor-mode-map-alist (delq drgnx-keys--foreign-entry (copy-sequence minor-mode-map-alist)))
  (when drgnx-keys--foreign-on
    (setq minor-mode-map-alist (append minor-mode-map-alist (list drgnx-keys--foreign-entry)))))

(defun drgnx-keys--fill-foreign (targets)
  "Make the layer from TARGETS, ((MAPSYM (KEY . COMMAND) …) …): nil empties it.  The target keymaps are looked up
when a key is pressed, so a map that is made later, or replaced, needs nothing here.  A key of yours in a target map
leaves the profile's keys it meets out (`drgnx-keys--yours-blocks-p')."
  (setq drgnx-keys--foreign-last targets)
  (let ((nidhogg-define-key-redirect-function nil) wrapped-maps aux-maps)
    (dolist (target targets)
      (let ((layer (make-sparse-keymap)) (wrapped (make-sparse-keymap))
            (filter (apply-partially #'drgnx-keys--foreign-filter (car target))))
        (dolist (item (cdr target))
          (unless (drgnx-keys--yours-blocks-p (car target) (key-description (key-parse (car item))))
            (condition-case err (define-key layer (key-parse (car item)) (cdr item))
              (error (push (format "cannot bind %s in %s: %s" (car item) (car target) (error-message-string err))
                           drgnx-keys-problems)))))
        (cl-flet ((wrap (into ev def) (define-key into (vector ev) `(menu-item "" ,def :filter ,filter))))
          (map-keymap (lambda (ev def)
                        (if (drgnx-keys--state-event-p ev)    ; keys for an evil state: the layer's auxiliary keymap
                            (let ((w (make-sparse-keymap)))
                              (map-keymap (lambda (ev2 def2) (wrap w ev2 def2)) def)
                              (push w (alist-get ev aux-maps)))
                          (wrap wrapped ev def)))
                      layer))
        (push wrapped wrapped-maps)))
    (pcase-dolist (`(,ev . ,_) aux-maps) (drgnx-keys--aux drgnx-keys--foreign-aux ev))
    (pcase-dolist (`(,ev . ,aux) (cdr drgnx-keys--foreign-aux))
      (setcdr aux (cons (keymap-prompt aux) (nreverse (alist-get ev aux-maps)))))
    (setcdr drgnx-keys--foreign-map (append (cdr drgnx-keys--foreign-aux) (nreverse wrapped-maps)))
    (setq drgnx-keys--foreign-on (and (or wrapped-maps aux-maps) t))
    (drgnx-keys--foreign-keep-last)
    (drgnx-keys--normalize-evil)))

(defun drgnx-keys--set-layers (entries generation)
  "Put ENTRIES ((SPEC COMMAND BINDING) …), the profile's keys in maps that are neither the global map nor the
engine's, into layers: parents of drgnx's own maps, the foreign layer for the others."
  (let (own foreign features)
    (dolist (e entries)
      (pcase-let* ((`(,spec ,command ,b) e) (`(,feature . ,sym) (drgnx-commands--keymap-spec spec))
                   (key (plist-get b :key))
                   ;; under evil, its state maps sit above every mode map: the key goes in the layer's auxiliary
                   ;; keymaps for normal and motion state too
                   (rows (cons (list b (cons key command))
                               (and (drgnx-keys--evil-aux-p b sym)
                                    (mapcar (lambda (st) (list b (cons (key-description (vconcat (vector (drgnx-keys--state-event st))
                                                                                                 (key-parse key)))
                                                                       command)))
                                            drgnx-keys--evil-aux-states)))))
        (setf (alist-get sym features) feature)
        (dolist (row rows)
          (if (drgnx-keys--own-map-p sym) (push row (alist-get sym own)) (push row (alist-get sym foreign))))))
    (when-let* ((help (drgnx-keys--help-in-minibuffer))) (push (list nil help) (alist-get 'minibuffer-local-map foreign)))
    (pcase-dolist (`(,sym . ,rows) own)
      (let ((items (mapcar #'cadr (reverse rows))))
        (drgnx-keys--when-map-ready (alist-get sym features) sym generation
                                    (lambda (_late) (drgnx-keys--fill-own sym items)))))
    (drgnx-keys--fill-foreign
     (mapcar (lambda (f) (cons (car f) (mapcar #'cadr (reverse (cdr f))))) (reverse foreign)))
    (setq drgnx-keys--named-maps (delete-dups (append (mapcar #'car own) (mapcar #'car foreign))))
    (drgnx-keys--watch-named)))

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
                                       (abbreviate-file-name (drgnx-config-file 'settings)))))))
    (error (message "drgnx: key problems not recorded as notices: %s" (error-message-string err)))))

(defun drgnx-keys--help-in-minibuffer ()
  "When a profile took the help key (`help-char', C-h) from the global map, the item (KEY . help-command) that gives
it back in the minibuffer, for the foreign layer: the profile's command for it (Replace in File) means nothing while the
minibuffer reads, and C-h f there is the way to look something up.  Else nil."
  (let ((key (key-description (vector help-char))))
    (unless (memq (lookup-key drgnx-keys--global-map (key-parse key)) '(help-command nil))
      (cons key 'help-command))))

(defun drgnx-keys-apply ()
  "Bind the keys of the active stack and keys.eld, replacing what drgnx bound before.
Never prompts: problems are collected in `drgnx-keys-last'.  Returns the resolution."
  (setq drgnx-keys-problems nil drgnx-keys--stale nil)
  (condition-case err
      (progn
        (drgnx-keys--ensure-profiles)
        ;; Restore first: resolution then sees Emacs' own bindings, not drgnx's previous ones.
        (drgnx-keys--restore)
        (cl-incf drgnx-keys--generation)
        (let* ((user (drgnx-keys-read-user)) (globals nil) (layered nil)
               (layers (or drgnx-keys--session-layers (plist-get user :layers) (drgnx-keys--layers)))
               (r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-profiles :layers layers
                                      :user user :platform (drgnx-platform)
                                      :yours (drgnx-keys--yours-alist)
                                      :maps (lambda (m) (and (boundp m) (keymapp (symbol-value m)) (drgnx-keys--resolver-map m)))
                                      :snapshots (and (featurep 'evil)
                                                      (drgnx-keys-modal-engine-maps 'evil drgnx-keys-profiles)))))
          (drgnx-keys--set-mac-modifiers layers (plist-get user :mac-option))
          (drgnx-keys--profile-indent layers)
          (dolist (c (drgnx-commands-all)) (setf (drgnx-cmd-bound c) nil))
          (dolist (b (plist-get r :bindings))
            (let ((cmd (drgnx-commands-get (plist-get b :id))))
              ;; the global map's keys go into the profile's layer (all of them: a key of yours is left out there, and
              ;; comes back when you take yours away)
              (when (and cmd (eq (cdr (drgnx-commands--keymap-spec (plist-get b :map))) 'global-map))
                (push (cons (plist-get b :key) (drgnx-cmd-command cmd)) globals))
              ;; A key that beats the modal engine's in some states goes in the engine's keymaps too (:also): for evil's
              ;; state maps, in the profile map's auxiliary keymap for the state (your key for that state there beats
              ;; it, and is said); every other map gets a layer.
              (dolist (map (cons (plist-get b :map) (plist-get b :also)))
                (let* ((state (drgnx-keys--engine-state map))
                       (text (and state (key-description (vconcat (vector (drgnx-keys--state-event state))
                                                                  (key-parse (plist-get b :key))))))
                       (yours (and text (gethash text drgnx-keys--yours))))
                  (if yours
                      (setq r (plist-put r :conflicts
                                         (append (plist-get r :conflicts)
                                                 (list (list :key (plist-get b :key)
                                                             :map (cdr (drgnx-commands--keymap-spec map)) :kind 'claim
                                                             :winner (list :claim (drgnx-keys--def-text (car yours))
                                                                           :layer "your own binding, kept")
                                                             :losers (list (list :id (plist-get b :id) :layer (plist-get b :layer))))))))
                    (setf (drgnx-cmd-bound cmd) (append (drgnx-cmd-bound cmd) (list (cons (plist-get b :key) map)))))
                  (cond ((eq (cdr (drgnx-commands--keymap-spec map)) 'global-map))
                        (state (push (cons text (drgnx-cmd-command cmd)) globals))
                        (t (push (list map (drgnx-cmd-command cmd) b) layered)))))))
          ;; a key of yours the profile also binds is out of :bindings but waits in :held, to come back with your key
          (dolist (b (plist-get r :held))
            (when-let* (((eq (cdr (drgnx-commands--keymap-spec (plist-get b :map))) 'global-map))
                        (cmd (drgnx-commands-get (plist-get b :id))))
              (push (cons (plist-get b :key) (drgnx-cmd-command cmd)) globals)))
          (drgnx-keys--fill-profile (nreverse globals))
          (drgnx-keys--install-global)
          (drgnx-keys--set-everywhere (append (plist-get r :bindings) (plist-get r :held)))
          (drgnx-keys--set-layers (nreverse layered) drgnx-keys--generation)
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
        (error (require 'drgnx-notice)
               (drgnx-notify 'keys 'warn (format "%S failed after applying keys: %s" fn (error-message-string err))
                             :id (cons 'after-apply fn))))))
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
Code's C-k chords over kill-line) are one line.  A key of yours that changed since the apply is settled first."
  (drgnx-keys-settle)
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
  "Write DATA as the value of KEY (:layers, :bind, … `drgnx-keys--settings') into settings.el: only that entry
changes; comments, layout and the other entries stay, and the value applies at once.  A settings.el with a mistake is
refused (`drgnx-settings-refused'), not written."
  (drgnx-settings-area-set (list (cons (or (alist-get key drgnx-keys--settings) (error "No keys setting %s" key)) data))))

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
                                          (car (rassoc (drgnx-keys--layers) drgnx-keys-presets))))
                     t))
  (unless (assoc name drgnx-keys-presets)
    (user-error "No keyboard profile %S (profiles: %s)" name (mapconcat #'car drgnx-keys-presets ", ")))
  (drgnx-settings-area-ensure-writable)                 ; a settings.el with a mistake: refused before anything changes
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

(drgnx-keys--install-redirect)

(provide 'drgnx-keys)
;;; drgnx-keys.el ends here
