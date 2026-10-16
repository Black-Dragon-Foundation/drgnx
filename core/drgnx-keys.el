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

(provide 'drgnx-keys)
;;; drgnx-keys.el ends here
