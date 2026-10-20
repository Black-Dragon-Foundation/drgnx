;;; wb-signal-test.el --- batch tests: the change bus -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-signal)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-signal-test--with (events-var &rest body)
  "BODY with a fresh bus; every emission is pushed onto EVENTS-VAR as (EVENT . DATA)."
  (declare (indent 1))
  `(let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal-errors nil)
         (,events-var nil)
         (dir (make-temp-file "drgnx-signal" t)))
     (unwind-protect
         (progn
           (dolist (e '(editor-changed buffer-set-changed modified-changed))
             (let ((e e)) (drgnx-signal-subscribe e (lambda (data) (push (cons e data) ,events-var)))))
           (drgnx-signal--flush)                   ; the starting state is not an edge
           (setq ,events-var nil)
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory dir t))))

(defun drgnx-signal-test--file (dir name)
  (let ((f (expand-file-name name dir))) (write-region "x\n" nil f nil 'silent) (find-file-noselect f)))

(ert-deftest drgnx-signal/edges-only ()
  (drgnx-signal-test--with events
    (drgnx-signal--flush)
    (should (null events))                          ; nothing changed, nothing emitted
    (let ((a (drgnx-signal-test--file dir "a.txt")))
      (drgnx-signal--flush)
      (should (assq 'buffer-set-changed events))
      (setq events nil)
      (switch-to-buffer a)
      (drgnx-signal--flush)
      (should (equal (cdr (assq 'editor-changed events)) a))
      (setq events nil)
      (drgnx-signal--flush)
      (should (null events)))))

(ert-deftest drgnx-signal/coalesces-into-one-flush ()
  (drgnx-signal-test--with events
    (dotimes (i 10) (drgnx-signal-test--file dir (format "f%d.txt" i)))
    (drgnx-signal--flush)
    (should (= 1 (seq-count (lambda (e) (eq (car e) 'buffer-set-changed)) events)))
    (should (= 10 (length (seq-filter (lambda (b) (string-prefix-p dir (or (buffer-file-name b) "")))
                                      (cdr (assq 'buffer-set-changed events))))))))

(ert-deftest drgnx-signal/internal-buffers-never-count ()
  (drgnx-signal-test--with events
    (kill-buffer (generate-new-buffer " *drgnx internal*"))
    (get-buffer-create " *drgnx other internal*")
    (drgnx-signal--flush)
    (kill-buffer " *drgnx other internal*")
    (should (null events))))

(ert-deftest drgnx-signal/modified-edges ()
  (drgnx-signal-test--with events
    (let ((a (drgnx-signal-test--file dir "a.txt")))
      (drgnx-signal--flush)
      (setq events nil)
      (with-current-buffer a (insert "more"))
      (drgnx-signal--flush)
      (should (equal (cdr (assq 'modified-changed events)) (list a)))
      (setq events nil)
      (with-current-buffer a (insert "and more"))
      (drgnx-signal--flush)
      (should (null events))                        ; still modified: no edge
      (with-current-buffer a (save-buffer))
      (drgnx-signal--flush)
      (should (equal (cdr (assq 'modified-changed events)) (list a))))))

(ert-deftest drgnx-signal/a-failing-subscriber-does-not-stop-the-others ()
  (drgnx-signal-test--with events
    (drgnx-signal-subscribe 'buffer-set-changed (lambda (_) (error "Subscriber broke")))
    (drgnx-signal-test--file dir "a.txt")
    (drgnx-signal--flush)
    (should (assq 'buffer-set-changed events))
    (should (seq-find (lambda (m) (string-search "Subscriber broke" m)) drgnx-signal-errors))))

(ert-deftest drgnx-signal/one-flush-per-burst ()
  ;; Raw hooks do no work: a burst arms one idle flush, the timer layer's `signal-flush' (owned by `:core'), which
  ;; runs once in the next pause; the next burst arms it again.
  (let ((n 0))
    (cl-letf (((symbol-function 'drgnx-signal--flush) (lambda () (cl-incf n))))
      (drgnx-test-with-clock ()
        (dotimes (_ 3) (drgnx-signal--schedule))
        (should (equal (assq 'signal-flush (drgnx-timer-pending)) '(signal-flush :core soon)))
        (drgnx-test-idle (* 2 drgnx-signal-delay))
        (should (= n 1))
        (should-not (drgnx-timer-active-p 'signal-flush))
        (drgnx-signal--schedule)
        (drgnx-signal--schedule)
        (drgnx-test-idle (* 2 drgnx-signal-delay))
        (should (= n 2))))))

(ert-deftest drgnx-signal/editor-point-changed-is-an-edge ()
  ;; DEFERRED M3d-6: the point of the editor's window moving (same buffer) is an edge, for followers such as
  ;; the Outline; no edge while it stays, none for a buffer switch (that is `editor-changed').
  (drgnx-signal-test--with events
    (let ((a (drgnx-signal-test--file dir "a.txt")) (moved nil))
      (with-current-buffer a (insert "line one\nline two\n"))
      (drgnx-signal-subscribe 'editor-point-changed (lambda (data) (push data moved)))
      (switch-to-buffer a)
      (drgnx-signal--flush)
      (should (null moved))                         ; a new editor buffer: `editor-changed', not a move
      (goto-char (point-min))
      (drgnx-signal--flush)
      (should (equal moved (list a)))
      (drgnx-signal--flush)
      (should (= 1 (length moved)))                 ; it stayed
      (set-buffer-modified-p nil))))

;;; The bus on the store (Task 10): window answers and `editor-changed' come from the state store.

(defvar drgnx-signal-test--store nil "What a store subscriber of these tests got, newest first.")
(defun drgnx-signal-test--on-store (data) (push data drgnx-signal-test--store))

(defvar drgnx-signal-test--frames nil "The frames a `drgnx-signal-window-functions' function got, newest first.")
(defun drgnx-signal-test--window-fn (frame) (push frame drgnx-signal-test--frames))

(defmacro drgnx-signal-test--with-store (&rest body)
  "BODY with a fresh store and bus (`drgnx-test-with-state'), one window on *scratch*, an empty log."
  (declare (indent 0))
  `(drgnx-test-with-state
     (setq drgnx-signal-test--store nil drgnx-signal-test--frames nil)
     (delete-other-windows)
     (switch-to-buffer "*scratch*")
     (unwind-protect (progn ,@body)
       (delete-other-windows)
       (switch-to-buffer "*scratch*"))))

(ert-deftest drgnx-signal/legacy-editor-changed-is-buffer-only ()
  "The store's `editor-changed' says which window; the bus's gets the buffer of the selected frame's MRU editor,
and only when it differs from the last one it got."
  (drgnx-signal-test--with-store
    (let ((legacy nil) (b (get-buffer-create "drgnx-signal-test-b")))
      (unwind-protect
          (progn
            (drgnx-state-subscribe 'editor-changed #'drgnx-signal-test--on-store)
            (drgnx-signal-subscribe 'editor-changed (lambda (buffer) (push buffer legacy)))
            (drgnx-signal--flush)
            (setq legacy nil drgnx-signal-test--store nil)
            (let* ((w1 (selected-window)) (w2 (split-window w1 nil 'right)))
              (select-window w2)                        ; the same buffer in another window
              (drgnx-signal--flush)
              (should (eq w2 (plist-get (car drgnx-signal-test--store) :window)))
              (should-not legacy)
              (switch-to-buffer b)
              (drgnx-signal--flush)
              (should (equal (list b) legacy))
              (select-window w1)
              (drgnx-signal--flush)
              (should (equal (list (get-buffer "*scratch*") b) legacy))))
        (kill-buffer b)))))

(ert-deftest drgnx-signal/editor-window-is-the-stores ()
  (drgnx-signal-test--with-store
    (let* ((w1 (selected-window)) (w2 (split-window w1 nil 'right)))
      (should (eq w1 (drgnx-signal-editor-window)))      ; the frame not recorded yet: observed now
      (should (eq w1 (drgnx-state-editor-window)))
      (should (eq w2 (drgnx-state-use-editor w2)))       ; chosen without selecting it
      (should (eq w1 (selected-window)))
      (should (eq w2 (drgnx-signal-editor-window)))
      (delete-window w2)                                 ; gone before the next observation: observed now
      (should (eq w1 (drgnx-signal-editor-window)))
      (should (eq w1 (drgnx-state-editor-window))))))

(ert-deftest drgnx-signal/editor-window-p-reads-the-role-table ()
  (drgnx-signal-test--with-store
    (let ((w (split-window nil nil 'below)))
      (drgnx-state-undefine-role 'bar)
      (set-window-parameter w 'drgnx-role 'bar)
      (should (drgnx-signal-editor-window-p w))          ; no module defined `bar': an editor window
      (drgnx-state-define-role 'bar)
      (should-not (drgnx-signal-editor-window-p w))
      (set-window-parameter w 'drgnx-role 'drgnx-signal-test-strip)
      (should (drgnx-signal-editor-window-p w))
      (drgnx-state-define-role 'drgnx-signal-test-strip)
      (should-not (drgnx-signal-editor-window-p w))
      (set-window-parameter w 'drgnx-role nil)
      (should (drgnx-signal-editor-window-p (selected-window)))
      (should-not (drgnx-signal-editor-window-p (minibuffer-window))))))

(ert-deftest drgnx-signal/frame-changed-from-selected-changed ()
  (drgnx-signal-test--with-store
    (let ((was-on drgnx-signal-mode) (seen nil))
      (unwind-protect
          (progn
            (drgnx-signal-mode 1)
            (drgnx-signal-subscribe 'frame-changed (lambda (frame) (push frame seen)))
            (drgnx-signal--flush)
            (setq seen nil)
            ;; another window of the same frame: no frame change
            (select-window (split-window nil nil 'right))
            (drgnx-state--emit 'selected-changed (list :frame (selected-frame) :window (selected-window)
                                                       :old-window (next-window) :old-frame (selected-frame)))
            (drgnx-signal--flush)
            (should-not seen)
            ;; the store saw another frame become the selected one
            (drgnx-state--emit 'selected-changed (list :frame (selected-frame) :window (selected-window)
                                                       :old-window nil :old-frame 'drgnx-signal-test-other))
            (should (drgnx-timer-active-p 'signal-flush))   ; the bus's `now' subscriber arms the flush…
            (should-not seen)
            (drgnx-signal--flush)                      ; …which says it
            (should (equal (list (selected-frame)) seen)))
        (unless was-on (drgnx-signal-mode -1))))))

(ert-deftest drgnx-signal/window-functions-run-from-the-observation ()
  (drgnx-signal-test--with-store
    (let ((was-on drgnx-signal-mode))
      (unwind-protect
          (with-suppressed-warnings ((obsolete drgnx-signal-window-functions))
            (should (get 'drgnx-signal-window-functions 'byte-obsolete-variable))
            (drgnx-signal-mode 1)
            (add-hook 'drgnx-signal-window-functions #'drgnx-signal-test--window-fn)
            (should-not (memq 'drgnx-signal--windows (default-value 'window-buffer-change-functions)))
            (should-not (memq 'drgnx-signal--schedule (default-value 'window-selection-change-functions)))
            (drgnx-state-sync)
            (setq drgnx-signal-test--frames nil)
            (let ((w (split-window nil nil 'right)))
              (drgnx-state-sync)                       ; the observation, before any flush or redisplay
              (should (equal (list (selected-frame)) drgnx-signal-test--frames))
              (setq drgnx-signal-test--frames nil)
              (select-window w)                        ; a selection changes no window
              (drgnx-state-sync)
              (should-not drgnx-signal-test--frames)))
        (remove-hook 'drgnx-signal-window-functions #'drgnx-signal-test--window-fn)
        (unless was-on (drgnx-signal-mode -1))))))

(ert-deftest drgnx-signal/flush-syncs-first ()
  (drgnx-signal-test--with-store
    (drgnx-state-subscribe 'windows-changed #'drgnx-signal-test--on-store)   ; the idle lane
    (drgnx-signal--flush)
    (setq drgnx-signal-test--store nil)
    (let ((w (split-window nil nil 'right)))           ; batch Emacs: no redisplay observes it
      (drgnx-signal--flush)
      (should (memq w (drgnx-state-windows (selected-frame))))
      (should (memq w (plist-get (car drgnx-signal-test--store) :windows))))))

(ert-deftest drgnx-signal/one-idle-flush ()
  (drgnx-signal-test--with-store
    (should-not (boundp 'drgnx-state--idle-timer))
    (drgnx-state-sync)
    (drgnx-state-subscribe 'windows-changed #'drgnx-signal-test--on-store)
    (split-window nil nil 'right)
    (drgnx-state-sync)                                 ; an idle call waits…
    (should-not drgnx-signal-test--store)
    (should (equal (assq 'signal-flush (drgnx-timer-pending)) '(signal-flush :core soon)))   ; …for the bus's one flush
    (drgnx-signal--flush)
    (should drgnx-signal-test--store)
    (should-not (drgnx-timer-active-p 'signal-flush))))

(ert-deftest drgnx-signal/the-flush-goes-when-the-bus-and-the-store-are-off ()
  ;; One `signal-flush' (`:core', so no module's net cancels it) serves the bus and the store's idle lane: the
  ;; first of the two modes to go keeps it, the last one cancels it, in either order.
  (drgnx-signal-test--with-store
    (let ((was-on drgnx-signal-mode))
      (unwind-protect
          (dolist (order '((drgnx-signal-mode drgnx-state-mode) (drgnx-state-mode drgnx-signal-mode)))
            (drgnx-state-mode 1)
            (drgnx-signal-mode 1)                      ; arms the flush
            (should (drgnx-timer-active-p 'signal-flush))
            (funcall (car order) -1)
            (should (drgnx-timer-active-p 'signal-flush))
            (funcall (cadr order) -1)
            (should-not (drgnx-timer-active-p 'signal-flush)))
        (drgnx-state-mode -1)
        (drgnx-signal-mode (if was-on 1 -1))))))

(ert-deftest drgnx-signal/the-store-alone-keeps-its-idle-flush ()
  ;; The bus turned off while a store idle call waits: the store is still on, so the call is made in the next pause.
  (drgnx-signal-test--with-store
    (let ((was-on drgnx-signal-mode))
      (unwind-protect
          (drgnx-test-with-clock ()
            (drgnx-state-mode 1)
            (drgnx-signal-mode 1)
            (drgnx-state-subscribe 'windows-changed #'drgnx-signal-test--on-store)
            (split-window nil nil 'right)
            (drgnx-state-sync)                         ; an idle call waits…
            (drgnx-signal-mode -1)                     ; …and the bus goes
            (should-not drgnx-signal-test--store)
            (drgnx-test-idle (* 2 drgnx-signal-delay))
            (should drgnx-signal-test--store)          ; …made all the same
            (should-not (drgnx-timer-active-p 'signal-flush))
            (drgnx-state-mode -1))
        (drgnx-state-mode -1)
        (drgnx-signal-mode (if was-on 1 -1))))))

(ert-deftest drgnx-signal/the-editor-window-variable-is-gone ()
  (let ((name (concat "drgnx-signal--" "editor-window")) (hits nil))
    (should-not (boundp (intern name)))
    (should-not (fboundp 'drgnx-signal--frame))
    (dolist (dir '("core" "wb" "modules" "harness" "test" "docs"))
      (dolist (file (directory-files-recursively (expand-file-name dir drgnx-dir) "\\.\\(el\\|eld\\|md\\)\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (when (search-forward name nil t) (push file hits)))))
    (should-not hits))
  (drgnx-signal-test--with-store
    (drgnx-signal--flush)
    (should-not (plist-member drgnx-signal--state :editor))
    (should-not (plist-member drgnx-signal--state :frame))))
