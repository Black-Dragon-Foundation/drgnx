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
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-jobs" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-details" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-recommend" drgnx-dir) nil t)
(require 'drgnx-hub-client)

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
                                    :fields [["label" "a"] ["state" "update"] ["signed" "unsigned-archive"]
                                             ["source" "melpa"] ["section" "updates"] ["version" "1.0"] ["latest" "1.1"]]))
                      :edges []
                      :lists (vector (list :name "order" :ids ["section:updates" "pkg:a"])))))))
  "The hub's model of a list with one section holding one row.")

(defun drgnx-extensions-rows-test--row (key text &optional id)
  (list :key key :text text
        :props (append (list (list 0 (length text) "drgnx-work-id" (or id key)))
                       (and id (list (list 0 (length text) "drgnx-extensions-id" id))))))

(ert-deftest drgnx-extensions-list/rows-applied-from-the-model ()
  "The list asks `extensions/list' once (every section, each with its page), never a search per section; the hub's
rows are inserted as they come; a row's data and point's row come from the model; the answer's totals give the
Updates count."
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
        (drgnx-view-model--views (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
        (calls nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-extensions-list-call) (lambda (m p cb &rest _) (push (list m p cb) calls) 1))
                  ((symbol-function 'drgnx-view-env-register) #'ignore))
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
            (should (equal "a" (plist-get (drgnx-extensions-list-row "pkg:a") :name)))   ; the model's label
            (should-not (drgnx-extensions-list-row "section:updates"))
            (goto-char (point-min))
            (search-forward "a 1.0")
            (should (equal "pkg:a" (drgnx-extensions-list--id-at-point)))
            (should (equal "pkg:a" (drgnx-view-nav-selection)))
            (funcall (nth 2 (car calls)) (list :sections (list (list :name "updates" :total 1 :loaded 1))) nil)
            (should (= 1 drgnx-extensions-list--updates))
            (should (equal '("pkg:a") (drgnx-extensions-list--update-ids)))))
      (when (get-buffer drgnx-extensions-list-buffer-name) (kill-buffer drgnx-extensions-list-buffer-name))
      (drgnx-extensions-list--reset))))

(defmacro drgnx-extensions-rows-test--with-list (calls &rest body)
  "BODY in the list's buffer with row pkg:a drawn from the hub's model; CALLS holds the hub calls (newest first)."
  (declare (indent 1) (debug t))
  `(let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
         (drgnx-view-model--views (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
         (drgnx-extensions-jobs--state (make-hash-table))
         (,calls nil))
     (ignore ,calls)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-extensions-list-call) (lambda (m p cb &rest _) (push (list m p cb) ,calls) 1))
                   ((symbol-function 'drgnx-view-env-register) #'ignore))
           (drgnx-extensions-list--reset)
           (with-current-buffer (drgnx-extensions-list--buffer)
             (drgnx-extensions-list-refresh)
             (drgnx-view-model-event (list :view "extensions" :hub 7 :base 0 :version 1 :reset t
                                           :model drgnx-extensions-rows-test--model))
             (drgnx-view-apply-patch
              (list :view "extensions" :class "unshown" :hub 7 :base 0 :version 1 :env_epoch 0 :model 1
                    :ops (list (list :reset (list (drgnx-extensions-rows-test--row "section:updates" "Updates (1)")
                                                  (drgnx-extensions-rows-test--row "pkg:a" "a 1.0  update to 1.1" "pkg:a"))))))
             (drgnx-view-draw-now drgnx-view)
             ,@body))
       (drgnx-extensions-list--teardown))))

(defun drgnx-extensions-rows-test--chips ()
  "The text of every job chip the list's buffer shows now."
  (mapconcat (lambda (ov) (substring-no-properties (or (overlay-get ov 'after-string) "")))
             (overlays-in (point-min) (point-max)) ""))

(ert-deftest drgnx-extensions-list/a-busy-row-shows-step-and-elapsed ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-extensions-rows-test--with-list calls
    (drgnx-extensions-jobs--put '(a) (list :status 'busy :step 'native :i 14 :n 37 :since (- (float-time) 12)))
    (drgnx-extensions-list--jobs-changed '(a))
    (let ((text (drgnx-extensions-rows-test--chips)))
      (should (string-match-p "native 14/37" text))
      (should (string-match-p "12s" text)))))

(ert-deftest drgnx-extensions-list/a-job-step-reads-no-row-and-keeps-the-header ()
  ;; a step only moves the chip: no row is read out of the model, the header is set again only when the restart note moves
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-extensions-rows-test--with-list calls
    (drgnx-test-with-clock (:allow-pending t)
      (let ((headers 0))
        (cl-letf (((symbol-function 'drgnx-extensions-list-row) (lambda (&rest _) (error "A row was read")))
                  ((symbol-function 'drgnx-extensions-list--header) (lambda () (cl-incf headers))))
          (dotimes (i 3)
            (drgnx-extensions-jobs--put '(a) (list :status 'busy :step 'native :i i :n 3 :since (float-time)))
            (drgnx-extensions-list--jobs-changed '(a)))
          (should (string-match-p "native 2/3" (drgnx-extensions-rows-test--chips)))
          (should (= headers 0)))))))

(ert-deftest drgnx-extensions-list/the-second-tick-moves-busy-chips-only ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-extensions-rows-test--with-list calls
    (drgnx-test-with-clock (:allow-pending t)
      (let (drawn)
        (drgnx-extensions-jobs--put '(a) (list :status 'busy :step 'download :since (float-time)))
        (cl-letf (((symbol-function 'drgnx-extensions-list--rows-chips) (lambda (ids) (push ids drawn))))
          (drgnx-extensions-list--jobs-changed '(a))
          (setq drawn nil)
          (drgnx-test-advance 1.0)
          (should (equal (car drawn) '("pkg:a")))
          (should (drgnx-timer-active-p 'extensions-list-tick))
          (remhash 'a drgnx-extensions-jobs--state)
          (drgnx-extensions-list--jobs-changed '(a))
          (should-not (drgnx-timer-active-p 'extensions-list-tick)))))))

(ert-deftest drgnx-extensions-list/no-timer-without-a-busy-row ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-extensions-rows-test--with-list calls
    (drgnx-test-with-clock (:allow-pending t)
      (should-not (drgnx-timer-active-p 'extensions-list-tick))
      (drgnx-extensions-jobs--put '(a) (list :status 'queued))
      (drgnx-extensions-list--jobs-changed '(a))
      (should-not (drgnx-timer-active-p 'extensions-list-tick))
      (drgnx-extensions-jobs--put '(a) (list :status 'busy :since (float-time)))
      (drgnx-extensions-list--jobs-changed '(a))
      (should (drgnx-timer-active-p 'extensions-list-tick))
      (drgnx-extensions-jobs--put '(a) (list :status 'done))
      (drgnx-extensions-list--jobs-changed '(a))
      (should-not (drgnx-timer-active-p 'extensions-list-tick)))))

(ert-deftest drgnx-extensions-list/a-refused-click-says-try-again-and-is-not-busy ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-extensions-rows-test--with-list calls
    (drgnx-test-with-clock (:allow-pending t)
      ;; what the job layer says when another drgnx held the queue file
      (drgnx-extensions-jobs--put '(a) (list :status 'refused :error "busy, try again" :since (float-time)))
      (drgnx-extensions-list--jobs-changed '(a))
      (let ((text (drgnx-extensions-rows-test--chips)))
        (should (string-search "busy, try again" text))
        (should-not (string-search "working" text)))
      (should-not (drgnx-extensions-list--busy-ids))
      (should-not (drgnx-timer-active-p 'extensions-list-tick)))))

(ert-deftest drgnx-extensions-list/the-next-page-is-asked-near-the-end ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-extensions-rows-test--with-list calls
    (drgnx-extensions-list--listed (list (list :name "installed" :total 450 :loaded 200)))
    (setq calls nil)
    (let ((inhibit-read-only t)) (erase-buffer) (insert (make-string 6000 ?x)))
    (goto-char (point-max))
    (drgnx-extensions-list--post-command)
    (drgnx-extensions-list--post-command)
    (should (= (length calls) 1))
    (should (equal (caar calls) "extensions/list"))
    (let ((section (aref (plist-get (nth 1 (car calls)) :sections) 0)))
      (should (equal (plist-get section :name) "installed"))
      (should (= (plist-get (plist-get section :search) :limit) 400)))))

(defconst drgnx-extensions-rows-test--gens
  (list (list :n 4 :time "2026-11-12 10:00" :note "update magit" :differs '("magit 4.1 → 4.2") :current t :size 2048)
        (list :n 3 :time "2026-11-11 09:00"))
  "Two generations, newest first, as `drgnx-extensions-details-generations' gives them.")

(ert-deftest drgnx-extensions-list/rollback-reads-the-selected-generation ()
  "The Generations section is the hub's: `extensions/list' sends the generations (at the end of the list, or alone
under `@generations'), and Roll Back Packages on a generation's row reads its `gen' from the model, the row made the
selection.  Off a generation's row it asks."
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (let ((jobs nil))
    (cl-letf (((symbol-function 'drgnx-extensions-details-generations) (lambda () drgnx-extensions-rows-test--gens))
              ((symbol-function 'drgnx-extensions-details-copies-note) #'ignore)
              ((symbol-function 'drgnx-extensions-jobs-run) (lambda (&rest a) (push a jobs)))
              ((symbol-function 'completing-read) (lambda (&rest _) "3")))
      (drgnx-extensions-rows-test--with-list calls
        (let ((gens (append (plist-get (nth 1 (car calls)) :generations) nil)))
          (should (equal (mapcar (lambda (g) (plist-get g :n)) gens) '(4 3)))
          (should (equal (plist-get (car gens) :differs) ["magit 4.1 → 4.2"]))
          (should (eq (plist-get (car gens) :current) t)))
        (drgnx-view-model-event
         (list :view "extensions" :hub 7 :base 0 :version 2 :reset t
               :model (json-serialize
                       (list :ops
                             (vector
                              (list :reset
                                    (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"]
                                                            :lists ["order"] :classes ["selected" "match" "dim"]
                                                            :flags ["expanded"] :forms [] :start "order")
                                          :nodes (vector
                                                  (list :id "section:updates" :kind "section" :flags 1
                                                        :fields [["label" "Updates"] ["section" "updates"]])
                                                  (list :id "pkg:a" :kind "package" :flags 0 :parent "section:updates"
                                                        :fields [["label" "a"] ["state" "update"]])
                                                  (list :id "section:generations" :kind "section" :flags 1
                                                        :fields [["label" "Generations"] ["section" "generations"]])
                                                  (list :id "gen:4" :kind "generation" :flags 0
                                                        :parent "section:generations" :fields [["label" "#4"] ["gen" 4]]))
                                          :edges []
                                          :lists (vector (list :name "order" :ids ["section:updates" "pkg:a"
                                                                                   "section:generations" "gen:4"])))))))))
        (drgnx-view-apply-patch
         (list :view "extensions" :class "unshown" :hub 7 :base 1 :version 2 :env_epoch 0 :model 2
               :ops (list (list :reset (list (drgnx-extensions-rows-test--row "section:updates" "Updates (1)")
                                             (drgnx-extensions-rows-test--row "pkg:a" "a 1.0  update to 1.1" "pkg:a")
                                             (drgnx-extensions-rows-test--row "section:generations" "Generations (1)")
                                             (drgnx-extensions-rows-test--row "gen:4" "#4  2026-11-12 10:00"))))))
        (drgnx-view-draw-now drgnx-view)
        (goto-char (point-min))
        (search-forward "#4")
        (drgnx-extensions-rollback)
        (should (equal jobs '((rollback 4))))
        (should (equal "gen:4" (drgnx-view-nav-selection)))
        (goto-char (point-min))
        (drgnx-extensions-rollback)
        (should (equal (car jobs) '(rollback 3)))))))

(ert-deftest drgnx-extensions-list/without-sja-the-list-shows-the-notice ()
  "An Emacs without Sjá: the list's buffer says so, asks the hub nothing and has no model."
  (let ((calls nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-extensions-list-rows-p) (lambda () nil))
                  ((symbol-function 'drgnx-extensions-list-call) (lambda (m &rest _) (push m calls) 1)))
          (drgnx-extensions-list--reset)
          (with-current-buffer (drgnx-extensions-list--buffer)
            (should (string-match-p "needs Sjá" (buffer-string)))
            (should-not (drgnx-extensions-list--hub-fed-p))
            (drgnx-extensions-list-refresh)
            (drgnx-extensions-list--fetch 'installed 200)
            (should-not (drgnx-extensions-list-row "pkg:a"))
            (should-not calls)))
      (drgnx-extensions-list--teardown))))

(ert-deftest drgnx-extensions-list/the-list-asks-on-the-subscribed-connection ()
  "The hub sends a view's model and rows to the connection that asked, and holds the Recommended set per connection:
`extensions/list' and `extensions/recommended' go on the subscribed connection, the one the env and the patches use,
never on the call connection (there the rows went nowhere and the list stayed empty)."
  (let* ((events (make-pipe-process :name "drgnx-test-events" :noquery t))
         (client (make-pipe-process :name "drgnx-test-client" :noquery t))
         (drgnx-hub--events events) (drgnx-hub--client client) (sent nil)
         (drgnx-extensions-recommend--held (vector nil 0 0 nil 4 '("pkg:a"))))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub--call-on)
                   (lambda (conn method &rest _) (push (cons method conn) sent) 1)))
          (drgnx-extensions-list--ask)
          (drgnx-extensions-recommend-send)
          (should (equal (reverse sent) `(("extensions/list" . ,events) ("extensions/recommended" . ,events)))))
      (delete-process events)
      (delete-process client))))

(ert-deftest drgnx-extensions-list/with-the-hub-down-the-header-says-so ()
  "Sjá but no hub: asking fails at once, the list says why in its header, and nothing waits."
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
        (drgnx-view-model--views (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-extensions-list-call) (lambda (&rest _) (error "the hub is down")))
                  ((symbol-function 'drgnx-view-env-register) #'ignore))
          (drgnx-extensions-list--reset)
          (with-current-buffer (drgnx-extensions-list--buffer)
            (drgnx-extensions-list-refresh)
            (should (equal drgnx-extensions-list--error "the hub is down"))
            (should (string-search "the hub is down" (format "%s" (car header-line-format))))))
      (drgnx-extensions-list--teardown))))

(ert-deftest drgnx-extensions-jobs/progress-from-events ()
  "A job's steps and plans come as `exec-progress' events: the job takes the step, the plan hook runs once per plan
with the plan file's name, and another session's plan goes with its job's `exec-done'."
  (let ((drgnx-extensions-jobs--on t) (plans nil) (gone nil)
        (drgnx-extensions-jobs-plan-functions nil) (drgnx-extensions-jobs-plan-gone-functions nil)
        (drgnx-extensions-jobs-changed-functions nil)
        (file (expand-file-name "t1.json" (drgnx-extensions-jobs-dir))))
    (unwind-protect
        (progn
          (add-hook 'drgnx-extensions-jobs-plan-functions (lambda (p) (push p plans)))
          (add-hook 'drgnx-extensions-jobs-plan-gone-functions (lambda (f) (push f gone)))
          (puthash "t1" (list :token "t1" :id "j1" :kind 'upgrade :status 'running :ids '(a)) drgnx-extensions-jobs--jobs)
          (puthash "j1" "t1" drgnx-extensions-jobs--ids)
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
            (should (equal (list (concat other ".plan.json")) gone))))
      (dolist (table (list drgnx-extensions-jobs--jobs drgnx-extensions-jobs--ids drgnx-extensions-jobs--plans
                           drgnx-extensions-jobs--others))
        (clrhash table)))))

(ert-deftest drgnx-extensions-jobs/details-and-trust-still-normalise ()
  "A page whose row the list does not hold takes the hub's answer through `drgnx-extensions-list--normalize' (kept as
the one row normaliser): its kind, state and signed become symbols."
  (let ((n 0))
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
