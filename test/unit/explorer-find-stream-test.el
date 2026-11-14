;;; explorer-find-stream-test.el --- Find in Explorer reads its files in batches -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the listing is stubbed to its contract (batches in order, none after a stop); no process, no timer.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-explorer)

(defmacro drgnx-explorer-find-stream-test--with (&rest body)
  "BODY with Find's state fresh, the debounce recorded in REFILTERS, and the generation counter as it is."
  (declare (indent 0))
  `(let ((drgnx-explorer--find nil) (drgnx-explorer--find-streams nil) (refilters 0)
         (drgnx-explorer--roots '("/r/")))
     (cl-letf (((symbol-function 'drgnx-timer-debounce) (lambda (&rest _) (cl-incf refilters))))
       ,@body)))

(ert-deftest drgnx-explorer-find-stream/batches-add-files-in-order ()
  "Pattern D: a batch of the current generation adds its files (not the excluded names) after those read; an older one,
or one after Find ended, adds nothing."
  (drgnx-explorer-find-stream-test--with
    (setq drgnx-explorer--find (list :files '("/r/a.el") :query "e"))
    (let ((gen drgnx-explorer--find-gen))
      (drgnx-explorer--find-batch gen "/r/" '("b.el" ".git/config" "src/__pycache__/y.pyc" "c.el"))
      (should (equal (plist-get drgnx-explorer--find :files) '("/r/a.el" "/r/b.el" "/r/c.el")))
      (should (= refilters 1))
      (drgnx-explorer--find-batch (1- gen) "/r/" '("old.el"))
      (should (equal (plist-get drgnx-explorer--find :files) '("/r/a.el" "/r/b.el" "/r/c.el")))
      (setq drgnx-explorer--find nil)
      (drgnx-explorer--find-batch gen "/r/" '("late.el"))
      (should-not drgnx-explorer--find))))

(ert-deftest drgnx-explorer-find-stream/a-streamed-root-fills-in-and-stop-drops-the-rest ()
  "Pattern D: with a stream available, loading returns nothing at once and the batches fill :files; stopping Find
stops the stream and drops what it delivers afterwards; starting over drops the older listing's batches."
  (drgnx-explorer-find-stream-test--with
    (let (callbacks stopped)
      (cl-letf (((symbol-function 'drgnx-file-stream-available-p) (lambda (_) t))
                ((symbol-function 'drgnx-explorer--check-find-root) #'ignore)
                ((symbol-function 'drgnx-file-stream-start)
                 (lambda (_root on-batch _done) (push on-batch callbacks) (drgnx-file-stream--make)))
                ((symbol-function 'drgnx-file-stream-stop) (lambda (s) (push s stopped))))
        (should-not (drgnx-explorer--find-load))
        (setq drgnx-explorer--find (list :files nil :query "e"))
        (funcall (car callbacks) '("a.el"))
        (should (equal (plist-get drgnx-explorer--find :files) '("/r/a.el")))
        (drgnx-explorer--find-load)                                        ; starting over: the first listing is stopped
        (should (= (length stopped) 1))
        (funcall (cadr callbacks) '("stale.el"))
        (should (equal (plist-get drgnx-explorer--find :files) '("/r/a.el")))
        (funcall (car callbacks) '("b.el"))
        (should (equal (plist-get drgnx-explorer--find :files) '("/r/a.el" "/r/b.el")))
        (drgnx-explorer--find-stop)
        (should (= (length stopped) 2))
        (funcall (car callbacks) '("after-stop.el"))
        (should (equal (plist-get drgnx-explorer--find :files) '("/r/a.el" "/r/b.el")))))))

(ert-deftest drgnx-explorer-find-stream/without-a-stream-the-files-are-read-now ()
  "Pattern D: no framing, or a remote root: the files come back from the loading call, as before."
  (drgnx-explorer-find-stream-test--with
    (cl-letf (((symbol-function 'drgnx-file-stream-available-p) (lambda (_) nil))
              ((symbol-function 'drgnx-explorer--root-files) (lambda (root) (list (concat root "x.el")))))
      (should (equal (drgnx-explorer--find-load) '("/r/x.el")))
      (should-not drgnx-explorer--find-streams))))
