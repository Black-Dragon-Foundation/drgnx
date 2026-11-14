;;; mod-sticky-test.el --- batch tests: sticky scroll — the scopes scrolled past, in the header after the breadcrumb -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/memo-alloc-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/measure-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-sticky" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defun drgnx-sticky-test--elisp (n)
  "A buffer text: a defun of N body lines."
  (concat "(defun drgnx-sticky-test-fn ()\n  \"Doc.\"\n"
          (mapconcat (lambda (i) (format "  (message \"line %d\")" i)) (number-sequence 1 n) "\n")
          ")\n"))

(defmacro drgnx-sticky-test--in (text mode &rest body)
  "BODY in a buffer with TEXT in MODE, shown in the selected window."
  (declare (indent 2))
  `(let ((b (generate-new-buffer "sticky-test")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer b)
           (insert ,text)
           (funcall ,mode)
           (goto-char (point-min))
           ,@body)
       (kill-buffer b))))

(defun drgnx-sticky-test--start-at-line (n)
  (set-window-start (selected-window) (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point))))

;; The scopes of a buffer without tree-sitter come from the hub: mod-sticky-hub-test.el.

(ert-deftest drgnx-sticky/a-parse-not-ready-is-never-waited-for ()
  ;; On Nidhogg a parse job (a large file's first parse) may still run when the header is drawn: the hub answers then,
  ;; a poll redraws once the tree is ready, and the next build reads tree-sitter
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
    (let ((ready nil) (polls nil) (b (current-buffer)) (epoch (drgnx-epoch 'sticky (current-buffer))))
      (cl-letf (((symbol-function 'treesit-parser-list) (lambda (&rest _) '(parser)))
                ((symbol-function 'treesit-parser-p) (lambda (p) (eq p 'parser)))
                ((symbol-function 'nidhogg-treesit-parser-ready-p) (lambda (_p) ready))
                ((symbol-function 'drgnx-timer-poll) (lambda (&rest args) (push args polls))))
        (should-not (drgnx-sticky--treesit-p))
        (should (equal (car (car polls)) (cons 'sticky-parse b)))
        (should (eq (nth 2 (car polls)) 'drgnx-sticky--parse-landed))
        (should-not (drgnx-sticky--parse-landed b))          ; still parsing: the poll goes on, the header stays
        (should (equal (drgnx-epoch 'sticky b) epoch))
        (setq ready t)
        (should (drgnx-sticky--parse-landed b))              ; ready: one redraw, the poll ends
        (should-not (equal (drgnx-epoch 'sticky b) epoch))
        (should (drgnx-sticky--treesit-p))
        (should (= (length polls) 1))
        (let ((dead (generate-new-buffer " sticky-dead")))   ; a buffer killed meanwhile ends the poll
          (kill-buffer dead)
          (should (drgnx-sticky--parse-landed dead)))))))

(ert-deftest drgnx-sticky/the-scopes-are-names-in-the-caption-face ()
  "The look (design §4, breadcrumbs): symbol names in the UI caption, never the scope's code line; a `%' is doubled."
  (let ((s (drgnx-sticky--join '("Shape" "drgnx-sticky-test-%pct"))))
    (should (equal (substring-no-properties s) " › Shape › drgnx-sticky-test-%%pct"))   ; the mode line expands a single %
    (should (memq 'drgnx-sticky (ensure-list (get-text-property (1- (length s)) 'face s))))
    (should (memq 'drgnx-ui-caption (ensure-list (face-attribute 'drgnx-sticky :inherit)))))
  (should (equal (drgnx-sticky--join nil) "")))

(ert-deftest drgnx-sticky/at-most-three-outermost-and-only-those-above ()
  ;; The hub's answer for a start line: the scopes that start above it, the outermost three; one starting on the line
  ;; itself is on screen, so it is not shown
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 60) #'emacs-lisp-mode
    (let ((b (current-buffer)) (epoch (drgnx-epoch 'sticky (current-buffer))))
      (drgnx-sticky--answered b (buffer-chars-modified-tick) 50
                              '((:name "a" :line 1) (:name "b" :line 2) (:name "c" :line 3) (:name "d" :line 4)
                                (:name "e" :line 50)))
      (should (equal (substring-no-properties (aref drgnx-sticky--hub 2)) " › a › b › c"))
      (should-not (equal (drgnx-epoch 'sticky b) epoch))))) ; the header is drawn again

(ert-deftest drgnx-sticky/with-no-hub-no-scopes-and-the-ask-goes-nowhere ()
  ;; A batch Emacs connects no hub: the header shows no scopes, and the question finds no one to ask
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
    (drgnx-sticky-test--start-at-line 20)
    (should (equal (drgnx-sticky--segment (selected-window)) ""))
    (should (equal drgnx-sticky--asked (cons (buffer-chars-modified-tick) 20)))
    (require 'drgnx-outline)
    (should-not (drgnx-outline-scopes (current-buffer) 20 #'ignore))
    (drgnx-timer-cancel (cons 'sticky-ask (current-buffer)))))

(ert-deftest drgnx-sticky/the-header-follows-the-mode ()
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
    (drgnx-sticky-mode 1)
    (save-window-excursion
      (set-window-buffer (selected-window) (current-buffer))
      (should (stringp (drgnx-sticky--tail (selected-window))))
      (drgnx-sticky-mode -1)
      (should-not (drgnx-sticky--tail (selected-window))))))

(ert-deftest drgnx-sticky/tree-sitter-scopes-without-the-root ()
  ;; python's root node is `module': never a scope (the file's first line is not)
  (skip-unless (and (fboundp 'treesit-language-available-p) (treesit-language-available-p 'python)))
  (drgnx-sticky-test--in (concat "import os\n\nclass Shape:\n    def area(self):\n"
                                 (mapconcat (lambda (i) (format "        y%d = %d" i i)) (number-sequence 1 30) "\n") "\n")
      #'python-ts-mode
    (drgnx-sticky-test--start-at-line 20)
    (should (equal (substring-no-properties (drgnx-sticky--segment (selected-window))) " › Shape › area"))))

(ert-deftest drgnx-sticky/turning-the-module-off-turns-sticky-scroll-off-in-live-buffers ()
  (let ((b (generate-new-buffer "sticky-off")))
    (unwind-protect
        (progn
          (drgnx-test-with-modules '(editor/sticky) :strict t
                                   (should (memq #'drgnx-sticky--maybe prog-mode-hook))
                                   (with-current-buffer b (emacs-lisp-mode) (drgnx-sticky-mode 1))
                                   (should (buffer-local-value 'drgnx-sticky-mode b)))
          (should-not (buffer-local-value 'drgnx-sticky-mode b))
          (should-not (memq #'drgnx-sticky--maybe prog-mode-hook)))
      (kill-buffer b))))

;;; mod-sticky-test.el ends here

(ert-deftest drgnx-sticky/the-chrome-is-left-alone-while-it-is-off ()
  ;; Turning sticky scroll on redraws the header only when the editor chrome is on: with drgnx-chrome loaded but
  ;; off (a test session, a configuration without the workbench), the window gets no tab line or header from it.
  (require 'drgnx-chrome)
  (let ((drgnx-chrome-mode nil))
    (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
      (dolist (p '(tab-line-format header-line-format mode-line-format)) (set-window-parameter nil p nil))
      (drgnx-sticky-mode 1)
      (should-not (window-parameter nil 'tab-line-format))
      (should-not (window-parameter nil 'header-line-format))
      (drgnx-sticky-mode -1))))

(ert-deftest drgnx-sticky/quiet-in-a-large-file-buffer ()
  ;; the flag editor/large-files sets (by hand here: the module is not needed): no sticky scroll
  (require 'drgnx-large-file)
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name "big.el" temporary-file-directory))
    (unwind-protect
        (progn (setq-local drgnx-large-file 'lean)
               (drgnx-sticky--maybe)
               (should-not drgnx-sticky-mode)
               (setq-local drgnx-large-file nil)            ; the same buffer, not large: on
               (drgnx-sticky--maybe)
               (should drgnx-sticky-mode))
      (drgnx-sticky-mode -1)
      (setq buffer-file-name nil))))
