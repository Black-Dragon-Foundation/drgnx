;;; drgnx-workbench-test.el --- live: the workbench dock in a GUI session (config=drgnx) -*- lexical-binding: t -*-
;; test-class: cond
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
            (should (= (plist-get first :n) 3))                       ; Buffers, Explorer, Outline
            (should (eq (plist-get first :selected-dock) :false))
            (should (seq-every-p (lambda (h) (> h 0)) (plist-get first :headers)))
            (should (seq-every-p (lambda (v) (eq v :false)) (plist-get first :scrollbars)))
            (dotimes (_ 10)
              (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-b"))))
            (should (= (plist-get (drgnx-ui-call sess probe) :width) (plist-get first :width)))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/the-dock-gives-the-editor-groups-their-sizes-back ()
  ;; Two editor groups side by side: C-b hides the sidebar and C-b shows it again; each group is as wide as it was
  ;; (the sidebar's width comes back from where it went, not out of one group).
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" "1400x850" 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (list :groups (vconcat (mapcar #'window-pixel-width (drgnx-groups-list)))
                         :dock (if (seq-some (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock))
                                             (window-list nil 'nomini))
                                   t :false)))"))
    (unwind-protect
        (progn
          (drgnx-ui-call sess "(progn (drgnx-wb-show-sidebar) (drgnx-wb-focus-editor) (drgnx-groups-split-right)
                                      (drgnx-uitest--json (list :ok t)))")
          (drgnx-ui-measure sess nil)
          (let ((before (drgnx-ui-call sess probe)))
            (should (eq (plist-get before :dock) t))
            (should (= (length (plist-get before :groups)) 2))
            (drgnx-ui-measure sess (list (list :keys "C-b")))
            (let ((hidden (drgnx-ui-call sess probe)))
              (should (eq (plist-get hidden :dock) :false))
              (message "dock-split before %S hidden %S" before hidden))
            (drgnx-ui-measure sess (list (list :keys "C-b")))
            (let ((after (drgnx-ui-call sess probe)))
              (message "dock-split after %S" after)
              (should (equal (plist-get after :groups) (plist-get before :groups))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/panel-and-right-dock-are-pixel-stable ()
  ;; Real keys (VS Code profile): C-` toggles the panel, C-M-b the right dock — 10 times each, sizes
  ;; ±0 px, focus never taken; M-x describe-function car RET puts *Help* in the panel's Help tab.
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
            (drgnx-ui-measure sess (list (list :keys "M-x") (list :type "describe-function") (list :keys "RET") (list :type "car") (list :keys "RET")))
            (let ((help (drgnx-ui-call sess probe)))
              (should (equal (plist-get help :panel-buffer) "*Help*"))
              (should (= (plist-get help :panel) (plist-get first :panel))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/the-outline-of-a-file-without-one-is-a-quiet-empty-state ()
  ;; The scene's case: the Outline lists an Emacs Lisp file's definitions, then the editor shows a shell script with
  ;; none.  The notice row is whole: not scrolled sideways, nothing drawn before it (no selection left over from the
  ;; rows it replaced), no row selected on it.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" "1400x850" 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (el (expand-file-name "a.el" root)) (sh (expand-file-name "b.sh" root))
         (probe "(drgnx-uitest--json
                   (with-current-buffer drgnx-outline-buffer-name
                     (let ((w (get-buffer-window nil t)))
                       (list :text (buffer-substring-no-properties (point-min) (pos-eol 1))
                             :hscroll (if w (window-hscroll w) -1)
                             :strings (length (seq-filter (lambda (o) (or (overlay-get o 'after-string)
                                                                          (overlay-get o 'before-string)))
                                                          (overlays-in (point-min) (min (point-max) (1+ (pos-eol 1))))))
                             :selected (if (seq-find (lambda (o) (and (overlay-get o 'drgnx-row-selected)
                                                                      (overlay-buffer o)))
                                                     (overlays-in (point-min) (point-max)))
                                           t :false)))))"))
    (with-temp-file el (insert "(defun alpha () 1)\n(defun beta () 2)\n(defun gamma () 3)\n"))
    (with-temp-file sh (insert "#!/bin/sh\necho hello\n"))
    (unwind-protect
        (progn
          (drgnx-ui-call sess (format "(progn (drgnx-wb-show-sidebar) (drgnx-wb-focus-editor) (find-file %S)
                                             (drgnx-uitest--json (list :ok t)))" el))
          (drgnx-ui-measure sess nil)
          ;; a row of the Outline selected, as a click leaves it
          (drgnx-ui-call sess "(progn (drgnx-outline-refresh)
                                      (with-selected-window (get-buffer-window drgnx-outline-buffer-name t)
                                        (goto-char (point-min)) (forward-line 2) (drgnx-wb-selection-sync))
                                      (drgnx-uitest--json (list :ok t)))")
          (drgnx-ui-measure sess nil)
          (drgnx-ui-call sess (format "(progn (drgnx-wb-focus-editor) (find-file %S) (drgnx-outline-refresh)
                                             (drgnx-uitest--json (list :ok t)))" sh))
          (drgnx-ui-measure sess nil)
          (let ((after (drgnx-ui-call sess probe)))
            (message "outline empty state %S" after)
            (should (string-match-p "No outline for this file" (plist-get after :text)))
            (should (= 0 (plist-get after :hscroll)))
            (should (= 0 (plist-get after :strings)))
            (should (eq :false (plist-get after :selected)))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))
