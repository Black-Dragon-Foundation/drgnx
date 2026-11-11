;;; agent-panel-rows-test.el --- the agent panel inserts the rows the hub builds; the mirror patches in place -*- lexical-binding: t -*-
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
(declare-function drgnx-agent-panel--take-entries "drgnx-agent-panel")
(declare-function drgnx-agent-panel-toggle-type "drgnx-agent-panel-steps")

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
                  (let* ((keys (drgnx-agent-panel-rows-test--keys (plist-get s :buf)))
                         (hub (seq-filter #'stringp keys))
                         (first (seq-position keys (car hub) #'equal))
                         (look (cdr (assoc "agents/panel/look" drgnx-agent-panel-rows-test--sent))))
                    (cond ((not (equal hub '("e:3" "e:0" "e:1" "e:2")))
                           (format "the hub rows are %S, not the new hub's" hub))
                          ((not (equal (seq-subseq keys first (+ first 4)) hub))
                           (format "the hub rows are not together: %S" keys))
                          ((not (equal (car keys) '(:header))) (format "the header is not first: %S" keys))
                          ((not (equal (nth (+ first 4) keys) '(:rows-end)))
                           (format "the panel's own rows below the transcript are not after it: %S" keys))
                          ((not (equal (plist-get look :view) "agent-panel/s1")) "no look sent for the panel")))))
      (when-let* ((b (get-buffer "*drgnx agent: s1*"))) (kill-buffer b)))))

(ert-deftest drgnx-agent-panel-rows/composer-keys-unchanged ()
  (let (bindings)
    (dolist (up '(nil t))
      (drgnx-agent-panel-rows-test--with up
        (let ((buf (drgnx-agent-panel-rows-test--fresh)))
          (unwind-protect
              (with-current-buffer buf
                (should (eq up (and drgnx-view-patch t)))
                (drgnx-view-draw-now drgnx-view)
                (goto-char (point-min))
                (while (and (not (eobp)) (not (equal (drgnx-view-key-at) '(:composer)))) (forward-line 1))
                (should (equal (drgnx-view-key-at) '(:composer)))
                (push (mapcar (lambda (k) (key-binding (kbd k))) '("RET" "TAB" "C-c C-c" "M-p")) bindings))
            (kill-buffer buf)))))
    (should (equal (car bindings) (cadr bindings)))))

(ert-deftest drgnx-agent-panel-rows/old-path-switch-still-draws-the-panel ()
  (drgnx-agent-panel-rows-test--with t
    (let* ((drgnx-view-old-path t) (buf (drgnx-agent-panel-rows-test--fresh)))
      (unwind-protect
          (with-current-buffer buf
            (should-not drgnx-view-patch)
            (drgnx-agent-panel--take-entries
             (list (list 0 (list :type "user" :text "go"))
                   (list 1 (list :type "tool" :id "t1" :title "Read a.el" :kind "read" :status "completed"))))
            (drgnx-view-draw-now drgnx-view)
            (should (string-match-p "Read a.el" (buffer-string)))
            (should-not (assoc "agents/panel/look" drgnx-agent-panel-rows-test--sent)))
        (kill-buffer buf)))))

;;;; A panel in two display classes

(defun drgnx-agent-panel-rows-test--line (buf key)
  "The text of BUF's row KEY, drawn."
  (with-current-buffer buf
    (drgnx-view-draw-now drgnx-view)
    (goto-char (point-min))
    (while (and (not (eobp)) (not (equal (drgnx-view-key-at) key))) (forward-line 1))
    (and (equal (drgnx-view-key-at) key) (buffer-substring-no-properties (pos-bol) (pos-eol)))))

(ert-deftest drgnx-agent-panel-rows/a-twin-shows-the-panels-state-with-its-class-rows ()
  "The panel's buffer in a second display class (RRO-PANEL-TWIN-1): the hub's rows of its own class between the
panel's rows; the header, cards and composer drawn from the panel's state, and drawn again when it changes; a
change asked for in the twin reaches the panel; not a panel of its own (no subscription, not in the finders)."
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
            (let ((keys (drgnx-agent-panel-rows-test--keys tw)))
              (should (equal (car keys) '(:header)))
              (should (equal (seq-filter #'stringp keys) '("e:0" "e:1")))
              (should (equal (nth (1+ (seq-position keys "e:1")) keys) '(:rows-end)))
              (should (member '(:composer) keys)))
            (should (equal (seq-filter #'stringp (drgnx-agent-panel-rows-test--keys buf)) '("e:0")))
            ;; the panel's state changes: the twin's header follows
            (with-current-buffer buf (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :name "Twin title")))
            (should (equal (drgnx-agent-panel-rows-test--line tw '(:header)) (drgnx-agent-panel-rows-test--line buf '(:header))))
            (should (string-match-p "Twin title" (drgnx-agent-panel-rows-test--line tw '(:header))))
            ;; a row the panel adds (a plan's card) shows in the twin too
            (with-current-buffer buf
              (drgnx-agent-panel--take-entries
               (list (list 0 (list :type "plan" :entries (vector (list :content "first step" :status "pending")))))))
            (should (equal (seq-remove #'stringp (drgnx-agent-panel-rows-test--keys tw))
                           (seq-remove #'stringp (drgnx-agent-panel-rows-test--keys buf))))
            ;; killing the twin leaves the panel's subscription alone
            (with-current-buffer buf (setq drgnx-agent-panel--subscribed t))
            (kill-buffer tw)
            (should (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (should-not (assoc "agents/entries/unsubscribe" drgnx-agent-panel-rows-test--sent))
            (with-current-buffer buf (drgnx-agent-panel--dirty (list :header)) (drgnx-view-draw-now drgnx-view)))
        (when (buffer-live-p tw) (kill-buffer tw))
        (kill-buffer buf)))))

;;;; The mirror keeps its transcript in place

(defun drgnx-agent-panel-rows-test--block (n text)
  (list :block n :kind "paragraph" :spans (vector (list :text text :style "text"))))

(defun drgnx-agent-panel-rows-test--mirror-step (s ev)
  "EV on both mirrors of S: :m patched in place, :r behind `drgnx-view-old-path' (the reference).  `entries' as the
hub sends them; `restart': both fetch the hub's whole transcript (`:hub', its entries complete) again."
  (let ((m (plist-get s :m)) (r (plist-get s :r)))
    (pcase (car ev)
      ('entries
       (let* ((pairs (cadr ev)) (before (drgnx-agent-session-entries m))
              (grows (cl-some (lambda (p) (>= (car p) (length before))) pairs)))
         (dolist (p pairs)
           (setf (alist-get (car p) (plist-get s :hub))
                 (let ((e (drgnx-agents-mirror--complete-blocks (alist-get (car p) (plist-get s :hub)) (cadr p))))
                   (if (plist-get e :blocks) (plist-put e :blocks (vconcat (plist-get e :blocks))) e))))
         (setq s (plist-put s :stops-m (+ (plist-get s :stops-m) (drgnx-agents-mirror--apply-entries m pairs))))
         (let ((drgnx-view-old-path t))
           (setq s (plist-put s :stops-r (+ (plist-get s :stops-r) (drgnx-agents-mirror--apply-entries r pairs)))))
         (when (and before (not grows) (not (eq before (drgnx-agent-session-entries m))))
           (setq s (plist-put s :copied t)))))
      ('restart
       (let ((all (sort (mapcar (lambda (c) (list (car c) (cdr c))) (plist-get s :hub)) (lambda (a b) (< (car a) (car b))))))
         (setf (drgnx-agent-session-entries m) nil (drgnx-agent-session-entries r) nil)
         (drgnx-agents-mirror--apply-entries m all)
         (let ((drgnx-view-old-path t)) (drgnx-agents-mirror--apply-entries r all)))))
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
     :init (lambda () (list :m (drgnx-agents--make :remote "s-p" :id "s-p") :r (drgnx-agents--make :remote "s-p" :id "s-p")
                            :hub nil :stops-m 0 :stops-r 0 :copied nil))
     :step #'drgnx-agent-panel-rows-test--mirror-step
     :check (lambda (s _)
              (let ((m (drgnx-agent-session-entries (plist-get s :m)))
                    (r (drgnx-agent-session-entries (plist-get s :r))))
                (cond ((not (equal m r)) (format "in place %S, copied %S" m r))
                      ((not (= (plist-get s :stops-m) (plist-get s :stops-r) 1))
                       (format "the turn ended %d times in place, %d copied" (plist-get s :stops-m) (plist-get s :stops-r)))
                      ((plist-get s :copied) "a patch of entries it held copied the transcript")
                      ((not (equal (mapcar (lambda (b) (plist-get (elt (plist-get b :spans) 0) :text))
                                           (plist-get (nth 1 m) :blocks))
                                   '("one" "two!")))
                       (format "the blocks are %S" (plist-get (nth 1 m) :blocks)))))))))

;;; agent-panel-rows-test.el ends here
