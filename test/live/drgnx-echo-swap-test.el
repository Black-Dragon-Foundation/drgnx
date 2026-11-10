;;; drgnx-echo-swap-test.el --- live: a full workbench survives the echo box's frame swap (config=drgnx) -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; A frame cannot gain or lose its minibuffer, so turning the echo box on or off (`drgnx-look-echo-row') replaces each
;; graphical frame with one like it.  Here the frame holds the whole workbench: the Buffers and Explorer docks, two
;; editor groups (a split) with tabs, an auxiliary window, the agent panel (the mock agent, when $DRGNX_RATATOSKR_BIN names one) and the
;; card group of the docks.  It is swapped to the classic row and back; after each swap every part is where it was,
;; draws, and still answers its keys.  Frames need a graphical session: batch Emacs cannot make them.
(require 'ert)
(require 'drgnx-ui)

(defun drgnx-echo-swap-test--eval (sess form)
  "FORM's value (any Lisp value, printed) from the session."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form) 60) :v))))

(defconst drgnx-echo-swap-test--probe
  "(defun kx-probe ()
     \"The selected frame's workbench as data: no window objects, so two frames compare.\"
     (let* ((f (selected-frame)))
       (list :roots (length (seq-remove (lambda (x) (or (frame-parent x) (not (display-graphic-p x)))) (frame-list)))
             :mains (seq-count (lambda (x) (eq (frame-parameter x 'drgnx-frame-role) 'main)) (frame-list))
             :role (drgnx-frame-role f)
             :box (and (drgnx-look-echo-box f) t)
             :selected (buffer-name (window-buffer (frame-selected-window f)))
             :panes (and (boundp 'drgnx-pane--last) (sort (mapcar #'car (gethash f drgnx-pane--last)) #'string<))
             :windows
             (mapcar (lambda (w)
                       (list (buffer-name (window-buffer w))
                             :cols (list (nth 0 (window-edges w)) (nth 2 (window-edges w)))
                             :role (window-parameter w 'drgnx-role)
                             :tabs (mapcar (lambda (b) (if (bufferp b) (buffer-name b) b)) (window-parameter w 'drgnx-tabs))
                             :card-group (and (window-parameter w 'card-group) t)
                             :card (and (window-parameter w 'drgnx-look-card) t)
                             :draws (> (window-body-height w t) 0)))
                     (window-list f 'nomini (frame-first-window f))))))"
  "Defined in the session: what each swap must keep.")

(defconst drgnx-echo-swap-test--panel
  "(and (buffer-live-p kx-panel) (or (get-buffer-window kx-panel) (seq-some (lambda (w) (memq kx-panel (window-parameter w 'drgnx-tabs))) (window-list nil 'nomini))) t)"
  "In the session: the agent panel lives and is shown, or is a tab of an editor group.")

(ert-deftest drgnx-live/echo-swap-keeps-the-whole-workbench ()
  (let* ((root (make-temp-file "drgnx-echo-swap" t))
         (project (file-name-as-directory (expand-file-name "project" root)))
         (bin (getenv "DRGNX_RATATOSKR_BIN"))
         (shots (or (getenv "DRGNX_UI_EVIDENCE") root))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (progn
              (dolist (f '("a.el" "b.el" "c.el")) (make-directory project t)
                      (write-region (format ";; %s\n" f) nil (expand-file-name f project) nil 'silent))
              (drgnx-ui-start "drgnx" "1400x850" 60)))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (progn
          (drgnx-echo-swap-test--eval sess drgnx-echo-swap-test--probe)
          (drgnx-echo-swap-test--eval
           sess (format "(progn (defvar kx-dir %S) (defvar kx-panel nil)
                          (when %S
                            (load (expand-file-name \"test/fixtures/panel-replay-fixture\" drgnx-dir) nil t)
                            (setq kx-panel (drgnx-panel-replay-up %S)))
                          (drgnx-wb-focus-editor)
                          (find-file (expand-file-name \"a.el\" kx-dir)) (drgnx-chrome-apply nil t)
                          (find-file (expand-file-name \"b.el\" kx-dir)) (drgnx-chrome-apply nil t)
                          (drgnx-explorer-set-roots (list kx-dir))
                          (drgnx-wb-show-sidebar)
                          (drgnx-wb-focus-editor)
                          (drgnx-groups-split-right)
                          (find-file (expand-file-name \"c.el\" kx-dir)) (drgnx-chrome-apply nil t)
                          ;; a second window (auxiliary): the swap must not make it main too
                          (let ((main (selected-frame)))
                            (make-frame '((name . \"kx aux\") (width . 80) (height . 20)))
                            (select-frame-set-input-focus main))
                          (drgnx-wb-focus-editor)
                          t)"
                        project bin bin))
          (drgnx-ui-measure sess nil)
          (let ((before (drgnx-echo-swap-test--eval sess "(kx-probe)")))
            ;; the premise: the whole workbench is there, the box is on, one main window
            (should (plist-get before :box))
            (should (eq (plist-get before :role) 'main))
            (should (= (plist-get before :mains) 1))
            (should (= (plist-get before :roots) 2))
            (should (>= (seq-count (lambda (w) (eq (plist-get (cdr w) :role) 'dock)) (plist-get before :windows)) 2))
            (should (seq-some (lambda (w) (plist-get (cdr w) :card-group)) (plist-get before :windows)))
            (should (>= (seq-count (lambda (w) (member "a.el" (plist-get (cdr w) :tabs))) (plist-get before :windows)) 1))
            (should (seq-some (lambda (w) (equal (car w) "c.el")) (plist-get before :windows)))
            (when bin
              (should (drgnx-echo-swap-test--eval sess drgnx-echo-swap-test--panel)))
            (drgnx-ui-screenshot sess (expand-file-name "echo-swap-0-box.png" shots))
            (pcase-dolist (`(,setting ,box ,name) '((classic nil "echo-swap-1-row") (float t "echo-swap-2-box")))
              ;; what this swap must keep: the workbench as the keys below left it
              (setq before (drgnx-echo-swap-test--eval sess "(kx-probe)"))
              (drgnx-echo-swap-test--eval
               sess (format "(progn (setq drgnx-look-echo-row '%s) (drgnx-look-echo-apply) t)" setting))
              (drgnx-ui-measure sess nil)
              (let ((after (drgnx-echo-swap-test--eval sess "(kx-probe)")))
                (let ((print-length nil) (print-level nil))
                  (message "echo-swap %s before %S\n after %S" setting before after))
                (should (eq (plist-get after :box) box))
                (should (equal (plist-put (copy-sequence after) :box nil) (plist-put (copy-sequence before) :box nil))))
              (when bin
                (should (drgnx-echo-swap-test--eval sess drgnx-echo-swap-test--panel)))
              ;; it works: the keys still hide and show the sidebar, and focus the second group
              (drgnx-ui-measure sess (list (list :keys "C-b")))
              (should-not (drgnx-echo-swap-test--eval sess "(seq-some (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock)) (window-list nil 'nomini))"))
              (drgnx-ui-measure sess (list (list :keys "C-b")))
              (should (drgnx-echo-swap-test--eval sess "(and (seq-some (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock)) (window-list nil 'nomini)) t)"))
              (drgnx-echo-swap-test--eval sess "(progn (drgnx-groups-focus-1) t)")
              (should (equal (drgnx-echo-swap-test--eval sess "(buffer-name (window-buffer (selected-window)))") "b.el"))
              (drgnx-echo-swap-test--eval sess "(progn (drgnx-groups-focus-2) t)")
              (should (equal (drgnx-echo-swap-test--eval sess "(buffer-name (window-buffer (selected-window)))") "c.el"))
              (drgnx-ui-screenshot sess (expand-file-name (concat name ".png") shots)))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

;; Startup: with ui/look on (the box is the default), the first frame is born with the box: no frame is swapped.  That
;; takes an Emacs that makes the first frame so (Nidhogg's lisp/nidhogg-frame.el); a daemon's client frames are born
;; with it anywhere.
(defconst drgnx-echo-swap-test--born
  "(let* ((f (seq-find (lambda (x) (and (display-graphic-p x) (not (frame-parent x)))) (frame-list))))
     (list :swaps drgnx-look-echo-swaps :box (and f (drgnx-look-echo-box f) t)
           :no-row (and f (= (nth 3 (window-pixel-edges (frame-root-window f))) (frame-inner-height f)))))"
  "In the session: the swaps so far, and whether the graphical frame has the box and no echo row.")

(ert-deftest drgnx-live/echo-box-at-startup-swaps-no-frame ()
  (let* ((root (make-temp-file "drgnx-echo-start" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" "1200x800" 60))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (progn
          (drgnx-ui-measure sess nil)
          (should (drgnx-echo-swap-test--eval sess "(featurep 'nidhogg-frame)"))
          (should (equal (drgnx-echo-swap-test--eval sess drgnx-echo-swap-test--born) '(:swaps 0 :box t :no-row t))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/echo-box-in-a-daemon-swaps-no-frame ()
  (let* ((root (make-temp-file "drgnx-echo-daemon" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" "1200x800" 60 t))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (progn
          (should (eql 0 (plist-get (drgnx-ui-new-frame sess 60) :exit)))
          (drgnx-ui-measure sess nil)
          (should (equal (drgnx-echo-swap-test--eval sess drgnx-echo-swap-test--born) '(:swaps 0 :box t :no-row t))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

;;; drgnx-echo-swap-test.el ends here
