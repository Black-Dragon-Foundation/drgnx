;;; drgnx-popup-test.el --- live: the popup lane in a GUI session (config=drgnx) -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-ui)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-live-popup--edges
  "(drgnx-uitest--json (list :edges (format \"%S\" (mapcar (lambda (w) (list (buffer-name (window-buffer w)) (window-pixel-edges w))) (window-list nil 'nomini)))
                             :geometry (format \"%S\" (mapcar #'window-pixel-edges (window-list nil 'nomini)))
                             :minibuffer (if (minibufferp (window-buffer (selected-window))) t :false)
                             :panel (if (drgnx-wb-area-window 'panel) (buffer-name (window-buffer (drgnx-wb-area-window 'panel))) \"\")
                             :shown (if (let ((w (drgnx-popup--window))) (and w (frame-visible-p (window-frame w)))) t :false)))"
  "Every window's buffer and pixel edges, whether the minibuffer is selected, what the panel shows, whether a popup
is on screen (in a window of the frame, or under Glitnir in the lane's child frame).")

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
           (drgnx-ui-wait-start-page ,sess)
           ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(defun drgnx-live-popup--measure (session actions)
  "`drgnx-ui-measure' of ACTIONS in SESSION; the test fails when the session did not settle (the report's :settled)."
  (let ((report (drgnx-ui-measure session actions)))
    (should (eq (plist-get report :settled) t))
    report))

(defun drgnx-live-popup--no-trace (sess open close &optional borrowed)
  "OPEN then CLOSE (key strings): every window's edges and buffer identical before and after.
BORROWED: while open, no window moved either (the popup is in the panel's window)."
  (let* ((r (drgnx-ui-call sess drgnx-live-popup--edges)) (before (plist-get r :edges)))
    (drgnx-live-popup--measure sess(list (list :keys open)))
    (let ((open-r (drgnx-ui-call sess drgnx-live-popup--edges)))
      (should (eq t (plist-get open-r :shown)))                              ; it showed
      (when borrowed (should (equal (plist-get r :geometry) (plist-get open-r :geometry)))))
    (drgnx-live-popup--measure sess(list (list :keys close)))
    (let ((after (drgnx-ui-call sess drgnx-live-popup--edges)))
      (should (eq :false (plist-get after :shown)))
      (should (equal before (plist-get after :edges))))))

(ert-deftest drgnx-live/transient-leaves-no-trace-with-and-without-the-panel ()
  (drgnx-live-popup--with sess
    (drgnx-live-popup--no-trace sess "<f19>" "C-g")
    (drgnx-live-popup--measure sess(list (list :keys "C-`")))           ; the panel open: borrowed and given back
    (drgnx-live-popup--no-trace sess "<f19>" "C-g" t)))

(ert-deftest drgnx-live/completions-leave-no-trace ()
  (drgnx-live-popup--with sess
    (let ((before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges)))
      (drgnx-live-popup--measure sess(list (list :keys "M-x") (list :type "describe-") (list :keys "TAB")))
      (drgnx-live-popup--measure sess(list (list :keys "C-g")))
      (should (equal before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges))))))

(ert-deftest drgnx-live/help-from-the-minibuffer-keeps-it-focused ()
  (drgnx-live-popup--with sess
    (drgnx-live-popup--measure sess(list (list :keys "M-x") (list :keys "<help> f") (list :type "car") (list :keys "RET")))
    (let ((r (drgnx-ui-call sess drgnx-live-popup--edges)))
      (should (equal (plist-get r :panel) "*Help*"))
      (should (eq (plist-get r :minibuffer) t)))
    (drgnx-live-popup--measure sess(list (list :keys "C-g")))))

(ert-deftest drgnx-live/completions-in-the-panel-are-filled-and-given-back ()
  ;; The panel open: *Completions* borrows it (under Glitnir: shows in the lane's child frame), has candidates (its
  ;; body-function ran), and leaving the minibuffer ends it and gives the panel back with its tab row.
  (drgnx-live-popup--with sess
    (drgnx-live-popup--measure sess(list (list :keys "C-`")))
    (let ((before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges))
          (q "(drgnx-uitest--json (list :size (if (get-buffer \"*Completions*\") (buffer-size (get-buffer \"*Completions*\")) 0)
                                         :active (if (drgnx-popup-active-p) t :false)
                                         :tabs (if (window-parameter (drgnx-wb-area-window 'panel) 'header-line-format) t :false)))"))
      (drgnx-live-popup--measure sess(list (list :keys "M-x") (list :type "describe-") (list :keys "TAB")))
      (should (> (plist-get (drgnx-ui-call sess q) :size) 0))
      (drgnx-live-popup--measure sess(list (list :keys "C-g")))
      (let ((r (drgnx-ui-call sess q)))
        (should (eq (plist-get r :active) :false))
        (should (eq (plist-get r :tabs) t)))
      (should (equal before (plist-get (drgnx-ui-call sess drgnx-live-popup--edges) :edges))))))
