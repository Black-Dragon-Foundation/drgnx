;;; card-panels-test.el --- GUI tests: docked panes as cards under Glitnir (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; The Explorer (a dock) is a card while ui/look runs under Glitnir: its window carries the card parameters, the
;; frame's dividers are the gap, and the picture shows the rounded corner over the gap.  Both rows skip unless Glitnir
;; draws the frames (the native shell), and are race-proof by pattern D: every picture is taken after
;; `drgnx-test-wait-presented', and compared with another taken the same way.  Also writes the whole-window scene's
;; screenshot to the session's temp dir (`drgnx-card-panels-ui-test--scene').

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-card-panels-ui-test--repo           ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-card-panels-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-wb)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-card-panels-ui-test--repo) nil t)

(defvar drgnx-look-card)
(declare-function drgnx-look-cards-apply "drgnx-look")
(declare-function drgnx-look-cards-clear "drgnx-look")
(declare-function glitnir-refresh "glitnir")

(defmacro drgnx-card-panels-ui-test--with-explorer (&rest body)
  "BODY with a one-section dock showing, cards applied, and the picture presented.  Everything undone after."
  (declare (indent 0))
  `(progn
     (skip-unless (drgnx-uitest-glitnir-p))
     (drgnx-uitest-bare-frame)
     (let ((drgnx-wb--sections nil))
       (drgnx-wb-define-section 'card-panels :slot 0 :title " EXPLORER"
                                :buffer (lambda () (with-current-buffer (get-buffer-create "*card-panels*")
                                                     (erase-buffer) (insert "dock text\n") (current-buffer))))
       (unwind-protect
           (progn (drgnx-wb-show-sidebar)
                  (drgnx-look-cards-apply)
                  (drgnx-test-wait-presented)
                  ,@body)
         (drgnx-look-cards-clear)
         (drgnx-wb-hide-sidebar)
         (drgnx-wb-undefine-section 'card-panels)
         (when (get-buffer "*card-panels*") (kill-buffer "*card-panels*"))
         (drgnx-test-wait-presented)))))

(defun drgnx-card-panels-ui-test--rect (window)
  "WINDOW's pixel edges (L T R B) in the snapshot's device pixels."
  (let ((s (drgnx-uitest-device-scale (window-frame window))))
    (mapcar (lambda (e) (round (* s e))) (window-pixel-edges window))))

(defun drgnx-card-panels-ui-test--editor ()
  "The frame's editor window: neither a dock nor a lane."
  (seq-find (lambda (w) (not (window-parameter w 'drgnx-role))) (window-list nil 'nomini)))

(defun drgnx-card-panels-ui-test--scene ()
  "Write the scene's picture into the session's temp dir; return its path."
  (let ((shot (plist-get (drgnx-uitest-capture (make-temp-file "card-panels" t)) :root))
        (out (expand-file-name "card-panels-scene.png" temporary-file-directory)))
    (copy-file shot out t)
    (message "card-panels screenshot: %s" out)
    out))

(ert-deftest drgnx-ui-card-panels/explorer-has-card ()
  "The dock's window has the card parameters and the gap; its top-left corner pixel shows the gap, not the dock."
  (drgnx-card-panels-ui-test--with-explorer
    (let* ((dock (car (drgnx-wb--dock-windows))) (gap (alist-get 'gap drgnx-look-card)))
      (should dock)
      (dolist (p '(corner-radius shadow ring))
        (should (equal (window-parameter dock p) (alist-get p drgnx-look-card))))
      (should (eql (frame-parameter nil 'right-divider-width) (round (* gap (frame-scale-factor)))))
      (let* ((on (drgnx-uitest-snapshot)) (r (drgnx-card-panels-ui-test--rect dock))
             (corner (drgnx-uitest-pixel on (nth 0 r) (nth 1 r)))
             (inside (drgnx-uitest-pixel on (+ (nth 0 r) 40) (+ (nth 1 r) 40))))
        (should-not (equal corner inside))        ; the corner is cut away: the gap shows, not the dock's background
        (drgnx-card-panels-ui-test--scene)))))

(ert-deftest drgnx-ui-card-panels/text-never-covered ()
  "The editor window's picture between its corner rows is the same with the card chrome as with only the card gap:
chrome takes no text."
  (drgnx-card-panels-ui-test--with-explorer
    (let* ((dock (car (drgnx-wb--dock-windows))) (editor (drgnx-card-panels-ui-test--editor))
           (_ (with-current-buffer (window-buffer editor)
                (let ((inhibit-read-only t)) (erase-buffer) (dotimes (i 20) (insert (format "editor line %d\n" i))))))
           (_ (drgnx-test-wait-presented))
           (with-chrome (drgnx-uitest-snapshot))
           (rect (drgnx-card-panels-ui-test--rect editor))
           (middle (list (nth 0 rect) (+ (nth 1 rect) 40) (nth 2 rect) (- (nth 3 rect) 40))))
      (dolist (w (list dock editor)) (dolist (p '(corner-radius shadow ring)) (set-window-parameter w p nil)))
      (drgnx-test-wait-presented)
      (should (drgnx-uitest-region-equal-p with-chrome (drgnx-uitest-snapshot) middle)))))

(ert-deftest drgnx-ui-card-panels/editor-card-keeps-corners-when-scrolled ()
  "An editor card has its corners cut at rest, and the four outermost corner pixels are the same after the
text scrolls one line at a time: a full-window scroll puts the window on its own layer, which the row asserts, and
the card's corners go with it."
  (drgnx-card-panels-ui-test--with-explorer
    (let* ((editor (drgnx-card-panels-ui-test--editor)))
      (should (equal (window-parameter editor 'corner-radius) (alist-get 'corner-radius drgnx-look-card)))
      (with-current-buffer (window-buffer editor)
        (let ((inhibit-read-only t))
          (erase-buffer) (dotimes (i 400) (insert (format "editor line %d with some text to scroll\n" i)))
          (goto-char (point-min))))
      (set-window-start editor (point-min))
      (drgnx-test-wait-presented)
      (let* ((r (drgnx-card-panels-ui-test--rect editor))
             (spots (list (cons (nth 0 r) (nth 1 r)) (cons (1- (nth 2 r)) (nth 1 r))
                          (cons (nth 0 r) (1- (nth 3 r))) (cons (1- (nth 2 r)) (1- (nth 3 r)))))
             (rest (drgnx-uitest-snapshot))
             (inside (drgnx-uitest-pixel rest (+ (nth 0 r) 60) (+ (nth 1 r) 60))))
        (dolist (s spots)               ; cut away: not the window's own background
          (should-not (equal (drgnx-uitest-pixel rest (car s) (cdr s)) inside)))
        ;; one line at a time: a whole-window scroll run, which promotes the window to a layer of its own (a scroll
        ;; of almost a screen is drawn again instead, in the frame); the snapshot is taken while it is promoted
        (dotimes (_ 3)
          (with-selected-window editor (scroll-up 1))
          (drgnx-test-wait-presented))
        (when (fboundp 'nhwl--scroll-layers)
          ;; `nhwl--scroll-layers' counts the frame's own outputs and its cards
          (should (> (- (nhwl--scroll-layers)
                        (seq-count (lambda (w) (window-parameter w 'glitnir--card)) (window-list nil t)))
                     0)))
        (let ((after (drgnx-uitest-snapshot)))
          (dolist (s spots)
            (should (equal (drgnx-uitest-pixel rest (car s) (cdr s)) (drgnx-uitest-pixel after (car s) (cdr s))))))))))

(ert-deftest drgnx-ui-card-panels/whole-window-scene ()
  "Explorer, editor and panel are all cards; the scene's screenshot is written for the sign-off (palette and status
bar are other modules')."
  (drgnx-card-panels-ui-test--with-explorer
    (require 'drgnx-area)
    (let ((res (with-current-buffer (get-buffer-create "*card-panels-results*")
                 (erase-buffer) (dotimes (i 10) (insert (format "result %d\n" i))) (current-buffer))))
      (unwind-protect
          (progn
            (drgnx-wb-area-show 'panel 'results res)
            (drgnx-look-cards-apply)
            (drgnx-test-wait-presented)
            (dolist (w (list (car (drgnx-wb--dock-windows)) (drgnx-card-panels-ui-test--editor)
                             (drgnx-wb-area-window 'panel)))
              (should w)
              (should (equal (window-parameter w 'corner-radius) (alist-get 'corner-radius drgnx-look-card))))
            (should (file-exists-p (drgnx-card-panels-ui-test--scene))))
        (drgnx-wb-area-hide 'panel)
        (kill-buffer res)))))

(ert-deftest drgnx-ui-card-panels/gap-is-logical ()
  "The gap between the cards is `gap' logical pixels: the dock's right divider and the frame's divider widths are
\(* gap scale) device pixels.  Pattern D (read after `drgnx-test-wait-presented').  Meaningful at a scale above 1
\(`DRGNX_UI_SCALE=2')."
  (drgnx-card-panels-ui-test--with-explorer
    (let* ((dock (car (drgnx-wb--dock-windows)))
           (want (round (* (alist-get 'gap drgnx-look-card) (frame-scale-factor)))))
      (should (eql (window-right-divider-width dock) want))
      (should (eql (frame-parameter nil 'right-divider-width) want))
      (should (eql (frame-parameter nil 'bottom-divider-width) want)))))

(provide 'card-panels-test)
;;; card-panels-test.el ends here
