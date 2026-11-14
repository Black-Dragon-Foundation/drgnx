;;; look-scenes-test.el --- the look's scenes: one per mockup, a project with the audit's git state -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure) for the scene table and the size; the project is made with git in a temp directory.  The scenes
;; themselves are drawn by `drgnx ui look-scenes' in a session (docs/develop/harness.md, "Look scenes"); no pixel is
;; asserted anywhere: the pictures are looked at beside the mockups.
(require 'ert)
(require 'drgnx)
(require 'drgnx-look-scenes (expand-file-name "harness/drgnx-look-scenes" drgnx-dir))
(load (expand-file-name "harness/drgnx-look-scenes-session" drgnx-dir) nil t)
(defvar drgnx-look-scene-rows-wait)
(require 'drgnx-view)

(ert-deftest drgnx-look-scenes/one-scene-per-mockup ()
  "Every mockup the look was approved on has a scene of the same name, and every scene has its setup function."
  (dolist (mockup '(window-dark window-light window-hc palette agent-panel magit debugging))
    (should (assq mockup drgnx-look-scenes)))
  (should (eq (plist-get (cdr (assq 'work-flow drgnx-look-scenes)) :mockup) 'hub-orchestration))
  (dolist (scene drgnx-look-scenes)
    (should (fboundp (intern (format "drgnx-look-scene-%s" (car scene)))))))

(ert-deftest drgnx-look-scenes/size-is-the-mockups-window ()
  "The mockups' window is 1440x900 logical pixels: the device size grows with the scale."
  (should (equal (drgnx-look-scenes--size 1) "1440x900"))
  (should (equal (drgnx-look-scenes--size 2) "2880x1800")))

(ert-deftest drgnx-look-scenes/the-project-is-the-mockups ()
  "The mockups' project: drgnx-gateway.el and gateway-test.el modified, jobs-test.el untracked, the lock file
ignored, on main two commits ahead of its remote; drgnx-gateway.el's line 216 is the mockup's, and the shell script has its heredoc."
  (let ((dir (make-temp-file "look-scenes" t)))
    (unwind-protect
        (let* ((proj (drgnx-look-scene-project (expand-file-name "drgnx" dir)))
               (default-directory proj)
               (status (with-temp-buffer (call-process "git" nil t nil "status" "--porcelain" "--ignored")
                                         (buffer-string))))
          (should (string-match-p "^ M core/drgnx-gateway\\.el$" status))
          (should (string-match-p "^ M test/unit/gateway-test\\.el$" status))
          (should (string-match-p "^\\?\\? test/unit/jobs-test\\.el$" status))
          (should (string-match-p "^!! drgnx\\.lock\\.eld$" status))
          (with-temp-buffer
            (insert-file-contents "core/drgnx-gateway.el")
            (forward-line 215)
            (should (equal (buffer-substring (point) (line-end-position)) "      (process-send-string p reply)"))
            (forward-line -15)
            (should (equal (buffer-substring (point) (line-end-position)) ";;;; Replies")))
          (should (string-match-p "<<PY" (with-temp-buffer (insert-file-contents "docs/p2-verify.sh") (buffer-string))))
          (should (string-match-p "\\`## main\\.\\.\\.origin/main \\[ahead 2\\]"
                                  (with-temp-buffer (call-process "git" nil t nil "status" "-sb") (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest drgnx-look-scenes/the-diff-has-a-refined-pair ()
  "The highlights scene's hunk is a valid one (its header counts its lines), so `diff-refine-hunk' marks the changed
words of its line pairs: `when' against `if', the faces `diff-refine-removed' and `diff-refine-added'."
  (require 'diff-mode)
  (with-temp-buffer
    (insert drgnx-look-scene--diff)
    (diff-mode)
    (goto-char (point-min))
    (diff-hunk-next)
    (diff-refine-hunk)
    (let ((fine (mapcar (lambda (o) (list (overlay-get o 'face) (buffer-substring (overlay-start o) (overlay-end o))))
                        (seq-filter (lambda (o) (eq (overlay-get o 'diff-mode) 'fine))
                                    (overlays-in (point-min) (point-max))))))
      (should (member '(diff-refine-removed "when") fine))
      (should (member '(diff-refine-added "if") fine)))))

(ert-deftest drgnx-look-scenes/a-limit-is-named-not-hidden ()
  "What the line cannot show of a mockup is written to the scene's facts."
  (should (assq 'window-dark drgnx-look-scene-limits)))

(ert-deftest drgnx-look-scenes/the-cli-knows-the-command ()
  (require 'drgnx-ui (expand-file-name "harness/drgnx-ui" drgnx-dir))
  (should (string-match-p "look-scenes" drgnx-ui-usage)))

(provide 'look-scenes-test)
;;; look-scenes-test.el ends here

(ert-deftest drgnx-look-scenes/the-notebook-scenes-are-the-notebook-mockups ()
  (dolist (scene '(notebook-dark notebook-light))
    (should (eq (plist-get (cdr (assq scene drgnx-look-scenes)) :mockup) 'notebook))
    (should (fboundp (intern (format "drgnx-look-scene-%s" scene))))
    (should (assq scene drgnx-look-scene-limits))))

(ert-deftest drgnx-look-scenes/the-notebook-scene-holds-the-mockups-four-cells ()
  (let ((buffer (drgnx-look-scene--notebook-buffer)))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal (mapcar (lambda (c) (plist-get c :type)) (drgnx-notebook--rescan)) '(markdown code code code)))
          (should (string-search "[*]" (overlay-get (plist-get (drgnx-notebook--chrome-of "c2") :head) 'before-string)))
          (should (string-search "NameError" (overlay-get (plist-get (drgnx-notebook--chrome-of "c3") :tail) 'after-string)))
          (should (equal (buffer-name) "cache-experiments.ipynb")))
      (kill-buffer buffer))))

(defun drgnx-look-scenes-test--shown-view (view then)
  "A hub-fed VIEW shown in the selected window, its env sent and no rows yet; THEN called with its state, with
`accept-process-output' standing for the hub's wait (it returns nil)."
  (let ((b (generate-new-buffer " *look-scenes unfed*")) (w (selected-window)) (was (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (with-current-buffer b (drgnx-view-patch-attach view "c"))
          (set-window-buffer w b)
          (funcall then (buffer-local-value 'drgnx-view-patch b)))
      (set-window-buffer w was)
      (kill-buffer b))))

(ert-deftest drgnx-look-scenes/a-view-a-step-shows-is-waited-for-until-its-rows-come ()
  "A view a step's command has just shown (a class change re-pairs it, so it is empty until the hub's reset) is not
an error while the hub's rows are on their way: the step waits for them, as the user does, then answers."
  (drgnx-look-scenes-test--shown-view
   "unfed-test"
   (lambda (state)
     (let ((drgnx-look-scene--errors nil) (waits 0))
       (cl-letf (((symbol-function 'drgnx-hub-running-p) (lambda () t))
                 ((symbol-function 'drgnx-view-env-classes) (lambda (_) '("c")))
                 ((symbol-function 'redisplay) #'ignore)
                 ;; the hub's rows come during the second wait
                 ((symbol-function 'accept-process-output)
                  (lambda (&rest _) (when (= 2 (cl-incf waits)) (setf (drgnx-view-patch-version state) 1)) nil)))
         (drgnx-look-scene--unfed))
       (should (= 2 waits))
       (should-not drgnx-look-scene--errors)))))

(ert-deftest drgnx-look-scenes/a-view-whose-rows-never-come-is-an-error ()
  "A shown view the hub sends no rows for is still the step's error, naming the view, once the wait is over."
  (drgnx-look-scenes-test--shown-view
   "unfed-test"
   (lambda (_state)
     (let ((drgnx-look-scene--errors nil) (drgnx-look-scene-rows-wait 0))
       (cl-letf (((symbol-function 'drgnx-hub-running-p) (lambda () t))
                 ((symbol-function 'drgnx-view-env-classes) (lambda (_) '("c")))
                 ((symbol-function 'redisplay) #'ignore)
                 ((symbol-function 'accept-process-output) #'ignore))
         (drgnx-look-scene--unfed))
       (should (= 1 (length drgnx-look-scene--errors)))
       (should (string-match-p "\\`unfed-test: shown in .* with no rows from the hub" (car drgnx-look-scene--errors)))))))

;; The scenes that follow one another share a session: what a scene leaves is what the next one starts from.
(ert-deftest drgnx-look-scenes/the-popup-scenes-are-closed-with-the-popups-own-key ()
  ;; the Replace All sheet and the Ask an Agent card end on Esc (the popup lane's key; C-g is the palette's): a
  ;; sheet left open leaves the popup frame selected, with no editor window for the scenes after it
  (dolist (scene '(search-sheet search-ask))
    (should (equal (plist-get (cdr (assq scene drgnx-look-scenes)) :then) "<escape>"))))

(ert-deftest drgnx-look-scenes/the-stand-in-eglot-answers-what-the-product-asks-a-server
    ()
  ;; the Search view asks the buffer's server what it can do (`eglot-server-capable'): a stand-in of the status bar's
  ;; `● eglot' that cannot answer made every Search scene after the window scene fail
  (require 'eglot)
  (with-temp-buffer
    (unwind-protect
        (progn (drgnx-look-scene--eglot)
               (should (eglot-current-server))
               (should-not (eglot-server-capable :renameProvider)))
      (when (bound-and-true-p eglot--cached-server)
        (ignore-errors (delete-process (jsonrpc--process eglot--cached-server)))))))
