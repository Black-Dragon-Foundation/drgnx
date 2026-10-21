;;; drgnx-ui-kit.el --- The UI kit: glyphs by meaning, status faces, buttons -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What every surface that draws a mark shares, in core, so the status bar, the lists and the notices never
;; depend on the `ui/face' module being loaded.  Glyphs are by meaning: `close' is the mark of a close button,
;; `fail' is "tests failed", `dismiss' is "dismiss this notice" -- restyling one leaves the others alone.  Each
;; glyph has an ASCII form for terminals that do not write UTF-8.  The status faces inherit theme faces.  A button
;; runs a registry command, a command or a function; the close button is the `close' glyph on a header line.
;; The file is not `drgnx-ui.el': that is the harness's feature (harness/drgnx-ui.el), and the test runner has both on its
;; `load-path'.  See docs/develop/core.md ("The UI kit") and docs/guide/face.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-surfaces)

(defconst drgnx-ui--default-glyphs
  '((handle "⠿" . "::") (close "×" . "x") (branch "⑂" . "Y") (warning "⚠" . "!") (ok "✓" . "+")
    (busy "◎" . "@") (waiting "◐" . "?") (paused "⏸" . "||") (ahead "↑" . "^") (behind "↓" . "v")
    (dot "●" . "*") (circle "○" . "o") (sep " · " . " | ") (flag "⚑" . "#")
    (diamond "◆" . "<>") (search "⌕" . "/") (bullet "•" . ">") (minimize "–" . "-") (maximize "▢" . "[]")
    (fail "✕" . "X") (stopped "■" . "#") (dismiss "×" . "x") (unqueue "−" . "-")
    (info "ℹ" . "i") (warn "⚠" . "!"))
  "The standard glyph table: the default of `drgnx-face-glyphs', and where a name the option lacks is found.")

(defcustom drgnx-face-glyphs drgnx-ui--default-glyphs
  "The glyphs drgnx draws: NAME → (UNICODE . ASCII).  The ASCII form is used on a terminal frame that is not UTF-8.
One glyph per meaning: `close' (a close button), `fail' (something failed), `dismiss' (dismiss a notice) and
`unqueue' (take a queued message back) look alike by default and are separate so each can be restyled alone.
Change one to suit your font; `drgnx-face-glyph' reads this.  A name missing here (a value saved before drgnx
added it) is drawn from the standard table."
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
FRAME defaults to the selected one.  A NAME the option lacks comes from `drgnx-ui--default-glyphs'; nil when
neither has it."
  (when-let* ((g (or (alist-get name drgnx-face-glyphs) (alist-get name drgnx-ui--default-glyphs))))
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

;;;; Buttons

(defface drgnx-ui-button '((t :inherit button)) "A button drawn by the UI kit (`drgnx-ui-button')." :group 'drgnx)

(defface drgnx-ui-close '((t :inherit shadow))
  "The close button (×) of a title, tab row or popup header (`drgnx-ui-close-button')." :group 'drgnx)

(defvar drgnx-ui--button-maps (make-hash-table :test #'eq :weakness 'key)
  "ACTION → alist WHERE → the keymap of a button that runs ACTION.  Weak: a closure's maps go with it.")

(defun drgnx-ui--run (action)
  "Run ACTION: a registry id through `drgnx-surfaces-run' (the usage count and the key tip follow), else a command
called interactively, else a function of no arguments.  A symbol that is none of these (its module is off) says so."
  (cond ((and (symbolp action) (drgnx-commands-get action)) (drgnx-surfaces-run action))
        ((commandp action) (call-interactively action))
        ((and (symbolp action) (not (fboundp action))) (user-error "%s is not available (its module is off)" action))
        (t (funcall action))))

(defun drgnx-ui--button-map (action where)
  "The keymap of a button that runs ACTION on WHERE, built once per (ACTION . WHERE)."
  (let ((maps (gethash action drgnx-ui--button-maps)))
    (or (alist-get where maps)
        (let ((m (make-sparse-keymap)) (run (lambda () (interactive) (drgnx-ui--run action))))
          (if (eq where 'text)
              (progn (define-key m [mouse-1] run) (define-key m [mouse-2] run) (define-key m (kbd "RET") run))
            (define-key m (vector where 'mouse-1) run))
          (puthash action (cons (cons where m) maps) drgnx-ui--button-maps)
          m))))

(cl-defun drgnx-ui-button (label action &key help face (where 'text) props)
  "LABEL as a button that runs ACTION: a registry id (run as from the palette, so its use is counted), a command, or
a function of no arguments.  WHERE is `text' (`mouse-1' and RET), `header-line', `mode-line' or `tab-line' (`mouse-1'
there).  FACE defaults to `drgnx-ui-button'; HELP is the `help-echo'; PROPS are more text properties."
  (apply #'propertize label 'face (or face 'drgnx-ui-button) 'mouse-face 'highlight 'help-echo help
         (if (eq where 'text) 'keymap 'local-map) (drgnx-ui--button-map action where)
         (append (and (eq where 'text) '(follow-link t)) props)))

(defun drgnx-ui-insert-button (label action &rest keys)
  "Insert at point the button `drgnx-ui-button' makes of LABEL, ACTION and KEYS."
  (insert (apply #'drgnx-ui-button label action keys)))

(defvar drgnx-ui--close-maps nil "Alist (COMMAND . WHERE) → the keymap of a close button that runs COMMAND.")

(cl-defun drgnx-ui-close-button (command help &key (where 'header-line) props)
  "The `close' glyph as a button on WHERE (default `header-line'; or `mode-line', `tab-line', `text'): `mouse-1' runs
COMMAND itself, so it gets the click event.  HELP is its `help-echo'; PROPS are text properties the command reads.
Build it when a title or row is set, never while drawing."
  (let* ((key (cons command where))
         (map (or (alist-get key drgnx-ui--close-maps nil nil #'equal)
                  (let ((m (make-sparse-keymap)))
                    (define-key m (if (eq where 'text) [mouse-1] (vector where 'mouse-1)) command)
                    (setf (alist-get key drgnx-ui--close-maps nil nil #'equal) m)))))
    (apply #'propertize (drgnx-face-glyph 'close) 'face 'drgnx-ui-close 'mouse-face 'highlight
           (if (eq where 'text) 'keymap 'local-map) map 'help-echo help props)))

(provide 'drgnx-ui-kit)
;;; drgnx-ui-kit.el ends here
