;;; look-explorer-cover-gui-test.el --- GUI test: a long name's ⋯ drawn over it on hover (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Pattern D (any compositor, Nidhogg's mouse sensors): the Explorer with a file whose name runs to the sidebar's edge, so the
;; hub cuts it at the full body and its tail leaves the ⋯ out (`drgnx-row-tail-short').  The compositor's pointer
;; moves onto its row: the ⋯ is drawn over the end of the name at its place (`drgnx-wb-cover-sense'), and a click
;; there lands on it; off the row, the cover goes, and the module turned off leaves no cover anywhere.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-look-explorer-cover--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-explorer-cover--repo)))
(require 'drgnx)
(require 'drgnx-state)
(load (expand-file-name "test/fixtures/ui-hub-fixture" drgnx-ui-look-explorer-cover--repo) nil t)   ; the hub's rows
(require 'drgnx-explorer)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-ui-look-explorer-cover--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-ui-look-explorer-cover--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-explorer-cover--repo) nil t)

(defun drgnx-ui-look-explorer-cover--settle ()
  (drgnx-uitest-run nil)
  (drgnx-signal--flush)
  (drgnx-test-wait-presented))

(defun drgnx-ui-look-explorer-cover--covers ()
  "Every live cover overlay in every buffer: (BUFFER . OVERLAY)."
  (let ((out nil))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (dolist (o (overlays-in (point-min) (point-max)))
          (when (overlay-get o 'drgnx-wb-cover) (push (cons b o) out)))))
    out))

(drgnx-look-gui-deftest drgnx-ui-look-explorer-cover/a-long-name-gets-its-dots-over-it-on-hover ()
  "A file whose name runs to the Explorer's edge: no ⋯ at rest; the pointer on its row draws the ⋯ over the end of
the name at the ⋯'s place, where a click lands on it; off the row the cover goes, and the module off leaves none."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (skip-unless (boundp 'mouse-sensor-enabled))
  (skip-unless (eq t (drgnx-uitest-pointer-set 0 0)))
  (let* ((root (drgnx-uitest-root-frame))
         (dir (file-name-as-directory (make-temp-file "look-explorer-cover" t)))
         (name "a-file-whose-name-runs-on-and-on-past-the-edge-of-the-sidebar.el")
         (config (with-selected-frame root (current-window-configuration)))
         (drgnx-wb--sections nil)
         (drgnx-explorer--roots (list dir)) (drgnx-explorer-git nil))
    (write-region "x\n" nil (expand-file-name name dir) nil 'silent)
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (drgnx-look-density-on)
          (drgnx-state-mode 1)
          (drgnx-ui-hub-start drgnx-ui-look-explorer-cover--repo)
          (let ((drgnx-modules--current 'look-explorer-cover) (drgnx-modules--setup-load load-file-name))
            (drgnx-explorer-setup))
          (drgnx-signal--flush)
          (drgnx-wb-show-sidebar)
          ;; the env goes out on an idle timer after a window change; a test's wait never idles
          (drgnx-view-env-update drgnx-explorer-hub-view-name)
          (let ((row (lambda () (with-current-buffer drgnx-explorer-buffer-name
                                  (save-excursion (goto-char (point-min))
                                                  (and (search-forward "a-file-whose" nil t) (pos-bol)))))))
            (drgnx-test-wait (lambda () (drgnx-ui-look-explorer-cover--settle)
                               (when-let* ((bol (funcall row)))
                                 (with-current-buffer drgnx-explorer-buffer-name
                                   (get-text-property bol 'drgnx-row-tail-short))))
                             :what "the long name's row, cut at the edge with no room for its ⋯")
            (drgnx-ui-look-explorer-cover--settle)
            (let* ((w (get-buffer-window drgnx-explorer-buffer-name root))
                   (bol (funcall row))
                   (y (cdr (posn-x-y (posn-at-point bol w))))
                   ;; `posn-at-x-y' counts from the window's top, above its tab and header lines
                   (top (+ (window-tab-line-height w) (window-header-line-height w)))
                   (h (with-current-buffer drgnx-explorer-buffer-name (save-excursion (goto-char bol) (line-pixel-height))))
                   (edges (window-inside-pixel-edges w))
                   ;; the ⋯'s middle: it starts at the control's place, the stretch before it ends there
                   (dots-x (+ 5 (- (window-body-width w t) (cadr (drgnx-wb-tail-px w)))))
                   (on-dots (lambda ()
                              (let ((s (posn-string (posn-at-x-y dots-x (+ y top (/ h 2)) w))))
                                (and (stringp (car s)) (get-text-property (cdr s) 'drgnx-row-control (car s))))))
                   ;; the frame's place from the harness, on any compositor (sway's tree is not there under KWin)
                   (origin (drgnx-uitest-frame-origin))
                   (s (drgnx-pixels-scale))   ; a Lisp pixel is a device pixel; the pointer takes logical ones
                   (point-at (lambda (x y) (drgnx-uitest-pointer-set (+ (car origin) (round (/ x s)))
                                                                     (+ (cdr origin) (round (/ y s)))))))
              (should origin)
              ;; at rest: the name runs under the ⋯'s place, no ⋯ drawn
              (should-not (funcall on-dots))
              (should-not (drgnx-ui-look-explorer-cover--covers))
              ;; the pointer on the row, left of the ⋯'s place
              (should (eq t (funcall point-at (+ (nth 0 edges) 20) (+ (nth 1 edges) y (/ h 2.0)))))
              (drgnx-ui-look-explorer-cover--settle)
              ;; headless sway may never give the frame the pointer: then there is no hover to see (a listed skip)
              (skip-unless (cadr (mouse-pixel-position)))
              (drgnx-test-wait (lambda () (drgnx-ui-look-explorer-cover--settle) (funcall on-dots))
                               :what "the ⋯ drawn over the end of the hovered name, at its place")
              ;; the row keeps its width: nothing drawn past the body
              (with-current-buffer drgnx-explorer-buffer-name
                (should (<= (car (window-text-pixel-size w bol (save-excursion (goto-char bol) (pos-eol))))
                            (window-body-width w t))))
              ;; a click at the ⋯'s place lands on it (the cover's string, its `drgnx-row-control')
              (let ((posn (posn-at-x-y dots-x (+ y top (/ h 2)) w)))
                (should (eq w (posn-window posn)))
                (should (= bol (with-current-buffer drgnx-explorer-buffer-name
                                 (save-excursion (goto-char (posn-point posn)) (pos-bol))))))
              ;; off the row: the cover goes, the name is drawn there again
              (should (eq t (funcall point-at (+ (nth 0 edges) 20) (+ (nth 3 edges) -2))))
              (drgnx-ui-look-explorer-cover--settle)
              (drgnx-test-wait (lambda () (drgnx-ui-look-explorer-cover--settle) (not (funcall on-dots)))
                               :what "the cover gone off the row")
              (should-not (seq-filter (lambda (c) (overlay-buffer (cdr c))) (drgnx-ui-look-explorer-cover--covers)))
              ;; on the row again, then the module off: no cover left anywhere
              (should (eq t (funcall point-at (+ (nth 0 edges) 20) (+ (nth 1 edges) y (/ h 2.0)))))
              (drgnx-test-wait (lambda () (drgnx-ui-look-explorer-cover--settle) (funcall on-dots))
                               :what "the ⋯ drawn again on the row")
              (dolist (u (alist-get 'look-explorer-cover drgnx-modules--stacks)) (funcall (cdr u)))
              (setf (alist-get 'look-explorer-cover drgnx-modules--stacks nil t) nil)
              (should-not (drgnx-ui-look-explorer-cover--covers))
              (should-not (with-current-buffer drgnx-explorer-buffer-name drgnx-wb--covers)))))
      (drgnx-wb-hide-sidebar)
      (dolist (u (alist-get 'look-explorer-cover drgnx-modules--stacks)) (funcall (cdr u)))
      (setf (alist-get 'look-explorer-cover drgnx-modules--stacks nil t) nil)
      (drgnx-state-mode -1)
      (drgnx-ui-hub-stop)
      (drgnx-look-density-off)
      (mapc #'disable-theme custom-enabled-themes)
      (with-selected-frame root (set-window-configuration config))
      (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
      (delete-directory dir t))))

(provide 'look-explorer-cover-gui-test)
;;; look-explorer-cover-gui-test.el ends here
