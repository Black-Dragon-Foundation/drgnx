;;; debug-view-test.el --- batch tests: the Run and Debug view, hub-fed, its keys from Sjá -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub: the view's buffer is attached as the
;; hub-fed view `debug', what it asks of the hub is recorded, and a model and rows shaped like the hub's
;; (view/debug/model.rs: a `tree' of path nodes) are handed to it as the hub would.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)

(defvar drgnx-hub--events)

(defun debug-view-test--model ()
  "The hub's model: VARIABLES open with Locals (n, obj closed), WATCH, CALL STACK with a frame, BREAKPOINTS."
  (let ((node (lambda (id kind flags parent &rest fields)
                (append (list :id id :kind kind :flags flags)
                        (and parent (list :parent parent))
                        (list :fields (vconcat (mapcar (lambda (f) (vector (car f) (cdr f))) fields)))))))
    (json-serialize
     (list :ops
           (vector
            (list :reset
                  (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["order"]
                                          :classes ["selected" "match" "dim" "ticked"] :flags ["expanded"] :forms []
                                          :start "order")
                        :nodes (vector (funcall node "section:variables" "section" 1 nil '("label" . "VARIABLES") '("openable" . 1))
                                       (funcall node "v:d1:Locals" "scope" 1 "section:variables" '("label" . "Locals") '("openable" . 1))
                                       (funcall node "v:d1:Locals/n" "var" 0 "v:d1:Locals" '("label" . "n") '("value" . "5")
                                                '("evaluate_name" . "n"))
                                       (funcall node "v:d1:Locals/obj" "var" 0 "v:d1:Locals" '("label" . "obj") '("value" . "Obj")
                                                '("openable" . 1))
                                       (funcall node "v:d1:Locals/old" "var" 0 "v:d1:Locals" '("label" . "old") '("value" . "1")
                                                '("openable" . 1) '("dim" . 1))
                                       (funcall node "section:callstack" "section" 1 nil '("label" . "CALL STACK") '("openable" . 1))
                                       (funcall node "f:d1:1:0" "frame" 0 "section:callstack" '("label" . "main")
                                                '("session" . "d1") '("thread" . 1) '("frame" . 1000))
                                       (funcall node "section:breakpoints" "section" 1 nil '("label" . "BREAKPOINTS") '("openable" . 1))
                                       (funcall node "b:3" "breakpoint" 0 "section:breakpoints" '("label" . "a.py:3")
                                                '("ticked" . 1) '("id" . 3)))
                        :edges []
                        :lists (vector (list :name "order"
                                             :ids ["section:variables" "v:d1:Locals" "v:d1:Locals/n" "v:d1:Locals/obj"
                                                   "v:d1:Locals/old" "section:callstack" "f:d1:1:0"
                                                   "section:breakpoints" "b:3"])))))))))

(defun debug-view-test--rows ()
  "The hub's rows of that model, each row's id over all of it."
  (mapcar (lambda (r) (list :key (car r) :text (cadr r)
                            :props (list (list 0 (length (cadr r)) "drgnx-work-id" (car r)))))
          '(("section:variables" "▾ VARIABLES") ("v:d1:Locals" "  ▾ Locals") ("v:d1:Locals/n" "      n: 5")
            ("v:d1:Locals/obj" "    ▸ obj: Obj") ("v:d1:Locals/old" "    ▸ old: 1") ("section:callstack" "▾ CALL STACK")
            ("f:d1:1:0" "    main") ("section:breakpoints" "▾ BREAKPOINTS") ("b:3" "    [x] ● a.py:3"))))

(defmacro debug-view-test--with (&rest body)
  "BODY in the view's buffer attached as the hub-fed view `debug' of /p, the model and rows applied.  CALLS holds what
was asked of the hub (newest first): (METHOD . PARAMS) on the subscribed connection, (:call METHOD PARAMS) on the call
connection."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (when (get-buffer drgnx-debug-view-buffer-name) (kill-buffer drgnx-debug-view-buffer-name))
     (let* ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
            (drgnx-view-model--views (make-hash-table :test #'equal))
            (drgnx-view-patch--hooked nil)
            (drgnx-view-old-path nil)
            (drgnx-view-patch-send-function #'ignore)
            (drgnx-debug-view-await-limit 0)
            (drgnx-hub--events (make-pipe-process :name "drgnx-test-events" :noquery t))
            (calls nil))
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-hub-call)
                      (lambda (method params _cb &rest _) (push (list :call method params) calls)))
                     ((symbol-function 'drgnx-hub--call-on)
                      (lambda (_conn method params _cb &rest _) (push (cons method params) calls)))
                     ((symbol-function 'drgnx-debug-launch-root) (lambda () "/p"))
                     ((symbol-function 'drgnx-view-env-register) #'ignore))
             (with-current-buffer (drgnx-debug-view--buffer)
               (drgnx-view-model-event (list :view "debug" :hub 7 :base 0 :version 1 :reset t
                                             :model (debug-view-test--model)))
               (drgnx-view-apply-patch (list :view "debug" :class "unshown" :hub 7 :base 0 :version 1 :env_epoch 0
                                             :model 1 :ops (list (list :reset (debug-view-test--rows)))))
               (drgnx-view-draw-now drgnx-view)
               ,@body))
         (delete-process drgnx-hub--events)
         (drgnx-view-patch-teardown)
         (when-let* ((b (get-buffer drgnx-debug-view-buffer-name)))
           (drgnx-timer-cancel (cons 'drgnx-view b))
           (drgnx-timer-cancel (cons 'drgnx-view-nav-notice b))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
         (drgnx-timer-cancel (cons 'drgnx-view-model "debug"))))))

(defun debug-view-test--goto (id)
  "Point to the row of node ID."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal id (get-text-property (point) drgnx-view-patch-id-prop))))
    (forward-line 1)))

(ert-deftest drgnx-debug-view/asks-the-hub-and-draws-its-rows ()
  "Attached, the view asks `debug/view' for its project on the subscribed connection and shows the hub's rows."
  (debug-view-test--with
    (should (equal "debug/view" (car (car (last calls)))))
    (should (equal "/p" (plist-get (cdr (car (last calls))) :root)))
    (should (string-prefix-p "▾ VARIABLES\n  ▾ Locals\n      n: 5\n"
                             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest drgnx-debug-view/expand-asks-the-hub-in-the-keys-command ()
  "Expand on a closed variable asks `debug/expand' (open) on the subscribed connection, in the command; on an open
node it goes to the first child; an old stop's node does not open."
  (debug-view-test--with
    (setq calls nil)
    (debug-view-test--goto "v:d1:Locals/obj")
    (drgnx-debug-view-expand)
    (should (equal (cons "debug/expand" (list :view "debug" :node "v:d1:Locals/obj" :open t)) (car calls)))
    (debug-view-test--goto "v:d1:Locals")
    (drgnx-debug-view-expand)
    (should (equal "v:d1:Locals/n" (drgnx-view-nav-selection)))
    (debug-view-test--goto "v:d1:Locals/old")
    (setq calls nil)
    (should-error (drgnx-debug-view-expand) :type 'user-error)
    (should-not calls)))

(ert-deftest drgnx-debug-view/selecting-a-frame-moves-the-editor ()
  "RET on a frame asks `debug/select' for it: the hub fetches its scopes again and names its line (`debug-frame')."
  (debug-view-test--with
    (setq calls nil)
    (debug-view-test--goto "f:d1:1:0")
    (drgnx-debug-view-activate)
    (should (equal (list :call "debug/select" (list :session "d1" :thread 1 :frame 1000)) (car calls)))))

(ert-deftest drgnx-debug-view/a-tick-box-toggles-its-breakpoint ()
  (debug-view-test--with
    (setq calls nil)
    (debug-view-test--goto "b:3")
    (drgnx-debug-view-activate)
    (should (equal (list :call "debug/breakpoints" (list :root "/p" :op (list :op "edit" :id 3 :enabled :false)))
                   (car calls)))))

(ert-deftest drgnx-debug-view/filter-on-typing ()
  "The filter asks the hub for the view with the text; empty asks for all of it."
  (debug-view-test--with
    (drgnx-debug-view--filter-apply "tot")
    (should (equal "tot" (plist-get (cdr (car calls)) :filter)))
    (drgnx-debug-view--filter-apply "")
    (should-not (plist-member (cdr (car calls)) :filter))))

(ert-deftest drgnx-debug-view/copy-as-expression-and-add-to-watch ()
  (debug-view-test--with
    (debug-view-test--goto "v:d1:Locals/n")
    (let ((kill-ring nil)) (drgnx-debug-copy-expression) (should (equal "n" (car kill-ring))))
    (setq calls nil)
    (drgnx-debug-add-to-watch)
    (should (equal (list :call "debug/watch" (list :root "/p" :op "add" :expr "n")) (car calls)))))

(ert-deftest drgnx-debug-view/the-header-starts-the-picked-configuration ()
  "The header holds Start and the picker; Start with nothing picked picks first, then starts that configuration."
  (debug-view-test--with
    (should (string-match-p "▶ Start" (drgnx-debug-view--header)))
    (should (string-match-p "No Configuration ▾" (drgnx-debug-view--header)))
    (let (started)
      (cl-letf (((symbol-function 'drgnx-debug-launch-read-config) (lambda (_root) "c1"))
                ((symbol-function 'drgnx-debug-launch-configs)
                 (lambda (_root) (list :configs (vector (list :id "c1" :name "Python: app")))))
                ((symbol-function 'drgnx-debug-launch-start) (lambda (root id) (setq started (list root id)))))
        (drgnx-debug-view-start)
        (should (equal '("/p" "c1") started))
        (should (string-match-p "Python: app ▾" (drgnx-debug-view--header)))))))

(ert-deftest drgnx-debug-view/a-step-patches-its-rows-in-place ()
  "A step's model diff and rows patch (the hub's `:replace' of the rows that changed) are drawn in place; a chunk
opened from its row is answered with its rows inserted after it.  (The perf rows `debug-step-variables' and
`debug-expand-chunks' run the same.)"
  (debug-view-test--with
    (drgnx-view-model-event (list :view "debug" :hub 7 :base 1 :version 2
                                  :model (json-serialize
                                          (list :ops (vector (list :nodes (vector (list :id "v:d1:Locals/n" :kind "var"
                                                                                        :flags 0 :parent "v:d1:Locals"
                                                                                        :fields [["label" "n"] ["value" "6"]]))))))))
    (drgnx-view-apply-patch (list :view "debug" :class "unshown" :hub 7 :base 1 :version 2 :env_epoch 0 :model 2
                                  :ops (list (list :replace (list (list :key "v:d1:Locals/n" :text "      n: 6"
                                                                        :props '((0 10 "drgnx-work-id" "v:d1:Locals/n"))))))))
    (drgnx-view-draw-now drgnx-view)
    (should (string-match-p "      n: 6\n" (buffer-substring-no-properties (point-min) (point-max))))
    (cl-letf (((symbol-function 'drgnx-hub--call-on)
               (lambda (_conn method params _cb &rest _)
                 (when (equal method "debug/expand")
                   (drgnx-view-apply-patch
                    (list :view "debug" :class "unshown" :hub 7 :base 2 :version 3 :env_epoch 0 :model 2
                          :ops (list (list :insert (list :after (plist-get params :node)
                                                         :rows (list (list :key "v:d1:Locals/obj/a" :text "      a: 1"
                                                                           :props '((0 10 "drgnx-work-id" "v:d1:Locals/obj/a")))))))))
                   (drgnx-view-draw-now drgnx-view)))))
      (debug-view-test--goto "v:d1:Locals/obj")
      (drgnx-debug-view-expand)
      (should (string-match-p "obj: Obj\n      a: 1\n" (buffer-substring-no-properties (point-min) (point-max)))))))
