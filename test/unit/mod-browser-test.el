;;; mod-browser-test.el --- batch tests: the browser pane, Test Report, Agent's Page -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(require 'drgnx-jobs)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-browser" drgnx-dir) nil t)

(defvar drgnx-browser-test--urls nil "URLs the stubbed WebKit was asked for.")

(defun drgnx-browser-test--webkit (url &rest _)
  "A stand-in for `xwidget-webkit-browse-url': a buffer shown in the selected window."
  (push url drgnx-browser-test--urls)
  (switch-to-buffer (get-buffer-create "*drgnx-browser-test-xwidget*")))

(defmacro drgnx-browser-test--with (&rest body)
  "BODY in a 200×60 frame with one editor window, the browser's state fresh and no real xwidgets or browser."
  (declare (indent 0))
  `(let* ((drgnx-wb--sections nil) (drgnx-signal--editor-window nil)
          (drgnx-browser--told nil) (drgnx-browser--buffer nil) (drgnx-browser-test--urls nil)
          (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
          (size (cons (frame-width) (frame-height))))
     (set-frame-size nil 200 60)
     (delete-other-windows)
     (switch-to-buffer (get-buffer-create "*drgnx-browser-test-code*"))
     (set-window-parameter nil 'drgnx-tabs nil)
     (unwind-protect (progn ,@body)
       (delete-other-windows)
       (set-window-parameter nil 'drgnx-tabs nil)
       (set-window-parameter nil 'drgnx-layouts-pane nil)
       (set-frame-size nil (car size) (cdr size))
       (switch-to-buffer "*scratch*")
       (dolist (b '("*drgnx-browser-test-code*" "*drgnx-browser-test-xwidget*" "*drgnx: browser*" "*drgnx: agent screenshot*"))
         (when-let* ((buf (get-buffer b))) (kill-buffer buf))))))

(defun drgnx-browser-test--messages (thunk)
  "The messages THUNK prints, as a list."
  (let (out)
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) out))))
      (funcall thunk))
    (nreverse out)))

(ert-deftest drgnx-browser/a-text-frame-says-so-and-opens-the-system-browser ()
  ;; an Emacs with WebKit still cannot show a page in a terminal frame (batch has none graphical)
  (drgnx-browser-test--with
    (let ((had (featurep 'xwidget-internal)) opened msgs)
      (unwind-protect
          (progn
            (provide 'xwidget-internal)
            (should-not (drgnx-browser-webkit-p))
            (cl-letf (((symbol-function 'browse-url) (lambda (u &rest _) (push u opened))))
              (setq msgs (drgnx-browser-test--messages (lambda () (drgnx-browser-open "https://example.org")))))
            (should (equal opened '("https://example.org")))
            (should (= 1 (length msgs)))
            (should (string-match-p "this terminal cannot show a web page" (car msgs)))
            (should-not (string-match-p "no WebKit" (car msgs)))
            (should (string-match-p "terminal cannot show a web page" (with-current-buffer (drgnx-browser--placeholder) (buffer-string)))))
        (unless had (setq features (delq 'xwidget-internal features)))))))

(ert-deftest drgnx-browser/xwidget-or-fallback ()
  (drgnx-browser-test--with
    ;; without WebKit: the system browser, and one message naming the reason (only the first time)
    (let (opened msgs)
      (cl-letf (((symbol-function 'drgnx-browser-webkit-p) (lambda () nil))
                ((symbol-function 'browse-url) (lambda (u &rest _) (push u opened))))
        (setq msgs (append (drgnx-browser-test--messages (lambda () (drgnx-browser-open "http://localhost:3000")))
                           (drgnx-browser-test--messages (lambda () (drgnx-browser-open "https://example.org")))))
        (should (equal (nreverse opened) '("http://localhost:3000" "https://example.org")))
        (should (= 1 (length msgs)))
        (should (string-match-p "no WebKit" (car msgs)))
        (should (string-match-p "docs/guide/browser.md" (car msgs)))
        (should (= 1 (length (window-list nil 'nomini))))))     ; no pane for a page the system browser shows
    ;; with WebKit: a pane to the right of the editor with the page, and a header line (address, back, forward, reload)
    (let ((code (selected-window)))
      (cl-letf (((symbol-function 'drgnx-browser-webkit-p) (lambda () t))
                ((symbol-function 'xwidget-webkit-browse-url) #'drgnx-browser-test--webkit)
                ((symbol-function 'xwidget-webkit-goto-url) (lambda (url) (push url drgnx-browser-test--urls)))
                ((symbol-function 'xwidget-webkit-uri) (lambda (&rest _) "http://localhost:3000/"))
                ((symbol-function 'xwidget-webkit-current-session) (lambda () 'session))
                ((symbol-function 'browse-url) (lambda (&rest _) (error "browse-url is the fallback"))))
        (drgnx-browser-open "localhost:3000")
        (should (equal drgnx-browser-test--urls '("http://localhost:3000")))
        (let ((pane (window-in-direction 'right code)))
          (should (window-live-p pane))
          (should (eq (window-parameter pane 'drgnx-layouts-pane) 'browser))
          (should (equal (buffer-name (window-buffer pane)) "*drgnx-browser-test-xwidget*"))
          (with-current-buffer (window-buffer pane)
            (should drgnx-browser-mode)
            (should (equal header-line-format '(:eval (drgnx-browser--header))))
            (let ((h (substring-no-properties (drgnx-browser--header))))  ; batch Emacs draws no header line
              (dolist (want '("◀" "▶" "⟳" "http://localhost:3000/")) (should (string-search want h)))))
          ;; the next page goes into the same pane
          (drgnx-browser-open "https://example.org")
          (should (= 2 (length (window-list nil 'nomini))))
          (should (equal (car drgnx-browser-test--urls) "https://example.org")))))
    ;; addresses: a scheme stays, a host gets one, words are a search
    (should (equal (drgnx-browser--normalise "https://a.b/c") "https://a.b/c"))
    (should (equal (drgnx-browser--normalise "localhost:8080/x") "http://localhost:8080/x"))
    (should (equal (drgnx-browser--normalise "example.org") "https://example.org"))
    (should (string-prefix-p "https://duckduckgo.com/?q=emacs%20xwidgets" (drgnx-browser--normalise "emacs xwidgets")))))

(ert-deftest drgnx-browser/browser-layout-shape ()
  (drgnx-browser-test--with
    (let ((drgnx-layouts-shapes (copy-sequence drgnx-layouts-shapes)))
      (drgnx-browser--register-shape)
      (should (alist-get 'editor+browser drgnx-layouts-shapes))
      (cl-letf (((symbol-function 'drgnx-browser-webkit-p) (lambda () nil)))
        (let* ((code (selected-window))
               (pane (funcall (alist-get 'editor+browser drgnx-layouts-shapes) code)))
          (should (eq (window-in-direction 'right code) pane))
          (should (eq (window-parameter pane 'drgnx-layouts-pane) 'browser))
          (should (eq (selected-window) code))
          (with-current-buffer (window-buffer pane)
            (should (string-search "Browser: Open URL" (buffer-string)))
            (should (string-search "no WebKit" (buffer-string)))))))))

(defun drgnx-browser-test--touch (file seconds-ago)
  (make-directory (file-name-directory file) t)
  (write-region "x" nil file nil 'silent)
  (set-file-times file (time-subtract (current-time) seconds-ago)))

(ert-deftest drgnx-browser/test-report-finds-the-newest ()
  (let* ((root (make-temp-file "drgnx-browser" t))
         (old (expand-file-name "old/playwright-report/index.html" root))
         (new (expand-file-name "playwright-report/index.html" root))
         (trace (expand-file-name "test-results/a/trace.zip" root))
         (junk (expand-file-name "node_modules/x/playwright-report/index.html" root))
         jobs polls (msgs nil))
    (unwind-protect
        (progn
          (drgnx-browser-test--touch old 3600)
          (drgnx-browser-test--touch trace 1800)
          (drgnx-browser-test--touch new 60)
          (drgnx-browser-test--touch junk 1)                    ; node_modules is not looked into
          (should (equal (drgnx-browser-newest root) (list :kind 'report :path (file-name-directory new))))
          ;; a trace newer than every report wins and opens with show-trace
          (drgnx-browser-test--touch trace 5)
          (should (equal (drgnx-browser-newest root) (list :kind 'trace :path trace)))
          (drgnx-browser-test--touch trace 1800)
          ;; the command: a durable job, then the page at the URL the server prints
          (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "npx") "/usr/bin/npx")))
                    ((symbol-function 'drgnx-jobs-start)
                     (lambda (name command &rest args) (push (list name command args) jobs) "job-1"))
                    ((symbol-function 'drgnx-jobs-list) (lambda () nil))
                    ((symbol-function 'drgnx-jobs-log) (lambda (&rest _) "Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.\n"))
                    ((symbol-function 'drgnx-jobs-get) (lambda (&rest _) (list :status 'running)))
                    ((symbol-function 'run-with-timer) (lambda (_s _r fn &rest _) (push fn polls) 'timer))
                    ((symbol-function 'cancel-timer) #'ignore)
                    ((symbol-function 'drgnx-browser-open) (lambda (url &optional keep) (push (if keep url (list :steals-focus url)) msgs))))
            (let ((default-directory root))
              (drgnx-browser-test-report))
            (should (equal (cadr (car jobs))
                           (list "npx" "playwright" "show-report" (directory-file-name (file-name-directory new)) "--port" "0")))
            (should (equal (plist-get (nth 2 (car jobs)) :cwd) root))
            (should (plist-get (nth 2 (car jobs)) :no-wait))
            (should (null msgs))                                 ; nothing opened before the server speaks
            (funcall (car polls))
            (should (equal msgs '("http://localhost:9323")))
            ;; a trace goes to show-trace
            (setq jobs nil)
            (drgnx-browser-test--touch trace 5)
            (let ((default-directory root))
              (drgnx-browser-test-report))
            (should (equal (cadr (car jobs)) (list "npx" "playwright" "show-trace" trace "--port" "0")))))
      (delete-directory root t))))

(ert-deftest drgnx-browser/test-report-says-what-is-missing ()
  (let ((root (make-temp-file "drgnx-browser" t)) started)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (setq started t))))
          (let ((default-directory root))
            ;; no report
            (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/npx")))
              (let ((m (drgnx-browser-test--messages #'drgnx-browser-test-report)))
                (should (string-match-p "No Playwright report" (car m)))))
            ;; no npx
            (drgnx-browser-test--touch (expand-file-name "playwright-report/index.html" root) 10)
            (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
              (let ((m (drgnx-browser-test--messages #'drgnx-browser-test-report)))
                (should (string-match-p "npx" (car m)))))
            (should-not started)))
      (delete-directory root t))))

(defconst drgnx-browser-test--png
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  "A 1×1 PNG, base64.")

(defun drgnx-browser-test--nav (id url &optional title)
  (list :type 'tool :id id :title (or title "mcp__playwright__browser_navigate") :status "completed"
        :url url))

(defun drgnx-browser-test--shot (id)
  (list :type 'tool :id id :title "mcp__playwright__browser_take_screenshot" :status "completed"
        :content (list (list :type "content" :content (list :type "image" :data drgnx-browser-test--png :mimeType "image/png")))))

(ert-deftest drgnx-browser/agent-page-from-tool-calls ()
  (drgnx-browser-test--with
    (let* ((s (drgnx-agents--make
               :name "claude · app" :status 'idle
               :entries (list '(:type user :text "check the login page")
                              (drgnx-browser-test--nav "t1" "http://localhost:3000/")
                              (drgnx-browser-test--shot "t2")
                              ;; not a navigation: a fetch tool that happens to take a url
                              (drgnx-browser-test--nav "t3" "https://docs.example.org/" "WebFetch")
                              ;; a sub-agent's tool call is a call too, and the last one wins
                              (list :type 'tool :id "task" :title "Task: check" :status "completed"
                                    :children (list (drgnx-browser-test--nav "t4" "http://localhost:3000/login")
                                                    (drgnx-browser-test--shot "t5")))
                              '(:type agent :text "Done."))))
           opened)
      (should (equal (drgnx-browser-agent-url s) "http://localhost:3000/login"))
      (cl-letf (((symbol-function 'drgnx-browser-open) (lambda (url) (push url opened))))
        (drgnx-browser-agent-page s))
      (should (equal opened '("http://localhost:3000/login")))
      ;; the latest screenshot in a side buffer
      (let ((buf (get-buffer "*drgnx: agent screenshot*")))
        (should buf)
        (should (get-buffer-window buf))
        (with-current-buffer buf
          (should (string-search "claude · app" (buffer-string)))
          (let ((img (get-text-property (or (text-property-any (point-min) (point-max) 'drgnx-browser-image t) (point-min))
                                        'display)))
            (should (eq (car-safe img) 'image))
            (should (eq (plist-get (cdr img) :type) 'png))
            (should (equal (plist-get (cdr img) :data) (base64-decode-string drgnx-browser-test--png)))))))))

(ert-deftest drgnx-browser/no-url-says-so ()
  (drgnx-browser-test--with
    (let ((s (drgnx-agents--make :name "claude · app" :status 'idle
                                 :entries (list '(:type user :text "hi")
                                                (drgnx-browser-test--nav "t1" "https://docs.example.org/" "WebFetch")
                                                '(:type tool :id "t2" :title "Read" :status "completed" :rawInput (:path "/a")))))
          opened)
      (should-not (drgnx-browser-agent-url s))
      (cl-letf (((symbol-function 'drgnx-browser-open) (lambda (url) (push url opened))))
        (let ((m (drgnx-browser-test--messages (lambda () (drgnx-browser-agent-page s)))))
          (should (= 1 (length m)))
          (should (string-match-p "claude · app has not opened a page" (car m)))))
      (should-not opened)
      (should-not (get-buffer "*drgnx: agent screenshot*")))))

(ert-deftest drgnx-browser/tool-calls-keep-only-the-url ()
  (let ((s (drgnx-agents--make :name "x" :status 'busy)))
    (drgnx-agents--update s '(:sessionUpdate "tool_call" :toolCallId "t1" :title "mcp__playwright__browser_navigate" :status "pending"))
    (drgnx-agents--update s '(:sessionUpdate "tool_call_update" :toolCallId "t1" :status "in_progress"
                                             :rawInput (:url "http://localhost:3000/")))
    (drgnx-agents--update s '(:sessionUpdate "tool_call" :toolCallId "t2" :title "Write" :rawInput (:file_path "/a" :content "a whole file")))
    (should (equal (plist-get (nth 0 (drgnx-agent-session-entries s)) :url) "http://localhost:3000/"))
    ;; the raw input itself is not kept (a Write's is the whole file)
    (dolist (e (drgnx-agent-session-entries s)) (should-not (plist-get e :rawInput)))
    (should-not (plist-get (nth 1 (drgnx-agent-session-entries s)) :url))
    (should (equal (drgnx-browser-agent-url s) "http://localhost:3000/"))
    ;; an entry that still has the raw input (the Live module's tests build them so) reads the same
    (should (equal (drgnx-browser-agent-url
                    (drgnx-agents--make :entries (list '(:type tool :title "browser_navigate" :rawInput (:url "http://a.test/")))))
                   "http://a.test/"))))

(ert-deftest drgnx-browser/the-header-escapes-percent-signs ()
  (cl-letf (((symbol-function 'xwidget-webkit-current-session) (lambda () 'session))
            ((symbol-function 'xwidget-webkit-uri) (lambda (&rest _) "https://duckduckgo.com/?q=emacs%20xwidgets")))
    (let ((h (substring-no-properties (drgnx-browser--header))))
      (should (string-search "q=emacs%%20xwidgets" h)))
    ;; the address the prompt starts from stays as it is
    (should (equal (drgnx-browser--url) "https://duckduckgo.com/?q=emacs%20xwidgets"))))

(ert-deftest drgnx-browser/local-addresses-open-as-pages ()
  (dolist (c '(("192.168.1.5:8080" . "http://192.168.1.5:8080") ("0.0.0.0:3000/x" . "http://0.0.0.0:3000/x")
               ("10.0.2.2" . "http://10.0.2.2") ("myhost:3000/app" . "http://myhost:3000/app")
               ("example.org" . "https://example.org")))
    (should (equal (drgnx-browser--normalise (car c)) (cdr c))))
  (should (string-prefix-p "https://duckduckgo.com/?q=" (drgnx-browser--normalise "my host:3000"))))

(ert-deftest drgnx-browser/the-server-address-is-read-from-its-own-line ()
  (should (equal (drgnx-browser--log-url "\e[32mServing HTML report at http://localhost:9323\e[0m. Press Ctrl+C to quit.\r\n")
                 "http://localhost:9323"))
  (should (equal (drgnx-browser--log-url "npm warn see https://npm.example/x\nListening on http://127.0.0.1:5555\n")
                 "http://127.0.0.1:5555"))
  (should (equal (drgnx-browser--log-url "see https://npm.example/x\nopening http://localhost:7000/trace\n")
                 "http://localhost:7000/trace"))
  (should-not (drgnx-browser--log-url "npm warn see https://npm.example/x\n"))
  (should-not (drgnx-browser--log-url "")))

(defun drgnx-browser-test--jobs ()
  (let ((cwd "/tmp/drgnx-pw"))
    (list (list :id "old" :name "playwright" :cwd cwd :status 'running :unit "drgnx-job-old" :command '("npx" "x"))
          (list :id "lost" :name "playwright" :cwd (concat cwd "/") :status 'gone :unit "drgnx-job-lost")
          (list :id "elsewhere" :name "playwright" :cwd "/tmp/other/" :status 'running :unit "drgnx-job-elsewhere")
          (list :id "done" :name "playwright" :cwd cwd :status 'exited :unit "drgnx-job-done")
          (list :id "mermaid" :name "mermaid" :cwd cwd :status 'running :unit "drgnx-job-mermaid"))))

(defmacro drgnx-browser-test--with-jobs (&rest body)
  "BODY with the jobs of `drgnx-browser-test--jobs'; `stopped' collects the ids and `units' the systemd units stopped."
  (declare (indent 0))
  `(let (stopped units)
     (cl-letf (((symbol-function 'drgnx-jobs-list) #'drgnx-browser-test--jobs)
               ((symbol-function 'drgnx-jobs-get)
                (lambda (id) (seq-find (lambda (j) (equal (plist-get j :id) id)) (drgnx-browser-test--jobs))))
               ((symbol-function 'drgnx-jobs-stop) (lambda (id) (push id stopped)))
               ((symbol-function 'call-process) (lambda (_p &rest args) (push (car (last args)) units) 0)))
       ,@body)))

(ert-deftest drgnx-browser/test-report-stops-the-servers-it-replaces ()
  (let ((root (make-temp-file "drgnx-browser" t)) started)
    (unwind-protect
        (progn
          (drgnx-browser-test--touch (expand-file-name "playwright-report/index.html" root) 10)
          (drgnx-browser-test--with-jobs
            (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/npx"))
                      ((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (setq started t) "new"))
                      ((symbol-function 'run-with-timer) (lambda (&rest _) 'timer))
                      ((symbol-function 'drgnx-browser--root) (lambda () "/tmp/drgnx-pw/"))
                      ((symbol-function 'drgnx-browser-newest)
                       (lambda (_) (list :kind 'report :path (file-name-as-directory root)))))
              (drgnx-browser-test-report)
              (should started)
              ;; the running and the lost ones of this project, nothing else (a lost one may still run: its unit is stopped too)
              (should (equal (sort stopped #'string<) '("lost" "old")))
              (should (equal (sort units #'string<) '("drgnx-job-lost" "drgnx-job-old"))))))
      (delete-directory root t))))

(ert-deftest drgnx-browser/the-watcher-gives-up-and-stops-the-server ()
  ;; The timer never blocks: the server's unit is stopped with --no-block through a process, not a synchronous stop.
  (let (fns cancelled commands)
    (drgnx-browser-test--with-jobs
      (cl-letf (((symbol-function 'drgnx-jobs-log) (lambda (&rest _) ""))
                ((symbol-function 'run-with-timer) (lambda (_s _r fn &rest _) (push fn fns) (intern (format "timer-%d" (length fns)))))
                ((symbol-function 'cancel-timer) (lambda (tm) (push tm cancelled)))
                ((symbol-function 'make-process) (lambda (&rest args) (push (plist-get args :command) commands) nil)))
        ;; a second Test Report on the same job does not stack a second watcher
        (drgnx-browser--watch-job "old")
        (drgnx-browser--watch-job "old")
        (should (equal cancelled '(timer-1)))
        (let ((fn (car fns)))
          (dotimes (_ 120) (funcall fn))
          (should-not commands)
          (let ((m (drgnx-browser-test--messages fn)))
            (should (string-match-p "did not print an address" (car m))))
          (should (equal commands '(("systemctl" "--user" "stop" "--no-block" "drgnx-job-old"))))
          (should-not stopped)                          ; `drgnx-jobs-stop' waits for systemd: not from a timer
          (should-not units)
          (should (memq 'timer-2 cancelled)))))))

(ert-deftest drgnx-browser/an-error-in-the-watcher-ends-the-timer ()
  (let (fn cancelled (drgnx-browser--watchers nil))
    (drgnx-browser-test--with-jobs
      (cl-letf (((symbol-function 'drgnx-jobs-log) (lambda (&rest _) ""))
                ((symbol-function 'drgnx-jobs-get) (lambda (&rest _) (error "the job store is broken")))
                ((symbol-function 'run-with-timer) (lambda (_s _r f &rest _) (setq fn f) 'timer))
                ((symbol-function 'cancel-timer) (lambda (tm) (push tm cancelled))))
        (drgnx-browser--watch-job "j")
        (let ((m (drgnx-browser-test--messages fn)))     ; no error escapes the timer
          (should (string-match-p "the job store is broken" (car m))))
        (should (equal cancelled '(timer)))))))

(ert-deftest drgnx-browser/a-lost-job-is-waited-for-and-an-ended-one-is-not ()
  (let (fn cancelled (status 'gone))
    (drgnx-browser-test--with-jobs
      (cl-letf (((symbol-function 'drgnx-jobs-log) (lambda (&rest _) ""))
                ((symbol-function 'drgnx-jobs-get) (lambda (&rest _) (list :id "j" :status status)))
                ((symbol-function 'run-with-timer) (lambda (_s _r f &rest _) (setq fn f) 'timer))
                ((symbol-function 'cancel-timer) (lambda (tm) (push tm cancelled))))
        (drgnx-browser--watch-job "j")
        (funcall fn) (funcall fn)                 ; `gone' can be a job systemd runs: no giving up yet
        (should-not cancelled)
        (setq status 'exited)
        (drgnx-browser-test--messages fn)
        (should cancelled)))))

(ert-deftest drgnx-browser/a-timer-open-keeps-the-focus ()
  (drgnx-browser-test--with
    (let ((code (selected-window)))
      (cl-letf (((symbol-function 'drgnx-browser-webkit-p) (lambda () t))
                ((symbol-function 'xwidget-webkit-browse-url) #'drgnx-browser-test--webkit))
        (drgnx-browser-open "localhost:3000" t)
        (should (eq (selected-window) code))
        (should (window-live-p (window-in-direction 'right code)))))))

(provide 'mod-browser-test)
;;; mod-browser-test.el ends here

(ert-deftest drgnx-browser/the-fixture-keeps-the-frame-size ()
  ;; The fixture gives the frame back its size: a frame one line shorter after each test left later docks no room.
  (let ((size (cons (frame-width) (frame-height))))
    (drgnx-browser-test--with (ignore))
    (read-event nil nil 0.01)                           ; a terminal frame takes its new size at the next wait
    (should (equal (cons (frame-width) (frame-height)) size))))

(ert-deftest drgnx-browser/command-labels-say-browser-once ()
  ;; The palette shows "Category: Title": the titles must not repeat the category.
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-browser--define-commands)
    (should (equal (mapcar (lambda (id) (drgnx-commands-label (drgnx-commands-get id)))
                           '(browser-open browser-test-report browser-agent-page browser-go))
                   '("Browser: Open URL…" "Browser: Test Report" "Browser: Agent's Page" "Browser: Go to Address…")))))
