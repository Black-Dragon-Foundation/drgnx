;;; drgnx-tty-popups.el --- Module ui/terminal-popups: popups in terminal windows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What a popup is in a terminal window (`emacsclient -t', `emacs -nw'):
;;
;; - Emacs 31.1 and later (`tty-child-frames'): corfu's popup is a child frame of the terminal frame, as it is on
;;   a graphical one.  A child frame that has a border draws it with the box slots of `standard-display-table':
;;   box-drawing characters while every terminal writes UTF-8, ASCII (+ - |) as soon as one does not.
;; - Emacs 30.2: no child frames.  corfu's own commands fall back to `completion--in-region' there, but its
;;   completion as you type (corfu-auto) shows nothing at all.  This module fills the gap: in a terminal frame,
;;   with `corfu-mode' and `corfu-auto' on, the candidates appear in `*Completions*' in the popup lane
;;   (wb/drgnx-popup.el), nothing is inserted, and C-g (or leaving the word) removes them.  A graphical frame
;;   keeps corfu's popup.
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
(require 'drgnx-timer)
(require 'drgnx-frame-kind)
(defvar corfu-mode)
(defvar corfu-auto)
(defvar corfu-auto-delay)
(defvar corfu-auto-prefix)
(defvar corfu-auto-commands)
(defvar standard-display-table)
(declare-function drgnx-tty-frames--tty-frames "drgnx-tty-frames")

(defcustom drgnx-tty-popups-auto-completions t
  "Non-nil: on Emacs 30.2 in a terminal window, completion as you type (corfu with `corfu-auto') shows its
candidates in `*Completions*' in the popup lane.  Nil: not there (corfu-auto stays as it is in graphical frames)."
  :type 'boolean :group 'drgnx)

;;;; Borders: the box slots of the standard display table

(defconst drgnx-tty-popups-box-slots
  '(box-vertical box-horizontal box-down-right box-down-left box-up-right box-up-left)
  "The single-line border slots of a display table, which tty child frames and menu separators draw with.")

(defconst drgnx-tty-popups--box-unicode [#x2502 #x2500 #x250c #x2510 #x2514 #x2518]
  "Box drawing: │ ─ ┌ ┐ └ ┘.")

(defconst drgnx-tty-popups--box-ascii [?| ?- ?+ ?+ ?+ ?+] "ASCII: | - + + + +.")

(defun drgnx-tty-popups--child-frames-p ()
  "Non-nil when this Emacs has child frames on terminals (31.1 and later)."
  (featurep 'tty-child-frames))

(defun drgnx-tty-popups--slots-p ()
  "Non-nil when this Emacs has the box slots in its display tables (31.1 and later)."
  (condition-case nil (progn (display-table-slot (make-display-table) (car drgnx-tty-popups-box-slots)) t)
    (error nil)))

(defun drgnx-tty-popups-ascii-p (&optional frame)
  "Non-nil when FRAME (default: the selected one) is a terminal frame whose terminal does not write UTF-8."
  (let ((frame (or frame (selected-frame))))
    (and (not (display-graphic-p frame))
         (let ((coding (terminal-coding-system (frame-terminal frame))))
           (not (and coding (string-prefix-p "utf-8" (symbol-name (coding-system-base coding)))))))))

(defun drgnx-tty-popups--borders (ascii)
  "Set the box slots of `standard-display-table': ASCII marks when ASCII is non-nil, else box drawing.
Only these slots: the window dividers and everything else keep what they have.  Nothing on an Emacs without them."
  (when (drgnx-tty-popups--slots-p)
    (unless standard-display-table (setq standard-display-table (make-display-table)))
    (let ((glyphs (if ascii drgnx-tty-popups--box-ascii drgnx-tty-popups--box-unicode)))
      (seq-do-indexed (lambda (slot i)
                        (set-display-table-slot standard-display-table slot (make-glyph-code (aref glyphs i))))
                      drgnx-tty-popups-box-slots))))

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
ones while a terminal does not write UTF-8, the completion shim's while a terminal window exists on an Emacs
without tty child frames.  A session with graphical windows only, or UTF-8 terminals on 31.1, pays nothing."
  (let* ((frames (drgnx-tty-popups--tty-frames))
         (ascii (and (seq-some #'drgnx-tty-popups--ascii-frame-p frames) t))
         (shim (and frames drgnx-tty-popups-auto-completions (not (drgnx-tty-popups--child-frames-p)))))
    (drgnx-tty-popups--hook ascii 'pre-redisplay-functions #'drgnx-tty-popups--pre-redisplay)
    (drgnx-tty-popups--hook ascii 'window-configuration-change-hook #'drgnx-tty-popups--windows-changed)
    (if ascii
        (advice-add 'drgnx-chrome--set :around #'drgnx-tty-popups--chrome-set)
      (advice-remove 'drgnx-chrome--set #'drgnx-tty-popups--chrome-set))
    (drgnx-tty-popups--hook shim 'post-command-hook #'drgnx-tty-popups--post-command)
    (unless shim
      (drgnx-timer-cancel 'tty-popups-show)
      (drgnx-tty-popups--close))))

;;;; Each terminal frame

(defun drgnx-tty-popups-setup (&optional frame)
  "Look after FRAME (default: the selected one) when it is a terminal frame: the border glyphs of child frames
\(31.1), and the ASCII table for the windows of a terminal that does not write UTF-8.  Never prompts or signals."
  (let ((frame (or frame (selected-frame))))
    (when (and (frame-live-p frame) (not (display-graphic-p frame))
               (not (drgnx-module-disabled-p 'ui/terminal-popups)))
      (condition-case err
          (progn
            (when (drgnx-tty-popups--child-frames-p) (drgnx-tty-popups--update-borders))
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
                               (progn (when (drgnx-tty-popups--child-frames-p) (drgnx-tty-popups--update-borders))
                                      (drgnx-tty-popups--sync))
                             (error nil)))))))

;;;; Completion as you type on Emacs 30.2: the popup lane

(defvar drgnx-tty-popups--ours nil
  "While the completion list showing is one this module started (and refreshes as you type): (BUFFER . FRAME) it
was started in.  Nil otherwise.")

(defun drgnx-tty-popups--close ()
  "End the completion list this module started, if there is one."
  (when drgnx-tty-popups--ours
    (setq drgnx-tty-popups--ours nil)
    (when completion-in-region-mode (completion-in-region-mode -1))))

(defun drgnx-tty-popups--lane-p ()
  "Non-nil when completion as you type goes to the popup lane: the selected frame is a terminal frame of an
Emacs without tty child frames (30.2).  A graphical frame keeps corfu's popup."
  (and (not (display-graphic-p)) (not (drgnx-tty-popups--child-frames-p))))

(defun drgnx-tty-popups--command-p ()
  "Non-nil when `this-command' is one after which corfu would complete (`corfu-auto-commands')."
  (let ((name (and (symbolp this-command) (symbol-name this-command))))
    (and name
         (seq-some (lambda (c) (if (stringp c) (string-match-p c name) (eq c this-command)))
                   (if (boundp 'corfu-auto-commands) corfu-auto-commands '("self-insert-command\\'"))))))

(defun drgnx-tty-popups--prefix-length ()
  "How many symbol characters end at point."
  (save-excursion (let ((end (point))) (skip-syntax-backward "w_") (- end (point)))))

(defun drgnx-tty-popups--wanted-p ()
  "Non-nil when typing the last command should show candidates: in the lane (30.2 terminal frame), with
`corfu-mode' and `corfu-auto' on in this buffer — the user's choice of completion as you type —, after a typing
command, with `corfu-auto-prefix' characters before point; not in a macro, a read-only buffer or the minibuffer.
A completion list somebody else started (TAB) is left alone; one of ours is refreshed."
  (and drgnx-tty-popups-auto-completions
       (bound-and-true-p corfu-mode) (bound-and-true-p corfu-auto)
       (drgnx-tty-popups--lane-p)
       (not defining-kbd-macro) (not buffer-read-only) (not (minibufferp))
       (or drgnx-tty-popups--ours (not completion-in-region-mode))
       (drgnx-tty-popups--command-p)
       (>= (drgnx-tty-popups--prefix-length) (if (boundp 'corfu-auto-prefix) corfu-auto-prefix 3))))

(defun drgnx-tty-popups--tick ()
  (list (selected-window) (current-buffer) (buffer-chars-modified-tick) (point)))

(defun drgnx-tty-popups--show (buffer tick)
  "The timer: show the candidates around point in the lane, unless typing went on (TICK changed) or a list somebody
else started is showing.  Never prompts."
  (when (and (buffer-live-p buffer) (eq buffer (window-buffer (selected-window)))
             (drgnx-tty-popups--lane-p) (not (input-pending-p)))
    (with-current-buffer buffer
      (when (and (equal tick (drgnx-tty-popups--tick))
                 (or drgnx-tty-popups--ours (not completion-in-region-mode)))
        (condition-case err
            (let ((inhibit-message t) (message-log-max nil) (inhibit-interaction t))
              (drgnx-tty-popups--close)
              (if (eq (while-no-input (completion-help-at-point) 'done) 'done)
                  (when completion-in-region-mode
                    (setq drgnx-tty-popups--ours (cons buffer (selected-frame))))
                ;; typing went on in the middle of a slow completion function: the mode it turned on goes too
                (when completion-in-region-mode (completion-in-region-mode -1))))
          (error
           (when completion-in-region-mode (completion-in-region-mode -1))
           (push (format "ui/terminal-popups: %s" (error-message-string err)) drgnx-hooks-problems)))))))

(defun drgnx-tty-popups--post-command ()
  "`post-command-hook': after typing, show the candidates once typing pauses (`corfu-auto-delay'); our list goes
when the selected buffer or frame is not the one it was started in."
  (cond ((and drgnx-tty-popups--ours (not completion-in-region-mode))
         (setq drgnx-tty-popups--ours nil))     ; C-g, or leaving the word, ended it
        ((and drgnx-tty-popups--ours
              (not (equal drgnx-tty-popups--ours (cons (current-buffer) (selected-frame)))))
         (drgnx-tty-popups--close)))
  (if (condition-case nil (drgnx-tty-popups--wanted-p) (error nil))
      (drgnx-timer-debounce 'tty-popups-show (if (boundp 'corfu-auto-delay) corfu-auto-delay 0.2)
                            #'drgnx-tty-popups--show :args (list (current-buffer) (drgnx-tty-popups--tick))
                            :owner 'ui/terminal-popups)
    (drgnx-timer-cancel 'tty-popups-show)))

;;;; Turning the module off

(defun drgnx-tty-popups--unset-borders ()
  "Empty the box slots of `standard-display-table' that still hold drgnx's glyphs (Emacs's own borders again); a
slot someone else set since stays."
  (when (and (drgnx-tty-popups--slots-p) standard-display-table)
    (seq-do-indexed (lambda (slot i)
                      (when (memql (display-table-slot standard-display-table slot)
                                   (list (make-glyph-code (aref drgnx-tty-popups--box-unicode i))
                                         (make-glyph-code (aref drgnx-tty-popups--box-ascii i))))
                        (set-display-table-slot standard-display-table slot nil)))
                    drgnx-tty-popups-box-slots)))

(defun drgnx-tty-popups--teardown ()
  "The module's teardown: what each terminal frame's setup did, which nothing records — the hooks and the advice
`drgnx-tty-popups--sync' keeps while a terminal needs them, the completion list it started, the ASCII display table
of its windows (a window's own table stays) and the box slots.  The chrome strings come back as the chrome draws."
  (drgnx-tty-popups--hook nil 'pre-redisplay-functions #'drgnx-tty-popups--pre-redisplay)
  (drgnx-tty-popups--hook nil 'window-configuration-change-hook #'drgnx-tty-popups--windows-changed)
  (drgnx-tty-popups--hook nil 'post-command-hook #'drgnx-tty-popups--post-command)
  (advice-remove 'drgnx-chrome--set #'drgnx-tty-popups--chrome-set)
  (drgnx-timer-cancel 'tty-popups-show)
  (drgnx-tty-popups--close)
  (dolist (frame (frame-list))
    (when (frame-parameter frame 'drgnx-tty-ascii)
      (set-frame-parameter frame 'drgnx-tty-ascii nil)
      (dolist (w (window-list frame t))
        (when (and drgnx-tty-popups--ascii-table (eq (window-display-table w) drgnx-tty-popups--ascii-table))
          (set-window-display-table w nil)))))
  (drgnx-tty-popups--unset-borders))

(drgnx-module-define 'ui/terminal-popups
                     :doc "Popups in terminal windows: corfu's child frame with box-drawing borders on 31.1, completion as you type in the popup lane on 30.2, ASCII marks on a terminal that does not write UTF-8."
                     :stage 'startup
                     :teardown #'drgnx-tty-popups--teardown
                     :setup (lambda ()
                              (add-hook 'delete-frame-functions #'drgnx-tty-popups--frame-deleted)
                              ;; terminal frames made before this module ran (each one's setup syncs the hooks)
                              (dolist (f (drgnx-tty-popups--tty-frames)) (drgnx-tty-popups-setup f))))

(provide 'drgnx-tty-popups)
;;; drgnx-tty-popups.el ends here
