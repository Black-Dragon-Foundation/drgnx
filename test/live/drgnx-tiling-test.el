;;; drgnx-tiling-test.el --- live: the workbench under a tiling window manager (headless sway) -*- lexical-binding: t -*-
;; test-class: cond
;; Runs only in the sway tier (`bin/drgnx test --ui --compositor sway', or in the GUI container:
;; `bin/drgnx test --container --ui --compositor sway'); elsewhere it is skipped.  I11 is listed in
;; docs/guide/workbench.md.
(require 'ert)
(require 'seq)
(require 'drgnx-ui)

(defmacro drgnx-tiling--with (sess &rest body)
  "BODY with SESS a sway session (config=drgnx, one 1920x1080 output) whose editor shows a fixture file.
The output is wide enough for the docks' default widths (32 + 50 columns) in half of it: where they do not fit,
Emacs has to shrink them."
  (declare (indent 1))
  `(let* ((root (make-temp-file "drgnx-tiling" t))
          (file (expand-file-name "README.md" root))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (progn (write-region "README\n" nil file nil 'silent)
                    (drgnx-ui-start "drgnx" "1920x1080" 60 nil nil "sway")))
          (,sess (drgnx-ui-own-session (plist-get s :name))))
     (unwind-protect
         (progn
           (drgnx-ui-call ,sess (format "(progn (find-file %S) (defvar drgnx-tiling--f1 (selected-frame))
                                                (drgnx-uitest--json (list :ok t)))"
                                        file))
           (drgnx-ui-measure ,sess nil)
           ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(defun drgnx-tiling--emacs-cons (sess)
  "The window nodes (cons with a pid) of SESS's sway tree."
  (let ((todo (list (plist-get (drgnx-ui-wm sess) :tree))) found)
    (while todo
      (let ((node (pop todo)))
        (when (and (equal (plist-get node :type) "con") (integerp (plist-get node :pid)))
          (push node found))
        (setq todo (append (plist-get node :nodes) (plist-get node :floating_nodes) todo))))
    found))

(defun drgnx-tiling--measure (sess thunk)
  "The jank report of what happens in SESS while THUNK runs here and the session settles."
  ;; The first frame's report: after `make-frame' the new frame comes first in `frame-list'.
  (drgnx-ui-call sess "(progn (drgnx-uitest-measure-begin drgnx-tiling--f1) (drgnx-uitest--json (list :ok t)))")
  (let ((ended nil))
    (unwind-protect
        (progn
          (funcall thunk)
          (let* ((settled (drgnx-ui-wait sess 500 15))
                 (r (drgnx-ui-call sess "(drgnx-uitest-api-measure-end)")))
            (setq ended t)
            (append (list :settled (if settled t :false)) r)))
      (unless ended (ignore-errors (drgnx-ui-call sess "(drgnx-uitest-api-measure-end)" 5))))))

(defconst drgnx-tiling--probe
  "(drgnx-uitest--json
     (let* ((f drgnx-tiling--f1) (d (car (drgnx-wb--dock-windows f)))
            (p (drgnx-wb-area-window 'panel f)) (r (drgnx-wb-area-window 'right f)))
       (list :frame (vector (frame-pixel-width f) (frame-pixel-height f))
             :dock (if d (window-pixel-width d) 0) :panel (if p (window-pixel-height p) 0)
             :right (if r (window-pixel-width r) 0)
             :editors (vconcat (mapcar #'window-pixel-width
                                       (seq-filter #'drgnx-signal-editor-window-p (window-list f 'nomini)))))))"
  "The first frame's pixel size, its dock's and right dock's widths, its panel's height, its editors' widths.")

(ert-deftest drgnx-wm/i11-docks-keep-their-size-when-the-wm-resizes ()
  (skip-unless (equal (drgnx-ui-default-compositor) "sway"))
  (drgnx-tiling--with sess
    (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "M-j") (list :keys "C-M-b")))
    ;; Tab switches first: Emacs preserves a size only for the buffer it was set with.
    (drgnx-ui-measure sess (list (list :keys "M-x") (list :type "describe-function") (list :keys "RET") (list :type "car") (list :keys "RET")))   ; the panel's Help tab
    (drgnx-ui-call sess "(progn (drgnx-wb-define-tab 'right 'notes :title \"Notes\")
                                (drgnx-wb-area-show 'right 'notes (get-buffer-create \"*notes*\"))
                                (set-frame-parameter drgnx-tiling--f1 'name \"drgnx-i11-first\")
                                (drgnx-uitest--json (list :ok t)))")
    (drgnx-ui-measure sess nil)
    (let ((first (drgnx-ui-call sess drgnx-tiling--probe)) (bad nil))
      (should (> (plist-get first :dock) 0))
      (should (> (plist-get first :panel) 0))
      (should (> (plist-get first :right) 0))
      (dolist (step (list (cons "make-frame: sway halves the first frame"
                                (lambda () (drgnx-ui-call sess "(progn (make-frame) (drgnx-uitest--json (list :ok t)))")))
                          (cons "resize set width 900 px"
                                (lambda ()
                                  (let ((con (seq-find (lambda (n) (equal (plist-get n :name) "drgnx-i11-first"))
                                                       (drgnx-tiling--emacs-cons sess))))
                                    (should con)
                                    (should (eq t (plist-get (aref (drgnx-ui-wm-command
                                                                    sess (format "[con_id=%d] resize set width 900 px"
                                                                                 (plist-get con :id)))
                                                                   0)
                                                             :success))))))))
        (let* ((before (drgnx-ui-call sess drgnx-tiling--probe))
               (r (drgnx-tiling--measure sess (cdr step)))
               (after (drgnx-ui-call sess drgnx-tiling--probe)))
          (unless (and (not (equal (plist-get after :frame) (plist-get before :frame)))   ; the WM did resize it
                       (equal (plist-get after :dock) (plist-get first :dock))
                       (equal (plist-get after :panel) (plist-get first :panel))
                       (equal (plist-get after :right) (plist-get first :right))
                       (not (equal (plist-get after :editors) (plist-get before :editors)))
                       (> (plist-get r :wm_resizes) 0)
                       (= 0 (plist-get r :collateral_moves))
                       (= 0 (plist-get r :guard_violations)))
            (push (list (car step) :before before :after after :wm_resizes (plist-get r :wm_resizes)
                        :collateral (plist-get r :collateral) :causes (plist-get r :causes) :guard (plist-get r :guard))
                  bad))))
      (should-not bad))))

;;; drgnx-tiling-test.el ends here
