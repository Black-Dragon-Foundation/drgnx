;;; debug-inline-test.el --- batch tests: inline values at line ends while stopped -*- lexical-binding: t -*-
;; test-class: det
;; The hub's `debug-inline' events (which names, where, how long, what changed: debug::tests_inline and
;; debug::tests_registry) fed to the module's handler after their `debug-frame', as the hub sends them.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-blame" drgnx-dir) nil t)

(defvar debug-inline-test--a nil "The test's a.py.")

(defmacro debug-inline-test--with (&rest body)
  "BODY with a.py (ten lines) open in `buf', session s stopped at its line 4, the hub replaced, and every mark and buffer
it made gone after."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "dinl" t)) (a (expand-file-name "a.py" dir)) (before (buffer-list))
          (drgnx-debug--sessions nil) (drgnx-debug-gutter--sessions nil) (drgnx-debug-inline-values 'on))
     (setq debug-inline-test--a a)
     (with-temp-file a (dotimes (i 10) (insert (format "line_%d = %d\n" (1+ i) i))))
     (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore)
               ((symbol-function 'drgnx-debug-launch-root) (lambda () (directory-file-name dir))))
       (unwind-protect
           (save-window-excursion
             (drgnx-debug-mode 1)
             (drgnx-debug--event "debug-state" (list :sessions (vector (list :id "s" :root (directory-file-name dir)
                                                                             :state "stopped"))))
             (debug-inline-test--frame 1 4)
             (let ((buf (get-file-buffer a)))
               ,@body))
         (drgnx-debug-gutter-stop-clear-all)
         (drgnx-debug-mode -1)
         (drgnx-debug-session-mode -1)
         (dolist (b (buffer-list))
           (unless (memq b before)
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (delete-directory dir t)))))

(defun debug-inline-test--frame (epoch line)
  "A `debug-frame' of session s: a.py's LINE, the top frame, opened, in stop EPOCH."
  (drgnx-debug--event "debug-frame" (list :session "s" :epoch epoch :thread 1 :path debug-inline-test--a :line line :col 1
                                          :top t :reason "step" :open t :name "f")))

(defun debug-inline-test--send (epoch &rest lines)
  "A `debug-inline' of session s for a.py in stop EPOCH: LINES are (LINE TEXT CHANGED), CHANGED a list of (START END)."
  (drgnx-debug--event "debug-inline"
                      (list :session "s" :epoch epoch :path debug-inline-test--a
                            :lines (vconcat (mapcar (lambda (l) (list :line (nth 0 l) :text (nth 1 l)
                                                                      :changed (vconcat (mapcar #'vconcat (nth 2 l)))))
                                                    lines)))))

(defun debug-inline-test--overlays (buf)
  "BUF's inline value overlays."
  (with-current-buffer buf
    (seq-filter (lambda (o) (eq (overlay-get o 'drgnx-debug-stop) 'inline)) (overlays-in (point-min) (point-max)))))

(defun debug-inline-test--at (buf line)
  "The inline value overlay on LINE of BUF, or nil."
  (with-current-buffer buf
    (seq-find (lambda (o) (= (line-number-at-pos (overlay-start o)) line)) (debug-inline-test--overlays buf))))

(defun debug-inline-test--shown (buf)
  "BUF's inline values as ((LINE . TEXT) …), in line order."
  (with-current-buffer buf
    (sort (mapcar (lambda (o) (cons (line-number-at-pos (overlay-start o))
                                    (string-trim (substring-no-properties (overlay-get o 'after-string)))))
                  (debug-inline-test--overlays buf))
          (lambda (x y) (< (car x) (car y))))))

(ert-deftest drgnx-debug-inline/values-at-line-ends-below-diagnostics ()
  "Each line's values after its end, in the value face, a changed item in the changed face, at priority 90 (below
diagnostics' 100, so the values come first), the cursor kept before them."
  (debug-inline-test--with
    (debug-inline-test--send 1 '(2 "line_2 = 1" nil) '(4 "line_4 = 3  x = 1" ((12 17))))
    (should (equal (debug-inline-test--shown buf) '((2 . "line_2 = 1") (4 . "line_4 = 3  x = 1"))))
    (let* ((o (debug-inline-test--at buf 4)) (s (overlay-get o 'after-string))
           (start (string-search "line_4" s)))
      (should (= (overlay-get o 'priority) 90))
      (with-current-buffer buf
        (goto-char (point-min)) (forward-line 3)
        (should (= (overlay-start o) (line-end-position))))
      (should (get-text-property 0 'cursor s))
      (should (eq (get-text-property start 'face s) 'drgnx-debug-inline-value))
      (should (eq (get-text-property (+ start 12) 'face s) 'drgnx-debug-inline-value-changed))
      (should (eq (get-text-property (+ start 16) 'face s) 'drgnx-debug-inline-value-changed))
      (should (eq (get-text-property (+ start 11) 'face s) 'drgnx-debug-inline-value)))))

(ert-deftest drgnx-debug-inline/the-next-stop-replaces-them-in-place ()
  "The next stop's frame leaves the values; its `debug-inline' updates a line that keeps values in the same overlay,
adds new lines and takes away the others."
  (debug-inline-test--with
    (debug-inline-test--send 1 '(2 "a = 1" nil) '(4 "b = 2" nil))
    (let ((o4 (debug-inline-test--at buf 4)))
      (debug-inline-test--frame 2 5)
      (should (eq (debug-inline-test--at buf 4) o4))
      (should (equal (debug-inline-test--shown buf) '((2 . "a = 1") (4 . "b = 2"))))
      (debug-inline-test--send 2 '(4 "b = 3" ((0 5))) '(5 "c = 1" nil))
      (should (eq (debug-inline-test--at buf 4) o4))
      (should (equal (debug-inline-test--shown buf) '((4 . "b = 3") (5 . "c = 1"))))
      ;; a stop with no values here (another file, or none) takes them away
      (debug-inline-test--send 3)
      (should-not (debug-inline-test--overlays buf)))))

(ert-deftest drgnx-debug-inline/gone-150-ms-after-running-and-at-the-end ()
  (debug-inline-test--with
    (debug-inline-test--send 1 '(4 "b = 2" nil))
    (let ((state (lambda (s) (drgnx-debug--event "debug-state" (list :sessions (vector (list :id "s" :root "/x" :state s)))))))
      (funcall state "running")
      (should (drgnx-timer-active-p '(debug-stop . "s")))
      (should (= drgnx-debug-gutter-stop-linger 0.15))
      (should (debug-inline-test--overlays buf))
      (drgnx-debug-gutter-stop-clear "s")             ; what the timer calls
      (should-not (debug-inline-test--overlays buf))
      (debug-inline-test--frame 2 4)
      (debug-inline-test--send 2 '(4 "b = 3" nil))
      (drgnx-debug--event "debug-ended" (list :session "s" :reason "exited"))
      (should-not (debug-inline-test--overlays buf)))))

(ert-deftest drgnx-debug-inline/the-setting-off-shows-none ()
  (debug-inline-test--with
    (debug-inline-test--send 1 '(4 "b = 2" nil))
    (should (debug-inline-test--overlays buf))
    (customize-set-variable 'drgnx-debug-inline-values 'off)
    (should-not (debug-inline-test--overlays buf))           ; at once
    (debug-inline-test--send 2 '(4 "b = 3" nil))
    (should-not (debug-inline-test--overlays buf))
    (customize-set-variable 'drgnx-debug-inline-values 'on)
    (debug-inline-test--send 3 '(4 "b = 4" nil))
    (should (equal (debug-inline-test--shown buf) '((4 . "b = 4"))))))

(ert-deftest drgnx-debug-inline/a-modified-buffer-shows-none-and-says-why ()
  "The program runs the saved file: a buffer modified since has no values, and the echo area says why."
  (debug-inline-test--with
    (with-current-buffer buf (goto-char (point-max)) (insert "extra = 1\n"))
    (let (said)
      (cl-letf (((symbol-function 'message) (lambda (f &rest args) (setq said (apply #'format f args)))))
        (debug-inline-test--send 1 '(4 "b = 2" nil)))
      (should-not (debug-inline-test--overlays buf))
      (should (string-match-p "modified since it was saved" said)))))

(ert-deftest drgnx-debug-inline/blame-yields-on-their-lines ()
  "Blame on a line that gets values goes, and is not shown there again while they are; other lines keep it."
  (debug-inline-test--with
    (with-current-buffer buf
      (let ((info (list :author "Ada" :summary "Fix the parser")))
        (cl-letf (((symbol-function 'drgnx-blame--room) (lambda () 60)))
          (goto-char (point-min)) (forward-line 3)
          (drgnx-blame--show info)
          (should (overlay-buffer drgnx-blame--overlay))
          (debug-inline-test--send 1 '(4 "b = 2" nil))
          (should-not (and drgnx-blame--overlay (overlay-buffer drgnx-blame--overlay)))
          (drgnx-blame--show info)                    ; asked again on that line
          (should-not (and drgnx-blame--overlay (overlay-buffer drgnx-blame--overlay)))
          (forward-line 1)
          (drgnx-blame--show info)
          (should (overlay-buffer drgnx-blame--overlay))
          (drgnx-blame--hide))))))

;;; debug-inline-test.el ends here
