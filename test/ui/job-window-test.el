;;; job-window-test.el --- GUI tests: a job in the Work cockpit (it was the job window) — what needs you, a card's button, hiding it (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)
(defconst drgnx-job-window-test--repo                       ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-job-window-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-job-window-test--repo))
(require 'drgnx-persist)
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-job-window-test--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-job-window-test--repo) nil t)

(defconst drgnx-job-window-test--summary
  '(:id "jw" :title "A feature" :status "running" :repo "/r/" :budget 5.0 :spent 0.4
        :tasks ((:n 1 :title "parser" :role "implement" :profile "mock" :status "running" :agent "s-a" :deps :null)
                (:n 2 :title "docs" :role "docs" :profile "mock" :status "needs-input" :agent :null :deps (1)))
        :agents ((:id "s-a" :profile "mock" :task "jw#1" :status "busy" :review :false))
        :cards ((:id 7 :kind "agent" :task "jw#2" :title "its agent ended 3 times" :actions (("retry" "Retry") ("drop" "Drop the task")) :data :null))
        :messages :null
        :decisions ((:n 2 :kind "wont-build" :subject "csv" :author "user" :status "current")
                    (:n 1 :kind "build" :subject "csv" :author "s-a" :status "replaced"))))

(defmacro drgnx-job-window-test--with (&rest body)
  "BODY in the root frame with the cockpit's pane kinds (and nothing else of it), the hub stubbed — CALLS gets each
call, a `job/status' is answered with the summary — and the workbench as it was after."
  (declare (indent 0))
  `(let* ((root (drgnx-uitest-root-frame)) (calls nil)
          (config (with-selected-frame root (current-window-configuration)))
          (drgnx-pane--kinds nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas)) (drgnx-wb--sections nil)
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-cockpit-filter-functions nil) (drgnx-persist-state-functions nil) (drgnx-persist-after-restore-functions nil)
          (drgnx-cockpit-graph-current-filter nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call)
                    (lambda (method params &optional cb)
                      (push (cons method params) calls)
                      (when (and cb (equal method "job/status")) (funcall cb drgnx-job-window-test--summary nil))))
                   ((symbol-function 'drgnx-hub-connect) #'ignore))
           (with-selected-frame root
             (delete-other-windows)
             (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-right-px drgnx-wb-dock-px)) (set-frame-parameter nil p nil))
             (drgnx-cockpit--setup)
             ,@body))
       (with-selected-frame root
         (ignore-errors (drgnx-wb-area-hide 'right))
         (ignore-errors (drgnx-wb-hide-sidebar))
         ;; their kill-buffer-hooks take the hooks and timers they own
         (dolist (n (list drgnx-cockpit-cards-buffer-name drgnx-cockpit-decisions-buffer-name drgnx-cockpit-graph-buffer-name))
           (when (get-buffer n) (kill-buffer n)))
         (dolist (w (window-list root 'never)) (set-window-dedicated-p w nil))
         (set-window-configuration config)))))

(defun drgnx-job-window-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 5)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(ert-deftest drgnx-ui-job-window/the-cockpit-shows-the-job-and-a-button-acts ()
  ;; Show Job in Work: no frame; the right dock shows what needs you, filtered to the job; a click on a card's button
  ;; acts through the hub
  (drgnx-job-window-test--with
    (let ((frames (frame-list)) (dir (make-temp-file "drgnx-job-shot" t)))
      (unwind-protect
          (progn
            (should-not (drgnx-job-ui-show "jw"))
            (should (equal (frame-list) frames))
            (should (equal drgnx-cockpit-graph-current-filter '(:job "jw")))
            (let ((w (drgnx-pane-window 'needs-you)))
              (should (window-live-p w))
              (should (eq (window-buffer w) (get-buffer drgnx-cockpit-cards-buffer-name)))
              (should (eq (selected-window) w)))
            (should (drgnx-job-window-test--wait
                     (lambda () (string-search "its agent ended 3 times" (with-current-buffer drgnx-cockpit-cards-buffer-name (buffer-string))))))
            (should (equal (assoc "job/status" calls) '("job/status" :id "jw" :decisions t)))
            (redisplay t) (sit-for 0.3)
            (let ((shot (plist-get (drgnx-uitest-capture dir) :root)) (out (expand-file-name "job-in-the-cockpit.png" temporary-file-directory)))
              (should (file-exists-p shot))
              (copy-file shot out t)
              (message "job in the cockpit screenshot: %s" out))
            (let ((xy (drgnx-uitest-target-xy drgnx-cockpit-cards-buffer-name "[Retry]")))
              (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)))))
            (should (equal (assoc "job/card" calls) '("job/card" :card 7 :action "retry" :arg nil))))
        (delete-directory dir t)))))

(ert-deftest drgnx-ui-job-window/hiding-it-stops-nothing-and-it-catches-up ()
  ;; closing the job's pane forgets nothing and asks the hub nothing; shown again, it asks once
  (drgnx-job-window-test--with
    (drgnx-job-ui-show "jw")
    (should (drgnx-job-window-test--wait (lambda () (assoc "job/status" calls))))
    (drgnx-pane-hide 'needs-you)
    (should-not (drgnx-pane-window 'needs-you))
    (should (get-buffer drgnx-cockpit-cards-buffer-name))
    (setq calls nil)
    (dotimes (_ 20) (drgnx-cockpit-cards--hub-event "card" '(:job "jw")))
    (sit-for 0.8)
    (should-not (assoc "job/status" calls))
    (drgnx-pane-show 'needs-you)
    (should (drgnx-job-window-test--wait (lambda () (assoc "job/status" calls))))
    (should (= 1 (seq-count (lambda (c) (equal (car c) "job/status")) calls)))))

;;; job-window-test.el ends here
