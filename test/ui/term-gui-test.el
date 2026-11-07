;;; term-gui-test.el --- GUI rows: drgnx's terminal in a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; A real hub (a test-hooks build from DRGNX_RATATOSKR_BIN, `drgnx-rows-demo-with') starts the terminal worker beside
;; it; the shell is /bin/sh.  The rows measure what a graphical frame shows: wide cells (CJK, a ZWJ emoji, a combining
;; mark) keep the columns after them in place, and the cursor's shape follows what the program asks (DECSCUSR).
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
  "Rows of a CJK pair (4 cells) and a letter with a combining mark (1), each followed by `|': the bar is drawn at its
cell, whatever width the font gives the characters before it."
  (skip-unless (display-graphic-p))
  (drgnx-term-gui--with
    (let* ((b (drgnx-term-gui--start)) (cw (frame-char-width))
           (rows `(("A" ,(string #x6f22 #x5b57) 5) ("C" ,(string ?e #x301) 2))))
      (drgnx-term-gui--run b (concat "printf '"
                                     (mapconcat (lambda (r) (concat (car r) (drgnx-term-gui--octal (cadr r)) "|\\n")) rows "")
                                     "'"))
      (drgnx-test-wait (lambda () (cl-every (lambda (r) (drgnx-term-gui--bar-x b (car r))) rows))
                       :secs 30 :what "the two rows")
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

(provide 'term-gui-test)
;;; term-gui-test.el ends here
