;;; drgnx-tty-popups.el --- Module ui/terminal-popups: popups in terminal windows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What a popup is in a terminal window (`emacsclient -t', `emacs -nw'):
;;
;; - corfu's popup is a child frame of the terminal frame (`tty-child-frames'), as it is on a graphical one.  A child
;;   frame that has a border draws it with the box slots of `standard-display-table': box-drawing characters while
;;   every terminal writes UTF-8, ASCII (+ - |) as soon as one does not.
;; - A terminal that does not write UTF-8 (a C locale) shows `?' for the glyphs drgnx draws in the tab line,
;;   the breadcrumb and the Explorer: its windows get a display table with ASCII marks instead.  The table
;;   belongs to the windows of that terminal's frames, never to the session.
;;
;; `drgnx-tty-popups-setup' is called for each terminal frame by ui/terminal (modules/ui/drgnx-tty-frames.el).
;; Nothing here prompts or signals: it runs from hooks and timers; errors go to `drgnx-hooks-problems'.
;; See docs/guide/terminal.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-hooks)
(require 'drgnx-modules)
(require 'drgnx-ui-kit)
(require 'drgnx-frame-kind)
(defvar standard-display-table)
(declare-function drgnx-tty-frames--tty-frames "drgnx-tty-frames")

;;;; Borders: the box slots of the standard display table

(defconst drgnx-tty-popups-box-slots
  '(box-vertical box-horizontal box-down-right box-down-left box-up-right box-up-left)
  "The single-line border slots of a display table, which tty child frames and menu separators draw with.")

(defconst drgnx-tty-popups--box-unicode [#x2502 #x2500 #x250c #x2510 #x2514 #x2518]
  "Box drawing: │ ─ ┌ ┐ └ ┘.")

(defconst drgnx-tty-popups--box-ascii [?| ?- ?+ ?+ ?+ ?+] "ASCII: | - + + + +.")

(defalias 'drgnx-tty-popups-ascii-p #'drgnx-ui-ascii-frame-p
  "Non-nil when FRAME (default: the selected one) is a terminal frame whose terminal does not write UTF-8.")

(defun drgnx-tty-popups--borders (ascii)
  "Set the box slots of `standard-display-table': ASCII marks when ASCII is non-nil, else box drawing.
Only these slots: the window dividers and everything else keep what they have."
  (unless standard-display-table (setq standard-display-table (make-display-table)))
  (let ((glyphs (if ascii drgnx-tty-popups--box-ascii drgnx-tty-popups--box-unicode)))
    (seq-do-indexed (lambda (slot i)
                      (set-display-table-slot standard-display-table slot (make-glyph-code (aref glyphs i))))
                    drgnx-tty-popups-box-slots)))

(defun drgnx-tty-popups--tty-frames ()
  "The live terminal frames of terminals Emacs set up."
  (if (fboundp 'drgnx-tty-frames--tty-frames)
      (drgnx-tty-frames--tty-frames)
    (seq-filter (lambda (f) (eq (drgnx-state-frame-kind f) 'tty)) (frame-list))))

(defun drgnx-tty-popups--update-borders ()
  "Follow the terminals now connected: the table is shared, so one terminal that does not write UTF-8 makes the
borders ASCII for all of them.  Nothing when no terminal frame is left."
  (when-let* ((frames (drgnx-tty-popups--tty-frames)))
    (drgnx-tty-popups--borders (seq-some #'drgnx-tty-popups-ascii-p frames))))

;;;; ASCII terminals: marks for the glyphs drgnx draws

(defconst drgnx-tty-popups-ascii-glyphs
  '((?× . "x") (?● . "*") (?› . ">") (?▾ . "v") (?▸ . ">") (?│ . "|") (?— . "-") (?… . "...") (?· . ".") (?→ . "->")
    (?‘ . "'") (?’ . "'") (?“ . "\"") (?” . "\""))
  "Character → its ASCII mark, for the tab line (× close, ● changed), the breadcrumb (›), the Explorer
\(▾ ▸ chevrons, │ guides) and the dashes, dots, arrows, ellipses and curved quotes of their text.")

(defvar drgnx-tty-popups--ascii-table nil "The display table of `drgnx-tty-popups-ascii-glyphs', made once.")

(defun drgnx-tty-popups--ascii-table ()
  "The display table with the ASCII marks."
  (or drgnx-tty-popups--ascii-table
      (setq drgnx-tty-popups--ascii-table
            (let ((table (make-display-table)))
              (pcase-dolist (`(,char . ,mark) drgnx-tty-popups-ascii-glyphs)
                (aset table char (vconcat mark)))
              table))))

(defun drgnx-tty-popups--ascii-windows (frame)
  "Give every window of FRAME, the echo area's included, without a display table the ASCII one (a window that has
its own keeps it)."
  (dolist (w (window-list frame t))
    (unless (window-display-table w)
      (set-window-display-table w (drgnx-tty-popups--ascii-table)))))

(defun drgnx-tty-popups--ascii-string (string)
  "STRING with the marks of `drgnx-tty-popups-ascii-glyphs' for its glyphs (a mark of several characters
gives its first), text properties kept; STRING itself when it has none of them."
  (if (not (string-match-p "[^[:ascii:]]" string))
      string
    (let ((out string))
      (pcase-dolist (`(,char . ,mark) drgnx-tty-popups-ascii-glyphs)
        (when (seq-contains-p out char)
          (setq out (subst-char-in-string char (aref mark 0) out))))
      out)))

(defun drgnx-tty-popups--ascii-value (value)
  "VALUE, a tab line, header line or mode line format, with its strings written with ASCII marks: a string, or the
strings of a list (a `:propertize' form's first element too); an `:eval' form is left, since it makes its string
only when drawn.  VALUE itself when nothing changes."
  (cond ((stringp value) (drgnx-tty-popups--ascii-string value))
        ((not (and (consp value) (proper-list-p value))) value)
        ((eq (car value) :eval) value)
        ((eq (car value) :propertize)
         (let ((elt (drgnx-tty-popups--ascii-value (cadr value))))
           (if (eq elt (cadr value)) value (cons :propertize (cons elt (cddr value))))))
        (t (let ((new (mapcar #'drgnx-tty-popups--ascii-value value)))
             (if (cl-every #'eq new value) value new)))))

(defun drgnx-tty-popups--ascii-chrome-window (window)
  "The tab line, header line and mode line parameters of WINDOW — a display table does not reach those — written
with ASCII marks."
  (dolist (param '(tab-line-format header-line-format mode-line-format))
    (let* ((value (window-parameter window param))
           (ascii (drgnx-tty-popups--ascii-value value)))
      (unless (eq ascii value) (set-window-parameter window param ascii)))))

(defun drgnx-tty-popups--chrome-set (orig window param value)
  "Around `drgnx-chrome--set' (it sets a window parameter only when it differs from what it wants): on a frame of
an ASCII terminal the parameter holds the rewritten value, so it is given the rewritten one, and a redundant set,
which redraws the window, is skipped as it is elsewhere."
  (funcall orig window param
           (if (drgnx-tty-popups--ascii-frame-p (window-frame window)) (drgnx-tty-popups--ascii-value value) value)))

(defun drgnx-tty-popups--ascii-frame-p (frame)
  (and (frame-live-p frame) (frame-parameter frame 'drgnx-tty-ascii)))

(defun drgnx-tty-popups--windows-changed ()
  "`window-configuration-change-hook': windows made on a frame of an ASCII terminal get the table too."
  (let ((frame (selected-frame)))
    (when (drgnx-tty-popups--ascii-frame-p frame)
      (drgnx-tty-popups--ascii-windows frame))))

(defun drgnx-tty-popups--pre-redisplay (window)
  "`pre-redisplay-functions': the chrome strings of a window of an ASCII terminal, as it is about to be drawn
\(whoever wrote them, whenever)."
  (when (drgnx-tty-popups--ascii-frame-p (window-frame window))
    (drgnx-tty-popups--ascii-chrome-window window)))

;;;; Hooks only while a terminal needs them

(defun drgnx-tty-popups--hook (on hook function)
  (if on (add-hook hook function) (remove-hook hook function)))

(defun drgnx-tty-popups--sync ()
  "Have the hooks that run on every redisplay or command only while some terminal frame needs them: the ASCII
ones while a terminal does not write UTF-8.  A session with graphical windows only, or UTF-8 terminals, pays
nothing."
  (let* ((frames (drgnx-tty-popups--tty-frames))
         (ascii (and (seq-some #'drgnx-tty-popups--ascii-frame-p frames) t)))
    (drgnx-tty-popups--hook ascii 'pre-redisplay-functions #'drgnx-tty-popups--pre-redisplay)
    (drgnx-tty-popups--hook ascii 'window-configuration-change-hook #'drgnx-tty-popups--windows-changed)
    (if ascii
        (advice-add 'drgnx-chrome--set :around #'drgnx-tty-popups--chrome-set)
      (advice-remove 'drgnx-chrome--set #'drgnx-tty-popups--chrome-set))))

;;;; Each terminal frame

(defun drgnx-tty-popups-setup (&optional frame)
  "Look after FRAME (default: the selected one) when it is a terminal frame: the border glyphs of child frames,
and the ASCII table for the windows of a terminal that does not write UTF-8.  Never prompts or signals."
  (let ((frame (or frame (selected-frame))))
    (when (and (frame-live-p frame) (not (display-graphic-p frame))
               (not (drgnx-module-disabled-p 'ui/terminal-popups)))
      (condition-case err
          (progn
            (drgnx-tty-popups--update-borders)
            (when (drgnx-tty-popups-ascii-p frame)
              (set-frame-parameter frame 'drgnx-tty-ascii t)
              (drgnx-tty-popups--ascii-windows frame)
              (dolist (w (window-list frame 'nomini)) (drgnx-tty-popups--ascii-chrome-window w)))
            (drgnx-tty-popups--sync))
        (error (push (format "ui/terminal-popups: %s" (error-message-string err)) drgnx-hooks-problems))))))

(defun drgnx-tty-popups--frame-deleted (frame)
  "`delete-frame-functions': once it is gone, the terminals left decide the borders and the hooks again.
A killed terminal's frames are dead when this runs (the classifier says nil for them): they count as top-level."
  (unless (eq (drgnx-state-frame-kind frame) 'child)
    (run-at-time 0 nil (lambda ()
                         (let ((inhibit-interaction t))
                           (condition-case nil
                               (progn (drgnx-tty-popups--update-borders)
                                      (drgnx-tty-popups--sync))
                             (error nil)))))))

;;;; Turning the module off

(defun drgnx-tty-popups--unset-borders ()
  "Empty the box slots of `standard-display-table' that still hold drgnx's glyphs (Emacs's own borders again); a
slot someone else set since stays."
  (when standard-display-table
    (seq-do-indexed (lambda (slot i)
                      (when (memql (display-table-slot standard-display-table slot)
                                   (list (make-glyph-code (aref drgnx-tty-popups--box-unicode i))
                                         (make-glyph-code (aref drgnx-tty-popups--box-ascii i))))
                        (set-display-table-slot standard-display-table slot nil)))
                    drgnx-tty-popups-box-slots)))

(defun drgnx-tty-popups--teardown ()
  "The module's teardown: what each terminal frame's setup did, which nothing records — the hooks and the advice
`drgnx-tty-popups--sync' keeps while a terminal needs them, the ASCII display table
of its windows (a window's own table stays) and the box slots.  The chrome strings come back as the chrome draws."
  (drgnx-tty-popups--hook nil 'pre-redisplay-functions #'drgnx-tty-popups--pre-redisplay)
  (drgnx-tty-popups--hook nil 'window-configuration-change-hook #'drgnx-tty-popups--windows-changed)
  (advice-remove 'drgnx-chrome--set #'drgnx-tty-popups--chrome-set)
  (dolist (frame (frame-list))
    (when (frame-parameter frame 'drgnx-tty-ascii)
      (set-frame-parameter frame 'drgnx-tty-ascii nil)
      (dolist (w (window-list frame t))
        (when (and drgnx-tty-popups--ascii-table (eq (window-display-table w) drgnx-tty-popups--ascii-table))
          (set-window-display-table w nil)))))
  (drgnx-tty-popups--unset-borders))

(drgnx-module-define 'ui/terminal-popups
                     :doc "Popups in terminal windows: corfu's child frame with box-drawing borders, ASCII marks on a terminal that does not write UTF-8."
                     :stage 'startup
                     :teardown #'drgnx-tty-popups--teardown
                     :setup (lambda ()
                              (add-hook 'delete-frame-functions #'drgnx-tty-popups--frame-deleted)
                              ;; terminal frames made before this module ran (each one's setup syncs the hooks)
                              (dolist (f (drgnx-tty-popups--tty-frames)) (drgnx-tty-popups-setup f))))

(provide 'drgnx-tty-popups)
;;; drgnx-tty-popups.el ends here
