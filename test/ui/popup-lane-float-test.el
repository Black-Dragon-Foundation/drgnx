;;; popup-lane-float-test.el --- GUI tests: the popup lane floats in a child frame under Glitnir (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; With `drgnx-popup-style' `float' (what `auto' picks under Glitnir) a transient menu, which-key's hints and
;; `*Completions*' show in one child frame over the editor, bottom-centre.  Every row skips unless Glitnir draws the
;; frames (the native shell).  Pattern D (pure): each row asserts frame and window state after the lane call returns;
;; the picture is awaited with `drgnx-test-wait-presented' only to leave a clean frame for the next row.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-popup-float-ui-test--repo           ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-popup-float-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-rules)
(require 'drgnx-popup)

(defvar drgnx-wb-unrouted)

(defmacro drgnx-popup-float-ui-test--with (&rest body)
  "BODY on a bare root frame with the rules on and the lane floating; the lane and its buffers gone after."
  (declare (indent 0))
  `(progn
     (skip-unless (drgnx-uitest-glitnir-p))
     (drgnx-uitest-bare-frame)
     (let ((drgnx-popup-style 'float) (drgnx-wb-unrouted nil)
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
           (root (drgnx-uitest-root-frame)))
       (delete-other-windows)
       (drgnx-rules-mode 1)
       (unwind-protect (progn ,@body)
         (when-let* ((lane (drgnx-popup--window root))) (drgnx-popup--end lane))
         (drgnx-rules-mode -1)
         (dolist (b '("*Calendar*" " *transient*" " *which-key*" "*Completions*"))
           (when (get-buffer b) (kill-buffer b)))
         (when-let* ((c (frame-parameter root 'drgnx-popup-frame))) (when (frame-live-p c) (delete-frame c)))
         (set-frame-parameter root 'drgnx-popup-frame nil)
         (drgnx-test-wait-presented)))))

(defun drgnx-popup-float-ui-test--buffer (name &optional lines)
  "The buffer NAME with LINES (default 3) lines of text."
  (with-current-buffer (get-buffer-create name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dotimes (i (or lines 3)) (insert (format "line %d of %s\n" i name))))
    (current-buffer)))

(defun drgnx-popup-float-ui-test--child (root)
  "ROOT's popup child frame, or nil."
  (frame-parameter root 'drgnx-popup-frame))

(ert-deftest drgnx-ui-popup-lane-float/which-key ()
  "which-key's buffer shows in one visible child frame of the root: undecorated, bottom-centre above the echo area,
at most 0.9 of the frame wide and 0.33 high, and not the selected frame."
  (drgnx-popup-float-ui-test--with
    (let* ((w (display-buffer (drgnx-popup-float-ui-test--buffer " *which-key*" 6)))
           (child (window-frame w)))
      (should (eq (frame-parent child) root))
      (should (eq child (drgnx-popup-float-ui-test--child root)))
      (should (frame-visible-p child))
      (should (frame-parameter child 'drgnx-popup))
      (should (frame-parameter child 'undecorated))
      (should (frame-parameter child 'no-accept-focus))
      (should (frame-parameter child 'no-other-frame))
      (should-not (eq child (selected-frame)))
      ;; the compositor answers the size later: wait until the frame has the size that was asked for
      (drgnx-test-wait (lambda () (redisplay t) (<= (frame-outer-height child) (* 0.33 (frame-pixel-height root))))
                       :secs 10 :what "the lane's frame has its fitted size")
      (should (<= (frame-outer-width child) (* 0.9 (frame-pixel-width root))))
      (should (<= (frame-outer-height child) (* 0.33 (frame-pixel-height root))))
      (let* ((x (car (frame-position child)))
             (centre (/ (- (frame-pixel-width root) (frame-outer-width child)) 2)))
        (should (<= (abs (- x centre)) 1)))
      (should (<= (+ (cdr (frame-position child)) (frame-outer-height child))
                  (- (frame-pixel-height root) (window-pixel-height (minibuffer-window root)) -1))))))

(ert-deftest drgnx-ui-popup-lane-float/transient-keys-in-editor ()
  "While a transient's buffer floats, the editor frame and window stay selected and keys still insert there."
  (drgnx-popup-float-ui-test--with
    (let ((editor (selected-window)) (text (generate-new-buffer "float-editor")))
      (unwind-protect
          (progn
            (set-window-buffer editor text)
            (display-buffer (drgnx-popup-float-ui-test--buffer " *transient*" 4))
            (should (drgnx-popup-active-p root))
            (should (eq (selected-frame) root))
            (should (eq (selected-window) editor))
            (with-current-buffer text (execute-kbd-macro "ab") (should (equal (buffer-string) "ab"))))
        (kill-buffer text)))))

(ert-deftest drgnx-ui-popup-lane-float/completions-click ()
  "A mouse-1 click on a candidate in the floating `*Completions*' chooses it."
  (drgnx-popup-float-ui-test--with
    (let* ((target (generate-new-buffer "float-target"))
           (choices '("alpha" "bravo" "charlie")) (chosen nil))
      (unwind-protect
          (progn
            (with-current-buffer target (insert "") (setq completion-reference-buffer target))
            (with-output-to-temp-buffer "*Completions*" (display-completion-list choices))
            (let ((w (get-buffer-window "*Completions*" t)))
              (should w)
              (should (frame-parent (window-frame w)))
              (with-current-buffer "*Completions*"
                (setq completion-reference-buffer target)
                (goto-char (point-min))
                (let ((m (text-property-search-forward 'completion--string "bravo" t)))
                  (should m)
                  (goto-char (prop-match-beginning m)))
                (let ((event (list 'mouse-1 (posn-at-point (point) w))))
                  (setq chosen (condition-case err (progn (choose-completion event) t) (error err)))))
              (should (eq chosen t))
              (should (equal (with-current-buffer target (buffer-string)) "bravo"))))
        (kill-buffer target)))))

(ert-deftest drgnx-ui-popup-lane-float/ends-four-ways ()
  "delete-window, quit-window, bury-buffer and kill-buffer each end the lane: the frame goes invisible and stays alive."
  (drgnx-popup-float-ui-test--with
    (dolist (how '(delete quit bury kill))
      (let* ((b (drgnx-popup-float-ui-test--buffer "*Calendar*"))
             (w (display-buffer b)) (child (window-frame w)))
        (should (frame-visible-p child))
        (pcase how
          ('delete (delete-window w))
          ('quit (with-selected-window w (quit-window)))
          ('bury (with-selected-window w (bury-buffer)))
          ('kill (kill-buffer b)))
        ;; bury and quit change the window's buffer: the lane ends at the next redisplay
        (drgnx-test-wait (lambda () (redisplay t) (not (frame-visible-p child))) :secs 10
                         :what (format "the lane ended by %s" how))
        (should (frame-live-p child))
        (should-not (drgnx-popup-active-p root))
        (should (eq child (drgnx-popup-float-ui-test--child root)))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest drgnx-ui-popup-lane-float/frame-reused ()
  "Two popups in a row, and one after the lane ended, use the same child frame; the root has only that one."
  (drgnx-popup-float-ui-test--with
    (let* ((w1 (display-buffer (drgnx-popup-float-ui-test--buffer "*Calendar*")))
           (child (window-frame w1))
           (w2 (display-buffer (drgnx-popup-float-ui-test--buffer " *which-key*" 5))))
      (should (eq child (window-frame w2)))
      (drgnx-popup--end w2)
      (let ((w3 (display-buffer (get-buffer "*Calendar*"))))
        (should (eq child (window-frame w3)))
        (should (frame-visible-p child)))
      (should (= 1 (length (seq-filter (lambda (f) (eq (frame-parent f) root)) (frame-list))))))))

(provide 'popup-lane-float-test)
;;; popup-lane-float-test.el ends here
