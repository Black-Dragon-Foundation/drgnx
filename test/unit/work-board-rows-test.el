;;; work-board-rows-test.el --- batch tests: the Board on the rows path, its rows the hub's and its keys from its own model -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub: a map buffer is attached as a hub-fed
;; view with a model of its own, the Board is opened beside it (`drgnx-hub-call' records what it asks), and the
;; Board's model and rows (shaped like work::trail::board's) are handed to it as the hub would.  Each test names its
;; pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-board" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-board-rows-test--n 0 "Each run's views get names of their own in Sjá.")

(defun drgnx-work-board-rows-test--map-model ()
  "A map model of one agent, `agent:s1'."
  (json-serialize
   (list :ops
         (vector
          (list :reset
                (list :descriptor (list :scheme "links" :chain_kinds [] :match_fields ["label"] :lists ["team"]
                                        :classes ["selected" "match" "dim"] :flags [] :forms [] :start "team")
                      :nodes (vector (list :id "agent:s1" :kind "agent" :flags 0 :fields [["label" "s1"]]))
                      :edges []
                      :lists (vector (list :name "team" :ids ["agent:s1"]))))))))

(defun drgnx-work-board-rows-test--board-model ()
  "The hub's Board: a and b queued, c running (its agent s1); the `board' form's links, `team' holding c."
  (let ((card (lambda (id nav fields) (list :id id :kind "card" :flags 0 :navs (list :board nav)
                                            :fields (vconcat fields)))))
    (json-serialize
     (list :ops
           (vector
            (list :reset
                  (list :descriptor (list :scheme "links" :chain_kinds [] :match_fields ["label"]
                                          :lists ["cards" "team"] :classes ["selected" "match" "lit" "dim"]
                                          :flags [] :forms (vector (list :name "board")) :start "cards")
                        :nodes (vector
                                (funcall card "task:a" (list :down "task:b" :right "task:c")
                                         '(["label" "A"] ["status" "open"] ["column" "queued"]))
                                (funcall card "task:b" (list :up "task:a" :right "task:c")
                                         '(["label" "B"] ["status" "open"] ["column" "queued"]))
                                (funcall card "task:c" (list :left "task:a")
                                         '(["label" "C"] ["status" "running"] ["column" "running"]
                                           ["agent" "agent:s1"] ["agent-label" "S1"])))
                        :edges []
                        :lists (vector (list :name "cards" :ids ["task:a" "task:b" "task:c"])
                                       (list :name "team" :ids ["task:c"])))))))))

(defun drgnx-work-board-rows-test--rows ()
  "The hub's Board rows: the headings, then a title row and a state row for card height 0 and 1."
  (let ((row (lambda (key text ids)
               (list :key key :text text
                     :props (mapcar (lambda (span) (list (nth 0 span) (nth 1 span) "drgnx-work-id" (nth 2 span))) ids)))))
    (list (funcall row "head" "Queued · 2  Running · 1" nil)
          (funcall row "cards:0:0" "● A  ● C" '((0 3 "task:a") (5 8 "task:c")))
          (funcall row "cards:0:1" "open  running · S1" '((0 4 "task:a") (6 18 "task:c")))
          (funcall row "cards:1:0" "● B" '((0 3 "task:b")))
          (funcall row "cards:1:1" "open" '((0 4 "task:b"))))))

(defmacro drgnx-work-board-rows-test--with (&rest body)
  "BODY with MAP a hub-fed map buffer (agent s1 selected) and BOARD its Board opened on the rows path, the Board's
model and rows applied; CALLS holds what was asked of the hub.  Nothing is sent."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let* ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
            (drgnx-view-model--views (make-hash-table :test #'equal))
            (drgnx-view-patch--hooked nil)
            (drgnx-view-old-path nil)
            (drgnx-view-patch-send-function #'ignore)
            (mview (format "wbr-test-%d" (cl-incf drgnx-work-board-rows-test--n)))
            (bview (concat mview "/board"))
            (calls nil)
            (map (generate-new-buffer "*drgnx work: wbr-test*"))
            (board nil))
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-hub-call)
                      (lambda (method params _cb &rest _) (push (cons method params) calls)))
                     ((symbol-function 'drgnx-view-env-register) #'ignore))
             (with-current-buffer map
               (drgnx-view-patch-attach mview "c" :epoch 1)
               (drgnx-view-model-event (list :view mview :hub 7 :base 0 :version 1 :reset t
                                             :model (drgnx-work-board-rows-test--map-model)))
               (drgnx-view-model--due mview)
               (drgnx-view-nav 'select "agent:s1"))
             (setq board (drgnx-work-board-open map))
             (with-current-buffer board
               (drgnx-view-model-event (list :view bview :hub 7 :base 0 :version 1 :reset t
                                             :model (drgnx-work-board-rows-test--board-model)))
               (drgnx-view-apply-patch (list :view bview :class "c" :hub 7 :base 0 :version 1 :env_epoch 1 :model 1
                                             :ops (list (list :reset (drgnx-work-board-rows-test--rows)))))
               (drgnx-view-draw-now drgnx-view))
             ,@body)
         (drgnx-view-patch-teardown)
         (dolist (b (list board map))
           (when (buffer-live-p b)
             (drgnx-timer-cancel (cons 'drgnx-view b))
             (drgnx-timer-cancel (cons 'drgnx-view-nav-notice b))
             (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
         (drgnx-timer-cancel (cons 'drgnx-view-model mview))
         (drgnx-timer-cancel (cons 'drgnx-view-model bview))))))

(ert-deftest drgnx-work-board/rows-come-from-the-hub ()
  "Pattern D: on the rows path the Board beside a map view VIEW is the hub-fed view VIEW/board in the map's class: it
asks `work/board/subscribe' for it (the map view whose agents go on the cards) and shows the hub's rows as they come."
  (drgnx-work-board-rows-test--with
    (should (equal (list (cons "work/board/subscribe" (list :view bview :map mview :plans [])))
                   calls))
    (with-current-buffer board
      (should (equal bview (drgnx-view-patch-view drgnx-view-patch)))
      (should (equal "c" (drgnx-view-patch-class drgnx-view-patch)))
      (should (equal "Queued · 2  Running · 1\n● A  ● C\nopen  running · S1\n● B\nopen\n"
                     (buffer-substring-no-properties (point-min) (point-max))))
      ;; asked again (the map changed): the same view, no drawing here
      (drgnx-work-board-refresh board)
      (should (= 2 (length calls))))))

(ert-deftest drgnx-work-board/a-cards-bar-is-two-sized-spaces ()
  "Pattern D: a card's progress bar comes as a row of `spaces' (`work::trail::board'): each is shown as a space of
its width and height in device px, `(space :width (W) :height (H))', in its run's face, the done part
`drgnx-work-bar' and the rest `drgnx-work-bar-rest'; the bar holds its card's id."
  (drgnx-work-board-rows-test--with
    (with-current-buffer board
      (drgnx-view-apply-patch
       (list :view bview :class "c" :hub 7 :base 1 :version 2 :env_epoch 1 :model 1
             :ops (list (list :insert (list :after "cards:0:1"
                                            :rows (list (list :key "cards:0:2" :text "  "
                                                              :runs '((0 1 "drgnx-work-bar") (1 2 "drgnx-work-bar-rest"))
                                                              :props '((0 2 "drgnx-work-id" "task:a"))
                                                              :spaces '((0 46 4) (1 138 4)))))))))
      (drgnx-view-draw-now drgnx-view)
      (goto-char (point-min))
      (forward-line 3)
      (should (equal "  " (buffer-substring-no-properties (point) (line-end-position))))
      (should (equal '(space :width (46) :height (4)) (get-text-property (point) 'display)))
      (should (memq 'drgnx-work-bar (ensure-list (get-text-property (point) 'face))))
      (should (equal '(space :width (138) :height (4)) (get-text-property (1+ (point)) 'display)))
      (should (memq 'drgnx-work-bar-rest (ensure-list (get-text-property (1+ (point)) 'face))))
      (should (equal "task:a" (get-text-property (1+ (point)) 'drgnx-work-id))))))

(ert-deftest drgnx-work-board/board-form-moves-across-columns ()
  "Pattern D: the Board's keys follow its model's `board' form: down within a column, right across to the next column
with cards, left back; the agent keys walk the cards an agent works on; open opens the selected card's agent."
  (drgnx-work-board-rows-test--with
    (with-current-buffer board
      (drgnx-work-board--nav 'down)
      (should (equal "task:a" (drgnx-view-nav-selection)))
      (drgnx-work-board--nav 'down)
      (should (equal "task:b" (drgnx-view-nav-selection)))
      (drgnx-work-board--nav 'right)
      (should (equal "task:c" (drgnx-view-nav-selection)))
      (drgnx-work-board--nav 'left)
      (should (equal "task:a" (drgnx-view-nav-selection)))
      (drgnx-work-board--nav 'next-agent)
      (should (equal "task:c" (drgnx-view-nav-selection)))
      (let ((opened nil))
        (cl-letf (((symbol-function 'drgnx-work--open-agent) (lambda (sid) (push sid opened))))
          (drgnx-work-board--nav 'open))
        (should (equal '("s1") opened))))))

(ert-deftest drgnx-work-board/its-selection-is-its-own ()
  "Pattern D: the Board's selection is its own (the user's call on Task 11): moving it leaves the map's selection where
it was, moving the map's leaves the Board's, and switching back to the map from the Board selects nothing there."
  (drgnx-work-board-rows-test--with
    (with-current-buffer board
      (drgnx-work-board--nav 'down)                     ; from nothing: the first card
      (drgnx-work-board--nav 'right))
    (with-current-buffer board (should (equal "task:c" (drgnx-view-nav-selection))))
    (with-current-buffer map (should (equal "agent:s1" (drgnx-view-nav-selection))))
    (with-current-buffer map (drgnx-view-nav 'select nil))
    (with-current-buffer board (should (equal "task:c" (drgnx-view-nav-selection))))
    (let ((selected nil))
      (cl-letf (((symbol-function 'drgnx-work-map-select) (lambda (sel) (push sel selected)))
                ((symbol-function 'pop-to-buffer-same-window) #'ignore))
        (with-current-buffer board
          (setq-local drgnx-work-lens--map map)
          (drgnx-work-lens-switch 'map)))
      (should-not selected))))

;;; work-board-rows-test.el ends here
