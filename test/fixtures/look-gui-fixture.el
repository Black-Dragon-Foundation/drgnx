;;; look-gui-fixture.el --- the look GUI tests' clean-session check -*- lexical-binding: t -*-
;; The look's GUI tests share one session.  A row that leaves the session changed (a frame size, a window split, a
;; tab bar, a mode, a theme, the default height) breaks a later row with a pixel that is merely somewhere else.  The
;; session is recorded when this file loads, before any row runs; `drgnx-look-gui-check-clean' at a row's start fails
;; naming what differs from it, so the leak is fixed in the row that made it, never by order or reruns.

(require 'ert)
(require 'cl-lib)

(defun drgnx-look-gui-session ()
  "What a look row may assume of the session: the root frame selected and focused, at its size, scale and bars, with
the frame parameters that move pixels; one window, its parameters (no tab or header line left on it); the modes the
rows turn on, off; no theme; the default height; the global hooks and mode lines as they were."
  (let ((f (selected-frame)))
    (list :frame-px (list (frame-pixel-width f) (frame-pixel-height f))
          :bars (mapcar (lambda (p) (cons p (frame-parameter f p))) '(tab-bar-lines tool-bar-lines menu-bar-lines))
          :frames (length (seq-filter #'frame-visible-p (frame-list)))
          :windows (length (window-list f 'nomini))
          :modes (mapcar (lambda (m) (cons m (and (boundp m) (symbol-value m) t)))
                         '(tab-bar-mode drgnx-state-mode drgnx-statusbar-mode))
          :themes custom-enabled-themes
          :default-height (face-attribute 'default :height)
          ;; the parameters that move pixels; nil is absent (Emacs cannot remove a parameter), and so is no extra
          ;; line spacing, which a frame reports as 0 once it has had some
          :params (seq-remove (lambda (c) (or (null (cdr c)) (equal c '(line-spacing . 0))))
                              (mapcar (lambda (p) (cons p (frame-parameter f p)))
                                      '(line-spacing internal-border-width child-frame-border-width left-fringe
                                                     right-fringe right-divider-width bottom-divider-width vertical-scroll-bars
                                                     horizontal-scroll-bars font drgnx-ui-scale fullscreen undecorated)))
          :hooks (mapcar (lambda (h) (cons h (and (boundp h) (default-value h))))
                         '(window-selection-change-functions window-buffer-change-functions window-state-change-functions
                                                             window-configuration-change-hook window-size-change-functions post-command-hook
                                                             pre-command-hook focus-in-hook tab-bar-format mode-line-format header-line-format
                                                             global-mode-string after-make-frame-functions))
          :focus (format "%S" after-focus-change-function)
          :sel (list (selected-window) (frame-focus-state f))
          ;; the harness's own label of a window it drove keys in (`drgnx-uitest-id') draws nothing
          :window-params (seq-remove (lambda (c) (or (null (cdr c)) (eq (car c) 'drgnx-uitest-id)))
                                     (window-parameters (frame-selected-window f)))
          :scale (list (and (fboundp 'frame-scale-factor) (frame-scale-factor f))
                       (and (fboundp 'glitnir-active-p) (glitnir-active-p))
                       (frame-parameter f 'drgnx-ui-scale)))))

(defvar drgnx-look-gui--clean (drgnx-look-gui-session)
  "The session as it was before the first look row (`drgnx-look-gui-session').")

(defun drgnx-look-gui-check-clean ()
  "Fail, naming the differences, unless the session is as it was before the first look row."
  (let ((now (drgnx-look-gui-session)) diffs)
    (cl-loop for (k v) on drgnx-look-gui--clean by #'cddr
             unless (equal v (plist-get now k))
             do (push (if (and (consp v) (consp (car-safe v)))
                          (list k (seq-difference (plist-get now k) v) :was (seq-difference v (plist-get now k)))
                        (list k :was v :now (plist-get now k)))
                      diffs))
    (when diffs (ert-fail (cons 'session-left-changed (nreverse diffs))))))

(defmacro drgnx-look-gui-deftest (name args &rest body)
  "`ert-deftest' NAME ARGS BODY for a look GUI row: the row starts with `drgnx-look-gui-check-clean', so a row that
an earlier one left something for fails naming it, before it reads a pixel.  BODY's docstring and keywords stay first."
  (declare (indent 2) (doc-string 3))
  (let (head)
    (when (and (stringp (car body)) (cdr body)) (push (pop body) head))
    (while (keywordp (car body)) (push (pop body) head) (push (pop body) head))
    `(ert-deftest ,name ,args ,@(nreverse head) (drgnx-look-gui-check-clean) ,@body)))

(provide 'drgnx-look-gui-fixture)
;;; look-gui-fixture.el ends here
