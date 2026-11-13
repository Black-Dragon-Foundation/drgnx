;;; drgnx-work-map.el --- The Work map's buffer: mode, view type and rows (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The map is one read-only buffer, `*drgnx work: NAME*', in `drgnx-work-map-mode': a hub-fed view whose rows the hub
;; builds and sends as patches (`drgnx-view-patch-attach'), its keys answered from the map's model in Sjá, Nidhogg's
;; view model.  The hub draws the cards, the strip, the outline and the bands; the editor selects, opens, sends the
;; filters and moves a layout the user asked for.  An Emacs without Sjá, and a map with no workspace, show a notice
;; (the view type `work-map' draws `drgnx-work-space--message' alone).  The buffer's view id is
;; `drgnx-work-space--view'.  Keys come from the key profiles (keys/*.eld), never from this file.  Loaded by
;; tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-pixels)
(require 'drgnx-work-client)
(require 'drgnx-hooks)
(require 'drgnx-ui-kit)
(defvar drgnx-chrome-own-tab-line)
;; the faces the hub's rows name: the cards' (decor) and the machines' dots (the runners view)
(unless (featurep 'drgnx-decor)
  (load (expand-file-name "../ui/drgnx-decor" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-runners-view)
  (load (expand-file-name "drgnx-runners-view" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(declare-function nidhogg-view-set "nidhogg-views" (h what value))
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-work-space--show-detail "drgnx-work-space")
(declare-function drgnx-face-glyph "drgnx-ui-kit")

(defvar-local drgnx-work-space--view nil
  "The id of the map view this buffer shows (`drgnx-work-client-open'), or nil for an empty map.")
(defvar-local drgnx-work-space--message nil
  "The text a map shows when the hub's rows cannot be (no workspace, or no Sjá).")
(defvar-local drgnx-work-map--outline nil
  "The form the user asked for with `O': t the outline, `off' the cards, nil none asked (the hub's choice).")

(defvar-local drgnx-work-map--selection nil
  "The selected item, (KIND . ID), or nil: the model's selection in Sjá, kept by `drgnx-work-map--nav'.")
(defvar-local drgnx-work-map--finished nil
  "The id of the item that finished while it was selected; the side panel says so until the selection moves.")
(defvar-local drgnx-work-map--search nil
  "The text `work-search' narrows the map to, or nil: items that do not match are dimmed.")

(defvar-local drgnx-work-map--lens ""
  "The lens (Map · Board · Timeline), the buffer's tab line.")
;; a mode line keeps the faces of a variable's string only when the variable is risky
(put 'drgnx-work-map--lens 'risky-local-variable t)
(defvar-local drgnx-work-map--filters nil
  "The filters sent to the hub: a plist (:focus ITEM-ID :overlaps BOOL :finished BOOL).")
(defvar-local drgnx-work-map--collapsed nil "The collapsed layers (1 to 6).")
(defvar-local drgnx-work-map--asked nil
  "Non-nil from a layout the user asked for (`drgnx-work-map--send-filters') until the hub answers it.")
(defvar-local drgnx-work-map--needs-at 0 "The index of the strip entry `n' selected last.")

(defvar drgnx-work-map-select-functions nil
  "Called with the map buffer after its selection changed.")

(defvar drgnx-work-map-scale nil
  "The display scale the motion's card rectangles are reckoned at; nil: the frame's.  A test binds it.")

(defvar drgnx-work-lens-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "Keys every Work view shares: the map, the Board, the Timeline and the trail (the lens, moving, opening).  The
key profiles bind them (`drgnx-command-define' with this map); each view's own keymap has it as its parent.")
(defvar-local drgnx-work-lens--map nil
  "In a Board, Timeline, trail or review buffer: the map buffer it is a view of (the selection lives there).")
(defvar-local drgnx-work-lens-nav nil
  "In a Work view that is not the map: a function of one direction (`left' `right' `up' `down' `next-agent'
`previous-agent' `open' `open-beside') that moves or opens in that view; the shared keys call it.")

(defvar drgnx-work-map-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the map buffer.  The key profiles bind them (`drgnx-command-define' with this map).")

(defface drgnx-work-band '((t :height 0.1))
  "The blank lines of the bands between rows: small, so a band is as high as its tile and no higher."
  :group 'drgnx-work-space)

(define-derived-mode drgnx-work-map-mode special-mode "Work map"
  "The Work space's map: layers of asks, specs, plans, agents, branches and files, and the edges between them."
  (setq-local drgnx-view-nav-notice-method "work/map/set")  ; the rows path tells the hub the selection, trailing
  (setq-local truncate-lines t cursor-type nil drgnx-chrome-own-tab-line t
              tab-line-format '("" drgnx-work-map--lens)))

(defconst drgnx-work-map--margin 84 "The width, in logical pixels, of the layer labels' margin.")

(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))
(defun drgnx-work-map-buffers ()
  "The live map buffers."
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-map-mode) (not (drgnx-view-patch-twin-p b)))) (buffer-list)))

(defun drgnx-work-map-buffer (view-id)
  "The map buffer showing view VIEW-ID, or nil."
  (seq-find (lambda (b) (equal (buffer-local-value 'drgnx-work-space--view b) view-id)) (drgnx-work-map-buffers)))

;;;; Geometry

(defun drgnx-work-map--scale ()
  (or drgnx-work-map-scale (drgnx-pixels-scale)))

(defun drgnx-work-map--px (units)
  "UNITS (4 logical pixels each) in device pixels."
  (round (* units 4 (drgnx-work-map--scale))))

(defun drgnx-work-map--margin-px () (round (* drgnx-work-map--margin (drgnx-work-map--scale))))

;;;; The notice: a map with no rows of the hub's

(defconst drgnx-work-map-no-sja
  "The Work map needs Sjá, Nidhogg's view model: it is drawn from the hub's rows, and this Emacs has no Sjá."
  "What a map, and the views beside it, say in an Emacs without Sjá.")

(defun drgnx-work-map--render (_key)
  "The one row of a map with no rows of the hub's: its message."
  (concat (or drgnx-work-space--message "") "\n"))

(defun drgnx-work-map--sync (_view)
  (drgnx-view-sync-rows drgnx-view '((:empty)) #'identity))

(drgnx-view-define 'work-map :render #'drgnx-work-map--render :sync #'drgnx-work-map--sync)

;;;; The rows path: keys answer from the map's model in Sjá

(defconst drgnx-work-map--through-faces
  '(drgnx-card-top drgnx-card-mid drgnx-card-bottom drgnx-card-single
                   drgnx-card-sel-top drgnx-card-sel-mid drgnx-card-sel-bottom drgnx-card-sel-single)
  "The faces of a card's rows, plain and selected: a class (the dimming) goes through their box, as for text.")

(defconst drgnx-work-map--nav-faces '(("selected") ("chain") ("dim"))
  "The map's class faces: the hub draws the selected card in its ring faces, the chain in its lanes and what is off the
chain dim (`drgnx-work-dim' in its rows), so no class has a face of the editor's.")

(defvar drgnx-view-nav-through-faces)
(defvar drgnx-view-nav-faces)

(defun drgnx-work-map-rows-p ()
  "Whether this Emacs can show the hub's rows of a map: it has Sjá (the keys answer from its model)."
  (fboundp 'nidhogg-view--call))

(defun drgnx-work-map-rows-attach (view)
  "Make the current map buffer the hub-fed view VIEW (the map view's id): its rows come as patches for the classes
whose env this Emacs sends while a window shows it; the selection goes to the hub by the trailing notice."
  (drgnx-view-patch-attach view "unshown")
  (setq-local drgnx-view-patch-twin-function #'drgnx-work-map--twin
              drgnx-view-nav-through-faces drgnx-work-map--through-faces
              drgnx-view-nav-faces drgnx-work-map--nav-faces)
  (setq drgnx-work-map--lens (drgnx-work-map--lens-string))
  (require 'drgnx-view-env)
  (drgnx-view-env-register view (current-buffer)))

(defun drgnx-work-map--twin (class)
  "The map's buffer in display CLASS (`drgnx-view-patch-twin-function'): its state and its lens's, read again before
each command there."
  (drgnx-view-env-twin class '("drgnx-work-map-" "drgnx-work-lens-")))

(defun drgnx-work-map--sja ()
  "This map's instance in Sjá (its rows are the hub's), or nil."
  (and drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch)))

(defun drgnx-work-map--require-sja ()
  "This map's instance in Sjá, or a user error that says the map needs it."
  (or (drgnx-work-map--sja) (user-error "%s" drgnx-work-map-no-sja)))

(defun drgnx-work-map--nav (verb &rest args)
  "Move the selection by VERB and ARGS through `drgnx-view-nav'; keep `drgnx-work-map--selection' as (KIND . ID) and
run `drgnx-work-map-select-functions' when it moved.  A broken view keeps the selection it had."
  (let ((h (drgnx-work-map--require-sja)) (before drgnx-work-map--selection))
    (let* ((id (apply #'drgnx-view-nav verb args))
           (kind (and id (nidhogg-view-get h 'kind id)))
           (sel (and id (cons (if (stringp kind) (intern kind) kind) id))))
      (unless (or (equal sel before) (and (null id) (eql 2 (nidhogg-view-get h 'health))))
        (setq drgnx-work-map--selection sel drgnx-work-map--finished nil)
        (run-hook-with-args 'drgnx-work-map-select-functions (current-buffer)))
      drgnx-work-map--selection)))

(defun drgnx-work-map--class-index (h name)
  "The index of class NAME in H's descriptor, or nil."
  (cl-position name (nidhogg-view-get h 'class-names) :test #'equal))

(defun drgnx-work-map--sja-search (h text)
  "Search H's model for TEXT (nil: none) and select the first agent of the outline that matches."
  (nidhogg-view-set h 'search text)
  (drgnx-view-nav-class-step drgnx-view)
  (when-let* ((text) (m (drgnx-work-map--class-index h "match"))
              (first (seq-find (lambda (id) (eql m (nidhogg-view-get h 'class id)))
                               (nidhogg-view-get h 'list "outline"))))
    (drgnx-work-map--nav 'select first)))

(defun drgnx-work-map-chain-agents ()
  "The hub session ids of the current map's team agents on the selection's chain, in team order (nil without Sjá)."
  (when-let* ((h (drgnx-work-map--sja)))
    (let ((chain (drgnx-work-map--class-index h "chain")) out)
      (dolist (id (nidhogg-view-get h 'list "team"))
        (when (and chain (eql chain (nidhogg-view-get h 'class id)) (string-prefix-p "agent:" id))
          (push (substring id (length "agent:")) out)))
      (nreverse out))))

(defun drgnx-work-map-select (sel)
  "Select SEL, (KIND . ID), in the current map: the model in Sjá selects (`drgnx-work-map--nav'), the hub draws the
classes, point goes to the card and the side panel follows."
  (drgnx-work-map--nav 'select (cdr sel)))

;;;; Moving the selection

(defun drgnx-work-map--move (dir)
  "Move the selection in DIR; in a Work view that is not the map, that view's own move."
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav dir)
    (drgnx-work-map--nav 'follow (symbol-name dir))))

(defun drgnx-work-map-left () "Select the previous item of this layer." (interactive) (drgnx-work-map--move 'left))
(defun drgnx-work-map-right () "Select the next item of this layer." (interactive) (drgnx-work-map--move 'right))
(defun drgnx-work-map-why () "Select what the selection came from." (interactive) (drgnx-work-map--move 'up))
(defun drgnx-work-map-touches () "Select what the selection touches." (interactive) (drgnx-work-map--move 'down))

(defun drgnx-work-map--history (link)
  "Follow Sjá's reserved LINK (\"back\" or \"forward\") in this Work view: the map through `drgnx-work-map--nav', a
view of it straight through `drgnx-view-nav'."
  (if drgnx-work-lens-nav (drgnx-view-nav 'follow link) (drgnx-work-map--nav 'follow link)))

(defun drgnx-work-map-back () "Select what was selected before the last move." (interactive)
       (drgnx-work-map--history "back"))
(defun drgnx-work-map-forward () "Redo the move that back undid." (interactive) (drgnx-work-map--history "forward"))

(defun drgnx-work-map-next-agent ()
  "Select the next agent, in team order."
  (interactive)
  (if drgnx-work-lens-nav (funcall drgnx-work-lens-nav 'next-agent) (drgnx-work-map--nav 'walk "team" 1)))

(defun drgnx-work-map-previous-agent ()
  "Select the previous agent, in team order."
  (interactive)
  (if drgnx-work-lens-nav (funcall drgnx-work-lens-nav 'previous-agent) (drgnx-work-map--nav 'walk "team" -1)))

;;;; Opening the selection

(defvar drgnx-agents--sessions)
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-agent-session-remote "drgnx-agents")

(declare-function drgnx-work-code-open-file "drgnx-work-code")
(declare-function drgnx-work-code-local-file "drgnx-work-code")
(declare-function drgnx-work-code--roots "drgnx-work-code")

(defun drgnx-work--open-agent (sid)
  "Open the panel of the hub session SID."
  (if (fboundp 'drgnx-agent-panel-open)
      (drgnx-agent-panel-open sid)
    (message "Work: the agent panel is not on")))

(defun drgnx-work-map--root-named (name)
  "The workspace root whose directory is called NAME, or nil."
  (let ((roots (plist-get (drgnx-work-client--view-params (drgnx-work-client--get drgnx-work-space--view)) :workspace)))
    (seq-find (lambda (r) (equal (file-name-nondirectory (directory-file-name r)) name)) (plist-get roots :roots))))

(defun drgnx-work-map--open-item (sel beside label &optional agents)
  "Open the item SEL as the design's table says; BESIDE: without moving focus.  LABEL is the item's label and AGENTS
the session ids a file opens at."
  (let* ((id (cdr sel)) (key (cadr (split-string id ":")))
         (show (lambda (buffer) (if beside (display-buffer buffer) (pop-to-buffer buffer)))))
    (pcase (car sel)
      ('agent (drgnx-work--open-agent (substring id (length "agent:"))))
      ('subagent (drgnx-work--open-agent (car (split-string (substring id (length "agent:")) "/"))))
      ('branch (let* ((parts (split-string key "/")) (root (drgnx-work-map--root-named (car parts))))
                 (cond ((null root) (message "Work: %s is not in this workspace" (car parts)))
                       ((fboundp 'magit-status) (funcall #'magit-status root))
                       (t (funcall show (dired-noselect root))))))
      ('file (drgnx-work-code-open-file sel :beside beside :agents agents))
      ('machine (drgnx-work-space--show-detail (current-buffer))
                (message "Work: %s — its queue is in the side panel" label))
      ;; a document's key is the hub's: only a plain local file inside a root of the workspace opens, by its true name
      (_ (let ((path (seq-some (lambda (root) (drgnx-work-code-local-file key (list root)))
                               (if-let* ((v (drgnx-work-client--get drgnx-work-space--view)))
                                   (plist-get (plist-get (drgnx-work-client--view-params v) :workspace) :roots)
                                 (drgnx-work-code--roots)))))
           (if path (funcall show (find-file-noselect path))
             (message "Work: no document is recorded for %s" label)))))))

(defun drgnx-work-map-open-selection (&optional beside)
  "Open the selected item: an agent's transcript, a branch's repository, a file, a document.  BESIDE (a prefix
argument): without moving focus."
  (interactive "P")
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav (if beside 'open-beside 'open))
    ;; the kind came with the selection; the label is read once, the chain's agents only for a file
    (let ((h (drgnx-work-map--require-sja)) (sel drgnx-work-map--selection))
      (unless sel (user-error "Nothing is selected"))
      (drgnx-work-map--open-item sel beside (nidhogg-view-get h 'field "label" (cdr sel))
                                 (and (eq (car sel) 'file) (drgnx-work-map-chain-agents))))))

(defun drgnx-work-map-open-beside ()
  "Open the selected item beside the map, without moving focus."
  (interactive)
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav 'open-beside)
    (drgnx-work-map-open-selection t)))

;;;; Card faces, shared with the Work views drawn here

(defun drgnx-work-map--card-face (n i)
  "The decoration face of line I of a card of N lines."
  (cond ((= n 1) (if (facep 'drgnx-card-single) 'drgnx-card-single 'drgnx-work-chip))
        ((= i 0) 'drgnx-card-top) ((= i (1- n)) 'drgnx-card-bottom) (t 'drgnx-card-mid)))

;;;; The outline form

(defun drgnx-work-map-toggle-outline ()
  "Show the outline form instead of the map, or the map again (a terminal's frame always shows the outline)."
  (interactive)
  (let ((h (drgnx-work-map--require-sja)))
    (setq drgnx-work-map--outline (if (eq drgnx-work-map--outline t) 'off t))
    ;; the model's up and down walk the outline list in that form
    (nidhogg-view-set h 'form (if (eq drgnx-work-map--outline t) "outline" "graph"))
    ;; the hub draws the form asked for (kept for the next subscription)
    (drgnx-work-client-set drgnx-work-space--view :outline (if (eq drgnx-work-map--outline t) "on" "off"))))

;;;; The lens: the tab line

(defun drgnx-work-lens-string (&optional current name keys)
  "The lens bar: the Work space's tab (Work · NAME, the workspace's name), then Map · Board · Timeline · Flow with
CURRENT (`map', `board', `timeline' or `flow'; default `map') marked and the others in the label face (`m' `b' `t' `F'
switch), then KEYS, the lens's own keys ((LABEL . KEY) …), as chips with their key badges."
  (let ((current (or current 'map)))
    (concat (propertize (concat " " (or (drgnx-face-glyph 'layers) "") " " (if name (concat "Work · " name) "Work") " ")
                        'face 'drgnx-work-lens-title)
            "  "
            (mapconcat (lambda (v)
                         (propertize (format " %s " (cdr v))
                                     'face (if (eq (car v) current) 'drgnx-work-lens-current 'drgnx-work-label)))
                       '((map . "Map") (board . "Board") (timeline . "Timeline") (flow . "Flow")) " ")
            (mapconcat (lambda (k)
                         (concat "  " (propertize (format " %s " (car k)) 'face 'drgnx-work-chip)
                                 (propertize (format " %s " (cdr k)) 'face 'drgnx-work-lens-key)))
                       keys ""))))

(defun drgnx-work-lens-name (&optional map)
  "The workspace's name on the lens bar: the folder name of MAP's (default: the current buffer's) first root."
  (with-current-buffer (if (buffer-live-p map) map (current-buffer))
    (and default-directory (file-name-nondirectory (directory-file-name default-directory)))))

(defconst drgnx-work-map--lens-keys '(("focus" . "f") ("overlaps" . "o"))
  "The map's own keys on its lens bar: the filters, as pills with their keycaps.")

(defun drgnx-work-map--lens-string ()
  "The lens bar of the map, the map marked."
  (drgnx-work-lens-string 'map (drgnx-work-lens-name) drgnx-work-map--lens-keys))

;;;; What needs you: the strip's entries, the model's list `needs-you'

(defun drgnx-work-map-needs-you (n)
  "Select the item the strip's Nth chip (g N) is about, the Nth entry of the model's needs-you list.  It selects;
nothing is approved, pushed or answered.  An entry about nothing the map shows (its card's id, no node) selects
nothing; n and p go on from it."
  (let* ((h (drgnx-work-map--require-sja)) (id (nth (1- n) (nidhogg-view-get h 'list "needs-you"))))
    (when id (setq drgnx-work-map--needs-at (1- n)))
    (if (and id (nidhogg-view-get h 'kind id))
        (drgnx-work-map--nav 'walk-to "needs-you" (1- n))
      (message "Work: nothing needs you at g%d" n))))

(defun drgnx-work-map-needs-you-here-next (&optional back)
  "Select the next (BACK: previous) thing that needs you, cycling."
  (interactive)
  (let ((n (length (nidhogg-view-get (drgnx-work-map--require-sja) 'list "needs-you"))))
    (if (zerop n)
        (message "Work: nothing needs you")
      (setq drgnx-work-map--needs-at (mod (+ drgnx-work-map--needs-at (if back -1 1)) n))
      (drgnx-work-map-needs-you (1+ drgnx-work-map--needs-at)))))

(defun drgnx-work-map-needs-you-here-previous ()
  "Select the previous thing that needs you."
  (interactive)
  (drgnx-work-map-needs-you-here-next t))

;;;; Filters: the user's own layouts, which the hub makes at once

(defun drgnx-work-map--send-filters ()
  "Tell the hub the filters and collapsed layers: it sends the layout's patches, then its answer.  A layout the user
asks for moves (`drgnx-work-map--motion-begin')."
  (drgnx-work-map--motion-begin)
  (when drgnx-work-space--view
    (setq drgnx-work-map--asked t)
    (drgnx-work-client-set-then drgnx-work-space--view
                                (apply-partially #'drgnx-work-map--answered (current-buffer))
                                :filters (list :focus (plist-get drgnx-work-map--filters :focus)
                                               :overlaps (if (plist-get drgnx-work-map--filters :overlaps) t :false)
                                               :finished (if (plist-get drgnx-work-map--filters :finished) t :false))
                                :collapsed (vconcat drgnx-work-map--collapsed))))

(defvar drgnx-work-map--motion)                   ; "Motion", below

(defun drgnx-work-map--answered (buffer _result err)
  "The hub answered the filters BUFFER's map sent.  The layout's patches came before the answer (one connection, in
order): the view draws them at the next timer pass, not after its throttle (live patches keep the map drawing once
per `drgnx-view-delay')."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq drgnx-work-map--asked nil)
      (when (and (not err) drgnx-view-patch (drgnx-view-p drgnx-view))
        ;; the layout the user asked for moves (`drgnx-work-map--motion-frame'); live patches never call this
        (if drgnx-work-map--motion (drgnx-work-map--motion-frame) (drgnx-view-hurry drgnx-view))))))

(defun drgnx-work-map-focus ()
  "Hide what is not on the selection's chain; again, or with nothing selected, show everything.  While focused, the
arrow keys move inside the chain and send nothing."
  (interactive)
  (let ((sel drgnx-work-map--selection) (cur (plist-get drgnx-work-map--filters :focus)))
    (cond ((and cur (or (null sel) (equal cur (cdr sel)))) (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :focus nil)))
          (sel (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :focus (cdr sel))))
          (t (user-error "Select an item first")))
    (drgnx-work-map--send-filters)))

(defun drgnx-work-map-overlaps ()
  "Show only the agents and branches that overlap, and what they share; again for everything."
  (interactive)
  (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :overlaps (not (plist-get drgnx-work-map--filters :overlaps))))
  (drgnx-work-map--send-filters))

(defun drgnx-work-map-show-finished ()
  "Show finished items too; again to hide them."
  (interactive)
  (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :finished (not (plist-get drgnx-work-map--filters :finished))))
  (drgnx-work-map--send-filters))

(defun drgnx-work-map-collapse-layer (n)
  "Collapse layer N to one thin row, or expand it."
  (setq drgnx-work-map--collapsed (if (memq n drgnx-work-map--collapsed) (delq n (copy-sequence drgnx-work-map--collapsed))
                                    (cons n drgnx-work-map--collapsed)))
  (drgnx-work-map--send-filters))

(defun drgnx-work-map-expand-layers ()
  "Expand every layer."
  (interactive)
  (setq drgnx-work-map--collapsed nil)
  (drgnx-work-map--send-filters))

(defun drgnx-work-map-search (text)
  "Narrow the map to the items matching TEXT, dim the rest, and select the first match."
  (interactive (list (read-string "Narrow the map to: " drgnx-work-map--search)))
  (let ((h (drgnx-work-map--require-sja)) (text (and text (not (string-empty-p text)) text)))
    (setq drgnx-work-map--search text)
    (drgnx-work-map--sja-search h text)))

(declare-function drgnx-close-pane "drgnx-close")

(defun drgnx-work-map-escape ()
  "Clear the search; with none, clear the filters and the collapsed layers; with none of those, close the pane."
  (interactive)
  (cond ((and drgnx-work-map--search (not (string-empty-p drgnx-work-map--search)))
         (drgnx-work-map-search nil))
        ((or (plist-get drgnx-work-map--filters :focus) (plist-get drgnx-work-map--filters :overlaps)
             (plist-get drgnx-work-map--filters :finished) drgnx-work-map--collapsed)
         (setq drgnx-work-map--filters nil drgnx-work-map--collapsed nil)
         (drgnx-work-map--send-filters))
        (t (drgnx-close-pane))))

;;;; Motion: a layout the user asked for moves, in the compositor

;; Glitnir's layout leg (Nidhogg): the window parameter `glitnir-layout-capture' asks the presenter for a picture of
;; the window's text area, `glitnir-layout-captured-p' says it holds it, and `glitnir-layout-motion' says what moved
;; from it.  Without the leg (a terminal, a flat GUI, macOS for now, reduced motion) the map jumps, and says nothing.
(declare-function glitnir-active-p "glitnir")
(declare-function glitnir-layout-captured-p "glitnir")
(declare-function glitnir--reduced-motion-p "glitnir")
(defvar drgnx-look-motion)

(defvar drgnx-work-map-motion-duration 0.16
  "Seconds a layout the user asked for takes to move: the look's longest transition.  A test binds it.")

(defconst drgnx-work-map--motion-period (/ 1.0 60)
  "One frame period: how long the new layout waits for the compositor to hold the old picture.")

(defvar drgnx-work-map-motion-stats (list :legs 0 :skipped 0)
  "This Emacs's map motion: :legs the layouts that moved, :skipped those whose old picture the compositor did not
hold within one period (they jumped).")

(defvar-local drgnx-work-map--motion nil
  "The layout the user asked for, waiting for the hub's answer: (OLD-IDS . WINDOWS), OLD-IDS the cards the buffer drew
then (`drgnx-work-map--drawn-ids'), WINDOWS a list of (WINDOW OLD) for each window that asked for a capture.  OLD: an
alist id → (X Y W H), the cards the window showed, in pixels of its text area.  Nil when nothing waits.")

(defvar-local drgnx-work-map--motion-windows nil
  "The windows this map set `glitnir-layout-capture' on: the leg's end and the teardown take their parameters off.")

(defun drgnx-work-map--motion-p ()
  "Whether a layout can move here: Glitnir draws the selected frame, it has the layout leg, and motion is not
reduced (the desktop's setting through Glitnir, or `drgnx-look-motion')."
  (and (display-graphic-p) (fboundp 'glitnir-layout-captured-p) (fboundp 'glitnir-active-p) (glitnir-active-p)
       (not (eq (bound-and-true-p drgnx-look-motion) 'reduced))
       (not (and (fboundp 'glitnir--reduced-motion-p) (glitnir--reduced-motion-p)))))

(defun drgnx-work-map--card-row-p (key)
  "Whether row KEY is one of the layout's card rows (the hub's `row:…'; not the strip, a band or the outline)."
  (and (stringp key) (string-prefix-p "row:" key)))

(defun drgnx-work-map--drawn-ids ()
  "Hash id → t: every card the buffer's card rows draw now."
  (let ((ids (make-hash-table :test #'equal)) (pos (point-min)) (end (point-max)))
    (while (< pos end)
      (let ((id (get-text-property pos 'drgnx-work-id)) (next (next-single-property-change pos 'drgnx-work-id nil end)))
        (when (and id (drgnx-work-map--card-row-p (drgnx-view-key-at pos))) (puthash id t ids))
        (setq pos next)))
    ids))

(defun drgnx-work-map--item-rects (window)
  "Alist id → (X Y W H): the cards WINDOW shows, at least in part, in pixels of its text area.  X and W are the
model's (fields x and w, from Sjá); Y and H where the display engine lays out the card's lines, so a line taller than
the layout (an emoji, a larger fallback font) is where it is drawn: each line's height is `window-text-pixel-size' of
that line alone (from its start to the next line's end, the next line's height left out), added up from the window's
first line down to its bottom, one line's layout each (no redisplay).  Only the card rows count: the outline moves
nothing.  Nil when WINDOW scrolls sideways."
  (when (zerop (window-hscroll window))
    (let ((h (drgnx-work-map--sja)) (margin (drgnx-work-map--margin-px)) (bottom (window-body-height window t))
          (spans (make-hash-table :test #'equal)) (order nil) (y 0) out)
      ;; each card: (TOP . BOTTOM), the y its first line starts at and its last line ends at
      (save-excursion
        (goto-char (window-start window))
        (while (and (< y bottom) (not (eobp)))
          (let* ((bol (point)) (eol (line-end-position)) (next (min (point-max) (1+ eol)))
                 ;; up to the next line's end, that line left out: a measure that stops at the next line's start
                 ;; stops before a display property there, and leaves out this line's newline (its height)
                 (lh (cdr (if (< eol next)
                              (window-text-pixel-size window bol (save-excursion (goto-char next) (line-end-position))
                                                      nil nil nil t)
                            (window-text-pixel-size window bol eol)))))
            (when (drgnx-work-map--card-row-p (drgnx-view-key-at bol))
              (let ((p bol))
                (while (< p eol)
                  (let ((id (get-text-property p 'drgnx-work-id))
                        (q (next-single-property-change p 'drgnx-work-id nil eol)))
                    (when id
                      (if-let* ((s (gethash id spans))) (setcdr s (+ y lh))
                        (puthash id (cons y (+ y lh)) spans)
                        (push id order)))
                    (setq p q)))))
            (setq y (+ y lh))
            (goto-char next))))
      (dolist (id order)
        (when-let* ((x (nidhogg-view-get h 'field "x" id)) (w (nidhogg-view-get h 'field "w" id)))
          (let ((left (+ margin (drgnx-work-map--px x))) (s (gethash id spans)))
            (push (list id left (car s) (- (+ margin (drgnx-work-map--px (+ x w))) left) (- (cdr s) (car s)))
                  out))))
      out)))

(defun drgnx-work-map--motion-begin ()
  "A layout the user asked for is on its way (the hub's patches and answer come): each window showing the map asks
the compositor for the picture of the layout it shows now, and remembers where its cards are.  Nothing when the map
cannot move here (`drgnx-work-map--motion-p') or shows no card (the outline): the new layout then jumps."
  (when (and drgnx-work-space--view (drgnx-view-p drgnx-view) (drgnx-work-map--sja) (drgnx-work-map--motion-p))
    (let ((windows nil))
      (dolist (w (get-buffer-window-list (current-buffer) nil t))
        (when-let* ((rects (drgnx-work-map--item-rects w)))
          ;; a new value, not `eq' to the last: the compositor takes a new picture
          (set-window-parameter w 'glitnir-layout-capture (list 'work-map))
          (cl-pushnew w drgnx-work-map--motion-windows)
          (push (list w rects) windows)))
      (when windows
        (drgnx-timer-cancel (cons 'work-motion-end drgnx-work-space--view))
        (setq drgnx-work-map--motion (cons (drgnx-work-map--drawn-ids) windows))
        ;; an answer that never comes (no hub) leaves no capture behind
        (drgnx-timer-start (cons 'work-motion-expire drgnx-work-space--view) 1 #'drgnx-work-map--motion-expire
                           :args (list (current-buffer)) :owner (current-buffer))))))

(defun drgnx-work-map--motion-frame ()
  "The hub answered the layout the user asked for (its patches came first, on the same connection): it is drawn now
when every window's old picture is held, else one period later (`drgnx-work-map--motion-settle'), moving where it is
held."
  (drgnx-timer-cancel (cons 'work-motion-expire drgnx-work-space--view))
  (unless (drgnx-work-map--motion-try (current-buffer))
    (drgnx-timer-poll (cons 'work-motion drgnx-work-space--view) drgnx-work-map--motion-period
                      #'drgnx-work-map--motion-try :deadline drgnx-work-map--motion-period
                      :on-timeout #'drgnx-work-map--motion-settle :args (list (current-buffer))
                      :owner (current-buffer))))

(defun drgnx-work-map--motion-try (buffer)
  "Draw BUFFER's new layout if every window's old picture is held; non-nil when it is drawn (or nothing waits)."
  (or (not (buffer-live-p buffer))
      (with-current-buffer buffer
        (or (null drgnx-work-map--motion)
            (when (seq-every-p (lambda (w) (or (not (window-live-p (car w))) (glitnir-layout-captured-p (car w))))
                               (cdr drgnx-work-map--motion))
              (drgnx-work-map--motion-draw)
              t)))))

(defun drgnx-work-map--motion-settle (buffer)
  "One period passed: BUFFER's new layout is drawn, moving in the windows whose old picture is held."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when drgnx-work-map--motion (drgnx-work-map--motion-draw)))))

(defun drgnx-work-map--motion-of (old-ids ids window old)
  "The `glitnir-layout-motion' of WINDOW from its cards at OLD (an alist as `drgnx-work-map--item-rects') to the
layout the buffer draws now and WINDOW has not shown yet; OLD-IDS and IDS the cards the buffer drew before and draws
now (`drgnx-work-map--drawn-ids').  Nil when nothing WINDOW shows moved."
  (let ((new (drgnx-work-map--item-rects window)) moves enters exits)
    (dolist (n new)
      (let ((o (assoc (car n) old)))
        (cond ((and o (not (equal (cdr o) (cdr n)))) (push (list (car n) (cdr o) (cdr n)) moves))
              ((and (null o) (not (gethash (car n) old-ids))) (push (list (car n) (cdr n)) enters)))))
    (dolist (o old)
      (unless (gethash (car o) ids) (push (list (car o) (cdr o)) exits)))
    (when (or moves enters exits)
      (list :moves moves :enters enters :exits exits :background 'default
            :duration drgnx-work-map-motion-duration :curve 'ease-out))))

(defun drgnx-work-map--motion-draw ()
  "Draw the new layout and, before the redisplay that shows it, tell the compositor what moved: a window whose old
picture is held gets `glitnir-layout-motion'; one whose picture is not held drops its capture and jumps (a skipped
leg, counted in `drgnx-work-map-motion-stats')."
  (let ((old-ids (car drgnx-work-map--motion)) (windows (cdr drgnx-work-map--motion)) (moved nil))
    (setq drgnx-work-map--motion nil)
    (drgnx-timer-cancel (cons 'work-motion drgnx-work-space--view))
    (drgnx-view-draw-now drgnx-view)
    (let ((ids (drgnx-work-map--drawn-ids)))
      (pcase-dolist (`(,w ,old) windows)
        (when (window-live-p w)
          (let* ((held (glitnir-layout-captured-p w))
                 (motion (and held (eq (window-buffer w) (current-buffer))
                              (drgnx-work-map--motion-of old-ids ids w old))))
            (if motion
                (progn (set-window-parameter w 'glitnir-layout-motion motion)
                       (setq moved t)
                       (cl-incf (plist-get drgnx-work-map-motion-stats :legs)))
              (unless held (cl-incf (plist-get drgnx-work-map-motion-stats :skipped)))
              (set-window-parameter w 'glitnir-layout-capture nil)
              (set-window-parameter w 'glitnir-layout-motion nil))))))
    (when moved
      ;; the leg is over by then: its parameters go, so the window is an ordinary one again
      (drgnx-timer-start (cons 'work-motion-end drgnx-work-space--view) (+ drgnx-work-map-motion-duration 0.1)
                         #'drgnx-work-map--motion-end :args (list (current-buffer)) :owner (current-buffer)))))

(defun drgnx-work-map--motion-off ()
  "Take the capture and the motion off every window this map set them on (a jump for a leg still running)."
  (dolist (w drgnx-work-map--motion-windows)
    (when (window-live-p w)
      (set-window-parameter w 'glitnir-layout-capture nil)
      (set-window-parameter w 'glitnir-layout-motion nil)))
  (setq drgnx-work-map--motion-windows nil))

(defun drgnx-work-map--frame-replaced (old new)
  "`drgnx-frame-replaced-functions': a map whose motion has windows on OLD stops it, on their counterparts in NEW
too (they were made with the capture and motion parameters)."
  (dolist (b (drgnx-work-map-buffers))
    (with-current-buffer b
      (when (seq-some (lambda (w) (and (window-live-p w) (eq (window-frame w) old))) drgnx-work-map--motion-windows)
        (setq drgnx-work-map--motion-windows
              (append (delq nil (mapcar (lambda (w) (drgnx-frame-replaced-window w new)) drgnx-work-map--motion-windows))
                      drgnx-work-map--motion-windows))
        (drgnx-work-map-motion-clear b)))))

(defun drgnx-work-map--motion-end (buffer)
  "The timer function at a leg's end: BUFFER's windows lose their capture and motion, unless a new layout waits."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless drgnx-work-map--motion (drgnx-work-map--motion-off)))))

(defun drgnx-work-map--motion-expire (buffer)
  "The timer function a second after a layout was asked for and its frame did not come: the captures go."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq drgnx-work-map--motion nil)
      (drgnx-work-map--motion-off))))

(defun drgnx-work-map-motion-clear (&optional buffer)
  "Stop BUFFER's (default: the current) map motion: nothing waits, its timers stop and its windows lose the capture
and the motion.  The module's teardown and a map buffer's end call it."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-work-space--view
      (dolist (k '(work-motion work-motion-expire work-motion-end))
        (drgnx-timer-cancel (cons k drgnx-work-space--view))))
    (setq drgnx-work-map--motion nil)
    (drgnx-work-map--motion-off)))

(provide 'drgnx-work-map)
;;; drgnx-work-map.el ends here
