;;; view-env-test.el --- batch tests: what the editor tells the hub about a hub-fed view (wb/drgnx-view-env.el) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'drgnx-view-env)

(defvar drgnx-view-env-test--sent nil "What the module sent, newest first: (METHOD . PARAMS).")
(defvar drgnx-view-env-test--palette '(("edge" "#111111")) "The palette the stubbed reader returns.")
(defvar drgnx-view-env-test--gui nil "Windows the stubbed facts call GUI; the others are a terminal's.")

(defun drgnx-view-env-test--facts (window)
  "Stubbed facts: a GUI class for the windows in `drgnx-view-env-test--gui', with a ui font whose size follows the
buffer's `text-scale'."
  (let ((factor (drgnx-view-env--scale-factor (window-buffer window))))
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
