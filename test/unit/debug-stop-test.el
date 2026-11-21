;;; debug-stop-test.el --- batch tests: the stopped line, caller frames, sources and the exception card -*- lexical-binding: t -*-
;; test-class: det
;; The hub's events are fed to the module's handler as the hub sends them (`debug-frame', `debug-state',
;; `debug-ended'); `drgnx-hub-call' is replaced (`debug/source' answers from the test).  The hub side has its own tests
;; (debug::tests_registry: exceptionInfo, debug/source, the frame's names).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)

(defvar debug-stop-test--a nil "The test's a.py.")

(defmacro debug-stop-test--with (&rest body)
  "BODY with a project folder `dir' holding a.py (ten lines) and b.py, the hub replaced (`calls' holds each call), and
every buffer and mark it made gone after."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "dstop" t))
          (a (expand-file-name "a.py" dir)) (b (expand-file-name "b.py" dir))
          (calls nil) (before (buffer-list))
          (drgnx-debug--sessions nil) (drgnx-debug-gutter--sessions nil))
     (setq debug-stop-test--a a)
     (with-temp-file a (dotimes (i 10) (insert (format "line_%d = %d\n" (1+ i) i))))
     (with-temp-file b (insert "x = 1\ny = 2\n"))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params cb &rest _)
                  (setq calls (append calls (list (cons method params))))
                  (when (equal method "debug/source")
                    (funcall cb (list :text "function f() {\n  return 1;\n}\n" :mime "text/javascript") nil))))
               ((symbol-function 'drgnx-debug-launch-root) (lambda () (directory-file-name dir))))
       (unwind-protect
           (save-window-excursion
             (drgnx-debug-mode 1)
             (drgnx-debug--event "debug-state" (list :sessions (vector (list :id "s" :root (directory-file-name dir)
                                                                             :state "stopped"))))
             ,@body)
         (drgnx-debug-gutter-stop-clear-all)
         (drgnx-debug-mode -1)
         (drgnx-debug-session-mode -1)
         (dolist (buf (buffer-list))
           (unless (memq buf before)
             (with-current-buffer buf (set-buffer-modified-p nil))
             (kill-buffer buf)))
         (delete-directory dir t)))))

(defun debug-stop-test--frame (&rest more)
  "A `debug-frame' of session s: a.py:4:3, the top frame, opened, then MORE over it."
  (let ((d (list :session "s" :epoch 1 :thread 1 :path debug-stop-test--a :line 4 :col 3 :top t :reason "breakpoint" :open t
                 :name "f" :source_name nil :exception nil)))
    (while more (setq d (plist-put d (pop more) (pop more))))
    (drgnx-debug--event "debug-frame" d)))

(defun debug-stop-test--marks (buffer)
  "The stop marks in BUFFER as (LINE ROLE KIND), in line order."
  (with-current-buffer buffer
    (sort (delq nil (mapcar (lambda (o)
                              (when-let* ((role (overlay-get o 'drgnx-debug-stop)))
                                (list (line-number-at-pos (overlay-start o)) role (overlay-get o 'drgnx-debug-kind))))
                            (overlays-in (point-min) (point-max))))
          (lambda (x y) (< (car x) (car y))))))

(defun debug-stop-test--band (buffer line)
  "The face of the band on LINE of BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min)) (forward-line (1- line))
      (seq-some (lambda (o) (and (overlay-get o 'drgnx-debug-stop) (overlay-get o 'face))) (overlays-at (point))))))

(ert-deftest drgnx-debug-stop/the-stopped-file-opens-at-the-line ()
  "The starting editor opens the file and puts point at the stop's line and column; arrow and band mark it."
  (debug-stop-test--with
    (debug-stop-test--frame)
    (let ((buf (get-file-buffer a)))
      (should buf)
      (should (eq (window-buffer (selected-window)) buf))
      (with-current-buffer buf
        (should (= (line-number-at-pos (window-point)) 4))
        (should (= (current-column) 2)))
      (should (equal (debug-stop-test--marks buf) '((4 top stop))))
      (should (eq (debug-stop-test--band buf 4) 'drgnx-debug-stopped-line)))))

(ert-deftest drgnx-debug-stop/another-editor-draws-only-where-the-file-is-open ()
  "Without `open' nothing is visited; a buffer already showing the file is marked and its point stays."
  (debug-stop-test--with
    (debug-stop-test--frame :open nil)
    (should-not (get-file-buffer a))
    (let ((buf (find-file-noselect a)))
      (with-current-buffer buf (goto-char (point-min)))
      (debug-stop-test--frame :open nil :epoch 2)
      (should (equal (debug-stop-test--marks buf) '((4 top stop))))
      (with-current-buffer buf (should (= (point) (point-min)))))))

(ert-deftest drgnx-debug-stop/a-caller-frame-gets-its-own-mark ()
  "A caller frame (top nil) gets the outline arrow and the ok band, the top frame keeps its arrow; the next stop
clears both, and selecting the top frame again takes the caller's mark away."
  (debug-stop-test--with
    (debug-stop-test--frame)
    (debug-stop-test--frame :line 8 :top nil)
    (let ((buf (get-file-buffer a)))
      (should (equal (debug-stop-test--marks buf) '((4 top stop) (8 frame frame))))
      (should (eq (debug-stop-test--band buf 8) 'drgnx-debug-frame-line))
      (debug-stop-test--frame :line 4 :top t)
      (should (equal (debug-stop-test--marks buf) '((4 top stop))))
      (debug-stop-test--frame :line 8 :top nil)
      (debug-stop-test--frame :epoch 2 :line 6)
      (should (equal (debug-stop-test--marks buf) '((6 top stop)))))))

(ert-deftest drgnx-debug-stop/a-breakpoint-under-the-arrow ()
  "On a line with a breakpoint the arrow carries the dot (`stop-bp') and the breakpoint's own glyph is hidden until
the stop goes."
  (debug-stop-test--with
    (let ((buf (find-file-noselect a)))
      (with-current-buffer buf
        (drgnx-debug-gutter--apply (list :version 1 :breakpoints (list (list :id 1 :line 4 :enabled t :verified t)))))
      (debug-stop-test--frame)
      (should (equal (debug-stop-test--marks buf) '((4 top stop-bp))))
      (with-current-buffer buf
        (let ((mark (cdr (assq 1 drgnx-debug-gutter--overlays))))
          (should-not (overlay-get mark 'before-string))
          (drgnx-debug-gutter-stop-clear "s")
          (should (overlay-get mark 'before-string))))
      (should-not (debug-stop-test--marks buf)))))

(ert-deftest drgnx-debug-stop/the-exception-card ()
  "An exception stop: the error arrow and band, and a card under the line with the type, the message and the keys;
the next stop takes it away."
  (debug-stop-test--with
    (debug-stop-test--frame :reason "exception"
                            :exception (list :id "KeyError" :message "'nut-m6'" :break_mode "unhandled"
                                             :type "KeyError"))
    (let* ((buf (get-file-buffer a))
           (card (with-current-buffer buf
                   (seq-some (lambda (o) (overlay-get o 'after-string)) (overlays-in (point-min) (point-max))))))
      (should (equal (debug-stop-test--marks buf) '((4 top exception))))
      (should (eq (debug-stop-test--band buf 4) 'drgnx-debug-exception-line))
      (should (string-match-p "KeyError" card))
      (should (string-match-p "uncaught" card))
      (should (string-match-p "'nut-m6'" card))
      (should (string-match-p "continue" card))
      (debug-stop-test--frame :epoch 2 :line 5)
      (should-not (with-current-buffer buf
                    (seq-some (lambda (o) (overlay-get o 'after-string)) (overlays-in (point-min) (point-max))))))))

(ert-deftest drgnx-debug-stop/a-source-without-a-file ()
  "A frame with only a sourceReference opens a read-only buffer named after the source, filled by `debug/source'."
  (debug-stop-test--with
    (debug-stop-test--frame :path nil :ref 42 :source_name "<eval> VM12" :line 2 :col 1)
    (should (member '("debug/source" :session "s" :ref 42) calls))
    (let ((buf (get-buffer "<eval> VM12 (from the debugger)")))
      (should buf)
      (with-current-buffer buf
        (should buffer-read-only)
        (should (string-prefix-p "function f()" (buffer-string)))
        (should (= (line-number-at-pos (window-point (get-buffer-window buf))) 2)))
      (should (equal (debug-stop-test--marks buf) '((2 top stop)))))))

(ert-deftest drgnx-debug-stop/a-frame-with-no-source-says-so ()
  (debug-stop-test--with
    (let ((said nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (debug-stop-test--frame :path nil :name "<native code>"))
      (should (equal said "No source: <native code>"))
      (should-not (get-file-buffer a)))))

(ert-deftest drgnx-debug-stop/marks-go-150-ms-after-running ()
  "Running starts a 150 ms timer that clears the marks unless a stop comes first; the session's end clears at once."
  (debug-stop-test--with
    (debug-stop-test--frame)
    (let ((buf (get-file-buffer a)) (sessions (lambda (state) (list :sessions (vector (list :id "s" :root "/x" :state state))))))
      (drgnx-debug--event "debug-state" (funcall sessions "running"))
      (should (drgnx-timer-active-p '(debug-stop . "s")))
      (should (debug-stop-test--marks buf))
      (debug-stop-test--frame :epoch 2 :line 5)
      (should-not (drgnx-timer-active-p '(debug-stop . "s")))
      (should (equal (debug-stop-test--marks buf) '((5 top stop))))
      (drgnx-debug--event "debug-state" (funcall sessions "running"))
      (drgnx-debug-gutter-stop-clear "s")           ; what the timer calls
      (should-not (debug-stop-test--marks buf))
      (debug-stop-test--frame :epoch 3)
      (drgnx-debug--event "debug-ended" (list :session "s" :reason "exited"))
      (should-not (debug-stop-test--marks buf))
      (should-not (drgnx-timer-active-p '(debug-stop . "s"))))))

(ert-deftest drgnx-debug-stop/focus-only-when-asked ()
  (debug-stop-test--with
    (let ((raised 0))
      (cl-letf (((symbol-function 'select-frame-set-input-focus) (lambda (&rest _) (cl-incf raised))))
        (let ((drgnx-debug-focus-on-stop nil)) (debug-stop-test--frame))
        (should (= raised 0))
        (let ((drgnx-debug-focus-on-stop t)) (debug-stop-test--frame :epoch 2))
        (should (= raised 1))
        (let ((drgnx-debug-focus-on-stop t)) (debug-stop-test--frame :epoch 3 :open nil))
        (should (= raised 1))))))
