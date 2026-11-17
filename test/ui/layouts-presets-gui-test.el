;;; layouts-presets-gui-test.el --- GUI test: the Work + Code layout on two monitors and on one (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Work + Code arranges this window as Work and a second window as Code: on the second monitor when the session has two
;; (`DRGNX_UI_MONITORS=2'), else on the one monitor there is.  The one-monitor row hides the second monitor from
;; `display-monitor-attributes-list' in the test only.  The rows run on a frame of their own with the grid fixture; the
;; frames they make are deleted after.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-layouts-presets--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-layouts-presets--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-layouts-presets--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-layouts-presets--repo) nil t)
(require 'drgnx-grid-frames)
(require 'drgnx-layouts)

(defmacro drgnx-ui-layouts-presets--with (&rest body)
  "BODY on a frame of its own (`frame') with the grid fixture, `drgnx-grid-mode' on, an empty stack, no layout and a
temp state dir (the projects' layouts); every frame BODY made deleted after."
  (declare (indent 0))
  `(progn
     (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
     (let* ((state (make-temp-file "drgnx-ui-layouts" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
            (frames (frame-list)) (selected (selected-frame)) (drgnx-grid--stack nil)
            (frame (make-frame '((width . 160) (height . 50)))))
       (unwind-protect
           (with-selected-frame frame
             (drgnx-grid-test--with
               (let ((was drgnx-grid-mode))
                 (unless was (drgnx-grid-mode 1))
                 (unwind-protect
                     (progn (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p frame)) :secs 10
                                             :what "the frame mapped")
                            (dolist (p '(drgnx-layouts-current drgnx-layouts-state drgnx-layouts-previous
                                                               drgnx-layouts-zen-return drgnx-layouts-project))
                              (set-frame-parameter frame p nil))
                            ,@body)
                   (drgnx-timer-cancel '(layouts-save . "global"))   ; the store's write waits 2 s: not this file's
                   (unless was (drgnx-grid-mode -1))))))
         (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
         (when (frame-live-p selected) (select-frame selected))
         (delete-directory state t)))))

(defun drgnx-ui-layouts-presets--second (frame)
  "The second window Work + Code made beside FRAME."
  (seq-find (lambda (f) (and (not (eq f frame)) (frame-parameter f 'drgnx-layouts-second))) (frame-list)))

(defun drgnx-ui-layouts-presets--right (frame)
  "What FRAME's tile docked right shows."
  (plist-get (cdr (seq-find (lambda (l) (eq (plist-get (cdr l) :dock) 'right)) (drgnx-grid-tree-leaves (drgnx-grid-tree frame))))
             :shown))

(defun drgnx-ui-layouts-presets--monitor (frame)
  "The name of the monitor FRAME is on."
  (alist-get 'name (frame-monitor-attributes frame)))

(ert-deftest drgnx-ui-layouts-presets/work-and-code-uses-two-monitors ()
  :tags '(:compositor)
  (drgnx-ui-layouts-presets--with
    (let ((monitors (display-monitor-attributes-list)))
      (unless (cdr monitors) (ert-skip "needs two monitors (DRGNX_UI_MONITORS=2)"))
      (drgnx-layouts-apply 'work-and-code)
      (let ((second (drgnx-ui-layouts-presets--second frame)))
        (should (frame-live-p second))
        (should (eq 'work-detail (drgnx-ui-layouts-presets--right frame)))
        (should (eq 'agents-side (drgnx-ui-layouts-presets--right second)))
        (drgnx-test-wait (lambda () (redisplay t)
                           (equal (drgnx-ui-layouts-presets--monitor second) (alist-get 'name (cadr monitors))))
                         :secs 10 :what "the second window on the second monitor")
        ;; again: the same second window, no third
        (let ((n (length (frame-list))))
          (drgnx-layouts-apply 'work-and-code)
          (should (= n (length (frame-list))))
          (should (eq second (drgnx-ui-layouts-presets--second frame))))))))

(ert-deftest drgnx-ui-layouts-presets/one-monitor-two-frames ()
  :tags '(:compositor)
  (drgnx-ui-layouts-presets--with
    (let* ((all (display-monitor-attributes-list)))
      (cl-letf (((symbol-function 'display-monitor-attributes-list) (lambda (&rest _) (list (car all)))))
        (drgnx-layouts-apply 'work-and-code)
        (let ((second (drgnx-ui-layouts-presets--second frame)))
          (should (frame-live-p second))
          (should (eq 'agents-side (drgnx-ui-layouts-presets--right second)))
          (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p second)) :secs 10 :what "the second window mapped")
          (should (equal (drgnx-ui-layouts-presets--monitor second) (drgnx-ui-layouts-presets--monitor frame))))))))
