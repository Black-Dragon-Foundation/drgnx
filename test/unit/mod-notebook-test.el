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
    (should (equal (delete "notebook/tail" (mapcar #'car (reverse nb-test--calls))) '("notebook/restart" "notebook/sync" "notebook/execute")))))

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
  (nb-test--with
    (setq nb-test--answers
          (list (cons "notebook/output" (lambda (_) (cons (list :outputs (list (list :output_type "stream" :text (list "one\n" "two\n")))) nil)))))
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "a") :head)))
    (save-window-excursion
      (drgnx-notebook-open-output)
      (should (string-prefix-p "*Output: " (buffer-name)))
      (should (equal (buffer-string) "one\ntwo\n"))
      (kill-buffer (current-buffer)))))

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
