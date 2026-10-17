;;; job-window-test.el --- GUI tests: the job window — three areas, a card's button, closing it (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)
(defconst drgnx-job-window-test--repo                       ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-job-window-test--repo))
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-job-window-test--repo) nil t)

(defconst drgnx-job-window-test--summary
  '(:id "jw" :title "A feature" :status "running" :repo "/r/" :budget 5.0 :spent 0.4
        :tasks ((:n 1 :title "parser" :role "implement" :profile "mock" :status "running" :agent "s-a" :deps :null)
                (:n 2 :title "docs" :role "docs" :profile "mock" :status "needs-input" :agent :null :deps (1)))
        :agents ((:id "s-a" :profile "mock" :task "jw#1" :status "busy" :review :false))
        :cards ((:id 7 :kind "agent" :task "jw#2" :title "its agent ended 3 times" :actions (("retry" "Retry") ("drop" "Drop the task")) :data :null))
        :messages :null
        :decisions ((:n 2 :kind "wont-build" :subject "csv" :author "user" :status "current")
                    (:n 1 :kind "build" :subject "csv" :author "s-a" :status "replaced"))))

(ert-deftest drgnx-ui-job-window/three-areas-and-a-button ()
  ;; the window's layout in the root frame (a job's own frame is laid out the same): screenshot, then a click
  (let* ((calls nil) (root (drgnx-uitest-root-frame)) (dir (make-temp-file "drgnx-job-shot" t))
         (config (with-selected-frame root (current-window-configuration))))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &optional _cb) (push (cons method params) calls))))
          (with-selected-frame root (drgnx-job-ui--layout "jw"))
          (drgnx-job-ui--draw "jw" drgnx-job-window-test--summary)
          (redisplay t) (sit-for 0.3)
          (let ((ws (sort (window-list root 'never) (lambda (a b) (< (car (window-edges a)) (car (window-edges b)))))))
            (should (= (length ws) 3))
            (should (equal (mapcar (lambda (w) (buffer-name (window-buffer w))) ws)
                           '("*job jw: tasks*" "*job jw: needs you*" "*job jw: decisions*")))
            (should (> (window-total-width (nth 1 ws)) (window-total-width (nth 0 ws)))))
          (let ((shot (plist-get (drgnx-uitest-capture dir) :root)))
            (should (file-exists-p shot))
            (message "job window screenshot: %s" shot))
          (let ((xy (drgnx-uitest-target-xy "*job jw: needs you*" "[Retry]")))
            (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)))))
          (should (equal (assoc "job/card" calls) '("job/card" :card 7 :action "retry" :arg nil))))
      (with-selected-frame root
        (dolist (w (window-list root 'never)) (set-window-dedicated-p w nil))
        (set-window-configuration config))
      (delete-directory dir t)
      (dolist (p '(tasks cards log)) (when-let* ((b (get-buffer (drgnx-job-ui--buffer-name "jw" p)))) (kill-buffer b)))
      (clrhash drgnx-job-ui--drawn))))

(ert-deftest drgnx-ui-job-window/closing-it-takes-only-its-buffers ()
  (let ((f (make-frame '((name . "drgnx job jx") (drgnx-job . "jx") (width . 120) (height . 30)))))
    (with-selected-frame f (drgnx-job-ui--layout "jx"))
    (drgnx-job-ui--draw "jx" (plist-put (copy-tree drgnx-job-window-test--summary) :id "jx"))
    (should (get-buffer "*job jx: tasks*"))
    (drgnx-job-ui--frame-deleted f)                                    ; what `delete-frame-functions' runs
    (delete-frame f)
    (should-not (get-buffer "*job jx: tasks*"))))

;;; job-window-test.el ends here
