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
                                          :classes ["selected" "match" "dim" "ticked"] :flags ["expanded"] :forms []
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
                                                          :indent (drgnx-explorer--tree-indent)
                                                          :exclude (vconcat drgnx-explorer-exclude-names)
                                                          :window drgnx-explorer-rows-window)))
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
the single root's row is invisible, with no tail."
  (drgnx-explorer-rows-nav-test--with
    (should (get-text-property (point-min) 'invisible))
    (should (equal (list (list 1 nil nil) (list 2 "●" 'drgnx-status-warn) (list 3 nil nil)
                         (list 4 "M" 'drgnx-status-warn))
                   (drgnx-explorer-rows-nav-test--tails)))
    (should (get-char-property (save-excursion (goto-char (point-min)) (forward-line 4) (point)) 'mouse-face))
    (let ((before (seq-filter (lambda (o) (overlay-get o 'drgnx-row-tail)) (overlays-in (point-min) (point-max)))))
      (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 1
                                    :ops (list (list :remove (list "/r/a")))))
      (drgnx-view-draw-now drgnx-view)
      (should (equal (list (list 1 "●" 'drgnx-status-warn) (list 2 nil nil)
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

;;;; E3: Find, marks, ranges, exclusions, reveal (plan sja-complete)

(ert-deftest drgnx-explorer-rows/find-lists-only-what-it-found ()
  "Pattern D: Find on the rows path asks the hub for the tree of the files it found (`only'), with no row vector of
its own; leaving Find asks for the tree as it was."
  (drgnx-explorer-rows-nav-test--with
    (cl-letf (((symbol-function 'drgnx-explorer--find-load) (lambda () (list "/r/lib/m.el" "/r/z.txt" "/r/a/mm.c")))
              ((symbol-function 'drgnx-explorer--find-ask) #'ignore)
              ((symbol-function 'drgnx-explorer--find-stop) #'ignore))
      (let ((rows-before drgnx-explorer--rows))
        (drgnx-explorer--find-apply "m")
        (should (equal ["/r/lib/m.el" "/r/a/mm.c"] (plist-get (cdar calls) :only)))
        (should (eq rows-before drgnx-explorer--rows)))
      (drgnx-explorer-find-clear)
      (should (equal "explorer/subscribe" (caar calls)))
      (should-not (plist-member (cdar calls) :only))
      (should (equal ["/r/lib"] (plist-get (cdar calls) :expanded))))))

(ert-deftest drgnx-explorer-rows/marks-are-sja-s-ticked-set ()
  "Pattern D: a mark (Ctrl-click, `drgnx-explorer-mark') puts the row in Sjá's ticked set, drawn in the class
`ticked'; unmarking takes it out; file operations act on the marks."
  (drgnx-explorer-rows-nav-test--with
    (let ((h (drgnx-view-patch-handle drgnx-view-patch))
          (ticked (lambda (h) (sort (append (nidhogg-view-get h 'ticked) nil) #'string<))))
      (drgnx-explorer--set-selection (list "/r/a" "/r/z.txt"))
      (should (equal '("/r/a" "/r/z.txt") (funcall ticked h)))
      (should (equal 3 (nidhogg-view-get h 'class "/r/a")))     ; the descriptor's `ticked'
      (should (eq 'drgnx-explorer-selected (drgnx-view-nav--face-of 3)))
      (drgnx-explorer--set-selection (list "/r/z.txt"))
      (should (equal '("/r/z.txt") (funcall ticked h)))
      (goto-char (point-min)) (forward-line 4)                   ; on z.txt, which is marked
      (cl-letf (((symbol-function 'file-exists-p) (lambda (_) t)))
        (should (equal '("/r/z.txt") (drgnx-explorer--targets))))
      (drgnx-explorer--clear-selection)
      (should-not (funcall ticked h)))))

(ert-deftest drgnx-explorer-rows/a-shift-click-marks-the-visible-range ()
  "Pattern D: a range marks the drawn rows between the anchor and the row, in order: the tree's visible rows."
  (drgnx-explorer-rows-nav-test--with
    (setq drgnx-explorer--anchor "/r/a")
    (drgnx-explorer--select-range-to (save-excursion (goto-char (point-min)) (forward-line 3) (point)))
    (should (equal '("/r/a" "/r/lib" "/r/lib/m.el") drgnx-explorer--selection))
    (should (equal '("/r/a" "/r/lib" "/r/lib/m.el")
                   (sort (append (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked) nil) #'string<)))))

(ert-deftest drgnx-explorer-rows/the-exclusions-reach-the-hub ()
  "Pattern D (Q4): `drgnx-explorer-exclude-names' (names and globs) goes with the subscription; the old path's names
match the same way."
  (drgnx-explorer-rows-nav-test--with
    (let ((drgnx-explorer-exclude-names '("*.o" "node_modules")))
      (drgnx-explorer-refresh)
      (should (equal ["*.o" "node_modules"] (plist-get (cdar calls) :exclude)))
      (should (drgnx-explorer--excluded-name-p "main.o"))
      (should-not (drgnx-explorer--excluded-name-p ".git")))
    (should (drgnx-explorer--excluded-name-p ".#init.el"))
    (should-not (drgnx-explorer--excluded-name-p ".gitignore"))))

(ert-deftest drgnx-explorer-rows/a-reveal-waits-for-its-listing ()
  "Pattern D (SJA-EXPLORER-1 (6)): revealing a file in a closed folder opens its folders and asks the hub; the file
is selected when the listing that holds it is drawn."
  (drgnx-explorer-rows-nav-test--with
    (should (drgnx-explorer-reveal "/r/a/new.el"))
    (should (equal ["/r/a" "/r/lib"] (plist-get (cdar calls) :expanded)))
    (should (equal "/r/a/new.el" (plist-get (cdar calls) :around)))   ; the hub's window moves to hold it
    (should (equal "/r/a/new.el" drgnx-explorer--reveal-pending))
    (should-not (equal "/r/a/new.el" (drgnx-view-nav-selection)))
    (let ((node (lambda (id kind flags parent label dir)
                  (append (list :id id :kind kind :flags flags) (and parent (list :parent parent))
                          (list :fields (vector (vector "label" label) (vector "path" id) (vector "dir" dir)))))))
      (drgnx-view-model-event
       (list :view view :hub 7 :base 1 :version 2 :reset t
             :model (json-serialize
                     (list :ops (vector (list :reset
                                              (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"]
                                                                      :lists ["order"] :classes ["selected" "match" "dim" "ticked"]
                                                                      :flags ["expanded"] :forms [] :start "order")
                                                    :nodes (vector (funcall node "/r" "root" 1 nil "R" 1)
                                                                   (funcall node "/r/a" "dir" 1 "/r" "a" 1)
                                                                   (funcall node "/r/a/new.el" "file" 0 "/r/a" "new.el" 0))
                                                    :edges []
                                                    :lists (vector (list :name "order" :ids ["/r" "/r/a" "/r/a/new.el"])))))))))
      (drgnx-view-apply-patch
       (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 2
             :ops (list (list :insert (list :after "/r/a"
                                            :rows (list (list :key "/r/a/new.el" :text "│   new.el"
                                                              :props (list (list 0 9 "drgnx-work-id" "/r/a/new.el")))))))))
      (drgnx-view-draw-now drgnx-view)
      (should-not drgnx-explorer--reveal-pending)
      (should (equal "/r/a/new.el" (drgnx-view-nav-selection)))
      ;; the selected row (the workbench's, with its ring when focused) is the revealed file's
      (should (equal "/r/a/new.el" (get-text-property (overlay-start drgnx-wb--selected-overlay) 'drgnx-work-id))))))

(ert-deftest drgnx-explorer-rows/the-selection-is-the-workbench-s-row-alone ()
  "Pattern D: on the rows path the selected row is drawn once, by the workbench's selection (`drgnx-wb-selection-sync':
the look's fill and ring); Sjá's `selected' class puts no overlay of its own on the node, nor its `dim' on the
others (the Explorer has no chain, so Sjá dims every row off the selection), a key moves the one row, and a reveal of
a drawn row moves it too."
  (drgnx-explorer-rows-nav-test--with
    (let ((class-ovs (lambda () (seq-filter (lambda (o) (memq (overlay-get o 'face) '(drgnx-view-selected shadow)))
                                            (overlays-in (point-min) (point-max))))))
      (goto-char (point-min))
      (drgnx-explorer--rows-key 'next)
      (drgnx-wb-selection-sync)                     ; post-command's
      (should-not (funcall class-ovs))
      (should (drgnx-explorer-reveal "/r/z.txt"))
      (should (equal "/r/z.txt" (drgnx-view-nav-selection)))
      (should-not (funcall class-ovs))
      (should (equal "/r/z.txt" (get-text-property (overlay-start drgnx-wb--selected-overlay) 'drgnx-work-id))))))

(ert-deftest drgnx-explorer-rows/a-reset-keeps-the-selected-row ()
  "Pattern D: the hub's reset of the rows (a theme's new env draws every row again) deletes them all; point and the
workbench's selected row go back to Sjá's selection, not to the first row."
  (drgnx-explorer-rows-nav-test--with
    (should (drgnx-explorer-reveal "/r/z.txt"))
    (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 1
                                  :ops (list (list :reset (drgnx-explorer-rows-nav-test--rows)))))
    (drgnx-view-draw-now drgnx-view)
    (should (equal "/r/z.txt" (drgnx-view-nav-selection)))
    (should (equal "/r/z.txt" (drgnx-explorer-node-at (point))))
    (should (equal "/r/z.txt" (get-text-property (overlay-start drgnx-wb--selected-overlay) 'drgnx-work-id)))))

(ert-deftest drgnx-explorer-rows/a-scroll-near-the-window-s-edge-asks-the-next ()
  "Pattern D (E4): the hub holds a window of the listing (60 of 200 entries from 0); a scroll within a page of the
rows' end asks `view/window' half the window on, once; with the window at 100, a scroll near the top asks half back."
  (drgnx-explorer-rows-nav-test--with
    (let* ((sent nil)
           (drgnx-view-patch-send-function (lambda (method params) (push (cons method params) sent)))
           (ids (lambda (from) (cl-loop for i from from below (+ from 60) collect (format "/r/f%03d" i))))
           (model (lambda (from)
                    (json-serialize
                     (list :ops (vector (list :reset
                                              (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"]
                                                                      :lists ["order"] :classes ["selected" "match" "dim" "ticked"]
                                                                      :flags ["expanded"] :forms [] :start "order")
                                                    :nodes (vconcat (list (list :id "/r" :kind "root" :flags 1
                                                                                :fields [["label" "R"] ["path" "/r"] ["dir" 1]]))
                                                                    (mapcar (lambda (id) (list :id id :kind "file" :flags 0 :parent "/r"
                                                                                               :fields (vector (vector "label" id) (vector "path" id) (vector "dir" 0))))
                                                                            (funcall ids from)))
                                                    :edges []
                                                    :lists (vector (list :name "order" :ids (vconcat (funcall ids from))
                                                                         :total 200 :from from)))))))))
           (rows (lambda (from) (mapcar (lambda (id) (list :key id :text id :props (list (list 0 (length id) "drgnx-work-id" id))))
                                        (funcall ids from)))))
      (drgnx-view-model-event (list :view view :hub 7 :base 1 :version 2 :reset t :model (funcall model 0)))
      (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 2
                                    :ops (list (list :reset (funcall rows 0)))))
      (drgnx-view-draw-now drgnx-view)
      (let ((w (selected-window)))
        (set-window-buffer w (current-buffer))
        (drgnx-explorer--rows-scrolled w (point-min))          ; at the top of the first window: nothing to ask
        (should-not sent)
        (let ((near-end (save-excursion (goto-char (point-max)) (forward-line (- (window-body-height w))) (point))))
          (drgnx-explorer--rows-scrolled w near-end)
          (drgnx-explorer--rows-scrolled w near-end)        ; asked once
          (should (equal (list (list "view/window" :view view :list "order" :from 30)) sent)))
        (setq sent nil)
        (drgnx-view-model-event (list :view view :hub 7 :base 2 :version 3 :reset t :model (funcall model 100)))
        (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 2 :version 3 :env_epoch 0 :model 3
                                      :ops (list (list :reset (funcall rows 100)))))
        (drgnx-view-draw-now drgnx-view)
        ;; shown: tails only near what the window shows; a scroll gives the rows it reaches theirs
        (let ((tailed (lambda (id) (when-let* ((o (gethash id drgnx-explorer--tails))) (overlay-buffer o)))))
          (should (funcall tailed "/r/f100"))
          (when (< (* 2 (window-body-height w)) 50)
            (should-not (funcall tailed "/r/f159")))
          (drgnx-explorer--rows-scrolled w (point-min))
          (should (equal 70 (plist-get (cdar sent) :from)))
          (drgnx-explorer--rows-scrolled
           w (save-excursion (goto-char (point-max)) (forward-line (- (window-body-height w))) (point)))
          (should (funcall tailed "/r/f159")))))))

(ert-deftest drgnx-explorer-rows/a-twin-s-scroll-pages-the-view-s-window ()
  "Pattern D: the Explorer's twin (its buffer in another display class: a dock on a second monitor) pages the hub's
window when it scrolls, as the Explorer does: a scroll within a page of its rows' end asks `view/window' further on.
The window is the view's: the Explorer's buffer, whose rows the move took, does not ask it back; its user's next scroll
does."
  (drgnx-explorer-rows-nav-test--with
    (let* ((sent nil) (drgnx-explorer--window-asker nil) (main (current-buffer))
           (drgnx-view-patch-send-function (lambda (method params) (push (cons method params) sent)))
           (ids (lambda (from) (cl-loop for i from from below (+ from 60) collect (format "/r/f%03d" i))))
           (model (lambda (from)
                    (json-serialize
                     (list :ops (vector (list :reset
                                              (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"]
                                                                      :lists ["order"] :classes ["selected" "match" "dim" "ticked"]
                                                                      :flags ["expanded"] :forms [] :start "order")
                                                    :nodes (vconcat (list (list :id "/r" :kind "root" :flags 1
                                                                                :fields [["label" "R"] ["path" "/r"] ["dir" 1]]))
                                                                    (mapcar (lambda (id) (list :id id :kind "file" :flags 0 :parent "/r"
                                                                                               :fields (vector (vector "label" id) (vector "path" id) (vector "dir" 0))))
                                                                            (funcall ids from)))
                                                    :edges []
                                                    :lists (vector (list :name "order" :ids (vconcat (funcall ids from))
                                                                         :total 200 :from from)))))))))
           (rows (lambda (from) (mapcar (lambda (id) (list :key id :text id :props (list (list 0 (length id) "drgnx-work-id" id))))
                                        (funcall ids from))))
           (tw (drgnx-explorer--rows-twin "c2")))
      (unwind-protect
          (let ((w (selected-window)))
            (drgnx-view-model-event (list :view view :hub 7 :base 1 :version 2 :reset t :model (funcall model 0)))
            (with-current-buffer tw
              (drgnx-view-apply-patch (list :view view :class "c2" :hub 7 :base 0 :version 1 :env_epoch 0 :model 2
                                            :ops (list (list :reset (funcall rows 0)))))
              (drgnx-view-draw-now drgnx-view)
              (set-window-buffer w tw)
              (run-hook-with-args 'window-scroll-functions w
                                  (save-excursion (goto-char (point-max)) (forward-line (- (window-body-height w))) (point)))
              (should (equal (list (list "view/window" :view view :list "order" :from 30)) sent)))
            ;; the hub moves the view's window to 30 and sends both classes their rows: the Explorer's buffer, scrolled
            ;; to its top (its rows from 30 on, the earlier ones gone), asks nothing back
            (drgnx-view-model-event (list :view view :hub 7 :base 2 :version 3 :reset t :model (funcall model 30)))
            (with-current-buffer main
              (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 3
                                            :ops (list (list :reset (funcall rows 30)))))
              (drgnx-view-draw-now drgnx-view)
              (should (equal 30 (car (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'window "order"))))
              (let ((asks (lambda () (mapcar (lambda (c) (plist-get (cdr c) :from))
                                             (seq-filter (lambda (c) (equal "view/window" (car c))) sent)))))
                (set-window-buffer w main)        ; runs its `window-scroll-functions': the rows moved under it
                (should (equal '(30) (funcall asks)))            ; the twin's ask alone
                ;; the user's own scroll after that, at the top of its rows: half a window back
                (drgnx-explorer--rows-scrolled w (point-min))
                (should (equal '(0 30) (funcall asks)))))))
      (kill-buffer tw))))

(ert-deftest drgnx-explorer-rows/a-twin-made-with-the-hub-down-says-it-waits ()
  "Pattern D: a twin of the Explorer made while the hub is down shows the line saying it waits for the hub, as the
Explorer does."
  (drgnx-explorer-rows-nav-test--with
    (delete-process drgnx-hub--events)
    (let ((tw (drgnx-explorer--rows-twin "c2")))
      (unwind-protect
          (with-current-buffer tw (should (drgnx-explorer-rows-nav-test--waiting)))
        (kill-buffer tw)))))

(ert-deftest drgnx-explorer-rows/a-hidden-root-takes-no-line ()
  "Pattern D (E4 side-by-side): the single root's row is invisible (the island's header names it), its newline too, so
no empty line shows; it gets no tail (a tail's string would show on it)."
  (drgnx-explorer-rows-nav-test--with
    (goto-char (point-min))
    (should (invisible-p (point)))
    (should (invisible-p (pos-eol)))                  ; the newline: the line takes no room
    (should-not (invisible-p (save-excursion (forward-line 1) (point))))
    (should-not (when-let* ((o (gethash "/r" drgnx-explorer--tails))) (overlay-buffer o)))))

(ert-deftest drgnx-explorer-rows/expand-draws-in-the-key-s-own-frame ()
  "Pattern D (E4, the same frame as the old path): expanding a closed folder waits inside the command, bounded, for the
hub's answer on the subscribed connection and draws it before the command returns: no redisplay and no timer run
between the key and the new rows.  When nothing comes within the bound the command returns and the rows come later."
  (drgnx-explorer-rows-nav-test--with
    (let* ((redisplays 0) (waited nil) (deliver t)
           (count (lambda () (cl-incf redisplays)))
           (node (lambda (id kind flags parent label dir)
                   (append (list :id id :kind kind :flags flags) (and parent (list :parent parent))
                           (list :fields (vector (vector "label" label) (vector "path" id) (vector "dir" dir))))))
           (answer
            (lambda ()
              (drgnx-view-model-event
               (list :view view :hub 7 :base 1 :version 2 :reset t
                     :model (json-serialize
                             (list :ops (vector (list :reset
                                                      (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"]
                                                                              :lists ["order"] :classes ["selected" "match" "dim" "ticked"]
                                                                              :flags ["expanded"] :forms [] :start "order")
                                                            :nodes (vector (funcall node "/r" "root" 1 nil "R" 1)
                                                                           (funcall node "/r/a" "dir" 1 "/r" "a" 1)
                                                                           (funcall node "/r/a/x.el" "file" 0 "/r/a" "x.el" 0)
                                                                           (funcall node "/r/lib" "dir" 1 "/r" "lib" 1)
                                                                           (funcall node "/r/lib/m.el" "file" 0 "/r/lib" "m.el" 0)
                                                                           (funcall node "/r/z.txt" "file" 0 "/r" "z.txt" 0))
                                                            :edges []
                                                            :lists (vector (list :name "order" :ids ["/r" "/r/a" "/r/a/x.el" "/r/lib" "/r/lib/m.el" "/r/z.txt"])))))))))
              (drgnx-view-apply-patch
               (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 0 :model 2
                     :ops (list (list :insert (list :after "/r/a"
                                                    :rows (list (list :key "/r/a/x.el" :text "│   x.el"
                                                                      :props (list (list 0 8 "drgnx-work-id" "/r/a/x.el"))))))))))))
      (add-hook 'pre-redisplay-functions count)
      (unwind-protect
          (cl-letf (((symbol-function 'accept-process-output)
                     (lambda (proc &rest _)
                       (should (eq proc drgnx-hub--events))   ; only the subscribed connection, nothing else runs
                       (setq waited t)
                       (when deliver (setq deliver nil) (funcall answer))
                       t)))
            (drgnx-view-nav 'select "/r/a")
            (call-interactively #'drgnx-explorer-expand)
            (should waited)
            (should (drgnx-view-row-start drgnx-view "/r/a/x.el"))   ; drawn before the command returned
            (should (= 0 redisplays))
            ;; nothing comes: the wait ends at its bound and the command returns, the rows not drawn yet
            (setq waited nil)
            (drgnx-view-nav 'select "/r/lib")
            (call-interactively #'drgnx-explorer-collapse)
            (should waited)
            (should (drgnx-view-row-start drgnx-view "/r/lib/m.el")))
        (remove-hook 'pre-redisplay-functions count)))))

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
                         :indent (drgnx-explorer--tree-indent)
                         :exclude (vconcat drgnx-explorer-exclude-names) :window drgnx-explorer-rows-window)
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
                         :indent (drgnx-explorer--tree-indent)
                         :exclude (vconcat drgnx-explorer-exclude-names) :window drgnx-explorer-rows-window)
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

;;;; The switch (plan sja-complete E4): the Explorer opens on the rows path

(defmacro drgnx-explorer-rows-nav-test--opened (roots hub-up &rest body)
  "BODY in the Explorer's buffer as `drgnx-explorer--buffer' opens it, with ROOTS, the hub's events connection up when
HUB-UP.  CALLS holds what was asked of the hub (newest first, as `drgnx-explorer-rows-nav-test--with'); LISTED counts
the Lisp listings (`drgnx-explorer--render-old', stubbed: no disk, no host); VIEW is the hub view's name."
  (declare (indent 2))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
     (let* ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
            (drgnx-view-model--views (make-hash-table :test #'equal))
            (drgnx-view-patch--hooked nil)
            (drgnx-view-patch-send-function #'ignore)
            (drgnx-hub--events (and ,hub-up (make-pipe-process :name "drgnx-test-events" :noquery t)))
            (drgnx-explorer--hub-view nil)
            (drgnx-explorer--roots ,roots)
            (drgnx-explorer--expanded (make-hash-table :test #'equal))
            (drgnx-explorer--watches (make-hash-table :test #'equal))
            (drgnx-explorer-git nil)
            (view (format "explorer-rows-test-%d" (cl-incf drgnx-explorer-rows-nav-test--n)))
            (drgnx-explorer-hub-view-name view)
            (calls nil)
            (listed 0))
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-hub--call-on)
                      (lambda (conn method params _cb &rest _)
                        (push (if (eq conn drgnx-hub--events) (cons method params) (list :other-connection method params)) calls)))
                     ((symbol-function 'drgnx-view-env-register) #'ignore)
                     ((symbol-function 'drgnx-wb-island-refresh) #'ignore)
                     ((symbol-function 'drgnx-explorer--render-old) (lambda () (cl-incf listed))))
             (with-current-buffer (drgnx-explorer--buffer)
               ,@body))
         (when (process-live-p drgnx-hub--events) (delete-process drgnx-hub--events))
         (drgnx-view-patch-teardown)
         (when-let* ((b (get-buffer drgnx-explorer-buffer-name)))
           (drgnx-timer-cancel (cons 'drgnx-view b))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
         (drgnx-timer-cancel (cons 'drgnx-view-model view))))))

(defun drgnx-explorer-rows-nav-test--waiting ()
  "The \"waiting for the hub\" line the Explorer shows, or nil."
  (seq-some (lambda (o) (let ((s (overlay-get o 'before-string)))
                          (and s (string-match-p "hub" s) s)))
            (overlays-in (point-min) (point-max))))

(ert-deftest drgnx-explorer-rows/the-explorer-opens-on-the-rows-path ()
  "Pattern D (plan sja-complete E4): opened with the hub up in an Emacs with Sjá, the Explorer is a hub-fed view: it
asks the hub for its listing and lists nothing in Lisp."
  (drgnx-explorer-rows-nav-test--opened '("/r/") t
    (should (drgnx-explorer--rows-p))
    (should (equal view drgnx-explorer--hub-view))
    (should (equal "explorer/subscribe" (caar calls)))
    (should (equal ["/r"] (plist-get (cdar calls) :roots)))
    (should (= 0 listed))))

(ert-deftest drgnx-explorer-rows/it-waits-for-the-hub-then-fills ()
  "Pattern D (plan sja-complete E4, Q2): with the hub not up yet the Explorer shows its frame and a line saying it waits
for the hub, lists nothing in Lisp, and fills with the hub's rows when they come; the line goes."
  (drgnx-explorer-rows-nav-test--opened '("/r/") nil
    (should (drgnx-explorer--rows-p))
    (should-not calls)
    (should (= 0 listed))
    (should (drgnx-explorer-rows-nav-test--waiting))
    (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                  :model (drgnx-explorer-rows-nav-test--model)))
    (drgnx-view-apply-patch (list :view view :class "unshown" :hub 7 :base 0 :version 1 :env_epoch 0 :model 1
                                  :ops (list (list :reset (drgnx-explorer-rows-nav-test--rows)))))
    (drgnx-view-draw-now drgnx-view)
    (should (equal "▾ R\n▸ a\n▾ lib\n│   m.el\n  z.txt\n" (buffer-substring-no-properties (point-min) (point-max))))
    (should-not (drgnx-explorer-rows-nav-test--waiting))))

(ert-deftest drgnx-explorer-rows/a-remote-root-keeps-the-lisp-listing ()
  "Pattern D (plan sja-complete E4, Q3 (b)): the hub lists local folders only, so with a remote root the Explorer
lists in Lisp, as before; when the roots are local again it is the hub's view again."
  (drgnx-explorer-rows-nav-test--opened '("/ssh:host:/r/") t
    (should-not (drgnx-explorer--rows-p))
    (should (= 1 listed))
    (should-not calls)
    (drgnx-explorer-set-roots '("/r/"))
    (with-current-buffer drgnx-explorer-buffer-name
      (should (drgnx-explorer--rows-p))
      (should (= 1 listed))
      (should (equal "explorer/subscribe" (caar calls)))
      (drgnx-explorer-set-roots '("/r/" "/ssh:host:/s/"))
      (should-not (drgnx-explorer--rows-p))
      (should (= 2 listed)))))

;;; explorer-rows-nav-test.el ends here
