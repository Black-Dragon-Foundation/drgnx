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

;;;; The `lines' style (F6) and pinned regions (X5)

(ert-deftest drgnx-sticky/lines-the-scopes-come-from-the-fold-table ()
  ;; The scopes holding the window's start that begin above it, outermost first, at most `drgnx-sticky-max'; one that
  ;; begins on the start's own line is on screen
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 60) #'emacs-lisp-mode
    (drgnx-sticky-test--start-at-line 30)
    (let* ((l (lambda (n) (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point))))
           (folds (list (list (funcall l 1) (funcall l 60) 'block 0 'model) (list (funcall l 2) (funcall l 50) 'block 1 'model)
                        (list (funcall l 3) (funcall l 40) 'block 2 'model) (list (funcall l 4) (funcall l 35) 'block 3 'model)
                        (list (funcall l 30) (funcall l 33) 'block 4 'model)))
           (drgnx-sticky-max 3))
      (cl-letf (((symbol-function 'drgnx-fold-ranges) (lambda (&rest _) folds)))
        (should (equal (drgnx-sticky--scopes (selected-window)) (list (funcall l 1) (funcall l 2) (funcall l 3))))))))

(ert-deftest drgnx-sticky/lines-the-header-wants-a-card-only-when-the-scopes-change ()
  ;; The `lines' style shows nothing after the breadcrumb; the card is filled again only for a new set of scopes
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 60) #'emacs-lisp-mode
    (let ((drgnx-sticky-style 'lines) (asked nil) (w (selected-window)) (drgnx-sticky--cards nil)
          (drgnx-sticky--pin-shown nil))
      (cl-letf (((symbol-function 'drgnx-timer-debounce) (lambda (&rest args) (push args asked)))
                ((symbol-function 'drgnx-sticky--scopes) (lambda (_w) '(1 33))))
        (drgnx-sticky-test--start-at-line 30)
        (should (equal (drgnx-sticky--segment w) ""))
        (should (equal (nth 2 (car asked)) #'drgnx-sticky--fill))
        (should (equal (plist-get (nthcdr 3 (car asked)) :args) (list w '(1 33))))
        ;; the card shows them: the same set wants nothing
        (setq drgnx-sticky--cards (list (cons w (vector nil nil '(1 33)))) asked nil)
        (drgnx-sticky--want w '(1 33))
        (should-not asked)
        ;; a window showing a pin keeps it
        (setq drgnx-sticky--pin-shown (list (cons w 'pin)))
        (drgnx-sticky--want w '(1))
        (should-not asked)))))

(ert-deftest drgnx-sticky/lines-a-line-is-its-number-and-its-code ()
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 60) #'emacs-lisp-mode
    (let* ((p (save-excursion (goto-char (point-min)) (forward-line 9) (point)))
           (s (drgnx-sticky--text-of (list (point-min) p) 3))
           (num (lambda (i) (cadr (get-text-property i 'display s)))))
      ;; each number in the left margin, padded to the editor's digits (3 here: not the card's last line's 2)
      (should (equal (substring-no-properties s) " (defun drgnx-sticky-test-fn ()\n   (message \"line 8\")"))
      (should (equal (car (get-text-property 0 'display s)) '(margin left-margin)))
      (should (equal (substring-no-properties (funcall num 0)) "   1 "))
      (should (equal (substring-no-properties (funcall num (1+ (string-search "\n" s)))) "  10 "))
      (should (memq 'line-number (ensure-list (get-text-property 0 'face (funcall num 0)))))
      ;; the editor shows no numbers: neither does the card
      (should (equal (substring-no-properties (drgnx-sticky--text-of (list (point-min)))) "(defun drgnx-sticky-test-fn ()"))
      (should (eq (get-text-property 0 'drgnx-sticky-pos s) (point-min)))
      (should (eq (get-text-property (- (length s) 1) 'drgnx-sticky-pos s) p))
      (should (eq (lookup-key (get-text-property 0 'keymap s) [mouse-1]) #'drgnx-sticky-click)))))

(ert-deftest drgnx-sticky/lines-a-click-goes-to-the-scope ()
  ;; A click on a card's line selects the window under the card and puts point on that scope's line; Ctrl+click folds it
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 60) #'emacs-lisp-mode
    (let* ((owner (selected-window)) (src (current-buffer))
           (p (save-excursion (goto-char (point-min)) (forward-line 9) (point)))
           (text (drgnx-sticky--text-of (list (point-min) p)))
           (card (generate-new-buffer " *sticky-card-test*")) (folded nil))
      (unwind-protect
          (let ((cw (split-window owner)))
            (with-current-buffer card (insert text) (setq drgnx-sticky--owner owner))
            (set-window-buffer cw card)
            (drgnx-sticky-test--start-at-line 30)
            (with-current-buffer src (goto-char (point-max)))
            (let ((event (list 'mouse-1 (list cw (with-current-buffer card (1- (point-max))) '(0 . 0) 0))))
              (select-window cw)
              (drgnx-sticky-click event)
              (should (eq (selected-window) owner))
              (should (= (point) p)))
            (cl-letf (((symbol-function 'drgnx-fold-toggle) (lambda () (interactive) (setq folded (point)))))
              (select-window cw)
              (drgnx-sticky-fold-click (list 'C-mouse-1 (list cw 2 '(0 . 0) 0)))
              (should (eq (selected-window) owner))
              (should (eql folded (point-min)))))
        (kill-buffer card)))))

(ert-deftest drgnx-sticky/pins-are-marks-and-the-minimaps-names ()
  ;; A pin: the region's lines, named for the symbol it defines; the scroll bar's `pin' marks run to its end, and the
  ;; minimap's spec carries the pin kind, the colour and the names in buffer order
  (load (expand-file-name "modules/editor/drgnx-minimap" drgnx-dir) nil t)
  (drgnx-sticky-test--in (concat (drgnx-sticky-test--elisp 10) (drgnx-sticky-test--elisp 10)) #'emacs-lisp-mode
    (let ((l (lambda (n) (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))) (sources nil))
      (cl-letf (((symbol-function 'drgnx-ruler-source)
                 (lambda (owner fn &optional _b) (setq sources (if fn (list (cons owner fn)) nil)))))
        (drgnx-pin-region (funcall l 13) (funcall l 16))
        (drgnx-pin-region (funcall l 2) (+ 3 (funcall l 3)) "head")
        (should (equal (drgnx-sticky-pin-names) '("head" "drgnx-sticky-test-fn")))   ; buffer order
        (should (equal (mapcar #'car sources) '(pins)))
        (should (equal (funcall (cdar sources))
                       (list (list (funcall l 2) 'left 'drgnx-marks-pin 1 nil (1- (funcall l 4)))
                             (list (funcall l 13) 'left 'drgnx-marks-pin 1 nil (1- (funcall l 17))))))
        (let ((spec (drgnx-minimap--spec (selected-window))))
          (should (eql (plist-get spec :pin-kind) (cl-position 'pin drgnx-ruler-kinds)))
          (should (eq (plist-get spec :pin) 'drgnx-marks-pin))
          (should (equal (plist-get spec :pin-names) ["head" "drgnx-sticky-test-fn"])))
        ;; unpinned: the one at point goes; the last one gone takes the marks and the spec's keys
        (goto-char (funcall l 15))
        (drgnx-unpin-region)
        (should (equal (drgnx-sticky-pin-names) '("head")))
        (goto-char (funcall l 2))
        (drgnx-unpin-region)
        (should-not drgnx-sticky--pins)
        (should-not sources)
        (should-not (plist-member (drgnx-minimap--spec (selected-window)) :pin-names))))))

(ert-deftest drgnx-sticky/pin-show-toggles-the-pin-in-the-card ()
  ;; `pin-show' fills the window's card with the pin's lines (at most a third of the window), and again takes it off
  (drgnx-sticky-test--in (drgnx-sticky-test--elisp 40) #'emacs-lisp-mode
    (let ((filled nil) (hidden nil) (w (selected-window)) (drgnx-sticky--pin-shown nil) (drgnx-sticky--cards nil)
          (l (lambda (n) (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))))
      (cl-letf (((symbol-function 'drgnx-ruler-source) #'ignore)
                ((symbol-function 'drgnx-sticky--fill) (lambda (win pos) (push (cons win pos) filled)))
                ((symbol-function 'drgnx-sticky--hide) (lambda (win) (push win hidden))))
        (drgnx-pin-region (funcall l 1) (funcall l 3))
        (goto-char (funcall l 30))
        (drgnx-pin-show)
        (should (equal (car filled) (cons w (list (funcall l 1) (funcall l 2) (funcall l 3)))))
        (should (assq w drgnx-sticky--pin-shown))
        (drgnx-pin-show)
        (should-not drgnx-sticky--pin-shown)
        (should (equal hidden (list w)))
        (goto-char (funcall l 2))
        (drgnx-unpin-region)))))

(ert-deftest drgnx-sticky/turning-the-module-off-takes-the-pins ()
  (let ((b (generate-new-buffer "sticky-pins-off")))
    (unwind-protect
        (progn
          (drgnx-test-with-modules '(editor/sticky)
            (with-current-buffer b
              (insert (drgnx-sticky-test--elisp 10))
              (emacs-lisp-mode)
              (drgnx-pin-region (point-min) (+ 5 (point-min)))
              (should drgnx-sticky--pins)))
          (should-not (buffer-local-value 'drgnx-sticky--pins b))
          (should-not drgnx-sticky--cards))
      (kill-buffer b))))
