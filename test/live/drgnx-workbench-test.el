;;; drgnx-workbench-test.el --- live: the workbench dock in a GUI session (config=drgnx) -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-live/the-dock-is-clean-and-pixel-stable ()
  ;; Real key presses: C-b shows the sidebar (VS Code profile) without taking focus; its width is
  ;; identical over 10 hide/show cycles; titles are drawn; no scroll bars in the dock.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" nil 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (let ((ws (seq-filter (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock)) (window-list nil 'nomini))))
                     (list :n (length ws)
                           :width (if ws (window-pixel-width (car ws)) 0)
                           :headers (vconcat (mapcar #'window-header-line-height
                                                     (seq-remove (lambda (w) (window-parameter w 'drgnx-folded)) ws)))
                           :folded (vconcat (mapcar (lambda (w) (with-current-buffer (window-buffer w)
                                                                  (buffer-substring-no-properties (point-min) (pos-eol 1))))
                                                    (seq-filter (lambda (w) (window-parameter w 'drgnx-folded)) ws)))
                           :scrollbars (vconcat (mapcar (lambda (w) (if (nth 2 (window-scroll-bars w)) t :false)) ws))
                           :selected-dock (if (memq (selected-window) ws) t :false))))"))
    (unwind-protect
        (progn
          (drgnx-ui-measure sess (list (list :keys "C-b")))
          (let ((first (drgnx-ui-call sess probe)))
            (should (= (plist-get first :n) 3))                       ; Buffers, Explorer, Outline
            (should (eq (plist-get first :selected-dock) :false))
            ;; open sections draw their title in a header line; Open editors (the UX audit's E2: as VS Code's) and the
            ;; Outline start folded to their headers, drawn as their one-line buffers
            (should (seq-every-p (lambda (h) (> h 0)) (plist-get first :headers)))
            (should (= (length (plist-get first :folded)) 2))
            (should (seq-every-p (lambda (s) (string-match-p "[[:alpha:]]" s)) (plist-get first :folded)))
            (should (seq-every-p (lambda (v) (eq v :false)) (plist-get first :scrollbars)))
            (dotimes (_ 10)
              (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-b"))))
            (should (= (plist-get (drgnx-ui-call sess probe) :width) (plist-get first :width)))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/the-dock-gives-the-editor-groups-their-sizes-back ()
  ;; Two editor groups side by side: C-b hides the sidebar and C-b shows it again; each group is as wide as it was
  ;; (the sidebar's width comes back from where it went, not out of one group).
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" (drgnx-ui-size-at-scale "1400x850") 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (list :groups (vconcat (mapcar #'window-pixel-width (drgnx-groups-list)))
                         :dock (if (seq-some (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock))
                                             (window-list nil 'nomini))
                                   t :false)))"))
    (unwind-protect
        (progn
          (drgnx-ui-call sess "(progn (drgnx-wb-show-sidebar) (drgnx-wb-focus-editor) (drgnx-groups-split-right)
                                      (drgnx-uitest--json (list :ok t)))")
          (drgnx-ui-measure sess nil)
          (let ((before (drgnx-ui-call sess probe)))
            (should (eq (plist-get before :dock) t))
            (should (= (length (plist-get before :groups)) 2))
            (drgnx-ui-measure sess (list (list :keys "C-b")))
            (let ((hidden (drgnx-ui-call sess probe)))
              (should (eq (plist-get hidden :dock) :false))
              (message "dock-split before %S hidden %S" before hidden))
            (drgnx-ui-measure sess (list (list :keys "C-b")))
            (let ((after (drgnx-ui-call sess probe)))
              (message "dock-split after %S" after)
              (should (equal (plist-get after :groups) (plist-get before :groups))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/panel-and-right-dock-are-pixel-stable ()
  ;; Real keys (VS Code profile): M-j toggles the panel, C-M-b the right dock — 10 times each, sizes
  ;; ±0 px, focus never taken; M-x describe-function car RET puts *Help* in the panel's Help tab.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" nil 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (let ((p (drgnx-wb-area-window 'panel)) (r (drgnx-wb-area-window 'right)))
                     (list :panel (if p (window-pixel-height p) 0) :right (if r (window-pixel-width r) 0)
                           :panel-buffer (if p (buffer-name (window-buffer p)) \"\")
                           :selected-area (if (memq (selected-window) (list p r)) t :false))))"))
    (unwind-protect
        (progn
          (drgnx-ui-measure sess (list (list :keys "M-j") (list :keys "C-M-b")))
          (let ((first (drgnx-ui-call sess probe)))
            (should (> (plist-get first :panel) 0))
            (should (> (plist-get first :right) 0))
            (should (eq (plist-get first :selected-area) :false))
            (dotimes (_ 10)
              (drgnx-ui-measure sess (list (list :keys "M-j") (list :keys "M-j") (list :keys "C-M-b") (list :keys "C-M-b"))))
            (let ((again (drgnx-ui-call sess probe)))
              (should (= (plist-get again :panel) (plist-get first :panel)))
              (should (= (plist-get again :right) (plist-get first :right))))
            (drgnx-ui-measure sess (list (list :keys "M-x") (list :type "describe-function") (list :keys "RET") (list :type "car") (list :keys "RET")))
            (let ((help (drgnx-ui-call sess probe)))
              (should (equal (plist-get help :panel-buffer) "*Help*"))
              (should (= (plist-get help :panel) (plist-get first :panel))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(defun drgnx-live-wb--until (sess form what)
  "Ask SESS for FORM (a Lisp string whose value is t or :false under :v) until it is t, at most 30 s; else fail on WHAT."
  (let ((deadline (+ (float-time) 30)))
    (while (not (eq t (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (if %s t :false)))" form)) :v)))
      (when (> (float-time) deadline) (ert-fail (list "not within 30 s" what)))
      (drgnx-ui--poll-pause 0.05))))

(defun drgnx-live-wb--hub (sess)
  "Start the test hub in SESS's Emacs and connect it, as `drgnx-tty-session-hub' does for a tty session: a session
starts none by itself (DRGNX_NO_HUB_START), and the Outline's rows are the hub's.  No hub binary fails the test."
  (let ((bin (seq-some (lambda (kv) (and (string-prefix-p "DRGNX_RATATOSKR_BIN=" kv) (substring kv 20)))
                       (drgnx-ui--hub-env))))
    (unless (and bin (file-executable-p bin))
      (ert-fail "needs the test hub: DRGNX_RATATOSKR_BIN"))
    (drgnx-ui-call sess (format "(progn (require 'drgnx-hub-client)
                                  (unless (drgnx-hub-running-p)
                                    (let ((process-environment (cons \"RATATOSKR_SUPERVISOR=none\" process-environment)))
                                      (make-process :name \"ratatoskr-test\" :noquery t :connection-type 'pipe
                                                    :buffer (generate-new-buffer \" *ratatoskr-test*\")
                                                    :command (list %S \"serve\" \"--foreground\"
                                                                   \"--parent-pid\" (number-to-string (emacs-pid))))))
                                  (drgnx-uitest--json (list :ok t)))"
                                bin))
    (drgnx-live-wb--until sess "(drgnx-hub-running-p)" "the hub running")
    (drgnx-ui-call sess "(progn (drgnx-hub-connect) (drgnx-uitest--json (list :ok t)))")
    (drgnx-live-wb--until sess "(and drgnx-hub--events (eq (process-status drgnx-hub--events) 'open))"
                          "the hub connected")))

(ert-deftest drgnx-live/the-outline-of-a-file-without-one-is-a-quiet-empty-state ()
  ;; The scene's case: the Outline lists an Emacs Lisp file's definitions, then the editor shows a shell script with
  ;; none.  The notice row is whole: not scrolled sideways, nothing drawn before it (no selection left over from the
  ;; rows it replaced), no row selected on it.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" (drgnx-ui-size-at-scale "1400x850") 30))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (el (expand-file-name "a.el" root)) (sh (expand-file-name "b.sh" root))
         (probe "(drgnx-uitest--json
                   (with-current-buffer drgnx-outline-buffer-name
                     (let ((w (get-buffer-window nil t)))
                       (list :text (buffer-substring-no-properties (point-min) (pos-eol 1))
                             :hscroll (if w (window-hscroll w) -1)
                             :strings (length (seq-filter (lambda (o) (or (overlay-get o 'after-string)
                                                                          (overlay-get o 'before-string)))
                                                          (overlays-in (point-min) (min (point-max) (1+ (pos-eol 1))))))
                             :selected (if (seq-find (lambda (o) (and (overlay-get o 'drgnx-row-selected)
                                                                      (overlay-buffer o)))
                                                     (overlays-in (point-min) (point-max)))
                                           t :false)))))"))
    (with-temp-file el (insert "(defun alpha () 1)\n(defun beta () 2)\n(defun gamma () 3)\n"))
    (with-temp-file sh (insert "#!/bin/sh\necho hello\n"))
    (unwind-protect
        (progn
          (drgnx-live-wb--hub sess)
          ;; the Outline opened (it starts folded): this tests its rows, not its fold
          (drgnx-ui-call sess (format "(progn (drgnx-wb-show-sidebar)
                                             (when (drgnx-wb-section-collapsed-p 'outline) (drgnx-wb-toggle-section 'outline))
                                             (drgnx-wb-focus-editor) (find-file %S)
                                             (drgnx-uitest--json (list :ok t)))" el))
          (drgnx-ui-measure sess nil)
          ;; a row of the Outline selected, as a click leaves it
          (drgnx-ui-call sess "(progn (drgnx-outline-refresh)
                                      (with-selected-window (get-buffer-window drgnx-outline-buffer-name t)
                                        (goto-char (point-min)) (forward-line 2) (drgnx-wb-selection-sync))
                                      (drgnx-uitest--json (list :ok t)))")
          (drgnx-ui-measure sess nil)
          (drgnx-ui-call sess (format "(progn (drgnx-wb-focus-editor) (find-file %S) (drgnx-outline-refresh)
                                             (drgnx-uitest--json (list :ok t)))" sh))
          (drgnx-ui-measure sess nil)
          ;; the hub builds the Outline's rows: asked until its notice came (the probe again each look, at most 10 s)
          (let ((after (drgnx-ui-call sess probe)) (deadline (+ (float-time) 10)))
            (while (and (not (string-match-p "No outline for this file" (plist-get after :text)))
                        (< (float-time) deadline))
              (drgnx-ui--poll-pause 0.05)
              (setq after (drgnx-ui-call sess probe)))
            (message "outline empty state %S" after)
            (should (string-match-p "No outline for this file" (plist-get after :text)))
            (should (= 0 (plist-get after :hscroll)))
            (should (= 0 (plist-get after :strings)))
            (should (eq :false (plist-get after :selected)))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/a-file-clicked-in-the-explorer-opens-while-the-work-map-fills-the-editor ()
  ;; A daily install: with the Work space's map in the editor area, a click on a file in the Explorer did not open it
  ;; ("stuck on the work folder"), and *Messages* said "Text is read-only".  A real click on the file's row must show
  ;; the file in an editor window, with no read-only error.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (project (file-name-as-directory (expand-file-name "project" root)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (progn (make-directory (expand-file-name ".git" project) t)
                   (write-region "first\n" nil (expand-file-name "alpha.txt" project) nil 'silent)
                   (write-region "second\n" nil (expand-file-name "beta.txt" project) nil 'silent)
                   (drgnx-ui-start "drgnx" (drgnx-ui-size-at-scale "1400x850") 30)))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (list :shown (if (seq-find (lambda (w) (equal (buffer-name (window-buffer w)) \"beta.txt\"))
                                              (window-list nil 'nomini))
                                    t :false)
                         :editor (buffer-name (window-buffer (drgnx-wb-editor-window)))
                         :windows (format \"%S\" (mapcar (lambda (w) (list (buffer-name (window-buffer w))
                                                                           (window-parameter w 'drgnx-role)
                                                                           (window-dedicated-p w)))
                                                         (window-list nil 'nomini)))
                         :messages (with-current-buffer \"*Messages*\"
                                     (if (string-match-p \"read-only\" (buffer-string)) (buffer-string) \"\"))))"))
    (unwind-protect
        (progn
          (drgnx-live-wb--hub sess)
          (drgnx-ui-call sess (format "(progn (find-file %S) (drgnx-explorer-set-roots (list %S)) (drgnx-wb-show-sidebar)
                                             (drgnx-wb-focus-editor) (drgnx-work-space-open)
                                             (drgnx-uitest--json (list :ok t)))"
                                      (expand-file-name "alpha.txt" project) project))
          (drgnx-ui-measure sess nil)
          (drgnx-live-wb--until sess "(with-current-buffer (window-buffer (drgnx-wb-editor-window)) (derived-mode-p 'drgnx-work-map-mode))" "the Work map in the editor")
          (drgnx-ui-measure sess (list (list :buffer " *drgnx explorer*" :text "beta.txt")))
          (let ((after (drgnx-ui-call sess probe)) (deadline (+ (float-time) 10)))
            (while (and (not (eq t (plist-get after :shown))) (< (float-time) deadline))
              (drgnx-ui--poll-pause 0.1)
              (setq after (drgnx-ui-call sess probe)))
            (ert-info ((format "editor %s; windows %s; messages %s" (plist-get after :editor) (plist-get after :windows)
                               (plist-get after :messages)))
              (should (eq t (plist-get after :shown)))
              (should (equal "" (plist-get after :messages))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))

(ert-deftest drgnx-live/the-work-map-of-a-project-draws ()
  ;; A daily install: the Work space opened on a git project and its map drew nothing.  The map of a project with no
  ;; agents still draws its rows (the hub lays them out): the buffer has text within 20 s.
  (let* ((root (make-temp-file "drgnx-wb" t))
         (project (file-name-as-directory (expand-file-name "project" root)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (progn (make-directory project t)
                   (write-region "first\n" nil (expand-file-name "alpha.txt" project) nil 'silent)
                   (let ((default-directory project))
                     (call-process "git" nil nil nil "init" "-q")
                     (call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@example.invalid"
                                   "commit" "-q" "--allow-empty" "-m" "one"))
                   (drgnx-ui-start "drgnx" (drgnx-ui-size-at-scale "1400x850") 30)))
         (sess (drgnx-ui-own-session (plist-get s :name)))
         (probe "(drgnx-uitest--json
                   (let ((b (seq-find (lambda (b) (with-current-buffer b (derived-mode-p 'drgnx-work-map-mode))) (buffer-list))))
                     (if (not b) (list :text \"\" :info \"no map buffer\")
                       (with-current-buffer b
                         (list :text (buffer-substring-no-properties (point-min) (min (point-max) 600))
                               :info (format \"%S\" (list (buffer-name) (buffer-size)
                                                          (and (boundp 'drgnx-view-patch) drgnx-view-patch t)
                                                          (and (boundp 'drgnx-work-space--message) drgnx-work-space--message)
                                                          (and (fboundp 'drgnx-work-map-rows-p) (drgnx-work-map-rows-p))
                                                          (get-buffer-window b t))))))))"))
    (unwind-protect
        (progn
          (drgnx-live-wb--hub sess)
          (drgnx-ui-call sess (format "(progn (find-file %S) (drgnx-wb-focus-editor) (drgnx-work-space-open)
                                             (drgnx-uitest--json (list :ok t)))"
                                      (expand-file-name "alpha.txt" project)))
          (drgnx-ui-measure sess nil)
          (let ((after (drgnx-ui-call sess probe)) (deadline (+ (float-time) 20)))
            (while (and (string-empty-p (string-trim (plist-get after :text))) (< (float-time) deadline))
              (drgnx-ui--poll-pause 0.2)
              (setq after (drgnx-ui-call sess probe)))
            (ert-info ((format "map: %s; text: %S" (plist-get after :info) (plist-get after :text)))
              (should-not (string-empty-p (string-trim (plist-get after :text)))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))
