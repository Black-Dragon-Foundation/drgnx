;;; wb-area-companions-test.el --- batch tests: an area tab's companion windows above and below it -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/grid-on-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/areas-backend" drgnx-dir) nil t)
(require 'drgnx-area)
(require 'drgnx-panes)
(defvar drgnx-view-patch-twin-of)       ; drgnx-view.el: in a view's twin, the view's own buffer

(defvar drgnx-area-companions-test--parts nil
  "What the test tab's companion function returns for its main buffer: (ABOVE BELOW).")

(defun drgnx-area-companions-test--parts (_main) drgnx-area-companions-test--parts)

(defun drgnx-area-companions-test--buffer (name lines)
  (with-current-buffer (get-buffer-create name)
    (let ((inhibit-read-only t)) (erase-buffer) (dotimes (i lines) (insert (format "%s %d\n" name i))))
    (current-buffer)))

(defmacro drgnx-area-companions-test--with (&rest body)
  "BODY with rules on, one editor window, the right dock hidden, fresh area state, and two tabs in the right dock:
`withparts' (companions from `drgnx-area-companions-test--parts') and `plain' (none)."
  `(drgnx-test-with-state
     (let ((drgnx-wb-unrouted nil)
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
           (drgnx-area-companions-test--parts nil))
       (delete-other-windows)
       (set-frame-parameter nil 'drgnx-wb-areas nil)
       (set-frame-parameter nil 'drgnx-wb-right-px nil)
       (drgnx-rules-mode 1)
       (drgnx-wb-define-tab 'right 'withparts :title "With" :companions #'drgnx-area-companions-test--parts)
       (drgnx-wb-define-tab 'right 'plain :title "Plain")
       (unwind-protect (drgnx-test-with-grid-on ,@body)
         (drgnx-rules-mode -1)
         (drgnx-wb-area-hide 'right)
         (drgnx-wb-undefine-tab 'right 'withparts)
         (drgnx-wb-undefine-tab 'right 'plain)
         (delete-other-windows)
         (dolist (b '("*main*" "*above*" "*below*" "*other*")) (when (get-buffer b) (kill-buffer b)))))))

(defun drgnx-area-companions-test--right-windows ()
  "The right side's windows, top to bottom."
  (sort (seq-filter (lambda (w) (eq (window-parameter w 'drgnx-role) 'right)) (window-list nil 'nomini))
        (lambda (a b) (< (nth 1 (window-edges a)) (nth 1 (window-edges b))))))

(ert-deftest drgnx-area-companions/a-tab-shows-its-companions-above-and-below-it ()
  (drgnx-area-companions-test--with
   (let* ((main (drgnx-area-companions-test--buffer "*main*" 50))
          (above (drgnx-area-companions-test--buffer "*above*" 2))
          (below (drgnx-area-companions-test--buffer "*below*" 1)))
     (setq drgnx-area-companions-test--parts (list above below))
     (let* ((w (drgnx-wb-area-show 'right 'withparts main)) (ws (drgnx-area-companions-test--right-windows)))
       (should (equal (mapcar #'window-buffer ws) (list above main below)))
       (should (eq w (nth 1 ws)))
       (should (eq (drgnx-wb-area-window 'right) w))
       (should (equal (mapcar (lambda (x) (window-parameter x 'drgnx-area-part)) ws) '(above nil below)))
       (dolist (x ws)
         (should (window-dedicated-p x))
         (should (eq 'right (window-parameter x 'drgnx-role)))
         (should (eq 'none (window-parameter x 'mode-line-format))))
       ;; the store reads the main window as the tab's pane, the companions as no pane of their own
       (drgnx-state-sync)
       (should (eq w (drgnx-state-pane-window 'withparts)))
       ;; the tab row is the topmost window's, and only its
       (should (memq (window-parameter (nth 0 ws) 'header-line-format) '(none)))
       (should (or (eq (window-parameter w 'header-line-format) 'none) (null (window-parameter w 'header-line-format))))
       (should (eq (drgnx-area--top-window 'right) (nth 0 ws)))))))

(ert-deftest drgnx-area-companions/the-tab-row-goes-on-the-topmost-window ()
  "With two tabs of content the right dock draws its tab row (not `lone'): on the companion above when there is one."
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 5)) (other (drgnx-area-companions-test--buffer "*other*" 5))
         (above (drgnx-area-companions-test--buffer "*above*" 2)))
     (drgnx-wb-area-show 'right 'plain other)
     (setq drgnx-area-companions-test--parts (list above nil))
     (let* ((w (drgnx-wb-area-show 'right 'withparts main)) (top (car (drgnx-area-companions-test--right-windows))))
       (should (eq (window-buffer top) above))
       (should (stringp (window-parameter top 'header-line-format)))   ; the row is a string (`drgnx-wb-bar')
       (should (eq 'none (window-parameter w 'header-line-format)))
       ;; a redraw of the row (a tab's actions changed) puts it there again
       (drgnx-wb-area-redraw 'right)
       (should (stringp (window-parameter top 'header-line-format)))
       (should (eq 'none (window-parameter w 'header-line-format)))))))

(ert-deftest drgnx-area-companions/a-tab-without-them-takes-them-away-and-back ()
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50)) (other (drgnx-area-companions-test--buffer "*other*" 5))
         (above (drgnx-area-companions-test--buffer "*above*" 2)) (below (drgnx-area-companions-test--buffer "*below*" 1)))
     (setq drgnx-area-companions-test--parts (list above below))
     (drgnx-wb-area-show 'right 'withparts main)
     (drgnx-wb-area-show 'right 'plain other)
     (should (equal (mapcar #'window-buffer (drgnx-area-companions-test--right-windows)) (list other)))
     (drgnx-wb-area-show 'right 'withparts)
     (should (equal (mapcar #'window-buffer (drgnx-area-companions-test--right-windows)) (list above main below))))))

(ert-deftest drgnx-area-companions/hiding-the-area-deletes-them-and-a-nil-part-shows-none ()
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50)) (below (drgnx-area-companions-test--buffer "*below*" 1)))
     (setq drgnx-area-companions-test--parts (list nil below))
     (drgnx-wb-area-show 'right 'withparts main)
     (should (equal (mapcar #'window-buffer (drgnx-area-companions-test--right-windows)) (list main below)))
     (drgnx-wb-area-hide 'right)
     (should-not (drgnx-area-companions-test--right-windows))
     (drgnx-wb-area-show 'right)
     (should (equal (mapcar #'window-buffer (drgnx-area-companions-test--right-windows)) (list main below))))))

(ert-deftest drgnx-area-companions/killing-the-main-buffer-takes-its-companions ()
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50))
         (above (drgnx-area-companions-test--buffer "*above*" 2)) (below (drgnx-area-companions-test--buffer "*below*" 1)))
     (setq drgnx-area-companions-test--parts (list above below))
     (drgnx-wb-area-show 'right 'withparts main)
     (kill-buffer main)
     (let ((ws (drgnx-area-companions-test--right-windows)))
       (should (= 1 (length ws)))
       (should (buffer-local-value 'drgnx-area--placeholder-p (window-buffer (car ws))))))))

(ert-deftest drgnx-area-companions/killing-a-companion-buffer-takes-only-its-window ()
  "A companion's buffer killed: its window goes and the area stays (a dedicated side window would otherwise be
deleted through the area's `delete-window', which hides the whole area)."
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50))
         (above (drgnx-area-companions-test--buffer "*above*" 2)) (below (drgnx-area-companions-test--buffer "*below*" 1)))
     (setq drgnx-area-companions-test--parts (list above below))
     (drgnx-wb-area-show 'right 'withparts main)
     (kill-buffer below)
     (should (equal (mapcar #'window-buffer (drgnx-area-companions-test--right-windows)) (list above main))))))

(ert-deftest drgnx-area-companions/a-tab-left-on-a-twin-comes-back-with-its-view-buffer ()
  "A tab left showing a hub view's twin in another display class: when the twin is gone (no window shows its class),
the tab comes back with the view's own buffer, and its companions, not a placeholder."
  (drgnx-area-companions-test--with
   (let* ((main (drgnx-area-companions-test--buffer "*main*" 50)) (other (drgnx-area-companions-test--buffer "*other*" 5))
          (below (drgnx-area-companions-test--buffer "*below*" 1))
          (twin (with-current-buffer (drgnx-area-companions-test--buffer "*main* <tty>" 50)
                  (setq-local drgnx-view-patch-twin-of main)
                  (current-buffer))))
     (unwind-protect
         (progn
           (setq drgnx-area-companions-test--parts (list nil below))
           (drgnx-wb-area-show 'right 'withparts twin)
           (drgnx-wb-area-show 'right 'plain other)
           (kill-buffer twin)
           (drgnx-wb-area-show 'right 'withparts)
           (should (equal (mapcar #'window-buffer (drgnx-area-companions-test--right-windows)) (list main below))))
       (when (buffer-live-p twin) (kill-buffer twin))))))

(ert-deftest drgnx-area-companions/a-pane-kind-passes-its-companions-to-the-tab ()
  (drgnx-area-companions-test--with
   (let ((drgnx-pane--kinds nil) (drgnx-pane-backend 'areas))
     (drgnx-pane-define-kind 'companions-kind :title "K" :home 'right
                             :companions #'drgnx-area-companions-test--parts)
     (unwind-protect
         (progn
           (should (eq #'drgnx-area-companions-test--parts (plist-get (drgnx-pane-kind 'companions-kind) :companions)))
           (should (eq #'drgnx-area-companions-test--parts
                       (plist-get (alist-get 'companions-kind (plist-get (alist-get 'right drgnx-wb--areas) :tabs))
                                  :companions))))
       (drgnx-pane-undefine-kind 'companions-kind)))))

(ert-deftest drgnx-area-companions/a-companion-is-fitted-to-its-lines ()
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50))
         (above (drgnx-area-companions-test--buffer "*above*" 3)) (below (drgnx-area-companions-test--buffer "*below*" 2)))
     (with-current-buffer above (goto-char (point-max)) (delete-char -1))   ; 3 lines, no empty last line
     (with-current-buffer below (goto-char (point-max)) (delete-char -1))
     (setq drgnx-area-companions-test--parts (list above below))
     (drgnx-wb-area-show 'right 'withparts main)
     (let ((ws (drgnx-area-companions-test--right-windows)))
       (should (= 3 (window-body-height (nth 0 ws))))
       (should (= 2 (window-body-height (nth 2 ws))))
       ;; a companion that grew is fitted again when asked
       (with-current-buffer below (goto-char (point-max)) (insert "\nmore"))
       (drgnx-wb-area-fit-companions 'right)
       (should (= 3 (window-body-height (nth 2 ws))))
       ;; a long one stops at 45% of the area
       (with-current-buffer below (goto-char (point-max)) (dotimes (_ 200) (insert "\nmore")))
       (drgnx-wb-area-fit-companions 'right)
       (let ((area (apply #'+ (mapcar #'window-pixel-height ws))))
         (should (<= (window-pixel-height (nth 2 ws)) (* 0.45 area)))
         (should (> (window-pixel-height (nth 2 ws)) (* 0.3 area)))
         ;; at the cap it is fitted as asked: nothing to report
         (should-not (window-parameter (nth 2 ws) 'drgnx-area-unfitted)))))))

(defvar drgnx-view-sja-tail)            ; drgnx-view-sja.el: a view that opens at its tail

(ert-deftest drgnx-area-companions/a-tail-view-left-at-its-end-comes-back-at-its-new-end ()
  "A tab whose buffer is a tail view (`drgnx-view-sja-tail') left with its window's point at the end comes back with
point at the end it has now, after lines came while it was hidden; one left elsewhere comes back where it was."
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50)) (other (get-buffer-create "*other*")))
     (with-current-buffer main (setq-local drgnx-view-sja-tail t))
     (let ((w (drgnx-wb-area-show 'right 'withparts main)))
       (set-window-point w (with-current-buffer main (point-max)))
       (drgnx-wb-area-show 'right 'plain other)
       (with-current-buffer main (goto-char (point-max)) (insert "more\nmore\n"))
       (drgnx-wb-area-show 'right 'withparts)
       (should (eq main (window-buffer w)))
       (should (= (window-point w) (with-current-buffer main (point-max))))
       ;; left on a line above the end: back on it
       (set-window-point w 10)
       (drgnx-wb-area-show 'right 'plain other)
       (with-current-buffer main (goto-char (point-max)) (insert "more\n"))
       (drgnx-wb-area-show 'right 'withparts)
       (should (= (window-point w) 10))))))

(ert-deftest drgnx-area-companions/a-fit-that-does-not-take-is-reported ()
  "A companion whose fit changed nothing while its lines want another height gets the window parameter
`drgnx-area-unfitted' (its height and the one it wanted); the next fit that takes clears it."
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50))
         (above (drgnx-area-companions-test--buffer "*above*" 2)) (below (drgnx-area-companions-test--buffer "*below*" 2)))
     (setq drgnx-area-companions-test--parts (list above below))
     (drgnx-wb-area-show 'right 'withparts main)
     (let ((w (nth 2 (drgnx-area-companions-test--right-windows))))
       (should-not (window-parameter w 'drgnx-area-unfitted))
       (with-current-buffer below (dotimes (_ 3) (insert "more\n")))
       ;; a resize Emacs refuses (as under a window's least height): the fit changes nothing
       (cl-letf (((symbol-function 'window-resize-no-error) #'ignore))
         (drgnx-wb-area-fit-companions 'right))
       (let ((r (window-parameter w 'drgnx-area-unfitted)))
         (should r)
         (should (= (plist-get r :height) (window-pixel-height w)))
         (should (> (plist-get r :want) (plist-get r :height))))
       (drgnx-wb-area-fit-companions 'right)
       (should-not (window-parameter w 'drgnx-area-unfitted))))))

;; Red first for the agent panel's blank space under its end (r6-docks-open): its header is empty until the hub's rows
;; come, and an empty companion's fit asked for less than the window's minimum, so `fit-window-to-buffer' resized
;; nothing and the header kept its split size (264 px at s1).  When its rows came it shrank to them and the transcript,
;; which had followed its end in the smaller window, grew with its start kept: blank space under the end.
;; The companion carries the dock's tab row (two tabs of content).  It was fitted before the row was put on it, to one
;; line, where Emacs draws no header line (and `window-min-size' counts none): the row was lost until its rows came.
(ert-deftest drgnx-area-companions/an-empty-companion-is-fitted-to-its-least-height ()
  (drgnx-area-companions-test--with
   (let ((main (drgnx-area-companions-test--buffer "*main*" 50)) (other (drgnx-area-companions-test--buffer "*other*" 5))
         (above (drgnx-area-companions-test--buffer "*above*" 0)) (below (drgnx-area-companions-test--buffer "*below*" 2)))
     (with-current-buffer below (goto-char (point-max)) (delete-char -1))
     (drgnx-wb-area-show 'right 'plain other)
     (setq drgnx-area-companions-test--parts (list above below))
     (drgnx-wb-area-show 'right 'withparts main)
     (let* ((ws (drgnx-area-companions-test--right-windows)) (top (nth 0 ws)))
       (should (eq (window-buffer top) above))
       ;; the row is drawn, and with it one line is under the least height
       (should (> (window-header-line-height top) 0))
       (should (> (window-min-size top nil top) 1))
       ;; about as small as the window can be (its least size, rounded up to a whole line), not its split size
       (should (<= (window-total-height top) (1+ (window-min-size top nil top))))
       ;; its rows come: it grows to them
       (with-current-buffer above (insert "one\ntwo"))
       (drgnx-wb-area-fit-companions 'right)
       (should (= 2 (window-body-height top)))))))

(provide 'wb-area-companions-test)
;;; wb-area-companions-test.el ends here
