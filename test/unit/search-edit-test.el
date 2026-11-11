;;; search-edit-test.el --- batch tests: Edit Results, the Search view's results as an editable buffer -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: `drgnx-hub--call-on' answers from a table and records the calls; the hub's end event (`search-change') is
;; given by hand.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "modules/tools/drgnx-search-edit" drgnx-dir) nil t)

(defconst drgnx-search-edit-test--doc
  '(:lines ((:line_id "l:0" :path "/r/a.el" :line 1 :text "(defvar one 1)" :kind "match" :eol t)
            (:line_id "l:1" :path "/r/a.el" :line 2 :text ";; between" :kind "context" :eol t)
            (:line_id "l:2" :path "/r/a.el" :line 3 :text "(defvar two 2)" :kind "match" :eol t)
            (:line_id "l:3" :path "/r/b.txt" :line 5 :text "one more" :kind "match" :eol nil))
           :total 4)
  "The hub's `search/edit-doc' answer: a.el's lines 1 to 3 (2 is context), b.txt's last line (no newline after it).")

(defvar drgnx-search-edit-test--calls nil "The hub calls made, newest first: (METHOD PARAMS).")
(defvar drgnx-replace-view)
(defvar drgnx-replace--root)
(defvar drgnx-hub--events nil)          ; the hub client is not loaded: the stub below takes its calls

(defmacro drgnx-search-edit-test--with (answers &rest body)
  "BODY in an Edit Results buffer of the document above; the hub answers each method from ANSWERS (alist METHOD →
result), every call recorded."
  (declare (indent 1))
  `(let ((drgnx-search-edit-test--calls nil) (drgnx-search-edit--buffers nil) (buf nil))
     (cl-letf (((symbol-function 'drgnx-hub--call-on)
                (lambda (_conn method params cb &rest _)
                  (push (list method params) drgnx-search-edit-test--calls)
                  (funcall cb (cdr (assoc method ,answers)) nil)))
               ((symbol-function 'drgnx-replace--open-paths) (lambda () []))
               ((symbol-function 'drgnx-wb-show-in-editor) #'ignore))
       (unwind-protect
           (progn
             (setq buf (drgnx-search-edit--open "s" "one" "/r/" drgnx-search-edit-test--doc))
             (with-current-buffer buf ,@body))
         (when (buffer-live-p buf)
           (with-current-buffer buf (clrhash drgnx-search-edit--marked))
           (kill-buffer buf))))))

(defun drgnx-search-edit-test--goto (id)
  "Point at the start of line ID's text."
  (goto-char (drgnx-search-edit--line-start (cl-find id drgnx-search-edit--lines :key #'drgnx-search-edit--line-id
                                                     :test #'equal))))

(defun drgnx-search-edit-test--line (id)
  "Line ID's record."
  (cl-find id drgnx-search-edit--lines :key #'drgnx-search-edit--line-id :test #'equal))

(defun drgnx-search-edit-test--sent (method)
  "The params of the last call of METHOD."
  (cadr (assoc method drgnx-search-edit-test--calls)))

(defun drgnx-search-edit-test--edit (id text)
  "Replace line ID's text with TEXT, as typing would."
  (let ((l (drgnx-search-edit-test--line id)))
    (goto-char (drgnx-search-edit--line-start l))
    (delete-region (point) (drgnx-search-edit--line-end l))
    (insert text)))

(ert-deftest drgnx-search-edit/headers-and-numbers-are-read-only ()
  "Pattern D: the document shows each line once under its file's header, with its number; the header and the number
cannot be typed into, the line can; a context line is dim."
  (drgnx-search-edit-test--with '()
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "a.el  (3)\n1  (defvar one 1)\n2  ;; between\n3  (defvar two 2)\nb.txt  (1)\n5  one more\n"))
    (goto-char (point-min))
    (should-error (insert "x") :type 'text-read-only)
    (drgnx-search-edit-test--goto "l:0")
    (should-error (delete-char -1) :type 'text-read-only)
    (insert-and-inherit "z")
    (should (equal (drgnx-search-edit--text (drgnx-search-edit-test--line "l:0")) "z(defvar one 1)"))
    (let ((l (drgnx-search-edit-test--line "l:1")))
      (should (memq 'drgnx-search-edit-context
                    (ensure-list (get-text-property (drgnx-search-edit--line-start l) 'face)))))))

(ert-deftest drgnx-search-edit/save-sends-only-the-changed-lines ()
  "Pattern D: save collects the marked lines only, and of them only the ones whose text differs from the file's; the
edit set (`search/edits' with `lines') is applied (`search/apply'); when the hub ends the save, the lines take their
new text and lose their marks, and the header says what was saved."
  (drgnx-search-edit-test--with '(("search/edits" . (:change 9 :files nil :skipped nil)) ("search/apply" . t))
    (drgnx-search-edit-test--edit "l:2" "(defvar three 3)")
    (drgnx-search-edit-test--edit "l:0" "(defvar one 1)")   ; typed back as it was: not sent
    (should (= (hash-table-count drgnx-search-edit--marked) 2))
    (drgnx-search-edit-save)
    (let ((lines (plist-get (drgnx-search-edit-test--sent "search/edits") :lines)))
      (should (equal (append lines nil)
                     '((:line_id "l:2" :path "/r/a.el" :line 3 :old "(defvar two 2)" :new ["(defvar three 3)"] :eol t)))))
    (should (equal (plist-get (drgnx-search-edit-test--sent "search/apply") :change) 9))
    (should (drgnx-search-edit-change '(:view "s" :change 9 :origin "edit-results" :written 1 :files 1)))
    (should (equal (drgnx-search-edit--line-old (drgnx-search-edit-test--line "l:2")) "(defvar three 3)"))
    (should (= (hash-table-count drgnx-search-edit--marked) 0))
    (should-not (buffer-modified-p))
    (should (equal drgnx-search-edit--status "Saved 1 line in 1 file"))
    (should-not (drgnx-search-edit-change '(:view "s" :change 10 :origin "replace-all")))))

(ert-deftest drgnx-search-edit/a-line-typed-into-several-writes-them-all ()
  "Pattern D: a newline typed in a line makes it several lines: sent as one line with several new lines, and once
saved the lines after it in its file move down."
  (drgnx-search-edit-test--with '(("search/edits" . (:change 3 :files nil :skipped nil)) ("search/apply" . t))
    (drgnx-search-edit-test--goto "l:0")
    (forward-char (length "(defvar one 1)"))
    (insert-and-inherit "\n(defvar half 1.5)")
    (drgnx-search-edit-save)
    (should (equal (plist-get (aref (plist-get (drgnx-search-edit-test--sent "search/edits") :lines) 0) :new)
                   ["(defvar one 1)" "(defvar half 1.5)"]))
    (drgnx-search-edit-change '(:view "s" :change 3 :origin "edit-results" :written 1 :files 1))
    (should (equal (drgnx-search-edit--line-old (drgnx-search-edit-test--line "l:0")) "(defvar one 1)\n(defvar half 1.5)"))
    (should (= (drgnx-search-edit--line-line (drgnx-search-edit-test--line "l:2")) 4))
    ;; another file: unmoved
    (should (= (drgnx-search-edit--line-line (drgnx-search-edit-test--line "l:3")) 5))))

(ert-deftest drgnx-search-edit/delete-line-deletes-on-save ()
  "Pattern D: Delete Line marks a line (struck, dim) and sends it with no new text; again, it unmarks it; once saved
the line is read-only and the lines after it move up."
  (drgnx-search-edit-test--with '(("search/edits" . (:change 4 :files nil :skipped nil)) ("search/apply" . t))
    (drgnx-search-edit-test--goto "l:1")
    (drgnx-search-edit-delete-line)
    (should (eq (drgnx-search-edit--line-state (drgnx-search-edit-test--line "l:1")) 'deleted))
    (should (eq (overlay-get (drgnx-search-edit--line-ov (drgnx-search-edit-test--line "l:1")) 'face)
                'drgnx-search-edit-deleted))
    (drgnx-search-edit-test--goto "l:3")
    (drgnx-search-edit-delete-line)
    (drgnx-search-edit-test--goto "l:3")
    (drgnx-search-edit-delete-line)
    (should-not (drgnx-search-edit--line-state (drgnx-search-edit-test--line "l:3")))
    (drgnx-search-edit-save)
    (should (equal (append (plist-get (drgnx-search-edit-test--sent "search/edits") :lines) nil)
                   '((:line_id "l:1" :path "/r/a.el" :line 2 :old ";; between" :eol t))))
    (drgnx-search-edit-change '(:view "s" :change 4 :origin "edit-results" :written 1 :files 1))
    (should (eq (drgnx-search-edit--line-state (drgnx-search-edit-test--line "l:1")) 'gone))
    (should (= (drgnx-search-edit--line-line (drgnx-search-edit-test--line "l:2")) 2))
    (drgnx-search-edit-test--goto "l:1")
    (should-error (insert "x") :type 'text-read-only)))

(ert-deftest drgnx-search-edit/a-conflict-keeps-the-text-and-marks-the-row ()
  "Pattern D: a line whose file changed underneath is skipped (by the edit set or by the write): its text stays, it
stays marked, and its row says why; the other line is saved."
  (drgnx-search-edit-test--with '(("search/edits" . (:change 5 :files nil
                                                             :skipped ((:id "l:0" :path "/r/a.el" :why "its text changed"))))
                                  ("search/apply" . t))
    (drgnx-search-edit-test--edit "l:0" "(defvar uno 1)")
    (drgnx-search-edit-test--edit "l:3" "one less")
    (drgnx-search-edit-save)
    (drgnx-search-edit-change '(:view "s" :change 5 :origin "edit-results" :written 1 :files 1))
    (let ((l (drgnx-search-edit-test--line "l:0")))
      (should (equal (drgnx-search-edit--text l) "(defvar uno 1)"))
      (should (equal (drgnx-search-edit--line-conflict l) "its text changed"))
      (should (gethash l drgnx-search-edit--marked))
      (should (eq (overlay-get (drgnx-search-edit--line-ov l) 'face) 'drgnx-search-edit-conflict))
      (should (string-match-p "changed since: your text kept" (overlay-get (drgnx-search-edit--line-ov l)
                                                                           'after-string))))
    (should (equal drgnx-search-edit--status "Saved 1 line in 1 file · 1 skipped"))))

(ert-deftest drgnx-search-edit/refresh-line-takes-the-files-line ()
  "Pattern D: Take the File's Line reads the file's line as it is now: shown beside yours, and the line a save writes
over."
  (let ((f (make-temp-file "drgnx-search-edit" nil ".txt" "first\nnow different\nthird\n")))
    (unwind-protect
        (drgnx-search-edit-test--with '()
          (let ((l (drgnx-search-edit-test--line "l:1")))
            (setf (drgnx-search-edit--line-path l) f (drgnx-search-edit--line-line l) 2)
            (drgnx-search-edit-test--edit "l:1" ";; mine")
            (drgnx-search-edit-test--goto "l:1")
            (drgnx-search-edit-refresh-line)
            (should (equal (drgnx-search-edit--line-old l) "now different"))
            (should (equal (drgnx-search-edit--text l) ";; mine"))
            (should (string-match-p "file: now different" (overlay-get (drgnx-search-edit--line-ov l) 'after-string)))
            (should (gethash l drgnx-search-edit--marked))))
      (delete-file f))))

(ert-deftest drgnx-search-edit/abort-and-kill ()
  "Pattern D: Abort drops the edits and closes, asking nothing; killing with edits asks only from a command you ran
\(this-command), never from code."
  (drgnx-search-edit-test--with '()
    (drgnx-search-edit-test--edit "l:0" "x")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked"))))
      (let ((this-command nil)) (should (drgnx-search-edit--kill-query))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (let ((this-command 'kill-buffer)) (should-not (drgnx-search-edit--kill-query))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked"))))
      (let ((this-command 'drgnx-search-edit-abort)) (drgnx-search-edit-abort)))
    (should-not (buffer-live-p buf))))

(ert-deftest drgnx-search-edit/held-lines-are-read-only ()
  "Pattern D: a line the hub says an agent holds cannot be edited."
  (let ((drgnx-search-edit-test--doc
         (list :lines (list (list :line_id "l:0" :path "/r/a.el" :line 1 :text "held" :kind "match" :eol t :held t))
               :total 1)))
    (drgnx-search-edit-test--with '()
      (drgnx-search-edit-test--goto "l:0")
      (should-error (insert "x") :type 'text-read-only))))

(ert-deftest drgnx-search-edit/over-the-max-is-refused-with-the-count ()
  "Pattern D: a search with more lines than `drgnx-search-edit-max-lines' opens nothing and says how many."
  (let ((view (generate-new-buffer " search view")) (msg nil) (drgnx-search-edit--buffers nil)
        (drgnx-replace-view "s") (drgnx-replace--root "/r/"))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-replace--live-view) (lambda () view))
                  ((symbol-function 'drgnx-replace--rows-p) (lambda () t))
                  ((symbol-function 'drgnx-replace--text) (lambda (_) "one"))
                  ((symbol-function 'drgnx-hub--call-on)
                   (lambda (_conn method params cb &rest _)
                     (should (equal method "search/edit-doc"))
                     (should (equal (plist-get params :max) drgnx-search-edit-max-lines))
                     (funcall cb '(:lines nil :total 25000 :over t) nil)))
                  ((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
          (drgnx-search-edit-results)
          (should (equal msg "Edit Results: narrow the search (25000 lines; at most 20000)"))
          (should-not drgnx-search-edit--buffers))
      (kill-buffer view))))

(ert-deftest drgnx-search-edit/undo-all-saves-puts-the-lines-back ()
  "Pattern D: Undo All Saves sends each save's undo, newest first; when the hub ends one, its lines are as they were
before it, marked again (your text is still in the buffer), and the next is sent."
  (drgnx-search-edit-test--with '(("search/edits" . (:change 6 :files nil :skipped nil))
                                  ("search/apply" . t) ("search/undo" . t))
    (drgnx-search-edit-test--edit "l:2" "(defvar three 3)")
    (drgnx-search-edit-save)
    (drgnx-search-edit-change '(:view "s" :change 6 :origin "edit-results" :written 1 :files 1))
    (drgnx-search-edit-undo-saves)
    (should (equal (plist-get (drgnx-search-edit-test--sent "search/undo") :change) 6))
    (should (drgnx-search-edit-change '(:view "s" :change 7 :origin "undo" :undoes 6 :written 1 :files 1)))
    (let ((l (drgnx-search-edit-test--line "l:2")))
      (should (equal (drgnx-search-edit--line-old l) "(defvar two 2)"))
      (should (eq (drgnx-search-edit--line-state l) 'edited)))
    (should-not drgnx-search-edit--saves)))

(ert-deftest drgnx-search-edit/lines-are-fontified-by-their-files-mode ()
  "Pattern D: a line shows in its file's major mode's faces (a hidden buffer per mode, its hooks not run); a file
with no mode of its own stays plain."
  (drgnx-search-edit-test--with '()
    (drgnx-search-edit--fontify (point-min) (point-max))
    (let ((l (drgnx-search-edit-test--line "l:0")))
      (should (memq 'font-lock-keyword-face
                    (ensure-list (get-text-property (1+ (drgnx-search-edit--line-start l)) 'face)))))
    (should-not (get-text-property (drgnx-search-edit--line-start (drgnx-search-edit-test--line "l:3")) 'face))))

(ert-deftest drgnx-search-edit/saving-the-buffer-saves-the-lines ()
  "Pattern D: every save of the buffer (`save-buffer': the profiles' Save, Vim's `:w') saves the edited lines, never
asking for a file; a line marked for deletion alone is something to save; the global before-save hooks never touch
the lines."
  (drgnx-search-edit-test--with '(("search/edits" . (:change 6 :files nil :skipped nil)) ("search/apply" . t))
    (drgnx-search-edit-test--goto "l:1")
    (drgnx-search-edit-delete-line)
    (should (buffer-modified-p))
    (let ((touched nil))
      (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) (error "Asked for a file")))
                ((default-value 'before-save-hook) (list (lambda () (setq touched t)))))
        (save-buffer))
      (should-not touched))
    (should (equal (append (plist-get (drgnx-search-edit-test--sent "search/edits") :lines) nil)
                   '((:line_id "l:1" :path "/r/a.el" :line 2 :old ";; between" :eol t))))
    (should-not buffer-file-name)))

;;; search-edit-test.el ends here
