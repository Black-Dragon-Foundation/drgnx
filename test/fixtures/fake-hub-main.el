;;; fake-hub-main.el --- the fake hub (fake-hub.el) in a process of its own -*- lexical-binding: t -*-
;; A batch Nidhogg entry point for tests whose own Emacs must not answer: a front call (`drgnx-hub-call-front') waits
;; with JUST-THIS-ONE an integer, which starves every other filter and timer of the waiting Emacs, a fake hub served
;; there too.  Run as
;;   EMACS --batch -Q -L CORE -l test/fixtures/fake-hub-main.el -f drgnx-fake-hub-main
;; with the environment:
;; - DRGNX_FAKE_HUB_SOCKET: where it serves (the cap file goes beside it; the test waits for that file);
;; - DRGNX_FAKE_HUB_LOG: a file that gets each request's method, one a line, before it is answered;
;; - DRGNX_FAKE_HUB_MODE (v1, wrong-proof, no-proof, legacy), DRGNX_FAKE_HUB_SILENT (methods, comma-separated),
;;   DRGNX_FAKE_HUB_DELAY (seconds), DRGNX_FAKE_HUB_ERRORS (a JSON object METHOD → {code, message, path}):
;;   `drgnx-fake-hub-start''s MODE, SILENT, DELAY and ERRORS;
;; - DRGNX_FAKE_HUB_PARENT: a pid; the fake hub ends when it is gone.
(require 'cl-lib)
(load (expand-file-name "fake-hub" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defvar drgnx-fake-hub-main--log nil "The file each request's method is appended to.")

(defun drgnx-fake-hub-main--note (_server _conn json)
  "Append JSON's method to `drgnx-fake-hub-main--log' (before the fake hub answers it)."
  (when drgnx-fake-hub-main--log
    (write-region (format "%s\n" (or (plist-get json :method) "")) nil drgnx-fake-hub-main--log t 'silent)))

(defun drgnx-fake-hub-main--errors (text)
  "TEXT, a JSON object METHOD → {code, message, path}, as `drgnx-fake-hub-start''s ERRORS."
  (when (and text (not (string-empty-p text)))
    (let ((out nil))
      (maphash (lambda (method e) (push (cons method (list :code (gethash "code" e) :message (gethash "message" e)
                                                           :path (gethash "path" e)))
                                        out))
               (json-parse-string text :object-type 'hash-table))
      out)))

(defun drgnx-fake-hub-main ()
  "Serve the fake hub as the environment says (the file's commentary) until the parent is gone or the process is
killed."
  (let ((socket (getenv "DRGNX_FAKE_HUB_SOCKET"))
        (parent (string-to-number (or (getenv "DRGNX_FAKE_HUB_PARENT") "0")))
        (delay (getenv "DRGNX_FAKE_HUB_DELAY"))
        (silent (getenv "DRGNX_FAKE_HUB_SILENT"))
        (mode (getenv "DRGNX_FAKE_HUB_MODE")))
    (setq drgnx-fake-hub-main--log (getenv "DRGNX_FAKE_HUB_LOG"))
    (advice-add 'drgnx-fake-hub--line :before #'drgnx-fake-hub-main--note)
    (drgnx-fake-hub-start socket :mode (if (and mode (not (string-empty-p mode))) (intern mode) 'v1)
                          :silent (and silent (split-string silent "," t))
                          :delay (and delay (not (string-empty-p delay)) (string-to-number delay))
                          :errors (drgnx-fake-hub-main--errors (getenv "DRGNX_FAKE_HUB_ERRORS")))
    (while (or (<= parent 0) (process-attributes parent))
      (accept-process-output nil 0.05))
    (kill-emacs 0)))

;;; fake-hub-main.el ends here
