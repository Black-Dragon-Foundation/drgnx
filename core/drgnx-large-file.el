;;; drgnx-large-file.el --- The large-file flag: what producers check, what callers bind -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A buffer that holds a large file (or a part of one) carries the permanent-local flag `drgnx-large-file'.
;; Producers — a mode hook, a `find-file-hook' function, a status-bar segment — check `drgnx-large-file-p' and show
;; nothing; agents read such a file from disk.  Callers that open files bind `drgnx-large-file-open' to say what
;; they need.  The module editor/large-files sets the flag; with it off the flag is never set and every check is
;; one nil test.  No dependencies, so core and every module can require it.  See docs/develop/core.md.

;;; Code:

(defvar-local drgnx-large-file nil
  "How this buffer holds a large file: nil (not a large file), `lean' (whole, with the expensive modes off), `raw'
\(whole, literally) or `chunks' (a part at a time).  Permanent: a major-mode change keeps it.")
(put 'drgnx-large-file 'permanent-local t)

(defvar drgnx-large-file--opening nil
  "`lean' while a lean open runs the original `find-file-noselect' (dynamically bound): the major mode and its
hooks run before the flag is set, and `drgnx-large-file-p' answers for the buffer being opened all the same.")

(defvar drgnx-large-file-open nil
  "What a caller that visits a file needs if it is large: `auto' (never ask: the remembered answer, else chunks),
`whole' (the whole file, lean, never ask) or nil (decided by context).  Let-bound around the visit, or set
buffer-locally in a buffer whose commands visit files (an agent review's diff).  A file that only binds it declares
`(defvar drgnx-large-file-open)'.")

(defsubst drgnx-large-file-p (&optional buffer)
  "Non-nil when BUFFER (default the current one) holds a large file: its flag is set, or it is current while a lean
open of it is running.  One variable read: safe in redisplay and on every keystroke."
  (if (or (null buffer) (eq buffer (current-buffer)))
      (or drgnx-large-file drgnx-large-file--opening)
    (buffer-local-value 'drgnx-large-file buffer)))

(provide 'drgnx-large-file)
;;; drgnx-large-file.el ends here
