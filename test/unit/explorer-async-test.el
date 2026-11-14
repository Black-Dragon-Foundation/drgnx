;;; explorer-async-test.el --- the Explorer reads a folder off the main thread -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): `nidhogg-directory-files-async' is stubbed to its documented contract (callback batches in order,
;; DONE last; nil when it did not start); Nidhogg's own `dir-equivalence' rows prove the real one.  No process, no timer.
;; The order cases are explorer-async-orders-test.el.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-explorer)
(defvar nidhogg-workers-framing)        ; a `let' of it binds it dynamically, also on an Emacs without the feature

(defmacro drgnx-explorer-async-test--with (root &rest body)
  "BODY with ROOT a fixture folder, the read primitive stubbed (CALLBACKS: (DIR . CALLBACK) newest first, STARTS: whether
it starts), `drgnx-explorer--patch-dir' recorded (PATCHED), and the workers on."
  (declare (indent 1))
  `(let ((,root (file-name-as-directory (make-temp-file "drgnx-async" t)))
         (drgnx-explorer--reads (make-hash-table :test #'equal))
         (drgnx-explorer--read-mtimes (make-hash-table :test #'equal))
         (nidhogg-workers-framing t) (drgnx-explorer--async-reads nil) callbacks patched (starts t))
     (unwind-protect
         (progn
           (dolist (n '("a.txt" "B.el" "c2.md" "c10.md" ".git/x" "src/m.py" "docs/g.md"))
             (let ((f (expand-file-name n ,root)))
               (make-directory (file-name-directory f) t)
               (write-region "" nil f nil 'silent)))
           (drgnx-cache--clear 'explorer-listing)
           (cl-letf (((symbol-function 'nidhogg-set-process-framing) #'ignore)
                     ((symbol-function 'nidhogg-directory-files-async)
                      (lambda (dir cb &rest _) (when starts (push (cons dir cb) callbacks) 1)))
                     ((symbol-function 'drgnx-explorer--patch-dir) (lambda (d) (push d patched))))
             ,@body))
       (drgnx-cache--clear 'explorer-listing)
       (delete-directory ,root t))))

(ert-deftest drgnx-explorer-async/same-tree ()
  "Pattern D: a fixture folder lists the same rows read at once and read off the main thread in two batches, and the
rows are put in place once, when the last batch is in."
  (drgnx-explorer-async-test--with root
    (let ((sync (drgnx-explorer-children root)))
      (should (equal (mapcar #'car sync) '("docs" "src" "a.txt" "B.el" "c2.md" "c10.md")))
      (drgnx-cache--clear 'explorer-listing)
      (let ((drgnx-explorer--async-reads t))
        (should (equal (drgnx-explorer-children root) '(("…" . nil))))     ; no cached rows: the one reading row
        (should (equal (drgnx-explorer-children root) '(("…" . nil))))     ; another look starts no second read
        (should (= (length callbacks) 1)))
      (let* ((all (directory-files-and-attributes root nil nil t)) (cb (cdar callbacks)))
        (funcall cb (seq-take all 3) nil nil)
        (should-not patched)
        (funcall cb (seq-drop all 3) t nil))
      (should (equal patched (list root)))
      (should (equal (drgnx-explorer-children root) sync)))))

(ert-deftest drgnx-explorer-async/a-stale-folder-shows-its-cached-rows-while-it-is-read ()
  "Pattern D: a folder whose modification time changed shows the rows it had until the read ends."
  (drgnx-explorer-async-test--with root
    (let ((had (drgnx-explorer-children root)))
      (set-file-times root (time-add (current-time) 10))
      (let ((drgnx-explorer--async-reads t))
        (should (equal (drgnx-explorer-children root) had))
        (should (= (length callbacks) 1))))))

(ert-deftest drgnx-explorer-async/not-started-reads-now ()
  "Pattern D: a read that did not start (the primitive returns nil) is read at once, as without the workers."
  (drgnx-explorer-async-test--with root
    (let ((sync (drgnx-explorer-children root)))
      (drgnx-cache--clear 'explorer-listing)
      (setq starts nil)
      (let ((drgnx-explorer--async-reads t))
        (should (equal (drgnx-explorer-children root) sync))
        (should-not callbacks)))))

(ert-deftest drgnx-explorer-async/off-without-the-switch-or-for-a-full-render ()
  "Pattern D: without the workers' switch, or outside a command or event that shows a folder, nothing is read off the
main thread."
  (drgnx-explorer-async-test--with root
    (let ((sync (drgnx-explorer-children root)))
      (drgnx-cache--clear 'explorer-listing)
      (should (equal (drgnx-explorer-children root) sync))                ; async-reads is nil
      (should-not callbacks)
      (drgnx-cache--clear 'explorer-listing)
      (let ((drgnx-explorer--async-reads t) (nidhogg-workers-framing nil))
        (should (equal (drgnx-explorer-children root) sync))
        (should-not callbacks)))))

(ert-deftest drgnx-explorer-async/the-core-does-not-change-the-state-it-is-given ()
  "Pattern D: `drgnx-explorer--read-step' is pure: the state given is the state after, whatever the event."
  (let* ((s (drgnx-explorer--read-make))
         (slots (lambda () (cl-loop for slot in '(expanded gen reading acc dirty)
                                    collect (cl-struct-slot-value 'drgnx-explorer--read slot s)))))
    (dolist (ev '((expand) (collapse) (changed) (refresh) (batch 1 (("a" . nil))) (done 1)))
      (let ((before (funcall slots)))
        (drgnx-explorer--read-step s ev)
        (should (equal before (funcall slots)))))
    (let ((r (car (drgnx-explorer--read-step s '(expand)))))
      (should (drgnx-explorer--read-reading r))
      (should-not (drgnx-explorer--read-reading s)))))
