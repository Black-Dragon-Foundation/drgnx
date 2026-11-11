;;; explorer-rows-nav-test.el --- batch tests: the Explorer on the rows path, its listing the hub's and its keys from Sjá -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub, no disk: the Explorer's buffer is
;; attached as a hub-fed view (`drgnx-explorer-rows-attach'), what it asks of the hub is recorded, and a model and rows
;; shaped like the hub's (view/explorer.rs: a `tree' of path nodes) are handed to it as the hub would.  Each test names
;; its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-explorer)

(defvar drgnx-hub--events)
(defvar drgnx-explorer-rows-nav-test--n 0 "Each run's view gets a name of its own in Sjá.")

(defun drgnx-explorer-rows-nav-test--model ()
  "The hub's listing of /r with lib open: a/ (closed), lib/ (m.el in it), z.txt."
  (let ((node (lambda (id kind flags parent label dir)
                (append (list :id id :kind kind :flags flags)
                        (and parent (list :parent parent))
                        (list :fields (vector (vector "label" label) (vector "path" id) (vector "dir" dir)))))))
    (json-serialize
     (list :ops
           (vector
            (list :reset
                  (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["order"]
                                          :classes ["selected" "match" "dim"] :flags ["expanded"] :forms []
                                          :start "order")
                        :nodes (vector (funcall node "/r" "root" 1 nil "R" 1)
                                       (funcall node "/r/a" "dir" 0 "/r" "a" 1)
                                       (funcall node "/r/lib" "dir" 1 "/r" "lib" 1)
                                       (funcall node "/r/lib/m.el" "file" 0 "/r/lib" "m.el" 0)
                                       (funcall node "/r/z.txt" "file" 0 "/r" "z.txt" 0))
                        :edges []
                        :lists (vector (list :name "order"
                                             :ids ["/r" "/r/a" "/r/lib" "/r/lib/m.el" "/r/z.txt"])))))))))

(defun drgnx-explorer-rows-nav-test--rows ()
  "The hub's rows of that listing, each row's path over all of it; the single root's row invisible, lib/ and z.txt
with a git status on the name (lib/ has the change inside it)."
  (mapcar (lambda (r)
            (let ((len (length (cadr r))))
              (list :key (car r) :text (cadr r)
                    :props (append (list (list 0 len "drgnx-work-id" (car r)))
                                   (and (nth 2 r) (list (list (- len (nth 3 r)) len "drgnx-git-status" (nth 2 r))))
                                   (and (equal (car r) "/r") (list (list 0 len "invisible" t)))))))
          '(("/r" "▾ R") ("/r/a" "▸ a") ("/r/lib" "▾ lib" "modified" 3) ("/r/lib/m.el" "│   m.el")
            ("/r/z.txt" "  z.txt" "modified" 5))))

(defmacro drgnx-explorer-rows-nav-test--with (&rest body)
  "BODY in the Explorer's buffer attached as hub-fed VIEW (roots /r, lib open), the model and rows applied; CALLS holds
what was asked of the hub (newest first): (METHOD . PARAMS) on the subscribed connection (`drgnx-hub--events', where the
hub sends the view), tagged :call-connection or :other-connection elsewhere.  Nothing is sent, nothing on disk is read."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
     (let* ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
            (drgnx-view-model--views (make-hash-table :test #'equal))
            (drgnx-view-patch--hooked nil)
            (drgnx-view-old-path nil)
            (drgnx-view-patch-send-function #'ignore)
            (drgnx-hub--events (make-pipe-process :name "drgnx-test-events" :noquery t))   ; the subscribed connection
            (drgnx-explorer--hub-view nil)
            (drgnx-explorer--roots '("/r/"))
            (drgnx-explorer--expanded (make-hash-table :test #'equal))
            (drgnx-explorer--watches (make-hash-table :test #'equal))
            (drgnx-explorer-git nil)
            (view (format "explorer-rows-test-%d" (cl-incf drgnx-explorer-rows-nav-test--n)))
            (calls nil))
       (puthash "/r/lib" t drgnx-explorer--expanded)
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-hub-call)   ; the call connection: the hub would send the view nowhere
                      (lambda (method params _cb &rest _) (push (list :call-connection method params) calls)))
                     ((symbol-function 'drgnx-hub--call-on)
                      (lambda (conn method params _cb &rest _)
                        (push (if (eq conn drgnx-hub--events) (cons method params) (list :other-connection method params)) calls)))
                     ((symbol-function 'drgnx-view-env-register) #'ignore))
             (with-current-buffer (get-buffer-create drgnx-explorer-buffer-name)
               (drgnx-explorer-mode)
               (drgnx-explorer-rows-attach view "c")
               (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                             :model (drgnx-explorer-rows-nav-test--model)))
               (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 0 :version 1 :env_epoch 0 :model 1
                                             :ops (list (list :reset (drgnx-explorer-rows-nav-test--rows)))))
               (drgnx-view-draw-now drgnx-view)
               ,@body))
         (delete-process drgnx-hub--events)
         (drgnx-view-patch-teardown)
         (when-let* ((b (get-buffer drgnx-explorer-buffer-name)))
           (drgnx-timer-cancel (cons 'drgnx-view b))
           (drgnx-timer-cancel (cons 'drgnx-view-nav-notice b))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
         (drgnx-timer-cancel (cons 'drgnx-view-model view))))))

(ert-deftest drgnx-explorer-rows/listing-comes-from-the-hub ()
  "Pattern D: attached, the Explorer asks `explorer/subscribe' for its roots and open folders and shows the hub's rows;
a row's node is its path; a refresh asks again and draws nothing itself."
  (drgnx-explorer-rows-nav-test--with
    (should (equal (list (cons "explorer/subscribe" (list :view view :roots ["/r"] :expanded ["/r/lib"] :compact t
                                                          :indent (drgnx-explorer--tree-indent))))
                   calls))
    (should (equal "▾ R\n▸ a\n▾ lib\n│   m.el\n  z.txt\n" (buffer-substring-no-properties (point-min) (point-max))))
    (goto-char (point-min))
    (forward-line 3)
    (should (equal "/r/lib/m.el" (drgnx-explorer-node-at (point))))
    (should-not (drgnx-explorer-dir-at (point)))
    (should (drgnx-explorer-dir-at (point-min)))
    (drgnx-explorer-refresh)
    (should (= 2 (length calls)))
    (should (equal "▾ R\n▸ a\n▾ lib\n│   m.el\n  z.txt\n" (buffer-substring-no-properties (point-min) (point-max))))))

(defun drgnx-explorer-rows-nav-test--tails ()
  "Each line's tail overlay as (LINE MARK FACE), in line order."
  (let (out)
    (dolist (o (overlays-in (point-min) (point-max)))
      (when-let* ((tail (overlay-get o 'drgnx-row-tail)))
        (push (list (1- (line-number-at-pos (overlay-start o))) (nth 0 tail) (nth 1 tail)) out)))
    (sort out (lambda (a b) (< (car a) (car b))))))

(ert-deftest drgnx-explorer-rows/marks-and-the-control-at-the-right-edge ()
  "Pattern D (plan sja-complete E2): on the rows path each drawn row gets the old path's tail at the right edge (the
⋯ control, the hover's mouse face), with the git mark of the status the hub put on its name: a file's letter in its
status face, ● for a folder with changes inside.  A patch moves the overlays it keeps instead of making new ones, and
the single root's row is invisible."
  (drgnx-explorer-rows-nav-test--with
    (should (get-text-property (point-min) 'invisible))
    (should (equal (list (list 0 nil nil) (list 1 nil nil) (list 2 "●" 'drgnx-status-warn) (list 3 nil nil)
                         (list 4 "M" 'drgnx-status-warn))
                   (drgnx-explorer-rows-nav-test--tails)))
    (should (get-char-property (save-excursion (goto-char (point-min)) (forward-line 4) (point)) 'mouse-face))
    (let ((before (seq-filter (lambda (o) (overlay-get o 'drgnx-row-tail)) (overlays-in (point-min) (point-max)))))
      (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 1
                                    :ops (list (list :remove (list "/r/a")))))
      (drgnx-view-draw-now drgnx-view)
      (should (equal (list (list 0 nil nil) (list 1 "●" 'drgnx-status-warn) (list 2 nil nil)
                           (list 3 "M" 'drgnx-status-warn))
                     (drgnx-explorer-rows-nav-test--tails)))
      (should (cl-every (lambda (o) (memq o before))
                        (seq-filter (lambda (o) (overlay-get o 'drgnx-row-tail)) (overlays-in (point-min) (point-max))))))))

(defun drgnx-explorer-rows-nav-test--badges ()
  "Each line's badge (an empty overlay's `before-string') as (LINE . STRING), in line order."
  (let (out)
    (dolist (o (overlays-in (point-min) (point-max)))
      (when (and (= (overlay-start o) (overlay-end o)) (overlay-get o 'before-string))
        (push (cons (1- (line-number-at-pos (overlay-start o))) (overlay-get o 'before-string)) out)))
    (sort out (lambda (a b) (< (car a) (car b))))))

(ert-deftest drgnx-explorer-rows/who-is-here-badges-from-the-hub ()
  "Pattern D (plan sja-complete E2): the hub puts the ordinals of the agents at a row on its name
\(`drgnx-agents-here'); the Explorer draws the badge `drgnx-explorer-badge-functions' makes of them (a folder's told
it is one) after the name, moves it with its row, and takes it away when the hub's row has none."
  (let ((drgnx-explorer-badge-functions
         (list (lambda (ords dirp) (format " [%s%s]" (mapconcat #'number-to-string ords ",") (if dirp "/" ""))))))
    (drgnx-explorer-rows-nav-test--with
      (let ((row (lambda (key text ords)
                   (list :key key :text text
                         :props (append (list (list 0 (length text) "drgnx-work-id" key))
                                        (and ords (list (list 2 (length text) "drgnx-agents-here" ords))))))))
        (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 1
                                      :ops (list (list :replace (list (funcall row "/r/lib" "▾ lib" [1 2])
                                                                      (funcall row "/r/lib/m.el" "│   m.el" [2]))))))
        (drgnx-view-draw-now drgnx-view)
        (should (equal '((2 . " [1,2/]") (3 . " [2]")) (drgnx-explorer-rows-nav-test--badges)))
        (save-excursion (goto-char (point-min)) (forward-line 3)
                        (should (= (pos-eol) (overlay-start (gethash "/r/lib/m.el" drgnx-explorer--badges)))))
        (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 2 :version 3 :env_epoch 0 :model 1
                                      :ops (list (list :remove (list "/r/a")))))
        (drgnx-view-draw-now drgnx-view)
        (should (equal '((1 . " [1,2/]") (2 . " [2]")) (drgnx-explorer-rows-nav-test--badges)))
        (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 3 :version 4 :env_epoch 0 :model 1
                                      :ops (list (list :replace (list (funcall row "/r/lib/m.el" "│   m.el" nil))))))
        (drgnx-view-draw-now drgnx-view)
        (should (equal '((1 . " [1,2/]")) (drgnx-explorer-rows-nav-test--badges)))))))

(ert-deftest drgnx-explorer-rows/a-density-change-asks-again-at-once ()
  "Pattern D: the indent the hub draws is the density's `tree-indent', sent with the subscription; a density change
asks the hub again with the new indent at once (no restart)."
  (drgnx-explorer-rows-nav-test--with
    (cl-letf (((symbol-function 'drgnx-explorer--tree-indent) (lambda () 14)))
      (setq calls nil)
      (run-hooks 'drgnx-look-density-changed-hook)
      (should (equal 14 (plist-get (cdr (car calls)) :indent))))))

(ert-deftest drgnx-explorer-rows/no-lisp-watches-on-the-rows-path ()
  "Pattern D: on the rows path the hub watches the listed folders (plan sja-complete E1): the Explorer adds no Lisp
`file-notify' watch, at attach or on a refresh."
  (drgnx-explorer-rows-nav-test--with
    (should (= 0 (hash-table-count drgnx-explorer--watches)))
    (drgnx-explorer-refresh)
    (should (= 0 (hash-table-count drgnx-explorer--watches)))))

(ert-deftest drgnx-explorer-rows/keys-walk-the-tree ()
  "Pattern D: next and previous walk the visible rows; expand on a closed folder asks the hub with it open (the
selection stays), on an open folder goes to its first child; collapse on a file goes to its folder, on an open folder
asks the hub with it closed.  Point follows the selection."
  (drgnx-explorer-rows-nav-test--with
    (goto-char (point-max))                             ; no row here: the keys start from the model's start
    (drgnx-explorer-next)
    (should (equal "/r" (drgnx-view-nav-selection)))
    (drgnx-explorer-next)
    (should (equal "/r/a" (drgnx-view-nav-selection)))
    (should (equal "/r/a" (drgnx-explorer-node-at (point))))
    (drgnx-explorer-expand)
    (should (equal "/r/a" (drgnx-view-nav-selection)))
    (should (equal (list :view view :roots ["/r"] :expanded ["/r/a" "/r/lib"] :compact t
                         :indent (drgnx-explorer--tree-indent))
                   (cdar calls)))
    (drgnx-explorer-next)
    (drgnx-explorer-next)
    (should (equal "/r/lib/m.el" (drgnx-view-nav-selection)))
    (drgnx-explorer-collapse)
    (should (equal "/r/lib" (drgnx-view-nav-selection)))
    (drgnx-explorer-expand)
    (should (equal "/r/lib/m.el" (drgnx-view-nav-selection)))
    (drgnx-explorer-previous)
    (should (equal "/r/lib" (drgnx-view-nav-selection)))
    (drgnx-explorer-collapse)
    (should (equal "/r/lib" (drgnx-view-nav-selection)))
    (should (equal (list :view view :roots ["/r"] :expanded ["/r/a"] :compact t
                         :indent (drgnx-explorer--tree-indent))
                   (cdar calls)))))

(ert-deftest drgnx-explorer-rows/typing-and-open ()
  "Pattern D: typing selects the next visible sibling whose name starts with what was typed; a click on another row
moves the selection there first; opening a file shows it in the editor, opening a folder asks the hub."
  (drgnx-explorer-rows-nav-test--with
    (goto-char (point-min))
    (forward-line 1)                                    ; a click: point on a/, no key yet
    (let ((last-command-event ?z)) (drgnx-explorer-type))
    (should (equal "/r/z.txt" (drgnx-view-nav-selection)))
    (should (equal "/r/z.txt" (drgnx-explorer-node-at (point))))
    (let ((shown nil))
      (cl-letf (((symbol-function 'find-file-noselect) (lambda (f &rest _) f))
                ((symbol-function 'drgnx-wb-show-in-editor) (lambda (b &rest _) (push b shown))))
        (drgnx-explorer-open))
      (should (equal '("/r/z.txt") shown)))
    (goto-char (point-min))
    (forward-line 1)
    (let ((n (length calls)))
      (drgnx-explorer-open)
      (should (= (1+ n) (length calls)))
      (should (equal ["/r/a" "/r/lib"] (plist-get (cdar calls) :expanded))))))

;;; explorer-rows-nav-test.el ends here
