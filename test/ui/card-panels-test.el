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
      (should (eql (frame-parameter nil 'right-divider-width) gap))
      (let* ((on (drgnx-uitest-snapshot)) (r (drgnx-card-panels-ui-test--rect dock))
             (corner (drgnx-uitest-pixel on (nth 0 r) (nth 1 r)))
             (inside (drgnx-uitest-pixel on (+ (nth 0 r) 40) (+ (nth 1 r) 40))))
        (should-not (equal corner inside))        ; the corner is cut away: the gap shows, not the dock's background
        (drgnx-card-panels-ui-test--scene)))))

(ert-deftest drgnx-ui-card-panels/text-never-covered ()
  "The editor window's picture is the same with the card chrome as with only the card gap: chrome takes no text."
  (drgnx-card-panels-ui-test--with-explorer
    (let* ((dock (car (drgnx-wb--dock-windows)))
           (editor (seq-find (lambda (w) (not (window-parameter w 'drgnx-role))) (window-list nil 'nomini)))
           (_ (with-current-buffer (window-buffer editor)
                (let ((inhibit-read-only t)) (erase-buffer) (dotimes (i 20) (insert (format "editor line %d\n" i))))))
           (_ (drgnx-test-wait-presented))
           (with-chrome (drgnx-uitest-snapshot))
           (rect (drgnx-card-panels-ui-test--rect editor)))
      (dolist (p '(corner-radius shadow ring)) (set-window-parameter dock p nil))
      (drgnx-test-wait-presented)
      (should (drgnx-uitest-region-equal-p with-chrome (drgnx-uitest-snapshot) rect)))))

(provide 'card-panels-test)
;;; card-panels-test.el ends here
