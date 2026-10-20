;;; drgnx-popup-test.el --- live: the popup lane in a GUI session (config=drgnx) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(defconst drgnx-live-popup--edges
  "(drgnx-uitest--json (list :edges (format \"%S\" (mapcar (lambda (w) (list (buffer-name (window-buffer w)) (window-pixel-edges w))) (window-list nil 'nomini)))
                             :geometry (format \"%S\" (mapcar #'window-pixel-edges (window-list nil 'nomini)))
                             :minibuffer (if (minibufferp (window-buffer (selected-window))) t :false)
                             :panel (if (drgnx-wb-area-window 'panel) (buffer-name (window-buffer (drgnx-wb-area-window 'panel))) \"\")))"
  "Every window's buffer and pixel edges, whether the minibuffer is selected, what the panel shows.")

(defmacro drgnx-live-popup--with (sess &rest body)
  (declare (indent 1))
  `(let* ((root (make-temp-file "drgnx-popup" t))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (drgnx-ui-start "drgnx" nil 30))
          (,sess (drgnx-ui-own-session (plist-get s :name))))
     (unwind-protect
         (progn
           (drgnx-ui-call ,sess "(progn (require 'transient)
                                        (transient-define-prefix drgnx-live-tr () [(\"a\" \"Do A\" ignore)])
                                        (keymap-global-set \"<f19>\" #'drgnx-live-tr)
                                        (drgnx-uitest--json (list :ok t)))")
           ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(defun drgnx-live-popup--no-trace (sess open close &optional borrowed)
  "OPEN then CLOSE (key strings): every window's edges and buffer identical before and after.
BORROWED: while open, no window moved either (the popup is in the panel's window)."
  (let* ((r (drgnx-ui-call sess drgnx-live-popup--edges)) (before (plist-get r :edges)))
    (drgnx-ui-measure sess (list (list :keys open)))
    (let ((open-r (drgnx-ui-call sess drgnx-live-popup--edges)))
      (should-not (equal before (plist-get open-r :edges)))                 ; it showed
      (when borrowed (should (equal (plist-get r :geometry) (plist-get open-r :geometry)))))
    (drgnx-ui-measure sess (list (list :keys close)))
    (should (equal before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges)))))

(ert-deftest drgnx-live/transient-leaves-no-trace-with-and-without-the-panel ()
  (drgnx-live-popup--with sess
    (drgnx-live-popup--no-trace sess "<f19>" "C-g")
    (drgnx-ui-measure sess (list (list :keys "C-`")))           ; the panel open: borrowed and given back
    (drgnx-live-popup--no-trace sess "<f19>" "C-g" t)))

(ert-deftest drgnx-live/completions-leave-no-trace ()
  (drgnx-live-popup--with sess
    (let ((before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges)))
      (drgnx-ui-measure sess (list (list :keys "M-x") (list :type "describe-") (list :keys "TAB")))
      (drgnx-ui-measure sess (list (list :keys "C-g")))
      (should (equal before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges))))))

(ert-deftest drgnx-live/help-from-the-minibuffer-keeps-it-focused ()
  (drgnx-live-popup--with sess
    (drgnx-ui-measure sess (list (list :keys "M-x") (list :keys "<help> f") (list :type "car") (list :keys "RET")))
    (let ((r (drgnx-ui-call sess drgnx-live-popup--edges)))
      (should (equal (plist-get r :panel) "*Help*"))
      (should (eq (plist-get r :minibuffer) t)))
    (drgnx-ui-measure sess (list (list :keys "C-g")))))

(ert-deftest drgnx-live/completions-in-the-panel-are-filled-and-given-back ()
  ;; The panel open: *Completions* borrows it, has candidates (its body-function ran), and leaving
  ;; the minibuffer (which restores the window configuration) gives the panel back with its tab row.
  (drgnx-live-popup--with sess
    (drgnx-ui-measure sess (list (list :keys "C-`")))
    (let ((before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges))
          (q "(drgnx-uitest--json (list :size (if (get-buffer \"*Completions*\") (buffer-size (get-buffer \"*Completions*\")) 0)
                                         :active (if (drgnx-popup-active-p) t :false)
                                         :tabs (if (window-parameter (drgnx-wb-area-window 'panel) 'header-line-format) t :false)))"))
      (drgnx-ui-measure sess (list (list :keys "M-x") (list :type "describe-") (list :keys "TAB")))
      (should (> (plist-get (drgnx-ui-call sess q) :size) 0))
      (drgnx-ui-measure sess (list (list :keys "C-g")))
      (let ((r (drgnx-ui-call sess q)))
        (should (eq (plist-get r :active) :false))
        (should (eq (plist-get r :tabs) t)))
      (should (equal before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges))))))
