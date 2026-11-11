;;; view-env-test.el --- batch tests: what the editor tells the hub about a hub-fed view (wb/drgnx-view-env.el) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'drgnx-view-env)

(defvar drgnx-view-env-test--sent nil "What the module sent, newest first: (METHOD . PARAMS).")
(defvar drgnx-view-env-test--palette '(("edge" "#111111")) "The palette the stubbed reader returns.")
(defvar drgnx-view-env-test--gui nil "Windows the stubbed facts call GUI; the others are a terminal's.")

(defun drgnx-view-env-test--facts (window &optional buffer)
  "Stubbed facts: a GUI class for the windows in `drgnx-view-env-test--gui', with a ui font whose size follows
BUFFER's `text-scale' (default: WINDOW's buffer)."
  (let ((factor (drgnx-view-env--scale-factor (or buffer (window-buffer window)))))
    (if (memq window drgnx-view-env-test--gui)
        (list :display "gui" :scale 1.0 :cell '(8 16)
              :fonts (list (list "ui" "/f/Inter.ttf" 0 (* 13.0 factor) 12.0 3.0 7.0 4.0 "Inter-13")))
      (list :display "tty" :scale 1.0 :cell '(1 1) :fonts nil))))

(defmacro drgnx-view-env-test--with (&rest body)
  "BODY with the module's state fresh, its sending captured, the facts and palette stubbed, a buffer `buf' shown in
the selected window (a GUI class) and torn down after."
  (declare (indent 0))
  `(let ((drgnx-view-env--views (make-hash-table :test #'equal))
         (drgnx-view-env--sent (make-hash-table :test #'equal))
         (drgnx-view-env--glyphs (make-hash-table :test #'equal))
         (drgnx-view-env--hooked nil)
         (drgnx-view-env-test--sent nil)
         (drgnx-view-env-test--palette '(("edge" "#111111")))
         (drgnx-view-env-send-function (lambda (m p) (push (cons m p) drgnx-view-env-test--sent)))
         (buf (generate-new-buffer " *view-env-test*")))
     (cl-letf (((symbol-function 'drgnx-view-env--window-facts) #'drgnx-view-env-test--facts)
               ((symbol-function 'drgnx-view-env--palette) (lambda () drgnx-view-env-test--palette))
               ((symbol-function 'drgnx-view-env--windows) (lambda (b) (get-buffer-window-list b nil t))))
       (save-window-excursion
         (delete-other-windows)
         (switch-to-buffer buf)
         (let ((drgnx-view-env-test--gui (list (selected-window))))
           (unwind-protect (progn ,@body)
             (drgnx-view-env-teardown)
             (kill-buffer buf)))))))

(defun drgnx-view-env-test--envs ()
  "The `view/env' params sent, oldest first."
  (mapcar #'cdr (reverse (cl-remove-if-not (lambda (s) (equal (car s) "view/env")) drgnx-view-env-test--sent))))

(ert-deftest drgnx-view-env/text-scale-changes-the-class ()
  (drgnx-view-env-test--with
    (drgnx-view-env-register "v" buf)
    (with-current-buffer buf (text-scale-set 2))
    (let ((envs (drgnx-view-env-test--envs)))
      (should (= 2 (length envs)))
      (should-not (equal (plist-get (nth 0 envs) :class) (plist-get (nth 1 envs) :class)))
      ;; the new class's font is the scaled one, measured in the view's buffer
      (should (> (nth 3 (car (plist-get (nth 1 envs) :fonts))) (nth 3 (car (plist-get (nth 0 envs) :fonts)))))
      ;; a new class starts at epoch 1, and the old one is forgotten
      (should (= 1 (plist-get (nth 1 envs) :epoch)))
      (should (equal (list (plist-get (nth 1 envs) :class)) (drgnx-view-env-classes "v"))))))

(ert-deftest drgnx-view-env/theme-change-sends-palette-once ()
  (drgnx-view-env-test--with
    (drgnx-view-env-register "v" buf)
    (setq drgnx-view-env-test--sent nil
          drgnx-view-env-test--palette '(("edge" "#222222")))
    (run-hook-with-args 'enable-theme-functions 'some-theme)
    (should (= 1 (length (drgnx-view-env-test--envs))))
    (should (equal '(("edge" "#222222")) (plist-get (car (drgnx-view-env-test--envs)) :palette)))
    ;; a second hook run with nothing changed sends nothing
    (run-hook-with-args 'disable-theme-functions 'some-theme)
    (should (= 1 (length (drgnx-view-env-test--envs))))))

(ert-deftest drgnx-view-env/two-frames-two-classes ()
  (drgnx-view-env-test--with
    (let ((other (split-window)))
      (set-window-buffer other buf)
      ;; the selected window is a GUI frame's, OTHER a terminal's
      (drgnx-view-env-register "v" buf)
      (let ((envs (drgnx-view-env-test--envs)))
        (should (= 2 (length envs)))
        (should (equal '("gui" "tty") (sort (mapcar (lambda (e) (plist-get e :display)) envs) #'string<)))
        (should (= 2 (length (delete-dups (mapcar (lambda (e) (plist-get e :class)) envs)))))))))

(ert-deftest drgnx-view-env/a-view-in-two-classes-gets-a-buffer-per-class ()
  "A view whose buffer has a twin function, shown in two classes (two monitors at two scales): the windows of the class
the buffer is paired with show it, the other class's a twin paired with that class (its rows come there); once that
window's class is the buffer's again, it shows the buffer and the twin goes, and with the view the twins go."
  (require 'drgnx-view)
  (drgnx-view-env-test--with
    (let ((other (split-window)) (made nil))
      (set-window-buffer other buf)
      (with-current-buffer buf
        (drgnx-view-patch-attach "v" "none")
        (setq-local drgnx-view-patch-twin-function
                    (lambda (class)
                      (let ((tw (generate-new-buffer " *view-env-twin*")))
                        (with-current-buffer tw (drgnx-view-patch-attach "v" class))
                        (push tw made)
                        tw))))
      ;; the selected window is a GUI frame's, OTHER a terminal's
      (drgnx-view-env-register "v" buf)
      (let* ((pair (lambda (b) (buffer-local-value 'drgnx-view-patch b)))
             (class-of (lambda (w) (drgnx-view-env--class (drgnx-view-env-test--facts w buf))))
             (twin (car made)))
        (should (= 1 (length made)))
        (should (eq buf (window-buffer (selected-window))))
        (should (eq twin (window-buffer other)))
        (should (equal (funcall class-of (selected-window)) (drgnx-view-patch-class (funcall pair buf))))
        (should (equal (funcall class-of other) (drgnx-view-patch-class (funcall pair twin))))
        (should (eq twin (gethash (cons "v" (funcall class-of other)) drgnx-view-patch--buffers)))
        ;; both classes' envs went out, each a new pair
        (should (= 2 (length (drgnx-view-env-test--envs))))
        ;; OTHER moves to the buffer's class: it shows the buffer, the twin goes
        (push other drgnx-view-env-test--gui)
        (drgnx-view-env-update "v")
        (should (eq buf (window-buffer other)))
        (should-not (buffer-live-p twin))
        ;; and back: a new twin, which goes with the view
        (setq drgnx-view-env-test--gui (list (selected-window)))
        (drgnx-view-env-update "v")
        (should (= 2 (length made)))
        (should (eq (car made) (window-buffer other)))
        (drgnx-view-env-unregister "v")
        (should-not (buffer-live-p (car made)))))))

(defvar-local drgnx-view-env-test-state nil "A module's state, as a twin copies it.")
(defvar-local drgnx-view-env-test-mark nil "A module's marker, which a twin never takes.")
(define-derived-mode drgnx-view-env-test-mode special-mode "Env test")

(ert-deftest drgnx-view-env/a-twin-takes-the-view-buffers-state-before-each-command ()
  "`drgnx-view-env-twin': a buffer in the view buffer's mode, attached to (view, CLASS), marked a twin of it, with its
state (the locals of the prefixes, a marker left out) as made and again before each command; SETUP runs in it."
  (require 'drgnx-view)
  (let ((buf (generate-new-buffer " *view-env-twin-test*")) tw ran)
    (unwind-protect
        (with-current-buffer buf
          (drgnx-view-env-test-mode)
          (drgnx-view-patch-attach "tv" "a")
          (setq-local drgnx-view-env-test-state 1 drgnx-view-env-test-mark (point-marker))
          (setq tw (drgnx-view-env-twin "b" '("drgnx-view-env-test-") (lambda () (setq ran (current-buffer)))))
          (should (eq ran tw))
          (with-current-buffer tw
            (should (eq major-mode 'drgnx-view-env-test-mode))
            (should (equal "b" (drgnx-view-patch-class drgnx-view-patch)))
            (should (eq buf (drgnx-view-patch-twin-p)))
            (should (= 1 drgnx-view-env-test-state))
            (should-not drgnx-view-env-test-mark))
          (should (eq tw (gethash (cons "tv" "b") drgnx-view-patch--buffers)))
          (should-not (drgnx-view-patch-twin-p buf))
          (setq drgnx-view-env-test-state 2)
          (with-current-buffer tw (run-hooks 'pre-command-hook) (should (= 2 drgnx-view-env-test-state))))
      (when (buffer-live-p tw) (kill-buffer tw))
      (kill-buffer buf))))

(ert-deftest drgnx-view-env/two-windows-one-class-send-the-narrowest ()
  (drgnx-view-env-test--with
    (let ((other (split-window nil nil t)))
      (set-window-buffer other buf)
      (push other drgnx-view-env-test--gui)
      (adjust-window-trailing-edge (selected-window) 5 t)
      (drgnx-view-env-register "v" buf)
      (let ((envs (drgnx-view-env-test--envs)))
        (should (= 1 (length envs)))
        (should (= (min (window-body-width (selected-window) t) (window-body-width other t))
                   (plist-get (car envs) :width_px)))
        (should (/= (window-body-width (selected-window) t) (window-body-width other t)))))))

(ert-deftest drgnx-view-env/env-change-bumps-the-epoch ()
  (drgnx-view-env-test--with
    (drgnx-view-env-register "v" buf)
    (let ((class (plist-get (car (drgnx-view-env-test--envs)) :class)))
      (should (= 1 (drgnx-view-env-epoch "v" class)))
      (setq drgnx-view-env-test--palette '(("edge" "#333333")))
      (drgnx-view-env-update "v")
      (should (= 2 (drgnx-view-env-epoch "v" class)))
      ;; nothing changed: nothing sent, the epoch stays
      (let ((n (length drgnx-view-env-test--sent)))
        (drgnx-view-env-update "v")
        (should (= n (length drgnx-view-env-test--sent))))
      ;; a width change alone is sent, at the same epoch
      ;; (the new window shows another buffer: only the view's window narrows)
      (let ((other (split-window nil nil t)))
        (set-window-buffer other (messages-buffer))
        (drgnx-view-env-update "v")
        (let ((last (car (last (drgnx-view-env-test--envs)))))
          (should (= 2 (plist-get last :epoch)))
          (should (= (window-body-width (selected-window) t) (plist-get last :width_px))))))))

(ert-deftest drgnx-view-env/glyph-asks-are-cached-per-font ()
  (drgnx-view-env-test--with
    (drgnx-view-env-register "v" buf)
    (let ((measured 0))
      (cl-letf (((symbol-function 'drgnx-view-env--measure) (lambda (_b _f _c) (cl-incf measured) 9)))
        (dotimes (_ 2)
          (drgnx-view-env-event "view-glyphs" (list :view "v" :class "c" :ask '(("ui" "→") ("ui" "✓")))))
        (should (= 2 measured))
        (let ((answers (cl-remove-if-not (lambda (s) (equal (car s) "view/glyphs")) drgnx-view-env-test--sent)))
          (should (= 2 (length answers)))
          (should (equal '(("ui" "→" 9) ("ui" "✓" 9)) (plist-get (cdar answers) :glyphs))))))))

(ert-deftest drgnx-view-env/teardown-leaves-no-hooks ()
  (drgnx-view-env-test--with
    (drgnx-view-env-register "v" buf)
    (should (memq #'drgnx-view-env--theme-changed enable-theme-functions))
    (drgnx-view-env-teardown)
    (dolist (h '(enable-theme-functions disable-theme-functions window-size-change-functions
                                        window-buffer-change-functions drgnx-hub-connected-functions drgnx-hub-event-functions))
      (should-not (memq #'drgnx-view-env--theme-changed (default-value h)))
      (should-not (memq #'drgnx-view-env--size-changed (default-value h)))
      (should-not (memq #'drgnx-view-env--reconnected (default-value h)))
      (should-not (memq #'drgnx-view-env-event (default-value h))))
    (with-current-buffer buf
      (should-not (memq #'drgnx-view-env--text-scale text-scale-mode-hook))
      (should-not (memq #'drgnx-view-env--buffer-killed kill-buffer-hook)))
    (should (zerop (hash-table-count drgnx-view-env--views)))
    (should (zerop (hash-table-count drgnx-view-env--sent)))))

(ert-deftest drgnx-view-env/reconnect-resends-env-before-subscribe ()
  (drgnx-view-env-test--with
    (drgnx-view-env-register "v" buf (lambda (view) (push (cons "subscribe" view) drgnx-view-env-test--sent)))
    (setq drgnx-view-env-test--sent nil)
    (run-hooks 'drgnx-hub-connected-functions)
    (should (equal '("view/env" "subscribe") (mapcar #'car (reverse drgnx-view-env-test--sent))))
    ;; the restarted hub holds no env: the same epoch is sent again, as the hub's first for the pair
    (should (= 1 (plist-get (cdr (car (last drgnx-view-env-test--sent))) :epoch)))))
