;;; notebook-live-test.el --- batch tests: a notebook buffer against a real hub (the notebook/* methods) -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; A real hub as its own process holds the notebook (`notebook/open', `/save', `/kernels', `/clear', `/close', the events) and
;; this Emacs plays the editor inside the delivery gate (`drgnx-test-gated').  Needs the hub's binary (a test-hooks build) and
;; no Sjá (a notebook is not a hub-fed view); skipped without the binary.  No kernel runs here (none is installed in the test image): the
;; notebook's file, its cells, the edit and the save, the kernel list and the answers to a notebook with no kernel are the
;; hub's own.  The recorder tests of the buffer: mod-notebook-test.el.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(dolist (f '("wait-fixture" "ratatoskr-fixture" "delivery-gate-fixture" "runtime-settings-fixture" "hub-client-fixture" "clock-fixture"))
  (load (expand-file-name (concat "test/fixtures/" f) drgnx-dir) nil t))

(defun drgnx-test-hub-settle (pred what)
  "Wait until PRED holds, the hub's clock moved by 100 ms and what it has written released before each look."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (funcall pred)) :what what))

(defmacro notebook-live-test--with-hub (&rest body)
  "BODY with a gated hub this Emacs is connected to (`root' is the hub's root): the hub-client tests' fixtures, as the other
gated tests use them, but without their need for Sjá (a notebook is not a hub-fed view)."
  (declare (indent 0))
  `(drgnx-test-with-clock (:allow-pending t)
     (drgnx-hub-client-test--with-hub
       (drgnx-test-gated '()
         (drgnx-hub-connect)
         (drgnx-test-hub-settle (lambda () (process-live-p drgnx-hub--events)) "the subscribed connection")
         ,@body))))

(defconst notebook-live-test--file
  (concat "{\n \"cells\": [\n  {\n   \"cell_type\": \"markdown\",\n   \"id\": \"intro\",\n   \"metadata\": {},\n"
          "   \"source\": [\n    \"# Title\"\n   ]\n  },\n  {\n   \"cell_type\": \"code\",\n   \"execution_count\": null,\n"
          "   \"id\": \"calc\",\n   \"metadata\": {},\n   \"outputs\": [],\n   \"source\": [\n    \"x = 1\"\n   ]\n  }\n ],\n"
          " \"metadata\": {\n  \"kernelspec\": {\n   \"display_name\": \"Python 3\",\n   \"language\": \"python\",\n"
          "   \"name\": \"python3\"\n  },\n  \"language_info\": {\n   \"name\": \"python\"\n  }\n },\n"
          " \"nbformat\": 4,\n \"nbformat_minor\": 5\n}\n")
  "A notebook as nbformat's writer lays it out: a markdown cell and a code cell, ids, no outputs.")

(defvar notebook-live-test--answers nil "Alist METHOD → (RESULT . ERROR) of the hub's answers a test collected.")

(defun notebook-live-test--ask (method params)
  "Ask the real hub METHOD with PARAMS and wait for the answer (the gate's clock moves meanwhile); (RESULT . ERROR)."
  (let ((done nil) answer)
    (drgnx-notebook--call method params (lambda (r e) (setq done t answer (cons r e))))
    (drgnx-test-hub-settle (lambda () done) (format "the answer to %s" method))
    answer))

(ert-deftest drgnx-notebook-live/a-notebook-opens-edits-and-saves-through-the-hub ()
  (notebook-live-test--with-hub
    (drgnx-test-with-modules '(lang/notebook)
      (let* ((file (expand-file-name "nb.ipynb" root)) buffer)
        (with-temp-file file (insert notebook-live-test--file))
        (setq buffer (find-file-noselect file))
        (unwind-protect
            (with-current-buffer buffer
              (should (eq major-mode 'drgnx-notebook-mode))
              ;; the hub opens it: the buffer becomes the cells, from the hub's answer
              (drgnx-test-hub-settle (lambda () drgnx-notebook--id) "the notebook opened")
              (should (equal (mapcar (lambda (c) (plist-get c :id)) (drgnx-notebook--rescan)) '("intro" "calc")))
              (should (equal (drgnx-notebook--cell-source (drgnx-notebook--cell-by-id "calc")) "x = 1"))
              (should (eq (plist-get (drgnx-notebook--cell-by-id "intro") :type) 'markdown))
              (should-not (buffer-modified-p))
              ;; an edit and a save: the hub writes the file, changing only the edited cell
              (goto-char (plist-get (drgnx-notebook--cell-by-id "calc") :tail))
              (insert "\ny = 2")
              (let ((saved nil))
                (drgnx-notebook--call "notebook/save" (list :id drgnx-notebook--id :cells (drgnx-notebook--sync-cells))
                                      (lambda (r e) (setq saved (list r e))))
                (drgnx-test-hub-settle (lambda () saved) "the save")
                (should (equal saved '(t nil))))
              (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
                (should (string-search "\"x = 1\\n\",\n    \"y = 2\"" text))
                ;; the markdown cell's bytes are the file's, untouched
                (should (string-prefix-p (substring notebook-live-test--file 0 (string-search "  {\n   \"cell_type\": \"code\"" notebook-live-test--file)) text)))
              ;; with no kernel: a tail comes from the file, the kernel list answers, running says there is none
              (let ((tail (notebook-live-test--ask "notebook/tail" (list :id drgnx-notebook--id :cell "calc"))))
                (should-not (cdr tail))
                (should (equal (plist-get (car tail) :cell) "calc"))
                (should (plist-get (plist-get (car tail) :head) :text)))
              (let ((kernels (notebook-live-test--ask "notebook/kernels" nil)))
                (should-not (cdr kernels))
                (should (listp (plist-get (car kernels) :kernels))))
              (let ((run (notebook-live-test--ask "notebook/execute"
                                                  (list :id drgnx-notebook--id
                                                        :cells (vector (list :id "calc" :type "code" :source "x = 1"))))))
                (should (string-search "no kernel" (or (cdr run) ""))))
              (should (equal (notebook-live-test--ask "notebook/clear" (list :id drgnx-notebook--id)) '(t)))
              ;; a notebook that is not this connection's is refused
              (let ((other (notebook-live-test--ask "notebook/tail" (list :id "nb-not-mine" :cell "calc"))))
                (should (cdr other))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))))

;; A hub that came back holds no notebook: the old id is refused, the file is opened again and the buffer's cells (the unsaved edit) go to it.
(ert-deftest drgnx-notebook-live/a-hub-that-forgot-the-notebook-gets-it-again-with-the-unsaved-edit ()
  (notebook-live-test--with-hub
    (drgnx-test-with-modules '(lang/notebook)
      (let* ((file (expand-file-name "nb2.ipynb" root)) buffer)
        (with-temp-file file (insert notebook-live-test--file))
        (setq buffer (find-file-noselect file))
        (unwind-protect
            (with-current-buffer buffer
              (drgnx-test-hub-settle (lambda () drgnx-notebook--id) "the notebook opened")
              (let ((old drgnx-notebook--id))
                (goto-char (plist-get (drgnx-notebook--cell-by-id "calc") :tail))
                (insert "\ny = 2")
                ;; the hub forgets the notebook, as a restarted one does
                (should (equal (notebook-live-test--ask "notebook/close" (list :id old)) '(t)))
                (should (cdr (notebook-live-test--ask "notebook/tail" (list :id old :cell "calc"))))
                (drgnx-notebook--reconnect)
                (drgnx-test-hub-settle (lambda () (not (equal drgnx-notebook--id old))) "the notebook opened again")
                (should (eq (gethash drgnx-notebook--id drgnx-notebook--buffers) buffer))
                (drgnx-test-hub-settle (lambda () (gethash "calc" drgnx-notebook--known)) "the cells taken")
                (should (buffer-modified-p))
                (should (equal (drgnx-notebook--cell-source (drgnx-notebook--cell-by-id "calc")) "x = 1\ny = 2"))
                ;; the new hub has the unsaved text: a save writes it
                (let ((saved nil))
                  (drgnx-notebook--call "notebook/save" (list :id drgnx-notebook--id) (lambda (r e) (setq saved (list r e))))
                  (drgnx-test-hub-settle (lambda () saved) "the save")
                  (should (equal saved '(t nil))))
                (should (string-search "\"x = 1\\n\",\n    \"y = 2\"" (with-temp-buffer (insert-file-contents file) (buffer-string))))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))))

(provide 'notebook-live-test)
;;; notebook-live-test.el ends here
