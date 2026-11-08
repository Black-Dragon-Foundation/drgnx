;;; extensions-rows-test.el --- batch tests: the Extensions list on the hub's rows, its jobs' steps from events -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the list's calls are recorded, the hub's model and patches are applied by hand (the rows
;; path needs Sjá, a Nidhogg with `nidhogg-view--call'; that test is skipped elsewhere), job steps arrive as the
;; `exec-progress' events would bring them.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(defvar drgnx-view-old-path)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-jobs" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-details" drgnx-dir) nil t)

(defconst drgnx-extensions-rows-test--model
  (json-serialize
   (list :ops
         (vector
          (list :reset
                (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["order"]
                                        :classes ["selected" "match" "dim"] :flags ["expanded"] :forms [] :start "order")
                      :nodes (vector
                              (list :id "section:updates" :kind "section" :flags 1
                                    :fields [["label" "Updates"] ["section" "updates"] ["count" 1]])
                              (list :id "pkg:a" :kind "package" :flags 0 :parent "section:updates"
                                    :fields [["label" "a"] ["name" "a"] ["state" "update"] ["signed" "unsigned-archive"]
                                             ["source" "melpa"] ["section" "updates"] ["version" "1.0"] ["latest" "1.1"]]))
                      :edges []
                      :lists (vector (list :name "order" :ids ["section:updates" "pkg:a"])))))))
  "The hub's model of a list with one section holding one row.")

(defun drgnx-extensions-rows-test--row (key text &optional id)
  (list :key key :text text
        :props (append (list (list 0 (length text) "drgnx-work-id" (or id key)))
                       (and id (list (list 0 (length text) "drgnx-extensions-id" id))))))

(ert-deftest drgnx-extensions-list/rows-applied-without-keys-rebuild ()
  "On the rows path the list asks `extensions/list' once (every section, each with its page), never a search per
section; the hub's rows are inserted as they come, with no key list built and no `drgnx-view-sync-rows'; a row's data
and point's row come from the model; the answer's totals give the Updates count."
  (skip-unless (fboundp 'nidhogg-view--call))
  (let ((drgnx-view-old-path nil) (drgnx-view-patch--buffers (make-hash-table :test #'equal))
        (drgnx-view-model--views (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
        (calls nil) (keys 0) (syncs 0))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (m p cb) (push (list m p cb) calls) 1))
                  ((symbol-function 'drgnx-view-env-register) #'ignore)
                  ((symbol-function 'drgnx-extensions-list--keys) (lambda () (cl-incf keys) nil))
                  ((symbol-function 'drgnx-view-sync-rows) (lambda (&rest _) (cl-incf syncs))))
          (drgnx-extensions-list--reset)
          (with-current-buffer (drgnx-extensions-list--buffer)
            (drgnx-extensions-list-refresh)
            (should (equal (mapcar #'car calls) '("extensions/list")))
            (let ((p (nth 1 (car calls))))
              (should (equal (mapcar (lambda (s) (plist-get s :name)) (append (plist-get p :sections) nil))
                             '("installed" "updates" "recommended" "plugins" "builtin")))
              (should (eql 200 (plist-get (plist-get (aref (plist-get p :sections) 0) :search) :limit))))
            (drgnx-view-model-event (list :view "extensions" :hub 7 :base 0 :version 1 :reset t
                                          :model drgnx-extensions-rows-test--model))
            (drgnx-view-apply-patch
             (list :view "extensions" :class "unshown" :hub 7 :base 0 :version 1 :env_epoch 0 :model 1
                   :ops (list (list :reset (list (drgnx-extensions-rows-test--row "section:updates" "Updates (1)")
                                                 (drgnx-extensions-rows-test--row "pkg:a" "a 1.0  update to 1.1" "pkg:a"))))))
            (drgnx-view-draw-now drgnx-view)
            (should (string-match-p "update to 1\\.1" (buffer-string)))
            (should (eq 'update (plist-get (drgnx-extensions-list-row "pkg:a") :state)))
            (should (equal "1.1" (plist-get (drgnx-extensions-list-row "pkg:a") :latest)))
            (should-not (drgnx-extensions-list-row "section:updates"))
            (goto-char (point-min))
            (search-forward "a 1.0")
            (should (equal "pkg:a" (drgnx-extensions-list--id-at-point)))
            (should (equal "pkg:a" (drgnx-view-nav-selection)))
            (funcall (nth 2 (car calls)) (list :sections (list (list :name "updates" :total 1 :loaded 1))) nil)
            (should (= 1 drgnx-extensions-list--updates))
            (should (equal '("pkg:a") (drgnx-extensions-list--update-ids)))
            (should (= 0 keys))
            (should (= 0 syncs))))
      (when (get-buffer drgnx-extensions-list-buffer-name) (kill-buffer drgnx-extensions-list-buffer-name))
      (drgnx-extensions-list--reset))))

(ert-deftest drgnx-extensions-jobs/progress-from-events-reads-no-file ()
  "Off the old path a job's steps and plans come as `exec-progress' events: the job takes the step, the plan hook
runs once per plan with the plan file's name, another session's plan goes with its job's `exec-done', and no
progress or plan file is read (none exists)."
  (let ((drgnx-view-old-path nil) (drgnx-extensions-jobs--on t) (reads 0) (plans nil) (gone nil)
        (drgnx-extensions-jobs-plan-functions nil) (drgnx-extensions-jobs-plan-gone-functions nil)
        (drgnx-extensions-jobs-changed-functions nil)
        (file (expand-file-name "t1.json" (drgnx-extensions-jobs-dir))))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-extensions-jobs--json) (lambda (_f) (cl-incf reads) nil)))
          (add-hook 'drgnx-extensions-jobs-plan-functions (lambda (p) (push p plans)))
          (add-hook 'drgnx-extensions-jobs-plan-gone-functions (lambda (f) (push f gone)))
          (puthash "t1" (list :token "t1" :id "j1" :kind 'upgrade :status 'running :ids '(a)) drgnx-extensions-jobs--jobs)
          (puthash "j1" "t1" drgnx-extensions-jobs--ids)
          (should-not (drgnx-extensions-jobs--files-p))
          (drgnx-extensions-jobs--event "exec-progress" (list :id "j1" :file file :step (list :step "download" :pkg "a" :i 1 :n 3)))
          (let ((job (gethash "t1" drgnx-extensions-jobs--jobs)))
            (should (eq 'download (plist-get job :step)))
            (should (eql 1 (plist-get job :i))))
          (drgnx-extensions-jobs--event "exec-progress" (list :id "j1" :file file :plan (list :seq 1 :adds ["a-1.1"])))
          (drgnx-extensions-jobs--event "exec-progress" (list :id "j1" :file file :plan (list :seq 1 :adds ["a-1.1"])))
          (should (= 1 (length plans)))
          (should (equal (concat file ".plan.json") (plist-get (car plans) :file)))
          ;; another session's job: its plan is told, and its end says the plan went
          (let ((other (expand-file-name "t9.json" (drgnx-extensions-jobs-dir))))
            (drgnx-extensions-jobs--event "exec-progress" (list :id "j9" :file other :plan (list :seq 1)))
            (should (= 2 (length plans)))
            (drgnx-extensions-jobs--event "exec-done" (list :id "j9" :status "done" :exit 0))
            (should (equal (list (concat other ".plan.json")) gone)))
          (should (= 0 reads)))
      (dolist (table (list drgnx-extensions-jobs--jobs drgnx-extensions-jobs--ids drgnx-extensions-jobs--plans
                           drgnx-extensions-jobs--others))
        (clrhash table)))))

(ert-deftest drgnx-extensions-jobs/details-and-trust-still-normalise ()
  "A page whose row the list does not hold takes the hub's answer through `drgnx-extensions-list--normalize' (kept as
the one row normaliser): its kind, state and signed become symbols."
  (let ((drgnx-view-old-path t) (n 0))
    (drgnx-extensions-list--reset)
    (advice-add 'drgnx-extensions-list--normalize :before (lambda (&rest _) (cl-incf n)) '((name . rows-test)))
    (unwind-protect
        (with-temp-buffer
          (setq-local drgnx-extensions-details--id "pkg:x"
                      drgnx-extensions-details--info
                      (list :row (list :id "pkg:x" :kind "package" :name "x" :state "update" :signed "signed")))
          (let ((row (drgnx-extensions-details--row)))
            (should (eq 'update (plist-get row :state)))
            (should (eq 'package (plist-get row :kind)))
            (should (eq 'signed (plist-get row :signed))))
          (should (= 1 n)))
      (advice-remove 'drgnx-extensions-list--normalize 'rows-test))))

;;; extensions-rows-test.el ends here
