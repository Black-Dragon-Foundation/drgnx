;;; drgnx-ui-kit.el --- The UI kit: glyphs by meaning, status faces -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What every surface that draws a mark shares, in core, so the status bar, the lists and the notices never
;; depend on the `ui/face' module being loaded.  Glyphs are by meaning: `close' is the mark of a close button,
;; `fail' is "tests failed", `dismiss' is "dismiss this notice" -- restyling one leaves the others alone.  Each
;; glyph has an ASCII form for terminals that do not write UTF-8.  The status faces inherit theme faces.
;; The file is not `drgnx-ui.el': that is the harness's feature (harness/drgnx-ui.el), and the test runner has both on its
;; `load-path'.  See docs/develop/core.md ("The UI kit") and docs/guide/face.md.

;;; Code:
(require 'subr-x)

(defcustom drgnx-face-glyphs
  '((handle "⠿" . "::") (close "×" . "x") (branch "⑂" . "Y") (warning "⚠" . "!") (ok "✓" . "+")
    (busy "◎" . "@") (waiting "◐" . "?") (paused "⏸" . "||") (ahead "↑" . "^") (behind "↓" . "v")
    (dot "●" . "*") (circle "○" . "o") (sep " · " . " | ") (flag "⚑" . "#")
    (diamond "◆" . "<>") (search "⌕" . "/") (bullet "•" . ">") (minimize "–" . "-") (maximize "▢" . "[]")
    (fail "✕" . "X") (stopped "■" . "#") (dismiss "×" . "x") (unqueue "−" . "-")
    (info "ℹ" . "i") (warn "⚠" . "!"))
  "The glyphs drgnx draws: NAME → (UNICODE . ASCII).  The ASCII form is used on a terminal frame that is not UTF-8.
One glyph per meaning: `close' (a close button), `fail' (something failed), `dismiss' (dismiss a notice) and
`unqueue' (take a queued message back) look alike by default and are separate so each can be restyled alone.
Change one to suit your font; `drgnx-face-glyph' reads this."
  :type '(alist :key-type symbol :value-type (cons (string :tag "Unicode") (string :tag "ASCII")))
  :group 'drgnx)

(defun drgnx-ui-ascii-frame-p (&optional frame)
  "Non-nil when FRAME (default: the selected one) is a terminal frame whose terminal does not write UTF-8."
  (let ((frame (or frame (selected-frame))))
    (and (not (display-graphic-p frame))
         (let ((coding (terminal-coding-system (frame-terminal frame))))
           (not (and coding (string-prefix-p "utf-8" (symbol-name (coding-system-base coding)))))))))

(defun drgnx-face-glyph (name &optional frame)
  "The glyph NAME (see `drgnx-face-glyphs') as a string: its ASCII form on a terminal frame that is not UTF-8.
FRAME defaults to the selected one.  nil when NAME is unknown."
  (when-let* ((g (alist-get name drgnx-face-glyphs)))
    (if (drgnx-ui-ascii-frame-p frame) (cdr g) (car g))))

;;;; Status

(defface drgnx-status-ok '((t :inherit success)) "Something is fine." :group 'drgnx)
(defface drgnx-status-info '((t :inherit shadow)) "Something to know." :group 'drgnx)
(defface drgnx-status-warn '((t :inherit warning)) "Something to look at." :group 'drgnx)
(defface drgnx-status-fail '((t :inherit error)) "Something failed." :group 'drgnx)
(defface drgnx-status-needs-you '((t :inherit error)) "Something waits for you." :group 'drgnx)

(defconst drgnx-ui--severities
  '((ok ok drgnx-status-ok) (info info drgnx-status-info) (warn warn drgnx-status-warn)
    (fail fail drgnx-status-fail) (needs-you waiting drgnx-status-needs-you))
  "SEVERITY → (GLYPH-NAME FACE).")

(defun drgnx-ui-status (severity &optional text)
  "The glyph for SEVERITY (ok, info, warn, fail or needs-you), then a space and TEXT when given, in its status face.
An unknown SEVERITY is `info'."
  (pcase-let ((`(,_ ,glyph ,face) (or (assq severity drgnx-ui--severities) (assq 'info drgnx-ui--severities))))
    (propertize (if text (concat (drgnx-face-glyph glyph) " " text) (drgnx-face-glyph glyph)) 'face face)))

(provide 'drgnx-ui-kit)
;;; drgnx-ui-kit.el ends here
