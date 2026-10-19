;;; drgnx-face-state.el --- What the face remembers: face.eld in the state directory -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One small file, `face.eld' in `drgnx-state-dir', holding a plist of things the face (M12f part A) keeps between
;; runs, for example `:start-dismissed' (the start page's "Don't show this again").  Batch-safe: it needs nothing
;; but the file layer (`drgnx-file', `drgnx-config'; both need only `drgnx-paths'), so the launcher's Emacs and the
;; tests read it too.  A missing or unreadable file reads as nil.  A change is a `drgnx-file-update': under the file's
;; lock, on a fresh read, atomically; keys this drgnx does not know stay, a file that cannot be read is copied aside
;; (`face.eld.bak-<time>') before it is started again, and a change that changes nothing writes nothing.  The file is
;; printed on one line (`prin1'), because bin/drgnx reads `:variant' and `:gtk-theme' from it with `sed'.

;;; Code:
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)

(defconst drgnx-face-state--header ";; drgnx: what the face remembers, written by drgnx (docs/guide/face.md)\n"
  "The comment a new face.eld starts with.  It names none of the keys bin/drgnx looks for with `sed'.")

(drgnx-config-define 'face
                     :file "face.eld" :dir 'state :shape 'plist :version 1 :reload 'mtime :last-good t :default nil
                     :schema '(plist (:variant (or symbol null) "The title bar's variant: dark, light or nil")
                                     (:gtk-theme (or string null) "The GTK theme the launchers start GTK with")
                                     (:start-dismissed (or boolean null) "t once \"Don't show this again\" was chosen"))
                     :header drgnx-face-state--header
                     :doc "What the face remembers between runs: the title bar's variant, its GTK theme (read by bin/drgnx) and the start page's dismissal.")

(defun drgnx-face-state-file ()
  "The file the face keeps its state in: face.eld in the state directory.
Worked out from \"/\", never from the current buffer's folder: with a remote one (a remote *scratch*) expanding the
state directory's \"~\" would ask that host."
  (drgnx-config-file 'face))

(defun drgnx-face-state--plist (data)
  "DATA when it is a plist (a list of an even length), else nil."
  (and (proper-list-p data) (zerop (% (length data) 2)) data))

(defun drgnx-face-state-read ()
  "The face's state as a plist; nil when the file is missing, unreadable or not a plist.  Never signals, never asks."
  (let ((r (ignore-errors (drgnx-file-read (drgnx-face-state-file)))))
    (and (eq (plist-get r :status) 'ok) (drgnx-face-state--plist (plist-get r :data)))))

(defun drgnx-face-state-update (fn &optional timeout)
  "Replace the face's state with (FN STATE), STATE being the plist as the file holds it now; return the new state.
It runs under the file's lock, on a fresh read, and writes only when the plist changed.  A file that cannot be read,
or that holds something other than a plist, is copied aside first and FN gets nil.  Waits at most TIMEOUT seconds
for the lock (default 1; an automatic path passes 0), then signals `drgnx-file-busy'.  Never asks."
  (let ((file (drgnx-face-state-file)) (inhibit-interaction t))
    (drgnx-file-update file
                       (lambda (data)
                         (let ((state (drgnx-face-state--plist data)))
                           (when (and data (not state)) (drgnx-file-backup file))
                           (funcall fn state)))
                       :on-unreadable 'backup :timeout (or timeout 1.0) :header drgnx-face-state--header)))

(defun drgnx-face-state-put (plist &optional timeout)
  "Set the keys of PLIST in the face's state and keep every other key; return the new state.  See
`drgnx-face-state-update' for the lock, TIMEOUT and what happens to a file that cannot be read."
  (drgnx-face-state-update
   (lambda (state)
     (cl-loop for (key value) on plist by #'cddr do (setq state (plist-put state key value)))
     state)
   timeout))

(defun drgnx-face-state-write (plist)
  "Replace the face's state with PLIST (a plist of symbols, numbers, strings and lists): every other key goes.
Prefer `drgnx-face-state-put', which keeps the keys it is not setting."
  (drgnx-face-state-update (lambda (_) plist))
  plist)

;; The title bar (M12f A2) keeps `:variant' (`dark', `light' or nil) and `:gtk-theme' (a theme name such as "Adwaita") here
;; so that the launchers can start GTK in the right variant before any frame exists: bin/drgnx reads the file with `sed'
;; (open_start) and `drgnx-pkg-service-unit' reads it with `drgnx-face-state-gtk-theme'.

(defun drgnx-face-state-gtk-theme ()
  "The value for GTK_THEME that the state asks for, \"NAME:dark\" or \"NAME:light\", or nil.
nil when there is no variant (the setting is `system'), no theme name, or a name that is not a plain one: it ends up
in a unit file and in an environment variable, so only letters, digits and . _ + - are accepted.  Never signals."
  (let* ((state (drgnx-face-state-read)) (variant (plist-get state :variant)) (theme (plist-get state :gtk-theme)))
    (and (memq variant '(dark light)) (stringp theme)
         (string-match-p "\\`[A-Za-z0-9._+-]+\\'" theme)
         (format "%s:%s" theme variant))))

(provide 'drgnx-face-state)
;;; drgnx-face-state.el ends here
