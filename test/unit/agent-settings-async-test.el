;;; agent-settings-async-test.el --- the settings page reads Claude Code's file off the main thread -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): `nidhogg-read-file-async' and `nidhogg-insert-file-block' are stubbed to their documented contract (the
;; callback gets a block, or nil and an error; nil = not started); Nidhogg's own `file-block' rows prove the real ones.
;; Every agent home is a temp directory (test/fixtures/agent-config-fixture.el).
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-registry)
(require 'drgnx-keys)
(require 'drgnx-agents)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-panel-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-settings" drgnx-dir) nil t)
(defvar nidhogg-workers-framing)        ; a `let' of it binds it dynamically, also on an Emacs without the feature

(defmacro drgnx-agent-settings-async-test--with (&rest body)
  "BODY in the fixture's environment with a `.claude.json' holding one server, the primitives stubbed (READS:
\(FILE . CALLBACK) newest first; STARTS: whether the read starts) and the workers on."
  (declare (indent 0))
  `(drgnx-agent-config-test-env
     (let ((nidhogg-workers-framing t) reads (starts t))
       (let ((file (drgnx-agent-config-claude-json-file)))
         (make-directory (file-name-directory file) t)
         (write-region "{\n  \"mcpServers\": {\n    \"docs\": {\"type\": \"stdio\", \"command\": \"drgnx-no-such-command\"}\n  }\n}\n"
                       nil file nil 'silent))
       (cl-letf (((symbol-function 'nidhogg-set-process-framing) #'ignore)
                 ((symbol-function 'nidhogg-directory-files-async) #'ignore)
                 ((symbol-function 'nidhogg-read-file-async) (lambda (f cb &rest _) (when starts (push (cons f cb) reads) 1)))
                 ((symbol-function 'nidhogg-insert-file-block) (lambda (block) (insert-file-contents (plist-get block :file)))))
         ,@body))))

(defun drgnx-agent-settings-async-test--data-after (&optional load)
  "The page data of Claude Code's settings read the usual way, or, with LOAD, what LOAD does in the page buffer."
  (with-temp-buffer
    (setq drgnx-agent-settings--kind 'claude drgnx-agent-settings--root nil)
    (if load (funcall load) (drgnx-agent-settings--read))
    (list (plist-get drgnx-agent-settings--data :items) (plist-get drgnx-agent-settings--data :problems))))

(ert-deftest drgnx-agent-settings/async-read-same ()
  "Pattern D: the page reads the same data when `.claude.json' comes from a block that lands later as when it is read
at once; until the block lands a new page says it is reading, and the text read is not kept for an edit's re-read."
  (drgnx-agent-settings-async-test--with
    (let* ((sync (drgnx-agent-settings-async-test--data-after)) (file (drgnx-agent-config-claude-json-file)) landed)
      (should (seq-find (lambda (i) (equal (plist-get i :name) "docs")) (car sync)))
      (with-temp-buffer
        (setq drgnx-agent-settings--kind 'claude drgnx-agent-settings--root nil)
        (drgnx-agent-settings--read-then (current-buffer) (lambda () (setq landed t)))
        (should-not landed)
        (should (string-search "Reading" (buffer-string)))
        (should (= (length reads) 1))
        (funcall (cdar reads) (list :file file) nil)
        (should landed)
        (should (equal (list (plist-get drgnx-agent-settings--data :items) (plist-get drgnx-agent-settings--data :problems))
                       sync)))
      (should-not drgnx-agent-config--preread))))

(ert-deftest drgnx-agent-settings/the-text-read-is-the-text-the-page-shows ()
  "Pattern D: the data comes from the block's text, not from a second read of the file."
  (drgnx-agent-settings-async-test--with
    (let ((file (drgnx-agent-config-claude-json-file)) (block-file (make-temp-file "drgnx-block")))
      (unwind-protect
          (progn
            (write-region "{\"mcpServers\": {\"from-block\": {\"type\": \"stdio\", \"command\": \"x\"}}}" nil block-file nil 'silent)
            (with-temp-buffer
              (setq drgnx-agent-settings--kind 'claude drgnx-agent-settings--root nil)
              (drgnx-agent-settings--read-then (current-buffer) #'ignore)
              (funcall (cdar reads) (list :file block-file) nil)
              (let ((names (mapcar (lambda (i) (plist-get i :name)) (plist-get drgnx-agent-settings--data :items))))
                (should (member "from-block" names))
                (should-not (member "docs" names))))
            (should (file-exists-p file)))
        (delete-file block-file)))))

(ert-deftest drgnx-agent-settings/not-started-reads-now ()
  "Pattern D: a read that did not start is read at once, as without the workers: the page is drawn before the call returns."
  (drgnx-agent-settings-async-test--with
    (setq starts nil)
    (let ((sync (drgnx-agent-settings-async-test--data-after)) landed)
      (with-temp-buffer
        (setq drgnx-agent-settings--kind 'claude drgnx-agent-settings--root nil)
        (drgnx-agent-settings--read-then (current-buffer) (lambda () (setq landed t)))
        (should landed)
        (should-not reads)
        (should (equal (list (plist-get drgnx-agent-settings--data :items) (plist-get drgnx-agent-settings--data :problems))
                       sync))))))

(ert-deftest drgnx-agent-settings/an-edit-reads-at-once ()
  "Pattern D: `drgnx-agent-config-read-text', the read of an edit's read-modify-write, never goes through the async read,
with the workers on or off."
  (drgnx-agent-settings-async-test--with
    (let ((file (drgnx-agent-config-claude-json-file)))
      (should (string-search "docs" (drgnx-agent-config-read-text file)))
      (should-not reads))))

(ert-deftest drgnx-agent-settings/other-agents-read-at-once ()
  "Pattern D: only Claude Code's `.claude.json' is read off the main thread."
  (drgnx-agent-settings-async-test--with
    (let (landed)
      (with-temp-buffer
        (setq drgnx-agent-settings--kind 'codex drgnx-agent-settings--root nil)
        (drgnx-agent-settings--read-then (current-buffer) (lambda () (setq landed t)))
        (should landed)
        (should-not reads)))))
