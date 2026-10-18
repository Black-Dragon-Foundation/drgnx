;;; mod-browser-test.el --- batch tests: the browser pane, Test Report, Agent's Page -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
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
          (size (cons (window-total-width (frame-root-window)) (window-total-height (frame-root-window)))))
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
                    ((symbol-function 'drgnx-browser-open) (lambda (url) (push url msgs))))
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
        :rawInput (list :url url)))

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

(ert-deftest drgnx-browser/tool-calls-keep-their-raw-input ()
  (let ((s (drgnx-agents--make :name "x" :status 'busy)))
    (drgnx-agents--update s '(:sessionUpdate "tool_call" :toolCallId "t1" :title "mcp__playwright__browser_navigate" :status "pending"))
    (drgnx-agents--update s '(:sessionUpdate "tool_call_update" :toolCallId "t1" :status "in_progress"
                                             :rawInput (:url "http://localhost:3000/")))
    (drgnx-agents--update s '(:sessionUpdate "tool_call" :toolCallId "t2" :title "Read" :rawInput (:path "/a")))
    (should (equal (plist-get (nth 0 (drgnx-agent-session-entries s)) :rawInput) '(:url "http://localhost:3000/")))
    (should (equal (plist-get (nth 1 (drgnx-agent-session-entries s)) :rawInput) '(:path "/a")))
    (should (equal (drgnx-browser-agent-url s) "http://localhost:3000/"))))

(provide 'mod-browser-test)
;;; mod-browser-test.el ends here
