;;; wb-outline-test.el --- batch tests: the Outline section -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-outline)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-outline-test--with (src &rest body)
  "BODY with SRC an elisp buffer in the editor and the Outline shown in the dock."
  (declare (indent 1))
  `(drgnx-test-with-state
     (drgnx-test-with-clock (:allow-pending t)
       (let ((drgnx-wb--sections nil)
             (,src (generate-new-buffer "outline-src.el")))
         (delete-other-windows)
         (with-current-buffer ,src
           (insert "(defun alpha () 1)\n(defvar beta 2)\n\n\n(defun gamma () 3)\n")
           (emacs-lisp-mode))
         (switch-to-buffer ,src)
         (drgnx-test-use-editor (selected-window))
         (drgnx-outline-setup)
         (drgnx-wb-show-sidebar)
         (unwind-protect (progn (drgnx-outline-refresh) (drgnx-outline-test--draw) ,@body)
           (drgnx-wb-hide-sidebar)
           (delete-other-windows)
           (kill-buffer ,src)
           (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name)))))))

(defun drgnx-outline-test--draw ()
  "Draw the Outline's view now (the view draws from its timer, which the tests do not run)."
  (with-current-buffer drgnx-outline-buffer-name (drgnx-view-draw-now drgnx-view)))

(defun drgnx-outline-test--rows-drawn ()
  (plist-get (drgnx-view-stats (buffer-local-value 'drgnx-view (get-buffer drgnx-outline-buffer-name))) :rows-drawn))

(defun drgnx-outline-test--text ()
  (with-current-buffer drgnx-outline-buffer-name (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-outline-test--marked ()
  "The text of the Outline's marked row, or nil."
  (with-current-buffer drgnx-outline-buffer-name
    (when-let* ((o (seq-find (lambda (o) (overlay-get o 'drgnx-outline-current)) (overlays-in (point-min) (point-max)))))
      (buffer-substring-no-properties (overlay-start o) (overlay-end o)))))

(defun drgnx-outline-test--names ()
  (with-current-buffer drgnx-outline-buffer-name
    (mapcar (lambda (r) (aref r 0)) drgnx-outline--rows)))

(ert-deftest drgnx-outline/lists-the-definitions-in-order ()
  (drgnx-outline-test--with src
    (let ((names (drgnx-outline-test--names)))
      (should (member "beta" names))
      (should (< (seq-position names "alpha") (seq-position names "gamma"))))))

(ert-deftest drgnx-outline/a-row-jumps-in-the-editor ()
  (drgnx-outline-test--with src
    (let ((editor (selected-window)))
      (with-current-buffer drgnx-outline-buffer-name
        (drgnx-outline-jump (seq-position (drgnx-outline-test--names) "gamma")))
      (should (eq (selected-window) editor))
      (should (equal (with-current-buffer src (save-excursion (goto-char (window-point editor)) (thing-at-point 'line t)))
                     "(defun gamma () 3)\n")))))

(ert-deftest drgnx-outline/no-index-shows-a-notice ()
  (drgnx-outline-test--with src
    (with-current-buffer src (fundamental-mode))
    (drgnx-outline-refresh)
    (drgnx-outline-test--draw)
    (should (null (drgnx-outline-test--names)))
    (should (string-match-p "No outline" (with-current-buffer drgnx-outline-buffer-name (buffer-string))))
    (let ((drgnx-outline-max-size 10))
      (with-current-buffer src (emacs-lisp-mode))
      (drgnx-outline-refresh)
      (drgnx-outline-test--draw)
      (should (string-match-p "too large" (with-current-buffer drgnx-outline-buffer-name (buffer-string)))))))

(ert-deftest drgnx-outline/quiet-in-a-large-file-buffer ()
  ;; a chunk of a large file is small (under `drgnx-outline-max-size'); the flag editor/large-files sets (by hand here)
  ;; says what it is: no index is built
  (require 'drgnx-large-file)
  (with-temp-buffer
    (insert "(defun alpha () 1)\n")
    (emacs-lisp-mode)
    (setq-local drgnx-large-file 'chunks)
    (cl-letf (((symbol-function 'imenu--make-index-alist) (lambda (&rest _) (ert-fail "an index of a large file"))))
      (should (equal (drgnx-outline--index (current-buffer)) "This file is too large for an outline")))))

(ert-deftest drgnx-outline/an-edit-updates-it-after-a-pause ()
  (drgnx-outline-test--with src
    (with-current-buffer src (goto-char (point-max)) (insert "(defun delta () 4)\n"))
    (should (drgnx-timer-active-p 'outline-refresh))
    (drgnx-outline--idle)                         ; the pause
    (drgnx-outline-test--draw)
    (should (member "delta" (drgnx-outline-test--names)))))

(ert-deftest drgnx-outline/an-empty-index-is-a-notice ()
  ;; imenu answers (nil) for an elisp buffer without definitions (*scratch*).
  (drgnx-outline-test--with src
    (with-current-buffer src (erase-buffer) (insert ";; nothing\n"))
    (drgnx-outline-refresh)
    (drgnx-outline-test--draw)
    (should (null (drgnx-outline-test--names)))
    (should (string-match-p "No outline" (with-current-buffer drgnx-outline-buffer-name (buffer-string))))))

(ert-deftest drgnx-outline/no-rescan-row ()
  (drgnx-outline-test--with src
    (let ((imenu-auto-rescan nil))
      (should-not (member "*Rescan*" (drgnx-outline-test--names))))))

(ert-deftest drgnx-outline/a-hidden-outline-computes-nothing ()
  ;; I6: building an index can take most of a second (python-mode, 114 KB); hidden, it is not built.
  (drgnx-outline-test--with src
    (drgnx-wb-hide-sidebar)
    (let ((n 0))
      (cl-letf* ((orig (symbol-function 'imenu--make-index-alist))
                 ((symbol-function 'imenu--make-index-alist) (lambda (&rest a) (setq n (1+ n)) (apply orig a))))
        (drgnx-outline-refresh)
        (should (= n 0))
        (drgnx-wb-show-sidebar)                    ; :on-show builds it
        (should (= n 1))))))

(ert-deftest drgnx-outline/ret-is-a-registry-command ()
  ;; I10: keys come from the profiles, never a direct `define-key'.
  (should-not (lookup-key (let ((m (copy-keymap drgnx-outline-mode-map))) (set-keymap-parent m nil) m) (kbd "RET"))))

(ert-deftest drgnx-outline/follows-current-symbol ()
  ;; DEFERRED M3d-6: the definition the editor's point is in is marked in the Outline with an overlay; the
  ;; Outline's own point (the user's selection in it) never moves.
  (drgnx-outline-test--with src
    (let* ((editor (selected-window)) (outline (get-buffer drgnx-outline-buffer-name))
           (marked #'drgnx-outline-test--marked)
           (here (with-current-buffer outline (point))))
      (drgnx-signal--flush)                          ; the starting state
      (set-window-point editor (with-current-buffer src (goto-char (point-min)) (search-forward "gamma") (point)))
      (drgnx-signal--flush)
      (should (string-match-p "gamma" (funcall marked)))
      (set-window-point editor (with-current-buffer src (goto-char (point-min)) (search-forward "beta") (point)))
      (drgnx-signal--flush)
      (should (string-match-p "beta" (funcall marked)))
      (should (= here (with-current-buffer outline (point))))
      ;; before the first definition: nothing is marked
      (with-current-buffer src (goto-char (point-min)) (insert ";; header\n"))
      (drgnx-outline--idle)
      (drgnx-outline-test--draw)
      (set-window-point editor 1)
      (drgnx-signal--flush)
      (should-not (funcall marked)))))

;;;; The Outline on the view (PERF-M1)

(defun drgnx-outline-test--big-source (src n)
  "Fill SRC with N definitions."
  (with-current-buffer src
    (erase-buffer)
    (dotimes (i n) (insert (format "(defun fn-%d () %d)\n" i i)))))

(ert-deftest drgnx-outline/no-imenu-marker-is-left ()
  ;; Every marker imenu makes is unchained before the refresh returns: 50 refreshes of 2,000 definitions leave none
  ;; in the source buffer (a marker slows every edit of the buffer until a garbage collection frees it).
  (drgnx-outline-test--with src
    (drgnx-outline-test--big-source src 2000)
    (let ((indexes nil) (seen 0) (live 0))
      (cl-letf* ((orig (symbol-function 'imenu--make-index-alist))
                 ((symbol-function 'imenu--make-index-alist)
                  (lambda (&rest a) (let ((r (apply orig a))) (push r indexes) r))))
        (dotimes (_ 50) (drgnx-outline--refresh-1)))
      (cl-labels ((walk (x) (cond ((markerp x) (cl-incf seen) (when (marker-buffer x) (cl-incf live)))
                                  ((consp x) (while (consp x) (walk (car x)) (setq x (cdr x))) (walk x)))))
        (mapc #'walk indexes))
      (should (>= seen (* 50 2000)))                ; the spy saw the markers imenu made
      (should (= live 0))
      (should (= (length drgnx-outline--rows) 2000))
      (should (integerp (aref (aref drgnx-outline--rows 0) 2))))))

(ert-deftest drgnx-outline/an-edit-that-moves-positions-redraws-nothing ()
  (drgnx-outline-test--with src
    (let* ((drawn (drgnx-outline-test--rows-drawn))
           (pos (lambda () (aref (seq-find (lambda (r) (equal (aref r 0) "alpha")) drgnx-outline--rows) 2)))
           (old (funcall pos)))
      (should (> drawn 0))
      (with-current-buffer src (goto-char (point-min)) (insert ";; a header comment\n;; and another\n"))
      (drgnx-outline--refresh-1)
      (drgnx-outline-test--draw)
      (should (= (drgnx-outline-test--rows-drawn) drawn))
      (should (> (funcall pos) old))   ; the positions did move
      (should-not (drgnx-view--check (buffer-local-value 'drgnx-view (get-buffer drgnx-outline-buffer-name)))))))

(ert-deftest drgnx-outline/a-new-definition-inserts-one-row ()
  (drgnx-outline-test--with src
    (let ((drawn (drgnx-outline-test--rows-drawn)))
      (with-current-buffer src (goto-char (point-max)) (insert "(defun delta () 4)\n"))
      (drgnx-outline--refresh-1)
      (drgnx-outline-test--draw)
      (should (= (drgnx-outline-test--rows-drawn) (1+ drawn)))
      (should (string-match-p "gamma.*\n.*delta" (drgnx-outline-test--text)))
      (should-not (drgnx-view--check (buffer-local-value 'drgnx-view (get-buffer drgnx-outline-buffer-name)))))))

(ert-deftest drgnx-outline/rows-are-keyed-by-name-depth-and-ordinal ()
  (drgnx-outline-test--with src
    (with-current-buffer src (goto-char (point-max)) (insert "(defun alpha () 9)\n"))   ; a second "alpha"
    (drgnx-outline--refresh-1)
    (drgnx-outline-test--draw)
    (let ((view (buffer-local-value 'drgnx-view (get-buffer drgnx-outline-buffer-name))))
      (should (drgnx-view-row-start view '("alpha" 0 0)))
      (should (drgnx-view-row-start view '("alpha" 0 1)))
      (should-not (drgnx-view-row-start view '("alpha" 0 2))))))

(ert-deftest drgnx-outline/the-outline-keeps-its-place ()
  ;; A definition added above does not move the Outline's point off its row.
  (drgnx-outline-test--with src
    (let* ((outline (get-buffer drgnx-outline-buffer-name)) (window (get-buffer-window outline t))
           (row-at (lambda () (with-current-buffer outline (buffer-substring-no-properties (pos-bol) (pos-eol))))))
      (with-current-buffer outline
        (goto-char (point-min)) (search-forward "gamma")
        (set-window-point window (point)))
      (should (string-match-p "gamma" (funcall row-at)))
      (with-current-buffer src (goto-char (point-min)) (insert "(defun aardvark () 0)\n"))
      (drgnx-outline--refresh-1)
      (drgnx-outline-test--draw)
      (should (string-match-p "aardvark" (drgnx-outline-test--text)))
      (should (string-match-p "gamma" (funcall row-at)))
      (should (string-match-p "gamma" (with-current-buffer outline
                                        (save-excursion (goto-char (window-point window))
                                                        (buffer-substring-no-properties (pos-bol) (pos-eol)))))))))

(ert-deftest drgnx-outline/another-file-starts-at-the-top-or-the-current-definition ()
  ;; UI audit #3: after a file switch the Outline's window sat on its last row.  Another file starts at the top, with
  ;; the Outline's point on the definition the editor's point is in.
  (drgnx-outline-test--with src
    (let* ((outline (get-buffer drgnx-outline-buffer-name)) (window (get-buffer-window outline t))
           (editor (selected-window)) (other (generate-new-buffer "outline-other.el"))
           (row-at (lambda (pos) (with-current-buffer outline
                                   (save-excursion (goto-char pos) (buffer-substring-no-properties (pos-bol) (pos-eol)))))))
      (unwind-protect
          (progn
            (drgnx-outline-test--big-source other 200)
            (with-current-buffer other (emacs-lisp-mode) (goto-char (point-min)))
            (with-current-buffer outline (set-window-point window (point-max)) (goto-char (point-max)))
            (set-window-buffer editor other)
            (set-window-point editor 1)
            (drgnx-outline--refresh-1)
            (drgnx-outline-test--draw)
            (should (= (window-start window) (with-current-buffer outline (point-min))))
            (should (string-match-p "fn-0$" (funcall row-at (window-point window))))
            ;; back and forth: the current definition, far down, is shown
            (set-window-buffer editor src)
            (drgnx-outline--refresh-1)
            (drgnx-outline-test--draw)
            (set-window-buffer editor other)
            (set-window-point editor (with-current-buffer other (goto-char (point-min)) (search-forward "fn-150 ") (point)))
            (drgnx-outline--refresh-1)
            (drgnx-outline-test--draw)
            (should (string-match-p "fn-150$" (funcall row-at (window-point window))))
            (should (< (window-start window) (window-point window)))
            ;; the same file again: the Outline's own point stays
            (with-current-buffer outline (set-window-point window (point-min)))
            (with-current-buffer other (goto-char (point-max)) (insert "(defun fn-200 () 0)\n"))
            (drgnx-outline--refresh-1)
            (drgnx-outline-test--draw)
            (should (= (window-point window) (with-current-buffer outline (point-min)))))
        (set-window-buffer editor src)
        (kill-buffer other)))))

(ert-deftest drgnx-outline/the-current-mark-follows-the-patch ()
  ;; The mark is an overlay on a row; drawing the row again (or a row above it) puts the mark back (PATCHED).
  (drgnx-outline-test--with src
    (let* ((editor (selected-window))
           (view(buffer-local-value 'drgnx-view (get-buffer drgnx-outline-buffer-name))))
      (drgnx-signal--flush)
      (set-window-point editor (with-current-buffer src (goto-char (point-min)) (search-forward "gamma") (point)))
      (drgnx-signal--flush)
      (should (string-match-p "gamma" (drgnx-outline-test--marked)))
      (drgnx-view-dirty view (list '("gamma" 0 0)))          ; the marked row is drawn again
      (drgnx-outline-test--draw)
      (should (string-match-p "gamma" (drgnx-outline-test--marked)))
      (with-current-buffer src (goto-char (point-min)) (insert "(defun aardvark () 0)\n"))   ; and a row above it
      (set-window-point editor (with-current-buffer src (goto-char (point-min)) (search-forward "gamma") (point)))
      (drgnx-outline--refresh-1)
      (drgnx-outline-test--draw)
      (should (string-match-p "gamma" (drgnx-outline-test--marked))))))

(ert-deftest drgnx-outline/the-edit-timer-is-the-layers ()
  (drgnx-outline-test--with src
    (should-not (drgnx-timer-active-p 'outline-refresh))
    (with-current-buffer src (goto-char (point-max)) (insert "(defun delta () 4)\n"))
    (should (drgnx-timer-active-p 'outline-refresh))
    (should (assoc 'outline-refresh (mapcar (lambda (e) (cons (car e) (nth 2 e))) (drgnx-timer-pending))))))
