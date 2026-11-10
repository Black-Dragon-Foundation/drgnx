;;; drgnx-view-nav.el --- Keys through the native view model: the move, the classes on the cards, the notice -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A hub-fed view's keys answer in-process from Sjá, Nidhogg's replica of the view's model as it is drawn
;; (`drgnx-view.el', "The native view model"; docs/develop/core.md).  A command is one line:
;;
;;   (drgnx-view-nav 'follow "up")        ; a link of the selection
;;   (drgnx-view-nav 'walk "team" 1)      ; the next entry of a list
;;
;; `drgnx-view-nav' moves the buffer's instance, puts point on the selection's span in every window, runs the class
;; step, arms the trailing notice and runs `drgnx-view-selected-functions'.  No call waits on the hub.
;;
;; The class step: Sjá answers the nodes whose class changed; each class is a face (`drgnx-view-nav-faces', by the
;; descriptor's class name), put as an overlay on the node's span (the text whose `drgnx-view-patch-id-prop' is the
;; node's id) in the rows that hold it, never on the whole line.  The rows that hold a node are learned as rows are
;; rendered (`drgnx-view-patch-ids'); a row a patch replaced gets its nodes' classes again after the draw.
;;
;; The trailing notice tells the hub the selection once it has been still for `drgnx-view-delay', and at most once per
;; `drgnx-view-delay' while a key is held: the view's `drgnx-view-nav-notice-method' with (:view V :selected ID), or
;; (:view V :clear t) for no selection.
;;
;; Windows: a list longer than the hub sends whole is a window of it (a trail past 500 steps, a search or an Explorer
;; past 20,000 entries).  A key that stops at its edge gets `more' from Sjá; the view asks the hub for the window
;; centred on that edge (`view/window'), keeps the key (one per buffer, the newest wins) and runs it again once a
;; model whose window moved is drained.  Nothing waits for the hub: keys pressed meanwhile answer from the window held.

;;; Code:
(require 'cl-lib)
(require 'drgnx-timer)
(require 'drgnx-notice)
(require 'drgnx-view)

(declare-function nidhogg-view-follow "nidhogg-views" (h link))
(declare-function nidhogg-view-walk "nidhogg-views" (h list step))
(declare-function nidhogg-view-walk-to "nidhogg-views" (h list n))
(declare-function nidhogg-view-set "nidhogg-views" (h what value))
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))

(defface drgnx-view-match '((t :inherit match))
  "A node that matches a hub-fed view's search."
  :group 'drgnx)

(defface drgnx-view-chain '((t :inherit lazy-highlight))
  "A node on the selection's chain in a hub-fed view."
  :group 'drgnx)

(defface drgnx-view-lit '((t :inherit secondary-selection))
  "A node another view lit (the map's selection's lanes, in the timeline)."
  :group 'drgnx)

(defconst drgnx-view-nav-default-faces
  '(("selected" . drgnx-view-selected) ("match" . drgnx-view-match) ("chain" . drgnx-view-chain)
    ("lit" . drgnx-view-lit) ("dim" . shadow))
  "Each class Sjá knows by name and its face, unless a view names its own (`drgnx-view-nav-faces').")

(defvar-local drgnx-view-nav-faces nil
  "This view's (CLASS-NAME . FACE) pairs, before `drgnx-view-nav-default-faces'.  A class with neither has no face.")

(defvar-local drgnx-view-nav-notice-method nil
  "The hub method the trailing notice calls with (:view V :selected ID) or (:view V :clear t); nil: none.")

(defvar drgnx-view-selected-functions nil
  "Called with (BUFFER ID) after a key moved the selection of BUFFER's hub-fed view (ID nil: none).  Another view
follows here (the timeline's lit lanes after the map's selection).")

(defvar-local drgnx-view-nav--said-broken nil "Non-nil once this buffer said its view is broken.")

(defvar-local drgnx-view-nav-list "order"
  "The list a `follow' that answers `more' pages: the view's primary list (the descriptor's `start').")

(defvar-local drgnx-view-nav-paged-functions nil
  "Called with the selection (an id or nil) after a key that waited for another window ran again: a view whose rows
are a window of their own shows the selection's row here (Search).")

(defvar-local drgnx-view-nav--place-after-draw nil
  "Non-nil when a key ran again as a model came, before the rows drawn from it: the draw's class step puts point.")

(defvar-local drgnx-view-nav--pending nil
  "The key waiting for another window: (LIST WINDOW VERB . ARGS), WINDOW being the list's (FROM LENGTH TOTAL) when
the view asked the hub (`drgnx-view-nav--ask-window').  One per buffer; the newest key wins.")

(defun drgnx-view-nav--face-of (class)
  "The face of CLASS, an index into the descriptor's classes, or nil.  The faces by index are made once per applied
model (`drgnx-view-patch-class-faces')."
  (let ((faces (or (drgnx-view-patch-class-faces drgnx-view-patch)
                   (setf (drgnx-view-patch-class-faces drgnx-view-patch)
                         (vconcat (mapcar (lambda (name)
                                            (cdr (or (assoc name drgnx-view-nav-faces)
                                                     (assoc name drgnx-view-nav-default-faces))))
                                          (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch)
                                                            'class-names)))))))
    (and class (< class (length faces)) (aref faces class))))

;;;; The class step

(defun drgnx-view-nav--spans (view id)
  "The (BEG . END) spans of node ID in VIEW's drawn rows, by `drgnx-view-patch-id-prop'."
  (let ((prop drgnx-view-patch-id-prop) spans)
    (dolist (key (gethash id (drgnx-view-patch-ids drgnx-view-patch)))
      (when-let* ((beg (drgnx-view-row-start view key)))
        (let ((end (save-excursion (goto-char beg) (line-end-position))) (pos beg))
          (while (and pos (< pos end))
            (if (equal (get-text-property pos prop) id)
                (let ((stop (min end (next-single-property-change pos prop nil end))))
                  (push (cons pos stop) spans)
                  (setq pos stop))
              (setq pos (next-single-property-change pos prop nil end)))))))
    (nreverse spans)))

(defun drgnx-view-nav--put-class (view id class)
  "Show node ID in CLASS (an index, or nil: none) over its spans; its old overlays go."
  (let* ((state drgnx-view-patch) (table (drgnx-view-patch-spans state)) (old (gethash id table)))
    (mapc #'delete-overlay old)
    (cl-incf (drgnx-view-patch-classed state) (length old))
    (remhash id table)
    (when-let* ((face (drgnx-view-nav--face-of class)))
      (let (ovs)
        (dolist (span (drgnx-view-nav--spans view id))
          (let ((ov (make-overlay (car span) (cdr span))))
            (overlay-put ov 'face face)
            (overlay-put ov 'priority 10)
            (push ov ovs)))
        (cl-incf (drgnx-view-patch-classed state) (length ovs))
        (when ovs (puthash id ovs table))))))

(defun drgnx-view-nav-class-step (view &optional keys)
  "The class step of VIEW, in its buffer: the nodes whose class changed in Sjá get it on their spans; with KEYS (rows a
draw replaced), every node drawn in them gets its current class again and the overlays left empty go."
  (when-let* ((h (drgnx-view-patch-handle drgnx-view-patch)))
    (let ((changes (nidhogg-view-get h 'classes)) (done (make-hash-table :test #'equal)) (i 0))
      (while (< i (length changes))
        (puthash (aref changes i) t done)
        (drgnx-view-nav--put-class view (aref changes i) (aref changes (1+ i)))
        (setq i (+ i 2)))
      (when keys
        (let ((ids (drgnx-view-patch-ids drgnx-view-patch)) (keyset (make-hash-table :test #'equal)))
          (dolist (k keys) (puthash k t keyset))
          ;; no closure per node: a panel draws one per step, and every draw walks them all
          (maphash (lambda (id rows)
                     (unless (gethash id done)
                       (while (and rows (not (gethash (car rows) keyset))) (setq rows (cdr rows)))
                       (when rows (drgnx-view-nav--put-class view id (nidhogg-view-get h 'class id)))))
                   ids)
          ;; a draw may have deleted text under an overlay: the empty ones go (a key alone deletes no text)
          (let ((table (drgnx-view-patch-spans drgnx-view-patch)))
            (maphash (lambda (id ovs)
                       (let ((live (cl-remove-if (lambda (o)
                                                   (when (= (overlay-start o) (overlay-end o)) (delete-overlay o) t))
                                                 ovs)))
                         (if live (puthash id live table) (remhash id table))))
                     table))
          (when drgnx-view-nav--place-after-draw
            (setq drgnx-view-nav--place-after-draw nil)
            (when-let* ((id (nidhogg-view-get h 'selection))) (drgnx-view-nav--place-point view id))))))))

;;;; Point, the notice, the broken view

(defun drgnx-view-nav--place-point (view id)
  "Point to the start of ID's first span, in every window that shows VIEW's buffer."
  (when-let* ((span (car (drgnx-view-nav--spans view id))))
    (goto-char (car span))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (set-window-point w (car span)))))

(defun drgnx-view-nav--notice (buffer)
  "The trailing notice of BUFFER's view: tell the hub its selection as it is now."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((state drgnx-view-patch) (h (drgnx-view-patch-handle state)) (method drgnx-view-nav-notice-method))
        (let ((id (nidhogg-view-get h 'selection)) (view (drgnx-view-patch-view state)))
          (funcall drgnx-view-patch-send-function method
                   (if id (list :view view :selected id) (list :view view :clear t))))))))

(defun drgnx-view-nav--arm-notice ()
  (when drgnx-view-nav-notice-method
    (drgnx-timer-soon (cons 'drgnx-view-nav-notice (current-buffer)) drgnx-view-delay #'drgnx-view-nav--notice
                      :args (list (current-buffer)) :min-interval drgnx-view-delay :owner (current-buffer))))

(defun drgnx-view-nav--broken-p (h)
  "Non-nil when H's view is broken (Sjá's breaker tripped): said once per buffer."
  (when (eql 2 (nidhogg-view-get h 'health))
    (unless drgnx-view-nav--said-broken
      (setq drgnx-view-nav--said-broken t)
      ;; a condition while the view is broken: the doctor's `views' row fails on it; closing the view clears it
      (drgnx-notify 'render 'fail (format "the view %s stopped: its model broke twice" (drgnx-view-patch-view drgnx-view-patch))
                    :id (cons 'view-broken (drgnx-view-patch-view drgnx-view-patch)) :life 'condition
                    :fix "close its buffer and open it again"))
    t))

;;;; Windows

(defconst drgnx-view-nav-window-step 2000
  "The most entries a window moves by when a key passes its edge: a page costs the hub, the line and Sjá what it adds,
so a long window moves a step, not half its length.")

(defun drgnx-view-nav--ask-window (h verb args)
  "The key VERB ARGS stopped at the edge of its list's window (`nidhogg-view-more' the direction): ask the hub for the
window that holds a step past that edge (half the window, at most `drgnx-view-nav-window-step'), or for a `walk-to' the
window centred on its entry, once while one is asked, and keep the key as the one to run when it comes."
  (let* ((list (if (eq verb 'follow) drgnx-view-nav-list (car args)))
         (window (nidhogg-view-get h 'window list)))
    (when window
      (let* ((from (nth 0 window)) (len (nth 1 window)) (total (nth 2 window))
             (step (min (/ len 2) drgnx-view-nav-window-step))
             (want (max 0 (min (- total len)
                               (cond ((eq verb 'walk-to) (- (cadr args) (/ len 2)))
                                     ((< nidhogg-view-more 0) (- from step))
                                     (t (+ from step)))))))
        (unless (and drgnx-view-nav--pending (equal (car drgnx-view-nav--pending) list))
          (funcall drgnx-view-patch-send-function "view/window"
                   (list :view (drgnx-view-patch-view drgnx-view-patch) :list list :from want)))
        (setq drgnx-view-nav--pending
              (cons list (cons (if (equal (car drgnx-view-nav--pending) list) (cadr drgnx-view-nav--pending) window)
                               (cons verb args))))))))

(defun drgnx-view-nav-drained (view)
  "A model of VIEW was drained into Sjá: in each of VIEW's buffers, a key waiting for another window runs again when
the window it was asked from has moved (a model that did not move it leaves the key waiting)."
  (maphash (lambda (pair buffer)
             (when (and (equal (car pair) view) (buffer-live-p buffer))
               (with-current-buffer buffer
                 (when-let* ((pending drgnx-view-nav--pending) (state drgnx-view-patch)
                             (h (drgnx-view-patch-handle state))
                             ((not (equal (nidhogg-view-get h 'window (car pending)) (cadr pending)))))
                   (setq drgnx-view-nav--pending nil
                         drgnx-view-nav--place-after-draw t)
                   (run-hook-with-args 'drgnx-view-nav-paged-functions (apply #'drgnx-view-nav (cddr pending)))))))
           drgnx-view-patch--buffers))

(defun drgnx-view-nav-waiting-p (view)
  "Non-nil when a buffer of VIEW (a view's name) has a key waiting for another window: its models apply as they come."
  (catch 'waiting
    (maphash (lambda (pair buffer)
               (when (and (equal (car pair) view) (buffer-live-p buffer)
                          (buffer-local-value 'drgnx-view-nav--pending buffer))
                 (throw 'waiting t)))
             drgnx-view-patch--buffers)
    nil))

(defun drgnx-view-nav-paging-p ()
  "Non-nil while a key of the current hub-fed view waits for another window (a move that stayed is not an end)."
  (and drgnx-view-nav--pending t))

;;;; The one entry point

(defun drgnx-view-nav (verb &rest args)
  "Move the current hub-fed view's selection by VERB with ARGS, in-process: `follow' LINK, `walk' LIST STEP,
`walk-to' LIST N, or `select' ID.  Puts point on the selection, runs the class step, arms the trailing notice and
runs `drgnx-view-selected-functions'.  A move that stops at a window's edge asks the hub for the next window and runs
again when it comes (\"Windows\" above).  Returns the selection (an id or nil).  Nothing without a model."
  (when-let* ((state drgnx-view-patch) (h (drgnx-view-patch-handle state)))
    (let* ((before (nidhogg-view-get h 'selection))
           (answer (pcase verb
                     ('follow (nidhogg-view-follow h (car args)))
                     ('walk (nidhogg-view-walk h (car args) (cadr args)))
                     ('walk-to (nidhogg-view-walk-to h (car args) (cadr args)))
                     ('select (nidhogg-view-set h 'select (car args)))
                     (_ (error "drgnx-view-nav: no verb %s" verb)))))
      (unless (and (null answer) (drgnx-view-nav--broken-p h))
        (when (and (consp answer) (eq (cdr answer) 'more))
          (drgnx-view-nav--ask-window h verb args))
        (let ((view drgnx-view) (id (nidhogg-view-get h 'selection)))
          (drgnx-view-nav-class-step view)
          (when id (drgnx-view-nav--place-point view id))
          (unless (equal id before)
            (drgnx-view-nav--arm-notice)
            (run-hook-with-args 'drgnx-view-selected-functions (current-buffer) id))
          id)))))

(defun drgnx-view-nav-selection ()
  "The current hub-fed view's selection (an id), or nil."
  (when-let* ((state drgnx-view-patch) (h (drgnx-view-patch-handle state)))
    (nidhogg-view-get h 'selection)))

(defun drgnx-view-nav-field (name &optional id)
  "Field NAME of node ID (default: the selection) of the current hub-fed view, or nil."
  (when-let* ((state drgnx-view-patch) (h (drgnx-view-patch-handle state)))
    (nidhogg-view-get h 'field name id)))

(provide 'drgnx-view-nav)
;;; drgnx-view-nav.el ends here
