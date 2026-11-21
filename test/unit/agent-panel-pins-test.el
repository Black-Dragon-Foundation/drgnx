;;; agent-panel-pins-test.el --- the agent panel: pinned cards, the to-do list, the edits ledger -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the panel is fed snapshots and entries by hand, and the hub client's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-entries "drgnx-agent-panel")
(declare-function drgnx-agent-panel-pin "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-ledger "drgnx-agent-panel-cards")

(defmacro drgnx-agent-panel-pins-test--with (&rest body)
  "BODY with the module set up, the hub's calls swallowed, and panel \"s1\" as `buf'."
  (declare (indent 0))
  `(let (buf)
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (unwind-protect (progn (setq buf (drgnx-agent-panel-buffer "s1")) ,@body)
           (when (buffer-live-p buf) (kill-buffer buf)))))))

;;; hub rows: the pinned cards, the to-do list and the ledger are the hub's (view/panel_cards.rs).  What stays here is
;;; the state the editor keeps and sends: what is pinned, and whether the ledger is open.

(defvar drgnx-agent-panel--pins)
(defvar drgnx-agent-panel--ledger-open)
(declare-function drgnx-agent-panel--look-params "drgnx-agent-panel")

(ert-deftest drgnx-agent-panel/pin-a-card ()
  "A pin is the step's one line, sent to the hub with the look (`pins'); pinned again, or from its card (the hub's row
carries `drgnx-agent-panel-pin'), it goes; what is not a step or a card cannot be pinned."
  (drgnx-agent-panel-pins-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (list :type "tool" :id "t1" :title "Read the spec" :kind "read" :status "completed"))
             (list 1 (list :type "tool" :id "t2" :title "Run the tests" :kind "execute" :status "completed"))))
      ;; the hub's step rows, each naming its entry
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "  ● Read the spec\n" 'drgnx-agent-panel-entry 0)
                (propertize "  ● Run the tests\n" 'drgnx-agent-panel-entry 1)
                "  a row that is no step\n"))
      (goto-char (point-min))
      (forward-line 1)
      (drgnx-agent-panel-pin)
      (should (equal '("Run the tests") (append (plist-get (drgnx-agent-panel--look-params) :pins) nil)))
      ;; pinned again from the step: gone; and pinned, then unpinned from the card
      (drgnx-agent-panel-pin)
      (should (= 0 (length (plist-get (drgnx-agent-panel--look-params) :pins))))
      (drgnx-agent-panel-pin)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (propertize "card" 'drgnx-agent-panel-pin 0))
        (goto-char (- (point-max) 2)))
      (drgnx-agent-panel-pin)
      (should-not drgnx-agent-panel--pins)
      ;; something that is not a step or a card cannot be pinned
      (goto-char (point-min))
      (forward-line 2)
      (should-error (drgnx-agent-panel-pin) :type 'user-error))))

(ert-deftest drgnx-agent-panel/the-ledger-open-flag-goes-to-the-hub ()
  (drgnx-agent-panel-pins-test--with
    (with-current-buffer buf
      (should (eq :false (plist-get (drgnx-agent-panel--look-params) :ledger_open)))
      (drgnx-agent-panel-ledger)
      (should (eq t (plist-get (drgnx-agent-panel--look-params) :ledger_open)))
      (drgnx-agent-panel-ledger)
      (should (eq :false (plist-get (drgnx-agent-panel--look-params) :ledger_open))))))

;;; the header's pin button (`drgnx-agent-panel--pin-from'): it pins at the point of the transcript under the header,
;;; on the header's own panel, and nowhere else

(defvar drgnx-agent-companion--main)
(declare-function drgnx-agent-panel--pin-from "drgnx-agent-panel-steps")

(defun drgnx-agent-panel-pins-test--steps (buffer)
  "Give BUFFER, a panel, two steps and the hub's rows for them; point on the second."
  (with-current-buffer buffer
    (drgnx-agent-panel--take-entries
     (list (list 0 (list :type "tool" :id "t1" :title "Read the spec" :kind "read" :status "completed"))
           (list 1 (list :type "tool" :id "t2" :title "Run the tests" :kind "execute" :status "completed"))))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "  ● Read the spec\n" 'drgnx-agent-panel-entry 0)
              (propertize "  ● Run the tests\n" 'drgnx-agent-panel-entry 1)))
    (goto-char (point-min))
    (forward-line 1)))

(defmacro drgnx-agent-panel-pins-test--header (vars &rest body)
  "BODY with VARS (HEADER-WINDOW HEADER) bound: a window split off the selected one, the `above' companion of the
right area, showing HEADER, a buffer whose panel is the current `buf'."
  (declare (indent 1))
  `(let* ((,(nth 1 vars) (generate-new-buffer " pin header"))
          (,(car vars) (split-window (selected-window) nil 'above)))
     (unwind-protect
         (progn
           (with-current-buffer ,(nth 1 vars) (setq-local drgnx-agent-companion--main buf))
           (set-window-buffer ,(car vars) ,(nth 1 vars))
           (set-window-parameter ,(car vars) 'drgnx-role 'right)
           (set-window-parameter ,(car vars) 'drgnx-area-part 'above)
           ,@body)
       (when (window-live-p ,(car vars)) (delete-window ,(car vars)))
       (kill-buffer ,(nth 1 vars)))))

(ert-deftest drgnx-agent-panel/the-headers-pin-wants-its-transcript ()
  "With no transcript window under the header (its area has no main window on the frame), the header's pin is a
user error and pins nothing: not the step at the point of whatever window is selected."
  (drgnx-agent-panel-pins-test--with
    (drgnx-agent-panel-pins-test--steps buf)
    (set-window-buffer (selected-window) buf)
    (set-window-point (selected-window) (with-current-buffer buf (point)))
    (drgnx-agent-panel-pins-test--header (hw _h)
      (cl-letf (((symbol-function 'drgnx-wb-area-window) (lambda (&rest _) nil)))
        (should-error (drgnx-agent-panel--pin-from hw) :type 'user-error))
      (should-not (buffer-local-value 'drgnx-agent-panel--pins buf)))))

(ert-deftest drgnx-agent-panel/the-headers-pin-is-its-own-panels ()
  "When the area's main window shows another chat's panel, the header's pin is a user error and pins in neither."
  (drgnx-agent-panel-pins-test--with
    (let ((other (drgnx-agent-panel-buffer "s2")))
      (unwind-protect
          (progn
            (drgnx-agent-panel-pins-test--steps buf)
            (drgnx-agent-panel-pins-test--steps other)
            (set-window-buffer (selected-window) other)
            (set-window-point (selected-window) (with-current-buffer other (point)))
            (drgnx-agent-panel-pins-test--header (hw _h)
              (let ((tw (selected-window)))
                (cl-letf (((symbol-function 'drgnx-wb-area-window) (lambda (&rest _) tw)))
                  (should-error (drgnx-agent-panel--pin-from hw) :type 'user-error)))
              (should-not (buffer-local-value 'drgnx-agent-panel--pins buf))
              (should-not (buffer-local-value 'drgnx-agent-panel--pins other))))
        (kill-buffer other)))))

(ert-deftest drgnx-agent-panel/the-headers-pin-pins-at-the-transcripts-point ()
  "The header's pin pins the step at its transcript window's point, not at the panel buffer's own point, on the panel."
  (drgnx-agent-panel-pins-test--with
    (drgnx-agent-panel-pins-test--steps buf)
    (set-window-buffer (selected-window) buf)
    (let ((tw (selected-window)))
      (set-window-point tw (with-current-buffer buf (point)))           ; the second step
      (drgnx-agent-panel-pins-test--header (hw _h)
        (select-window hw)                                              ; the transcript is not selected
        (with-current-buffer buf (goto-char (point-min)))              ; the buffer's own point on the first step
        (cl-letf (((symbol-function 'drgnx-wb-area-window) (lambda (&rest _) tw)))
          (drgnx-agent-panel--pin-from hw))
        (should (equal '((:e 1)) (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins buf))))))))

(ert-deftest drgnx-agent-panel/the-headers-pin-at-the-end-pins-the-last-step ()
  "A transcript that follows its end keeps its window's point after its last row: the header's pin there pins the last
step, not a user error about a point the user never placed."
  (drgnx-agent-panel-pins-test--with
    (drgnx-agent-panel-pins-test--steps buf)
    (set-window-buffer (selected-window) buf)
    (let ((tw (selected-window)))
      (set-window-point tw (with-current-buffer buf (point-max)))
      (drgnx-agent-panel-pins-test--header (hw _h)
        (select-window hw)
        (cl-letf (((symbol-function 'drgnx-wb-area-window) (lambda (&rest _) tw)))
          (drgnx-agent-panel--pin-from hw))
        (should (equal '((:e 1)) (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins buf))))))))

(provide 'agent-panel-pins-test)
;;; agent-panel-pins-test.el ends here
