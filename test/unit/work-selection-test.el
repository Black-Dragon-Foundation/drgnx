;;; work-selection-test.el --- one selection for every Work view -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the map client's calls are caught at `drgnx-work-client--call'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-work-client)
(require 'drgnx-hub-client)
(require 'drgnx-ai)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-space--view)
(defvar drgnx-work-map--selection)
(defvar drgnx-work-selection)
(defvar drgnx-work-selection-functions)

(defmacro work-selection-test--with-maps (names &rest body)
  "BODY with one map buffer per NAMES (views \"workspace:NAME\"), bound to `maps' in order, and the hub's calls in
`calls' (newest first)."
  (declare (indent 1))
  `(let ((calls nil) (maps nil) (drgnx-work-selection nil) (drgnx-work-selection-functions nil))
     (cl-letf (((symbol-function 'drgnx-work-client--call)
                (lambda (method params &rest _) (push (cons method params) calls) t)))
       (unwind-protect
           (progn
             (dolist (n ',names)
               (let ((b (generate-new-buffer (format " *work-selection-%s*" n))) (view (format "workspace:%s" n)))
                 (with-current-buffer b
                   (drgnx-work-map-mode)
                   (setq drgnx-work-space--view view))
                 (drgnx-work-client-open view (list :id view :roots nil))
                 (setq maps (append maps (list b)))))
             (setq calls nil)
             ,@body)
         (mapc #'kill-buffer maps)))))

(ert-deftest drgnx-work-selection/one-selection-for-all-views ()
  (work-selection-test--with-maps ("a" "b")
    (let (told)
      (add-hook 'drgnx-work-selection-functions (lambda (kind id) (push (cons kind id) told)))
      (drgnx-work-select 'plan "plan:p1")
      (should (equal '(plan . "plan:p1") drgnx-work-selection))
      (dolist (b maps)
        (should (equal '(plan . "plan:p1") (buffer-local-value 'drgnx-work-map--selection b))))
      (let ((sets (seq-filter (lambda (c) (equal (car c) "work/map/set")) calls)))
        (should (equal '("workspace:a" "workspace:b")
                       (sort (mapcar (lambda (c) (plist-get (cdr c) :view)) sets) #'string<)))
        (dolist (c sets) (should (equal "plan:p1" (plist-get (cdr c) :selected)))))
      (should (equal '((plan . "plan:p1")) told)))))

(ert-deftest drgnx-work-selection/a-move-in-one-map-reaches-the-others ()
  (work-selection-test--with-maps ("a" "b")
    (with-current-buffer (car maps)
      (setq drgnx-work-map--selection '(task . "task:t1"))
      (drgnx-work--share-selection (current-buffer) drgnx-work-map--selection))
    (should (equal '(task . "task:t1") drgnx-work-selection))
    (should (equal '(task . "task:t1") (buffer-local-value 'drgnx-work-map--selection (cadr maps))))
    (let ((sets (seq-filter (lambda (c) (equal (car c) "work/map/set")) calls)))
      (should (equal '("workspace:b") (mapcar (lambda (c) (plist-get (cdr c) :view)) sets)))
      (should (equal "task:t1" (plist-get (cdr (car sets)) :selected))))))

(ert-deftest drgnx-work-selection/result-goes-to-the-last-editor-frame ()
  ;; the grid is on (its tiles are stubbed below); with it off there are no tiles: the selected frame
  (dlet ((drgnx-grid-mode t))
    (let ((f1 'frame-1) (f2 'frame-2) (f3 'frame-3))
      (cl-letf (((symbol-function 'frame-list) (lambda () (list f1 f2 f3)))
                ((symbol-function 'frame-live-p) (lambda (_) t))
                ((symbol-function 'frame-visible-p) (lambda (_) t))
                ;; f3 was used last but has no editor tile; f2's tile was used after f1's
                ((symbol-function 'drgnx-grid-tiles)
                 (lambda (frame &optional _filter)
                   (pcase frame ('frame-1 '(w1)) ('frame-2 '(w2a w2b)) (_ nil))))
                ((symbol-function 'window-use-time)
                 (lambda (w) (pcase w ('w1 10) ('w2a 30) ('w2b 20) (_ 99)))))
        (should (eq f2 (drgnx-work--result-frame)))))
    (should-not (dlet ((drgnx-grid-mode nil)) (drgnx-work--result-frame)))))

(ert-deftest drgnx-work-selection/nothing-moves-between-monitors ()
  "Opening an item shows it in the result frame with that frame selected only for the call: no frame is made, moved
or raised."
  (let (made moved raised shown-in)
    (cl-letf (((symbol-function 'drgnx-work--result-frame) (lambda () 'frame-2))
              ((symbol-function 'selected-frame) (lambda () 'frame-1))
              ((symbol-function 'make-frame) (lambda (&rest _) (setq made t)))
              ((symbol-function 'set-frame-position) (lambda (&rest _) (setq moved t)))
              ((symbol-function 'raise-frame) (lambda (&rest _) (setq raised t)))
              ((symbol-function 'select-frame-set-input-focus) (lambda (&rest _) (setq raised t)))
              ((symbol-function 'drgnx-work--in-frame)
               (lambda (frame fn) (setq shown-in frame) (funcall fn))))
      (should (equal 'ran (drgnx-work--show-in-result-frame (lambda () 'ran))))
      (should (eq 'frame-2 shown-in))
      (should-not (or made moved raised)))))

(provide 'work-selection-test)
;;; work-selection-test.el ends here
