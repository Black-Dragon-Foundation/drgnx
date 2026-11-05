;;; work-rows-test.el --- the map's rows, from a frame: pure functions of the cached frame -*- lexical-binding: t -*-
;; test-class: det
;; The Work map's text is a function of the cached frame (core/drgnx-work-client.el): no hub, process or clock.
;; Pattern D: pure.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-map-row-text "drgnx-work-map")
(declare-function drgnx-work-map-outline "drgnx-work-map")
(declare-function drgnx-work-map--layout-keys "drgnx-work-map")
(defvar drgnx-work-map-scale)

(defun drgnx-work-rows-test--state ()
  (drgnx-work-client-init (drgnx-work-fixture-frame)))

(defun drgnx-work-rows-test--flat (s)
  "S as plain text with each `display' space shown as <N>, N its pixel column (a golden holds positions too)."
  (let ((pos 0) (out nil))
    (while (< pos (length s))
      (let* ((next (next-single-property-change pos 'display s (length s))) (d (get-text-property pos 'display s)))
        (push (cond ((and (consp d) (eq (car d) 'space))
                     (let ((a (plist-get (cdr d) :align-to))) (format "<%s>" (if (consp a) (car a) a))))
                    (d "<img>")
                    (t (substring-no-properties s pos next)))
              out)
        (setq pos next)))
    (apply #'concat (nreverse out))))

(defun drgnx-work-rows-test--golden ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/work-space/rows-golden.eld" drgnx-dir))
    (read (current-buffer))))

(ert-deftest drgnx-work-rows/golden-rows-of-the-fixture ()
  ;; every row of the fixture frame at scale 1: its text and the pixel columns of its cards
  (let* ((drgnx-work-map-scale 1) (state (drgnx-work-rows-test--state))
         (actual (mapcar (lambda (key) (cons key (drgnx-work-rows-test--flat (drgnx-work-map-row-text state key))))
                         (drgnx-work-map--layout-keys state)))
         (golden (condition-case nil (drgnx-work-rows-test--golden) (error nil))))
    (unless (equal actual golden)
      (let ((print-length nil) (print-level nil)) (message "ROWS-ACTUAL\n%S\nROWS-END" actual))
      (ert-fail (list "the rows differ from test/fixtures/work-space/rows-golden.eld; actual:" actual)))
    ;; and the properties: each newline fixes its line's height, each card line names its item
    (dolist (key (drgnx-work-map--layout-keys state))
      (let ((text (drgnx-work-map-row-text state key)) (pos 0))
        (while (setq pos (string-search "\n" text pos))
          (should (get-text-property pos 'line-height text))
          (setq pos (1+ pos)))))
    (let ((text (drgnx-work-map-row-text state '(:row 4 0 0))))
      (should (equal "agent:a1" (get-text-property (string-search "hub rows" text) 'drgnx-work-id text))))))

(ert-deftest drgnx-work-rows/field-change-redraws-only-its-row ()
  (drgnx-test-with-modules '(tools/work-space)
    (let* ((drgnx-work-map-scale 1) (id "work-rows-test") (frame (drgnx-work-fixture-frame))
           (drgnx-work-client--views (make-hash-table :test #'equal))
           (drgnx-work-client-change-functions '(drgnx-work-map--changed)))
      (puthash id (drgnx-work-client--make-view :id id :state (drgnx-work-client-init frame) :status 'live)
               drgnx-work-client--views)
      (drgnx-work-fixture-with-buffer
        (drgnx-work-map-mode)
        (setq drgnx-work-space--view id drgnx-work-map--outline 'off)      ; a batch Emacs has no graphic frame
        (drgnx-view-attach 'work-map)
        (drgnx-view-touch drgnx-view)
        (drgnx-view-draw-now drgnx-view)
        (let ((drawn (plist-get (drgnx-view-stats drgnx-view) :rows-drawn)))
          (drgnx-work-client-event
           "work-map" (plist-put (drgnx-work-fixture-delta
                                  4 3 :changed (list (drgnx-work-fixture-changed frame "agent:a1" :minutes 33)))
                                 :view id))
          (drgnx-view-draw-now drgnx-view)
          (should (= 1 (- (plist-get (drgnx-view-stats drgnx-view) :rows-drawn) drawn)))
          (should (string-search "33 min" (buffer-string))))))))

(ert-deftest drgnx-work-rows/compact-keeps-the-overlap-mark ()
  (let* ((drgnx-work-map-scale 1) (state (drgnx-work-rows-test--state)))
    (puthash "agent:a2" "compact" (plist-get (drgnx-work-client-layout state) :form))
    (let* ((text (substring-no-properties (drgnx-work-map-row-text state '(:row 4 0 0))))
           (lines (split-string text "\n")))
      (should (string-match-p "⚠" (nth 1 lines)))               ; line 2 of the compact card carries the mark
      (should (string-match-p "fx-sess" (nth 0 lines))))))

(ert-deftest drgnx-work-rows/subagent-under-its-parent ()
  (let* ((drgnx-work-map-scale 1) (state (drgnx-work-rows-test--state)) (keys (drgnx-work-map--layout-keys state)))
    (should (< (cl-position '(:row 4 0 0) keys :test #'equal) (cl-position '(:row 4 0 1) keys :test #'equal)))
    (should (= 2 (- (cl-position '(:row 4 0 1) keys :test #'equal)
                    (cl-position '(:row 5 0 0) keys :test #'equal))))   ; after the parent's branch row and a band
    (let ((text (drgnx-work-map-row-text state '(:row 4 0 1))))
      (should (string-search "explore" text))
      (should (equal "agent:a1/t1" (get-text-property (string-search "explore" text) 'drgnx-work-id text)))
      ;; indented under the parent: its card starts to the right of the parent's
      (should (> (plist-get (drgnx-work-client-rect state "agent:a1/t1") :x)
                 (plist-get (drgnx-work-client-rect state "agent:a1") :x))))))

(ert-deftest drgnx-work-rows/an-emoji-ask-keeps-the-row-height ()
  ;; an emoji in an ask's words is cut by the width of its chip, and the row's lines keep their height
  (let* ((drgnx-work-map-scale 1) (plain (drgnx-work-rows-test--state)) (emoji (drgnx-work-rows-test--state))
         (it (copy-sequence (drgnx-work-client-item emoji "ask:1"))))
    (puthash "ask:1" (plist-put it :label "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀 ship it right now please") (drgnx-work-client-items emoji))
    (let ((a (drgnx-work-map-row-text plain '(:row 1 0 0))) (b (drgnx-work-map-row-text emoji '(:row 1 0 0))))
      (should (equal (get-text-property (string-search "\n" a) 'line-height a)
                     (get-text-property (string-search "\n" b) 'line-height b)))
      (should (= 1 (length (split-string (string-trim-right b "\n") "\n"))))
      (should-not (string-search "please" b)))))

(ert-deftest drgnx-work-rows/outline-at-80-and-120-columns ()
  (let ((state (drgnx-work-rows-test--state)))
    (dolist (cols '(80 120))
      (let* ((text (drgnx-work-map-outline state cols)) (lines (split-string text "\n" t)))
        (should (cl-every (lambda (l) (<= (string-width l) cols)) lines))
        (should (seq-some (lambda (l) (string-match-p "\\`● Opus · hub rows" l)) lines))
        (should (seq-some (lambda (l) (string-match-p "\\`   why: +you: \"fix deferred testing rows\"" l)) lines))
        (should (seq-some (lambda (l) (string-match-p "\\`   touches: +.*rp-df-hub" l)) lines))
        (should (seq-some (lambda (l) (string-match-p "turn_core drops the started flag" l)) lines))))))

(ert-deftest drgnx-work-rows/no-literal-colour ()
  ;; the map's files take every colour from faces: no hex colour, no colour name in a face spec
  (dolist (f '("modules/tools/drgnx-work-map.el" "modules/tools/drgnx-work-space.el"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name f drgnx-dir))
      (goto-char (point-min))
      (should-not (re-search-forward "\"#[0-9a-fA-F]\\{3,8\\}\"\\|:\\(foreground\\|background\\|color\\) +\"" nil t)))))

;;;; The strip and the lens (header line and tab line)

(declare-function drgnx-work-map--strip-string "drgnx-work-map")
(declare-function drgnx-work-map--lens-string "drgnx-work-map")

(ert-deftest drgnx-work-rows/strip-has-no-eval-work ()
  (let* ((state (drgnx-work-rows-test--state)) (strip (substring-no-properties (drgnx-work-map--strip-string state))))
    ;; needs you: a chip with its jump key; the machines' load on the right
    (should (string-search "⚑ Codex asks: cargo clippy" strip))
    (should (string-search "g1" strip))
    (should (string-search "desktop 3/16" strip))
    ;; the card covers the agent that needs you, so no chip of its own; more than nine: a +N
    (let ((many (copy-sequence (drgnx-work-fixture-frame))))
      (setq many (plist-put many :needs_you
                            (cl-loop for i from 1 to 11
                                     collect (list :card (format "card:%d" i) :kind "push" :text (format "push %d" i)
                                                   :about '("agent:a1")))))
      (let ((s (substring-no-properties (drgnx-work-map--strip-string (drgnx-work-client-init many)))))
        (should (string-search "g9" s))
        (should-not (string-search "g10" s))
        (should (string-search "+3" s))))                       ; 11 cards + the one agent without a card, less 9
    ;; the lines hold variables the draw fills: nothing is worked out while redisplay reads them
    (with-temp-buffer
      (drgnx-work-map-mode)
      (should-not (memq :eval (flatten-tree header-line-format)))
      (should-not (memq :eval (flatten-tree tab-line-format)))
      (should (string-search "Map" (substring-no-properties (drgnx-work-map--lens-string))))
      (should (string-search "Board" (substring-no-properties (drgnx-work-map--lens-string))))
      (should (string-search "Timeline" (substring-no-properties (drgnx-work-map--lens-string)))))))

(provide 'work-rows-test)
;;; work-rows-test.el ends here
