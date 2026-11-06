;;; replace-blocks-test.el --- Replace's rescan reads a file off the main thread -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): `nidhogg-read-file-async' and `nidhogg-insert-file-block' are stubbed to their documented contract (the
;; callback gets a block, or nil and an error; the insert puts the file's text after point); Nidhogg's own `file-block'
;; rows prove the real ones.  The order cases are replace-blocks-orders-test.el.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'eglot)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
(defvar nidhogg-workers-framing)        ; a `let' of it binds it dynamically, also on an Emacs without the feature

(defmacro drgnx-replace-blocks-test--with (file &rest body)
  "BODY with FILE a fixture file of three lines, two of them matching \"foo\", in a view-like buffer that lists it; the
primitives stubbed (READS: (FILE . CALLBACK) newest first; RESCANS: (FILE BLOCK) the rescans made)."
  (declare (indent 1))
  `(let ((,file (make-temp-file "drgnx-blocks" nil ".txt" "foo one\nbar\nfoo two\n")) reads rescans (nidhogg-workers-framing t))
     (unwind-protect
         (with-temp-buffer
           (setq drgnx-replace--listed (make-hash-table :test #'equal) drgnx-replace--root (file-name-directory ,file)
                 drgnx-replace--opts nil drgnx-replace--rs (drgnx-replace--rs-make))
           (puthash ,file t drgnx-replace--listed)
           (cl-letf (((symbol-function 'nidhogg-set-process-framing) #'ignore)
                     ((symbol-function 'nidhogg-directory-files-async) #'ignore)
                     ((symbol-function 'nidhogg-read-file-async) (lambda (f cb &rest _) (push (cons f cb) reads) 1))
                     ((symbol-function 'nidhogg-insert-file-block) (lambda (block) (insert-file-contents (plist-get block :file))))
                     ((symbol-function 'drgnx-replace--text) (lambda (name) (if (eq name 'find) "foo" "")))
                     ((symbol-function 'drgnx-replace--update-status) #'ignore))
             ,@body))
       (delete-file ,file))))

(defun drgnx-replace-blocks-test--key (matches)
  (mapcar (lambda (m) (list (plist-get m :file) (plist-get m :line) (plist-get m :text))) matches))

(ert-deftest drgnx-replace-blocks/same-matches ()
  "Pattern D: a file scanned from its block gives the matches it gives scanned from disk."
  (drgnx-replace-blocks-test--with file
    (let ((disk (drgnx-replace--scan file)) (block (drgnx-replace--scan file (list :file file))))
      (should (= (length disk) 2))
      (should (equal (drgnx-replace-blocks-test--key block) (drgnx-replace-blocks-test--key disk))))))

(ert-deftest drgnx-replace-blocks/a-changed-file-is-read-off-the-main-thread-and-shown-when-the-block-lands ()
  "Pattern D: after the pause the changed file with no buffer is read by the primitive; its rows move when the block lands,
from that block."
  (drgnx-replace-blocks-test--with file
    (cl-letf (((symbol-function 'drgnx-replace--rescan) (lambda (f &optional b) (push (list f b) rescans))))
      (drgnx-replace--rs-feed (list 'file-changed file))
      (drgnx-replace--rs-feed '(tick))
      (should (= (length reads) 1))
      (should-not rescans)
      (funcall (cdar reads) (list :file file) nil)
      (should (equal rescans (list (list file (list :file file))))))))

(ert-deftest drgnx-replace-blocks/not-started-rescans-now ()
  "Pattern D: a read that did not start lands at once without a block, and the rescan reads the file itself."
  (drgnx-replace-blocks-test--with file
    (cl-letf (((symbol-function 'drgnx-replace--rescan) (lambda (f &optional b) (push (list f b) rescans)))
              ((symbol-function 'nidhogg-read-file-async) (lambda (&rest _) nil)))
      (drgnx-replace--rs-feed (list 'file-changed file))
      (drgnx-replace--rs-feed '(tick))
      (should (equal rescans (list (list file nil)))))))

(ert-deftest drgnx-replace-blocks/a-file-with-a-buffer-or-without-the-workers-is-rescanned-at-once ()
  "Pattern D: a file some buffer visits, or any file when the workers are off, takes the synchronous rescan."
  (drgnx-replace-blocks-test--with file
    (should (drgnx-replace--async-file-p file))
    (let ((nidhogg-workers-framing nil)) (should-not (drgnx-replace--async-file-p file)))
    (cl-letf (((symbol-function 'find-buffer-visiting) (lambda (_) (current-buffer))))
      (should-not (drgnx-replace--async-file-p file)))))

(ert-deftest drgnx-replace-blocks/the-core-does-not-change-the-state-it-is-given ()
  "Pattern D: `drgnx-replace--rescan-step' is pure."
  (let* ((s (drgnx-replace--rs-make :pending '("a") :inflight '(("b" . 1)) :counter 1))
         (slots (lambda () (list (copy-sequence (drgnx-replace--rs-pending s)) (copy-tree (drgnx-replace--rs-inflight s))
                                 (drgnx-replace--rs-counter s)))))
    (dolist (ev '((file-changed "b") (tick) (block-landed "b" 1) (new-search) (replace)))
      (let ((before (funcall slots)))
        (drgnx-replace--rescan-step s ev)
        (should (equal before (funcall slots)))))))
