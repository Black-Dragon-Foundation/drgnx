;;; wb-buffers-test.el --- batch tests: the Buffers panel, its rows from a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; A real hub as its own process builds the rows (`buffers/set', view/buffers.rs) and Sjá draws them; this Emacs plays
;; the editor inside the delivery gate (`drgnx-test-gated').  Needs Sjá (a Nidhogg with `nidhogg-view-push') and the
;; hub's binary; skipped without either.  Nothing of the hub's side is stubbed: each look waits for the panel to show
;; what the test did (a condition, never a deadline).  The panel with the hub down: wb-buffers-edge-test.el.
(require 'ert)
(require 'cl-lib)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/gated-hub-fixture" drgnx-dir) nil t)
(require 'drgnx-buffers)
(require 'drgnx-git)
(require 'drgnx-actions)
(require 'drgnx-explorer)
(defvar drgnx-explorer--lisp-listing)

(defvar drgnx-buffers-test--calls nil "The `buffers/set' params sent in a test, newest first.")

(defun drgnx-buffers-test--record (conn method params &rest _)
  "Advice before `drgnx-hub--call-on': note what the panel sent (the call itself goes on to the hub)."
  (when (and (eq conn drgnx-hub--events) (equal method "buffers/set")) (push params drgnx-buffers-test--calls)))

(defmacro drgnx-buffers-test--with (dir &rest body)
  "BODY with a gated hub this Emacs is connected to, a fresh bus, the Buffers panel shown in the dock (its rows the
hub's, drawn by Sjá), and a temp DIR for files."
  (declare (indent 1))
  `(drgnx-test-with-gated-hub
     (drgnx-test-with-state
       (let* ((,dir (file-name-as-directory (make-temp-file "drgnx-buffers" t)))
              (drgnx-wb--sections nil) (drgnx-buffers--filter nil) (drgnx-buffers-all-windows nil)
              (drgnx-buffers--ids (make-hash-table :test #'eq :weakness 'key))
              (drgnx-buffers--by-id (make-hash-table :test #'equal :weakness 'value))
              (drgnx-buffers--sent (make-hash-table :test #'eq :weakness 'key))
              (drgnx-buffers--next 0) (drgnx-buffers--ops nil) (drgnx-buffers--scope 'all)
              (drgnx-buffers--pressed nil) (drgnx-buffers-test--calls nil))
         (advice-add 'drgnx-hub--call-on :before #'drgnx-buffers-test--record)
         (unwind-protect
             (progn
               (delete-other-windows)
               (drgnx-buffers-setup)
               (drgnx-wb-show-sidebar)
               ;; a batch Emacs never redisplays, so `window-buffer-change-functions' do not run: the env of the
               ;; class the dock shows the panel in goes as a shown window would send it
               (drgnx-view-env-update drgnx-buffers-hub-view)
               (drgnx-buffers-test--settle (lambda () (not drgnx-buffers--waiting)) "the first rows")
               ,@body)
           (advice-remove 'drgnx-hub--call-on #'drgnx-buffers-test--record)
           (drgnx-wb-hide-sidebar)
           (delete-other-windows)
           (dolist (b (buffer-list))
             (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
               (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
           (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))
           (drgnx-git-letters-clear)
           (delete-directory ,dir t))))))

(defun drgnx-buffers-test--settle (pred what)
  "Flush the bus, then wait until PRED holds in the panel's buffer: before each look the hub's lines are released
and what came is drawn.  PRED's value."
  (drgnx-signal--flush)
  (drgnx-test-hub-settle
   (lambda () (when-let* ((p (get-buffer drgnx-buffers-buffer-name)))
                (with-current-buffer p (drgnx-view-draw-now nil) (funcall pred))))
   what))

(defun drgnx-buffers-test--open (dir name)
  "Visit NAME under DIR (made with one line); the buffer, once its row is drawn."
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (write-region "x\n" nil f nil 'silent)
    (let ((b (find-file-noselect f)))
      (drgnx-buffers-test--settle (lambda () (drgnx-buffers--row-pos b)) (format "the row of %s" name))
      b)))

(defun drgnx-buffers-test--kill (b)
  "Kill buffer B; return once its row is gone."
  (let ((id (gethash b drgnx-buffers--ids)))
    (kill-buffer b)
    (drgnx-buffers-test--settle (lambda () (not (drgnx-view-row-start nil id))) "a closed buffer's row gone")))

(defun drgnx-buffers-test--rows (dir)
  "Names of the rows for buffers of files under DIR, top to bottom."
  (mapcar #'buffer-name (seq-filter (lambda (b) (and (buffer-live-p b) (string-prefix-p dir (or (buffer-file-name b) ""))))
                                    (drgnx-buffers--shown))))

(defun drgnx-buffers-test--window ()
  (get-buffer-window drgnx-buffers-buffer-name))

(defun drgnx-buffers-test--row-count ()
  (with-current-buffer drgnx-buffers-buffer-name (count-lines (point-min) (point-max))))

(defun drgnx-buffers-test--tail (b)
  "The string at the right edge of buffer B's row."
  (with-current-buffer drgnx-buffers-buffer-name
    (let ((row (drgnx-buffers--row-pos b)))
      (seq-some (lambda (o) (and (overlay-get o 'drgnx-row-tail) (overlay-get o 'after-string)))
                (overlays-in row (1+ (save-excursion (goto-char row) (pos-eol))))))))

(defun drgnx-buffers-test--ops ()
  "The ops sent since the last call, oldest first, each a plist; forgets them."
  (prog1 (apply #'append (mapcar (lambda (p) (append (plist-get p :ops) nil)) (reverse drgnx-buffers-test--calls)))
    (setq drgnx-buffers-test--calls nil)))

(ert-deftest drgnx-buffers/the-section-fits-its-rows ()
  "The Open section is as tall as its rows and its header (no empty rows below the last), at most 0.3 of the frame;
past that it holds whole rows and scrolls.  With no rows it is the header and the one line Emacs keeps."
  (drgnx-buffers-test--with dir
    ;; a section below the Open one, as the Explorer is: it takes what Open gives up
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-define-section 'below :slot 0 :title "Below" :buffer (lambda () (get-buffer-create " *below*")))
    (drgnx-wb-show-sidebar)
    (drgnx-signal--flush)
    (let ((frame-h (frame-inner-height)))
      (when (zerop (drgnx-buffers-test--row-count))
        ;; Emacs keeps one text line in a live window: the header and that line, no more
        (should (<= (window-body-height (drgnx-buffers-test--window) t) (frame-char-height))))
      (dolist (n '("a" "b" "c" "d")) (drgnx-buffers-test--open dir (concat n ".txt")))
      (let ((w (drgnx-buffers-test--window)) (rows (drgnx-buffers-test--row-count)))
        (should (>= rows 4))
        (when (<= (+ rows (window-header-line-height w)) (* 0.3 frame-h))
          (should (= (window-body-height w t) (* rows (frame-char-height))))))
      (dotimes (i 40) (drgnx-buffers-test--open dir (format "many-%02d.txt" i)))
      (let ((w (drgnx-buffers-test--window)))
        (should (<= (window-pixel-height w) (floor (* 0.3 frame-h))))
        (should (< (window-body-height w t) (* (drgnx-buffers-test--row-count) (frame-char-height))))
        (should (zerop (mod (window-body-height w t) (frame-char-height))))))))

(ert-deftest drgnx-buffers/rows-keep-their-open-order ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (should (equal (drgnx-buffers-test--rows dir) '("a.txt" "b.txt" "c.txt")))
      ;; Switching (recency) never re-sorts, and sends nothing.
      (drgnx-buffers-test--ops)
      (switch-to-buffer a) (switch-to-buffer c) (switch-to-buffer b)
      (drgnx-signal--flush)
      (drgnx-buffers--send)
      (should-not (drgnx-buffers-test--ops))
      (should (equal (drgnx-buffers-test--rows dir) '("a.txt" "b.txt" "c.txt")))
      (drgnx-buffers-test--kill b)
      (should (equal (drgnx-buffers-test--rows dir) '("a.txt" "c.txt"))))))

(ert-deftest drgnx-buffers/sends-only-what-changed ()
  "A flush that changed nothing sends nothing; a new buffer is one put; an edit flips the unsaved flag once (one
`modified' op, then nothing while typing on), and so does the save."
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")))
      (drgnx-buffers-test--ops)
      (drgnx-signal--flush)
      (drgnx-buffers--send)
      (should-not (drgnx-buffers-test--ops))
      (drgnx-buffers-test--open dir "b.txt")
      (should (equal (mapcar (lambda (op) (plist-get op :op)) (drgnx-buffers-test--ops)) '("put")))
      (with-current-buffer a (insert "one"))
      (drgnx-buffers-test--settle (lambda () (string-search (drgnx-face-glyph 'dot) (drgnx-buffers-test--tail a))) "the ●")
      (with-current-buffer a (insert "two"))
      (drgnx-signal--flush)
      (drgnx-buffers--send)
      (should (equal (drgnx-buffers-test--ops)
                     (list (list :op "modified" :id (gethash a drgnx-buffers--ids) :modified t))))
      (with-current-buffer a (save-buffer))
      (drgnx-buffers-test--settle (lambda () (not (string-search (drgnx-face-glyph 'dot) (drgnx-buffers-test--tail a))))
                                  "the ● gone after the save")
      (should (equal (drgnx-buffers-test--ops)
                     (list (list :op "modified" :id (gethash a drgnx-buffers--ids) :modified :false)))))))

(ert-deftest drgnx-buffers/modified-files-show-a-dot ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")))
      (with-current-buffer a (insert "change"))
      (drgnx-buffers-test--settle (lambda () (string-search (drgnx-face-glyph 'dot) (drgnx-buffers-test--tail a))) "the ●")
      ;; the dot takes the close button's place at the right edge, always shown
      (let* ((tail (drgnx-buffers-test--tail a)) (i (string-search (drgnx-face-glyph 'dot) tail)))
        (should (get-text-property i 'drgnx-row-control tail))
        (should (memq 'drgnx-buffers-modified (ensure-list (get-text-property i 'face tail))))
        (should-not (string-search (drgnx-face-glyph 'close) tail))))))

(ert-deftest drgnx-buffers/a-hovered-modified-row-shows-close ()
  ;; VS Code's way: the dot of a file with unsaved changes becomes the close button while its row is hovered (Nidhogg's
  ;; mouse sensors call the row's sensor with entered and left)
  (drgnx-buffers-test--with dir
    (let* ((a (drgnx-buffers-test--open dir "a.txt"))
           (b (drgnx-buffers-test--open dir "b.txt"))
           (win (get-buffer-window drgnx-buffers-buffer-name))
           (sensor (lambda (buf)
                     (with-current-buffer drgnx-buffers-buffer-name
                       (let ((row (drgnx-buffers--row-pos buf)))
                         (cons (get-char-property row 'mouse-sensor-functions) row)))))
           (sense (lambda (buf dir)
                    (pcase-let ((`(,fns . ,row) (funcall sensor buf)))
                      (dolist (f fns) (funcall f win row dir))))))
      (with-current-buffer a (insert "change"))
      (drgnx-buffers-test--settle (lambda () (string-search (drgnx-face-glyph 'dot) (drgnx-buffers-test--tail a))) "the ●")
      ;; each row has a sensor of its own, on its row and on its tail
      (should (car (funcall sensor a)))
      (should-not (eq (car (funcall sensor a)) (car (funcall sensor b))))
      (should (eq (car (funcall sensor a))
                  (get-text-property 0 'mouse-sensor-functions (drgnx-buffers-test--tail a))))
      (funcall sense a 'entered)
      (let ((tail (drgnx-buffers-test--tail a)))
        (should (string-search (drgnx-face-glyph 'close) tail))
        (should-not (string-search (drgnx-face-glyph 'dot) tail)))
      ;; the sensor stays the same object through the repaint: the pointer is still on the row
      (should (eq (car (funcall sensor a))
                  (get-text-property 0 'mouse-sensor-functions (drgnx-buffers-test--tail a))))
      (funcall sense a 'left)
      (let ((tail (drgnx-buffers-test--tail a)))
        (should (string-search (drgnx-face-glyph 'dot) tail))
        (should-not (string-search (drgnx-face-glyph 'close) tail))))))

(ert-deftest drgnx-buffers/a-row-is-the-icon-and-the-name ()
  ;; window-dark.html's Open rows: the file's icon and name; no folder, no close column at the start; the close
  ;; button is the control at the right edge, hidden until the row is hovered (a terminal always shows it).  A name
  ;; with two spaces in it is the row's whole name, and the whole row lights under the pointer.
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "sub/a  b.el")))     ; no x in it: an ASCII terminal's close glyph is x
      (with-current-buffer drgnx-buffers-buffer-name
        (let* ((row (drgnx-buffers--row-pos a))
               (text (buffer-substring-no-properties row (save-excursion (goto-char row) (pos-eol)))))
          (should (equal "a  b.el" (string-trim text)))
          (should-not (string-search "sub" text))
          (should-not (string-search (drgnx-face-glyph 'close) text))
          (should (get-char-property (+ row 2 3) 'mouse-face))))
      (let* ((tail (drgnx-buffers-test--tail a)) (i (string-search (drgnx-face-glyph 'close) tail)))
        (should i)
        (should (get-text-property i 'drgnx-row-control tail))))))

(ert-deftest drgnx-buffers/a-click-on-the-control-closes-the-row ()
  ;; a click on the right edge's × closes that row's buffer; a click elsewhere on the row opens it
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt")))
      (let* ((tail (drgnx-buffers-test--tail b)) (i (string-search (drgnx-face-glyph 'close) tail))
             (w (drgnx-wb-section-window 'buffers))
             (eol (with-current-buffer drgnx-buffers-buffer-name
                    (save-excursion (goto-char (drgnx-buffers--row-pos b)) (pos-eol))))
             (posn (list w eol '(0 . 0) 0 (cons tail i) eol)))
        (should (drgnx-buffers--on-control-p posn))
        (drgnx-buffers-mouse-click (list 'mouse-1 posn posn)))
      (should (buffer-live-p a))
      (should-not (buffer-live-p b)))))

(ert-deftest drgnx-buffers/view-and-selection-stay-by-identity ()
  (drgnx-buffers-test--with dir
    (let ((bufs (mapcar (lambda (i) (drgnx-buffers-test--open dir (format "f%02d.txt" i))) (number-sequence 0 39)))
          (w (drgnx-wb-section-window 'buffers)))
      (with-current-buffer drgnx-buffers-buffer-name
        (set-window-start w (drgnx-buffers--row-pos (nth 15 bufs)))
        (set-window-point w (drgnx-buffers--row-pos (nth 20 bufs))))
      (drgnx-buffers-test--open dir "zz-new.txt")
      (with-current-buffer drgnx-buffers-buffer-name
        (should (eq (drgnx-buffers-buffer-at (window-start w)) (nth 15 bufs)))
        (should (eq (drgnx-buffers-buffer-at (window-point w)) (nth 20 bufs)))))))

(ert-deftest drgnx-buffers/a-draw-keeps-each-window-on-its-buffer ()
  ;; Two windows on the panel and its own point: rows closing above them keep each start and point on its buffer, at
  ;; the same place in the row; a window whose first row closed falls to the row now in its place, not to the top.
  (drgnx-buffers-test--with dir
    (let* ((bufs (mapcar (lambda (i) (drgnx-buffers-test--open dir (format "f%02d.txt" i))) (number-sequence 0 39)))
           (w1 (drgnx-wb-section-window 'buffers)) (w2 (split-window (drgnx-wb-editor-window)))
           (pos (lambda (i) (drgnx-buffers--row-pos (nth i bufs)))))
      (select-window (drgnx-wb-editor-window))
      (set-window-buffer w2 drgnx-buffers-buffer-name)
      (with-current-buffer drgnx-buffers-buffer-name
        (set-window-start w1 (funcall pos 15))
        (set-window-point w1 (+ (funcall pos 20) 4))
        (set-window-start w2 (funcall pos 5))
        (set-window-point w2 (+ (funcall pos 8) 2))
        (goto-char (1+ (funcall pos 30))))
      (kill-buffer (nth 12 bufs))                       ; between the two windows' rows
      (drgnx-buffers-test--kill (nth 5 bufs))           ; the second window's first row
      (with-current-buffer drgnx-buffers-buffer-name
        (should-not (drgnx-buffers--row-pos (nth 5 bufs)))
        (should (= (window-start w1) (funcall pos 15)))
        (should (= (window-point w1) (+ (funcall pos 20) 4)))
        (should (= (window-start w2) (funcall pos 6)))
        (should (= (window-point w2) (+ (funcall pos 8) 2)))
        (should (= (point) (1+ (funcall pos 30))))))))

(ert-deftest drgnx-buffers/close-kills-exactly-the-rows-buffer ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (drgnx-buffers-close-at (drgnx-buffers--row-pos b)))
      (should (buffer-live-p a))
      (should-not (buffer-live-p b))
      (should (buffer-live-p c)))))

(ert-deftest drgnx-buffers/the-header-is-the-windows ()
  (drgnx-buffers-test--with dir
    (let ((w (drgnx-wb-section-window 'buffers)))
      (with-current-buffer drgnx-buffers-buffer-name (setq header-line-format nil))
      (should (stringp (window-parameter w 'header-line-format))))))

(ert-deftest drgnx-buffers/a-newline-in-a-name-keeps-rows-in-step ()
  (drgnx-buffers-test--with dir
    (let ((b (drgnx-buffers-test--open dir "b.txt")) (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer b (rename-buffer "b\nodd"))
      (drgnx-buffers-test--settle (lambda () (string-search "b^Jodd" (buffer-string))) "the renamed row")
      (with-current-buffer drgnx-buffers-buffer-name
        (should (= (count-lines (point-min) (point-max)) (length (drgnx-buffers--shown))))
        (goto-char (point-min)) (search-forward "c.txt")
        (should (eq (drgnx-buffers-buffer-at (point)) c))))))

(ert-deftest drgnx-buffers/the-selection-highlight-survives-a-draw ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt")))
      (select-window (get-buffer-window drgnx-buffers-buffer-name))   ; its selection shows while it has focus
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos b))
        (drgnx-wb-selection-sync))
      (with-current-buffer a (insert "x"))           ; ● on a: its row drawn again
      (drgnx-buffers-test--settle (lambda () (string-search (drgnx-face-glyph 'dot) (drgnx-buffers-test--tail a))) "the ●")
      (with-current-buffer drgnx-buffers-buffer-name
        (should (= (overlay-start drgnx-wb--selected-overlay) (drgnx-buffers--row-pos b)))))))

(ert-deftest drgnx-buffers/nothing-goes-while-a-button-is-held ()
  (drgnx-buffers-test--with dir
    (drgnx-buffers-test--open dir "a.txt")
    (drgnx-buffers-test--ops)
    (setq drgnx-buffers--pressed t)
    (let ((b (find-file-noselect (expand-file-name "b.txt" dir))))
      (drgnx-signal--flush)
      (drgnx-buffers--send)
      (should-not (drgnx-buffers-test--ops))         ; held: rows stay under the pointer
      (drgnx-buffers-mouse-ignore nil)               ; the release
      (should (drgnx-buffers-test--ops))
      (drgnx-buffers-test--settle (lambda () (drgnx-buffers--row-pos b)) "the held buffer's row")
      (should (member "b.txt" (drgnx-buffers-test--rows dir))))))

(ert-deftest drgnx-buffers/renames-and-saved-flags-show-up ()
  ;; M3a-2: a rename, or a buffer marked unmodified without saving, is reflected after the next flush.
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")))
      (with-current-buffer a (rename-buffer "renamed.txt"))     ; a rename alone
      (drgnx-buffers-test--settle (lambda () (string-search "renamed.txt" (buffer-string))) "the renamed row")
      (with-current-buffer a (insert "x"))
      (drgnx-buffers-test--settle (lambda () (string-search (drgnx-face-glyph 'dot) (drgnx-buffers-test--tail a))) "the ●")
      (with-current-buffer a (set-buffer-modified-p nil))        ; unmodified without a save
      (drgnx-buffers-test--settle (lambda () (not (string-search (drgnx-face-glyph 'dot) (drgnx-buffers-test--tail a))))
                                  "the ● gone")
      (with-current-buffer drgnx-buffers-buffer-name
        (let ((row (buffer-substring (drgnx-buffers--row-pos a) (save-excursion (goto-char (drgnx-buffers--row-pos a)) (pos-eol)))))
          (should (string-search "renamed.txt" row)))))))

(ert-deftest drgnx-signal/every-command-arms-a-flush ()
  ;; Undo back to the saved state flips the modified flag without any buffer hook.
  (unwind-protect
      (progn (drgnx-signal-mode 1)
             (drgnx-timer-cancel 'signal-flush)                    ; enabling arms one itself
             (run-hooks 'post-command-hook)
             (should (drgnx-timer-active-p 'signal-flush)))
    (drgnx-timer-cancel 'signal-flush)))

;;;; Actions (M3b)

(ert-deftest drgnx-buffers/save-all-and-close-saved ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer a (insert "A"))
      (with-current-buffer b (insert "B"))
      (drgnx-buffers-close-saved)                    ; c only: a and b have unsaved changes
      (should-not (buffer-live-p c))
      (should (and (buffer-live-p a) (buffer-live-p b)))
      (drgnx-buffers-save-all)
      (should-not (buffer-modified-p a))
      (should (string-prefix-p "A" (with-temp-buffer (insert-file-contents (expand-file-name "a.txt" dir)) (buffer-string)))))))

(ert-deftest drgnx-buffers/close-others-and-close-all ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos b))
        (drgnx-buffers-close-others))
      (should (buffer-live-p b))
      (should-not (or (buffer-live-p a) (buffer-live-p c)))
      (drgnx-buffers-close-all)
      (should-not (buffer-live-p b)))))

(ert-deftest drgnx-buffers/filter-by-name ()
  (drgnx-buffers-test--with dir
    (drgnx-buffers-test--open dir "alpha.txt")
    (drgnx-buffers-test--open dir "beta.txt")
    (drgnx-buffers-test--open dir "alphabet.md")
    (drgnx-buffers--filter-apply "ALPHA")
    (drgnx-buffers-test--settle (lambda () (equal (drgnx-buffers-test--rows dir) '("alpha.txt" "alphabet.md")))
                                "the filtered rows")
    (let ((gamma (find-file-noselect (expand-file-name "gamma.txt" dir))))   ; a new buffer while filtered: still filtered
      (drgnx-signal--flush)
      (drgnx-buffers-test--settle (lambda () (gethash gamma drgnx-buffers--sent)) "gamma put")
      (drgnx-buffers--filter-apply nil)
      (drgnx-buffers-test--settle (lambda () (= 4 (length (drgnx-buffers-test--rows dir)))) "every row again")
      (should (equal (drgnx-buffers-test--rows dir) '("alpha.txt" "beta.txt" "alphabet.md" "gamma.txt"))))))

(ert-deftest drgnx-buffers/close-commands-act-on-the-rows-shown ()
  ;; Close Saved, Close Others and Close All never touch buffers the filter hides.
  (drgnx-buffers-test--with dir
    (let ((alpha (drgnx-buffers-test--open dir "alpha.txt")) (alps (drgnx-buffers-test--open dir "alps.txt"))
          (zzz (drgnx-buffers-test--open dir "zzz.txt"))
          (alive (lambda (bufs) (seq-filter #'buffer-live-p bufs))))
      (drgnx-buffers--filter-apply "alp")
      (drgnx-buffers-test--settle (lambda () (not (drgnx-buffers--row-pos zzz))) "zzz filtered out")
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos alpha))
        (drgnx-buffers-close-others))
      (should (equal (funcall alive (list alpha alps zzz)) (list alpha zzz)))
      (drgnx-buffers-close-saved)
      (should (equal (funcall alive (list alpha zzz)) (list zzz)))
      (let ((other (drgnx-buffers-test--open dir "alpine.txt")))
        (drgnx-buffers-close-all)
        (should-not (buffer-live-p other))
        (should (buffer-live-p zzz))))))

(ert-deftest drgnx-buffers/no-selection-while-another-window-has-focus ()
  "window-dark.html: the sidebar shows one selected row, the Files row of the current buffer.  The Buffers panel
shows its selected row only while its window has focus."
  (drgnx-buffers-test--with dir
    (let ((b (drgnx-buffers-test--open dir "b.txt")) (panel (get-buffer-window drgnx-buffers-buffer-name)))
      (should (window-live-p panel))
      (should-not (eq panel (selected-window)))
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos b))
        (drgnx-wb-selection-sync)
        (should-not (and (overlayp drgnx-wb--selected-overlay) (overlay-buffer drgnx-wb--selected-overlay))))
      (with-selected-window panel
        (goto-char (drgnx-buffers--row-pos b))
        (drgnx-wb-selection-sync)
        (should (= (overlay-start drgnx-wb--selected-overlay) (drgnx-buffers--row-pos b)))))))

(ert-deftest drgnx-buffers/the-git-letter-is-the-hubs ()
  "A changed file's row has its git letter at the right edge: the hub marks the row from the status `git/letters'
read on the same connection."
  (skip-unless (executable-find "git"))
  (drgnx-buffers-test--with dir
    (let ((default-directory dir))
      (write-region "one\n" nil (expand-file-name "b.txt" dir) nil 'silent)
      (dolist (args '(("init" "-q") ("add" "-A") ("-c" "user.name=t" "-c" "user.email=t@t" "commit" "-qm" "x")))
        (should (zerop (apply #'call-process "git" nil nil nil args))))
      (write-region "two\n" nil (expand-file-name "b.txt" dir) nil 'silent))
    (let ((b (drgnx-buffers-test--open dir "b.txt")))
      (drgnx-git-refresh dir)
      (drgnx-buffers-test--settle (lambda () (string-search "M" (or (drgnx-buffers-test--tail b) ""))) "the M"))))

;;;; Row actions with the Explorer (drgnx-actions)

(defmacro drgnx-buffers-test--with-explorer (root &rest body)
  "BODY in `drgnx-buffers-test--with' ROOT, with an Explorer rooted at ROOT (a.txt, sub/b.txt; the Lisp listing) and
the rules on."
  (declare (indent 1))
  `(drgnx-buffers-test--with ,root
     (let ((drgnx-explorer--lisp-listing t) (display-buffer-alist nil))
       (unwind-protect
           (progn
             (make-directory (expand-file-name "sub" ,root))
             (dolist (f '("a.txt" "sub/b.txt")) (write-region "x\n" nil (expand-file-name f ,root) nil 'silent))
             (drgnx-rules-mode 1)
             (drgnx-wb-hide-sidebar)
             (drgnx-explorer-setup)
             (drgnx-explorer-set-roots (list ,root))
             (drgnx-wb-show-sidebar)
             ,@body)
         (drgnx-rules-mode -1)
         (drgnx-explorer-set-roots nil)                 ; its watches go: no events from the folder's removal
         (drgnx-wb-hide-sidebar) (drgnx-wb-area-hide 'panel)
         (dolist (b (buffer-list))
           (when (with-current-buffer b (and (derived-mode-p 'dired-mode) (string-prefix-p ,root default-directory)))
             (kill-buffer b)))
         (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))))))

(defun drgnx-buffers-test--explorer-at (name)
  (select-window (drgnx-wb-section-window 'explorer))
  (goto-char (point-min))
  (re-search-forward (regexp-quote name))
  (current-buffer))

(ert-deftest drgnx-actions/buffers-rows ()
  (drgnx-buffers-test--with-explorer root
    (let ((a (find-file-noselect (expand-file-name "a.txt" root))))
      (drgnx-buffers-test--settle (lambda () (drgnx-buffers--row-pos a)) "a's row")
      (with-current-buffer a (insert "y"))
      (select-window (drgnx-wb-section-window 'buffers))
      (goto-char (drgnx-buffers--row-pos a))
      (drgnx-buffers-save-row)
      (should-not (buffer-modified-p a))
      (drgnx-buffers-copy-path-row)
      (should (equal (current-kill 0) (expand-file-name "a.txt" root)))
      (drgnx-buffers-reveal-row)
      (should (eq (selected-window) (drgnx-wb-section-window 'explorer)))
      (should (equal (drgnx-explorer-node-at (point)) (expand-file-name "a.txt" root))))))

(ert-deftest drgnx-actions/explorer-rows ()
  (drgnx-buffers-test--with-explorer root
    (let ((a (find-file-noselect (expand-file-name "a.txt" root))))
      (drgnx-buffers-test--settle (lambda () (drgnx-buffers--row-pos a)) "a's row")
      (drgnx-buffers-test--explorer-at "a.txt")
      (drgnx-explorer-reveal-in-buffers)
      (should (eq (selected-window) (drgnx-wb-section-window 'buffers)))
      (should (eq (drgnx-buffers-buffer-at (point)) a))
      (drgnx-buffers-test--explorer-at "sub")
      (drgnx-explorer-open-in-dired)
      (should (with-current-buffer (window-buffer (drgnx-wb-editor-window)) (derived-mode-p 'dired-mode))))))

;;; wb-buffers-test.el ends here
