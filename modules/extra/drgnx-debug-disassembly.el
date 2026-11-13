;;; drgnx-debug-disassembly.el --- the disassembly view: the instructions around a stop, with instruction breakpoints -*- lexical-binding: t -*-
;; Part of extra/debug (docs/develop/debugging.md, "The disassembly view").  Open Disassembly View (from a frame, or
;; at a stop in code with no file) reads the instructions around the frame's `instruction_pointer'
;; (`debug/disassemble', at most 500 a call): the source line they came from as a quiet row above them, the address,
;; the bytes, the instruction.  The debug column marks the current instruction and takes the session's instruction
;; breakpoints (`debug/breakpoints' ops `add-instruction', `remove-instruction'; the hub's instruction view and its
;; `debug-breakpoints' events with a session and no path).  The step keys step one instruction while it has focus.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-debug--session "drgnx-debug" (&optional state))
(declare-function drgnx-debug-can-p "drgnx-debug-launch" (session cap))
(declare-function drgnx-debug-launch-root "drgnx-debug-launch" ())
(declare-function drgnx-debug-gutter--margin-string "drgnx-debug-gutter" (kind help &optional agent))
(declare-function drgnx-debug-gutter--columns "drgnx-debug-gutter" ())
(declare-function drgnx-margins-claim "drgnx-margins" (owner columns &rest keys))
(defvar drgnx-debug--sessions)

(defcustom drgnx-debug-disassembly-count 200
  "How many instructions the disassembly view reads at a time, around the current one (the hub gives 500 at most)."
  :type 'natnum :group 'drgnx-debug)

(defface drgnx-debug-disassembly-address '((t :inherit drgnx-text-subtle)) "An instruction's address."
  :group 'drgnx-debug)
(defface drgnx-debug-disassembly-bytes '((t :inherit drgnx-text-disabled)) "An instruction's bytes." :group 'drgnx-debug)
(defface drgnx-debug-disassembly-source '((t :inherit drgnx-text-subtle))
  "The source line instructions came from, above them." :group 'drgnx-debug)
(defface drgnx-debug-disassembly-place '((t :inherit drgnx-text-disabled)) "A source row's file and line."
  :group 'drgnx-debug)
(defface drgnx-debug-disassembly-step '((t :inherit drgnx-chip-warn))
  "The header's chip while the step keys step one instruction." :group 'drgnx-debug)

(defconst drgnx-debug-disassembly-buffer-name "*Disassembly*")

(defvar drgnx-debug-disassembly--frames nil
  "SESSION → the last `debug-frame' that had an `instruction_pointer': where Open Disassembly View starts.")

(defvar-local drgnx-debug-disassembly--session nil)
(defvar-local drgnx-debug-disassembly--anchor nil "The address the page is read around (a string the hub gave).")
(defvar-local drgnx-debug-disassembly--first 0 "The first instruction's offset from the anchor, in instructions.")
(defvar-local drgnx-debug-disassembly--frame nil "The frame shown: its `debug-frame' plist.")
(defvar-local drgnx-debug-disassembly--bps nil "The session's instruction breakpoints as the hub last said.")
(defvar-local drgnx-debug-disassembly--version 0)
(defvar-local drgnx-debug-disassembly--marks nil "The column's overlays.")

(defvar-keymap drgnx-debug-disassembly-mode-map
  :doc "The disassembly view's keys; the profiles add theirs (`debug-disassembly-*' in keys/*.eld).")

(define-derived-mode drgnx-debug-disassembly-mode special-mode "Disassembly"
  "The instructions around a stop: source rows, addresses, bytes, instructions; instruction breakpoints in the column."
  (setq-local truncate-lines t)
  (buffer-disable-undo)
  (setq header-line-format '(:eval (drgnx-debug-disassembly--header)))
  (drgnx-margins-claim 'debug (drgnx-debug-gutter--columns) :order 0))

(defun drgnx-debug-disassembly--address (s)
  "The number of address S (\"0x…\" or decimal), or nil."
  (when (stringp s)
    (if (string-prefix-p "0x" (downcase s)) (string-to-number (substring s 2) 16) (string-to-number s))))

(defun drgnx-debug-disassembly--header ()
  "The header: the frame and the session; the chip while the step keys step one instruction."
  (let ((s (seq-find (lambda (s) (equal (plist-get s :id) drgnx-debug-disassembly--session)) drgnx-debug--sessions)))
    (concat " " (propertize "Disassembly" 'face 'bold) "  "
            (propertize (string-join (delq nil (list (plist-get drgnx-debug-disassembly--frame :name)
                                                     (plist-get s :name)))
                                     " · ")
                        'face 'drgnx-text-subtle)
            (when (eq (selected-window) (get-buffer-window (current-buffer)))
              (concat "  " (propertize " instruction step " 'face 'drgnx-debug-disassembly-step))))))

(defun drgnx-debug-disassembly--state (session)
  "SESSION's plist in the last `debug-state'."
  (seq-find (lambda (s) (equal (plist-get s :id) session)) drgnx-debug--sessions))

(defun drgnx-debug-disassembly-frame (data)
  "A `debug-frame' event (DATA): remember where its instruction is; an open view of its session follows it."
  (when-let* ((session (plist-get data :session)) ((plist-get data :instruction_pointer)))
    (setf (alist-get session drgnx-debug-disassembly--frames nil nil #'equal) data)
    (when-let* ((b (get-buffer drgnx-debug-disassembly-buffer-name)))
      (with-current-buffer b
        (when (equal drgnx-debug-disassembly--session session)
          (setq drgnx-debug-disassembly--frame data)
          (if (drgnx-debug-disassembly--line-of (drgnx-debug-disassembly--address (plist-get data :instruction_pointer)))
              (drgnx-debug-disassembly--mark)
            (drgnx-debug-disassembly--at (plist-get data :instruction_pointer))))))))

(defun drgnx-debug-disassembly-show (data)
  "Open the view at `debug-frame' DATA when its adapter disassembles; nil when it cannot."
  (when-let* ((session (plist-get data :session)) ((plist-get data :instruction_pointer))
              ((drgnx-debug-can-p (drgnx-debug-disassembly--state session) :supportsDisassembleRequest)))
    (drgnx-debug-disassembly-open session data)
    t))

(defun drgnx-debug-disassembly-open (session frame)
  "Show the instructions around FRAME's (a `debug-frame' plist) in SESSION."
  (let ((b (get-buffer-create drgnx-debug-disassembly-buffer-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-debug-disassembly-mode) (drgnx-debug-disassembly-mode))
      (unless (equal drgnx-debug-disassembly--session session)
        (setq drgnx-debug-disassembly--bps nil drgnx-debug-disassembly--version 0))
      (setq drgnx-debug-disassembly--session session drgnx-debug-disassembly--frame frame)
      (drgnx-debug-disassembly--at (plist-get frame :instruction_pointer))
      (drgnx-debug-disassembly--ask nil))
    (pop-to-buffer b)))

(defun drgnx-debug-open-disassembly ()
  "Open Disassembly View: the instructions around the stopped session's current frame."
  (interactive)
  (let* ((s (or (drgnx-debug--session "stopped") (user-error "No stopped debug session")))
         (frame (or (alist-get (plist-get s :id) drgnx-debug-disassembly--frames nil nil #'equal)
                    (user-error "The debugger gives no instruction for this frame"))))
    (unless (drgnx-debug-can-p s :supportsDisassembleRequest)
      (user-error "This debugger cannot disassemble"))
    (drgnx-debug-disassembly-open (plist-get s :id) frame)))

(defun drgnx-debug-disassembly--at (anchor)
  "Read the page around ANCHOR (an address string): a quarter of it before."
  (setq drgnx-debug-disassembly--anchor anchor
        drgnx-debug-disassembly--first (- (/ drgnx-debug-disassembly-count 4)))
  (drgnx-debug-disassembly--read))

(defun drgnx-debug-disassembly--read ()
  "Read the page and draw it when it comes."
  (let ((b (current-buffer)))
    (drgnx-hub-call "debug/disassemble" (list :session drgnx-debug-disassembly--session
                                              :reference drgnx-debug-disassembly--anchor
                                              :instruction_offset drgnx-debug-disassembly--first
                                              :count drgnx-debug-disassembly-count)
                    (lambda (r error)
                      (when (buffer-live-p b)
                        (with-current-buffer b
                          (if error (message "Disassembly: %s" error)
                            (drgnx-debug-disassembly--draw (append (plist-get r :instructions) nil)))))))))

(defun drgnx-debug-disassembly--source-line (path line)
  "LINE of file PATH, trimmed, or nil when it cannot be read."
  (when (and path line (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (when (zerop (forward-line (1- line)))
        (string-trim (buffer-substring-no-properties (point) (line-end-position)))))))

(defun drgnx-debug-disassembly--draw (instructions)
  "Draw INSTRUCTIONS: a source row where the place changes, then each one's address, bytes and text."
  (let ((inhibit-read-only t) (place nil) (at (drgnx-debug-disassembly--line-address)))
    (delete-region (point-min) (point-max))
    (dolist (i instructions)
      (let ((path (plist-get i :path)) (line (plist-get i :line)))
        (when (and path line (not (equal place (cons path line))))
          (setq place (cons path line))
          (insert (propertize (concat "  " (or (drgnx-debug-disassembly--source-line path line) ""))
                              'face 'drgnx-debug-disassembly-source)
                  "  " (propertize (format "%s:%d" (file-name-nondirectory path) line)
                                   'face 'drgnx-debug-disassembly-place)
                  "\n"))
        (insert (propertize (concat (propertize (format "%-18s" (plist-get i :address))
                                                'face 'drgnx-debug-disassembly-address)
                                    (propertize (format "%-24s" (or (plist-get i :bytes) ""))
                                                'face 'drgnx-debug-disassembly-bytes)
                                    (plist-get i :instruction))
                            'drgnx-debug-disassembly-address (drgnx-debug-disassembly--address (plist-get i :address))
                            'help-echo (plist-get i :symbol))
                "\n")))
    (drgnx-debug-disassembly--mark)
    (goto-char (point-min))
    (when-let* ((p (drgnx-debug-disassembly--line-of
                    (or at (drgnx-debug-disassembly--address
                            (plist-get drgnx-debug-disassembly--frame :instruction_pointer))))))
      (goto-char p))))

(defun drgnx-debug-disassembly--line-address ()
  "The address of the instruction on point's line, or nil."
  (get-text-property (line-beginning-position) 'drgnx-debug-disassembly-address))

(defun drgnx-debug-disassembly--line-of (address)
  "The start of the line of instruction ADDRESS (a number), or nil."
  (when address
    (save-excursion
      (goto-char (point-min))
      (let ((found nil))
        (while (and (not found) (not (eobp)))
          (if (eql (get-text-property (point) 'drgnx-debug-disassembly-address) address)
              (setq found (point))
            (forward-line 1)))
        found))))

(defun drgnx-debug-disassembly--bp-address (bp)
  "The address BP stops at: its instruction plus its offset."
  (when-let* ((a (drgnx-debug-disassembly--address (plist-get bp :instruction))))
    (+ a (or (plist-get bp :offset) 0))))

(defun drgnx-debug-disassembly--mark ()
  "Mark the current instruction and the instruction breakpoints in the column."
  (mapc #'delete-overlay drgnx-debug-disassembly--marks)
  (setq drgnx-debug-disassembly--marks nil)
  (let ((ip (drgnx-debug-disassembly--address (plist-get drgnx-debug-disassembly--frame :instruction_pointer)))
        (top (eq (plist-get drgnx-debug-disassembly--frame :top) t)))
    (dolist (bp drgnx-debug-disassembly--bps)
      (let ((addr (drgnx-debug-disassembly--bp-address bp)))
        (unless (eql addr ip)
          (when-let* ((p (drgnx-debug-disassembly--line-of addr)))
            (drgnx-debug-disassembly--put p (cond ((not (eq (plist-get bp :enabled) t)) 'off)
                                                  ((not (eq (plist-get bp :verified) t)) 'unverified)
                                                  ((or (plist-get bp :condition) (plist-get bp :hit)) 'cond)
                                                  (t 'bp))
                                          (format "Instruction breakpoint at %s" (plist-get bp :instruction)) nil)))))
    (when-let* ((p (drgnx-debug-disassembly--line-of ip)))
      (drgnx-debug-disassembly--put p (if top 'stop 'frame) "The current instruction"
                                    (if top 'drgnx-debug-stopped-line 'drgnx-debug-frame-line)))))

(defun drgnx-debug-disassembly--put (pos kind help line-face)
  "A mark of KIND on the line at POS, with HELP; LINE-FACE over the line when non-nil."
  (let ((o (make-overlay pos (save-excursion (goto-char pos) (min (point-max) (1+ (line-end-position)))))))
    (overlay-put o 'before-string (drgnx-debug-gutter--margin-string kind help))
    (when line-face (overlay-put o 'face line-face))
    (push o drgnx-debug-disassembly--marks)))

(defun drgnx-debug-disassembly--apply (view)
  "Take the hub's instruction VIEW of this session (newer `version' wins) and mark it."
  (when (>= (or (plist-get view :version) 0) drgnx-debug-disassembly--version)
    (setq drgnx-debug-disassembly--version (or (plist-get view :version) 0)
          drgnx-debug-disassembly--bps (append (plist-get view :breakpoints) nil))
    (drgnx-debug-disassembly--mark)))

(defun drgnx-debug-disassembly-breakpoints (view)
  "A `debug-breakpoints' event with a session and no path: VIEW of its instruction breakpoints."
  (when-let* ((b (get-buffer drgnx-debug-disassembly-buffer-name)))
    (with-current-buffer b
      (when (equal drgnx-debug-disassembly--session (plist-get view :session))
        (drgnx-debug-disassembly--apply view)))))

(defun drgnx-debug-disassembly--ask (op)
  "Send OP (nil: only ask) on the session's instruction breakpoints; mark the answer."
  (let ((b (current-buffer)))
    (drgnx-hub-call "debug/breakpoints"
                    (append (list :root (drgnx-debug-launch-root) :session drgnx-debug-disassembly--session
                                  :kind "instruction")
                            (and op (list :op op)))
                    (lambda (result error)
                      (if error (message "Disassembly: %s" error)
                        (when (and result (buffer-live-p b))
                          (with-current-buffer b (drgnx-debug-disassembly--apply result))))))))

(defun drgnx-debug-disassembly-toggle-breakpoint ()
  "An instruction breakpoint on the instruction at point, or none."
  (interactive)
  (let ((addr (or (drgnx-debug-disassembly--line-address) (user-error "No instruction here"))))
    (unless (drgnx-debug-can-p (drgnx-debug-disassembly--state drgnx-debug-disassembly--session)
                               :supportsInstructionBreakpoints)
      (user-error "This debugger has no instruction breakpoints"))
    (drgnx-debug-disassembly--ask
     (if-let* ((bp (seq-find (lambda (bp) (eql (drgnx-debug-disassembly--bp-address bp) addr))
                             drgnx-debug-disassembly--bps)))
         (list :op "remove-instruction" :id (plist-get bp :n))
       (list :op "add-instruction" :instruction (format "0x%x" addr))))))

(defun drgnx-debug-disassembly-earlier ()
  "Read the instructions before this page."
  (interactive)
  (cl-decf drgnx-debug-disassembly--first drgnx-debug-disassembly-count)
  (drgnx-debug-disassembly--read))

(defun drgnx-debug-disassembly-later ()
  "Read the instructions after this page."
  (interactive)
  (cl-incf drgnx-debug-disassembly--first drgnx-debug-disassembly-count)
  (drgnx-debug-disassembly--read))

(defun drgnx-debug-disassembly-instruction-step-p ()
  "Whether the step keys step one instruction: the disassembly view has focus."
  (derived-mode-p 'drgnx-debug-disassembly-mode))

(defun drgnx-debug-disassembly--teardown ()
  "The view goes with the module."
  (setq drgnx-debug-disassembly--frames nil)
  (when-let* ((b (get-buffer drgnx-debug-disassembly-buffer-name))) (kill-buffer b)))

(defconst drgnx-debug-disassembly-commands
  '((debug-disassembly-toggle-breakpoint "Disassembly: Toggle Instruction Breakpoint"
                                         drgnx-debug-disassembly-toggle-breakpoint
                                         "An instruction breakpoint on the instruction at point, or none")
    (debug-disassembly-earlier "Disassembly: Earlier Instructions" drgnx-debug-disassembly-earlier
                               "Read the instructions before this page")
    (debug-disassembly-later "Disassembly: Later Instructions" drgnx-debug-disassembly-later
                             "Read the instructions after this page"))
  "The disassembly view's commands, keys of its own map: (ID TITLE FUNCTION DOC).")

(provide 'drgnx-debug-disassembly)
;;; drgnx-debug-disassembly.el ends here
