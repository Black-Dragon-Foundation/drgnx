;;; agent-panel-rows-test.el --- the agent panel is the rows the hub builds; the mirror patches in place -*- lexical-binding: t -*-
;; test-class: det
;; Pattern A: every order of the hub's patches, a key and a reconnect (orders-fixture.el).  Pattern D: pure.  No hub:
;; the hub connection reads as up, and what the panel sends is recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel-toggle-type "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-buffers "drgnx-agent-panel")
(declare-function drgnx-agent-panel--send-look "drgnx-agent-panel")
(defvar drgnx-agent-panel--disclosure)
(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--subscribed)

(defvar drgnx-agent-panel-rows-test--sent nil "What the panel sent the hub, newest first: (METHOD . PARAMS).")

(defmacro drgnx-agent-panel-rows-test--with (up &rest body)
  "BODY with the module set up, the hub's calls recorded and unanswered, the connection up when UP."
  (declare (indent 1))
  `(let ((drgnx-agent-panel-rows-test--sent nil)
         (drgnx-view-patch--buffers (make-hash-table :test #'equal))
         (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) drgnx-agent-panel-rows-test--sent))))
     ;; stubbed inside: setting the module up loads its files again
     (drgnx-test-with-modules '(tools/agent-panel)
       (cl-letf (((symbol-function 'drgnx-hub-call)
                  (lambda (method params _cb &rest _) (push (cons method params) drgnx-agent-panel-rows-test--sent) 1))
                 ((symbol-function 'drgnx-agent-panel--hub-up-p) (lambda () ,up)))
         ,@body))))

(defun drgnx-agent-panel-rows-test--fresh ()
  "Panel \"s1\", made again."
  (when-let* ((old (get-buffer "*drgnx agent: s1*"))) (kill-buffer old))
  (drgnx-agent-panel-buffer "s1"))

(defun drgnx-agent-panel-rows-test--keys (buf)
  "BUF's view drawn: the key of each line, top to bottom, a key once."
  (with-current-buffer buf
    (drgnx-view-draw-now drgnx-view)
    (goto-char (point-min))
    (let (keys)
      (while (not (eobp))
        (let ((k (drgnx-view-key-at)))
          (unless (equal k (car keys)) (push k keys)))
        (forward-line 1))
      (nreverse keys))))

(cl-defun drgnx-agent-panel-rows-test--patch (ops &key (hub 7) (base 0) (version 1))
  (list 'patch (list :view "agent-panel/s1" :class nil :hub hub :base base :version version :env_epoch 0 :ops ops)))

(defun drgnx-agent-panel-rows-test--row (key)
  (list :key key :text (format "row %s" key)))

(defun drgnx-agent-panel-rows-test--reset (hub keys)
  (drgnx-agent-panel-rows-test--patch (list (list :reset (mapcar #'drgnx-agent-panel-rows-test--row keys))) :hub hub))

(defun drgnx-agent-panel-rows-test--insert (hub base after key)
  (drgnx-agent-panel-rows-test--patch
   (list (list :insert (list :after after :rows (list (drgnx-agent-panel-rows-test--row key)))))
   :hub hub :base base :version (1+ base)))

(defun drgnx-agent-panel-rows-test--step (s ev)
  "One event on panel S's buffer: a patch (for the class the panel shows), a key, or the link going down."
  (with-current-buffer (plist-get s :buf)
    (pcase (car ev)
      ('patch (let ((p (copy-sequence (cadr ev))))
                (drgnx-view-apply-patch (plist-put p :class (drgnx-view-patch-class drgnx-view-patch)))))
      ('key (drgnx-agent-panel-toggle-type 'thinking))
      ('disconnect (drgnx-view-patch--forget drgnx-view-patch))))
  (cons s nil))

(ert-deftest drgnx-agent-panel-rows/every-order-of-patch-key-and-reconnect-converges ()
  (drgnx-agent-panel-rows-test--with t
    (unwind-protect
        (drgnx-test-every-order
         :kinds '(patch key disconnect)
         :sources `(("old hub" ,(drgnx-agent-panel-rows-test--reset 7 '("e:0"))
                     ,(drgnx-agent-panel-rows-test--insert 7 1 "e:0" "e:1"))
                    ("link" (disconnect))
                    ("new hub" ,(drgnx-agent-panel-rows-test--reset 8 '("e:0" "e:1" "e:2"))
                     ,(drgnx-agent-panel-rows-test--insert 8 1 nil "e:3"))
                    ("user" (key)))
         :edges '((("old hub" . 0) . ("link" . 0)) (("link" . 0) . ("new hub" . 0)))
         :init (lambda () (list :buf (drgnx-agent-panel-rows-test--fresh)))
         :step #'drgnx-agent-panel-rows-test--step
         :check (lambda (s _)
                  (let ((keys (drgnx-agent-panel-rows-test--keys (plist-get s :buf)))
                        (look (cdr (assoc "agents/panel/look" drgnx-agent-panel-rows-test--sent))))
                    ;; the buffer is the hub's rows and nothing else
                    (cond ((not (equal keys '("e:3" "e:0" "e:1" "e:2")))
                           (format "the rows are %S, not the new hub's" keys))
                          ((not (equal (plist-get look :view) "agent-panel/s1")) "no look sent for the panel")))))
      (when-let* ((b (get-buffer "*drgnx agent: s1*"))) (kill-buffer b)))))

;;;; A panel in two display classes

(ert-deftest drgnx-agent-panel-rows/a-twin-shows-the-panels-state-with-its-class-rows ()
  "The panel's buffer in a second display class (RRO-PANEL-TWIN-1): the hub's rows of its own class; its commands read
the panel's state and what they change reaches the panel; not a panel of its own (no subscription, not in the
finders)."
  (drgnx-agent-panel-rows-test--with t
    (let* ((buf (drgnx-agent-panel-rows-test--fresh)) tw)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (should (functionp drgnx-view-patch-twin-function))
              (drgnx-view-apply-patch (plist-put (cadr (drgnx-agent-panel-rows-test--reset 7 '("e:0")))
                                                 :class (drgnx-view-patch-class drgnx-view-patch)))
              (setq tw (funcall drgnx-view-patch-twin-function "c2")))
            (should (eq tw (gethash (cons "agent-panel/s1" "c2") drgnx-view-patch--buffers)))
            (should-not (memq tw (drgnx-agent-panel-buffers)))
            (with-current-buffer tw
              (drgnx-view-apply-patch (plist-put (cadr (drgnx-agent-panel-rows-test--reset 7 '("e:0" "e:1")))
                                                 :class "c2")))
            (should (equal (drgnx-agent-panel-rows-test--keys tw) '("e:0" "e:1")))
            (should (equal (drgnx-agent-panel-rows-test--keys buf) '("e:0")))
            (should (equal "s1" (buffer-local-value 'drgnx-agent-panel--session tw)))
            ;; a command in the twin works on the panel's state: read before it, given back after it
            (with-current-buffer buf (setq drgnx-agent-panel--disclosure '(edit)))
            (with-current-buffer tw
              (run-hooks 'pre-command-hook)
              (should (equal '(edit) drgnx-agent-panel--disclosure))
              (drgnx-agent-panel-toggle-type 'read)
              (run-hooks 'post-command-hook))
            (should (equal '(read edit) (buffer-local-value 'drgnx-agent-panel--disclosure buf)))
            ;; killing the twin leaves the panel's subscription alone
            (with-current-buffer buf (setq drgnx-agent-panel--subscribed t))
            (kill-buffer tw)
            (should (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (should-not (assoc "agents/entries/unsubscribe" drgnx-agent-panel-rows-test--sent)))
        (when (buffer-live-p tw) (kill-buffer tw))
        (kill-buffer buf)))))

;;;; The mirror keeps its transcript in place

(defun drgnx-agent-panel-rows-test--block (n text)
  (list :block n :kind "paragraph" :spans (vector (list :text text :style "text"))))

(defun drgnx-agent-panel-rows-test--mirror-step (s ev)
  "EV on the mirror :m of S, patched in place.  `entries' as the hub sends them; `restart': it fetches the hub's whole
transcript (`:hub', its entries complete) again."
  (let ((m (plist-get s :m)))
    (pcase (car ev)
      ('entries
       (let* ((pairs (cadr ev)) (before (drgnx-agent-session-entries m))
              (grows (cl-some (lambda (p) (>= (car p) (length before))) pairs)))
         (dolist (p pairs)
           (setf (alist-get (car p) (plist-get s :hub))
                 (let ((e (drgnx-agents-mirror--complete-blocks (alist-get (car p) (plist-get s :hub)) (cadr p))))
                   (if (plist-get e :blocks) (plist-put e :blocks (vconcat (plist-get e :blocks))) e))))
         (setq s (plist-put s :stops-m (+ (plist-get s :stops-m) (drgnx-agents-mirror--apply-entries m pairs))))
         (when (and before (not grows) (not (eq before (drgnx-agent-session-entries m))))
           (setq s (plist-put s :copied t)))))
      ('restart
       (let ((all (sort (mapcar (lambda (c) (list (car c) (cdr c))) (plist-get s :hub)) (lambda (a b) (< (car a) (car b))))))
         (setf (drgnx-agent-session-entries m) nil)
         (drgnx-agents-mirror--apply-entries m all))))
    (cons s nil)))

(ert-deftest drgnx-agent-panel-rows/mirror-commits-a-patch-once ()
  (let ((b0 (drgnx-agent-panel-rows-test--block 0 "one")) (b1 (drgnx-agent-panel-rows-test--block 1 "two")))
    (drgnx-test-every-order
     :kinds '(entries restart)
     :sources `(("hub" (entries ((0 (:type "user" :text "go"))))
                 (entries ((1 (:type "agent" :text "one" :blocks ,(vector b0)))))
                 (entries ((1 (:type "agent" :text "one two" :patch ,(vector b1)))))
                 (entries ((1 (:type "agent" :text "one two!"
                                     :patch ,(vector (drgnx-agent-panel-rows-test--block 1 "two!"))))
                           (2 (:type "stop" :text "end_turn")))))
                ("hub restart" (restart)))
     :init (lambda () (list :m (drgnx-agents--make :remote "s-p" :id "s-p") :hub nil :stops-m 0 :copied nil))
     :step #'drgnx-agent-panel-rows-test--mirror-step
     :check (lambda (s _)
              (let ((m (drgnx-agent-session-entries (plist-get s :m))))
                (cond ((not (= (plist-get s :stops-m) 1))
                       (format "the turn ended %d times" (plist-get s :stops-m)))
                      ((plist-get s :copied) "a patch of entries it held copied the transcript")
                      ((not (equal (mapcar (lambda (b) (plist-get (elt (plist-get b :spans) 0) :text))
                                           (plist-get (nth 1 m) :blocks))
                                   '("one" "two!")))
                       (format "the blocks are %S" (plist-get (nth 1 m) :blocks)))))))))

(ert-deftest drgnx-agent-panel-rows/a-reset-keeps-a-window-scrolled-back-on-its-row ()
  "The hub draws every row again (a reset: the panel's width or the theme changed): a window the user scrolled back
keeps its start and point on the rows they were on, not after the hub's rows (the long look scene's wheel lost its
place when the reset of the frame's resize came in during it)."
  (drgnx-agent-panel-rows-test--with t
    (let* ((buf (drgnx-agent-panel-rows-test--fresh))
           (keys (mapcar (lambda (i) (format "e:%d" i)) (number-sequence 0 59)))
           (row-start (lambda (key) (save-excursion (goto-char (point-min))
                                                    (while (and (not (eobp)) (not (equal (drgnx-view-key-at) key)))
                                                      (forward-line 1))
                                                    (point)))))
      (unwind-protect
          (with-current-buffer buf
            (drgnx-view-apply-patch (plist-put (cadr (drgnx-agent-panel-rows-test--reset 7 keys))
                                               :class (drgnx-view-patch-class drgnx-view-patch)))
            (drgnx-view-draw-now drgnx-view)
            (let ((w (selected-window)))
              (set-window-buffer w buf)
              (set-window-start w (funcall row-start "e:20"))
              (set-window-point w (funcall row-start "e:22"))
              (drgnx-view-apply-patch (plist-put (plist-put (plist-put (cadr (drgnx-agent-panel-rows-test--reset 7 keys))
                                                                       :class (drgnx-view-patch-class drgnx-view-patch))
                                                            :base 1)
                                                 :version 2))
              (drgnx-view-draw-now drgnx-view)
              (should (equal (list (save-excursion (goto-char (window-start w)) (drgnx-view-key-at))
                                   (save-excursion (goto-char (window-point w)) (drgnx-view-key-at)))
                             '("e:20" "e:22")))))
        (kill-buffer buf)))))

;;;; The thresholds the hub's rows warn at

(defvar drgnx-agent-panel-slow-seconds)
(defvar drgnx-agent-panel-expensive-cost)

(ert-deftest drgnx-agent-panel-rows/the-slow-and-expensive-settings-reach-the-hub-at-once ()
  "The hub draws a step's time and cost in the warning face over `drgnx-agent-panel-slow-seconds' and
`drgnx-agent-panel-expensive-cost': the look carries both (`slow_secs', `dear_cost'), and setting either sends every
panel's look again at once."
  (let ((slow drgnx-agent-panel-slow-seconds) (dear drgnx-agent-panel-expensive-cost))
    (drgnx-agent-panel-rows-test--with t
      (let ((buf (drgnx-agent-panel-rows-test--fresh)))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (drgnx-agent-panel--send-look))
              (let ((look (cdr (assoc "agents/panel/look" drgnx-agent-panel-rows-test--sent))))
                (should (equal slow (plist-get look :slow_secs)))
                (should (equal dear (plist-get look :dear_cost))))
              (setq drgnx-agent-panel-rows-test--sent nil)
              (setopt drgnx-agent-panel-slow-seconds 3)
              (let ((look (cdr (assoc "agents/panel/look" drgnx-agent-panel-rows-test--sent))))
                (should (equal "agent-panel/s1" (plist-get look :view)))
                (should (equal 3 (plist-get look :slow_secs))))
              (setq drgnx-agent-panel-rows-test--sent nil)
              (setopt drgnx-agent-panel-expensive-cost 2.5)
              (should (equal 2.5 (plist-get (cdr (assoc "agents/panel/look" drgnx-agent-panel-rows-test--sent)) :dear_cost))))
          (kill-buffer buf)
          (setopt drgnx-agent-panel-slow-seconds slow)
          (setopt drgnx-agent-panel-expensive-cost dear))))))

;;; agent-panel-rows-test.el ends here
