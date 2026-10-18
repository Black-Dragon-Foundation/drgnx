;;; drgnx-browser.el --- Module tools/browser: a web page pane beside the editor, Test Report, Agent's Page -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A real, clickable web page in a pane to the right of the editor (an `xwidget-webkit' session), with the
;; address, back, forward and reload on its header line.  It needs an Emacs built with WebKit (xwidgets);
;; without one, pages open in your system browser (`browse-url') and one message says why.  The Browser layout
;; (module `tools/layouts') uses this pane.  Test Report serves the newest Playwright HTML report (or opens
;; the newest trace) found in the project, as a durable job, and shows it here; Agent's Page opens the page
;; an agent's Playwright session is on, with its latest screenshot beside it.  See docs/guide/browser.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)

(declare-function xwidget-webkit-browse-url "xwidget")
(declare-function xwidget-webkit-goto-url "xwidget")
(declare-function xwidget-webkit-current-session "xwidget")
(declare-function xwidget-webkit-uri "xwidget")
(declare-function xwidget-webkit-back "xwidget")
(declare-function xwidget-webkit-forward "xwidget")
(declare-function xwidget-webkit-reload "xwidget")
(declare-function drgnx-wb-editor-window "drgnx-wb")
(declare-function drgnx-groups--split "drgnx-groups")
(declare-function drgnx-jobs-stop "drgnx-jobs")
(declare-function drgnx-jobs-start "drgnx-jobs")
(declare-function drgnx-jobs-get "drgnx-jobs")
(declare-function drgnx-jobs-list "drgnx-jobs")
(declare-function drgnx-jobs-log "drgnx-jobs")
(declare-function drgnx-agents-ui--session "drgnx-agents-ui")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-entries "drgnx-agents")
(defvar drgnx-layouts-shapes)
(defvar xwidget-webkit-last-session-buffer)

(defvar drgnx-browser--told nil "Non-nil once the message about the missing WebKit has been shown.")
(defvar drgnx-browser--buffer nil "The last page buffer of the pane (a WebKit session),
shown again by the Browser layout.")

(defconst drgnx-browser--no-webkit
  "no WebKit in this Emacs (it was built without xwidgets), so pages open in your system browser; see docs/guide/browser.md")

(defun drgnx-browser-webkit-p ()
  "Does this Emacs have WebKit (xwidgets)?"
  (featurep 'xwidget-internal))

;;;; Addresses

(defun drgnx-browser--normalise (text)
  "TEXT as a URL: one with a scheme stays; a host (localhost, or with a dot) gets http(s)://; words are a web search."
  (let ((text (string-trim text)))
    (cond ((string-match-p "\\`[a-z][a-z0-9+.-]*://" text) text)
          ((string-match-p "\\`\\(?:localhost\\|127\\.0\\.0\\.1\\|\\[::1\\]\\)\\(?:[:/]\\|\\'\\)" text) (concat "http://" text))
          ;; a dev server on the network: an IPv4 address, or host:port
          ((string-match-p "\\`\\(?:[0-9]\\{1,3\\}\\.\\)\\{3\\}[0-9]\\{1,3\\}\\(?:[:/?#].*\\)?\\'" text) (concat "http://" text))
          ((string-match-p "\\`[a-z0-9_-]+:[0-9]+\\(?:[/?#].*\\)?\\'" text) (concat "http://" text))
          ((string-match-p "\\`[^ \t/]+\\.[a-z]\\{2,\\}\\(?:[:/?#].*\\)?\\'" text) (concat "https://" text))
          (t (concat "https://duckduckgo.com/?q=" (url-hexify-string text))))))

;;;; The pane

(defvar drgnx-browser-mode-map (make-sparse-keymap) "Keys in a browser pane (see Browser: Go to Address…).")

(defun drgnx-browser--url ()
  "The address the page in this buffer shows."
  (or (ignore-errors (xwidget-webkit-uri (xwidget-webkit-current-session))) ""))

(defun drgnx-browser--button (label help action)
  "LABEL as a header-line button that runs ACTION in the pane's buffer on click."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
                (lambda (e)
                  (interactive "e")
                  (with-current-buffer (window-buffer (posn-window (event-start e))) (funcall action))))
    (propertize label 'face 'link 'mouse-face 'highlight 'help-echo help 'keymap map)))

(defun drgnx-browser--go-command () (call-interactively #'drgnx-browser-go))

(defun drgnx-browser--header ()
  "The header line: back, forward, reload and the address (click it, or RET, to go elsewhere)."
  (concat " "
          (drgnx-browser--button "◀" "Back" #'xwidget-webkit-back) " "
          (drgnx-browser--button "▶" "Forward" #'xwidget-webkit-forward) " "
          (drgnx-browser--button "⟳" "Reload" #'xwidget-webkit-reload) "  "
          (drgnx-browser--button (string-replace "%" "%%" (drgnx-browser--url)) "Go to another address (RET)" #'drgnx-browser--go-command)))

(define-minor-mode drgnx-browser-mode
  "The pane's header line (address, back, forward, reload) and RET to go to another address."
  :lighter nil :keymap drgnx-browser-mode-map
  (setq-local header-line-format (and drgnx-browser-mode '(:eval (drgnx-browser--header)))))

(defun drgnx-browser--pane (&optional select)
  "The window of the browser pane: the editor's right-hand group, made when there is none.  SELECT it too."
  (let* ((editor (drgnx-wb-editor-window))
         (pane (or (seq-find (lambda (w) (eq (window-parameter w 'drgnx-layouts-pane) 'browser)) (window-list nil 'nomini))
                   (with-selected-window editor
                     (let ((w (if (fboundp 'drgnx-groups--split) (drgnx-groups--split 'right) (split-window editor nil 'right))))
                       (set-window-parameter w 'drgnx-layouts-pane 'browser)
                       (set-window-parameter w 'drgnx-tabs nil)
                       (set-window-parameter w 'drgnx-tab-history nil)
                       w)))))
    (if select (select-window pane) (when (window-live-p editor) (select-window editor)))
    pane))

(defun drgnx-browser-open (url &optional keep-focus)
  "Show URL in the browser pane beside the editor (WebKit), else in the system browser, saying why once.
The pane takes the focus, unless KEEP-FOCUS (a timer opening a page must not move it)."
  (interactive (list (read-string "URL or search: ")))
  (let ((url (drgnx-browser--normalise url)) (origin (selected-window)))
    (if (not (drgnx-browser-webkit-p))
        (progn
          (unless drgnx-browser--told
            (setq drgnx-browser--told t)
            (message "drgnx: %s" drgnx-browser--no-webkit))
          (browse-url url))
      (let ((pane (drgnx-browser--pane t)))
        (if (buffer-live-p drgnx-browser--buffer)
            (progn (set-window-buffer pane drgnx-browser--buffer)
                   (with-current-buffer drgnx-browser--buffer (xwidget-webkit-goto-url url)))
          (xwidget-webkit-browse-url url))
        ;; the new session's buffer shows in the pane (whichever window the library used)
        (let ((buf (if (and (not (buffer-live-p drgnx-browser--buffer)) (boundp 'xwidget-webkit-last-session-buffer)
                            (buffer-live-p xwidget-webkit-last-session-buffer))
                       xwidget-webkit-last-session-buffer
                     (window-buffer pane))))
          (unless (eq (window-buffer pane) buf) (set-window-buffer pane buf))
          (with-current-buffer buf (drgnx-browser-mode 1))
          (setq drgnx-browser--buffer buf))
        (when (and keep-focus (window-live-p origin)) (select-window origin))))))

(defun drgnx-browser-go (url)
  "Go to another address (or search) in this page."
  (interactive (list (read-string "Go to: " (drgnx-browser--url))))
  (xwidget-webkit-goto-url (drgnx-browser--normalise url)))

;;;; The Browser layout's shape

(defun drgnx-browser--placeholder ()
  "A buffer that says how to open a page here (and why WebKit is missing, when it is)."
  (with-current-buffer (get-buffer-create "*drgnx: browser*")
    (unless (derived-mode-p 'special-mode) (special-mode))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "No page yet — Browser: Open URL… opens one here.\n")
      (unless (drgnx-browser-webkit-p)
        (insert "\nThis Emacs has no WebKit, so pages open in your system browser; see docs/guide/browser.md.\n")))
    (current-buffer)))

(defun drgnx-browser--fill (pane)
  "Show the last page (else a hint) in PANE."
  (set-window-buffer pane (if (buffer-live-p drgnx-browser--buffer) drgnx-browser--buffer (drgnx-browser--placeholder))))

(defun drgnx-browser--shape (editor)
  "The Browser layout's shape: EDITOR with the browser pane to its right (the last page, else a hint)."
  (let ((pane (with-selected-window editor (drgnx-browser--pane))))
    (drgnx-browser--fill pane)
    (select-window editor)
    pane))

(defun drgnx-browser--register-shape ()
  "Teach the layouts the `editor+browser' shape, and how to fill the pane found again after a restart."
  (require 'drgnx-layouts)
  (setf (alist-get 'editor+browser drgnx-layouts-shapes) #'drgnx-browser--shape)
  (setf (alist-get 'browser drgnx-layouts-pane-fillers) #'drgnx-browser--fill))

;;;; Test Report

(defun drgnx-browser--root ()
  (or (when-let* ((p (and (fboundp 'project-current) (project-current)))) (project-root p)) default-directory))

(defun drgnx-browser--candidates (root)
  "Playwright reports (their directory) and traces under ROOT, as (MTIME KIND PATH).
Not into node_modules or dot-directories."
  (let (found)
    (cl-labels ((walk (dir depth)
                  (dolist (f (ignore-errors (directory-files dir t directory-files-no-dot-files-regexp t)))
                    (let ((name (file-name-nondirectory f)))
                      (cond ((file-directory-p f)
                             (when (and (< depth 6) (not (file-symlink-p f)) (not (string-prefix-p "." name)) (not (equal name "node_modules")))
                               (walk f (1+ depth))))
                            ((and (equal name "index.html") (equal (file-name-nondirectory (directory-file-name dir)) "playwright-report"))
                             (push (list (float-time (file-attribute-modification-time (file-attributes f))) 'report (file-name-as-directory dir))
                                   found))
                            ((equal name "trace.zip")
                             (push (list (float-time (file-attribute-modification-time (file-attributes f))) 'trace f) found)))))))
      (walk (expand-file-name root) 0))
    found))

(defun drgnx-browser-newest (root)
  "The newest Playwright report or trace under ROOT: (:kind report|trace :path PATH), or nil."
  (when-let* ((best (car (sort (drgnx-browser--candidates root) (lambda (a b) (> (car a) (car b)))))))
    (list :kind (nth 1 best) :path (nth 2 best))))

(defun drgnx-browser--log-url (text)
  "The address in TEXT, what the Playwright server printed: the URL on its own \"Serving\" or \"Listening\" line, else a
localhost URL; nil when there is none.  Colour codes and carriage returns are ignored."
  (let ((clean (replace-regexp-in-string "\e\\[[0-9;?]*[A-Za-z]\\|\r" "" text)))
    (when (or (string-match "\\(?:Serving\\|Listening\\)[^\n]*?\\(https?://[^ \t\n\e]+\\)" clean)
              (string-match "\\(https?://\\(?:localhost\\|127\\.0\\.0\\.1\\|0\\.0\\.0\\.0\\|\\[::1\\]\\)[^ \t\n\e]*\\)" clean))
      (string-trim-right (match-string 1 clean) "[.,]+"))))

(defun drgnx-browser--stop-job (id)
  "Stop job ID: through the jobs, and its systemd unit too (which the jobs may not see running)."
  (let ((job (drgnx-jobs-get id)))
    (drgnx-jobs-stop id)
    (when-let* ((unit (plist-get job :unit))
                ((not (memq (plist-get job :status) '(exited stopped)))))
      (call-process "systemctl" nil nil nil "--user" "stop" unit))))

(defvar drgnx-browser--watchers nil "Alist job id → the timer waiting for that job's address.")

(defun drgnx-browser--watch-job (id)
  "Open the server URL of job ID in the pane once the job's log has it.
Looked at every half second, 60 s at most; never waits."
  (let ((timer nil) (tries 0))
    (when-let* ((old (assoc id drgnx-browser--watchers))) (cancel-timer (cdr old)))
    (setq timer
          (run-with-timer
           0.5 0.5
           (lambda ()
             (let ((url (ignore-errors (drgnx-browser--log-url (drgnx-jobs-log id 4000))))
                   (status (plist-get (drgnx-jobs-get id) :status)))
               (cond (url (cancel-timer timer) (drgnx-browser-open url t))
                     ;; `gone' can be a job systemd runs, so only the clock or an ended job ends the wait
                     ((or (> (cl-incf tries) 120) (memq status '(exited stopped)))
                      (cancel-timer timer)
                      (when (> tries 120) (drgnx-browser--stop-job id))
                      (message "drgnx: the Playwright server did not print an address (Show Job Log: playwright)")))))))
    (setf (alist-get id drgnx-browser--watchers nil nil #'equal) timer)))

(defun drgnx-browser--stop-others (keep root)
  "Stop the Playwright servers of ROOT other than job KEEP (a new report replaces the older servers)."
  (let ((dir (file-name-as-directory (expand-file-name root))))
    (dolist (j (drgnx-jobs-list))
      (when (and (equal (plist-get j :name) "playwright") (not (equal (plist-get j :id) keep))
                 (equal (file-name-as-directory (expand-file-name (or (plist-get j :cwd) ""))) dir)
                 (not (memq (plist-get j :status) '(exited stopped))))
        (when-let* ((w (assoc (plist-get j :id) drgnx-browser--watchers))) (cancel-timer (cdr w)))
        (drgnx-browser--stop-job (plist-get j :id))))))

(defun drgnx-browser-test-report ()
  "Open the newest Playwright HTML report (or trace) of this project in the browser pane."
  (interactive)
  (let* ((root (drgnx-browser--root)) (found (drgnx-browser-newest root)))
    (cond ((not (executable-find "npx"))
           (message "drgnx: Test Report needs npx (Node.js); it is not installed"))
          ((not found)
           (message "drgnx: No Playwright report or trace under %s — run npx playwright test first" (abbreviate-file-name root)))
          (t
           (require 'drgnx-jobs)
           (let* ((report (eq (plist-get found :kind) 'report))
                  (command (list "npx" "playwright" (if report "show-report" "show-trace")
                                 (if report (directory-file-name (plist-get found :path)) (plist-get found :path))
                                 "--port" "0"))
                  (running (seq-find (lambda (j) (and (eq (plist-get j :status) 'running) (equal (plist-get j :command) command)))
                                     (drgnx-jobs-list)))
                  (id (if running (plist-get running :id)
                        (drgnx-jobs-start "playwright" command :cwd root :memory-max "1G" :no-wait t))))
             (drgnx-browser--stop-others id root)
             (message "Test Report: serving %s…" (abbreviate-file-name (plist-get found :path)))
             (drgnx-browser--watch-job id))))))

;;;; Agent's Page

(defun drgnx-browser--tools (entries)
  "Every tool call in ENTRIES, in order, sub-agents' calls included."
  (let (out)
    (cl-labels ((walk (es) (dolist (e es)
                             (when (eq (plist-get e :type) 'tool) (push e out))
                             (walk (plist-get e :children)))))
      (walk entries))
    (nreverse out)))

(defun drgnx-browser-agent-url (session)
  "The last URL in SESSION's Playwright tool calls (their :url, taken from the raw input), or nil."
  (let (url)
    (dolist (e (drgnx-browser--tools (drgnx-agent-session-entries session)))
      (when-let* ((u (or (plist-get e :url) (plist-get (plist-get e :rawInput) :url)))
                  ((stringp u))
                  ((string-match-p "playwright\\|browser_\\|navigate" (downcase (or (plist-get e :title) "")))))
        (setq url u)))
    url))

(defun drgnx-browser--image (content)
  "The (DATA . MIME) of the first image in a tool call's CONTENT list, or nil."
  (seq-some (lambda (c)
              (let ((c (if (equal (plist-get c :type) "content") (plist-get c :content) c)))
                (when (and (equal (plist-get c :type) "image") (stringp (plist-get c :data)))
                  (cons (plist-get c :data) (or (plist-get c :mimeType) "image/png")))))
            (append content nil)))

(defun drgnx-browser-agent-screenshot (session)
  "The latest image in SESSION's tool results as (DATA . MIME), base64 DATA, or nil."
  (let (shot)
    (dolist (e (drgnx-browser--tools (drgnx-agent-session-entries session)))
      (when-let* ((img (drgnx-browser--image (plist-get e :content)))) (setq shot img)))
    shot))

(defun drgnx-browser--show-screenshot (session shot)
  "Show SHOT (DATA . MIME) of SESSION in the side buffer, beside the pane."
  (let* ((type (if (string-match-p "jpe?g" (cdr shot)) 'jpeg 'png))
         (image (ignore-errors (create-image (base64-decode-string (car shot)) type t))))
    (with-current-buffer (get-buffer-create "*drgnx: agent screenshot*")
      (unless (derived-mode-p 'special-mode) (special-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s — latest screenshot\n\n" (drgnx-agent-session-name session)) 'face 'bold))
        (if image
            (insert (propertize " " 'display image 'drgnx-browser-image t) "\n")
          (insert "This Emacs cannot show the image.\n")))
      (display-buffer (current-buffer) '((display-buffer-reuse-window display-buffer-below-selected) (window-height . 0.4))))))

(defun drgnx-browser-agent-page (&optional session)
  "Open the page SESSION's Playwright tool calls are on (the selected agent's), with its latest screenshot beside it."
  (interactive)
  (let* ((session (or session (drgnx-agents-ui--session "Agent: ")))
         (url (drgnx-browser-agent-url session)))
    (if (not url)
        (message "drgnx: %s has not opened a page yet (no Playwright navigation in its tool calls)" (drgnx-agent-session-name session))
      (drgnx-browser-open url)
      (when-let* ((shot (drgnx-browser-agent-screenshot session)))
        (drgnx-browser--show-screenshot session shot)))))

;;;; Module

(defun drgnx-browser--define-commands ()
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((browser-open "Open URL…" drgnx-browser-open "A web page (or a search) in the pane beside the editor")
                   (browser-test-report "Test Report" drgnx-browser-test-report "The newest Playwright report or trace of this project")
                   (browser-agent-page "Agent's Page" drgnx-browser-agent-page "The page the agent's Playwright session is on, with its screenshot")
                   (browser-go "Go to Address…" drgnx-browser-go "Another address or search in this page")))
    (drgnx-command-define id :category "Browser" :title title :command fn :doc doc :scope 'window
                          :map (and (eq id 'browser-go) '(drgnx-browser . drgnx-browser-mode-map))
                          :when (and (eq id 'browser-go) (lambda () (bound-and-true-p drgnx-browser-mode))))))

(drgnx-module-define 'tools/browser
                     :doc "A web page pane beside the editor (WebKit), Test Report and Agent's Page."
                     :stage 'idle :requires '(core/workbench tools/layouts tools/agents)
                     :setup
                     (lambda ()
                       (require 'drgnx-groups)
                       (drgnx-browser--register-shape)
                       (drgnx-browser--define-commands)))

(provide 'drgnx-browser)
;;; drgnx-browser.el ends here
