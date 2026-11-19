;;; agent-proposals-gui-test.el --- GUI tests: proposals drawn as kit diff blocks in the viewed file -*- lexical-binding: t -*-
;; test-class: det
;; Flow Task 25: an agent working in its own worktree on the file you look at shows its hunk as a kit diff block after
;; the hunk's last line (an overlay `after-string' at canonical-character widths) with Accept `a' and Revert `D'
;; buttons, its session and its reason; a paired agent's edits land in the buffer and make no block.
;; No hub: the calls are caught at `drgnx-hub-call'.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(defconst agent-proposals-gui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness" "themes"))
  (add-to-list 'load-path (expand-file-name d agent-proposals-gui--repo)))
(add-to-list 'custom-theme-load-path (expand-file-name "themes" agent-proposals-gui--repo))
(require 'drgnx)
(require 'drgnx-hub-client)
(require 'drgnx-ui-kit)
(load (expand-file-name "modules/tools/drgnx-agent-proposals" drgnx-dir) nil t)

(declare-function drgnx-agent-proposals-set "drgnx-agent-proposals")
(declare-function drgnx-agent-proposals-accept "drgnx-agent-proposals")
(declare-function drgnx-agent-proposals--overlays "drgnx-agent-proposals")
(defvar drgnx-agent-proposals--list)
(defvar drgnx-agent-proposals-paired-function)

(defmacro agent-proposals-gui--in-file (&rest body)
  "BODY in a window showing a buffer of a file in a temp git project, three lines long."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "agent-proposals-gui" t)))
          (file (expand-file-name "a.txt" root)))
     (make-directory (expand-file-name ".git" root))
     (with-temp-file file (insert "one\ntwo\nthree\n"))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer (find-file-noselect file))
           (unwind-protect (progn ,@body) (set-buffer-modified-p nil) (kill-buffer)))
       (delete-directory root t))))

(defconst agent-proposals-gui--frame
  (list :proposals (vector (list :session "s1" :op 7 :index 0 :start_line 2 :end_line 2 :text "two!"
                                 :reason "rename the thing"))))

(defun agent-proposals-gui--block ()
  "The text of the first proposal block's overlay in the current buffer, or nil."
  (when-let* ((ov (car (drgnx-agent-proposals--overlays))))
    (substring-no-properties (overlay-get ov 'after-string))))

(drgnx-look-gui-deftest agent-proposals/worktree-agent-edit-shows-accept-revert ()
  "A proposal is a diff block after its hunk's last line: the file, the agent's session and reason, the added text,
and Accept and Revert as kit buttons."
  (skip-unless (display-graphic-p))
  (agent-proposals-gui--in-file
    (drgnx-agent-proposals-set (current-buffer) agent-proposals-gui--frame)
    (let ((block (agent-proposals-gui--block)) (ov (car (drgnx-agent-proposals--overlays))))
      (should block)
      (should (string-match-p "a\\.txt" block))
      (should (string-match-p "s1" block))
      (should (string-match-p "rename the thing" block))
      (should (string-match-p "two!" block))
      (should (string-match-p "Accept" block))
      (should (string-match-p "Revert" block))
      ;; after the hunk's last line: the overlay sits at the end of line 2
      (should (= (overlay-start ov) (save-excursion (goto-char (point-min)) (forward-line 1) (line-end-position))))
      ;; the rows are the diff block's: its add face is on the added line
      (let ((after (overlay-get ov 'after-string)))
        (should (eq 'drgnx-kit-diff-block-add
                    (car (ensure-list (get-text-property (string-match "two!" after) 'face after)))))))))

(drgnx-look-gui-deftest agent-proposals/pair-edit-lands-with-undo-and-no-buttons ()
  "A paired agent's edit is in the buffer (undoable) and makes no block: no overlay, no Accept or Revert."
  (skip-unless (display-graphic-p))
  (agent-proposals-gui--in-file
    (let ((drgnx-agent-proposals-paired-function (lambda (sid) (equal sid "s1"))))
      (drgnx-agent-proposals-set (current-buffer) agent-proposals-gui--frame)
      (should-not (drgnx-agent-proposals--overlays))
      (buffer-enable-undo)
      (goto-char (point-max)) (insert "four\n")
      (undo-boundary)
      (primitive-undo 1 buffer-undo-list)
      (should (equal "one\ntwo\nthree\n" (buffer-string))))))

(drgnx-look-gui-deftest agent-proposals/accept-removes-the-block ()
  "Accept marks the hunk reviewed and takes its block away; a later frame without it leaves none."
  (skip-unless (display-graphic-p))
  (agent-proposals-gui--in-file
    (let (calls)
      (cl-letf (((symbol-function 'drgnx-hub-call)
                 (lambda (m p cb &rest _) (push (cons m p) calls) (funcall cb nil nil)))
                ((symbol-function 'project-current) (lambda (&rest _) (cons 'transient root)))
                ((symbol-function 'project-root) (lambda (_) root)))
        (drgnx-agent-proposals-set (current-buffer) agent-proposals-gui--frame)
        (should (drgnx-agent-proposals--overlays))
        (goto-char (point-min)) (forward-line 1)
        (drgnx-agent-proposals-accept)
        (should (equal "review/mark" (car (car calls))))
        (should-not (drgnx-agent-proposals--overlays))
        (should-not drgnx-agent-proposals--list)))))

(drgnx-look-gui-deftest agent-proposals/same-buffer-two-frames-two-scales ()
  "A buffer shown in two windows (of frames at scales 1 and 2) gets one block per window, each overlay bound to its
window and built for that window's frame, so its pads are right at that frame's scale."
  (skip-unless (display-graphic-p))
  (agent-proposals-gui--in-file
    (let ((w1 (selected-window)) (w2 (split-window-right)) frames)
      (set-window-buffer w2 (current-buffer))
      (let ((orig (symbol-function 'drgnx-ui-kit-diff-block)))
        (cl-letf (((symbol-function 'drgnx-ui-kit-diff-block)
                   (lambda (&rest args) (push (nth 6 args) frames) (apply orig args))))
          (drgnx-agent-proposals-set (current-buffer) agent-proposals-gui--frame)))
      (let ((ovs (drgnx-agent-proposals--overlays)))
        (should (= 2 (length ovs)))
        (should (equal (sort (mapcar (lambda (o) (overlay-get o 'window)) ovs) (lambda (a b) (< (sxhash a) (sxhash b))))
                       (sort (list w1 w2) (lambda (a b) (< (sxhash a) (sxhash b))))))
        (should (= 2 (length frames)))
        (should (cl-every #'frame-live-p frames))))))
