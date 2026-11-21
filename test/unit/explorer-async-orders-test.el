;;; explorer-async-orders-test.el --- a folder read off the main thread, against what the user does, in every order -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: orders
;; Pattern A.  The core (`drgnx-explorer--read-step') takes the user's expand, collapse and refresh, a change of the
;; folder on disk, and the batches and end of the read: three sources in every order they can come in
;; (`drgnx-test-every-order').  The oracle is independent of the core: it keeps what the user did and what the read
;; delivered, and holds every effect the core raises against that.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-explorer)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defun drgnx-explorer-async-orders-test--note (log event)
  "LOG, a plist, after EVENT: what the user did, what the read delivered, when the folder last changed.
:exp (the user's view of expanded), :n (events so far), :last-inval (when the last change or refresh came), :starts
\((GEN . N)...), :got ((GEN . ENTRIES)...), :bad (messages), :patched (how many patches), :stored (how many stores)."
  (let* ((n (1+ (plist-get log :n))) (log (plist-put (copy-sequence log) :n n)) (gen (nth 1 event)))
    (pcase (car event)
      ('expand (plist-put log :exp t))
      ('collapse (plist-put log :exp nil))
      ((or 'changed 'refresh) (plist-put log :last-inval n))
      ('batch (plist-put log :got (cons (cons gen (append (alist-get gen (plist-get log :got)) (nth 2 event) nil))
                                        (assq-delete-all gen (copy-sequence (plist-get log :got))))))
      ('start (plist-put log :starts (cons (cons gen n) (plist-get log :starts))))
      ('store
       (let ((log (plist-put log :stored (1+ (plist-get log :stored)))))
         (if (equal (nth 2 event) (alist-get gen (plist-get log :got))) log
           (plist-put log :bad (cons (format "store %S: entries %S, the read delivered %S" gen (nth 2 event)
                                             (alist-get gen (plist-get log :got)))
                                     (plist-get log :bad))))))
      ('patch
       (let ((log (plist-put log :patched (1+ (plist-get log :patched)))) (started (alist-get gen (plist-get log :starts))))
         (unless (plist-get log :exp)
           (setq log (plist-put log :bad (cons (format "patch %S after a collapse" gen) (plist-get log :bad)))))
         (unless (and started (> started (plist-get log :last-inval)))
           (setq log (plist-put log :bad (cons (format "patch %S of a read that a change or a refresh overtook" gen)
                                               (plist-get log :bad)))))
         log))
      (_ log))))

(defun drgnx-explorer-async-orders-test--run (check-fn)
  "Every order of the user's four events, one change on disk and the read of gen 1 (two batches, then its end).
The read starts after the first expand (an edge).  CHECK-FN gets the oracle's log at the end and returns nil or a message.
The step's state is (CORE . LOG)."
  (drgnx-test-every-order
   :kinds '(expand collapse changed refresh batch done start store patch)
   :sources (list (cons 'user (list '(expand) '(collapse) '(expand) '(refresh)))
                  (cons 'disk (list '(changed)))
                  (cons 'read (list '(batch 1 (("a" . nil) ("b" . t))) '(batch 1 (("c" . nil))) '(done 1))))
   :edges (list (cons (cons 'user 0) (cons 'read 0)))
   :init (lambda () (cons (drgnx-explorer--read-make) (list :exp t :n 0 :last-inval 0 :patched 0 :stored 0)))
   :step (lambda (st ev)
           (let ((log (drgnx-explorer-async-orders-test--note (cdr st) ev)))
             ;; effects are the core's output, not its input
             (if (memq (car ev) '(start store patch))
                 (cons (cons (car st) log) nil)
               (let ((r (drgnx-explorer--read-step (car st) ev)))
                 (cons (cons (car r) log) (cdr r))))))
   :check (lambda (st _order) (funcall check-fn (cdr st)))))

(ert-deftest drgnx-explorer-async/collapse-before-done-shows-nothing-stale ()
  "Pattern A: a folder collapsed before its read ends is not patched; a read that a change on disk or a Refresh overtook
is not shown either (it starts over, or the render that follows reads at once); the cache gets what the read delivered."
  (let ((patched nil) (stored nil))
    (drgnx-explorer-async-orders-test--run
     (lambda (log)
       (setq patched (or patched (> (plist-get log :patched) 0)) stored (or stored (> (plist-get log :stored) 0)))
       (car (reverse (plist-get log :bad)))))
    (should patched)                    ; some order shows the rows, so the check above is not vacuous
    (should stored)))
