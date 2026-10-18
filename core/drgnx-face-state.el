;;; drgnx-face-state.el --- What the face remembers: face.eld in the state directory -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One small file, `face.eld' in `drgnx-state-dir', holding a plist of things the face (M12f part A) keeps between
;; runs, for example `:start-dismissed' (the start page's "Don't show this again").  Batch-safe: it needs nothing
;; but `drgnx-paths', so the launcher's Emacs and the tests read it too.  A missing or unreadable file reads as nil;
;; a write replaces the file whole and atomically, so an interrupted write never leaves half a plist.

;;; Code:
(require 'drgnx-paths)

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
                     (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))
        (and (proper-list-p state) (zerop (% (length state) 2)) state)))))

(defun drgnx-face-state-write (plist)
  "Replace the face's state with PLIST (a plist of symbols, numbers, strings and lists); write it atomically."
  (let* ((file (drgnx-face-state-file)) (dir (file-name-directory file)))
    (make-directory dir t)
    (let ((tmp (make-temp-file (expand-file-name ".face-" dir))))
      (with-temp-file tmp (let ((print-length nil) (print-level nil)) (prin1 plist (current-buffer))))
      (rename-file tmp file t))
    plist))

(provide 'drgnx-face-state)
;;; drgnx-face-state.el ends here
