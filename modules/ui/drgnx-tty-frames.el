;;; drgnx-tty-frames.el --- Module ui/terminal: terminal windows — what each terminal can do, EDITOR frames -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A terminal frame (`emacsclient -t', `emacs -nw') is a workbench window like a graphical one
;; (`drgnx-frames--workbench-p').  This module looks after each one, from `tty-setup-hook' and
;; `server-after-make-frame-hook':
;;
;; - `drgnx-tty-frame-caps': what the terminal can do — which terminal it is (from the client's own
;;   environment, never the daemon's, and its answer to XTVERSION), how its keys arrive (kkp, modifyOtherKeys
;;   or legacy), OSC 52 copy, colours, the mouse.  The terminal is asked once, for at most
;;   `drgnx-tty-frames-query-timeout' seconds, and never again for another client of the same terminal: only
;;   that identity is kept (`drgnx-tty-frames--cache'); the rest is read from the frame on every call.  The last
;;   result is in the terminal parameter `drgnx-tty-caps'.
;; - The mouse: `xterm-mouse-mode' (SGR reports) on while `drgnx-tty-mouse' is t, started from a terminal frame's
;;   setup, never for a graphical frame; Toggle Mouse in Terminal Windows.  The terminal's own selection is then
;;   Shift+drag.
;; - `drgnx-tty-frames-write-report': terminal-report.eld in the state dir — each terminal's capabilities and
;;   the active profile's keys it cannot send — for the doctor and the key sheet; written whole, then renamed
;;   into place.  `drgnx-tty-frames-refresh-report' writes it again (ui/terminal-keys, once kkp is on).
;; - EDITOR frames: `emacsclient -t FILE' (git's editor) shows the editor only and is never the main window;
;;   Close Tab (its key or the tab's ×) or C-x # ends the edit and the client returns, as `code --wait' does —
;;   asking to save a changed file first.  Moving the tab elsewhere does not end it.
;;
;; Nothing here prompts or signals: it runs in the daemon's hooks; errors go to `drgnx-hooks-problems'.
;; See docs/guide/terminal.md.

;;; Code:
(require 'seq)
(require 'drgnx-hooks)
(require 'drgnx-modules)
(require 'drgnx-paths)
(require 'drgnx-registry)
(require 'drgnx-tty)
(require 'drgnx-wb)
(declare-function drgnx-wb-area-hide "drgnx-area")
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function server-done "server")
(declare-function drgnx-frames-mark-main "drgnx-frames")
(declare-function xterm--query "term/xterm")
(declare-function xterm--read-event-for-query "term/xterm")
(defvar xterm-query-timeout)
(defvar server-buffer-clients)
(defvar drgnx-keys-last)
(defvar xterm-mouse-mode)
(declare-function xterm-mouse-mode "xt-mouse")
(declare-function turn-on-xterm-mouse-tracking-on-terminal "xt-mouse")
(declare-function turn-off-xterm-mouse-tracking-on-terminal "xt-mouse")

(defvar drgnx-tty-frames-query-timeout 0.2
  "Seconds to wait for a terminal's answer to XTVERSION (a late answer is still taken off the input).")

(defvar drgnx-tty-frames--cache (make-hash-table :test #'equal)
  "Identities (:id :outer :version) by kind of terminal (`drgnx-tty-frames--cache-key'): a terminal is asked
once, not once per client.  What can differ between two clients of one kind (keys, colours) is not kept here.")

;;;; What a terminal can do

(defun drgnx-tty-frames--cache-key (env)
  "The cache key of a terminal with ENV: its id, the terminal around it and its version as the environment
names them, and TERM; nil when the environment does not name the terminal (two of those cannot be told apart
without asking)."
  (let ((id (drgnx-tty-identify env)))
    (unless (eq (plist-get id :id) 'unknown)
      (list (plist-get id :id) (plist-get id :outer) (plist-get id :version) (cdr (assoc "TERM" env))))))

(defun drgnx-tty-frames--xtversion-handler ()
  "Read the rest of an XTVERSION answer (`ESC P > | TEXT ESC \\') into the terminal parameter
`drgnx-tty-xtversion'."
  (let ((text "") chr)
    (while (and (setq chr (xterm--read-event-for-query)) (not (eq chr ?\e)))
      (setq text (concat text (string chr))))
    (when (eq chr ?\e) (xterm--read-event-for-query))   ; the final backslash
    (set-terminal-parameter nil 'drgnx-tty-xtversion (concat "\eP>|" text "\e\\"))))

(defun drgnx-tty-frames--ask (frame)
  "FRAME's terminal's answer to XTVERSION, or nil: asked once, waiting `drgnx-tty-frames-query-timeout'
seconds at most; a later answer is taken off the input by Emacs's xterm.el.  Not on the Linux console."
  (unless (member (tty-type (frame-terminal frame)) '("linux" "dumb"))
    (require 'term/xterm)
    (with-selected-frame frame
      (let ((xterm-query-timeout drgnx-tty-frames-query-timeout))
        (xterm--query "\e[>0q" '(("\eP>|" . drgnx-tty-frames--xtversion-handler))))
      (terminal-parameter nil 'drgnx-tty-xtversion))))

(defun drgnx-tty-frames--keys (term)
  "How TERM's keys arrive: `kkp' when the ui/terminal-keys module turned it on (terminal parameter
`drgnx-tty-kkp'), `mok' when Emacs's xterm.el turned modifyOtherKeys on, else `legacy'."
  (cond ((terminal-parameter term 'drgnx-tty-kkp) 'kkp)
        ((member "\e[>4;1m" (terminal-parameter term 'tty-mode-set-strings)) 'mok)
        (t 'legacy)))

(defun drgnx-tty-frames--identity (frame)
  "FRAME's terminal's identity (:id :outer :version): asked once per terminal, never for a terminal of a kind
already asked (the cache); an answer that came after the wait (xterm.el's handler stored it) is read now."
  (let* ((term (frame-terminal frame))
         (answer (terminal-parameter term 'drgnx-tty-xtversion))
         (stored (terminal-parameter term 'drgnx-tty-identity)))
    (if (and stored (equal (car stored) answer))
        (cdr stored)
      (let* ((env (drgnx-tty-env frame))
             (key (drgnx-tty-frames--cache-key env))
             (cached (and (not stored) key (gethash key drgnx-tty-frames--cache)))
             (id (cond (cached)
                       (stored (drgnx-tty-identify env answer))   ; the late answer
                       (t (drgnx-tty-identify env (setq answer (drgnx-tty-frames--ask frame)))))))
        (when (and key (not cached)) (puthash key id drgnx-tty-frames--cache))
        (when (terminal-live-p term)          ; the terminal can go while it is asked
          (set-terminal-parameter term 'drgnx-tty-identity (cons answer id)))
        id))))

(defun drgnx-tty-frame-caps (&optional frame)
  "What FRAME's terminal can do: (:id :outer :version :keys kkp|mok|legacy :osc52 BOOL :colors N :mouse BOOL).
The identity is asked once per terminal (`drgnx-tty-frames--identity'); keys, OSC 52, colours and the mouse are
read from FRAME on every call, so kkp turned on later shows.  The result is also the terminal parameter
`drgnx-tty-caps'.  Nil when the terminal went away meanwhile (killed while it was asked)."
  (let* ((frame (or frame (selected-frame)))
         (term (frame-terminal frame))
         (id (drgnx-tty-frames--identity frame)))
    (when (and (frame-live-p frame) (terminal-live-p term))
      (let* ((row (drgnx-tty-terminal (plist-get id :id)))
             (caps (list :id (plist-get id :id) :outer (plist-get id :outer) :version (plist-get id :version)
                         :keys (drgnx-tty-frames--keys term)
                         :osc52 (and (or (terminal-parameter term 'xterm--set-selection) (plist-get row :osc52)) t)
                         :colors (display-color-cells frame)
                         :mouse (if row (and (plist-get row :mouse) t) t))))
        (set-terminal-parameter term 'drgnx-tty-caps caps)
        caps))))

;;;; The report

(defun drgnx-tty-frames--report-file () (expand-file-name "terminal-report.eld" (drgnx-state-dir)))

(defun drgnx-tty-frames-write-report (frame)
  "Add FRAME's terminal to terminal-report.eld in the state dir: (:terminals ((TTY . (:caps CAPS :unsendable
KEYS :seen TIME)) …)), newest first, one entry per terminal device (two clients never replace each other's);
:unsendable the active key profile's keys this terminal cannot send.  Nothing when the terminal is gone."
  (when-let* ((caps (drgnx-tty-frame-caps frame)))
    (let* ((file (drgnx-tty-frames--report-file))
           (key (terminal-name (frame-terminal frame)))
           (keys (seq-uniq (delq nil (mapcar (lambda (b) (plist-get b :key))
                                             (plist-get (bound-and-true-p drgnx-keys-last) :bindings)))))
           (read (plist-get (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))
                            :terminals))
           (old (and (proper-list-p read) (seq-every-p #'consp read) read))   ; a broken report heals
           (entry (list :caps caps :unsendable (drgnx-tty-unsendable keys (plist-get caps :keys))
                        :seen (format-time-string "%FT%T%z"))))
      (make-directory (file-name-directory file) t)
      ;; written whole under a new name, then renamed: no lock on the report (whose owner would be asked about,
      ;; a prompt in a daemon hook), and a reader sees the old report or the new one, never half of one
      (let* ((create-lockfiles nil)
             (tmp (make-temp-file (expand-file-name ".terminal-report-" (file-name-directory file)))))
        (condition-case err
            (progn
              (with-temp-file tmp
                (let ((print-length nil) (print-level nil))
                  (prin1 (list :terminals (cons (cons key entry) (assoc-delete-all key (copy-sequence old))))
                         (current-buffer))
                  (insert "\n")))
              (rename-file tmp file t))
          (error (ignore-errors (delete-file tmp))
                 (signal (car err) (cdr err))))))))

(defun drgnx-tty-frames-refresh-report (frame)
  "Write FRAME's terminal's entry in terminal-report.eld again, from what it can do now (ui/terminal-keys calls
it once kkp is on).  Never signals: errors go to `drgnx-hooks-problems'."
  (condition-case err
      (drgnx-tty-frames-write-report frame)
    (error (push (format "ui/terminal: %s" (error-message-string err)) drgnx-hooks-problems))))

;;;; The mouse

(defcustom drgnx-tty-mouse t
  "Non-nil: the mouse works in terminal windows (clicks, wheel, dragging dividers, the Explorer, tabs, menus).
The terminal's own selection and paste are then Shift+drag (Option+drag in iTerm2).  Nil: the terminal keeps the
mouse.  Toggle Mouse in Terminal Windows changes it."
  :type 'boolean :group 'drgnx :initialize #'custom-initialize-default
  :set (lambda (sym val) (set-default sym val) (drgnx-tty-frames-mouse-apply)))

(defun drgnx-tty-frames--tty-frames ()
  "The live terminal frames of terminals Emacs set up (not the daemon's initial terminal)."
  (seq-filter (lambda (f) (and (frame-live-p f) (not (display-graphic-p f))
                               (not (equal (terminal-name (frame-terminal f)) "initial_terminal"))))
              (frame-list)))

(defun drgnx-tty-frames-mouse-apply ()
  "Make the terminals follow `drgnx-tty-mouse': mouse reports on in the terminals that can send them while it
is t, off in all of them when it is nil (Emacs 31 turns the mode on by itself).  A session without a terminal
frame is left alone: a graphical frame never gets `xterm-mouse-mode'.  Never asks a terminal anything."
  (when-let* ((frames (drgnx-tty-frames--tty-frames)))
    (let ((wanted (and drgnx-tty-mouse
                       (seq-filter (lambda (f) (let ((caps (terminal-parameter (frame-terminal f) 'drgnx-tty-caps)))
                                                 (or (null caps) (plist-get caps :mouse))))
                                   frames))))
      (require 'xt-mouse)
      (if wanted
          (unless xterm-mouse-mode (xterm-mouse-mode 1))
        (when xterm-mouse-mode (xterm-mouse-mode -1)))
      (dolist (f frames)
        (if (memq f wanted)
            (turn-on-xterm-mouse-tracking-on-terminal (frame-terminal f))
          (turn-off-xterm-mouse-tracking-on-terminal (frame-terminal f)))))))

(defun drgnx-tty-frames-toggle-mouse ()
  "Turn the mouse in terminal windows on or off; run interactively, the choice is saved."
  (interactive)
  (let ((val (not drgnx-tty-mouse)))
    (if (called-interactively-p 'any)
        (customize-save-variable 'drgnx-tty-mouse val)
      (customize-set-variable 'drgnx-tty-mouse val))
    (message "Mouse in terminal windows: %s" (if val "on" "off"))))

;;;; EDITOR frames

(defun drgnx-tty-frames--visit ()
  "`server-visit-hook': a new terminal client that asked for files (`emacsclient -t FILE') is an editor
frame, kept for those files: never the main window (role `editor'; the main role moves on).  A frame that
already showed (one reused by a later `emacsclient FILE') stays as it is."
  (let ((frame (selected-frame)))
    (when (and (not (display-graphic-p frame)) (processp (frame-parameter frame 'client))
               (not (frame-parameter frame 'drgnx-tty-shown)))
      (set-frame-parameter frame 'drgnx-tty-editor-only t)
      (set-frame-parameter frame 'drgnx-frame-role 'editor)
      (when (fboundp 'drgnx-frames-mark-main) (drgnx-frames-mark-main)))))

(defun drgnx-tty-frames--editor-only (frame)
  "FRAME shows the editor only: no sidebar, panel or right dock."
  (with-selected-frame frame
    (drgnx-wb-hide-sidebar)
    (when (fboundp 'drgnx-wb-area-hide)
      (drgnx-wb-area-hide 'panel)
      (drgnx-wb-area-hide 'right))))

(defun drgnx-tty-frames--tab-closed (window buffer)
  "After the user closed BUFFER's tab in WINDOW: in an editor frame, closing the tab of a file its client waits
for ends the edit (`server-done': a changed file is offered to save first, as C-x # does); the client returns
once it has no file left."
  (when (and (window-live-p window) (buffer-live-p buffer)
             (frame-parameter (window-frame window) 'drgnx-tty-editor-only)
             (memq (frame-parameter (window-frame window) 'client)
                   (buffer-local-value 'server-buffer-clients buffer)))
    (with-current-buffer buffer (server-done))))

;; Close Tab and the tab's × are what ends an edit, not every way a tab leaves a group (a move uses the same
;; primitive, `drgnx-chrome--close').  Task 15 replaces these two advices with a hook the chrome runs on a close.
(defun drgnx-tty-frames--close-tab (close &rest args)
  "Around Close Tab: the shown tab of the selected window, then `drgnx-tty-frames--tab-closed'."
  (let ((window (selected-window)) (buffer (window-buffer)))
    (prog1 (apply close args) (drgnx-tty-frames--tab-closed window buffer))))

(defun drgnx-tty-frames--close-clicked (close event &rest args)
  "Around a click on a tab's ×: that tab, then `drgnx-tty-frames--tab-closed'."
  (let* ((posn (event-start event)) (s (posn-string posn))
         (buffer (and s (get-text-property (cdr s) 'drgnx-buffer (car s)))) (window (posn-window posn)))
    (prog1 (apply close event args)
      (when (and (windowp window) (bufferp buffer)) (drgnx-tty-frames--tab-closed window buffer)))))

;;;; Each terminal frame

(defun drgnx-tty-frames--guard (what fn &rest args)
  "Call FN with ARGS; an error goes to `drgnx-hooks-problems' (WHAT names the step)."
  (condition-case err
      (apply fn args)
    (error (push (format "ui/terminal: %s: %s" what (error-message-string err)) drgnx-hooks-problems) nil)))

(defun drgnx-tty-frames-setup (&optional frame)
  "Look after FRAME (default: the selected frame) when it is a terminal frame: its capabilities and the
report, asked once per terminal; the mouse.  Never prompts or signals: each step on its own, a failing one
does not stop the next."
  (let ((frame (or frame (selected-frame))))
    (when (and (frame-live-p frame) (not (display-graphic-p frame))
               (not (equal (terminal-name (frame-terminal frame)) "initial_terminal")))
      (unless (terminal-parameter (frame-terminal frame) 'drgnx-tty-identity)
        (drgnx-tty-frames--guard "capabilities" #'drgnx-tty-frames-write-report frame))
      (drgnx-tty-frames--guard "mouse" #'drgnx-tty-frames-mouse-apply))))

(defun drgnx-tty-frames--after-make-frame ()
  "`server-after-make-frame-hook' (the client's frame is selected): set it up; an editor frame shows the
editor only; give its windows their tabs now — a client showing the buffer the daemon's editor already showed
(*scratch*) is no change the workbench's bus would see, and its tab line would stay empty.  The frame has shown
now.  (The server runs this hook outside a minibuffer and isearch: `server-goto-toplevel' leaves both first.)"
  (let ((frame (selected-frame)))
    (drgnx-tty-frames-setup frame)
    (unless (display-graphic-p frame)
      (set-frame-parameter frame 'drgnx-tty-shown t)
      (when (frame-parameter frame 'drgnx-tty-editor-only)
        (drgnx-tty-frames--guard "editor frame" #'drgnx-tty-frames--editor-only frame))
      (when (fboundp 'drgnx-chrome-apply)
        (drgnx-tty-frames--guard "tabs" #'drgnx-chrome-apply frame t)))))

(drgnx-module-define 'ui/terminal
                     :doc "Terminal windows: what each terminal can do, asked once; the mouse; editor-only EDITOR frames."
                     :stage 'startup
                     :setup (lambda ()
                              (drgnx-command-define 'terminal-toggle-mouse :category "Terminal"
                                                    :title "Toggle Mouse in Terminal Windows" :scope 'window
                                                    :command #'drgnx-tty-frames-toggle-mouse
                                                    :doc "Mouse clicks, wheel and drags in terminal windows on or off")
                              (add-hook 'tty-setup-hook #'drgnx-tty-frames-setup)
                              (add-hook 'server-visit-hook #'drgnx-tty-frames--visit)
                              (add-hook 'server-after-make-frame-hook #'drgnx-tty-frames--after-make-frame)
                              (advice-add 'drgnx-chrome-close-tab :around #'drgnx-tty-frames--close-tab)
                              (advice-add 'drgnx-chrome--close-clicked :around #'drgnx-tty-frames--close-clicked)
                              ;; a terminal Emacs set up before this module ran (`emacs -nw' sets its own up after init)
                              (when (terminal-parameter nil 'terminal-initted)
                                (drgnx-tty-frames-setup))))

(provide 'drgnx-tty-frames)
;;; drgnx-tty-frames.el ends here
