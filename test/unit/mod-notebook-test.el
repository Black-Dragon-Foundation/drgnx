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
(defvar nb-test--strict t "Whether the module teardown is checked for state left behind (not with a real grammar: loading its mode adds global hooks).")

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
        :tails ((:cell "a" :version 1 :text "2" :stale t :head (:text "[3]  python" :state "idle" :runs nil)
                       :runs nil :images nil :more_lines 0)))
  "What `notebook/open' answers: the cells, and each code cell's tail with the head the hub built.")

(defmacro nb-test--with (&rest body)
  "BODY in a notebook buffer holding `nb-test--opened', the module on, the hub a recorder."
  (declare (indent 0))
  `(drgnx-test-with-modules '(lang/notebook) :strict nb-test--strict
                            (let ((nb-test--calls nil) (nb-test--answers nil))
                              (cl-letf (((symbol-function 'drgnx-notebook--call) (lambda (m p cb &optional _full) (nb-test--hub m p cb)))
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
    (let ((calls (cl-remove "notebook/focus" (reverse nb-test--calls) :key #'car :test #'equal)))
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
      (should (equal (delete "notebook/focus" (delete "notebook/tail" (mapcar #'car (reverse nb-test--calls))))
                     '("notebook/sync" "notebook/execute" "notebook/start" "notebook/sync" "notebook/execute"))))))

(ert-deftest drgnx-notebook/the-head-is-the-hubs-and-comes-with-a-tail ()
  (nb-test--with
    (let ((head (lambda (id) (overlay-get (plist-get (drgnx-notebook--chrome-of id) :head) 'before-string))))
      ;; the hub's text after the run button; the Lisp strip has no prompt or chips of its own
      (should (string-search "[3]  python" (funcall head "a")))
      (should-not (string-search " code " (funcall head "a")))
      ;; a cell with no head from the hub yet shows its type
      (should (string-search "markdown" (funcall head "b")))
      (should (string-search "markdown" (funcall head "b")))
      ;; a tail brings a new head, its runs' faces on it
      (drgnx-notebook--event "notebook-tail"
                             (append (list :cell "c" :head (list :text "[*]  python" :state "running"
                                                                 :runs (list (list :start 0 :end 3 :fg 3 :bold t))))
                                     (nb-test--tail "7")))
      (let ((s (funcall head "c")))
        (should (string-search "[*]  python" s))
        (should (memq 'drgnx-notebook-fg-yellow (ensure-list (get-text-property (string-search "[*]" s) 'face s))))))))

(ert-deftest drgnx-notebook/status-events-feed-the-status-bar ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "b") :head)))
    (drgnx-notebook--select-at (point))
    (should (equal (drgnx-notebook--segment-cell) "cell 2 of 3 · python"))
    (should (equal (substring-no-properties (drgnx-notebook--segment-kernel)) "no kernel"))
    (setq drgnx-notebook--kernel "python3")
    (drgnx-notebook--event "notebook-status" (list :id "nb1" :state "busy" :cell "c" :queue 2))
    (should (equal (substring-no-properties (drgnx-notebook--segment-kernel)) "● python3 · busy"))
    (should (equal drgnx-notebook--queue 2))
    (drgnx-notebook--event "notebook-status" (list :id "nb1" :state "dead" :queue 0))
    (should (string-search "dead" (drgnx-notebook--segment-kernel)))))

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
                                    notebook-toggle-outputs notebook-outline notebook-kernel-log))
      (should (drgnx-commands-get id)))))

(ert-deftest drgnx-notebook/a-hub-that-says-no-leaves-the-file-as-text ()
  (drgnx-test-with-modules '(lang/notebook) :strict t
                           (cl-letf (((symbol-function 'drgnx-notebook--call) (lambda (_m _p cb &optional _full)
                                                                                (funcall cb nil '(:code "refused" :message "not a notebook")))))
                             (with-temp-buffer
                               (setq buffer-file-name "/tmp/not-a-notebook.ipynb")
                               (insert "{}")
                               (unwind-protect (progn (drgnx-notebook-mode) (should-not buffer-read-only) (should (equal (buffer-string) "{}")))
                                 (setq buffer-file-name nil))))))

(provide 'mod-notebook-test)
;;; mod-notebook-test.el ends here

;;; The look: the terminal roles and the hairline are the themes' (colours only in themes/)

(defun nb-test--theme-attr (variant face attr)
  "ATTR of FACE in the first clause of VARIANT's theme spec."
  (let ((clause (cadr (assq face (drgnx-theme--specs variant)))))
    (plist-get (cdr (car clause)) attr)))

(ert-deftest drgnx-notebook/every-terminal-role-has-a-foreground-and-a-background-face-in-every-theme ()
  (require 'drgnx-theme-gen (expand-file-name "themes/drgnx-theme-gen" drgnx-dir))
  (dolist (variant '(dark light hc))
    (let ((i 0))
      (while (< i 16)
        (let ((name (aref drgnx-notebook--ansi-names i)))
          (should (stringp (nb-test--theme-attr variant (intern (format "drgnx-notebook-fg-%s" name)) :foreground)))
          (should (stringp (nb-test--theme-attr variant (intern (format "drgnx-notebook-bg-%s" name)) :background))))
        (cl-incf i)))
    ;; red is the error token, as the terminal's red is
    (should (equal (nb-test--theme-attr variant 'drgnx-notebook-fg-red :foreground) (drgnx-look-token 'error variant)))
    (should (equal (nb-test--theme-attr variant 'drgnx-notebook-fg-green :foreground) (drgnx-look-token 'ok variant)))))

(ert-deftest drgnx-notebook/the-cell-header-has-the-border-hairline-and-keeps-its-parents ()
  (require 'drgnx-theme-gen (expand-file-name "themes/drgnx-theme-gen" drgnx-dir))
  (dolist (variant '(dark light hc))
    (should (equal (nb-test--theme-attr variant 'drgnx-notebook-head :overline) (drgnx-look-token 'border-subtle variant)))
    (should (equal (nb-test--theme-attr variant 'drgnx-notebook-head :inherit)
                   (plist-get (cdr (car (get 'drgnx-notebook-head 'face-defface-spec))) :inherit)))))

;;; Tree-sitter: one parser per language, its ranges the union of that language's cells

(ert-deftest drgnx-notebook/the-ranges-of-a-language-are-its-cells-source ()
  (nb-test--with
    (let ((ranges (drgnx-notebook--language-ranges)))
      (should (equal (mapcar #'car ranges) '("python" "markdown")))
      (let ((a (drgnx-notebook--cell-by-id "a")) (c (drgnx-notebook--cell-by-id "c")) (b (drgnx-notebook--cell-by-id "b")))
        (should (equal (cdr (assoc "python" ranges))
                       (list (cons (1+ (plist-get a :head)) (plist-get a :tail)) (cons (1+ (plist-get c :head)) (plist-get c :tail)))))
        (should (equal (cdr (assoc "markdown" ranges)) (list (cons (1+ (plist-get b :head)) (plist-get b :tail)))))))
    ;; a raw cell has no language
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "b") :head)))
    (drgnx-notebook-change-cell-type 'raw)
    (should (equal (mapcar #'car (drgnx-notebook--language-ranges)) '("python")))))

(ert-deftest drgnx-notebook/the-language-at-point-is-the-cells ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (should (eq (drgnx-notebook--language-at-point) 'python))
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "b") :head)))
    (should (eq (drgnx-notebook--language-at-point) 'markdown))
    ;; on a boundary: the neighbouring cell's, never an error
    (goto-char (plist-get (drgnx-notebook--cell-by-id "c") :head))
    (should (symbolp (drgnx-notebook--language-at-point)))))

(defun nb-test--python-grammar-p ()
  "Whether a python grammar is here: on the load path, or in the folder DRGNX_TEST_TS_GRAMMARS names (the pack job's)."
  (when-let* ((dir (getenv "DRGNX_TEST_TS_GRAMMARS")) ((file-directory-p dir)))
    (add-to-list 'treesit-extra-load-path dir))
  (let ((here (and (fboundp 'treesit-available-p) (treesit-available-p) (treesit-language-available-p 'python))))
    ;; a grammar that was promised (the unit tier builds one, CI requires it) must be there: a skip would hide its absence
    (when (and (not here) (or (getenv "DRGNX_TEST_TS_GRAMMARS") (getenv "DRGNX_TEST_TS_REQUIRED")))
      (ert-fail "a python grammar was promised (DRGNX_TEST_TS_GRAMMARS or DRGNX_TEST_TS_REQUIRED) and is not loadable"))
    here))

(ert-deftest drgnx-notebook/a-parser-holds-the-included-ranges-of-its-cells ()
  :tags '(:real-grammar)
  (skip-unless (nb-test--python-grammar-p))
  (progn (nb-test--with
           (drgnx-notebook--sync-parsers)
           (let* ((parsers (seq-filter (lambda (p) (eq (treesit-parser-language p) 'python)) (treesit-parser-list)))
                  (ranges (treesit-parser-included-ranges (car parsers))))
             (should (= (length parsers) 1))
             (should (= (length ranges) 2))
             (should (equal (car ranges) (cons (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)) (plist-get (drgnx-notebook--cell-by-id "a") :tail)))))
           ;; the same parser after an edit, not a second one
           (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
           (insert "y = 3\n")
           (drgnx-notebook--rescan)
           (should (= 1 (length (seq-filter (lambda (p) (eq (treesit-parser-language p) 'python)) (treesit-parser-list))))))))

;;; Images: static PNG and JPEG outputs, fetched once from the hub's full output

(defconst nb-test--png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

(defun nb-test--image-tail (version)
  (list :id "nb1" :cell "a" :version version :text (concat "a\n" (string #xfffc) "\nb") :runs nil :more_lines 0
        :images (list (list :at 2 :output 1 :mime "image/png" :width 640 :height 360))))

(ert-deftest drgnx-notebook/an-image-output-is-fetched-once-and-drawn-in-its-place ()
  (nb-test--with
    (setq nb-test--answers
          (list (cons "notebook/output"
                      (lambda (_p) (cons (list :outputs (list (list :output_type "stream" :text "a")
                                                              (list :output_type "display_data" :data (list :image/png nb-test--png))))
                                         nil)))))
    (setq nb-test--calls nil)
    (drgnx-notebook--event "notebook-tail" (nb-test--image-tail 1))
    (let* ((s (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :tail) 'after-string))
           (display (get-text-property 2 'display s)))
      (should (eq (car-safe display) 'image))
      (should (eq (plist-get (cdr display) :type) 'png))
      (should (> (length (plist-get (cdr display) :data)) 20))
      (should (= (length (seq-filter (lambda (c) (equal (car c) "notebook/output")) nb-test--calls)) 1)))
    ;; a newer tail with the same image uses what it has
    (drgnx-notebook--event "notebook-tail" (nb-test--image-tail 2))
    (should (= (length (seq-filter (lambda (c) (equal (car c) "notebook/output")) nb-test--calls)) 1))
    (should (eq (car-safe (get-text-property 2 'display (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :tail) 'after-string))) 'image))))

(ert-deftest drgnx-notebook/an-image-that-is-not-there-yet-or-not-supported-is-a-label ()
  (nb-test--with
    (setq nb-test--answers (list (cons "notebook/output" (lambda (_p) (cons nil "no output")))))
    (drgnx-notebook--event "notebook-tail" (nb-test--image-tail 1))
    (let ((s (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :tail) 'after-string)))
      (should-not (get-text-property 2 'display s))
      (should (string-search "image/png 640" s)))
    (let ((s (drgnx-notebook--tail-string (list :text (string #xfffc)
                                                :images (list (list :at 0 :output 0 :mime "image/svg+xml" :width 10 :height 10))))))
      (should-not (get-text-property 0 'display s))
      (should (string-search "image/svg+xml" s)))))

;;; The same, against a recording tree-sitter layer: what the notebook asks of it (the suite has no grammar in its image)

(defmacro nb-test--with-fake-treesit (&rest body)
  "BODY with the tree-sitter functions the notebook uses replaced by a recorder: a parser is (LANGUAGE . RANGES)."
  (declare (indent 0))
  `(let ((parsers nil) (deleted nil))
     (ignore deleted)
     (cl-letf (((symbol-function 'treesit-available-p) (lambda () t))
               ((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (memq lang '(python markdown))))
               ((symbol-function 'treesit-parser-list) (lambda (&rest _) (copy-sequence parsers)))
               ((symbol-function 'treesit-parser-language) (lambda (p) (car p)))
               ((symbol-function 'treesit-parser-create) (lambda (lang &rest _) (car (push (cons lang nil) parsers))))
               ((symbol-function 'treesit-parser-set-included-ranges) (lambda (p ranges) (setcdr p ranges)))
               ((symbol-function 'treesit-parser-delete) (lambda (p) (push (car p) deleted) (setq parsers (delq p parsers)))))
       ,@body)))

(ert-deftest drgnx-notebook/one-parser-per-language-holds-its-cells-ranges ()
  (nb-test--with
    (nb-test--with-fake-treesit
      (setq drgnx-notebook--ranges nil)
      (drgnx-notebook--sync-parsers)
      (should (equal (sort (mapcar #'car (treesit-parser-list)) (lambda (a b) (string< a b))) '(markdown python)))
      (let* ((python (seq-find (lambda (p) (eq (car p) 'python)) (treesit-parser-list)))
             (a (drgnx-notebook--cell-by-id "a")) (c (drgnx-notebook--cell-by-id "c")))
        (should (equal (cdr python) (list (cons (1+ (plist-get a :head)) (plist-get a :tail)) (cons (1+ (plist-get c :head)) (plist-get c :tail))))))
      ;; an edit moves the ranges on the same parsers, a second parser is not made
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
      (insert "y = 3\n")
      (drgnx-notebook--rescan)
      (should (= 2 (length (treesit-parser-list))))
      (let ((python (seq-find (lambda (p) (eq (car p) 'python)) (treesit-parser-list))) (c (drgnx-notebook--cell-by-id "c")))
        (should (equal (car (last (cdr python))) (cons (1+ (plist-get c :head)) (plist-get c :tail)))))
      ;; a language no cell has any more loses its parser
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "b") :head)))
      (drgnx-notebook-change-cell-type 'raw)
      (drgnx-notebook--rescan)
      (should (equal (mapcar #'car (treesit-parser-list)) '(python))))))

;;; The real shapes of the routed methods: restart, clear, kernels, output, the add row, the selected tint

(ert-deftest drgnx-notebook/restart-is-the-hubs ()
  (nb-test--with
    (setq nb-test--answers (list (cons "notebook/restart" (lambda (_) (cons (list :kernel "python3") nil)))))
    (setq nb-test--calls nil)
    (drgnx-notebook-restart-kernel)
    (should (equal (mapcar #'car (reverse nb-test--calls)) '("notebook/restart")))
    (should (equal drgnx-notebook--kernel "python3"))
    ;; and run all once it is up
    (setq nb-test--calls nil)
    (drgnx-notebook-restart-and-run-all)
    (should (equal (delete "notebook/focus" (delete "notebook/tail" (mapcar #'car (reverse nb-test--calls)))) '("notebook/restart" "notebook/sync" "notebook/execute")))))

(ert-deftest drgnx-notebook/clear-outputs-asks-the-hub-for-all-or-one ()
  (nb-test--with
    (setq nb-test--calls nil)
    (drgnx-notebook-clear-outputs)
    (should (equal (cdr (assoc "notebook/clear" nb-test--calls)) '(:id "nb1")))
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
    (drgnx-notebook-clear-outputs t)
    (should (equal (cdr (assoc "notebook/clear" nb-test--calls)) '(:id "nb1" :cell "c")))))

(ert-deftest drgnx-notebook/the-kernel-picker-lists-the-skipped-with-their-reason ()
  (let* ((result (list :kernels (list (list :name "python3" :display_name "Python 3" :language "python" :interrupt "signal"))
                       :skipped (list (list :name "broken" :why "its kernel.json is not JSON"))))
         (candidates (drgnx-notebook--kernel-candidates result)))
    (should (equal (mapcar #'car candidates) '("python3" "broken")))
    (should (equal (plist-get (cdr (assoc "broken" candidates)) :why) "its kernel.json is not JSON"))
    ;; the picker shows both with annotations, and a skipped one is refused with its reason
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _)
                 (let ((note (funcall (plist-get completion-extra-properties :annotation-function) "broken")))
                   (should (string-search "unavailable: its kernel.json is not JSON" note))
                   (should (equal (funcall (plist-get completion-extra-properties :annotation-function) "python3") "  Python 3 (python)"))
                   (car (member "broken" coll))))))
      (should-error (drgnx-notebook--choose-kernel candidates) :type 'user-error))))

(ert-deftest drgnx-notebook/open-output-shows-the-whole-output-in-a-buffer ()
  ;; without Sjá (a stock Emacs): the text of the output in a buffer of its own
  (nb-test--with
    (cl-letf (((symbol-function 'drgnx-notebook--views-p) #'ignore))
      (setq nb-test--answers
            (list (cons "notebook/output" (lambda (_) (cons (list :outputs (list (list :output_type "stream" :text (list "one\n" "two\n")))) nil)))))
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
      (save-window-excursion
        (drgnx-notebook-open-output)
        (should (string-prefix-p "*Output: " (buffer-name)))
        (should (equal (buffer-string) "one\ntwo\n"))
        (kill-buffer (current-buffer))))))

(ert-deftest drgnx-notebook/the-selected-cell-has-the-add-row-and-the-selected-tint-on-its-output ()
  (nb-test--with
    (drgnx-notebook--event "notebook-tail" (nb-test--tail "out"))
    (let ((tail (lambda (id) (overlay-get (plist-get (drgnx-notebook--chrome-of id) :tail) 'after-string))))
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
      (drgnx-notebook--select-at (point))
      (should (string-search "+ Code" (funcall tail "a")))
      (should (string-search "+ Markdown" (funcall tail "a")))
      (should (memq 'drgnx-notebook-cell-selected (ensure-list (get-text-property 0 'face (funcall tail "a")))))
      ;; the selection moves: the row and the tint go with it
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
      (drgnx-notebook--select-at (point))
      (should-not (string-search "+ Code" (funcall tail "a")))
      (should (memq 'drgnx-notebook-cell (ensure-list (get-text-property 0 'face (funcall tail "a")))))
      (should (string-search "+ Code" (funcall tail "c"))))))

(ert-deftest drgnx-notebook/the-add-row-adds-a-cell-of-its-type ()
  (nb-test--with
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (drgnx-notebook--select-at (point))
    (let* ((row (drgnx-notebook--add-row)) (at (string-search "+ Markdown" row)))
      (should (eq (get-text-property at 'drgnx-notebook-add row) 'markdown)))
    (drgnx-notebook-add-cell-below 'markdown)
    (should (eq (plist-get (drgnx-notebook--cell-by-id (nth 1 (nb-test--ids))) :type) 'markdown))))

;;; A hub that came back: the notebook is opened again by its path and the buffer's cells go to it

(defconst nb-test--reopened
  '(:id "nb2" :language "python" :kernelspec "python3"
        :cells ((:id "a" :type "code" :source "x = 1\nx" :execution_count 3)
                (:id "b" :type "markdown" :source "# Title")
                (:id "c" :type "code" :source "print(2)"))
        :tails ((:cell "a" :version 1 :text "from the file" :stale t :head (:text "[3]  python" :state "idle" :runs nil)
                       :runs nil :images nil :more_lines 0)))
  "What the new hub answers to `notebook/open' for the same path: the file's cells, a new id.")

(defmacro nb-test--reconnecting (&rest body)
  "BODY in a notebook that visits a file, the new hub answering `nb-test--reopened'."
  (declare (indent 0))
  `(nb-test--with
     (setq buffer-file-name "/nonexistent/nb-test.ipynb"
           nb-test--answers (list (cons "notebook/open" (lambda (_) (cons nb-test--reopened nil)))
                                  (cons "notebook/sync" (lambda (_) (cons t nil)))))
     (unwind-protect (progn ,@body) (setq buffer-file-name nil))))

(ert-deftest drgnx-notebook/a-new-hub-gets-the-notebook-again-with-the-unsaved-edits ()
  (nb-test--reconnecting
    (goto-char (plist-get (drgnx-notebook--cell-by-id "c") :tail))
    (insert "\nprint(3)")
    (should (buffer-modified-p))
    (drgnx-notebook--reconnect)
    (let ((open (assoc "notebook/open" nb-test--calls)) (sync (assoc "notebook/sync" nb-test--calls)))
      (should (equal (plist-get (cdr open) :path) "/nonexistent/nb-test.ipynb"))
      (should (equal (plist-get (cdr sync) :id) "nb2"))
      ;; the hub gets the buffer's text, not the file's
      (should (equal (plist-get (aref (plist-get (cdr sync) :cells) 2) :source) "print(2)\nprint(3)")))
    (should (equal drgnx-notebook--id "nb2"))
    (should (eq (gethash "nb2" drgnx-notebook--buffers) (current-buffer)))
    (should-not (gethash "nb1" drgnx-notebook--buffers))
    (should (buffer-modified-p))
    (should (equal (nb-test--source "c") "print(2)\nprint(3)"))
    (should (string-match-p "from the file" (overlay-get (plist-get (drgnx-notebook--chrome-of "a") :tail) 'after-string)))))

(ert-deftest drgnx-notebook/a-reopened-notebook-has-no-kernel-until-one-starts ()
  (nb-test--reconnecting
    (setq drgnx-notebook--kernel "python3" drgnx-notebook--state "busy" drgnx-notebook--running "a")
    (drgnx-notebook--reconnect)
    (should-not drgnx-notebook--kernel)
    (should-not drgnx-notebook--running)
    (should (equal drgnx-notebook--state "idle"))))

(ert-deftest drgnx-notebook/a-refused-reopen-keeps-the-buffer-as-it-is ()
  (nb-test--reconnecting
    (setq nb-test--answers (list (cons "notebook/open" (lambda (_) (cons nil "not a notebook path")))))
    (goto-char (plist-get (drgnx-notebook--cell-by-id "c") :tail))
    (insert "!")
    (drgnx-notebook--reconnect)
    (should (equal drgnx-notebook--id "nb1"))
    (should (equal (nb-test--source "c") "print(2)!"))
    (should-not (assoc "notebook/sync" nb-test--calls))))

(ert-deftest drgnx-notebook/the-reconnect-hook-is-the-modules ()
  (nb-test--with
    (should (memq #'drgnx-notebook--reconnect-all drgnx-hub-connected-functions))))

(ert-deftest drgnx-notebook/an-open-the-dying-hub-never-answered-is-asked-again-at-the-next-connect ()
  (drgnx-test-with-modules '(lang/notebook) :strict t
                           (let ((calls nil) (hub-up nil) (buffer (generate-new-buffer "*nb-pending*")))
                             (cl-letf (((symbol-function 'drgnx-notebook--call)
                                        (lambda (m p cb &optional _full)
                                          (push (cons m p) calls)
                                          (if hub-up (funcall cb nb-test--opened nil) (funcall cb nil "the connection closed")))))
                               (unwind-protect
                                   (with-current-buffer buffer
                                     (setq buffer-file-name "/nonexistent/pending.ipynb")
                                     (insert "{\"cells\": []}")
                                     (drgnx-notebook-mode)
                                     ;; the hub went away before it answered: still a notebook buffer, still the file's text, waiting
                                     (should (eq major-mode 'drgnx-notebook-mode))
                                     (should buffer-read-only)
                                     (should (equal (buffer-string) "{\"cells\": []}"))
                                     (should-not drgnx-notebook--id)
                                     (setq hub-up t)
                                     (drgnx-notebook--reconnect-all)
                                     (should (equal (plist-get (cdr (assoc "notebook/open" calls)) :text) "{\"cells\": []}"))
                                     (should (equal drgnx-notebook--id "nb1"))
                                     (should-not buffer-read-only)
                                     (should (equal (nb-test--ids) '("a" "b" "c")))
                                     ;; opened now: the next connect takes the reconnect path, not another first open
                                     (setq calls nil)
                                     (drgnx-notebook--reconnect-all)
                                     (should (equal (delete "notebook/focus" (mapcar #'car (reverse calls))) '("notebook/open" "notebook/sync")))
                                     (should-not (plist-member (cdr (car (reverse calls))) :text)))
                                 (with-current-buffer buffer (set-buffer-modified-p nil) (setq buffer-file-name nil))
                                 (kill-buffer buffer)
                                 (clrhash drgnx-notebook--buffers))))))

;;; The card: a Glitnir block ring around each cell's rows (the band stays without Glitnir: a terminal, batch)

(defmacro nb-test--with-cards (&rest body)
  "BODY in a notebook shown in the selected window, where Glitnir blocks are taken to be there."
  (declare (indent 0))
  `(nb-test--with
     (cl-letf (((symbol-function 'drgnx-notebook--cards-p) (lambda () t)))
       (let ((window (selected-window)))
         (set-window-buffer window (current-buffer))
         (unwind-protect (progn (drgnx-notebook--rescan) (drgnx-notebook--blocks-update) ,@body)
           (set-window-parameter window 'glitnir-blocks nil))))))

(ert-deftest drgnx-notebook/each-cell-is-a-ring-block-radius-10 ()
  (nb-test--with-cards
    (let ((blocks (window-parameter (selected-window) 'glitnir-blocks)))
      (should (= (length blocks) 3))
      (dolist (c (drgnx-notebook--rescan))
        (let ((b (seq-find (lambda (b) (= (nth 1 b) (plist-get c :head))) blocks)))
          (should (eq (car b) 'ring))
          (should (= (nth 2 b) (1+ (plist-get c :tail))))       ; END exclusive: the tail's newline is the card's last row
          (should (= (plist-get (nthcdr 3 b) :radius) (drgnx-px 10)))
          (should (eq (plist-get (nthcdr 3 b) :beneath) 'default)))))))

(ert-deftest drgnx-notebook/a-card-stands-in-a-gap-with-the-card-shadow-and-the-outer-ring ()
  (nb-test--with-cards
    (let* ((blocks (window-parameter (selected-window) 'glitnir-blocks))
           (plist (lambda (id) (nthcdr 3 (seq-find (lambda (b) (= (nth 1 b) (plist-get (drgnx-notebook--cell-by-id id) :head)))
                                                   blocks)))))
      (dolist (id '("a" "b"))
        (let ((p (funcall plist id)))
          (should (= (plist-get p :gap) (drgnx-px 4)))       ; two cards stand 8 px apart
          (should (consp (plist-get p :shadow)))
          (should (consp (plist-get p :shadow-ring)))))
      ;; the focused, selected cell: the focus ring inside, the border step outside
      (should (equal (plist-get (funcall plist "a") :outer) '(drgnx-border-subtle . 1.0)))
      (should-not (plist-get (funcall plist "b") :outer)))))

(ert-deftest drgnx-notebook/the-focus-ring-is-the-selected-cells-in-the-focused-window-only ()
  (nb-test--with-cards
    (let* ((window (selected-window))
           (ring (lambda (id) (let ((c (drgnx-notebook--cell-by-id id)))
                                (plist-get (nthcdr 3 (seq-find (lambda (b) (= (nth 1 b) (plist-get c :head)))
                                                               (window-parameter window 'glitnir-blocks)))
                                           :ring)))))
      (should (equal drgnx-notebook--selected-id "a"))
      (should (eq (funcall ring "a") 'drgnx-focus-line))
      (should (eq (funcall ring "b") 'drgnx-border-subtle))
      ;; the window is not the selected one: the selected cell keeps a stronger edge, no ring
      (cl-letf (((symbol-function 'selected-window) (lambda () nil)))
        (drgnx-notebook--blocks-update))
      (should (eq (funcall ring "a") 'drgnx-border-strong))
      (should (eq (funcall ring "b") 'drgnx-border-subtle)))))

(ert-deftest drgnx-notebook/the-blocks-are-set-only-when-they-changed ()
  (nb-test--with-cards
    (let ((first (window-parameter (selected-window) 'glitnir-blocks)))
      (drgnx-notebook--blocks-update)
      (should (eq first (window-parameter (selected-window) 'glitnir-blocks)))
      ;; the selection moves: the rings change
      (goto-char (plist-get (drgnx-notebook--cell-by-id "c") :head))
      (forward-char 1)
      (drgnx-notebook--select-at (point))
      (drgnx-notebook--blocks-update)
      (should-not (eq first (window-parameter (selected-window) 'glitnir-blocks))))))

(ert-deftest drgnx-notebook/a-card-has-no-overline-and-the-fringes-are-its-insets ()
  (nb-test--with-cards
    (should (= left-fringe-width (drgnx-px 16)))
    (should (= right-fringe-width (drgnx-px 16)))
    (let* ((s (drgnx-notebook--head-string "a" 'code)) (faces (get-text-property (1- (length s)) 'face s)))
      (should (member '(:overline nil) (if (and (consp faces) (not (keywordp (car faces)))) faces (list faces)))))))

(ert-deftest drgnx-notebook/without-glitnir-the-band-look-stays ()
  (nb-test--with
    (set-window-buffer (selected-window) (current-buffer))
    (drgnx-notebook--rescan)
    (drgnx-notebook--blocks-update)
    (should-not (window-parameter (selected-window) 'glitnir-blocks))
    (should-not (member '(:overline nil)
                        (let ((f (get-text-property (1- (length (drgnx-notebook--head-string "a" 'code))) 'face
                                                    (drgnx-notebook--head-string "a" 'code))))
                          (if (and (consp f) (not (keywordp (car f)))) f (list f)))))))

(ert-deftest drgnx-notebook/the-card-goes-with-the-buffer ()
  (nb-test--with-cards
    (should (window-parameter (selected-window) 'glitnir-blocks))
    (drgnx-notebook--blocks-clear)
    (should-not (window-parameter (selected-window) 'glitnir-blocks))))

;;; The views: the cell outline, a cell's full output and the kernel log, hub-fed Sjá views the editor only shows

(defmacro nb-test--with-views (&rest body)
  "BODY in a notebook, Sjá taken to be there: the view attach and env registration are recorded in `attached' and
`registered', each view the hub names being `nbv:KIND' (an output's `nbv:output:CELL')."
  (declare (indent 0))
  `(nb-test--with
     (let ((attached nil) (registered nil) (unregistered nil))
       (setq nb-test--answers
             (list (cons "notebook/view"
                         (lambda (p) (cons (list :view (format "nbv:%s%s%s" (plist-get p :kind) (if (plist-get p :cell) ":" "")
                                                               (or (plist-get p :cell) ""))
                                                 )
                                           nil)))))
       (cl-letf (((symbol-function 'drgnx-notebook--views-p) (lambda () t))
                 ((symbol-function 'drgnx-view-patch-attach) (lambda (view class &rest _) (push (list view class) attached)))
                 ((symbol-function 'drgnx-view-env-register) (lambda (view buffer &rest _) (push (cons view buffer) registered)))
                 ((symbol-function 'drgnx-view-env-unregister) (lambda (view) (push view unregistered)))
                 ((symbol-function 'pop-to-buffer) (lambda (b &rest _) (set-buffer b))))
         (let ((notebook (current-buffer)))
           (unwind-protect (progn ,@body)
             (dolist (b (buffer-list))
               (when (string-prefix-p "*Notebook " (buffer-name b)) (let ((kill-buffer-hook nil)) (kill-buffer b))))
             (set-buffer notebook)))))))

(ert-deftest drgnx-notebook/the-outline-is-the-hubs-view-attached-and-registered ()
  (nb-test--with-views
    (drgnx-notebook-outline)
    (let ((call (assoc "notebook/view" nb-test--calls)))
      (should (equal (plist-get (cdr call) :id) "nb1"))
      (should (equal (plist-get (cdr call) :kind) "outline")))
    (should (equal attached '(("nbv:outline" "unshown"))))
    (let ((buffer (cdr (car registered))))
      (should (equal (car (car registered)) "nbv:outline"))
      (should (string-prefix-p "*Notebook outline: " (buffer-name buffer)))
      (should (eq (buffer-local-value 'major-mode buffer) 'drgnx-notebook-outline-mode)))))

(ert-deftest drgnx-notebook/a-view-asked-again-is-the-same-buffer ()
  (nb-test--with-views
    (drgnx-notebook-outline)
    (set-buffer (get-buffer (buffer-name (cdr (car registered)))))
    (set-buffer (get-buffer (replace-regexp-in-string "\\*Notebook outline: \\(.*\\)\\*" "\\1" (buffer-name))))
    (drgnx-notebook-outline)
    (should (= (length registered) 1))))

(ert-deftest drgnx-notebook/the-full-output-is-the-view-of-the-cell-at-point ()
  (nb-test--with-views
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c") :head)))
    (drgnx-notebook-open-output)
    (let ((call (assoc "notebook/view" nb-test--calls)))
      (should (equal (plist-get (cdr call) :kind) "output"))
      (should (equal (plist-get (cdr call) :cell) "c")))
    (should (string-prefix-p "*Notebook output: " (buffer-name (cdr (car registered)))))
    (should (eq (buffer-local-value 'major-mode (cdr (car registered))) 'drgnx-notebook-output-mode))))

(ert-deftest drgnx-notebook/the-kernel-log-is-a-view-too ()
  (nb-test--with-views
    (drgnx-notebook-kernel-log)
    (should (equal (plist-get (cdr (assoc "notebook/view" nb-test--calls)) :kind) "log"))
    (should (eq (buffer-local-value 'major-mode (cdr (car registered))) 'drgnx-notebook-log-mode))))

(ert-deftest drgnx-notebook/a-row-of-the-outline-takes-you-to-its-cell ()
  (nb-test--with-views
    (let ((notebook (current-buffer)))
      (drgnx-notebook-outline)
      (set-buffer (cdr (car registered)))
      (let ((inhibit-read-only t))
        (insert (propertize "2  code  [ ]  print(2)\n" 'drgnx-notebook-cell "c")))
      (goto-char (point-min))
      (drgnx-notebook-outline-visit)
      (should (eq (current-buffer) notebook))
      (should (equal (plist-get (drgnx-notebook--cell-at) :id) "c")))))

(ert-deftest drgnx-notebook/an-outline-row-that-is-not-a-cell-says-so ()
  (nb-test--with-views
    (drgnx-notebook-outline)
    (set-buffer (cdr (car registered)))
    (let ((inhibit-read-only t)) (insert "more  3 cells\n"))
    (goto-char (point-min))
    (should-error (drgnx-notebook-outline-visit) :type 'user-error)))

(ert-deftest drgnx-notebook/the-output-window-moves-by-half-a-window ()
  (nb-test--with-views
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (drgnx-notebook-open-output)
    (set-buffer (cdr (car registered)))
    (let ((inhibit-read-only t))
      (insert (propertize "line one\n" 'drgnx-notebook-cell "a" 'drgnx-notebook-line 1001))
      (insert (propertize "line two\n" 'drgnx-notebook-cell "a" 'drgnx-notebook-line 1002)))
    (setq nb-test--calls nil)
    (drgnx-notebook-output-later)
    (let ((call (assoc "view/window" nb-test--calls)))
      (should (equal (plist-get (cdr call) :view) "nbv:output:a"))
      (should (equal (plist-get (cdr call) :list) "lines"))
      (should (= (plist-get (cdr call) :from) 1500)))
    (setq nb-test--calls nil)
    (drgnx-notebook-output-earlier)
    (should (= (plist-get (cdr (assoc "view/window" nb-test--calls)) :from) 500))))

(ert-deftest drgnx-notebook/killing-a-view-closes-it-at-the-hub ()
  (nb-test--with-views
    (drgnx-notebook-outline)
    (let ((buffer (cdr (car registered))))
      (setq nb-test--calls nil)
      (kill-buffer buffer)
      (should (equal (plist-get (cdr (assoc "view/close" nb-test--calls)) :view) "nbv:outline")))))

(ert-deftest drgnx-notebook/the-views-go-with-the-notebook ()
  (nb-test--with-views
    (drgnx-notebook-outline)
    (let ((view (cdr (car registered))))
      (drgnx-notebook--kill-views)
      (should-not (buffer-live-p view)))))

(ert-deftest drgnx-notebook/a-view-is-asked-again-when-the-notebook-comes-back-on-a-new-hub ()
  (nb-test--with-views
    (setq buffer-file-name "/nonexistent/nb-test.ipynb")
    (unwind-protect
        (progn
          (drgnx-notebook-outline)
          (let ((view (cdr (car registered))))
            (setq nb-test--answers
                  (append (list (cons "notebook/open" (lambda (_) (cons nb-test--reopened nil)))
                                (cons "notebook/sync" (lambda (_) (cons t nil))))
                          nb-test--answers)
                  nb-test--calls nil
                  attached nil)
            (drgnx-notebook--reconnect)
            (should (equal (plist-get (cdr (assoc "notebook/view" nb-test--calls)) :id) "nb2"))
            (should (member "nbv:outline" unregistered))
            (should (equal attached '(("nbv:outline" "unshown"))))
            (should (buffer-live-p view))))
      (setq buffer-file-name nil))))

(ert-deftest drgnx-notebook/without-sja-the-views-say-so ()
  (nb-test--with
    (cl-letf (((symbol-function 'drgnx-notebook--views-p) #'ignore))
      (should-error (drgnx-notebook-outline) :type 'user-error)
      (should-error (drgnx-notebook-kernel-log) :type 'user-error))))

(ert-deftest drgnx-notebook/the-views-faces-are-lisps-and-hold-no-colour ()
  (dolist (face '(drgnx-notebook-inverse drgnx-notebook-prompt drgnx-notebook-stale drgnx-notebook-fg-red drgnx-notebook-bg-red))
    (should (facep face)))
  (should (eq (face-attribute 'drgnx-notebook-inverse :inverse-video nil t) t)))

;;; The views' foot line and gutter (the approved mockup: the-look/notebook-views.html): what the status bar says of a view, from its rows

(defun nb-test--view-buffer (mode rows)
  "A view buffer in MODE holding ROWS, each (TEXT . PROPS), as a hub's patch draws them."
  (let ((buffer (generate-new-buffer "*Notebook view test*")))
    (with-current-buffer buffer
      (funcall mode)
      (let ((inhibit-read-only t))
        (dolist (r rows) (insert (apply #'propertize (car r) (cdr r)) "\n")))
      (drgnx-notebook-view--refresh))
    buffer))

(ert-deftest drgnx-notebook/the-outlines-foot-counts-the-listed-cells-and-the-hidden-ones ()
  (nb-test--with
    (let ((b (nb-test--view-buffer 'drgnx-notebook-outline-mode
                                   '(("1  markdown  # T" drgnx-notebook-cell "a") ("2  code      [1] x" drgnx-notebook-cell "b")
                                     ("more: 1 991 cells are not listed" drgnx-notebook-more 1991)))))
      (unwind-protect
          (with-current-buffer b
            (should (equal drgnx-notebook-view--foot "2 of 1 993 listed")))
        (kill-buffer b)))))

(ert-deftest drgnx-notebook/the-outputs-foot-says-which-lines-of-how-many ()
  (nb-test--with
    (let ((b (nb-test--view-buffer 'drgnx-notebook-output-mode
                                   '(("▲ 1240 lines above   M-p earlier lines" drgnx-notebook-above 1240) ("epoch 41" drgnx-notebook-line 1241)
                                     ("epoch 42" drgnx-notebook-line 1242)
                                     ("▼ 310 lines below   M-n later lines" drgnx-notebook-below 310)))))
      (unwind-protect
          (with-current-buffer b
            (should (equal drgnx-notebook-view--foot "lines 1 241–1 242 of 1 552"))
            ;; the gutter is the lines' own numbers (a line-prefix), blank on the cut rows, as the mockup has it
            (should-not display-line-numbers)
            (let ((prefix (lambda (n) (goto-char (point-min)) (forward-line n)
                            (substring-no-properties (get-text-property (point) 'line-prefix)))))
              (should (equal (string-trim (funcall prefix 1)) "1 241"))
              (should (string-blank-p (funcall prefix 0)))
              (should (string-blank-p (funcall prefix 3)))
              (should (= (length (funcall prefix 0)) (length (funcall prefix 1))))))
        (kill-buffer b)))))

(ert-deftest drgnx-notebook/the-logs-foot-counts-entries ()
  (nb-test--with
    (let ((b (nb-test--view-buffer 'drgnx-notebook-log-mode
                                   '(("lost  12 earlier entries" drgnx-notebook-lost 12) ("stream  hello" drgnx-notebook-log 1) ("error   boom" drgnx-notebook-log 2)
                                     ("        more" drgnx-notebook-log 2)))))
      (unwind-protect
          (with-current-buffer b (should (equal drgnx-notebook-view--foot "2 entries · 12 dropped")))
        (kill-buffer b)))))

(ert-deftest drgnx-notebook/the-view-foot-is-a-status-bar-segment ()
  (nb-test--with
    (when (fboundp 'drgnx-statusbar-define-segment)
      (should (memq 'notebook-view drgnx-statusbar-other))
      (should (memq 'notebook-view-hint drgnx-statusbar-other-right)))
    (let ((b (nb-test--view-buffer 'drgnx-notebook-log-mode '(("stream  hi" drgnx-notebook-log 1)))))
      (unwind-protect (with-current-buffer b (should (equal (drgnx-notebook--segment-view) "1 entries")))
        (kill-buffer b)))))

;;; The views' pane title: a header line with the view's name, what it is of and a count chip (the approved mockup)

(ert-deftest drgnx-notebook/the-outlines-title-names-the-notebook-and-counts-its-cells ()
  (nb-test--with
    (let ((b (nb-test--view-buffer 'drgnx-notebook-outline-mode
                                   '(("1  markdown  # T" drgnx-notebook-cell "a") ("more: 1 991 cells are not listed" drgnx-notebook-more 1991)))))
      (unwind-protect
          (with-current-buffer b
            (setq drgnx-notebook-view--notebook (get-buffer "*nb-test*"))
            (drgnx-notebook-view--refresh)
            (should (string-prefix-p "Outline" (substring-no-properties drgnx-notebook-view--header)))
            (should (string-search "*nb-test*" drgnx-notebook-view--header))
            (should (string-search "1 992 cells" drgnx-notebook-view--header))
            (should (equal header-line-format '(" " (:eval drgnx-notebook-view--header)))))
        (kill-buffer b)))))

(ert-deftest drgnx-notebook/the-outputs-title-says-follows-the-run-for-the-running-cell ()
  (nb-test--with
    (let ((b (nb-test--view-buffer 'drgnx-notebook-output-mode '(("epoch 1" drgnx-notebook-line 1)))))
      (unwind-protect
          (with-current-buffer b
            (setq drgnx-notebook-view--notebook (get-buffer "*nb-test*") drgnx-notebook-view--cell "a")
            (with-current-buffer drgnx-notebook-view--notebook (setq drgnx-notebook--running "a"))
            (drgnx-notebook-view--refresh)
            (should (string-search "Output" drgnx-notebook-view--header))
            (should (string-search "cell 1" drgnx-notebook-view--header))
            (should (string-search "follows the run" drgnx-notebook-view--header))
            (with-current-buffer drgnx-notebook-view--notebook (setq drgnx-notebook--running nil))
            (drgnx-notebook-view--refresh)
            (should-not (string-search "follows the run" drgnx-notebook-view--header)))
        (kill-buffer b)))))

(ert-deftest drgnx-notebook/the-logs-title-counts-what-was-dropped ()
  (nb-test--with
    (let ((b (nb-test--view-buffer 'drgnx-notebook-log-mode '(("lost  12 earlier entries" drgnx-notebook-lost 12) ("stream  hi" drgnx-notebook-log 1)))))
      (unwind-protect
          (with-current-buffer b
            (should (string-search "Kernel log" drgnx-notebook-view--header))
            (should (string-search "12 earlier entries dropped" drgnx-notebook-view--header)))
        (kill-buffer b)))))

(ert-deftest drgnx-notebook/the-hint-says-enter-not-ret ()
  (should (equal (drgnx-notebook--key-word "RET") "Enter"))
  (should (equal (drgnx-notebook--key-word "C-c C-j") "C-c C-j")))

;;; The views' faces and the current cell (the hub half: notebook views a to d)

(ert-deftest drgnx-notebook/the-views-new-faces-are-lisps-and-extend-without-a-colour ()
  (dolist (face '(drgnx-notebook-cut drgnx-notebook-error-row drgnx-notebook-current-row))
    (should (facep face))
    (should (eq (face-attribute face :extend nil t) t))
    (should (eq (face-attribute face :background nil nil) 'unspecified))))        ; their colours are inherited, themes own them

(ert-deftest drgnx-notebook/the-hub-is-told-which-cell-point-is-in-when-it-changes ()
  (nb-test--with
    (setq nb-test--calls nil)
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "b") :head)))
    (drgnx-notebook--select-at (point))
    (let ((call (assoc "notebook/focus" nb-test--calls)))
      (should (equal (plist-get (cdr call) :id) "nb1"))
      (should (equal (plist-get (cdr call) :cell) "b")))
    ;; moving inside the cell says nothing
    (setq nb-test--calls nil)
    (goto-char (+ 2 (plist-get (drgnx-notebook--cell-by-id "b") :head)))
    (drgnx-notebook--select-at (point))
    (should-not (assoc "notebook/focus" nb-test--calls))))

(ert-deftest drgnx-notebook/point-in-no-cell-leaves-the-cell-out ()
  (nb-test--with
    (setq nb-test--calls nil)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'drgnx-notebook--cell-at) (lambda (&optional _) nil)))
      (drgnx-notebook--select-at (point)))
    (let ((call (assoc "notebook/focus" nb-test--calls)))
      (should call)
      (should-not (plist-member (cdr call) :cell)))))
