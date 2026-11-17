;;; tiling-frames-gui-test.el --- GUI test: Move to New Window and each window's shell (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; A tile torn out to a new window (`drgnx-grid-move-to-new-frame') goes whole, a docked one loses its dock, an editor
;; keeps its start and point, and the layout before is on the stack; a tab's menu holds Move to New Window (dragging a
;; tab out of every window cannot open one: Emacs gets no release there, so the menu is the way).  Each window's shell
;; is its own.  The rows run on a frame of their own with the grid fixture; the frames they make are deleted after.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-tiling-frames--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-tiling-frames--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-tiling-frames--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-tiling-frames--repo) nil t)
(require 'drgnx-groups)
(require 'drgnx-frames)
(require 'drgnx-grid-ops)
(require 'drgnx-grid-frames)
(require 'drgnx-frame-shell)

(defvar drgnx-ui-tiling-frames--parts nil "The conversation kind's companions: (ABOVE BELOW).")
(defun drgnx-ui-tiling-frames--parts (_main) drgnx-ui-tiling-frames--parts)

(defmacro drgnx-ui-tiling-frames--with (&rest body)
  "BODY on a frame of its own (`frame') with the grid fixture, `drgnx-grid-mode' on and an empty stack; every frame
BODY made deleted after, the mode as it was."
  (declare (indent 0))
  `(progn
     (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
     (let* ((frames (frame-list)) (selected (selected-frame)) (drgnx-grid--stack nil)
            (frame (make-frame '((width . 160) (height . 50)))))
       (unwind-protect
           (with-selected-frame frame
             (drgnx-grid-test--with
               (let ((was drgnx-grid-mode))
                 (unless was (drgnx-grid-mode 1))
                 (unwind-protect
                     (progn (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p frame)) :secs 10
                                             :what "the frame mapped")
                            ,@body)
                   (unless was (drgnx-grid-mode -1))))))
         (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
         (when (frame-live-p selected) (select-frame selected))))))

(defun drgnx-ui-tiling-frames--buffer (name lines)
  "Buffer NAME holding LINES numbered lines."
  (with-current-buffer (get-buffer-create name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dotimes (i lines) (insert (format "%s line %d\n" name (1+ i)))))
    (current-buffer)))

(defun drgnx-ui-tiling-frames--buffers (frame)
  (mapcar #'window-buffer (window-list frame 'nomini)))

(ert-deftest drgnx-ui-tiling-frames/move-to-new-window-moves-a-dock-tile ()
  (drgnx-ui-tiling-frames--with
    ;; the session's panel: a docked area, its shown tab the tile's kind
    (let* ((w (drgnx-wb-area-show 'panel)) (tab (drgnx-wb-area-tab 'panel)) (b (window-buffer w)))
      (should (window-parameter w 'drgnx-tile-dock))
      (let* ((new (drgnx-grid-move-to-new-frame w)) (main (frame-first-window new)))
        (should (frame-live-p new))
        (should-not (eq new frame))
        (should-not (drgnx-wb-area-window 'panel frame))
        (should-not (memq b (drgnx-ui-tiling-frames--buffers frame)))
        (should (= 1 (length (drgnx-grid-tiles new))))
        (should (drgnx-grid-tool-tile-p main))
        (should (equal (window-parameter main 'drgnx-pane-stack) (list tab)))
        (should (eq (window-buffer main) b))
        (should-not (window-parameter main 'drgnx-tile-dock))
        (should (eq (selected-frame) new))))))

(ert-deftest drgnx-ui-tiling-frames/move-to-new-window-moves-a-conversation ()
  ;; a conversation is three windows, one atom: the transcript and its two companions go together
  (drgnx-ui-tiling-frames--with
    (let* ((transcript (drgnx-ui-tiling-frames--buffer "*g-conv*" 20))
           (drgnx-ui-tiling-frames--parts (list (drgnx-ui-tiling-frames--buffer "*g-conv-above*" 2)
                                                (drgnx-ui-tiling-frames--buffer "*g-conv-below*" 1))))
      (drgnx-pane-define-kind 'g-conv :title "Conversation" :home 'right :size 40 :buffer transcript
                              :companions #'drgnx-ui-tiling-frames--parts)
      ;; a tool tile of its own (a docked area draws its companions its own way)
      (let ((w (drgnx-grid--new-tile (selected-window) 'right '(g-conv))) (three (cons transcript drgnx-ui-tiling-frames--parts)))
        (should (cl-subsetp three (drgnx-ui-tiling-frames--buffers frame)))
        (let ((new (drgnx-grid-move-to-new-frame w)))
          (should (cl-every (lambda (b) (memq b (drgnx-ui-tiling-frames--buffers new))) three))
          (should (= 3 (length (window-list new 'nomini))))
          (should-not (window-live-p (frame-root-window new)))   ; one atom, its root an internal window
          (should-not (seq-intersection three (drgnx-ui-tiling-frames--buffers frame)))
          (should (= 1 (length (drgnx-grid-tiles new)))))))))

(ert-deftest drgnx-ui-tiling-frames/move-to-new-window-pushes-a-snapshot ()
  (drgnx-ui-tiling-frames--with
    (drgnx-pane-show 'g-term)
    (let ((before (drgnx-grid-tree frame)) (id (drgnx-grid-frame-id frame)))
      (drgnx-grid-move-to-new-frame (drgnx-grid-window 'g-term frame))
      (let ((top (car drgnx-grid--stack)))
        (should (eq (plist-get top :why) 'tear-out))
        (should (equal (plist-get (seq-find (lambda (s) (eql (plist-get s :id) id)) (plist-get top :frames)) :tree)
                       before))))))

(ert-deftest drgnx-ui-tiling-frames/move-to-new-window-keeps-point-and-start ()
  (drgnx-ui-tiling-frames--with
    (let* ((b (drgnx-ui-tiling-frames--buffer "*g-long*" 300))
           (w (drgnx-groups-split-right)))
      (set-window-buffer w b)
      (set-window-parameter w 'drgnx-tabs (list b))
      (let ((start (with-current-buffer b (save-excursion (goto-char (point-min)) (forward-line 100) (point))))
            (point (with-current-buffer b (save-excursion (goto-char (point-min)) (forward-line 110) (point)))))
        (set-window-start w start)
        (set-window-point w point)
        (redisplay t)
        (let* ((new (drgnx-grid-move-to-new-frame w)) (main (frame-first-window new)))
          (redisplay t)
          (should (eq (window-buffer main) b))
          (should (equal (window-parameter main 'drgnx-tabs) (list b)))
          (should (= (window-start main) start))
          (should (= (window-point main) point))
          (should-not (memq b (drgnx-ui-tiling-frames--buffers frame))))))))

(ert-deftest drgnx-ui-tiling-frames/drag-tab-out-makes-a-frame ()
  ;; The documented fallback (P4: a release outside every window never reaches Emacs): the tab's menu
  (drgnx-ui-tiling-frames--with
    (let* ((w (drgnx-grid--new-tile (selected-window) 'below '(g-term g-problems)))
           (item (cdr (assq 'move-to-new-window (cddr (drgnx-grid-tab-menu w 'g-term))))))
      (should (equal (cadr item) "Move to New Window"))
      (should (equal (sort (copy-sequence (window-parameter w 'drgnx-pane-stack)) #'string<) '(g-problems g-term)))
      (funcall (nth 2 item))
      (let ((new (selected-frame)))
        (should-not (eq new frame))
        (should (equal (window-parameter (frame-first-window new) 'drgnx-pane-stack) '(g-term)))
        ;; only that tab moved: the other stays in its tile
        (should (equal (window-parameter w 'drgnx-pane-stack) '(g-problems)))))))

(ert-deftest drgnx-ui-tiling-frames/torn-out-frame-has-its-own-shell ()
  (drgnx-ui-tiling-frames--with
    (drgnx-pane-show 'g-term)
    (let ((new (drgnx-grid-move-to-new-frame (drgnx-grid-window 'g-term frame))))
      (should (drgnx-shell-get frame :rail))
      (should (drgnx-shell-get new :rail))
      ;; the toggle in the new window changes only it
      (with-selected-frame new (drgnx-shell-toggle-rail))
      (should-not (drgnx-shell-get new :rail))
      (should (eq (frame-parameter new 'drgnx-rail) 'hidden))
      (should (drgnx-shell-get frame :rail))
      (should-not (frame-parameter frame 'drgnx-rail))
      (with-selected-frame frame (drgnx-shell-toggle-title))
      (should-not (drgnx-shell-get frame :title))
      (should (drgnx-shell-get new :title)))))

(provide 'tiling-frames-gui-test)
;;; tiling-frames-gui-test.el ends here
