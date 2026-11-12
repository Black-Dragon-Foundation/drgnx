;;; drgnx-debug-memory.el --- the memory view: a variable's bytes, read and written through the hub -*- lexical-binding: t -*-
;; Part of extra/debug (docs/develop/debugging.md, "The memory view").  View Binary Data on a Variables row whose
;; adapter gives a `memoryReference' opens its bytes a page at a time (`debug/read-memory'), 16 to a line: the
;; address, the bytes in hex, the bytes as text.  Writes go back with `debug/write-memory'.

;;; Code:

(require 'cl-lib)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-debug-view--value-node "drgnx-debug-view" ())
(declare-function drgnx-debug-view--field "drgnx-debug-view" (name id))
(declare-function drgnx-debug--session "drgnx-debug" (&optional state))
(declare-function drgnx-debug-can-p "drgnx-debug-launch" (session cap))
(defvar drgnx-debug--sessions)

(defcustom drgnx-debug-memory-page-bytes 256
  "How many bytes the memory view reads at a time (the hub refuses more than 64 KiB)."
  :type 'natnum :group 'drgnx-debug)

(defface drgnx-debug-memory-address '((t :inherit shadow)) "A line's address in the memory view." :group 'drgnx-debug)
(defface drgnx-debug-memory-unreadable '((t :inherit shadow)) "Bytes the program cannot give." :group 'drgnx-debug)

(defvar-local drgnx-debug-memory--session nil)
(defvar-local drgnx-debug-memory--reference nil)
(defvar-local drgnx-debug-memory--offset 0 "The page's first byte, from the reference.")

(defvar-keymap drgnx-debug-memory-mode-map
  :doc "The memory view's keys; the profiles add theirs (`debug-memory-*' in keys/*.eld).")

(define-derived-mode drgnx-debug-memory-mode special-mode "Memory"
  "A variable's bytes: 16 to a line, the address, hex and text; the next and previous pages, and writes."
  (setq-local truncate-lines t)
  (buffer-disable-undo))

(defun drgnx-debug-memory-open (session reference name)
  "Show the memory at REFERENCE in SESSION, as NAME's."
  (let ((b (get-buffer-create (format "*Memory: %s*" name))))
    (with-current-buffer b
      (drgnx-debug-memory-mode)
      (setq drgnx-debug-memory--session session drgnx-debug-memory--reference reference drgnx-debug-memory--offset 0)
      (drgnx-debug-memory--read))
    (pop-to-buffer b)))

(defun drgnx-debug-view-memory ()
  "View Binary Data: the memory of the variable at point in the Run and Debug view."
  (interactive)
  (let* ((id (drgnx-debug-view--value-node))
         (ref (or (drgnx-debug-view--field "memory_reference" id)
                  (user-error "The adapter gives no memory for this variable")))
         (session (if (string-match "\\`v:\\([^:]+\\):" id) (match-string 1 id)
                    (plist-get (or (drgnx-debug--session "stopped") (user-error "No stopped debug session")) :id))))
    (unless (drgnx-debug-can-p (drgnx-debug-memory--state session) :supportsReadMemoryRequest)
      (user-error "This debugger cannot read memory"))
    (drgnx-debug-memory-open session ref (drgnx-debug-view--field "label" id))))

(defun drgnx-debug-memory--state (session)
  "SESSION's plist in the last `debug-state'."
  (seq-find (lambda (s) (equal (plist-get s :id) session)) drgnx-debug--sessions))

(defun drgnx-debug-memory--read ()
  "Read the page at the offset and draw it when it comes."
  (let ((b (current-buffer)))
    (drgnx-hub-call "debug/read-memory" (list :session drgnx-debug-memory--session :reference drgnx-debug-memory--reference
                                              :offset drgnx-debug-memory--offset :count drgnx-debug-memory-page-bytes)
                    (lambda (r error)
                      (when (buffer-live-p b)
                        (with-current-buffer b
                          (if error (message "Memory: %s" error) (drgnx-debug-memory--draw r))))))))

(defun drgnx-debug-memory--draw (r)
  "Draw the answer R: `:address' of the page's first byte, `:data' (base64), `:unreadable' bytes after it."
  (let* ((data (base64-decode-string (or (plist-get r :data) "")))
         (n (+ (length data) (or (plist-get r :unreadable) 0)))
         (address (plist-get r :address))
         (base (if (and (stringp address) (string-match "\\`0[xX]\\([[:xdigit:]]+\\)\\'" address))
                   (string-to-number (match-string 1 address) 16)
                 drgnx-debug-memory--offset))
         (inhibit-read-only t) (p (point)) (lines nil))
    (dotimes (row (/ (+ n 15) 16))
      (let ((hex nil) (text nil))
        (dotimes (col 16)
          (let ((i (+ (* row 16) col)))
            (cond ((< i (length data))
                   (push (propertize (format "%02x" (aref data i)) 'drgnx-debug-memory-offset i) hex)
                   (push (let ((c (aref data i))) (if (<= 32 c 126) (string c) ".")) text))
                  ((< i n)
                   (push (propertize "??" 'face 'drgnx-debug-memory-unreadable) hex)
                   (push " " text))
                  (t (push "  " hex)))))
        (push (concat (propertize (format "%08x" (+ base (* row 16))) 'face 'drgnx-debug-memory-address)
                      "  " (mapconcat #'identity (nreverse hex) " ") "  " (apply #'concat (nreverse text)))
              lines)))
    ;; only the lines that changed are replaced (a refresh after a write changes one)
    (save-excursion
      (goto-char (point-min))
      (dolist (l (nreverse lines))
        (if (eobp)
            (insert l "\n")
          (let ((eol (line-end-position)))
            (unless (equal-including-properties (buffer-substring (point) eol) l)
              (delete-region (point) eol)
              (insert l))
            (forward-line 1))))
      (delete-region (point) (point-max)))
    (goto-char (min p (point-max)))))

(defun drgnx-debug-memory-next ()
  "The next page of memory."
  (interactive)
  (cl-incf drgnx-debug-memory--offset drgnx-debug-memory-page-bytes)
  (drgnx-debug-memory--read))

(defun drgnx-debug-memory-previous ()
  "The page before (never before the variable's reference)."
  (interactive)
  (when (> drgnx-debug-memory--offset 0)
    (setq drgnx-debug-memory--offset (max 0 (- drgnx-debug-memory--offset drgnx-debug-memory-page-bytes)))
    (drgnx-debug-memory--read)))

(defun drgnx-debug-memory-refresh ()
  "Read the page again."
  (interactive)
  (drgnx-debug-memory--read))

(defun drgnx-debug-memory-write ()
  "Write bytes, typed in hex, from the byte at point (`debug/write-memory'); the page is read again after."
  (interactive)
  (unless (drgnx-debug-can-p (drgnx-debug-memory--state drgnx-debug-memory--session) :supportsWriteMemoryRequest)
    (user-error "This debugger cannot write memory"))
  (let* ((at (or (get-text-property (point) 'drgnx-debug-memory-offset)
                 (get-text-property (max (point-min) (1- (point))) 'drgnx-debug-memory-offset)
                 (user-error "No byte here")))
         (hex (replace-regexp-in-string "[ \t]" "" (read-string (format "Bytes at +%d (hex): " at)))))
    (unless (and (> (length hex) 0) (cl-evenp (length hex)) (string-match-p "\\`[[:xdigit:]]+\\'" hex))
      (user-error "Type the bytes in hex, two digits each"))
    (let ((bytes (apply #'unibyte-string (cl-loop for i from 0 below (length hex) by 2
                                                  collect (string-to-number (substring hex i (+ i 2)) 16))))
          (b (current-buffer)))
      (drgnx-hub-call "debug/write-memory" (list :session drgnx-debug-memory--session
                                                 :reference drgnx-debug-memory--reference
                                                 :offset (+ drgnx-debug-memory--offset at)
                                                 :data (base64-encode-string bytes))
                      (lambda (_r error)
                        (if error (message "Memory: %s" error)
                          (when (buffer-live-p b) (with-current-buffer b (drgnx-debug-memory--read)))))))))

(defun drgnx-debug-memory--teardown ()
  "The memory views go with the module."
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-debug-memory-mode) (kill-buffer b))))

(defconst drgnx-debug-memory-commands
  '((debug-memory-next "Memory: Next Page" drgnx-debug-memory-next "The next page of the variable's memory")
    (debug-memory-previous "Memory: Previous Page" drgnx-debug-memory-previous "The page of memory before this one")
    (debug-memory-refresh "Memory: Refresh" drgnx-debug-memory-refresh "Read the page of memory again")
    (debug-memory-write "Memory: Write Bytes…" drgnx-debug-memory-write "Write bytes, in hex, from the byte at point"))
  "The memory view's commands, keys of its own map: (ID TITLE FUNCTION DOC).")

(provide 'drgnx-debug-memory)
;;; drgnx-debug-memory.el ends here
