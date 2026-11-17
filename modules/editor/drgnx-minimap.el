;;; drgnx-minimap.el --- Module editor/minimap: the scroll bar with marks on every surface -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The module of the scroll bar and, as its later stages land, the minimap that widens out of it (docs/guide/
;; minimap.md).  Its setup turns on the scroll bar on every scrollable surface (`drgnx-scrollbar-mode',
;; core/drgnx-ruler.el) and the marks' producers (core/drgnx-marks.el), and redraws the strips when the UI
;; scale or the density changes; its teardown undoes both.  It registers the next-mark commands (`mark-next', by kind
;; `change-next', `bookmark-next', `agent-edit-next', each with a previous).

;;
;; The minimap (state B, design §4): an editor window's strip widens into a map of the whole file when the pointer
;; rests on it, drawn by Nidhogg over the text's right edge from the buffer text's line model (`glitnir-minimap',
;; Hlidskjalf), so a scroll, an edit or a pointer move costs no Lisp.  Lisp gives each editor window its spec when
;; its strip is placed (`drgnx-ruler-place-functions'), the model the MARK expression, and the hub the file whose
;; definitions label the map (`minimap/watch'; the labels go from the hub to Sjá, not through Lisp).  A tree-sitter
;; buffer's bars are coloured by class: its pack's highlights query (else its own font-lock rules' queries) runs in C
;; at each parse (`nidhogg-treesit-highlight-query'), the classes' colours are the standard faces'.

;;; Code:
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-ruler)
(require 'drgnx-marks)
(require 'drgnx-registry)
(require 'drgnx-setting)

(defvar drgnx-look-density-changed-hook)
(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-notify "drgnx-notice")
(declare-function nidhogg-lines-enable "nidhogg-lines" (&optional buffer wait))
(declare-function nidhogg-lines-set-section-regexp "nidhogg-lines" (buffer regexp))
(declare-function nidhogg-treesit-refold "treesit.c" (parser))
(declare-function treesit-parser-list "treesit.c" (&optional buffer language tag))
(declare-function treesit-parser-language "treesit.c" (parser))
(declare-function treesit-query-compile "treesit.c" (language query &optional eager))
(declare-function treesit-query-language "treesit.c" (query))
(declare-function drgnx-packs-language-dir "drgnx-packs" (language))
(defvar nidhogg-treesit-highlight-query)
(defvar treesit-primary-parser)
(defvar treesit-font-lock-settings)

(defun drgnx-minimap--setting-changed (&rest _)
  "A minimap setting changed: every window's spec again, now."
  (when drgnx-scrollbar-mode (drgnx-scrollbar-refresh-all)))

(drgnx-defsetting drgnx-minimap t
  "Non-nil: an editor's scroll bar widens into the minimap while the pointer rests on it (150 ms), over the text's
right edge, and shrinks back 600 ms after the pointer leaves."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-width 120
  "The minimap's width in logical pixels, 80 to 200."
  :type 'natnum :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-labels t
  "The names drawn over the minimap: t, each definition (from the hub's outline, for files up to 8 MiB) and each
MARK section; `marks-only', the MARK sections alone; nil, none."
  :type '(choice (const :tag "Definitions and MARK sections" t) (const :tag "MARK sections only" marks-only)
                 (const :tag "None" nil))
  :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(defconst drgnx-minimap-default-mark-regexp
  "^\\s*(?:;;;;+|(?://+|#+|;+|--|/\\*+)\\s*(?:MARK:\\s*-?|pragma\\s+mark\\s+-?|region\\b|%%))\\s*(?P<name>\\S.*?)\\s*(?:\\*/)?$"
  "The MARK sections drgnx finds by default: `MARK:' comments, `// region' and `#region', `#pragma mark', Lisp
`;;;;' headings and `# %%' cells.")

(drgnx-defsetting drgnx-minimap-mark-regexp drgnx-minimap-default-mark-regexp
  "The comment lines drawn as MARK sections on the minimap, a regular expression in Rust's regex syntax (not
Emacs's): it is matched against each line; the section's name is the group named `name', else the first group, else
the whole match.  Nil: no MARK sections."
  :type '(choice (const :tag "None" nil) string) :group 'drgnx-minimap :scope 'global
  :apply #'drgnx-minimap--setting-changed)

(defface drgnx-minimap-label '((t :inherit drgnx-ui-text :weight semi-bold))
  "The font of the minimap's labels (its colour comes from the label's kind)." :group 'drgnx-minimap)

;;;; Colours: the line model's display classes

(defconst drgnx-minimap--class-faces
  '((keyword font-lock-keyword-face) (function font-lock-function-name-face) (type font-lock-type-face)
    (string font-lock-string-face) (comment font-lock-comment-face) (constant font-lock-constant-face)
    (added diff-indicator-added) (removed diff-indicator-removed) (heading outline-1) (link link)
    (special font-lock-escape-face))
  "Each display class (`glitnir-minimap-classes') and the face whose foreground colours its bars, (CLASS FACE); a
class not listed (variable, property, operator, punctuation), or whose face is not defined, draws as text.")

(defvar drgnx-minimap--queries (make-hash-table :test 'eq)
  "Each tree-sitter language's compiled `queries/highlights.scm' of its pack, or `none'.")

(defun drgnx-minimap--query (language)
  "The highlight query the minimap colours a LANGUAGE buffer by: its pack's `queries/highlights.scm' (compiled once a
language), else the compiled queries of the buffer's own tree-sitter font-lock rules for LANGUAGE that are on (their
captures are face names, which Nidhogg maps to classes as well); nil when there is neither."
  (let ((q (gethash language drgnx-minimap--queries)))
    (unless q
      (setq q (or (when-let* ((dir (and (require 'drgnx-packs nil t) (drgnx-packs-language-dir language)))
                              (file (expand-file-name "queries/highlights.scm" dir))
                              ((file-readable-p file)))
                    (ignore-errors
                      (treesit-query-compile language (with-temp-buffer (insert-file-contents file) (buffer-string))
                                             t)))
                  'none))
      (puthash language q drgnx-minimap--queries))
    (if (not (eq q 'none))
        q
      (and (fboundp 'treesit-query-language)
           (seq-keep (lambda (setting)
                       (let ((c (car setting)))
                         (and (nth 1 setting) (ignore-errors (eq (treesit-query-language c) language)) c)))
                     (bound-and-true-p treesit-font-lock-settings))))))

(defun drgnx-minimap--highlight ()
  "Give the current buffer's tree-sitter parser (its primary one, else its first) the highlight query that colours
its minimap (`nidhogg-treesit-highlight-query'), running it over the whole text when it changed; nothing without a
parser or a Nidhogg that runs it."
  (when-let* (((fboundp 'nidhogg-treesit-refold)) ((boundp 'nidhogg-treesit-highlight-query))
              ((fboundp 'treesit-parser-list))
              (parser (or (bound-and-true-p treesit-primary-parser) (car (treesit-parser-list))))
              (q (drgnx-minimap--query (treesit-parser-language parser))))
    (unless (equal q nidhogg-treesit-highlight-query)
      (setq-local nidhogg-treesit-highlight-query q)
      (nidhogg-treesit-refold parser))))

(defvar-local drgnx-minimap--regexp :none "The MARK expression last given the buffer's line model.")
(defvar-local drgnx-minimap--watched nil "The file name the hub was last told this buffer shows in a minimap.")

(defun drgnx-minimap-window-p (window)
  "Whether WINDOW gets the minimap: its strip is shown and it holds an editor's text (a file or a text buffer that
is not a view: no `drgnx-ruler-span-function', not a special mode)."
  (and drgnx-minimap (window-parameter window 'glitnir-ruler) (fboundp 'nidhogg-lines-enable)
       (with-current-buffer (window-buffer window)
         (and (not drgnx-ruler-span-function) (not (derived-mode-p 'special-mode))
              (or buffer-file-name (derived-mode-p 'prog-mode 'text-mode))))))

(defun drgnx-minimap--file (buffer)
  "The name BUFFER's file has in the hub's minimap layers (its true name), or nil (no file, a remote one)."
  (when-let* ((f (buffer-file-name buffer)) ((not (file-remote-p f))))
    (file-truename f)))

(defun drgnx-minimap--spec (window)
  "WINDOW's `glitnir-minimap': the width, the colours and the labels."
  (let ((file (and drgnx-minimap-labels (not (eq drgnx-minimap-labels 'marks-only))
                   (drgnx-minimap--file (window-buffer window)))))
    (append
     (list :width (max 80 (min 200 drgnx-minimap-width)) :scale 2 :nesting t
           :fill (cons (face-background 'drgnx-surface-panel nil 'default) 1.0)
           :text (cons 'default 0.35)
           :band (cons 'default 0.09)
           :classes (seq-keep (lambda (c) (and (facep (cadr c)) (cons (car c) (cadr c))))
                              drgnx-minimap--class-faces))
     (and drgnx-minimap-labels
          (list :labels (if (eq drgnx-minimap-labels 'marks-only) 'marks-only t)
                :label 'default :sub 'drgnx-text-muted :accent 'drgnx-accent :mark 'warning
                :label-face 'drgnx-minimap-label))
     (and file (list :file file)))))

(defun drgnx-minimap--hub-p ()
  "Non-nil when the hub's subscribed connection is up (the labels come there)."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events) (fboundp 'drgnx-hub--call-on)))

(defun drgnx-minimap--watch (buffer file)
  "Tell the hub BUFFER now shows FILE in a minimap (nil: none), when that changed."
  (with-current-buffer buffer
    (unless (equal file drgnx-minimap--watched)
      (when (drgnx-minimap--hub-p)
        (when drgnx-minimap--watched
          (drgnx-hub--call-on drgnx-hub--events "minimap/watch" (list :file drgnx-minimap--watched :on :false)
                              #'ignore))
        (when file
          (drgnx-hub--call-on drgnx-hub--events "minimap/watch" (list :file file :on t) #'ignore))
        (setq drgnx-minimap--watched file)))))

(defun drgnx-minimap--place (window on)
  "`drgnx-ruler-place-functions': WINDOW's minimap as it should be now, given that it shows the strip (ON)."
  (if (and on (drgnx-minimap-window-p window))
      (let ((buffer (window-buffer window)))
        (with-current-buffer buffer
          (nidhogg-lines-enable)
          (drgnx-minimap--highlight)
          (let ((re (and drgnx-minimap-labels drgnx-minimap-mark-regexp)))
            (unless (equal re drgnx-minimap--regexp)
              (setq drgnx-minimap--regexp re)
              (condition-case err
                  (nidhogg-lines-set-section-regexp nil re)
                (error (drgnx-notify 'minimap 'warn (format "Minimap MARK regexp: %s" (error-message-string err))
                                     :id 'mark-regexp))))))
        (let ((spec (drgnx-minimap--spec window)))
          (unless (equal spec (window-parameter window 'glitnir-minimap))
            (set-window-parameter window 'glitnir-minimap spec))
          (drgnx-minimap--watch buffer (plist-get spec :file))))
    (when (window-parameter window 'glitnir-minimap)
      (set-window-parameter window 'glitnir-minimap nil))))

(defun drgnx-minimap--off ()
  "Every window's minimap gone, and the hub told no file is shown in one."
  (dolist (f (frame-list))
    (dolist (w (window-list f 'nomini))
      (when (window-parameter w 'glitnir-minimap) (set-window-parameter w 'glitnir-minimap nil))))
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-minimap--watched b) (drgnx-minimap--watch b nil))
    (when (local-variable-p 'nidhogg-treesit-highlight-query b)
      (with-current-buffer b (kill-local-variable 'nidhogg-treesit-highlight-query))))
  (clrhash drgnx-minimap--queries))

(defconst drgnx-minimap--commands
  '((mark-next "Next Mark" drgnx-marks-next "Go to the next mark of any kind on the scroll bar")
    (mark-previous "Previous Mark" drgnx-marks-previous "Go to the previous mark of any kind on the scroll bar")
    (change-next "Next Change" drgnx-marks-next-change "Go to the next change against the last commit")
    (change-previous "Previous Change" drgnx-marks-previous-change "Go to the previous change against the last commit")
    (bookmark-next "Next Bookmark" drgnx-marks-next-bookmark "Go to the next bookmark in this file")
    (bookmark-previous "Previous Bookmark" drgnx-marks-previous-bookmark "Go to the previous bookmark in this file")
    (bookmark-toggle "Toggle Bookmark" drgnx-marks-bookmark-toggle "Set a bookmark on this line, or clear it")
    (bookmark-name "Name Bookmark…" drgnx-marks-bookmark-name "Name the bookmark on this line")
    (bookmark-go "Go to Bookmark…" drgnx-marks-bookmark-go "Go to a bookmark, this file's first")
    (agent-edit-next "Next Agent Edit" drgnx-marks-next-agent-edit "Go to the next place an agent edited in this file")
    (agent-edit-previous "Previous Agent Edit" drgnx-marks-previous-agent-edit
                         "Go to the previous place an agent edited in this file"))
  "The module's commands: (ID TITLE FUNCTION DOC) each.")

(defun drgnx-minimap--teardown ()
  "The scroll bar and the marks' producers off; every window's strip gone."
  (drgnx-marks-off)
  (remove-hook 'drgnx-ruler-place-functions #'drgnx-minimap--place)
  (drgnx-minimap--off)
  (remove-hook 'drgnx-look-density-changed-hook #'drgnx-scrollbar-refresh-all)
  (drgnx-scrollbar-mode -1))

(drgnx-module-define 'editor/minimap
                     :doc "The scroll bar on every scrollable surface: the thumb and the file's marks (changes, problems, search hits)."
                     :stage 'startup
                     :teardown #'drgnx-minimap--teardown
                     :setup (lambda ()
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-minimap--commands)
                                (drgnx-command-define id :category "Go" :title title :command fn :scope 'editing
                                                      :doc doc))
                              (add-hook 'drgnx-ruler-place-functions #'drgnx-minimap--place)
                              (drgnx-scrollbar-mode 1)
                              (add-hook 'drgnx-look-density-changed-hook #'drgnx-scrollbar-refresh-all)
                              (drgnx-marks-on)))

(provide 'drgnx-minimap)
;;; drgnx-minimap.el ends here
