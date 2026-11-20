;;; drgnx-rail.el --- The layout A rail: seven places, one click to each -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The rail (the-look/frontend/sidebars.html option A): a 44 px column of place buttons on the frame's left edge, beside
;; the side bar, always there (a frame's `drgnx-rail' parameter `hidden' drops it).  It is a real left side window,
;; outside the grid (`drgnx-grid-root' is the root less the side windows), so it exists under the grid backend
;; (`drgnx-pane-backend' `grid', the default); under the old side-window backend the dock is itself left side windows
;; and a second one would stack above them, so the rail stays away.  The status bar splits the frame's root, so it
;; spans the frame below the rail.  Each place is a kit `rail-item' (core/drgnx-ui-kit.el): its icon in a 32 px square,
;; the current place on the quiet selection, a warn dot when something changed there.
;;
;; A place's command (`place-work', `place-files', ...) shows the place's view in the side bar; on the current place
;; it hides the side bar instead (a second click closes what the first opened).  Work, Machines and Extensions are
;; not side bar views: their command opens the place in the editor area, and the rail marks it current until another
;; place is chosen.  See docs/guide/look.md ("The rail").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-ui-kit)
(require 'drgnx-pixels)
(require 'drgnx-frame-kind)

(defvar drgnx-rules--placing)             ; wb/drgnx-rules.el: a side window we mean is not rerouted
(defvar drgnx-pane-backend)
(defvar drgnx-pane-place-view-function)
(defvar drgnx-git-changed-functions)
(defvar drgnx-extensions-jobs-done-functions)
(defvar drgnx-hub-event-functions)
(defvar compilation-finish-functions)
(declare-function drgnx-wb-sidebar-showing-p "drgnx-wb" (&optional frame))
(declare-function drgnx-wb-sidebar-view "drgnx-wb" (&optional frame))
(declare-function drgnx-wb-show-view "drgnx-wb" (view))
(declare-function drgnx-shell-set "drgnx-frame-shell" (frame key value))
(declare-function drgnx-shell-get "drgnx-frame-shell" (frame key))
(declare-function drgnx-shell-right-for "drgnx-frame-shell" (place))
(declare-function drgnx-pane-show "drgnx-panes")
(declare-function drgnx-wb-hide-sidebar "drgnx-wb" ())
(declare-function drgnx-wb-grid-p "drgnx-wb" ())
(declare-function drgnx-command-define "drgnx-registry")
(declare-function drgnx-state-subscribe "drgnx-state")
(declare-function drgnx-state-unsubscribe "drgnx-state")
(declare-function drgnx-ui-kit-run "drgnx-ui-kit" (action))

(defconst drgnx-rail-places
  '((work "Work" workflow place-work)
    (files "Files" folder place-files)
    (search "Search" search place-search)
    (changes "Changes" git-branch place-changes)
    (run "Run" play place-run)
    (machines "Machines" server place-machines)
    (extensions "Extensions" blocks place-extensions))
  "The rail's places, in order: (ID TITLE ICON COMMAND).  ICON is a name of etc/icons, COMMAND the registry id that goes
to the place (`drgnx-rail-go').")

(defconst drgnx-rail--targets
  '((work nil work-view)
    (files explorer view-explorer)
    (search search view-search)
    (changes scm scm-view)
    (run debug nil)
    (machines nil runners)
    (extensions nil extensions-open))
  "What each place goes to: (ID VIEW COMMAND).  A VIEW is a side bar view (`drgnx-wb-show-view'): the place is current
while the side bar shows it.  COMMAND is the registry command that shows the place (nil: just the view).")

(defconst drgnx-rail-width 44 "The rail's width, logical px (sidebars.html `.rail').")
(defconst drgnx-rail-gap 6 "The gap between two items and above the first, logical px.")

(defconst drgnx-rail-buffer-prefix " *drgnx: Rail" "The start of a rail's buffer name: one buffer a frame, its text is the frame's.")

(defvar drgnx-rail--buffers (make-hash-table :test #'eq :weakness 'key)
  "Frame → its rail buffer: weak on the frame, emptied when the mode goes off.")

(defvar drgnx-rail--changed nil "The places with a dot: places (IDs) something changed in since they were last shown.")

;;;; Which place is current, which changed

(defun drgnx-rail-current (&optional frame)
  "The place that is current on FRAME (nil: the selected one): the one last chosen that is no side bar view, else the
place of the view the side bar shows."
  (or (frame-parameter frame 'drgnx-rail-place)
      (and (drgnx-wb-sidebar-showing-p frame)
           (let ((view (drgnx-wb-sidebar-view frame)))
             (car (seq-find (lambda (tg) (eq (nth 1 tg) view)) drgnx-rail--targets))))))

(defun drgnx-rail-mark-changed (place)
  "Put a dot on PLACE: something changed there (the producers of step 6 call this)."
  (unless (memq place drgnx-rail--changed)
    (push place drgnx-rail--changed)
    (drgnx-rail-refresh)))

(defun drgnx-rail-clear-changed (place)
  "Take the dot off PLACE."
  (when (memq place drgnx-rail--changed)
    (setq drgnx-rail--changed (delq place drgnx-rail--changed))
    (drgnx-rail-refresh)))

(defun drgnx-rail-places ()
  "The rail's place ids, in order (the variable `drgnx-rail-places' has their titles, icons and commands)."
  (mapcar #'car drgnx-rail-places))

(defun drgnx-rail-changed-p (place &optional _frame)
  "Non-nil when PLACE has its dot: something changed there since it was last shown."
  (and (memq place drgnx-rail--changed) t))

;;;; Each place's own signal

(defun drgnx-rail--hub-event (event _data)
  "A `drgnx-hub-event-functions' handler: the hub's search, machines and debug events dot their places."
  (pcase event
    ("search-run-done" (drgnx-rail-mark-changed 'search))
    ("machines-changed" (drgnx-rail-mark-changed 'machines))
    ("debug-ended" (drgnx-rail-mark-changed 'run))))

(defun drgnx-rail--files-changed () "A visited file changed on disk and was read again." (drgnx-rail-mark-changed 'files))
(defun drgnx-rail--git-changed (&rest _) "A repository's status was read." (drgnx-rail-mark-changed 'changes))
(defun drgnx-rail--run-ended (&rest _) "A compilation or run ended." (drgnx-rail-mark-changed 'run))
(defun drgnx-rail--extensions-done (&rest _) "An Extensions job ended." (drgnx-rail-mark-changed 'extensions))

(defconst drgnx-rail--signals
  '((after-revert-hook . drgnx-rail--files-changed)
    (drgnx-git-changed-functions . drgnx-rail--git-changed)
    (compilation-finish-functions . drgnx-rail--run-ended)
    (drgnx-extensions-jobs-done-functions . drgnx-rail--extensions-done)
    (drgnx-hub-event-functions . drgnx-rail--hub-event))
  "(HOOK . FUNCTION): the signals that put a dot on a place, hooked while the rail is on.  Work has none: its own
needs-you count is its signal.")

(defun drgnx-rail-producers ()
  "Each place but Work with a function that gives it its dot (`drgnx-shell-changed-producers')."
  (list (cons 'files #'drgnx-rail--files-changed)
        (cons 'search (lambda () (drgnx-rail--hub-event "search-run-done" nil)))
        (cons 'changes #'drgnx-rail--git-changed)
        (cons 'run #'drgnx-rail--run-ended)
        (cons 'machines (lambda () (drgnx-rail--hub-event "machines-changed" nil)))
        (cons 'extensions #'drgnx-rail--extensions-done)))

(defun drgnx-rail--show-place-view (place)
  "Show PLACE's view in the side bar, or run its command (`drgnx-pane-place-view-function')."
  (pcase-let ((`(,_ ,view ,command) (assq place drgnx-rail--targets)))
    (set-frame-parameter nil 'drgnx-rail-place (and (not view) place))
    (cond (command (drgnx-ui-kit-run command))
          (view (drgnx-wb-show-view view)))
    (drgnx-rail-clear-changed place)))

;;;; Going to a place

(defun drgnx-rail-go (place)
  "Go to PLACE: show its view in the side bar (or open it in the editor area), and take its dot off.  On the current
place with its view in the side bar, hide the side bar instead."
  (let* ((target (or (assq place drgnx-rail--targets) (user-error "No place %s" place)))
         (view (nth 1 target)) (command (nth 2 target)))
    (if (and view (eq place (drgnx-rail-current)) (drgnx-wb-sidebar-showing-p))
        (drgnx-wb-hide-sidebar)
      (set-frame-parameter nil 'drgnx-rail-place (and (not view) place))
      (cond (command (drgnx-ui-kit-run command))
            (view (drgnx-wb-show-view view)))
      ;; the grid's shell: the place also sets the right side (Work's Detail, else the Agents side)
      (when (and (eq (bound-and-true-p drgnx-pane-backend) 'grid) (fboundp 'drgnx-shell-set))
        (drgnx-shell-set nil :place place)
        (when (drgnx-shell-get nil :right) (drgnx-pane-show (drgnx-shell-right-for place)))))
    (drgnx-rail-clear-changed place)
    (drgnx-rail-refresh)
    place))

(defmacro drgnx-rail--define-go (id)
  "Define `drgnx-rail-place-ID', the command that goes to place ID."
  (let ((name (intern (format "drgnx-rail-place-%s" id))))
    `(defun ,name ()
       ,(format "Go to the %s place of the rail (`drgnx-rail-go')." id)
       (interactive)
       (drgnx-rail-go ',id))))

(drgnx-rail--define-go work)
(drgnx-rail--define-go files)
(drgnx-rail--define-go search)
(drgnx-rail--define-go changes)
(drgnx-rail--define-go run)
(drgnx-rail--define-go machines)
(drgnx-rail--define-go extensions)

(defun drgnx-rail-define-commands ()
  "The place commands (`place-work' ... `place-extensions'), in the registry."
  (pcase-dolist (`(,id ,title ,_icon ,command) drgnx-rail-places)
    (drgnx-command-define command :category "View" :title (format "Go to %s" title) :scope 'window
                          :command (intern (format "drgnx-rail-place-%s" id))
                          :doc (format "Show %s: its view in the side bar; on the current place the side bar hides" title))))

;;;; The window

(defun drgnx-rail-window (&optional frame)
  "FRAME's rail window, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-role) 'rail)) (window-list frame 'nomini)))

(defun drgnx-rail--buffer (frame)
  "FRAME's rail buffer, made once (kept in `drgnx-rail--buffers'): a frame's own text, since two frames
differ in scale and in the current place."
  (let ((kept (gethash frame drgnx-rail--buffers)))
    (if (buffer-live-p kept)
        kept
      (with-current-buffer (generate-new-buffer (concat drgnx-rail-buffer-prefix "*"))
        (setq-local cursor-type nil cursor-in-non-selected-windows nil truncate-lines t mode-line-format nil
                    header-line-format nil tab-line-format nil buffer-read-only t window-size-fixed 'width
                    show-trailing-whitespace nil
                    ;; a line ends in a space of the default face's width (the room for the cursor): a character wide
                    ;; past the cell's 38 px, which the 44 px window cannot hold, and a line that does not fit is cut
                    ;; off and ends in `$' over the cell's right edge.  The rail holds pictures and spaces only: its
                    ;; default face is as small as a face gets, and the line fits.
                    face-remapping-alist '((default (:height 10))))
        (buffer-disable-undo)
        (puthash frame (current-buffer) drgnx-rail--buffers)
        (current-buffer)))))

(defun drgnx-rail--gap-line (px)
  "A line PX device px tall of nothing: a space of that height on a font too small to make the line taller."
  (concat (propertize " " 'face '(:height 10) 'display `(space :width 0.1 :height (,px)))
          (propertize "\n" 'face '(:height 10))))

(defun drgnx-rail--tall (item height frame)
  "ITEM (a kit rail item) with its cell's first pad HEIGHT device px tall, the text centred in it: the cell's fill fills
the whole line, so the cell is as tall as its row.  `line-height' and `line-spacing' on the newline do not reach a
line that holds an image.  The accent bar and the dot, pictures HEIGHT tall, are centred the same way (the kit leaves
only the descent below them, for a row with a line height of its own: here the lines have none, and a picture that
did not agree with the first pad would make the line taller)."
  (let* ((extent (drgnx-pixels-font-extent 'drgnx-kit-rail-item frame)))
    (when (and extent (> height (+ (car extent) (cdr extent))))
      (let* ((below (+ (cdr extent) (/ (- height (car extent) (cdr extent)) 2)))
             (percent (min 100 (ceiling (* 100.0 (- height below)) height))))
        (dotimes (i (length item))
          (let ((disp (get-text-property i 'display item)))
            (cond ((and (= i 1) (eq (car-safe disp) 'space))
                   (put-text-property i (1+ i) 'display
                                      `(space :width ,(plist-get (cdr disp) :width) :height (,height) :ascent ,percent)
                                      item))
                  ((and (eq (car-safe disp) 'image) (numberp (plist-get (cdr disp) :ascent)))
                   (put-text-property i (1+ i) 'display
                                      (cons 'image (plist-put (copy-sequence (cdr disp)) :ascent percent))
                                      item)))))))
    item))

(defun drgnx-rail--pixel-pads (item frame)
  "ITEM (a kit rail item built for buffer text) with each pad a width in device px.  The kit's text-mode pad is a width
in FRAME's canonical characters, drawn in the window's own font: where that font is larger than the frame's, the cell is
wider than its 44 px and its line past the window's edge."
  (let ((cw (frame-char-width frame)))
    (dotimes (i (length item))
      (let ((d (get-text-property i 'display item)))
        (when (and (eq (car-safe d) 'space) (floatp (plist-get (cdr d) :width)))
          (put-text-property i (1+ i) 'display
                             `(space ,@(plist-put (copy-sequence (cdr d)) :width
                                                  (list (round (* cw (plist-get (cdr d) :width))))))
                             item))))
    item))

(defun drgnx-rail--string (frame)
  "The rail's text on FRAME: a gap, then each place's item on a line of its own height and a gap after it."
  (let* ((gui (display-graphic-p frame)) (current (drgnx-rail-current frame))
         (geom (plist-get (drgnx-ui-kit-component 'rail-item) :geometry))
         (height (and gui (drgnx-px (plist-get geom :height) frame)))
         (gap (and gui (drgnx-px drgnx-rail-gap frame)))
         (lines (and gui (list (drgnx-rail--gap-line gap)))))
    (dolist (p drgnx-rail-places)
      (let ((item (drgnx-ui-kit-rail-item (nth 0 p) (nth 2 p) (nth 1 p)
                                          (if (eq (nth 0 p) current) 'selected 'rest)
                                          (and (memq (nth 0 p) drgnx-rail--changed) t)
                                          'text frame (nth 3 p))))
        ;; the item without its last character, the surface's inset after the cell: the line is 38 px, not the window's
        ;; 44, so its end (see `drgnx-rail--buffer') fits
        (push (concat (if gui (substring (drgnx-rail--tall (drgnx-rail--pixel-pads item frame) height frame) 0 -1) item) "\n") lines)
        (when gui (push (drgnx-rail--gap-line gap) lines))))
    (apply #'concat (nreverse lines))))

(defun drgnx-rail--draw (s)
  "Make the current buffer's text S, nothing erased: the characters by `replace-region-contents' (only what differs
changes), then S's properties (a scale change moves only those) over them."
  (let ((inhibit-read-only t) (pos 0) (n (length s)))
    (replace-region-contents (point-min) (point-max) s)
    (set-text-properties (point-min) (point-max) nil)
    (while (< pos n)
      (let ((next (or (next-property-change pos s) n)))
        (set-text-properties (1+ pos) (1+ next) (text-properties-at pos s))
        (setq pos next)))))

(defun drgnx-rail-refresh ()
  "Draw the rail again on every frame that has one, when what it shows changed."
  (dolist (f (frame-list))
    (when-let* ((w (drgnx-rail-window f)))
      (let ((s (drgnx-rail--string f)))
        (with-current-buffer (window-buffer w)
          (unless (equal-including-properties s (buffer-string))
            (drgnx-rail--draw s)))))))

(defun drgnx-rail--wanted-p (frame)
  "Non-nil when FRAME gets the rail: a workbench frame on the grid backend, its `drgnx-rail' parameter not `hidden'."
  (and (frame-live-p frame) (drgnx-state-workbench-frame-p frame) (not (frame-parent frame))
       (not (eq (frame-parameter frame 'drgnx-rail) 'hidden))
       (with-selected-frame frame (drgnx-wb-grid-p))))

(defun drgnx-rail--fit (window)
  "WINDOW's text area as wide as the rail is (the rail's 44 px: its items' width), in px on a graphical frame, in
columns on a terminal, and kept so.  The window is wider by what Emacs puts round the text (the divider that is the gap
between cards)."
  (let ((frame (window-frame window)))
    (if (display-graphic-p frame)
        (let* ((want (drgnx-px drgnx-rail-width frame)) (have (window-body-width window t)) (window-resize-pixelwise t))
          (unless (= want have) (ignore-errors (window-resize window (- want have) t t t))))
      (let ((want 3) (have (window-body-width window)))
        (unless (= want have) (ignore-errors (window-resize window (- want have) t t)))))
    (window-preserve-size window t t)))

(defun drgnx-rail--ensure (frame)
  "FRAME has its rail window when it should, once, and none when it should not."
  (when (frame-live-p frame)
    (let ((w (drgnx-rail-window frame)))
      (cond
       ((drgnx-rail--wanted-p frame)
        (unless w
          (setq w (with-selected-frame frame
                    (let ((drgnx-rules--placing t) (display-buffer-alist nil))
                      (display-buffer-in-side-window
                       (drgnx-rail--buffer frame)
                       `((side . left) (slot . -1) (window-width . 3) (dedicated . t)
                         (window-parameters . ((drgnx-role . rail) (no-other-window . t) (no-delete-other-windows . t)
                                               (mode-line-format . none) (header-line-format . none)
                                               (tab-line-format . none))))))))
          (when (window-live-p w)
            (set-window-fringes w 0 0)
            (set-window-margins w 0 0)
            (set-window-scroll-bars w nil nil nil nil t)))
        (when (window-live-p w)
          (drgnx-rail--fit w)
          (drgnx-rail-refresh)))
       (w (let ((ignore-window-parameters t)) (ignore-errors (delete-window w))))))))

(defun drgnx-rail--windows-changed (data)
  "The store's `windows-changed' (idle) and `frame-added': the frame's rail is as it should be."
  (drgnx-rail--ensure (or (plist-get data :frame) (selected-frame))))

;; The UI scale or the density changed: the rail's width and its rows are in device px, made again.
(defvar drgnx-look-density-changed-hook)

(defun drgnx-rail--scale-changed ()
  "`drgnx-look-density-changed-hook': every frame's rail is as wide and as tall as the new scale says."
  (drgnx-rail--apply))

(defun drgnx-rail--apply ()
  "Every frame gets, keeps or loses its rail."
  (dolist (f (frame-list)) (drgnx-rail--ensure f)))

;;;; The mode

(define-minor-mode drgnx-rail-mode
  "The layout A rail on every workbench frame (a frame's `drgnx-rail' parameter `hidden' drops it)."
  :global t :group 'drgnx-look
  (if drgnx-rail-mode
      (progn
        (drgnx-state-subscribe 'windows-changed #'drgnx-rail--windows-changed)
        (drgnx-state-subscribe 'frame-added #'drgnx-rail--windows-changed)
        (add-hook 'drgnx-look-density-changed-hook #'drgnx-rail--scale-changed)
        (pcase-dolist (`(,hook . ,fn) drgnx-rail--signals) (add-hook hook fn))
        (setq drgnx-pane-place-view-function #'drgnx-rail--show-place-view)
        (drgnx-rail--apply))
    (drgnx-state-unsubscribe 'windows-changed #'drgnx-rail--windows-changed)
    (drgnx-state-unsubscribe 'frame-added #'drgnx-rail--windows-changed)
    (remove-hook 'drgnx-look-density-changed-hook #'drgnx-rail--scale-changed)
    (pcase-dolist (`(,hook . ,fn) drgnx-rail--signals) (remove-hook hook fn))
    (when (eq drgnx-pane-place-view-function #'drgnx-rail--show-place-view)
      (setq drgnx-pane-place-view-function nil))
    (dolist (f (frame-list))
      (when-let* ((w (drgnx-rail-window f)))
        (let ((ignore-window-parameters t)) (ignore-errors (delete-window w)))))
    (dolist (b (buffer-list))
      (when (string-prefix-p drgnx-rail-buffer-prefix (buffer-name b)) (kill-buffer b)))
    (clrhash drgnx-rail--buffers)
    (setq drgnx-rail--changed nil)))

(defun drgnx-rail-on ()
  "Turn the rail on (the look's setup)."
  (drgnx-rail-mode 1))

(defun drgnx-rail-off ()
  "Turn the rail off (the look's teardown)."
  (drgnx-rail-mode -1))

(provide 'drgnx-rail)
;;; drgnx-rail.el ends here
