;;; drgnx-workbench-test.el --- live: the workbench dock in a GUI session (config=drgnx) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-live/the-dock-is-clean-and-pixel-stable ()
  ;; Real key presses: C-b shows the sidebar (VS Code profile) without taking focus; its width is
  ;; identical over 10 hide/show cycles; titles are drawn; no scroll bars in the dock.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" nil 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (let ((ws (seq-filter (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock)) (window-list nil 'nomini))))
                     (list :n (length ws)
                           :width (if ws (window-pixel-width (car ws)) 0)
                           :headers (vconcat (mapcar #'window-header-line-height ws))
                           :scrollbars (vconcat (mapcar (lambda (w) (if (nth 2 (window-scroll-bars w)) t :false)) ws))
                           :selected-dock (if (memq (selected-window) ws) t :false))))"))
    (unwind-protect
        (progn
          (drgnx-ui-measure sess (list (list :keys "C-b")))
          (let ((first (drgnx-ui-call sess probe)))
            (should (= (plist-get first :n) 2))
            (should (eq (plist-get first :selected-dock) :false))
            (should (seq-every-p (lambda (h) (> h 0)) (plist-get first :headers)))
            (should (seq-every-p (lambda (v) (eq v :false)) (plist-get first :scrollbars)))
            (dotimes (_ 10)
              (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-b"))))
            (should (= (plist-get (drgnx-ui-call sess probe) :width) (plist-get first :width)))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/panel-and-right-dock-are-pixel-stable ()
  ;; Real keys (VS Code profile): C-` toggles the panel, C-M-b the right dock — 10 times each, sizes
  ;; ±0 px, focus never taken; C-h f car RET puts *Help* in the panel's Help tab.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" nil 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (let ((p (drgnx-wb-area-window 'panel)) (r (drgnx-wb-area-window 'right)))
                     (list :panel (if p (window-pixel-height p) 0) :right (if r (window-pixel-width r) 0)
                           :panel-buffer (if p (buffer-name (window-buffer p)) \"\")
                           :selected-area (if (memq (selected-window) (list p r)) t :false))))"))
    (unwind-protect
        (progn
          (drgnx-ui-measure sess (list (list :keys "C-`") (list :keys "C-M-b")))
          (let ((first (drgnx-ui-call sess probe)))
            (should (> (plist-get first :panel) 0))
            (should (> (plist-get first :right) 0))
            (should (eq (plist-get first :selected-area) :false))
            (dotimes (_ 10)
              (drgnx-ui-measure sess (list (list :keys "C-`") (list :keys "C-`") (list :keys "C-M-b") (list :keys "C-M-b"))))
            (let ((again (drgnx-ui-call sess probe)))
              (should (= (plist-get again :panel) (plist-get first :panel)))
              (should (= (plist-get again :right) (plist-get first :right))))
            (drgnx-ui-measure sess (list (list :keys "C-h f") (list :type "car") (list :keys "RET")))
            (let ((help (drgnx-ui-call sess probe)))
              (should (equal (plist-get help :panel-buffer) "*Help*"))
              (should (= (plist-get help :panel) (plist-get first :panel))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))
