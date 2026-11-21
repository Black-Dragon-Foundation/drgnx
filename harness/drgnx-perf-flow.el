;;; drgnx-perf-flow.el --- perf workloads of the Flow plan: the conversation, the Agents side, the look reset, Budgets -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Flow plan's timing rows as perf-lab workloads (docs/develop/perf.md, "Flow"): `conversation-open',
;; `conversation-append', `agents-side-stream', `agents-side-typing', `look-reset-3-frames' and `budget-page-open'.
;; Each is a measure-only workload in the form of drgnx-perf-extensions.el: the library below is evaluated in the
;; session; its entry points make the view's buffer, feed it the rows the hub sends for it (made here, at the sizes the
;; plan names: a 10k-block conversation, 30 streaming agents, 500 budget scopes with 3 meters and 8 days of history) as
;; `view-patch' data through `drgnx-view-apply-patch', and time the editor's side: the patch applied and drawn.  The
;; hub's side of the same views is the Rust tests' (view/agents_side.rs, view/budgets.rs, agents/session/rows.rs).

;;; Code:
(require 'cl-lib)

(defconst drgnx-perf-flow--lib
  '(progn
     (require 'cl-lib)
     (require 'subr-x)
     (require 'drgnx-view)
     (require 'drgnx-perf)

     (defvar drgnx-perf-flow-n
       '((blocks . 10000) (window . 200) (appends . 120) (agents . 30) (patches . 200) (keys . 100)
         (scopes . 500) (meters . 3) (days . 8) (page . 100) (work . 500))
       "How big each fixture is.")
     (defvar drgnx-perf-flow--buffers nil "The buffers the setups made, killed by the teardowns.")
     (defvar drgnx-perf-flow--version nil "Hash: view → the last version sent to it.")

     (defun drgnx-perf-flow--size (k) (cdr (assq k drgnx-perf-flow-n)))
     (defun drgnx-perf-flow--ms (fn)
       "FN's wall clock in milliseconds, after a collection that is not counted."
       (garbage-collect)
       (let ((t0 (float-time))) (funcall fn) (* 1000 (- (float-time) t0))))

     (defun drgnx-perf-flow--row (key text &optional face)
       (list :key key :text text :runs (and face (list (list 0 (length text) face)))
             :props (list (list 0 (length text) "drgnx-work-id" key))))

     (defun drgnx-perf-flow--buffer (view)
       "A fresh buffer attached to VIEW's rows (class \"c\", epoch 1), shown in the selected window."
       (let ((b (get-buffer-create (format " *perf-flow %s*" view))))
         (with-current-buffer b
           (let ((inhibit-read-only t)) (erase-buffer))
           (drgnx-view-patch-attach view "c" :epoch 1))
         (puthash view 0 drgnx-perf-flow--version)
         (push b drgnx-perf-flow--buffers)
         (set-window-buffer (selected-window) b)
         b))

     (defun drgnx-perf-flow--send (view ops)
       "Send VIEW the patch of OPS, the next version, and draw it now."
       (let* ((v (gethash view drgnx-perf-flow--version 0)) (b (1+ v)))
         (puthash view b drgnx-perf-flow--version)
         (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base v :version b :env_epoch 1 :ops ops))
         (when-let* ((buf (seq-find (lambda (x) (and (buffer-live-p x)
                                                     (equal view (ignore-errors
                                                                   (drgnx-view-patch-view
                                                                    (buffer-local-value 'drgnx-view-patch x))))))
                                    drgnx-perf-flow--buffers)))
           (with-current-buffer buf
             (when (drgnx-view-p drgnx-view) (drgnx-view-draw-now drgnx-view))))))

     (defun drgnx-perf-flow-setup ()
       (setq drgnx-perf-flow--version (make-hash-table :test #'equal))
       t)

     (defun drgnx-perf-flow-teardown ()
       (dolist (b drgnx-perf-flow--buffers)
         (when (buffer-live-p b)
           (with-current-buffer b (ignore-errors (drgnx-view-patch-teardown)))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
       (setq drgnx-perf-flow--buffers nil)
       t)

     ;; the conversation: blocks, the window the hub sends of them, appends of a step at a time
     (defun drgnx-perf-flow--block-rows (from n)
       (let (rows)
         (dotimes (i n)
           (let ((k (+ from i)))
             (push (drgnx-perf-flow--row (format "k:%d/0" k)
                                         (pcase (% k 4)
                                           (0 (format "  you: change number %d of the inbox drop-down" k))
                                           (1 (format "  Explored · %d files · 2.0 s" (% k 9)))
                                           (2 (format "  The agent explains step %d in a sentence or two." k))
                                           (_ (format "  core/inbox.el +%d −%d   Open  Revert  Comment" (% k 7) (% k 3))))
                                         "agent-panel-subtle")
                   rows)))
         (nreverse rows)))

     (defun drgnx-perf-flow-conversation-open ()
       "(:first-rows MS): the median of 5 opens of a 10k-block conversation: attached, its last window's rows drawn."
       (let ((n (drgnx-perf-flow--size 'blocks)) (w (drgnx-perf-flow--size 'window)) times)
         (dotimes (_ 5)
           (push (drgnx-perf-flow--ms
                  (lambda ()
                    (drgnx-perf-flow--buffer "perf-conversation")
                    (drgnx-perf-flow--send "perf-conversation"
                                           (list (list :reset (drgnx-perf-flow--block-rows (- n w) w))))))
                 times)
           (drgnx-perf-flow-teardown))
         (list :first-rows (drgnx-perf--round (plist-get (drgnx-perf-stats times) :p50)))))

     (defun drgnx-perf-flow-conversation-append ()
       "(:append STATS): each new block (3 rows) inserted after the last, drawn."
       (let* ((n (drgnx-perf-flow--size 'blocks)) (w (drgnx-perf-flow--size 'window)) times)
         (drgnx-perf-flow--buffer "perf-conversation")
         (drgnx-perf-flow--send "perf-conversation" (list (list :reset (drgnx-perf-flow--block-rows (- n w) w))))
         (dotimes (i (drgnx-perf-flow--size 'appends))
           (let ((at (+ n i)))
             (push (drgnx-perf-flow--ms
                    (lambda ()
                      (drgnx-perf-flow--send "perf-conversation"
                                             (list (list :insert (list :after (format "k:%d/0" (1- at))
                                                                       :rows (drgnx-perf-flow--block-rows at 1)))))))
                   times)))
         (list :append (mapcar #'drgnx-perf--round (drgnx-perf-stats times)))))

     ;; the Agents side: 30 cards of 3 rows; a streaming agent changes its card's state line
     (defun drgnx-perf-flow--card (i tick)
       (list (drgnx-perf-flow--row (format "card:s%d:0" i) (format "● agent %d · Claude" i) "kit-agent-1")
             (drgnx-perf-flow--row (format "card:s%d:1" i) (format "Task %d of the inbox plan" i))
             (drgnx-perf-flow--row (format "card:s%d:2" i)
                                   (format "running · $%.2f/$5 · %d/6   Open" (* 0.01 tick) (% tick 6))
                                   "kit-progress")))

     (defun drgnx-perf-flow--side-up ()
       (drgnx-perf-flow--buffer "perf-agents-side")
       (drgnx-perf-flow--send "perf-agents-side"
                              (list (list :reset (cl-loop for i below (drgnx-perf-flow--size 'agents)
                                                          append (drgnx-perf-flow--card i 0))))))

     (defun drgnx-perf-flow-agents-side-stream ()
       "(:patch STATS): one agent's card replaced (only its rows), drawn; the 30 agents in turn."
       (drgnx-perf-flow--side-up)
       (let ((a (drgnx-perf-flow--size 'agents)) times)
         (dotimes (k (drgnx-perf-flow--size 'patches))
           (push (drgnx-perf-flow--ms
                  (lambda () (drgnx-perf-flow--send "perf-agents-side"
                                                    (list (list :replace (drgnx-perf-flow--card (% k a) k))))))
                 times))
         (list :patch (mapcar #'drgnx-perf--round (drgnx-perf-stats times)))))

     (defun drgnx-perf-flow--keys (patch)
       "The median ms of a typed character in a scratch composer, with PATCH (a function) run before each key."
       (let ((c (get-buffer-create " *perf-flow composer*")) times)
         (push c drgnx-perf-flow--buffers)
         (with-current-buffer c
           (dotimes (k (drgnx-perf-flow--size 'keys))
             (when patch (funcall patch k))
             (push (drgnx-perf-flow--ms (lambda () (insert "x") (redisplay t))) times)))
         (plist-get (drgnx-perf-stats times) :p50)))

     (defun drgnx-perf-flow-agents-side-typing ()
       "(:delta MS): what a key in the composer costs more while the side streams (its median with, less without)."
       (drgnx-perf-flow--side-up)
       (let* ((a (drgnx-perf-flow--size 'agents))
              (quiet (drgnx-perf-flow--keys nil))
              (busy (drgnx-perf-flow--keys
                     (lambda (k) (drgnx-perf-flow--send "perf-agents-side"
                                                        (list (list :replace (drgnx-perf-flow--card (% k a) k))))))))
         (list :delta (drgnx-perf--round (max 0 (- busy quiet))))))

     ;; a look change: three frames' views (Work, the Agents side, a conversation) take a reset each
     (defun drgnx-perf-flow-look-reset-3-frames ()
       "(:reset MS): the median of 5: three frames' Work, Agents side and conversation views each reset and drawn."
       (let ((views (list (cons "perf-work" (drgnx-perf-flow--size 'work))
                          (cons "perf-agents-side" (* 3 (drgnx-perf-flow--size 'agents)))
                          (cons "perf-conversation" (drgnx-perf-flow--size 'window))))
             times)
         (dotimes (f 3)
           (dolist (v views)
             (drgnx-perf-flow--buffer (format "%s-%d" (car v) f))
             (drgnx-perf-flow--send (format "%s-%d" (car v) f)
                                    (list (list :reset (drgnx-perf-flow--block-rows 0 (cdr v)))))))
         (dotimes (r 5)
           (push (drgnx-perf-flow--ms
                  (lambda ()
                    (dotimes (f 3)
                      (dolist (v views)
                        (drgnx-perf-flow--send (format "%s-%d" (car v) f)
                                               (list (list :reset (drgnx-perf-flow--block-rows r (cdr v)))))))))
                 times))
         (list :reset (drgnx-perf--round (plist-get (drgnx-perf-stats times) :p50)))))

     ;; the Budgets page: 3 meters with 8 days of history, then the first page of 500 scopes
     (defun drgnx-perf-flow--budget-rows ()
       (let (rows)
         (dotimes (m (drgnx-perf-flow--size 'meters))
           (push (drgnx-perf-flow--row (format "pace:p%d:week" m)
                                       (format "Claude · week %d %% used · +0.4 %%/h · estimate" (* 10 m)) "kit-progress")
                 rows)
           (push (drgnx-perf-flow--row (format "pace:p%d:week:history" m)
                                       (mapconcat #'identity (make-list (drgnx-perf-flow--size 'days) "▆") " "))
                 rows))
         (dotimes (s (min (drgnx-perf-flow--size 'page) (drgnx-perf-flow--size 'scopes)))
           (push (drgnx-perf-flow--row (format "scope:plan:p%d" s)
                                       (format "%sPlan %d  ~$%d.00  limit 40  forecast $20–$30  ok"
                                               (make-string (* 2 (% s 3)) ?\s) s (% s 40))
                                       "kit-progress-meter-fill")
                 rows))
         (nreverse rows)))

     (defun drgnx-perf-flow-budget-page-open ()
       "(:first-rows MS): the median of 5 opens: the meters and the first page of the scope tree drawn."
       (let (times)
         (dotimes (_ 5)
           (push (drgnx-perf-flow--ms
                  (lambda ()
                    (drgnx-perf-flow--buffer "perf-budgets")
                    (drgnx-perf-flow--send "perf-budgets" (list (list :reset (drgnx-perf-flow--budget-rows))))))
                 times)
           (drgnx-perf-flow-teardown))
         (list :first-rows (drgnx-perf--round (plist-get (drgnx-perf-stats times) :p50)))))
     t)
  "The library the Flow workloads evaluate in the session.")

(defconst drgnx-perf-flow--names
  '(conversation-open conversation-append agents-side-stream agents-side-typing look-reset-3-frames budget-page-open)
  "The workloads, each measured by `drgnx-perf-flow-NAME'.")

(defun drgnx-perf-flow-workloads ()
  "The Flow workloads, in the shape of `drgnx-perf-run--workloads'."
  (mapcar (lambda (name)
            (list name
                  :setup (prin1-to-string `(progn ,drgnx-perf-flow--lib (drgnx-perf-flow-setup)))
                  :measure (format "(prog1 (drgnx-perf-flow-%s) (drgnx-perf-flow-teardown))" name)
                  :teardown "(drgnx-perf-flow-teardown)"))
          drgnx-perf-flow--names))

(provide 'drgnx-perf-flow)
;;; drgnx-perf-flow.el ends here
