;;; wb-outline-test.el --- batch tests: the Outline section -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-outline)

(defmacro drgnx-outline-test--with (src &rest body)
  "BODY with SRC an elisp buffer in the editor and the Outline shown in the dock."
  (declare (indent 1))
  `(drgnx-test-with-state
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
       (unwind-protect (progn (drgnx-outline-refresh) ,@body)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (kill-buffer ,src)
         (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name))))))

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
    (should (null (drgnx-outline-test--names)))
    (should (string-match-p "No outline" (with-current-buffer drgnx-outline-buffer-name (buffer-string))))
    (let ((drgnx-outline-max-size 10))
      (with-current-buffer src (emacs-lisp-mode))
      (drgnx-outline-refresh)
      (should (string-match-p "too large" (with-current-buffer drgnx-outline-buffer-name (buffer-string)))))))

(ert-deftest drgnx-outline/an-edit-updates-it-after-a-pause ()
  (drgnx-outline-test--with src
    (with-current-buffer src (goto-char (point-max)) (insert "(defun delta () 4)\n"))
    (should (timerp drgnx-outline--timer))
    (drgnx-outline--idle)                         ; the pause
    (should (member "delta" (drgnx-outline-test--names)))))

(ert-deftest drgnx-outline/an-empty-index-is-a-notice ()
  ;; imenu answers (nil) for an elisp buffer without definitions (*scratch*).
  (drgnx-outline-test--with src
    (with-current-buffer src (erase-buffer) (insert ";; nothing\n"))
    (drgnx-outline-refresh)
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
           (marked (lambda () (with-current-buffer outline
                                (when-let* ((o (seq-find (lambda (o) (overlay-get o 'drgnx-outline-current))
                                                         (overlays-in (point-min) (point-max)))))
                                  (buffer-substring-no-properties (overlay-start o) (overlay-end o))))))
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
      (set-window-point editor 1)
      (drgnx-signal--flush)
      (should-not (funcall marked)))))
