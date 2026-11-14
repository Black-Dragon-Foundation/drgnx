;;; mod-notebook-test.el --- batch tests: the notebook buffer (cell blocks, boundaries, tails, commands) -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The hub is outside this buffer: its answers are a function the tests bind (`drgnx-notebook--call'), the buffer is real.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defvar nb-test--calls nil "The hub calls made, newest first: (METHOD . PARAMS).")
(defvar nb-test--answers nil "Alist METHOD → a function of PARAMS returning (RESULT . ERROR).")

(defun nb-test--hub (method params &optional callback)
  (push (cons method params) nb-test--calls)
  (let ((answer (funcall (or (cdr (assoc method nb-test--answers)) (lambda (_) (cons nil nil))) params)))
    (when callback (funcall callback (car answer) (cdr answer)))
    (car answer)))

(defconst nb-test--opened
  '(:id "nb1" :language "python" :kernelspec "python3"
        :cells ((:id "a" :type "code" :source "x = 1\nx" :execution_count 3)
                (:id "b" :type "markdown" :source "# Title")
                (:id "c" :type "code" :source "print(2)"))
        :tails nil))

(defmacro nb-test--with (&rest body)
  "BODY in a notebook buffer holding `nb-test--opened', the module on, the hub a recorder."
  (declare (indent 0))
  `(drgnx-test-with-modules '(lang/notebook) :strict t
                            (let ((nb-test--calls nil) (nb-test--answers nil))
                              (cl-letf (((symbol-function 'drgnx-notebook--call) (lambda (m p cb) (nb-test--hub m p cb)))
                                        ((symbol-function 'drgnx-notebook--call-sync) (lambda (m p &optional _t) (nb-test--hub m p))))
                                (let ((buf (generate-new-buffer "*nb-test*"))) ; not with-temp-buffer: it runs no buffer hooks
                                  (unwind-protect
                                      (with-current-buffer buf
                                        (drgnx-notebook-mode)
                                        (drgnx-notebook--install nb-test--opened)
                                        ,@body)
                                    (with-current-buffer buf (set-buffer-modified-p nil))
                                    (kill-buffer buf)
                                    (clrhash drgnx-notebook--buffers)))))))

(defun nb-test--ids () (mapcar (lambda (c) (plist-get c :id)) (drgnx-notebook--rescan)))
(defun nb-test--source (id) (drgnx-notebook--rescan) (drgnx-notebook--cell-source (drgnx-notebook--cell-by-id id)))
(defun nb-test--tail (text &optional version)
  (list :id "nb1" :cell "a" :text text :version (or version 1) :runs nil :images nil :more_lines 0))

(ert-deftest drgnx-notebook/opening-builds-the-cells-from-the-hub ()
  (nb-test--with
    (should (equal (nb-test--ids) '("a" "b" "c")))
    (should (equal (nb-test--source "a") "x = 1\nx"))
    (should-not (buffer-modified-p))
    (should (null buffer-undo-list))
    (should (equal (get-text-property (plist-get (drgnx-notebook--cell-by-id "b") :head) 'drgnx-cell-type) 'markdown))
    (should (string-match-p "\\[3\\]" (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :head) 'before-string)))))

(ert-deftest drgnx-notebook/the-boundaries-are-read-only-and-text-typed-beside-them-is-source ()
  (nb-test--with
    (let ((head (plist-get (drgnx-notebook--cell-by-id "a") :head)))
      (should (get-text-property head 'read-only))
      (goto-char head)
      (should-error (delete-char 1) :type 'text-read-only)
      (goto-char (1+ head))
      (insert "y")                     ; typing beside the head is source
      (should (equal (nb-test--source "a") "yx = 1\nx"))
      (should-not (get-text-property (1+ head) 'drgnx-cell)))))

(ert-deftest drgnx-notebook/kill-region-across-a-boundary-is-a-user-error ()
  (nb-test--with
    (should-error (kill-region (point-min) (point-max)) :type 'user-error)
    (should (equal (nb-test--ids) '("a" "b" "c")))
    ;; inside one cell's source it still kills
    (let ((c (drgnx-notebook--cell-by-id "c")))
      (kill-region (1+ (plist-get c :head)) (+ 3 (plist-get c :head)))
      (should (equal (nb-test--source "c") "int(2)")))))

(ert-deftest drgnx-notebook/add-delete-and-undo ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (drgnx-notebook-add-cell-below)
    (should (= (length (nb-test--ids)) 4))
    (should (equal (nth 0 (nb-test--ids)) "a"))
    (should (member (nth 1 (nb-test--ids)) (nb-test--ids)))
    (let ((new (nth 1 (nb-test--ids))))
      (should-not (member new '("a" "b" "c")))
      (should (equal (nb-test--source new) "")))
    (undo-boundary)
    (drgnx-notebook-delete-cell)
    (should (= (length (nb-test--ids)) 3))))

(ert-deftest drgnx-notebook/an-undo-that-restores-a-boundary-asks-the-hub-for-its-tail ()
  (nb-test--with
    (setq nb-test--answers (list (cons "notebook/tail" (lambda (p) (cons (nb-test--tail (format "tail of %s" (plist-get p :cell))) nil)))))
    (buffer-enable-undo)
    (drgnx-notebook--event "notebook-tail" (nb-test--tail "first" 1)) ; an output was shown for the cell
    (setq nb-test--calls nil)
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (undo-boundary)
    (drgnx-notebook-delete-cell)
    (should (equal (nb-test--ids) '("b" "c")))
    (let ((inhibit-read-only t)) (primitive-undo 1 buffer-undo-list))
    (setq drgnx-notebook--dirty t)
    (should (equal (nb-test--ids) '("a" "b" "c")))
    ;; the restored tail has no overlay string of its own: the hub is asked, and its answer is what shows
    (should (assoc "notebook/tail" nb-test--calls))
    (should (equal (plist-get (cdr (assoc "notebook/tail" nb-test--calls)) :cell) "a"))
    (should (string-search "tail of a" (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :tail) 'after-string)))))

(ert-deftest drgnx-notebook/split-and-merge ()
  (nb-test--with
    (let ((c (drgnx-notebook--cell-by-id "a")))
      (goto-char (+ (plist-get c :head) 1 (length "x = 1\n")))
      (drgnx-notebook-split-cell)
      (should (= (length (nb-test--ids)) 4))
      (should (equal (nb-test--source "a") "x = 1\n"))
      (let ((new (nth 1 (nb-test--ids))))
        (should (equal (nb-test--source new) "x"))
        (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
        (drgnx-notebook-merge-cell-below)
        (should (equal (nb-test--ids) '("a" "b" "c")))
        (should (equal (nb-test--source "a") "x = 1\nx"))))))

(ert-deftest drgnx-notebook/move-swaps-the-cells ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
    (drgnx-notebook-move-cell-up)
    (should (equal (nb-test--ids) '("a" "c" "b")))
    (should (equal (nb-test--source "c") "print(2)"))
    (drgnx-notebook-move-cell-down)
    (should (equal (nb-test--ids) '("a" "b" "c")))
    (should-error (progn (goto-char (point-max)) (drgnx-notebook-move-cell-down)) :type 'user-error)))

(ert-deftest drgnx-notebook/cut-and-paste-mint-a-new-id ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "b") :head)))
    (drgnx-notebook-cut-cell)
    (should (equal (nb-test--ids) '("a" "c")))
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (drgnx-notebook-paste-cell)
    (let ((ids (nb-test--ids)))
      (should (= (length ids) 3))
      (should-not (member (nth 1 ids) '("a" "b" "c")))
      (should (equal (nb-test--source (nth 1 ids)) "# Title"))
      (should (eq (plist-get (drgnx-notebook--cell-by-id (nth 1 ids)) :type) 'markdown)))))

(ert-deftest drgnx-notebook/a-yank-of-a-copied-boundary-is-plain-source-and-a-repeated-id-is-re-minted ()
  (nb-test--with
    ;; a region copied across a boundary carries the property; the yank drops it
    (copy-region-as-kill (plist-get (drgnx-notebook--cell-by-id "a") :head) (+ 2 (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
    (let ((n (length (nb-test--ids)))) (yank) (should (= n (length (nb-test--ids)))))
    (should-not (text-property-not-all (plist-get (drgnx-notebook--cell-by-id "c") :head) (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)) 'drgnx-cell
                                       (get-text-property (plist-get (drgnx-notebook--cell-by-id "c") :head) 'drgnx-cell)))
    ;; a whole cell inserted with its property under an id the buffer has: the rescan gives it a new one
    (let ((inhibit-read-only t) (dup (drgnx-notebook--cell-text "a" 'code "dup")))
      (save-excursion (goto-char (point-max)) (insert dup))
      (setq drgnx-notebook--dirty t)
      (let ((ids (nb-test--ids)))
        (should (= (length ids) 4))
        (should (= (length (delete-dups (copy-sequence ids))) 4))))))

(ert-deftest drgnx-notebook/a-streaming-tail-changes-neither-undo-nor-the-modified-flag ()
  (nb-test--with
    (buffer-enable-undo)
    (let ((undo buffer-undo-list) (chars (buffer-chars-modified-tick)))
      (dotimes (i 50)
        (drgnx-notebook--event "notebook-tail" (nb-test--tail (format "line %d" i) (1+ i))))
      (should (eq undo buffer-undo-list))
      (should (= chars (buffer-chars-modified-tick)))
      (should-not (buffer-modified-p))
      (should (string-search "line 49" (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :tail) 'after-string)))
      ;; an older version never replaces a newer one
      (drgnx-notebook--event "notebook-tail" (nb-test--tail "old" 3))
      (should (string-search "line 49" (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :tail) 'after-string))))))

(ert-deftest drgnx-notebook/the-tail-string-takes-its-faces-from-the-runs ()
  (nb-test--with
    (let ((s (drgnx-notebook--tail-string (list :text "ok\nbad" :runs (list (list :start 3 :end 6 :fg 1 :bold t))))))
      (should (string-suffix-p "\n" s))
      (should (memq 'drgnx-notebook-fg-red (ensure-list (get-text-property 3 'face s))))
      (should (memq 'bold (ensure-list (get-text-property 3 'face s))))
      (should-not (memq 'drgnx-notebook-fg-red (ensure-list (get-text-property 0 'face s)))))
    (should (equal (drgnx-notebook--tail-string (list :text "")) ""))))

(ert-deftest drgnx-notebook/changes-are-not-scanned-per-keystroke ()
  (nb-test--with
    (drgnx-notebook--rescan)
    (let ((n drgnx-notebook--rescans))
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
      (dotimes (_ 100) (insert "z"))
      (should (= n drgnx-notebook--rescans))
      (should drgnx-notebook--dirty)
      (drgnx-notebook--rescan)
      (should (= (1+ n) drgnx-notebook--rescans)))))

(ert-deftest drgnx-notebook/run-syncs-the-cells-then-queues-the-cell ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
    (drgnx-notebook-run-cell)
    (let ((calls (reverse nb-test--calls)))
      (should (equal (mapcar #'car calls) '("notebook/sync" "notebook/execute")))
      (should (= 3 (length (plist-get (cdar calls) :cells))))
      (should (equal (mapcar (lambda (c) (plist-get c :id)) (plist-get (cdr (cadr calls)) :cells)) '("c")))
      (should (equal (plist-get (aref (plist-get (cdr (cadr calls)) :cells) 0) :source) "print(2)")))))

(ert-deftest drgnx-notebook/run-all-runs-the-code-cells-in-order ()
  (nb-test--with
    (drgnx-notebook-run-all)
    (should (equal (mapcar (lambda (c) (plist-get c :id)) (plist-get (cdr (assoc "notebook/execute" nb-test--calls)) :cells)) '("a" "c")))))

(ert-deftest drgnx-notebook/a-kernel-that-is-not-started-is-started-then-the-cell-runs ()
  (nb-test--with
    (let ((n 0))
      (setq nb-test--answers
            (list (cons "notebook/execute" (lambda (_) (if (> (cl-incf n) 1) (cons nil nil) (cons nil "this notebook has no kernel"))))
                  (cons "notebook/start" (lambda (_) (cons (list :kernel "python3") nil)))))
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
      (drgnx-notebook-run-cell)
      (should (equal (delete "notebook/tail" (mapcar #'car (reverse nb-test--calls)))
                     '("notebook/sync" "notebook/execute" "notebook/start" "notebook/sync" "notebook/execute"))))))

(ert-deftest drgnx-notebook/status-events-show-the-running-prompt ()
  (nb-test--with
    (drgnx-notebook--event "notebook-status" (list :id "nb1" :state "busy" :cell "c" :queue 0))
    (should (string-search "[*]" (overlay-get (plist-get (drgnx-notebook--chrome-of "c") :head) 'before-string)))
    (drgnx-notebook--event "notebook-status" (list :id "nb1" :state "idle" :cell nil :queue 0))
    (should-not (string-search "[*]" (overlay-get (plist-get (drgnx-notebook--chrome-of "c") :head) 'before-string)))
    (drgnx-notebook--event "notebook-tail" (append (list :cell "c" :execution_count 7) (nb-test--tail "7")))
    (should (string-search "[7]" (overlay-get (plist-get (drgnx-notebook--chrome-of "c") :head) 'before-string)))))

(ert-deftest drgnx-notebook/save-hands-the-cells-to-the-hub ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
    (insert "# edited\n")
    (should (drgnx-notebook--write))
    (let ((save (cdr (assoc "notebook/save" nb-test--calls))))
      (should (equal (plist-get save :id) "nb1"))
      (should (equal (plist-get (aref (plist-get save :cells) 2) :source) "# edited\nprint(2)")))
    (should-not (buffer-modified-p))))

(ert-deftest drgnx-notebook/the-commands-are-in-the-registry ()
  (nb-test--with
    (dolist (id '(notebook-run-cell notebook-run-and-advance notebook-run-all notebook-run-above notebook-run-below notebook-interrupt
                                    notebook-restart notebook-restart-run-all notebook-add-below notebook-add-above notebook-cut-cell notebook-copy-cell
                                    notebook-paste-cell notebook-delete-cell notebook-move-up notebook-move-down notebook-split-cell notebook-merge-cell
                                    notebook-change-type notebook-clear-outputs notebook-select-kernel notebook-open-output notebook-copy-output
                                    notebook-toggle-outputs))
      (should (drgnx-commands-get id)))))

(ert-deftest drgnx-notebook/a-hub-that-says-no-leaves-the-file-as-text ()
  (drgnx-test-with-modules '(lang/notebook) :strict t
                           (cl-letf (((symbol-function 'drgnx-notebook--call) (lambda (_m _p cb) (funcall cb nil "not a notebook"))))
                             (with-temp-buffer
                               (setq buffer-file-name "/tmp/not-a-notebook.ipynb")
                               (insert "{}")
                               (unwind-protect (progn (drgnx-notebook-mode) (should-not buffer-read-only) (should (equal (buffer-string) "{}")))
                                 (setq buffer-file-name nil))))))

(provide 'mod-notebook-test)
;;; mod-notebook-test.el ends here
