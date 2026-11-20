;;; shell-rail-gui-test.el --- GUI tests: the layout A shell, places in the docks (Flow Task 19; run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Written against the interfaces the plan names: the kit's rail (kit Task 17: `drgnx-rail-places', `drgnx-rail-mode',
;; `drgnx-rail-mark-changed' / `-clear-changed', the commands `place-work' … `place-extensions') and this task's
;; `drgnx-shell-show-place' (a place's view in the side-bar dock tile; the current place toggles it) and
;; `drgnx-shell-changed-producers' (each place's own signal).  They cannot fail for their own reason until the kit's
;; rail is on the line (r6-kit); `drgnx-shell-right-for' and the frame's `drgnx-rail' parameter exist since tiling Task 11.
;; Not repeated here: the rail's label and 44 px width (the kit's `drgnx-rail/changed-dot-is-labelled',
;; `drgnx-rail-ui/rail-is-44-px-at-every-scale'); and `:rail nil' writing `hidden' (tiling Task 11's tests).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-frame-shell)

(defconst drgnx-ui-shell-rail--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness" "modules/ui"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-shell-rail--repo)))

(declare-function drgnx-rail-places "drgnx-rail" ())
(declare-function drgnx-rail-changed-p "drgnx-rail" (place &optional frame))
(declare-function drgnx-rail-mark-changed "drgnx-rail" (place &optional frame))
(declare-function drgnx-shell-show-place "drgnx-frame-shell" (place))
(declare-function drgnx-shell-right-for "drgnx-frame-shell" (place))
(declare-function drgnx-shell-changed-producers "drgnx-frame-shell" ())

(ert-deftest drgnx-ui-shell-rail/every-frame-has-a-rail-with-seven-places ()
  "Two frames each have the rail (the frame parameter `drgnx-rail' is not `hidden') and the rail has the seven places."
  (skip-unless (display-graphic-p))
  (require 'drgnx-rail)
  (let ((f2 (make-frame)))
    (unwind-protect
        (dolist (f (list (selected-frame) f2))
          (should (= 7 (length (drgnx-rail-places))))
          (should-not (eq 'hidden (frame-parameter f 'drgnx-rail))))
      (delete-frame f2))))

(ert-deftest drgnx-ui-shell-rail/place-shows-in-the-side-bar-dock-tile ()
  "A place command shows the place's view in the side-bar dock tile, and on the current place it toggles the side bar."
  (skip-unless (display-graphic-p))
  (let (shown hidden)
    (cl-letf (((symbol-function 'drgnx-pane-show) (lambda (kind &rest args) (push (cons kind args) shown)))
              ((symbol-function 'drgnx-pane-hide) (lambda (kind &rest _) (push kind hidden))))
      (drgnx-shell-show-place 'search)
      (should (eq 'side-bar (car (car (last shown)))))
      (should (eq 'search (plist-get (cdr (car (last shown))) :place)))
      ;; the same place again: the side bar toggles away
      (drgnx-shell-show-place 'search)
      (should (equal '(side-bar) hidden)))))

(ert-deftest drgnx-ui-shell-rail/place-sets-the-right-side ()
  "A place also sets the right side: the kind `drgnx-shell-right-for' names is shown in the right dock tile."
  (skip-unless (display-graphic-p))
  (let (shown)
    (cl-letf (((symbol-function 'drgnx-pane-show) (lambda (kind &rest _) (push kind shown))))
      (drgnx-shell-show-place 'files)
      (should (memq (drgnx-shell-right-for 'files) shown)))))

(ert-deftest drgnx-ui-shell-rail/a-changed-place-gets-its-dot ()
  "Each place but Work has a producer of its own that calls `drgnx-rail-mark-changed'; running one gives the place its dot."
  (skip-unless (display-graphic-p))
  (require 'drgnx-rail)
  (let ((producers (drgnx-shell-changed-producers)))
    (dolist (place (remq 'work (drgnx-rail-places)))
      (should (functionp (alist-get place producers))))
    (funcall (alist-get 'search producers))
    (should (drgnx-rail-changed-p 'search))))

(provide 'shell-rail-gui-test)
;;; shell-rail-gui-test.el ends here
