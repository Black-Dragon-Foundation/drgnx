;;; replace-blocks-orders-test.el --- Replace's rescan against edits, searches and replaces, in every order -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: orders
;; Pattern A.  The core (`drgnx-replace--rescan-step') takes a file's changes and the pauses after them, a new search and a
;; replace, and the blocks that land, in every order they can come in (`drgnx-test-every-order').  The oracle is independent of
;; the core: it keeps when each read started and what happened since, and holds every `apply' against that.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'eglot)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defun drgnx-replace-blocks-orders-test--note (log event)
  "LOG, a plist, after EVENT.  :n (events so far), :since ((KIND . N)...: the last file-changed / new-search / replace),
:reads (((FILE . GEN) . N)...), :bad (messages), :applied (how many)."
  (let* ((n (1+ (plist-get log :n))) (log (plist-put (copy-sequence log) :n n)))
    (pcase (car event)
      ((or 'file-changed 'new-search 'replace)
       (plist-put log :since (cons (cons (car event) n) (assq-delete-all (car event) (copy-sequence (plist-get log :since))))))
      ('read (plist-put log :reads (cons (cons (cons (nth 1 event) (nth 2 event)) n) (plist-get log :reads))))
      ('apply
       (let* ((started (alist-get (cons (nth 1 event) (nth 2 event)) (plist-get log :reads) nil nil #'equal))
              (log (plist-put log :applied (1+ (plist-get log :applied)))))
         (dolist (kind '(file-changed new-search replace))
           (when (or (null started) (> (or (alist-get kind (plist-get log :since)) 0) started))
             (setq log (plist-put log :bad (cons (format "apply %S: %s came after its read started (or it never started)"
                                                         (cdr event) kind)
                                                 (plist-get log :bad))))))
         log))
      (_ log))))

(defun drgnx-replace-blocks-orders-test--run (check-fn)
  "Every order of two changes of one file each followed by its pause, a new search, a replace and the landing of the
first two reads.  CHECK-FN gets the oracle's log at the end and returns nil or a message."
  (drgnx-test-every-order
   :kinds '(file-changed tick new-search replace block-landed read apply)
   :sources (list (cons 'edits (list '(file-changed "f") '(tick) '(file-changed "f") '(tick)))
                  (cons 'user (list '(new-search) '(replace)))
                  (cons 'disk (list '(block-landed "f" 1) '(block-landed "f" 2))))
   :init (lambda () (cons (drgnx-replace--rs-make) (list :n 0 :applied 0)))
   :step (lambda (st ev)
           (let ((log (drgnx-replace-blocks-orders-test--note (cdr st) ev)))
             (if (memq (car ev) '(read apply))
                 (cons (cons (car st) log) nil)
               (let ((r (drgnx-replace--rescan-step (car st) ev)))
                 (cons (cons (car r) log) (cdr r))))))
   :check (lambda (st _order) (funcall check-fn (cdr st)))))

(ert-deftest drgnx-replace-blocks/stale-block-dropped ()
  "Pattern A: a block that lands after the file changed again, after a new search started or after a replace is dropped:
every rescan that is shown comes from a read that started after the last of those."
  (let ((applied nil))
    (drgnx-replace-blocks-orders-test--run
     (lambda (log)
       (setq applied (or applied (> (plist-get log :applied) 0)))
       (car (reverse (plist-get log :bad)))))
    (should applied)))                  ; some order shows a rescan, so the check above is not vacuous
