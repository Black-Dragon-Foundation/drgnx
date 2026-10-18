;;; mod-quickhelp-test.el --- batch tests: quick help — a card beside the symbol, a strip in terminals (M12f A8) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-quickhelp" drgnx-dir) nil t)

(defmacro drgnx-quickhelp-test--with (&rest body)
  "BODY with the quick help's state, hooks and commands kept away from the rest of the test process; one window."
  (declare (indent 0))
  `(let ((drgnx-quickhelp--request 0) (drgnx-quickhelp--timer nil) (drgnx-quickhelp--origin nil)
         (drgnx-quickhelp--strip nil) (drgnx-quickhelp--showing nil) (emulation-mode-map-alists emulation-mode-map-alists)
         (drgnx-quickhelp--card-up nil) (drgnx-quickhelp--unmap-timer nil)
         (drgnx-quickhelp--active nil) (drgnx-quickhelp-hover nil)
         (drgnx-quickhelp--hover-timer nil) (drgnx-quickhelp--poll nil) (drgnx-quickhelp--rest nil)
         (pre-command-hook nil) (post-command-hook nil)
         (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
     (save-window-excursion
       (delete-other-windows)
       (unwind-protect (progn ,@body)
         (drgnx-quickhelp-hide)
         (setq drgnx-quickhelp--active nil)
         (drgnx-quickhelp--apply-hover)))))

(defmacro drgnx-quickhelp-test--elisp (text &rest body)
  "BODY in a buffer of Emacs Lisp TEXT shown in the selected window."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (emacs-lisp-mode)
     (set-window-buffer (selected-window) (current-buffer))
     ,@body))

(defun drgnx-quickhelp-test--wait (pred seconds)
  "Run timers until PRED is non-nil or SECONDS pass; PRED's value."
  (let ((deadline (+ (float-time) seconds)) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    v))

(defun drgnx-quickhelp-test--overlaps-p (y h top bottom)
  "Non-nil when the rows Y..Y+H intersect TOP..BOTTOM."
  (and (< y bottom) (> (+ y h) top)))

;;;; Placement (pure)

(ert-deftest drgnx-quickhelp/placement-below-else-above ()
  (let ((win '(0 0 800 600)))
    ;; room below: under the line, at the symbol
    (should (equal (drgnx-quickhelp-placement win 100 120 50 300 200) '(50 . 120)))
    ;; no room below: above the line
    (should (equal (drgnx-quickhelp-placement win 500 520 50 300 200) '(50 . 300)))
    ;; exactly fits below
    (should (equal (drgnx-quickhelp-placement win 380 400 0 100 200) '(0 . 400)))
    ;; neither side has room: the bigger side, still beside the line
    (should (equal (drgnx-quickhelp-placement win 100 120 0 100 550) '(0 . 120)))
    (should (equal (drgnx-quickhelp-placement win 480 500 0 100 550) '(0 . -70)))))

(ert-deftest drgnx-quickhelp/placement-never-covers-the-line ()
  (let ((win '(10 30 810 630)) (checked 0))
    (cl-loop for top from 30 below 630 by 20 do
             (cl-loop for h in '(20 60 140 300 580 620 900) do
                      (cl-loop for x in '(10 400 790) do
                               (let ((p (drgnx-quickhelp-placement win top (+ top 20) x 320 h)))
                                 (cl-incf checked)
                                 (should-not (drgnx-quickhelp-test--overlaps-p (cdr p) h top (+ top 20)))))))
    (should (> checked 500))))

(ert-deftest drgnx-quickhelp/placement-stays-in-the-window ()
  (let ((win '(10 30 810 630)))
    (cl-loop for top from 30 below 630 by 20 do
             (cl-loop for x in '(10 300 700 790 809) do
                      (cl-loop for (w . h) in '((320 . 100) (790 . 200) (200 . 280)) do
                               (let* ((p (drgnx-quickhelp-placement win top (+ top 20) x w h)))
                                 (should (>= (car p) 10))
                                 (should (<= (+ (car p) w) 810))
                                 ;; the card fits on one side here (280 + 20 <= 600 / 2 + 20), so it is in the window
                                 (should (>= (cdr p) 30))
                                 (should (<= (+ (cdr p) h) 630))))))
    ;; a card wider than the window starts at its left edge
    (should (= (car (drgnx-quickhelp-placement win 100 120 500 2000 50)) 10))))

;;;; Collecting docs (eldoc's functions)

(ert-deftest drgnx-quickhelp/collect-gathers-every-backend-and-drops-stale-answers ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n(cdr y)\n"
      (let* ((pending nil) (seen-point nil) (got1 :none) (got2 :none)
             (sync (lambda (cb) (push (point) seen-point) (funcall cb "one" :thing 'car)))
             (legacy (lambda (_cb) "two"))
             (nothing (lambda (_cb) nil))
             (broken (lambda (_cb) (error "A backend that fails")))
             (async (lambda (cb) (push cb pending) t)))
        (setq-local eldoc-documentation-functions (list sync legacy nothing broken async))
        (goto-char (point-max))
        (drgnx-quickhelp-collect 2 (selected-window) (lambda (docs) (setq got1 docs)))
        ;; ran with point at POS, which is given back
        (should (equal seen-point '(2)))
        (should (= (point) (point-max)))
        (should (eq got1 :none))                 ; still waiting on the async one
        ;; a newer request: the older one never answers, even when its backend does
        (drgnx-quickhelp-collect 10 (selected-window) (lambda (docs) (setq got2 docs)))
        (should (= (length pending) 2))
        (funcall (cadr pending) "stale" :thing 'old)
        (should (eq got1 :none))
        (should (eq got2 :none))
        (funcall (car pending) "four")
        (should (equal got2 '(("one" :thing car) ("two") ("four"))))
        ;; a second answer from the same backend changes nothing
        (funcall (car pending) "again")
        (should (equal got2 '(("one" :thing car) ("two") ("four"))))
        ;; the older request's timeout never fires its callback
        (drgnx-quickhelp-test--wait (lambda () nil) 1.2)
        (should (eq got1 :none))))))

(ert-deftest drgnx-quickhelp/collect-never-waits ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (let ((got :none) (t0 (float-time)))
        (setq-local eldoc-documentation-functions (list (lambda (_cb) t)          ; never calls back
                                                        (lambda (cb) (funcall cb "sync"))))
        (drgnx-quickhelp-collect 2 (selected-window) (lambda (docs) (setq got (cons (float-time) docs))))
        (should (< (- (float-time) t0) 0.1))     ; returned at once
        (should (eq got :none))
        (should (drgnx-quickhelp-test--wait (lambda () (consp got)) 3))
        (should (>= (- (car got) t0) 0.9))       ; after a second, from a timer
        (should (equal (cdr got) '(("sync"))))))))

;;;; Showing and hiding

(defun drgnx-quickhelp-test--show (docs)
  "Ask for quick help at point with eldoc answering DOCS at once."
  (setq-local eldoc-documentation-functions (list (lambda (cb) (dolist (d docs) (apply cb d)) t)))
  (call-interactively #'drgnx-quickhelp-show))

(ert-deftest drgnx-quickhelp/hidden-on-typing ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (goto-char 2)
      (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))
      (should (drgnx-quickhelp-shown-p))
      ;; the card's text: the docs, a close mark and the three buttons
      (with-current-buffer (get-buffer drgnx-quickhelp--buffer-name)
        (let ((s (buffer-string)))
          (should (string-search "car: (LIST)" s))
          (should (string-search (drgnx-face-glyph 'close) s))
          (dolist (b '("Open Help" "Go to Definition" "Find References")) (should (string-search b s)))))
      ;; scrolling the card and the card's own buttons keep it
      (let ((this-command 'drgnx-quickhelp--click)) (run-hooks 'pre-command-hook))
      (should (drgnx-quickhelp-shown-p))
      ;; a typed character moves it out of the way
      (let ((this-command 'self-insert-command)) (run-hooks 'pre-command-hook))
      (should-not (drgnx-quickhelp-shown-p))
      ;; C-g too
      (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))
      (should (drgnx-quickhelp-shown-p))
      (let ((this-command 'keyboard-quit)) (run-hooks 'pre-command-hook))
      (should-not (drgnx-quickhelp-shown-p))
      ;; another buffer in the window
      (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))
      (with-temp-buffer
        (set-window-buffer (selected-window) (current-buffer))
        (run-hooks 'post-command-hook))
      (should-not (drgnx-quickhelp-shown-p))
      (set-window-buffer (selected-window) (current-buffer))
      ;; an answer that comes after the card was put away does not bring it back
      (let (late)
        (setq-local eldoc-documentation-functions (list (lambda (cb) (setq late cb) t)))
        (call-interactively #'drgnx-quickhelp-show)
        (let ((this-command 'self-insert-command)) (run-hooks 'pre-command-hook))
        (funcall late "(LIST)" :thing 'car)
        (should-not (drgnx-quickhelp-shown-p))))))

(ert-deftest drgnx-quickhelp/esc-and-q-close-and-a-hover-card-lets-the-key-through ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (goto-char 2)
      (setq-local eldoc-documentation-functions (list (lambda (cb) (funcall cb "(LIST)" :thing 'car))))
      ;; the showing map (Esc and q from the profiles) is on exactly while a card is up
      (should (memq 'drgnx-quickhelp--emulation (progn (drgnx-quickhelp-setup) emulation-mode-map-alists)))
      (should (eq (cdr (car drgnx-quickhelp--emulation)) drgnx-quickhelp-showing-map))
      (should-not drgnx-quickhelp--showing)
      (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () [?q])))
        ;; a card you asked for: q closes it, nothing typed
        (call-interactively #'drgnx-quickhelp-show)
        (should (drgnx-quickhelp-shown-p))
        (should drgnx-quickhelp--showing)
        (let ((this-command 'drgnx-quickhelp-close)) (run-hooks 'pre-command-hook))
        (call-interactively #'drgnx-quickhelp-close)
        (should-not (drgnx-quickhelp-shown-p))
        (should-not drgnx-quickhelp--showing)
        (should (equal (buffer-string) "(car x)\n"))
        ;; a card from hovering: q closes it and types q
        ;; (hover cards are graphical only: its state stands in for one here)
        (setq drgnx-quickhelp--origin (list :window (selected-window) :buffer (current-buffer) :pos 2 :key nil)
              drgnx-quickhelp--showing t)
        (let ((last-command-event ?q)) (call-interactively #'drgnx-quickhelp-close))
        (should-not drgnx-quickhelp--origin)
        (should-not drgnx-quickhelp--showing)
        (should (equal (buffer-string) "(qcar x)\n"))))))

(ert-deftest drgnx-quickhelp/again-while-shown-opens-help ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (goto-char 2)
      (let ((described nil))
        (cl-letf (((symbol-function 'describe-symbol) (lambda (s &rest _) (push s described))))
          (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))
          (should (drgnx-quickhelp-shown-p))
          (let ((this-command 'drgnx-quickhelp-show)) (run-hooks 'pre-command-hook))
          (call-interactively #'drgnx-quickhelp-show)
          (should (equal described '(car)))
          (should-not (drgnx-quickhelp-shown-p)))))))

(ert-deftest drgnx-quickhelp/terminal-gets-a-strip-and-gives-it-back ()
  (drgnx-quickhelp-test--with
    (should-not (display-graphic-p))            ; batch: a terminal frame
    (drgnx-quickhelp-test--elisp (mapconcat (lambda (i) (format "(car x%d)" i)) (number-sequence 1 60) "\n")
      (let* ((editor (selected-window))
             (other (split-window editor nil 'right))      ; another group beside it
             (before (mapcar #'window-pixel-edges (list editor other))))
        (goto-char (point-min))
        (forward-line 15)
        (forward-char 1)
        (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))
        (let ((strip drgnx-quickhelp--strip))
          (should (window-live-p strip))
          (should (eq (window-parameter strip 'drgnx-role) 'quickhelp))
          (should (eq (window-parameter strip 'mode-line-format) 'none))
          (should (eq (window-parameter strip 'header-line-format) 'none))
          (should (eq (window-parameter strip 'tab-line-format) 'none))
          (should (= (window-total-height strip) drgnx-quickhelp-strip-lines))
          ;; under the editor, as wide as it; the other group untouched
          (should (= (nth 1 (window-edges strip)) (nth 3 (window-edges editor))))
          (should (= (nth 0 (window-edges strip)) (nth 0 (window-edges editor))))
          (should (= (nth 2 (window-edges strip)) (nth 2 (window-edges editor))))
          (should (equal (window-pixel-edges other) (nth 1 before)))
          (should (eq (selected-window) editor))
          (should (string-search "car: (LIST)" (with-current-buffer (window-buffer strip) (buffer-string))))
          ;; typing: the strip goes and the editor has its rows back
          (let ((this-command 'self-insert-command)) (run-hooks 'pre-command-hook))
          (should-not (window-live-p strip))
          (should (equal (mapcar #'window-pixel-edges (list editor other)) before)))))))

(ert-deftest drgnx-quickhelp/no-strip-in-a-window-too-small ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (let* ((editor (selected-window)) (below (split-window editor 6 'below))   ; the editor: 6 lines
             (before (mapcar #'window-pixel-edges (list editor below))))
        (goto-char 2)
        (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))   ; no error
        (should-not (window-live-p drgnx-quickhelp--strip))
        (should (equal (mapcar #'window-pixel-edges (list editor below)) before))))))

;;;; Commands and keys

(ert-deftest drgnx-quickhelp/commands-are-registered ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-setup)
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'quick-help)) #'drgnx-quickhelp-show))
    (should (equal (drgnx-cmd-title (drgnx-commands-get 'quick-help)) "Show Quick Help"))
    (should (equal (drgnx-cmd-category (drgnx-commands-get 'quick-help)) "Help"))
    (should (equal (drgnx-cmd-title (drgnx-commands-get 'quick-help-toggle-hover)) "Toggle Quick Help on Hover"))
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'quick-help-close)) #'drgnx-quickhelp-close))
    (let ((drgnx-quickhelp-hover t))
      (call-interactively (drgnx-cmd-command (drgnx-commands-get 'quick-help-toggle-hover)))
      (should-not drgnx-quickhelp-hover)
      (should-not (timerp drgnx-quickhelp--hover-timer))
      (call-interactively (drgnx-cmd-command (drgnx-commands-get 'quick-help-toggle-hover)))
      (should drgnx-quickhelp-hover)
      (should (timerp drgnx-quickhelp--hover-timer))
      (setq drgnx-quickhelp--active nil)
      (drgnx-quickhelp--apply-hover)
      (should-not (timerp drgnx-quickhelp--hover-timer)))))

(ert-deftest drgnx-quickhelp/keys-in-every-profile ()
  (dolist (p '(("vscode" . "(quick-help \"C-k C-i\")")
               ("emacs" . "(quick-help :none \"C-h . shows local help (stock); the palette\")")
               ("vim" . "(quick-help \"SPC k\")")))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" (car p)) drgnx-dir))
      (should (search-forward (cdr p) nil t))
      (goto-char (point-min))
      (should (search-forward "(quick-help-toggle-hover :none \"the palette\")" nil t))
      (goto-char (point-min))
      (should (search-forward "(quick-help-close \"<escape>\" \"q\" :map drgnx-quickhelp-showing-map)" nil t)))))

(ert-deftest drgnx-quickhelp/faces-inherit-the-theme ()
  (should (eq (face-attribute 'drgnx-quickhelp :inherit) 'tooltip))
  (should (eq (face-attribute 'drgnx-quickhelp-title :inherit) 'bold)))

;;; mod-quickhelp-test.el ends here
