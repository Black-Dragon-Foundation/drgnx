;;; drgnx-keys-modal.el --- Where a modal profile's keys go (pure) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The key resolver (`drgnx-keys-resolve') asks these functions where a key binds when a profile has a `:modal'
;; plist (keys/vim.eld): a leader key (`SPC f f', `C-w h') always goes in the profile's leader map; any other key in
;; the entry's map, the command's, the modal plist's `:default-map', else the profile's.  `:maps' of the modal plist
;; says which keymaps carry modal keys and in which states; a modal profile's keys in those maps are kept in a
;; stack where the profile covers fewer scopes (a mixed stack).
;;
;; Claims per state: a key another layer binds in `global-map' or a panel's map meets the modal profile where it
;; binds the same key (or a prefix of it, or a key it starts) in a state — in evil's state maps (read from a
;; snapshot of them taken when evil loads, before drgnx binds anything there; the profile's hand-listed `:claims'
;; with their STATES until then), in the leader map and in the panel map (`drgnx-keys-modal-claims').  The
;; resolver keeps such a binding and lets the higher layer win in those states only.  Apart from the snapshot,
;; nothing here touches a keymap or needs evil.  See docs/guide/keys.md and docs/develop/core.md ("Modal core").

;;; Code:
(require 'cl-lib)

(defvar drgnx-keys-profiles)
(defvar drgnx-modal-panel-modes)
(declare-function drgnx-keys--ensure-profiles "drgnx-keys")
(declare-function drgnx-keys--existing "drgnx-keys")
(declare-function drgnx-keys--parse "drgnx-keys")
(declare-function drgnx-keys--prefix-of-p "drgnx-keys")

(defun drgnx-keys-modal-leader-p (key modal)
  "Non-nil if KEY is, or starts with, one of MODAL's `:leader' keys followed by a space (\"SPC f f\", \"C-w h\"):
not the leader key alone."
  (cl-some (lambda (leader) (string-prefix-p (concat leader " ") key)) (plist-get modal :leader)))

(defun drgnx-keys-modal--mapsym (map)
  "The keymap symbol of MAP, a symbol or (FEATURE . KEYMAP-SYMBOL)."
  (if (consp map) (cdr map) map))

(defun drgnx-keys-modal-states (map modal)
  "The states MAP (a keymap spec) is active in according to MODAL's `:maps', or nil if it is not one of them."
  (when map
    (let ((sym (drgnx-keys-modal--mapsym map)))
      (cl-some (lambda (m) (and (eq (drgnx-keys-modal--mapsym (car m)) sym) (cdr m))) (plist-get modal :maps)))))

(defun drgnx-keys-modal-key-map (key modal entry-map cmd-map profile-map)
  "The keymap spec KEY binds in: PROFILE-MAP for one of MODAL's leader keys whatever the entry says; else the first
non-nil of ENTRY-MAP, CMD-MAP, MODAL's `:default-map' and PROFILE-MAP."
  (if (and profile-map (drgnx-keys-modal-leader-p key modal))
      profile-map
    (or entry-map cmd-map (plist-get modal :default-map) profile-map)))

(defun drgnx-keys-modal-of-stack (layers profiles)
  "The modal layer of the stack LAYERS (PROFILES: alist PROFILE → plist) as (:modal PLIST :profile P :map PROFILE-MAP),
or nil if no layer's profile has `:modal'."
  (cl-some (lambda (layer)
             (let ((spec (alist-get (car layer) profiles)))
               (and (plist-get spec :modal)
                    (list :modal (plist-get spec :modal) :profile (car layer) :map (plist-get spec :map)))))
           layers))

;;;; Claims per state

(defconst drgnx-keys-modal-places '(normal visual motion insert panels)
  "Where a key works under a modal stack, in the order the key sheet names them: the engine's states and panels.")

(defun drgnx-keys-modal-order (states)
  "STATES once each, in the order of `drgnx-keys-modal-places' (any other after them, as given)."
  (append (cl-remove-if-not (lambda (p) (memq p states)) drgnx-keys-modal-places)
          (cl-remove-if (lambda (s) (memq s drgnx-keys-modal-places)) (delete-dups (copy-sequence states)))))

(defun drgnx-keys-modal--engine-maps (modal)
  "MODAL's `:maps' entries of the engine's keymaps: (SPEC STATE…), SPEC being (FEATURE . KEYMAP-SYMBOL)."
  (cl-remove-if-not (lambda (m) (consp (car m))) (plist-get modal :maps)))

(defun drgnx-keys-modal--own-maps (modal)
  "MODAL's `:maps' entries of drgnx's own modal keymaps (the leader and panel maps): (KEYMAP-SYMBOL STATE…)."
  (cl-remove-if (lambda (m) (consp (car m))) (plist-get modal :maps)))

(defvar drgnx-keys-modal-snapshots nil
  "Alist KEYMAP-SYMBOL → a copy of that keymap of the modal engine, taken when the engine's feature loads and before
drgnx binds anything in it: what the engine itself binds, for the claims per state.  Nil until the engine loads.
Its size is fixed: one copy per keymap the profiles' `:modal' `:maps' name.")

(defun drgnx-keys-modal-take-snapshots (feature profiles)
  "Copy the keymaps of FEATURE that the `:modal' `:maps' of PROFILES (alist PROFILE → plist) name into
`drgnx-keys-modal-snapshots'; a keymap not defined (yet) is skipped.  Returns the snapshots."
  (let (out)
    (dolist (p profiles)
      (dolist (m (drgnx-keys-modal--engine-maps (plist-get (cdr p) :modal)))
        (let ((sym (cdar m)))
          (when (and (eq (caar m) feature) (not (assq sym out)) (boundp sym) (keymapp (symbol-value sym)))
            (push (cons sym (copy-keymap (symbol-value sym))) out)))))
    (setq drgnx-keys-modal-snapshots (nreverse out))))

(defun drgnx-keys-modal--snapshot-evil ()
  "When evil has loaded: snapshot its state maps (`drgnx-keys-modal-take-snapshots').  Never an error."
  (with-demoted-errors "drgnx: evil's keymaps not read: %S"
    (when (fboundp 'drgnx-keys--ensure-profiles)
      (drgnx-keys--ensure-profiles)
      (drgnx-keys-modal-take-snapshots 'evil drgnx-keys-profiles))))

(defvar drgnx-keys-modal--snapshot-registered nil
  "Non-nil once `drgnx-keys-modal--snapshot-evil' waits for evil (a reload of this file registers it once).")

;; Registered as this file loads, before any binding drgnx defers to evil's load, so it runs first.
(unless drgnx-keys-modal--snapshot-registered
  (setq drgnx-keys-modal--snapshot-registered t)
  (eval-after-load 'evil #'drgnx-keys-modal--snapshot-evil))

(defun drgnx-keys-modal-mixed-p (layers profiles)
  "Non-nil when LAYERS has a layer of a profile in PROFILES (alist PROFILE → plist) without `:modal': a modal
profile mixed with another editor's keys (no modal layer at all counts too).  Malformed LAYERS: nil."
  (and (proper-list-p layers)
       (cl-some (lambda (l) (when-let* ((spec (and (consp l) (assq (car l) profiles))))
                              (not (plist-get (cdr spec) :modal))))
                layers)))

(defun drgnx-keys-modal-panel-maps ()
  "The keymap symbols of panels: those of `drgnx-modal-panel-modes' and the sidebar docks' `drgnx-wb-dock-map'."
  (cons 'drgnx-wb-dock-map
        (mapcar (lambda (m) (intern (format "%s-map" m))) (bound-and-true-p drgnx-modal-panel-modes))))

(defun drgnx-keys-modal-claims (bindings modal layer rank snapshots panel-maps &optional hand mixed)
  "State claims on BINDINGS (resolution bindings: plists :id :key :map :layer :rank) by the modal profile whose
plist is MODAL, the stack's layer LAYER of rank RANK.  A list of (:key :claim :layer :rank :states :map :binding B
[:id ID] [:drop (BINDING…)]), one per binding B and keymap meeting it (B is `eq' to one of BINDINGS).
- A binding in `global-map' meets the engine's state maps of MODAL's `:maps' where their SNAPSHOTS (alist
  KEYMAP-SYMBOL → keymap) bind its key, a prefix of it to a command, or keys under it: :map is the map's spec,
  :states its states.  Without SNAPSHOTS, HAND stands in — the profile's (SCOPE KEY DESCRIPTION STATES) claims, on
  the same key, each on the engine maps whose states it covers.  The description is HAND's for the key, else what
  the engine binds.  MIXED (a stack with another editor's keys, where Vim's insert-state keys are off): no claim
  in insert state.
- A binding in `global-map' or in one of PANEL-MAPS (keymap symbols) meets drgnx's leader and panel maps (the
  plain symbols of `:maps') where BINDINGS put a key equal to its key, a prefix of it, or under it: :drop lists
  those bindings, :rank is the highest of theirs, :id the one whose key is the binding's or a prefix of it.  A
  panel's binding meets them only in `panels', and they win there whatever the ranks: they are above the panel's
  own map.
A binding is not claimed by its own layer."
  (let ((engine (drgnx-keys-modal--engine-maps modal)) (own (drgnx-keys-modal--own-maps modal))
        (by-event (make-hash-table :test #'equal)) out)
    (cl-flet ((mapsym (b) (let ((m (plist-get b :map))) (or (if (consp m) (cdr m) m) 'global-map)))   ; nil: global
              (states (ss) (drgnx-keys-modal-order (if mixed (remq 'insert ss) ss))))
      ;; drgnx's modal maps' bindings by (MAP . first event): only those can be prefixes of each other.
      (dolist (l bindings)
        (when (assq (mapsym l) own)
          (push l (gethash (cons (mapsym l) (aref (drgnx-keys--parse (plist-get l :key)) 0)) by-event))))
      (dolist (b bindings)
        (let* ((key (plist-get b :key)) (parsed (drgnx-keys--parse key)) (sym (mapsym b))
               (global (eq sym 'global-map)) (panel (memq sym panel-maps)))
          (when (and global (not (eq (plist-get b :layer) layer)))
            (let ((desc (nth 2 (cl-find-if (lambda (h) (equal (drgnx-keys--parse (nth 1 h)) parsed)) hand))))
              (if snapshots
                  (pcase-dolist (`(,spec . ,ss) engine)
                    (let ((snap (alist-get (cdr spec) snapshots)) (ss (states ss)))
                      (when-let* ((ss) (snap) (found (drgnx-keys--existing snap key)))
                        (push (list :key key :claim (or desc (cdr found)) :layer layer :rank rank :states ss :map spec
                                    :binding b)
                              out))))
                (dolist (h hand)
                  (when (and (nth 3 h) (equal (drgnx-keys--parse (nth 1 h)) parsed))
                    (pcase-dolist (`(,spec . ,ss) engine)
                      (when-let* (((cl-subsetp ss (nth 3 h))) (ss (states ss)))
                        (push (list :key key :claim (nth 2 h) :layer layer :rank rank :states ss :map spec :binding b)
                              out))))))))
          (when (or global panel)
            (pcase-dolist (`(,osym . ,ss) own)
              (let ((where (if panel (and (memq 'panels ss) '(panels)) (states ss)))
                    (ls (cl-remove-if-not
                         (lambda (l) (and (not (eq (plist-get l :layer) (plist-get b :layer)))
                                          (let ((lk (plist-get l :key)))
                                            (or (equal (drgnx-keys--parse lk) parsed) (drgnx-keys--prefix-of-p lk key)
                                                (drgnx-keys--prefix-of-p key lk)))))
                         (reverse (gethash (cons osym (aref parsed 0)) by-event)))))
                (when (and where ls)
                  (let ((exact (cl-find-if-not (lambda (l) (drgnx-keys--prefix-of-p key (plist-get l :key))) ls))
                        (top (cl-reduce (lambda (w l) (if (> (plist-get l :rank) (plist-get w :rank)) l w)) ls)))
                    (push (append (list :key key
                                        :claim (and (not exact)
                                                    (format "the %s %s keys" (if (equal ss '(panels)) "panel map's" "leader's")
                                                            key))
                                        :layer (plist-get top :layer)
                                        :rank (if panel most-positive-fixnum (plist-get top :rank))
                                        :states where :map osym :binding b :drop ls)
                                  (and exact (list :id (plist-get exact :id))))
                          out)))))))))
    (nreverse out)))

(provide 'drgnx-keys-modal)
;;; drgnx-keys-modal.el ends here
