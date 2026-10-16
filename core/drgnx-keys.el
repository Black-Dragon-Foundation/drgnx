;;; drgnx-keys.el --- Key profiles, layers and conflicts -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Commands are registered without keys (`drgnx-command-define'); keys come from profiles —
;; data files keys/<profile>.eld mapping command ids to keys (VS Code, Emacs, Vim), plus entries
;; modules add with `drgnx-keys-define'.  The active setup is a stack of layers, each a profile
;; with the command scopes it covers (editing, app, window); later layers win, the user's
;; keys.eld wins over all, and every conflict is reported, never silently resolved.
;; `drgnx-keys-resolve' is the pure part: inputs in, (bindings conflicts problems) out.
;; See docs/keys.md.

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
  "The first form in FILE, or nil with a problem recorded (never an error or a prompt)."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (read (current-buffer)))
    (error (push (format "%s: %s" (abbreviate-file-name file) (error-message-string err)) drgnx-keys-problems)
           nil)))

(defun drgnx-keys-load-profiles (dir)
  "Profiles from DIR/*.eld, as an alist PROFILE → plist, in file-name order."
  (let (out)
    (dolist (f (directory-files dir t "\\.eld\\'"))
      (when-let* ((spec (drgnx-keys--read-file f)))
        (push (cons (intern (file-name-base f)) spec) out)))
    (nreverse out)))

(defun drgnx-keys-define (profile entries)
  "Add ENTRIES, in profile :bind form, to PROFILE (for modules); later entries for an id win."
  (let ((spec (alist-get profile drgnx-keys-profiles)))
    (setf (alist-get profile drgnx-keys-profiles)
          (plist-put spec :bind (append (seq-remove (lambda (e) (assq (car e) entries)) (plist-get spec :bind))
                                        entries)))))

;;;; Resolution

(defun drgnx-keys--mac-cmd (key)
  "KEY with every C- modifier turned into s- (Cmd), as VS Code does on macOS."
  (replace-regexp-in-string "\\(\\`\\| \\)C-" "\\1s-" key t))

(defun drgnx-keys--entry (entry spec platform)
  "ENTRY (ID KEY… [:map M] [:mac K]) or (ID :none REASON) of profile SPEC → plist (:keys :map)."
  (let ((rest (cdr entry)) keys)
    (if (eq (car rest) :none)
        (list :keys nil)
      (while (stringp (car rest)) (push (pop rest) keys))
      (setq keys (nreverse keys))
      (when (eq platform 'macos)
        (setq keys (cond ((plist-get rest :mac) (ensure-list (plist-get rest :mac)))
                         ((plist-get spec :mac-cmd) (mapcar #'drgnx-keys--mac-cmd keys))
                         (t keys))))
      (list :keys keys :map (or (plist-get rest :map) (plist-get spec :map))))))

(defun drgnx-keys--default (defaults key)
  "What KEY does in the DEFAULTS keymap: (claim . DESCRIPTION), (prefix . DESCRIPTION) or nil."
  (let ((def (ignore-errors (keymap-lookup defaults key))))
    (cond ((keymapp def) (cons 'prefix (format "the %s prefix" key)))
          ((numberp def)
           (let* ((prefix (key-description (seq-take (key-parse key) def)))
                  (cmd (keymap-lookup defaults prefix)))
             (cons 'prefix (format "%s (%s)" cmd prefix))))
          ((and (symbolp def) def (commandp def) (not (memq def '(self-insert-command undefined ignore))))
           (cons 'claim (symbol-name def))))))

(defun drgnx-keys--global-p (map)
  (eq (cdr (drgnx-commands--keymap-spec map)) 'global-map))

(cl-defun drgnx-keys-resolve (&key commands profiles layers user platform defaults)
  "Resolve keys for COMMANDS (registry structs) → plist (:bindings :conflicts :problems).
PROFILES: alist PROFILE → plist.  LAYERS: list of (PROFILE SCOPE…), later wins.  USER: the
keys.eld plist (:bind :unbind), which wins over every layer.  PLATFORM: `macos' turns VS Code's
C- into s-.  DEFAULTS: Emacs' own global keymap, for the emacs layer's claims and prefix checks.
A binding is a plist (:id :key :map :layer); a conflict is (:key :map :kind :winner :losers),
KIND `same-key', `claim' (a key another layer uses natively) or `prefix'."
  (let ((cmds (make-hash-table :test #'eq)) (assign (make-hash-table :test #'eq))
        (rank 0) claims defaults-claim problems bindings conflicts)
    (dolist (c commands) (puthash (drgnx-cmd-id c) c cmds))
    ;; Each command takes its keys from the last layer covering its scope.
    (pcase-dolist (`(,profile . ,scopes) layers)
      (cl-incf rank)
      (if-let* ((spec (alist-get profile profiles)))
          (progn
            (dolist (entry (plist-get spec :bind))
              (when-let* ((c (gethash (car entry) cmds)))
                (when (memq (drgnx-cmd-scope c) scopes)
                  (puthash (car entry) (append (list :layer profile :rank rank) (drgnx-keys--entry entry spec platform))
                           assign))))
            (pcase-dolist (`(,scope ,key ,desc) (plist-get spec :claims))
              (when (memq scope scopes) (push (list :key key :claim desc :layer profile :rank rank) claims)))
            (when (and (plist-get spec :claims-defaults) (memq 'editing scopes))
              (setq defaults-claim (list :layer profile :rank rank))))
        (push (format "key layer %s: no such profile (known: %s)" profile (mapconcat #'symbol-name (mapcar #'car profiles) ", "))
              problems)))
    (cl-incf rank)
    (dolist (entry (plist-get user :bind))
      (if (gethash (car entry) cmds)
          (puthash (car entry) (append (list :layer 'user :rank rank) (drgnx-keys--entry entry nil platform)) assign)
        (push (format "keys.eld: no command %s (in :bind)" (car entry)) problems)))
    (dolist (id (plist-get user :unbind))
      (if (gethash id cmds) (puthash id (list :layer 'user :rank rank :keys nil) assign)
        (push (format "keys.eld: no command %s (in :unbind)" id) problems)))
    ;; Flatten, in registry order.
    (dolist (c commands)
      (when-let* ((a (gethash (drgnx-cmd-id c) assign)))
        (dolist (k (plist-get a :keys))
          (if (key-valid-p k)
              (push (list :id (drgnx-cmd-id c) :key k :map (or (plist-get a :map) (drgnx-cmd-map c))
                          :layer (plist-get a :layer) :rank (plist-get a :rank))
                    bindings)
            (push (format "%s: \"%s\" is not a valid key" (drgnx-cmd-id c) k) problems)))))
    (setq bindings (nreverse bindings))
    ;; Two commands on one key in one keymap: the higher layer keeps it.
    (let ((groups nil))
      (dolist (b bindings)
        (push b (alist-get (cons (plist-get b :key) (cdr (drgnx-commands--keymap-spec (plist-get b :map)))) groups
                           nil nil #'equal)))
      (pcase-dolist (`((,key . ,mapsym) . ,group) (reverse groups))
        (when (cdr (delete-dups (mapcar (lambda (b) (plist-get b :id)) group)))
          (let* ((group (reverse group))
                 (winner (seq-reduce (lambda (w b) (if (> (plist-get b :rank) (plist-get w :rank)) b w)) group (car group)))
                 (losers (remq winner group)))
            (push (list :key key :map mapsym :kind 'same-key
                        :winner (list :id (plist-get winner :id) :layer (plist-get winner :layer))
                        :losers (mapcar (lambda (b) (list :id (plist-get b :id) :layer (plist-get b :layer))) losers))
                  conflicts)
            (setq bindings (seq-remove (lambda (b) (memq b losers)) bindings))))))
    ;; Keys other layers use natively (claims), Emacs' defaults, and prefixes.
    (dolist (b (copy-sequence bindings))
      (let* ((key (plist-get b :key)) (rank (plist-get b :rank))
             (rivals (seq-filter (lambda (cl) (and (equal (plist-get cl :key) key)
                                                   (not (eq (plist-get cl :layer) (plist-get b :layer)))))
                                 claims))
             (kind (and rivals 'claim)))
        (when (and (drgnx-keys--global-p (plist-get b :map)) defaults)
          (pcase (drgnx-keys--default defaults key)
            (`(prefix . ,desc)
             (setq kind 'prefix)
             (push (list :claim desc :layer (plist-get defaults-claim :layer) :rank (or (plist-get defaults-claim :rank) 0))
                   rivals))
            (`(claim . ,desc)
             (when (and defaults-claim (not (equal desc (format "%s" (drgnx-cmd-command (gethash (plist-get b :id) cmds))))))
               (setq kind (or kind 'claim))
               (push (list :claim desc :layer (plist-get defaults-claim :layer) :rank (plist-get defaults-claim :rank))
                     rivals)))))
        (when rivals
          (let* ((top (seq-reduce (lambda (w r) (if (> (plist-get r :rank) (plist-get w :rank)) r w)) rivals (car rivals)))
                 (b-wins (>= rank (plist-get top :rank)))
                 (me (list :id (plist-get b :id) :layer (plist-get b :layer)))
                 (them (mapcar (lambda (r) (list :claim (plist-get r :claim) :layer (plist-get r :layer))) rivals)))
            (push (list :key key :map (cdr (drgnx-commands--keymap-spec (plist-get b :map))) :kind kind
                        :winner (if b-wins me (car (seq-filter (lambda (x) (equal (plist-get x :claim) (plist-get top :claim))) them)))
                        :losers (if b-wins them (cons me (seq-remove (lambda (x) (equal (plist-get x :claim) (plist-get top :claim))) them))))
                  conflicts)
            (unless b-wins (setq bindings (remq b bindings)))))))
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
      (let ((form (drgnx-keys--read-file file)))
        (cond ((null form) nil)
              ((not (and (listp form) (keywordp (car form))))
               (push (format "%s: not a plist like (:layers … :bind … :unbind …)" (abbreviate-file-name file))
                     drgnx-keys-problems)
               nil)
              ((not (seq-every-p (lambda (l) (and (consp l) (symbolp (car l)) (seq-every-p #'symbolp (cdr l))))
                                 (plist-get form :layers)))
               (push (format "%s: :layers must be a list of (PROFILE SCOPE…)" (abbreviate-file-name file))
                     drgnx-keys-problems)
               (plist-put (copy-sequence form) :layers nil))
              (t form))))))

(defun drgnx-keys-platform () (if (eq system-type 'darwin) 'macos 'linux))

(defun drgnx-keys--set (map key def)
  "Bind KEY to DEF in MAP; nil DEF removes the entry."
  (if def (define-key map (key-parse key) def) (keymap-unset map key t)))

(defun drgnx-keys--bind (mapsym key def)
  "Bind KEY in MAPSYM's keymap, remembering what was there; a command blocking KEY as a prefix
is lifted first (and remembered)."
  (let* ((map (symbol-value mapsym)) (prev (keymap-lookup map key)))
    (when (numberp prev)
      (let ((prefix (key-description (seq-take (key-parse key) prev))))
        (push (list mapsym prefix (keymap-lookup map prefix) :prefix) drgnx-keys--applied)
        (keymap-unset map prefix t)
        (setq prev nil)))
    (push (list mapsym key prev def) drgnx-keys--applied)
    (define-key map (key-parse key) def)))

(defun drgnx-keys--restore ()
  "Undo every binding drgnx made, newest first — except one someone else changed since."
  (pcase-dolist (`(,mapsym ,key ,prev ,ours) drgnx-keys--applied)
    (when (and (boundp mapsym) (keymapp (symbol-value mapsym)))
      (let* ((map (symbol-value mapsym)) (now (keymap-lookup map key)))
        (when (if (eq ours :prefix) (or (null now) (equal now '(keymap))) (equal now ours))
          (drgnx-keys--set map key prev)))))
  (setq drgnx-keys--applied nil))

(defun drgnx-keys--apply-binding (b cmd generation)
  "Bind resolution binding B (command CMD) now, or when its keymap's feature loads."
  (pcase-let* ((`(,feature . ,mapsym) (drgnx-commands--keymap-spec (plist-get b :map)))
               (bind (lambda ()
                       (when (= generation drgnx-keys--generation)
                         (condition-case err
                             (drgnx-keys--bind mapsym (plist-get b :key) (drgnx-cmd-command cmd))
                           (error (push (format "%s: cannot bind %s in %s: %s" (plist-get b :id) (plist-get b :key)
                                                mapsym (error-message-string err))
                                        drgnx-keys-problems)))))))
    (cond ((and feature (not (featurep feature))) (with-eval-after-load feature (funcall bind)))
          ((and (boundp mapsym) (keymapp (symbol-value mapsym))) (funcall bind))
          (t (push (format "%s: no keymap %s for %s" (plist-get b :id) mapsym (plist-get b :key)) drgnx-keys-problems)))))

(defun drgnx-keys-apply ()
  "Bind the keys of the active stack and keys.eld, replacing what drgnx bound before.
Never prompts: problems are collected in `drgnx-keys-last'.  Returns the resolution."
  (setq drgnx-keys-problems nil)
  (drgnx-keys--ensure-profiles)
  (let* ((user (drgnx-keys-read-user))
         (layers (or drgnx-keys--session-layers (plist-get user :layers) drgnx-keys-layers))
         (r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-profiles :layers layers
                                :user user :platform (drgnx-keys-platform) :defaults drgnx-keys--defaults)))
    (drgnx-keys--restore)
    (cl-incf drgnx-keys--generation)
    (dolist (c (drgnx-commands-all)) (setf (drgnx-cmd-bound c) nil))
    (dolist (b (plist-get r :bindings))
      (let ((cmd (drgnx-commands-get (plist-get b :id))))
        (setf (drgnx-cmd-bound cmd) (append (drgnx-cmd-bound cmd) (list (cons (plist-get b :key) (plist-get b :map)))))
        (drgnx-keys--apply-binding b cmd drgnx-keys--generation)))
    (setq drgnx-keys-last (append (list :layers layers
                                        :problems (append (reverse drgnx-keys-problems) (plist-get r :problems)))
                                  r))
    (drgnx-keys--write-report)
    drgnx-keys-last))

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

(defun drgnx-keys-conflict-lines ()
  "The last apply's conflicts as text lines."
  (mapcar #'drgnx-keys-conflict-text (plist-get drgnx-keys-last :conflicts)))

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
  "Write LAYERS into keys.eld, keeping everything else in it."
  (let* ((file (drgnx-keys-file))
         (old (and (file-exists-p file)
                   (or (drgnx-keys--read-file file)
                       (user-error "%s cannot be read — fix it first (it was not changed)" (abbreviate-file-name file)))))
         (new (plist-put (copy-sequence old) :layers layers))
         (tmp (progn (make-directory (file-name-directory file) t)
                     (make-temp-file (expand-file-name ".keys-" (file-name-directory file))))))
    ;; A temp file renamed over keys.eld: writing it directly could ask about a stale buffer.
    (with-temp-file tmp
      (insert ";; drgnx keys (docs/keys.md): :layers — profile stack, :bind — (ID KEY… [:map M]), :unbind — (ID…)\n")
      (pp new (current-buffer)))
    (set-file-modes tmp #o644)
    (rename-file tmp file t)))

(defun drgnx-keys-choose-profile (name)
  "Switch the key profile to the preset NAME and save it in keys.eld."
  (interactive (list (completing-read "Keyboard profile: " drgnx-keys-presets nil t)))
  (let ((r (drgnx-keys-use (cdr (assoc name drgnx-keys-presets)) t)))
    (message "Keys: %s%s" name
             (if-let* ((n (length (plist-get r :conflicts))) ((> n 0)))
                 (format " — %d conflict%s, see Keyboard Shortcuts" n (if (= n 1) "" "s"))
               ""))))

(provide 'drgnx-keys)
;;; drgnx-keys.el ends here
