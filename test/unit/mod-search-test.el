;;; mod-search-test.el --- batch tests: Semantic Search commands, which ask the hub (Hrafn) and only render -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(require 'drgnx-ai)                       ; loaded now: a command's `require' would replace a stubbed function
(require 'drgnx-search-setup)
(require 'project)
(require 'xref)                         ; loaded now: Repo Map's and Find Usages' `require' would replace the stub
(load (expand-file-name "modules/tools/drgnx-search" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)

(defun drgnx-search-test--hit (&rest kv)
  "A hit of `search/query', changed by KV."
  (append kv (list :path "a.el" :line_start 3 :line_end 5 :symbol "alpha" :score 0.03
                   :preview "(defun alpha ()\n  1)" :routes '("symbol") :reanchored nil)))

(defun drgnx-search-test--answer (&rest kv)
  "An answer of `search/query' with one hit, a model and a lag line, changed by KV."
  (append kv (list :hits (list (drgnx-search-test--hit)) :model "granite-embedding-small-english-r2"
                   :lag '(:chunks_total 40 :chunks_behind 3 :files_behind 12 :dirty_files 0 :built_from "abc")
                   :lag_line "vectors: 12 files behind (3 chunks); keyword and symbol results are current")))

(defvar drgnx-search-test--calls nil "The hub calls the stub got, newest first: (METHOD . PARAMS).")

(defmacro drgnx-search-test--with-stub-hub (replies &rest body)
  "BODY with the hub's `drgnx-hub-call' answering from REPLIES ((METHOD . RESULT)…) at once, and every call recorded
in `drgnx-search-test--calls'.  `message' is collected in MESSAGES.  A project ROOT (a git repository) is the current
directory."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-search-proj" t)))
          (default-directory root) (drgnx-search-test--calls nil) (messages nil))
     (unwind-protect
         (progn
           (call-process "git" nil nil nil "init" "-q")
           (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () t))
                     ((symbol-function 'drgnx-hub-call)
                      (lambda (method params callback &rest _)
                        (push (cons method params) drgnx-search-test--calls)
                        (funcall callback (cdr (assoc method ,replies)) nil)
                        1))
                     ((symbol-function 'drgnx-ai-confirm-project-route) (lambda () t))
                     ((symbol-function 'message) (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)))))
             ,@body))
       (delete-directory root t))))

(defmacro drgnx-search-test--with-xref (&rest body)
  "BODY with `xref-show-xrefs' recording the items it was given in ITEMS, in a buffer `*xref*' it makes."
  (declare (indent 0))
  `(let ((items nil))
     (cl-letf (((symbol-function 'xref-show-xrefs)
                (lambda (fetcher _alist)
                  (setq items (funcall fetcher))
                  (with-current-buffer (get-buffer-create "*xref*") (setq header-line-format nil))))
               ((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
       (unwind-protect (progn ,@body) (when (get-buffer "*xref*") (kill-buffer "*xref*"))))))

;;;; The real hub

(defmacro drgnx-search-test--with-hub (&rest body)
  "BODY with the real hub (Ratatoskr from DRGNX_RATATOSKR_BIN) serving a temporary data dir, this Emacs connected, and
ROOT a git project with one file.  Skipped without the binary (test/no-skip.eld lists the tests)."
  (declare (indent 0))
  `(let* ((top (file-name-as-directory (make-temp-file "drgnx-search-hub" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" top "config") (concat "DRGNX_DATA_DIR=" top "data")
                                             (concat "XDG_STATE_HOME=" top "state") (concat "XDG_DATA_HOME=" top "xdg-data")
                                             (concat "XDG_CONFIG_HOME=" top "xdg-config") (concat "XDG_CACHE_HOME=" top "cache")
                                             (concat "HOME=" top "home") "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment))
          (root (file-name-as-directory (concat top "proj"))))
     (dolist (d '("run" "home" "config" "data" "state" "proj")) (with-file-modes #o700 (make-directory (concat top d) t)))
     (unwind-protect
         (let ((default-directory root))
           (call-process "git" nil nil nil "init" "-q")
           (write-region "(defun drgnx-search-test-alpha ()\n  \"Alpha.\"\n  1)\n" nil (concat root "a.el") nil 'silent)
           (drgnx-test-with-ratatoskr top ,@body))
       (delete-directory top t))))

(ert-deftest drgnx-search/semantic-goes-through-hub ()
  ;; The real hub answers keyword and symbol results at once, whatever the model: the first query of a fresh install.
  (drgnx-search-test--with-hub
    (let (result why (done nil))
      (drgnx-search--ask "search/query" (list :root (directory-file-name root) :text "drgnx-search-test-alpha" :scope "code" :k 5)
                         (lambda (r w) (setq result r why w done t)))
      (drgnx-test-wait (lambda () done) :secs 60 :what "the hub's answer to search/query")
      (should-not why)
      (let ((hit (car (plist-get result :hits))))
        (should (equal (plist-get hit :path) "a.el"))
        (should (equal (plist-get hit :symbol) "drgnx-search-test-alpha"))
        (should (= (plist-get hit :line_start) 1)))
      (should (stringp (plist-get result :lag_line)))
      (should-not (plist-get result :model)))))

;;;; Commands

(ert-deftest drgnx-search/semantic-asks-the-hub-for-the-project-and-shows-the-hits ()
  (drgnx-search-test--with-stub-hub `(("search/query" . ,(drgnx-search-test--answer)))
    (drgnx-search-test--with-xref
      (let ((window (selected-window)))
        (ignore window)
        (drgnx-search-semantic "alpha")
        (let ((call (car drgnx-search-test--calls)))
          (should (equal (car call) "search/query"))
          (should (equal (plist-get (cdr call) :root) (directory-file-name root)))
          (should (equal (plist-get (cdr call) :text) "alpha")))
        (should (= (length items) 1))
        (let ((item (car items)))
          (should (equal (xref-item-summary item) "(defun alpha ()"))
          (should (equal (xref-location-line (xref-item-location item)) 3)))))))

(ert-deftest drgnx-search/lag-line-shown ()
  (drgnx-search-test--with-stub-hub `(("search/query" . ,(drgnx-search-test--answer)))
    (drgnx-search-test--with-xref
      (drgnx-search-semantic "alpha")
      (let ((header (buffer-local-value 'header-line-format (get-buffer "*xref*"))))
        (should (string-match-p "model granite-embedding-small-english-r2" header))
        (should (string-match-p "vectors: 12 files behind" header)))
      (should (seq-some (lambda (m) (string-match-p "vectors: 12 files behind" m)) messages)))))

(ert-deftest drgnx-search/no-model-says-keyword-only ()
  (drgnx-search-test--with-stub-hub `(("search/query" . ,(drgnx-search-test--answer
                                                          :model nil :notice "built-in model not downloaded"
                                                          :lag_line "vectors: not used")))
    (drgnx-search-test--with-xref
      (drgnx-search-semantic "alpha")
      (let ((header (buffer-local-value 'header-line-format (get-buffer "*xref*"))))
        (should (string-match-p "keyword and symbol results only (built-in model not downloaded)" header))))))

(ert-deftest drgnx-search/no-hub-says-why ()
  (drgnx-search-test--with-stub-hub nil
    (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () (error "Ratatoskr is not built: run `drgnx runtime build'"))))
      (drgnx-search-semantic "alpha")
      (should (seq-some (lambda (m) (string-match-p "Semantic search: the drgnx hub is not available (Ratatoskr is not built" m))
                        messages))
      (should-not drgnx-search-test--calls))))

(ert-deftest drgnx-search/index-project-asks-the-hub-and-rebuild-is-the-prefix ()
  (drgnx-search-test--with-stub-hub '(("search/index" . (:started t)))
    (drgnx-search-index-project)
    (should (eq (plist-get (cdr (car drgnx-search-test--calls)) :rebuild) :false))
    (drgnx-search-index-project t)
    (should (eq (plist-get (cdr (car drgnx-search-test--calls)) :rebuild) t))
    (should (seq-some (lambda (m) (string-match-p "Indexing .* in the background" m)) messages))))

(ert-deftest drgnx-search/index-status-says-models-device-and-lag ()
  (drgnx-search-test--with-stub-hub
      '(("search/status" . (:files 9 :chunks 120 :coverage_errors nil
                                   :lag (:chunks_behind 3 :files_behind 1)
                                   :models ((:model "granite-embedding-small-english-r2" :vectors 117))
                                   :worker (:device (:kind "gpu" :name "AMD Radeon RX 7900")
                                                    :fallback "the GPU was lost")
                                   :tier2 "running" :embedded 4)))
    (drgnx-search-index-status)
    (let ((line (car messages)))
      (should (string-match-p "120 chunks in 9 files" line))
      (should (string-match-p "vectors: granite-embedding-small-english-r2 (117)" line))
      (should (string-match-p "device: GPU AMD Radeon RX 7900 (fell back to the CPU: the GPU was lost)" line))
      (should (string-match-p "tier 2 running" line))
      (should (string-match-p "behind: 3 chunks in 1 file" line)))))

(ert-deftest drgnx-search/commands-ask-about-a-projects-remote-route-first ()
  ;; The project's .drgnx/ai.eld may route the embed role to a remote provider; the user is asked once per project root,
  ;; in the command they ran, with the project as the current directory (never later, from a timer or in batch).
  (drgnx-search-test--with-stub-hub `(("search/query" . ,(drgnx-search-test--answer)) ("search/index" . (:started t)))
    (let (asked)
      (cl-letf (((symbol-function 'drgnx-ai-confirm-project-route)
                 (lambda () (push (file-truename default-directory) asked) t))
                ((symbol-function 'drgnx-search-setup) (lambda (&rest _) (list 'ok "fine"))))
        (let ((default-directory (file-name-as-directory (expand-file-name "sub" root))))
          (make-directory default-directory t)
          (drgnx-search-test--with-xref
            (dolist (cmd '(drgnx-search-semantic drgnx-search-index-project drgnx-search-set-up))
              (setq asked nil)
              (if (eq cmd 'drgnx-search-semantic) (funcall cmd "alpha") (funcall cmd))
              (should (equal asked (list (file-truename root)))))))))))      ; once, with the project root

;;;; The retriever

(ert-deftest drgnx-search/retriever-gives-snippets ()
  (drgnx-search-test--with-stub-hub `(("search/query" . ,(drgnx-search-test--answer)))
    (let (got)
      (drgnx-search--retriever "alpha" root (lambda (s) (push s got)))
      (should (= (length got) 1))
      (should (equal (car got) '((:file "a.el" :line 3 :text "(defun alpha ()\n  1)"))))
      (should (equal (plist-get (cdr (car drgnx-search-test--calls)) :k) 5)))))

(ert-deftest drgnx-search/retriever-gives-nil-without-a-hub-and-never-starts-one ()
  (let (got (ensured nil))
    (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () (setq ensured t)))
              ((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "no hub"))))
      (drgnx-search--retriever "alpha" "/p/" (lambda (s) (push (list s) got)))
      (should (equal got '((nil))))
      (should-not ensured))))

;;;; The keystroke signal

(ert-deftest drgnx-search/typing-is-sent-throttled ()
  ;; test-pattern: gate (the virtual clock moves it)
  (let (calls)
    (drgnx-test-with-clock ()
      (drgnx-test-with-modules '(tools/search)
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method _params _callback &rest _) (push method calls) 1)))
          (dotimes (_ 5) (drgnx-tools/search--typing))        ; five commands: a flag, no call
          (should-not calls)
          (drgnx-test-advance 2.1)
          (should (equal calls '("search/typing")))             ; one call for the burst
          (drgnx-test-advance 2.1)
          (should (= (length calls) 1))                         ; nothing typed since: nothing sent
          (drgnx-tools/search--typing)
          (drgnx-test-advance 2.1)
          (should (= (length calls) 2)))))))

(ert-deftest drgnx-search/typing-never-signals-without-a-hub ()
  (let ((drgnx-search--typed t))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "no hub"))))
      (should-not (drgnx-search--send-typing))
      (should-not drgnx-search--typed))))

(ert-deftest drgnx-search/typing-hook-goes-at-teardown ()
  (drgnx-test-with-modules '(tools/search) :strict t
                           (should (memq 'drgnx-tools/search--typing post-command-hook))
                           (should (drgnx-timer-active-p 'search-typing)))
  (should-not (memq 'drgnx-tools/search--typing post-command-hook))
  (should-not (drgnx-timer-active-p 'search-typing)))

;;;; The command line

(ert-deftest drgnx-search/bin-search-goes-to-ratatoskr ()
  ;; `drgnx search …' execs Ratatoskr's `search' with the same arguments; a stand-in for it records them.
  (skip-unless (executable-find "bash"))
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-search-bin" t)))
         (stub (concat dir "ratatoskr")) (log (concat dir "args"))
         (process-environment (append (list (concat "DRGNX_RATATOSKR_BIN=" stub) (concat "STUB_LOG=" log)
                                            (concat "DRGNX_DATA_DIR=" dir "data") (concat "HOME=" dir "home"))
                                      process-environment)))
    (unwind-protect
        (progn
          (with-temp-file stub (insert "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$STUB_LOG\"\n"))
          (set-file-modes stub #o755)
          (should (= 0 (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil nil nil
                                     "search" "query" "/r" "where" "is" "it" "-k" "3")))
          (should (equal (with-temp-buffer (insert-file-contents log) (split-string (buffer-string) "\n" t))
                         '("search" "query" "/r" "where" "is" "it" "-k" "3")))
          (should (= 2 (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil nil nil "search" "nonsense"))))
      (delete-directory dir t))))

;;;; Rendering

(ert-deftest drgnx-search/main-thread-render ()
  :tags '(:timing)                                      ; wall-clock budget: the :timing group runs alone
  ;; Showing a 10-hit answer is render only: the median of 20 renders stays under one frame (16 ms).
  (drgnx-search-test--with-xref
    (let ((answer (drgnx-search-test--answer :hits (cl-loop for i from 1 to 10 collect (drgnx-search-test--hit :line_start i))))
          (samples nil))
      (dotimes (_ 20)
        (let ((start (float-time)))
          (drgnx-search--show "/p/" "alpha" answer)
          (push (- (float-time) start) samples)))
      (should (<= (nth 10 (sort samples #'<)) 0.016)))))

;;;; Show in Search View

(ert-deftest drgnx-search/the-list-shows-in-the-search-view ()
  "Pattern D: the Semantic Search list's header line has Show in Search view; the command asks the same question in
the Search view, Meaning mode, in the list's project."
  (drgnx-search-test--with-xref
    (let ((answer (drgnx-search-test--answer :hits (list (drgnx-search-test--hit :line_start 1)))) (opened nil))
      (drgnx-search--show "/p/" "where is alpha" answer)
      (with-current-buffer "*xref*"
        (should (string-match-p "Show in Search view" (format "%s" header-line-format)))
        (should (equal drgnx-search--question '("/p/" . "where is alpha"))))
      (cl-letf (((symbol-function 'drgnx-replace--open) (lambda (&rest args) (setq opened args))))
        (drgnx-search-show-in-view))
      (should (equal opened '(:text "where is alpha" :mode meaning :root "/p/"))))))

;;;; Repo Map and Find Usages (search/map, search/usages)

(defconst drgnx-search-test--map
  (list :text "b.el\n  beta\na.el\n  alpha\n2 files, 2 shown, ~9 tokens" :tokens 9 :files_total 2
        :fresh '(:files_pending 0 :view "checkout")
        :files (list (list :path "b.el" :rank 0.7
                           :defs (list (list :name "beta" :kind "function" :line_start 4 :line_end 6
                                             :sig "(defun beta ()" :depth 0)))
                     (list :path "a.el" :rank 0.3
                           :defs (list (list :name "alpha" :kind "function" :line_start 1 :line_end 3
                                             :sig "(defun alpha ()" :depth 0)))))
  "An answer of `search/map': b.el ranks over a.el.")

(defconst drgnx-search-test--usages
  (list :fresh '(:files_pending 2 :view "checkout")
        :defined (list (list :path "a.el" :name "alpha" :kind "function" :line_start 1 :line_end 3
                             :sig "(defun alpha ()" :class "code"))
        :usages (list (list :path "b.el" :line 5 :lines [5 9] :n 2 :enclosing "beta" :rank 0.9)))
  "An answer of `search/usages' for alpha: defined in a.el, used twice in b.el (inside beta).")

(ert-deftest drgnx-search/repo-map-lists-the-ranked-files-and-their-definitions ()
  "Pattern D: Repo Map asks `search/map' for the project, centred on the current file, and lists each file's
definitions in the map's order (the Results tab groups them by file); the header says the counts."
  (drgnx-search-test--with-stub-hub `(("search/map" . ,drgnx-search-test--map))
    (drgnx-search-test--with-xref
      (with-current-buffer (find-file-noselect (expand-file-name "c.el" root))
        (unwind-protect
            (progn
              (drgnx-search-repo-map)
              (let ((call (car drgnx-search-test--calls)))
                (should (equal (car call) "search/map"))
                (should (equal (plist-get (cdr call) :root) (directory-file-name root)))
                (should (equal (plist-get (cdr call) :focus) ["c.el"])))
              (should (equal (mapcar (lambda (i) (list (file-name-nondirectory
                                                        (xref-file-location-file (xref-item-location i)))
                                                       (xref-location-line (xref-item-location i))
                                                       (xref-item-summary i)))
                                     items)
                             '(("b.el" 4 "function beta  (defun beta ()") ("a.el" 1 "function alpha  (defun alpha ()"))))
              (should (string-match-p "2 files, 2 shown"
                                      (buffer-local-value 'header-line-format (get-buffer "*xref*")))))
          (kill-buffer))))))

(ert-deftest drgnx-search/find-usages-lists-the-definition-then-each-use ()
  "Pattern D: Find Usages asks `search/usages' for the name at point; the definition comes first, then every line a
file uses it on, under the definition that holds it; what is still being indexed is said."
  (drgnx-search-test--with-stub-hub `(("search/usages" . ,drgnx-search-test--usages))
    (drgnx-search-test--with-xref
      (drgnx-search-usages "alpha")
      (should (equal (plist-get (cdar drgnx-search-test--calls) :name) "alpha"))
      (should (equal messages '("Usages of alpha; 2 files still to index")))
      (should (equal (mapcar (lambda (i) (list (file-name-nondirectory (xref-file-location-file (xref-item-location i)))
                                               (xref-location-line (xref-item-location i))
                                               (xref-item-summary i)))
                             items)
                     '(("a.el" 1 "definition: (defun alpha ()") ("b.el" 5 "in beta") ("b.el" 9 "in beta"))))
      (should (string-match-p "2 files still to index"
                              (buffer-local-value 'header-line-format (get-buffer "*xref*")))))))

(ert-deftest drgnx-search/xref-references-and-definitions-come-from-the-hub ()
  "Pattern D, the real hub: in a project the xref backend answers references from `search/usages' and definitions
from its exact matches; a use in another file is found by name."
  (drgnx-search-test--with-hub
    (write-region "(defun drgnx-search-test-beta ()\n  (drgnx-search-test-alpha))\n" nil (concat root "b.el") nil 'silent)
    (drgnx-test-wait (lambda () (eql 0 (plist-get (plist-get (drgnx-hub-call-sync
                                                              "search/usages" (list :root (directory-file-name root)
                                                                                    :name "drgnx-search-test-alpha")
                                                              10)
                                                             :fresh)
                                                  :files_pending)))
                     :secs 60 :what "the hub's index of the two files")
    (with-current-buffer (find-file-noselect (concat root "b.el"))
      (unwind-protect
          (let ((backend (drgnx-search-xref-backend)))
            (should (eq backend 'drgnx-hrafn))
            (should (equal (mapcar (lambda (i) (list (file-name-nondirectory
                                                      (xref-file-location-file (xref-item-location i)))
                                                     (xref-location-line (xref-item-location i))))
                                   (xref-backend-references backend "drgnx-search-test-alpha"))
                           '(("b.el" 2))))
            (should (equal (mapcar (lambda (i) (xref-location-line (xref-item-location i)))
                                   (xref-backend-definitions backend "drgnx-search-test-alpha"))
                           '(1))))
        (kill-buffer)))))

(provide 'mod-search-test)
;;; mod-search-test.el ends here
