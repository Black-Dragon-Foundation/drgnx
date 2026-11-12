;;; debug-memory-test.el --- batch tests: the memory view reads and writes a variable's bytes -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; What the view asks of the hub (`debug/read-memory', `debug/write-memory') is recorded and answered here.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)

(defmacro debug-memory-test--with (&rest body)
  "BODY with the hub's calls recorded in CALLS (newest first) as (METHOD PARAMS CALLBACK), the view's buffer killed
after."
  (declare (indent 0))
  `(let ((calls nil))
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params cb &rest _) (push (list method params cb) calls))))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (eq (buffer-local-value 'major-mode b) 'drgnx-debug-memory-mode) (kill-buffer b)))))))

(defun debug-memory-test--answer (calls bytes &optional unreadable)
  "Answer the newest call of CALLS: BYTES (a unibyte string) from 0x1000 plus UNREADABLE bytes."
  (funcall (nth 2 (car calls))
           (append (list :address "0x1000" :data (base64-encode-string bytes))
                   (and unreadable (list :unreadable unreadable)))
           nil))

(ert-deftest drgnx-debug-memory/reads-a-page-as-hex-and-text ()
  "A variable's memory: a page read from its reference (`debug/read-memory'), shown 16 bytes a line with the
address, the bytes in hex and as text (`.' for the unprintable); bytes the program cannot give show as `??'."
  (debug-memory-test--with
    (drgnx-debug-memory-open "s1" "0x1000" "buf")
    (should (equal (cadr (car calls)) (list :session "s1" :reference "0x1000" :offset 0
                                            :count drgnx-debug-memory-page-bytes)))
    (debug-memory-test--answer calls (concat "hello world!" (unibyte-string 0 1 2 3 255) "x") 2)
    (with-current-buffer "*Memory: buf*"
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (concat "00001000  68 65 6c 6c 6f 20 77 6f 72 6c 64 21 00 01 02 03  hello world!....\n"
                             "00001010  ff 78 ?? ??                                      .x  \n"))))))

(ert-deftest drgnx-debug-memory/pages-and-writes ()
  "The next and previous pages (never before the reference); a write at the byte under point sends the bytes typed
in hex (`debug/write-memory', base64) and reads the page again."
  (debug-memory-test--with
    (drgnx-debug-memory-open "s1" "0x1000" "buf")
    (debug-memory-test--answer calls "abcdef")
    (with-current-buffer "*Memory: buf*"
      (drgnx-debug-memory-next)
      (should (equal (plist-get (cadr (car calls)) :offset) drgnx-debug-memory-page-bytes))
      (debug-memory-test--answer calls "ghij")
      (drgnx-debug-memory-previous)
      (should (equal (plist-get (cadr (car calls)) :offset) 0))
      (debug-memory-test--answer calls "abcdef")
      (let ((n (length calls)))
        (drgnx-debug-memory-previous)
        (should (= n (length calls))))
      (goto-char (point-min))
      (search-forward "63")                ; the third byte, `c'
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "41 42")))
        (drgnx-debug-memory-write))
      (should (equal (cadr (car calls)) (list :session "s1" :reference "0x1000" :offset 2 :data "QUI=")))
      (funcall (nth 2 (car calls)) (list :written 2) nil)
      (should (equal (car (car calls)) "debug/read-memory"))
      (should-error (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "4"))) (drgnx-debug-memory-write))
                    :type 'user-error))))

(ert-deftest drgnx-debug-memory/opened-from-a-variable-row ()
  "View Binary Data on a Variables row opens its memory in its session; a row without a memory reference says so."
  (debug-memory-test--with
    (let ((fields '(("memory_reference" . "0x2000") ("label" . "data"))) (id "v:s7:Locals/data"))
      (cl-letf (((symbol-function 'drgnx-debug-view--value-node) (lambda () id))
                ((symbol-function 'drgnx-debug-view--field) (lambda (name _id) (cdr (assoc name fields)))))
        (drgnx-debug-view-memory)
        (should (equal (cadr (car calls)) (list :session "s7" :reference "0x2000" :offset 0
                                                :count drgnx-debug-memory-page-bytes)))
        (should (get-buffer "*Memory: data*"))
        (setq fields '(("label" . "n")))
        (should-error (drgnx-debug-view-memory) :type 'user-error)))))

;;; debug-memory-test.el ends here
