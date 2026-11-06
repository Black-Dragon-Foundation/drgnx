;;; file-stream-test.el --- the file listing stream's conversions, and when it is off -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure).  The records come from the real framer when this Emacs has it (`nidhogg-workers--test-frame'), else
;; from the shape its batches have.  No process.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-file-stream)
(defvar nidhogg-workers-framing)        ; a `let' of it binds it dynamically, also on an Emacs without the feature

(ert-deftest drgnx-file-stream/records-become-names ()
  "Pattern D: a records batch gives its names; an entry with an error, a non-string and an empty record are dropped."
  (let ((batch (if (fboundp 'nidhogg-workers--test-frame)
                   (car (nidhogg-workers--test-frame (list (encode-coding-string "a/b é.el\0c.el\0" 'utf-8) "\0d.el\0")
                                                     t 'records :separator 0 :coding 'utf-8-unix))
                 '(("a/b é.el" "raw" nil) ("c.el" "raw" nil) ("" "" nil) ("d.el" "raw" nil)))))
    (should (equal (drgnx-file-stream-record-names batch) '("a/b é.el" "c.el" "d.el"))))
  (should (equal (drgnx-file-stream-record-names '(("x" "x" nil) (nil "y" (error "bad")) ("z" "z" (error "bad")) ("w" "w" nil)))
                 '("x" "w"))))

(ert-deftest drgnx-file-stream/directory-batches-become-file-names ()
  "Pattern D: a directory batch gives its files and symbolic links, not its folders."
  (let ((file (file-attributes (expand-file-name "drgnx-file-stream.el" (file-name-directory (locate-library "drgnx-file-stream")))))
        (dir (file-attributes temporary-file-directory)))
    (should (equal (drgnx-file-stream-directory-names (list (cons "src/a.el" file) (cons "src" dir) (cons "b" (list "/x"))))
                   '("src/a.el" "b")))))

(ert-deftest drgnx-file-stream/off-without-switch ()
  "Pattern D: it streams only a local folder with the feature and the switch; otherwise it starts nothing."
  (let ((called nil))
    (cl-letf (((symbol-function 'nidhogg-set-process-framing) #'ignore)
              ((symbol-function 'nidhogg-directory-files-async) (lambda (&rest _) (setq called t))))
      (let ((nidhogg-workers-framing t))
        (should (drgnx-file-stream-available-p "/tmp/x/"))
        (should-not (drgnx-file-stream-available-p "/ssh:host:/tmp/x/")))
      (let ((nidhogg-workers-framing nil))
        (should-not (drgnx-file-stream-available-p "/tmp/x/"))
        (should-not (drgnx-file-stream-start "/tmp/x/" #'ignore #'ignore))))
    (let ((nidhogg-workers-framing t))
      (cl-letf (((symbol-function 'nidhogg-directory-files-async) nil))
        (should-not (drgnx-file-stream-available-p "/tmp/x/"))))
    (should-not called)))
