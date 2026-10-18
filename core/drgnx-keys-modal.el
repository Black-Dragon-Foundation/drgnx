;;; drgnx-keys-modal.el --- Where a modal profile's keys go (pure) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The key resolver (`drgnx-keys-resolve') asks these functions where a key binds when a profile has a `:modal'
;; plist (keys/vim.eld): a leader key (`SPC f f', `C-w h') always goes in the profile's leader map; any other key in
;; the entry's map, the command's, the modal plist's `:default-map', else the profile's.  `:maps' of the modal plist
;; says which keymaps carry modal keys and in which states; a modal profile's keys in those maps are kept in a
;; stack where the profile covers fewer scopes (a mixed stack).  Nothing here touches a keymap or needs evil.
;; See docs/guide/keys.md and docs/develop/core.md ("Modal core").

;;; Code:
(require 'cl-lib)

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

(provide 'drgnx-keys-modal)
;;; drgnx-keys-modal.el ends here
