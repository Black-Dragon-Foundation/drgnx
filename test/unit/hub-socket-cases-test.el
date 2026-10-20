;;; hub-socket-cases-test.el --- batch tests: Lisp's hub socket path agrees with the shared fixture -*- lexical-binding: t -*-
;; test/fixtures/hub-socket-cases.json is also read by the Rust side (runtime/conformance, paths.rs; later drgnx-proto):
;; Lisp, bash and Rust must agree on the socket path.  Every case is the whole environment (nothing else is set).
(require 'ert)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-hub)

(defconst hub-socket-cases-test--vars
  '("HOME" "DRGNX_DATA_DIR" "DRGNX_CONFIG_DIR" "XDG_DATA_HOME" "XDG_STATE_HOME" "XDG_CONFIG_HOME" "XDG_CACHE_HOME"
    "XDG_RUNTIME_DIR" "TMPDIR" "TMP" "TEMP")
  "Everything the rule reads: a case's environment replaces all of it.")

(defun hub-socket-cases-test--cases ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/hub-socket-cases.json" drgnx-dir))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(ert-deftest drgnx-hub-socket-cases/lisp-agrees-with-the-fixture ()
  ;; `temporary-file-directory' is another one: the socket follows the environment alone (macOS's Emacs starts with
  ;; `getconf DARWIN_USER_TEMP_DIR' there when TMPDIR, TMP and TEMP are unset, which the Rust side cannot know)
  (let ((cases (hub-socket-cases-test--cases)))
    (should (>= (length cases) 13))
    (dolist (c cases)
      (let* ((env (alist-get 'env c))
             (process-environment (append (mapcar (lambda (kv) (format "%s=%s" (car kv) (cdr kv))) env)
                                          hub-socket-cases-test--vars))
             (temporary-file-directory "/not-the-environments/T/")
             (uid (number-to-string (user-uid))))
        (should (equal (drgnx-data-dir) (alist-get 'data_dir c)))
        (should (equal (drgnx-hub-socket) (string-replace "$UID" uid (alist-get 'socket c))))))))
