;;; search-setup-test.el --- batch tests: Set Up Semantic Search, the wizard of the built-in model and servers -*- lexical-binding: t -*-
;; test-class: det
;; The hub is the seam: its answers are the stub's, the questions the wizard asks are `y-or-n-p's the test answers.
;; Everything is synchronous (no timer, process or wait), so the tests are pure.
;; (The model the wizard downloads is the table's default, 95 MB, which no test fetches.)
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(require 'drgnx-ai)
(require 'drgnx-settings-defaults)
(require 'drgnx-settings-runtime)
(require 'drgnx-search-setup)
(load (expand-file-name "modules/tools/drgnx-search" drgnx-dir) nil t)

(defconst drgnx-search-setup-test--model "granite-embedding-small-english-r2")
(defconst drgnx-search-setup-test--bytes 100663296 "96 MB.")

(defun drgnx-search-setup-test--embedders (&rest kv)
  "What `search/embedders' answers with the built-in model missing, changed by KV (keys of the answer)."
  (append kv (list :builtin (list :model drgnx-search-setup-test--model :state "missing"
                                  :bytes drgnx-search-setup-test--bytes :downloaded 0)
                   :servers nil)))

(defun drgnx-search-setup-test--ready ()
  (drgnx-search-setup-test--embedders
   :builtin (list :model drgnx-search-setup-test--model :state "ready" :bytes drgnx-search-setup-test--bytes
                  :downloaded drgnx-search-setup-test--bytes :device '(:kind "gpu" :name "AMD Radeon RX 7900"))))

(defconst drgnx-search-setup-test--tei-plan
  '(:available t :gpu nil :memory_cap "4g" :model "BAAI/bge-small-en-v1.5"
               :commands ("systemctl --user start drgnx-tei.service")))

(defvar drgnx-search-setup-test--calls nil "Hub calls, newest first: (METHOD . PARAMS).")
(defvar drgnx-search-setup-test--asked nil "The prompts of `y-or-n-p', newest first.")
(defvar drgnx-search-setup-test--saved nil "(SETTING . VALUE) of `drgnx-settings-defaults-save', newest first.")
(defvar drgnx-search-setup-test--told nil "How often the hub was told `config/changed'.")

(defmacro drgnx-search-setup-test--with (replies answers &rest body)
  "BODY in a frame-ful interactive Emacs whose hub answers REPLIES ((METHOD . RESULT)…) and whose `y-or-n-p' answers
ANSWERS (a list, one per question, nil past its end)."
  (declare (indent 2))
  `(let ((drgnx-search-setup-test--calls nil) (drgnx-search-setup-test--asked nil)
         (drgnx-search-setup-test--saved nil) (drgnx-search-setup-test--told 0)
         (answers ,answers) (noninteractive nil))
     (cl-letf (((symbol-function 'drgnx-hub-ensure)
                (lambda () (push '("ensure") drgnx-search-setup-test--calls) t))
               ((symbol-function 'drgnx-hub-running-p) (lambda () t))
               ((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &optional _timeout)
                  (push (cons method params) drgnx-search-setup-test--calls)
                  (cdr (assoc method ,replies))))
               ((symbol-function 'y-or-n-p)
                (lambda (prompt) (push prompt drgnx-search-setup-test--asked) (pop answers)))
               ((symbol-function 'drgnx-settings-defaults-save)
                (lambda (setting value) (push (cons setting value) drgnx-search-setup-test--saved)))
               ((symbol-function 'drgnx-settings-runtime-changed) (lambda () (cl-incf drgnx-search-setup-test--told)))
               ((symbol-function 'frame-list) (lambda () (list (selected-frame))))
               ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
       ,@body)))

(defun drgnx-search-setup-test--methods ()
  "The methods the hub was called with, oldest first."
  (mapcar #'car (reverse drgnx-search-setup-test--calls)))

(ert-deftest drgnx-search-setup/daemon-never-asks ()
  ;; batch, a daemon with no frame, and a call that is not a command: no question, no hub call, how to run it
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--embedders))) '(t t t)
    (let ((noninteractive t))
      (should (equal (drgnx-search-setup "/p" :interactive t) (list 'info drgnx-search-setup-guard-text))))
    (cl-letf (((symbol-function 'daemonp) (lambda () t))
              ((symbol-function 'frame-list) (lambda () nil)))
      (should (equal (drgnx-search-setup "/p" :interactive t) (list 'info drgnx-search-setup-guard-text))))
    (should (equal (drgnx-search-setup "/p") (list 'info drgnx-search-setup-guard-text)))   ; not a command
    (should-not drgnx-search-setup-test--asked)
    (should-not drgnx-search-setup-test--calls)
    (should (string-match-p "in a frame to download a model or start a server" drgnx-search-setup-guard-text))))

(ert-deftest drgnx-search-setup/detect-changes-nothing ()
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--embedders))) '(t t t)
    (let ((r (drgnx-search-setup-detect)))
      (should (eq (car r) 'info))
      (should (string-match-p "built-in model granite-embedding-small-english-r2 not downloaded (96 MB)" (cadr r)))
      (should (string-match-p "no server" (cadr r))))
    (should (equal (drgnx-search-setup-test--methods) '("search/embedders")))   ; it neither started the hub nor asked
    (should-not drgnx-search-setup-test--asked)
    (should-not drgnx-search-setup-test--saved))
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))) nil
    (should (eq (car (drgnx-search-setup-detect)) 'ok))
    (cl-letf (((symbol-function 'drgnx-hub-running-p) (lambda () nil)))
      (should (eq (car (drgnx-search-setup-detect)) 'info))
      (should (equal (drgnx-search-setup-test--methods) '("search/embedders"))))))      ; no second call: no hub

(ert-deftest drgnx-search-setup/decline-downloads-nothing ()
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--embedders))
                                   ("search/server-plan" . (:available nil :why "no podman"))
                                   ("search/index" . (:started t)))
      nil
    (let ((r (drgnx-search-setup "/p" :interactive t)))
      (should (eq (car r) 'info))
      (should (string-match-p "keyword and symbol search only" (cadr r))))
    (should-not (member "search/model-download" (drgnx-search-setup-test--methods)))
    (should (= (length drgnx-search-setup-test--asked) 1))))

(ert-deftest drgnx-search-setup/consent-states-size ()
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--embedders))
                                   ("search/server-plan" . (:available nil))
                                   ("search/model-download" . (:started t))
                                   ("search/index" . (:started t)))
      '(t)
    (drgnx-search-setup "/p" :interactive t)
    (let ((prompt (car (last drgnx-search-setup-test--asked))))
      (should (string-match-p (regexp-quote "Download granite-embedding-small-english-r2 (96 MB) for semantic search?") prompt))
      (should (string-match-p "on this machine, on the GPU when one is fast enough" prompt)))
    (let ((call (assoc "search/model-download" drgnx-search-setup-test--calls)))
      (should (equal (plist-get (cdr call) :model) drgnx-search-setup-test--model))
      (should (equal (plist-get (cdr call) :consent) (list :bytes drgnx-search-setup-test--bytes))))))

(ert-deftest drgnx-search-setup/server-offered-only-when-available ()
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))
                                   ("search/server-plan" . (:available nil :why "podman is not installed"))
                                   ("search/index" . (:started t)))
      '(t t)
    (drgnx-search-setup "/p" :interactive t)
    (should-not drgnx-search-setup-test--asked)                      ; ready model, no server possible: nothing to ask
    (should-not (member "search/server-start" (drgnx-search-setup-test--methods))))
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))
                                   ("search/server-plan" . ,drgnx-search-setup-test--tei-plan)
                                   ("search/index" . (:started t)))
      '(nil)
    (drgnx-search-setup "/p" :interactive t)
    (should (= (length drgnx-search-setup-test--asked) 1))
    (let ((prompt (car drgnx-search-setup-test--asked)))
      (should (string-match-p "systemctl --user start drgnx-tei.service" prompt))
      (should (string-match-p "Memory cap 4g" prompt))))
  ;; a server that already answers is not offered another
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))
                                   ("search/index" . (:started t)))
      '(t)
    (let ((e (drgnx-search-setup-test--ready)))
      (setq e (plist-put e :servers '((:kind "tei" :url "http://127.0.0.1:8087" :model "tei:local" :answering t))))
      (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                 (lambda (method &rest _) (push (list method) drgnx-search-setup-test--calls)
                   (and (equal method "search/embedders") e))))
        (drgnx-search-setup "/p" :interactive t)))
    (should-not (member "search/server-plan" (drgnx-search-setup-test--methods)))))

(ert-deftest drgnx-search-setup/decline-server-starts-nothing ()
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))
                                   ("search/server-plan" . ,drgnx-search-setup-test--tei-plan)
                                   ("search/index" . (:started t)))
      '(nil)
    (let ((r (drgnx-search-setup "/p" :interactive t)))
      (should (string-match-p "no server started" (cadr r))))
    (should-not (member "search/server-start" (drgnx-search-setup-test--methods)))
    (should-not drgnx-search-setup-test--saved)
    (should (= drgnx-search-setup-test--told 0))))

(ert-deftest drgnx-search-setup/started-server-lands-in-settings ()
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))
                                   ("search/server-plan" . ,drgnx-search-setup-test--tei-plan)
                                   ("search/server-start" . (:started t :unit "drgnx-tei.service"
                                                                      :provider (:id "tei-local" :kind "tei" :base "http://127.0.0.1:8087"
                                                                                     :auth "none" :caps ("embed"))))
                                   ("search/index" . (:started t)))
      '(t)
    (let ((r (drgnx-search-setup "/p" :interactive t)))
      (should (string-match-p "started tei" (cadr r))))
    (let ((call (assoc "search/server-start" drgnx-search-setup-test--calls)))
      (should (equal (cdr call) '(:kind "tei" :confirm t))))             ; confirmed, after the plan was shown
    (let* ((saved (assq 'drgnx-ai-providers drgnx-search-setup-test--saved))
           (entry (assq 'tei-local (cdr saved))))
      (should entry)
      (should (eq (plist-get (cdr entry) :kind) 'tei))
      (should (equal (plist-get (cdr entry) :url) "http://127.0.0.1:8087"))
      (should (equal (plist-get (cdr entry) :caps) '(embed))))
    (should (= drgnx-search-setup-test--told 1))))                      ; `config/changed'

(ert-deftest drgnx-search-setup/route-confirmed-once-per-root ()
  ;; The wizard never asks about a project's remote route itself: the command does, for the one project it runs in,
  ;; once, and never for several projects in one go.
  (let (asked (current nil))
    (cl-letf (((symbol-function 'drgnx-ai-confirm-project-route)
               (lambda () (push (file-truename default-directory) asked) t))
              ((symbol-function 'drgnx-search-setup) (lambda (&rest _) (list 'ok "fine")))
              ((symbol-function 'drgnx-search-setup--current-root) (lambda () current))
              ((symbol-function 'message) #'ignore))
      (dolist (dir (list (make-temp-file "drgnx-setup-a" t) (make-temp-file "drgnx-setup-b" t)))
        (setq current (directory-file-name dir) asked nil)
        (drgnx-search-set-up)
        (should (equal asked (list (file-truename (file-name-as-directory dir)))))
        (delete-directory dir t))))
  (let (asked)
    (cl-letf (((symbol-function 'drgnx-ai-confirm-project-route) (lambda () (push t asked))))
      (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))
                                       ("search/server-plan" . (:available nil))
                                       ("search/index" . (:started t)))
          nil
        (drgnx-search-setup "/p" :interactive t)
        (should-not asked)))))                                  ; the wizard itself never asks it

(ert-deftest drgnx-search-setup/indexes-after-consent ()
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--embedders))
                                   ("search/server-plan" . (:available nil))
                                   ("search/model-download" . (:started t))
                                   ("search/status" . (:files 3 :chunks 0 :models nil :lag (:chunks_behind 0)))
                                   ("search/index" . (:started t)))
      '(t)
    (let ((r (drgnx-search-setup "/p" :interactive t)))
      (should (string-match-p "is being indexed in the background" (cadr r))))
    (should (equal (drgnx-search-setup-test--methods)
                   '("ensure" "search/embedders" "search/model-download" "search/server-plan" "search/server-plan"
                     "search/status" "search/index")))
    (should (equal (plist-get (cdr (assoc "search/index" drgnx-search-setup-test--calls)) :root) "/p")))
  ;; a current index gets the test query instead
  (drgnx-search-setup-test--with `(("search/embedders" . ,(drgnx-search-setup-test--ready))
                                   ("search/server-plan" . (:available nil))
                                   ("search/status" . (:files 3 :chunks 40 :models ((:model "m" :vectors 40))
                                                              :lag (:chunks_behind 0)))
                                   ("search/query" . (:hits ((:path "core/a.el" :line_start 7)))))
      nil
    (let ((r (drgnx-search-setup "/p" :interactive t)))
      (should (string-match-p "test query \"where does the program start\": core/a.el:7" (cadr r))))
    (should-not (member "search/index" (drgnx-search-setup-test--methods)))))

(ert-deftest drgnx-search-setup/the-command-has-a-key-entry-in-every-profile ()
  (should (commandp 'drgnx-search-set-up))
  (dolist (profile '("vscode" "emacs" "vim"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
      (should (search-forward "(search-set-up :none \"in the palette\")" nil t)))))

(provide 'search-setup-test)
;;; search-setup-test.el ends here
