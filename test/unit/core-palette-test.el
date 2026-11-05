;;; core-palette-test.el --- batch tests: the command palette -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-palette)

(defvar drgnx-test--palette-ran nil)
(defun drgnx-test--palette-cmd () (interactive) (setq drgnx-test--palette-ran t))

(ert-deftest drgnx-palette/candidates-and-run ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-test--palette-ran nil))
    (drgnx-command-define 'p :title "Do It" :category "Test" :command #'drgnx-test--palette-cmd)
    (drgnx-command-define 'gone :title "Gone" :category "Test" :command 'drgnx-test--missing)
    (should (equal (mapcar #'car (drgnx-palette-candidates)) '("Test: Do It")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Test: Do It")))
      (drgnx-palette))
    (should drgnx-test--palette-ran)))

;; The answer is resolved here, not by the completion UI: `require-match' is nil, so a `#question' that no
;; completion style would offer (orderless filters candidates itself) still reaches the command.
(defun drgnx-test--palette-with-search (answer styles &rest opts)
  "Run the palette with ANSWER typed, under completion STYLES; return (SEARCH-ARGS REQUIRE-MATCH RAN)."
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (asked nil) (require-match 'unset) (drgnx-test--palette-ran nil)
        (completion-styles styles))
    (drgnx-command-define 'p :title "Do It" :category "Test" :command #'drgnx-test--palette-cmd)
    (when (plist-get opts :extra)
      (drgnx-command-define 'p2 :title "Do That" :category "Test" :command #'drgnx-test--palette-cmd))
    (drgnx-command-define 'search-semantic :title "Semantic Search" :category "Search"
                          :command (lambda (&optional q) (interactive (list "prompted")) (push q asked)))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _tbl _pred rm &rest _) (setq require-match rm) answer)))
      (drgnx-palette))
    (list asked require-match drgnx-test--palette-ran)))

(ert-deftest drgnx-palette/hash-runs-semantic-search ()
  (dolist (styles (append '((basic)) (and (locate-library "orderless") '((orderless basic)))))
    (pcase-let ((`(,asked ,rm ,_) (drgnx-test--palette-with-search "#  where do we parse json " styles)))
      (should (equal asked '("where do we parse json")))       ; the text after #, trimmed
      (should-not rm))                                         ; the UI never refuses the input
    ;; a bare # prompts (the command's own prompt)
    (should (equal (car (drgnx-test--palette-with-search "#" styles)) '("prompted")))
    ;; a label runs; empty does nothing; anything else is a clear error
    (should (nth 2 (drgnx-test--palette-with-search "Test: Do It" styles)))
    (should-not (car (drgnx-test--palette-with-search "" styles)))
    (should-not (nth 2 (drgnx-test--palette-with-search "  " styles)))
    (let ((err (should-error (drgnx-test--palette-with-search "nonsense" styles) :type 'user-error)))
      (should (string-match-p "No command: nonsense" (cadr err))))
    ;; a partial label resolves the way completion would (require-match t used to): unique runs it
    (should (nth 2 (drgnx-test--palette-with-search "Test: Do" styles)))
    (should (equal (car (drgnx-test--palette-with-search "Search: Sem" styles)) '("prompted")))
    ;; ambiguous: the names
    (let ((err (should-error (drgnx-test--palette-with-search "Test:" styles :extra t) :type 'user-error)))
      (should (string-match-p "Ambiguous: .*Test: Do It.*Test: Do That" (cadr err))))))

(ert-deftest drgnx-palette/a-label-starting-with-hash-wins ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-test--palette-ran nil) (asked nil))
    (drgnx-command-define 'h :title "tag" :category "#" :command #'drgnx-test--palette-cmd)
    (drgnx-command-define 'search-semantic :title "Semantic Search" :category "Search"
                          :command (lambda (&optional q) (interactive) (push q asked)))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "#: tag")))
      (drgnx-palette))
    (should drgnx-test--palette-ran)
    (should-not asked)))

(ert-deftest drgnx-palette/preferences-opens-it-on-the-preferences ()
  ;; Cmd+, (VS Code's Settings): the palette with "Preferences: " typed, one Preferences command away.
  (let (initial)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _table &optional _pred _req init &rest _) (setq initial init) "")))
      (drgnx-palette-preferences))
    (should (equal initial "Preferences: "))))

;; From the old UI list ("palette prefix legend", "? palette mode erroring on empty input"): gryphn's palette had
;; seven prefix modes and a `?' legend of them, whose Enter on an empty box was a Lisp error.  drgnx's palette
;; has one prefix, `#', and says so in its prompt; anything else it cannot resolve is a plain user error.
(ert-deftest drgnx-palette/the-prompt-names-the-prefix ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        prompt)
    (cl-letf (((symbol-function 'completing-read) (lambda (p &rest _) (setq prompt p) "")))
      (drgnx-palette))
    (should (string-match-p "#" prompt))))

(ert-deftest drgnx-palette/a-question-mark-is-no-command-never-a-lisp-error ()
  (dolist (styles (append '((basic)) (and (locate-library "orderless") '((orderless basic)))))
    (dolist (typed '("?" "? "))
      (let ((err (condition-case e (drgnx-test--palette-with-search typed styles) (error e))))
        (should (eq (car err) 'user-error))
        (should (string-match-p "No command: \\?" (cadr err)))))
    ;; the legend's own empty case: nothing typed, nothing happens, no error
    (should-not (nth 2 (drgnx-test--palette-with-search "" styles)))))

;; The floating palette (core/drgnx-palette-frame.el): Glitnir decides, nothing else does.
(require 'drgnx-palette-frame)
(defvar vertico-count)

(defun drgnx-test--palette-placed (parent-width)
  "The (WIDTH HEIGHT) `drgnx-palette-frame--place' gives a parent PARENT-WIDTH frame pixels wide."
  (let ((vertico-count 10) (drgnx-palette-frame-width 640) sized)
    (cl-letf (((symbol-function 'frame-char-height) (lambda (&rest _) 20))
              ((symbol-function 'frame-pixel-width) (lambda (f) (if (eq f 'parent) parent-width (car sized))))
              ((symbol-function 'frame-pixel-height) (lambda (_) 2000))
              ((symbol-function 'frame-scale-factor) (lambda (_) 2.0))
              ((symbol-function 'set-frame-size) (lambda (_f w h _pixelwise) (setq sized (list w h))))
              ((symbol-function 'set-frame-position) #'ignore))
      (drgnx-palette-frame--place 'child 'parent))
    sized))

(ert-deftest core-palette-float-sizes-are-logical-pixels ()
  ;; a frame of Nidhogg's Wayland shell counts device pixels: 640 logical at scale 2 are 1280 of them
  ;; `dlet': `features' is not special, so a `let' of it would be lexical here and change nothing
  (dlet ((features (cons 'nidhogg-wayland features)))
    (should (equal (drgnx-test--palette-placed 3000) '(1280 240)))
    (should (equal (drgnx-test--palette-placed 1000) '(936 240)))
    (cl-letf (((symbol-function 'frame-scale-factor) (lambda (_) 2.0)))
      (should (= 16 (alist-get 'internal-border-width (drgnx-palette-frame--params 'parent))))))
  ;; elsewhere a frame counts logical pixels already
  (dlet ((features (remq 'nidhogg-wayland features)))
    (should (equal (drgnx-test--palette-placed 3000) '(640 240)))
    (should (= 8 (alist-get 'internal-border-width (drgnx-palette-frame--params 'parent))))))

(ert-deftest core-palette-float-stays-for-a-minibuffer-on-top ()
  ;; a question on top of the open palette ends: the palette's own minibuffer still reads, so its box stays
  (let ((root (frame-root-window)) (drgnx-palette-frame--frame (selected-frame)) hidden)
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (set-window-buffer root (current-buffer))
            (cl-letf (((symbol-function 'frame-visible-p) (lambda (_) t))
                      ((symbol-function 'make-frame-invisible) (lambda (_) (setq hidden t)))
                      ((symbol-function 'active-minibuffer-window) (lambda () (minibuffer-window))))
              (drgnx-palette-frame-hide)
              (should-not hidden)
              (should (eq (window-buffer root) (current-buffer)))
              ;; the palette's own minibuffer ends
              (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () root)))
                (drgnx-palette-frame-hide))
              (should hidden)
              (should (equal (buffer-name (window-buffer root)) drgnx-palette-frame--buffer)))))
      (when-let* ((b (get-buffer drgnx-palette-frame--buffer))) (kill-buffer b)))))


(ert-deftest core-palette-float-off-without-glitnir ()
  (let (modes)
    (cl-letf (((symbol-function 'vertico-buffer-mode) (lambda (arg) (push arg modes))))
      ;; no Glitnir (or no graphical frame): the palette stays in the minibuffer, as before
      (should-not (drgnx-palette-frame-wanted-p))
      (drgnx-palette-frame-buffer 1)
      (should-not modes)
      ;; Glitnir on a graphical frame: `vertico-buffer-mode' on; off is always passed on
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'glitnir-active-p) (lambda () t)))
        (should (drgnx-palette-frame-wanted-p))
        (drgnx-palette-frame-buffer 1))
      (should (equal modes '(1)))
      (drgnx-palette-frame-buffer -1)
      (should (equal modes '(-1 1))))))
