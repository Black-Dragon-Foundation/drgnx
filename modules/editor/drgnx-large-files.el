;;; drgnx-large-files.el --- Module editor/large-files: big files open in chunks, lean or raw, and never freeze -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Above a size (large-files.eld's `:ask-above', 50 MiB), a file opens in chunks, lean (whole, without the
;; expensive modes) or raw.  This file holds the config, the decision and the answers remembered for the session:
;; - `drgnx-large-files-thresholds' gives a file's thresholds in bytes: the user's large-files.eld, lowered by the
;;   project's .drgnx/large-files.eld.  A project file is untrusted: it may only lower `:ask-above' and
;;   `:chunks-above', never set the chunk size, and is never read when the user's `:ask-above' is nil (off).
;; - `drgnx-large-files--decide' is the decision, a pure function of the size, how the open came (a command, an
;;   automatic path, a caller that needs the whole text), the remembered answer and the thresholds.
;; - The answers are remembered per file (its truename, or a remote name as it is) in a capped cache.
;; - `large-file-warning-threshold' follows `:ask-above', so `insert-file' still gets Emacs's own question.
;; - The one door, an around-advice on `find-file-noselect': a new visit of a file above `:ask-above' opens in
;;   chunks, lean or raw.  Only a command the user gave asks (`drgnx-large-files--ask'); every other open takes the
;;   remembered answer, else chunks (raw without the chunks module), and never asks.  The server's requests are
;;   automatic (`drgnx open --wait' needs the whole file).
;; - Lean is `drgnx-large-file-mode': the gate (no parser, no eglot while the major mode runs) and the sweep (the
;;   modes of `so-long-minor-modes' off, no undo, no auto-save).  A revert across `:ask-above' turns it on or off
;;   without a question.  so-long runs everywhere.
;; - A large file's buffer says its size and mode in the header line, with a button for each other mode, and in the
;;   status bar's `large-file' segment.  Large File: Open in Chunks, Open Whole (lean) and Open Raw switch it (never
;;   with unsaved changes) and remember the mode.
;; See docs/guide/large-files.md, docs/guide/modules.md, docs/develop/core.md ("Large files") and
;; docs/reference/config.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-ui-kit)                 ; `drgnx-ui-ascii-frame-p', for the status bar segment
(require 'drgnx-registry)
(require 'drgnx-config)
(require 'drgnx-memo)
(require 'drgnx-guard)
(require 'drgnx-large-file)
(require 'so-long)

(defvar treesit-max-buffer-size)
(defvar eglot--managed-mode)
(declare-function eglot--managed-mode "eglot")
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-parser-delete "treesit.c")
(defvar warning-suppress-log-types)
(defvar warning-suppress-types)
(declare-function server-execute "server")   ; advised before server.el loads; it applies once it does

(defconst drgnx-large-files--mib 1048576 "Bytes in a MiB: the config's sizes are numbers of MiB.")

(drgnx-cache-define 'drgnx-large-files--answers :key 'string :cap 256
                    :doc "File (truename, or a remote name) → the mode chosen for it: lean, raw or chunks.  For the
session only; capped at 256 files, the least recently used evicted.")

;;;; The config

(defun drgnx-large-files--mib-p (v)
  "Non-nil when V is a size in MiB: a number above 0 (fractions allowed), not infinite."
  (and (numberp v) (< 0 v 1.0e+INF)))

(defun drgnx-large-files--bytes (mib)
  "MIB MiB in bytes, rounded."
  (round (* mib drgnx-large-files--mib)))

(defun drgnx-large-files--define-config ()
  "Define large-files.eld and the project's .drgnx/large-files.eld.  The setup calls this; teardown undefines them."
  (drgnx-config-define
   'large-files
   :file "large-files.eld" :shape 'plist :version 1 :reload 'mtime :last-good t
   :schema '(plist (:ask-above (or null (pred drgnx-large-files--mib-p "a size in MiB above 0"))
                               "Above this size (MiB) a file opens in chunks, lean or raw (a command asks once); nil: never")
                   (:chunks-above (pred drgnx-large-files--mib-p "a size in MiB above 0")
                                  "Above this size (MiB) the question's default is chunks, else lean")
                   (:chunk-size (pred drgnx-large-files--mib-p "a size in MiB above 0")
                                "How much of the file (MiB) a chunk holds"))
   :default '(:version 1 :ask-above 50 :chunks-above 500 :chunk-size 1)
   :doc "When a file is large: the size that asks (or opens in chunks, lean or raw), the size above which chunks is the default, and a chunk's size.")
  (drgnx-config-define
   'large-files-project
   :dir 'project :file "large-files.eld" :shape 'plist :version 1 :reload 'mtime
   :schema '(plist (:ask-above (or null (pred drgnx-large-files--mib-p "a size in MiB above 0"))
                               "Lowers your :ask-above for the project (a higher value or nil is ignored)")
                   (:chunks-above (pred drgnx-large-files--mib-p "a size in MiB above 0")
                                  "Lowers your :chunks-above for the project (a higher value is ignored)"))
   :default nil
   :doc "A project's lower large-file sizes: it can only lower yours, never raise them or set the chunk size."))

(defun drgnx-large-files--project-root (file)
  "The folder holding the .drgnx/large-files.eld that applies to FILE, or nil.  Never looked for on a remote name."
  (let ((file (expand-file-name file)))
    (unless (file-remote-p file)
      (let ((default-directory "/"))
        (locate-dominating-file (file-name-directory file) ".drgnx/large-files.eld")))))

(defun drgnx-large-files-thresholds (file)
  "FILE's thresholds in bytes: (:ask-above BYTES-or-nil :chunks-above BYTES :chunk-size BYTES).
The user's large-files.eld, each size lowered by the project's .drgnx/large-files.eld when the project's is a
number below it.  With the user's `:ask-above' nil the project file is not read.  One `drgnx-config-get' of each
file (each is one stat)."
  (let* ((user (drgnx-config-get 'large-files))
         (default (plist-get (drgnx-config-definition 'large-files) :default))
         ;; a key left out of the file: the default's
         (get (lambda (key) (plist-get (if (plist-member user key) user default) key)))
         (ask (funcall get :ask-above))
         (chunks (funcall get :chunks-above)))
    (when-let* ((root (and ask (drgnx-large-files--project-root file))))
      (let* ((project (drgnx-config-get 'large-files-project nil root))
             (p-ask (plist-get project :ask-above))
             (p-chunks (plist-get project :chunks-above)))
        (when (and (numberp p-ask) (< p-ask ask)) (setq ask p-ask))
        (when (and (numberp p-chunks) (< p-chunks chunks)) (setq chunks p-chunks))))
    (list :ask-above (and ask (drgnx-large-files--bytes ask))
          :chunks-above (drgnx-large-files--bytes chunks)
          :chunk-size (drgnx-large-files--bytes (funcall get :chunk-size)))))

(defun drgnx-large-files--sync-threshold ()
  "Set `large-file-warning-threshold' to the user's `:ask-above' in bytes (nil when it is nil), when it differs."
  (let* ((ask (drgnx-config-get 'large-files :ask-above))
         (bytes (and ask (drgnx-large-files--bytes ask))))
    (unless (equal large-file-warning-threshold bytes)
      (drgnx-module-set 'large-file-warning-threshold bytes))))

;;;; The decision

(defun drgnx-large-files--decide (size how remembered thresholds chunks-ok)
  "How to open a file of SIZE bytes: `pass' (as Emacs does), `lean', `raw', `chunks' or (ask . DEFAULT).
HOW: `command' (the user's command: it may ask), `auto' (never asks) or `whole' (the caller needs the whole text).
REMEMBERED: the mode chosen for the file before, or nil.  THRESHOLDS: `drgnx-large-files-thresholds'.  CHUNKS-OK:
chunks can be built; without them chunks becomes raw.  Pure: the first rule that matches wins."
  (let ((ask (plist-get thresholds :ask-above))
        (chunks (if chunks-ok 'chunks 'raw)))
    (cond ((or (null ask) (<= size ask)) 'pass)
          ((eq how 'whole) 'lean)
          ((eq remembered 'chunks) chunks)
          ((memq remembered '(lean raw)) remembered)
          ((eq how 'command) (cons 'ask (if (<= size (plist-get thresholds :chunks-above)) 'lean chunks)))
          (t chunks))))

(defun drgnx-large-files--how ()
  "How the open running now came: `whole' or `auto' when `drgnx-large-file-open' says so in the current buffer;
else `auto' in automatic code (a timer, `drgnx-automatic', daemon startup), under `inhibit-interaction' or
`non-essential' (a preview from `post-command-hook', consult's file preview) or outside a command; else `command'."
  (cond (drgnx-large-file-open (if (eq drgnx-large-file-open 'whole) 'whole 'auto))
        ((or (drgnx-guard-automatic-p) inhibit-interaction non-essential (null this-command)) 'auto)
        (t 'command)))

(defun drgnx-large-files--never-query (value)
  "VALUE of `enable-local-variables' for code that must never ask: every value that may query (t and the others
that are not nil, :all or :safe) becomes :safe, so only safe local variables are set, without a question."
  (if (memq value '(nil :all :safe)) value :safe))

;;;; The remembered answers

(defun drgnx-large-files--key (file)
  "FILE's key among the answers: a remote name as it is (`file-remote-p' never connects), else its truename."
  (if (file-remote-p file) file (file-truename file)))

(defun drgnx-large-files-remember (file mode)
  "Remember MODE (`lean', `raw' or `chunks') for FILE, for the session."
  (drgnx-cache-put 'drgnx-large-files--answers (drgnx-large-files--key file) mode))

(defun drgnx-large-files-remembered (file)
  "The mode remembered for FILE this session, or nil."
  (drgnx-cache-get 'drgnx-large-files--answers (drgnx-large-files--key file)))

(defun drgnx-large-files--size-text (size)
  "SIZE bytes as a person reads it, for example \"412 MB\"."
  (file-size-human-readable size nil " " "B"))

;;;; The door: one advice on `find-file-noselect'

(defvar drgnx-large-files-chunk-open-function nil
  "A function of (FILE SIZE THRESHOLDS) that returns a buffer holding FILE in chunks; nil when chunks cannot be
built, and chunks then becomes raw.  The module editor/large-files-chunks sets it (`drgnx-module-set').")

(defvar drgnx-large-files--door nil
  "The thresholds of the file the door lets through to Emacs (dynamically bound around the visit): the sweep in
`find-file-hook' reuses them rather than looking for the project file again.")

(defvar drgnx-large-files--door-size nil
  "(FILE . SIZE): the size on disk the door read for the file it is opening (dynamically bound around the visit),
so that the header shows it without a second stat.")

(defun drgnx-large-files--chunks-ok ()
  "Non-nil when chunk buffers can be built."
  (and drgnx-large-files-chunk-open-function t))

(defun drgnx-large-files--size (file)
  "FILE's size on disk, following a link; nil when it does not exist or is a directory."
  (let ((attrs (file-attributes file)))
    (when (stringp (file-attribute-type attrs))
      (setq attrs (file-attributes (file-truename file))))
    (and attrs (not (eq (file-attribute-type attrs) t)) (file-attribute-size attrs))))

(defun drgnx-large-files--ask (file size default chunks-ok)
  "Ask how to open FILE of SIZE bytes: `lean', `raw' or `chunks' (only when CHUNKS-OK); quit is a `user-error'.
DEFAULT, the mode listed first.  In the minibuffer, in a GUI too."
  (let* ((choices (delq nil (list (and chunks-ok '(?c "chunks")) '(?n "normal (lean)") '(?r "raw") '(?q "quit"))))
         (first (assq (pcase default ('chunks ?c) ('raw ?r) (_ ?n)) choices))
         (answer (let ((use-dialog-box nil))
                   (car (read-multiple-choice
                         (format "%s is %s: " (file-name-nondirectory file) (drgnx-large-files--size-text size))
                         (cons first (delq first choices)))))))
    (pcase answer
      (?c 'chunks)
      (?n 'lean)
      (?r 'raw)
      (_ (user-error "Aborted")))))

(defun drgnx-large-files--without-parser (size fn)
  "Call FN with tree-sitter's size limit below SIZE bytes: a `*-ts-mode' it runs starts no parser, and does not
warn about it."
  (require 'treesit nil t)
  (require 'warnings)
  (let ((treesit-max-buffer-size (max 0 (1- size)))
        (warning-suppress-types (cons '(treesit) warning-suppress-types))
        (warning-suppress-log-types (cons '(treesit) warning-suppress-log-types)))
    (funcall fn)))

(defun drgnx-large-files--open-as (mode orig file nowarn size thresholds)
  "Visit FILE of SIZE bytes in MODE (`lean', `raw' or `chunks') through ORIG, the original `find-file-noselect'
\(NOWARN passed on); return the buffer.  THRESHOLDS: FILE's, for the chunks."
  (pcase mode
    ('lean
     (let ((buf (let ((large-file-warning-threshold nil)
                      ;; the major mode and its hooks run before the flag is set: they see "large" all the same
                      (drgnx-large-file--opening 'lean))
                  (drgnx-large-files--without-parser size (lambda () (funcall orig file nowarn nil nil))))))
       (with-current-buffer buf
         (unless (eq drgnx-large-file 'lean) (drgnx-large-file-mode 1)))
       buf))
    ('raw
     (let ((buf (let ((large-file-warning-threshold nil)) (funcall orig file nowarn t nil))))
       (with-current-buffer buf
         (setq drgnx-large-file 'raw)
         (drgnx-large-file-mode 1))      ; a raw visit runs no `find-file-hook': the sweep runs here
       buf))
    ('chunks
     (let ((buf (funcall drgnx-large-files-chunk-open-function file size thresholds)))
       (with-current-buffer buf (drgnx-large-files--header-refresh))
       buf))))

(defun drgnx-large-files--visit (orig filename nowarn rawfile wildcards)
  "The door: `find-file-noselect' (ORIG) of FILENAME, NOWARN, RAWFILE, WILDCARDS.
A new visit of a readable file above `:ask-above' opens in the mode `drgnx-large-files--decide' gives: a command
asks once, everything else never asks.  Anything else goes to ORIG unchanged."
  (let* ((file (expand-file-name filename))
         (size (and (not rawfile)
                    (not (and wildcards (string-match-p "[[*?]" filename)))
                    (drgnx-large-files--size file)))
         (th (and size (drgnx-large-files-thresholds file)))
         (ask (plist-get th :ask-above))
         (big (and ask (> size ask)))
         (visiting (and big (find-buffer-visiting file)))
         (mode (and big (not visiting)
                    (file-readable-p file)
                    (drgnx-large-files--decide size (drgnx-large-files--how) (drgnx-large-files-remembered file)
                                               th (drgnx-large-files--chunks-ok))))
         (drgnx-large-files--door-size (and size (cons file size))))
    (pcase mode
      ((or 'nil 'pass)
       ;; a raw buffer is reused as it is, whatever the size now (`:ask-above' may have been raised): without RAWFILE
       ;; Emacs would ask to revisit it normally
       (let ((drgnx-large-files--door th)
             (rawfile (or rawfile
                          (when-let* ((b (or visiting (get-file-buffer file))))
                            (eq (buffer-local-value 'drgnx-large-file b) 'raw)))))
         (funcall orig filename nowarn rawfile wildcards)))
      (`(ask . ,default)
       (let ((answer (drgnx-large-files--ask file size default (drgnx-large-files--chunks-ok))))
         (drgnx-large-files-remember file answer)
         (drgnx-large-files--open-as answer orig file nowarn size th)))
      (_ (drgnx-large-files--open-as mode orig file nowarn size th)))))

(defun drgnx-large-files--serve-unasked (files fn)
  "Call FN, the server's request for FILES ((NAME . POSITION) …), so that it asks nothing about a lean or raw buffer
already holding one of them whose file changed on disk (a growing log).  Emacs's `server-visit-files' reverts such
a buffer with (revert-buffer t nil), which asks: an unmodified one is reverted without the question (its exact name
in `revert-without-query'); a modified one is never reverted silently, so it is left as it is (its record of the
file's time is current while FN runs, then stale again) and the echo area says so."
  (let ((quiet nil) (kept nil))
    (dolist (f files)
      (when-let* ((b (get-file-buffer (car f))))
        (when (and (memq (buffer-local-value 'drgnx-large-file b) '(lean raw))
                   (not (verify-visited-file-modtime b))
                   (file-exists-p (car f)))
          (with-current-buffer b
            (if (not (buffer-modified-p))
                (push (concat "\\`" (regexp-quote buffer-file-name) "\\'") quiet)
              (push (cons b (visited-file-modtime)) kept)
              (set-visited-file-modtime))))))
    (let ((revert-without-query (append quiet revert-without-query)))
      (unwind-protect (funcall fn)
        (pcase-dolist (`(,b . ,time) kept)
          (when (buffer-live-p b)
            (with-current-buffer b (set-visited-file-modtime time))
            (message "%s changed on disk; its buffer has unsaved changes and is left as it is"
                     (file-name-nondirectory (buffer-file-name b)))))))))

;;;; Switching and the header line

(defun drgnx-large-files--offers-p (mode)
  "Non-nil when the current buffer holds a large file that can switch to MODE (`chunks', `lean' or `raw'): it is in
another mode, and chunks can be built when MODE is `chunks'."
  (and drgnx-large-file buffer-file-name (not (eq drgnx-large-file mode))
       (or (not (eq mode 'chunks)) (drgnx-large-files--chunks-ok))))

(defun drgnx-large-files--offer-chunks-p () "The command Open in Chunks applies here." (drgnx-large-files--offers-p 'chunks))
(defun drgnx-large-files--offer-whole-p () "The command Open Whole applies here." (drgnx-large-files--offers-p 'lean))
(defun drgnx-large-files--offer-raw-p () "The command Open Raw applies here." (drgnx-large-files--offers-p 'raw))

(defun drgnx-large-files--switch (mode)
  "Reopen the current buffer's large file in MODE (`chunks', `lean' or `raw'), remembered for the file, and show it
in the windows that showed the buffer.  A modified buffer is refused: switching reopens the file."
  (let ((file buffer-file-name) (buf (current-buffer)))
    (unless (and file drgnx-large-file) (user-error "This buffer does not hold a large file"))
    (when (buffer-modified-p)
      (user-error "Save or revert %s first: switching reopens the file" (file-name-nondirectory file)))
    (let ((windows (get-buffer-window-list buf nil t)))
      (drgnx-large-files-remember file mode)
      (kill-buffer buf)
      (when (buffer-live-p buf) (user-error "%s was not closed" (buffer-name buf)))
      ;; the remembered mode wins: no question
      (let ((new (let ((drgnx-large-file-open 'auto)) (find-file-noselect file))))
        (dolist (w windows) (when (window-live-p w) (set-window-buffer w new)))
        (set-buffer new)
        new))))

(defun drgnx-large-files-open-chunks ()
  "Reopen this large file in chunks: one chunk of the file at a time (refused while the buffer is modified)."
  (interactive)
  (drgnx-large-files--switch 'chunks))

(defun drgnx-large-files-open-whole ()
  "Reopen this large file whole, lean: without the expensive modes, undo or auto-save (refused while modified)."
  (interactive)
  (drgnx-large-files--switch 'lean))

(defun drgnx-large-files-open-raw ()
  "Reopen this large file raw: whole and literally, without decoding (refused while the buffer is modified)."
  (interactive)
  (drgnx-large-files--switch 'raw))

(defconst drgnx-large-files--modes '((chunks "in chunks" "Open in Chunks") (lean "lean" "Open Whole") (raw "raw" "Open Raw"))
  "Each mode: (MODE NAME BUTTON), as the header line says it and labels its button.")

(defvar drgnx-large-files--button-map
  (let ((m (make-sparse-keymap)))
    (define-key m [header-line mouse-1] #'drgnx-large-files--header-click)
    m)
  "The keymap of a header button's text.")

(defvar-local drgnx-large-files--header nil
  "The header line's text in a large file's buffer: its size, its mode and a button for each other mode.")
(put 'drgnx-large-files--header 'risky-local-variable t)   ; the header shows its text properties (the buttons)

(defvar-local drgnx-large-files--shown-size nil
  "The size of the large file in this buffer as the header and the status bar show it (\"412 MB\").")

(defvar drgnx-chrome-mode)
(defvar drgnx-chrome-header-tail)
(declare-function drgnx-chrome-apply "drgnx-chrome")

(defun drgnx-large-files--header-click (event)
  "Switch to the mode of the header button under the mouse EVENT, in the window it was clicked in."
  (interactive "e")
  (let* ((posn (event-start event))
         (str (posn-string posn))
         (mode (and str (get-text-property (cdr str) 'drgnx-large-files-switch (car str))))
         (w (posn-window posn)))
    (when mode
      (when (window-live-p w) (select-window w))
      (drgnx-large-files--switch mode))))

(defun drgnx-large-files--button (mode label)
  "A header button \"[LABEL]\" that switches to MODE."
  (propertize (concat "[" label "]") 'face 'button 'mouse-face 'mode-line-highlight
              'help-echo (format "mouse-1: %s" label) 'local-map drgnx-large-files--button-map
              'drgnx-large-files-switch mode))

(defun drgnx-large-files--chrome-apply ()
  "Draw the workbench's headers again when the chrome is on and the buffer is shown."
  (when (and (bound-and-true-p drgnx-chrome-mode) (fboundp 'drgnx-chrome-apply) (get-buffer-window))
    (drgnx-chrome-apply)))

(defun drgnx-large-files--header-clear ()
  "Take the large-file header out of the current buffer."
  (when (eq header-line-format 'drgnx-large-files--header) (kill-local-variable 'header-line-format))
  (when (and (boundp 'drgnx-chrome-header-tail) (eq drgnx-chrome-header-tail 'drgnx-large-files--header))
    (kill-local-variable 'drgnx-chrome-header-tail))
  (when drgnx-large-files--header
    (kill-local-variable 'drgnx-large-files--header)
    (kill-local-variable 'drgnx-large-files--shown-size)
    (drgnx-large-files--chrome-apply)))

(defun drgnx-large-files--header-refresh ()
  "Show the current buffer's large file in its header line: \"412 MB, in chunks: [Open Whole] [Open Raw]\", a
button for each other mode.  After the breadcrumb with the workbench's chrome, else as the buffer's header line.
Outside a large file's buffer it takes the header out."
  (if (not (and drgnx-large-file buffer-file-name))
      (drgnx-large-files--header-clear)
    (setq drgnx-large-files--shown-size
          (drgnx-large-files--size-text
           (or (if (equal (car drgnx-large-files--door-size) buffer-file-name)
                   (cdr drgnx-large-files--door-size)   ; opening now: the door's size
                 (drgnx-large-files--size buffer-file-name))
               (buffer-size))))
    (setq drgnx-large-files--header
          (concat " " drgnx-large-files--shown-size ", " (nth 1 (assq drgnx-large-file drgnx-large-files--modes)) ":"
                  (mapconcat (lambda (m)
                               (if (drgnx-large-files--offers-p (car m))
                                   (concat " " (drgnx-large-files--button (car m) (nth 2 m)))
                                 ""))
                             drgnx-large-files--modes "")))
    (if (bound-and-true-p drgnx-chrome-mode)
        (progn (when (eq header-line-format 'drgnx-large-files--header) (kill-local-variable 'header-line-format))
               (setq-local drgnx-chrome-header-tail 'drgnx-large-files--header))
      (setq-local header-line-format 'drgnx-large-files--header))
    (drgnx-large-files--chrome-apply)))

;;;; The status bar segment

(defvar drgnx-statusbar-right)
(defvar drgnx-statusbar--segments)
(declare-function drgnx-statusbar-define-segment "drgnx-statusbar")
(declare-function drgnx-statusbar-source-window "drgnx-statusbar")
(declare-function drgnx-large-files-chunks-position "drgnx-large-files-chunks")

(defun drgnx-large-files--segment ()
  "The status bar's `large-file': \"412 MB · chunk 3/412\", \"412 MB · lean\" or \"412 MB · raw\" (`-' for `·' on
an ASCII terminal); nothing outside a large file's buffer.  Reads the flag, the cached size and the chunk position."
  (when-let* ((mode drgnx-large-file) (size drgnx-large-files--shown-size))
    (concat size
            (if (drgnx-ui-ascii-frame-p (window-frame (drgnx-statusbar-source-window))) " - " " · ")
            (if (eq mode 'chunks)
                (let ((p (and (fboundp 'drgnx-large-files-chunks-position) (drgnx-large-files-chunks-position))))
                  (if p (format "chunk %d/%d" (car p) (cdr p)) "chunks"))
              (symbol-name mode)))))

(defun drgnx-large-files--segment-define ()
  "Define the segment `large-file' and put it before `position' in `drgnx-statusbar-right' (at the end without it)."
  (drgnx-statusbar-define-segment 'large-file :fn #'drgnx-large-files--segment
                                  :help "This large file's size and how it is open (chunks, lean or raw)")
  (unless (memq 'large-file drgnx-statusbar-right)
    (let ((tail (memq 'position drgnx-statusbar-right)))
      (drgnx-module-set 'drgnx-statusbar-right
                        (append (butlast drgnx-statusbar-right (length tail)) '(large-file) tail)))))

;;;; Lean

(define-minor-mode drgnx-large-file-mode
  "Lean: this buffer holds a large file whole, without the expensive modes (those of `so-long-minor-modes'),
a tree-sitter parser, eglot's management, undo or auto-save.  On, it sets the flag `drgnx-large-file' (a raw or
chunk buffer keeps its own); off, it clears it and gives undo and auto-save back, but turns no mode back on (a
revert does, by running the major mode again)."
  :lighter nil
  (if drgnx-large-file-mode
      (progn
        (unless (memq drgnx-large-file '(raw chunks)) (setq drgnx-large-file 'lean))
        (dolist (m so-long-minor-modes)       ; as so-long turns them off
          (when (and (boundp m) (symbol-value m) (fboundp m)) (funcall m 0)))
        ;; a buffer that turns lean on a revert kept its modes (auto-revert keeps them): the gate came too late
        (when (fboundp 'treesit-parser-list) (mapc #'treesit-parser-delete (treesit-parser-list nil nil t)))
        (when (bound-and-true-p eglot--managed-mode) (eglot--managed-mode -1))
        (buffer-disable-undo)
        (auto-save-mode -1)
        (drgnx-large-files--header-refresh))
    (setq drgnx-large-file nil)
    (buffer-enable-undo)
    (auto-save-mode (if auto-save-default 1 -1))
    (drgnx-large-files--header-clear)))

(defun drgnx-large-files--sweep-p ()
  "Non-nil when the buffer `find-file-hook' runs in should be lean: it holds a large file, or its text is above
`:ask-above' (a compressed file is asked about by its size on disk, and turns lean here)."
  (or (drgnx-large-file-p)
      (let ((ask (plist-get (or drgnx-large-files--door (drgnx-large-files-thresholds buffer-file-name))
                            :ask-above)))
        (and ask (> (buffer-size) ask)))))

(defun drgnx-large-files--after-revert ()
  "After a revert, follow the size across `:ask-above' without a question: a lean buffer at or below it turns lean
off and runs its major mode again; a buffer above it turns lean.  Raw and chunk buffers stay as they are."
  (when (and buffer-file-name (not (memq drgnx-large-file '(raw chunks))))
    (let* ((ask (plist-get (drgnx-large-files-thresholds buffer-file-name) :ask-above))
           (size (drgnx-large-files--size buffer-file-name))
           (big (and ask (or (> (buffer-size) ask) (and size (> size ask))))))
      (cond ((and (eq drgnx-large-file 'lean) (not big))
             (drgnx-large-file-mode -1)
             ;; a revert may run from a timer (auto-revert): only safe local variables, never a question
             (let ((enable-local-variables (drgnx-large-files--never-query enable-local-variables)))
               (normal-mode t)))
            ((and big (not (eq drgnx-large-file 'lean)))
             (drgnx-large-file-mode 1))))))

(defun drgnx-large-files--before-revert ()
  "Before a revert reads a lean or raw buffer's file: the buffer's record of the file's time becomes the file's.
Emacs truncates a buffer whose file shrank to a prefix of its text (a file read without decoding: raw) with a
change that asks `ask-user-about-supersession-threat' while that record is stale.
A revert, auto-revert's from a timer too, never asks: it replaces the text with the file's anyway."
  (when (and (memq drgnx-large-file '(lean raw)) buffer-file-name (file-readable-p buffer-file-name))
    (set-visited-file-modtime)))

(defun drgnx-large-files--teardown ()
  "Turn lean off in every lean or raw buffer, without running major modes again on huge buffers (it says so).
Chunk buffers stay, without the header.  The status bar's segment goes (its place in the bar is the setup's
recorded `drgnx-module-set')."
  (let ((any nil))
    (dolist (b (buffer-list))
      (pcase (buffer-local-value 'drgnx-large-file b)
        ((or 'lean 'raw) (with-current-buffer b (drgnx-large-file-mode -1)) (setq any t))
        ('chunks (with-current-buffer b (drgnx-large-files--header-clear)))))
    ;; `drgnx-statusbar-define-segment' records no undo yet (teardown Task 23): removed by hand
    (when (boundp 'drgnx-statusbar--segments)
      (remhash 'large-file drgnx-statusbar--segments)
      (force-mode-line-update t))
    (when any (message "Large files off: lean buffers keep their mode until you revert them"))))

(defconst drgnx-large-files--sweep-modes '(indent-bars-mode drgnx-blame-mode drgnx-sticky-mode diff-hl-margin-mode)
  "The expensive modes so-long's `so-long-minor-modes' lacks: the module adds them, so lean and so-long share one list.")

;;;; The module

(drgnx-module-define 'editor/large-files
                     :doc "Large files: above a size, a file opens in chunks, lean or raw (a command asks once), never freezing Emacs."
                     :stage 'startup
                     :teardown #'drgnx-large-files--teardown
                     :setup (lambda ()
                              (drgnx-large-files--define-config)
                              (drgnx-memo-activate 'drgnx-large-files--answers)
                              (drgnx-large-files--sync-threshold)
                              ;; the listener sets the threshold as this module, so each change is undone at teardown
                              (let ((sync (drgnx-modules-with-owner (drgnx-large-files--sync-threshold))))
                                (drgnx-module-hook 'drgnx-config-changed-functions config-changed (name)
                                  (when (eq name 'large-files) (funcall sync))))
                              ;; the door, and the server's requests, which are automatic
                              (drgnx-module-advice #'find-file-noselect :around open
                                                   (orig filename &optional nowarn rawfile wildcards)
                                (drgnx-large-files--visit orig filename nowarn rawfile wildcards))
                              ;; the first three arguments (31 adds EVALEXPRS after COMMANDS)
                              (drgnx-module-advice #'server-execute :around server (orig proc files nowait &rest rest)
                                ;; `drgnx open --wait': drgnx as $EDITOR needs the whole file
                                (let ((drgnx-large-file-open (if (and files (not nowait)) 'whole 'auto)))
                                  (drgnx-large-files--serve-unasked
                                   files (lambda () (apply orig proc files nowait rest)))))
                              ;; lean: the gate, the sweep, the revert
                              (drgnx-module-advice #'eglot-ensure :before-while not-large ()
                                (not (drgnx-large-file-p)))
                              ;; a revert runs the major mode again (`after-find-file'): still no parser
                              (drgnx-module-advice #'normal-mode :around no-parser (orig &rest args)
                                (if (memq drgnx-large-file '(lean raw))
                                    (drgnx-large-files--without-parser (buffer-size) (lambda () (apply orig args)))
                                  (apply orig args)))
                              ;; never in chunks: undo stays on there
                              (drgnx-module-hook 'find-file-hook sweep () :depth -90
                                                 (when (and (not (eq drgnx-large-file 'chunks))
                                                            (drgnx-large-files--sweep-p))
                                                   (drgnx-large-file-mode 1)))
                              ;; a major mode changed by hand resets the minor modes: the sweep again (after the
                              ;; global modes' turn-on, at the default depth); the flag is permanent
                              (drgnx-module-hook 'after-change-major-mode-hook major-mode () :depth 90
                                                 (pcase drgnx-large-file
                                                   ((or 'lean 'raw) (unless drgnx-large-file-mode (drgnx-large-file-mode 1)))
                                                   ;; the header and the chunk's opt-out of auto-save-visited were reset
                                                   ('chunks (setq-local auto-save-visited-mode nil)
                                                            (drgnx-large-files--header-refresh))))
                              (drgnx-module-hook 'before-revert-hook before-revert ()
                                (drgnx-large-files--before-revert))
                              (drgnx-module-hook 'after-revert-hook revert ()
                                (drgnx-large-files--after-revert))
                              ;; so-long everywhere, on the same list of modes
                              (unless global-so-long-mode (global-so-long-mode 1))
                              (let ((modes so-long-minor-modes))
                                (dolist (m drgnx-large-files--sweep-modes)
                                  (unless (memq m modes) (setq modes (append modes (list m)))))
                                (drgnx-module-set 'so-long-minor-modes modes))
                              ;; switching: each command is also a button of the header line
                              (pcase-dolist (`(,id ,title ,fn ,when ,doc)
                                             '((large-file-open-chunks "Large File: Open in Chunks" drgnx-large-files-open-chunks
                                                                       drgnx-large-files--offer-chunks-p
                                                                       "Reopen this large file in chunks, one part at a time")
                                               (large-file-open-whole "Large File: Open Whole (lean)" drgnx-large-files-open-whole
                                                                      drgnx-large-files--offer-whole-p
                                                                      "Reopen this large file whole, without the expensive modes")
                                               (large-file-open-raw "Large File: Open Raw" drgnx-large-files-open-raw
                                                                    drgnx-large-files--offer-raw-p
                                                                    "Reopen this large file whole and literally, without decoding")))
                                (drgnx-command-define id :category "File" :title title :command fn :when when :doc doc))
                              ;; the status bar's segment, once the bar is loaded (now, when it is)
                              (eval-after-load 'drgnx-statusbar
                                (drgnx-modules-with-owner (drgnx-large-files--segment-define)))))

(provide 'drgnx-large-files)
;;; drgnx-large-files.el ends here
