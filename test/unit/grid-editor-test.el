;;; grid-editor-test.el --- batch tests: editor tiles: split, the tile picker, Close Tile -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)   ; `drgnx-grid-test--with' and its kinds
(require 'drgnx-groups)

(defmacro drgnx-grid-editor-test--answering (answer &rest body)
  "BODY with `completing-read' answering ANSWER (a string), or quitting when ANSWER is `quit'."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) (if (eq ,answer 'quit) (signal 'quit nil) ,answer))))
     ,@body))

(ert-deftest drgnx-grid-editor/split-an-editor-copies-the-buffer ()
  (drgnx-grid-test--with
    (let* ((b (get-buffer-create "*g-file*")) (editor (selected-window)))
      (set-window-buffer editor b)
      (let ((new (drgnx-groups-split-right)))
        (drgnx-state-sync)
        (should (eq (window-buffer new) b))
        (should (eq (selected-window) new))
        (should (drgnx-grid-editor-tile-p new))
        (should (window-parameter new 'drgnx-tile-id))
        (should (= 2 (length (drgnx-grid-tiles nil 'editor))))))))

(ert-deftest drgnx-grid-editor/split-a-tool-tile-asks-for-a-kind ()
  ;; on the right dock's tile: a new tile below the whole tile, showing the kind picked (Term moves there)
  (drgnx-grid-test--with
    (let* ((chat (drgnx-pane-show 'g-chat)) (asked nil))
      (select-window chat)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest _)
                   (setq asked (mapcar (lambda (c) (if (consp c) (car c) c)) choices))
                   "Term")))
        (drgnx-groups-split-down))
      (should (member "Editor" asked))
      (should (member "Term" asked))
      (let ((term (drgnx-pane-window 'g-term)))
        (should (window-live-p term))
        (should (drgnx-grid-tool-tile-p term))
        (should (eq (window-buffer term) (get-buffer " *drgnx g-term*")))
        (should (= (window-pixel-left term) (window-pixel-left chat)))           ; below the right dock's tile
        (should (= (window-pixel-top term) (nth 3 (window-pixel-edges chat)))))
      (should (eq (drgnx-pane-window 'g-chat) chat))                             ; the tile it was split from stays
      (should-not (drgnx-wb-area-window 'panel)))))                              ; Term moved: no panel for it

(ert-deftest drgnx-grid-editor/picking-editor-makes-an-editor-tile ()
  (drgnx-grid-test--with
    (let* ((b (get-buffer-create "*g-file*")) (chat (drgnx-pane-show 'g-chat)))
      (set-window-buffer (selected-window) b)
      (select-window chat)
      (let ((new (drgnx-grid-editor-test--answering "Editor" (drgnx-groups-split-down))))
        (should (drgnx-grid-editor-tile-p new))
        (should (eq (window-buffer new) b))
        (should (= 2 (length (drgnx-grid-tiles nil 'editor))))))))

(ert-deftest drgnx-grid-editor/quitting-the-picker-leaves-no-tile ()
  (drgnx-grid-test--with
    (let* ((chat (drgnx-pane-show 'g-chat)) (before (window-list nil 'nomini)))
      (select-window chat)
      (should (eq 'quit (car (condition-case e (drgnx-grid-editor-test--answering 'quit (drgnx-groups-split-down))
                               (quit e)))))
      (should (eq (selected-window) chat))
      (should (seq-set-equal-p (window-list nil 'nomini) before)))))

(ert-deftest drgnx-grid-editor/close-a-tool-tile-hides-it ()
  (drgnx-grid-test--with
    (let ((term (drgnx-pane-show 'g-term)) (editors (drgnx-grid-tiles nil 'editor)))
      (select-window term)
      (drgnx-groups-close)
      (should-not (drgnx-pane-window 'g-term))
      (should (equal (drgnx-grid-tiles nil 'editor) editors))
      (should (eq (drgnx-pane-window 'g-term) nil))
      (should (drgnx-pane-show 'g-term)))))                                      ; it comes back

(ert-deftest drgnx-grid-editor/last-editor-tile-cannot-close ()
  (drgnx-grid-test--with
    (drgnx-state-sync)
    (should-error (drgnx-groups-close) :type 'user-error)
    (should (= 1 (length (drgnx-grid-tiles nil 'editor))))))
