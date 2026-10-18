;;; drgnx-compositor-test.el --- live: sessions under headless sway, Xvfb and Xvfb with i3 -*- lexical-binding: t -*-
;; Each test runs only in its compositor's tier (`bin/drgnx test --ui --compositor sway|x11|i3', or in the GUI
;; container: `bin/drgnx test --container --ui --compositor C'); elsewhere it is skipped.
(require 'ert)
(require 'seq)
(require 'drgnx-ui)

(defmacro drgnx-wm-test--with (sess compositor &rest body)
  "BODY with SESS a two-monitor (1280x800 each) minimal session under COMPOSITOR, in a state root of its own."
  (declare (indent 2))
  `(let* ((root (make-temp-file "drgnx-wm" t))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (drgnx-ui-start "minimal" "1280x800" 60 nil 2 ,compositor))
          (,sess (drgnx-ui-own-session (plist-get s :name))))
     (unwind-protect (progn ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(defun drgnx-wm-test--eval (sess form)
  "FORM's value (any Lisp value, printed) from the session."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form)) :v))))

(defun drgnx-wm-test--windows (node &optional output)
  "The window nodes of a sway/i3 tree NODE (those with a pid or an X window), each as (OUTPUT-NAME . NODE)."
  (let* ((output (if (equal (plist-get node :type) "output") (plist-get node :name) output))
         (kids (append (plist-get node :nodes) (plist-get node :floating_nodes) nil)))
    (append (and (equal (plist-get node :type) "con")
                 (or (integerp (plist-get node :pid)) (integerp (plist-get node :window)))
                 (list (cons output node)))
            (seq-mapcat (lambda (k) (drgnx-wm-test--windows k output)) kids))))

(defun drgnx-wm-test--outputs (tree)
  "The names of TREE's outputs, without sway's and i3's internal `__i3'."
  (seq-remove (lambda (n) (string-prefix-p "__" n))
              (mapcar (lambda (o) (plist-get o :name)) (append (plist-get tree :nodes) nil))))

(defconst drgnx-wm-test--monitors
  "(sort (mapcar (lambda (m) (alist-get 'geometry m)) (display-monitor-attributes-list))
         (lambda (a b) (< (car a) (car b))))"
  "The session's monitors' geometries, left to right (Emacs' own order is not stable).")

(ert-deftest drgnx-wm/a-sway-session-starts-tiles-emacs-and-answers-ui-wm ()
  (skip-unless (equal (drgnx-ui-default-compositor) "sway"))
  (drgnx-wm-test--with sess "sway"
    (let* ((wm (drgnx-ui-wm sess))
           (tree (plist-get wm :tree))
           (pid (drgnx-wm-test--eval sess "(emacs-pid)"))
           (emacs (seq-filter (lambda (w) (eql (plist-get (cdr w) :pid) pid)) (drgnx-wm-test--windows tree))))
      (should (equal (plist-get wm :wm) "sway"))
      (should (equal (sort (drgnx-wm-test--outputs tree) #'string<) '("HEADLESS-1" "HEADLESS-2")))
      ;; one Emacs window, tiled on the first output (it fills it: no border, no bar)
      (should (= (length emacs) 1))
      (should (equal (car (car emacs)) "HEADLESS-1"))
      (should (equal (plist-get (plist-get (cdr (car emacs)) :rect) :width) 1280))
      (should (equal (drgnx-wm-test--eval sess drgnx-wm-test--monitors) '((0 0 1280 800) (1280 0 1280 800))))
      ;; the test-only command reaches this session's sway, and only it
      (should (eq (plist-get (aref (drgnx-ui-wm-command sess "nop") 0) :success) t)))))

(ert-deftest drgnx-wm/an-x11-session-has-two-monitors ()
  (skip-unless (member (drgnx-ui-default-compositor) '("x11" "i3")))
  (let ((compositor (drgnx-ui-default-compositor)))
    (drgnx-wm-test--with sess compositor
      (should (equal (drgnx-wm-test--eval sess "window-system") 'x))
      (should (equal (drgnx-wm-test--eval sess drgnx-wm-test--monitors) '((0 0 1280 800) (1280 0 1280 800))))
      (let ((wm (drgnx-ui-wm sess)))
        (if (equal compositor "x11")
            (should (equal wm '(:wm "none")))
          ;; i3 manages the frame: its X window is in i3's tree, on the first monitor
          (let* ((xid (string-to-number (drgnx-wm-test--eval sess "(frame-parameter nil 'outer-window-id)")))
                 (emacs (seq-filter (lambda (w) (eql (plist-get (cdr w) :window) xid))
                                    (drgnx-wm-test--windows (plist-get wm :tree)))))
            (should (equal (plist-get wm :wm) "i3"))
            (should (member "XVFB-2" (drgnx-wm-test--outputs (plist-get wm :tree))))
            (should (= (length emacs) 1))
            (should (equal (car (car emacs)) "XVFB-1"))))))))

;;; drgnx-compositor-test.el ends here
