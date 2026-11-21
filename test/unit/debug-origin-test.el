;;; debug-origin-test.el --- batch tests: the origin trail -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call' replaced): what is tested is what the editor asks, sends and draws.
;; The tracer, the levels and the card's rows have Rust tests (debug::tests_origin).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-origin" drgnx-dir) nil t)

(defvar debug-origin-test--calls nil "Every (METHOD . PARAMS) the test's hub was asked, in order.")

(defconst debug-origin-test--event
  (list :origin "o1" :state "done"
        :links (vector (list :level 1 :target "shortfall" :value "16" :path "/p/stock.py" :line 3 :traced t
                             :operands (vector (vector "item.min" "10") (vector "item.reserve" "8")))
                       (list :level 2 :target "item.reserve" :value "8" :path "/p/stock.py" :line 2 :traced t
                             :operands []))
        :rows (vector (list :key "head" :text "Where did shortfall come from? · run 4, stop 3 · done")
                      (list :key "link:0" :text "← shortfall = 16" :props (vector (vector 0 16 "drgnx-debug-origin-link" 0)))
                      (list :key "link:1" :text "  ← item.reserve = 8" :props (vector (vector 0 20 "drgnx-debug-origin-link" 1)))))
  "A `debug-origin' event: a trail of two links, with its card.")

(defmacro debug-origin-test--with (&rest body)
  "BODY with the hub scripted, the events mode on, and a past stop shown (run r1, stop 3)."
  (declare (indent 0))
  `(let ((debug-origin-test--calls nil))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params cb &rest _)
                  (setq debug-origin-test--calls (append debug-origin-test--calls (list (cons method params))))
                  (funcall cb (pcase method
                                ("debug/origin" (list :origin "o1"))
                                ("debug/run/stop"
                                 (list :run "r1" :stop (list :index 3 :reason "breakpoint" :line 5)
                                       :capture (list :frames [] :scopes [])
                                       :source (list :path (plist-get params :file)
                                                     :text "class Item: pass\nitem.reserve = 8\nshortfall = 16\n")))
                                (_ t))
                           nil)
                  1)))
       (unwind-protect
           (progn (drgnx-debug-origin-events-mode 1)
                  (with-temp-buffer
                    (insert "shortfall = item.min - item.qty + item.reserve\n")
                    (setq-local drgnx-debug-timeline--past (list :run "r1" :stop (list :index 3 :line 1)))
                    ,@body))
         (drgnx-debug-origin-events-mode -1)
         (when-let* ((b (get-buffer drgnx-debug-timeline-past-buffer))) (kill-buffer b))
         (when-let* ((b (get-buffer drgnx-debug-timeline-vars-buffer))) (kill-buffer b))))))

(defun debug-origin-test--last (method)
  "The params of the last METHOD call."
  (cdr (car (last (seq-filter (lambda (c) (equal (car c) method)) debug-origin-test--calls)))))

(ert-deftest drgnx-debug-origin/the-name-at-point-is-a-dotted-path ()
  (with-temp-buffer
    (insert "shortfall = item.min - item.qty + item.reserve")
    (should (equal (drgnx-debug-origin--expr-at 3) "shortfall"))
    (should (equal (drgnx-debug-origin--expr-at 15) "item.min"))
    (should (equal (drgnx-debug-origin--expr-at 42) "item.reserve"))
    (should-not (drgnx-debug-origin--expr-at 11))))

(ert-deftest drgnx-debug-origin/asking-sends-the-stop-and-the-expression ()
  (debug-origin-test--with
    (goto-char 40)
    (call-interactively #'drgnx-debug-origin)
    (should (equal (debug-origin-test--last "debug/origin") '(:run "r1" :stop 3 :expr "item.reserve")))
    (should (equal drgnx-debug-origin--id "o1"))
    (should (string-match-p "Where did item.reserve come from"
                            (with-current-buffer drgnx-debug-origin-buffer (buffer-string))))))

(ert-deftest drgnx-debug-origin/the-card-and-a-link-opened-as-it-ran ()
  (debug-origin-test--with
    (drgnx-debug-origin "shortfall")
    ;; another trail's event is not drawn
    (drgnx-debug-origin--event "debug-origin" (list :origin "o9" :rows (vector (list :key "head" :text "Other"))))
    (drgnx-debug-origin--event "debug-origin" debug-origin-test--event)
    (drgnx-debug-origin--render)
    (with-current-buffer drgnx-debug-origin-buffer
      (should (equal (buffer-string) (concat "Where did shortfall come from? · run 4, stop 3 · done\n"
                                             "← shortfall = 16\n  ← item.reserve = 8\n")))
      (goto-char (point-min)) (forward-line 2) (forward-char 4)
      (drgnx-debug-origin-open-at-point))
    (should (equal (debug-origin-test--last "debug/run/stop") '(:run "r1" :stop 3 :file "/p/stock.py")))
    (with-current-buffer drgnx-debug-timeline-past-buffer
      (let ((o (seq-find (lambda (o) (overlay-get o 'drgnx-debug-past-stop)) (overlays-in (point-min) (point-max)))))
        (should (= (line-number-at-pos (overlay-start o)) 2))))
    (with-current-buffer drgnx-debug-timeline-vars-buffer
      (should (string-match-p "item.reserve = 8" (buffer-string))))))

(ert-deftest drgnx-debug-origin/off-leaves-nothing ()
  (debug-origin-test--with
    (drgnx-debug-origin "shortfall")
    (drgnx-debug-origin--event "debug-origin" debug-origin-test--event)
    (drgnx-debug-origin-events-mode -1)
    (should-not (memq #'drgnx-debug-origin--event drgnx-hub-event-functions))
    (should-not (get-buffer drgnx-debug-origin-buffer))
    (should-not drgnx-debug-origin--links)))

;;; debug-origin-test.el ends here
