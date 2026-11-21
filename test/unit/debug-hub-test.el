;;; debug-hub-test.el --- batch tests: the debug UI against the real hub and its mock adapter -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The hub is the real Ratatoskr (DRGNX_RATATOSKR_BIN, a test-hooks build: its `debug-mock' adapter plays a script of
;; DAP requests and answers, and fails on any request it did not expect); the test skips without it.  The module is set
;; up as a user has it, so the hub's events reach the console and the gutter as they do in use; every wait is for
;; what the hub sends (`drgnx-test-wait'), never a pause.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)
;; what connecting to the hub loads (the keys handed over, the providers' settings), loaded here so that a test's leak
;; census sees only what the test leaves
(require 'auth-source)
(require 'drgnx-ai)

(defmacro debug-hub-test--with (script &rest body)
  "BODY with the hub serving a project PROJ (bound, a true name) whose launch configuration runs the mock adapter on
SCRIPT (a list of steps, serialized to JSON), and the module set up.  `debug-hub-test--start' starts the session."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-debug-hub" t))))
          (proj (concat root "proj"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "XDG_CACHE_HOME=" root "cache")
                                             (concat "HOME=" root "home"))
                                       process-environment)))
     (dolist (d '("config" "data" "state" "home" "cache" "proj/.vscode")) (make-directory (concat root d) t))
     (with-temp-file (concat proj "/.vscode/launch.json")
       (insert (json-serialize (list :version "0.2.0"
                                     :configurations (vector (list :type "mock" :request "launch" :name "Mock"
                                                                   :program "app"))))))
     (with-temp-file (concat root "script.json") (insert (json-serialize (vconcat ,script))))
     (unwind-protect
         (drgnx-test-with-ratatoskr root
           (drgnx-test-with-modules '(extra/debug)
             (unwind-protect (progn ,@body)
               (when-let* ((b (get-buffer drgnx-debug-console-buffer-name)))
                 (let ((kill-buffer-query-functions nil)) (kill-buffer b))))))
       (delete-directory root t))))

(defun debug-hub-test--start (proj)
  "Trust PROJ and start its configuration on the mock adapter; the session's id."
  (should (drgnx-hub-call-sync "debug/trust" (list :root proj :trusted t)))
  (let* ((bin (drgnx-test-ratatoskr-bin))
         (script (expand-file-name "../script.json" proj))
         (adapters (vector (list :id "mock" :name "Mock" :types ["mock"] :find (list :path bin)
                                 :start (list :stdio (vector "{program}" "debug-mock" script)))))
         (r (drgnx-hub-call-sync "debug/start" (list :root proj :config "launch:0" :adapters adapters) 10)))
    (or (plist-get r :session) (ert-fail (list "the mock's session did not start" r)))))

(defun debug-hub-test--initialized (&rest caps)
  "The script's start: the adapter has CAPS, is launched and configured."
  (list (list :expect "initialize" :ok (apply #'list :supportsConfigurationDoneRequest t caps))
        (list :expect "launch")
        (list :event "initialized")))

(defun debug-hub-test--shown ()
  "The console's output as it shows: the text no fold hides."
  (with-current-buffer drgnx-debug-console-buffer-name
    (let ((s "") (p (point-min)) (end (marker-position drgnx-debug-console--end)))
      (while (< p end)
        (let ((next (min end (next-single-char-property-change p 'invisible))))
          (unless (invisible-p p) (setq s (concat s (buffer-substring-no-properties p next))))
          (setq p next)))
      s)))

(ert-deftest drgnx-debug-hub/console-groups-fold ()
  "The adapter's `group' outputs, through the hub's console batches: the opening lines get chevrons, a
`startCollapsed' group starts folded, and the line after the groups is outside them; toggling a group folds it."
  (debug-hub-test--with
      (append (debug-hub-test--initialized)
              (list (list :expect "configurationDone")
                    (list :event "output" :body (list :category "stdout" :output "Group A\n" :group "start"))
                    (list :event "output" :body (list :category "stdout" :output "child\n"))
                    (list :event "output" :body (list :category "stdout" :output "inner\n" :group "startCollapsed"))
                    (list :event "output" :body (list :category "stdout" :output "deep\n"))
                    (list :event "output" :body (list :category "stdout" :output "" :group "end"))
                    (list :event "output" :body (list :category "stdout" :output "" :group "end"))
                    (list :event "output" :body (list :category "stdout" :output "out\n"))
                    (list :expect "disconnect") (list :die t)))
    (debug-hub-test--start proj)
    (drgnx-test-wait (lambda () (when-let* ((b (get-buffer drgnx-debug-console-buffer-name)))
                                  (with-current-buffer b
                                    (string-search "out\n" (buffer-substring-no-properties
                                                            (point-min) drgnx-debug-console--end)))))
                     :what "the console's lines")
    (should (equal (debug-hub-test--shown) "▾ Group A\n  child\n  ▸ inner\nout\n"))
    (with-current-buffer drgnx-debug-console-buffer-name
      (goto-char (point-min))
      (search-forward "Group")
      (drgnx-debug-console-toggle)
      (should (equal (debug-hub-test--shown) "▸ Group A\nout\n")))))

(ert-deftest drgnx-debug-hub/inline-candidates-and-an-inline-breakpoint ()
  "While stopped, a line with a breakpoint shows the adapter's other places on it (`breakpointLocations', through
`debug/breakpoint-locations'); taking one sends the adapter a breakpoint at that column, and the column's dot shows."
  (let ((file nil) (buf nil))
    (debug-hub-test--with
        (append (debug-hub-test--initialized :supportsBreakpointLocationsRequest t)
                (list (list :expect "setBreakpoints" :args (list :breakpoints (vector (list :line 2)))
                            :ok (list :breakpoints (vector (list :id 11 :verified t :line 2))))
                      (list :expect "configurationDone")
                      (list :event "stopped" :body (list :reason "breakpoint" :threadId 1 :allThreadsStopped t))
                      (list :expect "threads" :ok (list :threads (vector (list :id 1 :name "main"))))
                      (list :any (vector
                                  (list :expect "stackTrace"
                                        :ok (list :stackFrames (vector (list :id 1000 :name "main" :line 2 :column 1
                                                                             :source (list :path "PATH")))
                                                  :totalFrames 1))
                                  (list :expect "scopes" :ok (list :scopes []))
                                  (list :expect "breakpointLocations" :args (list :line 2)
                                        :ok (list :breakpoints (vector (list :line 2 :column 1)
                                                                       (list :line 2 :column 5))))))
                      (list :expect "setBreakpoints"
                            :args (list :breakpoints (vector (list :line 2) (list :line 2 :column 5)))
                            :ok (list :breakpoints (vector (list :id 11 :verified t :line 2)
                                                           (list :id 12 :verified t :line 2 :column 5))))
                      (list :expect "disconnect") (list :die t)))
      (setq file (concat proj "/app.js"))
      (with-temp-file file (insert "let a = 1\nb = f(y)\n"))
      (with-temp-file (concat root "script.json")
        (insert (string-replace "\"PATH\"" (json-serialize file)
                                (with-temp-buffer (insert-file-contents (concat root "script.json")) (buffer-string)))))
      (unwind-protect
          (progn
            (setq buf (let ((auto-mode-alist nil) (magic-mode-alist nil) (interpreter-mode-alist nil))
                        (find-file-noselect file)))
            (with-current-buffer buf
              (should drgnx-debug-gutter-mode)
              (drgnx-debug-gutter-toggle 2)
              (drgnx-test-wait (lambda () drgnx-debug-gutter--bps) :what "the breakpoint in the store"))
            (debug-hub-test--start proj)
            (with-current-buffer buf
              (drgnx-test-wait (lambda () drgnx-debug-gutter--candidates) :what "the candidates while stopped")
              ;; the line breakpoint holds the first place (column 1): the one candidate is column 5
              (should (equal (mapcar (lambda (o) (- (overlay-start o) (line-beginning-position 2) -1))
                                     drgnx-debug-gutter--candidates)
                             '(5)))
              (funcall (overlay-get (car drgnx-debug-gutter--candidates) 'drgnx-debug-candidate))
              (drgnx-test-wait (lambda () (seq-find (lambda (b) (eql (plist-get b :column) 5)) drgnx-debug-gutter--bps))
                               :what "the inline breakpoint in the store")
              (drgnx-test-wait (lambda () (seq-find (lambda (o) (overlay-get o 'drgnx-debug-column))
                                                    (overlays-in (point-min) (point-max))))
                               :what "the inline breakpoint's dot")))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(defun debug-hub-test--stop (&rest after)
  "The script's stop on line 2 of PATH's file, then AFTER: the adapter's answers to the stop's own requests."
  (append (list (list :event "stopped" :body (list :reason "breakpoint" :threadId 1 :allThreadsStopped t))
                (list :expect "threads" :ok (list :threads (vector (list :id 1 :name "main"))))
                (list :any (vector (list :expect "stackTrace"
                                         :ok (list :stackFrames (vector (list :id 1000 :name "main" :line 2 :column 1
                                                                              :source (list :path "/nowhere/app.py")))
                                                   :totalFrames 1))
                                   (list :expect "scopes" :ok (list :scopes [])))))
          after))

(defun debug-hub-test--session (session)
  "SESSION's plist in the editor's last `debug-state'."
  (seq-find (lambda (s) (equal (plist-get s :id) session)) drgnx-debug--sessions))

(defun debug-hub-test--stopped (session &rest caps)
  "Wait until SESSION is stopped in the editor's `debug-state', with CAPS among its adapter's capabilities."
  (drgnx-test-wait (lambda () (when-let* ((s (seq-find (lambda (s) (equal (plist-get s :id) session))
                                                       drgnx-debug--sessions)))
                                (and (equal (plist-get s :state) "stopped")
                                     (seq-every-p (lambda (c) (drgnx-debug-can-p s c)) caps))))
                   :what "the session stopped, its capabilities known"))

(ert-deftest drgnx-debug-hub/console-completes-from-the-adapter ()
  "Completion in the Debug Console's input goes through `debug/completions' to the adapter's `completions' (the
column 1-based), once `debug-state' says the adapter completes; the targets complete the word before point."
  (debug-hub-test--with
      (append (debug-hub-test--initialized :supportsCompletionsRequest t)
              (list (list :expect "configurationDone"))
              (debug-hub-test--stop
               (list :expect "completions" :args (list :text "len(it" :column 7)
                     :ok (list :targets (vector (list :label "items" :type "variable")
                                                (list :label "iter" :type "function"))))
               (list :expect "disconnect") (list :die t)))
    (let ((session (debug-hub-test--start proj)))
      (debug-hub-test--stopped session :supportsCompletionsRequest)
      (let ((default-directory (file-name-as-directory proj))) (drgnx-debug-console--buffer))
      (with-current-buffer drgnx-debug-console-buffer-name
        (goto-char (point-max))
        (insert "len(it")
        (pcase-let ((`(,beg ,end ,table . ,_) (run-hook-with-args-until-success 'completion-at-point-functions)))
          (should (equal (buffer-substring-no-properties beg end) "it"))
          (should (equal (all-completions "it" table) '("items" "iter"))))))))

(ert-deftest drgnx-debug-hub/memory-view-reads-and-writes ()
  "The memory view reads a page through `debug/read-memory' (the adapter's `readMemory') and writes the bytes typed
through `debug/write-memory', then reads the page again; `debug-state' says the adapter can do both."
  (debug-hub-test--with
      (append (debug-hub-test--initialized :supportsReadMemoryRequest t :supportsWriteMemoryRequest t)
              (list (list :expect "configurationDone"))
              (debug-hub-test--stop
               (list :expect "readMemory" :args (list :memoryReference "0x1000" :offset 0 :count 256)
                     :ok (list :address "0x1000" :data (base64-encode-string "abcdef")))
               (list :expect "writeMemory" :args (list :memoryReference "0x1000" :offset 2 :data "QUI=")
                     :ok (list :bytesWritten 2))
               (list :expect "readMemory" :args (list :memoryReference "0x1000" :offset 0 :count 256)
                     :ok (list :address "0x1000" :data (base64-encode-string "abABef")))
               (list :expect "disconnect") (list :die t)))
    (let ((session (debug-hub-test--start proj)))
      (debug-hub-test--stopped session :supportsReadMemoryRequest :supportsWriteMemoryRequest)
      (unwind-protect
          (progn
            (save-window-excursion (drgnx-debug-memory-open session "0x1000" "buf"))
            (with-current-buffer "*Memory: buf*"
              (drgnx-test-wait (lambda () (string-search "abcdef" (buffer-string))) :what "the page")
              (should (string-prefix-p "00001000  61 62 63 64 65 66" (buffer-string)))
              (goto-char (point-min))
              (search-forward "63")
              (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "41 42")))
                (drgnx-debug-memory-write))
              (drgnx-test-wait (lambda () (string-search "abABef" (buffer-string))) :what "the page read again")))
        (when (get-buffer "*Memory: buf*") (kill-buffer "*Memory: buf*"))))))

(ert-deftest drgnx-debug-hub/console-timestamps-are-the-hubs ()
  "With timestamps on, each console line shows the time the hub stamped it (`time'), not the editor's."
  (debug-hub-test--with
      (append (debug-hub-test--initialized)
              (list (list :expect "configurationDone")
                    (list :event "output" :body (list :category "stdout" :output "hello\n"))
                    (list :expect "disconnect") (list :die t)))
    (let ((drgnx-debug-console-timestamps t))
      (debug-hub-test--start proj)
      (drgnx-test-wait (lambda () (when-let* ((b (get-buffer drgnx-debug-console-buffer-name)))
                                    (with-current-buffer b (string-search "hello" (buffer-string)))))
                       :what "the line")
      (with-current-buffer drgnx-debug-console-buffer-name
        (goto-char (point-min))
        (search-forward "hello")
        (let ((ms (get-text-property (line-beginning-position) 'drgnx-debug-console-time)))
          (should (natnump ms))
          (should (equal (get-text-property (line-beginning-position) 'line-prefix)
                         (drgnx-debug-console--stamp ms))))))))

(ert-deftest drgnx-debug-hub/disassembly-and-an-instruction-breakpoint ()
  "Open Disassembly View reads around the stop's `instruction_pointer' (the adapter's `disassemble'), marks it, sets
an instruction breakpoint from the column (`setInstructionBreakpoints'), and the step keys step one instruction
while it has focus."
  (debug-hub-test--with
      (append (debug-hub-test--initialized :supportsDisassembleRequest t :supportsInstructionBreakpoints t
                                           :supportsSteppingGranularity t)
              (list (list :expect "configurationDone")
                    (list :event "stopped" :body (list :reason "pause" :threadId 1 :allThreadsStopped t))
                    (list :expect "threads" :ok (list :threads (vector (list :id 1 :name "main"))))
                    (list :any (vector (list :expect "stackTrace"
                                             :ok (list :stackFrames (vector (list :id 5 :name "f" :line 2 :column 1
                                                                                  :source (list :path "/nowhere/app.c")
                                                                                  :instructionPointerReference "0x1000"))
                                                       :totalFrames 1))
                                       (list :expect "scopes" :ok (list :scopes []))))
                    (list :expect "disassemble"
                          :args (list :memoryReference "0x1000" :instructionOffset -1 :instructionCount 4)
                          :ok (list :instructions
                                    (vector (list :address "0xff8" :instructionBytes "55" :instruction "push rbp")
                                            (list :address "0x1000" :instructionBytes "89 e5" :instruction "mov ebp, esp")
                                            (list :address "0x1004" :instruction "ret")
                                            (list :address "0x1005" :instruction "nop"))))
                    (list :expect "setInstructionBreakpoints"
                          :args (list :breakpoints (vector (list :instructionReference "0x1004")))
                          :ok (list :breakpoints (vector (list :verified t))))
                    (list :expect "next" :args (list :threadId 1 :granularity "instruction"))
                    (list :expect "disconnect") (list :die t)))
    (let ((session (debug-hub-test--start proj)) (drgnx-debug-disassembly-count 4))
      (debug-hub-test--stopped session :supportsDisassembleRequest)
      (drgnx-test-wait (lambda () (alist-get session drgnx-debug-disassembly--frames nil nil #'equal))
                       :what "the stop's instruction")
      (unwind-protect
          (save-window-excursion
            (let ((default-directory (file-name-as-directory proj))) (drgnx-debug-open-disassembly))
            (with-current-buffer drgnx-debug-disassembly-buffer-name
              (drgnx-test-wait (lambda () (drgnx-debug-disassembly--line-of #x1004)) :what "the instructions")
              (should (= (line-number-at-pos (drgnx-debug-disassembly--line-of #x1000)) 2))
              (should (seq-find (lambda (o) (overlay-get o 'face)) drgnx-debug-disassembly--marks))
              (goto-char (drgnx-debug-disassembly--line-of #x1004))
              (drgnx-debug-disassembly-toggle-breakpoint)
              (drgnx-test-wait (lambda () (= 2 (length drgnx-debug-disassembly--marks))) :what "the breakpoint's mark")
              (should (equal (plist-get (car drgnx-debug-disassembly--bps) :instruction) "0x1004"))
              (cl-letf (((symbol-function 'drgnx-debug--session) (lambda (&rest _) (debug-hub-test--session session))))
                (drgnx-debug-step-over))
              (drgnx-test-wait (lambda () (equal (plist-get (debug-hub-test--session session) :state) "running"))
                               :what "the instruction step")))
        (when (get-buffer drgnx-debug-disassembly-buffer-name) (kill-buffer drgnx-debug-disassembly-buffer-name))))))

;;; debug-hub-test.el ends here
