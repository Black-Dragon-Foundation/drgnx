;;; replace-rows-nav-test.el --- batch tests: the Search view's keys, ticks and Replace All on the rows path answer from Sjá -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub, no search: the Search view's buffer is
;; attached as a hub-fed view, given a model shaped like the hub's (view/grep.rs: a `tree' of files and matches) and
;; its rows, and every key is a call in it.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)

(defvar drgnx-replace-rows-nav-test--n 0 "Each run's view gets a name of its own in Sjá.")

(defvar drgnx-replace-rows-nav-test--grouped nil
  "Non-nil: the model and rows are grouped, the hub's generic tree (view/search/group.rs): a folder `d:r' above
a.txt, each file's matches under their definitions (`s:'), b.txt's under \"(top level)\".")

(defun drgnx-replace-rows-nav-test--grouped-model ()
  "The grouped model (see `drgnx-replace-rows-nav-test--grouped')."
  (let ((node (lambda (id kind parent label path)
                (append (list :id id :kind kind :flags 1)
                        (and parent (list :parent parent))
                        (list :fields (vector (vector "label" label) (vector "path" path))))))
        (hit (lambda (f line parent)
               (list :id (format "m:%s:%d:4" f line) :kind "match" :flags 0 :parent parent
                     :fields (vector (vector "label" "let needle;") (vector "line" line)
                                     (vector "col" 4) (vector "end" 10) (vector "text" "needle"))))))
    (json-serialize
     (list :ops
           (vector
            (list :reset
                  (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["order"]
                                          :classes ["selected" "match" "dim"] :flags ["expanded"] :forms []
                                          :start "order")
                        :nodes (vector (funcall node "d:r" "folder" nil "r" "/r/r")
                                       (funcall node "f:a.txt" "file" "d:r" "a.txt" "/r/a.txt")
                                       (funcall node "s:a.txt:0:9:f" "symbol" "f:a.txt" "f" "/r/a.txt")
                                       (funcall hit "a.txt" 1 "s:a.txt:0:9:f") (funcall hit "a.txt" 2 "s:a.txt:0:9:f")
                                       (funcall node "f:b.txt" "file" nil "b.txt" "/r/b.txt")
                                       (funcall node "s:b.txt:top" "symbol" "f:b.txt" "(top level)" "/r/b.txt")
                                       (funcall hit "b.txt" 5 "s:b.txt:top"))
                        :edges []
                        :lists (vector (list :name "order"
                                             :ids ["d:r" "f:a.txt" "s:a.txt:0:9:f" "m:a.txt:1:4" "m:a.txt:2:4"
                                                   "f:b.txt" "s:b.txt:top" "m:b.txt:5:4"])))))))))

(defun drgnx-replace-rows-nav-test--model ()
  "The hub's model of a search: a.txt (matches on lines 1 and 2), then b.txt (one match on line 5)."
  (if drgnx-replace-rows-nav-test--grouped (drgnx-replace-rows-nav-test--grouped-model)
    (let ((file (lambda (f name) (list :id (concat "f:" (substring f 3)) :kind "file" :flags 1
                                       :fields (vector (vector "label" name) (vector "path" f)))))
          (hit (lambda (f line) (list :id (format "m:%s:%d:4" (substring f 3) line) :kind "match" :flags 0
                                      :parent (concat "f:" (substring f 3))
                                      :fields (vector (vector "label" "let needle;") (vector "line" line)
                                                      (vector "col" 4) (vector "end" 10) (vector "text" "needle"))))))
      (json-serialize
       (list :ops
             (vector
              (list :reset
                    (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["order"]
                                            :classes ["selected" "match" "dim"] :flags ["expanded"] :forms []
                                            :start "order")
                          :nodes (vector (funcall file "/r/a.txt" "a.txt") (funcall hit "/r/a.txt" 1)
                                         (funcall hit "/r/a.txt" 2) (funcall file "/r/b.txt" "b.txt")
                                         (funcall hit "/r/b.txt" 5))
                          :edges []
                          :lists (vector (list :name "order"
                                               :ids ["f:a.txt" "m:a.txt:1:4" "m:a.txt:2:4" "f:b.txt"
                                                     "m:b.txt:5:4"]))))))))))

(defun drgnx-replace-rows-nav-test--row (id text box)
  "The hub's row ID: TEXT, its tick box at BOX, the node id over the whole row."
  (list :key id :text text
        :props (list (list box (+ box 3) "drgnx-replace-box" id) (list 0 (length text) "drgnx-work-id" id))))

(defun drgnx-replace-rows-nav-test--rows ()
  (if drgnx-replace-rows-nav-test--grouped
      (list (let ((row (drgnx-replace-rows-nav-test--row "d:r" "▾ [x] r/  2" 2)))
              (plist-put row :props (cons (list 0 1 "drgnx-replace-fold" "d:r") (plist-get row :props))))
            (drgnx-replace-rows-nav-test--row "f:a.txt" "  [x] a.txt" 2)
            (drgnx-replace-rows-nav-test--row "s:a.txt:0:9:f" "    [x] ƒ f  2" 4)
            (drgnx-replace-rows-nav-test--row "m:a.txt:1:4" "      [x] let needle;" 6)
            (drgnx-replace-rows-nav-test--row "m:a.txt:2:4" "      [x] let needle;" 6)
            (drgnx-replace-rows-nav-test--row "f:b.txt" "[x] b.txt" 0)
            (drgnx-replace-rows-nav-test--row "s:b.txt:top" "  [x] (top level)  1" 2)
            (drgnx-replace-rows-nav-test--row "m:b.txt:5:4" "    [x] let needle;" 4))
    (list (drgnx-replace-rows-nav-test--row "f:a.txt" "[x] a.txt" 0)
          (drgnx-replace-rows-nav-test--row "m:a.txt:1:4" "  [x] let needle;" 2)
          (drgnx-replace-rows-nav-test--row "m:a.txt:2:4" "  [x] let needle;" 2)
          (drgnx-replace-rows-nav-test--row "f:b.txt" "[x] b.txt" 0)
          (drgnx-replace-rows-nav-test--row "m:b.txt:5:4" "  [x] let needle;" 2))))

(defmacro drgnx-replace-rows-nav-test--with (&rest body)
  "BODY in the Search view's buffer on the rows path holding the model and rows above, nothing selected, nothing sent."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (should-not (get-buffer drgnx-replace-buffer-name))
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-old-path nil)
           (drgnx-view-patch-send-function #'ignore)
           (view (format "rrn-test-%d" (cl-incf drgnx-replace-rows-nav-test--n)))
           (buf (get-buffer-create drgnx-replace-buffer-name)))
       (with-current-buffer buf
         (drgnx-replace-mode)
         (setq drgnx-replace--root "/r/")      ; the hub's ids name files relative to it
         ;; the view's tables, as `drgnx-replace--render-view' makes them
         (setq drgnx-replace--off (make-hash-table :test #'eq))
         (dolist (v '(drgnx-replace--seen drgnx-replace--listed drgnx-replace--off-files drgnx-replace--headers
                                          drgnx-replace--last-row))
           (set v (make-hash-table :test #'equal)))
         (drgnx-view-patch-attach view "c" :epoch 1)
         (drgnx-replace-rows-attached)
         (unwind-protect
             (progn
               (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                             :model (drgnx-replace-rows-nav-test--model)))
               (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 0 :version 1 :env_epoch 1 :model 1
                                             :ops (list (list :reset (drgnx-replace-rows-nav-test--rows)))))
               (drgnx-view-draw-now drgnx-view)
               ,@body)
           (drgnx-view-patch-teardown)
           (drgnx-timer-cancel (cons 'drgnx-view buf))
           (drgnx-timer-cancel (cons 'drgnx-view-nav-notice buf))
           (drgnx-timer-cancel (cons 'drgnx-view-model view))
           (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))

(defun drgnx-replace-rows-nav-test--boxes ()
  "Each row's tick box as shown: the overlay's `display' over the drawn text."
  (save-excursion
    (goto-char (point-min))
    (let (boxes)
      (while (not (eobp))
        (when-let* ((pos (text-property-not-all (point) (line-end-position) 'drgnx-replace-box nil)))
          (push (or (cl-some (lambda (o) (overlay-get o 'display)) (overlays-at pos))
                    (buffer-substring-no-properties pos (+ pos 3)))
                boxes))
        (forward-line 1))
      (nreverse boxes))))

(ert-deftest drgnx-replace-rows/next-match-walks-the-tree ()
  "Pattern D: Next Match goes from match to match over the file rows, wrapping at the end, Previous back; each is
shown in the editor from the model's fields."
  (drgnx-replace-rows-nav-test--with
    (let ((shown nil))
      (cl-letf (((symbol-function 'drgnx-replace--show-match) (lambda (m _select) (push m shown))))
        (drgnx-replace-next)
        (should (equal "m:a.txt:1:4" (drgnx-view-nav-selection)))
        (drgnx-replace-next)
        (drgnx-replace-next)
        (should (equal "m:b.txt:5:4" (drgnx-view-nav-selection)))
        (drgnx-replace-next)
        (should (equal "m:a.txt:1:4" (drgnx-view-nav-selection)))
        (drgnx-replace-prev)
        (should (equal "m:b.txt:5:4" (drgnx-view-nav-selection))))
      (should (equal '(:file "/r/b.txt" :line 5 :col 4 :end 10 :text "needle") (car shown)))
      (should (= 5 (length shown))))))

(ert-deftest drgnx-replace-rows/ticks-are-user-state ()
  "Pattern D: a match's box unticks in Sjá and shows [ ], its file's [-]; the file's box then unticks all of its
matches, and again ticks them all; a hub patch that redraws a row keeps its box as the ticks say."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:2:4")
    (should (equal ["m:a.txt:2:4"] (vconcat (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked))))
    (should (equal '("[-]" "[x]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-replace--rows-tick "f:a.txt")
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    ;; the hub redraws a row (a new replace preview): the box goes back on
    (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                  :env_epoch 1 :model 1
                                  :ops (list (list :replace (list (drgnx-replace-rows-nav-test--row
                                                                   "m:a.txt:1:4" "  [x] let needlepin;" 2))))))
    (drgnx-view-draw-now drgnx-view)
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-replace--rows-tick "f:a.txt")
    (should (equal '("[x]" "[x]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))))

(defun drgnx-replace-rows-nav-test--box-at (id)
  "Where row ID's tick box starts."
  (let ((p (point-min)) found)
    (while (and (not found) (setq p (text-property-not-all p (point-max) 'drgnx-replace-box nil)))
      (if (equal (get-text-property p 'drgnx-work-id) id)
          (setq found p)
        (setq p (or (next-single-property-change p 'drgnx-replace-box) (point-max)))))
    found))

(ert-deftest drgnx-replace-rows/ret-and-a-click-on-a-box-tick-it ()
  "Pattern D: a hub row's tick box is a button (SJA-SEARCH-1 (1)): RET on a match's box unticks it in Sjá, a click on
its file's box (a link: mouse-1 follows it) unticks the file's other match, and a box a hub patch redraws is one again."
  (drgnx-replace-rows-nav-test--with
    (goto-char (drgnx-replace-rows-nav-test--box-at "m:a.txt:2:4"))
    (call-interactively (key-binding (kbd "RET")))
    (should (equal '("[-]" "[x]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (let ((file (drgnx-replace-rows-nav-test--box-at "f:a.txt")))
      (should (mouse-on-link-p file))
      (push-button file))
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                  :env_epoch 1 :model 1
                                  :ops (list (list :replace (list (drgnx-replace-rows-nav-test--row
                                                                   "m:b.txt:5:4" "  [x] let needlepin;" 2))))))
    (drgnx-view-draw-now drgnx-view)
    (goto-char (drgnx-replace-rows-nav-test--box-at "m:b.txt:5:4"))
    (call-interactively (key-binding (kbd "RET")))
    (should (equal '("[ ]" "[ ]" "[ ]" "[ ]" "[ ]") (drgnx-replace-rows-nav-test--boxes)))))

(ert-deftest drgnx-replace-rows/a-new-search-ticks-every-match-again ()
  "Pattern D: a new search empties Sjá's ticked set, as the old path empties its unticked matches (SJA-SEARCH-1 (2)):
else a match of the new search with the same file, line and column as an unticked one would start unticked."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:2:4")
    (drgnx-replace--rows-tick "m:b.txt:5:4")
    (let ((searched 0))
      (cl-letf (((symbol-function 'drgnx-replace--hub-ready-p) #'always)
                ((symbol-function 'drgnx-replace--hub-search) (lambda (&rest _) (cl-incf searched)))
                ((symbol-function 'drgnx-replace--ensure-origin) #'ignore)
                ((symbol-function 'drgnx-replace--update-status) #'ignore))   ; the fields' status line
        (drgnx-replace--search-now))
      (should (= 1 searched)))
    (should-not (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked))
    (should (equal '("[x]" "[x]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))))

(ert-deftest drgnx-replace-rows/next-and-previous-file-walk-the-files ()
  "Pattern D: Next File selects the next file's row from a match (`down:file' in Sjá), Previous File the one before;
both have keys in every profile (SJA-SEARCH-1 (4))."
  (drgnx-replace-rows-nav-test--with
    (drgnx-view-nav 'select "m:a.txt:2:4")
    (drgnx-replace-next-file)
    (should (equal "f:b.txt" (drgnx-view-nav-selection)))
    (drgnx-replace-prev-file)
    (should (equal "f:a.txt" (drgnx-view-nav-selection)))
    (dolist (id '(replace-next-file replace-prev-file))
      (dolist (profile '("vscode" "emacs" "vim"))
        (with-temp-buffer
          (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
          (should (search-forward (format "(%s " id) nil t)))))))

(defmacro drgnx-replace-rows-nav-test--hub (&rest body)
  "BODY with the hub's calls recorded in `calls' (newest first, (METHOD . PARAMS)): `search/edits' answers change 7,
skipping nothing; the others answer t."
  (declare (indent 0))
  `(let ((calls nil))
     (cl-letf (((symbol-function 'drgnx-hub--call-on)
                (lambda (_conn method params cb &rest _)
                  (push (cons method params) calls)
                  (when cb (funcall cb (if (equal method "search/edits") '(:change 7 :files [] :skipped []) t) nil))))
               ((symbol-function 'drgnx-replace--search-now) #'ignore)
               ((symbol-function 'drgnx-replace--message)
                (lambda (fmt &rest args) (setq drgnx-replace--status (apply #'format fmt args)))))
       ,@body)))

(ert-deftest drgnx-replace-rows/replace-all-writes-the-ticked ()
  "Pattern D: Replace All asks the hub for the edit set of its search's matches but the unticked (`search/edits',
`off'), then writes it (`search/apply', naming the files open here); when the write ends (`search-change') the list is
what it left (none here: `search/grep-skipped' with no match), not a new search, and Undo can put it back."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:1:4")
    (drgnx-replace-rows-nav-test--hub
      (drgnx-replace--rows-replace-all "pin")
      (should (equal `("search/apply" "search/edits") (mapcar #'car calls)))
      (should (equal `(:view ,drgnx-replace-view :off ["m:a.txt:1:4"] :replace "pin") (cdr (nth 1 calls))))
      (should (equal 7 (plist-get (cdr (car calls)) :change)))
      (should (vectorp (plist-get (cdr (car calls)) :open)))
      (setq calls nil)
      (drgnx-replace--hub-event "search-change" (list :view drgnx-replace-view :change 7 :origin "replace-all"
                                                      :written 3 :files 2 :skipped []))
      (should (equal `(("search/grep-skipped" :view ,drgnx-replace-view :skipped [])) calls))
      (should (equal '(7) drgnx-replace--undo))
      (should (string-match-p "Replaced 3 in 2 files" drgnx-replace--status)))))

(defconst drgnx-replace-rows-nav-test--preview
  '(:path "/r/a.txt" :plus 2 :minus 2
          :diff "--- /r/a.txt\n+++ /r/a.txt\n@@ -1,3 +1,3 @@\n-let needle;\n-let needle;\n+let pin;\n+let pin;\n let needle;\n"
          :hunks ((:old_start 1 :old_lines 3 :new_start 1 :new_lines 3 :ids ("m:a.txt:1:4" "m:a.txt:2:4")
                              :captures ((:id "m:a.txt:1:4" :groups ("need" nil))) :kept (3))))
  "The hub's `search/preview' of a.txt: one hunk with two matches, a regexp's groups for the first, and line 3's match
unticked (kept).  Arrays are
lists, as the hub client decodes them (`:array-type' `list').")

(defun drgnx-replace-rows-nav-test--tile ()
  (get-buffer "a.txt · preview"))

(ert-deftest drgnx-replace-rows/preview-shows-a-files-diff-and-its-hunks-tick-the-rows ()
  "Pattern D: Preview This File's Changes asks the hub for the row's file (`search/preview', with the unticked and
the replacement) and draws its diff read-only: the counts, each hunk with its tick box, its lines and the groups line
\(a group that matched nothing is ∅).  `D' on the hunk unticks its matches in the view, `a' ticks them again; the
tile is asked for again."
  (drgnx-replace-rows-nav-test--with
    (cl-letf (((symbol-function 'drgnx-replace--live-view) (lambda () (get-buffer drgnx-replace-buffer-name)))
              ((symbol-function 'drgnx-replace--text) (lambda (_) "pin"))
              ((symbol-function 'drgnx-wb-show-in-editor) #'ignore))
      (unwind-protect
          (let ((calls nil))
            (cl-letf (((symbol-function 'drgnx-hub--call-on)
                       (lambda (_conn method params cb &rest _)
                         (push (cons method params) calls)
                         (funcall cb drgnx-replace-rows-nav-test--preview nil))))
              (drgnx-view-nav 'select "m:a.txt:2:4")
              (drgnx-replace-preview-file)
              (should (equal `("search/preview" :view ,drgnx-replace-view :path "/r/a.txt" :off [] :replace "pin")
                             (car calls)))
              (with-current-buffer (drgnx-replace-rows-nav-test--tile)
                (should (derived-mode-p 'drgnx-replace-preview-mode))
                (should buffer-read-only)
                (let ((text (buffer-string)))
                  (should (string-match-p "2 of 3 matches ticked · \\+2 −2"   ; the head is the header line
                                          (mapconcat (lambda (x) (if (stringp x) x "")) header-line-format "")))
                  (should (string-match-p "hunk 1" text))
                  ;; line 3's match is unticked (kept) inside the hunk: the hunk is partly ticked
                  (should (equal "[-]" (get-text-property (text-property-not-all (point-min) (point-max)
                                                                                 'drgnx-replace-tick nil)
                                                          'drgnx-replace-tick)))
                  ;; each line ends in the stretch that stops its tint at the card
                  (should (string-match-p "^    1 - let needle; $" text))   ; the old file's line number (after the 8 px inset)
                  (should (string-match-p "^    2 \\+ let pin; $" text))     ; the new file's
                  (should (string-match-p "^    3   let needle;   ← unticked, kept $" text))
                  (should (string-match-p "groups   \\\\1 = need   \\\\2 = ∅" text)))
                (goto-char (point-min))
                (search-forward "hunk 1")
                (setq calls nil)
                (drgnx-replace-preview-drop)))
            (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
            (should (equal '("m:a.txt:1:4" "m:a.txt:2:4")
                           (sort (append (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked) nil)
                                 #'string<)))
            (with-current-buffer (drgnx-replace-rows-nav-test--tile)
              (goto-char (point-min))
              (search-forward "hunk 1")
              (drgnx-replace-preview-keep))
            (should-not (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked)))
        (when-let* ((b (drgnx-replace-rows-nav-test--tile))) (kill-buffer b))))))

(ert-deftest drgnx-replace-rows/a-hunk-shows-no-blank-context-at-its-ends ()
  "Pattern A: a hunk's empty context lines at its start and end are left out (the mockup's hunks start and end on
text); the numbers of the lines kept are still the file's."
  (let ((out (substring-no-properties
              (drgnx-replace--hunk-lines "" (list :header "@@ -9,4 +9,4 @@" :lines '(" " "-a x" "+a y" " b" " "))))))
    (should (equal out "  10 - a x\n  10 + a y\n  11   b\n"))))

(ert-deftest drgnx-replace-rows/a-hunks-tints-stop-at-the-card ()
  "Pattern A: with a stop, a diff line's tint ends at it (a stretch in the line's face), and its newline carries no
tint, so nothing extends to the window's edge (the mockup's `.dl' margin)."
  (let* ((stop '(- right (8)))
         (out (drgnx-replace--hunk-lines "" (list :header "@@ -9,2 +9,2 @@" :lines '("-a x" "+a y")) nil nil nil stop))
         (nl (string-search "\n" out)))
    (should (equal (substring-no-properties out) "   9 - a x \n   9 + a y \n"))
    (should (equal `(space :align-to ,stop) (get-text-property (1- nl) 'display out)))
    (should (memq 'drgnx-replace-preview-del (ensure-list (get-text-property (1- nl) 'face out))))
    (should-not (memq 'drgnx-replace-preview-del (ensure-list (get-text-property nl 'face out))))
    ;; the line number is inside the tint (the mockup's `.dl .n'), in its own colour
    (should (memq 'drgnx-replace-preview-del (ensure-list (get-text-property 1 'face out))))
    (should (eq 'drgnx-replace-preview-number (car (ensure-list (get-text-property 1 'face out)))))))

(ert-deftest drgnx-replace-rows/a-preview-tile-has-its-own-header-line-at-once ()
  "Pattern D: a preview tile has a header line of its own from the start, before the hub's answer: the editor's chrome
shows a buffer's own header line (Open File, Replace in This File) only when it has one as the window shows it."
  (let ((buf (drgnx-replace--preview-buffer "/r/a.txt")))
    (unwind-protect
        (with-current-buffer buf
          (should (local-variable-p 'header-line-format))
          (should header-line-format)
          ;; no hollow box where the hunk's tick is when the tile is not the selected window
          (should (local-variable-p 'cursor-in-non-selected-windows))
          (should-not cursor-in-non-selected-windows))
      (kill-buffer buf))))

(ert-deftest drgnx-replace-rows/replace-all-shows-the-sheet-first ()
  "Pattern D: Replace All shows the Replace All sheet (threshold 1) with the edit set: every file with its lines added
and removed, what is skipped and why; Cancel writes nothing, Replace writes that edit set (`search/apply' of its
change); `C-u' Replace All writes at once, no sheet."
  (drgnx-replace-rows-nav-test--with
    (let ((answer '(:change 7 :skipped ((:id "m:b.txt:5:4" :path "/r/b.txt" :why "changed on disk since the search"))
                            :files ((:path "/r/a.txt" :source "disk"
                                           :edits ((:id "m:a.txt:1:4" :line 1) (:id "m:a.txt:2:4" :line 2))))))
          (calls nil) (refits nil))
      (cl-letf (((symbol-function 'drgnx-hub--call-on)
                 (lambda (_conn method params cb &rest _)
                   (push (cons method params) calls)
                   (pcase method
                     ("search/edits" (funcall cb answer nil))
                     ("search/preview" (funcall cb drgnx-replace-rows-nav-test--preview nil))
                     (_ (funcall cb t nil)))))
                ((symbol-function 'drgnx-replace--live-view) (lambda () (get-buffer drgnx-replace-buffer-name)))
                ((symbol-function 'drgnx-replace--text) (lambda (_) "pin"))
                ((symbol-function 'drgnx-popup-refit) (lambda (b) (push b refits)))
                ((symbol-function 'pop-to-buffer) #'set-buffer))
        (unwind-protect
            (progn
              (drgnx-replace--rows-replace-all "pin" t)
              (with-current-buffer drgnx-replace-sheet-buffer-name
                (should (derived-mode-p 'drgnx-replace-sheet-mode))
                (let ((text (buffer-string)))
                  (should (string-match-p "Replace 2 matches in 1 file · 1 skipped" text))
                  (should (string-match-p "a.txt \\+2 −2" text))
                  ;; the selected file's first hunk, 44 px in, inside its card (a stretch; one space in batch)
                  (should (string-match-p "^    1 - let needle; $" text))
                  (should (equal (get-text-property (string-match "^    1 - let needle; $" text) 'display text)
                                 `(space :width (,(drgnx-px 44)))))
                  (should (get-text-property (match-beginning 0) 'drgnx-replace-sheet-hunk text))
                  ;; its tint stops inside the card (a stretch to its edge), not at the window's
                  (let ((end (1- (match-end 0))))
                    (should (eq 'space (car-safe (get-text-property end 'display text))))
                    (should (eq :align-to (nth 1 (get-text-property end 'display text))))
                    (should-not (memq 'drgnx-replace-preview-del (ensure-list (get-text-property (1+ end) 'face text)))))
                  ;; the counts are coloured text, no diff tint
                  (let ((faces (ensure-list (get-text-property (string-match "\\+2" text) 'face text))))
                    (should (memq 'drgnx-replace-plus faces))
                    (should-not (memq 'drgnx-replace-preview-add faces)))
                  ;; the hairline above the foot, and the one under the title
                  (should (text-property-any 0 (length text) 'face 'drgnx-replace-sheet-rule text))
                  (should (eq 'drgnx-replace-sheet-rule
                              (get-text-property (1+ (string-search "\n" text)) 'face text)))
                  (should (string-match-p "1 skipped: changed on disk since the search" text))
                  ;; the hunk's changed lines only, as the mockup's sheet: no context line
                  (should-not (string-match-p "3   let needle;" text)))
                ;; the hunk comes after the sheet shows: the lane fits it again; the sheet's foot replaces a mode line
                (should (memq (current-buffer) refits))
                (should-not mode-line-format)
                (should-not (assoc "search/apply" calls))
                (cl-letf (((symbol-function 'quit-window) (lambda (&rest _) nil)))
                  (drgnx-replace-sheet-confirm)))
              (should (equal 7 (plist-get (cdr (assoc "search/apply" calls)) :change)))
              (setq calls nil)
              (drgnx-replace--rows-replace-all "pin" nil)
              (should (equal '("search/apply" "search/edits") (mapcar #'car calls))))
          (when-let* ((b (get-buffer drgnx-replace-sheet-buffer-name))) (kill-buffer b)))))))

(ert-deftest drgnx-replace-rows/the-sheet-hunk-card-follows-the-theme ()
  "Pattern D: the sheet's hunk is a Glitnir block ring (`glitnir-blocks' on the window showing it): around the hunk's
rows, 40 px in, radius 6, in `drgnx-border-subtle', its corners in the colour under it (the sheet's surface).  The
window parameter is set once per change, never again for a redraw that changes nothing, and again when the theme
changes the colour beneath."
  (drgnx-replace-rows-nav-test--with
    (let ((answer '(:change 7 :skipped nil
                            :files ((:path "/r/a.txt" :source "disk"
                                           :edits ((:id "m:a.txt:1:4" :line 1) (:id "m:a.txt:2:4" :line 2))))))
          (sets 0) (setp (symbol-function 'set-window-parameter)))
      (custom-declare-theme 'drgnx-test-sheet-a nil)
      (custom-declare-theme 'drgnx-test-sheet-b nil)
      (custom-theme-set-faces 'drgnx-test-sheet-a '(drgnx-surface-overlay ((t :background "#101112"))))
      (custom-theme-set-faces 'drgnx-test-sheet-b '(drgnx-surface-overlay ((t :background "#f0f1f2"))))
      (cl-letf (((symbol-function 'drgnx-hub--call-on)
                 (lambda (_conn method _params cb &rest _)
                   (pcase method
                     ("search/edits" (funcall cb answer nil))
                     ("search/preview" (funcall cb drgnx-replace-rows-nav-test--preview nil))
                     (_ (funcall cb t nil)))))
                ((symbol-function 'drgnx-replace--live-view) (lambda () (get-buffer drgnx-replace-buffer-name)))
                ((symbol-function 'drgnx-replace--text) (lambda (_) "pin"))
                ((symbol-function 'drgnx-popup-refit) #'ignore)
                ((symbol-function 'pop-to-buffer) (lambda (b &rest _) (set-window-buffer (selected-window) b) (set-buffer b)))
                ((symbol-function 'set-window-parameter)
                 (lambda (w p v) (when (eq p 'glitnir-blocks) (setq sets (1+ sets))) (funcall setp w p v))))
        (unwind-protect
            (progn
              (enable-theme 'drgnx-test-sheet-a)
              (drgnx-replace--rows-replace-all "pin" t)
              (with-current-buffer drgnx-replace-sheet-buffer-name
                (let* ((w (selected-window)) (card (window-parameter w 'glitnir-blocks)) (b (car card))
                       (hunk (text-property-any (point-min) (point-max) 'drgnx-replace-sheet-hunk t)))
                  (should (= (length card) 1))
                  (should (eq (car b) 'ring))
                  (should (= (marker-position (nth 1 b)) hunk))
                  (should (= (marker-position (nth 2 b))
                             (or (next-single-property-change hunk 'drgnx-replace-sheet-hunk) (point-max))))
                  (should (equal (list (plist-get (nthcdr 3 b) :x0) (plist-get (nthcdr 3 b) :radius)
                                       (plist-get (nthcdr 3 b) :ring) (plist-get (nthcdr 3 b) :beneath))
                                 (list (drgnx-px 40) (drgnx-px 6) 'drgnx-border-subtle "#101112")))
                  (let ((n sets))
                    ;; a redraw that changes nothing sets nothing
                    (drgnx-replace--sheet-draw)
                    (should (= sets n))
                    (should (eq (window-parameter w 'glitnir-blocks) card))
                    ;; a theme change: the colour beneath follows, set once
                    (disable-theme 'drgnx-test-sheet-a)
                    (setq n sets)
                    (enable-theme 'drgnx-test-sheet-b)
                    (should (= sets (1+ n)))
                    (should (equal (plist-get (nthcdr 3 (car (window-parameter w 'glitnir-blocks))) :beneath)
                                   "#f0f1f2"))))))
          (disable-theme 'drgnx-test-sheet-a)
          (disable-theme 'drgnx-test-sheet-b)
          (when-let* ((b (get-buffer drgnx-replace-sheet-buffer-name))) (kill-buffer b))
          (should-not (window-parameter (selected-window) 'glitnir-blocks)))))))

(ert-deftest drgnx-replace-rows/replace-all-leaves-the-skipped-with-their-reasons ()
  "Pattern D: a match Replace All skipped stays listed with its reason (SJA-SEARCH-1 (3)): the hub is told which
\(`search/grep-skipped', by node id) and lists only those; the ticks start over."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:1:4")
    (drgnx-replace-rows-nav-test--hub
      (drgnx-replace--rows-replace-all "pin")
      (setq calls nil)
      (drgnx-replace--hub-event "search-change"
                                (list :view drgnx-replace-view :change 7 :origin "replace-all" :written 2 :files 1
                                      :skipped [(:id "m:b.txt:5:4" :path "/r/b.txt" :why "changed on disk since the preview")]))
      (should (equal `(("search/grep-skipped" :view ,drgnx-replace-view
                        :skipped [(:id "m:b.txt:5:4" :why "changed on disk since the preview")]))
                     calls))
      (should-not (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked)))))

(ert-deftest drgnx-replace-rows/undo-puts-back-the-last-write ()
  "Pattern D: Undo Replace asks the hub to put back the view's last change set (`search/undo'); when it ends the view
searches again and says which files it left alone (edited since)."
  (drgnx-replace-rows-nav-test--with
    (setq drgnx-replace--undo '(7))
    (cl-letf (((symbol-function 'drgnx-replace--live-view) (lambda () (current-buffer))))
      (drgnx-replace-rows-nav-test--hub
        (let ((searched 0))
          (cl-letf (((symbol-function 'drgnx-replace--search-now) (lambda () (cl-incf searched))))
            (drgnx-replace-view-undo)
            (should (equal "search/undo" (caar calls)))
            (should (equal 7 (plist-get (cdar calls) :change)))
            (should-not drgnx-replace--undo)
            (drgnx-replace--hub-event "search-change" (list :view drgnx-replace-view :change 8 :origin "undo" :undoes 7
                                                            :written 2 :files 1 :skipped [] :left ["/r/b.txt"]))
            (should (= 1 searched))
            (should (equal "Undone in 1 file; left alone (changed since): b.txt" drgnx-replace--status))
            (should-not drgnx-replace--undo)))))))

(defun drgnx-replace-rows-nav-test--drop-b ()
  "The hub sent a window of the rows that stops after a.txt: b.txt's rows are not in the view (its nodes are in the model)."
  (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                :env_epoch 1 :model 1 :ops (list (list :remove (list "f:b.txt" "m:b.txt:5:4")))))
  (drgnx-view-draw-now drgnx-view)
  (should-not (gethash "m:b.txt:5:4" (drgnx-view-patch-rows drgnx-view-patch))))

(ert-deftest drgnx-replace-rows/next-match-beyond-the-rows-asks-the-hub-for-its-row ()
  "Pattern D: the model holds every match, the hub sends a window of the rows: Next Match to a match whose row is not
in the view selects it from the model, shows it in the editor and asks the hub for the rows up to it (`upto'); a match
whose row is in the view asks nothing."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace-rows-nav-test--drop-b)
    (let ((asked nil) (shown nil))
      (cl-letf (((symbol-function 'drgnx-replace--look) (lambda (params) (push params asked)))
                ((symbol-function 'drgnx-replace--show-match) (lambda (m _select) (push m shown))))
        (drgnx-replace-next)
        (drgnx-replace-next)
        (should-not asked)
        (drgnx-replace-next)
        (should (equal "m:b.txt:5:4" (drgnx-view-nav-selection)))
        (should (equal '((:upto "m:b.txt:5:4")) asked))
        (should (equal '(:file "/r/b.txt" :line 5 :col 4 :end 10 :text "needle") (car shown)))
        ;; the row arrives: point goes to it
        (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 2 :version 3
                                      :env_epoch 1 :model 1
                                      :ops (list (list :insert (list :after "m:a.txt:2:4"
                                                                     :rows (list (drgnx-replace-rows-nav-test--row "f:b.txt" "[x] b.txt" 0)
                                                                                 (drgnx-replace-rows-nav-test--row "m:b.txt:5:4" "  [x] let needle;" 2)))))))
        (drgnx-view-draw-now drgnx-view)
        (should (equal "m:b.txt:5:4" (get-text-property (line-beginning-position) 'drgnx-work-id)))))))

(ert-deftest drgnx-replace-rows/replace-all-writes-the-matches-beyond-the-rows ()
  "Pattern D: Replace All names the unticked, not the rows: with b.txt's rows not in the view the hub's edit set still
holds its match (no `ids': every match of the search but the `off' ones)."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace-rows-nav-test--drop-b)
    (drgnx-replace-rows-nav-test--hub
      (drgnx-replace--rows-replace-all "pin")
      (should (equal `(:view ,drgnx-replace-view :off [] :replace "pin") (cdr (nth 1 calls)))))))

(ert-deftest drgnx-replace-rows/the-end-of-the-rows-asks-for-more-once-per-growth ()
  "Pattern D: when the window shows the end of the rows the view asks the hub for one more window (`more'); it asks
again only when the rows have grown since, so a hub with no more is not asked over and over."
  (drgnx-replace-rows-nav-test--with
    (let ((asked nil) (win (selected-window)) (old (window-buffer (selected-window))))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-replace--look) (lambda (params) (push params asked))))
            (set-window-buffer win (current-buffer))
            (drgnx-replace--look-more win)
            (drgnx-replace--look-more win)
            (should (equal '((:more t)) asked))
            (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                          :env_epoch 1 :model 1
                                          :ops (list (list :insert (list :after "m:b.txt:5:4"
                                                                         :rows (list (drgnx-replace-rows-nav-test--row
                                                                                      "m:b.txt:6:4" "  [x] let needle;" 2)))))))
            (drgnx-view-draw-now drgnx-view)
            (drgnx-replace--look-more win)
            (should (equal '((:more t) (:more t)) asked)))
        (set-window-buffer win old)))))

(ert-deftest drgnx-replace-rows/a-gap-in-sight-asks-for-the-rows-before-it ()
  "Pattern D: after a far jump the hub sends a block of rows after a gap row (SJA-ROWS-FAR-1); when the window shows
the gap row the view asks for the rows before it (`fill'), again only once the rows have changed."
  (drgnx-replace-rows-nav-test--with
    (let ((asked nil) (win (selected-window)) (old (window-buffer (selected-window))))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-replace--look) (lambda (params) (push params asked))))
            (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                          :env_epoch 1 :model 1
                                          :ops (list (list :insert (list :after "m:a.txt:2:4"
                                                                         :rows (list (list :key "gap" :text "  ⋯ 1200 more")))))))
            (drgnx-view-draw-now drgnx-view)
            (set-window-buffer win (current-buffer))
            (drgnx-replace--look-more win)
            (drgnx-replace--look-more win)
            (should (equal 1 (cl-count '(:fill t) asked :test #'equal)))
            (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 2 :version 3
                                          :env_epoch 1 :model 1
                                          :ops (list (list :replace (list (list :key "gap" :text "  ⋯ 1000 more"))))))
            (drgnx-view-draw-now drgnx-view)
            (drgnx-replace--look-more win)
            (should (equal 2 (cl-count '(:fill t) asked :test #'equal))))
        (set-window-buffer win old)))))

;;; replace-rows-nav-test.el ends here

(ert-deftest drgnx-replace-rows/grouped-ticks-cascade-down-the-tree ()
  "Pattern D: grouped (Folders, Symbols), a group's box ticks everything under it (the file box's rule, a level up):
a folder's every file's matches, a definition's its own; a match's box shows [-] on each group above it; Replace
finds a match's file on its definition's `path'."
  (let ((drgnx-replace-rows-nav-test--grouped t))
    (drgnx-replace-rows-nav-test--with
      (should (equal '("m:a.txt:1:4" "m:a.txt:2:4") (drgnx-replace--rows-file-matches "d:r")))
      (drgnx-replace--rows-tick "m:a.txt:2:4")
      (should (equal '("[-]" "[-]" "[-]" "[x]" "[ ]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
      (drgnx-replace--rows-tick "d:r")
      (should (equal '("[ ]" "[ ]" "[ ]" "[ ]" "[ ]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
      (drgnx-replace--rows-tick "s:a.txt:0:9:f")
      (should (equal '("[x]" "[x]" "[x]" "[x]" "[x]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
      (drgnx-replace--rows-tick "s:b.txt:top")
      (should (equal '("[x]" "[x]" "[x]" "[x]" "[x]" "[ ]" "[ ]" "[ ]") (drgnx-replace-rows-nav-test--boxes)))
      (should (equal "/r/b.txt" (plist-get (drgnx-replace--rows-match "m:b.txt:5:4") :file)))
      (should (equal "f:a.txt" (drgnx-replace--rows-file-of "s:a.txt:0:9:f")))
      (should-not (drgnx-replace--rows-file-of "d:r")))))

(ert-deftest drgnx-replace-rows/next-group-walks-the-definitions-in-symbols ()
  "Pattern D: grouped by Symbols, Next File / Previous File (Next Group) walk the definitions (`down:symbol')."
  (let ((drgnx-replace-rows-nav-test--grouped t))
    (drgnx-replace-rows-nav-test--with
      (setq drgnx-replace--group 'symbol)
      (drgnx-view-nav 'select "m:a.txt:1:4")
      (drgnx-replace-next-file)
      (should (equal "s:b.txt:top" (drgnx-view-nav-selection)))
      (drgnx-replace-prev-file)
      (should (equal "s:a.txt:0:9:f" (drgnx-view-nav-selection))))))

(ert-deftest drgnx-replace-rows/grouping-regroups-without-searching ()
  "Pattern D: the grouping control (and Next Grouping) asks the hub to regroup (`search/group', the sort with it),
never a search again; a new search keeps the grouping (`search/run''s `group' and `sort'); the keys are in every
profile."
  (let ((drgnx-replace-rows-nav-test--grouped t))
    (drgnx-replace-rows-nav-test--with
      (drgnx-replace-rows-nav-test--hub
        (let ((searched 0))
          (cl-letf (((symbol-function 'drgnx-replace--search-now) (lambda (&rest _) (cl-incf searched))))
            (drgnx-replace-search-group-next)
            (should (eq 'tree drgnx-replace--group))
            (should (equal "search/group" (caar calls)))
            (should (equal "tree" (plist-get (cdar calls) :group)))
            (drgnx-replace-search-group 'symbol 'count)
            (should (equal '("symbol" "count") (list (plist-get (cdar calls) :group) (plist-get (cdar calls) :sort))))
            (should (= 0 searched))
            ;; Folders: a folder's chevron folds it (`search/fold'), on its row or a row under it
            (drgnx-replace-search-group 'tree)
            (drgnx-replace-search-fold "d:r")
            (should (equal '("search/fold" :view nil :node "d:r" :open :false)
                           (cons (caar calls) (plist-put (cdar calls) :view nil))))
            (drgnx-replace-search-group 'symbol)
            (should-error (drgnx-replace-search-fold "d:r") :type 'user-error))
          (cl-letf (((symbol-function 'drgnx-replace--send-buffers) #'ignore)
                    ((symbol-function 'drgnx-replace--hub-attach) #'ignore))
            (drgnx-replace--hub-search "needle" nil))
          (should (equal "search/run" (caar calls)))
          (should (equal '("symbol" "count") (list (plist-get (cdar calls) :group) (plist-get (cdar calls) :sort))))))))
  (dolist (id '(search-group-next search-group search-fold))
    (dolist (profile '("vscode" "emacs" "vim"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
        (should (search-forward (format "(%s " id) nil t))))))
