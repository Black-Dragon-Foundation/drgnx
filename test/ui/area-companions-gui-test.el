;;; area-companions-gui-test.el --- GUI tests: an area tab's companions are fitted to their lines (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; The right dock with a tab whose companions hold a few lines over and under an empty main buffer, on the root frame
;; with the store on.  Run at each scale (s1, s2): each companion's body is its lines' pixel height, through a frame
;; resize and when a line is added; hiding the area leaves the frame's windows as they were before it showed.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-area-companions--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-area-companions--repo)))
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-state)

(defvar drgnx-ui-area-companions--parts nil "The test tab's companions: (ABOVE BELOW).")
(defun drgnx-ui-area-companions--parts (_main) drgnx-ui-area-companions--parts)

(defun drgnx-ui-area-companions--buffer (name lines)
  "Buffer NAME holding LINES lines, the last without a newline."
  (with-current-buffer (get-buffer-create name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (mapconcat (lambda (i) (format "%s line %d" name i)) (number-sequence 1 lines) "\n")))
    (current-buffer)))

(defun drgnx-ui-area-companions--settle ()
  "Let redisplay, the size-change functions and the store's idle calls run, until the right side stops moving (a
header line's height is known after the first redisplay; at most 5 rounds)."
  (let ((edges nil) (n 0))
    (while (and (< n 5)
                (not (equal edges (setq edges (mapcar #'window-pixel-edges
                                                      (seq-filter (lambda (w) (window-parameter w 'drgnx-area-part))
                                                                  (window-list nil 'nomini)))))))
      (setq n (1+ n))
      (drgnx-uitest-run (drgnx-uitest-key-events "C-l"))
      (drgnx-test-wait-presented))))

(defun drgnx-ui-area-companions--part (part)
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-area-part) part)) (window-list nil 'nomini)))

(defun drgnx-ui-area-companions--fitted (w)
  "WINDOW W's body against its lines' pixel height: (BODY TEXT)."
  (list (window-body-height w t)
        (cdr (window-text-pixel-size w (with-current-buffer (window-buffer w) (point-min))
                                     (with-current-buffer (window-buffer w) (point-max))))))

(defun drgnx-ui-area-companions--layout ()
  "The selected frame's text size and its windows, in order: (BUFFER LEFT TOP WIDTH SIDE) each, and the bottom edge
of the lowest plus the echo area's height.  The echo area alone may change between two layouts (a two-line message an
earlier row left shrinks to one), so the heights are compared through their sum."
  (let ((ws (window-list nil 'nomini (frame-first-window))))
    (list (frame-text-width) (frame-text-height)
          (+ (apply #'max (mapcar (lambda (w) (nth 3 (window-pixel-edges w))) ws))
             (window-pixel-height (minibuffer-window)))
          (mapcar (lambda (w) (pcase-let ((`(,l ,top ,r ,_) (window-pixel-edges w)))
                                (list (window-buffer w) l top (- r l) (window-parameter w 'window-side))))
                  ws))))

(ert-deftest drgnx-ui-area-companions/fitted-through-a-resize-and-a-new-line ()
  (let* ((root (drgnx-uitest-root-frame))
         ;; the text size, which `set-frame-size' sets: the outer one would give the frame its bars' pixels back
         (size (list (frame-text-width root) (frame-text-height root)))
         (config (with-selected-frame root (current-window-configuration)))
         (saved (mapcar (lambda (p) (cons p (frame-parameter root p))) '(drgnx-wb-areas drgnx-wb-right-px)))
         (main (get-buffer-create "*companions main*"))
         (above (drgnx-ui-area-companions--buffer "*companions above*" 3))
         (below (drgnx-ui-area-companions--buffer "*companions below*" 1))
         (full (frame-parameter root 'fullscreen)) (base nil))
    (unwind-protect
        (with-selected-frame root
          ;; the session's root is fullscreen, which keeps its output's size: out of it, 100 px smaller each way
          (setq full (drgnx-test-frame-fullscreen root nil)
                base (list (- (car size) 100) (- (cadr size) 100)))
          (drgnx-test-frame-text-size root (car base) (cadr base))
          (delete-other-windows)
          (drgnx-state-mode 1)
          (set-frame-parameter root 'drgnx-wb-areas nil)
          (set-frame-parameter root 'drgnx-wb-right-px nil)
          (drgnx-wb-define-tab 'right 'ui-companions :title "Companions" :companions #'drgnx-ui-area-companions--parts)
          (setq drgnx-ui-area-companions--parts (list above below))
          (drgnx-ui-area-companions--settle)
          (let ((before (drgnx-ui-area-companions--layout)))
            (drgnx-wb-area-show 'right 'ui-companions main)
            (drgnx-ui-area-companions--settle)
            (let ((top (drgnx-ui-area-companions--part 'above)) (bottom (drgnx-ui-area-companions--part 'below)))
              (should (window-live-p top))
              (should (window-live-p bottom))
              (should (eq above (window-buffer top)))
              ;; fitted: the body is the lines, to the pixel; the header line (the tab row's place) is chrome
              (should (apply #'= (drgnx-ui-area-companions--fitted top)))
              (should (apply #'= (drgnx-ui-area-companions--fitted bottom)))
              ;; the window manager makes the frame shorter, then gives it back
              (drgnx-test-frame-text-size root (car base) (- (cadr base) 200))
              (drgnx-ui-area-companions--settle)
              (should (apply #'= (drgnx-ui-area-companions--fitted top)))
              (should (apply #'= (drgnx-ui-area-companions--fitted bottom)))
              (drgnx-test-frame-text-size root (car base) (cadr base))
              (drgnx-ui-area-companions--settle)
              (should (apply #'= (drgnx-ui-area-companions--fitted top)))
              (should (apply #'= (drgnx-ui-area-companions--fitted bottom)))
              ;; a line more: the window grows with it
              (let ((was (window-body-height bottom t)))
                (with-current-buffer below (goto-char (point-max)) (insert "\none more"))
                (drgnx-wb-area-fit-companions 'right)
                (drgnx-ui-area-companions--settle)
                (should (> (window-body-height bottom t) was))
                (should (apply #'= (drgnx-ui-area-companions--fitted bottom)))))
            (drgnx-wb-area-hide 'right)
            (drgnx-ui-area-companions--settle)
            (should (equal before (drgnx-ui-area-companions--layout)))))
      (ignore-errors (with-selected-frame root (drgnx-wb-area-hide 'right)))
      (drgnx-wb-undefine-tab 'right 'ui-companions)
      (drgnx-state-mode -1)
      (pcase-dolist (`(,p . ,v) saved) (set-frame-parameter root p v))
      (set-frame-size root (car size) (cadr size) t)
      (drgnx-test-frame-fullscreen root full)
      (with-selected-frame root (set-window-configuration config))
      (dolist (b (list main above below)) (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest drgnx-ui-area-companions/an-empty-companion-is-fitted-to-its-least-height ()
  "An empty companion (the agent panel's header before its rows come) is fitted to its least height in whole lines, not
left at its split height; its lines then grow it, fitted, and no fit is reported as not taken.  Red first: the fit
asked for one line (under the window's least height, its tab row and a line), the resize was refused whole and the
window kept half the area."
  (let* ((root (drgnx-uitest-root-frame))
         (config (with-selected-frame root (current-window-configuration)))
         (saved (mapcar (lambda (p) (cons p (frame-parameter root p))) '(drgnx-wb-areas drgnx-wb-right-px)))
         (main (get-buffer-create "*companions main*"))
         (above (drgnx-ui-area-companions--buffer "*companions above*" 0))
         (below (drgnx-ui-area-companions--buffer "*companions below*" 1)))
    ;; a row on the companion (a title of the buffer's own, as the panel's header carries the area's tab row): the
    ;; empty companion's least height is the row and a line, and its fit asks one line with the row, under that
    (with-current-buffer main (setq-local drgnx-area-own-title "Companions"))
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (drgnx-state-mode 1)
          (set-frame-parameter root 'drgnx-wb-areas nil)
          (set-frame-parameter root 'drgnx-wb-right-px nil)
          (drgnx-wb-define-tab 'right 'ui-companions :title "Companions" :companions #'drgnx-ui-area-companions--parts)
          (setq drgnx-ui-area-companions--parts (list above below))
          (drgnx-wb-area-show 'right 'ui-companions main)
          (should-not (eq 'none (window-parameter (drgnx-ui-area-companions--part 'above) 'header-line-format)))
          (drgnx-ui-area-companions--settle)
          (let* ((top (drgnx-ui-area-companions--part 'above)) (line (window-default-line-height top))
                 (least (* line (ceiling (window-min-size top nil top t) line))))
            (should (window-live-p top))
            (should (equal (list :height (window-pixel-height top) :unfitted nil)
                           (list :height least :unfitted (window-parameter top 'drgnx-area-unfitted))))
            (with-current-buffer above (insert "one\ntwo\nthree"))
            (drgnx-wb-area-fit-companions 'right)
            (drgnx-ui-area-companions--settle)
            (should (apply #'= (drgnx-ui-area-companions--fitted top)))
            (should-not (window-parameter top 'drgnx-area-unfitted))))
      (ignore-errors (with-selected-frame root (drgnx-wb-area-hide 'right)))
      (drgnx-wb-undefine-tab 'right 'ui-companions)
      (drgnx-state-mode -1)
      (pcase-dolist (`(,p . ,v) saved) (set-frame-parameter root p v))
      (with-selected-frame root (set-window-configuration config))
      (dolist (b (list main above below)) (when (buffer-live-p b) (kill-buffer b))))))

(provide 'area-companions-gui-test)
;;; area-companions-gui-test.el ends here
