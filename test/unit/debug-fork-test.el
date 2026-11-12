;;; debug-fork-test.el --- batch tests: what-if forks in the editor -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call-sync' replaced) and its `debug-fork' events fed by hand: what is
;; tested is what the editor sends, draws and takes back.  The hub side has its Rust tests (debug::tests_fork*).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-fork" drgnx-dir) nil t)

(defmacro debug-fork-test--with-hub (answers &rest body)
  "BODY with the hub answering each call from ANSWERS (METHOD → results in turn); `calls' holds (METHOD . PARAMS)."
  (declare (indent 1))
  `(let ((calls nil) (answers (copy-tree ,answers)) (drgnx-debug-fork--views (make-hash-table :test #'equal))
         (drgnx-debug-fork-last nil))
     (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &optional _timeout)
                  (setq calls (append calls (list (cons method params))))
                  (let ((queue (assoc method answers)))
                    (if (cdr queue) (pop (cdr queue)) t)))))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (string-prefix-p "*What if: " (buffer-name b)) (kill-buffer b)))))))

(defconst debug-fork-test--done
  '(:fork "f1" :run "r1" :root "/p" :state "done"
          :at (:path "/p/stock.py" :line 20 :hit 2 :steps [])
          :matched (:matched 1 :of 1 :first nil)
          :applied "0"
          :lanes [(:probe "shortfall" :then ["12" "9"] :now ["12" "11"])]
          :then (:kind "stop" :path "/p/stock.py" :line 30 :reason "breakpoint")
          :now (:kind "exit" :code 0)))

(ert-deftest drgnx-debug-fork/asks-then-forks ()
  "A slow point asks first; yes sends the same fork again with confirm; an input the run's start needs is asked."
  (debug-fork-test--with-hub
      '(("debug/fork" (:ask "the run took 90 s to reach this point")
         (:needs [(:input (:id "who" :kind "promptString" :description "Who" :password :false))])
         (:fork "f1")))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'read-string) (lambda (&rest _) "me")))
      (should (equal (drgnx-debug-fork "r1" '(:stop 5) '(:value (:path ["item" "reserve"] :text "0")) "exit") "f1")))
    (should (equal (mapcar #'car calls) '("debug/fork" "debug/fork" "debug/fork")))
    (let ((first (cdr (nth 0 calls))) (last (cdr (nth 2 calls))))
      (should (equal (plist-get first :confirm) :false))
      (should (equal (plist-get first :at) '(:stop 5)))
      (should (equal (plist-get first :until) "exit"))
      (should (equal (plist-get first :change) '(:value (:path ["item" "reserve"] :text "0"))))
      (should (eq (plist-get last :confirm) t))
      (should (equal (plist-get last :inputs) [(:id "who" :value "me")])))
    (should (equal drgnx-debug-fork-last "f1"))))

(ert-deftest drgnx-debug-fork/no-means-no-fork ()
  (debug-fork-test--with-hub '(("debug/fork" (:ask "slow")))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (should-error (drgnx-debug-fork "r1" '(:stop 5)) :type 'user-error))
    (should (= (length calls) 1))))

(ert-deftest drgnx-debug-fork/the-what-if-tab ()
  "A done fork's event draws the tab: matched, the lanes with the changed values marked, how each went on."
  (debug-fork-test--with-hub nil
    (drgnx-debug-fork--event "debug-fork" '(:fork "f1" :run "r1" :root "/p" :state "running"))
    (should-not (get-buffer "*What if: f1*"))
    (drgnx-debug-fork--event "debug-fork" debug-fork-test--done)
    (with-current-buffer "*What if: f1*"
      (let ((text (buffer-string)))
        (should (string-match-p "Matched on 1 of 1 hits" text))
        (should (string-match-p "From stock.py:20, hit 2" text))
        (should (string-match-p "then  12 9" text))
        (should (string-match-p "The run: stopped at stock.py:30 (breakpoint)" text))
        (should (string-match-p "The fork: exited with code 0" text)))
      (goto-char (point-min))
      (search-forward "now   ")
      (should (eq (get-text-property (point) 'face) 'drgnx-debug-fork-same))
      (search-forward "11")
      (should (eq (get-text-property (match-beginning 0) 'face) 'drgnx-debug-fork-differs)))
    (drgnx-debug-fork--event "debug-fork" '(:fork "f1" :run "r1" :state "dropped"))
    (should-not (gethash "f1" drgnx-debug-fork--views))))

(ert-deftest drgnx-debug-fork/a-first-difference-and-a-failure ()
  (debug-fork-test--with-hub nil
    (drgnx-debug-fork--event
     "debug-fork" (plist-put (copy-tree debug-fork-test--done) :matched
                             '(:matched 1 :of 3 :first (:probe "shortfall" :hit 2 :then "12" :now "11"))))
    (with-current-buffer "*What if: f1*"
      (should (string-match-p "Matched on 1 of 3 hits" (buffer-string)))
      (should (string-match-p "First difference: probe shortfall, hit 2: 12 then, 11 now" (buffer-string))))
    (drgnx-debug-fork--event "debug-fork" '(:fork "f2" :run "r1" :state "failed" :error "no value item"))
    (with-current-buffer "*What if: f2*"
      (should (string-match-p "The fork failed: no value item" (buffer-string))))))

(ert-deftest drgnx-debug-fork/code-what-if-open-run-take ()
  "A code what-if: Open Fork finds this file in the tree, Run Fork runs it, Take puts the fork's text in the buffer
(undoable, unsaved)."
  (let* ((dir (make-temp-file "dfk" t)) (root (expand-file-name "p" dir)) (tree (expand-file-name "f1/w" dir)))
    (make-directory root t) (make-directory tree t)
    (with-temp-file (expand-file-name "stock.py" root) (insert "a = 1\nb = 2\n"))
    (with-temp-file (expand-file-name "stock.py" tree) (insert "a = 1\nb = 3\n"))
    (unwind-protect
        (debug-fork-test--with-hub '(("debug/fork/run" t))
          (drgnx-debug-fork--event "debug-fork" (list :fork "f1" :run "r1" :root root :state "editing" :tree tree))
          (setq drgnx-debug-fork-last "f1")
          (should (equal (drgnx-debug-fork--in-tree (expand-file-name "stock.py" root) "f1")
                         (expand-file-name "stock.py" tree)))
          (drgnx-debug-fork-run "f1")
          (should (equal (car calls) '("debug/fork/run" :fork "f1")))
          (drgnx-debug-fork--event "debug-fork" (list :fork "f1" :run "r1" :root root :state "done" :tree tree
                                                      :changed ["stock.py"]))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
            (drgnx-debug-fork-take "f1"))
          (let ((b (get-file-buffer (expand-file-name "stock.py" root))))
            (unwind-protect
                (with-current-buffer b
                  (should (equal (buffer-string) "a = 1\nb = 3\n"))
                  (should (buffer-modified-p))
                  (should (consp buffer-undo-list)))
              (with-current-buffer b (set-buffer-modified-p nil))
              (kill-buffer b))))
      (delete-directory dir t))))

;;; debug-fork-test.el ends here
