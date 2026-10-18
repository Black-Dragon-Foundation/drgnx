;;; drgnx-face-state.el --- What the face remembers: face.eld in the state directory -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One small file, `face.eld' in `drgnx-state-dir', holding a plist of things the face (M12f part A) keeps between
;; runs, for example `:start-dismissed' (the start page's "Don't show this again").  Batch-safe: it needs nothing
;; but `drgnx-paths', so the launcher's Emacs and the tests read it too.  A missing or unreadable file reads as nil;
;; a write replaces the file whole and atomically, so an interrupted write never leaves half a plist.

;;; Code:
(require 'drgnx-paths)
(defvar read-eval)

(defun drgnx-face-state-file ()
  "The file the face keeps its state in: face.eld in the state directory.
Worked out from \"/\", never from the current buffer's folder: with a remote one (a remote *scratch*) expanding the
state directory's \"~\" would ask that host."
  (let ((default-directory "/"))
    (expand-file-name "face.eld" (drgnx-state-dir))))

(defun drgnx-face-state-read ()
  "The face's state as a plist; nil when the file is missing, unreadable or not a plist.  Never signals, never asks."
  (let ((file (drgnx-face-state-file)))
    (when (file-readable-p file)
      (let ((state (ignore-errors
                     (with-temp-buffer (insert-file-contents file) (let ((read-eval nil)) (read (current-buffer)))))))
        (and (proper-list-p state) (zerop (% (length state) 2)) state)))))

(defun drgnx-face-state-write (plist)
  "Replace the face's state with PLIST (a plist of symbols, numbers, strings and lists); write it atomically."
  (let* ((file (drgnx-face-state-file)) (dir (file-name-directory file)))
    (make-directory dir t)
    (let ((tmp (make-temp-file (expand-file-name ".face-" dir))))
      (with-temp-file tmp (let ((print-length nil) (print-level nil)) (prin1 plist (current-buffer))))
      (rename-file tmp file t))
    plist))

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
