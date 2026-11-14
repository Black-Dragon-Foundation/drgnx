;;; drgnx-view-sja.el --- Hub-fed rows held in Sjá, drawn from its edits -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A hub-fed view whose rows Sjá holds (docs/develop/hub.md, "Rows in Sjá").  The hub sends its row patches on the
;; raw `view-model' line (`view/env' with `rows_in_sja'), so Lisp never reads a patch: Sjá's push decides each one by
;; the rows' rules and keeps the rows, styles and images; a draw asks Sjá for the edits that turn the buffer's region
;; into the rows (`nidhogg-view-rows' `draw') and inserts them.  What stays in Lisp is what only Emacs can do: a face
;; for a style, an image for an SVG, the insert, the windows' places, and the messages to the hub.
;;
;; - The buffer keeps its `drgnx-view-patch' state (the pairing, epoch, styles, faces, images, stale shade, Sjá
;;   handle), marked SJA; it has no `drgnx-view' and no rows of its own.
;; - A draw runs widened, with `inhibit-quit' bound: Sjá keeps the drawn state pending until `drawn' confirms the
;;   batch, and a batch never confirmed is drawn whole the next time.  A region whose length is not Sjá's drawn state
;;   is drawn whole too, so a stray edit cannot leave the rows wrong for long.
;; - Each window's start and point are turned into (ROW . OFFSET) before the batch and back after it, so the windows
;;   stay on their rows; a window whose point was at the region's end follows the tail.
;; - The read-only text, the region markers (the end's insertion type t), the stops and images, the faces of styles
;;   (an LRU shared with the Lisp inserter's) are as `drgnx-view-patch-render' draws them.
;; - A view's own text properties go on through `drgnx-view-sja-prop-functions' (a terminal's links and images) and
;;   its own fit of the text before a stop through `drgnx-view-sja-stop-function' (a terminal's wide cells), both
;;   per property or stop the draw puts on, never a scan of the buffer.

;;; Code:

(require 'cl-lib)
(require 'drgnx-view)

(declare-function nidhogg-view-rows "nidhogg-views" (h what &optional a b))
(declare-function drgnx-view-nav-sja-step "drgnx-view-nav" (&optional ids))
(defvar nidhogg-view--row-decisions)

(defvar-local drgnx-view-sja-prop-functions nil
  "Alist (PROP . FN) of a view held in Sjá: after a draw put PROP on FROM..TO of a STRING it inserts, FN is called
with (FROM TO VALUE STRING) and may put more properties on it (a terminal's link: its keymap and help).")

(defvar-local drgnx-view-sja-stop-function nil
  "Called with (STRING LO POS) for each stop a draw puts at POS of STRING (LO: where the text since the last stop
starts): a view's own fit of the text before the stop (a terminal's wide cells), put on STRING.  Nil: none.")

(defvar-local drgnx-view-sja-drawn-functions nil
  "Called with (BEG END) in a view held in Sjá after a draw changed BEG..END of its buffer (the cursor of a terminal,
the link patterns the user set).")

(defconst drgnx-view-sja-table-max 4096
  "The most styles or images a buffer holds from Sjá; past that it drops them and asks Sjá for every live one again
\(`refresh'), so the ones Sjá evicted go.")

(defun drgnx-view-sja-available-p ()
  "Non-nil when this Emacs's Sjá holds rows (`nidhogg-view-rows')."
  (fboundp 'nidhogg-view-rows))

(defun drgnx-view-sja-p (&optional buffer)
  "Non-nil when BUFFER's (default: the current one's) hub-fed rows are held in Sjá."
  (let ((s (buffer-local-value 'drgnx-view-patch (or buffer (current-buffer)))))
    (and s (drgnx-view-patch-sja s) t)))

(defun drgnx-view-sja-held-p (view class)
  "Non-nil when the buffer of (VIEW, CLASS) holds its rows in Sjá: its `view/env' says so (`rows_in_sja')."
  (let ((b (gethash (cons view class) drgnx-view-patch--buffers)))
    (and (buffer-live-p b) (drgnx-view-sja-p b))))

(cl-defun drgnx-view-sja-attach (view class &key buffer start epoch ack (delay drgnx-view-first-delay) epoch-reset)
  "Make BUFFER (default: the current one) show the rows of (VIEW, CLASS) as Sjá holds them, from START (default: the
buffer's start) to its end.  EPOCH: the env epoch sent for the pair.  ACK: each applied patch is acknowledged
\(`view/ack').  DELAY: seconds from a patch to its draw (0: the next timer pass).  EPOCH-RESET: a patch of an older env
epoch is held until a reset (else applied: a terminal's faces repaint in place).  Returns the state."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-view-patch (drgnx-view-sja--release drgnx-view-patch))
    (setq-local drgnx-view nil)
    (let ((s (drgnx-view-patch--make :view view :class class :epoch (or epoch 0) :ack ack :epoch-reset epoch-reset
                                     :sja delay)))
      (setq-local drgnx-view-patch s)
      (drgnx-view-model--open s)
      (nidhogg-view-rows (drgnx-view-patch-handle s) 'on (if epoch-reset 1 0) class)
      (setf (drgnx-view-patch-beg s) (copy-marker (or start (point-min)))
            (drgnx-view-patch-end s) (copy-marker (point-max) t))
      (setq-local bidi-paragraph-direction 'left-to-right)
      (puthash (cons view class) (current-buffer) drgnx-view-patch--buffers)
      (add-hook 'kill-buffer-hook #'drgnx-view-patch--killed nil t)
      (drgnx-view-patch--hooks)
      s)))

(defun drgnx-view-sja--release (s)
  "S's instance in Sjá closed, its draw timer and markers gone."
  (drgnx-timer-cancel (cons 'drgnx-view-sja (current-buffer)))
  (dolist (m (list (drgnx-view-patch-beg s) (drgnx-view-patch-end s))) (when m (set-marker m nil)))
  (drgnx-view-model--close s))

(defun drgnx-view-sja--restart (s forget &optional epoch class)
  "S's pair in Sjá: with FORGET, it starts afresh (a new pair, a new class: the books of what was applied go); with
EPOCH, the env epoch its patches must carry is that; with CLASS, its rows are that display class's from now on."
  (when-let* ((h (drgnx-view-patch-handle s)))
    (when class (nidhogg-view-rows h 'on (if (drgnx-view-patch-epoch-reset s) 1 0) class))
    (when forget (nidhogg-view-rows h 'forget))
    (when epoch (nidhogg-view-rows h 'epoch epoch))))

(defun drgnx-view-sja--send (s method &rest params)
  "METHOD to the hub for S's (view, class), with PARAMS."
  (funcall drgnx-view-patch-send-function method
           (append (list :view (drgnx-view-patch-view s) :class (drgnx-view-patch-class s)) params)))

(defun drgnx-view-sja--decided (s what version)
  "Sjá decided WHAT for a patch of S's view (VERSION, when applied), in S's buffer: an applied one is drawn and
acknowledged, a resync asked for, a held one dims the view, a broken store says so."
  (pcase what
    ('apply
     (setf (drgnx-view-patch-version s) version)
     (when (drgnx-view-patch-stale s) (drgnx-view-patch--stale s nil))
     (drgnx-view-sja--arm s)
     (when (drgnx-view-patch-ack s) (drgnx-view-sja--send s "view/ack" :version version)))
    ('resync
     (cl-incf (drgnx-view-patch-resyncs s))
     (drgnx-view-sja--send s "view/resync" :version (or (drgnx-view-patch-version s) 0)))
    ('hold (drgnx-view-patch--stale s t))
    ('paused (when-let* ((kept (drgnx-view-patch-paused s))) (setcar kept (1+ (car kept)))))   ; Sjá keeps them
    ('broken (drgnx-view-sja--broken s)))
  what)

(defun drgnx-view-sja-pushed (r)
  "R, Sjá's answer to a pushed row patch, (VIEW VERSION DECISION CLASS): see `drgnx-view-sja--decided'.  Returns the
decision, or nil when no buffer shows the pair."
  (let ((b (gethash (cons (nth 0 r) (nth 3 r)) drgnx-view-patch--buffers)))
    (when (buffer-live-p b)
      (with-current-buffer b
        (when (drgnx-view-sja-p)
          (drgnx-view-sja--decided drgnx-view-patch (nth 2 r) (nth 1 r)))))))

(defun drgnx-view-sja--broken (s)
  "S's store broke (resyncs in a loop): the view stops, and a `render' condition says so (the doctor fails)."
  (require 'drgnx-notice)
  (drgnx-notify 'render 'fail (format "the view %s stopped: its rows asked for a reset again and again"
                                      (drgnx-view-patch-view s))
                :id (cons 'view-broken (drgnx-view-patch-view s)) :life 'condition
                :fix "close the view and open it again; see the doctor"))

(defun drgnx-view-sja-pause (s on)
  "Pause S's view (ON) or resume it, in its buffer: while paused Sjá keeps its patches; resuming applies them, draws
and acknowledges the last, or asks for a reset when too many came."
  (let ((h (drgnx-view-patch-handle s)))
    (if on
        (progn (setf (drgnx-view-patch-paused s) (list 0)) (nidhogg-view-rows h 'pause 1))
      (setf (drgnx-view-patch-paused s) nil)
      (let ((ds (mapcar (lambda (n) (aref nidhogg-view--row-decisions n)) (nidhogg-view-rows h 'pause 0))))
        (when (memq 'resync ds) (drgnx-view-sja--decided s 'resync nil))
        (when (memq 'apply ds) (drgnx-view-sja--decided s 'apply (nth 1 (nidhogg-view-rows h 'state))))))))

(defun drgnx-view-sja--arm (s)
  "S's draw, DELAY (its SJA slot) after the patch, and no sooner than one throttle after the last; at the next timer
pass when the view asked for a change the user waits to see (`drgnx-view-patch-hurry', cleared)."
  (let ((delay (if drgnx-view-patch-hurry 0 (drgnx-view-patch-sja s))))
    (setq drgnx-view-patch-hurry nil)
    (unless (eq (drgnx-view-patch-sja s) 'data)   ; rows read as data (`drgnx-view-patch-attach' :sja `data'): never drawn
      (drgnx-timer-soon (cons 'drgnx-view-sja (current-buffer)) delay #'drgnx-view-sja-draw
                        :args (list (current-buffer)) :owner :core
                        :min-interval (and (> delay 0) drgnx-view-delay)))))

(defun drgnx-view-sja-hurry ()
  "Draw the current buffer's rows at the next timer pass, not after their throttle (`drgnx-view-hurry')."
  (when-let* ((s drgnx-view-patch) ((drgnx-view-patch-sja s)))
    (setq drgnx-view-patch-hurry t)
    (drgnx-view-sja--arm s)))

(defun drgnx-view-sja-redraw (buffer &optional refresh)
  "BUFFER's rows drawn again from the faces as they are now (a theme change): with REFRESH, Sjá gives every style and
image again too (a GUI/tty switch)."
  (when (and (buffer-live-p buffer) (drgnx-view-sja-p buffer))
    (with-current-buffer buffer
      (let ((s drgnx-view-patch))
        (clrhash (drgnx-view-patch-faces s))
        (clrhash (drgnx-view-patch-face-names s))
        (when refresh (clrhash (drgnx-view-patch-styles s)) (clrhash (drgnx-view-patch-images s)))
        (nidhogg-view-rows (drgnx-view-patch-handle s) (if refresh 'refresh 'redraw))
        (drgnx-view-sja--arm s)))))

(defun drgnx-view-sja-row-start (key &optional buffer)
  "Where row KEY starts in BUFFER (default: the current one), or nil when it is not drawn."
  (with-current-buffer (or buffer (current-buffer))
    (when-let* ((s drgnx-view-patch) ((drgnx-view-patch-sja s))
                (span (nidhogg-view-rows (drgnx-view-patch-handle s) 'span nil key)))
      (+ (drgnx-view-patch-beg s) (car span)))))

;;;; The draw

(defun drgnx-view-sja--take (s styles images)
  "The STYLES ([ID JSON ...]) and IMAGES ([ID SVG ...]) a draw gave, into S's tables."
  (let ((st (drgnx-view-patch-styles s)) (im (drgnx-view-patch-images s)))
    (when (or (> (hash-table-count st) drgnx-view-sja-table-max) (> (hash-table-count im) drgnx-view-sja-table-max))
      (clrhash st) (clrhash im)
      (nidhogg-view-rows (drgnx-view-patch-handle s) 'refresh))
    (cl-loop for i from 0 below (length styles) by 2
             do (puthash (aref styles i)
                         (json-parse-string (aref styles (1+ i)) :object-type 'plist :array-type 'list
                                            :null-object nil :false-object nil)
                         st))
    (cl-loop for i from 0 below (length images) by 2
             do (puthash (aref images i) (drgnx-view-patch--image (aref images (1+ i))) im))))

(defun drgnx-view-sja--face (s name)
  "The face a run's NAME names (`drgnx-view-patch--face'), remembered in S once found; a name that is no face yet is
asked again the next time (it may be defined later)."
  (let ((names (drgnx-view-patch-face-names s)))
    (or (gethash name names)
        (when-let* ((f (drgnx-view-patch--face name))) (puthash name f names)))))

(defun drgnx-view-sja--value (v)
  "A property's value as a draw gives it: a JSON value is a one-element list of its text."
  (if (consp v) (json-parse-string (car v) :object-type 'plist :array-type 'list :null-object nil :false-object nil) v))

(defun drgnx-view-sja--dress (s text runs props display)
  "TEXT, one edit's rows, with RUNS, PROPS and DISPLAY put on (see `nidhogg-view-rows' `draw'); returns TEXT."
  (cl-loop for i from 0 below (length runs) by 3
           do (let* ((f (aref runs (+ i 2)))
                     (face (if (integerp f) (drgnx-view-patch--style-face s f) (drgnx-view-sja--face s f))))
                (when face (add-face-text-property (aref runs i) (aref runs (1+ i)) face t text))))
  (cl-loop for i from 0 below (length props) by 4
           do (when-let* ((name (drgnx-view-patch--prop (aref props (+ i 2)))))
                (let ((from (aref props i)) (to (aref props (1+ i))) (v (drgnx-view-sja--value (aref props (+ i 3)))))
                  (put-text-property from to name v text)
                  (when-let* ((fn (alist-get name drgnx-view-sja-prop-functions))) (funcall fn from to v text)))))
  (let ((lo 0))
    (cl-loop for i from 0 below (length display) by 4
             do (let ((kind (aref display i)) (pos (aref display (1+ i)))
                      (a (aref display (+ i 2))) (b (aref display (+ i 3))))
                  (pcase kind
                    (0 (put-text-property pos (1+ pos) 'display (drgnx-view-patch--stop s a) text)
                       (when drgnx-view-sja-stop-function (funcall drgnx-view-sja-stop-function text lo pos))
                       (setq lo (1+ pos)))
                    (1 (let ((spec (gethash a (drgnx-view-patch-images s))))
                         (put-text-property pos (1+ pos) 'display (if (or (null spec) (eq spec :alt)) b spec) text)))
                    (2 (put-text-property pos (1+ pos) 'display `(space :width (,a) :height (,b)) text))
                    (3 (put-text-property pos (1+ pos) 'line-height
                                          (* a (if (> b 0) b (or drgnx-view--line-height
                                                                 (setq drgnx-view--line-height (default-line-height)))))
                                          text))))))
  (unless buffer-read-only (add-text-properties 0 (length text) drgnx-view--read-only text))
  text)

(defun drgnx-view-sja--place (h beg end pos)
  "POS turned into Sjá's (ROW . OFFSET) of H, or POS itself when it is outside BEG..END or past the rows."
  (or (and (<= beg pos) (< pos end) (nidhogg-view-rows h 'place (- pos beg))) pos))

(defun drgnx-view-sja--pos (h beg place)
  "PLACE (from `drgnx-view-sja--place') back to a position: its row's start plus its offset, or the position."
  (if (consp place)
      (let ((p (nidhogg-view-rows h 'pos (cdr place) (car place)))) (if p (+ beg p) beg))
    (min place (point-max))))

(defun drgnx-view-sja-draw (buffer)
  "Draw BUFFER's rows as Sjá holds them now: the edits Sjá answers, inserted in one batch (see the Commentary)."
  (when (and (buffer-live-p buffer) (drgnx-view-sja-p buffer))
    (with-current-buffer buffer
      (let* ((s drgnx-view-patch) (h (drgnx-view-patch-handle s))
             (beg (drgnx-view-patch-beg s)) (end (drgnx-view-patch-end s))
             (inhibit-quit t) (inhibit-read-only t) (inhibit-modification-hooks t) (buffer-undo-list t)
             lo hi drawn)
        (save-restriction
          (widen)
          (let* ((wins (mapcar (lambda (w) (list w (drgnx-view-sja--place h beg end (window-start w))
                                                 (drgnx-view-sja--place h beg end (window-point w))
                                                 (= (window-point w) end)))
                               (get-buffer-window-list buffer nil t)))
                 (pt (drgnx-view-sja--place h beg end (point)))
                 (pt-end (= (point) end))
                 (d (progn (nidhogg-view-rows h 'idprop nil (symbol-name drgnx-view-patch-id-prop)) ; the nodes drawn
                           (nidhogg-view-rows h 'draw (- end beg)))))
            (when d
              (drgnx-view-sja--take s (nth 3 d) (nth 4 d))
              (when-let* ((term (nth 5 d)))
                (setf (drgnx-view-patch-term s)
                      (json-parse-string term :object-type 'plist :array-type 'list :null-object nil :false-object nil)))
              (when-let* ((n (nth 6 d)) (m (gethash (drgnx-view-patch-view s) drgnx-view-model--views)))
                (drgnx-view-model--apply m n))
              (let ((edits (nth 2 d)))
                (dotimes (i (length edits))
                  (let* ((e (aref edits i)) (at (+ beg (nth 0 e))))
                    (goto-char at)
                    (delete-char (nth 1 e))
                    (insert (drgnx-view-sja--dress s (nth 2 e) (nth 3 e) (nth 4 e) (nth 5 e)))
                    (setq lo (if lo (min lo at) at) hi (max (or hi 0) (point))))))
              (nidhogg-view-rows h 'drawn (nth 0 d))
              (setq drawn d)
              (cl-incf (drgnx-view-patch-draws s))
              (dolist (w wins)
                (when (window-live-p (nth 0 w))
                  (set-window-start (nth 0 w) (drgnx-view-sja--pos h beg (nth 1 w)) t)
                  (set-window-point (nth 0 w) (if (nth 3 w) end (drgnx-view-sja--pos h beg (nth 2 w))))))
              (goto-char (if pt-end end (drgnx-view-sja--pos h beg pt)))
              (when-let* ((o (drgnx-view-patch-stale-overlay s))) (move-overlay o (point-min) (point-max))))))
        (when lo (run-hook-with-args 'drgnx-view-sja-drawn-functions lo hi))
        (when drawn
          ;; the model's classes on what was drawn, then the view's own marks over the rows drawn (KEYS)
          (let ((keys (append (nth 7 drawn) nil)))
            (when (fboundp 'drgnx-view-nav-sja-step) (drgnx-view-nav-sja-step (nth 8 drawn)))
            (run-hook-with-args 'drgnx-view-patch-patched-functions nil keys)))))))

(defun drgnx-view-sja-draw-now (&optional buffer)
  "Draw BUFFER's (default: the current one's) rows now, not at the next timer pass."
  (let ((b (or buffer (current-buffer))))
    (drgnx-timer-cancel (cons 'drgnx-view-sja b))
    (drgnx-view-sja-draw b)))

(provide 'drgnx-view-sja)
;;; drgnx-view-sja.el ends here
