;;; debug-disassembly-test.el --- batch tests: the disassembly view, its marks and instruction breakpoints -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; What the view asks of the hub (`debug/disassemble', `debug/breakpoints') is recorded and answered here.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)

(defmacro debug-disassembly-test--with (&rest body)
  "BODY with the hub's calls recorded in CALLS (newest first) as (METHOD PARAMS CALLBACK), a stopped session s1 that
disassembles and takes instruction breakpoints, and the view's buffer killed after."
  (declare (indent 0))
  `(let ((calls nil)
         (drgnx-debug-disassembly--frames nil)
         (drgnx-debug--sessions (list (list :id "s1" :name "stockroom" :state "stopped" :root "/p/"
                                            :caps (list :supportsDisassembleRequest t
                                                        :supportsInstructionBreakpoints t)))))
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params cb &rest _) (push (list method params cb) calls)))
               ((symbol-function 'drgnx-debug-launch-root) (lambda () "/p/")))
       (unwind-protect (save-window-excursion ,@body)
         (when (get-buffer drgnx-debug-disassembly-buffer-name) (kill-buffer drgnx-debug-disassembly-buffer-name))))))

(defun debug-disassembly-test--answer (calls method result)
  "Answer the newest call of CALLS to METHOD with RESULT."
  (funcall (nth 2 (seq-find (lambda (c) (equal (car c) method)) calls)) result nil))

(defconst debug-disassembly-test--page
  (vector (list :address "0x401136" :bytes "48 8b 7d f8" :instruction "mov rdi, [rbp-0x8]" :path "/nowhere/pack.c" :line 47)
          (list :address "0x40113a" :bytes "e8 c1 ff ff ff" :instruction "call pack_size" :path "/nowhere/pack.c" :line 47)
          (list :address "0x40113f" :bytes "89 45 f4" :instruction "mov [rbp-0xc], eax" :path "/nowhere/pack.c" :line 47)
          (list :address "0x401142" :bytes "8b 45 f0" :instruction "mov eax, [rbp-0x10]" :path "/nowhere/pack.c" :line 48))
  "A page: two source places.")

(defun debug-disassembly-test--marks ()
  "The view's marks: (LINE-TEXT-START . KIND-STRING) from each before-string's help."
  (with-current-buffer drgnx-debug-disassembly-buffer-name
    (sort (mapcar (lambda (o) (cons (line-number-at-pos (overlay-start o))
                                    (get-text-property 0 'help-echo (overlay-get o 'before-string))))
                  drgnx-debug-disassembly--marks)
          (lambda (a b) (< (car a) (car b))))))

(ert-deftest drgnx-debug-disassembly/opens-at-the-stop ()
  "Open Disassembly View reads the instructions around the frame's instruction (a quarter before), shows a source row
where the place changes, then address, bytes and instruction, and marks the current one."
  (debug-disassembly-test--with
    (drgnx-debug-disassembly-frame (list :session "s1" :top t :name "pack" :instruction_pointer "0x40113f"))
    (drgnx-debug-open-disassembly)
    (should (equal (cadr (assoc "debug/disassemble" calls))
                   (list :session "s1" :reference "0x40113f" :instruction_offset (- (/ drgnx-debug-disassembly-count 4))
                         :count drgnx-debug-disassembly-count)))
    (should (equal (cadr (assoc "debug/breakpoints" calls)) (list :root "/p/" :session "s1" :kind "instruction")))
    (debug-disassembly-test--answer calls "debug/disassemble" (list :instructions debug-disassembly-test--page))
    (with-current-buffer drgnx-debug-disassembly-buffer-name
      (should (equal (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")
                     '("   pack.c:47"
                       "0x401136          48 8b 7d f8             mov rdi, [rbp-0x8]"
                       "0x40113a          e8 c1 ff ff ff          call pack_size"
                       "0x40113f          89 45 f4                mov [rbp-0xc], eax"
                       "   pack.c:48"
                       "0x401142          8b 45 f0                mov eax, [rbp-0x10]"
                       "")))
      (should (= (line-number-at-pos) 4))
      (should (string-search "pack · stockroom" (drgnx-debug-disassembly--header))))
    (should (equal (debug-disassembly-test--marks) '((4 . "The current instruction"))))))

(ert-deftest drgnx-debug-disassembly/the-rows-look-like-the-mockup ()
  "debugging-extras.html `.dis': the mnemonic, the registers and the symbols each in their face; a source row italic
with its place pushed to the right edge; the header's instruction-step chip at the right edge."
  (debug-disassembly-test--with
    (drgnx-debug-disassembly-frame (list :session "s1" :top t :name "pack" :instruction_pointer "0x40113f"))
    (drgnx-debug-open-disassembly)
    (debug-disassembly-test--answer calls "debug/disassemble" (list :instructions debug-disassembly-test--page))
    (with-current-buffer drgnx-debug-disassembly-buffer-name
      (cl-flet ((face-of (word &optional n)
                  (save-excursion
                    (goto-char (point-min))
                    (dotimes (_ (or n 1)) (search-forward word))
                    (let ((f (get-text-property (match-beginning 0) 'face))) (if (listp f) f (list f))))))
        (should (memq 'drgnx-debug-disassembly-mnemonic (face-of "mov")))
        (should (memq 'drgnx-debug-disassembly-register (face-of "rdi")))
        (should (memq 'drgnx-debug-disassembly-register (face-of "rbp")))
        (should (memq 'drgnx-debug-disassembly-symbol (face-of "pack_size")))
        (should-not (memq 'drgnx-debug-disassembly-register (face-of "0x8")))
        (should (memq 'drgnx-debug-disassembly-place (face-of "pack.c:47"))))
      (goto-char (point-min))
      (search-forward "pack.c:47")
      (let ((gap (get-text-property (- (match-beginning 0) 1) 'display)))
        (should (eq (car-safe gap) 'space))
        (should (eq (car-safe (plist-get (cdr gap) :align-to)) '-)))
      (let ((head (save-window-excursion
                    (select-window (display-buffer (current-buffer)))
                    (drgnx-debug-disassembly--header))))
        (should (string-match-p "instruction step" head))
        (let ((pos (string-search "instruction step" head)))
          (should (eq (car-safe (plist-get (cdr (get-text-property (- pos 2) 'display head)) :align-to)) '-)))))))

(ert-deftest drgnx-debug-disassembly/instruction-breakpoints ()
  "The column toggles an instruction breakpoint (`add-instruction', `remove-instruction' by its number) and draws the
session's instruction view, a newer version winning; the hub's event for the session redraws it."
  (debug-disassembly-test--with
    (drgnx-debug-disassembly-frame (list :session "s1" :top t :instruction_pointer "0x40113f"))
    (drgnx-debug-open-disassembly)
    (debug-disassembly-test--answer calls "debug/disassemble" (list :instructions debug-disassembly-test--page))
    (with-current-buffer drgnx-debug-disassembly-buffer-name
      (goto-char (point-min))
      (forward-line 2)                  ; 0x40113a
      (drgnx-debug-disassembly-toggle-breakpoint)
      (should (equal (cadr (car calls)) (list :root "/p/" :session "s1" :kind "instruction"
                                              :op (list :op "add-instruction" :instruction "0x40113a"))))
      (debug-disassembly-test--answer
       calls "debug/breakpoints"
       (list :session "s1" :version 2 :breakpoints (vector (list :id "i:s1:1" :n 1 :kind "instruction"
                                                                 :instruction "0x40113a" :verified t :enabled t))))
      (should (equal (debug-disassembly-test--marks) '((3 . "Instruction breakpoint at 0x40113a")
                                                       (4 . "The current instruction"))))
      ;; an older view is dropped
      (drgnx-debug-disassembly-breakpoints (list :session "s1" :version 1 :breakpoints []))
      (should (= 2 (length drgnx-debug-disassembly--marks)))
      (drgnx-debug-disassembly-toggle-breakpoint)
      (should (equal (plist-get (cadr (car calls)) :op) (list :op "remove-instruction" :id 1)))
      (drgnx-debug-disassembly-breakpoints (list :session "s1" :version 3 :breakpoints []))
      (should (equal (debug-disassembly-test--marks) '((4 . "The current instruction"))))
      ;; an adapter without instruction breakpoints is not asked
      (let ((drgnx-debug--sessions (list (list :id "s1" :state "stopped" :caps (list :supportsDisassembleRequest t))))
            (n (length calls)))
        (should-error (drgnx-debug-disassembly-toggle-breakpoint) :type 'user-error)
        (should (= n (length calls)))))))

(ert-deftest drgnx-debug-disassembly/follows-the-stop-and-steps-instructions ()
  "A new stop on the page moves the mark without a read; one off the page reads around it.  The step keys ask for
one instruction while the view has focus; paging reads before and after."
  (debug-disassembly-test--with
    (drgnx-debug-disassembly-frame (list :session "s1" :top t :instruction_pointer "0x40113f"))
    (drgnx-debug-open-disassembly)
    (debug-disassembly-test--answer calls "debug/disassemble" (list :instructions debug-disassembly-test--page))
    (let ((n (length calls)))
      (drgnx-debug-disassembly-frame (list :session "s1" :top t :instruction_pointer "0x401142"))
      (should (= n (length calls)))
      (should (equal (debug-disassembly-test--marks) '((6 . "The current instruction"))))
      (drgnx-debug-disassembly-frame (list :session "s1" :top t :instruction_pointer "0x500000"))
      (should (equal (plist-get (cadr (car calls)) :reference) "0x500000")))
    (with-current-buffer drgnx-debug-disassembly-buffer-name
      (cl-letf (((symbol-function 'drgnx-debug--session) (lambda (&rest _) (car drgnx-debug--sessions))))
        (drgnx-debug-step-over)
        (should (equal (cadr (car calls)) (list :session "s1" :op "next" :granularity "instruction"))))
      (let ((first drgnx-debug-disassembly--first))
        (drgnx-debug-disassembly-earlier)
        (should (equal (plist-get (cadr (car calls)) :instruction_offset) (- first drgnx-debug-disassembly-count)))
        (drgnx-debug-disassembly-later)
        (should (equal (plist-get (cadr (car calls)) :instruction_offset) first))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'drgnx-debug--session) (lambda (&rest _) (car drgnx-debug--sessions))))
        (drgnx-debug-step-over)
        (should (equal (cadr (car calls)) (list :session "s1" :op "next")))))))

(ert-deftest drgnx-debug-disassembly/opened-at-a-stop-with-no-file ()
  "A stop the editor opens with no file and no source opens the view when the adapter disassembles; without it, or
without an instruction, it says there is no source."
  (debug-disassembly-test--with
    (drgnx-debug-gutter-show-frame (list :session "s1" :top t :open t :name "pack" :instruction_pointer "0x40113f"))
    (should (get-buffer drgnx-debug-disassembly-buffer-name))
    (should (assoc "debug/disassemble" calls))
    (kill-buffer drgnx-debug-disassembly-buffer-name)
    (let ((drgnx-debug--sessions (list (list :id "s1" :state "stopped" :caps nil))))
      (drgnx-debug-gutter-show-frame (list :session "s1" :top t :open t :name "pack" :instruction_pointer "0x40113f"))
      (should-not (get-buffer drgnx-debug-disassembly-buffer-name)))))

;;; debug-disassembly-test.el ends here
