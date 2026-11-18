;;; drgnx-monitors.el --- Move a window to another monitor: the commands and what the workbench knows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Move to Monitor… (a picker), Move to Next Monitor and Move to Previous Monitor (they wrap round) ask the
;; window-manager adapter (`drgnx-platform') to move the selected window.  A command never blocks: it says
;; "Moving…" and reports the adapter's answer in the echo area, in plain words.  Where the window manager does
;; not let an app move its windows (GNOME) the command says why and names the key that does.  The picker is
;; the one prompt, and only in a command you ran; it waits (at most the adapter's deadline) for the monitor
;; list, because a prompt can never be opened from a timer or a callback.
;;
;; The mode keeps what the workbench knows about the monitors: the frame parameter `drgnx-monitor' (the
;; monitor a window is on, absent where the adapter knows none: the window manager's monitor, with its name and
;; serial, even where the adapter answers with Emacs' geometry) and `drgnx-monitors--count'.  After a move the
;; monitor is the one moved to and the count is refreshed; both are refreshed asynchronously through one idle timer (1 s) when monitors are plugged or unplugged (once per burst, whatever
;; the last refresh) and when a window gains focus or is moved (at most once per window every 10 s; a refresh held back
;; by that limit is deferred, not dropped).  Replies of an older query never overwrite a newer one.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-platform)
(require 'drgnx-timer)
(require 'drgnx-state)

(defun drgnx-monitors--warn (text)
  "TEXT, something the monitor code could not do, as a `warn' event of source `wb' (never a prompt, never raised)."
  (drgnx-notify 'wb 'warn (concat "monitors: " text)))

(defvar drgnx-monitors--count nil
  "How many monitors the window manager lists, as of the last refresh (nil: not known yet).")

(defvar drgnx-monitors--pending nil "Frames waiting for the idle timer's refresh.")
(defvar drgnx-monitors--force nil
  "Non-nil when the pending refresh ignores `drgnx-monitors--min-interval' (monitors were plugged or unplugged).")
(defvar drgnx-monitors--list-gen 0 "Generation of the latest monitor-list query; an older reply is ignored.")

;; Per-frame state lives in weak tables, not in frame parameters: none of it can leak into a saved layout.
(defvar drgnx-monitors--stamps (make-hash-table :test #'eq :weakness 'key) "Frame -> time of its last refresh.")
(defvar drgnx-monitors--gens (make-hash-table :test #'eq :weakness 'key)
  "Frame -> generation of its latest monitor query; an older reply is ignored.")
(defvar drgnx-monitors--moving (make-hash-table :test #'eq :weakness 'key) "Frames with a move under way.")

(defconst drgnx-monitors--idle-delay 1 "Seconds of idle time before the pending frames are refreshed.")
(defconst drgnx-monitors--min-interval 10 "A frame is refreshed by the timer at most once in this many seconds.")

(defconst drgnx-monitors--only-one "Only one monitor: there is nowhere to move this window")

;;;; Which frames

(defun drgnx-monitors--eligible-p (frame)
  "FRAME is live, graphical and not a child frame (terminal frames are workbench frames too, but have no monitor)."
  (and (frame-live-p frame) (display-graphic-p frame) (not (frame-parent frame))))

(defun drgnx-monitors-available-p ()
  "The selected frame can be moved to a monitor: graphical, live, not a child frame."
  (drgnx-monitors--eligible-p (selected-frame)))

(defun drgnx-monitors--error-p (r) (and (consp r) (eq (car r) :error)))

(defun drgnx-monitors--later (fn) (run-at-time 0 nil fn))

;;;; Moving

(defun drgnx-monitors--reason (can)
  "CAN, a `drgnx-platform-can-move' refusal (REASON . FIX), as one sentence: \"REASON: FIX\"."
  (if (consp can)
      (if (cdr can) (format "%s: %s" (car can) (cdr can)) (car can))
    "drgnx cannot move this window"))

(defun drgnx-monitors--name (mon)
  "\"monitor N (NAME)\" for MON (a numbered monitor); without a name just \"monitor N\"."
  (let ((name (plist-get mon :name)))
    (if (and (stringp name) (not (string-empty-p name)))
        (format "monitor %d (%s)" (plist-get mon :number) name)
      (format "monitor %d" (plist-get mon :number)))))

(defun drgnx-monitors--target (target current monitors)
  "The monitor of MONITORS (numbered, sorted) TARGET names, or (:error MESSAGE).
TARGET is a number, `next' or `previous' (they wrap round from CURRENT, the monitor the window is on)."
  (let ((n (length monitors)))
    (cond ((integerp target)
           (or (seq-find (lambda (m) (eql (plist-get m :number) target)) monitors)
               (list :error (format "There is no monitor %d: there %s %d" target (if (= n 1) "is" "are") n))))
          ((not current) (list :error "Cannot tell which monitor this window is on"))
          (t (let ((i (1- (plist-get current :number))))
               (nth (mod (if (eq target 'next) (1+ i) (1- i)) n) monitors))))))

(defun drgnx-monitors--step (frame target monitors callback)
  "Second half of a move: MONITORS are known (two or more); find the current one, then move."
  (drgnx-platform-frame-monitor
   frame
   (lambda (seen)
     (let* ((current (and seen (drgnx-platform-match-monitor seen monitors)))
            (mon (drgnx-monitors--target target current monitors)))
       (cond ((drgnx-monitors--error-p mon) (funcall callback mon))
             ((and current (eql (plist-get current :number) (plist-get mon :number)))
              (funcall callback (list :ok (format "Already on %s" (drgnx-monitors--name mon)))))
             (t (drgnx-platform-move-frame
                 frame mon
                 (lambda (r)
                   (if (drgnx-monitors--error-p r)
                       (funcall callback r)
                     (when (frame-live-p frame)
                       ;; the window manager's monitor, with its name and serial; Emacs' own answer may still be
                       ;; the old monitor for a moment (the compositor's enter event comes later), so the frame is
                       ;; not asked again now: it counts as refreshed, and the next refresh waits the interval
                       (drgnx-monitors--set-monitor frame mon)
                       (puthash frame (float-time) drgnx-monitors--stamps)
                       (drgnx-monitors--fetch-count frame))
                     (funcall callback (list :ok (format "Moved to %s" (drgnx-monitors--name mon)))))))))))))

(defun drgnx-monitors--move (frame target callback &optional monitors can)
  "Move FRAME to TARGET (a monitor number, `next' or `previous').  CALLBACK, later, gets (:ok MESSAGE) or
\(:error MESSAGE).  MONITORS, when given, is the numbered list the caller has fetched; CAN the answer of
`drgnx-platform-can-move' the caller already has (asked here when nil).  A move already under way for FRAME is
not joined: the new one is refused.  Never signals."
  (if (gethash frame drgnx-monitors--moving)
      (drgnx-monitors--later
       (lambda () (funcall callback (list :error "A move of this window is already under way"))))
    (puthash frame t drgnx-monitors--moving)
    (let ((cb (lambda (r)
                (remhash frame drgnx-monitors--moving)
                (condition-case err (funcall callback r)
                  (error (drgnx-monitors--warn (error-message-string err)))))))
      (condition-case err
          (let ((can (or can (drgnx-platform-can-move frame))))
            (cond ((not (eq can t))
                   (drgnx-monitors--later (lambda () (funcall cb (list :error (drgnx-monitors--reason can))))))
                  (monitors
                   (drgnx-monitors--step frame target monitors cb))
                  (t (drgnx-platform-monitors
                      frame
                      (lambda (mons)
                        (cond ((drgnx-monitors--error-p mons) (funcall cb mons))
                              ((< (length mons) 2) (funcall cb (list :error drgnx-monitors--only-one)))
                              (t (drgnx-monitors--step frame target mons cb))))))))
        (error (drgnx-monitors--later
                (lambda () (funcall cb (list :error (format "Moving failed: %s" (error-message-string err)))))))))))

(defun drgnx-monitors-move (frame target &optional callback)
  "Move FRAME to TARGET: a monitor number, `next' or `previous' (they wrap round).
CALLBACK, called later, gets `ok' or (:error MESSAGE) (\"Moved to monitor 2 (DP-2)\" is the command's message).
Never signals and never blocks; FRAME's `drgnx-monitor' parameter is updated."
  (drgnx-monitors--move frame target
                        (lambda (r)
                          (when callback
                            (funcall callback (if (drgnx-monitors--error-p r) r 'ok))))))

;;;; Commands

(defun drgnx-monitors--show (r)
  "Say the result R of `drgnx-monitors--move' in the echo area."
  (message "%s" (cadr r)))

(defun drgnx-monitors--run (target)
  "The command body: move the selected window to TARGET, saying \"Moving…\" and then the result."
  (let* ((frame (selected-frame)) (can (drgnx-platform-can-move frame)))
    (if (not (eq can t))
        (message "%s" (drgnx-monitors--reason can))
      (message "Moving…")
      (drgnx-monitors--move frame target #'drgnx-monitors--show nil can))))

;;;###autoload
(defun drgnx-monitors-move-next ()
  "Move this window to the next monitor (from the last back to the first)."
  (interactive)
  (drgnx-monitors--run 'next))

;;;###autoload
(defun drgnx-monitors-move-previous ()
  "Move this window to the previous monitor (from the first to the last)."
  (interactive)
  (drgnx-monitors--run 'previous))

(defun drgnx-monitors--fetch-sync (frame)
  "FRAME's numbered monitors, or (:error MESSAGE).  Waits at most the adapter's deadline: only for the picker,
which is a prompt in a command the user ran (a prompt cannot be opened from a callback)."
  (let ((result nil)
        (deadline (+ (float-time) drgnx-platform-command-timeout drgnx-platform-watchdog-margin 0.5)))
    (drgnx-platform-monitors frame (lambda (r) (setq result (list r))))
    (while (and (not result) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (if result (car result) (list :error "The window manager did not answer"))))

(defun drgnx-monitors--table (labels)
  "A completion table over LABELS that keeps their order (monitor 1 first)."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity) (cycle-sort-function . identity))
      (complete-with-action action labels string pred))))

;;;###autoload
(defun drgnx-monitors-move-to ()
  "Move this window to a monitor you pick."
  (interactive)
  (let* ((frame (selected-frame)) (can (drgnx-platform-can-move frame)))
    (if (not (eq can t))
        (message "%s" (drgnx-monitors--reason can))
      (let ((mons (drgnx-monitors--fetch-sync frame)))
        (cond ((drgnx-monitors--error-p mons) (message "%s" (cadr mons)))
              ((< (length mons) 2) (message "%s" drgnx-monitors--only-one))
              (t (condition-case nil
                     (let* ((labels (mapcar (lambda (m) (plist-get m :label)) mons))
                            (pick (completing-read "Move window to monitor: " (drgnx-monitors--table labels) nil t))
                            (mon (seq-find (lambda (m) (equal (plist-get m :label) pick)) mons)))
                       (when mon
                         (message "Moving…")
                         (drgnx-monitors--move frame (plist-get mon :number) #'drgnx-monitors--show mons can)))
                   (quit (message "Move cancelled")))))))))

;;;; What the workbench knows

(defun drgnx-monitors--emacs-count (frame)
  "How many monitors Emacs itself sees from FRAME (nil when it cannot say)."
  (ignore-errors (length (display-monitor-attributes-list frame))))

(defun drgnx-monitors--write (frame monitor)
  "Set FRAME's parameter `drgnx-monitor' to MONITOR and let the store see it now (it compares the parameter only
when it observes the frame)."
  (set-frame-parameter frame 'drgnx-monitor monitor)
  (drgnx-state-sync frame))

(defun drgnx-monitors--set-monitor (frame monitor)
  "Record MONITOR (a plist, or nil: none known) as the monitor FRAME is on; older queries still in flight lose.
nil rather than a removed parameter: Emacs cannot delete a frame parameter, and `frame-parameter' reads both as nil."
  (puthash frame (1+ (gethash frame drgnx-monitors--gens 0)) drgnx-monitors--gens)
  (drgnx-monitors--write frame monitor))

(defun drgnx-monitors--anonymous-p (mon)
  "Non-nil when MON names no monitor: no name, make, model or serial (Emacs' own answer under pgtk)."
  (seq-every-p (lambda (k) (let ((v (plist-get mon k))) (or (null v) (equal v ""))))
               '(:name :make :model :serial)))

(defun drgnx-monitors--fetch-monitor (frame)
  "Ask the adapter which monitor FRAME is on; the answer is dropped when a newer query was started meanwhile.
An answer that names no monitor (Emacs' own geometry) is resolved against the window manager's list, so what is kept
and saved has the monitor's name, make, model and serial; while the frame stays on the monitor already known (the
same geometry), that one is kept as it is."
  (let ((gen (1+ (gethash frame drgnx-monitors--gens 0))))
    (puthash frame gen drgnx-monitors--gens)
    (puthash frame (float-time) drgnx-monitors--stamps)
    (cl-flet ((current-p () (and (frame-live-p frame) (eql gen (gethash frame drgnx-monitors--gens))))
              (geometry (m) (drgnx-platform--geometry m)))
      (drgnx-platform-frame-monitor
       frame (lambda (mon)
               (when (current-p)
                 (let ((old nil))
                   (cond ((or (null mon) (not (drgnx-monitors--anonymous-p mon)))
                          (drgnx-monitors--write frame mon))
                         ((and (consp (setq old (frame-parameter frame 'drgnx-monitor)))
                               (equal (geometry old) (geometry mon))))   ; still there: keep it
                         (t (drgnx-platform-monitors
                             frame (lambda (mons)
                                     (when (current-p)
                                       (drgnx-monitors--write
                                        frame
                                        (or (and (not (drgnx-monitors--error-p mons))
                                                 (seq-find (lambda (m) (equal (geometry m) (geometry mon))) mons))
                                            mon))))))))))))))

(defun drgnx-monitors--fetch-count (frame)
  "Ask the adapter how many monitors there are (Emacs' own count where it cannot list them); the answer is
dropped when a newer query was started meanwhile."
  (let ((gen (cl-incf drgnx-monitors--list-gen)))
    (drgnx-platform-monitors
     frame (lambda (r)
             (when (= gen drgnx-monitors--list-gen)
               (setq drgnx-monitors--count
                     (if (drgnx-monitors--error-p r) (drgnx-monitors--emacs-count frame) (length r))))))))

(defun drgnx-monitors-refresh (frame)
  "Update FRAME's parameter `drgnx-monitor' and `drgnx-monitors--count' from the adapter, asynchronously.
Where the adapter knows no monitor for FRAME the parameter is nil; where it cannot list monitors the count is
Emacs' own.  A terminal or child frame is left alone."
  (when (drgnx-monitors--eligible-p frame)
    (condition-case err
        (progn (drgnx-monitors--fetch-monitor frame)
               (drgnx-monitors--fetch-count frame))
      (error (drgnx-monitors--warn (error-message-string err))))))

(defun drgnx-monitors--arm (delay)
  "Have `drgnx-monitors--run-pending' run after DELAY seconds of idleness: one idle debounce for all frames."
  (drgnx-timer-debounce 'monitors-refresh delay #'drgnx-monitors--run-pending :idle t :owner :core))

(defun drgnx-monitors--run-pending ()
  "The idle timer's job.  Each pending frame not refreshed in the last `drgnx-monitors--min-interval' s (all of
them after a hot-plug) is refreshed, the monitor list being fetched once for all of them; the others are kept
and the timer is armed again for the time they have left."
  (drgnx-timer-cancel 'monitors-refresh)                ; harmless when it is the one running
  (let ((frames (seq-filter #'drgnx-monitors--eligible-p drgnx-monitors--pending))
        (force drgnx-monitors--force) (now (float-time)) due deferred (soonest nil))
    (setq drgnx-monitors--pending nil drgnx-monitors--force nil)
    (dolist (f frames)
      (let ((left (- drgnx-monitors--min-interval (- now (gethash f drgnx-monitors--stamps 0)))))
        (if (or force (<= left 0))
            (push f due)
          (push f deferred)
          (setq soonest (if soonest (min soonest left) left)))))
    (condition-case err
        (when due
          (dolist (f due) (drgnx-monitors--fetch-monitor f))
          (drgnx-monitors--fetch-count (car due)))
      (error (drgnx-monitors--warn (error-message-string err))))
    (when deferred
      (setq drgnx-monitors--pending deferred)
      (drgnx-monitors--arm (max drgnx-monitors--idle-delay soonest)))))

(defun drgnx-monitors--schedule-frames (frames &optional force)
  "Have FRAMES refreshed by the idle timer; FORCE: whatever their last refresh was."
  (dolist (f frames)
    (when (drgnx-monitors--eligible-p f) (cl-pushnew f drgnx-monitors--pending)))
  (when force (setq drgnx-monitors--force t))
  (when drgnx-monitors--pending (drgnx-monitors--arm drgnx-monitors--idle-delay)))

(defun drgnx-monitors--focus-changed (&rest _)
  "`after-focus-change-function': the frames that have focus may have changed monitor."
  (condition-case err
      (drgnx-monitors--schedule-frames
       (or (seq-filter (lambda (f) (and (drgnx-monitors--eligible-p f) (eq (frame-focus-state f) t))) (frame-list))
           (list (selected-frame))))
    (error (drgnx-monitors--warn (error-message-string err)))))

(defun drgnx-monitors--frame-moved (frame)
  "`move-frame-functions': FRAME was moved, maybe to another monitor."
  (drgnx-monitors--schedule-frames (list frame)))

(defun drgnx-monitors--monitors-changed (&rest _)
  "`display-monitors-changed-functions': a monitor was plugged or unplugged.  Refreshes, later and once per burst of
calls, and folds the windows of a monitor that went away (or brings back those of one that returned) once the burst
has settled (`drgnx-monitors--fold-watch')."
  (condition-case err
      (progn (drgnx-monitors--schedule-frames (frame-list) t)
             (drgnx-monitors--fold-watch))
    (error (drgnx-monitors--warn (error-message-string err)))))

;;;; Fold-in and return: the windows of a monitor that goes away
;; A monitor goes away: each auxiliary window on it folds into the main window.  Its place (FRAME-SNAP,
;; `drgnx-grid-snapshot') is kept under the monitor's key, its editors' buffers become tabs of the main window's editor
;; used last and its tool panes join the main window's docks; then it closes.  No buffer is killed and nothing asks.
;; The monitor returns: the window is made again from its place with its buffers as they are now, and the main window
;; gives back the tabs and panes the fold added.  The check runs a second after the last change of a burst
;; (`monitors-fold'), so a dock unplugged and plugged back folds nothing.  The folded windows are saved with the main
;; window (`:monitors-folded'); a saved window whose monitor is absent at a restore folds the same way.

(declare-function drgnx-grid-snapshot "drgnx-grid-frames" (&optional why))
(declare-function drgnx-grid-push "drgnx-grid-frames" (why &optional frame tree))
(declare-function drgnx-grid-restore "drgnx-grid-frames" (snap))
(declare-function drgnx-grid--frame-snapshot "drgnx-grid-frames" (frame))
(declare-function drgnx-grid--frame-snapshot-p "drgnx-grid-frames" (snap))
(declare-function drgnx-grid--snapshot-frames "drgnx-grid-frames" ())
(declare-function drgnx-grid--fold-buffers "drgnx-grid-frames" (buffers main))
(declare-function drgnx-grid-frame-id "drgnx-grid-frames" (frame))
(declare-function drgnx-grid--frame-by-id "drgnx-grid-frames" (id))
(declare-function drgnx-grid-tree-leaves "drgnx-grid-tree" (tree))
(declare-function drgnx-grid--named-buffer "drgnx-grid" (name))
(declare-function drgnx-grid--buffer-name "drgnx-grid" (b))
(declare-function drgnx-grid--tile-of "drgnx-grid" (kind frame))
(declare-function drgnx-grid-tiles "drgnx-grid" (&optional frame filter))
(declare-function drgnx-grid-show "drgnx-grid" (kind &rest args))
(declare-function drgnx-grid-hide "drgnx-grid" (kind))
(declare-function drgnx-grid--put-row "drgnx-grid" (window))
(declare-function drgnx-pane-kind "drgnx-panes" (kind))
(declare-function drgnx-frame-role "drgnx-frames" (&optional frame))
(declare-function drgnx-chrome-apply "drgnx-chrome" (&optional frame note))

(defvar drgnx-monitors--folded nil
  "The windows folded in, by monitor: ((KEY ENTRY…)…), KEY the monitor's identity (`drgnx-monitors--identity'), each
ENTRY (:snap FRAME-SNAP :tabs NAMES :kinds KINDS): the window's place, and the tabs (buffer names) and tool kinds the
fold added to the main window, given back on the return.  Saved with the main window (`:monitors-folded').")

(defvar drgnx-monitors--fold-seen nil
  "The auxiliary windows as they were when this burst of monitor changes began: ((FRAME KEY FRAME-SNAP)…).  The window
manager may move a window off a monitor that went away before the burst settles: its place is taken from here.")

(defun drgnx-monitors--present-p (key)
  "Non-nil when the monitor KEY names is connected: one of `display-monitor-attributes-list' has its name (else, for a
KEY without a name, its geometry)."
  (let ((name (plist-get key :name)) (geometry (plist-get key :geometry)))
    (seq-some (lambda (a) (if name (equal (alist-get 'name a) name)
                            (equal (alist-get 'geometry a) (if (vectorp geometry) (append geometry nil) geometry))))
              (ignore-errors (display-monitor-attributes-list)))))

(defun drgnx-monitors--frame-key (frame)
  "The identity of the monitor FRAME is on (its parameter `drgnx-monitor'), or nil when none is known."
  (let ((mon (frame-parameter frame 'drgnx-monitor)))
    (and (consp mon) (drgnx-monitors--identity mon))))

(defun drgnx-monitors--same-p (a b)
  "Non-nil when the monitor keys A and B name the same monitor: their names, when both have one, else their geometry."
  (if (and (plist-get a :name) (plist-get b :name)) (equal (plist-get a :name) (plist-get b :name))
    (equal (plist-get a :geometry) (plist-get b :geometry))))

(defun drgnx-monitors--aux-frames ()
  "The auxiliary workbench windows with a known monitor."
  (and (fboundp 'drgnx-grid--snapshot-frames)
       (seq-filter (lambda (f) (and (eq (drgnx-frame-role f) 'aux) (drgnx-monitors--frame-key f)))
                   (drgnx-grid--snapshot-frames))))

(defun drgnx-monitors--fold-watch ()
  "A monitor change: note where the auxiliary windows are, if this is the first change of a burst, and have the windows
folded or brought back after a second of idleness following the last one (`drgnx-monitors--fold-settle'; idle, as
the refresh is: it never runs in the middle of a command or a follow)."
  (unless drgnx-monitors--fold-seen
    (setq drgnx-monitors--fold-seen
          (mapcar (lambda (f) (list f (drgnx-monitors--frame-key f) (drgnx-grid--frame-snapshot f)))
                  (drgnx-monitors--aux-frames))))
  (drgnx-timer-debounce 'monitors-fold 1 #'drgnx-monitors--fold-settle :idle t :owner :core))

(defun drgnx-monitors--fold-settle ()
  "The monitors settled: fold the windows of each monitor that is gone, bring back those of each that returned."
  (drgnx-timer-cancel 'monitors-fold)
  (let ((seen drgnx-monitors--fold-seen))
    (setq drgnx-monitors--fold-seen nil)
    (condition-case err
        (progn
          (dolist (key (delete-dups (mapcar #'cadr seen)))
            (unless (drgnx-monitors--present-p key) (drgnx-monitors--fold key seen)))
          (dolist (e (copy-sequence drgnx-monitors--folded))
            (when (drgnx-monitors--present-p (car e)) (drgnx-monitors--unfold (car e)))))
      (error (drgnx-monitors--warn (error-message-string err))))))

(defun drgnx-monitors--main-frame ()
  (seq-find (lambda (f) (eq (drgnx-frame-role f) 'main)) (drgnx-grid--snapshot-frames)))

(defun drgnx-monitors--fold-in (snap main)
  "Show the window SNAP (a FRAME-SNAP) describes in MAIN: its editors' buffers as tabs of MAIN's editor used last, its
tool tiles' kinds on MAIN's docks.  The entry kept for the return: (:snap SNAP :tabs NAMES :kinds KINDS), the tabs and
kinds MAIN did not have."
  (let* ((leaves (drgnx-grid-tree-leaves (plist-get snap :tree)))
         (have (mapcar #'drgnx-grid--buffer-name
                       (mapcan (lambda (w) (cons (window-buffer w) (copy-sequence (window-parameter w 'drgnx-tabs))))
                               (drgnx-grid-tiles main 'editor))))
         (names nil) (kinds nil))
    (dolist (leaf leaves)
      (let ((p (cdr leaf)))
        (pcase (car leaf)
          ('editor (dolist (n (append (plist-get p :tabs) (list (plist-get p :shown))))
                     (when (and (stringp n) (drgnx-grid--named-buffer n) (not (member n have)) (not (member n names)))
                       (setq names (append names (list n))))))
          (_ (unless (or (plist-get (plist-get p :state) :area) (memq 'side-bar (plist-get p :kinds)))
               (dolist (k (plist-get p :kinds))
                 (when (and (symbolp k) (drgnx-pane-kind k) (not (drgnx-grid--tile-of k main)))
                   (push k kinds))))))))
    (drgnx-grid--fold-buffers (mapcar #'drgnx-grid--named-buffer names) main)
    (setq kinds (nreverse kinds))
    (with-selected-frame main
      (save-selected-window (dolist (k kinds) (drgnx-grid-show k))))
    (list :snap snap :tabs names :kinds kinds)))

(defun drgnx-monitors--keep (key entry)
  (setf (alist-get key drgnx-monitors--folded nil nil #'equal)
        (append (alist-get key drgnx-monitors--folded nil nil #'equal) (list entry))))

(defun drgnx-monitors--fold (key &optional seen)
  "Fold every auxiliary window on the monitor KEY into the main window (see the section's commentary), the layout
pushed first (`fold-in').  SEEN: where the windows were when the burst began (`drgnx-monitors--fold-seen')."
  (let* ((main (drgnx-monitors--main-frame))
         (frames (seq-filter (lambda (f) (and (frame-live-p f) (not (eq f main))
                                              (drgnx-monitors--same-p (or (cadr (assq f seen)) (drgnx-monitors--frame-key f)) key)))
                             (delete-dups (append (mapcar #'car seen) (drgnx-monitors--aux-frames))))))
    (when (and main frames)
      (drgnx-grid-push 'fold-in)
      (dolist (f frames)
        (let ((snap (or (nth 2 (assq f seen)) (drgnx-grid--frame-snapshot f))))
          (drgnx-monitors--keep key (drgnx-monitors--fold-in snap main))
          (delete-frame f t)))
      (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply main t)))))

(defun drgnx-monitors--fold-snap (snap main)
  "Fold the window SNAP describes, not made (a restore: its monitor is absent), into MAIN."
  (drgnx-monitors--keep (plist-get snap :monitor) (drgnx-monitors--fold-in snap main)))

(defun drgnx-monitors--give-back (entry main)
  "MAIN gives back the tabs and kinds ENTRY's fold added."
  (let ((names (plist-get entry :tabs)))
    (dolist (w (drgnx-grid-tiles main 'editor))
      (let ((tabs (seq-remove (lambda (b) (member (drgnx-grid--buffer-name b) names)) (window-parameter w 'drgnx-tabs))))
        (set-window-parameter w 'drgnx-tabs tabs)
        (when (and tabs (member (drgnx-grid--buffer-name (window-buffer w)) names))
          (set-window-buffer w (car tabs))))))
  (with-selected-frame main
    (save-selected-window
      (dolist (k (plist-get entry :kinds))
        (when-let* ((w (drgnx-grid--tile-of k main)))
          (if (eq (car (window-parameter w 'drgnx-pane-stack)) k) (drgnx-grid-hide k)
            (set-window-parameter w 'drgnx-pane-stack (remq k (window-parameter w 'drgnx-pane-stack)))
            (drgnx-grid--put-row w)))))))

(defun drgnx-monitors--unfold (key)
  "Bring back the windows folded in when the monitor KEY went away: each made again from its place, its buffers as
they are now; the main window gives back what the fold added."
  (when-let* ((entries (alist-get key drgnx-monitors--folded nil nil #'equal))
              (main (drgnx-monitors--main-frame)))
    (setq drgnx-monitors--folded (seq-remove (lambda (e) (equal (car e) key)) drgnx-monitors--folded))
    (dolist (e entries) (drgnx-monitors--give-back e main))
    (let ((snap (drgnx-grid-snapshot 'restore)))
      (plist-put snap :frames (append (plist-get snap :frames)
                                      (mapcar (lambda (e) (plist-get e :snap)) entries)))
      (save-selected-window (drgnx-grid-restore snap)))
    (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply main t))))

(defun drgnx-monitors--folded-p (data)
  "Non-nil when DATA (read from a saved workbench) is a list of folded windows as `drgnx-monitors--folded' holds."
  (and (proper-list-p data)
       (seq-every-p (lambda (e) (and (consp e) (proper-list-p (car e)) (proper-list-p (cdr e))
                                     (seq-every-p (lambda (x) (and (proper-list-p x)
                                                                   (drgnx-grid--frame-snapshot-p (plist-get x :snap))
                                                                   (seq-every-p #'stringp (plist-get x :tabs))
                                                                   (seq-every-p #'symbolp (plist-get x :kinds))))
                                                  (cdr e))))
                    data)))
;;;; Right-click menu

(defun drgnx-monitors--click-frame (click)
  (let ((w (and (mouse-event-p click) (ignore-errors (posn-window (event-start click))))))
    (cond ((windowp w) (window-frame w))
          ((framep w) w)
          (t (selected-frame)))))

(defun drgnx-monitors--context-p (click)
  "The `monitors' context: CLICK is in a graphical frame and more than one monitor is known."
  (let ((frame (drgnx-monitors--click-frame click)))
    (and (drgnx-monitors--eligible-p frame)
         (> (or drgnx-monitors--count (drgnx-monitors--emacs-count frame) 0) 1))))

;;;; Restore: auxiliary windows go back to their monitors
;; Saved through `drgnx-persist-state-functions' (the keys `:monitors-monitor' and `:monitors-fullscreen' of the
;; frame's extras) and put back from `drgnx-persist-after-restore-functions'.  This is an automatic path: the
;; restore returns at once, the adapter is asked later, every call has the restore deadline, and nothing prompts
;; or signals.  The frame parameter `drgnx-monitor' itself is neither saved nor restored (it is refreshed from the
;; window manager after the window is placed); the main window, `editor' windows and custom windows (job windows)
;; are never moved.

(defvar drgnx-persist-state-functions)
(defvar drgnx-persist-after-restore-functions)

(defvar drgnx-monitors--placed (make-hash-table :test #'eq :weakness 'key)
  "Restored frames whose monitor has been dealt with (placed, or found gone, or the attempt failed).")

(defconst drgnx-monitors--identity-keys '(:name :make :model :serial :geometry)
  "What of a monitor is saved: what `drgnx-platform-match-monitor' matches on, nothing numbered or derived.")

(defun drgnx-monitors--identity (monitor)
  "MONITOR (a plist) reduced to `drgnx-monitors--identity-keys', as a list that can be read back."
  (let (out)
    (dolist (k drgnx-monitors--identity-keys)
      (when-let* ((v (plist-get monitor k)))
        (setq out (append out (list k (if (vectorp v) (append v nil) v))))))
    out))

(defun drgnx-monitors--state ()
  "The selected frame's monitor and fullscreen state for `drgnx-persist-state-functions' (nothing when no monitor is
known), and in the main window the windows folded in (`:monitors-folded').  Reads frame parameters only: no
window-manager call while saving."
  (append (when-let* ((mon (frame-parameter nil 'drgnx-monitor)) ((consp mon))
                      (identity (drgnx-monitors--identity mon)))
            (list :monitors-monitor identity
                  :monitors-fullscreen (frame-parameter nil 'fullscreen)))
          (and drgnx-monitors--folded (eq (frame-parameter nil 'drgnx-frame-role) 'main)
               (list :monitors-folded (copy-tree drgnx-monitors--folded)))))

(defun drgnx-monitors--to-place ()
  "The restored auxiliary frames that have a saved monitor and were not dealt with yet, in the order they were made."
  (seq-filter (lambda (f)
                (and (drgnx-monitors--eligible-p f)
                     (eq (frame-parameter f 'drgnx-frame-role) 'aux)
                     (not (gethash f drgnx-monitors--placed))
                     (plist-get (frame-parameter f 'drgnx-persist-extra) :monitors-monitor)))
              (reverse (frame-list))))

(defun drgnx-monitors--saved (frame)
  (plist-get (frame-parameter frame 'drgnx-persist-extra) :monitors-monitor))

(defun drgnx-monitors--saved-name (saved)
  "A saved monitor as a person would call it: make and model, else its name, else its size and place."
  (let ((make (plist-get saved :make)) (model (plist-get saved :model)) (name (plist-get saved :name))
        (g (drgnx-platform--geometry saved)))
    (cond ((and (stringp make) (stringp model) (not (string-empty-p make)) (not (string-empty-p model)))
           (format "%s %s" make model))
          ((and (stringp name) (not (string-empty-p name))) name)
          (g (format "%d×%d at %d,%d" (nth 2 g) (nth 3 g) (nth 0 g) (nth 1 g)))
          (t "unknown monitor"))))

(defun drgnx-monitors--windows (n)
  (if (= n 1) "1 window" (format "%d windows" n)))

(defun drgnx-monitors--place-next (jobs)
  "Place the next of JOBS, a list of (FRAME MONITOR), then the rest: one at a time, as the adapters take the
focus for a moment.  The first failure ends it, said once."
  (when-let* ((job (car jobs)))
    (pcase-let ((`(,frame ,monitor) job))
      (if (not (frame-live-p frame))
          (drgnx-monitors--place-next (cdr jobs))
        (let ((fullscreen (plist-get (frame-parameter frame 'drgnx-persist-extra) :monitors-fullscreen)))
          (condition-case err
              (drgnx-platform-place-frame
               frame monitor
               (lambda (r)
                 (if (drgnx-monitors--error-p r)
                     (drgnx-monitors--warn (format "could not put %s back on their monitors (%s); the window manager placed them"
                                                   (drgnx-monitors--windows (length jobs)) (cadr r)))
                   (when (and fullscreen (frame-live-p frame))
                     (set-frame-parameter frame 'fullscreen fullscreen))
                   (drgnx-monitors--schedule-frames (list frame))
                   (drgnx-monitors--place-next (cdr jobs)))))
            (error (drgnx-monitors--warn (error-message-string err)))))))))

(defun drgnx-monitors--placing (frames monitors)
  "FRAMES, restored windows, are matched to MONITORS (the listing, or (:error MESSAGE)) and placed.  A window whose
monitor is not connected folds into the main window until it is (`drgnx-monitors--fold').  A window closed while the
listing was awaited is not counted."
  (setq frames (seq-filter #'frame-live-p frames))
  (when frames
    (if (drgnx-monitors--error-p monitors)
        (drgnx-monitors--warn (format "could not put %s back on their monitors (%s); the window manager placed them"
                                      (drgnx-monitors--windows (length frames)) (cadr monitors)))
      (let (jobs gone)
        (dolist (f frames)
          (let ((hit (drgnx-platform-match-monitor (drgnx-monitors--saved f) monitors)))
            (if hit (push (list f hit) jobs) (push f gone))))
        (when gone
          (drgnx-monitors--warn
           (format (if (cdr gone)
                       "%d windows' monitors are not connected (%s); their tabs are in the main window until they are"
                     "%d window's monitor is not connected (%s); its tabs are in the main window until it is")
                   (length gone)
                   (mapconcat #'identity
                              (delete-dups (mapcar (lambda (f) (drgnx-monitors--saved-name (drgnx-monitors--saved f)))
                                                   (reverse gone)))
                              ", ")))
          (when (fboundp 'drgnx-grid-push)                   ; the grid's frames: the fold needs them
            (dolist (f gone)
              (when (framep f)
                (let ((key (drgnx-monitors--saved f)))
                  (set-frame-parameter f 'drgnx-monitor key)
                  (drgnx-monitors--fold key))))))
        (drgnx-monitors--place-next (nreverse jobs))))))

(defun drgnx-monitors--place-restored (frame)
  "`drgnx-persist-after-restore-functions': put each restored auxiliary window back on the monitor it was on, and take
back the windows folded in that the main window (FRAME) was saved with (they return when their monitor does).  The
monitors are read once, later and with the restore deadline; the windows whose monitor is gone fold into the main
window.  Returns at once; never prompts or signals."
  (condition-case err
      (when-let* (((and (frame-live-p frame) (eq (frame-parameter frame 'drgnx-frame-role) 'main)))
                  (folded (plist-get (frame-parameter frame 'drgnx-persist-extra) :monitors-folded))
                  ((null drgnx-monitors--folded))
                  ((drgnx-monitors--folded-p folded)))
        (setq drgnx-monitors--folded (copy-tree folded))
        (drgnx-timer-debounce 'monitors-fold 1 #'drgnx-monitors--fold-settle :idle t :owner :core))
    (error (drgnx-monitors--warn (error-message-string err))))
  (condition-case err
      (when-let* ((frames (drgnx-monitors--to-place)))
        (dolist (f frames) (puthash f t drgnx-monitors--placed))
        (let ((drgnx-platform-command-timeout drgnx-platform-restore-timeout))
          (drgnx-platform-monitors (car frames) (lambda (monitors) (drgnx-monitors--placing frames monitors)))))
    (error (drgnx-monitors--warn (error-message-string err)))))

;;;; The mode

(define-minor-mode drgnx-monitors-mode
  "Keep what the workbench knows about the monitors: each window's monitor and how many there are."
  :global t :group 'drgnx
  (if drgnx-monitors-mode
      (progn
        (require 'drgnx-persist)
        (add-hook 'drgnx-persist-state-functions #'drgnx-monitors--state)
        (add-hook 'drgnx-persist-after-restore-functions #'drgnx-monitors--place-restored)
        (add-hook 'display-monitors-changed-functions #'drgnx-monitors--monitors-changed)
        (add-hook 'move-frame-functions #'drgnx-monitors--frame-moved)
        (add-function :after after-focus-change-function #'drgnx-monitors--focus-changed)
        (drgnx-monitors--schedule-frames (list (selected-frame))))
    (remove-hook 'drgnx-persist-state-functions #'drgnx-monitors--state)
    (remove-hook 'drgnx-persist-after-restore-functions #'drgnx-monitors--place-restored)
    (remove-hook 'display-monitors-changed-functions #'drgnx-monitors--monitors-changed)
    (remove-hook 'move-frame-functions #'drgnx-monitors--frame-moved)
    (remove-function after-focus-change-function #'drgnx-monitors--focus-changed)
    (drgnx-timer-cancel 'monitors-refresh)
    (drgnx-timer-cancel 'monitors-fold)
    (setq drgnx-monitors--pending nil drgnx-monitors--force nil drgnx-monitors--fold-seen nil)))

(provide 'drgnx-monitors)
;;; drgnx-monitors.el ends here
