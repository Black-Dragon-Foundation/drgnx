;;; term-gui-test.el --- GUI rows: drgnx's terminal in a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; A real hub (a test-hooks build from DRGNX_RATATOSKR_BIN, `drgnx-rows-demo-with') starts the terminal worker beside
;; it; the shell is /bin/sh.  The rows measure what a graphical frame shows: wide cells (CJK, emoji, a ZWJ emoji, a
;; combining mark) keep the columns after them in place, and the cursor's shape follows what the program asks (DECSCUSR).
;; Runnable from a checkout on any GUI build with the hub and the worker built.

(require 'ert)
(require 'cl-lib)
(require 'seq)

(defconst drgnx-term-gui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))

(dolist (d '("core" "wb" "harness" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-term-gui--repo)))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-term-gui--repo) nil t)
(require 'drgnx-terminal)
(require 'drgnx-term)

(defmacro drgnx-term-gui--with (&rest body)
  "BODY with a real hub, this Emacs connected, $SHELL /bin/sh with the prompt \"$ \", one window; terminals gone after."
  (declare (indent 0))
  `(drgnx-rows-demo-with
     (let ((process-environment (append (list "SHELL=/bin/sh" "PS1=$ " "ENV" "BASH_ENV" "HISTFILE=/dev/null"
                                              "LANG=C.UTF-8")
                                        process-environment))
           (drgnx-term--buffers (make-hash-table :test #'equal))
           (display-buffer-overriding-action '(display-buffer-same-window)))
       (delete-other-windows)
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (eq (buffer-local-value 'major-mode b) 'drgnx-term-mode)
             (let ((kill-buffer-query-functions nil)) (kill-buffer b))))))))

(defun drgnx-term-gui--lines (buffer)
  (with-current-buffer buffer
    (when drgnx-view (drgnx-view-draw-now drgnx-view))
    (mapcar #'string-trim-right (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n"))))

(defun drgnx-term-gui--start ()
  "A terminal running the shell in the selected window, its prompt shown."
  (let ((b (drgnx-term-start temporary-file-directory)))
    (drgnx-test-wait (lambda () (seq-some (lambda (l) (string-prefix-p "$" l)) (drgnx-term-gui--lines b)))
                     :secs 30 :what "the first prompt")
    b))

(defun drgnx-term-gui--octal (s)
  "S as printf's octal escapes of its UTF-8 bytes, so the shell is typed ASCII only."
  (mapconcat (lambda (b) (format "\\%03o" b)) (encode-coding-string s 'utf-8) ""))

(defun drgnx-term-gui--run (buffer command)
  (with-current-buffer buffer
    (drgnx-term-send-string command)
    (drgnx-term-send-key "return")))

(defun drgnx-term-gui--bar-x (buffer prefix)
  "The x in px, from the text area's left edge, of the `|' on BUFFER's row that starts with PREFIX, or nil.  (A wide
character's row holds a placeholder after it, the stop at its second cell: the row is found by its first letter.)"
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (concat "^" (regexp-quote prefix) "[^\n]*?\\(|\\)") nil t)
        (redisplay t)
        (car (posn-x-y (posn-at-point (match-beginning 1) (get-buffer-window buffer))))))))

(ert-deftest drgnx-term-gui/wide-cells-align ()
  "Rows of a CJK pair (4 cells), a letter with a combining mark (1), a leading emoji (2), an emoji after two letters
\(2) and a joined emoji (👩‍💻, one cluster of 2 cells: grapheme width \"unicode\", mode 2027 on), each followed by
`|': the bar is drawn at its cell, whatever width the font gives the characters before it, and no emoji becomes an
ellipsis (a glyph wider than its two cells is drawn smaller)."
  (skip-unless (display-graphic-p))
  (drgnx-term-gui--with
    (let* ((b (drgnx-term-gui--start)) (cw (frame-char-width))
           (rows `(("A" ,(string #x6f22 #x5b57) 5) ("C" ,(string ?e #x301) 2) ("B" ,(string #x1f600) 3)
                   ("D" ,(concat "ab" (string #x1f600)) 5) ("E" ,(string #x1f469 #x200d #x1f4bb) 3))))
      (drgnx-term-gui--run b (concat "printf '"
                                     (mapconcat (lambda (r) (concat (car r) (drgnx-term-gui--octal (cadr r)) "|\\n")) rows "")
                                     "'"))
      (drgnx-test-wait (lambda () (cl-every (lambda (r) (drgnx-term-gui--bar-x b (car r))) rows))
                       :secs 30 :what "the five rows")
      (should-not (seq-some (lambda (l) (string-search "…" l)) (drgnx-term-gui--lines b)))
      (dolist (r rows)
        (let ((x (drgnx-term-gui--bar-x b (car r))) (want (* (nth 2 r) cw)))
          (message "drgnx-term-gui: %s bar at %s px, its cell at %s px" (car r) x want)
          (should (<= (abs (- x want)) 1)))))))

(ert-deftest drgnx-term-gui/cursor-shape ()
  "DECSCUSR sets the cursor's shape (a bar, an underline, a block); the cursor stands on the prompt's cell after
its blank, drawn past the row's text by the padding."
  (skip-unless (display-graphic-p))
  (drgnx-term-gui--with
    (let ((b (drgnx-term-gui--start)))
      (dolist (c '(("6" . (bar . 2)) ("4" . (hbar . 2)) ("2" . box)))
        (drgnx-term-gui--run b (format "printf '\\033[%s q'" (car c)))
        (drgnx-test-wait (lambda () (drgnx-term-gui--lines b) (equal (buffer-local-value 'cursor-type b) (cdr c)))
                         :secs 30 :what (format "cursor %S" (cdr c))))
      (with-current-buffer b
        (drgnx-test-wait (lambda ()
                           (drgnx-term-gui--lines b)
                           (and (equal (buffer-substring-no-properties (line-beginning-position) (point)) "$")
                                drgnx-term--pad-overlay
                                (equal (overlay-get drgnx-term--pad-overlay 'after-string) "  ")))
                         :secs 30 :what "the cursor past the prompt's blank")
        (let ((s (overlay-get drgnx-term--pad-overlay 'after-string)))
          (should (get-text-property 1 'cursor s)))))))

;;;; Images and reattach

(require 'drgnx-uitest)
(defvar drgnx-session-quit-keep)

(defun drgnx-term-gui--sixel (cw ch)
  "A printf command drawing a sixel 2 cells wide (2 × CW px) and 2 cells tall (2 × CH px, in 6-px bands): red down
to the last whole band of its first cell row, blue below."
  (let* ((red (/ ch 6)) (bands (/ (+ (* 2 ch) 5) 6)) (w (* 2 cw)) (band (format "!%d~" w)))
    (concat "printf '\\033[H\\033[2J\\033P0;1;0q\"1;1;" (number-to-string w) ";" (number-to-string (* 6 bands))
            "#1;2;100;0;0#2;2;0;0;100"
            (mapconcat (lambda (i) (concat (if (< i red) "#1" "#2") band)) (number-sequence 0 (1- bands)) "-")
            "\\033\\\\after\\n'")))

(defun drgnx-term-gui--image-pos (buffer)
  "The first position of BUFFER whose cells display an image slice, or nil."
  (with-current-buffer buffer
    (when drgnx-view (drgnx-view-draw-now drgnx-view))
    (let ((pos (text-property-not-all (point-min) (point-max) 'drgnx-term-image nil)))
      (and pos (eq (car-safe (car-safe (get-text-property pos 'display))) 'slice) pos))))

(defun drgnx-term-gui--px (snap win pos dx dy)
  "SNAP's pixel (R G B) at DX, DY frame pixels from the top-left corner of POS's glyph in WIN."
  (redisplay t)
  (let* ((xy (posn-x-y (posn-at-point pos win))) (o (drgnx-uitest--text-origin win))
         (s (drgnx-uitest-device-scale (window-frame win))))
    (cdr (drgnx-uitest-pixel snap (round (* s (+ (car o) (car xy) dx))) (round (* s (+ (cdr o) (cdr xy) dy)))))))

(defun drgnx-term-gui--near (px rgb)
  (cl-every (lambda (a b) (<= (abs (- a b)) 40)) px rgb))

(defun drgnx-term-gui--cat (buffer bytes)
  "Clear BUFFER's screen and have its shell print BYTES (a unibyte string, escapes and all) from a file."
  (let ((f (make-temp-file "drgnx-term-gui")))
    (let ((coding-system-for-write 'no-conversion)) (write-region (concat "\e[H\e[2J" bytes) nil f nil 'silent))
    (drgnx-term-gui--run buffer (concat "cat " f "; rm " f))))

(defun drgnx-term-gui--png ()
  "The fixture PNG, 4 px by 2: a red row over a blue one, base64."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion))
      (insert-file-contents-literally (expand-file-name "test/fixtures/term-red-over-blue.png" drgnx-term-gui--repo)))
    (base64-encode-string (buffer-string) t)))

(defun drgnx-term-gui--two-by-two (b what)
  "Wait for BUFFER B's image (WHAT) and the line `after' below it; the image, 2 cells by 2 at the screen's top left,
is red in its first cell row, blue in its second, and the cell after it is neither."
  (let ((win (get-buffer-window b)) (cw (frame-char-width)) (ch (frame-char-height)))
    (drgnx-test-wait (lambda () (and (drgnx-term-gui--image-pos b) (member "after" (drgnx-term-gui--lines b))))
                     :secs 30 :what (concat what " and the text after it"))
    (let* ((pos (drgnx-term-gui--image-pos b)) (snap (drgnx-uitest-snapshot))
           (top (drgnx-term-gui--px snap win pos (/ cw 2) (/ ch 4)))
           (below (with-current-buffer b (save-excursion (goto-char pos) (forward-line 1) (point))))
           (bottom (drgnx-term-gui--px snap win below (/ cw 2) (/ ch 2)))
           (right (drgnx-term-gui--px snap win pos (+ (* 2 cw) (/ cw 2)) (/ ch 2))))
      (message "drgnx-term-gui: %s top %S, bottom %S, right of it %S" what top bottom right)
      (should (drgnx-term-gui--near top '(255 0 0)))
      (should (drgnx-term-gui--near bottom '(0 0 255)))
      (should-not (drgnx-term-gui--near right '(255 0 0)))
      (should-not (drgnx-term-gui--near right '(0 0 255)))
      (should (equal (nth 2 (drgnx-term-gui--lines b)) "after")))))

(ert-deftest drgnx-term-gui/a-sixel-is-drawn-at-its-cells ()
  "A sixel 2 cells by 2 is drawn where the program put it: red in its first cell row, blue in its second, the cell
after it the window's background; the text after it starts on the row below the image."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'png))
  (drgnx-term-gui--with
    (let ((b (drgnx-term-gui--start)))
      (drgnx-term-gui--run b (drgnx-term-gui--sixel (frame-char-width) (frame-char-height)))
      (drgnx-term-gui--two-by-two b "the sixel"))))

(ert-deftest drgnx-term-gui/a-kitty-png-is-scaled-to-its-cells ()
  "A kitty PNG (4 × 2 px) placed on 2 cells by 2 (`c', `r') is scaled to them: red over blue."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'png))
  (drgnx-term-gui--with
    (let ((b (drgnx-term-gui--start)))
      (drgnx-term-gui--cat b (concat "\e_Ga=T,f=100,c=2,r=2,q=2;" (drgnx-term-gui--png) "\e\\\r\nafter\n"))
      (drgnx-term-gui--two-by-two b "the kitty PNG"))))

(ert-deftest drgnx-term-gui/an-iterm2-image-is-sized-in-cells ()
  "An iTerm2 inline PNG asked 2 cells wide and 2 tall, its aspect not kept, fills them: red over blue."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'png))
  (drgnx-term-gui--with
    (let ((b (drgnx-term-gui--start)))
      (drgnx-term-gui--cat b (concat "\e]1337;File=inline=1;width=2;height=2;preserveAspectRatio=0:"
                                     (drgnx-term-gui--png) "\a\r\nafter\n"))
      (drgnx-term-gui--two-by-two b "the iTerm2 image"))))

(defun drgnx-term-gui--rgba (r g b)
  "4 × 4 px of R G B, opaque, as kitty's base64 RGBA."
  (let ((px (unibyte-string r g b 255)) (out ""))
    (dotimes (_ 16) (setq out (concat out px)))
    (base64-encode-string out t)))

(ert-deftest drgnx-term-gui/a-kitty-animation-plays-on-the-frame ()
  "A kitty animation of two frames (red, then blue; 100 ms each, looping) placed on 2 cells by 2: the frame shows
both colours in turn at the image's cell."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'png))
  (drgnx-term-gui--with
    (let ((b (drgnx-term-gui--start)) (seen nil))
      (drgnx-term-gui--cat b (concat "\e_Ga=T,i=7,f=32,s=4,v=4,c=2,r=2,q=2;" (drgnx-term-gui--rgba 255 0 0) "\e\\"
                                     "\e_Ga=f,i=7,f=32,s=4,v=4,z=100,q=2;" (drgnx-term-gui--rgba 0 0 255) "\e\\"
                                     "\e_Ga=a,i=7,r=1,z=100,q=2\e\\\e_Ga=a,i=7,s=3,v=1,q=2\e\\\r\nafter\n"))
      (let ((win (get-buffer-window b)) (cw (frame-char-width)) (ch (frame-char-height)))
        (drgnx-test-wait
         (lambda ()
           (let ((pos (drgnx-term-gui--image-pos b)))
             (when pos
               (let ((px (drgnx-term-gui--px (drgnx-uitest-snapshot) win pos (/ cw 2) (/ ch 2))))
                 (cond ((drgnx-term-gui--near px '(255 0 0)) (cl-pushnew 'red seen))
                       ((drgnx-term-gui--near px '(0 0 255)) (cl-pushnew 'blue seen))))))
           (and (memq 'red seen) (memq 'blue seen)))
         :secs 30 :what "both frames on the screen")
        (message "drgnx-term-gui: animation showed %S" seen)))))

(ert-deftest drgnx-term-gui/an-image-under-the-text-is-drawn-over-it ()
  "A kitty image placed under the text (`z=-1', the cursor left where it was) with text printed over its cells: the
cells show the image, not the text (Emacs displays a slice instead of the cells' text: the documented limit)."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'png))
  (drgnx-term-gui--with
    (let ((b (drgnx-term-gui--start)))
      (drgnx-term-gui--cat b (concat "\e_Ga=T,f=100,c=2,r=2,z=-1,C=1,q=2;" (drgnx-term-gui--png) "\e\\XX\r\n\r\nafter\n"))
      (drgnx-test-wait (lambda () (and (drgnx-term-gui--image-pos b) (member "after" (drgnx-term-gui--lines b))))
                       :secs 30 :what "the image under the text")
      (let* ((win (get-buffer-window b)) (pos (drgnx-term-gui--image-pos b)) (snap (drgnx-uitest-snapshot))
             (cw (frame-char-width)) (ch (frame-char-height)))
        (should (equal (with-current-buffer b (buffer-substring-no-properties pos (+ pos 2))) "XX"))
        (dolist (dx (list 1 (/ cw 2) (+ cw (/ cw 2))))
          (should (drgnx-term-gui--near (drgnx-term-gui--px snap win pos dx (/ ch 4)) '(255 0 0))))))))

(defun drgnx-term-gui--ask (method params)
  "The hub's answer to METHOD with PARAMS."
  (let (done answer)
    (drgnx-hub-call method params (lambda (r e) (setq answer (or r e) done t)))
    (drgnx-test-wait (lambda () done) :secs 30 :what (format "the hub's answer to %s" method))
    answer))

(defun drgnx-term-gui--row (id)
  "Terminal ID's `term/list' row, or nil."
  (seq-find (lambda (r) (equal (plist-get r :id) id)) (drgnx-term-gui--ask "term/list" nil)))

(ert-deftest drgnx-term-gui/a-reattached-screen-is-the-screen-before-the-quit ()
  "Kept at quit, the terminal's screen (coloured text, an image) is drawn by the next Emacs pixel for pixel as it
was, the cursor's row aside."
  (skip-unless (display-graphic-p))
  (skip-unless (image-type-available-p 'png))
  (drgnx-term-gui--with
    (let* ((b (drgnx-term-gui--start)) (win (get-buffer-window b)) (cw (frame-char-width)) (ch (frame-char-height))
           (id (buffer-local-value 'drgnx-term--id b)))
      (unwind-protect
          (let (before rect)
            (drgnx-term-gui--run b (drgnx-term-gui--sixel cw ch))
            (drgnx-test-wait (lambda () (and (drgnx-term-gui--image-pos b) (member "after" (drgnx-term-gui--lines b))))
                             :secs 30 :what "the image")
            (drgnx-term-gui--run b "printf '\\033[1;31mred\\033[0m \\033[44mon blue\\033[0m\\n'")
            (drgnx-test-wait (lambda () (member "red on blue" (drgnx-term-gui--lines b))) :secs 30 :what "the colours")
            (drgnx-test-wait (lambda ()
                               (drgnx-term-gui--lines b)
                               (with-current-buffer b
                                 (and (string-prefix-p "$" (buffer-substring-no-properties (line-beginning-position)
                                                                                           (line-end-position)))
                                      (save-excursion (forward-line -1) (looking-at "red on blue")))))
                             :secs 30 :what "the prompt after them")
            (redisplay t)
            (let* ((o (drgnx-uitest--text-origin win)) (s (drgnx-uitest-device-scale (window-frame win)))
                   (cur (with-current-buffer b (posn-x-y (posn-at-point (line-beginning-position) win)))))
              (setq rect (list (round (* s (car o))) (round (* s (cdr o)))
                               (round (* s (+ (car o) (window-body-width win t)))) (round (* s (+ (cdr o) (cdr cur))))))
              (setq before (drgnx-uitest-snapshot)))
            (let ((drgnx-term-on-quit 'ask) (drgnx-session-quit-keep 'keep) (drgnx-term--quit-keep (list id)))
              (drgnx-term--session-end))
            (drgnx-test-wait (lambda () (plist-get (drgnx-term-gui--row id) :detached_at)) :secs 30 :what "detached")
            (with-current-buffer b
              (remhash drgnx-term--id drgnx-term--buffers)
              (setq drgnx-term--id nil drgnx-term--state nil))
            (let ((kill-buffer-query-functions nil)) (kill-buffer b))
            (drgnx-hub-disconnect)
            (let ((drgnx-hub-session (format "next-%x" (random (ash 1 30)))))
              (drgnx-hub-connect)
              ;; what the module's `drgnx-hub-connected-functions' entry does in a new Emacs (the module is not on here)
              (drgnx-test-wait #'drgnx-term--up-p :secs 30 :what "the next subscription")
              (drgnx-term--look)
              (drgnx-test-wait (lambda () (seq-find (lambda (r) (equal (plist-get r :id) id)) drgnx-term--offered))
                               :secs 30 :what "the offer")
              (let ((nb (drgnx-term-reattach-one (seq-find (lambda (r) (equal (plist-get r :id) id)) drgnx-term--offered)
                                                 t)))
                (set-window-buffer win nb)
                (drgnx-test-wait (lambda () (and (eq (buffer-local-value 'drgnx-term--state nb) 'open)
                                                 (drgnx-term-gui--image-pos nb)
                                                 (member "red on blue" (drgnx-term-gui--lines nb))))
                                 :secs 30 :what "the reattached screen")
                (redisplay t)
                (let ((after (drgnx-uitest-snapshot)))
                  (message "drgnx-term-gui: reattach compares %S" rect)
                  (should (drgnx-uitest-region-equal-p before after rect))))))
        (ignore-errors (drgnx-term-gui--ask "term/close" (list :id id)))))))

(provide 'term-gui-test)
;;; term-gui-test.el ends here
