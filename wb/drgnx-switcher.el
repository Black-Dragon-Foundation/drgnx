;;; drgnx-switcher.el --- The tile switcher: a letter on every tile of every window -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Switch Tile (`drgnx-switcher-open', command `tile-switcher') puts a letter on every tile of every visible
;; workbench window, on every monitor.  The letters (`drgnx-grid-letters') go in window order (the selected window
;; first, then by monitor and position, left to right) and reading order inside each, so they are stable for one
;; layout.  The 12 largest tiles of graphical windows get a card: a pooled undecorated child frame centred on the
;; tile, the letter large and the tile's title under it (with the monitor's name when windows sit on several
;; monitors).  The others, and every tile of a terminal window, get the letter in inverse video at the window's start.
;; While it is open: a letter picks that tile (its window selected; no window moves), Shift and a letter swaps the
;; tile you were in with that one, the arrows move the highlight across tiles and windows and RET picks it, Esc closes,
;; and any other key closes and is replayed.  Letters count only once the cards show (`drgnx-switcher-pop-in', one
;; frame under reduced motion): one typed before closes and is replayed to the tile you were in.
;; The model (the items, their letters, the neighbour by direction, which get cards) is pure and takes items, so it is
;; tested without windows; module ui/tiles owns the command, the timers and the pool.
;; See docs/develop/core.md, "The tile switcher".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-frame-kind)
(require 'drgnx-grid-tree)
(require 'drgnx-timer)

(declare-function drgnx-grid-tiles "drgnx-grid" (&optional frame filter))
(declare-function drgnx-grid-tile-main "drgnx-grid-ops" (window))
(declare-function drgnx-grid-swap "drgnx-grid-ops" (a b))
(declare-function drgnx-grid-editor-tile-p "drgnx-grid" (window))
(declare-function drgnx-grid--title "drgnx-grid" (kind))
(declare-function drgnx-grid--entries "drgnx-grid-ops" (window))
(declare-function drgnx-px "drgnx-pixels" (logical &optional frame))
(declare-function drgnx-look-chrome-current "drgnx-look")
(defvar drgnx-look-motion)

(defconst drgnx-switcher-cards-max 12 "The most tiles that get a card; the others get a letter at the window's start.")
(defconst drgnx-switcher-pop-in 0.12 "Seconds the cards take to pop in; letters count after it.")
(defconst drgnx-switcher-one-frame 0.016 "Seconds of one frame: the gate under reduced motion.")
(defconst drgnx-switcher-letter-px 42 "The card letter's height, logical pixels.")

;;;; The model: items

;; An item is a plist (:window W :frame F :edges (L T R B) :rank N :terminal BOOL :title S :monitor NAME :letter C),
;; :edges in the layout's pixels (the frame's place on its monitor added), :rank the frame's place in window order.

(defun drgnx-switcher--frame-x (frame)
  "FRAME's left edge in the layout: its monitor's, plus its position on it."
  (+ (or (car (alist-get 'geometry (frame-monitor-attributes frame))) 0) (or (car (frame-position frame)) 0)))

(defun drgnx-switcher-frames ()
  "The visible workbench windows: the selected one first, then the others by monitor and position, left to right.
Child frames (cards, popups) and the daemon's initial frame take no part."
  (let* ((sel (selected-frame))
         (all (seq-filter (lambda (f) (and (frame-visible-p f) (memq (drgnx-state-frame-kind f) '(gui tty))))
                          (frame-list)))
         (others (sort (remq sel all) (lambda (a b) (< (drgnx-switcher--frame-x a) (drgnx-switcher--frame-x b))))))
    (if (memq sel all) (cons sel others) others)))

(defun drgnx-switcher--tile-title (w)
  "Tile W's title: an editor's buffer, a tool tile's shown kind."
  (if (drgnx-grid-editor-tile-p w) (buffer-name (window-buffer w))
    (let ((kind (car (drgnx-grid--entries w))))
      (string-trim (if kind (drgnx-grid--title kind) (buffer-name (window-buffer w)))))))

(defun drgnx-switcher--tile-windows (frame)
  "FRAME's tiles, each by its main window, in reading order."
  (delete-dups (mapcar #'drgnx-grid-tile-main (drgnx-grid-tiles frame))))

(defun drgnx-switcher-items ()
  "Every tile of every window (`drgnx-switcher-frames') as items, lettered (`drgnx-switcher-assign')."
  (let ((rank 0) (items nil))
    (dolist (f (drgnx-switcher-frames))
      (let ((x (drgnx-switcher--frame-x f))
            (y (or (cdr (frame-position f)) 0))
            (monitor (alist-get 'name (frame-monitor-attributes f))))
        (dolist (w (drgnx-switcher--tile-windows f))
          (let ((e (window-pixel-edges w)))
            (push (list :window w :frame f :rank rank :terminal (not (display-graphic-p f))
                        :edges (list (+ x (nth 0 e)) (+ y (nth 1 e)) (+ x (nth 2 e)) (+ y (nth 3 e)))
                        :local e :title (drgnx-switcher--tile-title w) :monitor monitor)
                  items))))
      (setq rank (1+ rank)))
    (drgnx-switcher-assign (nreverse items))))

(defun drgnx-switcher-assign (items)
  "ITEMS in letter order — by :rank, then reading order (top, then left) — each given its :letter (as many as
`drgnx-grid-letters' has; the rest none)."
  (let* ((sorted (sort (copy-sequence items)
                       (lambda (a b)
                         (let ((ea (plist-get a :edges)) (eb (plist-get b :edges)))
                           (cond ((/= (plist-get a :rank) (plist-get b :rank)) (< (plist-get a :rank) (plist-get b :rank)))
                                 ((/= (nth 1 ea) (nth 1 eb)) (< (nth 1 ea) (nth 1 eb)))
                                 (t (< (nth 0 ea) (nth 0 eb))))))))
         (letters (drgnx-grid-letters (length sorted))))
    (cl-loop for it in sorted
             collect (append (list :letter (pop letters)) (cl-loop for (k v) on it by #'cddr unless (eq k :letter)
                                                                   append (list k v))))))

(defun drgnx-switcher--area (it)
  (let ((e (plist-get it :edges))) (* (- (nth 2 e) (nth 0 e)) (- (nth 3 e) (nth 1 e)))))

(defun drgnx-switcher-cards (items)
  "The ITEMS that get a card: the `drgnx-switcher-cards-max' largest of graphical windows (the rest, and terminal
windows', get a letter at the window's start)."
  (seq-take (sort (seq-remove (lambda (it) (plist-get it :terminal)) (copy-sequence items))
                  (lambda (a b) (> (drgnx-switcher--area a) (drgnx-switcher--area b))))
            drgnx-switcher-cards-max))

(defun drgnx-switcher--centre (it)
  (let ((e (plist-get it :edges))) (cons (/ (+ (nth 0 e) (nth 2 e)) 2.0) (/ (+ (nth 1 e) (nth 3 e)) 2.0))))

(defun drgnx-switcher-neighbour (items from direction)
  "The item of ITEMS next to FROM toward DIRECTION (`left', `right', `up', `down') by the layout's pixels, across
windows: the nearest centre in that half-plane, the main axis counting more; nil at the edge."
  (let* ((c (drgnx-switcher--centre from)) best (score nil))
    (dolist (it items)
      (unless (eq it from)
        (let* ((o (drgnx-switcher--centre it)) (dx (- (car o) (car c))) (dy (- (cdr o) (cdr c)))
               (main (pcase direction ('right dx) ('left (- dx)) ('down dy) ('up (- dy))))
               (side (abs (if (memq direction '(left right)) dy dx))))
          (when (> main 0)
            (let ((s (+ main (* 2 side))))
              (when (or (null score) (< s score)) (setq best it score s)))))))
    best))

;;;; State

(defvar drgnx-switcher--state nil
  "While open: (:items ITEMS :origin WINDOW :current ITEM :ready BOOL :overlays OVS :cards CARDS).")

(defvar drgnx-switcher--pool nil "The pooled card frames, (FRAME . BUFFER) each, at most `drgnx-switcher-cards-max'.")

(defun drgnx-switcher-open-p () (and drgnx-switcher--state t))

(defun drgnx-switcher--reduced-p () (eq (bound-and-true-p drgnx-look-motion) 'reduced))

;;;; Cards

(defun drgnx-switcher--card-params (parent)
  "A card's frame parameters under PARENT: no focus, popup chrome, invisible until placed."
  (let ((chrome (and (featurep 'glitnir) (fboundp 'drgnx-look-chrome-current) (drgnx-look-chrome-current))))
    `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-switcher-card") (drgnx-switcher-card . t)
      (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t) (no-other-frame . t) (skip-taskbar . t)
      (unsplittable . t) (no-special-glyphs . t) (desktop-dont-save . t) (border-width . 0)
      (internal-border-width . ,(drgnx-px 8 parent))
      (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0) (left-fringe . 0) (right-fringe . 0)
      (vertical-scroll-bars) (horizontal-scroll-bars) (cursor-type . nil) (visibility . nil)
      ,@chrome)))

(defun drgnx-switcher--slot (i parent)
  "Pooled card number I under PARENT, made on first use."
  (let ((entry (nth i drgnx-switcher--pool)))
    (unless (and entry (frame-live-p (car entry)))
      (let* ((buf (get-buffer-create (format " *drgnx-switcher-%d*" i)))
             (frame (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                      (make-frame (drgnx-switcher--card-params parent)))))
        (with-current-buffer buf
          (setq-local indent-tabs-mode nil cursor-type nil mode-line-format nil header-line-format nil tab-line-format nil
                      cursor-in-non-selected-windows nil truncate-lines t))
        (set-window-buffer (frame-root-window frame) buf)
        (set-window-dedicated-p (frame-root-window frame) t)
        (setq entry (cons frame buf))
        (if (< i (length drgnx-switcher--pool)) (setf (nth i drgnx-switcher--pool) entry)
          (setq drgnx-switcher--pool (append drgnx-switcher--pool (list entry))))))
    (unless (eq (frame-parent (car entry)) parent) (set-frame-parameter (car entry) 'parent-frame parent))
    entry))

(defun drgnx-switcher--several-monitors-p (items)
  (cdr (delete-dups (mapcar (lambda (it) (plist-get it :monitor)) items))))

(defun drgnx-switcher--card-text (it monitors highlighted)
  "The text of IT's card: its letter large, its title (and with MONITORS, its monitor) under it."
  (let* ((f (plist-get it :frame))
         (height (max 1.0 (/ (float (drgnx-px drgnx-switcher-letter-px f)) (frame-char-height f))))
         (title (if (and monitors (plist-get it :monitor)) (format "%s · %s" (plist-get it :title) (plist-get it :monitor))
                  (plist-get it :title))))
    (concat (propertize (string (plist-get it :letter)) 'face `(:inherit ,(if highlighted '(highlight bold) 'bold) :height ,height))
            "\n" (propertize title 'face (if highlighted 'highlight 'shadow)))))

(defun drgnx-switcher--fill-card (entry it monitors highlighted)
  "Card ENTRY shows IT, centred on its tile."
  (pcase-let ((`(,frame . ,buf) entry))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (drgnx-switcher--card-text it monitors highlighted))
        (goto-char (point-min))
        (center-region (point-min) (point-max))))
    (let ((window-min-height 1) (window-min-width 1))
      (fit-frame-to-buffer frame))
    (let* ((e (plist-get it :local))
           (x (- (/ (+ (nth 0 e) (nth 2 e)) 2) (/ (frame-pixel-width frame) 2)))
           (y (- (/ (+ (nth 1 e) (nth 3 e)) 2) (/ (frame-pixel-height frame) 2))))
      (set-frame-position frame (max 0 x) (max 0 y)))
    (unless (frame-visible-p frame) (make-frame-visible frame))))

(defun drgnx-switcher--hide-cards ()
  (dolist (e drgnx-switcher--pool)
    (when (and (frame-live-p (car e)) (frame-visible-p (car e))) (make-frame-invisible (car e)))))

(defun drgnx-switcher-delete-pool ()
  "Delete the pooled card frames and their buffers."
  (dolist (e drgnx-switcher--pool)
    (when (frame-live-p (car e)) (delete-frame (car e) t))
    (when (buffer-live-p (cdr e)) (kill-buffer (cdr e))))
  (setq drgnx-switcher--pool nil))

;;;; Overlay letters

(defun drgnx-switcher--overlay (it highlighted)
  "IT's letter in inverse video at its window's start, the height of the text."
  (let* ((w (plist-get it :window)) (b (window-buffer w))
         (ov (make-overlay (window-start w) (window-start w) b)))
    (overlay-put ov 'window w)
    (overlay-put ov 'priority 1000)
    (overlay-put ov 'before-string (propertize (string (plist-get it :letter))
                                               'face (if highlighted '(:inherit highlight :inverse-video t)
                                                       '(:inverse-video t))))
    ov))

;;;; Drawing

(defun drgnx-switcher--draw ()
  "Show the state's cards and overlay letters, the current item highlighted."
  (let* ((st drgnx-switcher--state) (items (plist-get st :items)) (cur (plist-get st :current))
         (cards (drgnx-switcher-cards (seq-filter (lambda (it) (plist-get it :letter)) items)))
         (monitors (drgnx-switcher--several-monitors-p items)) (i 0))
    (mapc #'delete-overlay (plist-get st :overlays))
    (plist-put st :overlays nil)
    (dolist (it items)
      (when (plist-get it :letter)
        (if (memq it cards)
            (progn (drgnx-switcher--fill-card (drgnx-switcher--slot i (plist-get it :frame)) it monitors (eq it cur))
                   (setq i (1+ i)))
          (plist-put st :overlays (cons (drgnx-switcher--overlay it (eq it cur)) (plist-get st :overlays))))))
    (dolist (e (nthcdr i drgnx-switcher--pool))
      (when (and (frame-live-p (car e)) (frame-visible-p (car e))) (make-frame-invisible (car e))))
    (plist-put st :cards cards)))

;;;; Open, keys, close

(defvar drgnx-switcher-map (list 'keymap (cons t #'drgnx-switcher-key))
  "While the switcher is open every key goes to `drgnx-switcher-key'.")

(defun drgnx-switcher--ready ()
  "The pop-in is over: letters count."
  (when drgnx-switcher--state (plist-put drgnx-switcher--state :ready t)))

(defun drgnx-switcher-open ()
  "Switch Tile: a letter on every tile of every window; a letter picks (see the Commentary)."
  (interactive)
  (drgnx-switcher-close)
  (let* ((items (drgnx-switcher-items)) (origin (drgnx-grid-tile-main (selected-window))))
    (setq drgnx-switcher--state (list :items items :origin origin :ready nil :overlays nil :cards nil
                                      :current (seq-find (lambda (it) (eq (plist-get it :window) origin)) items)))
    (drgnx-switcher--draw)
    (drgnx-timer-start '(switcher . ready) (if (drgnx-switcher--reduced-p) drgnx-switcher-one-frame drgnx-switcher-pop-in)
                       #'drgnx-switcher--ready :owner 'ui/tiles)
    (plist-put drgnx-switcher--state :exit (set-transient-map drgnx-switcher-map #'drgnx-switcher-open-p))
    items))

(defun drgnx-switcher-close ()
  "Close the switcher: cards hidden (kept in the pool), letters gone, its timer cancelled."
  (when-let* ((st drgnx-switcher--state))
    (mapc #'delete-overlay (plist-get st :overlays))
    (setq drgnx-switcher--state nil)
    (when-let* ((exit (plist-get st :exit))) (funcall exit)))
  (drgnx-timer-cancel '(switcher . ready))
  (drgnx-switcher--hide-cards))

(defun drgnx-switcher--by-letter (c)
  (seq-find (lambda (it) (eql (plist-get it :letter) c)) (plist-get drgnx-switcher--state :items)))

(defun drgnx-switcher--pick (it)
  "Select IT's tile, its window selected first when it is another (no window moves)."
  (let ((w (plist-get it :window)))
    (drgnx-switcher-close)
    (when (window-live-p w)
      (unless (eq (window-frame w) (selected-frame)) (select-frame-set-input-focus (window-frame w)))
      (select-window w))
    w))

(defun drgnx-switcher--replay (event)
  "Close and give EVENT back to the command loop (the tile you were in reads it)."
  (drgnx-switcher-close)
  (setq unread-command-events (append unread-command-events (list event)))
  'replayed)

(defun drgnx-switcher-handle (event)
  "What the open switcher does with EVENT: `closed', `picked', `swapped', `moved' or `replayed'."
  (let* ((st drgnx-switcher--state) (ready (plist-get st :ready))
         (base (if (characterp event) event (event-basic-type event)))
         (lower (and (characterp event) (drgnx-switcher--by-letter event)))
         (upper (and (characterp event) (/= event (downcase event)) (drgnx-switcher--by-letter (downcase event)))))
    (cond
     ((null st) nil)
     ((memq event '(?\e escape)) (drgnx-switcher-close) 'closed)
     ((memq base '(left right up down))
      (when-let* ((n (drgnx-switcher-neighbour (plist-get st :items) (plist-get st :current) base)))
        (plist-put st :current n)
        (drgnx-switcher--draw))
      'moved)
     ((memq event '(?\r return)) (if (plist-get st :current) (progn (drgnx-switcher--pick (plist-get st :current)) 'picked)
                                   (drgnx-switcher-close) 'closed))
     ((and lower ready) (drgnx-switcher--pick lower) 'picked)
     ((and upper ready)
      (let ((origin (plist-get st :origin)) (target (plist-get upper :window)))
        (drgnx-switcher-close)
        (if (eq (window-frame origin) (window-frame target))
            (progn (drgnx-grid-swap origin target) 'swapped)
          (message "Swap Tile works inside one window")
          'closed)))
     (t (drgnx-switcher--replay event)))))

(defun drgnx-switcher-key ()
  "A key while the switcher is open (`drgnx-switcher-handle')."
  (interactive)
  (drgnx-switcher-handle last-input-event))

(provide 'drgnx-switcher)
;;; drgnx-switcher.el ends here
