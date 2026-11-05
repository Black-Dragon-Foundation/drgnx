;;; work-space-fixture.el --- a small Work map frame, as the hub's wire decodes it -*- lexical-binding: t -*-
;; The frame in test/fixtures/work-space/frame.json is what `work/map/subscribe' answers (decoded by the hub client's
;; own parser options), so the map client and the rows are tested on the wire's shape: 10 items in the six layers, a
;; subagent, an overlap between two agents, a shared file and one needs-you card.
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defun drgnx-work-fixture-frame ()
  "A fresh copy of the fixture frame (a plist, arrays as lists, as the hub client decodes a line)."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/work-space/frame.json" drgnx-dir))
    (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil :false-object nil)))

(defmacro drgnx-work-fixture-with-buffer (&rest body)
  "BODY in a fresh buffer that runs its kill hooks when it goes.
`with-temp-buffer' makes a buffer that does not (inhibit-buffer-hooks), so a layer timer a map buffer owns would
outlive it; the timer layer cancels the timers of a killed buffer through `kill-buffer-hook'."
  (declare (indent 0) (debug t))
  (let ((buf (make-symbol "buf")))
    `(let ((,buf (generate-new-buffer " *work-map-test*")))
       (unwind-protect (with-current-buffer ,buf ,@body)
         (when (buffer-live-p ,buf) (kill-buffer ,buf))))))

(defun drgnx-work-fixture-item (frame id)
  "The item ID of FRAME (a plist)."
  (seq-find (lambda (it) (equal (plist-get it :id) id)) (plist-get frame :items)))

(defun drgnx-work-fixture-changed (frame id &rest fields)
  "Item ID of FRAME with FIELDS (a plist) merged into its `:fields'."
  (let* ((it (copy-sequence (drgnx-work-fixture-item frame id))) (f (copy-sequence (plist-get it :fields))))
    (while fields (setq f (plist-put f (pop fields) (pop fields))))
    (plist-put it :fields f)))

(defun drgnx-work-fixture-delta (version base &rest keys)
  "A `work-map' event for the view \"v\" at VERSION on BASE; KEYS (:changed :removed :entered :places :edges :layout
:needs_you :chips :full) are added."
  (append (list :view "v" :version version :base base) keys))

(provide 'drgnx-work-space-fixture)
;;; work-space-fixture.el ends here
