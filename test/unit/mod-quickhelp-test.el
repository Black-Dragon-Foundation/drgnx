;;; mod-quickhelp-test.el --- batch tests: quick help — a card beside the symbol, a strip in terminals (M12f A8) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-quickhelp" drgnx-dir) nil t)

(defmacro drgnx-quickhelp-test--with (&rest body)
  "BODY with the quick help's state, hooks and commands kept away from the rest of the test process; one window."
  (declare (indent 0))
  `(drgnx-test-with-state
     (let ((drgnx-quickhelp--request 0) (drgnx-quickhelp--origin nil)
           (drgnx-quickhelp--strip nil) (drgnx-quickhelp--showing nil) (emulation-mode-map-alists emulation-mode-map-alists)
           (drgnx-modal-front-alists drgnx-modal-front-alists)
           (drgnx-quickhelp--card-up nil)
           (drgnx-quickhelp--active nil) (drgnx-quickhelp-hover nil)
           (drgnx-quickhelp--rest nil)
           (pre-command-hook nil) (post-command-hook nil)
           (drgnx-modules--runs (list (list 'ui/face 'ui/face)))   ; ui/face is on: its timers start
           (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
       (save-window-excursion
         (delete-other-windows)
         (unwind-protect (progn ,@body)
           (drgnx-quickhelp-hide)
           (setq drgnx-quickhelp--active nil)
           (drgnx-quickhelp--apply-hover)
           (mapc #'drgnx-timer-cancel '(quickhelp-timeout quickhelp-unmap quickhelp-look quickhelp-hover quickhelp-away)))))))

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

(defun drgnx-quickhelp-test--clear-p (y h bands)
  "Non-nil when the rows Y..Y+H cover no band of BANDS."
  (not (seq-some (lambda (b) (drgnx-quickhelp-test--overlaps-p y h (car b) (cdr b))) bands)))

(ert-deftest drgnx-quickhelp/placement-below-else-above ()
  (let ((win '(0 0 800 600)))
    ;; room below: under the line, at the symbol
    (should (equal (drgnx-quickhelp-placement win '((100 . 120)) 50 300 200) '(50 . 120)))
    ;; no room below: above the line
    (should (equal (drgnx-quickhelp-placement win '((500 . 520)) 50 300 200) '(50 . 300)))
    ;; exactly fits below
    (should (equal (drgnx-quickhelp-placement win '((380 . 400)) 0 100 200) '(0 . 400)))
    ;; neither side has room: nowhere (the caller shortens the card, or shows none) — never outside the window
    (should-not (drgnx-quickhelp-placement win '((100 . 120)) 0 100 550))
    (should-not (drgnx-quickhelp-placement win '((480 . 500)) 0 100 550))
    ;; the room the caller shortens it to fits
    (should (drgnx-quickhelp-placement win '((100 . 120)) 0 100 (drgnx-quickhelp--room win '((100 . 120)))))))

(ert-deftest drgnx-quickhelp/placement-never-covers-the-line ()
  ;; property: over a grid of symbol lines (one to three screen rows), point's line (none, the symbol's, the one
  ;; below, a row further down, above), card heights and positions, no row of the card is on either line and the card
  ;; is inside the window — or there is no place, and then no free run of the window is as tall as the card
  (let ((win '(10 30 810 630)) (checked 0) (placed 0))
    (cl-loop for top from 30 below 630 by 20 do
             (cl-loop for rows in '(1 3) do
                      (let ((sym (cons top (min 630 (+ top (* 20 rows))))))
                        (cl-loop for point in (list nil sym (cons (cdr sym) (+ (cdr sym) 20))
                                                    (cons (+ (cdr sym) 60) (+ (cdr sym) 80)) (cons (- top 40) (- top 20)))
                                 do (cl-loop for h in '(20 60 140 300 580 620 900) do
                                             (cl-loop for x in '(10 400 790) do
                                                      (let* ((bands (if point (list sym point) (list sym)))
                                                             (p (drgnx-quickhelp-placement win bands x 320 h)))
                                                        (cl-incf checked)
                                                        (if (not p)
                                                            (should (> h (drgnx-quickhelp--room win bands)))
                                                          (cl-incf placed)
                                                          (should (drgnx-quickhelp-test--clear-p (cdr p) h bands))
                                                          (should (>= (cdr p) 30))
                                                          (should (<= (+ (cdr p) h) 630))))))))))
    (should (> checked 5000))
    (should (> placed 2000))))

(ert-deftest drgnx-quickhelp/placement-wrapped-line-and-point-below ()
  (let ((win '(0 0 800 600)))
    ;; the symbol on the middle row of a line wrapped over three rows: the card is under the whole line
    (should (equal (drgnx-quickhelp-placement win '((100 . 160)) 50 300 200) '(50 . 160)))
    ;; … above it when there is no room below
    (should (equal (drgnx-quickhelp-placement win '((400 . 460)) 50 300 200) '(50 . 200)))
    ;; hovering a symbol with point on the line below: under that line too, not between them
    (should (equal (drgnx-quickhelp-placement win '((100 . 120) (120 . 140)) 50 300 200) '(50 . 140)))
    ;; point on the line below and no room under it: above the symbol's line
    (should (equal (drgnx-quickhelp-placement win '((400 . 420) (420 . 440)) 50 300 200) '(50 . 200)))
    ;; the room the caller shortens the card to: the tallest gap between the bands
    (should (= (drgnx-quickhelp--room win '((100 . 120) (420 . 440))) 300))
    (should (= (drgnx-quickhelp--room win '((0 . 580))) 20))))

(ert-deftest drgnx-quickhelp/placement-stays-in-the-window ()
  (let ((win '(10 30 810 630)))
    (cl-loop for top from 30 below 630 by 20 do
             (cl-loop for x in '(10 300 700 790 809) do
                      (cl-loop for (w . h) in '((320 . 100) (790 . 200) (200 . 280)) do
                               (let* ((p (drgnx-quickhelp-placement win (list (cons top (+ top 20))) x w h)))
                                 (should (>= (car p) 10))
                                 (should (<= (+ (car p) w) 810))
                                 ;; the card fits on one side here (280 + 20 <= 600 / 2 + 20), so it is in the window
                                 (should (>= (cdr p) 30))
                                 (should (<= (+ (cdr p) h) 630))))))
    ;; a card wider than the window starts at its left edge
    (should (= (car (drgnx-quickhelp-placement win '((100 . 120)) 500 2000 50)) 10))))

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
      ;; first of the maps in front of the modal engine's (evil's normal state would take Esc and q)
      (should (eq (car drgnx-modal-front-alists) 'drgnx-quickhelp--emulation))
      (should (< (cl-position 'drgnx-quickhelp--emulation emulation-mode-map-alists)
                 (or (cl-position 'drgnx-ai-ghost--emulation emulation-mode-map-alists) 0)))
      (should (eq (cdr (car drgnx-quickhelp--emulation)) drgnx-quickhelp-showing-map))
      (should-not drgnx-quickhelp--showing)
      (let ((keys nil))
        (cl-letf (((symbol-function 'this-command-keys-vector) (lambda () keys)))
          ;; a card you asked for, in a buffer you type into: q closes it and goes back to be read again (it moves out
          ;; of the way while you type: `query' keeps its q)
          (setq keys [?q])
          (call-interactively #'drgnx-quickhelp-show)
          (should (drgnx-quickhelp-shown-p))
          (should drgnx-quickhelp--showing)
          (let ((unread-command-events nil))
            (let ((this-command 'drgnx-quickhelp-close)) (run-hooks 'pre-command-hook))
            (call-interactively #'drgnx-quickhelp-close)
            (should-not (drgnx-quickhelp-shown-p))
            (should-not drgnx-quickhelp--showing)
            (should (equal unread-command-events '((no-record . ?q)))))
          ;; Esc there closes it, nothing passed on
          (setq keys [escape])
          (call-interactively #'drgnx-quickhelp-show)
          (let ((unread-command-events nil))
            (call-interactively #'drgnx-quickhelp-close)
            (should-not (drgnx-quickhelp-shown-p))
            (should-not unread-command-events))
          ;; in a read-only buffer (help, a listing) q only closes it, nothing typed
          (setq keys [?q])
          (call-interactively #'drgnx-quickhelp-show)
          (setq buffer-read-only t)
          (let ((unread-command-events nil))
            (call-interactively #'drgnx-quickhelp-close)
            (should-not (drgnx-quickhelp-shown-p))
            (should (equal (buffer-string) "(car x)\n"))
            (should-not unread-command-events))
          (setq buffer-read-only nil)
          ;; a card from hovering: q closes it and goes back to be read again (no record), so it types q
          ;; (hover cards are graphical only: its state stands in for one here)
          (setq drgnx-quickhelp--origin (list :window (selected-window) :buffer (current-buffer) :pos 2 :key nil)
                drgnx-quickhelp--showing t)
          (let ((unread-command-events nil))
            (call-interactively #'drgnx-quickhelp-close)
            (should-not drgnx-quickhelp--origin)
            (should-not drgnx-quickhelp--showing)
            (should (equal unread-command-events '((no-record . ?q))))
            ;; read again with the card gone, the key is the buffer's own
            (should (eq (key-binding (vector (cdar unread-command-events))) #'self-insert-command)))
          ;; Vim's normal state in a buffer you can edit: q is not typing there (it would record a macro), so it
          ;; only closes the card
          (setq keys [?q])
          (call-interactively #'drgnx-quickhelp-show)
          (setq-local drgnx-modal-state 'normal)
          (let ((unread-command-events nil))
            (call-interactively #'drgnx-quickhelp-close)
            (should-not (drgnx-quickhelp-shown-p))
            (should-not unread-command-events))
          (setq-local drgnx-modal-state 'insert)
          (call-interactively #'drgnx-quickhelp-show)
          (let ((unread-command-events nil))
            (call-interactively #'drgnx-quickhelp-close)
            (should (equal unread-command-events '((no-record . ?q))))))))))

(ert-deftest drgnx-quickhelp/again-replaces-a-hover-card-with-the-one-at-point ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n(cdr y)\n"
      (goto-char 10)                            ; on `cdr'
      (let ((described nil) (asked nil))
        (setq-local eldoc-documentation-functions
                    (list (lambda (cb) (push (point) asked) (funcall cb "(LIST)" :thing (symbol-at-point)))))
        (cl-letf (((symbol-function 'describe-symbol) (lambda (s &rest _) (push s described))))
          ;; a hover card on `car' (its state stands in for one: hover cards are graphical only)
          (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))
          (setq drgnx-quickhelp--origin (plist-put (plist-put drgnx-quickhelp--origin :key nil) :pos 2))
          (setq-local eldoc-documentation-functions
                      (list (lambda (cb) (push (point) asked) (funcall cb "(LIST)" :thing (symbol-at-point)))))
          (call-interactively #'drgnx-quickhelp-show)
          (should-not described)                ; not Open Help for the hovered symbol
          (should (equal asked '(10)))          ; quick help at point instead
          (should (= (point) 10))               ; point never went to the mouse
          (should (eq (plist-get drgnx-quickhelp--origin :key) t))
          ;; a key card, point moved since: a new card, not Open Help
          (goto-char 11)
          (call-interactively #'drgnx-quickhelp-show)
          (should-not described)
          (should (equal asked '(11 10))))))))

(ert-deftest drgnx-quickhelp/a-big-value-never-blocks ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "drgnx-quickhelp-test--big\n"
      (defvar drgnx-quickhelp-test--big nil "A variable with a big value.")
      (let ((drgnx-quickhelp-test--big (make-list 2000000 '(a (b (c (d)))))) (got nil) (t0 (float-time)))
        (setq-local eldoc-documentation-functions (list #'elisp-eldoc-var-docstring))
        (drgnx-quickhelp-collect 3 (selected-window) (lambda (docs) (setq got docs)))
        (should (< (- (float-time) t0) 0.4))     ; printed short: 1.5 s whole
        (should (string-search "A variable with a big value." (caar got)))
        (when (fboundp 'elisp-eldoc-var-docstring-with-value)   ; the value, cut
          (should (string-search "..." (caar got))))))))

(defmacro drgnx-quickhelp-test--pointer (&rest body)
  "BODY with a stubbed pointer (the variable `pointer', a `mouse-pixel-position' value) over symbol (W . 2),
idle for a while, a focused frame, and `drgnx-quickhelp--request' recording its calls in `requests'."
  (declare (indent 0))
  `(let* ((pointer (cons (selected-frame) (cons 100 100))) (requests nil) (reads 0) (symbol (cons (selected-window) 2))
          (drgnx-quickhelp-hover t) (drgnx-quickhelp-delay 0) (drgnx-quickhelp--still nil))
     (cl-letf (((symbol-function 'mouse-pixel-position) (lambda () (cl-incf reads) pointer))
               ((symbol-function 'drgnx-quickhelp--mouse-symbol) (lambda () symbol))
               ((symbol-function 'drgnx-quickhelp--focused-p) (lambda () t))
               ((symbol-function 'current-idle-time) (lambda () (seconds-to-time 5)))
               ((symbol-function 'drgnx-quickhelp--request) (lambda (&rest args) (push args requests))))
       ,@body
       (drgnx-timer-cancel 'quickhelp-look))))

(ert-deftest drgnx-quickhelp/hover-waits-for-the-pointer-to-move-after-typing ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (drgnx-quickhelp-test--pointer
        (setq drgnx-quickhelp--active t)
        (drgnx-quickhelp--apply-hover)
        (should (memq #'drgnx-quickhelp--note-pointer (default-value 'pre-command-hook)))
        ;; the pointer came to rest on a symbol: its card is asked for
        (drgnx-quickhelp--hover-look)
        (should (= (length requests) 1))
        ;; you type (the hook alone: a flag, no system call per keystroke), then pause: the pointer has not
        ;; moved, so no card
        (let ((before reads)) (run-hooks 'pre-command-hook) (should (= reads before)))
        (should (eq drgnx-quickhelp--still t))
        (dotimes (_ 5) (drgnx-quickhelp--hover-look))     ; 0.2 s apart in life
        (should (= (length requests) 1))
        ;; the pointer moves (still on the symbol): hover is armed again
        (setq pointer (cons (selected-frame) (cons 104 100)))
        (drgnx-quickhelp--hover-look)
        (should (= (length requests) 2))
        ;; no graphical frame has the focus: no look, nothing re-armed
        (cl-letf (((symbol-function 'drgnx-quickhelp--focused-p) (lambda () nil)))
          (drgnx-timer-cancel 'quickhelp-look)
          (setq pointer (cons (selected-frame) (cons 120 100)) drgnx-quickhelp--rest nil)
          (drgnx-quickhelp--hover-look)
          (should (= (length requests) 2))
          (should-not (drgnx-timer-active-p 'quickhelp-look)))))))

(ert-deftest drgnx-quickhelp/a-quick-move-to-the-next-symbol-gets-its-card ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n(cdr y)\n"
      (drgnx-quickhelp-test--pointer
        (let ((drgnx-quickhelp-delay 0.05))
          ;; a hover card is up for `car' (its state stands in for one); the pointer moves on to `cdr'
          (setq drgnx-quickhelp--origin (list :window (selected-window) :buffer (current-buffer) :pos 2 :key nil)
                symbol (cons (selected-window) 10))
          (drgnx-quickhelp--hover-look)          ; the card for `car' goes, `cdr' starts resting
          (should-not drgnx-quickhelp--origin)
          (should-not requests)
          (sleep-for 0.08)
          (drgnx-quickhelp--hover-look)          ; rested: its card, the pointer did not have to move again
          (should (equal requests (list (list (selected-window) 10 nil)))))))))

(ert-deftest drgnx-quickhelp/a-card-goes-when-its-window-scrolls-hover-or-not ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp (mapconcat (lambda (i) (format "(car x%d)" i)) (number-sequence 1 60) "\n")
      (cl-letf (((symbol-function 'current-idle-time) (lambda () (seconds-to-time 5))))
        (let ((drgnx-quickhelp-hover nil))
          ;; a key card placed against the window as it was (its state stands in: cards are graphical only)
          (setq drgnx-quickhelp--origin (list :window (selected-window) :buffer (current-buffer) :pos 2 :key t
                                              :start (window-start) :edges (window-pixel-edges))
                drgnx-quickhelp--card-up t)
          (drgnx-quickhelp--watch-card)
          (should (drgnx-timer-active-p 'quickhelp-look))     ; looks come though hover is off
          (drgnx-timer-cancel 'quickhelp-look)
          (drgnx-quickhelp--hover-look)
          (should drgnx-quickhelp--origin)            ; nothing moved: it stays, and the looks go on
          (should (drgnx-timer-active-p 'quickhelp-look))
          (drgnx-timer-cancel 'quickhelp-look)
          (set-window-start (selected-window) 30)
          (drgnx-quickhelp--hover-look)
          (should-not drgnx-quickhelp--origin)
          (should-not drgnx-quickhelp--card-up)
          (should-not (drgnx-timer-active-p 'quickhelp-look)))))))     ; no card, no hover: the looks stop

;;;; The store tells quick help its window moved

(defun drgnx-quickhelp-test--card-over (window)
  "Stand in for a card placed against WINDOW (cards are graphical only), its edges from the store."
  (setq drgnx-quickhelp--origin (list :window window :buffer (window-buffer window) :pos 2 :key t
                                      :selected (selected-window) :start (window-start window)
                                      :edges (drgnx-state-edges window))
        drgnx-quickhelp--card-up t))

(ert-deftest drgnx-quickhelp/a-resize-puts-the-card-away ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (let* ((w1 (selected-window)) (w2 (split-window w1 nil 'right)) (w3 (split-window w2 nil 'below)))
        (drgnx-state-sync)
        (drgnx-quickhelp--watch-windows)
        (drgnx-quickhelp-test--card-over w1)
        ;; w2 and w3 trade rows, w1 is untouched: the card stays, and nothing is armed
        (window-resize w2 -2)
        (drgnx-state-sync)
        (should drgnx-quickhelp--origin)
        (should-not (drgnx-timer-active-p 'quickhelp-away))
        ;; its own window changes size: the subscriber only arms the timer at 0 s, the card is still there
        (window-resize w1 -3 t)
        (drgnx-state-sync)
        (should (drgnx-timer-active-p 'quickhelp-away))
        (should drgnx-quickhelp--card-up)
        (should drgnx-quickhelp--origin)
        (should (drgnx-quickhelp-test--wait (lambda () (null drgnx-quickhelp--origin)) 2))
        (should-not drgnx-quickhelp--card-up)
        (ignore w3)))))

(ert-deftest drgnx-quickhelp/a-window-change-puts-the-card-away ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp "(car x)\n"
      (let* ((w1 (selected-window)) (w2 (split-window w1 nil 'right)))
        (drgnx-state-sync)
        (drgnx-quickhelp--watch-windows)
        (drgnx-quickhelp-test--card-over w1)
        ;; a window made beside the card's, w1 not resized: windows-changed
        (split-window w2 nil 'below)
        (drgnx-state-sync)
        (should (drgnx-timer-active-p 'quickhelp-away))
        (should (drgnx-quickhelp-test--wait (lambda () (null drgnx-quickhelp--origin)) 2))
        ;; the selection moving to another window of the frame, with no command run
        (drgnx-timer-cancel 'quickhelp-away)
        (drgnx-quickhelp-test--card-over w1)
        (select-window w2)
        (drgnx-state-sync)
        (should (drgnx-quickhelp-test--wait (lambda () (null drgnx-quickhelp--origin)) 2))))))

(ert-deftest drgnx-quickhelp/scrolling-is-still-polled ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp (mapconcat (lambda (i) (format "(car x%d)" i)) (number-sequence 1 60) "\n")
      (cl-letf (((symbol-function 'current-idle-time) (lambda () (seconds-to-time 5))))
        (let ((drgnx-quickhelp-hover nil) (w (selected-window)))
          (drgnx-state-sync)
          (drgnx-quickhelp-test--card-over w)
          ;; edges are the store's business: a look that finds other edges in the origin does not mind
          (setq drgnx-quickhelp--origin (plist-put drgnx-quickhelp--origin :edges '(1 2 3 4)))
          (should-not (drgnx-quickhelp--card-moved-p drgnx-quickhelp--origin))
          (drgnx-quickhelp--watch-card)
          (drgnx-timer-cancel 'quickhelp-look)
          (drgnx-quickhelp--hover-look)
          (should drgnx-quickhelp--origin)
          (drgnx-timer-cancel 'quickhelp-look)
          ;; scrolling is not window state: the look still sees it
          (set-window-start w 30)
          (drgnx-quickhelp--hover-look)
          (should-not drgnx-quickhelp--origin)
          (should-not drgnx-quickhelp--card-up))))))

(ert-deftest drgnx-quickhelp/the-strip-is-not-an-editor ()
  (drgnx-quickhelp-test--with
    (drgnx-state-define-role 'quickhelp)        ; what the module's setup does
    (drgnx-quickhelp-test--elisp (mapconcat (lambda (i) (format "(car x%d)" i)) (number-sequence 1 60) "\n")
      (let ((editor (selected-window)))
        (drgnx-state-sync)
        (drgnx-quickhelp--watch-windows)
        (goto-char (point-min))
        (forward-char 1)
        (drgnx-quickhelp-test--show '(("(LIST)" :thing car)))
        (let ((strip drgnx-quickhelp--strip))
          (should (window-live-p strip))
          (drgnx-state-sync)
          (should (eq (drgnx-state-window-role strip) 'quickhelp))
          (should (equal (drgnx-state-windows (selected-frame) 'editor) (list editor)))
          (should (eq (drgnx-state-editor-window) editor))
          ;; opening it was a window change, and it did not put itself away
          (should-not (drgnx-timer-active-p 'quickhelp-away))
          (should (window-live-p strip))
          (should (drgnx-quickhelp-shown-p)))))))

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

(ert-deftest drgnx-quickhelp/the-strip-shows-it-is-waiting ()
  (drgnx-quickhelp-test--with
    (drgnx-quickhelp-test--elisp (mapconcat (lambda (i) (format "(car x%d)" i)) (number-sequence 1 30) "\n")
      (goto-char 2)
      (let (late)
        (setq-local eldoc-documentation-functions (list (lambda (cb) (setq late cb) t)))
        (call-interactively #'drgnx-quickhelp-show)
        (let ((text (lambda () (with-current-buffer (window-buffer drgnx-quickhelp--strip) (buffer-string)))))
          (should (string-search "…" (funcall text)))
          (should-not (string-search "No documentation" (funcall text)))
          (funcall late "(LIST)" :thing 'car)
          (should (string-search "car: (LIST)" (funcall text))))))))

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
      (should-not (drgnx-timer-active-p 'quickhelp-hover))
      (call-interactively (drgnx-cmd-command (drgnx-commands-get 'quick-help-toggle-hover)))
      (should drgnx-quickhelp-hover)
      (should (drgnx-timer-active-p 'quickhelp-hover))
      (setq drgnx-quickhelp--active nil)
      (drgnx-quickhelp--apply-hover)
      (should-not (drgnx-timer-active-p 'quickhelp-hover)))))

(ert-deftest drgnx-quickhelp/its-timers-belong-to-the-face-module ()
  ;; one hover timer however often it is applied; the look and the hover end with the module's run; no run, no timer
  (drgnx-quickhelp-test--with
    (setq drgnx-quickhelp--active t drgnx-quickhelp-hover t)
    (drgnx-quickhelp--apply-hover)
    (drgnx-quickhelp--apply-hover)
    (should (equal (seq-filter (lambda (e) (eq (car e) 'quickhelp-hover)) (drgnx-timer-pending))
                   '((quickhelp-hover ui/face start))))
    (drgnx-quickhelp--watch-card)
    (should (drgnx-timer-active-p 'quickhelp-look))
    (should (= 2 (drgnx-timer-cancel-owner 'ui/face)))
    (let ((drgnx-modules--runs nil))
      (drgnx-quickhelp--apply-hover)
      (should-not (drgnx-timer-active-p 'quickhelp-hover)))))

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
