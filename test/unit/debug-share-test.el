;;; debug-share-test.el --- batch tests: Send Run and Open Sent Run in the editor -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call' replaced): what is tested is what the editor sends, shows, and
;; leaves behind.  The hub side has its Rust tests (debug::tests_record_sealed, debug::record::share).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-debug-share" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-debug-fork" drgnx-dir) nil t)

;; built from parts, so this file's own text (if a buffer holds it) never matches the search for the code
(defconst debug-share-test--code (concat "K7" "QF-M2XD-9RTA-PL4W-ZB6N-C3HV-Y8EG-UJ5S-QW2M-R7DK-X4PA-N6TB-FHC2"))
(defconst debug-share-test--needle (concat "K7" "QF"))

(defconst debug-share-test--run
  '(:id "r1" :n 4 :root "/p" :name "Python: plan the week" :stops 3 :ended 1700000000.0 :probes [(:id "a") (:id "b")]))

(defmacro debug-share-test--with-hub (answers &rest body)
  "BODY with the hub answering each call from ANSWERS (METHOD → (RESULT . ERROR) in turn); `calls' holds (METHOD .
PARAMS)."
  (declare (indent 1))
  `(let ((calls nil) (answers (copy-tree ,answers)))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params &optional callback &rest _)
                  (setq calls (append calls (list (cons method params))))
                  (let* ((queue (assoc method answers)) (a (if (cdr queue) (pop (cdr queue)) '(t))))
                    (when callback (funcall callback (car a) (cdr a))))
                  1)))
       (unwind-protect (progn ,@body)
         (when-let* ((b (get-buffer drgnx-debug-share-buffer)))
           (with-current-buffer b (drgnx-debug-share--forget))
           (kill-buffer b))))))

(defun debug-share-test--card-text ()
  (with-current-buffer drgnx-debug-share-buffer (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest drgnx-debug-share/the-card-comes-before-anything-is-written ()
  "Send Run shows the card (the warning, the run, the file) and calls nothing; Write File exports to the file."
  (debug-share-test--with-hub '(("debug/run/export" ((:path "/tmp/x/run4.drgnx-run" :code "C" :bytes 188416))))
    (drgnx-debug-send-run debug-share-test--run "/tmp/x/run4.drgnx-run")
    (should (null calls))
    (let ((text (debug-share-test--card-text)))
      (should (string-match-p "Send Run 4" text))
      (should (string-match-p "real values, unredacted" text))
      (should (string-match-p "Python: plan the week" text))
      (should (string-match-p "3 stops · 2 probes" text))
      (should (string-match-p "run4\\.drgnx-run" text))
      (should (string-match-p "Write File" text)))
    (with-current-buffer drgnx-debug-share-buffer (drgnx-debug-share-write))
    (should (equal calls '(("debug/run/export" :run "r1" :path "/tmp/x/run4.drgnx-run"))))
    (let ((text (debug-share-test--card-text)))
      (should (string-match-p "Run 4 written · 184 KB" text))
      (should (string-match-p "not shown again" text))
      (should (string-match-p "I've Noted It" text)))))

(ert-deftest drgnx-debug-share/cancel-writes-nothing ()
  (debug-share-test--with-hub nil
    (drgnx-debug-send-run debug-share-test--run "/tmp/x/run4.drgnx-run")
    (with-current-buffer drgnx-debug-share-buffer (drgnx-debug-share-cancel))
    (should (null calls))
    (should-not (get-buffer drgnx-debug-share-buffer))))

(ert-deftest drgnx-debug-share/a-refused-export-says-why ()
  (debug-share-test--with-hub '(("debug/run/export" (nil . (:message "run r1 is still recording: send it once it has ended"))))
    (drgnx-debug-send-run debug-share-test--run "/tmp/x/run4.drgnx-run")
    (with-current-buffer drgnx-debug-share-buffer (drgnx-debug-share-write))
    (should (string-match-p "still recording" (debug-share-test--card-text)))))

(ert-deftest drgnx-debug-share/the-code-is-shown-once-and-kept-nowhere ()
  "The card shows the code; it cannot be copied from the buffer with the region commands, the buffer is never
auto-saved or saved by desktop, and once the card closes no buffer, history or ring holds it."
  (let ((kill-ring nil) (kill-ring-yank-pointer nil))
    (debug-share-test--with-hub `(("debug/run/export" ((:path "/tmp/x/run4.drgnx-run" :code ,debug-share-test--code
                                                              :bytes 188416))))
      (drgnx-debug-send-run debug-share-test--run "/tmp/x/run4.drgnx-run")
      (with-current-buffer drgnx-debug-share-buffer
        (drgnx-debug-share-write)
        (should (string-match-p (concat debug-share-test--needle " M2XD 9RTA") (debug-share-test--card-text)))
        (should (null buffer-auto-save-file-name))
        (should (eq buffer-undo-list t))
        (should (local-variable-p 'desktop-save-buffer))
        (should (null desktop-save-buffer))
        (should-error (call-interactively (key-binding [remap kill-ring-save])) :type 'user-error)
        (kill-ring-save (point-min) (point-max))
        (should (equal (filter-buffer-substring (point-min) (point-max)) ""))
        (drgnx-debug-share-noted))
      (should-not (get-buffer drgnx-debug-share-buffer))
      (let ((needle debug-share-test--needle))
        (dolist (b (buffer-list))
          (with-current-buffer b
            (save-restriction (widen)
                              (should-not (save-excursion (goto-char (point-min)) (search-forward needle nil t))))))
        (should-not (cl-some (lambda (h) (and (boundp h) (string-match-p needle (format "%S" (symbol-value h)))))
                             '(minibuffer-history command-history extended-command-history kill-ring
                                                  read-expression-history)))))))

(ert-deftest drgnx-debug-share/closing-before-noting-asks ()
  (debug-share-test--with-hub `(("debug/run/export" ((:path "/tmp/x/r" :code ,debug-share-test--code :bytes 10))))
    (drgnx-debug-send-run debug-share-test--run "/tmp/x/r")
    (with-current-buffer drgnx-debug-share-buffer (drgnx-debug-share-write))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (with-current-buffer drgnx-debug-share-buffer (drgnx-debug-share-cancel)))
    (should (get-buffer drgnx-debug-share-buffer))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (with-current-buffer drgnx-debug-share-buffer (drgnx-debug-share-cancel)))
    (should-not (get-buffer drgnx-debug-share-buffer))))

(ert-deftest drgnx-debug-share/copy-code-clears-the-clipboard-after-60-s ()
  "Copy Code puts the code on the clipboard only, never in the kill ring; 60 s later it is cleared, but only while
the clipboard still holds it."
  (let ((clipboard nil) (kill-ring nil))
    (cl-letf (((symbol-function 'gui-set-selection) (lambda (_type data) (setq clipboard data)))
              ((symbol-function 'gui-get-selection) (lambda (&rest _) clipboard)))
      (drgnx-test-with-clock ()
        (debug-share-test--with-hub `(("debug/run/export" ((:path "/tmp/x/r" :code ,debug-share-test--code :bytes 10))))
          (drgnx-debug-send-run debug-share-test--run "/tmp/x/r")
          (with-current-buffer drgnx-debug-share-buffer
            (drgnx-debug-share-write)
            (drgnx-debug-share-copy))
          (should (equal clipboard debug-share-test--code))
          (should (null kill-ring))
          (drgnx-test-advance 59)
          (should (equal clipboard debug-share-test--code))
          (drgnx-test-advance 2)
          (should (equal clipboard ""))
          ;; someone else's later copy is never cleared
          (with-current-buffer drgnx-debug-share-buffer (drgnx-debug-share-copy))
          (setq clipboard "mine")
          (drgnx-test-advance 61)
          (should (equal clipboard "mine")))))))

(ert-deftest drgnx-debug-share/open-sent-run-imports-and-shows-it ()
  "Open Sent Run sends the file, the code and the project, then shows the run it made."
  (let (shown)
    (cl-letf (((symbol-function 'drgnx-debug-timeline-show) (lambda (&optional run) (setq shown run)))
              ((symbol-function 'drgnx-debug-timeline--root) (lambda () "/p")))
      (debug-share-test--with-hub '(("debug/run/import" ((:run "r9"))))
        (drgnx-debug-open-sent-run "/tmp/x/run4.drgnx-run" (copy-sequence debug-share-test--code))
        (should (equal calls `(("debug/run/import" :root "/p" :path "/tmp/x/run4.drgnx-run"
                                :code ,debug-share-test--code))))
        (should (equal shown "r9"))))))

(ert-deftest drgnx-debug-share/a-sent-run-is-never-forked ()
  "The strip's run is marked sent from its record, and Fork from Here refuses it before asking anything."
  (let ((drgnx-debug-timeline--run "r9")
        (drgnx-debug-timeline--meta '(:id "r9" :n 7 :imported (:at 1700000000.0 :n 4))))
    (should (drgnx-debug-timeline-sent-p "r9"))
    (should-not (drgnx-debug-timeline-sent-p "r1"))
    (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (error "Asked the hub"))))
      (should-error (drgnx-debug-fork "r9" '(:stop 1)) :type 'user-error))
    (should (string-match-p "Sent run · stop 1 of 3"
                            (substring-no-properties
                             (drgnx-debug-timeline--banner 1 3 '(:reason "breakpoint") nil))))
    (should (string-match-p "Sent.*run 4 where it was recorded"
                            (substring-no-properties (drgnx-debug-timeline--sent-line))))))

;;; debug-share-test.el ends here

(ert-deftest drgnx-debug-share/the-modal-ring-survives-the-padding ()
  "The card's frame takes the modal chrome's ring (high contrast's 2 px) and pads in its fringes, not its border."
  (cl-letf (((symbol-function 'drgnx-look-palette-current)
             (lambda () '((corner-radius . 12) (alpha-background . 1.0) (child-frame-border-width . 2) (transition . pop)))))
    (let ((params (drgnx-debug-share--params (selected-frame))))
      (should (equal (alist-get 'child-frame-border-width params) (drgnx-px-line 2)))
      (should (equal (alist-get 'left-fringe params) (drgnx-px 16)))
      (should (equal (alist-get 'right-fringe params) (drgnx-px 16)))
      (should (equal (alist-get 'corner-radius params) 12))
      (should-not (assq 'transition params))
      ;; the palette's frame takes the same ring
      (should (equal (alist-get 'child-frame-border-width (drgnx-palette-frame--params (selected-frame)))
                     (drgnx-px-line 2))))))

(ert-deftest drgnx-debug-share/the-warning-the-code-and-the-footer-are-blocks ()
  "The warning wraps under its text, not its icon; the warning and the code are rounded blocks (radius 6) across the
card, the footer has a hairline; the default button is ringed."
  (debug-share-test--with-hub `(("debug/run/export" ((:path "/tmp/x/run4.drgnx-run" :code ,debug-share-test--code
                                                            :bytes 188416))))
    (drgnx-debug-send-run debug-share-test--run "/tmp/x/run4.drgnx-run")
    (with-current-buffer drgnx-debug-share-buffer
      (goto-char (point-min))
      (search-forward "real values")
      (let ((wrap (get-text-property (point) 'wrap-prefix)))
        (should (eq (car (get-text-property 0 'display wrap)) 'space))
        (should (>= (car (plist-get (cdr (get-text-property 0 'display wrap)) :width)) (drgnx-px 18))))
      (should (equal (mapcar #'car drgnx-debug-share--blocks) '(ring rule)))
      (should (equal (plist-get (nthcdr 3 (car drgnx-debug-share--blocks)) :radius) (drgnx-px 6)))
      (should (eq (plist-get (nthcdr 3 (cadr drgnx-debug-share--blocks)) :ring) 'drgnx-border-subtle))
      (drgnx-debug-share-write)
      (should (equal (mapcar #'car drgnx-debug-share--blocks) '(ring rule)))
      (let ((code (car drgnx-debug-share--blocks)))
        (should (eq (plist-get (nthcdr 3 code) :ring) 'drgnx-border))
        (should (string-match-p (concat debug-share-test--needle " M2XD")
                                (buffer-substring-no-properties (nth 1 code) (nth 2 code))))))))

(ert-deftest drgnx-debug-share/the-default-button-has-the-focus-ring ()
  (cl-letf (((symbol-function 'drgnx-ui-button-focus-box) (lambda () '(:line-width (-2 . -2) :color "red"))))
    (let ((ringed (get-text-property 1 'face (drgnx-ui-button "Go" 'ignore :face 'drgnx-ui-button-primary :focus t))))
      (should (equal (plist-get ringed :box) '(:line-width (-2 . -2) :color "red")))
      (should (eq (plist-get ringed :inherit) 'drgnx-ui-button-primary))
      (should (eq (get-text-property 1 'face (drgnx-ui-button "Go" 'ignore :face 'drgnx-ui-button-primary))
                  'drgnx-ui-button-primary)))))
